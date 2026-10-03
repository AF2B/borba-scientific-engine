// Worked examples document an operation with concrete numbers; those literals are the data being documented.
// swiftlint:disable no_magic_numbers

extension ModuleName {
    /// Basic arithmetic.
    public static let arithmetic = ModuleName("arithmetic")
}

/// Wire names of the arithmetic operations.
enum ArithmeticOperation: String, CaseIterable {
    case add
    case subtract
    case multiply
    case divide
    case modulo
    case power
    case sum
    case product
    case absolute
    case greatestCommonDivisor = "greatest_common_divisor"
    case leastCommonMultiple = "least_common_multiple"
    case factorial
    case round
}

/// Parameters of the arithmetic operations. Each name is spelled once, here.
enum ArithmeticParameters {
    static let firstOperand = ParameterSpec.number("a", summary: "Left operand.")
    static let secondOperand = ParameterSpec.number("b", summary: "Right operand.")
    static let value = ParameterSpec.number("value", summary: "The number to operate on.")
    static let dividend = ParameterSpec.number("dividend", summary: "The number to divide.")
    static let divisor = ParameterSpec.number("divisor", summary: "The number to divide by. Must not be zero.")
    static let base = ParameterSpec.number("base", summary: "The number to raise.")
    static let exponent = ParameterSpec.number("exponent", summary: "The power to raise the base to.")
    static let values = ParameterSpec.numberList("values", summary: "The numbers to aggregate.")

    private static let exactIntegers = -Arithmetic.largestExactInteger...Arithmetic.largestExactInteger
    static let firstInteger = ParameterSpec.integer("a", summary: "First integer.", range: exactIntegers)
    static let secondInteger = ParameterSpec.integer("b", summary: "Second integer.", range: exactIntegers)
    static let factorialArgument = ParameterSpec.integer(
        "n",
        summary: "The non-negative integer whose factorial is computed.",
        range: 0...Arithmetic.largestFactorialArgument
    )

    private static let decimalPlaces = -15...15
    static let decimals = ParameterSpec.integer(
        "decimals",
        summary: "Decimal places to keep; negative values round to tens, hundreds and so on.",
        range: decimalPlaces,
        default: 0
    )
    static let strategy = ParameterSpec<RoundingStrategy>.choice(
        "strategy",
        summary: "How ties and excess digits are resolved.",
        default: .nearestAway
    )
}

/// Basic arithmetic: the four operators, remainders, powers, aggregates, divisibility and rounding.
public struct ArithmeticModule: CalculationModule {
    /// Name of the module on the wire.
    public let name = ModuleName.arithmetic

    /// One-sentence description of what the module covers.
    public let summary = "Basic arithmetic: operators, aggregates, divisibility and rounding."

    /// The operations the module offers, one per case of its operation enumeration.
    public let operations: [OperationDefinition]

    /// Creates the module.
    public init() {
        operations = ArithmeticOperation.allCases.map(Self.definition(for:))
    }

    private typealias P = ArithmeticParameters

    /// Maps every operation to its definition. The switch is exhaustive, so adding an operation without a
    /// definition does not compile.
    private static func definition(for operation: ArithmeticOperation) -> OperationDefinition {
        switch operation {
        case .add: add
        case .subtract: subtract
        case .multiply: multiply
        case .divide: divide
        case .modulo: modulo
        case .power: power
        case .sum: sum
        case .product: product
        case .absolute: absolute
        case .greatestCommonDivisor: greatestCommonDivisor
        case .leastCommonMultiple: leastCommonMultiple
        case .factorial: factorial
        case .round: round
        }
    }

    private static let add = OperationDefinition(
        name: ArithmeticOperation.add,
        summary: "Adds two numbers.",
        parameters: [P.firstOperand, P.secondOperand],
        result: .number,
        examples: [
            OperationExample("Adds two integers.", with: [(P.firstOperand, 2), (P.secondOperand, 3)], yields: 5)
        ],
        compute: { arguments in
            .number(try arguments[P.firstOperand] + arguments[P.secondOperand])
        }
    )

    private static let subtract = OperationDefinition(
        name: ArithmeticOperation.subtract,
        summary: "Subtracts the right operand from the left one.",
        parameters: [P.firstOperand, P.secondOperand],
        result: .number,
        examples: [
            OperationExample("Subtracts two integers.", with: [(P.firstOperand, 10), (P.secondOperand, 4)], yields: 6)
        ],
        compute: { arguments in
            .number(try arguments[P.firstOperand] - arguments[P.secondOperand])
        }
    )

    private static let multiply = OperationDefinition(
        name: ArithmeticOperation.multiply,
        summary: "Multiplies two numbers.",
        parameters: [P.firstOperand, P.secondOperand],
        result: .number,
        examples: [
            OperationExample(
                "Multiplies two decimals.",
                with: [(P.firstOperand, 1.5), (P.secondOperand, 4)],
                yields: 6
            )
        ],
        compute: { arguments in
            .number(try arguments[P.firstOperand] * arguments[P.secondOperand])
        }
    )

    private static let divide = OperationDefinition(
        name: ArithmeticOperation.divide,
        summary: "Divides the dividend by the divisor.",
        parameters: [P.dividend, P.divisor],
        result: .number,
        examples: [OperationExample("Divides two integers.", with: [(P.dividend, 7), (P.divisor, 2)], yields: 3.5)],
        compute: { arguments in
            .number(try Arithmetic.divide(arguments[P.dividend], by: arguments[P.divisor]))
        }
    )

