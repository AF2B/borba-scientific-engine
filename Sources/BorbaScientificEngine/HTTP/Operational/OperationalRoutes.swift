import Prometheus
import Vapor

/// Route paths of the operational endpoints, which are deliberately not versioned: orchestrators and monitors depend
/// on them and must not have to follow API versions.
enum OperationalPath {
    static let health: PathComponent = "health"
    static let metrics: PathComponent = "metrics"
    static let ready: PathComponent = "ready"
    static let version: PathComponent = "version"
}

/// The name the service goes by in `/version`, in logs and in the database's session list.
enum ServiceIdentity {
    static let name = "borba-scientific-engine"

    /// The versions of the business API this build serves.
    static let apiVersions = ["v1"]
}

/// Liveness payload.
struct LivenessResponse: Encodable, Sendable {
    enum Status: String, Codable {
        case alive
    }

    let status: Status
}

/// The body of the response to `GET /ready`.
///
/// ```json
/// { "status": "not_ready", "checks": [{ "name": "database", "status": "down", "detail": "migrations pending" }] }
/// ```
///
/// The `detail` comes from a fixed vocabulary; it never contains a host name or an error text.
struct ReadinessResponse: Encodable, Sendable, Equatable {
    /// The verdict.
    enum Status: String, Encodable, Sendable {
        case ready
        case notReady = "not_ready"
    }

    /// What one probe found.
    struct Check: Encodable, Sendable, Equatable {
        let name: String
        let status: ReadinessCheckResult.State
        let detail: String?
    }

    /// Whether the service should be sent traffic.
    let status: Status

    /// One entry per probe.
    let checks: [Check]

    /// Presents a readiness report.
    ///
    /// - Parameter report: What readiness found.
    init(_ report: ReadinessReport) {
        status = report.isReady ? .ready : .notReady
        checks = report.checks.map { Check(name: $0.name, status: $0.state, detail: $0.detail) }
    }
}

/// The body of the response to `GET /version`.
struct VersionResponse: Encodable, Sendable {
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
    /// The media type of the Prometheus text exposition format.
    private static let prometheusMediaType = "text/plain; version=0.0.4; charset=utf-8"

    private let version: VersionResponse
    private let readiness: ReadinessService
    private let metrics: EngineMetrics
    private let metricsRegistry: PrometheusCollectorRegistry
    private let processMetrics = ProcessMetricsRecorder()

    /// Creates the routes.
    ///
    /// - Parameters:
    ///   - version: What `/version` reports.
    ///   - readiness: Answers `/ready`.
    ///   - metrics: Records the process-level metrics just before they are published.
    ///   - metricsRegistry: Holds the metrics `/metrics` publishes.
    init(
        version: VersionResponse,
        readiness: ReadinessService,
        metrics: EngineMetrics,
        metricsRegistry: PrometheusCollectorRegistry
    ) {
        self.version = version
        self.readiness = readiness
        self.metrics = metrics
        self.metricsRegistry = metricsRegistry
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.get(OperationalPath.health, use: liveness)
        routes.get(OperationalPath.ready, use: readinessReport)
        routes.get(OperationalPath.metrics, use: metricsExposition)
        routes.get(OperationalPath.version, use: versionInformation)
    }

    /// Reports that the process is alive.
    ///
    /// Liveness must stay cheap and dependency-free: a failing database must never get the process restarted.
    ///
    /// - Parameter request: The incoming request.
    /// - Returns: A constant "alive" payload.
    /// - Throws: An encoding error when the response cannot be serialized.
    @Sendable
    private func liveness(_ request: Request) throws -> Response {
        try request.jsonResponse(LivenessResponse(status: .alive))
    }

    /// Reports whether the service should be sent traffic: the database answers with every migration applied, and the
    /// process is not shutting down.
    ///
    /// Unlike liveness this depends on the database, on purpose: an instance that cannot reach it should be taken out
    /// of rotation, not restarted. The answer is cached for a moment and shared by concurrent probes.
    ///
    /// - Parameter request: The incoming request.
    /// - Returns: `200` when ready, `503` otherwise, with what each probe found.
    /// - Throws: An encoding error when the response cannot be serialized.
    @Sendable
    private func readinessReport(_ request: Request) async throws -> Response {
        let report = await readiness.report()

        return try request.jsonResponse(
            ReadinessResponse(report),
            status: report.isReady ? .ok : .serviceUnavailable
        )
    }

    /// Publishes every metric of the service in the Prometheus text format, for a scraper to collect.
    ///
    /// The process-level gauges are read just before publishing, so they are as fresh as the scrape. The endpoint exposes
    /// operational detail and belongs behind the network boundary, not on the public internet.
    ///
    /// - Parameter request: The incoming request.
    /// - Returns: The metrics as text.
    @Sendable
    private func metricsExposition(_ request: Request) -> Response {
        processMetrics.refresh(into: metrics)

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: Self.prometheusMediaType)
        return Response(status: .ok, headers: headers, body: .init(string: metricsRegistry.emitToString()))
    }

    /// Reports which build is running.
    ///
    /// - Parameter request: The incoming request.
    /// - Returns: The build metadata.
    /// - Throws: An encoding error when the response cannot be serialized.
    @Sendable
    private func versionInformation(_ request: Request) throws -> Response {
        try request.jsonResponse(version)
    }
}
