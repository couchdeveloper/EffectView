# Using Env for Dependency Injection

The [previous article](CorrectByConstruction.md) showed how to model state and logic as a pure, testable function. This article shows how to connect that function to real services — a network client, an analytics tracker, a local cache — while keeping the logic layer free of concrete dependencies and preserving easy testability.

---

## The problem

Tasks in the update function need to call services. The obvious approaches all have friction:

- **Capture from the outer scope** — works for simple cases, but the captured value is fixed at view creation; and `EffectView` explicitly ignores `Env` changes after the first appearance to avoid mid-flight races. You need a principled way to inject dependencies, not accidental captures.
- **Protocol-based injection** — requires existentials or generics that propagate upward through every layer, making the call site and the `EffectView` signature more complex than necessary.
- **Singleton / static access** — untestable; you can't swap a live service for a test double without global mutable state.

EffectView's `Env` type parameter solves this cleanly: the value is captured once at view creation, forwarded to every effect, and can be swapped wholesale for testing.

---

## Step 1: Declare the service API in the View layer

The service API lives with the feature, not with the infrastructure. You declare it as a struct of closures — no protocol, no generic parameter.

```swift
// MovieSearch/MovieSearchActions.swift  (View layer)

import Foundation

struct MovieSearchActions: Sendable {
    var search: @Sendable (String) async throws -> [Movie]
    var cancelSearch: @Sendable () -> Void
    var trackQuery: @Sendable (String) -> Void
}
```

Using a struct of closures instead of a protocol has several advantages:

- **No generics required.** The feature module doesn't need a type parameter for its service.
- **Composition is trivial.** You can build a combined `Env` from several action structs.
- **Test doubles are a literal.** Replacing a closure value requires a single-line assignment; no mock class needed.
- **The caller decides the contract.** The feature defines precisely what it needs — not what the service is capable of.

---

## Step 2: Build the Env struct

`Env` is the container EffectView captures and forwards to every task and action:

```swift
// MovieSearch/MovieSearchEnv.swift  (View layer)

struct MovieSearchEnv: Sendable {
    var actions: MovieSearchActions
}
```

For features with a small number of dependencies you can inline the closures directly:

```swift
struct MovieSearchEnv: Sendable {
    var search: @Sendable (String) async throws -> [Movie]
    var trackQuery: @Sendable (String) -> Void
}
```

Either layout works. The struct-of-structs pattern scales better when several features share a dependency group.

The `update` function type annotation now becomes:

```swift
(inout MovieSearchState, MovieSearchEvent) -> Effect<MovieSearchEvent, MovieSearchEnv>?
```

And inside a task, `env` is simply the injected value:

```swift
case (_, .searchTapped(let query)):
    state = .loading(query: query)
    return .sequence([
        .cancel("search"),
        .task(name: "search") { input, env in
            env.trackQuery(query)
            do {
                let movies = try await env.search(query)
                input.enqueue(.resultsReceived(movies))
            } catch {
                input.enqueue(.requestFailed(error.localizedDescription))
            }
        }
    ])
```

The update function itself never imports the network module. It references `env.search` — a closure — whose concrete implementation is provided from outside.

---

## Step 3: Inject via the SwiftUI environment

SwiftUI's environment is the right place to propagate dependencies: it's already hierarchical, it reaches every view without threading values through every init, and it integrates naturally with `EnvReader`.

Declare a key using the `@Entry` macro (iOS 17 / macOS 14+):

```swift
// App/Environment+MovieSearch.swift  (Glue layer)

import SwiftUI
import MovieService  // concrete implementation lives here

extension EnvironmentValues {
    @Entry var movieSearchEnv = MovieSearchEnv(
        search: MovieService.live.search,
        trackQuery: Analytics.live.track
    )
}
```

The concrete `MovieService` and `Analytics` types are referenced only here, in the glue layer. The feature module itself has no import of either.

For older deployment targets, write the key manually:

```swift
private struct MovieSearchEnvKey: EnvironmentKey {
    static let defaultValue = MovieSearchEnv(
        search: MovieService.live.search,
        trackQuery: Analytics.live.track
    )
}

extension EnvironmentValues {
    var movieSearchEnv: MovieSearchEnv {
        get { self[MovieSearchEnvKey.self] }
        set { self[MovieSearchEnvKey.self] = newValue }
    }
}
```

To override the value for a subtree — in a preview, test host, or A/B variant — use `.environment(\.movieSearchEnv, ...)` on any ancestor view:

```swift
MovieSearchView()
    .environment(\.movieSearchEnv, MovieSearchEnv(
        search: PreviewData.search,
        trackQuery: { _ in }
    ))
```

---

## Step 4: Read the environment and wire up EffectView

`EnvReader` reads a value from the SwiftUI environment and makes it available as a closure parameter. Use it to bridge the environment into `EffectView`:

```swift
// MovieSearch/MovieSearchView.swift  (View layer)

struct MovieSearchView: View {
    @State private var state = MovieSearchState.idle

    var body: some View {
        EnvReader(\.movieSearchEnv) { env in
            EffectView(
                state: $state,
                initialEnv: env,
                update: MovieSearchLogic.update
            ) { state, send in
                MovieSearchContent(state: state, send: send)
            }
        }
    }
}
```

`EnvReader` is a thin wrapper around `@Environment`; it exists purely for ergonomics at the `EffectView` call site. The value it captures is passed to `initialEnv:`, and EffectView takes ownership from there — forwarding it to every `.task` and `.action` for the lifetime of the view.

Note that `update` is referenced as a static function (`MovieSearchLogic.update`) rather than a closure literal. This is not required, but it keeps the view body free of logic and makes the update function easily findable and independently testable.

---

## Step 5: Testing with no mocking framework

Because `Env` is a struct of closures, constructing a test double is constructing a value:

```swift
@Suite("MovieSearch transitions")
struct MovieSearchTransitionTests {

    // A test env whose search always returns two movies
    static let testEnv = MovieSearchEnv(
        search: { _ in [Movie(title: "A"), Movie(title: "B")] },
        trackQuery: { _ in }
    )

    @Test func searchTappedTransitionsToLoading() {
        var state = MovieSearchState.idle
        let effect = MovieSearchLogic.update(state: &state, event: .searchTapped(query: "inception"))

        #expect(state == .loading(query: "inception"))
        #expect(effect != nil)
    }

    @Test func resultsArrivedTransitionsToLoaded() async throws {
        var state = MovieSearchState.loading(query: "inception")
        let movies = try await testEnv.search("inception")

        _ = MovieSearchLogic.update(state: &state, event: .resultsReceived(movies))

        #expect(state == .loaded(query: "inception", results: movies))
    }
}
```

The state-transition tests don't involve `Env` at all — they call `update` directly and check the resulting state. The `Env` is only needed in the integration tests that exercise a complete event-effect-event cycle, and there it is a plain struct literal with no framework overhead.

---

## Layering summary

| Layer | Responsibility | Knows about |
|---|---|---|
| **Feature** | State, events, transitions, action closure types | Own types only |
| **View** | SwiftUI layout, `EffectView` wiring, `EnvReader` | Feature types |
| **Glue** | `EnvironmentValues` extension, concrete service instances | Feature + infrastructure |
| **Infrastructure** | Network clients, databases, analytics SDKs | Own types only |

The feature module declares *what* it needs (closure types). The glue layer decides *what provides it* (concrete instances). The two never meet directly.

This is dependency injection without a framework, without reflection, and without protocols. The only mechanism is function values — which Swift has had since day one.

*Next: [Testing EffectView end-to-end](TestingEffectView.md)*
