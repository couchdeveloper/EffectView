import SwiftUI

/// A view that reads a SwiftUI environment value and
/// passes it to a child view builder.
///
/// Use this when you need to forward an environment
/// value as a constructor argument to a child view —
/// a pattern `@Environment` properties alone cannot
/// express inside a closure.
///
/// ```swift
/// EnvReader(\.myEnv) { env in
///     MyView(value: env.value)
/// }
/// ```
///
/// ### Generic parameters
///
/// - `Env`: The environment value type to read.
/// - `Content`: The view produced by the content closure.
public struct EnvReader<Content: View, Env>: View {
    @Environment private var env: Env

    private let content: (Env) -> Content

    /// Creates an `EnvReader` that reads `keyPath` and
    /// passes the resulting value to `content`.
    ///
    /// - Parameters:
    ///   - keyPath: A key path into `EnvironmentValues`
    ///     identifying the value to read.
    ///   - content: A view builder that receives the
    ///     environment value.
    public init(
        _ keyPath: KeyPath<EnvironmentValues, Env>,
        @ViewBuilder content: @escaping (Env) -> Content
    ) {
        self._env = .init(keyPath)
        self.content = content
    }

    public var body: some View {
        content(env)
    }
}
