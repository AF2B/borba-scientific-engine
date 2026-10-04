import BorbaScientificCore
import Logging

extension Logger.MetadataProvider {
    /// Adds the request and correlation identifiers of the task that is logging.
    ///
    /// The identifiers are bound as a task-local value by the request middleware, so a log line written anywhere below
    /// the HTTP layer — in a use case, a repository, the database driver — carries them without any function passing
    /// them along.
    static var trace: Logger.MetadataProvider {
        Logger.MetadataProvider {
            guard let trace = TraceContext.current else {
                return [:]
            }
            return [
                TraceMetadataKey.requestID: .string(trace.requestID.rawValue),
                TraceMetadataKey.correlationID: .string(trace.correlationID.rawValue),
            ]
        }
    }
}

/// Installs the process-wide logging backend.
enum LoggingBootstrap {
    /// Routes every `Logger` in the process to standard output, in the configured format and at the configured level,
    /// with the trace identifiers of the current request added to every line.
    ///
    /// Must be called at most once per process, before the first logger is created.
    ///
    /// - Parameter settings: Level and format requested by the configuration.
    static func bootstrap(_ settings: LoggingSettings) {
        let level = settings.level
        let format = settings.format

        LoggingSystem.bootstrap(
            { label, provider -> any LogHandler in
                switch format {
                case .json:
                    return StructuredLogHandler(label: label, level: level, metadataProvider: provider)
                case .console:
                    var handler = StreamLogHandler.standardOutput(label: label, metadataProvider: provider)
                    handler.logLevel = level
                    return handler
                }
            },
            metadataProvider: .trace
        )
    }
}
