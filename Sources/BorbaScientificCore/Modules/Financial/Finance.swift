import Foundation

/// When periodic payments fall within a period.
enum PaymentTiming: String, CaseIterable, Sendable {
    /// At the end of each period (an ordinary annuity).
    case end

    /// At the start of each period (an annuity due).
    case beginning
}

/// One row of a loan's amortization schedule.
struct AmortizationRow: Sendable, Equatable {
    let period: Int
    let payment: Decimal
    let interest: Decimal
    let principal: Decimal
    let balance: Decimal
}

/// The terms of a fixed-rate loan repaid in equal monthly installments.
struct LoanTerms: Sendable, Equatable {
    let principal: Decimal
    let annualRatePercent: Decimal
    let termMonths: Int

    /// The interest rate applied each month, as a fraction.
    var monthlyRate: Decimal {
        annualRatePercent / Decimal(FinancialLimits.monthsPerYear) / Decimal(Int(Percentage.wholeInPercent))
    }
}

/// Pure financial mathematics: interest, time value of money, loans and investment appraisal.
///
/// Rates are accepted as percentages by the module and converted to fractions here. Where the result is an amount
/// of money it is rounded to cents with ``Money``; ratios and rates are returned unrounded.
enum Finance {
    /// Tolerance at which an internal rate of return is considered converged.
    static let rateTolerance = 1e-10

    /// Iteration budget of the internal-rate-of-return search.
    static let maximumRateIterations = 100

    /// The lowest rate the internal-rate-of-return search considers; a rate of exactly -100% is undefined.
    private static let lowestRate = -0.999_999

    /// The highest rate the internal-rate-of-return search considers, as a fraction (1000%).
    private static let highestRate = 10.0

    /// Interest earned on a principal without compounding.
    ///
    /// - Parameters:
    ///   - principal: The amount lent or invested.
    ///   - annualRatePercent: The yearly rate in percent.
    ///   - years: The duration in years.
    /// - Returns: The interest, rounded to cents.
    /// - Throws: ``FinancialError/amountOverflow`` when the result is not representable.
    static func simpleInterest(
        principal: Double,
        annualRatePercent: Double,
        years: Double
    ) throws(FinancialError) -> Decimal {
        try Money.rounded(principal * annualRatePercent / Percentage.wholeInPercent * years)
    }

    /// The value of a principal after compound interest.
    ///
    /// - Parameters:
    ///   - principal: The amount lent or invested.
    ///   - annualRatePercent: The yearly rate in percent.
    ///   - years: The duration in years.
    ///   - compoundingsPerYear: How many times a year interest is added to the principal.
    /// - Returns: The accumulated value, rounded to cents.
    /// - Throws: ``FinancialError/amountOverflow`` when the result is not representable.
    static func compoundedValue(
        principal: Double,
        annualRatePercent: Double,
        years: Double,
        compoundingsPerYear: Int
    ) throws(FinancialError) -> Decimal {
        let compoundings = Double(compoundingsPerYear)
        let ratePerCompounding = annualRatePercent / Percentage.wholeInPercent / compoundings

        return try Money.rounded(principal * pow(1 + ratePerCompounding, compoundings * years))
    }

    /// The value, after a number of periods, of a lump sum plus equal periodic payments.
    ///
    /// - Parameters:
    ///   - presentValue: The lump sum invested now.
    ///   - ratePercent: The interest rate per period, in percent.
    ///   - periods: The number of periods.
    ///   - payment: The amount paid in every period.
    ///   - timing: Whether payments fall at the start or at the end of each period.
    /// - Returns: The accumulated value, rounded to cents.
    /// - Throws: ``FinancialError/amountOverflow`` when the result is not representable.
    static func futureValue(
        presentValue: Double,
        ratePercent: Double,
        periods: Double,
        payment: Double,
        timing: PaymentTiming
    ) throws(FinancialError) -> Decimal {
        let rate = ratePercent / Percentage.wholeInPercent
        let growth = pow(1 + rate, periods)
        let annuityFactor = rate == 0 ? periods : (growth - 1) / rate

        return try Money.rounded(presentValue * growth + payment * annuityFactor * timingFactor(timing, rate: rate))
    }

