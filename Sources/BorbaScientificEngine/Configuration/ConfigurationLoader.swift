import Foundation

/// Builds an ``AppConfiguration`` from environment variables.
///
/// The loader is a pure function of its input, which keeps configuration testable without touching the real
/// process environment.
public enum ConfigurationLoader {
    /// Reads and validates the whole configuration.
    ///
    /// - Parameter environment: Environment variables, typically `ProcessInfo.processInfo.environment`.
    /// - Returns: A validated, immutable configuration.
    /// - Throws: ``ConfigurationError/invalid(_:)`` listing every missing or malformed variable.
    public static func load(from environment: [String: String]) throws(ConfigurationError) -> AppConfiguration {
        var reader = EnvironmentReader(values: environment)

        let appEnvironment = reader.choice(.applicationEnvironment, default: AppEnvironment.development)
        let defaults = EnvironmentDefaults(for: appEnvironment)

        let configuration = AppConfiguration(
            environment: appEnvironment,
            version: readVersion(from: reader),
            http: readHTTPSettings(from: &reader, defaults: defaults),
            logging: readLoggingSettings(from: &reader, defaults: defaults),
            database: readDatabaseSettings(from: &reader),
            calculation: readCalculationSettings(from: &reader),
            sentry: readSentrySettings(from: &reader)
        )

        try reader.finish()

        return configuration
    }

    /// Reads build metadata, all of which is optional.
    ///
    /// - Parameter reader: Source of the variables.
    /// - Returns: The build metadata, with defaults for anything unset.
    private static func readVersion(from reader: EnvironmentReader) -> ApplicationVersion {
        ApplicationVersion(
            number: reader.optionalString(.applicationVersion) ?? ConfigurationDefaults.applicationVersion,
            commit: reader.optionalString(.applicationCommit) ?? ConfigurationDefaults.applicationCommit,
            buildDate: reader.optionalString(.applicationBuildDate)
        )
    }

    /// Reads the HTTP server settings.
    ///
    /// - Parameters:
    ///   - reader: Source of the variables; records issues for invalid values.
    ///   - defaults: Defaults for the current environment.
    /// - Returns: The HTTP settings.
    private static func readHTTPSettings(
        from reader: inout EnvironmentReader,
        defaults: EnvironmentDefaults
    ) -> HTTPSettings {
        let shutdownTimeoutSeconds = reader.integer(
            .shutdownTimeoutSeconds,
            default: ConfigurationDefaults.shutdownTimeoutSeconds,
            within: ConfigurationLimits.shutdownTimeoutSeconds
        )

        return HTTPSettings(
            host: reader.optionalString(.httpHost) ?? defaults.httpHost,
            port: reader.integer(
                .httpPort,
                default: ConfigurationDefaults.httpPort,
                within: ConfigurationLimits.port
            ),
            maximumBodySizeBytes: reader.integer(
                .httpMaximumBodySizeBytes,
                default: ConfigurationDefaults.maximumBodySizeBytes,
                within: ConfigurationLimits.maximumBodySizeBytes
            ),
            shutdownTimeout: .seconds(shutdownTimeoutSeconds)
        )
    }

    /// Reads the logging settings.
    ///
    /// - Parameters:
    ///   - reader: Source of the variables; records issues for invalid values.
    ///   - defaults: Defaults for the current environment.
    /// - Returns: The logging settings.
    private static func readLoggingSettings(
        from reader: inout EnvironmentReader,
        defaults: EnvironmentDefaults
    ) -> LoggingSettings {
        LoggingSettings(
            level: reader.choice(.logLevel, default: defaults.logLevel),
            format: reader.choice(.logFormat, default: defaults.logFormat)
        )
    }

    /// Reads the database settings. `DATABASE_URL` is mandatory in every environment so no credential is ever
    /// embedded in code.
    ///
    /// - Parameter reader: Source of the variables; records issues for missing or invalid values.
    /// - Returns: The database settings.
    private static func readDatabaseSettings(from reader: inout EnvironmentReader) -> DatabaseSettings {
        let poolTimeoutMilliseconds = reader.integer(
            .databasePoolTimeoutMilliseconds,
            default: ConfigurationDefaults.databasePoolTimeoutMilliseconds,
            within: ConfigurationLimits.databasePoolTimeoutMilliseconds
        )
        let statementTimeoutMilliseconds = reader.integer(
            .databaseStatementTimeoutMilliseconds,
            default: ConfigurationDefaults.databaseStatementTimeoutMilliseconds,
            within: ConfigurationLimits.databaseStatementTimeoutMilliseconds
        )

        return DatabaseSettings(
            url: readDatabaseURL(from: &reader),
            maximumConnectionsPerEventLoop: reader.integer(
                .databaseMaximumConnectionsPerEventLoop,
                default: ConfigurationDefaults.databaseMaximumConnectionsPerEventLoop,
                within: ConfigurationLimits.databaseMaximumConnectionsPerEventLoop
            ),
            connectionPoolTimeout: .milliseconds(poolTimeoutMilliseconds),
            statementTimeout: .milliseconds(statementTimeoutMilliseconds)
        )
    }

    /// Reads and validates the connection URL.
    ///
    /// - Parameter reader: Source of the variable; records an issue when it is missing or malformed.
    /// - Returns: The URL wrapped as a secret, or an empty placeholder when an issue was recorded.
    private static func readDatabaseURL(from reader: inout EnvironmentReader) -> Secret {
        let placeholder = Secret("")

        guard let raw = reader.requiredString(.databaseURL) else {
            return placeholder
        }

        guard
            let components = URLComponents(string: raw),
            let scheme = components.scheme?.lowercased(),
            DatabaseURLScheme.accepted.contains(scheme),
            components.host?.isEmpty == false,
            components.path.count > 1
        else {
            reader.report(.databaseURL, reason: "must be a postgres:// URL with a host and a database name")
            return placeholder
        }

        return Secret(raw)
    }

    /// Reads the calculation limits.
    ///
    /// - Parameter reader: Source of the variables; records issues for invalid values.
    /// - Returns: The calculation settings.
    private static func readCalculationSettings(from reader: inout EnvironmentReader) -> CalculationSettings {
        let timeoutMilliseconds = reader.integer(
            .calculationTimeoutMilliseconds,
            default: ConfigurationDefaults.calculationTimeoutMilliseconds,
            within: ConfigurationLimits.calculationTimeoutMilliseconds
        )

        return CalculationSettings(
            timeout: .milliseconds(timeoutMilliseconds),
            maximumBatchSize: reader.integer(
                .batchMaximumSize,
                default: ConfigurationDefaults.batchMaximumSize,
                within: ConfigurationLimits.batchMaximumSize
            ),
            batchConcurrency: reader.integer(
                .batchConcurrency,
                default: ConfigurationDefaults.batchConcurrency,
                within: ConfigurationLimits.batchConcurrency
            )
        )
    }

    /// Reads the error-reporting settings.
    ///
    /// - Parameter reader: Source of the variables; records issues for invalid values.
    /// - Returns: The Sentry settings; reporting is disabled while no DSN is set.
    private static func readSentrySettings(from reader: inout EnvironmentReader) -> SentrySettings {
        SentrySettings(
            dsn: reader.optionalString(.sentryDSN).map(Secret.init),
            sampleRate: reader.decimal(
                .sentrySampleRate,
                default: ConfigurationDefaults.sentrySampleRate,
                within: ConfigurationLimits.sentrySampleRate
            )
        )
    }
}
