import BorbaScientificCore

/// One piece of structured context of an error, such as a rejected parameter.
struct ErrorDetailBody: Codable, Sendable, Equatable {
    /// The parameter, field, header or query parameter the detail refers to, when there is one.
    let field: String?

    /// What is wrong, phrased so the caller can fix it.
    let reason: String

    /// Converts a domain error detail.
    ///
    /// - Parameter detail: The detail to present.
    init(_ detail: ErrorDetail) {
        field = detail.field
        reason = detail.reason
    }

    /// Converts a detail stored with a recorded failure.
    ///
    /// - Parameter detail: The detail to present.
    init(_ detail: RecordedDetail) {
        field = detail.field
        reason = detail.reason
    }
}

/// The JSON body of every error response.
///
/// ```json
/// {
///   "error": {
///     "code": "DIVISION_BY_ZERO",
///     "message": "Division by zero is undefined: the divisor must not be zero.",
///     "request_id": "0192e4a1-7c3b-7d2e-8f4a-5b6c7d8e9f01",
///     "details": [{ "field": "divisor", "reason": "must not be zero" }],
///     "calculation_id": "0192e4a1-7c3b-7d2e-8f4a-5b6c7d8e9f02"
///   }
/// }
/// ```
///
/// `details` and `calculation_id` are omitted when there is nothing to say. The body never contains stack traces,
/// SQL, host names or any other internal information.
struct ErrorResponse: Codable, Sendable, Equatable {
    /// The error itself, wrapped so a client can tell an error body from a resource by its only key.
    struct Body: Codable, Sendable, Equatable {
        /// Stable identifier clients branch on.
        let code: String

        /// Explanation that is safe to show to a person.
        let message: String

        /// The request that failed, to quote when asking for support.
        let requestID: String

        /// Structured context; omitted when empty.
        let details: [ErrorDetailBody]?

        /// The calculation that was recorded, when the failure happened while computing one.
        let calculationID: String?

        enum CodingKeys: String, CodingKey {
            case code
            case message
            case requestID = "request_id"
            case details
            case calculationID = "calculation_id"
        }
    }

    /// The error.
    let error: Body
}
