/// An error raised by calculation code that knows how to present itself as a ``CalculationError``.
///
/// Calculation modules throw their own typed errors (`StatisticsError`, `MatrixError`, ...) from their domain
/// code, which keeps each module's failure modes explicit and exhaustively testable. The engine converts them
/// at a single place, so no call site has to translate errors by hand.
public protocol CalculationFailure: Error, Sendable {
    /// The cross-cutting representation used by the engine, the API and the history.
    var calculationError: CalculationError { get }
}

extension CalculationError: CalculationFailure {
    /// A ``CalculationError`` is already in its cross-cutting form.
    public var calculationError: CalculationError { self }
}

extension ValidationError: CalculationFailure {
    /// Wraps the error in ``CalculationError/validation(_:)``.
    public var calculationError: CalculationError { .validation(self) }
}

extension UnsupportedOperationError: CalculationFailure {
    /// Wraps the error in ``CalculationError/unsupportedOperation(_:)``.
    public var calculationError: CalculationError { .unsupportedOperation(self) }
}

extension DivisionByZeroError: CalculationFailure {
    /// Wraps the error in ``CalculationError/divisionByZero(_:)``.
    public var calculationError: CalculationError { .divisionByZero(self) }
}

extension LimitExceededError: CalculationFailure {
    /// Wraps the error in ``CalculationError/limitExceeded(_:)``.
    public var calculationError: CalculationError { .limitExceeded(self) }
}

extension DomainFailure: CalculationFailure {
    /// Wraps the failure in ``CalculationError/domain(_:)``.
    public var calculationError: CalculationError { .domain(self) }
}

extension CalculationError {
    /// Classifies any error that escapes a calculation.
    ///
    /// Calculation failures keep their meaning, cooperative cancellation becomes ``cancelled`` and anything else is
    /// reported as a defect without leaking its description to the caller.
    ///
    /// - Parameter error: The error thrown by calculation code.
    public init(escaping error: any Error) {
        switch error {
        case let failure as any CalculationFailure:
            self = failure.calculationError
        case is CancellationError:
            self = .cancelled
        default:
            self = .internalFailure(reason: "Unexpected error of type \(type(of: error))")
        }
    }
}
