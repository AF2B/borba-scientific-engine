import BorbaScientificCore
import Foundation

/// One row of the `calculations` table, as the database sees it. This type never leaves the persistence layer: the
/// rest of the application only ever sees ``CalculationRecord``.
///
/// The `jsonb` columns are exchanged as JSON *text* and converted here, in one place. The driver would otherwise pick
/// a SQL type from the shape of the Swift value — a bare number would travel as `double precision` and be rejected by
/// a `jsonb` column, and a bare number read from `jsonb` would come back as a string — so the conversion is made
/// explicit and exact instead of depending on that inference.
struct CalculationRow: Codable, Sendable {
    /// The columns, in the order the queries select them.
    static let columns = [
        "id", "module", "operation", "status", "parameters", "result", "error_code", "error_message",
        "error_details", "execution_time_ns", "request_id", "correlation_id", "created_at",
    ].joined(separator: ", ")

    private static let nanosecondsPerSecond: Int64 = 1_000_000_000
    private static let attosecondsPerNanosecond: Int64 = 1_000_000_000

    let id: UUID
    let module: String
    let operation: String
    let status: String
    let parameters: String
    let result: String?
    let errorCode: String?
    let errorMessage: String?
    let errorDetails: String?
    let executionTimeNanoseconds: Int64
    let requestID: String
    let correlationID: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, module, operation, status, parameters, result
        case errorCode = "error_code"
        case errorMessage = "error_message"
        case errorDetails = "error_details"
        case executionTimeNanoseconds = "execution_time_ns"
        case requestID = "request_id"
        case correlationID = "correlation_id"
        case createdAt = "created_at"
    }

    /// Flattens a record into columns.
    ///
    /// - Parameter record: The record to store.
    init(_ record: CalculationRecord) {
        id = record.id.rawValue
        module = record.type.module.rawValue
        operation = record.type.operation.rawValue
        status = record.status.rawValue
        parameters = Self.json(record.parameters)
        executionTimeNanoseconds = Self.nanoseconds(of: record.executionTime)
        requestID = record.trace.requestID.rawValue
        correlationID = record.trace.correlationID.rawValue
        createdAt = record.createdAt

        switch record.outcome {
        case .succeeded(let value):
            result = Self.json(value)
            errorCode = nil
            errorMessage = nil
            errorDetails = nil
        case .failed(let failure):
            result = nil
            errorCode = failure.code.rawValue
            errorMessage = failure.message
            errorDetails = Self.json(failure.details)
        }
    }

    /// Rebuilds the record, checking that the columns are consistent.
    ///
    /// - Returns: The record.
    /// - Throws: ``RepositoryError/corrupted(reason:)`` when the row cannot be a valid record.
    func record() throws(RepositoryError) -> CalculationRecord {
        guard let status = CalculationStatus(rawValue: status) else {
            throw .corrupted(reason: "unknown status")
        }

        let outcome: CalculationOutcome
        switch status {
        case .succeeded:
            guard let result else {
                throw .corrupted(reason: "a succeeded calculation has no result")
            }
            outcome = .succeeded(try Self.decode(CalculationValue.self, from: result))
        case .failed:
            guard let errorCode, let errorMessage else {
                throw .corrupted(reason: "a failed calculation has no error")
            }
            var details: [RecordedDetail] = []
            if let errorDetails {
                details = try Self.decode([RecordedDetail].self, from: errorDetails)
            }
            outcome = .failed(RecordedFailure(code: ErrorCode(errorCode), message: errorMessage, details: details))
        }

        return CalculationRecord(
            id: CalculationID(id),
            type: CalculationType(module: ModuleName(module), operation: OperationName(operation)),
            parameters: try Self.decode([String: CalculationValue].self, from: parameters),
            outcome: outcome,
            executionTime: .nanoseconds(executionTimeNanoseconds),
            createdAt: createdAt,
            trace: TraceContext(requestID: RequestID(requestID), correlationID: CorrelationID(correlationID))
        )
    }

    private static func json<Value: Encodable>(_ value: Value) -> String {
        guard let data = try? JSONEncoder().encode(value), let text = String(bytes: data, encoding: .utf8) else {
            // Values are finite by construction; a schema check rejects this placeholder if that ever fails.
            return "null"
        }
        return text
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from text: String
    ) throws(RepositoryError) -> Value {
        do {
            return try JSONDecoder().decode(type, from: Data(text.utf8))
        } catch {
            throw .corrupted(reason: "stored JSON could not be decoded as \(type): \(error)")
        }
    }

    private static func nanoseconds(of duration: Duration) -> Int64 {
        let components = duration.components
        let (whole, overflow) = components.seconds.multipliedReportingOverflow(by: nanosecondsPerSecond)
        return overflow ? Int64.max : whole + components.attoseconds / attosecondsPerNanosecond
    }
}

/// The idempotency-key columns needed to decide whether a request is a retry.
struct IdempotencyRow: Codable, Sendable {
    let calculationID: UUID
    let fingerprint: String

    enum CodingKeys: String, CodingKey {
        case calculationID = "calculation_id"
        case fingerprint
    }
}
