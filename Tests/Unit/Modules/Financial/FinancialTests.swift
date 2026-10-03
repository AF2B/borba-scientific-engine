import Foundation
import TestSupport
import Testing

@testable import BorbaScientificCore

@Suite("Financial")
struct FinancialTests {
    private typealias P = FinancialParameters

    private func decimal(_ text: String) -> Decimal {
        Decimal(string: text, locale: nil) ?? .nan
    }

    struct LoanCase: Sendable, CustomTestStringConvertible {
        let principal: String
        let annualRate: String
        let months: Int

        var testDescription: String {
            "\(principal) at \(annualRate)% over \(months) months"
        }
    }

    static let loans = [
        LoanCase(principal: "1000", annualRate: "12", months: 3),
        LoanCase(principal: "200000", annualRate: "5", months: 360),
        LoanCase(principal: "1200", annualRate: "0", months: 12),
        LoanCase(principal: "999.99", annualRate: "7.35", months: 7),
        LoanCase(principal: "50000", annualRate: "29.9", months: 120),
    ]

    @Test("rounds currency like a person reading the number, not by its binary expansion")
    func moneyRounding() throws {
        #expect(try Money.rounded(1_073.645) == decimal("1073.65"))
        #expect(try Money.rounded(2.675) == decimal("2.68"))
        #expect(try Money.rounded(-2.675) == decimal("-2.68"))
        #expect(throws: FinancialError.amountOverflow) { try Money.rounded(.infinity) }
    }

