import SwiftUI
import Foundation
import EffectView

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
public enum RemoteCounter {
    public enum Views {}
}

// MARK: - Remote Store

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
extension RemoteCounter {

    /// A minimal FSM actor implemented with `@Observable`.
    /// Private state, a public read-only projection, and an event-driven mutation API.
    /// Observers must use `withObservationTracking` (or wrap it) — the store itself
    /// does not publish a stream.
    @Observable @MainActor
    final class CounterStore: Sendable {

        enum Event { case increment, decrement, reset }

        private(set) var count: Int = 0

        func send(_ event: Event) {
            switch event {
            case .increment: count += 1
            case .decrement: count -= 1
            case .reset:     count  = 0
            }
        }
    }
}

// MARK: - Views

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
extension RemoteCounter.Views {

    struct ContentView: View {

        /// The store lives here — single instance for this subtree.
        @State private var store = RemoteCounter.CounterStore()

        var body: some View {
            CounterView(env: .init(store: store))
        }
    }

    struct CounterView: View {

        struct ViewState {
            var count: Int     = 0
            var lastDelta: Int = 0
        }

        enum Event {
            case start
            case storeChanged(newCount: Int)
            case incrementTapped
            case decrementTapped
            case resetTapped
        }

        struct Env: Identifiable {
            let id: UUID = .init()
            let store: RemoteCounter.CounterStore
        }

        @State private var state = ViewState()
        let env: Env

        @MainActor
        static func update(
            _ state: inout ViewState,
            event: Event
        ) -> Effect<Event, Env, Void>? {
            switch event {

            case .start:
                return .observe(
                    \.store, keyPath: \.count,
                     name: "observe-store-count"
                ) { @MainActor input, value in
                    print("observe-store-count: ", value)
                    await input.request(.storeChanged(newCount: value))
                }

            case .storeChanged(let newCount):
                // The only path that writes the mirrored value.
                print("received event: \(event)")
                
                state.lastDelta = newCount - state.count
                state.count     = newCount
                return nil

            case .incrementTapped:
                return .run { _, env in
                    await env.store.send(.increment)
                }

            case .decrementTapped:
                return .run { _, env in
                    await env.store.send(.decrement)
                }

            case .resetTapped:
                return .run { _, env in
                    await env.store.send(.reset)
                }
            }
        }

        var body: some View {
            EffectView(
                state: $state,
                initialEvent: .start,
                initialEnv: env,
                update: Self.update(_:event:)
            ) { state, send in
                VStack(spacing: 20) {
                    Text("\(state.count)")
                        .font(Font.largeTitle.monospacedDigit())
                    Text(deltaLabel(state.lastDelta))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 24) {
                        Button("−") { send(.decrementTapped) }
                        Button("+") { send(.incrementTapped) }
                        Button("Reset") { send(.resetTapped) }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .id(env.id)
        }

        private func deltaLabel(_ delta: Int) -> String {
            switch delta {
            case 0:    return " "
            case 1...: return "+\(delta)"
            default:   return "\(delta)"
            }
        }
    }
}

// MARK: - Previews

#Preview {
    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
        RemoteCounter.Views.ContentView()
    } else {
        Text("RemoteCounter not available on this OS version")
    }
}
