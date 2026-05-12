# Architectural Comparison

EffectView is not a new idea. It translates a family of well-established patterns — Elm, Redux, Elixir/GenServer — into idiomatic SwiftUI, using Swift's own concurrency model rather than fighting it.

This document maps EffectView against the patterns iOS developers are most likely to know, across five dimensions that matter in practice:

1. **State model** — what kinds of state exist, who owns each kind, and who can mutate it
2. **Effect/side-effect model** — how async work is described and executed
3. **Task lifecycle** — who creates tasks, who cancels them, and what scopes their lifetime
4. **Dispatch semantics** — what it means to "send" an event or action
5. **Testability** — what you need to construct to exercise the logic

---

## The patterns

### MVVM with `@Observable`

The default iOS pattern today. State lives in an `@Observable` class (the ViewModel). Methods on the ViewModel mutate state directly and launch async work via unstructured `Task { }` calls.

MVVM is a pattern, not a framework — it has no canonical implementation and no enforced conventions. Teams establish their own rules about what goes in the ViewModel, how state is exposed, and how async work is managed. Those rules exist only in documentation and code review; the compiler enforces nothing.

**State model:** All state — ephemeral view state, references to shared stores, and cached results from persistence — collapses into the ViewModel class. There is no structural distinction between them.

In the most common implementation, `@Observable` properties are fully public and read-write. Any code that holds a reference to the ViewModel can read *and* write any property at any time. This is widely recognised as an anti-pattern: a view that writes `viewModel.isLoading = false` directly bypasses whatever invariants the ViewModel was trying to maintain. The conventional remedy is to mark properties `private(set)` and expose mutation only through methods — but this is unenforced convention, and it still doesn't prevent two methods (or two tasks running the same method) from racing against each other.

**Effect model:** Async work is launched imperatively. A method calls `Task { ... }` and the task is anonymous. If the same method is called twice, two tasks run concurrently against the same state, potentially interleaving writes in any order.

**Task lifecycle:** Unmanaged. The developer manually holds `Task` handles and calls `.cancel()`. Easy to forget. Tasks outlive the view if the ViewModel is retained elsewhere.

**Dispatch:** Direct method calls. `viewModel.loadMovies()` is synchronous: it starts a task and returns immediately. There is no way to await the *completion* of the state change the task will eventually cause — not without adding a separate async method or a continuation.

**Testability:** Requires constructing the whole ViewModel. Async side effects run in unstructured tasks that the test cannot directly observe. Testing requires `@MainActor` isolation, `XCTestExpectation`, or polling.

---

### Redux

A global store holds the entire application state. A single pure *reducer* function handles all state mutations: `(State, Action) -> State`. Side effects are expressed as values (thunks, sagas, or middleware intercepts) that the framework executes outside the reducer.

**State model:** One global tree. All state — ephemeral UI, shared domain state, persistent cache — lives in the same structure. Slices are selected via key paths or selectors. Any component can subscribe to any slice.

**Effect model:** Effects are values returned from (or intercepted by) middleware. The reducer itself is pure. The middleware layer executes async work and dispatches further actions when done.

**Task lifecycle:** Middleware-managed. Cancellation requires dispatching a cancel action that middleware intercepts. The discipline is enforced by convention, not by the type system.

**Dispatch:** Fire-and-forget. `store.dispatch(.loadMovies)` enqueues an action and returns immediately. There is no standard mechanism to await the completion of the effect chain that action triggers.

**Testability:** The reducer is trivially testable — pure function, no async. Testing effects requires a test middleware or mock store. Testing the interaction between state changes and effects requires more setup.

---

### The Composable Architecture (TCA)

The most direct comparison to EffectView. TCA targets SwiftUI with a Redux-shaped architecture: a `@Reducer` macro generates a store, actions map to state mutations and `Effect<Action>` return values.

**State model:** Composable tree of child stores. Parent features compose child features using `Scope` and `IfLetStore`. Shared state is managed via `@Shared` property wrappers with explicit persistence strategies.

**Effect model:** `Effect<Action>` wraps async sequences or `Effect.run { send in ... }` closures. Effects dispatch further actions by calling `send(.someAction)` inside the closure. The reducer remains synchronous.

**Task lifecycle:** Effects are identified by a `CancelID`. Cancellation requires dispatching a separate action that the reducer handles by returning `.cancel(id:)`. The framework manages the actual task. This works well but the cancellation logic is split from the creation logic.

