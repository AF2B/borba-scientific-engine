import BorbaScientificCore
import Foundation
import HTTPSupport
import TestSupport
import Testing
import Vapor

@testable import BorbaScientificEngine

/// Holds the running API to the published OpenAPI document: what it describes must be what the service does, and
/// the other way round.
@Suite("OpenAPI contract")
struct OpenAPIContractTests {
    private static let calculationsPath = "/api/v1/calculations"
    private static let calculationsTemplate = "/api/v1/calculations"
    private static let idTemplate = "/api/v1/calculations/{id}"
    private static let batchTemplate = "/api/v1/calculations/batch"
    private static let operationTemplate = "/api/v1/types/{module}/{operation}"
    private static let missingIdentifier = "00000000-0000-7000-8000-000000000000"
    private static let oversizedBodyBytes = 2_048
    private static let smallestBodyLimit = "1024"
    private static let smallestBatchLimit = "2"

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

    // MARK: - The document itself

    @Test("is valid JSON whose references all resolve")
    func referencesResolve() throws {
        let document = try OpenAPIDocument.load()

        #expect(document.root.at("openapi")?.text?.hasPrefix("3.1") == true)
        #expect(!document.references.isEmpty)
        for reference in document.references {
            #expect(document.resolve(["$ref": .text(reference)]) != nil, "dangling reference \(reference)")
        }
    }

