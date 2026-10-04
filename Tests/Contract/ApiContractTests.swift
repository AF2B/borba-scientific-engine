import BorbaScientificCore
import HTTPSupport
import InMemoryLogging
import TestSupport
import Testing
import Vapor

/// The HTTP API as a client sees it, over the production middleware, routing and error mapping with in-memory adapters.
@Suite("HTTP API contract")
struct ApiContractTests {
    private static let calculationsPath = "/api/v1/calculations"
    private static let idempotencyKeyHeader = "Idempotency-Key"
    private static let replayedHeader = "Idempotent-Replayed"
    private static let requestIDHeader = "X-Request-ID"
    private static let correlationIDHeader = "X-Correlation-ID"

    private static let add: CalculationValue = [
        "module": "arithmetic",
        "operation": "add",
        "parameters": ["a": 2, "b": 3],
    ]
    private static let addOther: CalculationValue = [
        "module": "arithmetic",
        "operation": "add",
        "parameters": ["a": 10, "b": 20],
    ]
    private static let divideByZero: CalculationValue = [
        "module": "arithmetic",
        "operation": "divide",
        "parameters": ["dividend": 1, "divisor": 0],
    ]

    // MARK: - Calculations

    @Test("runs a calculation, records it and returns it with its location")
    func executesACalculation() async throws {
        try await TestApplication.run { harness in
            let response = try await harness.client.post(Self.calculationsPath, json: Self.add)
            let json = try response.json()

            #expect(response.status == .created)
            #expect(json.at("status") == "succeeded")
            #expect(json.at("result") == 5)
            #expect(response.header("Location") == "\(Self.calculationsPath)/\(json.at("id")?.text ?? "")")
            #expect(await harness.repository.recordCount == 1)
        }
    }

    @Test("answers a failed calculation with an error that carries the recorded calculation")
    func reportsDomainFailures() async throws {
        try await TestApplication.run { harness in
            let response = try await harness.client.post(Self.calculationsPath, json: Self.divideByZero)
            let json = try response.json()

            #expect(response.status == .unprocessableEntity)
            #expect(json.at("error", "code") == "DIVISION_BY_ZERO")
            #expect(json.at("error", "calculation_id") != nil)
            #expect(await harness.repository.recordCount == 1)
        }
    }

    @Test("refuses unknown operations and invalid parameters without recording anything")
    func refusesBadCalculations() async throws {
        try await TestApplication.run { harness in
            let unknown: CalculationValue = ["module": "arithmetic", "operation": "teleport"]
            let invalid: CalculationValue = ["module": "arithmetic", "operation": "add", "parameters": ["a": "x"]]

            let unknownResponse = try await harness.client.post(Self.calculationsPath, json: unknown)
            let invalidResponse = try await harness.client.post(Self.calculationsPath, json: invalid)

            #expect(unknownResponse.status == .notFound)
            #expect(try unknownResponse.json().at("error", "code") == "UNSUPPORTED_OPERATION")
            #expect(invalidResponse.status == .unprocessableEntity)
            #expect(try invalidResponse.json().at("error", "code") == "VALIDATION_FAILED")
            #expect(await harness.repository.recordCount == 0)
        }
    }

    @Test("replays an identical request that reuses an idempotency key and rejects a different one")
    func honoursIdempotencyKeys() async throws {
        try await TestApplication.run { harness in
            let headers = [Self.idempotencyKeyHeader: "key-1"]

            let first = try await harness.client.post(Self.calculationsPath, json: Self.add, headers: headers)
            let second = try await harness.client.post(Self.calculationsPath, json: Self.add, headers: headers)
            let conflict = try await harness.client.post(Self.calculationsPath, json: Self.addOther, headers: headers)

            #expect(first.status == .created)
            #expect(second.status == .ok)
            #expect(second.header(Self.replayedHeader) == "true")
            #expect(try second.json().at("id") == first.json().at("id"))
            #expect(conflict.status == .unprocessableEntity)
            #expect(try conflict.json().at("error", "code") == "IDEMPOTENCY_KEY_REUSED")
            #expect(await harness.repository.recordCount == 1)
        }
    }

    @Test("runs a batch item by item, keeping the order and isolating failures")
    func executesABatch() async throws {
        try await TestApplication.run { harness in
            let batch: CalculationValue = ["calculations": [Self.add, Self.divideByZero, Self.addOther]]

            let response = try await harness.client.post("\(Self.calculationsPath)/batch", json: batch)
            let json = try response.json()

            #expect(response.status == .ok)
            #expect(json.at("results", 0, "calculation", "result") == 5)
            #expect(json.at("results", 1, "error", "code") == "DIVISION_BY_ZERO")
            #expect(json.at("results", 2, "calculation", "result") == 30)
            #expect(json.at("summary", "succeeded") == 2)
            #expect(json.at("summary", "failed") == 1)
        }
    }

