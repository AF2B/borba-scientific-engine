/// Every environment variable read by the engine.
///
/// This enumeration is the single place where variable names are spelled out. `.env.example` must document
/// each case; a unit test keeps both in sync.
public enum EnvironmentVariable: String, Sendable, CaseIterable {
    case applicationEnvironment = "APP_ENV"
    case applicationVersion = "APP_VERSION"
    case applicationCommit = "APP_COMMIT"
    case applicationBuildDate = "APP_BUILD_DATE"
    case httpHost = "HTTP_HOST"
    case httpPort = "HTTP_PORT"
    case httpMaximumBodySizeBytes = "HTTP_MAX_BODY_SIZE_BYTES"
    case shutdownTimeoutSeconds = "SHUTDOWN_TIMEOUT_SECONDS"
    case logLevel = "LOG_LEVEL"
    case logFormat = "LOG_FORMAT"
    case databaseURL = "DATABASE_URL"
    case databaseMaximumConnectionsPerEventLoop = "DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP"
    case databasePoolTimeoutMilliseconds = "DATABASE_POOL_TIMEOUT_MS"
    case databaseStatementTimeoutMilliseconds = "DATABASE_STATEMENT_TIMEOUT_MS"
    case calculationTimeoutMilliseconds = "CALCULATION_TIMEOUT_MS"
    case batchMaximumSize = "BATCH_MAX_SIZE"
    case batchConcurrency = "BATCH_CONCURRENCY"
    case sentryDSN = "SENTRY_DSN"
    case sentrySampleRate = "SENTRY_SAMPLE_RATE"
}
