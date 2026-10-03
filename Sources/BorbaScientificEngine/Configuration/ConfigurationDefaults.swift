public import Logging

/// Binary multiples used to express sizes without bare literals.
enum ByteUnit {
    static let kibibyte = 1_024
    static let mebibyte = kibibyte * kibibyte
}

/// Values applied when an optional variable is not set.
enum ConfigurationDefaults {
    static let applicationVersion = "0.0.0-dev"
    static let applicationCommit = "unknown"
    static let httpPort = 8_080
    static let loopbackHost = "127.0.0.1"
    static let anyInterfaceHost = "0.0.0.0"
    static let maximumBodySizeBytes = ByteUnit.mebibyte
    static let shutdownTimeoutSeconds = 15
    static let databaseMaximumConnectionsPerEventLoop = 2
    static let databasePoolTimeoutMilliseconds = 5_000
    static let sentrySampleRate = 1.0
}

/// Inclusive bounds accepted for numeric variables.
enum ConfigurationLimits {
    private static let largestBodySizeMebibytes = 64

    static let port = 1...Int(UInt16.max)
    static let maximumBodySizeBytes = ByteUnit.kibibyte...(largestBodySizeMebibytes * ByteUnit.mebibyte)
    static let shutdownTimeoutSeconds = 0...300
    static let databaseMaximumConnectionsPerEventLoop = 1...32
    static let databasePoolTimeoutMilliseconds = 100...60_000
    static let sentrySampleRate = 0.0...1.0
}

/// URL schemes accepted for the database connection string.
enum DatabaseURLScheme {
    static let accepted: Set<String> = ["postgres", "postgresql"]
}

/// Defaults that depend on the deployment environment.
struct EnvironmentDefaults: Sendable, Equatable {
    let logLevel: Logger.Level
    let logFormat: LogFormat
    let httpHost: String

    /// Selects development-friendly defaults locally and container-friendly, quieter ones when deployed.
    ///
    /// - Parameter environment: Environment the process runs in.
    init(for environment: AppEnvironment) {
        switch environment {
        case .development:
            logLevel = .debug
            logFormat = .console
            httpHost = ConfigurationDefaults.loopbackHost
        case .test:
            logLevel = .warning
            logFormat = .console
            httpHost = ConfigurationDefaults.loopbackHost
        case .staging, .production:
            logLevel = .info
            logFormat = .json
            httpHost = ConfigurationDefaults.anyInterfaceHost
        }
    }
}