    @Test("documents every route the application registers, and nothing it does not")
    func routesMatchTheDocument() async throws {
        let document = try OpenAPIDocument.load()

        try await TestApplication.run { harness in
            let registered = Set(
                harness.application.routes.all.map { route in
                    let template = route.path.map { component -> String in
                        switch component {
                        case .constant(let name):
                            name
                        case .parameter(let name):
                            "{\(name)}"
                        case .anything:
                            "*"
                        case .catchall:
                            "**"
                        }
                    }
                    return "\(route.method.rawValue) /" + template.joined(separator: "/")
                }
            )

            #expect(
                registered.subtracting(document.operations).isEmpty,
                "routes missing from the document: \(registered.subtracting(document.operations).sorted())"
            )
            #expect(
                document.operations.subtracting(registered).isEmpty,
                "documented operations without a route: \(document.operations.subtracting(registered).sorted())"
            )
        }
    }

    @Test("enumerates exactly the error codes the catalog defines")
    func errorCodesMatchTheCatalog() throws {
        let document = try OpenAPIDocument.load()

        #expect(document.errorCodes == Set(ErrorCatalog.entries.map(\.code.rawValue)))
    }

    @Test("documents every status the error catalog can produce")
    func statusesAreDocumented() throws {
        let document = try OpenAPIDocument.load()
        let produced = Set(ErrorCatalog.entries.map { String($0.status.code) })

        #expect(produced.subtracting(document.documentedStatuses).isEmpty)
    }

    @Test("lists in the error guide exactly the catalog's codes and statuses")
    func errorGuideMatchesTheCatalog() throws {
        let guide = try String(
            contentsOf: OpenAPIDocument.repositoryRoot.appendingPathComponent("Documentation/API/errors.md"),
            encoding: .utf8
        )
        let row = #/^\| `([A-Z_]+)` \| (\d{3}) \|/#

        var documented: [String: UInt] = [:]
        for line in guide.split(separator: "\n") {
            if let match = line.firstMatch(of: row), let status = UInt(match.output.2) {
                documented[String(match.output.1)] = status
            }
        }

        let catalogued = Dictionary(
            uniqueKeysWithValues: ErrorCatalog.entries.map { ($0.code.rawValue, $0.status.code) }
        )
        #expect(documented == catalogued)
    }

    // MARK: - The running API

    /// Sends a request and checks the answer against the document: the status is documented for the operation, every
    /// documented header is present and the body conforms to the documented schema.
    private func verify(
        _ response: TestResponse,
        method: String,
        template: String,
        expecting status: HTTPResponseStatus
    ) throws {
        let document = try OpenAPIDocument.load()
        let label = "\(method) \(template) -> \(status.code)"

        #expect(response.status == status, "\(label): got \(response.status.code)")
        let documented = try #require(
            document.response(method: method, template: template, status: UInt(response.status.code)),
            "\(label): the document does not describe a \(response.status.code) response"
        )

        for header in documented.at("headers")?.fields?.keys.sorted() ?? [] {
            #expect(response.header(header) != nil, "\(label): documented header \(header) is missing")
        }

        guard let schema = documented.at("content", "application/json", "schema") else {
            return
        }
        let violations = SchemaValidator(document: document).validate(try response.json(), against: schema)
        #expect(violations.isEmpty, "\(label): \(violations.map(\.description))")
    }

    @Test("answers every operation the way the document describes it")
    func answersAsDocumented() async throws {
        try await TestApplication.run { harness in
            let client = harness.client
            let key = ["Idempotency-Key": "contract-1"]

            try verify(try await client.get("/health"), method: "GET", template: "/health", expecting: .ok)
            try verify(try await client.get("/version"), method: "GET", template: "/version", expecting: .ok)

            let created = try await client.post(Self.calculationsPath, json: Self.add, headers: key)
            try verify(created, method: "POST", template: Self.calculationsTemplate, expecting: .created)
            let replayed = try await client.post(Self.calculationsPath, json: Self.add, headers: key)
            try verify(replayed, method: "POST", template: Self.calculationsTemplate, expecting: .ok)
            try verify(
                try await client.post(Self.calculationsPath, json: Self.divideByZero),
                method: "POST",
                template: Self.calculationsTemplate,
                expecting: .unprocessableEntity
            )
            try verify(
                try await client.post(Self.calculationsPath, json: ["module": "arithmetic", "operation": "add"]),
                method: "POST",
                template: Self.calculationsTemplate,
                expecting: .unprocessableEntity
            )
            try verify(
                try await client.post(Self.calculationsPath, json: ["module": "arithmetic", "operation": "teleport"]),
                method: "POST",
                template: Self.calculationsTemplate,
                expecting: .notFound
            )
            try verify(
                try await client.post(Self.calculationsPath, body: "{"),
                method: "POST",
                template: Self.calculationsTemplate,
                expecting: .badRequest
            )
            try verify(
                try await client.post(Self.calculationsPath, body: "a=b", contentType: "text/plain"),
                method: "POST",
                template: Self.calculationsTemplate,
                expecting: .unsupportedMediaType
            )

            let batch: CalculationValue = ["calculations": [Self.add, Self.divideByZero]]
            try verify(
                try await client.post(Self.batchTemplate, json: batch),
                method: "POST",
                template: Self.batchTemplate,
                expecting: .ok
            )
            try verify(
                try await client.post(Self.batchTemplate, json: ["calculations": []]),
                method: "POST",
                template: Self.batchTemplate,
                expecting: .unprocessableEntity
            )
            try verify(
                try await client.post(Self.batchTemplate, json: ["calculation": []]),
                method: "POST",
                template: Self.batchTemplate,
                expecting: .badRequest
            )

            try verify(
                try await client.get(Self.calculationsPath),
                method: "GET",
                template: Self.calculationsTemplate,
                expecting: .ok
            )
            try verify(
                try await client.get("\(Self.calculationsPath)?status=failed&limit=1"),
                method: "GET",
                template: Self.calculationsTemplate,
                expecting: .ok
            )
            try verify(
                try await client.get("\(Self.calculationsPath)?limit=0"),
                method: "GET",
                template: Self.calculationsTemplate,
                expecting: .badRequest
            )

            let identifier = try #require(created.json().at("id")?.text)
            try verify(
                try await client.get("\(Self.calculationsPath)/\(identifier)"),
                method: "GET",
                template: Self.idTemplate,
                expecting: .ok
            )
            try verify(
                try await client.get("\(Self.calculationsPath)/nope"),
                method: "GET",
                template: Self.idTemplate,
                expecting: .badRequest
            )
            try verify(
                try await client.get("\(Self.calculationsPath)/\(Self.missingIdentifier)"),
                method: "GET",
                template: Self.idTemplate,
                expecting: .notFound
            )

            try verify(
                try await client.get("/api/v1/modules"),
                method: "GET",
                template: "/api/v1/modules",
                expecting: .ok
            )
            try verify(try await client.get("/api/v1/types"), method: "GET", template: "/api/v1/types", expecting: .ok)
            try verify(
                try await client.get("/api/v1/types/arithmetic/add"),
                method: "GET",
                template: Self.operationTemplate,
                expecting: .ok
            )
            try verify(
                try await client.get("/api/v1/types/arithmetic/teleport"),
                method: "GET",
                template: Self.operationTemplate,
                expecting: .notFound
            )
        }
    }

    @Test("describes every operation of the engine in a way that conforms to the document")
    func metadataConforms() async throws {
        try await TestApplication.run { harness in
            for type in ModuleRegistry.standard().types {
                let path = "/api/v1/types/\(type.module)/\(type.operation)"

                try verify(
                    try await harness.client.get(path),
                    method: "GET",
                    template: Self.operationTemplate,
                    expecting: .ok
                )
            }
        }
    }

    @Test("answers 413 for a body over the limit")
    func payloadTooLarge() async throws {
        let settings = [EnvironmentVariable.httpMaximumBodySizeBytes.rawValue: Self.smallestBodyLimit]

        try await TestApplication.run(settings: settings, transport: .network) { harness in
            let padding = String(repeating: "x", count: Self.oversizedBodyBytes)
            let response = try await harness.client.post(Self.calculationsPath, body: #"{"module":"\#(padding)"}"#)

            try verify(response, method: "POST", template: Self.calculationsTemplate, expecting: .payloadTooLarge)
        }
    }

    @Test("answers 422 LIMIT_EXCEEDED for a batch over the limit")
    func batchTooLarge() async throws {
        let settings = [EnvironmentVariable.batchMaximumSize.rawValue: Self.smallestBatchLimit]

        try await TestApplication.run(settings: settings) { harness in
            let batch: CalculationValue = ["calculations": [Self.add, Self.add, Self.add]]
            let response = try await harness.client.post(Self.batchTemplate, json: batch)

            try verify(response, method: "POST", template: Self.batchTemplate, expecting: .unprocessableEntity)
            #expect(try response.json().at("error", "code") == "LIMIT_EXCEEDED")
        }
    }

    @Test("answers 503 and 500 for storage failures, in the documented shape")
    func storageFailures() async throws {
        try await TestApplication.run { harness in
            await harness.repository.failNextCalls(with: .unavailable(reason: "connection refused"), times: 2)
            try verify(
                try await harness.client.post(Self.calculationsPath, json: Self.add),
                method: "POST",
                template: Self.calculationsTemplate,
                expecting: .serviceUnavailable
            )
            try verify(
                try await harness.client.get(Self.calculationsPath),
                method: "GET",
                template: Self.calculationsTemplate,
                expecting: .serviceUnavailable
            )

            await harness.repository.failNextCalls(with: .unexpected(reason: "constraint violated"), times: 1)
            try verify(
                try await harness.client.get(Self.calculationsPath),
                method: "GET",
                template: Self.calculationsTemplate,
                expecting: .internalServerError
            )
        }
    }
}
