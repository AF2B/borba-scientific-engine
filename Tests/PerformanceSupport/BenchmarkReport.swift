import Foundation

/// A set of benchmark results, which can be printed for a person and written for a machine.
public struct BenchmarkReport: Sendable, Codable {
    /// Where and how the benchmarks ran, because numbers mean nothing without it.
    public struct Environment: Sendable, Codable, Equatable {
        /// `debug` or `release`: debug builds are many times slower and are only good for catching crashes.
        public let configuration: String

        /// The number of logical processors.
        public let processors: Int

        /// The operating system.
        public let operatingSystem: String

        /// When the report was produced, ISO 8601.
        public let generatedAt: String

        enum CodingKeys: String, CodingKey {
            case configuration
            case processors
            case operatingSystem = "operating_system"
            case generatedAt = "generated_at"
        }

        /// The environment of the running process.
        public static var current: Environment {
            #if DEBUG
                let configuration = "debug"
            #else
                let configuration = "release"
            #endif

            return Environment(
                configuration: configuration,
                processors: ProcessInfo.processInfo.activeProcessorCount,
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                generatedAt: Date().formatted(.iso8601)
            )
        }
    }

    /// Where and how the benchmarks ran.
    public let environment: Environment

    /// The results, in the order they were measured.
    public let results: [BenchmarkResult]

    /// Creates a report.
    ///
    /// - Parameter results: The results.
    public init(results: [BenchmarkResult]) {
        environment = .current
        self.results = results
    }

    /// The report as a table of text.
    public var table: String {
        let header = ["benchmark", "n", "conc", "min", "p50", "p95", "p99", "max", "mean", "ops/s"]
        var rows = [header]

        for result in results {
            let latency = result.latency
            rows.append([
                result.name,
                String(latency.count),
                String(result.concurrency),
                Self.format(latency.minimum),
                Self.format(latency.p50),
                Self.format(latency.p95),
                Self.format(latency.p99),
                Self.format(latency.maximum),
                Self.format(latency.mean),
                String(Int(result.operationsPerSecond.rounded())),
            ])
        }
        return Self.align(rows) + "\n(\(environment.configuration) build, \(environment.processors) processors)"
    }

    /// Writes the report as JSON.
    ///
    /// - Parameter path: The file to write; its directory is created when missing.
    /// - Throws: An error when the file cannot be written.
    public func write(to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url)
    }

    private static let microsecondsPerSecond = 1_000_000.0
    private static let nanosecondsPerMicrosecond = 1_000.0
    private static let nanosecondsPerMillisecond = 1_000_000.0
    private static let nanosecondsPerSecond = 1_000_000_000.0

    /// A duration in the unit that reads best: nanoseconds, microseconds, milliseconds or seconds.
    ///
    /// - Parameter duration: The duration.
    /// - Returns: Text such as `12.3µs`.
    public static func format(_ duration: Duration) -> String {
        let nanoseconds = LatencyStatistics.nanoseconds(duration)

        switch nanoseconds {
        case ..<nanosecondsPerMicrosecond:
            return String(format: "%.0fns", nanoseconds)
        case ..<nanosecondsPerMillisecond:
            return String(format: "%.1fµs", nanoseconds / nanosecondsPerMicrosecond)
        case ..<nanosecondsPerSecond:
            return String(format: "%.2fms", nanoseconds / nanosecondsPerMillisecond)
        default:
            return String(format: "%.2fs", nanoseconds / nanosecondsPerSecond)
        }
    }

    private static func align(_ rows: [[String]]) -> String {
        let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max() ?? 0 }

        return rows.enumerated().map { index, row in
            let cells = row.enumerated().map { column, cell in
                column == 0
                    ? cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
                    : String(repeating: " ", count: widths[column] - cell.count) + cell
            }
            let line = cells.joined(separator: "  ")
            return index == 0 ? line + "\n" + String(repeating: "-", count: line.count) : line
        }.joined(separator: "\n")
    }
}
