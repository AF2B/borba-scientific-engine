/// Renders numbers the way a person would write them in an error message.
enum NumberFormatting {
    /// Largest magnitude below which every whole number is exactly representable as a `Double` (2^53).
    private static let exactIntegerLimit = 9_007_199_254_740_992.0

    /// Formats a number without a spurious fractional part: `5.0` becomes `5`, `0.25` stays `0.25`.
    ///
    /// - Parameter value: The number to format.
    /// - Returns: A compact decimal representation.
    static func plain(_ value: Double) -> String {
        guard value.rounded() == value, abs(value) < exactIntegerLimit else {
            return String(value)
        }
        return String(Int64(value))
    }
}

/// An optional lower and upper limit for a number, each either inclusive or exclusive.
public struct NumberBounds: Sendable, Equatable {
    /// One end of the interval.
    public struct Limit: Sendable, Equatable {
        /// The limit value.
        public let value: Double

        /// Whether the limit value itself is accepted.
        public let isInclusive: Bool
    }

    /// Smallest accepted value, when there is one.
    public let lower: Limit?

    /// Largest accepted value, when there is one.
    public let upper: Limit?

    /// Any finite number is accepted.
    public static let unbounded = NumberBounds(lower: nil, upper: nil)

    /// Strictly greater than zero.
    public static let positive = greaterThan(0)

    /// Zero or greater.
    public static let nonNegative = atLeast(0)

    /// Accepts values greater than or equal to a limit.
    ///
    /// - Parameter limit: Smallest accepted value.
    /// - Returns: The bounds.
    public static func atLeast(_ limit: Double) -> NumberBounds {
        NumberBounds(lower: Limit(value: limit, isInclusive: true), upper: nil)
    }

    /// Accepts values strictly greater than a limit.
    ///
    /// - Parameter limit: Value that must be exceeded.
    /// - Returns: The bounds.
    public static func greaterThan(_ limit: Double) -> NumberBounds {
        NumberBounds(lower: Limit(value: limit, isInclusive: false), upper: nil)
    }

    /// Accepts values less than or equal to a limit.
    ///
    /// - Parameter limit: Largest accepted value.
    /// - Returns: The bounds.
    public static func atMost(_ limit: Double) -> NumberBounds {
        NumberBounds(lower: nil, upper: Limit(value: limit, isInclusive: true))
    }

    /// Accepts values strictly less than a limit.
    ///
    /// - Parameter limit: Value that must not be reached.
    /// - Returns: The bounds.
    public static func lessThan(_ limit: Double) -> NumberBounds {
        NumberBounds(lower: nil, upper: Limit(value: limit, isInclusive: false))
    }

    /// Accepts values between two inclusive limits.
    ///
    /// - Parameters:
    ///   - lower: Smallest accepted value.
    ///   - upper: Largest accepted value.
    /// - Returns: The bounds.
    public static func between(
        _ lower: Double,
        _ upper: Double
    ) -> NumberBounds {
        NumberBounds(
            lower: Limit(value: lower, isInclusive: true),
            upper: Limit(value: upper, isInclusive: true)
        )
    }

    /// Accepts values above an exclusive lower limit up to an inclusive upper limit.
    ///
    /// - Parameters:
    ///   - lower: Value that must be exceeded.
    ///   - upper: Largest accepted value.
    /// - Returns: The bounds.
    public static func greaterThan(
        _ lower: Double,
        upTo upper: Double
    ) -> NumberBounds {
        NumberBounds(
            lower: Limit(value: lower, isInclusive: false),
            upper: Limit(value: upper, isInclusive: true)
        )
    }

    /// Checks a value against the bounds.
    ///
    /// - Parameter value: The value to check.
    /// - Returns: The value itself when it is within bounds.
    /// - Throws: ``ParameterRejection`` describing the violated bound.
    func validated(_ value: Double) throws(ParameterRejection) -> Double {
        if let lower, !(lower.isInclusive ? value >= lower.value : value > lower.value) {
            throw ParameterRejection(reason: lowerReason(lower))
        }
        if let upper, !(upper.isInclusive ? value <= upper.value : value < upper.value) {
            throw ParameterRejection(reason: upperReason(upper))
        }
        return value
    }

    private func lowerReason(_ limit: Limit) -> String {
        let comparison = limit.isInclusive ? "at least" : "greater than"
        return "must be \(comparison) \(NumberFormatting.plain(limit.value))"
    }

    private func upperReason(_ limit: Limit) -> String {
        let comparison = limit.isInclusive ? "at most" : "less than"
        return "must be \(comparison) \(NumberFormatting.plain(limit.value))"
    }
}