    /// The value today of a lump sum due later plus equal periodic payments.
    ///
    /// - Parameters:
    ///   - futureValue: The lump sum received at the end.
    ///   - ratePercent: The discount rate per period, in percent.
    ///   - periods: The number of periods.
    ///   - payment: The amount received in every period.
    ///   - timing: Whether payments fall at the start or at the end of each period.
    /// - Returns: The discounted value, rounded to cents.
    /// - Throws: ``FinancialError/amountOverflow`` when the result is not representable.
    static func presentValue(
        futureValue: Double,
        ratePercent: Double,
        periods: Double,
        payment: Double,
        timing: PaymentTiming
    ) throws(FinancialError) -> Decimal {
        let rate = ratePercent / Percentage.wholeInPercent
        let discount = pow(1 + rate, -periods)
        let annuityFactor = rate == 0 ? periods : (1 - discount) / rate

        return try Money.rounded(futureValue * discount + payment * annuityFactor * timingFactor(timing, rate: rate))
    }

    /// The level monthly installment that repays a loan.
    ///
    /// - Parameter terms: The terms of the loan.
    /// - Returns: The installment, rounded to cents.
    /// - Throws: ``FinancialError/amountOverflow`` when the result is not representable.
    static func monthlyPayment(for terms: LoanTerms) throws(FinancialError) -> Decimal {
        let principal = Money.double(terms.principal)
        let rate = Money.double(terms.monthlyRate)
        let months = Double(terms.termMonths)

        guard rate != 0 else {
            return try Money.rounded(principal / months)
        }
        return try Money.rounded(principal * rate / (1 - pow(1 + rate, -months)))
    }

    /// The full repayment plan of a loan, one row per month, in exact decimal arithmetic.
    ///
    /// Interest is rounded to cents every month, so the last installment absorbs the rounding drift and the final
    /// balance is exactly zero.
    ///
    /// - Parameter terms: The terms of the loan.
    /// - Returns: One row per month.
    /// - Throws: ``FinancialError/amountOverflow`` when the installment is not representable.
    static func amortizationSchedule(for terms: LoanTerms) throws(FinancialError) -> [AmortizationRow] {
        let installment = try monthlyPayment(for: terms)
        let monthlyRate = terms.monthlyRate

        var balance = terms.principal
        var rows: [AmortizationRow] = []
        rows.reserveCapacity(terms.termMonths)

        for period in 1...terms.termMonths {
            let interest = Money.rounded(balance * monthlyRate)
            let isFinal = period == terms.termMonths
            let scheduledPrincipal = max(installment - interest, 0)
            let principalPart = isFinal || scheduledPrincipal > balance ? balance : scheduledPrincipal

            balance -= principalPart
            rows.append(
                AmortizationRow(
                    period: period,
                    payment: principalPart + interest,
                    interest: interest,
                    principal: principalPart,
                    balance: balance
                )
            )
        }
        return rows
    }

    /// The sum of future cash flows discounted to today.
    ///
    /// - Parameters:
    ///   - ratePercent: The discount rate per period, in percent.
    ///   - cashFlows: Amounts per period; the first one happens now.
    /// - Returns: The net present value, rounded to cents.
    /// - Throws: ``FinancialError/amountOverflow`` when the result is not representable.
    static func netPresentValue(
        ratePercent: Double,
        cashFlows: [Double]
    ) throws(FinancialError) -> Decimal {
        try Money.rounded(presentValueOfFlows(cashFlows, at: ratePercent / Percentage.wholeInPercent))
    }

