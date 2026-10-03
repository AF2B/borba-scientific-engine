import Logging

/// Installs the process-wide logging backend.
enum LoggingBootstrap {
    /// Routes every `Logger` in the process to standard output at the configured level.
    ///
    /// Must be called at most once per process, before the first logger is created.
    ///
    /// - Parameter settings: Level and format requested by the configuration.
    static func bootstrap(_ settings: LoggingSettings) {
        let level = settings.level

        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = level
            return handler
        }
    }
}