**Dispatch:** Fire-and-forget from outside the store. `store.send(.loadMovies)` enqueues the action. There is no API to await the completion of the effect chain. Inside `Effect.run`, `send` is async — it awaits the action being processed — but only for one level; there is no recursive settle.

**Testability:** `TestStore` provides a structured assertion API: `await store.send(.event)` followed by `await store.receive(.resultEvent)`. Well-designed and expressive, but requires the TCA-specific test harness.

---

### Elm Architecture

The direct ancestor of all patterns in this family. An Elm application is defined by three things: `Model` (state), `Msg` (events), and `update : Msg -> Model -> (Model, Cmd Msg)` (transition function). The runtime handles rendering and command execution.

**State model:** A single immutable value, replaced on every update. No shared mutable state exists — inter-component communication is message-passing only. Ephemeral UI state and domain state are co-located in `Model` but structurally distinguished by the developer.

**Effect model:** `Cmd Msg` is a description of work to perform. The Elm runtime executes it and delivers the result as a new `Msg`. The update function never performs async work directly — it only describes it.

**Task lifecycle:** The runtime owns all tasks. Subscriptions (`Sub Msg`) are a separate concept: the runtime diffs the current subscription set against the previous one on each render cycle and starts or stops accordingly. There is no imperative cancel.

**Dispatch:** All messages are fire-and-forget. The runtime processes them one at a time, but there is no mechanism for a command to await the completion of the message it eventually triggers. Sequencing requires modelling intermediate states explicitly in `Model`.

**Testability:** The update function is a pure function. No framework, no async, no mocking. Test by calling `update msg model` and asserting on the returned `(model, cmd)`.

---

### Elixir / Phoenix LiveView / GenServer

The most conceptually illuminating comparison. A `GenServer` is an actor with a single `handle_call` / `handle_cast` callback — the structural equivalent of `update`. State is private to the process; all mutations go through the callback; side effects are either synchronous return values or out-of-band messages sent to other processes.

Phoenix LiveView's `handle_event` maps almost directly to EffectView's `update`: it receives the current socket (state), an event name, and parameters, mutates the socket, and optionally pushes async work via `Task.async` or `send_update`.

**State model:** Process-local. Each LiveView socket / GenServer process owns its own state exclusively. Shared state between processes requires explicit message passing or a shared ETS table — it is never implicit.

**Effect model:** Side effects are first-class values in the return tuple: `{:noreply, socket, {:continue, :load_data}}`. Async work spawns a child process that sends a message back when done.

**Task lifecycle:** OTP supervision trees manage process lifecycles. A process that crashes is restarted by its supervisor. When a LiveView socket disconnects, its process terminates and all associated state is cleaned up automatically.

**Dispatch:** `GenServer.call` is synchronous — the caller blocks until the server processes the message and replies. `GenServer.cast` is fire-and-forget. LiveView's `handle_event` is cast-style. There is no direct equivalent of `perform` — sequencing requires chaining `handle_info` messages via `{:continue, ...}`.

**Testability:** GenServer logic is testable by sending messages to a test process and asserting on state or replies. LiveView provides `Phoenix.LiveViewTest` for end-to-end socket testing.

---

## EffectView

EffectView translates the Elm/GenServer model into idiomatic SwiftUI — using `@State`, structured concurrency, and `@MainActor` as the runtime rather than a custom one.

**State model:** Three kinds of state are structurally distinct:

- **Ephemeral state** (`ViewState`) — a plain value type owned by `@State`. Lives and dies with the view's identity. Nothing outside the view can read or write it.
- **Shared state** — an `@Observable` object passed via `Env` or the SwiftUI environment. A view *observes a named slice* of shared state via `.observe(\.store, keyPath: \.count)` and receives changes as events into its own `update` loop. The view never writes shared state directly — it sends events to the store's own mutation API.
- **Persistent state** — always external. Effects read from or write to persistence, then translate results back into events. `update` never sees storage directly.

The read/write relationship with shared state is asymmetric by construction:

```
Store ──(observed slice)──▶ events ──▶ update ──▶ ViewState    (read)
ViewState ──(user action)──▶ update ──▶ effect ──▶ store.send  (write)
```

