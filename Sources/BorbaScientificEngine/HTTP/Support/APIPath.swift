import BorbaScientificCore
import Vapor

/// Route paths of the versioned API, spelled once so routes, `Location` headers and tests cannot drift apart.
enum APIPath {
    static let apiRoot: PathComponent = "api"
    static let version1: PathComponent = "v1"
    static let calculations: PathComponent = "calculations"
    static let batch: PathComponent = "batch"
    static let modules: PathComponent = "modules"
    static let types: PathComponent = "types"

    /// Name of the path parameter that carries a calculation identifier.
    static let calculationIDName = "id"

    /// Name of the path parameter that carries a module name.
    static let moduleName = "module"

    /// Name of the path parameter that carries an operation name.
    static let operationName = "operation"

    private static let separator = "/"

    /// The URL path of the calculation collection, such as `/api/v1/calculations`.
    static let calculationsPath =
        separator + [apiRoot, version1, calculations].map(\.description).joined(separator: separator)

    /// The URL path of one recorded calculation, returned in the `Location` header of a created calculation.
    ///
    /// - Parameter id: Identifier of the calculation.
    /// - Returns: The path, such as `/api/v1/calculations/0192e4a1-7c3b-7d2e-8f4a-5b6c7d8e9f01`.
    static func location(of id: CalculationID) -> String {
        calculationsPath + separator + id.description
    }
}
