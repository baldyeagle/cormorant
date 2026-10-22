/// How a user authenticates with an AI provider.
public enum AuthStrategy: String, CaseIterable, Hashable, Sendable {
    /// User pastes their own API key.
    case apiKey
    /// User signs in with the provider's own account flow.
    case providerSignIn
    /// User points at a self-hosted or third-party gateway URL.
    case gatewayURL
    /// Runs on-device (e.g. Apple Foundation Models); no credentials.
    case onDevice
}

/// A source of model completions. Concrete providers come later.
public protocol AIProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var supportedAuth: [AuthStrategy] { get }
}
