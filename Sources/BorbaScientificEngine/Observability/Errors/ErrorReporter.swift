import BorbaScientificCore

/// What the error tracker is told about a failure. Deliberately small: a stable code, how the failure is classified, where
/// it happened and which request it belongs to. Parameters, bodies, headers, query strings and client addresses are never
/// part of it, because they can carry personal data and the request identifier leads from a report to the logs, which are
/// under the operator's control.
struct ReportableFailure: Sendable, Equatable {
    /// The stable error code.
    let code: ErrorCode

    /// How the failure is treated; only infrastructure and unexpected failures are ever reported.
    let classification: ErrorClassification

    /// The HTTP status of the response.
    let status: UInt

    /// The message that was shown to the caller, which never contains internal detail.
    let message: String

    /// Technical detail. Only infrastructure failures carry it, because their reasons are driver-level and contain no
    /// caller data; it is masked and truncated before it leaves the process.
    let diagnostic: String?

    /// The HTTP method of the request, or a fixed word for one that matched no route.
    let method: String

    /// The route template of the request, such as `/api/v1/calculations/:id`.
    let route: String

    /// The identifiers of the request.
    let trace: TraceContext
}

/// Tells an error tracker about failures that deserve a person's attention.
protocol ErrorReporter: Sendable {
    /// Offers a failure to the tracker. It returns at once and never fails: the tracker being slow, full or down must
    /// not affect the request that produced the failure.
    ///
    /// - Parameter failure: The failure.
    func report(_ failure: ReportableFailure)

    /// Stops accepting failures and gives the ones already queued a bounded time to be delivered.
    ///
    /// - Parameters:
    ///   - timeout: How long to wait.
    ///   - clock: Measures the wait.
    func shutdown(
        within timeout: Duration,
        clock: any EngineClock
    ) async
}

/// The reporter used when no error tracker is configured.
struct DisabledErrorReporter: ErrorReporter {
    /// Ignores the failure.
    ///
    /// - Parameter failure: The failure.
    func report(_ failure: ReportableFailure) {}

    /// Returns at once: nothing is queued.
    ///
    /// - Parameters:
    ///   - timeout: Ignored.
    ///   - clock: Ignored.
    func shutdown(
        within timeout: Duration,
        clock: any EngineClock
    ) async {}
}
