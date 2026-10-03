/// Which divisor a variance, covariance or standard deviation uses.
enum VarianceKind: String, CaseIterable, Sendable {
    /// Divides by `n`: the observations are the whole population.
    case population

    /// Divides by `n - 1` (Bessel's correction): the observations are a sample of a larger population.
    case sample
}

/// The percentile each quartile sits at.
private enum QuartileRank: Double {
    case first = 25
    case second = 50
    case third = 75
}

/// The quartiles of a sample and the spread between the outer two.
struct Quartiles: Sendable, Equatable {
    let first: Double
    let median: Double
    let third: Double

    /// The distance between the third and the first quartile.
    var interquartileRange: Double {
        third - first
    }
}

/// A non-empty collection of finite observations and the descriptive statistics that can be derived from it.
///
/// The invariant — at least one observation — is established once at construction, so the statistics below never
/// have to handle an empty collection.
struct Sample: Sendable, Equatable {
    /// Observations needed before a sample statistic (which divides by `n - 1`) is defined.
    static let minimumObservationsForSampleStatistics = 2

    /// The observations in their original order.
    let values: [Double]

    /// Creates a sample.
    ///
    /// - Parameter values: The observations; must not be empty.
    /// - Throws: ``StatisticsError/emptySample`` when there are no observations.
    init(_ values: [Double]) throws(StatisticsError) {
        guard !values.isEmpty else {
            throw .emptySample
        }
        self.values = values
    }

    /// Number of observations.
    var count: Int {
        values.count
    }

    /// Sum of the observations, accumulated with compensation so long samples stay accurate.
    var sum: Double {
        CompensatedSum.total(of: values)
    }

    /// Arithmetic mean.
    var mean: Double {
        sum / Double(count)
    }

    /// Smallest observation.
    var minimum: Double {
        values.reduce(into: values[0]) { $0 = Swift.min($0, $1) }
    }

    /// Largest observation.
    var maximum: Double {
        values.reduce(into: values[0]) { $0 = Swift.max($0, $1) }
    }

    /// Distance between the largest and the smallest observation.
    var range: Double {
        maximum - minimum
    }

    /// The middle observation, or the midpoint of the two middle ones for an even count.
    var median: Double {
        Self.percentile(of: sorted, percent: QuartileRank.second.rawValue)
    }

    /// The most frequent observations in ascending order. Empty when no value occurs more than once, because a
    /// sample in which every value is unique has no meaningful mode.
    var modes: [Double] {
        let frequencies = values.reduce(into: [Double: Int]()) { $0[$1, default: 0] += 1 }

        guard let highest = frequencies.values.max(), highest > 1 else {
            return []
        }
        return frequencies.filter { $0.value == highest }.keys.sorted()
    }

    /// Population or sample variance, computed in one pass with Welford's algorithm, which avoids the
    /// catastrophic cancellation of the textbook "mean of squares minus square of mean" formula.
    ///
    /// - Parameter kind: Which divisor to use.
    /// - Returns: The variance.
    /// - Throws: ``StatisticsError/insufficientObservations(required:actual:)`` for a sample variance of a single
    ///   observation.
    func variance(kind: VarianceKind) throws(StatisticsError) -> Double {
        let degreesOfFreedom = try degreesOfFreedom(for: kind)

        var runningMean = 0.0
        var sumOfSquaredDeviations = 0.0
        for (index, value) in values.enumerated() {
            let delta = value - runningMean
            runningMean += delta / Double(index + 1)
            sumOfSquaredDeviations += delta * (value - runningMean)
        }
        return sumOfSquaredDeviations / Double(degreesOfFreedom)
    }

    /// Population or sample standard deviation.
    ///
    /// - Parameter kind: Which divisor to use.
    /// - Returns: The square root of the variance.
    /// - Throws: ``StatisticsError/insufficientObservations(required:actual:)`` for a sample standard deviation of a
    ///   single observation.
    func standardDeviation(kind: VarianceKind) throws(StatisticsError) -> Double {
        try variance(kind: kind).squareRoot()
    }

    /// The value below which a given percentage of the observations fall, interpolating linearly between the
    /// two nearest ranks (the method used by Excel's `PERCENTILE.INC` and NumPy's default).
    ///
    /// - Parameter percent: A percentage from 0 to 100 inclusive.
    /// - Returns: The interpolated observation.
    func percentile(_ percent: Double) -> Double {
        Self.percentile(of: sorted, percent: percent)
    }

    /// The first, second and third quartiles.
    var quartiles: Quartiles {
        let sorted = sorted
        return Quartiles(
            first: Self.percentile(of: sorted, percent: QuartileRank.first.rawValue),
            median: Self.percentile(of: sorted, percent: QuartileRank.second.rawValue),
            third: Self.percentile(of: sorted, percent: QuartileRank.third.rawValue)
        )
    }

    private var sorted: [Double] {
        values.sorted()
    }

