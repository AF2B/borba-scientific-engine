import BorbaScientificCore

/// A calculation type as the types listing shows it.
struct TypeResource: Encodable, Sendable, Equatable {
    /// The qualified name, such as `statistics.mean`.
    let type: String

    /// Name of the module.
    let module: String

    /// Name of the operation inside the module.
    let operation: String

    /// One-sentence description of what the operation computes.
    let summary: String

    /// Presents an operation.
    ///
    /// - Parameter descriptor: The operation's descriptor.
    init(_ descriptor: OperationDescriptor) {
        type = descriptor.type.description
        module = descriptor.type.module.rawValue
        operation = descriptor.type.operation.rawValue
        summary = descriptor.summary
    }
}

/// The body of the response to `GET /api/v1/types`.
struct TypeListResponse: Encodable, Sendable, Equatable {
    /// Every supported calculation type, ordered by module and operation.
    let types: [TypeResource]

    /// Presents the registry.
    ///
    /// - Parameter modules: The registered modules.
    init(modules: [ModuleDescriptor]) {
        types = modules.flatMap(\.operations).map(TypeResource.init)
    }
}

/// An operation inside a module listing: its name and what it computes.
struct OperationSummaryResource: Encodable, Sendable, Equatable {
    /// Name of the operation inside the module.
    let name: String

    /// One-sentence description of what the operation computes.
    let summary: String
}

/// A module as the modules listing shows it.
struct ModuleResource: Encodable, Sendable, Equatable {
    /// Name of the module.
    let name: String

    /// One-sentence description of what the module covers.
    let summary: String

    /// The operations the module offers, ordered by name.
    let operations: [OperationSummaryResource]

    /// Presents a module.
    ///
    /// - Parameter descriptor: The module's descriptor.
    init(_ descriptor: ModuleDescriptor) {
        name = descriptor.name.rawValue
        summary = descriptor.summary
        operations = descriptor.operations.map {
            OperationSummaryResource(name: $0.type.operation.rawValue, summary: $0.summary)
        }
    }
}

/// The body of the response to `GET /api/v1/modules`.
struct ModuleListResponse: Encodable, Sendable, Equatable {
    /// Every registered module, ordered by name.
    let modules: [ModuleResource]

    /// Presents the registry.
    ///
    /// - Parameter modules: The registered modules.
    init(modules: [ModuleDescriptor]) {
        self.modules = modules.map(ModuleResource.init)
    }
}
