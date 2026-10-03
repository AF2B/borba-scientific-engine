/// Failures of the statistics module.
enum StatisticsError: Error, Sendable, Equatable {
    /// A statistic was requested for a sample without observations.
    case emptySample

    /// A statistic needs more observations than were supplied.
    case insufficientObservations(required: Int, actual: Int)

    /// A statistic divides by a variance that is zero because every observation is identical.
    case zeroVariance

    /// Two paired samples have different sizes.
    case lengthMismatch(first: Int, second: Int)
}

extension StatisticsError: CalculationFailure {
    /// Maps each failure to its stable, user-facing representation.
    var calculationError: CalculationError {
        switch self {
        case .emptySample:
            .undefined("A sample needs at least one observation.")
        case .insufficientObservations(let required, let actual):
            .undefined("This statistic needs at least \(required) observations, but \(actual) were given.")
        case .zeroVariance:
            .undefined("The result is undefined because every observation of a variable is identical.")
        case .lengthMismatch(let first, let second):
            .invalidParameter(
                StatisticsParameters.y.name,
                reason: "must have as many elements as '\(StatisticsParameters.x.name)' (\(first) and \(second) given)"
            )
        }
    }
}
