import Foundation

/// Summary statistics of a set of measured durations.
///
/// Percentiles use the nearest-rank method: the p-th percentile is the smallest measurement that is greater than or
/// equal to p percent of all measurements. It always returns a value that was actually observed, which is what a latency
/// report should show: "99% of operations took at most this long".
public struct LatencyStatistics: Sendable, Equatable, Codable {
    /// How many measurements.
    public let count: Int

    /// The fastest measurement.
    public let minimum: Duration

    /// The slowest measurement.
    public let maximum: Duration

    /// The arithmetic mean.
    public let mean: Duration

    /// The median: half of the measurements were at most this long.
    public let p50: Duration

    /// 95% of the measurements were at most this long.
    public let p95: Duration

    /// 99% of the measurements were at most this long.
    public let p99: Duration

    /// The standard deviation of the measurements.
    public let standardDeviation: Duration

    /// Summarizes measurements.
    ///
    /// - Parameter samples: The measured durations. The initializer fails when there are none.
    public init?(samples: [Duration]) {
        guard !samples.isEmpty else {
            return nil
        }

        let sorted = samples.sorted()
        let nanoseconds = sorted.map(Self.nanoseconds)
        let mean = nanoseconds.reduce(0, +) / Double(nanoseconds.count)
        let variance = nanoseconds.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(nanoseconds.count)

        count = sorted.count
        minimum = sorted[0]
        maximum = sorted[sorted.count - 1]
        self.mean = Self.duration(nanoseconds: mean)
        p50 = Self.percentile(50, of: sorted)
        p95 = Self.percentile(95, of: sorted)
        p99 = Self.percentile(99, of: sorted)
        standardDeviation = Self.duration(nanoseconds: variance.squareRoot())
    }

    /// The nearest-rank percentile of sorted measurements.
    ///
    /// - Parameters:
    ///   - percentage: Between 0 and 100.
    ///   - sorted: The measurements, in ascending order; at least one.
    /// - Returns: The smallest measurement that is at least `percentage` percent of the way up the ranking.
    public static func percentile(
        _ percentage: Double,
        of sorted: [Duration]
    ) -> Duration {
        let rank = Int((percentage / percentageScale * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    private static let percentageScale = 100.0
    private static let nanosecondsPerSecond = 1_000_000_000.0
    private static let attosecondsPerNanosecond = 1_000_000_000.0

    /// A duration in nanoseconds.
    ///
    /// - Parameter duration: The duration.
    /// - Returns: The duration as a number of nanoseconds, with its fractional part.
    public static func nanoseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * nanosecondsPerSecond
            + Double(duration.components.attoseconds) / attosecondsPerNanosecond
    }

    /// A duration from nanoseconds.
    ///
    /// - Parameter nanoseconds: How many nanoseconds, with a fractional part.
    /// - Returns: The duration.
    public static func duration(nanoseconds: Double) -> Duration {
        .nanoseconds(Int64(nanoseconds.rounded()))
    }
}
