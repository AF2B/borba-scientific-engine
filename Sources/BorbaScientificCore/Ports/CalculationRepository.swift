/// A client-chosen label that makes retrying a request safe.
///
/// Two requests with the same key are the same logical operation, so only the first one has an effect.
public struct IdempotencyKey: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Longest accepted key, in characters.
    public static let maximumLength = 255

    /// The key as supplied by the client.
    public let rawValue: String

    /// Wraps a key.
    ///
    /// - Parameter rawValue: The key text.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Decodes a key from a single JSON string.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: A decoding error when the value is not a string.
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    /// Encodes the key as a single JSON string.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: An encoding error raised by the encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The key text.
    public var description: String {
        rawValue
    }
}

/// A digest of the logical content of a request. A key reused with a different fingerprint is a client error, not
/// a retry.
public struct RequestFingerprint: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The digest, as a string.
    public let rawValue: String

    /// Wraps a digest.
    ///
    /// - Parameter rawValue: The digest text.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Decodes a digest from a single JSON string.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: A decoding error when the value is not a string.
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    /// Encodes the digest as a single JSON string.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: An encoding error raised by the encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The digest text.
    public var description: String {
        rawValue
    }
}

/// An idempotency key together with the fingerprint of the request that used it first.
public struct IdempotencyClaim: Sendable, Equatable {
    /// The client's key.
    public let key: IdempotencyKey

    /// The digest of the request content.
    public let fingerprint: RequestFingerprint

    /// Creates a claim.
    ///
    /// - Parameters:
    ///   - key: The client's key.
    ///   - fingerprint: The digest of the request content.
    public init(
        key: IdempotencyKey,
        fingerprint: RequestFingerprint
    ) {
        self.key = key
        self.fingerprint = fingerprint
    }
}

/// A stored record that was created under an idempotency key.
public struct IdempotentRecord: Sendable, Equatable {
    /// The record created by the first request that used the key.
    public let record: CalculationRecord

    /// The fingerprint of that first request.
    public let fingerprint: RequestFingerprint

    /// Creates an idempotent record.
    ///
    /// - Parameters:
    ///   - record: The record created by the first request that used the key.
    ///   - fingerprint: The fingerprint of that first request.
    public init(
        record: CalculationRecord,
        fingerprint: RequestFingerprint
    ) {
        self.record = record
        self.fingerprint = fingerprint
    }
}

/// What happened when a record was saved.
public enum SaveResult: Sendable, Equatable {
    /// The record was stored.
    case created

    /// Another request already stored a record under the same idempotency key, and nothing was written.
    case duplicate(IdempotentRecord)
}

/// The persistent calculation history.
///
/// This is the port the use cases depend on; the PostgreSQL adapter implements it, and an in-memory implementation
/// backs the unit tests. Every method reports infrastructure problems as ``RepositoryError``.
public protocol CalculationRepository: Sendable {
    /// Stores a record and, when a claim is given, binds the idempotency key to it in the same transaction.
    ///
    /// Either both are stored or neither is. If the key is already bound to another record nothing is written and
    /// that record is returned, which makes concurrent retries converge on one record.
    ///
    /// - Parameters:
    ///   - record: The record to store.
    ///   - claim: The idempotency key and request fingerprint, when the client supplied a key.
    /// - Returns: ``SaveResult/created`` or the record that already owns the key.
    /// - Throws: ``RepositoryError`` when the store fails.
    func save(
        _ record: CalculationRecord,
        claiming claim: IdempotencyClaim?
    ) async throws(RepositoryError) -> SaveResult

    /// Finds the record created under an idempotency key.
    ///
    /// - Parameter key: The client's key.
    /// - Returns: The record and the fingerprint of the request that created it, or `nil` when the key is unused.
    /// - Throws: ``RepositoryError`` when the store fails.
    func record(for key: IdempotencyKey) async throws(RepositoryError) -> IdempotentRecord?

    /// Finds a record by identifier.
    ///
    /// - Parameter id: The identifier of the record.
    /// - Returns: The record, or `nil` when it does not exist.
    /// - Throws: ``RepositoryError`` when the store fails.
    func find(id: CalculationID) async throws(RepositoryError) -> CalculationRecord?

    /// Lists records, newest first.
    ///
    /// - Parameters:
    ///   - filter: Narrows the records considered.
    ///   - page: Which page to read.
    /// - Returns: The page, with a cursor when more records follow.
    /// - Throws: ``RepositoryError`` when the store fails.
    func list(
        matching filter: HistoryFilter,
        page: PageRequest
    ) async throws(RepositoryError) -> Page<CalculationRecord>
}
