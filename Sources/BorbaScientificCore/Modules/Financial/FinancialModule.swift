// Worked examples document an operation with concrete numbers; those literals are the data being documented.
// swiftlint:disable no_magic_numbers

import Foundation

extension ModuleName {
    /// Interest, time value of money, loans and investment appraisal.
    public static let financial = ModuleName("financial")
}

/// Wire names of the financial operations.
enum FinancialOperation: String, CaseIterable {
    case simpleInterest = "simple_interest"
    case compoundInterest = "compound_interest"
    case futureValue = "future_value"
    case presentValue = "present_value"
    case loanPayment = "loan_payment"
    case amortizationSchedule = "amortization_schedule"
    case netPresentValue = "net_present_value"
    case internalRateOfReturn = "internal_rate_of_return"
    case compoundAnnualGrowthRate = "compound_annual_growth_rate"
    case returnOnInvestment = "return_on_investment"
}

/// Parameters of the financial operations. Each name is spelled once, here.
enum FinancialParameters {
    private static let amounts = NumberBounds.greaterThan(0, upTo: FinancialLimits.maximumAmount)
    private static let nonNegativeAmounts = NumberBounds.between(0, FinancialLimits.maximumAmount)
    private static let ratesPerPeriod = NumberBounds.greaterThan(
        -Percentage.wholeInPercent,
        upTo: FinancialLimits.maximumAnnualRatePercent
    )

    static let principal = ParameterSpec.decimal(
        "principal",
        summary: "The amount lent, borrowed or invested.",
        bounds: amounts
    )
    static let annualRate = ParameterSpec.decimal(
        "annual_rate",
        summary: "The yearly interest rate in percent, such as 5 for five percent.",
        bounds: .between(0, FinancialLimits.maximumAnnualRatePercent)
    )
    static let years = ParameterSpec.number(
        "years",
        summary: "The duration in years; may be fractional.",
        bounds: .between(0, FinancialLimits.maximumYears)
    )
    static let compoundingsPerYear = ParameterSpec.integer(
        "compounds_per_year",
        summary: "How many times a year interest is added to the principal; 12 compounds monthly.",
        range: 1...FinancialLimits.maximumCompoundingsPerYear,
        default: FinancialLimits.monthsPerYear
    )
    static let presentValue = ParameterSpec.decimal(
        "present_value",
        summary: "The lump sum available now.",
        bounds: nonNegativeAmounts,
        default: 0
    )
    static let futureValue = ParameterSpec.decimal(
        "future_value",
        summary: "The lump sum due at the end.",
        bounds: nonNegativeAmounts,
        default: 0
    )
    static let payment = ParameterSpec.decimal(
        "payment",
        summary: "The amount paid or received in every period.",
        bounds: nonNegativeAmounts,
        default: 0
    )
    static let ratePerPeriod = ParameterSpec.number(
        "rate_per_period",
        summary: "The interest rate per period in percent.",
        bounds: ratesPerPeriod
    )
    static let periods = ParameterSpec.number(
        "periods",
        summary: "The number of periods.",
        bounds: .between(0, FinancialLimits.maximumPeriods)
    )
    static let timing = ParameterSpec<PaymentTiming>.choice(
        "timing",
        summary: "Whether payments fall at the end or at the beginning of each period.",
        default: .end
    )
    static let termMonths = ParameterSpec.integer(
        "term_months",
        summary: "The number of monthly installments.",
        range: 1...FinancialLimits.maximumTermMonths
    )
    static let discountRate = ParameterSpec.number(
        "rate",
        summary: "The discount rate per period in percent.",
        bounds: ratesPerPeriod
    )
    static let cashFlows = ParameterSpec.decimalList(
        "cash_flows",
        summary: "Amounts per period, outflows negative; the first one happens now.",
        size: 1...FinancialLimits.maximumCashFlows
    )
    static let investmentCashFlows = ParameterSpec.decimalList(
        "cash_flows",
        summary: "Amounts per period, outflows negative; the first one happens now.",
        size: 2...FinancialLimits.maximumCashFlows
    )
    static let guess = ParameterSpec.number(
        "guess",
        summary: "The starting rate of the search in percent.",
        bounds: .between(-Percentage.wholeInPercent + 1, FinancialLimits.maximumAnnualRatePercent),
        default: 10
    )
    static let beginningValue = ParameterSpec.decimal(
        "beginning_value",
        summary: "The value at the start.",
        bounds: amounts
    )
    static let endingValue = ParameterSpec.decimal(
        "ending_value",
        summary: "The value at the end.",
        bounds: nonNegativeAmounts
    )
    static let growthYears = ParameterSpec.number(
        "years",
        summary: "The duration in years; must be positive.",
        bounds: .greaterThan(0, upTo: FinancialLimits.maximumYears)
    )
    static let initialInvestment = ParameterSpec.decimal(
        "initial_investment",
        summary: "What was paid.",
        bounds: amounts
    )
    static let finalValue = ParameterSpec.decimal(
        "final_value",
        summary: "What the investment is worth at the end.",
        bounds: nonNegativeAmounts
    )
}

