import Vapor

/// Route paths of the operational endpoints, which are deliberately not versioned: orchestrators and monitors depend
/// on them and must not have to follow API versions.
enum OperationalPath {
    static let health: PathComponent = "health"
    static let version: PathComponent = "version"
}

/// The name the service goes by in `/version`, in logs and in the database's session list.
enum ServiceIdentity {
    static let name = "borba-scientific-engine"

    /// The versions of the business API this build serves.
    static let apiVersions = ["v1"]
}

/// Liveness payload.
struct LivenessResponse: Content {
    enum Status: String, Codable {
        case alive
    }

    let status: Status
}

/// The body of the response to `GET /version`.
struct VersionResponse: Content {
    /// The service name.
    let name: String

    /// Semantic version of the running build.
    let version: String

    /// Git commit the build was produced from.
    let commit: String

    /// ISO 8601 timestamp of the build, when the pipeline provides one.
    let buildDate: String?

    /// The environment the process runs in.
    let environment: String

    /// The versions of the business API this build serves.
    let apiVersions: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case version
        case commit
        case buildDate = "build_date"
        case environment
        case apiVersions = "api_versions"
    }
}

/// Endpoints used by orchestrators and operators rather than by API consumers.
struct OperationalRoutes: RouteCollection {
    private let version: VersionResponse

    /// Creates the routes.
    ///
    /// - Parameter version: What `/version` reports.
    init(version: VersionResponse) {
        self.version = version
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.get(OperationalPath.health, use: liveness)
        routes.get(OperationalPath.version, use: versionInformation)
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

    /// Reports which build is running.
    ///
    /// - Parameter request: The incoming request.
    /// - Returns: The build metadata.
    @Sendable
    private func versionInformation(_ request: Request) async -> VersionResponse {
        version
    }
}
