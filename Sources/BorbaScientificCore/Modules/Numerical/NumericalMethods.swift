/// How an integral is approximated.
enum IntegrationMethod: String, CaseIterable, Sendable {
    /// Joins the sampled points with straight lines; error shrinks with the square of the step.
    case trapezoid

    /// Joins triples of sampled points with parabolas; error shrinks with the fourth power of the step. Needs an even
    /// number of intervals.
    case simpson
}

/// How a root is searched for.
enum RootMethod: String, CaseIterable, Sendable {
    /// Halves an interval that is known to contain a root; slow but cannot fail once the interval brackets a root.
    case bisection

    /// Follows the tangent line from the middle of the interval; fast near a simple root, but may leave the interval.
    case newton
}

/// The result of a root search.
struct RootSearchResult: Sendable, Equatable {
    /// The approximate root.
    let root: Double

    /// How many iterations were spent.
    let iterations: Int

    /// The value of the function at the root; close to zero.
    let residual: Double
}

/// A real function of one variable, defined by an expression, that can be sampled at any point.
struct UnivariateFunction: Sendable {
    let expression: CompiledExpression
    let context: EvaluationContext
    let variable: String

    /// Evaluates the function.
    ///
    /// - Parameter point: The value of the variable.
    /// - Returns: The finite value of the function at that point.
    /// - Throws: ``CalculationError`` when the expression fails or is not finite at the point.
    func callAsFunction(_ point: Double) throws(CalculationError) -> Double {
        let value = try expression.evaluate(in: context.binding(variable, to: point))
        guard value.isFinite else {
            throw .undefined("The function is not finite at \(variable) = \(NumberFormatting.plain(point)).")
        }
        return value
    }
}

/// Numerical integration, differentiation and root finding.
///
/// Every loop checks for cancellation, so a request that exceeds its time budget stops promptly.
enum NumericalMethods {
    /// Most intervals an integration may use.
    static let maximumIntervals = 1_000_000

    /// Intervals used when the caller does not choose.
    static let defaultIntervals = 1_000

    /// Most iterations a root search may use.
    static let maximumIterations = 1_000

    /// Iterations used when the caller does not choose.
    static let defaultIterations = 100

    /// Absolute accuracy used when the caller does not choose.
    static let defaultTolerance = 1e-10

    /// Distance between the sample points of a numerical derivative when the caller does not choose.
    static let defaultStep = 1e-5

    private static let simpsonOddWeight = 4.0
    private static let simpsonEvenWeight = 2.0
    private static let simpsonDivisor = 3.0

    /// Approximates the definite integral of a function.
    ///
    /// - Parameters:
    ///   - function: The integrand.
    ///   - lower: The start of the interval.
    ///   - upper: The end of the interval; when smaller than `lower` the result is negated.
    ///   - intervals: The number of subintervals; must be even for Simpson's rule.
    ///   - method: The quadrature rule.
    /// - Returns: The approximate integral.
    /// - Throws: ``CalculationError`` when the function fails, is not finite somewhere on the interval or the task is
    ///   cancelled.
    static func integrate(
        _ function: UnivariateFunction,
        from lower: Double,
        to upper: Double,
        intervals: Int,
        method: IntegrationMethod
    ) throws(CalculationError) -> Double {
        let width = (upper - lower) / Double(intervals)
        var total = CompensatedSum()

        switch method {
        case .trapezoid:
            total.add(try function(lower) / 2)
            total.add(try function(upper) / 2)
            for index in 1..<intervals {
                try Cooperation.checkpoint(iteration: index)
                total.add(try function(lower + Double(index) * width))
            }
            return total.value * width
        case .simpson:
            total.add(try function(lower))
            total.add(try function(upper))
            for index in 1..<intervals {
                try Cooperation.checkpoint(iteration: index)
                let weight = index.isMultiple(of: 2) ? simpsonEvenWeight : simpsonOddWeight
                total.add(weight * (try function(lower + Double(index) * width)))
            }
            return total.value * width / simpsonDivisor
        }
    }

