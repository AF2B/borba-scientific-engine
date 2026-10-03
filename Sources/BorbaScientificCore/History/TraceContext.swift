/// Identifies one HTTP exchange. Generated for every request, or adopted from a trusted header.
public struct RequestID: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The identifier as it appears on the wire and in logs.
    public let rawValue: String

    /// Wraps an identifier.
    ///
    /// - Parameter rawValue: The identifier text.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Decodes an identifier from a single JSON string.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: A decoding error when the value is not a string.
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    /// Encodes the identifier as a single JSON string.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: An encoding error raised by the encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The identifier text.
    public var description: String {
        rawValue
    }
}

/// Groups every request that belongs to one logical operation, possibly spanning several services. It equals the
/// request identifier when the caller does not supply one.
public struct CorrelationID: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The identifier as it appears on the wire and in logs.
    public let rawValue: String

    /// Wraps an identifier.
    ///
    /// - Parameter rawValue: The identifier text.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Decodes an identifier from a single JSON string.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: A decoding error when the value is not a string.
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    /// Encodes the identifier as a single JSON string.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: An encoding error raised by the encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The identifier text.
    public var description: String {
        rawValue
    }
}

/// The identifiers that tie everything done on behalf of one request together.
///
/// The context travels two ways. Explicitly, it is stored with every record and carried by every event, so the
/// database and the event stream can be searched by request. Implicitly, it is bound as a task-local value for the
/// duration of the request, so structured logs emitted anywhere below the HTTP layer — in use cases, repositories and
/// database code — carry the same identifiers without any function having to pass them along.
public struct TraceContext: Sendable, Equatable, Hashable, Codable {
    /// The request being served.
    public let requestID: RequestID

    /// The logical operation the request belongs to.
    public let correlationID: CorrelationID

    /// Creates a context.
    ///
    /// - Parameters:
    ///   - requestID: The request being served.
    ///   - correlationID: The logical operation the request belongs to.
    public init(
        requestID: RequestID,
        correlationID: CorrelationID
    ) {
        self.requestID = requestID
        self.correlationID = correlationID
    }

    /// The context of the task that is currently running, when one was bound with
    /// ``withValue(_:operation:)``. Child tasks created with `async let` or a task group inherit it.
    @TaskLocal public static var current: TraceContext?

    /// Runs an operation with a context bound to the current task and every task it creates.
    ///
    /// - Parameters:
    ///   - context: The context to bind.
    ///   - operation: The work to run.
    /// - Returns: Whatever the operation returns.
    public static func withValue<Value>(
        _ context: TraceContext,
        operation: nonisolated(nonsending) () async throws -> Value
    ) async rethrows -> Value {
        try await $current.withValue(context, operation: operation)
    }
}
