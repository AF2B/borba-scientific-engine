import Foundation

/// A binary operator, in increasing order of precedence: additive, multiplicative, power.
enum BinaryOperator: Sendable, Equatable {
    case add
    case subtract
    case multiply
    case divide
    case remainder
    case power

    /// Applies the operator.
    ///
    /// - Parameters:
    ///   - lhs: The left operand.
    ///   - rhs: The right operand.
    /// - Returns: The result.
    /// - Throws: ``CalculationError`` for a division by zero or an undefined power.
    func apply(
        _ lhs: Double,
        _ rhs: Double
    ) throws(CalculationError) -> Double {
        do {
            switch self {
            case .add:
                return lhs + rhs
            case .subtract:
                return lhs - rhs
            case .multiply:
                return lhs * rhs
            case .divide:
                return try Arithmetic.divide(lhs, by: rhs)
            case .remainder:
                return try Arithmetic.remainder(of: lhs, dividedBy: rhs)
            case .power:
                return try Arithmetic.power(of: lhs, raisedTo: rhs)
            }
        } catch {
            throw error.calculationError
        }
    }
}

/// A mathematical constant that can be written by name in an expression.
enum ExpressionConstant: String, CaseIterable, Sendable {
    case pi
    case eulerNumber = "e"
    case tau

    /// The value of the constant.
    var value: Double {
        switch self {
        case .pi:
            .pi
        case .eulerNumber:
            M_E
        case .tau:
            2 * .pi
        }
    }
}

/// How many arguments a function accepts.
enum Arity: Sendable, Equatable {
    case exactly(Int)
    case atLeast(Int)

    /// Whether a number of arguments is acceptable.
    ///
    /// - Parameter count: The number of arguments supplied.
    /// - Returns: `true` when the function accepts that many arguments.
    func accepts(_ count: Int) -> Bool {
        switch self {
        case .exactly(let required):
            count == required
        case .atLeast(let minimum):
            count >= minimum
        }
    }

    /// A phrase such as "2 arguments" for error messages.
    var description: String {
        switch self {
        case .exactly(let required):
            "\(required) argument\(required == 1 ? "" : "s")"
        case .atLeast(let minimum):
            "at least \(minimum) argument\(minimum == 1 ? "" : "s")"
        }
    }
}

/// A function that can be called by name in an expression.
enum ExpressionFunction: String, CaseIterable, Sendable {
    case sin
    case cos
    case tan
    case asin
    case acos
    case atan
    case atan2
    case sinh
    case cosh
    case tanh
    case sqrt
    case cbrt
    case exp
    case ln
    case log
    case log2
    case abs
    case floor
    case ceil
    case round
    case trunc
    case sign
    case min
    case max
    case pow
    case hypot

    /// The number of arguments the function takes.
    var arity: Arity {
        switch self {
        case .atan2, .pow, .hypot:
            .exactly(2)
        case .min, .max:
            .atLeast(1)
        case .sin, .cos, .tan, .asin, .acos, .atan, .sinh, .cosh, .tanh, .sqrt, .cbrt, .exp, .ln, .log, .log2, .abs,
            .floor, .ceil, .round, .trunc, .sign:
            .exactly(1)
        }
    }