    private static let modulo = OperationDefinition(
        name: ArithmeticOperation.modulo,
        summary: "Computes the remainder of a truncating division; the result takes the sign of the dividend.",
        parameters: [P.dividend, P.divisor],
        result: .number,
        examples: [
            OperationExample("Remainder of 7 divided by 3.", with: [(P.dividend, 7), (P.divisor, 3)], yields: 1),
            OperationExample("The sign follows the dividend.", with: [(P.dividend, -7), (P.divisor, 3)], yields: -1),
        ],
        compute: { arguments in
            .number(try Arithmetic.remainder(of: arguments[P.dividend], dividedBy: arguments[P.divisor]))
        }
    )

    private static let power = OperationDefinition(
        name: ArithmeticOperation.power,
        summary: "Raises the base to the exponent.",
        parameters: [P.base, P.exponent],
        result: .number,
        examples: [
            OperationExample("Two to the tenth.", with: [(P.base, 2), (P.exponent, 10)], yields: 1_024),
            OperationExample(
                "A negative exponent gives a fraction.",
                with: [(P.base, 2), (P.exponent, -2)],
                yields: 0.25
            ),
        ],
        compute: { arguments in
            .number(try Arithmetic.power(of: arguments[P.base], raisedTo: arguments[P.exponent]))
        }
    )

    private static let sum = OperationDefinition(
        name: ArithmeticOperation.sum,
        summary: "Adds a list of numbers using compensated summation, which keeps long lists accurate.",
        parameters: [P.values],
        result: .number,
        examples: [OperationExample("Sums three decimals.", with: [(P.values, [0.1, 0.2, 0.3])], yields: 0.6)],
        compute: { arguments in
            .number(Arithmetic.sum(of: try arguments[P.values]))
        }
    )

    private static let product = OperationDefinition(
        name: ArithmeticOperation.product,
        summary: "Multiplies a list of numbers.",
        parameters: [P.values],
        result: .number,
        examples: [OperationExample("Multiplies four integers.", with: [(P.values, [1, 2, 3, 4])], yields: 24)],
        compute: { arguments in
            .number(Arithmetic.product(of: try arguments[P.values]))
        }
    )

    private static let absolute = OperationDefinition(
        name: ArithmeticOperation.absolute,
        summary: "Returns the magnitude of a number.",
        parameters: [P.value],
        result: .number,
        examples: [OperationExample("Absolute value of a negative number.", with: [(P.value, -3.5)], yields: 3.5)],
        compute: { arguments in
            .number(try abs(arguments[P.value]))
        }
    )

    private static let greatestCommonDivisor = OperationDefinition(
        name: ArithmeticOperation.greatestCommonDivisor,
        summary: "Finds the largest integer that divides both numbers.",
        parameters: [P.firstInteger, P.secondInteger],
        result: .number,
        examples: [
            OperationExample("GCD of 48 and 18.", with: [(P.firstInteger, 48), (P.secondInteger, 18)], yields: 6)
        ],
        compute: { arguments in
            .number(
                Double(Arithmetic.greatestCommonDivisor(try arguments[P.firstInteger], try arguments[P.secondInteger]))
            )
        }
    )

    private static let leastCommonMultiple = OperationDefinition(
        name: ArithmeticOperation.leastCommonMultiple,
        summary: "Finds the smallest positive integer divisible by both numbers.",
        parameters: [P.firstInteger, P.secondInteger],
        result: .number,
        examples: [OperationExample("LCM of 4 and 6.", with: [(P.firstInteger, 4), (P.secondInteger, 6)], yields: 12)],
        compute: { arguments in
            .number(Double(try Arithmetic.leastCommonMultiple(arguments[P.firstInteger], arguments[P.secondInteger])))
        }
    )

    private static let factorial = OperationDefinition(
        name: ArithmeticOperation.factorial,
        summary: "Computes n factorial. Exact up to 18! and correctly rounded up to 170!.",
        parameters: [P.factorialArgument],
        result: .number,
        examples: [OperationExample("Five factorial.", with: [(P.factorialArgument, 5)], yields: 120)],
        compute: { arguments in
            .number(Arithmetic.factorial(of: try arguments[P.factorialArgument]))
        }
    )

    private static let round = OperationDefinition(
        name: ArithmeticOperation.round,
        summary: "Rounds a number to a number of decimal places using decimal arithmetic.",
        parameters: [P.value, P.decimals, P.strategy],
        result: .number,
        examples: [
            OperationExample(
                "Commercial rounding of a binary-ambiguous value.",
                with: [(P.value, 2.675), (P.decimals, 2)],
                yields: 2.68
            ),
            OperationExample(
                "Banker's rounding sends ties to the even neighbour.",
                with: [(P.value, 2.5), (P.strategy, "nearest_even")],
                yields: 2
            ),
        ],
        compute: { arguments in
            .number(
                Arithmetic.rounded(
                    try arguments[P.value],
                    decimals: try arguments[P.decimals],
                    strategy: try arguments[P.strategy]
                )
            )
        }
    )
}

// swiftlint:enable no_magic_numbers
