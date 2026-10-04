/// The names of the metrics the service exposes and of their labels, spelled once.
///
/// Names follow the Prometheus conventions: `snake_case`, a unit suffix (`_seconds`, `_bytes`) and `_total` on counters.
/// Every label has a small, bounded set of values — module and operation names come from the registry, routes are
/// templates, failure codes come from the error catalog — so no label can grow without limit and exhaust the metrics
/// backend.
enum MetricName {
    // MARK: - HTTP

    static let httpRequestsTotal = "http_requests_total"
    static let httpRequestErrorsTotal = "http_request_errors_total"
    static let httpRequestDuration = "http_request_duration_seconds"
    static let httpRequestsInFlight = "http_requests_in_flight"

    // MARK: - Calculations

    static let calculationsTotal = "calculations_total"
    static let calculationDuration = "calculation_duration_seconds"
    static let calculationFailuresTotal = "calculation_failures_total"

    // MARK: - Storage and events

    static let databaseOperationDuration = "database_operation_duration_seconds"
    static let databaseFailuresTotal = "database_failures_total"
    static let repositoryRetriesTotal = "repository_retries_total"
    static let eventsDroppedTotal = "events_dropped_total"

    // MARK: - Error reporting

    static let errorReportsTotal = "error_reports_total"

    // MARK: - Process

    static let buildInfo = "build_info"
    static let processStartTime = "process_start_time_seconds"
    static let processResidentMemory = "process_resident_memory_bytes"
    static let processCPUSeconds = "process_cpu_seconds_total"
    static let processOpenFileDescriptors = "process_open_fds"
}

/// The names of the labels metrics carry.
enum MetricLabel {
    static let method = "method"
    static let route = "route"
    static let status = "status"
    static let module = "module"
    static let operation = "operation"
    static let code = "code"
    static let classification = "classification"
    static let kind = "kind"
    static let subscriber = "subscriber"
    static let outcome = "outcome"
    static let version = "version"
    static let commit = "commit"
    static let environment = "environment"
}
