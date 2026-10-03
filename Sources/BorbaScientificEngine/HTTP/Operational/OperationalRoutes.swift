import Vapor

/// Route paths of the operational endpoints, which are deliberately not versioned.
enum OperationalPath {
    static let health: PathComponent = "health"
}

/// Liveness payload.
struct LivenessResponse: Content {
    enum Status: String, Codable {
        case alive
    }

    let status: Status
}

/// Endpoints used by orchestrators and operators rather than by API consumers.
struct OperationalRoutes: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get(OperationalPath.health, use: liveness)
    }

    /// Reports that the process is alive.
    ///
    /// Liveness must stay cheap and dependency-free: a failing database must never get the process restarted.
    ///
    /// - Parameter request: The incoming request.
    /// - Returns: A constant "alive" payload.
    @Sendable
    private func liveness(_ request: Request) async -> LivenessResponse {
        LivenessResponse(status: .alive)
    }
}
