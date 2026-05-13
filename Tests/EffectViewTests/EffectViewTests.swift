#if canImport(SwiftUI) && (canImport(UIKit) || canImport(AppKit))
import Foundation
import Testing
import SwiftUI
@testable import EffectView

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Hosted EffectView Tests
//
// Testing strategy: wrap each EffectView in NSHostingController / UIHostingController
// to provide a real SwiftUI lifecycle. Input is captured via `onAppear` in the content
// closure — the same pattern used in Oak's TransducerView tests.
// Expectations synchronize with async state changes.

@Suite("EffectView")
@MainActor
struct EffectViewTests {

    // MARK: - TestView wrapper

    /// Owns @State so the Binding that flows into EffectView is live.
    struct TestView<State, Content: View>: View {
        @SwiftUI.State private var state: State
        private let content: (Binding<State>) -> Content

        init(initialState: State, @ViewBuilder content: @escaping (Binding<State>) -> Content) {
            self._state = .init(initialValue: initialState)
            self.content = content
        }

        var body: some View { content($state) }
    }

    // MARK: - Platform abstractions

    #if canImport(UIKit)
    typealias HostingController = UIHostingController<AnyView>
    typealias PlatformWindow   = UIWindow
    #elseif canImport(AppKit)
    typealias HostingController = NSHostingController<AnyView>
    typealias PlatformWindow   = NSWindow
    #endif

    // MARK: - Helpers
    
    struct EmbedInWindowAndMakeKeyTimeoutError: Error {}

