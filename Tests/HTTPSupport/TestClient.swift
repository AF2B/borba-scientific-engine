public import BorbaScientificCore
import Foundation
public import Vapor
import VaporTesting

/// What a test sees of a response.
public struct TestResponse: Sendable {
    /// The HTTP status.
    public let status: HTTPResponseStatus

    /// The response headers.
    public let headers: HTTPHeaders

    /// The body as text.
    public let body: String

    /// Reads a header.
    ///
    /// - Parameter name: The header name, in any case.
    /// - Returns: The first value, or `nil` when the header is absent.
    public func header(_ name: String) -> String? {
        headers.first(name: name)
    }

    /// Parses the body as JSON.
    ///
    /// - Returns: The body as a generic JSON value, so tests assert on the wire format and not on the types that
    ///   produced it.
    /// - Throws: A decoding error when the body is not JSON.
    public func json() throws -> CalculationValue {
        try JSONDecoder().decode(CalculationValue.self, from: Data(body.utf8))
    }
}

/// One step of a path into a JSON document: an object key or an array index.
public enum JSONStep: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    case key(String)
    case index(Int)

    /// Creates a step that names an object key.
    ///
    /// - Parameter value: The key.
    public init(stringLiteral value: String) {
        self = .key(value)
    }

    /// Creates a step that selects an array element.
    ///
    /// - Parameter value: The zero-based index.
    public init(integerLiteral value: Int) {
        self = .index(value)
    }
}

extension CalculationValue {
    /// Follows a path of keys and indexes into a JSON document.
    ///
    /// - Parameter steps: Object keys and array indexes, outermost first.
    /// - Returns: The value at the path, or `nil` when any step does not exist.
    public func at(_ steps: JSONStep...) -> CalculationValue? {
        var current: CalculationValue? = self

        for step in steps {
            switch step {
            case .key(let name):
                current = current?.fields?[name]
            case .index(let position):
                guard let elements = current?.elements, elements.indices.contains(position) else {
                    return nil
                }
                current = elements[position]
            }
        }
        return current
    }
}

/// Sends requests through the full HTTP stack of a test application — routing, middleware, handlers and error
/// mapping — without opening a socket.
public struct TestClient: Sendable {
    /// The media type of a JSON body.
    public static let jsonMediaType = "application/json"

    private let tester: any TestingApplicationTester

    init(tester: any TestingApplicationTester) {
        self.tester = tester
    }

    /// Sends a `GET` request.
    ///
    /// - Parameters:
    ///   - path: The path and query string.
    ///   - headers: Request headers.
    /// - Returns: The response.
    /// - Throws: An error when the request could not be performed.
    public func get(
        _ path: String,
        headers: [String: String] = [:]
    ) async throws -> TestResponse {
        try await send(.GET, path, headers: headers, body: nil)
    }

    /// Sends a `POST` request with a JSON body.
    ///
    /// - Parameters:
    ///   - path: The path.
    ///   - json: The body, written as JSON.
    ///   - headers: Request headers.
    /// - Returns: The response.
    /// - Throws: An error when the body cannot be encoded or the request could not be performed.
    public func post(
        _ path: String,
        json: CalculationValue,
        headers: [String: String] = [:]
    ) async throws -> TestResponse {
        let data = try JSONEncoder().encode(json)

        return try await post(
            path,
            body: String(bytes: data, encoding: .utf8) ?? "",
            contentType: Self.jsonMediaType,
            headers: headers
        )
    }

    /// Sends a `POST` request with a body written by the test, which lets it send malformed JSON.
    ///
    /// - Parameters:
    ///   - path: The path.
    ///   - body: The raw body.
    ///   - contentType: The `Content-Type` header, or `nil` to send none.
    ///   - headers: Request headers.
    /// - Returns: The response.
    /// - Throws: An error when the request could not be performed.
    public func post(
        _ path: String,
        body: String,
        contentType: String? = TestClient.jsonMediaType,
        headers: [String: String] = [:]
    ) async throws -> TestResponse {
        var headers = headers
        if let contentType {
            headers["Content-Type"] = contentType
        }
        return try await send(.POST, path, headers: headers, body: ByteBuffer(string: body))
    }

    /// Sends a request.
    ///
    /// - Parameters:
    ///   - method: The HTTP method.
    ///   - path: The path and query string.
    ///   - headers: Request headers.
    ///   - body: The body, if any.
    /// - Returns: The response.
    /// - Throws: An error when the request could not be performed.
    public func send(
        _ method: HTTPMethod,
        _ path: String,
        headers: [String: String],
        body: ByteBuffer?
    ) async throws -> TestResponse {
        var requestHeaders = HTTPHeaders()
        for (name, value) in headers {
            requestHeaders.add(name: name, value: value)
        }

        let response = try await tester.sendRequest(method, path, headers: requestHeaders, body: body)
        return TestResponse(status: response.status, headers: response.headers, body: response.body.string)
    }
}
