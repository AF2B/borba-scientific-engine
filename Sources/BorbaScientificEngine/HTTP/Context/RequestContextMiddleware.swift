import BorbaScientificCore
import Vapor

/// Gives every request its identifiers, makes them available everywhere below the HTTP layer and echoes them back.
///
/// - The **request identifier** names this exchange. A well-formed `X-Request-ID` from the caller is adopted, which
///   lets a gateway's identifier follow the request into our logs; otherwise a new one is generated.
/// - The **correlation identifier** names the logical operation the request belongs to, possibly across services.
///   A well-formed `X-Correlation-ID` is adopted; otherwise it equals the request identifier.
///
/// The identifiers are bound as a task-local value for the duration of the request, so logs written by any layer
/// below — use cases, repositories, database code — carry them without any function passing them along. They are also
/// returned in the response headers, on successes and errors alike, so a caller can always quote them.
///
/// This middleware must be the outermost one, so that error responses produced further in carry the headers too.
struct RequestContextMiddleware: AsyncMiddleware {
    private let identifiers: any IdentifierGenerator

    /// Creates the middleware.
    ///
    /// - Parameter identifiers: Source of generated request identifiers.
    init(identifiers: any IdentifierGenerator) {
        self.identifiers = identifiers
    }

    /// Binds the identifiers, runs the rest of the chain and adds the identifiers to the response.
    ///
    /// - Parameters:
    ///   - request: The incoming request.
    ///   - next: The rest of the middleware chain.
    /// - Returns: The response, with `X-Request-ID` and `X-Correlation-ID` set.
    /// - Throws: Whatever the rest of the chain throws.
    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        let trace = makeTrace(for: request)
        request.bind(trace)
        request.logger[metadataKey: TraceMetadataKey.requestID] = .string(trace.requestID.rawValue)
        request.logger[metadataKey: TraceMetadataKey.correlationID] = .string(trace.correlationID.rawValue)

        let response = try await TraceContext.withValue(trace) {
            try await next.respond(to: request)
        }

        response.headers.replaceOrAdd(name: APIHeader.requestID, value: trace.requestID.rawValue)
        response.headers.replaceOrAdd(name: APIHeader.correlationID, value: trace.correlationID.rawValue)
        return response
    }

    private func makeTrace(for request: Request) -> TraceContext {
        let requestID =
            adoptedIdentifier(APIHeader.requestID, in: request) ?? identifiers.next().uuidString.lowercased()
        let correlationID = adoptedIdentifier(APIHeader.correlationID, in: request) ?? requestID

        return TraceContext(requestID: RequestID(requestID), correlationID: CorrelationID(correlationID))
    }

    private func adoptedIdentifier(
        _ header: HTTPHeaders.Name,
        in request: Request
    ) -> String? {
        guard let supplied = request.headers.first(name: header), RequestIdentifierPolicy.isWellFormed(supplied) else {
            return nil
        }
        return supplied
    }
}