**Effect model:** `update` returns an `Effect` value — a description, never an execution. The library executes it. `update` is synchronous, has no `async` annotation, and cannot perform work directly. The same event on the same state always produces the same `Effect` description.

**Task lifecycle:** Tasks are created by returning `.task(name:)` from `update`. They are cancelled by returning `.cancel(name)` from `update`, or automatically when the view's identity is torn down via `.id(...)`. Both creation and cancellation are outputs of the transition function — they live alongside state mutations in the same `switch`, subject to the same compiler exhaustiveness checks.

A named task is automatically cancelled and replaced if `update` returns a new `.task` with the same name before the previous one finishes. This makes cancel-and-restart a one-liner with no explicit handle management:

```swift
// update:
case .queryChanged(let q):
    state.query = q
    return .task(name: "search") { input, env in   // cancels any prior "search" task
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let results = await env.search(q)
        await input.perform(.resultsLoaded(results))
    }
```

**Dispatch semantics:** `Input` exposes three levels, chosen at the call site:

| Method | Semantics | Use when |
|---|---|---|
| `input(.event)` | Fire-and-forget. Enqueues on `@MainActor`, returns immediately. | Button handlers, `onChange`, observation fire-and-forget |
| `await input.send(.event)` | Waits until `update` has processed the event. State is settled; effects are only *started*. | Caller needs to read resulting state, doesn't care about downstream work |
| `await input.perform(.event)` | Suspends until the full effect chain — `update`, the returned effect, and any effects it triggers recursively — has settled. | Pull-to-refresh spinners, sequential task steps, observation loop backpressure |

`perform` is the mechanism that makes SwiftUI's `.refreshable` work naturally:

```swift
.refreshable {
    await input.perform(.refresh)   // spinner shown until the full load cycle completes
}
```

And it provides natural backpressure in observation loops — the loop does not advance to wait for the next store change until the view has fully processed the current one:

```swift
await input.perform(.storeChanged(newCount: count))  // next observation cycle waits here
```

No rate-limiting code, no semaphores. The dispatch semantic *is* the backpressure mechanism.

**Testability:** `update` is a static function — `(inout ViewState, Event) -> Effect<Event, Env>?`. No framework, no `@MainActor`, no mocking. The full transition logic is exercisable from a plain `XCTest`:

```swift
var state = MyView.ViewState()
let effect = MyView.update(&state, event: .loadMovies)
XCTAssertEqual(state.isLoading, true)
// inspect the returned Effect description if needed
```

---

## Summary

| | MVVM | Redux | TCA | Elm | Elixir/GenServer | EffectView |
|---|---|---|---|---|---|---|
| **Ephemeral state owner** | ViewModel class | Global store | Feature store | Model value | Process-local | `ViewState` value |
| **Shared state access** | Direct reference | Global selector | `@Shared` wrapper | Message-passing only | Explicit IPC | Read-only slice via `.observe` |
| **Mutation authority** | Anyone with a reference | Reducer only | Reducer only | `update` only | `handle_*` only | `update` only |
| **Effect description** | Imperative `Task { }` | Middleware value | `Effect<Action>` | `Cmd Msg` | Return tuple | `Effect<Event, Env>` |
| **Task creation** | Anywhere | Middleware | `Effect.run` | Runtime | Spawn | `update` return value |
| **Task cancellation** | Manual handle | Dispatch cancel action | `CancelID` action | Runtime subscription diff | Process termination | `update` return value |
| **Task scope** | ViewModel lifetime | App lifetime | Store lifetime | Runtime | Process tree | View identity |
| **Dispatch levels** | Synchronous call | Fire-and-forget | Fire-and-forget (+ async `send` inside effects) | Fire-and-forget | `call` (sync) / `cast` (async) | `enqueue` / `send` / `perform` |
| **Test surface** | Full class construction | Reducer pure function | `TestStore` harness | Pure `update` function | Process message passing | Static pure function |

The common thread in the well-designed patterns (Elm, GenServer, TCA, EffectView) is the same: a single authoritative transition function that owns all state mutations and returns effect descriptions. The differences are in scope (global vs. local), dispatch semantics, task lifecycle management, and how much framework ceremony is required to express the pattern.

EffectView's position is that the SwiftUI runtime already provides the scope, lifecycle, and concurrency model — the only missing piece is a structured way to describe and manage effects. The library adds that piece and nothing else.
