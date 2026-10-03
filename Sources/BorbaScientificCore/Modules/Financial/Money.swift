import Foundation

/// Failures of the financial module.
enum FinancialError: Error, Sendable, Equatable {
    /// An iterative method did not converge.
    case noConvergence(iterations: Int)

    /// An internal rate of return needs at least one inflow and one outflow.
    case noSignChange

    /// An amount does not fit in a decimal number.
    case amountOverflow
}

extension FinancialError: CalculationFailure {
    /// Maps each failure to its stable, user-facing representation.
    var calculationError: CalculationError {
        switch self {
        case .noConvergence(let iterations):
            .didNotConverge(iterations: iterations)
        case .noSignChange:
            .invalidParameter(
                FinancialParameters.cashFlows.name,
                reason: "must contain at least one positive and one negative amount"
            )
        case .amountOverflow:
            .numericOverflow
        }
    }
}

/// Limits that keep financial inputs inside the range where decimal and floating-point arithmetic stay exact
/// enough for currency.
enum FinancialLimits {
    static let maximumAmount = 1e15
    static let maximumAnnualRatePercent = 1_000.0
    static let maximumYears = 1_000.0
    static let maximumPeriods = 10_000.0
    static let maximumCompoundingsPerYear = 366
    static let maximumTermMonths = 600
    static let maximumCashFlows = 1_000
    static let monthsPerYear = 12
}

/// Currency arithmetic: amounts are rounded to cents using commercial rounding (ties away from zero), which is
/// what lenders and invoices apply.
enum Money {
    /// Decimal places in a currency amount.
    static let scale = 2

    /// Rounds a decimal amount to cents.
    ///
    /// - Parameter amount: The amount to round.
    /// - Returns: The amount with two decimal places.
    static func rounded(_ amount: Decimal) -> Decimal {
        var source = amount
        var result = Decimal()
        NSDecimalRound(&result, &source, scale, .plain)
        return result
    }

    /// Rounds a floating-point amount to cents through its shortest decimal representation, so `1073.645` rounds
    /// the way a person reading the number would expect rather than by its binary expansion.
    ///
    /// - Parameter amount: The amount to round.
    /// - Returns: The amount with two decimal places.
    /// - Throws: ``FinancialError/amountOverflow`` when the amount is not finite.
    static func rounded(_ amount: Double) throws(FinancialError) -> Decimal {
        guard amount.isFinite, let decimal = Decimal(string: String(amount), locale: nil) else {
            throw .amountOverflow
        }
        return rounded(decimal)
    }

    /// Converts an amount to a floating-point number for the result.
    ///
    /// - Parameter amount: The amount to convert.
    /// - Returns: The nearest `Double`.
    static func double(_ amount: Decimal) -> Double {
        amount.nearestDouble
    }
}
