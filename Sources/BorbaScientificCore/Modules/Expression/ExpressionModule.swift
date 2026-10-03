// Worked examples document an operation with concrete numbers; those literals are the data being documented.
// swiftlint:disable no_magic_numbers

extension ModuleName {
    /// Evaluation of mathematical expressions.
    public static let expression = ModuleName("expression")
}

/// Wire names of the expression operations.
enum ExpressionOperation: String, CaseIterable {
    case evaluate
}

/// Parameters of the expression operations. Each name is spelled once, here.
enum ExpressionParameters {
    /// Most variables a request may define.
    static let maximumVariables = 32

    static let expression = ParameterSpec.text(
        "expression",
        summary: "The expression to evaluate, such as 2 * (3 + x)^2 or sqrt(a^2 + b^2).",
        maximumLength: Tokenizer.maximumLength
    )
    static let variables = ParameterSpec.numberMap(
        "variables",
        summary: "Values for the variables the expression uses; names must not be constants or functions.",
        size: 0...maximumVariables,
        default: [:]
    )
    static let angleUnit = ParameterSpec<AngleUnit>.choice(
        "angle_unit",
        summary: "The unit of the angles trigonometric functions consume and produce.",
        default: .radians
    )
}

/// Validates the variables of a request and builds the context an expression is evaluated in.
enum ExpressionVariables {
    /// Names that cannot be used for variables: built-in constants and function names.
    static let reservedNames: Set<String> = Set(ExpressionConstant.allCases.map(\.rawValue))
        .union(ExpressionFunction.allCases.map(\.rawValue))

    /// Builds the evaluation context for a request.
    ///
    /// - Parameters:
    ///   - variables: The variable values supplied by the caller.
    ///   - angleUnit: The unit of trigonometric arguments and results.
    /// - Returns: The context.
    /// - Throws: ``CalculationError/validation(_:)`` for a name that is not a valid identifier or is reserved.
    static func context(
        from variables: [String: Double],
        angleUnit: AngleUnit
    ) throws(CalculationError) -> EvaluationContext {
        for name in variables.keys.sorted() {
            guard Tokenizer.isIdentifier(name) else {
                throw .invalidParameter(
                    ExpressionParameters.variables.name,
                    reason: "entry '\(name)' is not a valid variable name"
                )
            }
            guard !reservedNames.contains(name) else {
                throw .invalidParameter(
                    ExpressionParameters.variables.name,
                    reason: "entry '\(name)' is a built-in constant or function and cannot be redefined"
                )
            }
        }
        return EvaluationContext(variables: variables, angleUnit: angleUnit)
    }

    /// Checks that every variable an expression reads has a value.
    ///
    /// - Parameters:
    ///   - names: The variables the expression reads.
    ///   - defined: The names that have a value.
    /// - Throws: ``CalculationError/validation(_:)`` listing every undefined variable.
    static func requireDefined(
        _ names: Set<String>,
        among defined: Set<String>
    ) throws(CalculationError) {
        let missing = names.subtracting(defined).sorted()
        guard missing.isEmpty else {
            throw .invalidParameter(
                ExpressionParameters.variables.name,
                reason: "must define: \(missing.joined(separator: ", "))"
            )
        }
    }
}

/// Evaluates mathematical expressions with variables, constants and a library of functions.
public struct ExpressionModule: CalculationModule {
    /// Name of the module on the wire.
    public let name = ModuleName.expression

    /// One-sentence description of what the module covers.
    public let summary = "Evaluation of mathematical expressions with variables, constants and functions."

    /// The operations the module offers, one per case of its operation enumeration.
    public let operations: [OperationDefinition]

    /// Creates the module.
    ///
    /// - Parameter compiler: Parses expressions; a caching compiler makes repeated formulas cheaper.
    init(compiler: any ExpressionCompiling) {
        operations = ExpressionOperation.allCases.map { Self.definition(for: $0, compiler: compiler) }
    }

    private typealias P = ExpressionParameters

    /// Maps every operation to its definition. The switch is exhaustive, so adding an operation without a
    /// definition does not compile.
    private static func definition(
        for operation: ExpressionOperation,
        compiler: any ExpressionCompiling
    ) -> OperationDefinition {
        switch operation {
        case .evaluate: evaluate(compiler: compiler)
        }
    }

    private static let evaluateExamples = [
        OperationExample("Parentheses and precedence.", with: [(P.expression, "2 * (3 + 4)")], yields: 14),
        OperationExample(
            "Variables.",
            with: [(P.expression, "sqrt(x^2 + y^2)"), (P.variables, ["x": 3, "y": 4])],
            yields: 5
        ),
        OperationExample(
            "Unary minus binds looser than the power.",
            with: [(P.expression, "-2^2")],
            yields: -4
        ),
        OperationExample("Powers associate to the right.", with: [(P.expression, "2^3^2")], yields: 512),
        OperationExample("Remainder.", with: [(P.expression, "10 % 4")], yields: 2),
        OperationExample(
            "Functions of several arguments.",
            with: [(P.expression, "max(1, 5, 3) + min(4, 2)")],
            yields: 7
        ),
        OperationExample(
            "Trigonometry in degrees.",
            with: [(P.expression, "sin(30)"), (P.angleUnit, "degrees")],
            yields: 0.5
        ),
        OperationExample(
            "The area of a circle.",
            with: [(P.expression, "pi * r^2"), (P.variables, ["r": 2])],
            yields: 12.566370614359172
        ),
    ]

    private static func evaluate(compiler: any ExpressionCompiling) -> OperationDefinition {
        OperationDefinition(
            name: ExpressionOperation.evaluate,
            summary: "Evaluates an expression. Supports + - * / % ^, parentheses, the constants pi, e and tau, and "
                + "the functions sin, cos, tan, asin, acos, atan, atan2, sinh, cosh, tanh, sqrt, cbrt, exp, ln, "
                + "log, log2, abs, floor, ceil, round, trunc, sign, min, max, pow and hypot.",
            parameters: [P.expression, P.variables, P.angleUnit],
            result: .number,
            examples: evaluateExamples,
            compute: { arguments in
                let variables = try arguments[P.variables]
                let compiled = try await compiler.compile(arguments[P.expression])
                let context = try ExpressionVariables.context(from: variables, angleUnit: arguments[P.angleUnit])

                try ExpressionVariables.requireDefined(compiled.variableNames, among: Set(variables.keys))
                return .number(try compiled.evaluate(in: context))
            }
        )
    }
}

// swiftlint:enable no_magic_numbers
