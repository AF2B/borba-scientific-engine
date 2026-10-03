import BorbaScientificCore
import Crypto
import Foundation

/// Reduces what a calculation request asks for to a digest, so a reused idempotency key can be recognised as a retry
/// (same digest) or as a mistake (different digest).
///
/// The digest covers the *meaning* of the request — module, operation and parameters — and not its spelling: key
/// order and whitespace do not matter, and `1` and `1.0` are the same number. It does not cover headers, so a retry
/// with a different request identifier is still a retry.
struct RequestFingerprinter: Sendable {
    /// Identifies the algorithm and the canonical form, so either can change without old digests being misread.
    static let prefix = "sha256:"

    private struct CanonicalRequest: Encodable {
        let module: String
        let operation: String
        let parameters: [String: CalculationValue]
    }

    /// Computes the digest of a request.
    ///
    /// - Parameter request: The request to digest.
    /// - Returns: The digest, such as `sha256:9f86d0…`.
    /// - Throws: An encoding error when a parameter cannot be written as JSON, which cannot happen for requests that
    ///   were read from JSON.
    func fingerprint(of request: CalculationRequest) throws -> RequestFingerprint {
        let canonical = CanonicalRequest(
            module: request.type.module.rawValue,
            operation: request.type.operation.rawValue,
            parameters: request.parameters
        )

        let bytes = try JSONCoding.makeEncoder().encode(canonical)
        return RequestFingerprint(Self.prefix + Hexadecimal.encode(SHA256.hash(data: bytes)))
    }
}

/// Lowercase hexadecimal text.
enum Hexadecimal {
    private static let digits = Array("0123456789abcdef")
    private static let bitsPerDigit = 4
    private static let digitMask: UInt8 = 0x0F

    /// Writes bytes as hexadecimal.
    ///
    /// - Parameter bytes: The bytes to write.
    /// - Returns: Two lowercase hexadecimal digits per byte.
    static func encode(_ bytes: some Sequence<UInt8>) -> String {
        var text = ""
        for byte in bytes {
            text.append(digits[Int(byte >> bitsPerDigit)])
            text.append(digits[Int(byte & digitMask)])
        }
        return text
    }
}
