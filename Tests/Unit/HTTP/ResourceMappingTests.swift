import Foundation
import TestSupport
import Testing

@testable import BorbaScientificCore
@testable import BorbaScientificEngine

@Suite("Resources")
struct ResourceMappingTests {
    private static let requestID = RequestID("request-9")

    private func json<Value: Encodable>(_ value: Value) throws -> CalculationValue {
        try JSONDecoder().decode(CalculationValue.self, from: JSONCoding.makeEncoder().encode(value))
    }

    private func parameter(
        _ kind: ParameterKind,
        requirement: ParameterRequirement = .required
    ) throws -> CalculationValue {
        let descriptor = ParameterDescriptor(name: "p", summary: "A parameter.", kind: kind, requirement: requirement)
        return try json(ParameterResource(descriptor))
    }

    // MARK: - Calculations

    @Test("presents a succeeded calculation with the contract's field names")
    func succeededCalculation() throws {
        let resource = try json(CalculationResource(RecordFixtures.record(sequence: 1)))

        #expect(resource.at("id")?.text == RecordFixtures.id(1).description)
        #expect(resource.at("module") == "arithmetic")
        #expect(resource.at("operation") == "add")
        #expect(resource.at("status") == "succeeded")
        #expect(resource.at("parameters", "a") == 2)
        #expect(resource.at("result") == 5)
        #expect(resource.at("execution_time_ms") == 0.042)
        #expect(resource.at("created_at") == "2023-11-14T22:13:20.250Z")
        #expect(resource.at("request_id") == "request-1")
        #expect(resource.at("correlation_id") == "correlation-1")
        #expect(resource.at("error") == nil)
    }

    @Test("presents a failed calculation with its error and without a result")
    func failedCalculation() throws {
        let resource = try json(
            CalculationResource(RecordFixtures.record(sequence: 2, outcome: RecordFixtures.failure))
        )

        #expect(resource.at("status") == "failed")
        #expect(resource.at("result") == nil)
        #expect(resource.at("error", "code") == "DIVISION_BY_ZERO")
        #expect(resource.at("error", "details", 0, "field") == "divisor")
    }

    @Test("leaves details out of a failure that has none")
    func failureWithoutDetails() throws {
        let outcome = CalculationOutcome.failed(
            RecordedFailure(code: .numericOverflow, message: "Too large.", details: [])
        )

        let resource = try json(CalculationResource(RecordFixtures.record(sequence: 3, outcome: outcome)))

        #expect(resource.at("error", "details") == nil)
    }

    // MARK: - Batches

    private func item(
        _ outcome: Result<ExecutionResult, ExecutionFailure>
    ) throws -> (BatchItemResponse, CalculationValue) {
        let response = BatchItemResponse(index: 4, outcome: outcome, requestID: Self.requestID)
        return (response, try json(response))
    }

    @Test("presents a calculation that ran now and one replayed from an earlier request")
    func batchSuccesses() throws {
        let record = RecordFixtures.record(sequence: 1)

        let (_, executed) = try item(.success(.executed(record)))
        let (_, replayed) = try item(.success(.replayed(record)))

        #expect(executed.at("index") == 4)
        #expect(executed.at("calculation", "result") == 5)
        #expect(executed.at("replayed") == nil)
        #expect(executed.at("error") == nil)
        #expect(replayed.at("replayed") == true)
    }

    @Test("presents a calculation that failed while running as an error that points at its record")
    func batchRecordedFailure() throws {
        let record = RecordFixtures.record(sequence: 5, outcome: RecordFixtures.failure)

        let (_, value) = try item(.success(.executed(record)))

        #expect(value.at("calculation") == nil)
        #expect(value.at("error", "code") == "DIVISION_BY_ZERO")
        #expect(value.at("error", "calculation_id")?.text == RecordFixtures.id(5).description)
        #expect(value.at("error", "request_id") == "request-9")
    }

    @Test("presents a request that was refused as an error without a calculation")
    func batchRefusal() throws {
        let (_, value) = try item(.failure(.rejected(.invalidParameter("a", reason: "is required"))))

        #expect(value.at("error", "code") == "VALIDATION_FAILED")
        #expect(value.at("error", "calculation_id") == nil)
        #expect(value.at("error", "details", 0, "field") == "a")
    }

    @Test("counts succeeded and failed items")
    func batchSummary() throws {
        let succeeded = BatchItemResponse(
            index: 0,
            outcome: .success(.executed(RecordFixtures.record(sequence: 1))),
            requestID: Self.requestID
        )
        let failed = BatchItemResponse(index: 1, outcome: .failure(.cancelled), requestID: Self.requestID)

        let response = BatchResponse(results: [succeeded, failed, succeeded])

        #expect(response.summary == BatchSummary(total: 3, succeeded: 2, failed: 1))
    }

    // MARK: - History

    @Test("writes the cursor explicitly as null on the last page")
    func lastPageHasNullCursor() throws {
        let page = Page(items: [RecordFixtures.record(sequence: 1)], nextCursor: nil)

        let value = try json(HistoryPageResponse(page: page, limit: 20))

        #expect(value.at("page", "next_cursor") == .null)
        #expect(value.at("page", "limit") == 20)
        #expect(value.at("items", 0, "id") != nil)
    }

