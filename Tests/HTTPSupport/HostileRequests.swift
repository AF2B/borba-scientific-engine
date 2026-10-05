import BorbaScientificCore
import Foundation
public import Vapor

@testable import BorbaScientificEngine

/// One thing a client that means harm can send.
public struct HostileRequest: Sendable {
    /// What it is, for the report.
    public let label: String

    /// The HTTP method.
    public let method: HTTPMethod

    /// The path and query string, as written.
    public let path: String

    /// The request headers.
    public let headers: [String: String]

    /// The raw body, if any.
    public let body: [UInt8]?

    init(
        label: String,
        method: HTTPMethod,
        path: String,
        headers: [String: String] = [:],
        body: [UInt8]? = nil
    ) {
        self.label = label
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

/// The part of the error envelope that says there is one. It is read with a decoder of its own, because the decoder of
/// calculation values refuses a NUL, and an error may quote one that the caller sent.
private struct ErrorEnvelope: Decodable {
    struct Body: Decodable {
        let code: String
    }

    let error: Body
}

/// What a client that means harm can send to the API: bodies, headers, paths, queries and methods that are malformed,
/// oversized, nested, encoded wrongly or aimed at the seams between layers, and every operation's example with one
/// parameter replaced by a value that tends to break whatever stores or computes it.
///
/// None of it may produce a server error, none of it may escape the error envelope, and the service must still answer
/// afterwards. A `5xx` on one of these is a bug that a caller could trigger at will. Run it against every adapter, because
/// what a database refuses is not what a test double refuses.
public enum HostileRequests {
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

    /// The body of an `expression.evaluate` request, from the JSON text of its expression and of its variables.
    private static func evaluating(
        _ expression: String,
        variables: String
    ) -> String {
        #"{"module":"expression","operation":"evaluate","parameters":"#
            + #"{"expression":"\#(expression)","variables":\#(variables)}}"#
    }

    private static func cursor(
        _ label: String,
        microseconds: Int64
    ) -> HostileRequest {
        let payload = "v1.\(microseconds).00000000-0000-7000-8000-000000000001"
        let token = Base64URL.encode(Data(payload.utf8))

        return HostileRequest(label: label, method: .GET, path: "\(calculationsPath)?cursor=\(token)")
    }

    private static func nested(_ open: String, _ close: String) -> String {
        String(repeating: open, count: nestingDepth) + String(repeating: close, count: nestingDepth)
    }

    private static var handWritten: [HostileRequest] {
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

            HostileRequest(
                label: "a date in the year 99999",
                method: .GET,
                path: "\(calculationsPath)?created_from=99999-01-01T00:00:00Z"
            ),
            HostileRequest(
                label: "a date in the year 999999",
                method: .GET,
                path: "\(calculationsPath)?created_from=999999-01-01T00:00:00Z"
            ),
            HostileRequest(
                label: "a date in the year 9999999",
                method: .GET,
                path: "\(calculationsPath)?created_before=9999999-01-01T00:00:00Z"
            ),
            HostileRequest(
                label: "a date in the year zero",
                method: .GET,
                path: "\(calculationsPath)?created_before=0000-01-01T00:00:00Z"
            ),
            cursor("a cursor at the greatest instant", microseconds: Int64.max),
            cursor("a cursor at the least instant", microseconds: Int64.min),
            cursor("a cursor past the year 9999", microseconds: 253_402_300_800_000_000),
            cursor("a cursor at the end of the year 9999", microseconds: 253_402_300_799_999_999),
            cursor("a cursor at the epoch", microseconds: 0),
            post("a NUL in the name of a variable", evaluating("x", variables: #"{"x\u0000":1}"#)),
            post("a NUL in the middle of an expression", evaluating(#"1+\u00002"#, variables: "{}")),
            HostileRequest(
                label: "a module filter that is a NUL",
                method: .GET,
                path: "\(calculationsPath)?module=%00"
            ),
            HostileRequest(
                label: "a module filter with a NUL inside",
                method: .GET,
                path: "\(calculationsPath)?module=a%00b"
            ),
            HostileRequest(
                label: "an operation filter that is a NUL",
                method: .GET,
                path: "\(calculationsPath)?operation=%00"
            ),
            HostileRequest(
                label: "a filter with an invalid UTF-8 escape",
                method: .GET,
                path: "\(calculationsPath)?module=%FF%FE"
            ),
            HostileRequest(
                label: "a filter with an overlong UTF-8 escape",
                method: .GET,
                path: "\(calculationsPath)?module=%C0%80"
            ),
        ]
    }

    /// Every example of every operation, with each of its parameters replaced, one at a time, by values that tend to break
    /// storage: text with a NUL, which PostgreSQL refuses in text and in JSON; numbers at the edges of what a double and a
    /// JSON number hold; an empty list.
    private static var generated: [HostileRequest] {
        let numbers: [Double] = [1e308, -1e308, .leastNonzeroMagnitude]
        var requests: [HostileRequest] = []

        for module in ModuleRegistry.standard().modules {
            for operation in module.operations {
                guard let example = operation.examples.first else {
                    continue
                }

                for (name, original) in example.parameters.sorted(by: { $0.key < $1.key }) {
                    var replacements: [(label: String, value: CalculationValue)] = []
                    switch original {
                    case .text(let text):
                        replacements.append(("text with a NUL", .text(text + "\u{0}")))
                    case .number:
                        replacements += numbers.map { ("the number \($0)", .number($0)) }
                    case .list:
                        replacements.append(("an empty list", .list([])))
                    case .boolean, .object, .null:
                        break
                    }

                    for replacement in replacements {
                        var parameters = example.parameters
                        parameters[name] = replacement.value
                        let request: CalculationValue = [
                            "module": .text(operation.type.module.rawValue),
                            "operation": .text(operation.type.operation.rawValue),
                            "parameters": .object(parameters),
                        ]
                        guard let encoded = try? JSONEncoder().encode(request) else {
                            continue
                        }
                        requests.append(
                            HostileRequest(
                                label: "\(operation.type) with \(name) as \(replacement.label)",
                                method: .POST,
                                path: calculationsPath,
                                headers: jsonHeaders,
                                body: Array(encoded)
                            )
                        )
                    }
                }
            }
        }
        return requests
    }

    /// Every hostile request.
    public static let all: [HostileRequest] = handWritten + generated

    /// Sends every hostile request to a running application.
    ///
    /// - Parameter client: The client of the application to attack.
    /// - Returns: What went wrong, one line per request: an answer in the `5xx` range, or an error that is not in the
    ///   documented envelope. Empty when the application held.
    /// - Throws: An error when a request could not be performed at all.
    public static func problems(in client: TestClient) async throws -> [String] {
        var problems: [String] = []

        for request in all {
            let response = try await client.send(
                request.method,
                request.path,
                headers: request.headers,
                body: request.body.map { ByteBuffer(bytes: $0) }
            )
            let status = Int(response.status.code)
            let code = (try? JSONDecoder().decode(ErrorEnvelope.self, from: Data(response.body.utf8)))?.error.code

            if status >= firstServerError {
                problems.append("\(request.label): answered \(status)")
            } else if status >= firstClientError, request.method != .HEAD, code == nil {
                problems.append("\(request.label): answered \(status) outside the error envelope")
            }
        }
        return problems
    }
}
