import BorbaScientificCore
import Foundation
import HTTPSupport
import NIOCore
import TestSupport
import Testing
import Vapor

@testable import BorbaScientificEngine

/// What a client that means harm can send. None of it may produce a server error, none of it may escape the error
/// envelope, and the service must still answer afterwards. A `5xx` here is a bug the caller could trigger at will.
@Suite("Hostile requests", .timeLimit(.minutes(2)))
struct HostileRequestTests {
    private struct HostileRequest {
        let label: String
        let method: HTTPMethod
        let path: String
        var headers: [String: String] = [:]
        var body: [UInt8]?
    }

    private static let calculationsPath = "/api/v1/calculations"
    private static let batchPath = "/api/v1/calculations/batch"
    private static let jsonHeaders = ["Content-Type": TestClient.jsonMediaType]
    private static let nestingDepth = 100_000
    private static let longValueLength = 10_000
    private static let firstServerError = 500
    private static let firstClientError = 400

    private static func body(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    private static func post(
        _ label: String,
        _ text: String,
        path: String = calculationsPath
    ) -> HostileRequest {
        HostileRequest(label: label, method: .POST, path: path, headers: jsonHeaders, body: body(text))
    }

    private static let mean = #"{"module":"statistics","operation":"mean","parameters":{"values":[1,2,3]}}"#

    private static func nested(_ open: String, _ close: String) -> String {
        String(repeating: open, count: nestingDepth) + String(repeating: close, count: nestingDepth)
    }

    private static var requests: [HostileRequest] {
        let longText = String(repeating: "x", count: longValueLength)
        let newline = "\n"

        return [
            post(
                "arrays nested a hundred thousand deep",
                #"{"module":"statistics","operation":"mean","parameters":{"values":"#
                    + nested("[", "]") + "}}"
            ),
            post(
                "objects nested a hundred thousand deep",
                #"{"module":"arithmetic","operation":"add","parameters":"#
                    + String(repeating: #"{"a":"#, count: nestingDepth) + "1"
                    + String(repeating: "}", count: nestingDepth) + "}"
            ),
            post(
                "a number no double holds",
                #"{"module":"arithmetic","operation":"add","parameters":{"a":1e999,"b":1}}"#
            ),
            post(
                "a number below what a double holds",
                #"{"module":"arithmetic","operation":"add","parameters":{"a":1e-999,"b":1}}"#
            ),
            post(
                "a number with a hundred thousand digits",
                #"{"module":"arithmetic","operation":"add","parameters":{"a":"#
                    + String(repeating: "9", count: nestingDepth) + #","b":1}}"#
            ),
            post(
                "duplicate keys",
                #"{"module":"arithmetic","module":"statistics","operation":"add","parameters":{"a":1,"b":2}}"#
            ),
            post(
                "a key ten thousand characters long",
                #"{"module":"arithmetic","operation":"add","parameters":{"\#(longText)":1}}"#
            ),
            post(
                "a module name ten thousand characters long",
                #"{"module":"\#(longText)","operation":"add","parameters":{}}"#
            ),
            post("a NUL in a name", #"{"module":"arith\u0000metic","operation":"add","parameters":{"a":1,"b":2}}"#),
            post("a lone surrogate escape", #"{"module":"\ud800","operation":"add","parameters":{}}"#),
            post("a byte order mark", "\u{FEFF}" + mean),
            post("an empty body", ""),
            post("a body that is only whitespace", "   \(newline)  "),
            post("null", "null"),
            post("a list", "[]"),
            post("a string", #""text""#),
            post("a number", "1"),
            post("truncated JSON", #"{"module":"statistics","operation":"#),
            post("trailing garbage", mean + "garbage"),
            post("a comment", "/* hi */" + mean),
            post("single quotes", "{'module':'statistics'}"),
            post("every field null", #"{"module":null,"operation":null,"parameters":null}"#),
            post("every field the wrong type", #"{"module":1,"operation":true,"parameters":[]}"#),
            post("parameters as a deep list", #"{"module":"statistics","operation":"mean","parameters":[[[[1]]]]}"#),
            post("a batch that is not a list", #"{"calculations":"x"}"#, path: batchPath),
            post("a batch with a null in it", #"{"calculations":[null]}"#, path: batchPath),
            post("a batch of arrays nested deep", #"{"calculations":"# + nested("[", "]") + "}", path: batchPath),
            post("an empty batch", #"{"calculations":[]}"#, path: batchPath),
            HostileRequest(
                label: "invalid UTF-8",
                method: .POST,
                path: calculationsPath,
                headers: jsonHeaders,
                body: [0x7B, 0xFF, 0xFE, 0x7D]
            ),
            HostileRequest(
                label: "JSON sent as text",
                method: .POST,
                path: calculationsPath,
                headers: ["Content-Type": "text/plain"],
                body: body(mean)
            ),
            HostileRequest(
                label: "JSON sent as a form",
                method: .POST,
                path: calculationsPath,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: body(mean)
            ),
            HostileRequest(label: "no content type", method: .POST, path: calculationsPath, body: body(mean)),
            HostileRequest(
                label: "a content type that is not one",
                method: .POST,
                path: calculationsPath,
                headers: ["Content-Type": "💥"],
                body: body(mean)
            ),
            HostileRequest(
                label: "an idempotency key ten thousand characters long",
                method: .POST,
                path: calculationsPath,
                headers: jsonHeaders.merging(["Idempotency-Key": longText]) { $1 },
                body: body(mean)
            ),
            HostileRequest(
                label: "an empty idempotency key",
                method: .POST,
                path: calculationsPath,
                headers: jsonHeaders.merging(["Idempotency-Key": ""]) { $1 },
                body: body(mean)
            ),
            HostileRequest(
                label: "an idempotency key with control characters",
                method: .POST,
                path: calculationsPath,
                headers: jsonHeaders.merging(["Idempotency-Key": "a\tb\u{7F}c"]) { $1 },
                body: body(mean)
            ),
            HostileRequest(
                label: "an idempotency key with unicode",
                method: .POST,
                path: calculationsPath,
                headers: jsonHeaders.merging(["Idempotency-Key": "ключ-🔑"]) { $1 },
                body: body(mean)
            ),
            HostileRequest(
                label: "a request id ten thousand characters long",
                method: .GET,
                path: "/health",
                headers: ["X-Request-ID": longText]
            ),
            HostileRequest(
                label: "a request id that tries to inject a log line",
                method: .GET,
                path: "/health",
                headers: ["X-Request-ID": "abc\" ,\"level\":\"critical"]
            ),
            HostileRequest(
                label: "a correlation id with markup",
                method: .GET,
                path: "/health",
                headers: ["X-Correlation-ID": "<script>alert(1)</script>"]
            ),

            HostileRequest(label: "a limit below one", method: .GET, path: "\(calculationsPath)?limit=-1"),
            HostileRequest(
                label: "a limit no integer holds",
                method: .GET,
                path: "\(calculationsPath)?limit=99999999999999999999"
            ),
            HostileRequest(label: "a limit that is text", method: .GET, path: "\(calculationsPath)?limit=lots"),
            HostileRequest(label: "a repeated limit", method: .GET, path: "\(calculationsPath)?limit=1&limit=2"),
            HostileRequest(label: "an empty cursor", method: .GET, path: "\(calculationsPath)?cursor="),
            HostileRequest(
                label: "a cursor ten thousand characters long",
                method: .GET,
                path: "\(calculationsPath)?cursor=\(longText)"
            ),
            HostileRequest(label: "a status that is a NUL", method: .GET, path: "\(calculationsPath)?status=%00"),
            HostileRequest(
                label: "a module ten thousand characters long",
                method: .GET,
                path: "\(calculationsPath)?module=\(longText)"
            ),
            HostileRequest(
                label: "a date that does not exist",
                method: .GET,
                path: "\(calculationsPath)?created_from=0000-00-00T00:00:00Z"
            ),
            HostileRequest(
                label: "a leap second",
                method: .GET,
                path: "\(calculationsPath)?created_before=2026-12-31T23:59:60Z"
            ),
            HostileRequest(
                label: "a date in the year ten thousand",
                method: .GET,
                path: "\(calculationsPath)?created_before=10000-01-01T00:00:00Z"
            ),
            HostileRequest(
                label: "a date before the year one",
                method: .GET,
                path: "\(calculationsPath)?created_from=-0001-01-01T00:00:00Z"
            ),
            HostileRequest(label: "a query that is only an ampersand", method: .GET, path: "\(calculationsPath)?&&&"),
            HostileRequest(
                label: "an identifier that is not one",
                method: .GET,
                path: "\(calculationsPath)/not-a-uuid"
            ),
            HostileRequest(label: "an identifier that is a NUL", method: .GET, path: "\(calculationsPath)/%00"),
            HostileRequest(
                label: "an identifier ten thousand characters long",
                method: .GET,
                path: "\(calculationsPath)/\(longText)"
            ),
            HostileRequest(label: "a traversal in the path", method: .GET, path: "/api/v1/types/%2e%2e/%2e%2e/health"),
            HostileRequest(label: "an unknown module", method: .GET, path: "/api/v1/types/%F0%9F%92%A5/boom"),
            HostileRequest(label: "an unknown version", method: .GET, path: "/api/v2/calculations"),
            HostileRequest(label: "the root", method: .GET, path: "/"),
            HostileRequest(
                label: "PATCH on the collection",
                method: .PATCH,
                path: calculationsPath,
                headers: jsonHeaders,
                body: body(mean)
            ),
            HostileRequest(label: "DELETE on the collection", method: .DELETE, path: calculationsPath),
            HostileRequest(label: "PUT on an operational endpoint", method: .PUT, path: "/health"),
            HostileRequest(label: "OPTIONS on the collection", method: .OPTIONS, path: calculationsPath),
            HostileRequest(label: "HEAD on the collection", method: .HEAD, path: calculationsPath),
        ]
    }

    @Test("every hostile request is refused inside the error envelope, and the service stays up")
    func hostileRequestsNeverCauseAServerError() async throws {
        try await TestApplication.run { harness in
            var problems: [String] = []

            for request in Self.requests {
                let response = try await harness.client.send(
                    request.method,
                    request.path,
                    headers: request.headers,
                    body: request.body.map { ByteBuffer(bytes: $0) }
                )
                let status = Int(response.status.code)
                let hasEnvelope = (try? response.json().at("error", "code")?.text) != nil

                if status >= Self.firstServerError {
                    problems.append("\(request.label): answered \(status)")
                } else if status >= Self.firstClientError, request.method != .HEAD, !hasEnvelope {
                    problems.append("\(request.label): answered \(status) outside the error envelope")
                }
            }

            let health = try await harness.client.get("/health")
            let ready = try await harness.client.get("/ready")
            let metrics = try await harness.client.get("/metrics")

            #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
            #expect(health.status == .ok && ready.status == .ok && metrics.status == .ok)
        }
    }

    @Test("never echoes a hostile request identifier back to the caller")
    func replacesHostileTraceIdentifiers() async throws {
        let hostile = "abc\" ,\"level\":\"critical"

        try await TestApplication.run { harness in
            let response = try await harness.client.get("/health", headers: ["X-Request-ID": hostile])

            let adopted = try #require(response.header("X-Request-ID"))
            #expect(adopted != hostile)
            #expect(adopted.allSatisfy { $0.isLetter || $0.isNumber || "._:-".contains($0) })
        }
    }
}
