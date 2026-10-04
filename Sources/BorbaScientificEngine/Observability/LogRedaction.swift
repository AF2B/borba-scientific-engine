/// Keeps secrets out of logs even when someone logs one by mistake.
///
/// Two layers, because either alone has gaps. A **key** that names a secret (`password`, `token`, `authorization`, …)
/// has its value replaced whatever it contains. And in **any** text, the password inside a URL such as
/// `postgres://user:password@host/db` is masked, which catches a connection string that ends up in an error message.
enum LogRedaction {
    /// What replaces a secret.
    static let placeholder = "[redacted]"

    private static let atSign = UInt8(ascii: "@")
    private static let dash = UInt8(ascii: "-")
    private static let underscore = UInt8(ascii: "_")
    private static let caseOffset = UInt8(ascii: "a") - UInt8(ascii: "A")

    /// Keys whose values are business data rather than secrets, but must not be logged either. The database drivers log
    /// the parameters of every statement under `binds`, and those are the calculation parameters callers sent.
    private static let withheldKeys: Set<[UInt8]> = [Array("binds".utf8)]

    private static let sensitiveFragments: [[UInt8]] = [
        "password", "passwd", "secret", "token", "authorization", "cookie", "credential", "api_key", "apikey", "dsn",
        "database_url", "private_key",
    ].map { Array($0.utf8) }

    /// Whether the value stored under a metadata key must never be written.
    ///
    /// The key is compared as lowercase bytes with dashes read as underscores, without building a normalized copy: this runs
    /// for every metadata key of every log line.
    ///
    /// - Parameter key: The metadata key, in any case; dashes count as underscores.
    /// - Returns: `true` when the key names a secret or carries data that must not be logged.
    static func isSensitive(key: String) -> Bool {
        let normalized = key.utf8.map { byte -> UInt8 in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"):
                byte + caseOffset
            case dash:
                underscore
            default:
                byte
            }
        }

        return withheldKeys.contains(normalized) || sensitiveFragments.contains { contains(normalized, fragment: $0) }
    }

    /// Masks the password of every URL with credentials in a piece of text.
    ///
    /// - Parameter text: Any text that is about to be logged.
    /// - Returns: The text with `scheme://user:password@host` turned into `scheme://user:[redacted]@host`.
    static func mask(_ text: String) -> String {
        // A URL with credentials contains an `@`, and almost no log text does: a byte scan settles the common case without
        // running a regular expression, which costs far more than everything else a log call does.
        guard text.utf8.contains(atSign) else {
            return text
        }

        return text.replacing(#/(://[^/\s:@]+:)[^@\s]+(@)/#) { match in
            "\(match.output.1)\(placeholder)\(match.output.2)"
        }
    }

    private static func contains(
        _ bytes: [UInt8],
        fragment: [UInt8]
    ) -> Bool {
        guard bytes.count >= fragment.count else {
            return false
        }
        return (0...(bytes.count - fragment.count)).contains { start in
            fragment.indices.allSatisfy { bytes[start + $0] == fragment[$0] }
        }
    }
}
