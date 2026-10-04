/// Keeps secrets out of logs even when someone logs one by mistake.
///
/// Two layers, because either alone has gaps. A **key** that names a secret (`password`, `token`, `authorization`, …)
/// has its value replaced whatever it contains. And in **any** text, the password inside a URL such as
/// `postgres://user:password@host/db` is masked, which catches a connection string that ends up in an error message.
enum LogRedaction {
    /// What replaces a secret.
    static let placeholder = "[redacted]"

    /// Keys whose values are business data rather than secrets, but must not be logged either. The database drivers log
    /// the parameters of every statement under `binds`, and those are the calculation parameters callers sent.
    private static let withheldKeys: Set<String> = ["binds"]

    private static let sensitiveFragments = [
        "password", "passwd", "secret", "token", "authorization", "cookie", "credential", "api_key", "apikey", "dsn",
        "database_url", "private_key",
    ]

    /// Whether the value stored under a metadata key must never be written.
    ///
    /// - Parameter key: The metadata key, in any case; dashes count as underscores.
    /// - Returns: `true` when the key names a secret or carries data that must not be logged.
    static func isSensitive(key: String) -> Bool {
        let normalized = key.lowercased().replacing("-", with: "_")

        return withheldKeys.contains(normalized) || sensitiveFragments.contains { normalized.contains($0) }
    }

    /// Masks the password of every URL with credentials in a piece of text.
    ///
    /// - Parameter text: Any text that is about to be logged.
    /// - Returns: The text with `scheme://user:password@host` turned into `scheme://user:[redacted]@host`.
    static func mask(_ text: String) -> String {
        text.replacing(#/(://[^/\s:@]+:)[^@\s]+(@)/#) { match in
            "\(match.output.1)\(placeholder)\(match.output.2)"
        }
    }
}
