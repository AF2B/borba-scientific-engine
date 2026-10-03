import TestSupport
import Testing

@testable import BorbaScientificCore

@Suite("ModuleRegistry")
struct ModuleRegistryTests {
    /// A module with configurable operation and parameter names, for exercising collision detection.
    private struct StubModule: CalculationModule {
        let name: ModuleName
        let summary = "A stub."
        let operations: [OperationDefinition]

        init(
            name: String,
            operations: [OperationDefinition]
        ) {
            self.name = ModuleName(name)
            self.operations = operations
        }
    }

    private enum StubOperation: String {
        case first
        case second
    }

    private func operation(
        _ name: StubOperation,
        parameters: [any ParameterDeclaration] = []
    ) -> OperationDefinition {
        OperationDefinition(
            name: name,
            summary: "A stub operation.",
            parameters: parameters,
            result: .number,
            compute: { _ in 0 }
        )
    }

    @Test("rejects two modules with the same name")
    func rejectsDuplicateModules() {
        #expect(throws: RegistryError.duplicateModule(ModuleName("stub"))) {
            try ModuleRegistry(modules: [
                StubModule(name: "stub", operations: []), StubModule(name: "stub", operations: []),
            ])
        }
    }

    @Test("rejects two operations with the same name in one module")
    func rejectsDuplicateOperations() {
        let duplicated = CalculationType(module: ModuleName("stub"), operation: OperationName("first"))

        #expect(throws: RegistryError.duplicateOperation(duplicated)) {
            try ModuleRegistry(modules: [StubModule(name: "stub", operations: [operation(.first), operation(.first)])])
        }
    }

    @Test("rejects an operation that declares the same parameter twice")
    func rejectsDuplicateParameters() {
        let type = CalculationType(module: ModuleName("stub"), operation: OperationName("first"))
        let parameter = ParameterSpec.number("x", summary: "A number.")

        #expect(throws: RegistryError.duplicateParameter(type, name: "x")) {
            try ModuleRegistry(
                modules: [
                    StubModule(name: "stub", operations: [operation(.first, parameters: [parameter, parameter])])
                ]
            )
        }
    }

    @Test("allows the same operation name in different modules")
    func allowsSharedOperationNames() throws {
        let registry = try ModuleRegistry(
            modules: [
                StubModule(name: "alpha", operations: [operation(.first)]),
                StubModule(name: "beta", operations: [operation(.first)]),
            ]
        )

        #expect(registry.types.count == 2)
    }

    @Test("lists modules and operations in a stable order")
    func ordersTheCatalog() throws {
        let registry = try ModuleRegistry(
            modules: [
                StubModule(name: "zeta", operations: [operation(.second), operation(.first)]),
                StubModule(name: "alpha", operations: [operation(.first)]),
            ]
        )

        #expect(registry.modules.map(\.name.rawValue) == ["alpha", "zeta"])
        #expect(registry.modules.last?.operations.map(\.type.operation.rawValue) == ["first", "second"])
        #expect(registry.types.map(\.description) == ["alpha.first", "zeta.first", "zeta.second"])
    }

    @Test("describes an operation without exposing its implementation")
    func describesOperations() throws {
        let registry = try ModuleRegistry(modules: [StubModule(name: "stub", operations: [operation(.first)])])
        let type = CalculationType(module: ModuleName("stub"), operation: OperationName("first"))

        let descriptor = try registry.descriptor(for: type)

        #expect(descriptor.type == type)
        #expect(descriptor.summary == "A stub operation.")
        #expect(descriptor.result == .number)
    }

    @Test("reports unknown calculations")
    func reportsUnknownCalculations() throws {
        let registry = try ModuleRegistry(modules: [StubModule(name: "stub", operations: [operation(.first)])])
        let unknown = CalculationType(module: ModuleName("stub"), operation: OperationName("missing"))

        #expect(throws: UnsupportedOperationError(type: unknown)) {
            try registry.descriptor(for: unknown)
        }
    }
}
