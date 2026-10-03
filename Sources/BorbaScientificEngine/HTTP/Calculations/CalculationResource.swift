import BorbaScientificCore

/// How a recorded calculation appears in responses: a representation of its own, so the domain model can change
/// without breaking the contract and the contract can change without touching the domain.
///
/// ```json
/// {
///   "id": "0192e4a1-7c3b-7d2e-8f4a-5b6c7d8e9f01",
///   "module": "arithmetic",
///   "operation": "add",
///   "status": "succeeded",
///   "parameters": { "left": 2, "right": 3 },
///   "result": 5,
///   "execution_time_ms": 0.021,
///   "created_at": "2026-10-03T12:00:00.123Z",
///   "request_id": "0192e4a1-7c3b-7d2e-8f4a-5b6c7d8e9f02",
///   "correlation_id": "0192e4a1-7c3b-7d2e-8f4a-5b6c7d8e9f02"
/// }
/// ```
///
/// A succeeded calculation has a `result` and no `error`; a failed one, which only the history returns, has an `error`
/// and no `result`.
struct CalculationResource: Encodable, Sendable, Equatable {
    /// Why a recorded calculation failed.
    struct Failure: Encodable, Sendable, Equatable {
        /// Stable identifier clients branch on.
        let code: String

        /// Explanation that is safe to show to a person.
        let message: String

        /// Structured context; omitted when empty.
        let details: [ErrorDetailBody]?
    }

    /// Identifier of the calculation.
    let id: String

    /// Name of the module that owns the operation.
    let module: String

    /// Name of the operation inside the module.
    let operation: String

    /// Whether the calculation produced a result.
    let status: CalculationStatus

    /// The parameters exactly as the caller supplied them.
    let parameters: [String: CalculationValue]

    /// The result of a succeeded calculation.
    let result: CalculationValue?

    /// The failure of a failed calculation.
    let error: Failure?

    /// Time spent computing, in milliseconds, excluding persistence.
    let executionTimeMilliseconds: Double

    /// When the calculation was recorded, ISO 8601 in UTC.
    let createdAt: String

    /// The request that asked for the calculation.
    let requestID: String

    /// The logical operation the request belonged to.
    let correlationID: String

    enum CodingKeys: String, CodingKey {
        case id
        case module
        case operation
        case status
        case parameters
        case result
        case error
        case executionTimeMilliseconds = "execution_time_ms"
        case createdAt = "created_at"
        case requestID = "request_id"
        case correlationID = "correlation_id"
    }

    /// Presents a record.
    ///
    /// - Parameter record: The record to present.
    init(_ record: CalculationRecord) {
        id = record.id.description
        module = record.type.module.rawValue
        operation = record.type.operation.rawValue
        status = record.status
        parameters = record.parameters
        executionTimeMilliseconds = record.executionTime.totalMilliseconds
        createdAt = Timestamp.format(record.createdAt)
        requestID = record.trace.requestID.rawValue
        correlationID = record.trace.correlationID.rawValue

        switch record.outcome {
        case .succeeded(let value):
            result = value
            error = nil
        case .failed(let failure):
            result = nil
            error = Failure(
                code: failure.code.rawValue,
                message: failure.message,
                details: failure.details.isEmpty ? nil : failure.details.map(ErrorDetailBody.init)
            )
        }
    }
}
