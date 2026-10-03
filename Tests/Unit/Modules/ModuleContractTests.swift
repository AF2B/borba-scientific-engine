import Foundation
import TestSupport
import Testing

@testable import BorbaScientificCore

/// One documented example together with the operation it documents.
struct DocumentedExample: Sendable, CustomTestStringConvertible {
    let descriptor: OperationDescriptor
    let example: OperationExample

    var testDescription: String {
        "\(descriptor.type): \(example.summary)"
    }

    static let all: [DocumentedExample] = ModuleRegistry.standard().modules
        .flatMap(\.operations)
        .flatMap { descriptor in descriptor.examples.map { DocumentedExample(descriptor: descriptor, example: $0) } }
}

/// Describes every operation of every built-in module, so conventions are enforced for all of them at once.
struct DocumentedOperation: Sendable, CustomTestStringConvertible {
    let descriptor: OperationDescriptor

    var testDescription: String {
        descriptor.type.description
    }

    static let all: [DocumentedOperation] = ModuleRegistry.standard().modules
        .flatMap(\.operations)
        .map(DocumentedOperation.init)
}

@Suite("Built-in calculation modules")
struct ModuleContractTests {
    private static var wireNamePattern: some RegexComponent {
        /^[a-z][a-z0-9]*(_[a-z0-9]+)*$/
    }

    @Test("every documented example reproduces its documented result", arguments: DocumentedExample.all)
    func examplesReproduceDocumentedResults(documented: DocumentedExample) async throws {
        let engine = CalculationEngine.standard()
        let request = CalculationRequest(type: documented.descriptor.type, parameters: documented.example.parameters)

        let run = try await engine.execute(request)

        guard case .success(let value) = run.result else {
            Issue.record("Expected success, got \(run.result)")
            return
        }
        #expect(documented.example.isSatisfied(by: value), "Documented \(documented.example.result), got \(value)")
        #expect(documented.descriptor.result.accepts(value), "Result does not match its declared shape")
    }

    @Test("every operation ships at least one executable example", arguments: DocumentedOperation.all)
    func operationsHaveExamples(operation: DocumentedOperation) {
        #expect(!operation.descriptor.examples.isEmpty)
    }

    @Test("names follow the snake_case wire convention", arguments: DocumentedOperation.all)
    func wireNamesAreSnakeCase(operation: DocumentedOperation) {
        let descriptor = operation.descriptor
        let names =
            [descriptor.type.module.rawValue, descriptor.type.operation.rawValue]
            + descriptor.parameters.map(\.name)

        for name in names {
            #expect(name.wholeMatch(of: Self.wireNamePattern) != nil, "'\(name)' is not snake_case")
        }
    }

    @Test("summaries are complete sentences", arguments: DocumentedOperation.all)
    func summariesAreSentences(operation: DocumentedOperation) {
        let descriptor = operation.descriptor
        let summaries = [descriptor.summary] + descriptor.parameters.map(\.summary)

        for summary in summaries {
            #expect(summary.hasSuffix("."), "'\(summary)' does not end with a period")
            #expect(summary.first?.isUppercase == true, "'\(summary)' does not start with a capital letter")
        }
    }

    @Test("module summaries are complete sentences")
    func moduleSummariesAreSentences() {
        for module in ModuleRegistry.standard().modules {
            #expect(module.summary.hasSuffix("."))
            #expect(!module.operations.isEmpty)
        }
    }
}
