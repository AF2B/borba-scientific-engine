import BorbaScientificCore
import Vapor

extension ErrorCode {
    /// The request is malformed: unreadable JSON, a missing or unknown field, a bad header or query parameter.
    static let invalidRequest = ErrorCode("INVALID_REQUEST")

    /// No route matches the request path.
    static let notFound = ErrorCode("NOT_FOUND")

    /// The request body is larger than the server accepts.
    static let payloadTooLarge = ErrorCode("PAYLOAD_TOO_LARGE")

    /// The request body is not JSON.
    static let unsupportedMediaType = ErrorCode("UNSUPPORTED_MEDIA_TYPE")
}

/// One documented error: the stable code, the HTTP status it travels with and what it means.
struct ErrorCatalogEntry: Sendable, Equatable {
    /// Stable identifier clients branch on.
    let code: ErrorCode

    /// HTTP status of the response.
    let status: HTTPResponseStatus

    /// What the error means and what the caller can do about it.
    let meaning: String
}

/// Every error the API can return, with its HTTP status.
///
/// The catalog is the single source of truth for the status mapping, for the error documentation and for the
/// OpenAPI specification; tests keep all three in step with the code.
enum ErrorCatalog {
    /// Status of a calculation failure whose code is not listed: the request was well formed but could not be
    /// computed, which is what every module-specific failure means.
    static let domainFailureStatus = HTTPResponseStatus.unprocessableEntity

    /// Codes that only appear in events and logs, never in an API response.
    static let eventOnlyCodes: Set<ErrorCode> = [.duplicateSuppressed]

    /// Every documented error, ordered from request-level problems to calculation and infrastructure failures.
    static let entries: [ErrorCatalogEntry] = requestEntries + calculationEntries + infrastructureEntries

    /// The HTTP status a code travels with.
    ///
    /// - Parameter code: The error code.
    /// - Returns: The status of the catalog entry, or ``domainFailureStatus`` when the code is not listed.
    static func status(for code: ErrorCode) -> HTTPResponseStatus {
        entry(for: code)?.status ?? domainFailureStatus
    }

    /// The catalog entry of a code.
    ///
    /// - Parameter code: The error code.
    /// - Returns: The entry, or `nil` when the code is not listed.
    static func entry(for code: ErrorCode) -> ErrorCatalogEntry? {
        index[code]
    }

    private static let index: [ErrorCode: ErrorCatalogEntry] = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.code, $0) }
    )

    private static let requestEntries: [ErrorCatalogEntry] = [
        ErrorCatalogEntry(
            code: .invalidRequest,
            status: .badRequest,
            meaning: "The request is malformed. The details name each offending field, header or query parameter."
        ),
        ErrorCatalogEntry(
            code: .unsupportedMediaType,
            status: .unsupportedMediaType,
            meaning: "The body must be sent as application/json."
        ),
        ErrorCatalogEntry(
            code: .payloadTooLarge,
            status: .payloadTooLarge,
            meaning: "The request body is larger than the server accepts."
        ),
        ErrorCatalogEntry(
            code: .notFound,
            status: .notFound,
            meaning: "No endpoint exists at this path."
        ),
    ]

    private static let calculationEntries: [ErrorCatalogEntry] = [
        ErrorCatalogEntry(
            code: .validationFailed,
            status: .unprocessableEntity,
            meaning: "A parameter is missing, malformed or out of range. The details list every problem."
        ),
        ErrorCatalogEntry(
            code: .unsupportedOperation,
            status: .notFound,
            meaning: "The module or operation does not exist. The types endpoint lists the supported ones."
        ),
        ErrorCatalogEntry(
            code: .calculationNotFound,
            status: .notFound,
            meaning: "No calculation with this identifier exists."
        ),
        ErrorCatalogEntry(
            code: .idempotencyKeyReused,
            status: .unprocessableEntity,
            meaning: "The idempotency key was already used with a different request. Use a new key."
        ),
        ErrorCatalogEntry(
            code: .divisionByZero,
            status: .unprocessableEntity,
            meaning: "A division, modulo or negative power of zero was requested."
        ),
        ErrorCatalogEntry(
            code: .undefinedResult,
            status: .unprocessableEntity,
            meaning: "The result is mathematically undefined for the input, such as the logarithm of zero."
        ),
        ErrorCatalogEntry(
            code: .numericOverflow,
            status: .unprocessableEntity,
            meaning: "The result is too large to be represented."
        ),
        ErrorCatalogEntry(
            code: .limitExceeded,
            status: .unprocessableEntity,
            meaning: "The input exceeds a safety limit, such as the largest matrix or the largest batch."
        ),
        ErrorCatalogEntry(
            code: .noConvergence,
            status: .unprocessableEntity,
            meaning: "An iterative method gave up before reaching the requested accuracy."
        ),
        ErrorCatalogEntry(
            code: .invalidExpression,
            status: .unprocessableEntity,
            meaning: "The expression cannot be parsed or evaluated. The details give the position of the problem."
        ),
        ErrorCatalogEntry(
            code: .singularMatrix,
            status: .unprocessableEntity,
            meaning: "The matrix has no inverse, so the system cannot be solved."
        ),
        ErrorCatalogEntry(
            code: .calculationTimeout,
            status: .unprocessableEntity,
            meaning: "The calculation did not finish within its time budget. Simplify the input or use a new key."
        ),
    ]

    private static let infrastructureEntries: [ErrorCatalogEntry] = [
        ErrorCatalogEntry(
            code: .calculationCancelled,
            status: .serviceUnavailable,
            meaning: "The calculation was cancelled before it finished, for example during a shutdown. Retry."
        ),
        ErrorCatalogEntry(
            code: .storageUnavailable,
            status: .serviceUnavailable,
            meaning: "The calculation history is temporarily unavailable. Retry later."
        ),
        ErrorCatalogEntry(
            code: .storageFailure,
            status: .internalServerError,
            meaning: "The calculation history failed in a way that will not go away by itself."
        ),
        ErrorCatalogEntry(
            code: .internalError,
            status: .internalServerError,
            meaning: "An unexpected failure inside the engine. Quote the request identifier when reporting it."
        ),
    ]
}