    // MARK: - Errors and request identity

    @Test("returns the error envelope, with the request identifier, for malformed requests and unknown routes")
    func returnsTheErrorEnvelope() async throws {
        try await TestApplication.run { harness in
            let truncated = try await harness.client.post(Self.calculationsPath, body: "{")
            let typo = try await harness.client.post(
                Self.calculationsPath,
                body: #"{"module":"arithmetic","operation":"add","paramters":{}}"#
            )
            let notJSON = try await harness.client.post(Self.calculationsPath, body: "a=b", contentType: "text/plain")
            let missing = try await harness.client.get("/api/v1/nothing-here")

            #expect(truncated.status == .badRequest)
            #expect(try truncated.json().at("error", "code") == "INVALID_REQUEST")
            #expect(typo.status == .badRequest)
            #expect(try typo.json().at("error", "details", 0, "field") == "paramters")
            #expect(notJSON.status == .unsupportedMediaType)
            #expect(missing.status == .notFound)
            #expect(try missing.json().at("error", "code") == "NOT_FOUND")
            #expect(try missing.json().at("error", "request_id")?.text == missing.header(Self.requestIDHeader))
        }
    }

    @Test("adopts well-formed request identifiers and replaces malformed ones")
    func handlesRequestIdentifiers() async throws {
        try await TestApplication.run { harness in
            let adopted = try await harness.client.get(
                "/health",
                headers: [Self.requestIDHeader: "client-req-1", Self.correlationIDHeader: "client-corr-1"]
            )
            let replaced = try await harness.client.get("/health", headers: [Self.requestIDHeader: "has spaces"])
            let generated = try await harness.client.get("/health")

            #expect(adopted.header(Self.requestIDHeader) == "client-req-1")
            #expect(adopted.header(Self.correlationIDHeader) == "client-corr-1")
            #expect(replaced.header(Self.requestIDHeader) != "has spaces")
            #expect(generated.header(Self.correlationIDHeader) == generated.header(Self.requestIDHeader))
        }
    }

    @Test("sends security headers on every response")
    func sendsSecurityHeaders() async throws {
        try await TestApplication.run { harness in
            for path in ["/health", "/api/v1/nothing-here"] {
                let response = try await harness.client.get(path)

                #expect(response.header("X-Content-Type-Options") == "nosniff")
                #expect(response.header("Cache-Control") == "no-store")
            }
        }
    }

    @Test("writes one access line per request, with the route template, the status and the request identifier")
    func writesAccessLines() async throws {
        try await TestApplication.run { harness in
            let created = try await harness.client.post(Self.calculationsPath, json: Self.add)
            let identifier = try #require(created.json().at("id")?.text)
            _ = try await harness.client.get("\(Self.calculationsPath)/\(identifier)")
            _ = try await harness.client.get("/health")
            _ = try await harness.client.get("/nowhere")

            let lines = harness.logs.entries.filter { $0.message == "Request completed" }
            func line(_ method: String, _ route: String) -> InMemoryLogHandler.Entry? {
                lines.first {
                    $0.metadata["method"]?.description == method && $0.metadata["route"]?.description == route
                }
            }

            let post = try #require(line("POST", "/api/v1/calculations"))
            #expect(post.metadata["status"]?.description == "201")
            #expect(post.metadata[TraceMetadataKey.requestID] == .string(try #require(created.header("X-Request-ID"))))
            #expect(post.level == .info)
            #expect(line("GET", "/api/v1/calculations/:id") != nil, "the identifier is not a log dimension")
            #expect(lines.allSatisfy { !$0.metadata.values.map(\.description).joined().contains(identifier) })
            #expect(line("GET", "/health")?.level == .debug, "probes are logged at debug level")
            #expect(line("GET", "unmatched")?.metadata["status"]?.description == "404")
        }
    }

