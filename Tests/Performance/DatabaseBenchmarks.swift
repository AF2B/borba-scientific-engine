import BorbaScientificCore
import BorbaScientificPersistence
import Foundation
import HTTPSupport
import IntegrationSupport
import PerformanceSupport
import SQLKit
import TestSupport
import Testing
import Vapor

@testable import BorbaScientificEngine

extension Benchmarks {
    /// The cost of the history against a real PostgreSQL, and of the whole service on top of it.
    ///
    /// These need `TEST_DATABASE_URL`; without it they are skipped.
    @Suite("Database", .enabled(if: BenchmarkScale.isDatabaseConfigured))
    struct DatabaseBenchmarks {
        private static let group = "database"
        private static let preloaded = 10_000

        private static func measure(
            _ name: String,
            iterations: Int,
            concurrency: Int = 1,
            operation: @escaping @Sendable (Int) async throws -> Void
        ) async throws -> BenchmarkResult {
            try await Benchmark.run(
                name,
                group: group,
                warmup: BenchmarkScale.warmup(for: iterations),
                iterations: iterations,
                concurrency: concurrency,
                operation: operation
            )
        }

        /// Fills the table with realistic rows in one statement, far faster than saving them one by one.
        private static func preload(
            _ count: Int,
            into database: TestDatabase
        ) async throws {
            try await database.execute(
                """
                INSERT INTO calculations
                    (id, module, operation, status, parameters, result, execution_time_ns,
                     request_id, correlation_id, created_at)
                SELECT gen_random_uuid(), 'arithmetic', 'add', 'succeeded', '{"a":1,"b":2}'::jsonb, '3'::jsonb, 1000,
                       'request-' || n, 'correlation-' || n, now() - (n || ' seconds')::interval
                FROM generate_series(1, \(literal: count)) AS n
                """
            )
        }

        @Test("measures every call of the history, then deep pagination and concurrent writes")
        func repository() async throws {
            let iterations = BenchmarkScale.iterations(500)

            let results = try await PostgresTestDatabase.withMigratedDatabase { database in
                try await Self.preload(Self.preloaded, into: database)
                let repository = database.repository
                let existing = try await repository.list(matching: HistoryFilter(), page: PageRequest(limit: 100))
                let ids = existing.items.map(\.id)
                let deepCursor = try await Self.cursorAfter(offset: Self.preloaded / 2, in: repository)
                var results: [BenchmarkResult] = []

                results.append(
                    try await Self.measure("save", iterations: iterations) { index in
                        _ = try await repository.save(RecordFixtures.record(sequence: 100_000 + index), claiming: nil)
                    }
                )
                results.append(
                    try await Self.measure("save with an idempotency key", iterations: iterations) { index in
                        let claim = IdempotencyClaim(
                            key: IdempotencyKey("benchmark-\(index)"),
                            fingerprint: RequestFingerprint("sha256:benchmark")
                        )
                        _ = try await repository.save(RecordFixtures.record(sequence: 200_000 + index), claiming: claim)
                    }
                )
                results.append(
                    try await Self.measure("find by id", iterations: iterations) { index in
                        _ = try await repository.find(id: ids[abs(index) % ids.count])
                    }
                )
                results.append(
                    try await Self.measure("list the first page of 20", iterations: iterations) { _ in
                        _ = try await repository.list(matching: HistoryFilter(), page: PageRequest(limit: 20))
                    }
                )
                results.append(
                    try await Self.measure(
                        "list a page of 20 after \(Self.preloaded / 2) rows (keyset)",
                        iterations: iterations
                    ) { _ in
                        _ = try await repository.list(
                            matching: HistoryFilter(),
                            page: PageRequest(limit: 20, cursor: deepCursor)
                        )
                    }
                )
                results.append(
                    try await Self.measure("list failures only (partial index)", iterations: iterations) { _ in
                        _ = try await repository.list(
                            matching: HistoryFilter(status: .failed),
                            page: PageRequest(limit: 20)
                        )
                    }
                )
                let saveInParallel: @Sendable (Int) async throws -> Void = { index in
                    _ = try await repository.save(RecordFixtures.record(sequence: 300_000 + index), claiming: nil)
                }
                results.append(
                    try await Self.measure(
                        "save × 8 concurrent writers",
                        iterations: iterations,
                        concurrency: 8,
                        operation: saveInParallel
                    )
                )
                return results
            }

            try BenchmarkScale.publish(group: "database-repository", results)
            for result in results {
                expectWithinBudget(result, p99: .milliseconds(100))
            }
            let first = try #require(results.first { $0.name.hasPrefix("list the first") })
            let deep = try #require(results.first { $0.name.contains("keyset") })
            #expect(
                deep.latency.p50 < first.latency.p50 * 5 + .milliseconds(5),
                "a keyset page deep in the table costs about the same as the first one"
            )
        }

        /// The cursor that continues after `offset` rows, found by walking pages of 100.
        private static func cursorAfter(
            offset: Int,
            in repository: some CalculationRepository
        ) async throws -> PageCursor {
            var cursor: PageCursor?
            var seen = 0
            while seen < offset {
                let page = try await repository.list(
                    matching: HistoryFilter(),
                    page: PageRequest(limit: 100, cursor: cursor)
                )
                seen += page.items.count
                cursor = page.nextCursor
            }
            return try #require(cursor)
        }

        @Test("measures the whole service — HTTP, the engine and PostgreSQL — for a recorded calculation and a listing")
        func endToEnd() async throws {
            let iterations = BenchmarkScale.iterations(500)

            let results = try await PostgresTestDatabase.withMigratedDatabase { database in
                try await Self.preload(Self.preloaded, into: database)

                return try await TestApplication.runLive(databaseURL: database.url) { harness in
                    let client = harness.client
                    let body: CalculationValue = [
                        "module": "arithmetic", "operation": "add", "parameters": ["a": 2, "b": 3],
                    ]

                    return [
                        try await Self.measure(
                            "POST /api/v1/calculations (HTTP + engine + PostgreSQL)",
                            iterations: iterations
                        ) { _ in
                            guard try await client.post("/api/v1/calculations", json: body).status == .created else {
                                throw BenchmarkFailure(description: "a calculation was not recorded")
                            }
                        },
                        try await Self.measure("GET /api/v1/calculations?limit=20", iterations: iterations) { _ in
                            guard try await client.get("/api/v1/calculations?limit=20").status == .ok else {
                                throw BenchmarkFailure(description: "the history was not served")
                            }
                        },
                        try await Self.measure(
                            "POST /api/v1/calculations × 8 concurrent",
                            iterations: iterations,
                            concurrency: 8
                        ) { _ in
                            guard try await client.post("/api/v1/calculations", json: body).status == .created else {
                                throw BenchmarkFailure(description: "a calculation was not recorded")
                            }
                        },
                    ]
                }
            }

            try BenchmarkScale.publish(group: "database-end-to-end", results)
            for result in results {
                expectWithinBudget(result, p99: .milliseconds(150))
            }
        }
    }
}
