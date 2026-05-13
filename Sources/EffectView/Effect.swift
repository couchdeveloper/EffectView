
/// A value describing a side effect to run after a state transition.
///
/// `update` returns an `Effect` to declare what async or synchronous work should
/// happen next. The effect engine executes it; `update` itself stays synchronous
/// and free of side effects. `Env` is forwarded to every effect so operations and
/// actions can access dependencies without capturing them at the call site.
///
/// ```swift
/// // Fire-and-forget task:
/// return .run(name: "ticker") { input, env in
///     while true {
///         try await env.clock.sleep(for: .seconds(1))
///         input(.tick)
///     }
/// }
///
/// // Perform-driven task (caller awaits result):
/// return .request(name: "load") { input, env in
///     let user = await env.api.fetchUser()
///     return await input.request(.loaded(user))
/// }
///
/// // Synchronous step — next event returned inline:
/// return .action { env in
///     env.analytics.track(.buttonTapped)
///     return .next
/// }
/// ```
///
/// ### Generic parameters
///
/// - `Event`: The event type of the FSM this effect belongs to.
/// - `Env`: The dependency environment forwarded into every task and action closure.
/// - `Output`: The value type returned to a caller suspended on ``Input/request(_:)``.
///   Use `Void` when no return value is needed.
public enum Effect<Event, Env, Output> {

    /// Starts an async operation tracked by the effect engine.
    ///
    /// The `operation` closure receives an ``Input`` handle for dispatching events and
    /// the captured `Env` for dependencies. Named tasks are automatically cancelled when
    /// the view disappears, or when ``cancel(_:)`` is returned from `update` with the
    /// same name. If a task with the same name is already running, it is cancelled before
    /// the new one starts.
    ///
    /// Prefer ``run(name:priority:operation:)`` for fire-and-forget tasks and
    /// ``request(name:priority:operation:)`` for perform-driven tasks rather than
    /// constructing `.task` directly.
    ///
    /// - Parameters:
    ///   - name: An optional name used to track and cancel the task. Pass `nil` for
    ///     anonymous tasks that run to completion without cancellation support.
    ///   - priority: The `TaskPriority` for the launched task. Pass `nil` to inherit
    ///     the current task's priority.
    ///   - operation: The async work to perform. Returns an optional `Output` value
    ///     forwarded to any caller suspended on ``Input/request(_:)``.
    case task(
        name: String? = nil,
        priority: TaskPriority? = nil,
        operation: @Sendable @isolated(any) (Input<Event, Output>, Env) async -> Output?
    )

    /// A synchronous step that may produce the next event to process immediately.
    ///
    /// The `action` closure receives `Env` and returns the next `Event` to feed back
    /// into `update`, or `nil` to end the chain. The entire chain runs synchronously
    /// on the `@MainActor` before any other work proceeds.
    ///
    /// - Parameter action: A synchronous closure receiving `Env` and returning an
    ///   optional next event.
    ///
    /// - Warning: Action chains unwind entirely on the `@MainActor` without yielding.
    ///   A cycle — two events that each produce an `.action` pointing back at the other —
    ///   will hang the main thread. Use ``run(name:priority:operation:)`` for any work
    ///   that could repeat or loop.
    case action(
        action: @Sendable (Env) -> Event?
    )
    
    /// Feeds `event` back into `update` immediately, in the current synchronous turn.
    case event(Event)
    
    /// Cancels the running task with the given name, if any.
    case cancel(String)

    /// Runs a list of effects left to right, associating the caller's continuation
    /// with the last effect only.
    ///
    /// ```swift
    /// // Cancel a stale load before starting a refresh:
    /// return .sequence([.cancel("load"), .refreshMovies()])
    /// ```
    ///
    /// - Important: Intermediate effects must be synchronous and terminal (`.cancel`
    ///   or side-effect `.action` closures). An intermediate effect that returns an
    ///   event is not supported — the event is silently discarded. Use a dedicated
    ///   `update` step for event-producing chains instead.
    case sequence([Effect<Event, Env, Output>])
}

extension Effect {

    /// Starts a fire-and-forget async task that communicates back through events.
    ///
    /// Use for long-running background work — timers, observers, subscriptions — where
    /// the caller does not need to await a result. The `operation` closure receives an
    /// ``Input`` handle and the captured `Env`; any return value is discarded.
    ///
    /// ```swift
    /// return .run(name: "ticker") { input, env in
    ///     do {
    ///         while true {
    ///             try await env.clock.sleep(for: .seconds(1))
    ///             input(.tick)
    ///         }
    ///     } catch {}
    /// }
    /// ```
    public static func run(
        name: String? = nil,
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable @isolated(any) (Input<Event, Output>, Env) async -> Void
    ) -> Self where Env: Sendable {
        .task(name: name, priority: priority) { input, env in
            await operation(input, env)
            return nil
        }
    }

    /// Starts an async task whose result is returned to the caller of ``Input/request(_:)``.
    ///
    /// The `operation` closure performs its work, drives the FSM to a completion event
    /// via `await input.request(...)`, and returns the resulting `Output?` to the
    /// original waiter. Use this when the call site needs to `await` the outcome of an
    /// async operation.
    ///
    /// ```swift
    /// return .request(name: "load") { input, env in
    ///     let user = await env.api.fetchUser()
    ///     return await input.request(.loaded(user))
    /// }
    /// ```
    public static func request(
        name: String? = nil,
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable @isolated(any) (Input<Event, Output>, Env) async -> Output?
    ) -> Self {
        .task(name: name, priority: priority, operation: operation)
    }
}
