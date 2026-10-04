import BorbaScientificCore
import Foundation
import TestSupport

@testable import BorbaScientificEngine

/// The published OpenAPI document, loaded so the tests can hold the running API to it.
struct OpenAPIDocument {
    private static let repositoryDepthFromThisFile = 3
    private static let documentPath = "Documentation/API/openapi.json"
    private static let referencePrefix = "#/"
    private static let referenceSeparator: Character = "/"
    private static let methods = ["get", "post", "put", "patch", "delete", "head", "options"]

    /// The root of the repository, found relative to this file.
    static var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<repositoryDepthFromThisFile {
            url.deleteLastPathComponent()
        }
        return url
    }

    /// The parsed document.
    let root: CalculationValue

    /// Reads `Documentation/API/openapi.json` from the repository.
    ///
    /// - Returns: The document.
    /// - Throws: An error when the file is missing or is not JSON.
    static func load() throws -> OpenAPIDocument {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(documentPath))

        return OpenAPIDocument(root: try JSONDecoder().decode(CalculationValue.self, from: data))
    }

    /// Every documented operation, as `METHOD /path/{template}`.
    var operations: Set<String> {
        var found: Set<String> = []
        for (path, item) in root.at("paths")?.fields ?? [:] {
            for method in Self.methods where item.fields?[method] != nil {
                found.insert("\(method.uppercased()) \(path)")
            }
        }
        return found
    }

    /// The error codes the document enumerates.
    var errorCodes: Set<String> {
        Set(root.at("components", "schemas", "ErrorCode", "enum")?.elements?.compactMap(\.text) ?? [])
    }

    /// Every status any operation documents.
    var documentedStatuses: Set<String> {
        var statuses: Set<String> = []
        for item in root.at("paths")?.fields?.values ?? [:].values {
            for method in Self.methods {
                statuses.formUnion(item.fields?[method]?.at("responses")?.fields?.keys ?? [:].keys)
            }
        }
        return statuses
    }

    /// Follows a `$ref` such as `#/components/schemas/Calculation`.
    ///
    /// - Parameter value: A schema, response or header that may be a reference.
    /// - Returns: The referenced value, resolved recursively, or the value itself when it is not a reference.
    func resolve(_ value: CalculationValue) -> CalculationValue? {
        guard let reference = value.at("$ref")?.text else {
            return value
        }
        guard reference.hasPrefix(Self.referencePrefix) else {
            return nil
        }

        var current: CalculationValue? = root
        for step in reference.dropFirst(Self.referencePrefix.count).split(separator: Self.referenceSeparator) {
            current = current?.fields?[String(step)]
        }
        return current.flatMap(resolve)
    }

    /// Every `$ref` in the document, to check that none dangles.
    var references: [String] {
        var found: [String] = []
        collectReferences(in: root, into: &found)
        return found
    }

    private func collectReferences(
        in value: CalculationValue,
        into found: inout [String]
    ) {
        switch value {
        case .object(let fields):
            for (key, child) in fields {
                if key == "$ref", let reference = child.text {
                    found.append(reference)
                } else {
                    collectReferences(in: child, into: &found)
                }
            }
        case .list(let elements):
            for element in elements {
                collectReferences(in: element, into: &found)
            }
        case .null, .boolean, .number, .text:
            break
        }
    }

    /// The documented response of an operation.
    ///
    /// - Parameters:
    ///   - method: The HTTP method, in any case.
    ///   - template: The path template, such as `/api/v1/calculations/{id}`.
    ///   - status: The HTTP status.
    /// - Returns: The response object, with references resolved, or `nil` when the operation does not document it.
    func response(
        method: String,
        template: String,
        status: UInt
    ) -> CalculationValue? {
        root.at("paths", .key(template), .key(method.lowercased()), "responses", .key(String(status))).flatMap(resolve)
    }
}

/// One way a body failed to match its schema.
struct SchemaViolation: CustomStringConvertible {
    /// Where in the body, such as `$.items[2].created_at`.
    let path: String

    /// What is wrong.
    let message: String

    var description: String {
        "\(path): \(message)"
    }
}

/// A validator for the subset of JSON Schema the document uses: `$ref`, `type`, `enum`, `properties`, `required`,
/// `additionalProperties`, `items`, length and range limits, and the `uuid` and `date-time` formats.
///
/// It is deliberately strict where the document is: a property the schema does not list is a violation, so a field
/// added to a response without being documented fails the contract.
struct SchemaValidator {
    let document: OpenAPIDocument

