import BorbaScientificCore
import Foundation
import Logging
import PerformanceSupport
import TestSupport
import Testing

@testable import BorbaScientificEngine

extension Benchmarks {
    /// What it costs to turn requests, results and logs into bytes and back.
    @Suite("Serialization")
    struct SerializationBenchmarks {
        private static let group = "serialization"

        private static func record(
            sequence: Int,
            result: CalculationValue
        ) -> CalculationRecord {
            RecordFixtures.record(sequence: sequence, outcome: .succeeded(result))
        }

        private static func measure(
            _ name: String,
            iterations: Int,
            operation: @escaping @Sendable () throws -> Void
        ) async throws -> BenchmarkResult {
            try await Benchmark.run(
                name,
                group: group,
                warmup: BenchmarkScale.warmup(for: iterations),
                iterations: iterations
            ) { _ in
                try operation()
            }
        }

        @Test("encodes responses of growing size")
        func encoding() async throws {
            let iterations = BenchmarkScale.iterations(2_000)
            let tenth = iterations / 10
            let quarter = iterations / 4
            let small = CalculationResource(Self.record(sequence: 1, result: 5))
            let large = CalculationResource(Self.record(sequence: 1, result: .numbers((0..<10_000).map(Double.init))))
            let page = HistoryPageResponse(
                page: Page(items: (1...100).map { Self.record(sequence: $0, result: 5) }, nextCursor: nil),
                limit: 100
            )
            let error = ErrorResponse(
                error: ErrorResponse.Body(
                    code: "VALIDATION_FAILED",
                    message: "The request parameters are invalid.",
                    requestID: "request-1",
                    details: [ErrorDetailBody(ErrorDetail(field: "a", reason: "is required"))],
                    calculationID: nil
                )
            )

            let results = [
                try await Self.measure("encode a calculation", iterations: iterations) {
                    _ = try JSONCoding.makeEncoder().encode(small)
                },
                try await Self.measure("encode a calculation with a 10,000-number result", iterations: tenth) {
                    _ = try JSONCoding.makeEncoder().encode(large)
                },
                try await Self.measure("encode a history page of 100", iterations: quarter) {
                    _ = try JSONCoding.makeEncoder().encode(page)
                },
                try await Self.measure("encode an error", iterations: iterations) {
                    _ = try JSONCoding.makeEncoder().encode(error)
                },
            ]

            try BenchmarkScale.publish(group: "serialization-encoding", results)
            expectWithinBudget(results[0], p99: .milliseconds(1))
            expectWithinBudget(results[1], p99: .milliseconds(100))
            expectWithinBudget(results[2], p99: .milliseconds(20))
        }

        @Test("decodes request bodies of growing size, and fingerprints them")
        func decoding() async throws {
            let iterations = BenchmarkScale.iterations(2_000)
            let quarter = iterations / 4
            let smallBody = Data(#"{"module":"arithmetic","operation":"add","parameters":{"a":2,"b":3}}"#.utf8)
            let numbers = (0..<1_000).map(String.init).joined(separator: ",")
            let largeBody = Data(
                #"{"module":"statistics","operation":"mean","parameters":{"values":[\#(numbers)]}}"#.utf8
            )
            let decoded = try JSONDecoder().decode(CalculationRequestBody.self, from: largeBody)
            let fingerprinter = RequestFingerprinter()

            let results = [
                try await Self.measure("decode a small request", iterations: iterations) {
                    _ = try JSONDecoder().decode(CalculationRequestBody.self, from: smallBody)
                },
                try await Self.measure("decode a request with 1,000 numbers", iterations: quarter) {
                    _ = try JSONDecoder().decode(CalculationRequestBody.self, from: largeBody)
                },
                try await Self.measure("fingerprint a request with 1,000 numbers (SHA-256)", iterations: quarter) {
                    _ = try fingerprinter.fingerprint(of: decoded.calculationRequest)
                },
            ]

            try BenchmarkScale.publish(group: "serialization-decoding", results)
            expectWithinBudget(results[0], p99: .milliseconds(1))
            expectWithinBudget(results[1], p99: .milliseconds(20))
            expectWithinBudget(results[2], p99: .milliseconds(20))
        }

        @Test("formats timestamps, cursors and log lines")
        func small() async throws {
            let iterations = BenchmarkScale.iterations(5_000)
            let date = Date(timeIntervalSince1970: 1_791_028_800.123)
            let cursor = PageCursor(createdAt: date, id: RecordFixtures.id(1))
            let record = LogRecord(
                timestamp: Timestamp.format(date),
                level: .info,
                label: "codes.vapor.application",
                message: "Request completed",
                error: nil,
                fields: [
                    "method": "POST", "route": "/api/v1/calculations", "status": .stringConvertible(201),
                    "duration_ms": .stringConvertible(1.5), "request_id": "0192e4a1-7c3b-7d2e-8f4a-5b6c7d8e9f01",
                    "correlation_id": "0192e4a1-7c3b-7d2e-8f4a-5b6c7d8e9f01",
                ]
            )

            let results = [
                try await Self.measure("format a timestamp", iterations: iterations) { _ = Timestamp.format(date) },
                try await Self.measure("parse a timestamp", iterations: iterations) {
                    _ = Timestamp.parse("2026-10-03T12:00:00.123Z")
                },
                try await Self.measure("encode and decode a cursor", iterations: iterations) {
                    _ = PageCursorCodec.decode(PageCursorCodec.encode(cursor))
                },
                try await Self.measure("render a log line", iterations: iterations) { _ = LogLine.render(record) },
            ]

            try BenchmarkScale.publish(group: "serialization-small", results)
            for result in results {
                expectWithinBudget(result, p99: .milliseconds(1))
            }
        }
    }
}