    private func degreesOfFreedom(for kind: VarianceKind) throws(StatisticsError) -> Int {
        switch kind {
        case .population:
            return count
        case .sample:
            guard count >= Self.minimumObservationsForSampleStatistics else {
                throw .insufficientObservations(required: Self.minimumObservationsForSampleStatistics, actual: count)
            }
            return count - 1
        }
    }

    private static func percentile(
        of sorted: [Double],
        percent: Double
    ) -> Double {
        let rank = percent / Percentage.wholeInPercent * Double(sorted.count - 1)
        let lowerIndex = Int(rank.rounded(.down))
        let upperIndex = Swift.min(lowerIndex + 1, sorted.count - 1)
        let weight = rank - Double(lowerIndex)

        return sorted[lowerIndex] + weight * (sorted[upperIndex] - sorted[lowerIndex])
    }
}

/// The result of fitting a straight line `y = slope * x + intercept` by least squares.
struct LinearRegression: Sendable, Equatable {
    /// Change in `y` per unit of `x`.
    let slope: Double

    /// Value of `y` where the line crosses `x = 0`.
    let intercept: Double

    /// Share of the variance of `y` explained by the line, from 0 to 1.
    let rSquared: Double
}

/// Sums of squared deviations from the mean and of their cross products for a pair of samples.
private struct DeviationSums {
    let xSquares: Double
    let ySquares: Double
    let crossProducts: Double
}

/// Two samples of equal size whose observations correspond one to one.
struct PairedSample: Sendable, Equatable {
    /// The independent variable.
    let x: Sample

    /// The dependent variable.
    let y: Sample

    /// Creates a paired sample.
    ///
    /// - Parameters:
    ///   - x: Observations of the independent variable.
    ///   - y: Observations of the dependent variable.
    /// - Throws: ``StatisticsError/lengthMismatch(first:second:)`` when the sizes differ and
    ///   ``StatisticsError/emptySample`` when there are no observations.
    init(
        x: [Double],
        y: [Double]
    ) throws(StatisticsError) {
        guard x.count == y.count else {
            throw .lengthMismatch(first: x.count, second: y.count)
        }
        self.x = try Sample(x)
        self.y = try Sample(y)
    }

    /// Population or sample covariance.
    ///
    /// - Parameter kind: Which divisor to use.
    /// - Returns: The covariance of the two variables.
    /// - Throws: ``StatisticsError/insufficientObservations(required:actual:)`` for a sample covariance of a single
    ///   pair.
    func covariance(kind: VarianceKind) throws(StatisticsError) -> Double {
        let degreesOfFreedom: Int
        switch kind {
        case .population:
            degreesOfFreedom = x.count
        case .sample:
            guard x.count >= Sample.minimumObservationsForSampleStatistics else {
                throw .insufficientObservations(
                    required: Sample.minimumObservationsForSampleStatistics,
                    actual: x.count
                )
            }
            degreesOfFreedom = x.count - 1
        }
        return sums.crossProducts / Double(degreesOfFreedom)
    }

    /// Pearson's correlation coefficient.
    ///
    /// - Returns: A value from -1 to 1.
    /// - Throws: ``StatisticsError/zeroVariance`` when either variable is constant.
    func correlation() throws(StatisticsError) -> Double {
        let sums = sums
        guard sums.xSquares > 0, sums.ySquares > 0 else {
            throw .zeroVariance
        }
        return sums.crossProducts / (sums.xSquares * sums.ySquares).squareRoot()
    }

    /// The least-squares line through the points.
    ///
    /// - Returns: Slope, intercept and coefficient of determination.
    /// - Throws: ``StatisticsError/zeroVariance`` when `x` is constant, because the slope is then undefined.
    func linearRegression() throws(StatisticsError) -> LinearRegression {
        let sums = sums
        guard sums.xSquares > 0 else {
            throw .zeroVariance
        }

        let slope = sums.crossProducts / sums.xSquares
        let rSquared = sums.ySquares > 0 ? sums.crossProducts * sums.crossProducts / (sums.xSquares * sums.ySquares) : 1

        return LinearRegression(slope: slope, intercept: y.mean - slope * x.mean, rSquared: rSquared)
    }

    /// Sums of squared deviations and of cross products, the building blocks of every statistic above.
    private var sums: DeviationSums {
        let xMean = x.mean
        let yMean = y.mean

        var xSquares = CompensatedSum()
        var ySquares = CompensatedSum()
        var crossProducts = CompensatedSum()
        for (xValue, yValue) in zip(x.values, y.values) {
            let xDeviation = xValue - xMean
            let yDeviation = yValue - yMean
            xSquares.add(xDeviation * xDeviation)
            ySquares.add(yDeviation * yDeviation)
            crossProducts.add(xDeviation * yDeviation)
        }
        return DeviationSums(xSquares: xSquares.value, ySquares: ySquares.value, crossProducts: crossProducts.value)
    }
}
