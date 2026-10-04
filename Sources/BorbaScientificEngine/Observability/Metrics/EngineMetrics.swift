import BorbaScientificCore
import CoreMetrics

/// How a recorded calculation ended, as a metric label.
enum CalculationMetricStatus: String, Sendable {
    /// The calculation produced a result.
    case succeeded

    /// The calculation ran and failed, or could not be recorded.
    case failed

    /// A concurrent retry lost the race for its idempotency key and was answered from the winner's record.
    case suppressed
}

/// What happened to an error that was offered to the error tracker, as a metric label.
enum ErrorReportOutcome: String, Sendable {
    /// The report was delivered.
    case sent

    /// The report was left out by sampling.
    case sampled

    /// The report repeated one sent recently and was folded into it.
    case throttled

    /// The queue of pending reports was full, so the oldest was dropped.
    case dropped

    /// The tracker did not accept the report.
    case failed
}

/// The one place that knows which metrics the service records and with which labels.
///
/// Components record through this type and never create counters or timers themselves, so the metric names, units and
/// labels stay consistent, and tests can substitute any `MetricsFactory` — they use a Prometheus registry of their own
/// — instead of depending on process-wide state.
struct EngineMetrics: Sendable {
    private let factory: any MetricsFactory

    /// Creates the recorder.
    ///
    /// - Parameter factory: Where the metrics are created.
    init(factory: any MetricsFactory) {
        self.factory = factory
    }

    // MARK: - HTTP

    /// Records a served request.
    ///
    /// - Parameters:
    ///   - method: The HTTP method.
    ///   - route: The route template, or a fixed word for requests that matched no route.
    ///   - status: The status code of the response.
    ///   - duration: How long the request took.
    func recordRequest(
        method: String,
        route: String,
        status: UInt,
        duration: Duration
    ) {
        let dimensions = [
            (MetricLabel.method, method),
            (MetricLabel.route, route),
            (MetricLabel.status, String(status)),
        ]

        Counter(label: MetricName.httpRequestsTotal, dimensions: dimensions, factory: factory).increment()
        if status >= HTTPStatusRange.serverErrorLowerBound {
            Counter(label: MetricName.httpRequestErrorsTotal, dimensions: dimensions, factory: factory).increment()
        }
        Timer(
            label: MetricName.httpRequestDuration,
            dimensions: dimensions,
            preferredDisplayUnit: .seconds,
            factory: factory
        ).recordNanoseconds(duration.totalNanoseconds)
    }

    /// Records how many requests are being served right now.
    ///
    /// - Parameter count: The number of requests in flight.
    func setRequestsInFlight(_ count: Int) {
        Meter(label: MetricName.httpRequestsInFlight, factory: factory).set(Double(count))
    }

    // MARK: - Calculations

    /// Records the end of a calculation.
    ///
    /// - Parameters:
    ///   - type: Which calculation ran.
    ///   - status: How it ended.
    ///   - duration: Time spent computing.
    func recordCalculation(
        _ type: CalculationType,
        status: CalculationMetricStatus,
        duration: Duration
    ) {
        Counter(
            label: MetricName.calculationsTotal,
            dimensions: [
                (MetricLabel.module, type.module.rawValue),
                (MetricLabel.operation, type.operation.rawValue),
                (MetricLabel.status, status.rawValue),
            ],
            factory: factory
        ).increment()

        Timer(
            label: MetricName.calculationDuration,
            dimensions: [
                (MetricLabel.module, type.module.rawValue),
                (MetricLabel.operation, type.operation.rawValue),
            ],
            preferredDisplayUnit: .seconds,
            factory: factory
        ).recordNanoseconds(duration.totalNanoseconds)
    }

    /// Records why a calculation failed.
    ///
    /// - Parameters:
    ///   - code: The stable error code.
    ///   - classification: How the failure is treated.
    func recordCalculationFailure(
        code: ErrorCode,
        classification: ErrorClassification
    ) {
        Counter(
            label: MetricName.calculationFailuresTotal,
            dimensions: [
                (MetricLabel.code, code.rawValue),
                (MetricLabel.classification, Self.name(of: classification)),
            ],
            factory: factory
        ).increment()
    }

    // MARK: - Storage and events

