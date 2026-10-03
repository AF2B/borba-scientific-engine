/// One problem found in the parameters of a request.
public struct ValidationIssue: Sendable, Equatable {
    /// Name of the offending parameter.
    public let parameter: String

    /// Why the value was rejected, phrased so it can be shown to the caller.
    public let reason: String

    /// Creates an issue.
    ///
    /// - Parameters:
    ///   - parameter: Name of the offending parameter.
    ///   - reason: Why the value was rejected.
    public init(
        parameter: String,
        reason: String
    ) {
        self.parameter = parameter
        self.reason = reason
    }
}

/// The request parameters do not satisfy the operation's contract. Nothing was computed.
public struct ValidationError: Error, Sendable, Equatable {
    /// Every problem found, never empty.
    public let issues: [ValidationIssue]

    /// Creates a validation error.
    ///
    /// - Parameter issues: Every problem found.
    public init(issues: [ValidationIssue]) {
        self.issues = issues
    }

    /// Creates a validation error for a single parameter.
    ///
    /// - Parameters:
    ///   - parameter: Name of the offending parameter.
    ///   - reason: Why the value was rejected.
    public init(
        parameter: String,
        reason: String
    ) {
        self.init(issues: [ValidationIssue(parameter: parameter, reason: reason)])
    }
}

/// The requested module or operation is not registered.
public struct UnsupportedOperationError: Error, Sendable, Equatable {
    /// What was asked for.
    public let type: CalculationType

    /// Creates an unsupported-operation error.
    ///
    /// - Parameter type: What was asked for.
    public init(type: CalculationType) {
        self.type = type
    }
}

/// A division, modulo or negative power of zero was requested.
public struct DivisionByZeroError: Error, Sendable, Equatable {
    /// The operand that must not be zero, such as `divisor`.
    public let operand: String

    /// Creates a division-by-zero error.
    ///
    /// - Parameter operand: The operand that must not be zero.
    public init(operand: String) {
        self.operand = operand
    }
}

/// The input exceeds a safety limit of the engine, such as the largest supported matrix.
public struct LimitExceededError: Error, Sendable, Equatable {
    /// What is limited, such as `matrix dimension`.
    public let limit: String

    /// Largest accepted value.
    public let maximum: Int

    /// Creates a limit-exceeded error.
    ///
    /// - Parameters:
    ///   - limit: What is limited.
    ///   - maximum: Largest accepted value.
    public init(
        limit: String,
        maximum: Int
    ) {
        self.limit = limit
        self.maximum = maximum
    }
}

/// A failure that belongs to one calculation module and carries its own stable code.
///
/// This keeps the engine kernel free of module-specific error types: a module defines its own typed errors and maps
/// them to this shape at its boundary.
public struct DomainFailure: Error, Sendable, Equatable {
    /// Stable identifier of the failure.
    public let code: ErrorCode

    /// Explanation that is safe to show to the caller.
    public let message: String

    /// Optional structured context, such as the position of a syntax error.
    public let details: [ErrorDetail]

    /// Creates a domain failure.
    ///
    /// - Parameters:
    ///   - code: Stable identifier of the failure.
    ///   - message: Explanation that is safe to show to the caller.
    ///   - details: Optional structured context.
    public init(
        code: ErrorCode,
        message: String,
        details: [ErrorDetail] = []
    ) {
        self.code = code
        self.message = message
        self.details = details
    }
}

/// Structured context attached to an error.
public struct ErrorDetail: Sendable, Equatable {
    /// The field or location the detail refers to, when there is one.
    public let field: String?

    /// What is wrong, phrased so it can be shown to the caller.
    public let reason: String

    /// Creates a detail.
    ///
    /// - Parameters:
    ///   - field: The field or location the detail refers to.
    ///   - reason: What is wrong.
    public init(
        field: String? = nil,
        reason: String
    ) {
        self.field = field
        self.reason = reason
    }
}

/// Every way a calculation can fail.
///
/// Failures that the caller can cause are values the history can record; only ``internalFailure(_:)`` signals a
/// defect in the engine itself.
public enum CalculationError: Error, Sendable, Equatable {
    /// The parameters violate the operation's contract.
    case validation(ValidationError)

