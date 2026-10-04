public import Foundation

/// Identifies one recorded calculation. Identifiers are time-ordered (see ``UUIDv7Generator``), so sorting by
/// identifier sorts by creation time and new rows land at the end of an index instead of being scattered through it.
public struct CalculationID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    /// The underlying UUID.
    public let rawValue: UUID

    /// Wraps a UUID.
    ///
    /// - Parameter rawValue: The UUID to wrap.
    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// Decodes an identifier from a single UUID string.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: A decoding error when the value is not a UUID string.
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    /// Encodes the identifier as a single UUID string.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: An encoding error raised by the encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Orders identifiers by their bytes, which for time-ordered UUIDs is chronological order.
    ///
    /// The bytes are compared directly. Comparing the text of the identifiers gives the same order, because lowercase
    /// hexadecimal digits sort like the values they stand for, but it builds two strings per comparison, which adds up
    /// when thousands of records are sorted.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        withUnsafeBytes(of: lhs.rawValue.uuid) { left in
            withUnsafeBytes(of: rhs.rawValue.uuid) { right in
                left.lexicographicallyPrecedes(right)
            }
        }
    }

    /// The lowercase canonical form, such as `0192e4a1-7c3b-7d2e-8f4a-5b6c7d8e9f01`.
    public var description: String {
        rawValue.uuidString.lowercased()
    }
}

/// Whether a recorded calculation produced a result.
public enum CalculationStatus: String, Sendable, Codable, CaseIterable {
    /// The calculation produced a value.
    case succeeded

    /// The calculation was accepted but could not be completed, for example because of a division by zero.
    case failed
}

/// Why a recorded calculation failed, in a form that can be stored and shown again later.
public struct RecordedFailure: Sendable, Equatable, Codable {
    /// Stable identifier of the failure.
    public let code: ErrorCode

    /// Explanation that is safe to show to the caller.
    public let message: String

    /// Structured context, such as the parameters that failed validation.
    public let details: [RecordedDetail]

    /// Captures a calculation error for storage.
    ///
    /// - Parameter error: The error to record.
    public init(_ error: CalculationError) {
        code = error.code
        message = error.message
        details = error.details.map(RecordedDetail.init)
    }

    /// Restores a recorded failure from storage.
    ///
    /// - Parameters:
    ///   - code: Stable identifier of the failure.
    ///   - message: Explanation that is safe to show to the caller.
    ///   - details: Structured context.
    public init(
        code: ErrorCode,
        message: String,
        details: [RecordedDetail]
    ) {
        self.code = code
        self.message = message
        self.details = details
    }
}

/// One piece of structured context of a recorded failure.
public struct RecordedDetail: Sendable, Equatable, Codable {
    /// The field the detail refers to, when there is one.
    public let field: String?

    /// What is wrong.
    public let reason: String

    /// Captures an error detail for storage.
    ///
    /// - Parameter detail: The detail to record.
    public init(_ detail: ErrorDetail) {
        field = detail.field
        reason = detail.reason
    }

    /// Restores a detail from storage.
    ///
    /// - Parameters:
    ///   - field: The field the detail refers to.
    ///   - reason: What is wrong.
    public init(
        field: String?,
        reason: String
    ) {
        self.field = field
        self.reason = reason
    }
}

/// What a recorded calculation produced.
public enum CalculationOutcome: Sendable, Equatable {
    /// The calculation produced a value.
    case succeeded(CalculationValue)

    /// The calculation failed.
    case failed(RecordedFailure)

    /// The status that summarizes the outcome.
    public var status: CalculationStatus {
        switch self {
        case .succeeded:
            .succeeded
        case .failed:
            .failed
        }
    }
}

/// One entry of the calculation history: what was asked, what came out, how long it took and how it can be traced.
public struct CalculationRecord: Sendable, Equatable {
    /// Identifier of the record.
    public let id: CalculationID

    /// Which calculation ran.
    public let type: CalculationType

    /// The parameters exactly as the caller supplied them.
    public let parameters: [String: CalculationValue]

    /// The result or the failure.
    public let outcome: CalculationOutcome

    /// Time spent computing, excluding persistence.
    public let executionTime: Duration

    /// When the calculation was recorded, from the injected clock.
    public let createdAt: Date

    /// The request and correlation identifiers of the HTTP exchange that asked for it.
    public let trace: TraceContext

    /// Creates a record.
    ///
    /// - Parameters:
    ///   - id: Identifier of the record.
    ///   - type: Which calculation ran.
    ///   - parameters: The parameters exactly as the caller supplied them.
    ///   - outcome: The result or the failure.
    ///   - executionTime: Time spent computing.
    ///   - createdAt: When the calculation was recorded.
    ///   - trace: The request and correlation identifiers.
    public init(
        id: CalculationID,
        type: CalculationType,
        parameters: [String: CalculationValue],
        outcome: CalculationOutcome,
        executionTime: Duration,
        createdAt: Date,
        trace: TraceContext
    ) {
        self.id = id
        self.type = type
        self.parameters = parameters
        self.outcome = outcome
        self.executionTime = executionTime
        self.createdAt = createdAt
        self.trace = trace
    }

    /// The status that summarizes the outcome.
    public var status: CalculationStatus {
        outcome.status
    }
}
