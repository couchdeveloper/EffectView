# EffectView

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fcouchdeveloper%2FEffectView%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/couchdeveloper/EffectView)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fcouchdeveloper%2FEffectView%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/couchdeveloper/EffectView)

A small SwiftUI helper for Elm-style event handling with explicit side effects.

- Single mutation point via `update`.
- Explicit effects (`task`, `action`, `cancel`).
- Optional dependency environment captured for the view lifetime.

## Core principles and benefits

- Clear separation between pure state updates and side effects.
- Effects are explicit, managed, and cancellable.
- Deterministic update loop with a single mutation point.
- Great testability: update logic can be exercised in isolation.


## Installation

Add the package to your Swift Package Manager dependencies:

```swift
// Package.swift
.package(url: "https://github.com/couchdeveloper/EffectView.git", from: "0.1.0")
```

Then add `EffectView` to your target dependencies.

## Usage

1. **Define `State` and `Event`.** `State` is a plain value type holding everything the view needs to render. `Event` is an enum of all user actions and system notifications that can change state.

2. **Define a pure `update` function.** A `static` function that takes the current state and an event, mutates state in place, and optionally returns an `Effect` to run or cancel. No async, no throwing — just a switch.

3. **Render and send.** The `EffectView` content closure receives the current state and a `send` function. Render state, and call `send` for user actions.

4. **Design service functions.** Long-running or async work lives in `.task` effects. These receive an `input` parameter which can be used to dispatch events back to the update loop as work progresses or completes. The example below where a `tick` event is sent back via input: `input(.tick)`:

```swift
struct CounterView: View {
    struct ViewState { var counter = 0 }
    enum Event { case start, tick, stop }

    @State private var state = ViewState()

    private static func update(
        state: inout ViewState,
        event: Event
    ) -> Effect<Event, Void>? {
        switch event {
        case .start:
            state.counter = 0
            return .task(name: "Counter") { input, env in
                while true {
                    do {
                        try await Task.sleep(for: .seconds(1))
                        input(.tick)
                    } catch {
                        // ignore cancellation
                    }
                }
            }
        case .tick:
            state.counter += 1
            return nil
        case .stop:
            return .cancel("Counter")
        }
    }

    var body: some View {
        EffectView(state: $state, update: Self.update) { state, send in
            VStack {
                Text("\(state.counter)")
                Button("Start") { send(.start) }
                Button("Stop")  { send(.stop)  }
            }
        }
    }
}
```

## Behavior notes

- `update` is captured once when the view appears.
- The lifetime of any running task is controlled by the `EffectView`. All tasks are automatically cancelled when the view's identity ceases to exist. A task can also be cancelled earlier by returning `.cancel(name)` from `update`.

## Effect

The return type of `update`. Controls what happens after a state mutation.

| Case | Purpose |
|---|---|
| `.task(name:priority:operation:)` | Starts an async operation. Named tasks are automatically cancelled and replaced if re-issued. |
| `.action(action:)` | Synchronous step; the returned `Event?` is processed immediately in the same run loop. |
| `.cancel(name)` | Cancels a running named task. |

Returning `nil` means no effect — state was mutated but no async work is needed.

### Custom effects

For readability, effects can be declared as static factory methods on `Effect` constrained to the view's `Event` and `Env` types. This keeps `update` free of construction details and makes effects reusable across multiple cases.

```swift
extension Effect where Event == MyView.Event, Env == MyView.Env {
    static func loadItems() -> Self {
        .task(name: "load") { input, env in
            do {
                let items = try await env.fetch()
                input(.loaded(items))
            } catch {
                input(.loadFailed(error))
            }
        }
    }
}
```

`update` can then return `.loadItems()` instead of spelling out the full task inline.


## Env and View identity

If you pass `initialEnv`, it is captured once when the view appears. This is intentional — swapping dependencies mid-flight can cause subtle bugs where a running task started with one implementation finishes against another. 

The environment value is passed as an argument to the effect's operation and action closure and can carry dependencies or configuration values, see custom effect example above.

To apply new dependencies, recreate the view identity with `.id(...)`.

## Dependency injection

Declare dependencies as a struct in the view layer. This keeps the interface close to the consumer and makes swapping implementations (e.g. live vs. mock) straightforward.