/// Interest, time value of money, loans and investment appraisal.
///
/// Amounts may be given as JSON numbers or as numeric text such as `"1234.56"`, and money results are rounded to cents.
public struct FinancialModule: CalculationModule {
    /// Name of the module on the wire.
    public let name = ModuleName.financial

    /// One-sentence description of what the module covers.
    public let summary = "Interest, time value of money, loans and investment appraisal."

    /// The operations the module offers, one per case of its operation enumeration.
    public let operations: [OperationDefinition]

    /// Creates the module.
    public init() {
        operations = FinancialOperation.allCases.map(Self.definition(for:))
    }

    private typealias P = FinancialParameters

    /// Maps every operation to its definition. The switch is exhaustive, so adding an operation without a
    /// definition does not compile.
    private static func definition(for operation: FinancialOperation) -> OperationDefinition {
        switch operation {
        case .simpleInterest: simpleInterest
        case .compoundInterest: compoundInterest
        case .futureValue: futureValue
        case .presentValue: presentValue
        case .loanPayment: loanPayment
        case .amortizationSchedule: amortizationSchedule
        case .netPresentValue: netPresentValue
        case .internalRateOfReturn: internalRateOfReturn
        case .compoundAnnualGrowthRate: compoundAnnualGrowthRate
        case .returnOnInvestment: returnOnInvestment
        }
    }

    private static let simpleInterest = OperationDefinition(
        name: FinancialOperation.simpleInterest,
        summary: "Computes the interest earned on a principal without compounding.",
        parameters: [P.principal, P.annualRate, P.years],
        result: .object([
            FieldShape("interest", .number, "The interest earned."),
            FieldShape("total", .number, "The principal plus the interest."),
        ]),
        examples: [
            OperationExample(
                "1,000 at 5% for three years.",
                with: [(P.principal, 1_000), (P.annualRate, 5), (P.years, 3)],
                yields: ["interest": 150, "total": 1_150]
            )
        ],
        compute: { arguments in
            let principal = try arguments[P.principal]
            let interest = try Finance.simpleInterest(
                principal: Money.double(principal),
                annualRatePercent: Money.double(arguments[P.annualRate]),
                years: arguments[P.years]
            )
            return .fields([
                "interest": .number(Money.double(interest)),
                "total": .number(Money.double(Money.rounded(principal) + interest)),
            ])
        }
    )

    private static let compoundInterest = OperationDefinition(
        name: FinancialOperation.compoundInterest,
        summary: "Computes the value of a principal after compound interest.",
        parameters: [P.principal, P.annualRate, P.years, P.compoundingsPerYear],
        result: .object([
            FieldShape("future_value", .number, "The principal plus the compounded interest."),
            FieldShape("interest", .number, "The interest earned."),
        ]),
        examples: [
            OperationExample(
                "1,000 at 5% for ten years, compounded monthly.",
                with: [(P.principal, 1_000), (P.annualRate, 5), (P.years, 10), (P.compoundingsPerYear, 12)],
                yields: ["future_value": 1_647.01, "interest": 647.01]
            )
        ],
        compute: { arguments in
            let principal = try arguments[P.principal]
            let value = try Finance.compoundedValue(
                principal: Money.double(principal),
                annualRatePercent: Money.double(arguments[P.annualRate]),
                years: arguments[P.years],
                compoundingsPerYear: arguments[P.compoundingsPerYear]
            )
            return .fields([
                "future_value": .number(Money.double(value)),
                "interest": .number(Money.double(value - Money.rounded(principal))),
            ])
        }
    )