    /// Approximates the derivative of a function with a central difference.
    ///
    /// - Parameters:
    ///   - function: The function to differentiate.
    ///   - point: Where to differentiate.
    ///   - step: Distance from the point to each sample.
    /// - Returns: The approximate slope.
    /// - Throws: ``CalculationError`` when the function fails or is not finite near the point.
    static func differentiate(
        _ function: UnivariateFunction,
        at point: Double,
        step: Double
    ) throws(CalculationError) -> Double {
        (try function(point + step) - function(point - step)) / (2 * step)
    }

    /// Searches an interval for a root.
    ///
    /// - Parameters:
    ///   - function: The function whose root is sought.
    ///   - interval: The interval to search.
    ///   - method: The search strategy.
    ///   - tolerance: The accuracy of the root, in the units of the variable.
    ///   - maximumIterations: The iteration budget.
    /// - Returns: The root, how many iterations it took and the residual.
    /// - Throws: ``CalculationError`` when the interval does not bracket a root (bisection), the search does not
    ///   converge within the budget, the function fails, or the task is cancelled.
    static func findRoot(
        of function: UnivariateFunction,
        over interval: ClosedRange<Double>,
        method: RootMethod,
        tolerance: Double,
        maximumIterations: Int
    ) throws(CalculationError) -> RootSearchResult {
        switch method {
        case .bisection:
            try bisect(
                function,
                from: interval.lowerBound,
                to: interval.upperBound,
                tolerance: tolerance,
                maximumIterations: maximumIterations
            )
        case .newton:
            try newton(
                function,
                from: interval.lowerBound,
                to: interval.upperBound,
                tolerance: tolerance,
                maximumIterations: maximumIterations
            )
        }
    }

    private static func bisect(
        _ function: UnivariateFunction,
        from lower: Double,
        to upper: Double,
        tolerance: Double,
        maximumIterations: Int
    ) throws(CalculationError) -> RootSearchResult {
        var low = lower
        var high = upper
        var lowValue = try function(low)
        let highValue = try function(high)

        if lowValue == 0 {
            return RootSearchResult(root: low, iterations: 0, residual: 0)
        }
        if highValue == 0 {
            return RootSearchResult(root: high, iterations: 0, residual: 0)
        }
        guard lowValue.sign != highValue.sign else {
            throw .undefined("The interval does not bracket a root: the function has the same sign at both ends.")
        }

        for iteration in 1...maximumIterations {
            try Cooperation.checkpoint(iteration: iteration)
            let middle = low + (high - low) / 2
            let middleValue = try function(middle)

            if middleValue == 0 || (high - low) / 2 < tolerance {
                return RootSearchResult(root: middle, iterations: iteration, residual: middleValue)
            }
            if middleValue.sign == lowValue.sign {
                low = middle
                lowValue = middleValue
            } else {
                high = middle
            }
        }
        throw .didNotConverge(iterations: maximumIterations)
    }

    private static func newton(
        _ function: UnivariateFunction,
        from lower: Double,
        to upper: Double,
        tolerance: Double,
        maximumIterations: Int
    ) throws(CalculationError) -> RootSearchResult {
        var point = lower + (upper - lower) / 2

        for iteration in 1...maximumIterations {
            try Cooperation.checkpoint(iteration: iteration)
            let value = try function(point)
            if abs(value) < tolerance {
                return RootSearchResult(root: point, iterations: iteration, residual: value)
            }

            let slope = try differentiate(function, at: point, step: defaultStep)
            guard slope != 0 else {
                throw .didNotConverge(iterations: iteration)
            }

            let next = point - value / slope
            guard next >= lower, next <= upper else {
                throw .undefined("Newton's method left the interval; try bisection or a closer interval.")
            }
            if abs(next - point) < tolerance {
                return RootSearchResult(root: next, iterations: iteration, residual: try function(next))
            }
            point = next
        }
        throw .didNotConverge(iterations: maximumIterations)
    }
}
