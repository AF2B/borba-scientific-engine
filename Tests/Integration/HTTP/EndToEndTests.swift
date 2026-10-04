import BorbaScientificCore
import HTTPSupport
import InMemoryLogging
import IntegrationSupport
import Logging
import TestSupport
import Testing
import Vapor

@testable import BorbaScientificEngine

/// The HTTP API over the production wiring and a real PostgreSQL: what a client of the running service observes.
@Suite("HTTP API against PostgreSQL")
struct EndToEndTests {
    private static let calculationsPath = "/api/v1/calculations"
    private static let idempotencyKeyHeader = "Idempotency-Key"
    private static let replayedHeader = "Idempotent-Replayed"
    private static let requestIDHeader = "X-Request-ID"
    private static let concurrentRetries = 8
    private static let batchSize = 25
    private static let pageSize = 4
    private static let metricsPollAttempts = 100
    private static let metricsPollInterval = Duration.milliseconds(20)

    private static let add: CalculationValue = [
        "module": "arithmetic",
        "operation": "add",
        "parameters": ["a": 2, "b": 3],
    ]
    private static let divideByZero: CalculationValue = [
        "module": "arithmetic",
        "operation": "divide",
        "parameters": ["dividend": 1, "divisor": 0],
    ]

    @Test("records a calculation and serves it back by identifier and through the history")
    func recordsAndServesBack() async throws {
        try await PostgresTestDatabase.withMigratedDatabase { database in
            try await TestApplication.runLive(databaseURL: database.url) { harness in
                let created = try await harness.client.post(Self.calculationsPath, json: Self.add)
                let identifier = try #require(created.json().at("id")?.text)

                let found = try await harness.client.get("\(Self.calculationsPath)/\(identifier)")
                let listed = try await harness.client.get(Self.calculationsPath)

                #expect(created.status == .created)
                #expect(found.status == .ok)
                #expect(try found.json().at("result") == 5)
                #expect(try found.json().at("request_id")?.text == created.header(Self.requestIDHeader))
                #expect(try listed.json().at("items", 0, "id")?.text == identifier)
            }
        }
    }

    @Test("records a calculation that failed and lists it among the failures")
    func recordsFailures() async throws {
        try await PostgresTestDatabase.withMigratedDatabase { database in
            try await TestApplication.runLive(databaseURL: database.url) { harness in
                _ = try await harness.client.post(Self.calculationsPath, json: Self.add)
                let failed = try await harness.client.post(Self.calculationsPath, json: Self.divideByZero)

                let failures = try await harness.client.get("\(Self.calculationsPath)?status=failed").json()

                #expect(failed.status == .unprocessableEntity)
                #expect(failures.at("items")?.elements?.count == 1)
                #expect(failures.at("items", 0, "error", "code") == "DIVISION_BY_ZERO")
                #expect(failures.at("items", 0, "id") == (try failed.json().at("error", "calculation_id")))
            }
        }
    }

