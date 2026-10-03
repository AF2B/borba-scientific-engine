// Worked examples document an operation with concrete numbers; those literals are the data being documented.
// swiftlint:disable no_magic_numbers

extension ModuleName {
    /// Numerical integration, differentiation and root finding.
    public static let numerical = ModuleName("numerical")
}

/// Wire names of the numerical operations.
enum NumericalOperation: String, CaseIterable {
    case integrate
    case derivative
    case findRoot = "find_root"
}

/// Parameters of the numerical operations. Each name is spelled once, here.
enum NumericalParameters {
    private static let maximumVariableLength = 32

    static let expression = ParameterSpec.text(
        "expression",
        summary: "The function to work on, written in terms of the variable, such as x^2 - 2.",
        maximumLength: Tokenizer.maximumLength
    )
    static let variable = ParameterSpec.text(
        "variable",
        summary: "The name of the variable the function depends on.",
        maximumLength: maximumVariableLength,
        default: "x"
    )
    static let variables = ExpressionParameters.variables
    static let angleUnit = ExpressionParameters.angleUnit
    static let lower = ParameterSpec.number("lower", summary: "The start of the interval.")
    static let upper = ParameterSpec.number("upper", summary: "The end of the interval.")
    static let integrationMethod = ParameterSpec<IntegrationMethod>.choice(
        "method",
        summary: "The quadrature rule; simpson needs an even number of intervals.",
        default: .simpson
    )
    static let intervals = ParameterSpec.integer(
        "intervals",
        summary: "The number of subintervals; more is more accurate and slower.",
        range: 2...NumericalMethods.maximumIntervals,
        default: NumericalMethods.defaultIntervals
    )
    static let point = ParameterSpec.number("at", summary: "The point to differentiate at.")
    static let step = ParameterSpec.number(
        "step",
        summary: "The distance from the point to each sample of the central difference.",
        bounds: .positive,
        default: NumericalMethods.defaultStep
    )
    static let rootMethod = ParameterSpec<RootMethod>.choice(
        "method",
        summary: "The search strategy; bisection needs the function to change sign over the interval.",
        default: .bisection
    )
    static let tolerance = ParameterSpec.number(
        "tolerance",
        summary: "The accuracy of the root, in the units of the variable.",
        bounds: .positive,
        default: NumericalMethods.defaultTolerance
    )
    static let maximumIterations = ParameterSpec.integer(
        "max_iterations",
        summary: "The iteration budget of the search.",
        range: 1...NumericalMethods.maximumIterations,
        default: NumericalMethods.defaultIterations
    )
}

/// Numerical calculus on functions written as expressions: integrals, derivatives and roots.
public struct NumericalModule: CalculationModule {
    /// Name of the module on the wire.
    public let name = ModuleName.numerical

    /// One-sentence description of what the module covers.
    public let summary = "Numerical integration, differentiation and root finding for functions written as expressions."

    /// The operations the module offers, one per case of its operation enumeration.
    public let operations: [OperationDefinition]

    /// Creates the module.
    ///
    /// - Parameter compiler: Parses the expressions the operations work on.
    init(compiler: any ExpressionCompiling) {
        operations = NumericalOperation.allCases.map { Self.definition(for: $0, compiler: compiler) }
    }

    private typealias P = NumericalParameters

    /// Maps every operation to its definition. The switch is exhaustive, so adding an operation without a
    /// definition does not compile.
    private static func definition(
        for operation: NumericalOperation,
        compiler: any ExpressionCompiling
    ) -> OperationDefinition {
        switch operation {
        case .integrate: integrate(compiler: compiler)
        case .derivative: derivative(compiler: compiler)
        case .findRoot: findRoot(compiler: compiler)
        }
    }

    /// Compiles the expression of a request and binds it to its variable.
    private static func function(
        from arguments: Arguments,
        compiler: any ExpressionCompiling
    ) async throws -> UnivariateFunction {
        let variable = try arguments[P.variable]
        guard Tokenizer.isIdentifier(variable), !ExpressionVariables.reservedNames.contains(variable) else {
            throw CalculationError.invalidParameter(
                P.variable.name,
                reason: "must be a name that is not a built-in constant or function"
            )
        }

        let variables = try arguments[P.variables]
        guard variables[variable] == nil else {
            throw CalculationError.invalidParameter(
                P.variables.name,
                reason: "must not define '\(variable)', which is the variable of the function"
            )
        }

        let compiled = try await compiler.compile(arguments[P.expression])
        let context = try ExpressionVariables.context(from: variables, angleUnit: arguments[P.angleUnit])
        try ExpressionVariables.requireDefined(compiled.variableNames, among: Set(variables.keys).union([variable]))

        return UnivariateFunction(expression: compiled, context: context, variable: variable)
    }

