/// Deployment environments supported by the engine.
///
/// The raw value is the exact string accepted by the ``EnvironmentVariable/applicationEnvironment`` variable.
public enum AppEnvironment: String, Sendable, CaseIterable {
    case development
    case test
    case staging
    case production

    /// Whether the environment serves real traffic and therefore demands explicit, strict configuration.
    public var isDeployed: Bool {
        switch self {
        case .development, .test:
            false
        case .staging, .production:
            true
        }
    }
}
