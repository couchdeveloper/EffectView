# Correct by Construction: State Machines and MVI with EffectView

The [previous article](TamingAsyncTasksInSwiftUIViews.md) solved a mechanical problem: `.task` doesn't give you the tools to manage task lifetimes properly. This article addresses a deeper one.

**Async logic is hard to reason about — even when the machinery works.**

When behaviour lives inside closures, async functions, and stored properties scattered across a view, it's difficult to answer basic questions:

- What are all the states this view can be in?
- Which events are valid in each state?
- Can two pieces of state ever be in contradiction with each other?
- What happens if the user taps a button while something is already loading?

EffectView addresses this by pulling all logic into a single, pure function.

---

## The update function

The heart of EffectView is the update function:

```swift
(inout State, Event) -> Effect<Event, Env>?
```

Given the current state and an event, it:

1. Mutates state synchronously.
2. Optionally returns an `Effect` — a *description* of work to do next, not the work itself.

That's all it does. It never touches the network, never reads a database, never calls `await`. It is a pure state transition function.

This has a name: it's a **finite state machine**.

---

## What is a finite state machine?

A finite state machine (FSM) is a model where:

- The system is always in exactly one **state**.
- **Events** cause transitions to a new state, optionally triggering side effects.
- The full set of states and transitions is *finite* and *explicit*.

FSMs are everywhere in UI logic, even when we don't acknowledge them. A loading screen is either waiting, loading, showing results, or showing an error. Pretending otherwise — using three boolean flags — is where bugs are born.

---

## Modelling state as an enum

Without an FSM, a search screen typically accumulates state like this:

```swift
@State private var isLoading = false
@State private var results: [Movie] = []
@State private var errorMessage: String? = nil
@State private var currentQuery = ""
```

There are immediately several illegal combinations: `isLoading == true && errorMessage != nil`. `results.isEmpty && !isLoading && errorMessage == nil` — is that idle, or empty results? Tests have to enumerate these combinations and hope they've covered the right ones.

With EffectView you model state as a Swift enum instead:

```swift
enum SearchState {
    case idle
    case loading(query: String)
    case loaded(query: String, results: [Movie])
    case failed(query: String, message: String)
}
```

Illegal combinations don't exist. The compiler enforces it.

---

## Events and transitions

```swift
enum SearchEvent {
    case searchTapped(query: String)
    case resultsReceived([Movie])
    case requestFailed(String)
    case cancelTapped
}
```

The update function is a `switch` over state and event:

```swift
func update(state: inout SearchState, event: SearchEvent) -> Effect<SearchEvent, SearchEnv>? {
    switch (state, event) {

    case (_, .searchTapped(let query)):
        state = .loading(query: query)
        return .sequence([
            .cancel("search"),
            .task(name: "search") { input, env in
                do {
                    let movies = try await env.search(query: query)
                    input.enqueue(.resultsReceived(movies))
                } catch {
                    input.enqueue(.requestFailed(error.localizedDescription))
                }
            }
        ])

    case (.loading(let query), .resultsReceived(let movies)):
        state = .loaded(query: query, results: movies)
        return nil

    case (.loading(let query), .requestFailed(let message)):
        state = .failed(query: query, message: message)
        return nil

    case (.loading, .cancelTapped):
        state = .idle
        return .cancel("search")

    default:
        return nil  // event not valid in current state — ignore it
    }
}
```

Every reachable behaviour is visible in one place. There is no flag to check somewhere else, no hidden early-return in an async closure, no `guard self != nil` buried in a completion handler.

---

## From Gherkin to Swift

Requirements written in Gherkin map almost directly to cases in the update function.

**Requirement:**

```gherkin
Feature: Movie search

  Scenario: User starts a search
    Given the screen is idle
    When the user submits query "inception"
    Then the screen is loading
    And a search task is started

  Scenario: Search returns results
    Given the screen is loading with query "inception"
    When the server returns 3 movies
    Then the screen shows 3 results for "inception"

  Scenario: User cancels while loading
    Given the screen is loading with query "inception"
    When the user taps Cancel
    Then the screen is idle
    And the search task is cancelled
```

**Implementation:**

