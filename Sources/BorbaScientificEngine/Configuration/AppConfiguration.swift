public import Logging

/// Build metadata exposed by the `/version` endpoint and attached to error reports.
public struct ApplicationVersion: Sendable, Equatable {
    /// Semantic version of the running build.
    public let number: String

    /// Git commit the build was produced from.
    public let commit: String

    /// ISO 8601 timestamp of the build, when the pipeline provides one.
    public let buildDate: String?
}

/// Output format of the logging backend.
public enum LogFormat: String, Sendable, CaseIterable {
    /// Human-readable lines for local development.
    case console

    /// One JSON object per line, intended for log aggregation.
    case json
}

/// HTTP server settings.
public struct HTTPSettings: Sendable, Equatable {
    /// Network interface the server binds to.
    public let host: String

    /// TCP port the server listens on.
    public let port: Int

    /// Largest accepted request body, in bytes.
    public let maximumBodySizeBytes: Int

    /// Time allowed for in-flight work to finish once a shutdown signal arrives.
    public let shutdownTimeout: Duration
}

/// Logging settings.
public struct LoggingSettings: Sendable, Equatable {
    /// Minimum level that is emitted.
    public let level: Logger.Level

    /// Output format.
    public let format: LogFormat
}

/// PostgreSQL connection settings.
public struct DatabaseSettings: Sendable, Equatable {
    /// Connection URL. It embeds credentials, so it is wrapped to stay out of logs.
    public let url: Secret

    /// Pool size per event loop. The total pool size is this value times the number of event loops.
    public let maximumConnectionsPerEventLoop: Int

    /// Longest a request waits for a free pooled connection before failing fast.
    public let connectionPoolTimeout: Duration
}

/// Sentry error-reporting settings.
public struct SentrySettings: Sendable, Equatable {
    /// Project DSN. Error reporting is disabled while this is `nil`.
    public let dsn: Secret?

    /// Fraction of reportable errors that is sent, between 0 and 1.
    public let sampleRate: Double

    /// Whether error reports are sent at all.
    public var isEnabled: Bool {
        dsn != nil
    }
}

/// Complete, validated runtime configuration of the engine.
///
/// Instances are produced by ``ConfigurationLoader`` and are immutable afterwards. Every dependency that needs a
/// setting receives it through its initializer; nothing reads the process environment after startup.
public struct AppConfiguration: Sendable, Equatable {
    /// Environment the process runs in.
    public let environment: AppEnvironment

    /// Build metadata.
    public let version: ApplicationVersion

    /// HTTP server settings.
    public let http: HTTPSettings

    /// Logging settings.
    public let logging: LoggingSettings

    /// Database settings.
    public let database: DatabaseSettings

    /// Error-reporting settings.
    public let sentry: SentrySettings
}
