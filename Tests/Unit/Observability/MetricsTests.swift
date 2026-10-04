import BorbaScientificCore
import Foundation
import Logging
import Metrics
import Prometheus
import Synchronization
import TestSupport
import Testing

@testable import BorbaScientificEngine

/// A metrics recorder over a registry of its own, and a way to read what it recorded.
private struct MetricsFixture {
    let registry = PrometheusCollectorRegistry()
    let metrics: EngineMetrics

    init() {
        metrics = EngineMetrics(factory: PrometheusMetricsFactory(registry: registry))
    }

    func scrape() -> MetricsScrape {
        MetricsScrape(registry.emitToString())
    }
}

private let addition = CalculationType(module: ModuleName("arithmetic"), operation: OperationName("add"))

@Suite("EngineMetrics")
struct EngineMetricsTests {
    @Test("counts requests by method, route and status, and server errors apart")
    func requests() {
        let fixture = MetricsFixture()

        fixture.metrics.recordRequest(
            method: "POST",
            route: "/api/v1/calculations",
            status: 201,
            duration: .milliseconds(3)
        )
        fixture.metrics.recordRequest(
            method: "POST",
            route: "/api/v1/calculations",
            status: 503,
            duration: .milliseconds(30)
        )
        let scrape = fixture.scrape()
        let created = ["method": "POST", "route": "/api/v1/calculations", "status": "201"]
        let unavailable = ["method": "POST", "route": "/api/v1/calculations", "status": "503"]

        #expect(scrape.value("http_requests_total", created) == 1)
        #expect(scrape.value("http_requests_total", unavailable) == 1)
        #expect(scrape.value("http_request_errors_total", unavailable) == 1)
        #expect(scrape.value("http_request_errors_total", created) == nil)
        #expect(scrape.value("http_request_duration_seconds_count", unavailable) == 1)
        #expect((scrape.value("http_request_duration_seconds_sum", unavailable) ?? 0) > 0.029)
    }

    @Test("counts calculations by module, operation and status, and times them")
    func calculations() {
        let fixture = MetricsFixture()

        fixture.metrics.recordCalculation(addition, status: .succeeded, duration: .microseconds(40))
        fixture.metrics.recordCalculation(addition, status: .succeeded, duration: .microseconds(60))
        fixture.metrics.recordCalculation(addition, status: .failed, duration: .microseconds(10))
        let scrape = fixture.scrape()
        let labels = ["module": "arithmetic", "operation": "add"]

        #expect(scrape.value("calculations_total", labels.merging(["status": "succeeded"]) { $1 }) == 2)
        #expect(scrape.value("calculations_total", labels.merging(["status": "failed"]) { $1 }) == 1)
        #expect(scrape.value("calculation_duration_seconds_count", labels) == 3)
    }

    @Test("counts failures by code and classification")
    func failures() {
        let fixture = MetricsFixture()

        fixture.metrics.recordCalculationFailure(code: .divisionByZero, classification: .expectedDomain)
        fixture.metrics.recordCalculationFailure(code: .storageUnavailable, classification: .infrastructure)
        let scrape = fixture.scrape()

        #expect(
            scrape.value(
                "calculation_failures_total",
                ["code": "DIVISION_BY_ZERO", "classification": "expected_domain"]
            ) == 1
        )
        #expect(
            scrape.value(
                "calculation_failures_total",
                ["code": "STORAGE_UNAVAILABLE", "classification": "infrastructure"]
            ) == 1
        )
    }

    @Test("times database calls and counts their failures by kind")
    func databaseOperations() {
        let fixture = MetricsFixture()

        fixture.metrics.recordDatabaseOperation("find", duration: .milliseconds(2), failure: nil)
        fixture.metrics.recordDatabaseOperation("find", duration: .milliseconds(9), failure: .timeout)
        fixture.metrics.recordDatabaseOperation(
            "save",
            duration: .milliseconds(1),
            failure: .unavailable(reason: "refused")
        )
        let scrape = fixture.scrape()

        #expect(scrape.value("database_operation_duration_seconds_count", ["operation": "find"]) == 2)
        #expect(scrape.value("database_failures_total", ["operation": "find", "kind": "timeout"]) == 1)
        #expect(scrape.value("database_failures_total", ["operation": "save", "kind": "unavailable"]) == 1)
        #expect(scrape.value("database_failures_total", ["operation": "find", "kind": "unavailable"]) == nil)
    }

    @Test("counts retries, dropped events and error reports, and publishes gauges")
    func smallerMetrics() {
        let fixture = MetricsFixture()

        fixture.metrics.recordRetry(operation: "list")
        fixture.metrics.recordDroppedEvent(subscriber: "metrics")
        fixture.metrics.recordErrorReport(.throttled)
        fixture.metrics.setRequestsInFlight(3)
        fixture.metrics.setBuildInfo(version: "1.2.3", commit: "abc", environment: "test")
        fixture.metrics.addProcessCPUSeconds(1.5)
        fixture.metrics.addProcessCPUSeconds(0.5)
        let scrape = fixture.scrape()

        #expect(scrape.value("repository_retries_total", ["operation": "list"]) == 1)
        #expect(scrape.value("events_dropped_total", ["subscriber": "metrics"]) == 1)
        #expect(scrape.value("error_reports_total", ["outcome": "throttled"]) == 1)
        #expect(scrape.value("http_requests_in_flight") == 3)
        #expect(scrape.value("build_info", ["version": "1.2.3", "commit": "abc", "environment": "test"]) == 1)
        #expect(scrape.value("process_cpu_seconds_total") == 2)
    }

    @Test("converts durations to whole nanoseconds without overflowing")
    func nanoseconds() {
        #expect(Duration.microseconds(21).totalNanoseconds == 21_000)
        #expect(Duration.seconds(2).totalNanoseconds == 2_000_000_000)
        #expect(Duration.seconds(Int64.max).totalNanoseconds == Int64.max)
    }
}

