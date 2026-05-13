import SwiftUI
import EffectView
import Foundation

public enum Movies {}

// MARK: - Model

extension Movies {
    public struct Movie: Equatable, Identifiable {
        public let id: UUID
        public let title: String
    }
}

// MARK: - Environment

extension Movies {
    
    public struct MovieFetch: Sendable {
        public var fetch: @Sendable () async throws -> [Movie]
        
        public func callAsFunction() async throws -> [Movie] {
            try await fetch()
        }
    }
    
    public struct Env: Sendable {
        public var movieFetch: Movies.MovieFetch
    }
}

extension EnvironmentValues {
    @Entry public var movieListViewEnv: Movies.Env = .init(
        movieFetch: .init(fetch: {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return [
                Movies.Movie(id: UUID(), title: "The Shawshank Redemption"),
                Movies.Movie(id: UUID(), title: "Moby Dick"),
                Movies.Movie(id: UUID(), title: "Severance"),
                Movies.Movie(id: UUID(), title: "Einer flog über das Kuckucksnest"),
            ]
        })
    )
}


// MARK: - Views

extension Movies {
    
    public struct ContentView: View {
        public var body: some View {
            EnvReader(\.movieListViewEnv) { env in
                Movies.MovieListView(env: env)
            }
        }
    }
    
    struct MovieListView: View {
        let env: Env
        
        @State private var state = ViewState()
        
        var body: some View {
            EffectView(state: $state, initialEvent: .load, initialEnv: env, update: Self.update) { state, input in
                ZStack {
                    switch state.content {
                    case .empty:
                        if #available(iOS 17.0, *) {
                            ContentUnavailableView("No Movies", systemImage: "film")
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "film")
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary)
                                Text("No Movies")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    case .content(let movies):
                        List(movies, rowContent: MovieRow.init)
                            .refreshable {
                                await input.request(.refresh)
                            }
                    }
                    
                    if state.isLoading {
                        ProgressView()
                    }
                }
                .alert(
                    "Error",
                    isPresented: .constant(state.error != nil),
                    presenting: state.error
                ) { _ in
                    Button("OK") { input.send(.dismiss) }
                } message: { error in
                    Text(error.localizedDescription)
                }
            }
        }
    }
    
}

extension Movies.MovieListView {
    
    typealias Movie = Movies.Movie

    struct ViewState {
        var mode: Mode
        var content: Content<[Movie]>

        enum Mode {
            case idle
            case loading
            case refreshing
            case failed(Error)
        }

        init() {
            mode = .idle
            content = .empty(.blank)
        }

        var error: Error? {
            if case .failed(let error) = mode { return error }
            return nil
        }   

        var isLoading: Bool {
            switch mode {
            case .loading: return true
            default: return false
            }
        }

        var isRefreshing: Bool {
            if case .refreshing = mode { return true }
            return false
        }
    }

    enum Event {
        case load
        case refresh
        case loaded([Movie])
        case loadFailed(Error)
        case cancel
        case dismiss
    }

    @MainActor
    static func update(state: inout ViewState, event: Event) -> Effect<Event, Movies.Env, Void>? {
        switch event {
        case .load:
            // Guard against refresh: can only race with programmatic load triggers
            // (e.g. .onAppear, timers). UI pull-to-refresh is serialised by SwiftUI.
            guard !state.isRefreshing else { return nil }
            guard !state.isLoading else { return nil }
            state.mode = .loading
            return .loadMovies()

        case .refresh:
            // Always supersedes a pending load; named task cancels any prior refresh.
            state.mode = .refreshing
            return .sequence([.cancel("load"), .refreshMovies()])

        case .loaded(let movies):
            state.mode = .idle
            state.content = .content(movies)
            return nil

        case .loadFailed(let error):
            state.mode = .failed(error)
            return nil

        case .cancel:
            state.mode = .idle
            return .cancel("load")

        case .dismiss:
            state.mode = .idle
            return nil
        }
    }

}

extension Movies.MovieListView {
    struct MovieRow: View {
        let movie: Movie

        var body: some View {
            Text(movie.title)
        }
    }
}

// MARK: - Custom Effects

extension Effect where Event == Movies.MovieListView.Event, Env == Movies.Env {
    static func loadMovies() -> Self {
        .run(name: "load") { input, env in
            do {
                let movies = try await env.movieFetch()
                input(.loaded(movies))
            } catch {
                input(.loadFailed(error))
            }
        }
    }

    static func refreshMovies() -> Self {
        // Note: a refresh action
        .run(name: "refresh") { input, env in
            do {
                let movies = try await env.movieFetch()
                input(.loaded(movies))
            } catch {
                input(.loadFailed(error))
            }
        }
    }
}

// MARK: - Previews

#Preview {
    EnvReader(\.movieListViewEnv) { env in
        Movies.MovieListView(env: env)
    }
}