```swift
struct CounterView: View {
    struct Env: Identifiable {
        let id: UUID
        // Declare the API the view layer needs.
        var fetchInitialCount: () async -> Int
        
        static let live = Env(id: UUID(), fetchInitialCount: { await CounterService.shared.count() })
        static let mock = Env(id: UUID(), fetchInitialCount: { 42 })
    }

    enum Event { case appeared, loaded(Int) }
    struct ViewState { var count: Int? }

    @State private var state = ViewState()
    let env: Env

    private static func update(state: inout ViewState, event: Event) -> Effect<Event, Env>? {
        switch event {
        case .appeared:
            return .task { send, env in
                let count = await env.fetchInitialCount()
                send(.loaded(count))
            }
        case .loaded(let count):
            state.count = count
            return nil
        }
    }

    var body: some View {
        EffectView(state: $state, initialEnv: env, update: Self.update) { state, send in
            Text(state.count.map { "\($0)" } ?? "Loading…")
                .task { send(.appeared) }
        }
        .id(env.id)
    }
}
```

At the call site, pass the environment that fits the context — no changes to the view or update logic required:

```swift
CounterView(env: .live)   // production
CounterView(env: .mock)   // previews, tests
```

## Dependency injection via SwiftUI Environment

For dependencies that need to be available deep in the view hierarchy, you can deliver them through the SwiftUI environment using `EnvReader`. Wrap each injectable operation in a lightweight `Action` struct so the environment key stays typed and the default implementation is co-located with the declaration.

```swift
// 1. Declare the action
struct CounterAction: Sendable {
    var fetchCount: @Sendable () async -> Int = { await CounterService.shared.count() }
}

extension EnvironmentValues {
    @Entry var counterAction = CounterAction()
}

// 2. Compose the view's Env from the environment at the call site
struct CounterContainerView: View {
    var body: some View {
        EnvReader(\.counterAction) { action in
            CounterView(
                env: .init(id: UUID(), 
                fetchInitialCount: action.fetchCount)
            )
        }
    }
}
```

In tests or previews, override just the actions you need:

```swift
CounterContainerView()
    .environment(\.counterAction, CounterAction(fetchCount: { 42 }))
```

This keeps each injectable operation minimal and composable. The view layer owns the interface; the environment owns the wiring.

## Recipes

Short, focused snippets for common patterns. Each one highlights a specific feature in isolation.

---

### Pull-to-refresh

`perform(_:)` suspends until the full effect chain completes, which makes it a natural fit for SwiftUI's `refreshable` modifier.

```swift
List(state.movies, rowContent: MovieRow.init)
    .refreshable {
        await input.perform(.refresh)   // spinner shown until .refresh effect completes
    }
```

`.refresh` is just a regular event. The actual async work is a custom effect returned from `update`:

```swift
extension Effect where Event == MyView.Event, Env == MyView.Env {
    static func refreshMovies() -> Self {
        .task(name: "refresh") { input, env in
            do {
                let movies = try await env.movieFetch()
                input(.loaded(movies))
            } catch {
                input(.loadFailed(error))
            }
        }
    }
}
```

---

### Cancel-and-restart (debounce / live search)

Name the task. A new event with the same task name cancels the previous run automatically before starting a fresh one.

```swift
// update:
case .queryChanged(let q):
    state.query = q
    return .task(name: "search") { input, env in
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let results = await env.search(q)
        input(.resultsLoaded(results))
    }
```

---

### Synchronous action chain (setup sequence)

`.action` returns the next event to process immediately in the same run loop. Use this to break multi-step setup into deterministic, individually-testable events.

```swift
// update:
case .appeared:
    return .action { _ in .loadConfig }   // processed synchronously before any external event
case .loadConfig:
    state.config = Config.default
    return .task { input, env in … }
```

---

### Fire-and-forget (button / gesture)

`input` is callable directly. Use it anywhere a `() -> Void` closure is expected.

```swift
Button("Retry", action: input(.retry))       // callAsFunction — enqueues on MainActor
Toggle("Sync", isOn: $state.syncEnabled)
    .onChange(of: state.syncEnabled) { input(.syncToggled($0)) }
```

---

### Cancel before starting

`.sequence` runs effects left-to-right. Useful when you need to cancel a stale task before issuing a new one in the same update step.

```swift
// update:
case .refresh:
    return .sequence([.cancel("load"), .task(name: "load") { … }])
```

---

### Await a sub-operation from another task

From inside a `.task`, use `perform(_:)` to drive the FSM and wait for the state change to settle before continuing.

```swift
return .task { input, env in
    await input.perform(.prepareUpload)   // waits for prepareUpload's full effect chain
    let result = await env.upload(…)
    input(.uploadFinished(result))
}
```

---

## License

Apache License, Version 2.0