@Suite("MetricsEventSubscriber")
struct MetricsEventSubscriberTests {
    private func event(
        _ code: ErrorCode? = nil,
        classification: ErrorClassification = .expectedDomain
    ) -> CalculationEvent {
        if let code {
            return .failed(
                CalculationFailed(
                    eventID: RecordFixtures.id(1).rawValue,
                    occurredAt: RecordFixtures.epoch,
                    calculationID: RecordFixtures.id(1),
                    type: addition,
                    code: code,
                    classification: classification,
                    executionTime: .microseconds(50),
                    trace: RecordFixtures.trace
                )
            )
        }
        return .completed(
            CalculationCompleted(
                eventID: RecordFixtures.id(1).rawValue,
                occurredAt: RecordFixtures.epoch,
                calculationID: RecordFixtures.id(1),
                type: addition,
                executionTime: .microseconds(50),
                trace: RecordFixtures.trace
            )
        )
    }

    @Test("records a calculation once, when it ends, and ignores its request event")
    func recordsOutcomes() async {
        let fixture = MetricsFixture()
        let subscriber = MetricsEventSubscriber(metrics: fixture.metrics)

        await subscriber.handle(
            .requested(
                CalculationRequested(
                    eventID: RecordFixtures.id(1).rawValue,
                    occurredAt: RecordFixtures.epoch,
                    calculationID: RecordFixtures.id(1),
                    type: addition,
                    trace: RecordFixtures.trace
                )
            )
        )
        #expect(fixture.scrape().count(named: "calculations_total") == 0)

        await subscriber.handle(event())
        await subscriber.handle(event(.divisionByZero))
        let scrape = fixture.scrape()
        let labels = ["module": "arithmetic", "operation": "add"]

        #expect(scrape.value("calculations_total", labels.merging(["status": "succeeded"]) { $1 }) == 1)
        #expect(scrape.value("calculations_total", labels.merging(["status": "failed"]) { $1 }) == 1)
        #expect(scrape.value("calculation_failures_total", ["code": "DIVISION_BY_ZERO"]) == 1)
    }

    @Test("counts a suppressed duplicate apart from failures")
    func suppressedDuplicates() async {
        let fixture = MetricsFixture()

        await MetricsEventSubscriber(metrics: fixture.metrics).handle(
            event(.duplicateSuppressed, classification: .application)
        )
        let scrape = fixture.scrape()

        #expect(scrape.value("calculations_total", ["status": "suppressed"]) == 1)
        #expect(scrape.value("calculations_total", ["status": "failed"]) == nil)
        #expect(scrape.count(named: "calculation_failures_total") == 0)
    }
}

@Suite("MeteredCalculationRepository")
struct MeteredCalculationRepositoryTests {
    @Test("measures successful calls and passes results through")
    func successes() async throws {
        let fixture = MetricsFixture()
        let base = InMemoryCalculationRepository()
        let repository = MeteredCalculationRepository(base: base, metrics: fixture.metrics, clock: ManualClock())
        let record = RecordFixtures.record(sequence: 1)

        _ = try await repository.save(record, claiming: nil)
        let found = try await repository.find(id: record.id)
        _ = try await repository.list(matching: HistoryFilter(), page: PageRequest())
        _ = try await repository.record(for: IdempotencyKey("none"))
        let scrape = fixture.scrape()

        #expect(found == record)
        for operation in ["save", "find", "list", "record"] {
            #expect(scrape.value("database_operation_duration_seconds_count", ["operation": operation]) == 1)
        }
        #expect(scrape.count(named: "database_failures_total") == 0)
    }

