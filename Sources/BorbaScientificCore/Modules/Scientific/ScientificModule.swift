// Worked examples document an operation with concrete numbers; those literals are the data being documented.
// swiftlint:disable no_magic_numbers

import Foundation

extension ModuleName {
    /// Trigonometry, logarithms, roots, combinatorics and physical constants.
    public static let scientific = ModuleName("scientific")
}

/// Wire names of the scientific operations.
enum ScientificOperation: String, CaseIterable {
    case sine
    case cosine
    case tangent
    case arcsine
    case arccosine
    case arctangent
    case arctangent2
    case hyperbolicSine = "hyperbolic_sine"
    case hyperbolicCosine = "hyperbolic_cosine"
    case hyperbolicTangent = "hyperbolic_tangent"
    case exponential
    case naturalLogarithm = "natural_logarithm"
    case logarithm
    case squareRoot = "square_root"
    case cubeRoot = "cube_root"
    case nthRoot = "nth_root"
    case combinations
    case permutations
    case physicalConstant = "physical_constant"
}

/// Parameters of the scientific operations. Each name is spelled once, here.
enum ScientificParameters {
    static let angle = ParameterSpec.number("angle", summary: "The angle, in the given unit.")
    static let unit = ParameterSpec<AngleUnit>.choice(
        "unit",
        summary: "The unit angles are measured in.",
        default: .radians
    )
    static let value = ParameterSpec.number("value", summary: "The number to operate on.")
    static let sineValue = ParameterSpec.number(
        "value",
        summary: "A number from -1 to 1.",
        bounds: .between(-1, 1)
    )
    static let positiveValue = ParameterSpec.number(
        "value",
        summary: "A positive number.",
        bounds: .positive
    )
    static let nonNegativeValue = ParameterSpec.number(
        "value",
        summary: "A number that is zero or greater.",
        bounds: .nonNegative
    )
    static let y = ParameterSpec.number("y", summary: "The vertical component.")
    static let x = ParameterSpec.number("x", summary: "The horizontal component.")
    static let base = ParameterSpec.number(
        "base",
        summary: "The base of the logarithm: positive and different from 1.",
        bounds: .positive,
        default: 10
    )
    static let degree = ParameterSpec.integer(
        "degree",
        summary: "The degree of the root, two or more.",
        range: 2...100
    )
    static let population = ParameterSpec.integer(
        "n",
        summary: "The number of available items.",
        range: 0...Scientific.largestPopulation
    )
    static let selected = ParameterSpec.integer(
        "k",
        summary: "The number of items to choose; must not exceed n.",
        range: 0...Scientific.largestPopulation
    )
    static let constant = ParameterSpec<PhysicalConstant>.choice(
        "constant",
        summary: "The constant to look up."
    )
}

/// Trigonometry, hyperbolic functions, exponentials, logarithms, roots, combinatorics and physical constants.
public struct ScientificModule: CalculationModule {
    /// Name of the module on the wire.
    public let name = ModuleName.scientific

    /// One-sentence description of what the module covers.
    public let summary = "Trigonometry, logarithms, roots, combinatorics and physical constants."

    /// The operations the module offers, one per case of its operation enumeration.
    public let operations: [OperationDefinition]

    /// Creates the module.
    public init() {
        operations = ScientificOperation.allCases.map(Self.definition(for:))
    }

    private typealias P = ScientificParameters

    /// Maps every operation to its definition. The switch is exhaustive, so adding an operation without a
    /// definition does not compile.
    private static func definition(for operation: ScientificOperation) -> OperationDefinition {
        switch operation {
        case .sine: sine
        case .cosine: cosine
        case .tangent: tangent
        case .arcsine: arcsine
        case .arccosine: arccosine
        case .arctangent: arctangent
        case .arctangent2: arctangent2
        case .hyperbolicSine: hyperbolicSine
        case .hyperbolicCosine: hyperbolicCosine
        case .hyperbolicTangent: hyperbolicTangent
        case .exponential: exponential
        case .naturalLogarithm: naturalLogarithm
        case .logarithm: logarithm
        case .squareRoot: squareRoot
        case .cubeRoot: cubeRoot
        case .nthRoot: nthRoot
        case .combinations: combinations
        case .permutations: permutations
        case .physicalConstant: physicalConstant
        }
    }

