# Bridging Event-Driven and Imperative Code

EffectView is event-driven: views fire events, `update` mutates state, effects
run as a consequence. This model is clean, testable, and predictable — but it
has one widely-cited pain point:

> "I tried event-driven, but it doesn't work with `.refreshable`."

This is true for naive event dispatch. It is not true for EffectView.

---

## The problem

SwiftUI's `.refreshable` modifier expects the supplied `async` closure to stay
suspended for as long as the refresh is in progress. The moment the closure
returns, the spinner stops. If you fire an event and return immediately, the
spinner disappears before the data arrives:

```swift
.refreshable {
    send(.refresh)   // returns instantly; spinner stops too early
}
```

The same issue arises for any SwiftUI feature that awaits an async closure:
`task(id:)`, `searchable` with an async suggestions closure, button actions in
`.toolbar`, sheet confirmations, and so on.

---

## The solution: `request(_:)`

`Input.request(_:)` suspends the caller until the entire resulting effect chain
has settled and returns an optional `Output` value:

```swift
.refreshable {
    await input.request(.refresh)
    // resumes only when .refresh has been
    // fully processed and the effect settled
}
```

The spinner stays active for exactly as long as the work takes — no polling,
no extra state flag, no manual `Task` management.

---

## How it works

When `request` is called, a `CheckedContinuation` is created and threaded
through the effect chain alongside the event. The continuation is not resumed
until the chain reaches a terminal point:

```
event → [.action chain] → terminal effect
                          ├─ .task   → Output?
                          ├─ .cancel → nil
                          └─ nil     → nil
```

Critically, the continuation travels *inside* the effect graph. The `.task`
closure does not need to know a caller is waiting — it just returns a value,
and the engine forwards it to the suspended caller automatically.

This is what distinguishes `request` from external state-polling approaches
like XState's `waitFor`: the caller does not observe state changes from
outside; it dispatches an event and awaits the FSM settling as a direct
consequence of that event.

---

## Real-world patterns

### Pull-to-refresh

```swift
.refreshable {
    await input.request(.refresh)
}
```

`update` handles `.refresh` by returning a `.task` that fetches data and
sends `.loaded(data)`. `request` resumes when the task closure returns.

### Navigation confirmation

A sheet's "Save" button can await the result of a save operation before
dismissing:

```swift
Button("Save") {
    Task {
        let saved = await input.request(.save)
        if saved != nil { dismiss() }
    }
}
```

### Async `task(id:)`

When the app regains foreground, re-fetch only if the previous task has
settled:

```swift
.task(id: appPhase) {
    if appPhase == .active {
        await input.request(.resumeIfNeeded)
    }
}
```

### Testing

`request` makes integration tests straightforward — no `XCTestExpectation`
or polling required:

```swift
let result = await input.request(.load)
XCTAssertEqual(state.items.count, 3)
```

---

## Comparison with other approaches

| Approach | Stays suspended? | Returns a value? | Always resumes? |
|---|---|---|---|
| `send(.refresh)` | No | — | — |
| `XCTestExpectation` / `Task.sleep` | Roughly | No | No |
| XState `waitFor(predicate)` | Yes | No | No |
| TCA `store.send(.refresh).finish()` | Yes | No | No |
| ImmutableData `dispatcher.dispatch` | No | — | — |
| Akka `actor ? message` | Yes | Yes (explicit reply) | No |
| `input.request(.refresh)` | Yes | Yes (`Output?`) | Yes |

### TCA: `StoreTask.finish()`

The Composable Architecture has a direct answer: `store.send(_:)` returns a
`StoreTask`, and `await storeTask.finish()` suspends until all effects
launched by that action complete.

```swift
// TCA
.refreshable {
    await store.send(.refresh).finish()
}
```

This works well for `.refreshable` and handles common edge cases correctly.
The differences from `request` are design choices, not deficiencies:

- **No return value.** Data flows back through state observation, not as a
  typed return. The caller cannot write `let result = await ...`.
- **Cancellation propagates.** If the outer `Task` is cancelled, TCA cancels
  the effect task. In practice SwiftUI holds the `.refreshable` task alive
  for the full gesture, so this behaves correctly in normal use. The
  propagation is intentional — it makes TCA effects participants in
  structured concurrency rather than escaping it.
- **Waits for all effects.** `finish()` waits until every effect spawned by
  the action exits. `request` waits only until the specific continuation is
  resolved. Both are correct; they reflect different granularity.

The two approaches are complementary. `StoreTask.finish()` fits TCA's
long-lived store model where effects participate in structured cancellation.
`request` fits EffectView's view-scoped FSM model where the `@MainActor`
lifetime is the safety net and a typed return value is useful.

### ImmutableData

ImmutableData has no equivalent mechanism. `dispatcher.dispatch(action:)` is
synchronous and `throws` but not `async`. Effects are not first-class values
returned from the reducer — side effects are expected to be managed outside
the store, typically via `@Observable` objects or Combine publishers that
react to state changes.

As a result, bridging to `.refreshable` requires a workaround: a state flag
(`isRefreshing: Bool`) that the view observes, combined with a polling or
`AsyncStream` approach to detect when the flag clears.

```swift
// ImmutableData — workaround required
.refreshable {
    dispatcher.dispatch(action: .refresh)
    // must poll or observe isRefreshing to know
    // when to let the closure return
}
```

This is the class of problem that prompted the "event-driven doesn't work
with `.refreshable`" complaint. ImmutableData does not address it.

### Akka `ask` pattern

Akka's `actor ? message` (the "ask" pattern) is the closest prior art:
request-response over a message-passing system. The difference is that Akka
requires the actor to explicitly send a reply message. Here, the reply is the
return value of the `.task` closure — the continuation threading is
transparent to the task author.

---

## Design rationale

The goal was to make event-driven code a first-class citizen in SwiftUI
without requiring callers to adopt a different programming model for
asynchronous flows. SwiftUI's async integration points (`refreshable`,
`task(id:)`, etc.) are built around `async`/`await`. `request` meets them
where they are.

The continuation-threading mechanism means there is no semantic difference
between "I fired this event and don't care about the result" (`send` /
`enqueue`) and "I fired this event and need to know when it's done"
(`request`). The FSM is identical in both cases; only the call site differs.