    // MARK: - Integration

    private static let integrateExamples = [
        OperationExample(
            "The area under a parabola.",
            with: [(P.expression, "x^2"), (P.lower, 0), (P.upper, 3)],
            yields: ["value": 9, "intervals": 1_000]
        ),
        OperationExample(
            "One arch of the sine.",
            with: [(P.expression, "sin(x)"), (P.lower, 0), (P.upper, 3.141592653589793)],
            yields: ["value": 2, "intervals": 1_000]
        ),
    ]

    private static func integrate(compiler: any ExpressionCompiling) -> OperationDefinition {
        OperationDefinition(
            name: NumericalOperation.integrate,
            summary: "Approximates the definite integral of a function over an interval.",
            parameters: [
                P.expression, P.variable, P.variables, P.angleUnit, P.lower, P.upper, P.integrationMethod, P.intervals,
            ],
            result: .object([
                FieldShape("value", .number, "The approximate integral."),
                FieldShape("intervals", .number, "The number of subintervals used."),
            ]),
            examples: integrateExamples,
            compute: { arguments in
                let function = try await function(from: arguments, compiler: compiler)
                let method = try arguments[P.integrationMethod]
                let intervals = try arguments[P.intervals]
                guard method != .simpson || intervals.isMultiple(of: 2) else {
                    throw CalculationError.invalidParameter(
                        P.intervals.name,
                        reason: "must be even for the simpson method"
                    )
                }

                let value = try NumericalMethods.integrate(
                    function,
                    from: arguments[P.lower],
                    to: arguments[P.upper],
                    intervals: intervals,
                    method: method
                )
                return .fields(["value": .number(value), "intervals": .number(Double(intervals))])
            }
        )
    }

    // MARK: - Differentiation

    private static func derivative(compiler: any ExpressionCompiling) -> OperationDefinition {
        OperationDefinition(
            name: NumericalOperation.derivative,
            summary: "Approximates the derivative of a function at a point with a central difference.",
            parameters: [P.expression, P.variable, P.variables, P.angleUnit, P.point, P.step],
            result: .number,
            examples: [
                OperationExample(
                    "The slope of x cubed at 2.",
                    with: [(P.expression, "x^3"), (P.point, 2)],
                    yields: 12
                )
            ],
            compute: { arguments in
                let function = try await function(from: arguments, compiler: compiler)

                return .number(
                    try NumericalMethods.differentiate(function, at: arguments[P.point], step: arguments[P.step])
                )
            }
        )
    }

    // MARK: - Root finding

    private static let findRootExamples = [
        OperationExample(
            "The square root of two as a root of x^2 - 2.",
            with: [(P.expression, "x^2 - 2"), (P.lower, 0), (P.upper, 2)],
            yields: ["root": 1.4142135623730951, "iterations": 35, "residual": 0]
        ),
        OperationExample(
            "The fixed point of the cosine, by Newton's method.",
            with: [(P.expression, "cos(x) - x"), (P.lower, 0), (P.upper, 1), (P.rootMethod, "newton")],
            yields: ["root": 0.7390851332151607, "iterations": 5, "residual": 0]
        ),
    ]

    private static func findRoot(compiler: any ExpressionCompiling) -> OperationDefinition {
        OperationDefinition(
            name: NumericalOperation.findRoot,
            summary: "Finds a root of a function inside an interval.",
            parameters: [
                P.expression, P.variable, P.variables, P.angleUnit, P.lower, P.upper, P.rootMethod, P.tolerance,
                P.maximumIterations,
            ],
            result: .object([
                FieldShape("root", .number, "The approximate root."),
                FieldShape("iterations", .number, "The iterations spent."),
                FieldShape("residual", .number, "The value of the function at the root; close to zero."),
            ]),
            examples: findRootExamples,
            compute: { arguments in
                let function = try await function(from: arguments, compiler: compiler)
                let lower = try arguments[P.lower]
                let upper = try arguments[P.upper]
                guard lower < upper else {
                    throw CalculationError.invalidParameter(P.upper.name, reason: "must be greater than 'lower'")
                }

                let result = try NumericalMethods.findRoot(
                    of: function,
                    over: lower...upper,
                    method: arguments[P.rootMethod],
                    tolerance: arguments[P.tolerance],
                    maximumIterations: arguments[P.maximumIterations]
                )
                return .fields([
                    "root": .number(result.root),
                    "iterations": .number(Double(result.iterations)),
                    "residual": .number(result.residual),
                ])
            }
        )
    }
}

// swiftlint:enable no_magic_numbers
