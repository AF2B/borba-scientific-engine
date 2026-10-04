import BorbaScientificCore
import Foundation
import Logging

/// Everything a ``SentryReporter`` needs, gathered so its initializer stays readable.
struct SentryReporterSettings: Sendable {
    /// The project reports go to and the identity of this service.
    let project: SentryProject

    /// The fraction of infrastructure failures that is sent, between 0 and 1. Unexpected failures are always sent.
    let sampleRate: Double

    /// How many failures may wait to be sent before the oldest are dropped.
    let queueSize: Int

    /// The longest a single delivery may take.
    let sendTimeout: Duration
}

/// Sends the failures that deserve a person's attention to Sentry, without ever making a request wait for it.
///
/// Reporting is a hand-off: ``report(_:)`` puts the failure in a bounded queue and returns. One task drains the queue and
/// decides, for each failure, whether to send it: only infrastructure and unexpected failures are reportable (a person
/// dividing by zero is not an incident), infrastructure failures are sampled, identical failures are folded together by
/// the throttle, and every delivery is bounded in time. The outcome of every failure — sent, sampled, throttled, dropped
/// or failed — is counted, so the reporter itself is observable, and a Sentry that is down costs a counter, not a request.
final class SentryReporter: ErrorReporter, Sendable {
    private static let failureLogInterval = 100

    private let queue: AsyncStream<ReportableFailure>.Continuation
    private let worker: Task<Void, Never>
    private let metrics: EngineMetrics

    /// Creates the reporter and starts its worker.
    ///
    /// - Parameters:
    ///   - settings: The project, the identity of the service and the limits.
    ///   - transport: Delivers envelopes.
    ///   - throttle: Folds identical failures together and bounds the total.
    ///   - clock: The time source of event timestamps and delivery time limits.
    ///   - identifiers: Creates event identifiers.
    ///   - metrics: Counts what happened to every failure.
    ///   - logger: Reports delivery problems.
    ///   - random: Supplies the number, between 0 and 1, sampling is decided with.
    init(
        settings: SentryReporterSettings,
        transport: any EnvelopeTransport,
        throttle: ReportThrottle,
        clock: any EngineClock,
        identifiers: any IdentifierGenerator,
        metrics: EngineMetrics,
        logger: Logger,
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.metrics = metrics

        let (stream, continuation) = AsyncStream.makeStream(
            of: ReportableFailure.self,
            bufferingPolicy: .bufferingNewest(settings.queueSize)
        )
        queue = continuation

        let pipeline = Pipeline(
            settings: settings,
            transport: transport,
            throttle: throttle,
            clock: clock,
            identifiers: identifiers,
            metrics: metrics,
            logger: logger,
            random: random
        )
        worker = Task {
            for await failure in stream {
                await pipeline.process(failure)
            }
        }
    }

    /// Queues a failure for reporting and returns at once.
    ///
    /// - Parameter failure: The failure.
    func report(_ failure: ReportableFailure) {
        if case .dropped = queue.yield(failure) {
            metrics.recordErrorReport(.dropped)
        }
    }

    /// Stops accepting failures and gives the queued ones a bounded time to be delivered.
    ///
    /// - Parameters:
    ///   - timeout: How long to wait.
    ///   - clock: Measures the wait.
    func shutdown(
        within timeout: Duration,
        clock: any EngineClock
    ) async {
        queue.finish()

        let worker = worker
        let drained = await Race.firstToFinish(
            {
                await worker.value
                return true
            },
            {
                try? await clock.sleep(for: timeout)
                return false
            }
        )
        if !drained {
            worker.cancel()
        }
    }

    /// What happens to one failure, on the worker's task.
    private struct Pipeline: Sendable {
        let settings: SentryReporterSettings
        let transport: any EnvelopeTransport
        let throttle: ReportThrottle
        let clock: any EngineClock
        let identifiers: any IdentifierGenerator
        let metrics: EngineMetrics
        let logger: Logger
        let random: @Sendable () -> Double

        func process(_ failure: ReportableFailure) async {
            guard failure.classification.isReportable else {
                return
            }
            if failure.classification == .infrastructure, random() >= settings.sampleRate {
                metrics.recordErrorReport(.sampled)
                return
            }

            let kind = "\(failure.code.rawValue)|\(failure.route)"
            switch await throttle.admit(kind: kind) {
            case .send(let repeats):
                await send(failure, repeats: repeats)
            case .suppress, .overLimit:
                metrics.recordErrorReport(.throttled)
            }
        }

        private func send(
            _ failure: ReportableFailure,
            repeats: Int
        ) async {
            let eventID = identifiers.next().uuidString.replacing("-", with: "").lowercased()
            guard
                let envelope = try? SentryEnvelope.make(
                    for: failure,
                    repeats: repeats,
                    eventID: eventID,
                    occurredAt: clock.currentDate(),
                    project: settings.project
                )
            else {
                metrics.recordErrorReport(.failed)
                return
            }

            let outcome = await deliver(envelope)
            metrics.recordErrorReport(outcome)
        }

        /// Delivers an envelope within the time limit. The delivery is raced against the clock instead of grouped with it,
        /// because a connection that ignores cancellation must not hold up the worker.
        private func deliver(_ envelope: SentryEnvelope) async -> ErrorReportOutcome {
            let settings = settings
            let transport = transport
            let clock = clock

            return await Race.firstToFinish(
                {
                    do {
                        try await transport.deliver(
                            envelope,
                            to: settings.project.dsn,
                            clientVersion: settings.project.context.clientVersion
                        )
                        return .sent
                    } catch {
                        return .failed
                    }
                },
                {
                    try? await clock.sleep(for: settings.sendTimeout)
                    return .failed
                }
            )
        }
    }
}
