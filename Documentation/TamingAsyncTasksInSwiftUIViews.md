# Taming async tasks in SwiftUI views

SwiftUI's `.task` modifier is a convenient way to start async work when a view appears. For simple cases — fire a fetch on load, cancel it when the view disappears — it works well. But as soon as your requirements grow slightly more complex, you start running into walls.

This article walks through those walls one by one, and shows how `EffectView` addresses each of them.

---

## The `.task` modifier and its limits

### Task lifetime is tied to rendering, not logic

The `.task` modifier cancels and restarts based on two things: the view appearing/disappearing, and changes to the `id:` parameter. Both are driven by SwiftUI's rendering engine — not by your application logic.

This means a task can be cancelled because a parent view re-rendered and changed the view's identity, even if you didn't intend any logical restart. Conversely, there is no way to keep a task running across a navigation push and pop, because the view disappears.

### The `id:` parameter re-cancels *and* restarts — there is no cancel-only

A common pattern for debounced search is:

```swift
.task(id: query) {
    try? await Task.sleep(for: .milliseconds(300))
    guard !Task.isCancelled else { return }
    results = await search(query)
}
```

This works as long as you understand that changing `query` *always* restarts the task — including immediately after the delay fires. There is no way to say "cancel the running task but don't start a new one." That asymmetry makes some patterns — like a Stop button that simply halts work without triggering a new run — awkward to express.

### The number of concurrent tasks is fixed at compile time

Each `.task` modifier owns exactly one task slot. If you need to run a variable number of concurrent operations — one upload per selected file, one prefetch per visible row, one sync per connected device — you cannot express that with modifiers alone.

The usual workaround is to reach for a ViewModel that holds an array of `Task` handles and manages them imperatively. That's already a signal that you've outgrown the primitive.

### Explicit cancellation on user intent is not straightforward

If the user taps a Cancel button, you want to stop the running task immediately. With `.task`, there is no handle to call `.cancel()` on. The modifier owns the task and exposes no cancellation API. The workarounds involve either changing the `id:` value (which also restarts), or storing a `Task` handle externally — at which point you're managing task lifetime manually, outside of SwiftUI's model.

### Coordination between tasks is manual

Two `.task` modifiers on the same view run independently. If one depends on the result of the other, or if they must not run simultaneously, you need to coordinate them yourself — through shared state, flags, or actor isolation. There is no built-in sequencing.

---

## What's actually needed

Stepping back, the requirements that fall out of real apps are:

1. Task lifetime is tied to the **view's logical identity**, not to individual renders.
2. Tasks can be **cancelled by name** from any event — a button tap, a timeout, a competing task starting.
3. A **dynamic number** of named tasks can run concurrently.
4. Starting a new task with a name that's already running **automatically cancels the previous one** — no manual bookkeeping.
5. Results feed back into the view through a **single, ordered mutation point** — no scattered `@State` writes racing each other.
6. The `refreshable` spinner stays visible until the **full effect chain completes** — not just until the first `await`.

`EffectView` is a small SwiftUI wrapper that provides exactly these primitives.

---

## The solution

`EffectView` separates concerns cleanly:

- **`update`** — a pure function `(inout State, Event) -> Effect?`. All state mutations happen here. No async, no throwing, just a switch.
- **`Effect`** — what the view asks the runtime to do next: start a named task, cancel a named task, fire a synchronous action chain, or a sequence of the above.
- **`Input`** — how async work sends events back into the update loop.

Tasks are identified by name strings at runtime, owned by the `EffectView` for its identity lifetime, and cancelled automatically when the view disappears.

### `refreshable` that actually waits

`perform(_:)` suspends the caller until the full effect chain — including any task that runs and sends events back — has completed. This makes it a natural fit for `refreshable`:

```swift
List(state.items, id: \.self) { Text($0) }
    .refreshable {
        await input.perform(.refresh)   // spinner stays until .refresh effect finishes
    }
```

`.refresh` is a plain event. The work is a named task returned from `update`:

```swift
case .refresh:
    return .task(name: "refresh") { input, env in
        let items = try await env.fetch()
        input.enqueue(.loaded(items))
    }
```

### Cancel on user intent

Cancellation is a first-class event returned from `update`:

```swift
case .cancelTapped:
    return .cancel("fetch")
```

That's it. No stored `Task` handle, no flag, no `id:` dance.

### Dynamic number of tasks

Because task names are runtime strings, you can start as many tasks as the data dictates and cancel any individual one:

```swift
case .startDownload(let id):
    return .task(name: "download-\(id)") { input, env in
        let data = try await env.download(id)
        input.enqueue(.downloaded(id, data))
    }

case .cancelDownload(let id):
    return .cancel("download-\(id)")
```

No ViewModel, no array of handles, no manual lifecycle.

### Automatic cancel-and-restart (debounce / live search)

Starting a task whose name is already running cancels the previous run first. Debounce is just a `Task.sleep` inside the operation — the restart behaviour is free:

```swift
case .queryChanged(let q):
    state.query = q
    return .task(name: "search") { input, env in
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let results = await env.search(q)
        input.enqueue(.resultsLoaded(results))
    }
```

---

## Adding `EffectView` to your project

```swift
// Package.swift
.package(url: "https://github.com/couchdeveloper/EffectView.git", from: "0.1.0")
```

The library is around 200 lines of source — a focused primitive, not a framework.

---

*Next: [Using Env for dependency injection](UsingEnvForDependencyInjection.md)*
