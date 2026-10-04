import Vapor

/// Counts every request from the moment it enters the application until its response is produced, so the shutdown can
/// wait for the ones that are still running. It must be the outermost middleware.
struct InFlightMiddleware: AsyncMiddleware {
    private let requests: InFlightRequests

    /// Creates the middleware.
    ///
    /// - Parameter requests: The counter to keep.
    init(requests: InFlightRequests) {
        self.requests = requests
    }

    /// Counts the request around the rest of the chain.
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
        requests.begin()
        defer { requests.end() }

        return try await next.respond(to: request)
    }
}
