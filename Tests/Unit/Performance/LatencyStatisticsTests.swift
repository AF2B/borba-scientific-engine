import Foundation
import PerformanceSupport
import Testing

@Suite("LatencyStatistics")
struct LatencyStatisticsTests {
    private func milliseconds(_ values: [Int]) -> [Duration] {
        values.map { .milliseconds($0) }
    }

    @Test("has nothing to summarize without measurements")
    func empty() {
        #expect(LatencyStatistics(samples: []) == nil)
    }

    @Test("summarizes a single measurement")
    func single() throws {
        let statistics = try #require(LatencyStatistics(samples: [.milliseconds(7)]))

        #expect(statistics.count == 1)
        #expect(statistics.minimum == .milliseconds(7))
        #expect(statistics.maximum == .milliseconds(7))
        #expect(statistics.mean == .milliseconds(7))
        #expect(statistics.p50 == .milliseconds(7))
        #expect(statistics.p99 == .milliseconds(7))
        #expect(statistics.standardDeviation == .zero)
    }

    @Test("uses the nearest-rank method, so a percentile is always a value that was observed")
    func nearestRank() throws {
        let statistics = try #require(LatencyStatistics(samples: milliseconds(Array(1...100))))

        #expect(statistics.p50 == .milliseconds(50))
        #expect(statistics.p95 == .milliseconds(95))
        #expect(statistics.p99 == .milliseconds(99))
        #expect(statistics.minimum == .milliseconds(1))
        #expect(statistics.maximum == .milliseconds(100))
    }

    @Test("does not depend on the order of the measurements")
    func order() throws {
        let ascending = try #require(LatencyStatistics(samples: milliseconds(Array(1...50))))
        let shuffled = try #require(LatencyStatistics(samples: milliseconds(Array(1...50).shuffled())))

        #expect(ascending == shuffled)
    }

    @Test("computes the mean and the standard deviation")
    func meanAndDeviation() throws {
        let statistics = try #require(LatencyStatistics(samples: milliseconds([2, 4, 4, 4, 5, 5, 7, 9])))

        #expect(statistics.mean == .milliseconds(5))
        #expect(statistics.standardDeviation == .milliseconds(2), "the classic example: population deviation of 2")
    }

    @Test("shows the tail that the mean hides")
    func tail() throws {
        let samples = milliseconds(Array(repeating: 1, count: 98) + [500, 900])
        let statistics = try #require(LatencyStatistics(samples: samples))

        #expect(statistics.p50 == .milliseconds(1))
        #expect(statistics.p95 == .milliseconds(1))
        #expect(statistics.p99 == .milliseconds(500))
        #expect(statistics.maximum == .milliseconds(900))
        #expect(statistics.mean > statistics.p95)
    }

    @Test("clamps the rank of extreme percentiles")
    func clamps() {
        let sorted = milliseconds([1, 2, 3])

        #expect(LatencyStatistics.percentile(0, of: sorted) == .milliseconds(1))
        #expect(LatencyStatistics.percentile(100, of: sorted) == .milliseconds(3))
        #expect(LatencyStatistics.percentile(250, of: sorted) == .milliseconds(3))
    }

    @Test("formats durations in the unit that reads best")
    func formatting() {
        #expect(BenchmarkReport.format(.nanoseconds(850)) == "850ns")
        #expect(BenchmarkReport.format(.microseconds(12) + .nanoseconds(300)) == "12.3µs")
        #expect(BenchmarkReport.format(.milliseconds(42)) == "42.00ms")
        #expect(BenchmarkReport.format(.seconds(3)) == "3.00s")
    }
}

@Suite("Benchmark", .timeLimit(.minutes(1)))
struct BenchmarkRunnerTests {
    @Test("measures every iteration but not the warm-up, and numbers the warm-up runs negatively")
    func iterations() async throws {
        let seen = Seen()

        let result = try await Benchmark.run("noop", group: "test", warmup: 3, iterations: 10) { index in
            await seen.record(index)
        }

        #expect(result.latency.count == 10)
        #expect(await seen.indexes.sorted() == [-3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
    }

    @Test("never has more operations in flight than the concurrency asks for")
    func concurrencyLimit() async throws {
        let counter = InFlight()

        _ = try await Benchmark.run("sleep", group: "test", warmup: 0, iterations: 40, concurrency: 4) { _ in
            await counter.enter()
            try await Task.sleep(for: .milliseconds(2))
            await counter.leave()
        }

        #expect(await counter.maximum <= 4)
        #expect(await counter.maximum > 1, "the operations did overlap")
    }

    @Test("reports a throughput that exceeds one over the latency when operations overlap")
    func throughput() async throws {
        let result = try await Benchmark.run("sleep", group: "test", warmup: 0, iterations: 64, concurrency: 8) { _ in
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(result.operationsPerSecond > 1.5 / (LatencyStatistics.nanoseconds(result.latency.mean) / 1e9))
    }

    @Test("propagates the failure of an operation instead of producing numbers")
    func failures() async {
        struct Broken: Error {}

        await #expect(throws: Broken.self) {
            try await Benchmark.run("broken", group: "test", warmup: 0, iterations: 5) { _ in throw Broken() }
        }
    }

    @Test("refuses to run zero iterations")
    func noIterations() async {
        await #expect(throws: BenchmarkError.self) {
            try await Benchmark.run("none", group: "test", warmup: 0, iterations: 0) { _ in }
        }
    }

    @Test("writes a report that reads back, and renders a table with every benchmark")
    func report() async throws {
        let result = try await Benchmark.run("one", group: "test", warmup: 0, iterations: 5) { _ in }
        let report = BenchmarkReport(results: [result])
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/report.json")
            .path

        try report.write(to: path)
        let decoded = try JSONDecoder().decode(BenchmarkReport.self, from: Data(contentsOf: URL(fileURLWithPath: path)))

        #expect(decoded.results == [result])
        #expect(report.table.contains("one"))
        #expect(report.table.contains("p99"))
    }
}

private actor Seen {
    private(set) var indexes: [Int] = []

    func record(_ index: Int) {
        indexes.append(index)
    }
}

private actor InFlight {
    private var current = 0
    private(set) var maximum = 0

    func enter() {
        current += 1
        maximum = max(maximum, current)
    }

    func leave() {
        current -= 1
    }
}