    /// The discount rate at which the net present value of the cash flows is zero.
    ///
    /// The search starts with Newton's method from the caller's guess, which converges in a handful of steps for
    /// ordinary investments, and falls back to bisection over a wide bracket when Newton's method leaves the
    /// valid range or stalls.
    ///
    /// - Parameters:
    ///   - cashFlows: Amounts per period; the first one happens now.
    ///   - guessPercent: The starting rate in percent.
    /// - Returns: The rate per period in percent.
    /// - Throws: ``FinancialError/noSignChange`` without both an inflow and an outflow, and
    ///   ``FinancialError/noConvergence(iterations:)`` when neither strategy finds a root.
    static func internalRateOfReturn(
        cashFlows: [Double],
        guessPercent: Double
    ) throws(FinancialError) -> Double {
        guard cashFlows.contains(where: { $0 > 0 }), cashFlows.contains(where: { $0 < 0 }) else {
            throw .noSignChange
        }

        if let rate = newtonRoot(of: cashFlows, startingAt: guessPercent / Percentage.wholeInPercent) {
            return rate * Percentage.wholeInPercent
        }
        if let rate = bisectionRoot(of: cashFlows) {
            return rate * Percentage.wholeInPercent
        }
        throw .noConvergence(iterations: maximumRateIterations)
    }

    /// The annual rate that grows a beginning value into an ending value over a number of years.
    ///
    /// - Parameters:
    ///   - beginningValue: The starting value; must be positive.
    ///   - endingValue: The final value.
    ///   - years: The duration in years; must be positive.
    /// - Returns: The compound annual growth rate in percent.
    static func compoundAnnualGrowthRate(
        beginningValue: Double,
        endingValue: Double,
        years: Double
    ) -> Double {
        (pow(endingValue / beginningValue, 1 / years) - 1) * Percentage.wholeInPercent
    }

    /// The gain of an investment relative to its cost.
    ///
    /// - Parameters:
    ///   - initialInvestment: What was paid; must be positive.
    ///   - finalValue: What it is worth at the end.
    /// - Returns: The return on investment in percent.
    static func returnOnInvestment(
        initialInvestment: Double,
        finalValue: Double
    ) -> Double {
        (finalValue - initialInvestment) / initialInvestment * Percentage.wholeInPercent
    }

    private static func timingFactor(
        _ timing: PaymentTiming,
        rate: Double
    ) -> Double {
        switch timing {
        case .end:
            1
        case .beginning:
            1 + rate
        }
    }

    private static func presentValueOfFlows(
        _ cashFlows: [Double],
        at rate: Double
    ) -> Double {
        cashFlows.enumerated().reduce(0) { total, flow in
            total + flow.element / pow(1 + rate, Double(flow.offset))
        }
    }

    /// The derivative of the net present value with respect to the rate.
    private static func slopeOfFlows(
        _ cashFlows: [Double],
        at rate: Double
    ) -> Double {
        cashFlows.enumerated().reduce(0) { total, flow in
            total - Double(flow.offset) * flow.element / pow(1 + rate, Double(flow.offset) + 1)
        }
    }

    private static func newtonRoot(
        of cashFlows: [Double],
        startingAt guess: Double
    ) -> Double? {
        var rate = guess

        for _ in 0..<maximumRateIterations {
            let value = presentValueOfFlows(cashFlows, at: rate)
            let slope = slopeOfFlows(cashFlows, at: rate)
            guard slope != 0, slope.isFinite else {
                return nil
            }

            let next = rate - value / slope
            guard next.isFinite, next > lowestRate else {
                return nil
            }
            if abs(next - rate) < rateTolerance {
                return next
            }
            rate = next
        }
        return nil
    }

    private static func bisectionRoot(of cashFlows: [Double]) -> Double? {
        var lower = lowestRate
        var upper = highestRate
        var lowerValue = presentValueOfFlows(cashFlows, at: lower)
        let upperValue = presentValueOfFlows(cashFlows, at: upper)

        guard lowerValue.isFinite, upperValue.isFinite, lowerValue.sign != upperValue.sign else {
            return nil
        }

        for _ in 0..<maximumRateIterations * 2 {
            let middle = (lower + upper) / 2
            let middleValue = presentValueOfFlows(cashFlows, at: middle)

            if abs(upper - lower) < rateTolerance || middleValue == 0 {
                return middle
            }
            if middleValue.sign == lowerValue.sign {
                lower = middle
                lowerValue = middleValue
            } else {
                upper = middle
            }
        }
        return nil
    }
}
