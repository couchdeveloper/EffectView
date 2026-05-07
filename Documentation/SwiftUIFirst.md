# SwiftUI First

Modern SwiftUI development has accumulated a rich set of companion patterns: ViewModels backed by `@Observable`, constructor injection through protocol-typed properties, Combine pipelines to bridge async work back to the main thread, and third-party architecture frameworks that bring their own conventions, macros, and learning curves.

These patterns all solve real problems. But they solve them *outside* SwiftUI — as a layer on top of it. The result is that every project ends up with two architectures: SwiftUI's own model and the one the team bolted on.

EffectView takes a different position. It asks: what if SwiftUI's own mechanisms are sufficient, and the only thing missing is structured effect management?

---

## What SwiftUI already gives you

SwiftUI is not a rendering library. It is an architecture.

| Mechanism | Role |
|---|---|
| `@State` / `Binding` | Ownership and propagation of mutable state |
| `@Environment` | Hierarchical dependency injection |
| View identity (`.id(...)`) | Lifecycle control — appear, disappear, restart |
| `@ViewBuilder` | Compositional, declarative UI construction |
| Structured concurrency (`.task`) | Async work tied to view lifetime |

These are not implementation details. They are the intended architecture for SwiftUI applications. `Binding` is the dependency injection mechanism for state. `Environment` is the dependency injection mechanism for services. View identity is the lifecycle. All of these are first-class, framework-supported tools.

The only gap is **effect management**: triggering, naming, cancelling, and coordinating async tasks in response to logic rather than rendering. That is what EffectView adds.

---

## What you don't need

### No ViewModel

A ViewModel in the iOS world is typically a class that holds `@Published` properties, owns async tasks, performs direct mutations, and is injected into views either via the environment or as a stored property. It is an imperative object that you have to manage.

With EffectView, state is a Swift value type (`struct` or `enum`) owned by the caller via `Binding`. There is no class, no `@Published`, no `objectWillChange`, and no `deinit` to worry about. State is just data.

Logic lives in a pure function:

```swift
func update(state: inout State, event: Event) -> Effect<Event, Env>?
```

This function is not an object. It has no stored properties, no lifecycle, and no hidden shared state. It is easier to read, easier to test, and easier to trace than a ViewModel — and it does more, because it explicitly models every side effect as a return value rather than as a fire-and-forget call inside an async method.

### No `@Observable`

`@Observable` tracks property access per-read and re-renders exactly the views that depend on each property. It is a performance optimisation. With EffectView, state is already a value type: SwiftUI's structural equality check means only views that actually use changed data re-render. `@Observable` solves a problem that the value-type model avoids having.

### No third-party DI framework

Dependency injection frameworks exist to solve one problem: getting concrete implementations of services into the code that needs them, without coupling the two directly. SwiftUI's `@Environment` already does this. It is hierarchical, it propagates automatically, and it can be overridden at any level of the view tree.

EffectView connects to it through `EnvReader` — a four-line wrapper around `@Environment`. No registration, no container, no reflection, no macros.

Dependencies are declared as structs of closures in the feature module. Concrete implementations are assigned in a single `EnvironmentValues` extension in the glue layer. Test doubles are struct literals.

### No Combine

Combine was the bridge between async work and `@Published` properties on the main thread. Structured concurrency obsoletes most of that. EffectView's `Input` type handles dispatch from any isolation — `send` for synchronous `@MainActor` calls, `enqueue` for fire-and-forget from background tasks, and `perform` when you need to await acknowledgement.

---

## What you get instead

| Concern | Solution | Article |
|---|---|---|
| Async task management | Named, cancellable tasks via `Effect.task` | [Taming async tasks in SwiftUI views](TamingAsyncTasksInSwiftUIViews.md) |
| Correctness and logic | FSM update function, impossible states unrepresentable | [Correct by Construction](CorrectByConstruction.md) |
| Dependency injection | Struct of closures + SwiftUI environment + `EnvReader` | [Using Env for Dependency Injection](UsingEnvForDependencyInjection.md) |

---

## The full picture in one diagram

```
┌────────────────────────────────────────────────────────────┐
│                        View tree                           │
│                                                            │
│   ┌─────────────────────────────────────────────────────┐  │
│   │  EnvReader(\.myEnv) { env in                        │  │
│   │      EffectView(state: $state,                      │  │
│   │                 initialEnv: env,                    │  │
│   │                 update: Logic.update) { state, send │  │
│   │          MyContent(state: state, send: send)        │  │
│   │      }                                              │  │
│   │  }                                                  │  │
│   └─────────────────────────────────────────────────────┘  │
│                                                            │
│   State (value type) ──────────────────────► Content       │
│   Events ◄──────────────────────────────────── Content     │
│                                                            │
│   event ──► update(state:event:) ──► Effect ──► Task       │
│               │                                   │        │
│               └── mutates state                   │        │
│                                                   │        │
│           env forwarded ──────────────────────────┘        │
│                                                            │
│   .environment(\.myEnv, ...) ── overrides in subtree       │
└────────────────────────────────────────────────────────────┘
```

---

## How this scales

A single feature follows the same pattern at any size:

- **Small screen** (a toggle that triggers a task): one `@State`, a two-case enum, a five-line `update` function.
- **Large screen** (a feed with pagination, search, filters, and pull-to-refresh): the same pattern with more states and events. The shape doesn't change.

Features compose by nesting `EffectView`s inside each other, with each one owning its slice of state and its slice of the environment. There is no shared mutable class to coordinate, no global event bus, and no parent ViewModel that aggregates child state.

---

## The trade-off

EffectView asks you to think in terms of states and events rather than imperative sequences. For developers used to writing `await someMethod()` directly in a button action, the indirection through events and an update function can feel unfamiliar at first.

The payoff is that the question "what happens when the user taps this button while something is already loading?" always has an explicit, readable answer — it's a case in the `switch`. There are no implicit races, no unintended concurrency, and no hidden shared mutable state. The behaviour of the whole screen is the content of one function.

That function requires no framework to test, no mocking library, and no async test infrastructure. It is called like any other function. The tests are fast, deterministic, and complete in milliseconds.

---

## Getting started

```swift
.package(url: "https://github.com/your-org/EffectView", from: "0.1.0")
```

Start with the simplest case — one state enum, one event enum, one `update` function — and expand from there. The pattern is the same at every scale.
