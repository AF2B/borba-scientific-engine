import BorbaScientificCore

/// Turns calculation events into metrics: how many calculations ended how, how long they took and why they failed.
///
/// Metrics are an observer of the calculation, not part of it, so they are recorded from events, outside the request, by
/// a subscriber that can fall behind without slowing anything down.
struct MetricsEventSubscriber: EventSubscriber {
    let name = "metrics"

    private let metrics: EngineMetrics

    /// Creates the subscriber.
    ///
    /// - Parameter metrics: Where the metrics are recorded.
    init(metrics: EngineMetrics) {
        self.metrics = metrics
    }

    /// Records the metrics of one event. A calculation counts once, when it ends: its `requested` event records nothing.
    ///
    /// - Parameter event: The event to record.
    func handle(_ event: CalculationEvent) async {
        switch event {
        case .requested:
            break
        case .completed(let completed):
            metrics.recordCalculation(completed.type, status: .succeeded, duration: completed.executionTime)
        case .failed(let failed):
            record(failed)
        }
    }

    private func record(_ failed: CalculationFailed) {
        if failed.code == .duplicateSuppressed {
            metrics.recordCalculation(failed.type, status: .suppressed, duration: failed.executionTime)
            return
        }

        metrics.recordCalculation(failed.type, status: .failed, duration: failed.executionTime)
        metrics.recordCalculationFailure(code: failed.code, classification: failed.classification)
    }
}
