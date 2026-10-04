import BorbaScientificCore
import Foundation
import IntegrationSupport
import PerformanceSupport
import Testing

/// The root of every benchmark suite. Benchmarks measure time, so they run strictly one after another: two running at
/// once would measure each other. Nested suites inherit the serialization.
@Suite("Benchmarks", .serialized)
struct Benchmarks {}

/// How big a run is and how strict its budgets are, depending on the build.
///
/// Benchmarks are meant for release builds. A debug build is many times slower, so it runs fewer iterations and gets
/// proportionally looser budgets: it still catches crashes and orders-of-magnitude regressions, which is all a debug run
/// can honestly say.
enum BenchmarkScale {
    private static let debugIterationDivisor = 20
    private static let minimumIterations = 20
    private static let debugBudgetMultiplier = 10.0
    private static let budgetScaleVariable = "BENCHMARK_BUDGET_SCALE"
    private static let outputDirectoryVariable = "BENCHMARK_OUTPUT_DIR"
    private static let defaultOutputDirectory = ".artifacts/benchmarks"
    private static let repositoryDepthFromThisFile = 3

    /// Whether a PostgreSQL server is configured for the benchmarks that need one.
    static var isDatabaseConfigured: Bool {
        (try? PostgresTestDatabase.serverURL()) != nil
    }

    /// Whether this is a release build.
    static var isRelease: Bool {
        #if DEBUG
            false
        #else
            true
        #endif
    }

    /// The number of measured runs for a benchmark, given what a release build should do.
    ///
    /// - Parameter release: The iterations in a release build.
    /// - Returns: `release` in a release build, a twentieth of it (at least 20) in a debug build.
    static func iterations(_ release: Int) -> Int {
        isRelease ? release : max(release / debugIterationDivisor, minimumIterations)
    }

    /// The number of warm-up runs: a tenth of the measured runs, at least ten.
    ///
    /// - Parameter iterations: The measured runs.
    /// - Returns: The warm-up runs.
    static func warmup(for iterations: Int) -> Int {
        max(iterations / 10, 10)
    }

    /// A latency budget adjusted for the build and for the machine.
    ///
    /// - Parameter release: The budget in a release build on a reference machine.
    /// - Returns: The budget to apply here. `BENCHMARK_BUDGET_SCALE` multiplies it, for slower machines such as shared CI
    ///   runners.
    static func budget(_ release: Duration) -> Duration {
        let machine = ProcessInfo.processInfo.environment[budgetScaleVariable].flatMap(Double.init) ?? 1
        return release * (isRelease ? 1 : debugBudgetMultiplier) * machine
    }

    /// Prints the results of a group and writes them as JSON for CI and for comparing runs.
    ///
    /// - Parameters:
    ///   - group: The family of benchmarks.
    ///   - results: Their results.
    /// - Throws: An error when the report cannot be written.
    static func publish(
        group: String,
        _ results: [BenchmarkResult]
    ) throws {
        let report = BenchmarkReport(results: results)
        print("\n── \(group) " + String(repeating: "─", count: 60) + "\n" + report.table + "\n")

        let directory = ProcessInfo.processInfo.environment[outputDirectoryVariable] ?? defaultOutputDirectory
        try report.write(to: absolute(directory) + "/\(group).json")
    }

    private static func absolute(_ directory: String) -> String {
        guard !directory.hasPrefix("/") else {
            return directory
        }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<repositoryDepthFromThisFile {
            root.deleteLastPathComponent()
        }
        return root.appendingPathComponent(directory).path
    }
}

/// Fails a test when a benchmark's 99th percentile exceeds its budget.
///
/// - Parameters:
///   - result: The measured benchmark.
///   - budget: The p99 budget in a release build on a reference machine.
///   - sourceLocation: Where a failure is reported.
func expectWithinBudget(
    _ result: BenchmarkResult,
    p99 budget: Duration,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let allowed = BenchmarkScale.budget(budget)
    let measured = BenchmarkReport.format(result.latency.p99)

    #expect(
        result.latency.p99 <= allowed,
        "\(result.name): p99 \(measured) exceeds the budget of \(BenchmarkReport.format(allowed))",
        sourceLocation: sourceLocation
    )
}

/// An operation that was expected to succeed did not.
struct BenchmarkFailure: Error, CustomStringConvertible {
    let description: String
}

/// Swallows events, so a benchmark measures the service and not the bookkeeping of a recorder.
struct NullEventPublisher: EventPublisher {
    func publish(_ event: CalculationEvent) async {}
}
