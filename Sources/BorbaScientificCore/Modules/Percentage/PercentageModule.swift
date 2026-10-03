// Worked examples document an operation with concrete numbers; those literals are the data being documented.
// swiftlint:disable no_magic_numbers

extension ModuleName {
    /// Percentages and relative change.
    public static let percentage = ModuleName("percentage")
}

/// Wire names of the percentage operations.
enum PercentageOperation: String, CaseIterable {
    case percentageOf = "percentage_of"
    case percentageChange = "percentage_change"
    case percentageDifference = "percentage_difference"
    case increaseByPercentage = "increase_by_percentage"
    case decreaseByPercentage = "decrease_by_percentage"
    case originalValue = "original_value"
    case percentageShare = "percentage_share"
}

/// Parameters of the percentage operations. Each name is spelled once, here.
enum PercentageParameters {
    static let percentage = ParameterSpec.number(
        "percentage",
        summary: "The percentage, such as 15 for fifteen percent."
    )
    static let base = ParameterSpec.number("base", summary: "The value the percentage applies to.")
    static let originalValue = ParameterSpec.number("original_value", summary: "The starting value.")
    static let updatedValue = ParameterSpec.number("updated_value", summary: "The ending value.")
    static let first = ParameterSpec.number("first", summary: "One of the two values to compare.")
    static let second = ParameterSpec.number("second", summary: "The other value to compare.")
    static let value = ParameterSpec.number("value", summary: "The starting value.")
    static let finalValue = ParameterSpec.number("final_value", summary: "The value after the change was applied.")
    static let percentageChange = ParameterSpec.number(
        "percentage_change",
        summary: "The change that was applied, in percent; negative for a decrease."
    )
    static let part = ParameterSpec.number("part", summary: "The portion.")
    static let total = ParameterSpec.number("total", summary: "The whole. Must not be zero.")
}

/// Percentages: shares, relative change, markups and discounts.
public struct PercentageModule: CalculationModule {
    /// Name of the module on the wire.
    public let name = ModuleName.percentage

    /// One-sentence description of what the module covers.
    public let summary = "Percentages: shares, relative change, markups and discounts."

    /// The operations the module offers, one per case of its operation enumeration.
    public let operations: [OperationDefinition]

    /// Creates the module.
    public init() {
        operations = PercentageOperation.allCases.map(Self.definition(for:))
    }

    private typealias P = PercentageParameters

    /// Maps every operation to its definition. The switch is exhaustive, so adding an operation without a
    /// definition does not compile.
    private static func definition(for operation: PercentageOperation) -> OperationDefinition {
        switch operation {
        case .percentageOf: percentageOf
        case .percentageChange: percentageChange
        case .percentageDifference: percentageDifference
        case .increaseByPercentage: increaseByPercentage
        case .decreaseByPercentage: decreaseByPercentage
        case .originalValue: originalValue
        case .percentageShare: percentageShare
        }
    }

    private static let percentageOf = OperationDefinition(
        name: PercentageOperation.percentageOf,
        summary: "Computes a percentage of a base value.",
        parameters: [P.percentage, P.base],
        result: .number,
        examples: [OperationExample("15% of 200.", with: [(P.percentage, 15), (P.base, 200)], yields: 30)],
        compute: { arguments in
            .number(try Percentage.of(arguments[P.percentage], base: arguments[P.base]))
        }
    )

    private static let percentageChange = OperationDefinition(
        name: PercentageOperation.percentageChange,
        summary: "Computes the relative change from an original to an updated value, in percent.",
        parameters: [P.originalValue, P.updatedValue],
        result: .number,
        examples: [
            OperationExample(
                "A rise from 80 to 100.",
                with: [(P.originalValue, 80), (P.updatedValue, 100)],
                yields: 25
            ),
            OperationExample(
                "A fall from 100 to 75.",
                with: [(P.originalValue, 100), (P.updatedValue, 75)],
                yields: -25
            ),
        ],
        compute: { arguments in
            .number(try Percentage.change(from: arguments[P.originalValue], to: arguments[P.updatedValue]))
        }
    )

    private static let percentageDifference = OperationDefinition(
        name: PercentageOperation.percentageDifference,
        summary: "Computes the symmetric difference of two values as a percentage of their average magnitude.",
        parameters: [P.first, P.second],
        result: .number,
        examples: [OperationExample("Between 90 and 110.", with: [(P.first, 90), (P.second, 110)], yields: 20)],
        compute: { arguments in
            .number(try Percentage.difference(between: arguments[P.first], and: arguments[P.second]))
        }
    )

    private static let increaseByPercentage = OperationDefinition(
        name: PercentageOperation.increaseByPercentage,
        summary: "Increases a value by a percentage of itself.",
        parameters: [P.value, P.percentage],
        result: .number,
        examples: [OperationExample("A 20% markup on 50.", with: [(P.value, 50), (P.percentage, 20)], yields: 60)],
        compute: { arguments in
            .number(try Percentage.increase(arguments[P.value], byPercentage: arguments[P.percentage]))
        }
    )

    private static let decreaseByPercentage = OperationDefinition(
        name: PercentageOperation.decreaseByPercentage,
        summary: "Decreases a value by a percentage of itself.",
        parameters: [P.value, P.percentage],
        result: .number,
        examples: [OperationExample("A 25% discount on 80.", with: [(P.value, 80), (P.percentage, 25)], yields: 60)],
        compute: { arguments in
            .number(try Percentage.decrease(arguments[P.value], byPercentage: arguments[P.percentage]))
        }
    )

    private static let originalValue = OperationDefinition(
        name: PercentageOperation.originalValue,
        summary: "Recovers the value a percentage change was applied to.",
        parameters: [P.finalValue, P.percentageChange],
        result: .number,
        examples: [
            OperationExample(
                "120 after a 20% increase was 100.",
                with: [(P.finalValue, 120), (P.percentageChange, 20)],
                yields: 100
            )
        ],
        compute: { arguments in
            .number(
                try Percentage.original(
                    fromFinal: arguments[P.finalValue],
                    afterChangeOf: arguments[P.percentageChange]
                )
            )
        }
    )

    private static let percentageShare = OperationDefinition(
        name: PercentageOperation.percentageShare,
        summary: "Expresses a part as a percentage of a total.",
        parameters: [P.part, P.total],
        result: .number,
        examples: [OperationExample("30 out of 120.", with: [(P.part, 30), (P.total, 120)], yields: 25)],
        compute: { arguments in
            .number(try Percentage.share(of: arguments[P.part], in: arguments[P.total]))
        }
    )
}

// swiftlint:enable no_magic_numbers
