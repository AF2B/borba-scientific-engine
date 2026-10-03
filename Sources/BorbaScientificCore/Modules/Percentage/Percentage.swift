/// Percentage arithmetic with explicit failure modes.
///
/// A percentage is a ratio expressed per hundred. All functions are deterministic and free of side effects.
enum Percentage {
    /// The value that represents "one whole" when a ratio is written as a percentage.
    static let wholeInPercent = 100.0

    /// Computes a percentage of a base value.
    ///
    /// - Parameters:
    ///   - percentage: The percentage to take, such as `15` for fifteen percent.
    ///   - base: The value the percentage applies to.
    /// - Returns: `percentage` percent of `base`.
    static func of(
        _ percentage: Double,
        base: Double
    ) -> Double {
        base * percentage / wholeInPercent
    }

    /// Computes the relative change from one value to another, as a percentage of the original magnitude.
    ///
    /// - Parameters:
    ///   - original: The starting value.
    ///   - updated: The ending value.
    /// - Returns: The change in percent; positive when the value grew, negative when it shrank.
    /// - Throws: ``DivisionByZeroError`` when the original value is zero, because any change from zero is infinite.
    static func change(
        from original: Double,
        to updated: Double
    ) throws(DivisionByZeroError) -> Double {
        guard original != 0 else {
            throw DivisionByZeroError(operand: "original value")
        }
        return (updated - original) / abs(original) * wholeInPercent
    }

    /// Computes the symmetric difference between two values as a percentage of their average magnitude.
    ///
    /// Unlike ``change(from:to:)`` the result does not depend on which value is considered the original.
    ///
    /// - Parameters:
    ///   - first: One value.
    ///   - second: The other value.
    /// - Returns: The difference in percent, `0` when both values are zero.
    static func difference(
        between first: Double,
        and second: Double
    ) -> Double {
        let averageMagnitude = (abs(first) + abs(second)) / 2
        guard averageMagnitude != 0 else {
            return 0
        }
        return abs(first - second) / averageMagnitude * wholeInPercent
    }

    /// Increases a value by a percentage of itself.
    ///
    /// - Parameters:
    ///   - value: The starting value.
    ///   - percentage: The increase in percent.
    /// - Returns: The increased value.
    static func increase(
        _ value: Double,
        byPercentage percentage: Double
    ) -> Double {
        value + of(percentage, base: value)
    }

    /// Decreases a value by a percentage of itself.
    ///
    /// - Parameters:
    ///   - value: The starting value.
    ///   - percentage: The decrease in percent.
    /// - Returns: The decreased value.
    static func decrease(
        _ value: Double,
        byPercentage percentage: Double
    ) -> Double {
        value - of(percentage, base: value)
    }

    /// Recovers the value a percentage change was applied to.
    ///
    /// - Parameters:
    ///   - final: The value after the change.
    ///   - percentageChange: The change that was applied, negative for a decrease.
    /// - Returns: The value before the change.
    /// - Throws: ``DivisionByZeroError`` when the change is a hundred percent decrease, which leaves no information
    ///   about the original value.
    static func original(
        fromFinal final: Double,
        afterChangeOf percentageChange: Double
    ) throws(DivisionByZeroError) -> Double {
        let factor = 1 + percentageChange / wholeInPercent
        guard factor != 0 else {
            throw DivisionByZeroError(operand: "change factor")
        }
        return final / factor
    }

    /// Expresses a part as a percentage of a total.
    ///
    /// - Parameters:
    ///   - part: The portion.
    ///   - total: The whole.
    /// - Returns: The share in percent.
    /// - Throws: ``DivisionByZeroError`` when the total is zero.
    static func share(
        of part: Double,
        in total: Double
    ) throws(DivisionByZeroError) -> Double {
        guard total != 0 else {
            throw DivisionByZeroError(operand: "total")
        }
        return part / total * wholeInPercent
    }
}
