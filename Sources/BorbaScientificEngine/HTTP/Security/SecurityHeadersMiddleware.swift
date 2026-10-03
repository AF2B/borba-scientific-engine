import Vapor

/// Adds the headers that stop a browser from interpreting, caching or embedding API output.
///
/// The API serves JSON to programs. Nothing it returns is meant to be rendered, framed or cached by an intermediary,
/// and saying so costs nothing. Transport security (HSTS, TLS) belongs to the proxy that terminates TLS.
struct SecurityHeadersMiddleware: AsyncMiddleware {
    /// Runs the rest of the chain and adds the headers to its response.
    ///
    /// - Parameters:
    ///   - request: The incoming request.
    ///   - next: The rest of the middleware chain.
    /// - Returns: The response with the security headers set.
    /// - Throws: Whatever the rest of the chain throws.
    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        let response = try await next.respond(to: request)

        response.headers.replaceOrAdd(name: .xContentTypeOptions, value: SecurityHeaderValue.noSniff)
        response.headers.replaceOrAdd(name: .contentSecurityPolicy, value: SecurityHeaderValue.contentSecurityPolicy)
        response.headers.replaceOrAdd(name: .cacheControl, value: SecurityHeaderValue.noStore)
        response.headers.replaceOrAdd(name: .xFrameOptions, value: SecurityHeaderValue.frameDeny)
        response.headers.replaceOrAdd(name: APIHeader.referrerPolicy, value: SecurityHeaderValue.noReferrer)
        return response
    }
}