    @Test("writes a cursor that reads the next page")
    func cursorIsPresented() throws {
        let cursor = PageCursor(createdAt: RecordFixtures.epoch, id: RecordFixtures.id(1))
        let page = Page(items: [RecordFixtures.record(sequence: 1)], nextCursor: cursor)

        let value = try json(HistoryPageResponse(page: page, limit: 1))

        #expect(PageCursorCodec.decode(try #require(value.at("page", "next_cursor")?.text)) == cursor)
    }

    // MARK: - Catalog parameters

    @Test("presents a bounded number")
    func numberParameter() throws {
        let value = try parameter(.number(.greaterThan(0, upTo: 100)))

        #expect(value.at("type") == "number")
        #expect(value.at("required") == true)
        #expect(value.at("default") == nil)
        #expect(value.at("constraints", "minimum") == ["value": 0, "inclusive": false])
        #expect(value.at("constraints", "maximum") == ["value": 100, "inclusive": true])
    }

    @Test("presents an integer range as inclusive bounds")
    func integerParameter() throws {
        let value = try parameter(.integer(1...12))

        #expect(value.at("type") == "integer")
        #expect(value.at("constraints", "minimum") == ["value": 1, "inclusive": true])
        #expect(value.at("constraints", "maximum") == ["value": 12, "inclusive": true])
    }

    @Test("presents the type of a parameter that has no constraint without a constraints object")
    func unconstrainedParameters() throws {
        #expect(try parameter(.boolean).at("type") == "boolean")
        #expect(try parameter(.boolean).at("constraints") == nil)
        #expect(try parameter(.number(.unbounded)).at("constraints") == nil)
    }

    @Test("presents text, choices and decimals")
    func scalarParameters() throws {
        #expect(try parameter(.text(maximumLength: 64)).at("constraints", "max_length") == 64)
        #expect(try parameter(.choice(["linear", "log"])).at("constraints", "choices") == ["linear", "log"])
        #expect(try parameter(.decimal(.nonNegative)).at("type") == "decimal")
    }

    @Test("presents collections with their sizes")
    func collectionParameters() throws {
        let list = try parameter(.numberList(size: 2...10, elements: .atLeast(0)))
        let decimals = try parameter(.decimalList(size: 1...5))
        let matrix = try parameter(.numberMatrix(rows: 1...3, columns: 2...4))
        let map = try parameter(.numberMap(size: 1...8))

        #expect(list.at("type") == "number_list")
        #expect(list.at("constraints", "items") == ["min": 2, "max": 10])
        #expect(list.at("constraints", "minimum", "value") == 0)
        #expect(decimals.at("type") == "decimal_list")
        #expect(matrix.at("type") == "number_matrix")
        #expect(matrix.at("constraints", "rows") == ["min": 1, "max": 3])
        #expect(matrix.at("constraints", "columns") == ["min": 2, "max": 4])
        #expect(map.at("type") == "number_map")
        #expect(map.at("constraints", "items") == ["min": 1, "max": 8])
    }

    @Test("presents an optional parameter with its default")
    func optionalParameter() throws {
        let value = try parameter(.integer(1...10), requirement: .optional(defaultValue: 4))

        #expect(value.at("required") == false)
        #expect(value.at("default") == 4)
    }

    // MARK: - Catalog shapes and operations

    @Test("presents a result shape as nested JSON")
    func shapes() throws {
        let shape = ValueShape.object([
            FieldShape("values", .list(of: .number), "The values."),
            FieldShape("label", .text, "The label."),
            FieldShape("ok", .boolean, "Whether it worked."),
        ])

        let value = try json(ShapeResource(shape))

        #expect(value.at("type") == "object")
        #expect(value.at("fields", 0, "name") == "values")
        #expect(value.at("fields", 0, "shape", "type") == "list")
        #expect(value.at("fields", 0, "shape", "items", "type") == "number")
        #expect(value.at("fields", 1, "shape", "type") == "text")
        #expect(value.at("fields", 2, "summary") == "Whether it worked.")
    }

    @Test("presents every operation of the standard registry with its parameters, result and examples")
    func everyStandardOperation() throws {
        let registry = ModuleRegistry.standard()
        var presented = 0

        for module in registry.modules {
            for descriptor in module.operations {
                let value = try json(OperationMetadataResource(descriptor))

                #expect(value.at("type")?.text == descriptor.type.description)
                #expect(value.at("parameters")?.elements?.count == descriptor.parameters.count)
                #expect(value.at("result", "type") != nil)
                #expect(value.at("examples")?.elements?.count == descriptor.examples.count)
                presented += 1
            }
        }

        #expect(presented == registry.types.count)
    }

    @Test("lists the types flat, in the registry's order, and the modules grouped")
    func listings() throws {
        let registry = ModuleRegistry.standard()

        let types = try json(TypeListResponse(modules: registry.modules))
        let modules = try json(ModuleListResponse(modules: registry.modules))

        #expect(types.at("types")?.elements?.compactMap { $0.at("type")?.text } == registry.types.map(\.description))
        #expect(modules.at("modules")?.elements?.count == registry.modules.count)
        #expect(modules.at("modules", 0, "operations", 0, "name") != nil)
    }
}