    /// Wraps `view` in a hosting controller, makes the window key, and suspends
    /// until every `onAppear` in the view hierarchy has fired.
    func embedInWindowAndMakeKey<V: View>(_ view: V, timeout: TimeInterval = 1.0) async throws -> (HostingController, PlatformWindow) {
        var hostingController: HostingController?
        var window: PlatformWindow?
        var isResumed = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let timeoutCancelTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000 + 0.5))
                guard isResumed == false else { return }
                isResumed = true
                continuation.resume(throwing: EmbedInWindowAndMakeKeyTimeoutError())
            }
            hostingController = HostingController(
                rootView: AnyView(
                    view.onAppear {
                        // Defer one run-loop cycle so child onAppear calls (which fire
                        // breadth-first) have also completed before we resume.
                        DispatchQueue.main.async {
                            guard isResumed == false else { return }
                            timeoutCancelTask.cancel()
                            isResumed = true
                            continuation.resume()
                        }
                    }
                )
            )
            #if canImport(UIKit)
            window = UIWindow()
            window!.rootViewController = hostingController
            window!.makeKeyAndVisible()
            #elseif canImport(AppKit)
            window = NSWindow(contentViewController: hostingController!)
            window!.makeKeyAndOrderFront(nil)
            #endif
        }
        return (hostingController!, window!)
    }

    func cleanup(_ window: PlatformWindow) {
        #if canImport(UIKit)
        window.isHidden = true
        #elseif canImport(AppKit)
        window.orderOut(nil)
        #endif
    }

    // MARK: - Lifecycle

    @Test func contentAppearsExactlyOnce() async throws {
        enum Event: Sendable { case dummy }
        struct State: Equatable { var x = 0 }

        var appearCount = 0
        let view = TestView(initialState: State()) { binding in
            EffectView(state: binding, update: { _, _ -> Effect<Event, Void, Void>? in nil }) { _, _ in
                Color.clear.onAppear { appearCount += 1 }
            }
        }

        let (_, window) = try await embedInWindowAndMakeKey(view)
        #expect(appearCount == 1, "content onAppear should fire exactly once on first render")
        cleanup(window)
    }

    @Test func initialStateIsPreserved() async throws {
        struct State: Equatable { var label: String }
        enum Event: Sendable { case dummy }

        var capturedLabel: String?
        let view = TestView(initialState: State(label: "custom")) { binding in
            EffectView(state: binding, update: { _, _ -> Effect<Event, Void, Void>? in nil }) { state, _ in
                Color.clear.onAppear { capturedLabel = state.label }
            }
        }

        let (_, window) = try await embedInWindowAndMakeKey(view)
        #expect(capturedLabel == "custom")
        cleanup(window)
    }

    // MARK: - State updates

    @Test func updateIsCalledAndStatePropagates() async throws {
        struct State: Equatable { var count = 0 }
        enum Event: Sendable { case increment }

        var capturedInput: Input<Event, Void>?
        var observedValues: [Int] = []
        let expectation = Expectation()
        
        let timeout: UInt64 = 5_000_000_000

        let view = TestView(initialState: State()) { binding in
            EffectView(
                state: binding,
                update: { state, _ -> Effect<Event, Void, Void>? in state.count += 1; return nil }
            ) { state, input in
                Text("\(state.count)")
                    .onAppear {
                        capturedInput = input
                        observedValues.append(state.count)
                    }
                    .onChange(of: state.count) { newValue in
                        observedValues.append(newValue)
                        expectation.fulfill()
                    }
            }
        }

        let (_, window) = try await embedInWindowAndMakeKey(view)
        #expect(observedValues == [0])
        #expect(capturedInput != nil)
        capturedInput?.send(.increment)
        try await expectation.await(nanoseconds: timeout)
        #expect(observedValues == [0, 1])
        cleanup(window)
    }

    @Test func stateChangeTriggersRerender() async throws {
        enum State: Equatable, Sendable { case off, on }
        enum Event: Sendable { case toggle }

        class RenderCounter: @unchecked Sendable { var count = 0 }
        let counter = RenderCounter()
        let expectation = Expectation()
        var capturedInput: Input<Event, Void>?

        let timeout: UInt64 = 5_000_000_000

        let view = TestView(initialState: State.off) { binding in
            EffectView(
                state: binding,
                update: { state, _ -> Effect<Event, Void, Void>? in state = (state == .off ? .on : .off); return nil }
            ) { state, input in
                Text(state == .on ? "on" : "off")
                    .onAppear {
                        capturedInput = input
                        counter.count += 1
                    }
                    .onChange(of: state) { _ in
                        counter.count += 1
                        expectation.fulfill()
                    }
            }
        }

        let (_, window) = try await embedInWindowAndMakeKey(view)
        let countAfterMount = counter.count
        capturedInput?.send(.toggle)
        try await expectation.await(nanoseconds: timeout)
        #expect(counter.count > countAfterMount, "View should re-render after state change")
        cleanup(window)
    }

    // MARK: - initialEvent

    @Test func initialEventFiresOnAppear() async throws {
        // The initial event fires synchronously inside EffectView's .task, in the same
        // run-loop pass as the input setup. SwiftUI batches both state mutations into a
        // single re-render, so onChange never sees a transition. Instead we capture every
        // event that reaches `update` in a log and assert on it after onAppear fires.
        class EventLog: @unchecked Sendable { var events: [Event] = [] }
        enum Event: Sendable, Equatable { case start }
        struct State: Equatable {}
        
        let log = EventLog()

        let view = TestView(initialState: State()) { binding in
            EffectView(
                state: binding,
                initialEvent: .start,
                update: { _, event -> Effect<Event, Void, Void>? in
                    // Note: update with the initial event will be called before
                    // onAppear will be called
                    log.events.append(event)
                    return nil
                }
            ) { _, _ in
                Color.clear.onAppear {
                    #expect(log.events == [.start], "initialEvent should be processed before content onAppear fires")
                }
            }
        }

        let (_, window) = try await embedInWindowAndMakeKey(view)
        cleanup(window)
    }

    // MARK: - request

    @Test func requestSuspendsUntilUpdateCompletes() async throws {
        struct State: Equatable { var count = 0 }
        enum Event: Sendable { case increment }

        var capturedInput: Input<Event, Void>?

        let view = TestView(initialState: State()) { binding in
            EffectView(
                state: binding,
                update: { state, _ -> Effect<Event, Void, Void>? in state.count += 1; return nil }
            ) { _, input in
                Color.clear.onAppear {
                    capturedInput = input
                }
            }
        }

        let (_, window) = try await embedInWindowAndMakeKey(view)
        guard let input = capturedInput else { Issue.record("Input not captured"); return }

        // Each request() suspends until the update loop has processed the event.
        // Three sequential requests must complete without deadlock or timeout.
        await input.request(.increment)
        await input.request(.increment)
        await input.request(.increment)
        cleanup(window)
    }

    @Test func multipleEventsProcessedInOrder() async throws {
        struct State: Equatable { var log: [Int] = [] }
        enum Event: Sendable { case record(Int) }

        class LogCapture: @unchecked Sendable { var entries: [Int] = [] }
        let captured = LogCapture()

        var capturedInput: Input<Event, Void>?
        let doneExpectation  = Expectation()

        let timeout: UInt64 = 5_000_000_000

        let view = TestView(initialState: State()) { binding in
            EffectView(
                state: binding,
                update: { state, event -> Effect<Event, Void, Void>? in
                    if case .record(let n) = event { state.log.append(n) }
                    return nil
                }
            ) { state, input in
                Text("\(state.log.count)")
                    .onAppear {
                        capturedInput = input
                    }
                    .onChange(of: state.log) { newLog in
                        captured.entries = newLog
                        if newLog.count == 5 { doneExpectation.fulfill() }
                    }
            }
        }

        let (_, window) = try await embedInWindowAndMakeKey(view)
        guard let input = capturedInput else { Issue.record("Input not captured"); return }

        // request() guarantees each update completes before the next event is sent.
        for i in 1...5 { await input.request(.record(i)) }
        try await doneExpectation.await(nanoseconds: timeout)
        #expect(captured.entries == [1, 2, 3, 4, 5])
        cleanup(window)
    }

    @Test func requestReturnsOutputFromTaskClosure() async throws {
        struct State: Equatable { var value: String = "" }
        enum Event: Sendable { case load, loaded(String) }
        typealias Output = String

        var capturedInput: Input<Event, Output>?

        let view = TestView(initialState: State()) { binding in
            EffectView(
                state: binding,
                update: { (state, event) -> Effect<Event, Void, Output>? in
                    switch event {
                    case .load:
                        return .request(name: "load") { input, _ in
                            // Simulate async work, fire a completion event to update state,
                            // then return the output value directly from the task closure.
                            let result = "hello"
                            await input.request(.loaded(result))   // drives state; return discarded
                            return result                           // this becomes the Output?
                        }
                    case .loaded(let v):
                        state.value = v
                        return nil
                    }
                }
            ) { _, input in
                Color.clear.onAppear { capturedInput = input }
            }
        }

        let (_, window) = try await embedInWindowAndMakeKey(view)
        guard let input = capturedInput else { Issue.record("Input not captured"); return }

        let output = await input.request(.load)
        #expect(output == "hello")
        cleanup(window)
    }

    // MARK: - Effects

    @Test func taskEffectRunsAndMutatesState() async throws {
        struct State: Equatable { var loaded = false }
        enum Event: Sendable { case load, didLoad }

        var capturedInput: Input<Event, Void>?
        let loadedExpectation = Expectation()

        let timeout: UInt64 = 5_000_000_000

        let view = TestView(initialState: State()) { binding in
            EffectView(
                state: binding,
                update: { state, event -> Effect<Event, Void, Void>? in
                    switch event {
                    case .load:
                        return .task(name: "fetch") { input, _ in input.enqueue(.didLoad) }
                    case .didLoad:
                        state.loaded = true
                        return nil
                    }
                }
            ) { state, input in
                Text(state.loaded ? "loaded" : "idle")
                    .onAppear {
                        capturedInput = input
                    }
                    .onChange(of: state.loaded) { _ in loadedExpectation.fulfill() }
            }
        }

        let (_, window) = try await embedInWindowAndMakeKey(view)
        capturedInput?.send(.load)
        try await loadedExpectation.await(nanoseconds: timeout)
        cleanup(window)
    }

    @Test func cancelEffectStopsRunningTask() async throws {
        struct State: Equatable { var ticks = 0; var running = false }
        enum Event: Sendable { case start, tick, stop }

        class TickCounter: @unchecked Sendable { var count = 0 }
        let tickCounter = TickCounter()

        var capturedInput: Input<Event, Void>?
        let twoTicksExpectation = Expectation(minFulfillCount: 2)
        let stoppedExpectation = Expectation()

        let timeout: UInt64 = 5_000_000_000

        let view = TestView(initialState: State()) { binding in
            EffectView(
                state: binding,
                update: { state, event -> Effect<Event, Void, Void>? in
                    switch event {
                    case .start:
                        state.running = true
                        return .task(name: "ticker") { input, _ in
                            do {
                                // run infinitely - or until "ticker" tasks gets cancelled
                                while true {
                                    try await Task.sleep(nanoseconds: 20_000_000) // 20 ms
                                    input.enqueue(.tick)
                                }
                            } catch { /* task cancelled — exit cleanly */ }
                        }
                    case .tick:
                        state.ticks += 1
                        return nil
                    case .stop:
                        state.running = false
                        return .cancel("ticker")
                    }
                }
            ) { state, input in
                Text("\(state.ticks)")
                    .onAppear {
                        capturedInput = input
                    }
                    .onChange(of: state.ticks) { _ in
                        tickCounter.count += 1
                        twoTicksExpectation.fulfill()
                    }
                    .onChange(of: state.running) { isRunning in
                        if !isRunning { stoppedExpectation.fulfill() }
                    }
            }
        }

        let (_, window) = try await embedInWindowAndMakeKey(view)
        #expect(capturedInput != nil)

        capturedInput?.send(.start)
        try await twoTicksExpectation.await(nanoseconds: timeout)
        capturedInput?.send(.stop)

        try await stoppedExpectation.await(nanoseconds: timeout)
        let countAtStop = tickCounter.count

        // Wait 3x the tick interval - any in-flight ticks would arrive within this window.
        try await Task.sleep(nanoseconds: 60_000_000) // 60 ms
        #expect(tickCounter.count == countAtStop, "No ticks should arrive after cancel")
        cleanup(window)
    }

    @Test func actionEffectChainFiresSynchronously() async throws {
        struct State: Equatable { var phase = 0 }
        enum Event: Sendable { case begin, step, done }

        var capturedInput: Input<Event, Void>?
        let readyExpectation = Expectation()
        let doneExpectation = Expectation()

        let view = TestView(initialState: State()) { binding in
            EffectView(
                state: binding,
                update: { state, event -> Effect<Event, Void, Void>? in
                    switch event {
                    case .begin: state.phase = 1; return .action { _ in .step }
                    case .step:  state.phase = 2; return .action { _ in .done }
                    case .done:  state.phase = 3; return nil
                    }
                }
            ) { state, input in
                Text("\(state.phase)")
                    .onAppear {
                        capturedInput = input
                        readyExpectation.fulfill()
                    }
                    .onChange(of: state.phase) { phase in
                        if phase == 3 { doneExpectation.fulfill() }
                    }
            }
        }

        let (_, window) = try await embedInWindowAndMakeKey(view)
        try await readyExpectation.await(nanoseconds: 5_000_000_000)

        // request() awaits the entire synchronous chain: begin → step → done.
        await capturedInput?.request(.begin)
        try await doneExpectation.await(nanoseconds: 5_000_000_000)
        cleanup(window)
    }

    @Test func sequenceEffectCancelsThenStartsTask() async throws {
        struct State: Equatable { var ticks = 0 }
        enum Event: Sendable { case startFirst, refresh, tick }

        var capturedInput: Input<Event, Void>?
        let tickExpectation = Expectation()
        let cancelExpectation = Expectation()
        
        let timeout: UInt64 = 5_000_000_000

        let view = TestView(initialState: State()) { binding in
            EffectView(
                state: binding,
                update: { (state, event) -> Effect<Event, Void, Void>? in
                    switch event {
                    case .startFirst:
                        // Long-running task that never ticks on its own.
                        return .task(name: "worker") { input, _ in
                            do {
                                try await Task.sleep(nanoseconds: timeout)
                            } catch {
                                cancelExpectation.fulfill()
                            }
                        }
                    case .refresh:
                        // Cancel stale worker, immediately start a fresh one that ticks.
                        return .sequence([
                            .cancel("worker"),
                            .task(name: "worker") { input, _ in input.enqueue(.tick) },
                        ])
                    case .tick:
                        state.ticks += 1
                        return nil
                    }
                }
            ) { state, input in
                Text("\(state.ticks)")
                    .onAppear {
                        capturedInput = input
                    }
                    .onChange(of: state.ticks) { _ in
                        tickExpectation.fulfill()
                    }
            }
        }

        let (_, window) = try await embedInWindowAndMakeKey(view)

        capturedInput?.send(.startFirst)
        capturedInput?.send(.refresh) // cancels first task, starts new one that ticks
        try await cancelExpectation.await(nanoseconds: timeout)
        try await tickExpectation.await(nanoseconds: timeout)
        cleanup(window)
    }

    // MARK: - Identity reset

    @Test func identityResetRestoresInitialState() async throws {
        struct State: Equatable { var count = 0 }
        enum Event: Sendable { case increment }

        var capturedInput: Input<Event, Void>?
        let resetExpectation = Expectation()
        var countsOnAppear: [Int] = []

        let timeout: UInt64 = 5_000_000_000

        let (hostingController, window) = try await embedInWindowAndMakeKey(
            TestView(initialState: State()) { binding in
                EffectView(
                    state: binding,
                    update: { state, _ -> Effect<Event, Void, Void>? in state.count += 1; return nil }
                ) { _, input in
                    Color.clear.onAppear {
                        capturedInput = input
                    }
                }
            }
        )

        guard let input = capturedInput else { Issue.record("Input not captured"); return }

        await input.request(.increment)
        await input.request(.increment)

        // Replace the root view with a fresh instance at initial state.
        hostingController.rootView = AnyView(
            TestView(initialState: State()) { binding in
                EffectView(
                    state: binding,
                    update: { state, _ -> Effect<Event, Void, Void>? in state.count += 1; return nil }
                ) { state, _ in
                    Color.clear.onAppear {
                        countsOnAppear.append(state.count)
                        resetExpectation.fulfill()
                    }
                }
            }
        )

        try await resetExpectation.await(nanoseconds: timeout)
        #expect(countsOnAppear.last == 0, "Fresh EffectView should start at count 0")
        cleanup(window)
    }

    // MARK: - Env

    @Test func envIsForwardedToTaskOperation() async throws {
        struct State: Equatable { var result = "" }
        enum Event: Sendable { case fetch, loaded(String) }
        struct Env: Sendable { var value: String }

        var capturedInput: Input<Event, Void>?
        let loadedExpectation = Expectation()

        let timeout: UInt64 = 5_000_000_000

        let view = TestView(initialState: State()) { binding in
            EffectView(
                state: binding,
                initialEnv: Env(value: "hello from env"),
                update: { state, event -> Effect<Event, Env, Void>? in
                    switch event {
                    case .fetch:
                        return .task(name: "fetch") { input, env in
                            input.enqueue(.loaded(env.value))
                        }
                    case .loaded(let value):
                        state.result = value
                        return nil
                    }
                }
            ) { state, input in
                Text(state.result)
                    .onAppear {
                        capturedInput = input
                    }
                    .onChange(of: state.result) { _ in loadedExpectation.fulfill() }
            }
        }

        let (_, window) = try await embedInWindowAndMakeKey(view)
        capturedInput?.send(.fetch)
        try await loadedExpectation.await(nanoseconds: timeout)
        cleanup(window)
    }
}

