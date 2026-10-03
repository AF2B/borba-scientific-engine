import Foundation

/// The operand that made an arithmetic operation undefined.
enum ArithmeticOperand: String {
    case divisor
    case base
}

/// Failures of the arithmetic module.
enum ArithmeticError: Error, Sendable, Equatable {
    /// A division, modulo or negative power of zero.
    case divisionByZero(operand: ArithmeticOperand)

    /// A negative base raised to a non-integer exponent has no real result.
    case negativeBaseWithFractionalExponent

    /// An integer result is larger than the largest exactly representable integer.
    case integerOverflow
}

extension ArithmeticError: CalculationFailure {
    /// Maps each failure to its stable, user-facing representation.
    var calculationError: CalculationError {
        switch self {
        case .divisionByZero(let operand):
            .divisionByZero(DivisionByZeroError(operand: operand.rawValue))
        case .negativeBaseWithFractionalExponent:
            .undefined("A negative base has no real result when raised to a fractional exponent.")
        case .integerOverflow:
            .numericOverflow
        }
    }
}

/// How a number is rounded to a given number of decimal places.
enum RoundingStrategy: String, CaseIterable, Sendable {
    /// To the nearest value; ties go away from zero (commercial rounding).
    case nearestAway = "nearest_away"

    /// To the nearest value; ties go to the even neighbour (banker's rounding).
    case nearestEven = "nearest_even"

    /// Toward negative infinity.
    case floor

    /// Toward positive infinity.
    case ceiling

    /// Toward zero, discarding the excess digits.
    case towardZero = "toward_zero"
}

/// Pure arithmetic with explicit failure modes.
///
/// Every function is deterministic and free of side effects; where IEEE 754 would silently produce an infinity or a
/// NaN, these functions report why the operation is undefined.
enum Arithmetic {
    /// Largest integer such that every smaller integer is exactly representable as a `Double` (2^53).
    static let largestExactInteger = 9_007_199_254_740_992

    /// Largest argument whose factorial fits in a `Double`.
    static let largestFactorialArgument = 170

    /// Divides two numbers.
    ///
    /// - Parameters:
    ///   - dividend: The number to divide.
    ///   - divisor: The number to divide by.
    /// - Returns: The quotient.
    /// - Throws: ``ArithmeticError/divisionByZero(operand:)`` when the divisor is zero.
    static func divide(
        _ dividend: Double,
        by divisor: Double
    ) throws(ArithmeticError) -> Double {
        guard divisor != 0 else {
            throw .divisionByZero(operand: .divisor)
        }
        return dividend / divisor
    }

    /// Computes the remainder of a truncating division, which takes the sign of the dividend.
    ///
    /// - Parameters:
    ///   - dividend: The number to divide.
    ///   - divisor: The number to divide by.
    /// - Returns: The remainder.
    /// - Throws: ``ArithmeticError/divisionByZero(operand:)`` when the divisor is zero.
    static func remainder(
        of dividend: Double,
        dividedBy divisor: Double
    ) throws(ArithmeticError) -> Double {
        guard divisor != 0 else {
            throw .divisionByZero(operand: .divisor)
        }
        return dividend.truncatingRemainder(dividingBy: divisor)
    }

    /// Raises a number to a power.
    ///
    /// - Parameters:
    ///   - base: The number to raise.
    ///   - exponent: The power.
    /// - Returns: `base` to the power of `exponent`.
    /// - Throws: ``ArithmeticError/divisionByZero(operand:)`` for zero to a negative power, and
    ///   ``ArithmeticError/negativeBaseWithFractionalExponent`` for a negative base with a fractional exponent.
    static func power(
        of base: Double,
        raisedTo exponent: Double
    ) throws(ArithmeticError) -> Double {
        if base == 0, exponent < 0 {
            throw .divisionByZero(operand: .base)
        }
        if base < 0, exponent.rounded() != exponent {
            throw .negativeBaseWithFractionalExponent
        }
        return pow(base, exponent)
    }

    /// Adds numbers with compensated summation, so long lists do not accumulate rounding error.
    ///
    /// - Parameter values: The numbers to add.
    /// - Returns: Their sum.
    static func sum(of values: [Double]) -> Double {
        CompensatedSum.total(of: values)
    }

    /// Multiplies numbers.
    ///
    /// - Parameter values: The numbers to multiply.
    /// - Returns: Their product.
    static func product(of values: [Double]) -> Double {
        values.reduce(1, *)
    }

    /// Finds the largest integer that divides both numbers.
    ///
    /// - Parameters:
    ///   - first: One integer.
    ///   - second: Another integer.
    /// - Returns: The greatest common divisor, which is `0` only when both inputs are `0`.
    static func greatestCommonDivisor(
        _ first: Int,
        _ second: Int
    ) -> Int {
        var larger = first.magnitude
        var smaller = second.magnitude

        while smaller != 0 {
            (larger, smaller) = (smaller, larger % smaller)
        }
        return Int(larger)
    }

    /// Finds the smallest positive integer divisible by both numbers.
    ///
    /// - Parameters:
    ///   - first: One integer.
    ///   - second: Another integer.
    /// - Returns: The least common multiple, or `0` when either input is `0`.
    /// - Throws: ``ArithmeticError/integerOverflow`` when the result is not exactly representable.
    static func leastCommonMultiple(
        _ first: Int,
        _ second: Int
    ) throws(ArithmeticError) -> Int {
        guard first != 0, second != 0 else {
            return 0
        }

        let divisor = greatestCommonDivisor(first, second)
        let (multiple, overflowed) = (first.magnitude / UInt(divisor)).multipliedReportingOverflow(by: second.magnitude)
        guard !overflowed, multiple <= UInt(largestExactInteger) else {
            throw .integerOverflow
        }
        return Int(multiple)
    }

    /// Computes `n!`. Results are exact up to `18!` and correctly rounded beyond that.
    ///
    /// - Parameter number: A non-negative integer no larger than ``largestFactorialArgument``.
    /// - Returns: The factorial.
    static func factorial(of number: Int) -> Double {
        guard number > 1 else {
            return 1
        }
        return (2...number).reduce(1.0) { $0 * Double($1) }
    }

    /// Rounds a number to a number of decimal places using decimal arithmetic, so `2.675` rounds to `2.68`
    /// instead of being mis-rounded by its binary representation.
    ///
    /// - Parameters:
    ///   - value: The number to round.
    ///   - decimals: Decimal places to keep; negative values round to tens, hundreds and so on.
    ///   - strategy: How ties and excess digits are resolved.
    /// - Returns: The rounded number.
    static func rounded(
        _ value: Double,
        decimals: Int,
        strategy: RoundingStrategy
    ) -> Double {
        guard var decimal = Decimal(string: String(value), locale: nil) else {
            return value
        }

        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, decimals, mode(for: strategy, negative: value < 0))
        return rounded.nearestDouble
    }

    private static func mode(
        for strategy: RoundingStrategy,
        negative: Bool
    ) -> NSDecimalNumber.RoundingMode {
        switch strategy {
        case .nearestAway:
            .plain
        case .nearestEven:
            .bankers
        case .floor:
            .down
        case .ceiling:
            .up
        case .towardZero:
            negative ? .up : .down
        }
    }
}
