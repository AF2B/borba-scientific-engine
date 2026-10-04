import BorbaScientificCore
import Vapor

/// Records the rate, errors and duration of every request, by method, route template and status.
///
/// These are the "RED" metrics of the service. The route is the *template* (`/api/v1/calculations/:id`), and requests
/// that matched no route share one fixed value, so a scanner probing random paths cannot create unlimited series.
///
/// Vapor emits similar metrics through the process-wide metrics system, which is switched off for this application:
/// recording through an explicitly passed factory keeps the metrics testable and free of global state.
struct MetricsMiddleware: AsyncMiddleware {
    private let metrics: EngineMetrics
    private let clock: any EngineClock

    /// Creates the middleware.
    ///
    /// - Parameters:
    ///   - metrics: Where the measurements are recorded.
    ///   - clock: Measures how long each request takes.
    init(
        metrics: EngineMetrics,
        clock: any EngineClock
    ) {
        self.metrics = metrics
        self.clock = clock
    }

    /// Runs the rest of the chain and records the outcome.
    ///
    /// - Parameters:
    ///   - request: The incoming request.
    ///   - next: The rest of the middleware chain.
    /// - Returns: Whatever the rest of the chain returns.
    /// - Throws: Whatever the rest of the chain throws.
    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        let startedAt = clock.uptime()

        do {
            let response = try await next.respond(to: request)
            record(request, status: response.status.code, startedAt: startedAt)
            return response
        } catch {
            record(request, status: HTTPStatus.internalServerError.code, startedAt: startedAt)
            throw error
        }
    }

    private func record(
        _ request: Request,
        status: UInt,
        startedAt: Duration
    ) {
        metrics.recordRequest(
            method: request.route == nil ? RouteLabel.unmatchedMethod : request.method.rawValue,
            route: RouteLabel.template(of: request),
            status: status,
            duration: clock.uptime() - startedAt
        )
    }
}

/// How a request's route is named in logs and metrics.
enum RouteLabel {
    /// The route of a request that matched none.
    static let unmatched = "unmatched"

    /// The method label of a request that matched no route: the real method of an unknown path is attacker-controlled.
    static let unmatchedMethod = "undefined"

    private static let separator = "/"

    /// The template of the route a request matched.
    ///
    /// - Parameter request: The request.
    /// - Returns: The path with parameters as `:name`, such as `/api/v1/calculations/:id`, or ``unmatched``.
    static func template(of request: Request) -> String {
        guard let route = request.route else {
            return unmatched
        }
        return separator + route.path.map(\.description).joined(separator: separator)
    }
}