    @Test("publishes metrics that reflect what the service did, with bounded labels")
    func publishesMetrics() async throws {
        try await TestApplication.run { harness in
            let created = try await harness.client.post(Self.calculationsPath, json: Self.add)
            let identifier = try #require(created.json().at("id")?.text)
            _ = try await harness.client.post(Self.calculationsPath, json: Self.divideByZero)
            _ = try await harness.client.get("\(Self.calculationsPath)/\(identifier)")
            _ = try await harness.client.get("/nowhere-1")
            _ = try await harness.client.get("/nowhere-2")

            let response = try await harness.client.get("/metrics")
            let scrape = MetricsScrape(response.body)
            let addLabels = ["module": "arithmetic", "operation": "add"]

            #expect(response.status == .ok)
            #expect(response.header("Content-Type")?.hasPrefix("text/plain; version=0.0.4") == true)
            #expect(scrape.value("calculations_total", addLabels.merging(["status": "succeeded"]) { $1 }) == 1)
            #expect(scrape.value("calculations_total", ["operation": "divide", "status": "failed"]) == 1)
            #expect(scrape.value("calculation_failures_total", ["code": "DIVISION_BY_ZERO"]) == 1)
            #expect(scrape.value("calculation_duration_seconds_count", addLabels) == 1)
            #expect(
                scrape.value(
                    "http_requests_total",
                    ["method": "POST", "route": "/api/v1/calculations", "status": "201"]
                ) == 1
            )
            #expect(
                scrape.value(
                    "http_requests_total",
                    ["method": "POST", "route": "/api/v1/calculations", "status": "422"]
                ) == 1
            )
            #expect(
                scrape.value(
                    "http_requests_total",
                    ["method": "GET", "route": "/api/v1/calculations/:id", "status": "200"]
                ) == 1
            )
            #expect(
                scrape.value("http_requests_total", ["method": "undefined", "route": "unmatched", "status": "404"])
                    == 2,
                "unknown paths share one series"
            )
            #expect(scrape.value("http_requests_in_flight") == 1, "the scrape itself is the only request in flight")
            #expect(!response.body.contains(identifier), "an identifier is never a label")
            #if os(Linux)
                #expect((scrape.value("process_resident_memory_bytes") ?? 0) > 0)
            #endif
        }
    }

    // MARK: - History, catalog and operations

    @Test("lists the history page by page and finds a calculation by identifier")
    func readsTheHistory() async throws {
        try await TestApplication.run { harness in
            let created = try await harness.client.post(Self.calculationsPath, json: Self.add)
            harness.clock.advance(by: .seconds(1))
            _ = try await harness.client.post(Self.calculationsPath, json: Self.addOther)

            let firstPage = try await harness.client.get("\(Self.calculationsPath)?limit=1").json()
            let cursor = try #require(firstPage.at("page", "next_cursor")?.text)
            let secondPage = try await harness.client.get("\(Self.calculationsPath)?limit=1&cursor=\(cursor)").json()
            let identifier = try #require(created.json().at("id")?.text)
            let found = try await harness.client.get("\(Self.calculationsPath)/\(identifier)")

            #expect(firstPage.at("items", 0, "result") == 30)
            #expect(secondPage.at("items", 0, "result") == 5)
            #expect(secondPage.at("page", "next_cursor") == .null)
            #expect(found.status == .ok)
            #expect(try found.json().at("id")?.text == identifier)
        }
    }

    @Test("rejects bad history queries and unknown identifiers")
    func rejectsBadHistoryQueries() async throws {
        try await TestApplication.run { harness in
            let badQuery = try await harness.client.get("\(Self.calculationsPath)?limit=0&staus=failed")
            let badID = try await harness.client.get("\(Self.calculationsPath)/not-a-uuid")
            let unknownID = try await harness.client.get(
                "\(Self.calculationsPath)/00000000-0000-7000-8000-000000000000"
            )

            #expect(badQuery.status == .badRequest)
            #expect(try badQuery.json().at("error", "details")?.elements?.count == 2)
            #expect(badID.status == .badRequest)
            #expect(unknownID.status == .notFound)
            #expect(try unknownID.json().at("error", "code") == "CALCULATION_NOT_FOUND")
        }
    }

    @Test("describes the supported calculation types and the parameters of one operation")
    func describesTheCatalog() async throws {
        try await TestApplication.run { harness in
            let types = try await harness.client.get("/api/v1/types").json()
            let metadata = try await harness.client.get("/api/v1/types/arithmetic/add")
            let unknown = try await harness.client.get("/api/v1/types/arithmetic/teleport")

            #expect(types.at("types")?.elements?.contains { $0.at("type") == "arithmetic.add" } == true)
            #expect(metadata.status == .ok)
            #expect(try metadata.json().at("parameters", 0, "name") == "a")
            #expect(try metadata.json().at("parameters", 0, "required") == true)
            #expect(unknown.status == .notFound)
        }
    }

    @Test("reports liveness and the running version")
    func reportsLivenessAndVersion() async throws {
        try await TestApplication.run { harness in
            let health = try await harness.client.get("/health")
            let version = try await harness.client.get("/version")

            #expect(try health.json().at("status") == "alive")
            #expect(try version.json().at("name") == "borba-scientific-engine")
            #expect(try version.json().at("api_versions", 0) == "v1")
        }
    }
}
