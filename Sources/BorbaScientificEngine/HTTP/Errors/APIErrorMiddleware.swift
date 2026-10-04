import BorbaScientificCore
import Vapor

/// Turns every thrown error into the API's error response and logs it at the level its classification deserves.
///
/// Handlers throw typed failures; this middleware is the only place that decides what the caller sees. The body is
/// built from the ``ErrorDescription`` alone, so no internal detail can leak into it.
struct APIErrorMiddleware: AsyncMiddleware {
    private static let fallbackMessage = "An unexpected error occurred."

    private let reporter: any ErrorReporter

    /// Creates the middleware.
    ///
    /// - Parameter reporter: Told about the failures that deserve a person's attention.
    init(reporter: any ErrorReporter) {
        self.reporter = reporter
    }

    /// Runs the rest of the chain and converts a thrown error into a response.
    ///
    /// - Parameters:
    ///   - request: The incoming request.
    ///   - next: The rest of the middleware chain.
    /// - Returns: The handler's response, or the error response when the handler threw.
    /// - Throws: Never in practice: every error becomes a response. The signature only satisfies the protocol.
    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            let description = ErrorMapper.describe(error)
            description.log(to: request.logger)
            if let failure = description.reportableFailure(for: request) {
                reporter.report(failure)
            }
            return response(for: description, on: request)
        }
    }

    private func response(
        for description: ErrorDescription,
        on request: Request
    ) -> Response {
        var headers = HTTPHeaders()
        if description.isReplay {
            headers.replaceOrAdd(name: APIHeader.idempotentReplayed, value: APIHeader.replayedValue)
        }

        do {
            return try request.jsonResponse(
                description.response(requestID: request.trace.requestID),
                status: description.status,
                headers: headers
            )
        } catch {
            return fallbackResponse(for: request)
        }
    }

    /// Used only if serializing the error body itself fails, which would otherwise leave the caller with nothing.
    /// The request identifier is made of characters that need no JSON escaping.
    private func fallbackResponse(for request: Request) -> Response {
        let body = """
            {"error":{"code":"\(ErrorCode.internalError.rawValue)","message":"\(Self.fallbackMessage)",\
            "request_id":"\(request.trace.requestID.rawValue)"}}
            """
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: .internalServerError, headers: headers, body: .init(string: body))
    }

}