    /// The module or operation is not registered.
    case unsupportedOperation(UnsupportedOperationError)

    /// A division by zero was requested.
    case divisionByZero(DivisionByZeroError)

    /// The result does not fit in a finite number.
    case numericOverflow

    /// The input exceeds a safety limit.
    case limitExceeded(LimitExceededError)

    /// The calculation ran out of its time budget.
    case timedOut(limit: Duration)

    /// The calculation was cancelled, for example because the client went away or the server is shutting down.
    case cancelled

    /// A module-specific failure with its own stable code.
    case domain(DomainFailure)

    /// A defect in the engine: a programming error or an unforeseen condition.
    case internalFailure(reason: String)
}

// MARK: - Presentation

extension CalculationError {
    /// Stable identifier of the failure.
    public var code: ErrorCode {
        switch self {
        case .validation:
            .validationFailed
        case .unsupportedOperation:
            .unsupportedOperation
        case .divisionByZero:
            .divisionByZero
        case .numericOverflow:
            .numericOverflow
        case .limitExceeded:
            .limitExceeded
        case .timedOut:
            .calculationTimeout
        case .cancelled:
            .calculationCancelled
        case .domain(let failure):
            failure.code
        case .internalFailure:
            .internalError
        }
    }

    /// Explanation that is safe to show to the caller: it never contains internal details.
    public var message: String {
        switch self {
        case .validation:
            "The request parameters are invalid."
        case .unsupportedOperation(let error):
            "The calculation '\(error.type)' is not supported."
        case .divisionByZero(let error):
            "Division by zero is undefined: the \(error.operand) must not be zero."
        case .numericOverflow:
            "The result is too large to be represented."
        case .limitExceeded(let error):
            "The input exceeds the limit for \(error.limit) (maximum \(error.maximum))."
        case .timedOut(let limit):
            "The calculation exceeded its time limit of \(limit)."
        case .cancelled:
            "The calculation was cancelled before it finished."
        case .domain(let failure):
            failure.message
        case .internalFailure:
            "An unexpected error occurred."
        }
    }

    /// Structured context for the caller, such as the parameters that failed validation.
    public var details: [ErrorDetail] {
        switch self {
        case .validation(let error):
            error.issues.map { ErrorDetail(field: $0.parameter, reason: $0.reason) }
        case .domain(let failure):
            failure.details
        case .unsupportedOperation, .divisionByZero, .numericOverflow, .limitExceeded, .timedOut, .cancelled,
            .internalFailure:
            []
        }
    }

    /// How logging, metrics and error reporting should treat this failure.
    public var classification: ErrorClassification {
        switch self {
        case .validation, .unsupportedOperation, .divisionByZero, .numericOverflow, .limitExceeded, .domain:
            .expectedDomain
        case .timedOut, .cancelled:
            .application
        case .internalFailure:
            .unexpected
        }
    }
}

// MARK: - Convenience constructors

extension CalculationError {
    /// The result is mathematically undefined for the given input, such as the square root of a negative number.
    ///
    /// - Parameter reason: Explanation that is safe to show to the caller.
    /// - Returns: A domain failure carrying ``ErrorCode/undefinedResult``.
    public static func undefined(_ reason: String) -> CalculationError {
        .domain(DomainFailure(code: .undefinedResult, message: reason))
    }

    /// An iterative method gave up before reaching the requested accuracy.
    ///
    /// - Parameter iterations: How many iterations were spent.
    /// - Returns: A domain failure carrying ``ErrorCode/noConvergence``.
    public static func didNotConverge(iterations: Int) -> CalculationError {
        .domain(
            DomainFailure(
                code: .noConvergence,
                message: "The method did not converge within \(iterations) iterations."
            )
        )
    }

    /// A single parameter violates the operation's contract.
    ///
    /// - Parameters:
    ///   - parameter: Name of the offending parameter.
    ///   - reason: Why the value was rejected.
    /// - Returns: A validation failure for that parameter.
    public static func invalidParameter(
        _ parameter: String,
        reason: String
    ) -> CalculationError {
        .validation(ValidationError(parameter: parameter, reason: reason))
    }
}
