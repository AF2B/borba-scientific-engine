/// A single problem found while reading the process environment.
public struct ConfigurationIssue: Sendable, Equatable {
    /// Name of the offending environment variable.
    public let variable: String

    /// Human-readable explanation. It never contains the offending value, because values may be secrets.
    public let reason: String

    /// Creates an issue for the given variable.
    ///
    /// - Parameters:
    ///   - variable: Name of the offending environment variable.
    ///   - reason: Explanation that must not echo the variable value.
    public init(
        variable: String,
        reason: String
    ) {
        self.variable = variable
        self.reason = reason
    }
}

/// Failure to build an ``AppConfiguration`` from the process environment.
///
/// Configuration problems are fatal at startup. All problems are collected and reported together so an
/// operator can fix the whole environment in a single iteration.
public enum ConfigurationError: Error, Sendable, Equatable {
    /// One or more variables are missing or malformed.
    case invalid([ConfigurationIssue])
}

extension ConfigurationError: CustomStringConvertible {
    /// One line per issue, safe to print because reasons never contain values.
    public var description: String {
        switch self {
        case .invalid(let issues):
            let lines = issues.map { "  - \($0.variable): \($0.reason)" }
            return (["Invalid configuration:"] + lines).joined(separator: "\n")
        }
    }
}