    @Test("lets exactly one of several concurrent retries with the same key record the calculation")
    func concurrentRetriesConverge() async throws {
        try await PostgresTestDatabase.withMigratedDatabase { database in
            try await TestApplication.runLive(databaseURL: database.url) { harness in
                let client = harness.client
                let headers = [Self.idempotencyKeyHeader: "retry-storm"]

                let responses = try await withThrowingTaskGroup(of: TestResponse.self) { group in
                    for _ in 0..<Self.concurrentRetries {
                        group.addTask { try await client.post(Self.calculationsPath, json: Self.add, headers: headers) }
                    }
                    return try await group.reduce(into: []) { $0.append($1) }
                }

                let identifiers = Set(try responses.compactMap { try $0.json().at("id")?.text })
                let listed = try await harness.client.get(Self.calculationsPath).json()

                #expect(responses.filter { $0.status == .created }.count == 1)
                #expect(
                    responses.filter { $0.header(Self.replayedHeader) == "true" }.count == Self.concurrentRetries - 1
                )
                #expect(identifiers.count == 1)
                #expect(listed.at("items")?.elements?.count == 1)
            }
        }
    }

    @Test("walks a long history page by page without losing or repeating a calculation")
    func paginatesTheHistory() async throws {
        try await PostgresTestDatabase.withMigratedDatabase { database in
            try await TestApplication.runLive(databaseURL: database.url) { harness in
                let calculations = CalculationValue.list(Array(repeating: Self.add, count: Self.batchSize))
                _ = try await harness.client.post(
                    "\(Self.calculationsPath)/batch",
                    json: ["calculations": calculations]
                )

                var identifiers: [String] = []
                var timestamps: [String] = []
                var cursor: String?
                repeat {
                    let query = "limit=\(Self.pageSize)" + (cursor.map { "&cursor=\($0)" } ?? "")
                    let page = try await harness.client.get("\(Self.calculationsPath)?\(query)").json()

                    identifiers += page.at("items")?.elements?.compactMap { $0.at("id")?.text } ?? []
                    timestamps += page.at("items")?.elements?.compactMap { $0.at("created_at")?.text } ?? []
                    cursor = page.at("page", "next_cursor")?.text
                } while cursor != nil && identifiers.count <= Self.batchSize

                #expect(identifiers.count == Self.batchSize)
                #expect(Set(identifiers).count == Self.batchSize)
                #expect(timestamps == timestamps.sorted(by: >), "newest first")
            }
        }
    }

    @Test("measures the database calls, counts calculations and publishes the build")
    func publishesLiveMetrics() async throws {
        try await PostgresTestDatabase.withMigratedDatabase { database in
            try await TestApplication.runLive(databaseURL: database.url) { harness in
                _ = try await harness.client.post(Self.calculationsPath, json: Self.add)
                _ = try await harness.client.get(Self.calculationsPath)

                // Calculation metrics come from events, which are delivered asynchronously.
                var scrape = try await harness.client.metrics()
                for _ in 0..<Self.metricsPollAttempts
                where scrape.value("calculations_total", ["status": "succeeded"]) == nil {
                    try await Task.sleep(for: Self.metricsPollInterval)
                    scrape = try await harness.client.metrics()
                }

                #expect(
                    scrape.value(
                        "calculations_total",
                        ["module": "arithmetic", "operation": "add", "status": "succeeded"]
                    ) == 1
                )
                #expect((scrape.value("database_operation_duration_seconds_count", ["operation": "save"]) ?? 0) >= 1)
                #expect((scrape.value("database_operation_duration_seconds_count", ["operation": "list"]) ?? 0) >= 1)
                #expect(scrape.count(named: "database_failures_total") == 0)
                #expect(scrape.value("build_info", ["version": "0.0.0-dev", "environment": "development"]) == 1)
                #expect((scrape.value("process_start_time_seconds") ?? 0) > 0)
            }
        }
    }

    @Test("reports ready once the schema is migrated, and names the problem when it is not")
    func readinessFollowsTheDatabase() async throws {
        try await PostgresTestDatabase.withEmptyDatabase { database in
            try await TestApplication.runLive(databaseURL: database.url) { harness in
                let pending = try await harness.client.get("/ready")

                #expect(pending.status == .serviceUnavailable)
                #expect(try pending.json().at("checks", 0, "detail") == "migrations pending")
            }
        }
        try await PostgresTestDatabase.withMigratedDatabase { database in
            try await TestApplication.runLive(databaseURL: database.url) { harness in
                let ready = try await harness.client.get("/ready")

                #expect(ready.status == .ok)
                #expect(try ready.json().at("checks", 0, "status") == "up")
            }
        }
    }

    @Test("answers 503 without leaking the database when the history is unreachable, and stays alive")
    func survivesAnUnreachableDatabase() async throws {
        let unreachable = "postgres://engine:secret-password@127.0.0.1:1/hidden_database_name"
        let settings = [EnvironmentVariable.databasePoolTimeoutMilliseconds.rawValue: "200"]

        try await TestApplication.runLive(databaseURL: unreachable, settings: settings) { harness in
            let calculation = try await harness.client.post(Self.calculationsPath, json: Self.add)
            let history = try await harness.client.get(Self.calculationsPath)
            let health = try await harness.client.get("/health")
            let ready = try await harness.client.get("/ready")

            #expect(ready.status == .serviceUnavailable)
            #expect(try ready.json().at("checks", 0, "detail") == "unreachable")
            #expect(!ready.body.contains("127.0.0.1"))
            #expect(calculation.status == .serviceUnavailable)
            #expect(try calculation.json().at("error", "code") == "STORAGE_UNAVAILABLE")
            #expect(history.status == .serviceUnavailable)
            #expect(health.status == .ok)
            for response in [calculation, history] {
                #expect(!response.body.contains("secret-password"))
                #expect(!response.body.contains("hidden_database_name"))
                #expect(!response.body.contains("127.0.0.1"))
            }

            let requestID = try #require(calculation.header(Self.requestIDHeader))
            let logged = harness.logs.entries.contains {
                $0.level == .error
                    && $0.metadata["error_code"] == "STORAGE_UNAVAILABLE"
                    && $0.metadata[TraceMetadataKey.requestID] == .string(requestID)
            }
            #expect(logged, "infrastructure failures are logged at error level with the request identifier")
        }
    }
}
