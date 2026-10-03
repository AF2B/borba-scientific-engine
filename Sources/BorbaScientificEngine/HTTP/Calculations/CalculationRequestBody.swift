import BorbaScientificCore

/// The body of `POST /api/v1/calculations`: which calculation to run and with what.
///
/// ```json
/// { "module": "arithmetic", "operation": "add", "parameters": { "left": 2, "right": 3 } }
/// ```
///
/// Fields the endpoint does not know are rejected rather than ignored, so a typo such as `paramters` is reported
/// instead of silently producing a validation error about missing parameters.
struct CalculationRequestBody: Decodable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case module
        case operation
        case parameters
    }

    /// Name of the module that owns the operation.
    let module: String

    /// Name of the operation inside the module.
    let operation: String

    /// Raw parameters by name; validated against the operation's declarations before anything runs.
    let parameters: [String: CalculationValue]

    /// Reads a body that carries exactly the calculation fields.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: ``UnknownFieldsError`` for extra fields and a decoding error for missing or mistyped ones.
    init(from decoder: any Decoder) throws {
        try self.init(from: decoder, extraFields: [])
    }

    /// Reads the calculation fields from an object that may also carry other known fields, such as a batch item.
    ///
    /// - Parameters:
    ///   - decoder: The decoder to read from.
    ///   - extraFields: Further field names the object may contain, which the caller reads itself.
    /// - Throws: ``UnknownFieldsError`` for fields that are neither calculation fields nor `extraFields`, and a
    ///   decoding error for missing or mistyped ones.
    init(
        from decoder: any Decoder,
        extraFields: Set<String>
    ) throws {
        try decoder.rejectUnknownFields(allowed: Set(CodingKeys.allCases.map(\.rawValue)).union(extraFields))

        let container = try decoder.container(keyedBy: CodingKeys.self)
        module = try container.decode(String.self, forKey: .module)
        operation = try container.decode(String.self, forKey: .operation)
        parameters = try container.decodeIfPresent([String: CalculationValue].self, forKey: .parameters) ?? [:]
    }

    /// The domain request this body describes.
    var calculationRequest: CalculationRequest {
        CalculationRequest(
            type: CalculationType(module: ModuleName(module), operation: OperationName(operation)),
            parameters: parameters
        )
    }
}

/// One calculation of a batch: the calculation itself and, optionally, its own idempotency key.
///
/// A batch has no single idempotency header because its calculations succeed or fail independently; each one that
/// needs retry safety carries its own key.
struct BatchItemBody: Decodable, Sendable, Equatable {
    private enum ExtraKeys: String, CodingKey {
        case idempotencyKey = "idempotency_key"
    }

    /// The calculation to run.
    let calculation: CalculationRequestBody

    /// The key that makes a retry of this calculation safe, as the caller wrote it.
    let idempotencyKey: String?

    /// Reads one item.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: ``UnknownFieldsError`` for unknown fields and a decoding error for missing or mistyped ones.
    init(from decoder: any Decoder) throws {
        calculation = try CalculationRequestBody(from: decoder, extraFields: [ExtraKeys.idempotencyKey.rawValue])

        let container = try decoder.container(keyedBy: ExtraKeys.self)
        idempotencyKey = try container.decodeIfPresent(String.self, forKey: .idempotencyKey)
    }
}

/// The body of `POST /api/v1/calculations/batch`.
///
/// ```json
/// { "calculations": [ { "module": "arithmetic", "operation": "add", "parameters": { "left": 1, "right": 2 } } ] }
/// ```
struct BatchRequestBody: Decodable, Sendable, Equatable {
    /// Name of the only field of the body.
    static let calculationsField = "calculations"

    private enum CodingKeys: String, CodingKey {
        case calculations
    }

    /// The calculations to run, in the order the results are returned.
    let calculations: [BatchItemBody]

    /// Reads a batch.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: ``UnknownFieldsError`` for unknown fields and a decoding error for missing or mistyped ones.
    init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownFields(allowed: [CodingKeys.calculations.rawValue])

        let container = try decoder.container(keyedBy: CodingKeys.self)
        calculations = try container.decode([BatchItemBody].self, forKey: .calculations)
    }
}
