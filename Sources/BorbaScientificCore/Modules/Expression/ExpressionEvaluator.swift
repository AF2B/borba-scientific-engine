/// The values an expression is evaluated against.
struct EvaluationContext: Sendable {
    /// Variables that keep the same value throughout an evaluation.
    let variables: [String: Double]

    /// The unit of the angles consumed or produced by trigonometric functions.
    let angleUnit: AngleUnit

    private let free: (name: String, value: Double)?

    /// Creates a context.
    ///
    /// - Parameters:
    ///   - variables: Named values, such as the constants of a formula.
    ///   - angleUnit: The unit of trigonometric arguments and results.
    init(
        variables: [String: Double] = [:],
        angleUnit: AngleUnit = .radians
    ) {
        self.variables = variables
        self.angleUnit = angleUnit
        self.free = nil
    }

    private init(
        variables: [String: Double],
        angleUnit: AngleUnit,
        free: (name: String, value: Double)
    ) {
        self.variables = variables
        self.angleUnit = angleUnit
        self.free = free
    }

    /// Returns a context in which one variable has a given value.
    ///
    /// Numerical methods evaluate the same expression thousands of times with a changing variable; binding it this
    /// way avoids rebuilding a dictionary for every evaluation.
    ///
    /// - Parameters:
    ///   - name: The variable to bind.
    ///   - value: Its value.
    /// - Returns: A copy of this context with the variable bound.
    func binding(
        _ name: String,
        to value: Double
    ) -> EvaluationContext {
        EvaluationContext(variables: variables, angleUnit: angleUnit, free: (name, value))
    }

    /// Looks up a constant or a variable.
    ///
    /// - Parameter name: The identifier used in the expression.
    /// - Returns: Its value.
    /// - Throws: ``CalculationError`` when the name is neither a built-in constant nor a bound variable.
    func value(of name: String) throws(CalculationError) -> Double {
        if let free, free.name == name {
            return free.value
        }
        if let value = variables[name] {
            return value
        }
        if let constant = ExpressionConstant(rawValue: name) {
            return constant.value
        }
        throw .invalidParameter(ExpressionParameters.expression.name, reason: "uses the undefined variable '\(name)'")
    }
}

extension ExpressionNode {
    /// Evaluates the expression.
    ///
    /// - Parameter context: The values of the variables and the angle unit.
    /// - Returns: The numeric result, which may be infinite or NaN; the engine rejects such results at its boundary.
    /// - Throws: ``CalculationError`` for a division by zero, a value outside a function's domain or an undefined
    ///   variable.
    func evaluate(in context: EvaluationContext) throws(CalculationError) -> Double {
        switch self {
        case .number(let value):
            return value
        case .variable(let name, _):
            return try context.value(of: name)
        case .negate(let operand):
            return -(try operand.evaluate(in: context))
        case .binary(let binaryOperator, let lhs, let rhs):
            let left = try lhs.evaluate(in: context)
            let right = try rhs.evaluate(in: context)
            return try binaryOperator.apply(left, right)
        case .call(let function, let arguments):
            let values = try arguments.map { (node) throws(CalculationError) in try node.evaluate(in: context) }
            return try function.apply(to: values, angleUnit: context.angleUnit)
        }
    }
}