    /// Checks a value against a schema.
    ///
    /// - Parameters:
    ///   - instance: The value to check.
    ///   - schema: The schema, which may be a `$ref`.
    ///   - path: Where the value sits in the body, for messages.
    /// - Returns: Every violation found; empty when the value conforms.
    func validate(
        _ instance: CalculationValue,
        against schema: CalculationValue,
        path: String = "$"
    ) -> [SchemaViolation] {
        guard let schema = document.resolve(schema) else {
            return [SchemaViolation(path: path, message: "the schema reference does not resolve")]
        }

        var violations = checkType(instance, schema, path)
        violations += checkEnumeration(instance, schema, path)

        switch instance {
        case .object(let fields):
            violations += checkObject(fields, schema, path)
        case .list(let elements):
            violations += checkArray(elements, schema, path)
        case .text(let text):
            violations += checkString(text, schema, path)
        case .number(let number):
            violations += checkNumber(number, schema, path)
        case .null, .boolean:
            break
        }
        return violations
    }

    private func jsonTypes(of instance: CalculationValue) -> Set<String> {
        switch instance {
        case .null:
            ["null"]
        case .boolean:
            ["boolean"]
        case .number(let value):
            value.rounded() == value ? ["integer", "number"] : ["number"]
        case .text:
            ["string"]
        case .list:
            ["array"]
        case .object:
            ["object"]
        }
    }

    private func checkType(
        _ instance: CalculationValue,
        _ schema: CalculationValue,
        _ path: String
    ) -> [SchemaViolation] {
        guard let declared = schema.at("type") else {
            return []
        }
        let allowed = Set(declared.text.map { [$0] } ?? declared.elements?.compactMap(\.text) ?? [])

        guard !jsonTypes(of: instance).isDisjoint(with: allowed) else {
            return [
                SchemaViolation(
                    path: path,
                    message: "expected \(allowed.sorted()), found \(jsonTypes(of: instance).sorted())"
                )
            ]
        }
        return []
    }

    private func checkEnumeration(
        _ instance: CalculationValue,
        _ schema: CalculationValue,
        _ path: String
    ) -> [SchemaViolation] {
        guard let allowed = schema.at("enum")?.elements, !allowed.contains(instance) else {
            return []
        }
        return [SchemaViolation(path: path, message: "\(instance) is not one of the documented values")]
    }

    private func checkObject(
        _ fields: [String: CalculationValue],
        _ schema: CalculationValue,
        _ path: String
    ) -> [SchemaViolation] {
        var violations: [SchemaViolation] = []
        let properties = schema.at("properties")?.fields ?? [:]

        for name in schema.at("required")?.elements?.compactMap(\.text) ?? [] where fields[name] == nil {
            violations.append(SchemaViolation(path: path, message: "missing required property '\(name)'"))
        }

        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            let propertyPath = "\(path).\(name)"
            if let propertySchema = properties[name] {
                violations += validate(value, against: propertySchema, path: propertyPath)
            } else if let additional = schema.at("additionalProperties") {
                if additional == .boolean(false) {
                    violations.append(SchemaViolation(path: propertyPath, message: "property is not documented"))
                } else if additional != .boolean(true) {
                    violations += validate(value, against: additional, path: propertyPath)
                }
            }
        }
        return violations
    }

    private func checkArray(
        _ elements: [CalculationValue],
        _ schema: CalculationValue,
        _ path: String
    ) -> [SchemaViolation] {
        var violations: [SchemaViolation] = []

        if let minimum = schema.at("minItems")?.number, Double(elements.count) < minimum {
            violations.append(
                SchemaViolation(path: path, message: "has \(elements.count) items, fewer than \(Int(minimum))")
            )
        }
        if let itemSchema = schema.at("items") {
            for (index, element) in elements.enumerated() {
                violations += validate(element, against: itemSchema, path: "\(path)[\(index)]")
            }
        }
        return violations
    }

    private func checkString(
        _ text: String,
        _ schema: CalculationValue,
        _ path: String
    ) -> [SchemaViolation] {
        var violations: [SchemaViolation] = []

        if let minimum = schema.at("minLength")?.number, Double(text.count) < minimum {
            violations.append(SchemaViolation(path: path, message: "is shorter than \(Int(minimum)) characters"))
        }
        if let maximum = schema.at("maxLength")?.number, Double(text.count) > maximum {
            violations.append(SchemaViolation(path: path, message: "is longer than \(Int(maximum)) characters"))
        }
        switch schema.at("format")?.text {
        case "uuid" where UUID(uuidString: text) == nil:
            violations.append(SchemaViolation(path: path, message: "is not a UUID"))
        case "date-time" where Timestamp.parse(text) == nil:
            violations.append(SchemaViolation(path: path, message: "is not an ISO 8601 timestamp"))
        default:
            break
        }
        return violations
    }

    private func checkNumber(
        _ number: Double,
        _ schema: CalculationValue,
        _ path: String
    ) -> [SchemaViolation] {
        var violations: [SchemaViolation] = []

        if let minimum = schema.at("minimum")?.number, number < minimum {
            violations.append(SchemaViolation(path: path, message: "\(number) is below the minimum \(minimum)"))
        }
        if let maximum = schema.at("maximum")?.number, number > maximum {
            violations.append(SchemaViolation(path: path, message: "\(number) is above the maximum \(maximum)"))
        }
        return violations
    }
}