    /// Records a call to the calculation history.
    ///
    /// - Parameters:
    ///   - operation: Which call: `save`, `record`, `find` or `list`.
    ///   - duration: How long it took.
    ///   - failure: Why it failed, when it did.
    func recordDatabaseOperation(
        _ operation: String,
        duration: Duration,
        failure: RepositoryError?
    ) {
        Timer(
            label: MetricName.databaseOperationDuration,
            dimensions: [(MetricLabel.operation, operation)],
            preferredDisplayUnit: .seconds,
            factory: factory
        ).recordNanoseconds(duration.totalNanoseconds)

        guard let failure else {
            return
        }
        Counter(
            label: MetricName.databaseFailuresTotal,
            dimensions: [(MetricLabel.operation, operation), (MetricLabel.kind, Self.name(of: failure))],
            factory: factory
        ).increment()
    }

    /// Records that a repository call was repeated after a failure.
    ///
    /// - Parameter operation: Which call.
    func recordRetry(operation: String) {
        Counter(
            label: MetricName.repositoryRetriesTotal,
            dimensions: [(MetricLabel.operation, operation)],
            factory: factory
        ).increment()
    }

    /// Records that an event subscriber missed an event because it could not keep up.
    ///
    /// - Parameter subscriber: The subscriber's name.
    func recordDroppedEvent(subscriber: String) {
        Counter(
            label: MetricName.eventsDroppedTotal,
            dimensions: [(MetricLabel.subscriber, subscriber)],
            factory: factory
        ).increment()
    }

    // MARK: - Error reporting and process

    /// Records what happened to an error offered to the error tracker.
    ///
    /// - Parameter outcome: What happened.
    func recordErrorReport(_ outcome: ErrorReportOutcome) {
        Counter(
            label: MetricName.errorReportsTotal,
            dimensions: [(MetricLabel.outcome, outcome.rawValue)],
            factory: factory
        ).increment()
    }

    /// Publishes which build is running, as the constant `1` with the build as labels, so dashboards can group by
    /// version and alerts can notice a rollout.
    ///
    /// - Parameters:
    ///   - version: The semantic version.
    ///   - commit: The git commit.
    ///   - environment: The environment the process runs in.
    func setBuildInfo(
        version: String,
        commit: String,
        environment: String
    ) {
        Meter(
            label: MetricName.buildInfo,
            dimensions: [
                (MetricLabel.version, version),
                (MetricLabel.commit, commit),
                (MetricLabel.environment, environment),
            ],
            factory: factory
        ).set(1)
    }

    /// Publishes a process-level gauge.
    ///
    /// - Parameters:
    ///   - name: The metric name.
    ///   - value: The current value.
    func setProcessGauge(
        _ name: String,
        _ value: Double
    ) {
        Meter(label: name, factory: factory).set(value)
    }

    /// Adds CPU time to the process counter.
    ///
    /// - Parameter seconds: How much CPU time the process used since the last call.
    func addProcessCPUSeconds(_ seconds: Double) {
        FloatingPointCounter(label: MetricName.processCPUSeconds, factory: factory).increment(by: seconds)
    }

    private static func name(of classification: ErrorClassification) -> String {
        switch classification {
        case .expectedDomain:
            "expected_domain"
        case .application:
            "application"
        case .infrastructure:
            "infrastructure"
        case .unexpected:
            "unexpected"
        }
    }

    private static func name(of failure: RepositoryError) -> String {
        switch failure {
        case .unavailable:
            "unavailable"
        case .timeout:
            "timeout"
        case .integrity:
            "integrity"
        case .corrupted:
            "corrupted"
        case .unexpected:
            "unexpected"
        }
    }
}

/// Where the HTTP status classes begin.
enum HTTPStatusRange {
    /// 500, the first server error.
    static let serverErrorLowerBound: UInt = 500
}

extension Duration {
    private static let nanosecondsPerSecond: Int64 = 1_000_000_000
    private static let attosecondsPerNanosecond: Int64 = 1_000_000_000

    /// The duration in whole nanoseconds, saturating instead of overflowing.
    var totalNanoseconds: Int64 {
        let (whole, overflow) = components.seconds.multipliedReportingOverflow(by: Self.nanosecondsPerSecond)
        return overflow ? Int64.max : whole + components.attoseconds / Self.attosecondsPerNanosecond
    }
}