    /// Defines an operation that maps one number to one number.
    private static func unary(
        _ name: ScientificOperation,
        summary: String,
        parameters: [any ParameterDeclaration],
        example: OperationExample,
        compute: @escaping @Sendable (Arguments) throws -> Double
    ) -> OperationDefinition {
        OperationDefinition(
            name: name,
            summary: summary,
            parameters: parameters,
            result: .number,
            examples: [example],
            compute: { arguments in .number(try compute(arguments)) }
        )
    }

    private static let sine = unary(
        .sine,
        summary: "Computes the sine of an angle.",
        parameters: [P.angle, P.unit],
        example: OperationExample("The sine of 30 degrees.", with: [(P.angle, 30), (P.unit, "degrees")], yields: 0.5),
        compute: { Scientific.sine(try $0[P.angle], in: try $0[P.unit]) }
    )

    private static let cosine = unary(
        .cosine,
        summary: "Computes the cosine of an angle.",
        parameters: [P.angle, P.unit],
        example: OperationExample(
            "The cosine of 60 degrees.",
            with: [(P.angle, 60), (P.unit, "degrees")],
            yields: 0.5
        ),
        compute: { Scientific.cosine(try $0[P.angle], in: try $0[P.unit]) }
    )

    private static let tangent = unary(
        .tangent,
        summary: "Computes the tangent of an angle; undefined at odd multiples of a quarter turn.",
        parameters: [P.angle, P.unit],
        example: OperationExample("The tangent of 45 degrees.", with: [(P.angle, 45), (P.unit, "degrees")], yields: 1),
        compute: { try Scientific.tangent($0[P.angle], in: $0[P.unit]) }
    )

    private static let arcsine = unary(
        .arcsine,
        summary: "Computes the angle whose sine is the given number.",
        parameters: [P.sineValue, P.unit],
        example: OperationExample(
            "The angle whose sine is 0.5.",
            with: [(P.sineValue, 0.5), (P.unit, "degrees")],
            yields: 30
        ),
        compute: { try $0[P.unit].fromRadians(asin($0[P.sineValue])) }
    )

    private static let arccosine = unary(
        .arccosine,
        summary: "Computes the angle whose cosine is the given number.",
        parameters: [P.sineValue, P.unit],
        example: OperationExample(
            "The angle whose cosine is 0.",
            with: [(P.sineValue, 0), (P.unit, "degrees")],
            yields: 90
        ),
        compute: { try $0[P.unit].fromRadians(acos($0[P.sineValue])) }
    )

    private static let arctangent = unary(
        .arctangent,
        summary: "Computes the angle whose tangent is the given number.",
        parameters: [P.value, P.unit],
        example: OperationExample(
            "The angle whose tangent is 1.",
            with: [(P.value, 1), (P.unit, "degrees")],
            yields: 45
        ),
        compute: { try $0[P.unit].fromRadians(atan($0[P.value])) }
    )

    private static let arctangent2 = unary(
        .arctangent2,
        summary: "Computes the direction of the point (x, y), resolving the quadrant from both signs.",
        parameters: [P.y, P.x, P.unit],
        example: OperationExample(
            "The direction of a point in the second quadrant.",
            with: [(P.y, 1), (P.x, -1), (P.unit, "degrees")],
            yields: 135
        ),
        compute: { try Scientific.arctangent(y: $0[P.y], x: $0[P.x], in: $0[P.unit]) }
    )

    private static let hyperbolicSine = unary(
        .hyperbolicSine,
        summary: "Computes the hyperbolic sine.",
        parameters: [P.value],
        example: OperationExample("sinh(1).", with: [(P.value, 1)], yields: 1.1752011936438014),
        compute: { sinh(try $0[P.value]) }
    )

    private static let hyperbolicCosine = unary(
        .hyperbolicCosine,
        summary: "Computes the hyperbolic cosine.",
        parameters: [P.value],
        example: OperationExample("cosh(1).", with: [(P.value, 1)], yields: 1.5430806348152437),
        compute: { cosh(try $0[P.value]) }
    )