    @Test("computes simple and compound interest")
    func interest() throws {
        #expect(try Finance.simpleInterest(principal: 1_000, annualRatePercent: 5, years: 3) == 150)
        #expect(
            try Finance.compoundedValue(principal: 1_000, annualRatePercent: 5, years: 10, compoundingsPerYear: 12)
                == decimal("1647.01")
        )
        #expect(
            try Finance.compoundedValue(principal: 1_000, annualRatePercent: 0, years: 10, compoundingsPerYear: 12)
                == 1_000
        )
    }

    @Test("grows lump sums and annuities, with payments at either end of the period")
    func futureValue() throws {
        let lump = try Finance.futureValue(
            presentValue: 1_000,
            ratePercent: 5,
            periods: 10,
            payment: 0,
            timing: .end
        )
        let ordinary = try Finance.futureValue(
            presentValue: 0,
            ratePercent: 5,
            periods: 10,
            payment: 100,
            timing: .end
        )
        let due = try Finance.futureValue(
            presentValue: 0,
            ratePercent: 5,
            periods: 10,
            payment: 100,
            timing: .beginning
        )

        #expect(lump == decimal("1628.89"))
        #expect(ordinary == decimal("1257.79"))
        #expect(due == decimal("1320.68"))
    }

    @Test("handles a zero rate without dividing by zero")
    func zeroRate() throws {
        let future = try Finance.futureValue(
            presentValue: 1_000,
            ratePercent: 0,
            periods: 10,
            payment: 100,
            timing: .end
        )
        let present = try Finance.presentValue(
            futureValue: 1_000,
            ratePercent: 0,
            periods: 10,
            payment: 100,
            timing: .end
        )

        #expect(future == 2_000)
        #expect(present == 2_000)
    }

    @Test("discounting undoes compounding")
    func presentValueInvertsFutureValue() throws {
        let future = try Finance.futureValue(presentValue: 750, ratePercent: 3.5, periods: 8, payment: 0, timing: .end)
        let present = try Finance.presentValue(
            futureValue: Money.double(future),
            ratePercent: 3.5,
            periods: 8,
            payment: 0,
            timing: .end
        )

        #expect(present == 750)
    }

    @Test("computes the level installment of a loan")
    func loanPayment() throws {
        let mortgage = LoanTerms(principal: 200_000, annualRatePercent: 5, termMonths: 360)
        let interestFree = LoanTerms(principal: 1_200, annualRatePercent: 0, termMonths: 12)

        #expect(try Finance.monthlyPayment(for: mortgage) == decimal("1073.64"))
        #expect(try Finance.monthlyPayment(for: interestFree) == 100)
    }

    @Test("every amortization schedule repays exactly the principal and ends at zero", arguments: FinancialTests.loans)
    func amortizationInvariants(loan: LoanCase) throws {
        let terms = LoanTerms(
            principal: decimal(loan.principal),
            annualRatePercent: decimal(loan.annualRate),
            termMonths: loan.months
        )

        let rows = try Finance.amortizationSchedule(for: terms)

        #expect(rows.count == loan.months)
        #expect(rows.map(\.period) == Array(1...loan.months))
        #expect(rows.last?.balance == 0)
        #expect(rows.reduce(Decimal.zero) { $0 + $1.principal } == terms.principal)
        #expect(rows.allSatisfy { $0.interest >= 0 && $0.principal > 0 && $0.balance >= 0 })
        #expect(rows.allSatisfy { $0.payment == $0.interest + $0.principal })

        let installment = try Finance.monthlyPayment(for: terms)
        #expect(rows.dropLast().allSatisfy { $0.payment == installment })
    }

    @Test("a near interest-only loan never amortizes negatively and still ends at zero")
    func degenerateLoan() throws {
        let terms = LoanTerms(principal: 50_000, annualRatePercent: 29.9, termMonths: 600)

        let rows = try Finance.amortizationSchedule(for: terms)

        #expect(rows.allSatisfy { $0.principal >= 0 && $0.balance >= 0 })
        #expect(rows.last?.balance == 0)
        #expect(rows.reduce(Decimal.zero) { $0 + $1.principal } == terms.principal)
    }

    @Test("balances shrink monotonically")
    func balancesShrink() throws {
        let terms = LoanTerms(principal: 10_000, annualRatePercent: 6, termMonths: 24)

        let balances = try Finance.amortizationSchedule(for: terms).map(\.balance)

        #expect(zip(balances, balances.dropFirst()).allSatisfy { $0 > $1 })
    }

    @Test("discounts cash flows")
    func netPresentValue() throws {
        let flows: [Double] = [-1_000, 300, 400, 500, 600]

        #expect(try Finance.netPresentValue(ratePercent: 10, cashFlows: flows) == decimal("388.77"))
        #expect(try Finance.netPresentValue(ratePercent: 0, cashFlows: flows) == 800)
    }

    @Test("finds the rate at which the net present value vanishes")
    func internalRateOfReturn() throws {
        #expect(abs(try Finance.internalRateOfReturn(cashFlows: [-100, 110], guessPercent: 10) - 10) < 1e-6)

        let flows: [Double] = [-1_000, 300, 400, 500, 600]
        let rate = try Finance.internalRateOfReturn(cashFlows: flows, guessPercent: 10)
        let residual = try Finance.netPresentValue(ratePercent: rate, cashFlows: flows)

        #expect(abs(Money.double(residual)) <= 0.01)
    }

    @Test("falls back to bisection when Newton's method is led astray")
    func internalRateOfReturnFromAFarGuess() throws {
        let flows: [Double] = [-1_000, 300, 400, 500, 600]
        let reference = try Finance.internalRateOfReturn(cashFlows: flows, guessPercent: 10)

        let fromFarAway = try Finance.internalRateOfReturn(cashFlows: flows, guessPercent: 900)

        #expect(abs(fromFarAway - reference) < 1e-6)
    }

    @Test(
        "needs both an inflow and an outflow to have a rate of return",
        arguments: [[100.0, 200.0], [-100.0, -50.0]]
    )
    func internalRateWithoutSignChange(flows: [Double]) {
        #expect(throws: FinancialError.noSignChange) {
            try Finance.internalRateOfReturn(cashFlows: flows, guessPercent: 10)
        }
    }

    @Test("computes growth rates and returns")
    func growthAndReturn() {
        #expect(
            abs(Finance.compoundAnnualGrowthRate(beginningValue: 1_000, endingValue: 2_000, years: 5) - 14.8698355)
                < 1e-6
        )
        #expect(Finance.compoundAnnualGrowthRate(beginningValue: 100, endingValue: 0, years: 3) == -100)
        #expect(Finance.returnOnInvestment(initialInvestment: 1_000, finalValue: 1_250) == 25)
        #expect(Finance.returnOnInvestment(initialInvestment: 1_000, finalValue: 500) == -50)
    }

    @Test("maps financial failures to stable error codes")
    func mapsFailures() {
        #expect(FinancialError.noConvergence(iterations: 100).calculationError.code == .noConvergence)
        #expect(FinancialError.noSignChange.calculationError.code == .validationFailed)
        #expect(FinancialError.amountOverflow.calculationError.code == .numericOverflow)
    }

    @Test("accepts amounts as numeric text so they never pass through binary floating point")
    func textAmountsThroughTheEngine() async throws {
        let engine = CalculationEngine.standard()

        let result = try await engine.calculate(
            .financial,
            FinancialOperation.loanPayment,
            [P.principal.name: "200000.00", P.annualRate.name: "5", P.termMonths.name: 360]
        )

        guard case .success(let value) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(value.fields?["payment"] == .number(1_073.64))
    }

    @Test("rejects amounts beyond the supported range")
    func hugeAmountsThroughTheEngine() async throws {
        let engine = CalculationEngine.standard()

        let error = await #expect(throws: CalculationError.self) {
            try await engine.calculate(
                .financial,
                FinancialOperation.simpleInterest,
                [P.principal.name: 1e18, P.annualRate.name: 5, P.years.name: 1]
            )
        }

        #expect(error?.details == [ErrorDetail(field: "principal", reason: "must be at most 1000000000000000")])
    }

    @Test("reports a missing sign change through the engine as a validation failure")
    func missingSignChangeThroughTheEngine() async throws {
        let engine = CalculationEngine.standard()

        let result = try await engine.calculate(
            .financial,
            FinancialOperation.internalRateOfReturn,
            [P.investmentCashFlows.name: [100, 200]]
        )

        #expect(result.failure?.code == .validationFailed)
        #expect(result.failure?.details.first?.field == "cash_flows")
    }
}
