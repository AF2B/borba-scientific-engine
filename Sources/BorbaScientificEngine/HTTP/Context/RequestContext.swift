import BorbaScientificCore
import Vapor

/// Rules for the identifiers a caller may supply to tie its requests to ours.
///
/// A supplied identifier is adopted only when it is short and made of harmless characters; anything else is replaced.
/// That keeps hostile input out of logs and out of the database, where the identifier is stored and indexed.
enum RequestIdentifierPolicy {
    /// Longest accepted identifier, in characters.
    static let maximumLength = 128

    private static let lowercaseLetters = UInt8(ascii: "a")...UInt8(ascii: "z")
    private static let uppercaseLetters = UInt8(ascii: "A")...UInt8(ascii: "Z")
    private static let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
    private static let allowedPunctuation: Set<UInt8> = Set("-_.:".utf8)

    /// Whether a supplied identifier may be adopted.
    ///
    /// - Parameter candidate: The identifier taken from a header.
    /// - Returns: `true` for 1 to ``maximumLength`` ASCII letters, digits and `-_.:`.
    static func isWellFormed(_ candidate: String) -> Bool {
        guard (1...maximumLength).contains(candidate.utf8.count) else {
            return false
        }
        return candidate.utf8.allSatisfy { byte in
            lowercaseLetters.contains(byte)
                || uppercaseLetters.contains(byte)
                || digits.contains(byte)
                || allowedPunctuation.contains(byte)
        }
    }
}

private struct TraceStorageKey: StorageKey {
    typealias Value = TraceContext
}

extension Request {
    /// The identifiers of this exchange, as decided by ``RequestContextMiddleware``.
    ///
    /// Falls back to Vapor's own request identifier when the middleware did not run, so the property is always usable.
    var trace: TraceContext {
        storage[TraceStorageKey.self] ?? TraceContext(requestID: RequestID(id), correlationID: CorrelationID(id))
    }

    /// Records the identifiers of this exchange for the handlers and middleware that follow.
    ///
    /// - Parameter trace: The identifiers to bind to the request.
    func bind(_ trace: TraceContext) {
        storage[TraceStorageKey.self] = trace
    }
}
