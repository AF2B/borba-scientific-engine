import BorbaScientificCore
import Foundation

/// Writes a page position as the opaque `cursor` string clients pass back to read the next page.
///
/// Clients must treat the string as a token: the format is versioned precisely so it can change. It is not signed,
/// because a forged cursor can only start a listing from a position the caller could reach anyway. It is still
/// validated, because it is input: a token that names an instant no timestamp can hold is refused.
enum PageCursorCodec {
    private static let version = "v1"
    private static let separator = "."
    private static let fieldCount = 3
    private static let wholeMicrosecondsPerSecond: Int64 = 1_000_000

    /// The instants a cursor may name are the years 0001 through 9999 of RFC 3339, the range of every timestamp the API
    /// reads or writes. Anything else was not produced by ``encode(_:)``, and turning it back into microseconds for the
    /// database would overflow.
    private static let earliestSecond: Int64 = -62_135_596_800  // 0001-01-01T00:00:00Z
    private static let latestSecond: Int64 = 253_402_300_799  // 9999-12-31T23:59:59Z
    private static let earliestMicroseconds = earliestSecond * wholeMicrosecondsPerSecond
    private static let latestMicroseconds = latestSecond * wholeMicrosecondsPerSecond + (wholeMicrosecondsPerSecond - 1)
    private static let validMicroseconds = earliestMicroseconds...latestMicroseconds

    /// Encodes a position.
    ///
    /// The instant is written as whole microseconds, the resolution of the database, so the position survives the
    /// round trip exactly.
    ///
    /// - Parameter cursor: The position of the last entry of a page.
    /// - Returns: The token, safe to put in a URL.
    static func encode(_ cursor: PageCursor) -> String {
        let microseconds = cursor.createdAt.wholeMicrosecondsSinceEpoch
        let payload = [version, String(microseconds), cursor.id.description].joined(separator: separator)

        return Base64URL.encode(Data(payload.utf8))
    }

    /// Decodes a token.
    ///
    /// - Parameter token: The `cursor` value a client sent.
    /// - Returns: The position, or `nil` when the token was not produced by ``encode(_:)``, which includes a token that
    ///   names an instant outside the years 0001 through 9999.
    static func decode(_ token: String) -> PageCursor? {
        guard
            let data = Base64URL.decode(token),
            let payload = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let fields = payload.components(separatedBy: separator)
        guard
            fields.count == fieldCount,
            fields[0] == version,
            let microseconds = Int64(fields[1]),
            validMicroseconds.contains(microseconds),
            let identifier = UUID(uuidString: fields[2])
        else {
            return nil
        }

        return PageCursor(
            createdAt: Date(wholeMicrosecondsSinceEpoch: microseconds),
            id: CalculationID(identifier)
        )
    }
}

/// Base64 with the URL-safe alphabet and no padding (RFC 4648 §5), so a token can sit in a query string unescaped.
enum Base64URL {
    private static let standardPlus: Character = "+"
    private static let standardSlash: Character = "/"
    private static let urlMinus: Character = "-"
    private static let urlUnderscore: Character = "_"
    private static let padding: Character = "="
    private static let quantumLength = 4

    /// Encodes bytes.
    ///
    /// - Parameter data: The bytes to encode.
    /// - Returns: The text, without padding.
    static func encode(_ data: Data) -> String {
        String(
            data.base64EncodedString().compactMap { character -> Character? in
                switch character {
                case standardPlus:
                    urlMinus
                case standardSlash:
                    urlUnderscore
                case padding:
                    nil
                default:
                    character
                }
            }
        )
    }

    /// Decodes text produced by ``encode(_:)``.
    ///
    /// - Parameter text: The URL-safe text, with or without padding.
    /// - Returns: The bytes, or `nil` when the text is not valid Base64.
    static func decode(_ text: String) -> Data? {
        var standard = String(
            text.map { character -> Character in
                switch character {
                case urlMinus:
                    standardPlus
                case urlUnderscore:
                    standardSlash
                default:
                    character
                }
            }
        )

        let remainder = standard.count % quantumLength
        if remainder != 0 {
            standard += String(repeating: padding, count: quantumLength - remainder)
        }
        return Data(base64Encoded: standard)
    }
}