```swift
// Scenario: User starts a search
case (_, .searchTapped(let query)):
    state = .loading(query: query)
    return .task(name: "search") { ... }

// Scenario: Search returns results
case (.loading(let query), .resultsReceived(let movies)):
    state = .loaded(query: query, results: movies)
    return nil

// Scenario: User cancels while loading
case (.loading, .cancelTapped):
    state = .idle
    return .cancel("search")
```

The scenarios *are* the implementation. The mapping is near 1:1.

This also works in reverse: given an update function, you can read off the Gherkin scenarios directly. The function is the specification.

---

## Testing: zero mocking, zero async

Because the update function is pure and synchronous, testing requires no mocking, no `XCTestExpectation`, no `async`/`await`, and no UI infrastructure. You call it like any other function and assert on the output.

```swift
@Suite("SearchState transitions")
struct SearchStateTests {

    @Test func searchTappedTransitionsToLoading() {
        var state = SearchState.idle
        let effect = update(state: &state, event: .searchTapped(query: "inception"))

        #expect(state == .loading(query: "inception"))
        #expect(effect != nil)
    }

    @Test func resultsArrivedTransitionsToLoaded() {
        var state = SearchState.loading(query: "inception")
        let effect = update(state: &state, event: .resultsReceived([.init(title: "Inception")]))

        #expect(state == .loaded(query: "inception", results: [.init(title: "Inception")]))
        #expect(effect == nil)
    }

    @Test func cancelWhileLoadingGoesIdle() {
        var state = SearchState.loading(query: "inception")
        let effect = update(state: &state, event: .cancelTapped)

        #expect(state == .idle)
        // effect is .cancel("search")
    }

    @Test func cancelInIdleStateIsIgnored() {
        var state = SearchState.idle
        _ = update(state: &state, event: .cancelTapped)

        #expect(state == .idle)
    }
}
```

You can exhaustively test every row in your transition table. The tests run in milliseconds and never flake, because there is no async work, no main-actor scheduling, and no shared mutable state to race against.

You can also derive a transition table from the test suite and verify it matches the Gherkin document directly — the connection is direct enough to automate.

---

## No edge cases

"Edge cases" in async UI code are usually one of two things:

1. **Impossible-state bugs** — two pieces of state that shouldn't both be true at once.
2. **Race conditions** — two events that arrive in an order the developer didn't anticipate.

The enum state model eliminates category 1 entirely: the Swift type system won't let you represent `isLoading == true && errorMessage != nil` if your states are an enum.

Category 2 is handled by the update function being processed serially on `@MainActor`. Two events never execute concurrently. State is never observed mid-mutation. The "what if the user taps twice?" scenario is just two calls to `update` in sequence: the second `searchTapped` hits the `.sequence([.cancel("search"), .task(name: "search") { ... }])` branch and replaces the in-flight task cleanly.

Concurrency exists — tasks genuinely run in the background — but concurrency never *touches* state directly. It only delivers events. The update function remains a simple, synchronous function.

---

## MVI in practice

EffectView implements the **Model–View–Intent** (MVI) pattern:

| MVI concept | EffectView equivalent |
|---|---|
| **Model** | `State` — the single source of truth |
| **Intent** | `Event` — user actions and system callbacks |
| **View** | SwiftUI `Content` closure — reads state, fires events |
| **Reducer** | `update` function — the only place state changes |
| **Side effects** | `Effect` — declarative descriptions returned from `update` |

The key MVI property is **unidirectional data flow**: state flows down into the view, events flow up into `update`, and `update` produces the next state. There is no path for the view to mutate state directly, no path for an async task to mutate state directly, and no path for two parts of the view to disagree about the current state.

---

## Summary

| Concern | Where it lives | Characteristic |
|---|---|---|
| State | Swift enum | Impossible states unrepresentable |
| Transitions | `update` function | Pure, synchronous, compiler-verified |
| Side effects | `Effect` return values | Declarative descriptions, not execution |
| Async work | Task closures in `Effect` | Isolated, named, cancellable |
| Rendering | SwiftUI `Content` closure | Reads state only, fires events only |

The update function does one thing: given a state and an event, decide what the next state is and what work to trigger. Because it is pure and synchronous, it is trivially testable, straightforwardly readable, and directly traceable to requirements. Concurrency is real, but it is confined to the edges — it delivers events, it doesn't own state.

*Next: [Using Env for dependency injection](UsingEnvForDependencyInjection.md)*
