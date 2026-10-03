import BorbaScientificCore
import Vapor

/// What an error looks like on the wire, plus what the logs need to know about it.
struct ErrorDescription: Sendable, Equatable {
    /// HTTP status of the response.
    let status: HTTPResponseStatus

    /// Stable identifier clients branch on.
    let code: ErrorCode

    /// Explanation that is safe to show to a person.
    let message: String

    /// Structured context for the caller.
    let details: [ErrorDetailBody]

    /// The recorded calculation the failure belongs to, when there is one.
    let calculationID: CalculationID?

    /// Whether the response repeats the stored outcome of an earlier identical request.
    let isReplay: Bool

    /// How logging, metrics and error reporting treat the failure.
    let classification: ErrorClassification

    /// Technical detail for logs and error reports only. It is never part of a response.
    let diagnostic: String?

    /// Creates a description. The status is taken from the ``ErrorCatalog`` unless one is given.
    ///
    /// - Parameters:
    ///   - code: Stable identifier clients branch on.
    ///   - message: Explanation that is safe to show to a person.
    ///   - classification: How logging, metrics and error reporting treat the failure.
    ///   - status: HTTP status; defaults to the catalog's status for `code`.
    ///   - details: Structured context for the caller.
    ///   - calculationID: The recorded calculation the failure belongs to.
    ///   - isReplay: Whether the response repeats the stored outcome of an earlier identical request.
    ///   - diagnostic: Technical detail for logs only.
    init(
        code: ErrorCode,
        message: String,
        classification: ErrorClassification,
        status: HTTPResponseStatus? = nil,
        details: [ErrorDetailBody] = [],
        calculationID: CalculationID? = nil,
        isReplay: Bool = false,
        diagnostic: String? = nil
    ) {
        self.status = status ?? ErrorCatalog.status(for: code)
        self.code = code
        self.message = message
        self.details = details
        self.calculationID = calculationID
        self.isReplay = isReplay
        self.classification = classification
        self.diagnostic = diagnostic
    }

    /// Builds the response body.
    ///
    /// - Parameter requestID: The request that failed.
    /// - Returns: The body to serialize.
    func response(requestID: RequestID) -> ErrorResponse {
        ErrorResponse(
            error: ErrorResponse.Body(
                code: code.rawValue,
                message: message,
                requestID: requestID.rawValue,
                details: details.isEmpty ? nil : details,
                calculationID: calculationID?.description
            )
        )
    }
}

/// Turns anything the application can throw into an ``ErrorDescription``.
///
/// This is the only place where errors become statuses and codes, which is what keeps error responses consistent:
/// handlers throw typed failures and never choose a status themselves.
enum ErrorMapper {
    private static let invalidRequestMessage = "The request is malformed."
    private static let unsupportedMediaTypeMessage = "The request body must be application/json."
    private static let payloadTooLargeMessage = "The request body is too large."
    private static let notFoundMessage = "No endpoint exists at this path."
    private static let unexpectedMessage = CalculationError.internalFailure(reason: "").message
    private static let clientErrorStatuses: ClosedRange<UInt> = 400...499

    /// Describes an error for the wire and for the logs.
    ///
    /// - Parameter error: Whatever a handler or a middleware threw.
    /// - Returns: The description. Errors that are not recognised become a generic internal error whose cause is
    ///   kept for the logs only.
    static func describe(_ error: any Error) -> ErrorDescription {
        switch error {
        case let failure as APIFailure:
            describe(failure)
        case let failure as ExecutionFailure:
            describe(failure)
        case let failure as HistoryFailure:
            describe(failure)
        case let abort as any AbortError:
            describe(abort)
        case is CancellationError:
            describe(ExecutionFailure.cancelled)
        default:
            unexpected(diagnostic: String(describing: error))
        }
    }

    // MARK: - Typed failures

    private static func describe(_ failure: APIFailure) -> ErrorDescription {
        switch failure {
        case .invalidRequest(let details):
            ErrorDescription(
                code: .invalidRequest,
                message: invalidRequestMessage,
                classification: .application,
                details: details.map(ErrorDetailBody.init)
            )
        case .unsupportedMediaType:
            ErrorDescription(
                code: .unsupportedMediaType,
                message: unsupportedMediaTypeMessage,
                classification: .application
            )
        case .calculationFailed(let recorded, let calculationID, let replayed):
            ErrorDescription(
                code: recorded.code,
                message: recorded.message,
                classification: .expectedDomain,
                details: recorded.details.map(ErrorDetailBody.init),
                calculationID: calculationID,
                isReplay: replayed
            )
        }
    }

    private static func describe(_ failure: ExecutionFailure) -> ErrorDescription {
        ErrorDescription(
            code: failure.code,
            message: failure.message,
            classification: failure.classification,
            details: failure.details.map(ErrorDetailBody.init),
            diagnostic: diagnostic(of: failure)
        )
    }

    private static func describe(_ failure: HistoryFailure) -> ErrorDescription {
        ErrorDescription(
            code: failure.code,
            message: failure.message,
            classification: failure.classification,
            diagnostic: diagnostic(of: failure)
        )
    }

    private static func diagnostic(of failure: ExecutionFailure) -> String? {
        switch failure {
        case .defect(let reason):
            reason
        case .storage(let error):
            error.diagnostic
        case .rejected, .idempotencyConflict, .cancelled:
            nil
        }
    }

    private static func diagnostic(of failure: HistoryFailure) -> String? {
        switch failure {
        case .storage(let error):
            error.diagnostic
        case .notFound:
            nil
        }
    }

    // MARK: - Vapor's own failures

    /// Maps the failures Vapor raises before a handler runs: no route, a body over the limit, an unreadable body.
    /// The reason Vapor attaches is never forwarded, because it may describe internals.
    private static func describe(_ abort: any AbortError) -> ErrorDescription {
        switch abort.status {
        case .notFound:
            return ErrorDescription(code: .notFound, message: notFoundMessage, classification: .application)
        case .payloadTooLarge:
            return ErrorDescription(
                code: .payloadTooLarge,
                message: payloadTooLargeMessage,
                classification: .application
            )
        case .unsupportedMediaType:
            return describe(APIFailure.unsupportedMediaType)
        default:
            guard clientErrorStatuses.contains(abort.status.code) else {
                return unexpected(diagnostic: abort.reason)
            }
            return ErrorDescription(
                code: .invalidRequest,
                message: invalidRequestMessage,
                classification: .application,
                status: abort.status,
                diagnostic: abort.reason
            )
        }
    }

    private static func unexpected(diagnostic: String) -> ErrorDescription {
        ErrorDescription(
            code: .internalError,
            message: unexpectedMessage,
            classification: .unexpected,
            diagnostic: diagnostic
        )
    }
}
