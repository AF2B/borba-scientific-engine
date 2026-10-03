/// A cohesive family of calculations, such as statistics or unit conversion.
///
/// A module owns its domain models, validation, business rules and errors, and exposes them to the engine as a list
/// of ``OperationDefinition``s. Adding a capability to the engine means adding a module and registering it; no
/// existing code has to change.
public protocol CalculationModule: Sendable {
    /// Name of the module on the wire, for example `statistics`.
    var name: ModuleName { get }

    /// One-sentence description of what the module covers.
    var summary: String { get }

    /// The operations the module offers.
    var operations: [OperationDefinition] { get }
}

/// Documentation-level description of an operation, without its implementation.
public struct OperationDescriptor: Sendable, Equatable {
    /// Fully qualified identity of the operation.
    public let type: CalculationType

    /// One-sentence description of what the operation computes.
    public let summary: String

    /// The parameters the operation accepts.
    public let parameters: [ParameterDescriptor]

    /// Structure of the result.
    public let result: ValueShape

    /// Worked examples.
    public let examples: [OperationExample]
}

/// Documentation-level description of a module and its operations.
public struct ModuleDescriptor: Sendable, Equatable {
    /// Name of the module.
    public let name: ModuleName

    /// One-sentence description of what the module covers.
    public let summary: String

    /// The module's operations, ordered by name.
    public let operations: [OperationDescriptor]
}

/// A problem found while assembling a registry. These are programming errors, detected at startup.
public enum RegistryError: Error, Sendable, Equatable {
    /// Two modules share a name.
    case duplicateModule(ModuleName)

    /// Two operations of one module share a name.
    case duplicateOperation(CalculationType)

    /// Two parameters of one operation share a name.
    case duplicateParameter(CalculationType, name: String)
}

/// The set of modules the engine can run, indexed for lookup.
///
/// A registry is immutable and validated once at construction, so lookups at request time cannot fail for
/// structural reasons.
public struct ModuleRegistry: Sendable {
    private let definitions: [CalculationType: OperationDefinition]
    private let catalog: [ModuleDescriptor]

    /// Builds a registry.
    ///
    /// - Parameter modules: The modules to register.
    /// - Throws: ``RegistryError`` when module, operation or parameter names collide.
    public init(modules: [any CalculationModule]) throws(RegistryError) {
        var definitions: [CalculationType: OperationDefinition] = [:]
        var catalog: [ModuleDescriptor] = []
        var seenModules: Set<ModuleName> = []

        for module in modules {
            guard seenModules.insert(module.name).inserted else {
                throw .duplicateModule(module.name)
            }

            var operations: [OperationDescriptor] = []
            for definition in module.operations {
                let type = CalculationType(module: module.name, operation: definition.name)
                guard definitions.updateValue(definition, forKey: type) == nil else {
                    throw .duplicateOperation(type)
                }
                operations.append(try Self.describe(definition, as: type))
            }

            catalog.append(
                ModuleDescriptor(
                    name: module.name,
                    summary: module.summary,
                    operations: operations.sorted { $0.type < $1.type }
                )
            )
        }

        self.definitions = definitions
        self.catalog = catalog.sorted { $0.name < $1.name }
    }

    /// Every registered module with its operations, ordered by name.
    public var modules: [ModuleDescriptor] {
        catalog
    }

    /// Every registered calculation type, ordered by module then operation.
    public var types: [CalculationType] {
        definitions.keys.sorted()
    }

    /// Finds the implementation of a calculation.
    ///
    /// - Parameter type: The calculation to look up.
    /// - Returns: The operation definition.
    /// - Throws: ``UnsupportedOperationError`` when no such calculation is registered.
    func definition(for type: CalculationType) throws(UnsupportedOperationError) -> OperationDefinition {
        guard let definition = definitions[type] else {
            throw UnsupportedOperationError(type: type)
        }
        return definition
    }

    /// Finds the documentation of a calculation.
    ///
    /// - Parameter type: The calculation to look up.
    /// - Returns: The operation's descriptor.
    /// - Throws: ``UnsupportedOperationError`` when no such calculation is registered.
    public func descriptor(for type: CalculationType) throws(UnsupportedOperationError) -> OperationDescriptor {
        guard
            let module = catalog.first(where: { $0.name == type.module }),
            let descriptor = module.operations.first(where: { $0.type == type })
        else {
            throw UnsupportedOperationError(type: type)
        }
        return descriptor
    }

    private static func describe(
        _ definition: OperationDefinition,
        as type: CalculationType
    ) throws(RegistryError) -> OperationDescriptor {
        var seenParameters: Set<String> = []
        for parameter in definition.parameters {
            let name = parameter.descriptor.name
            guard seenParameters.insert(name).inserted else {
                throw .duplicateParameter(type, name: name)
            }
        }

        return OperationDescriptor(
            type: type,
            summary: definition.summary,
            parameters: definition.parameters.map(\.descriptor),
            result: definition.result,
            examples: definition.examples
        )
    }
}
