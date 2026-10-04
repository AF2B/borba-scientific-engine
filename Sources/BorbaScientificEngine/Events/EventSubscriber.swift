import BorbaScientificCore
import Logging

/// Reacts to calculation events: records a metric, writes an audit line, raises an alert.
///
/// A subscriber runs outside the request that caused the event, on its own task, so it can be slow or busy without
/// delaying a response. It cannot fail a request either: ``handle(_:)`` does not throw, and a subscriber that has a
/// problem handles it itself — typically by logging it.
protocol EventSubscriber: Sendable {
    /// Names the subscriber in logs and in the accounting of events it missed.
    var name: String { get }

    /// Handles one event. Events reach a subscriber one at a time, in the order they were published.
    ///
    /// - Parameter event: The event to handle.
    func handle(_ event: CalculationEvent) async
}

/// Writes every calculation event to the log, so the life of each calculation can be followed from the logs alone.
///
/// Events are facts, not alarms: they are logged at debug level, and failures that deserve attention are logged by the
/// layer that handles them.
struct LoggingEventSubscriber: EventSubscriber {
    private static let message = "Calculation event"

    let name = "logging"

    private let logger: Logger

    /// Creates the subscriber.
    ///
    /// - Parameter logger: Where events are written.
    init(logger: Logger) {
        self.logger = logger
    }

    /// Logs an event with the identifiers that tie it to its request. The subscriber does not run inside the request's
    /// task, so the identifiers are taken from the event itself.
    ///
    /// - Parameter event: The event to log.
    func handle(_ event: CalculationEvent) async {
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
