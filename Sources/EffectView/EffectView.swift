import SwiftUI

/// A SwiftUI view that manages structured side effects via an Elm-style update loop.
///
/// `EffectView` owns the task scheduler for the duration of its view identity.
/// State is held by the caller via `Binding` so ancestor views can observe changes.
/// `update` is the single mutation point: it receives an event, mutates state, and
/// optionally returns an ``Effect`` to run or cancel.
///
/// ### Basic usage
///
/// ```swift
/// enum Event { case increment, reset }
/// struct MyState { var count = 0 }
///
/// @State private var state = MyState()
///
/// EffectView(
///     state: $state,
///     update: { state, event in
///         switch event {
///         case .increment: state.count += 1; return nil
///         case .reset:     state.count  = 0; return nil
///         }
///     }
/// ) { state, send in
///     Button("\(state.count)") { send(.increment) }
/// }
/// ```
///
/// ### Using `Env` for dependencies
///
/// Pass dependencies (clocks, API clients, etc.) via `Env`. The value is captured
/// once when the view appears and forwarded to every effect.
///
/// ```swift
/// struct Env { let api: any APIClient }
///
/// EffectView(
///     state: $state,
///     initialEnv: Env(api: liveAPI),
///     update: { state, event in
///         switch event {
///         case .load:
///             return .run(name: "load") { input, env in
///                 let data = await env.api.fetch()
///                 input(.loaded(data))
///             }
///         case .loaded(let data):
///             state.data = data; return nil
///         }
///     }
/// ) { state, send in
///     Button("Load") { send(.load) }
/// }
/// ```
///
/// ### Env changes
///
/// If `Env` changes during the view's lifetime, running effects keep the original
/// captured value. To restart with new dependencies, apply `.id(env)` at the call
/// site (requires `Env: Hashable`). This destroys the old view — cancelling all
/// tasks — and creates a fresh instance with the updated `Env`.
///
/// ### Generic parameters
///
/// - `State`: The type of the view's mutable state.
/// - `Event`: The event type driving state transitions.
/// - `Env`: The dependency environment. Use `Void` for no dependencies.
/// - `Output`: The value returned to callers of ``Input/request(_:)``.
///   Use `Void` when no return value is needed.
/// - `Content`: The view builder output type.
@MainActor
public struct EffectView<
    State,
    Event,
    Env: Sendable,
    Output: Sendable,
    Content: View
>: View {
    
    @SwiftUI.State private var input: Input<Event, Output>? = nil

    private var state: Binding<State>
    private var initialEvent: Event?
    private let env: Env
    private var update: (inout State, Event) -> Effect<Event, Env, Output>?
    private let content: (State, Input<Event, Output>) -> Content
    
        
    /// Creates an effect-managed view with a captured dependency environment.
    ///
    /// `initialEvent`, `initialEnv`, and `update` are captured once when the view
    /// appears for the first time. Later changes are intentionally ignored to avoid
    /// mid-flight dependency swaps during running effects. To restart with new
    /// dependencies, use `.id(env)` at the call site (requires `Env: Hashable`).
    ///
    /// ```swift
    /// EffectView(
    ///     state: $state,
    ///     initialEnv: env,
    ///     update: Self.update
    /// ) { state, send in
    ///     Button("Start") { send(.start) }
    /// }
    /// .id(env.id)
    /// ```
    ///
    /// - Parameters:
    ///   - state: A `Binding` to the view's state, owned by the caller.
    ///   - initialEvent: An optional event sent when the view first appears.
    ///   - initialEnv: The environment captured for this view's lifetime.
    ///   - update: Mutates state and returns an optional ``Effect``.
    ///   - content: Builds the view from current state and an ``Input`` handle.
    public init(
        state: Binding<State>,
        initialEvent: Event? = nil,
        initialEnv: Env,
        update: @escaping (inout State, Event) -> Effect<Event, Env, Output>?,
        @ViewBuilder content: @escaping (State, Input<Event, Output>) -> Content
    ) {
        self.state = state
        self.initialEvent = initialEvent
        self.env = initialEnv
        self.update = update
        self.content = content
    }
    
    public var body: some View {
        HStack {
            if let input {
                content(self.state.wrappedValue, input)
            } else {
                // transparent placeholder; holds layout until effectManager is ready
                Color.clear 
                    .frame(maxWidth: 1, maxHeight: 1)
            }
        }
        .task {
            guard self.input == nil else {
                return
            }

            let effectManager = EffectManager()
            let stateBinding = self.state
            let env = self.env
            let update = self.update
            let send = { @MainActor @Sendable (event: Event, input: Input<Event, Output>, continuation: CheckedContinuation<Output?, Never>?) in
                Self.compute(
                    event: event,
                    continuation: continuation,
                    state: stateBinding,
                    effectManager: effectManager,
                    input: input,
                    env: env,
                    update: update
                )
            }
            self.input = Input(send: send)
            if let event = initialEvent {
                input?.send(event)
            }
        }
    }
    
    private static func compute(
        event: Event,
        continuation: CheckedContinuation<Output?, Never>?,
        state: Binding<State>,
        effectManager: EffectManager,
        input: Input<Event, Output>,
        env: Env,
        update: (inout State, Event) -> Effect<Event, Env, Output>?
    ) {
        var nextEvent: Event? = event
        var cont = continuation
        while let event = nextEvent {
            nextEvent = nil
            if let effect = update(&state.wrappedValue, event) {
                (nextEvent, cont) = executeEffect(
                    effect,
                    continuation: cont,
                    effectManager: effectManager,
                    input: input,
                    env: env
                )
            } else {
                cont?.resume(returning: nil)
                cont = nil
            }
        }
        assert(cont == nil)
    }
    
    private static func executeEffect(
        _ effect: Effect<Event, Env, Output>,
        continuation: CheckedContinuation<Output?, Never>?,
        effectManager: EffectManager,
        input: Input<Event, Output>,
        env: Env
    ) -> (Event?, CheckedContinuation<Output?, Never>?) {
        switch effect {
        case .task(name: let name, priority: let priority, operation: let operation):
            effectManager.add(
                name: name,
                priority: priority,
                operation: {
                    let output = await operation(input, env)
                    continuation?.resume(returning: output)
                }
            )
            return (nil, nil)

        case .event(let event):
            return (event, continuation)
            
        case .action(action: let action):
            let event = action(env)
            if event == nil {
                continuation?.resume(returning: nil)
                return (nil, nil)
            }
            return (event, continuation)

        case .cancel(let name):
            effectManager.cancel(name: name)
            continuation?.resume(returning: nil)
            return (nil, nil)

        case .sequence(let effects):
            guard let last = effects.last else {
                continuation?.resume(returning: nil)
                return (nil, nil)
            }
            for effect in effects.dropLast() {
                _ = executeEffect(effect, continuation: nil, effectManager: effectManager, input: input, env: env)
            }
            return executeEffect(last, continuation: continuation, effectManager: effectManager, input: input, env: env)
        }
    }
}