    private static let hyperbolicTangent = unary(
        .hyperbolicTangent,
        summary: "Computes the hyperbolic tangent.",
        parameters: [P.value],
        example: OperationExample("tanh(1).", with: [(P.value, 1)], yields: 0.7615941559557649),
        compute: { tanh(try $0[P.value]) }
    )

    private static let exponential = unary(
        .exponential,
        summary: "Computes e raised to a power.",
        parameters: [P.value],
        example: OperationExample("e to the first power.", with: [(P.value, 1)], yields: 2.718281828459045),
        compute: { exp(try $0[P.value]) }
    )

    private static let naturalLogarithm = unary(
        .naturalLogarithm,
        summary: "Computes the natural logarithm of a positive number.",
        parameters: [P.positiveValue],
        example: OperationExample("ln(e).", with: [(P.positiveValue, 2.718281828459045)], yields: 1),
        compute: { log(try $0[P.positiveValue]) }
    )

    private static let logarithm = unary(
        .logarithm,
        summary: "Computes the logarithm of a positive number to a given base, 10 by default.",
        parameters: [P.positiveValue, P.base],
        example: OperationExample("log base 2 of 8.", with: [(P.positiveValue, 8), (P.base, 2)], yields: 3),
        compute: { try Scientific.logarithm(of: $0[P.positiveValue], base: $0[P.base]) }
    )

    private static let squareRoot = unary(
        .squareRoot,
        summary: "Computes the square root of a non-negative number.",
        parameters: [P.nonNegativeValue],
        example: OperationExample("The square root of 144.", with: [(P.nonNegativeValue, 144)], yields: 12),
        compute: { try $0[P.nonNegativeValue].squareRoot() }
    )

    private static let cubeRoot = unary(
        .cubeRoot,
        summary: "Computes the real cube root of a number.",
        parameters: [P.value],
        example: OperationExample("The cube root of -27.", with: [(P.value, -27)], yields: -3),
        compute: { cbrt(try $0[P.value]) }
    )

    private static let nthRoot = unary(
        .nthRoot,
        summary: "Computes the real root of a given degree; negative numbers have roots of odd degree only.",
        parameters: [P.value, P.degree],
        example: OperationExample("The fifth root of 32.", with: [(P.value, 32), (P.degree, 5)], yields: 2),
        compute: { try Scientific.root(of: $0[P.value], degree: $0[P.degree]) }
    )

    private static let combinations = unary(
        .combinations,
        summary: "Counts the ways to choose k items from n when order does not matter.",
        parameters: [P.population, P.selected],
        example: OperationExample("Choosing 2 of 5.", with: [(P.population, 5), (P.selected, 2)], yields: 10),
        compute: { try Scientific.combinations(of: $0[P.population], choosing: $0[P.selected]) }
    )

    private static let permutations = unary(
        .permutations,
        summary: "Counts the ways to arrange k items out of n when order matters.",
        parameters: [P.population, P.selected],
        example: OperationExample("Arranging 2 of 5.", with: [(P.population, 5), (P.selected, 2)], yields: 20),
        compute: { try Scientific.permutations(of: $0[P.population], choosing: $0[P.selected]) }
    )

    private static let physicalConstant = OperationDefinition(
        name: ScientificOperation.physicalConstant,
        summary: "Looks up a fundamental physical constant with its unit and uncertainty.",
        parameters: [P.constant],
        result: .object([
            FieldShape("value", .number, "The value in SI units."),
            FieldShape("unit", .text, "The SI unit of the value."),
            FieldShape("uncertainty", .number, "The standard uncertainty in the same unit; zero for exact values."),
            FieldShape("source", .text, "Where the value comes from."),
        ]),
        examples: [
            OperationExample(
                "The speed of light.",
                with: [(P.constant, "speed_of_light")],
                yields: [
                    "value": 299_792_458,
                    "unit": "m/s",
                    "uncertainty": 0,
                    "source": "SI definition (exact)",
                ]
            )
        ],
        compute: { arguments in
            let definition = try arguments[P.constant].definition
            return .fields([
                "value": .number(definition.value),
                "unit": .text(definition.unit),
                "uncertainty": .number(definition.uncertainty),
                "source": .text(definition.source),
            ])
        }
    )
}

// swiftlint:enable no_magic_numbers
