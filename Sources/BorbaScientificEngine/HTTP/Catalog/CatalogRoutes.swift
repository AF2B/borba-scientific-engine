import BorbaScientificCore
import Vapor

/// The endpoints that describe what the engine can calculate, so a client can discover operations and their
/// parameters instead of hard-coding them.
struct CatalogRoutes: RouteCollection {
    private let registry: ModuleRegistry

    /// Creates the routes.
    ///
    /// - Parameter registry: The modules the engine can run.
    init(registry: ModuleRegistry) {
        self.registry = registry
    }

    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped(APIPath.apiRoot, APIPath.version1)

        api.get(APIPath.modules, use: modules)
        api.get(APIPath.types, use: types)
        api.get(
            APIPath.types,
            .parameter(APIPath.moduleName),
            .parameter(APIPath.operationName),
            use: metadata
        )
    }

    /// Lists the modules, each with its operations.
    ///
    /// - Parameter request: The incoming request.
    /// - Returns: Every registered module.
    /// - Throws: An encoding error when the response cannot be serialized.
    @Sendable
    private func modules(_ request: Request) throws -> Response {
        try request.jsonResponse(ModuleListResponse(modules: registry.modules))
    }

    /// Lists every supported calculation type as a flat list.
    ///
    /// - Parameter request: The incoming request.
    /// - Returns: Every registered calculation type.
    /// - Throws: An encoding error when the response cannot be serialized.
    @Sendable
    private func types(_ request: Request) throws -> Response {
        try request.jsonResponse(TypeListResponse(modules: registry.modules))
    }

    /// Describes one operation: its parameters with their constraints and defaults, the shape of its result and
    /// worked examples.
    ///
    /// - Parameter request: The incoming request; the path names the module and the operation.
    /// - Returns: The operation's metadata.
    /// - Throws: ``ExecutionFailure`` when the operation does not exist.
    @Sendable
    private func metadata(_ request: Request) throws -> Response {
        let module = request.parameters.get(APIPath.moduleName) ?? ""
        let operation = request.parameters.get(APIPath.operationName) ?? ""
        let type = CalculationType(module: ModuleName(module), operation: OperationName(operation))

        do {
            return try request.jsonResponse(OperationMetadataResource(try registry.descriptor(for: type)))
        } catch let error as UnsupportedOperationError {
            throw ExecutionFailure.rejected(.unsupportedOperation(error))
        }
    }
}