    private static let futureValue = OperationDefinition(
        name: FinancialOperation.futureValue,
        summary: "Computes what a lump sum and equal periodic deposits grow to.",
        parameters: [P.presentValue, P.ratePerPeriod, P.periods, P.payment, P.timing],
        result: .number,
        examples: [
            OperationExample(
                "A lump sum of 1,000 at 5% per period for ten periods.",
                with: [(P.presentValue, 1_000), (P.ratePerPeriod, 5), (P.periods, 10)],
                yields: 1_628.89
            ),
            OperationExample(
                "Ten deposits of 100 at 5% per period.",
                with: [(P.ratePerPeriod, 5), (P.periods, 10), (P.payment, 100)],
                yields: 1_257.79
            ),
        ],
        compute: { arguments in
            .number(
                Money.double(
                    try Finance.futureValue(
                        presentValue: Money.double(arguments[P.presentValue]),
                        ratePercent: arguments[P.ratePerPeriod],
                        periods: arguments[P.periods],
                        payment: Money.double(arguments[P.payment]),
                        timing: arguments[P.timing]
                    )
                )
            )
        }
    )

    private static let presentValue = OperationDefinition(
        name: FinancialOperation.presentValue,
        summary: "Computes what a future lump sum and equal periodic payments are worth today.",
        parameters: [P.futureValue, P.ratePerPeriod, P.periods, P.payment, P.timing],
        result: .number,
        examples: [
            OperationExample(
                "1,000 due in ten periods, discounted at 5% per period.",
                with: [(P.futureValue, 1_000), (P.ratePerPeriod, 5), (P.periods, 10)],
                yields: 613.91
            )
        ],
        compute: { arguments in
            .number(
                Money.double(
                    try Finance.presentValue(
                        futureValue: Money.double(arguments[P.futureValue]),
                        ratePercent: arguments[P.ratePerPeriod],
                        periods: arguments[P.periods],
                        payment: Money.double(arguments[P.payment]),
                        timing: arguments[P.timing]
                    )
                )
            )
        }
    )

    private static let loanPayment = OperationDefinition(
        name: FinancialOperation.loanPayment,
        summary: "Computes the level monthly installment of a fixed-rate loan.",
        parameters: [P.principal, P.annualRate, P.termMonths],
        result: .object([
            FieldShape("payment", .number, "The monthly installment."),
            FieldShape("total_paid", .number, "The installment times the number of months."),
            FieldShape("total_interest", .number, "The total paid minus the principal."),
        ]),
        examples: [
            OperationExample(
                "A 200,000 mortgage at 5% over 30 years.",
                with: [(P.principal, 200_000), (P.annualRate, 5), (P.termMonths, 360)],
                yields: ["payment": 1_073.64, "total_paid": 386_510.40, "total_interest": 186_510.40]
            )
        ],
        compute: { arguments in
            let terms = LoanTerms(
                principal: try arguments[P.principal],
                annualRatePercent: try arguments[P.annualRate],
                termMonths: try arguments[P.termMonths]
            )
            let payment = try Finance.monthlyPayment(for: terms)
            let totalPaid = payment * Decimal(terms.termMonths)

            return .fields([
                "payment": .number(Money.double(payment)),
                "total_paid": .number(Money.double(totalPaid)),
                "total_interest": .number(Money.double(totalPaid - terms.principal)),
            ])
        }
    )

