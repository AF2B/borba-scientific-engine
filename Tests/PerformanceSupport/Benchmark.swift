import Foundation

/// The outcome of one benchmark.
public struct BenchmarkResult: Sendable, Equatable, Codable {
    /// What was measured, such as `POST /api/v1/calculations`.
    public let name: String

    /// The family it belongs to, such as `api`, `engine` or `database`.
    public let group: String

    /// How many operations ran concurrently at most.
    public let concurrency: Int

    /// How long the whole run took, from the first operation starting to the last one finishing.
    public let wallTime: Duration

    /// The latency of every operation.
    public let latency: LatencyStatistics

    /// Operations completed per second of wall time: the throughput, which under concurrency is more than one over the
    /// mean latency.
    public var operationsPerSecond: Double {
        Double(latency.count) / (LatencyStatistics.nanoseconds(wallTime) / LatencyStatistics.nanosecondsPerSecondValue)
    }

    enum CodingKeys: String, CodingKey {
        case name
        case group
        case concurrency
        case wallTime = "wall_time"
        case latency
    }
}

extension LatencyStatistics {
    /// Nanoseconds in a second, for converting throughput.
    public static let nanosecondsPerSecondValue = 1_000_000_000.0
}

/// Runs an operation many times and measures how long each run takes.
public enum Benchmark {
    /// Measures an operation.
    ///
    /// Warm-up runs happen first and are discarded, so caches, lazy initialisation and code paging do not distort the
    /// measurements. The measured runs then execute with at most `concurrency` in flight; each is timed on its own
    /// monotonic clock reading, so the latency is what a caller experienced, queueing included.
    ///
    /// - Parameters:
    ///   - name: What is measured.
    ///   - group: The family of the benchmark.
    ///   - warmup: How many runs to discard first.
    ///   - iterations: How many runs to measure.
    ///   - concurrency: How many runs may be in flight at once.
    ///   - operation: The work. It receives the number of the run, starting at 0.
    /// - Returns: The result.
    /// - Throws: Whatever the operation throws; a failing operation is not a benchmark.
    public static func run(
        _ name: String,
        group: String,
        warmup: Int,
        iterations: Int,
        concurrency: Int = 1,
        operation: @escaping @Sendable (Int) async throws -> Void
    ) async throws -> BenchmarkResult {
        for index in 0..<warmup {
            try await operation(-index - 1)
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        let samples = try await measureAll(iterations, concurrency: concurrency, clock: clock, operation: operation)
        let wallTime = clock.now - startedAt

        guard let latency = LatencyStatistics(samples: samples) else {
            throw BenchmarkError.noIterations(name)
        }
        return BenchmarkResult(
            name: name,
            group: group,
            concurrency: concurrency,
            wallTime: wallTime,
            latency: latency
        )
    }

    private static func measureAll(
        _ iterations: Int,
        concurrency: Int,
        clock: ContinuousClock,
        operation: @escaping @Sendable (Int) async throws -> Void
    ) async throws -> [Duration] {
        try await withThrowingTaskGroup(of: Duration.self) { group in
            var samples: [Duration] = []
            samples.reserveCapacity(iterations)
            var next = 0

            func start() {
                let index = next
                next += 1
                group.addTask {
                    let startedAt = clock.now
                    try await operation(index)
                    return clock.now - startedAt
                }
            }

            while next < min(max(concurrency, 1), iterations) {
                start()
            }
            while let sample = try await group.next() {
                samples.append(sample)
                if next < iterations {
                    start()
                }
            }
            return samples
        }
    }
}

/// Why a benchmark could not produce a result.
public enum BenchmarkError: Error, Equatable {
    /// The benchmark was asked to run zero iterations.
    case noIterations(String)
}
