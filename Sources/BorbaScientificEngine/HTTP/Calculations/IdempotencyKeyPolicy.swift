import BorbaScientificCore
import Vapor

/// Rules for the idempotency keys a client may send.
///
/// A key is any client-chosen label — typically a UUID — of visible ASCII characters. The rule is deliberately
/// permissive about content and strict about size and charset: keys are stored and indexed, so they must be bounded
/// and must never carry control characters.
enum IdempotencyKeyPolicy {
    /// What a client must do to send a valid key, for error messages and documentation.
    static let requirement = "must be 1 to \(IdempotencyKey.maximumLength) visible ASCII characters"

    /// Reported when the header is sent more than once.
    static let singleValueRequirement = "must be sent once"

    private static let visibleCharacters = UInt8(ascii: "!")...UInt8(ascii: "~")

    /// Validates a key.
    ///
    /// - Parameter raw: The key as the client wrote it.
    /// - Returns: The key, or `nil` when it is empty, too long or contains anything but visible ASCII characters.
    static func parse(_ raw: String) -> IdempotencyKey? {
        guard (1...IdempotencyKey.maximumLength).contains(raw.utf8.count),
            raw.utf8.allSatisfy(visibleCharacters.contains)
        else {
            return nil
        }
        return IdempotencyKey(raw)
    }
}

extension Request {
    /// Reads the `Idempotency-Key` header.
    ///
    /// - Returns: The key, or `nil` when the client did not send one.
    /// - Throws: ``APIFailure/invalidRequest(details:)`` when the header is repeated or the key is malformed.
    func idempotencyKey() throws(APIFailure) -> IdempotencyKey? {
        let values = headers[APIHeader.idempotencyKey]

        guard let first = values.first else {
            return nil
        }
        guard values.count == 1 else {
            throw .invalidRequest(
                details: [
                    ErrorDetail(
                        field: APIHeader.idempotencyKeyName,
                        reason: IdempotencyKeyPolicy.singleValueRequirement
                    )
                ]
            )
        }
        guard let key = IdempotencyKeyPolicy.parse(first) else {
            throw .invalidRequest(
                details: [ErrorDetail(field: APIHeader.idempotencyKeyName, reason: IdempotencyKeyPolicy.requirement)]
            )
        }
        return key
    }
}
