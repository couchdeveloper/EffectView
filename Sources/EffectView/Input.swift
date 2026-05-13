
/// A `Sendable` handle for dispatching events into the effect engine.
///
/// `Input` provides three dispatch strategies with different semantics:
/// - ``send(_:)`` — synchronous; must be called from the `@MainActor`.
/// - ``enqueue(_:)`` — fire-and-forget; safe from any isolation.
/// - ``request(_:)`` — suspends the caller, returning `Output?`.
///
/// ### Isolation and lifetime safety
///
/// All state mutations run on the `@MainActor`, a global, app-lifetime
/// executor. Because the `@MainActor` is never destroyed, ``request(_:)``
/// is guaranteed to resume its continuation on every code path — no
/// `withTaskCancellationHandler` bookkeeping is required.
///
/// If the calling `Task` is cancelled while awaiting ``request(_:)``,
/// the suspension continues until the event is processed. Swift does not
/// automatically resume continuations on cancellation; this is safe
/// because the `@MainActor` always completes its work.
///
/// ### Generic parameters
///
/// - `Event`: The event type dispatched into the state machine.
/// - `Output`: The value returned by ``request(_:)``.
///   Use `Void` when no return value is needed.
public struct Input<Event, Output>: Sendable {

    init(send: @escaping @MainActor @Sendable (Event, Input<Event, Output>, CheckedContinuation<Output?, Never>?) -> Void) {
        self._send = send
    }
        
    private var _send: @Sendable @MainActor (Event, Input<Event, Output>, CheckedContinuation<Output?, Never>?) -> Void

    /// Dispatches `event` synchronously on the `@MainActor`.
    ///
    /// Use `send` when you are already running on the `@MainActor` and want the event to be
    /// processed immediately, in the same synchronous turn. A typical example is a SwiftUI
    /// button action:
    ///
    /// ```swift
    /// Button("Increment") {
    ///     // Processed before the next await point:
    ///     input.send(.increment)
    /// }
    /// ```
    ///
    /// "Synchronous" here means that `update` is called inline, any `.action` chain is
    /// unwound, and the resulting state change is applied — all before `send` returns.
    /// If `update` returns a `.task`, that task is *launched* synchronously but runs
    /// concurrently; `send` does not wait for it to finish. Use ``request(_:)`` if you
    /// need to await the task's completion.
    ///
    /// If you want to fire-and-forget the event — scheduling it without waiting for even
    /// the synchronous `update` pass to complete — use ``enqueue(_:)`` instead.
    ///
    /// - Warning: Because `send` unwinds `.action` chains synchronously on the `@MainActor`,
    ///   a cycle in your `update` function — e.g. `.ping` → `.action { .pong }` → `.action { .ping }` →  … —
    ///   will loop forever and hang the main thread. ``enqueue(_:)`` and ``request(_:)`` are
    ///   immune because each re-entry is scheduled as a new task, yielding control between iterations.
    @MainActor
    public func send(_ event: Event) {
        _send(event, self, nil)
    }
    
    /// Schedules `event` on the `@MainActor` without awaiting it.
    ///
    /// Safe to call from any actor isolation or non-isolated context.
    /// Use this to fire-and-forget an event from a background task or a
    /// non-isolated callback without waiting for `update` to run.
    @inline(__always)
    public func enqueue(_ event: sending Event) {
        Task { @MainActor in
            send(event)
        }
    }

    /// Sends `event` and suspends until the entire resulting effect chain has completed,
    /// returning the `Output?` value produced by the terminal `.task` closure.
    ///
    /// A single event can trigger a cascade: an `.action` may return the next event to
    /// process immediately, which in turn may return another, and so on. The continuation
    /// is threaded through the whole chain and only resumed when the chain reaches a
    /// terminal effect — typically a `.task`, whose async operation runs to completion
    /// before `request` returns.
    ///
    /// ```
    /// event → [.action chain] → terminal effect
    ///                           ├─ .task   → Output?
    ///                           ├─ .cancel → nil
    ///                           └─ nil     → nil
    /// ```
    ///
    /// The caller hops to the `@MainActor` for the duration of the call. Because the
    /// `@MainActor` is a global, app-lifetime executor, the continuation is always
    /// resumed — no cancellation handler is needed.
    ///
    /// - Note: If the calling `Task` is cancelled while suspended,
    ///   `request` continues to wait until the effect chain settles.
    ///
    /// For usage patterns including `.refreshable`, `task(id:)`, and testing,
    /// see <doc:BridgingEventDrivenAndImperative>.
    @discardableResult
    @MainActor
    public func request(_ event: sending Event) async -> Output? {
        await withCheckedContinuation { continuation in
            self._send(event, self, continuation)
        }
    }

    /// Sends `event` and suspends until the entire resulting effect chain has completed.
    ///
    /// - Note: Renamed to ``request(_:)``. Use `request` for new code.
    @available(*, deprecated, renamed: "request(_:)")
    @MainActor
    public func perform(_ event: sending Event) async -> Void {
        await request(event)
    }

    /// Convenience call-as-function syntax for ``enqueue(_:)``.
    @inline(__always)
    public func callAsFunction(_ event: sending Event) {
        enqueue(event)
    }
}
