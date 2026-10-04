import BorbaScientificCore
import Logging
import Vapor

/// Writes one line per request: what was asked, what was answered and how long it took.
///
/// The route is logged as its *template* (`/api/v1/calculations/:id`), never as the raw path, so the field has a small
/// number of values that can be grouped and charted, and an identifier in a URL never turns into a log dimension. Client
/// addresses, headers, query strings and bodies are not logged: they can carry personal data, and the request
/// identifier already leads from a log line to everything else about the request.
///
/// The middleware sits inside the one that assigns the request identifiers, so the line carries them, and outside the
/// error mapping, so the status it reports is the one the client received.
struct AccessLogMiddleware: AsyncMiddleware {
    private static let message = "Request completed"
    private static let unmatchedRoute = "unmatched"
    private static let routeSeparator = "/"

    /// Routes polled by machines, logged at debug level so they do not drown the lines that matter.
    private static let probeRoutes: Set<String> = ["/health", "/ready", "/metrics"]

    private let clock: any EngineClock

    /// Creates the middleware.
    ///
    /// - Parameter clock: Measures how long each request takes.
    init(clock: any EngineClock) {
        self.clock = clock
    }

    /// Runs the rest of the chain and logs the outcome.
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
            log(request, status: response.status, bytesSent: response.body.count, startedAt: startedAt)
            return response
        } catch {
            log(request, status: .internalServerError, bytesSent: 0, startedAt: startedAt)
            throw error
        }
    }

    private func log(
        _ request: Request,
        status: HTTPResponseStatus,
        bytesSent: Int,
        startedAt: Duration
    ) {
        let route = Self.routeTemplate(of: request)
        let level: Logger.Level = Self.probeRoutes.contains(route) ? .debug : .info

        request.logger.log(
            level: level,
            "\(Self.message)",
            metadata: [
                "method": "\(request.method.rawValue)",
                "route": "\(route)",
                "status": .stringConvertible(Int(status.code)),
                "duration_ms": .stringConvertible((clock.uptime() - startedAt).totalMilliseconds),
                "request_bytes": .stringConvertible(request.body.data?.readableBytes ?? 0),
                "response_bytes": .stringConvertible(bytesSent),
            ]
        )
    }

    private static func routeTemplate(of request: Request) -> String {
        guard let route = request.route else {
            return unmatchedRoute
        }
        return routeSeparator + route.path.map(\.description).joined(separator: routeSeparator)
    }
}