#else
import Testing

@Suite("EffectView (SwiftUI unavailable)")
struct EffectViewTests {
    @Test func skipped() {
        // Hosted tests require SwiftUI + AppKit or UIKit.
        // This placeholder passes so `swift test` does not report a failure on
        // platforms where SwiftUI is unavailable (e.g. Linux).
    }
}

#endif

// MARK: - Spy helper

/// Records events dispatched via `Input` so tests can assert on them.
/// `@unchecked Sendable` is intentional: all accesses happen on `@MainActor`
/// (the Input closure is `@MainActor`; assertions run on `@MainActor` too).
private final class EventSpy<Event: Sendable>: @unchecked Sendable {
    var received: [Event] = []
}

// MARK: - Counter model (no Env)

private struct CounterState: Equatable {
    var count = 0
    var running = false
}

private enum CounterEvent: Equatable, Sendable {
    case increment, decrement, reset, start, stop, ticked
}

private func counterUpdate(
    state: inout CounterState,
    event: CounterEvent
) -> Effect<CounterEvent, Void, Void>? {
    switch event {
    case .increment:
        state.count += 1
        return nil
    case .decrement:
        state.count -= 1
        return nil
    case .reset:
        state = .init()
        return nil
    case .start:
        state.running = true
        return .task(name: "ticker") { input, _ in
            input.enqueue(.ticked)
        }
    case .stop:
        state.running = false
        return .cancel("ticker")
    case .ticked:
        state.count += 1
        return nil
    }
}

