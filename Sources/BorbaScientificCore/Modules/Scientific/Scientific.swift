import Foundation

/// The unit an angle is measured in.
enum AngleUnit: String, CaseIterable, Sendable {
    case radians
    case degrees

    /// Degrees in half a turn, the ratio between the two units.
    private static let degreesInHalfTurn = 180.0

    /// Converts an angle in this unit to radians.
    ///
    /// - Parameter angle: The angle to convert.
    /// - Returns: The angle in radians.
    func toRadians(_ angle: Double) -> Double {
        switch self {
        case .radians:
            angle
        case .degrees:
            angle * .pi / Self.degreesInHalfTurn
        }
    }

    /// Converts an angle in radians to this unit.
    ///
    /// - Parameter radians: The angle in radians.
    /// - Returns: The angle in this unit.
    func fromRadians(_ radians: Double) -> Double {
        switch self {
        case .radians:
            radians
        case .degrees:
            radians * Self.degreesInHalfTurn / .pi
        }
    }
}

/// Failures of the scientific module.
enum ScientificError: Error, Sendable, Equatable {
    /// The tangent has no value at odd multiples of a quarter turn.
    case tangentUndefined

    /// A logarithm to base one is undefined.
    case logarithmBaseOne

    /// An even root of a negative number has no real value.
    case evenRootOfNegative(degree: Int)

    /// Both arguments of the two-argument arctangent are zero, so the direction is undefined.
    case arctangentOfOrigin

    /// More items were selected than are available.
    case selectionLargerThanPopulation(selected: Int, population: Int)
}

extension ScientificError: CalculationFailure {
    /// Maps each failure to its stable, user-facing representation.
    var calculationError: CalculationError {
        switch self {
        case .tangentUndefined:
            .undefined("The tangent is undefined at odd multiples of a quarter turn.")
        case .logarithmBaseOne:
            .invalidParameter(
                ScientificParameters.base.name,
                reason: "must not be 1, because a logarithm to base 1 is undefined"
            )
        case .evenRootOfNegative(let degree):
            .undefined("A negative number has no real root of even degree \(degree).")
        case .arctangentOfOrigin:
            .undefined("The direction of the origin is undefined: y and x must not both be zero.")
        case .selectionLargerThanPopulation(let selected, let population):
            .invalidParameter(
                ScientificParameters.selected.name,
                reason: "must not exceed n (\(selected) of \(population) requested)"
            )
        }
    }
}

/// Elementary functions and combinatorics with explicit domains.
enum Scientific {
    /// The tangent is reported as undefined where the cosine is closer to zero than this.
    static let tangentSingularityTolerance = 1e-15

    /// Largest population size accepted by the combinatorial functions.
    static let largestPopulation = 1_000

    /// Sine of an angle.
    ///
    /// - Parameters:
    ///   - angle: The angle.
    ///   - unit: The unit the angle is measured in.
    /// - Returns: The sine.
    static func sine(
        _ angle: Double,
        in unit: AngleUnit
    ) -> Double {
        sin(unit.toRadians(angle))
    }

    /// Cosine of an angle.
    ///
    /// - Parameters:
    ///   - angle: The angle.
    ///   - unit: The unit the angle is measured in.
    /// - Returns: The cosine.
    static func cosine(
        _ angle: Double,
        in unit: AngleUnit
    ) -> Double {
        cos(unit.toRadians(angle))
    }

    /// Tangent of an angle.
    ///
    /// - Parameters:
    ///   - angle: The angle.
    ///   - unit: The unit the angle is measured in.
    /// - Returns: The tangent.
    /// - Throws: ``ScientificError/tangentUndefined`` at odd multiples of a quarter turn.
    static func tangent(
        _ angle: Double,
        in unit: AngleUnit
    ) throws(ScientificError) -> Double {
        let radians = unit.toRadians(angle)
        guard abs(cos(radians)) > tangentSingularityTolerance else {
            throw .tangentUndefined
        }
        return tan(radians)
    }

    /// The angle whose tangent is `y / x`, resolving the quadrant from the signs of both arguments.
    ///
    /// - Parameters:
    ///   - y: The vertical component.
    ///   - x: The horizontal component.
    ///   - unit: The unit the result is expressed in.
    /// - Returns: The angle, from a negative half turn to a positive half turn.
    /// - Throws: ``ScientificError/arctangentOfOrigin`` when both components are zero.
    static func arctangent(
        y: Double,
        x: Double,
        in unit: AngleUnit
    ) throws(ScientificError) -> Double {
        guard x != 0 || y != 0 else {
            throw .arctangentOfOrigin
        }
        return unit.fromRadians(atan2(y, x))
    }

    /// Logarithm of a positive number to a positive base other than one.
    ///
    /// - Parameters:
    ///   - value: The number, which must be positive.
    ///   - base: The base, which must be positive.
    /// - Returns: The power the base must be raised to in order to obtain the value.
    /// - Throws: ``ScientificError/logarithmBaseOne`` when the base is one.
    static func logarithm(
        of value: Double,
        base: Double
    ) throws(ScientificError) -> Double {
        guard base != 1 else {
            throw .logarithmBaseOne
        }
        return log(value) / log(base)
    }

    /// The real root of a given degree.
    ///
    /// - Parameters:
    ///   - value: The radicand; may be negative only for an odd degree.
    ///   - degree: The degree of the root, two or more.
    /// - Returns: The real root.
    /// - Throws: ``ScientificError/evenRootOfNegative(degree:)`` for an even root of a negative number.
    static func root(
        of value: Double,
        degree: Int
    ) throws(ScientificError) -> Double {
        if value >= 0 {
            return pow(value, 1 / Double(degree))
        }
        guard !degree.isMultiple(of: 2) else {
            throw .evenRootOfNegative(degree: degree)
        }
        return -pow(-value, 1 / Double(degree))
    }

    /// The number of ways to choose `selected` items from `population` when order does not matter.
    ///
    /// - Parameters:
    ///   - population: The number of available items.
    ///   - selected: The number of items to choose.
    /// - Returns: The binomial coefficient.
    /// - Throws: ``ScientificError/selectionLargerThanPopulation(selected:population:)`` when `selected` exceeds
    ///   `population`.
    static func combinations(
        of population: Int,
        choosing selected: Int
    ) throws(ScientificError) -> Double {
        guard selected <= population else {
            throw .selectionLargerThanPopulation(selected: selected, population: population)
        }

        let smaller = min(selected, population - selected)
        return (0..<smaller).reduce(1.0) { result, index in
            result * Double(population - index) / Double(index + 1)
        }
    }

    /// The number of ways to arrange `selected` items out of `population` when order matters.
    ///
    /// - Parameters:
    ///   - population: The number of available items.
    ///   - selected: The number of items to arrange.
    /// - Returns: The number of permutations.
    /// - Throws: ``ScientificError/selectionLargerThanPopulation(selected:population:)`` when `selected` exceeds
    ///   `population`.
    static func permutations(
        of population: Int,
        choosing selected: Int
    ) throws(ScientificError) -> Double {
        guard selected <= population else {
            throw .selectionLargerThanPopulation(selected: selected, population: population)
        }
        return (0..<selected).reduce(1.0) { $0 * Double(population - $1) }
    }
}
