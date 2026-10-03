import BorbaScientificCore
import Foundation
import Vapor

/// A request body contained a field the endpoint does not know. Silently ignoring it would hide typos such as
/// `paramters`, so the request is rejected instead.
struct UnknownFieldsError: Error, Equatable {
    /// Where the object sits in the body, such as `calculations[2]`; empty for the top level.
    let path: String

    /// The unrecognised field names, sorted.
    let fields: [String]
}

/// A coding key built from any string, used to look at the keys an object really contains.
struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

extension Decoder {
    /// Rejects objects that carry fields beyond the expected ones.
    ///
    /// - Parameter allowed: The field names the object may contain.
    /// - Throws: ``UnknownFieldsError`` naming the extra fields.
    func rejectUnknownFields(allowed: Set<String>) throws {
        let container = try container(keyedBy: DynamicCodingKey.self)
        let unknown = container.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()

        guard unknown.isEmpty else {
            throw UnknownFieldsError(path: FieldPath.render(codingPath), fields: unknown)
        }
    }
}

/// Renders the position of a value inside a JSON document the way a client wrote it: `calculations[2].parameters`.
enum FieldPath {
    private static let separator = "."

    /// Renders a coding path.
    ///
    /// - Parameter path: The coding path of a value.
    /// - Returns: The dotted path with array indexes in brackets; empty for the top level.
    static func render(_ path: [any CodingKey]) -> String {
        path.reduce(into: "") { rendered, key in
            if let index = key.intValue {
                rendered += "[\(index)]"
            } else if rendered.isEmpty {
                rendered = key.stringValue
            } else {
                rendered += separator + key.stringValue
            }
        }
    }

    /// Appends a field to a path.
    ///
    /// - Parameters:
    ///   - field: The field name.
    ///   - path: The path of the object that contains it.
    /// - Returns: The path of the field.
    static func join(
        _ field: String,
        under path: String
    ) -> String {
        path.isEmpty ? field : path + separator + field
    }
}

extension Request {
    private static let jsonType = "application"
    private static let jsonSubtype = "json"

    private static let missingBodyReason = "A JSON body is required."
    private static let notJSONReason = "The body is not valid JSON."
    private static let requiredReason = "is required"
    private static let wrongTypeReason = "has the wrong type"
    private static let nullReason = "must not be null"
    private static let malformedReason = "is malformed"
    private static let unknownFieldReason = "is not a recognised field"

    /// Reads the body as JSON.
    ///
    /// Problems the caller can fix are reported as ``APIFailure/invalidRequest(details:)`` with one detail per
    /// offending field. Details name fields and never repeat what the caller sent.
    ///
    /// - Parameter type: The type to decode.
    /// - Returns: The decoded body.
    /// - Throws: ``APIFailure/unsupportedMediaType`` when the body is not declared as JSON and
    ///   ``APIFailure/invalidRequest(details:)`` when it is missing, unreadable or does not match the type.
    func decodeJSONBody<Body: Decodable>(_ type: Body.Type) throws(APIFailure) -> Body {
        guard let contentType = headers.contentType, contentType.type == Self.jsonType,
            contentType.subType == Self.jsonSubtype
        else {
            throw .unsupportedMediaType
        }
        guard let buffer = body.data, buffer.readableBytes > 0 else {
            throw .invalidRequest(details: [ErrorDetail(reason: Self.missingBodyReason)])
        }

        do {
            return try JSONCoding.makeDecoder().decode(type, from: Data(buffer.readableBytesView))
        } catch let unknown as UnknownFieldsError {
            throw .invalidRequest(
                details: unknown.fields.map {
                    ErrorDetail(field: FieldPath.join($0, under: unknown.path), reason: Self.unknownFieldReason)
                }
            )
        } catch let error as DecodingError {
            throw .invalidRequest(details: [Self.detail(for: error)])
        } catch {
            throw .invalidRequest(details: [ErrorDetail(reason: Self.notJSONReason)])
        }
    }

    private static func detail(for error: DecodingError) -> ErrorDetail {
        switch error {
        case .keyNotFound(let key, let context):
            ErrorDetail(field: FieldPath.render(context.codingPath + [key]), reason: requiredReason)
        case .typeMismatch(_, let context):
            ErrorDetail(field: nonEmpty(FieldPath.render(context.codingPath)), reason: wrongTypeReason)
        case .valueNotFound(_, let context):
            ErrorDetail(field: nonEmpty(FieldPath.render(context.codingPath)), reason: nullReason)
        case .dataCorrupted(let context):
            context.codingPath.isEmpty
                ? ErrorDetail(reason: notJSONReason)
                : ErrorDetail(field: FieldPath.render(context.codingPath), reason: malformedReason)
        @unknown default:
            ErrorDetail(reason: notJSONReason)
        }
    }

    private static func nonEmpty(_ path: String) -> String? {
        path.isEmpty ? nil : path
    }

    /// Builds a JSON response.
    ///
    /// - Parameters:
    ///   - body: The value to serialize.
    ///   - status: The HTTP status.
    ///   - headers: Extra headers; `Content-Type` is set to JSON.
    /// - Returns: The response.
    /// - Throws: An encoding error when the value cannot be serialized.
    func jsonResponse<Body: Encodable>(
        _ body: Body,
        status: HTTPResponseStatus = .ok,
        headers: HTTPHeaders = [:]
    ) throws -> Response {
        var headers = headers
        headers.contentType = .json

        let data = try JSONCoding.makeEncoder().encode(body)
        return Response(status: status, headers: headers, body: .init(data: data))
    }
}