// MARK: - Loader model (with Env)

private struct LoaderState: Equatable {
    var items: [String] = []
    var isLoading = false
    var error: String? = nil
}

private enum LoaderEvent: Equatable, Sendable {
    case load, loaded([String]), failed(String)
}

private struct LoaderEnv: Sendable {
    var fetch: @Sendable () async throws -> [String]
}

private struct LoadFetchError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func loaderUpdate(
    state: inout LoaderState,
    event: LoaderEvent
) -> Effect<LoaderEvent, LoaderEnv, Void>? {
    switch event {
    case .load:
        state.isLoading = true
        state.error = nil
        return .task(name: "fetch") { input, env in
            do {
                let items = try await env.fetch()
                input.enqueue(.loaded(items))
            } catch {
                input.enqueue(.failed(error.localizedDescription))
            }
        }
    case .loaded(let items):
        state.isLoading = false
        state.items = items
        return nil
    case .failed(let message):
        state.isLoading = false
        state.error = message
        return nil
    }
}

// MARK: - Tests: pure state mutations

@Suite("State mutations")
struct StateMutationTests {

    @Test func incrementAddsOne() {
        var state = CounterState()
        let effect = counterUpdate(state: &state, event: .increment)
        #expect(state.count == 1)
        #expect(effect == nil)
    }

