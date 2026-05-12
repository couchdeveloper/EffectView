import Observation

// MARK: - Effect.observe

extension Effect {

    /// Observes a key path on an `@Observable` object resolved from the environment,
    /// dispatching events as the value changes.
    ///
    /// The handler is invoked with the **initial value** immediately, then again on every
    /// subsequent change, until the task is cancelled or the object is deallocated.
    ///
    /// The object is resolved from the environment inside the task, so the effect captures
    /// only a key path rather than the object itself. Use ``Input/perform(_:)`` in the
    /// handler so the loop waits for the view to settle before advancing:
    ///
    /// ```swift
    /// // update:
    /// case .start:
    ///     return .observe(\.store, keyPath: \.count) { input, count in
    ///         await input.perform(.countChanged(count))
    ///     }
    /// ```
    ///
    /// The named task (`"observe"` by default) is cancelled automatically when the view
    /// disappears, or immediately when `update` returns `.cancel(name)`.
    ///
    /// - Parameters:
    ///   - envKeyPath: Key path from `Env` to the `@Observable` object. The object is held
    ///     weakly inside the task; the loop exits when it is deallocated.
    ///   - keyPath: The property on the object to observe.
    ///   - name: Optional name for the underlying task. Defaults to `"observe"`.
    ///   - priority: Optional `TaskPriority` for the underlying task.
    ///   - handler: Called with `input` and the current value on the initial read and on
    ///     every subsequent change. `async` — use `await input.perform(…)` to wait for the
    ///     view to settle before the next observation cycle.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    public static func observe<Object, Value>(
        _ envKeyPath: KeyPath<Env, Object>,
        keyPath: KeyPath<Object, Value>,
        name: String? = "observe",
        priority: TaskPriority? = nil,
        handler: @escaping @MainActor @Sendable (Input<Event>, Value) async -> Void
    ) -> Self
    where Object: Observable & AnyObject & Sendable, Value: Sendable
    {
        let box = SendableKeyPath(keyPath: keyPath)
        let envKeyPathBox = SendableKeyPath(keyPath: envKeyPath)
        return .task(name: name, priority: priority) { @MainActor input, env in
            let object = env[keyPath: envKeyPathBox.keyPath]
            await observeKeyPath(object, keyPath: box.keyPath) { value in
                await handler(input, value)
            }
        }
    } 

    /// Observes a key path on an `@Observable` object and dispatches events as values change.
    ///
    /// The handler is invoked with the **initial value** immediately, then again on every
    /// subsequent change, until the task is cancelled or the object is deallocated.
    ///
    /// The `input` parameter gives the handler the same three dispatch strategies
    /// (``Input/enqueue(_:)``, ``Input/send(_:)``, ``Input/perform(_:)``) available in any
    /// other effect. For observation you will typically want ``Input/perform(_:)`` so the loop
    /// waits for the EffectView to process each change before advancing to the next one:
    ///
    /// ```swift
    /// // update:
    /// case .storeReceived(let store):
    ///     return .observe(store, keyPath: \.count) { input, count in
    ///         await input.perform(.countChanged(count))
    ///     }
    /// ```
    ///
    /// The named task (`"observe"` by default) is cancelled automatically when the view
    /// disappears, or immediately when `update` returns `.cancel(name)`.
    ///
    /// - Parameters:
    ///   - object: The `@Observable` object to watch. Held weakly inside the task so the
    ///     effect does not extend the object's lifetime. The loop exits when `object` is
    ///     deallocated.
    ///   - keyPath: The property to observe.
    ///   - name: Optional name for the underlying task. Defaults to `"observe"`.
    ///   - priority: Optional `TaskPriority` for the underlying task.
    ///   - handler: Called with `input` and the current value on the initial read and on
    ///     every subsequent change. `async` — use `await input.perform(…)` to wait for the
    ///     view to settle before the next observation cycle.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    public static func observe<Object, Value>(
        _ object: Object,
        keyPath: KeyPath<Object, Value>,
        name: String? = "observe",
        priority: TaskPriority? = nil,
        handler: @escaping @MainActor @Sendable (Input<Event>, Value) async -> Void
    ) -> Self
    where Object: Observable & AnyObject & Sendable, Value: Sendable
    {
        let box = SendableKeyPath(keyPath: keyPath)
        return .task(name: name, priority: priority) { @MainActor input, _ in
            await observeKeyPath(object, keyPath: box.keyPath) { value in
                await handler(input, value)
            }
        }
    } 

}

// MARK: - Internal helpers

/// A minimal `@unchecked Sendable` box for `KeyPath`.
///
/// `KeyPath` is a value type with no mutable state — it is intrinsically safe to share
/// across concurrency domains. This wrapper makes that explicit so key path values can be
/// captured in `@Sendable` closures without requiring `SE-0418` (`InferSendableFromCaptures`)
/// at every call site.
private struct SendableKeyPath<Root, Value>: @unchecked Sendable {
    let keyPath: KeyPath<Root, Value>
}

/// Observes a key path on an `@Observable` object, calling `handler` with each new value
/// until the current task is cancelled or `object` is deallocated.
///
/// On macOS 26+ / iOS 26+ uses `Observations.untilFinished` — a structured `AsyncSequence`
/// with cooperative cancellation. On earlier OS versions falls back to
/// `withObservationTracking` with recursive re-registration.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
@MainActor
public func observeKeyPath<Object, Value>(
    _ object: Object,
    keyPath: KeyPath<Object, Value>,
    handler: @escaping @MainActor @Sendable (Value) async -> Void
) async where Object: Observable & AnyObject & Sendable, Value: Sendable {
    let box = SendableKeyPath(keyPath: keyPath)
    if #available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, *) {
        let observations = Observations<Value, Never>.untilFinished { [weak object] in
            guard let object else { return .finish }
            return .next(object[keyPath: box.keyPath])
        }
        for await value in observations {
            await handler(value)
        }
    } else {
        // Seed the initial value — withObservationTracking only fires on *changes*.
        await handler(object[keyPath: box.keyPath])
        _observeKeyPath_legacy(object, keyPath: box, handler: handler)
    }
}

/// Legacy recursive helper for `observeKeyPath` on macOS < 26.
///
/// `onChange` fires *before* the new value is committed and on an arbitrary thread, so a
/// child `Task` hops to `@MainActor` to read the settled value. One unstructured task may
/// outlive cancellation by a single iteration — this is benign because `input.perform` on
/// a completed `EffectView` is a no-op.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
@MainActor
private func _observeKeyPath_legacy<Object, Value>(
    _ object: Object,
    keyPath box: SendableKeyPath<Object, Value>,
    handler: @escaping @MainActor @Sendable (Value) async -> Void
) where Object: Observable & AnyObject & Sendable, Value: Sendable {
    withObservationTracking {
        _ = object[keyPath: box.keyPath]
    } onChange: {
        guard !Task.isCancelled else { return }
        Task { @MainActor [weak object] in
            guard let object else { return }
            await handler(object[keyPath: box.keyPath])
            _observeKeyPath_legacy(object, keyPath: box, handler: handler)
        }
    }
}