    /// Calls the function.
    ///
    /// - Parameters:
    ///   - arguments: The evaluated arguments; their number was checked against ``arity`` when the expression was
    ///     parsed.
    ///   - angleUnit: The unit of the angles consumed or produced by trigonometric functions.
    /// - Returns: The result.
    /// - Throws: ``CalculationError`` when the arguments are outside the function's domain.
    func apply(
        to arguments: [Double],
        angleUnit: AngleUnit
    ) throws(CalculationError) -> Double {
        guard arity.accepts(arguments.count), let first = arguments.first else {
            throw .internalFailure(reason: "Function \(rawValue) called with \(arguments.count) arguments")
        }

        switch self {
        case .sin: return Scientific.sine(first, in: angleUnit)
        case .cos: return Scientific.cosine(first, in: angleUnit)
        case .tan: return try Self.tangent(first, in: angleUnit)
        case .asin: return try Self.arcsine(first, in: angleUnit)
        case .acos: return try Self.arccosine(first, in: angleUnit)
        case .atan: return angleUnit.fromRadians(Foundation.atan(first))
        case .atan2: return try Self.arctangent(y: first, x: arguments[1], in: angleUnit)
        case .sinh: return Foundation.sinh(first)
        case .cosh: return Foundation.cosh(first)
        case .tanh: return Foundation.tanh(first)
        case .sqrt: return try Self.squareRoot(first)
        case .cbrt: return Foundation.cbrt(first)
        case .exp: return Foundation.exp(first)
        case .ln: return try Self.logarithm(first, using: Foundation.log)
        case .log: return try Self.logarithm(first, using: Foundation.log10)
        case .log2: return try Self.logarithm(first, using: Foundation.log2)
        case .abs: return Swift.abs(first)
        case .floor: return first.rounded(.down)
        case .ceil: return first.rounded(.up)
        case .round: return first.rounded()
        case .trunc: return first.rounded(.towardZero)
        case .sign: return Self.sign(of: first)
        case .min: return arguments.reduce(first) { Swift.min($0, $1) }
        case .max: return arguments.reduce(first) { Swift.max($0, $1) }
        case .pow: return try BinaryOperator.power.apply(first, arguments[1])
        case .hypot: return Foundation.hypot(first, arguments[1])
        }
    }

    private static func tangent(
        _ angle: Double,
        in unit: AngleUnit
    ) throws(CalculationError) -> Double {
        do {
            return try Scientific.tangent(angle, in: unit)
        } catch {
            throw error.calculationError
        }
    }

    private static func arctangent(
        y: Double,
        x: Double,
        in unit: AngleUnit
    ) throws(CalculationError) -> Double {
        do {
            return try Scientific.arctangent(y: y, x: x, in: unit)
        } catch {
            throw error.calculationError
        }
    }

    private static func arcsine(
        _ value: Double,
        in unit: AngleUnit
    ) throws(CalculationError) -> Double {
        guard Swift.abs(value) <= 1 else {
            throw .undefined("The arcsine is defined only from -1 to 1.")
        }
        return unit.fromRadians(Foundation.asin(value))
    }

    private static func arccosine(
        _ value: Double,
        in unit: AngleUnit
    ) throws(CalculationError) -> Double {
        guard Swift.abs(value) <= 1 else {
            throw .undefined("The arccosine is defined only from -1 to 1.")
        }
        return unit.fromRadians(Foundation.acos(value))
    }

    private static func squareRoot(_ value: Double) throws(CalculationError) -> Double {
        guard value >= 0 else {
            throw .undefined("The square root is undefined for negative numbers.")
        }
        return value.squareRoot()
    }

    private static func logarithm(
        _ value: Double,
        using function: (Double) -> Double
    ) throws(CalculationError) -> Double {
        guard value > 0 else {
            throw .undefined("A logarithm is undefined for zero and negative numbers.")
        }
        return function(value)
    }

    private static func sign(of value: Double) -> Double {
        if value.isZero {
            return 0
        }
        return value > 0 ? 1 : -1
    }
}

/// The syntax tree of a parsed expression.
indirect enum ExpressionNode: Sendable, Equatable {
    case number(Double)
    case variable(name: String, position: Int)
    case negate(ExpressionNode)
    case binary(BinaryOperator, ExpressionNode, ExpressionNode)
    case call(ExpressionFunction, [ExpressionNode])

    /// The names of the variables the expression reads, excluding built-in constants.
    var variableNames: Set<String> {
        switch self {
        case .number:
            []
        case .variable(let name, _):
            ExpressionConstant(rawValue: name) == nil ? [name] : []
        case .negate(let operand):
            operand.variableNames
        case .binary(_, let lhs, let rhs):
            lhs.variableNames.union(rhs.variableNames)
        case .call(_, let arguments):
            arguments.reduce(into: Set<String>()) { $0.formUnion($1.variableNames) }
        }
    }
}