    @Test func decrementSubtractsOne() {
        var state = CounterState(count: 3, running: false)
        let effect = counterUpdate(state: &state, event: .decrement)
        #expect(state.count == 2)
        #expect(effect == nil)
    }

    @Test func resetRestoresDefaultState() {
        var state = CounterState(count: 5, running: true)
        let effect = counterUpdate(state: &state, event: .reset)
        #expect(state == CounterState())
        #expect(effect == nil)
    }

    @Test func loadSetsIsLoadingFlag() {
        var state = LoaderState()
        _ = loaderUpdate(state: &state, event: .load)
        #expect(state.isLoading == true)
        #expect(state.error == nil)
    }

    @Test func loadedClearsLoadingAndStoresItems() {
        var state = LoaderState(items: [], isLoading: true, error: nil)
        let effect = loaderUpdate(state: &state, event: .loaded(["A", "B"]))
        #expect(state.isLoading == false)
        #expect(state.items == ["A", "B"])
        #expect(effect == nil)
    }

    @Test func failedClearsLoadingAndStoresError() {
        var state = LoaderState(items: [], isLoading: true, error: nil)
        let effect = loaderUpdate(state: &state, event: .failed("network error"))
        #expect(state.isLoading == false)
        #expect(state.error == "network error")
        #expect(effect == nil)
    }
}

