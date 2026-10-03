/// How an error is treated by logging, metrics and error reporting.
///
/// Telling these four situations apart is what keeps the error tracker useful: a user dividing by zero is not an
/// incident, a database outage is.
public enum ErrorClassification: Sendable, Equatable {
    /// The request was well formed but cannot be computed, such as a division by zero. Logged at info level and
    /// never reported to the error tracker.
    case expectedDomain

    /// The application declined or aborted the work for an operational reason: a missing resource, a conflict,
    /// a time budget. Logged at info or warning level and never reported.
    case application

    /// A dependency such as the database failed. Reported, with rate limiting.
    case infrastructure

    /// A programming error or an unforeseen failure. Always reported.
    case unexpected

    /// Whether errors of this class are sent to the error tracker.
    public var isReportable: Bool {
        switch self {
        case .expectedDomain, .application:
            false
        case .infrastructure, .unexpected:
            true
        }
    }
}