    @Test("records a failed call with its kind, and still throws it")
    func failures() async {
        let fixture = MetricsFixture()
        let base = InMemoryCalculationRepository()
        await base.failNextCalls(with: .unavailable(reason: "refused"))
        let repository = MeteredCalculationRepository(base: base, metrics: fixture.metrics, clock: ManualClock())

        await #expect(throws: RepositoryError.self) {
            try await repository.find(id: RecordFixtures.id(1))
        }

        #expect(fixture.scrape().value("database_failures_total", ["operation": "find", "kind": "unavailable"]) == 1)
    }
}

@Suite("ProcessMetrics")
struct ProcessMetricsTests {
    private static let statm = "50000 12500 3000 100 0 8000 0"
    private static let stat =
        "4242 (borba (engine) x) S 1 4242 4242 0 -1 4194560 3000 0 0 0 150 50 0 0 20 0 8 0 100 "
        + "123456789 12500 18446744073709551615"

    @Test("reads resident memory in pages and converts it to bytes")
    func residentMemory() {
        let expected: Double = 12_500 * 4_096

        #expect(ProcessMetrics.residentMemory(statm: Self.statm, pageSize: 4096) == expected)
        #expect(ProcessMetrics.residentMemory(statm: "garbage", pageSize: 4096) == nil)
        #expect(ProcessMetrics.residentMemory(statm: "", pageSize: 4096) == nil)
    }

    @Test("adds user and kernel time, even when the command name contains spaces and parentheses")
    func cpuSeconds() {
        #expect(ProcessMetrics.cpuSeconds(stat: Self.stat, ticksPerSecond: 100) == 2.0)
        #expect(ProcessMetrics.cpuSeconds(stat: "no parenthesis", ticksPerSecond: 100) == nil)
        #expect(ProcessMetrics.cpuSeconds(stat: "1 (x) S 1", ticksPerSecond: 100) == nil)
        #expect(ProcessMetrics.cpuSeconds(stat: Self.stat, ticksPerSecond: 0) == nil)
    }

    @Test("reads the running process on Linux")
    func readsTheProcess() throws {
        #if os(Linux)
            let snapshot = try #require(ProcessMetrics.read())

            #expect(snapshot.residentMemoryBytes > 0)
            #expect(snapshot.openFileDescriptors > 0)
            #expect(snapshot.cpuSeconds >= 0)
        #endif
    }

    @Test("publishes CPU time as the difference since the last refresh, so the counter only goes up")
    func cpuIsPublishedAsADelta() {
        #if os(Linux)
            let fixture = MetricsFixture()
            let recorder = ProcessMetricsRecorder()

            recorder.refresh(into: fixture.metrics)
            let first = fixture.scrape().value("process_cpu_seconds_total") ?? -1
            recorder.refresh(into: fixture.metrics)
            let second = fixture.scrape().value("process_cpu_seconds_total") ?? -1

            #expect(first >= 0)
            #expect(second >= first)
            #expect(fixture.scrape().value("process_resident_memory_bytes") ?? 0 > 0)
        #endif
    }
}

@Suite("Metric hooks", .timeLimit(.minutes(1)))
struct MetricHookTests {
    @Test("tells the in-flight counter's observer the count every time it changes")
    func inFlightObserver() {
        let seen = Mutex<[Int]>([])
        let requests = InFlightRequests(onChange: { count in seen.withLock { $0.append(count) } })

        requests.begin()
        requests.begin()
        requests.end()
        requests.end()

        #expect(seen.withLock { $0 } == [1, 2, 1, 0])
    }

    @Test("tells the retry decorator's observer which call was repeated")
    func retryObserver() async throws {
        let observed = Mutex<[String]>([])
        let base = InMemoryCalculationRepository()
        await base.failNextCalls(with: .unavailable(reason: "refused"), times: 2)
        let repository = RetryingCalculationRepository(
            base: base,
            policy: .standard,
            clock: RecordingSleepClock(),
            logger: Logger(label: "test"),
            onRetry: { operation in observed.withLock { $0.append(operation) } }
        )

        _ = try await repository.find(id: RecordFixtures.id(1))

        #expect(observed.withLock { $0 } == ["find", "find"])
    }
}