// MARK: - Tests: returned Effect cases

@Suite("Effect types")
struct EffectTypeTests {

    @Test func startReturnsNamedTask() {
        var state = CounterState()
        let effect = counterUpdate(state: &state, event: .start)
        #expect(state.running == true)
        guard case .task(name: let name, _, _) = effect, name == "ticker" else {
            Issue.record(#"Expected .task(name: "ticker")"#)
            return
        }
    }

    @Test func stopReturnsCancelForTicker() {
        var state = CounterState(count: 0, running: true)
        let effect = counterUpdate(state: &state, event: .stop)
        #expect(state.running == false)
        guard case .cancel(let name) = effect else {
            Issue.record("Expected .cancel")
            return
        }
        #expect(name == "ticker")
    }

    @Test func loadReturnsNamedFetchTask() {
        var state = LoaderState()
        let effect = loaderUpdate(state: &state, event: .load)
        guard case .task(name: let name, _, _) = effect, name == "fetch" else {
            Issue.record(#"Expected .task(name: "fetch")"#)
            return
        }
    }

    @Test func actionEffectInvokesClosureAndReturnsEvent() {
        enum Ev: Equatable, Sendable { case a, b }
        let effect = Effect<Ev, Void, Void>.action { _ in .b }
        guard case .action(let run) = effect else {
            Issue.record("Expected .action")
            return
        }
        #expect(run(()) == .b)
    }

    @Test func actionEffectCanReturnNil() {
        enum Ev: Equatable, Sendable { case a }
        let effect = Effect<Ev, Void, Void>.action { _ in nil }
        guard case .action(let run) = effect else {
            Issue.record("Expected .action")
            return
        }
        #expect(run(()) == nil)
    }

    @Test func sequenceContainsOrderedEffects() {
        enum Ev: Equatable, Sendable { case done }
        let effect = Effect<Ev, Void, Void>.sequence([
            .cancel("old"),
            .task(name: "new") { _, _ in }
        ])
        guard case .sequence(let effects) = effect, effects.count == 2 else {
            Issue.record("Expected .sequence with 2 effects")
            return
        }
        guard case .cancel("old") = effects[0] else {
            Issue.record(#"Expected effects[0] to be .cancel("old")"#)
            return
        }
        guard case .task(name: let name, _, _) = effects[1], name == "new" else {
            Issue.record(#"Expected effects[1] to be .task(name: "new")"#)
            return
        }
    }
}

// MARK: - Tests: async task operations

/// These tests extract the operation closure from a returned `.task` effect and
/// drive it directly — no SwiftUI hosting required.
///
/// `enqueue` schedules work on `@MainActor` via a child Task, so one `Task.yield()`
/// after `await operation(...)` is needed to let that task run before asserting.
@Suite("Task operations")
@MainActor
struct TaskOperationTests {

    @Test func fetchSuccessSendsLoadedEvent() async {
        var state = LoaderState()
        let effect = loaderUpdate(state: &state, event: .load)
        guard case .task(_, _, let operation) = effect else {
            Issue.record("Expected .task"); return
        }

        let spy = EventSpy<LoaderEvent>()
        let input = Input<LoaderEvent, Void> { [spy] event, _, _ in spy.received.append(event) }
        await operation(input, LoaderEnv(fetch: { ["X", "Y"] }))
        await Task.yield()

        #expect(spy.received == [.loaded(["X", "Y"])])
    }

    @Test func fetchFailureSendsFailedEvent() async {
        var state = LoaderState()
        let effect = loaderUpdate(state: &state, event: .load)
        guard case .task(_, _, let operation) = effect else {
            Issue.record("Expected .task"); return
        }

        let spy = EventSpy<LoaderEvent>()
        let input = Input<LoaderEvent, Void> { [spy] event, _, _ in spy.received.append(event) }
        await operation(input, LoaderEnv(fetch: { throw LoadFetchError(message: "timed out") }))
        await Task.yield()

        #expect(spy.received == [.failed("timed out")])
    }

    @Test func tickerTaskEnqueuesTickedEvent() async {
        var state = CounterState()
        let effect = counterUpdate(state: &state, event: .start)
        guard case .task(_, _, let operation) = effect else {
            Issue.record("Expected .task"); return
        }

        let spy = EventSpy<CounterEvent>()
        let input = Input<CounterEvent, Void> { [spy] event, _, _ in spy.received.append(event) }
        await operation(input, ())
        await Task.yield()

        #expect(spy.received == [.ticked])
    }
}

