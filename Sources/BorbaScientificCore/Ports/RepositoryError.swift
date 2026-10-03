extension ErrorCode {
    /// The calculation history cannot be reached right now.
    public static let storageUnavailable = ErrorCode("STORAGE_UNAVAILABLE")

    /// The calculation history failed in a way that is not expected to go away by itself.
    public static let storageFailure = ErrorCode("STORAGE_FAILURE")
}

/// Why the calculation history could not be read or written.
///
/// Repository failures are infrastructure failures: the caller did nothing wrong. Reasons are for logs and error
/// reports only; they may name internals and must never be shown to an API consumer.
public enum RepositoryError: Error, Sendable, Equatable {
    /// The store cannot be reached: connection refused, pool exhausted, server shutting down.
    case unavailable(reason: String)

    /// The store did not answer within the time allowed.
    case timeout

    /// The store rejected a write that the application believed valid, such as a violated constraint.
    case integrity(reason: String)

    /// Stored data cannot be turned back into a record.
    case corrupted(reason: String)

    /// Any other failure.
    case unexpected(reason: String)

    /// Whether trying the same call again may succeed. Retrying is only safe for reads and for writes that are
    /// idempotent.
    public var isTransient: Bool {
        switch self {
        case .unavailable, .timeout:
            true
        case .integrity, .corrupted, .unexpected:
            false
        }
    }

    /// Stable identifier of the failure.
    public var code: ErrorCode {
        isTransient ? .storageUnavailable : .storageFailure
    }

    /// Explanation that is safe to show to the caller.
    public var message: String {
        isTransient
            ? "The calculation history is temporarily unavailable."
            : "The calculation history could not complete the operation."
    }

    /// Repository failures are always infrastructure failures.
    public var classification: ErrorClassification {
        .infrastructure
    }

    /// Technical detail for logs and error reports; never for API consumers.
    public var diagnostic: String {
        switch self {
        case .unavailable(let reason):
            "unavailable: \(reason)"
        case .timeout:
            "timeout"
        case .integrity(let reason):
            "integrity violation: \(reason)"
        case .corrupted(let reason):
            "corrupted data: \(reason)"
        case .unexpected(let reason):
            "unexpected: \(reason)"
        }
    }
}
