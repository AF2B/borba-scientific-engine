import Vapor

/// Names and fixed values of the HTTP headers the API reads and writes, spelled once.
enum APIHeader {
    /// Identifies one HTTP exchange. Adopted from the caller when well formed, generated otherwise.
    static let requestID = HTTPHeaders.Name("X-Request-ID")

    /// Groups the requests of one logical operation. Defaults to the request identifier.
    static let correlationID = HTTPHeaders.Name("X-Correlation-ID")

    /// Name of the header that makes a retry of a calculation safe.
    static let idempotencyKeyName = "Idempotency-Key"

    /// Header that makes a retry of a calculation safe.
    static let idempotencyKey = HTTPHeaders.Name(idempotencyKeyName)

    /// Marks a response that was served from an earlier identical request instead of being computed again.
    static let idempotentReplayed = HTTPHeaders.Name("Idempotent-Replayed")

    /// Value of ``idempotentReplayed`` on a replayed response.
    static let replayedValue = "true"

    /// Tells browsers not to send the address of the API as a referrer.
    static let referrerPolicy = HTTPHeaders.Name("Referrer-Policy")
}

/// Headers added to every response so a browser never interprets, caches or embeds API output.
enum SecurityHeaderValue {
    /// Stops browsers from guessing a content type different from the declared one.
    static let noSniff = "nosniff"

    /// The API serves JSON only: nothing may be loaded or framed.
    static let contentSecurityPolicy = "default-src 'none'; frame-ancestors 'none'"

    /// Responses are computed or read from live data, so intermediaries must not store them.
    static let noStore = "no-store"

    /// The API is never meant to be shown inside another page.
    static let frameDeny = "DENY"

    /// Callers do not leak the address of the API through the referrer.
    static let noReferrer = "no-referrer"
}
