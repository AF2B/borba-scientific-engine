import Foundation

/// The address a Sentry project accepts error reports at, taken apart from its DSN.
///
/// A DSN looks like `https://<public key>@<host>[:<port>][/<path>]/<project id>`. The public key identifies the
/// project and may be shipped in clients; it only allows sending reports, never reading them.
struct SentryDSN: Sendable, Equatable {
    private static let acceptedSchemes: Set<String> = ["http", "https"]
    private static let envelopePathSuffix = "envelope/"
    private static let apiPathComponent = "api"

    /// `http` or `https`.
    let scheme: String

    /// Identifies the project to Sentry.
    let publicKey: String

    /// Host name, with the port when it is not the scheme's default.
    let host: String

    /// Anything between the host and the project identifier, for a Sentry served under a sub-path.
    let pathPrefix: String

    /// Identifies the project.
    let projectID: String

    /// Takes a DSN apart.
    ///
    /// - Parameter text: The DSN as configured.
    /// - Returns: The parts, or `nil` when the text is not a DSN: wrong scheme, no key, no host or no project.
    static func parse(_ text: String) -> SentryDSN? {
        guard
            let components = URLComponents(string: text),
            let scheme = components.scheme?.lowercased(),
            acceptedSchemes.contains(scheme),
            let publicKey = components.user, !publicKey.isEmpty,
            let hostName = components.host, !hostName.isEmpty
        else {
            return nil
        }

        let segments = components.path.split(separator: "/").map(String.init)
        guard let projectID = segments.last, !projectID.isEmpty else {
            return nil
        }

        let host = components.port.map { "\(hostName):\($0)" } ?? hostName
        let prefix = segments.dropLast().map { "/" + $0 }.joined()
        return SentryDSN(scheme: scheme, publicKey: publicKey, host: host, pathPrefix: prefix, projectID: projectID)
    }

    /// The URL envelopes are posted to.
    var envelopeURL: String {
        "\(scheme)://\(host)\(pathPrefix)/\(Self.apiPathComponent)/\(projectID)/\(Self.envelopePathSuffix)"
    }

    /// The DSN without the key, which is safe to put in an envelope header or a log line.
    var redacted: String {
        "\(scheme)://\(host)\(pathPrefix)/\(projectID)"
    }
}