    private static let amortizationSchedule = OperationDefinition(
        name: FinancialOperation.amortizationSchedule,
        summary: "Lists every installment of a fixed-rate loan, split into interest and principal.",
        parameters: [P.principal, P.annualRate, P.termMonths],
        result: .list(
            of: .object([
                FieldShape("period", .number, "The installment number, starting at 1."),
                FieldShape("payment", .number, "The amount paid; the last installment absorbs rounding drift."),
                FieldShape("interest", .number, "The interest part of the payment."),
                FieldShape("principal", .number, "The principal part of the payment."),
                FieldShape("balance", .number, "The outstanding principal after the payment."),
            ])
        ),
        examples: [
            OperationExample(
                "1,000 at 12% over three months.",
                with: [(P.principal, 1_000), (P.annualRate, 12), (P.termMonths, 3)],
                yields: [
                    ["period": 1, "payment": 340.02, "interest": 10, "principal": 330.02, "balance": 669.98],
                    ["period": 2, "payment": 340.02, "interest": 6.7, "principal": 333.32, "balance": 336.66],
                    ["period": 3, "payment": 340.03, "interest": 3.37, "principal": 336.66, "balance": 0],
                ]
            )
        ],
        compute: { arguments in
            let terms = LoanTerms(
                principal: try arguments[P.principal],
                annualRatePercent: try arguments[P.annualRate],
                termMonths: try arguments[P.termMonths]
            )

            return .list(
                try Finance.amortizationSchedule(for: terms).map { row in
                    .fields([
                        "period": .number(Double(row.period)),
                        "payment": .number(Money.double(row.payment)),
                        "interest": .number(Money.double(row.interest)),
                        "principal": .number(Money.double(row.principal)),
                        "balance": .number(Money.double(row.balance)),
                    ])
                }
            )
        }
    )

    private static let netPresentValue = OperationDefinition(
        name: FinancialOperation.netPresentValue,
        summary: "Discounts a series of cash flows to today and sums them.",
        parameters: [P.discountRate, P.cashFlows],
        result: .number,
        examples: [
            OperationExample(
                "An investment of 1,000 returning 300, 400, 500 and 600, discounted at 10%.",
                with: [(P.discountRate, 10), (P.cashFlows, [-1_000, 300, 400, 500, 600])],
                yields: 388.77
            )
        ],
        compute: { arguments in
            .number(
                Money.double(
                    try Finance.netPresentValue(
                        ratePercent: arguments[P.discountRate],
                        cashFlows: arguments[P.cashFlows].map(Money.double)
                    )
                )
            )
        }
    )

    private static let internalRateOfReturn = OperationDefinition(
        name: FinancialOperation.internalRateOfReturn,
        summary: "Finds the discount rate per period, in percent, at which the net present value is zero.",
        parameters: [P.investmentCashFlows, P.guess],
        result: .number,
        examples: [
            OperationExample(
                "1,000 growing to 1,331 over three periods.",
                with: [(P.investmentCashFlows, [-1_000, 0, 0, 1_331])],
                yields: 10
            )
        ],
        compute: { arguments in
            .number(
                try Finance.internalRateOfReturn(
                    cashFlows: arguments[P.investmentCashFlows].map(Money.double),
                    guessPercent: arguments[P.guess]
                )
            )
        }
    )

    private static let compoundAnnualGrowthRate = OperationDefinition(
        name: FinancialOperation.compoundAnnualGrowthRate,
        summary: "Computes the steady yearly growth rate, in percent, between two values.",
        parameters: [P.beginningValue, P.endingValue, P.growthYears],
        result: .number,
        examples: [
            OperationExample(
                "1,000 doubling in five years.",
                with: [(P.beginningValue, 1_000), (P.endingValue, 2_000), (P.growthYears, 5)],
                yields: 14.869835499703509
            )
        ],
        compute: { arguments in
            .number(
                Finance.compoundAnnualGrowthRate(
                    beginningValue: Money.double(try arguments[P.beginningValue]),
                    endingValue: Money.double(try arguments[P.endingValue]),
                    years: try arguments[P.growthYears]
                )
            )
        }
    )

    private static let returnOnInvestment = OperationDefinition(
        name: FinancialOperation.returnOnInvestment,
        summary: "Computes the gain of an investment relative to its cost, in percent.",
        parameters: [P.initialInvestment, P.finalValue],
        result: .number,
        examples: [
            OperationExample(
                "1,000 turned into 1,250.",
                with: [(P.initialInvestment, 1_000), (P.finalValue, 1_250)],
                yields: 25
            )
        ],
        compute: { arguments in
            .number(
                Finance.returnOnInvestment(
                    initialInvestment: Money.double(try arguments[P.initialInvestment]),
                    finalValue: Money.double(try arguments[P.finalValue])
                )
            )
        }
    )
}

// swiftlint:enable no_magic_numbers
