public import Foundation

/// A calculation was accepted and is about to run.
public struct CalculationRequested: Sendable, Equatable {
    /// Unique identifier of the event.
    public let eventID: UUID

    /// When the event happened, from the injected clock.
    public let occurredAt: Date

    /// Identifier the calculation will be recorded under.
    public let calculationID: CalculationID

    /// Which calculation was requested.
    public let type: CalculationType

    /// The request that asked for it.
    public let trace: TraceContext

    /// Creates the event.
    ///
    /// - Parameters:
    ///   - eventID: Unique identifier of the event.
    ///   - occurredAt: When the event happened.
    ///   - calculationID: Identifier the calculation will be recorded under.
    ///   - type: Which calculation was requested.
    ///   - trace: The request that asked for it.
    public init(
        eventID: UUID,
        occurredAt: Date,
        calculationID: CalculationID,
        type: CalculationType,
        trace: TraceContext
    ) {
        self.eventID = eventID
        self.occurredAt = occurredAt
        self.calculationID = calculationID
        self.type = type
        self.trace = trace
    }
}

/// A calculation produced a result and was recorded.
public struct CalculationCompleted: Sendable, Equatable {
    /// Unique identifier of the event.
    public let eventID: UUID

    /// When the event happened, from the injected clock.
    public let occurredAt: Date

    /// Identifier the calculation was recorded under.
    public let calculationID: CalculationID

    /// Which calculation ran.
    public let type: CalculationType

    /// Time spent computing.
    public let executionTime: Duration

    /// The request that asked for it.
    public let trace: TraceContext

    /// Creates the event.
    ///
    /// - Parameters:
    ///   - eventID: Unique identifier of the event.
    ///   - occurredAt: When the event happened.
    ///   - calculationID: Identifier the calculation was recorded under.
    ///   - type: Which calculation ran.
    ///   - executionTime: Time spent computing.
    ///   - trace: The request that asked for it.
    public init(
        eventID: UUID,
        occurredAt: Date,
        calculationID: CalculationID,
        type: CalculationType,
        executionTime: Duration,
        trace: TraceContext
    ) {
        self.eventID = eventID
        self.occurredAt = occurredAt
        self.calculationID = calculationID
        self.type = type
        self.executionTime = executionTime
        self.trace = trace
    }
}

/// A calculation that was accepted did not produce a result: it failed, was cancelled or could not be recorded.
public struct CalculationFailed: Sendable, Equatable {
    /// Unique identifier of the event.
    public let eventID: UUID

    /// When the event happened, from the injected clock.
    public let occurredAt: Date

    /// Identifier the calculation was, or would have been, recorded under.
    public let calculationID: CalculationID

    /// Which calculation ran.
    public let type: CalculationType

    /// Stable identifier of the failure.
    public let code: ErrorCode

    /// How the failure is classified, which decides whether it is reported as an incident.
    public let classification: ErrorClassification

    /// Time spent computing before the failure.
    public let executionTime: Duration

    /// The request that asked for it.
    public let trace: TraceContext

    /// Creates the event.
    ///
    /// - Parameters:
    ///   - eventID: Unique identifier of the event.
    ///   - occurredAt: When the event happened.
    ///   - calculationID: Identifier the calculation was, or would have been, recorded under.
    ///   - type: Which calculation ran.
    ///   - code: Stable identifier of the failure.
    ///   - classification: How the failure is classified.
    ///   - executionTime: Time spent computing before the failure.
    ///   - trace: The request that asked for it.
    public init(
        eventID: UUID,
        occurredAt: Date,
        calculationID: CalculationID,
        type: CalculationType,
        code: ErrorCode,
        classification: ErrorClassification,
        executionTime: Duration,
        trace: TraceContext
    ) {
        self.eventID = eventID
        self.occurredAt = occurredAt
        self.calculationID = calculationID
        self.type = type
        self.code = code
        self.classification = classification
        self.executionTime = executionTime
        self.trace = trace
    }
}

/// Something that happened to a calculation, published after the fact for anyone who cares.
///
/// Events are immutable values. Every ``requested(_:)`` event is followed by exactly one ``completed(_:)`` or
/// ``failed(_:)`` event, so a consumer can account for every calculation without looking at the database.
public enum CalculationEvent: Sendable, Equatable {
    /// A calculation was accepted and is about to run.
    case requested(CalculationRequested)

    /// A calculation produced a result and was recorded.
    case completed(CalculationCompleted)

    /// A calculation did not produce a result.
    case failed(CalculationFailed)

    /// The name of the event, as it appears in logs.
    public var name: String {
        switch self {
        case .requested:
            "CalculationRequested"
        case .completed:
            "CalculationCompleted"
        case .failed:
            "CalculationFailed"
        }
    }

    /// The calculation the event is about.
    public var calculationID: CalculationID {
        switch self {
        case .requested(let event):
            event.calculationID
        case .completed(let event):
            event.calculationID
        case .failed(let event):
            event.calculationID
        }
    }

    /// The calculation type the event is about.
    public var type: CalculationType {
        switch self {
        case .requested(let event):
            event.type
        case .completed(let event):
            event.type
        case .failed(let event):
            event.type
        }
    }

    /// The request that caused the event.
    public var trace: TraceContext {
        switch self {
        case .requested(let event):
            event.trace
        case .completed(let event):
            event.trace
        case .failed(let event):
            event.trace
        }
    }
}

/// Receives events as they happen.
///
/// Publishing never fails and never blocks the request for long: an implementation that cannot deliver an event
/// must drop it (and say so in its own telemetry) rather than make a calculation fail because of an observer.
public protocol EventPublisher: Sendable {
    /// Hands an event to the observers.
    ///
    /// - Parameter event: The event to publish.
    func publish(_ event: CalculationEvent) async
}
