import SwiftUI
import Foundation
import EffectView

public enum Counter {}

// MARK: - Environment

extension EnvironmentValues {
    @Entry var counterViewEnv: Counter.CounterView.Env = .init()
}

// MARK: - Views

extension Counter {
    
    struct ContentView: View {
        var body: some View {
            EnvReader(\.counterViewEnv) {
                CounterView(env: $0)
            }
        }
    }
    
    struct CounterView: View {
        
        struct ViewState {
            var counter = 0
            init() {
                self.counter = 0
            }
        }
        
        enum Event {
            case start
            case tick
            case stop
        }
        
        struct Env: Identifiable {
            let id: UUID = .init()
            init() {}
        }
        
        @State private var state: ViewState = .init()
        
        let env: Env
        
        @MainActor
        private static func update(
            state: inout ViewState,
            event: Event
        ) -> Effect<Event, Env, Void>? {
            switch event {
            case .start:
                state.counter = 0
                return .run(name: "Counter") { input, env in
                    while true {
                        do {
                            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 sec
                            print("tick")
                            input(.tick)
                        } catch {
                            // most likeley, the counter task has been cancelled; ignore it.
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
            EffectView(
                state: $state,
                initialEnv: env,
                update: Self.update
            ) { state, send in
                VStack {
                    Text("\(state.counter)")
                        .font(Font.largeTitle.monospacedDigit())
                    Button("Start") { send(.start) }
                    Button("Stop")  { send(.stop)  }
                }
            }
            .id(env.id) // restart the EffectView when the env changes
        }
    }
}

#if false
#Preview {
    Counter.ContentView()
}
#endif
