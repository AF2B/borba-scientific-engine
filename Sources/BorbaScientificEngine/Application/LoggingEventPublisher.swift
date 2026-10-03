import BorbaScientificCore
import Logging

/// Writes every calculation event to the log, so the life of each calculation can be followed from the logs alone.
///
/// Events are facts, not alarms: they are logged at debug level, and failures that deserve attention are logged by
/// the layer that handles them.
struct LoggingEventPublisher: EventPublisher {
    private static let message = "Calculation event"

    private let logger: Logger

    /// Creates the publisher.
    ///
    /// - Parameter logger: Where events are written.
    init(logger: Logger) {
        self.logger = logger
    }

    /// Logs an event with the identifiers that tie it to its request.
    ///
    /// - Parameter event: The event to log.
    func publish(_ event: CalculationEvent) async {
        let trace = event.trace
        logger.debug(
            "\(Self.message)",
            metadata: [
                "event": "\(event.name)",
                "calculation_id": "\(event.calculationID)",
                "calculation_type": "\(event.type)",
                TraceMetadataKey.requestID: "\(trace.requestID)",
                TraceMetadataKey.correlationID: "\(trace.correlationID)",
            ]
        )
    }
}