extension EffectView where Env == Void {
    
    /// Creates an effect-managed view with no external dependencies.
    ///
    /// `initialEvent` and `update` are captured once when the view appears for
    /// the first time. Later changes to `update` are intentionally ignored.
    /// To reset the view, recreate its identity with `.id(...)`.
    ///
    /// ```swift
    /// EffectView(
    ///     state: $state,
    ///     update: Self.update
    /// ) { state, send in
    ///     Button("Start") { send(.start) }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - state: A `Binding` to the view's state, owned by the caller.
    ///   - initialEvent: An optional event sent when the view first appears.
    ///   - update: Mutates state and returns an optional ``Effect``.
    ///   - content: Builds the view from current state and an ``Input`` handle.
    public init(
        state: Binding<State>,
        initialEvent: Event? = nil,
        update: @escaping (inout State, Event) -> Effect<Event, Void, Output>?,
        @ViewBuilder content: @escaping (State, Input<Event, Output>) -> Content
    ) {
        self.state = state
        self.initialEvent = initialEvent
        self.env = ()
        self.update = update
        self.content = content
    }
}

// MARK: - Implementation

@MainActor
fileprivate final class EffectManager {
    private var tasks: Set<TaskID> = []
    
    init() {
        print("EffectManager: init")
    }
    
    isolated deinit {
        print("EffectManager: deinit")
        tasks.forEach { $0.task.cancel() }
    }

    @discardableResult
    func cancel(name: String) -> Bool {
        if let taskId = tasks.first(where: { $0.name == name }) {
            taskId.task.cancel()
            return true
        } else {
            return false
        }
    }

    func add(
        name: String? = nil,
        priority: TaskPriority? = nil,
        operation: sending @escaping @isolated(any) () async -> Void
    ) {
        if let taskName = name {
            cancel(name: taskName)
        }
        let id = Self.makeTaskID(name: name, priority: priority, operation: operation)
        tasks.insert(id)
        Task { [weak self] in
            defer {
                self?.complete(id: id)
            }
            await id.task.value
        }
    }

    private struct TaskID: Hashable, Equatable {
        let name: String?
        let task: Task<Void, Never>
    }
    
    private func complete(id: TaskID) {
        guard let _ = tasks.remove(id) else {
            fatalError("could not find task with id \(id)")
        }
    }

    private static func makeTaskID(
        name: String? = nil,
        priority: TaskPriority? = nil,
        operation: sending @escaping @isolated(any) () async -> Void
    ) -> TaskID {
        TaskID(
            name: name,
            task: Task(priority: priority, operation: operation)
        )
    }
    
}
