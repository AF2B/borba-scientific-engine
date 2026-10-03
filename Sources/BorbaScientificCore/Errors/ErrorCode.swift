/// A stable, machine-readable error identifier such as `DIVISION_BY_ZERO`.
///
/// Codes are part of the public API contract: clients branch on them, dashboards group by them and history
/// stores them. The set is open so each layer (and each calculation module) can define its own codes next to the
/// code that raises them.
public struct ErrorCode: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The code exactly as it appears on the wire.
    public let rawValue: String

    /// Wraps a raw code.
    ///
    /// - Parameter rawValue: The code as it appears on the wire, in `UPPER_SNAKE_CASE`.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Decodes a code from a single JSON string.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: A decoding error when the value is not a string.
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    /// Encodes the code as a single JSON string.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: An encoding error raised by the encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The raw code.
    public var description: String {
        rawValue
    }
}

// MARK: - Calculation codes

extension ErrorCode {
    /// One or more parameters are missing, malformed or out of range.
    public static let validationFailed = ErrorCode("VALIDATION_FAILED")

    /// The requested module or operation does not exist.
    public static let unsupportedOperation = ErrorCode("UNSUPPORTED_OPERATION")

    /// An iterative method did not converge on a solution.
    public static let noConvergence = ErrorCode("NO_CONVERGENCE")

    /// A division by zero was requested.
    public static let divisionByZero = ErrorCode("DIVISION_BY_ZERO")

    /// The result is mathematically undefined for the given input.
    public static let undefinedResult = ErrorCode("UNDEFINED_RESULT")

    /// The result is too large to be represented.
    public static let numericOverflow = ErrorCode("NUMERIC_OVERFLOW")

    /// The input exceeds a safety limit of the engine.
    public static let limitExceeded = ErrorCode("LIMIT_EXCEEDED")

    /// The calculation did not finish within its time budget.
    public static let calculationTimeout = ErrorCode("CALCULATION_TIMEOUT")

    /// The calculation was cancelled before it finished.
    public static let calculationCancelled = ErrorCode("CALCULATION_CANCELLED")

    /// An unexpected failure inside the engine.
    public static let internalError = ErrorCode("INTERNAL_ERROR")
}
