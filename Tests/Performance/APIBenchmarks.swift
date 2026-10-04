import BorbaScientificCore
import Foundation
import HTTPSupport
import NIOCore
import PerformanceSupport
import TestSupport
import Testing
import Vapor

@testable import BorbaScientificEngine

extension Benchmarks {
    /// The latency of the HTTP stack — routing, middleware, handlers, JSON — over in-memory adapters, so that what is
    /// measured is this service and not a network or a database.
    @Suite("API")
    struct APIBenchmarks {
        private static let group = "api"

        /// The in-memory history sorts everything on every listing, so a large one would measure the double, not the
        /// service. The database benchmarks measure listing at scale.
        private static let listedRecords = 100

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

        private static func measure(
            _ name: String,
            iterations: Int,
            concurrency: Int = 1,
            expecting status: HTTPResponseStatus,
            request: @escaping @Sendable () async throws -> TestResponse
        ) async throws -> BenchmarkResult {
            try await Benchmark.run(
                name,
                group: group,
                warmup: BenchmarkScale.warmup(for: iterations),
                iterations: iterations,
                concurrency: concurrency
            ) { _ in
                let response = try await request()
                guard response.status == status else {
                    throw BenchmarkFailure(description: "\(name): expected \(status), got \(response.status)")
                }
            }
        }

        @Test("measures each kind of endpoint, from the framework's floor up to a recorded calculation")
        func endpoints() async throws {
            let iterations = BenchmarkScale.iterations(2_000)

            let results = try await TestApplication.run(engineClock: SystemClock()) { harness in
                let client = harness.client
                for sequence in 1...Self.listedRecords {
                    _ = try await harness.repository.save(RecordFixtures.record(sequence: sequence), claiming: nil)
                }

                var results: [BenchmarkResult] = []
                func endpoint(
                    _ name: String,
                    expecting status: HTTPResponseStatus,
                    _ request: @escaping @Sendable () async throws -> TestResponse
                ) async throws {
                    results.append(
                        try await Self.measure(name, iterations: iterations, expecting: status, request: request)
                    )
                }

                try await endpoint("GET /health (the framework's floor)", expecting: .ok) {
                    try await client.get("/health")
                }
                try await endpoint("GET /api/v1/types", expecting: .ok) {
                    try await client.get("/api/v1/types")
                }
                try await endpoint("GET /api/v1/types/{module}/{operation}", expecting: .ok) {
                    try await client.get("/api/v1/types/statistics/mean")
                }
                try await endpoint("GET /api/v1/calculations?limit=20", expecting: .ok) {
                    try await client.get("/api/v1/calculations?limit=20")
                }
                try await endpoint("POST /api/v1/calculations (add)", expecting: .created) {
                    try await client.post("/api/v1/calculations", json: Self.add)
                }
                try await endpoint("POST /api/v1/calculations (domain failure)", expecting: .unprocessableEntity) {
                    try await client.post("/api/v1/calculations", json: Self.divideByZero)
                }
                return results
            }

            try BenchmarkScale.publish(group: "api-endpoints", results)
            for result in results {
                expectWithinBudget(result, p99: .milliseconds(10))
            }
        }

        @Test("measures the same endpoints over loopback HTTP, with connections reused as in production")
        func overHTTP() async throws {
            let iterations = BenchmarkScale.iterations(2_000)
            let body = ByteBuffer(string: #"{"module":"arithmetic","operation":"add","parameters":{"a":2,"b":3}}"#)

            let results = try await TestApplication.runServing(engineClock: SystemClock()) { application, base in
                func get(_ path: String) -> @Sendable (Int) async throws -> Void {
                    { _ in
                        let response = try await application.client.get(URI(string: base + path))
                        guard response.status == .ok else {
                            throw BenchmarkFailure(description: "GET \(path) answered \(response.status)")
                        }
                    }
                }
                let calculations = URI(string: base + "/api/v1/calculations")
                let create: @Sendable (Int) async throws -> Void = { _ in
                    let response = try await application.client.post(calculations) { request in
                        request.headers.contentType = .json
                        request.body = body
                    }
                    guard response.status == .created else {
                        throw BenchmarkFailure(description: "POST answered \(response.status)")
                    }
                }

                var results: [BenchmarkResult] = []
                results.append(try await Self.measureHTTP("GET /health", iterations, 1, get("/health")))
                results.append(try await Self.measureHTTP("GET /api/v1/types", iterations, 1, get("/api/v1/types")))
                results.append(try await Self.measureHTTP("POST /api/v1/calculations", iterations, 1, create))
                for level in [4, 16, 64] {
                    results.append(
                        try await Self.measureHTTP(
                            "POST /api/v1/calculations × \(level)",
                            iterations * 2,
                            level,
                            create
                        )
                    )
                }
                return results
            }

            try BenchmarkScale.publish(group: "api-http", results)
            for result in results {
                expectWithinBudget(result, p99: .milliseconds(100))
            }
        }

        private static func measureHTTP(
            _ name: String,
            _ iterations: Int,
            _ concurrency: Int,
            _ operation: @escaping @Sendable (Int) async throws -> Void
        ) async throws -> BenchmarkResult {
            try await Benchmark.run(
                "\(name) (loopback HTTP)",
                group: group,
                warmup: BenchmarkScale.warmup(for: iterations),
                iterations: iterations,
                concurrency: concurrency,
                operation: operation
            )
        }

        @Test("measures a recorded calculation under concurrent load")
        func underLoad() async throws {
            let iterations = BenchmarkScale.iterations(4_000)

            let results = try await TestApplication.run(engineClock: SystemClock()) { harness in
                let client = harness.client
                var results: [BenchmarkResult] = []

                for level in [1, 4, 16] {
                    results.append(
                        try await Self.measure(
                            "POST /api/v1/calculations × \(level)",
                            iterations: iterations,
                            concurrency: level,
                            expecting: .created
                        ) {
                            try await client.post("/api/v1/calculations", json: Self.add)
                        }
                    )
                }
                return results
            }

            try BenchmarkScale.publish(group: "api-load", results)
            for result in results {
                expectWithinBudget(result, p99: .milliseconds(50))
            }
        }
    }
}
