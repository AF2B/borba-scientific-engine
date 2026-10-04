import BorbaScientificCore
import Foundation
import Logging
import Metrics
import Prometheus
import Synchronization
import TestSupport
import Testing

@testable import BorbaScientificEngine

private let sampleDSN = SentryDSN.parse("https://abc123@o1.ingest.sentry.io/4501")!

private let sampleContext = SentryContext(
    release: "borba-scientific-engine@1.2.3",
    environment: "production",
    clientVersion: "1.2.3"
)

private let sampleProject = SentryProject(dsn: sampleDSN, context: sampleContext)

private func failure(
    _ code: ErrorCode = .storageUnavailable,
    classification: ErrorClassification = .infrastructure,
    status: UInt = 503,
    route: String = "/api/v1/calculations",
    diagnostic: String? = "unavailable: connection refused"
) -> ReportableFailure {
    ReportableFailure(
        code: code,
        classification: classification,
        status: status,
        message: "The calculation history is temporarily unavailable.",
        diagnostic: diagnostic,
        method: "POST",
        route: route,
        trace: TraceContext(requestID: RequestID("req-1"), correlationID: CorrelationID("corr-1"))
    )
}

@Suite("SentryDSN")
struct SentryDSNTests {
    @Test("takes a DSN apart and derives the envelope URL")
    func parsesTheParts() throws {
        let dsn = try #require(SentryDSN.parse("https://abc123@o1.ingest.sentry.io/4501"))

        #expect(dsn.scheme == "https")
        #expect(dsn.publicKey == "abc123")
        #expect(dsn.host == "o1.ingest.sentry.io")
        #expect(dsn.projectID == "4501")
        #expect(dsn.envelopeURL == "https://o1.ingest.sentry.io/api/4501/envelope/")
    }

    @Test("keeps a port and a path prefix, as a self-hosted Sentry may need")
    func selfHosted() throws {
        let dsn = try #require(SentryDSN.parse("http://key@sentry.internal:9000/errors/7"))

        #expect(dsn.host == "sentry.internal:9000")
        #expect(dsn.pathPrefix == "/errors")
        #expect(dsn.envelopeURL == "http://sentry.internal:9000/errors/api/7/envelope/")
    }

    @Test("ignores the secret of a legacy DSN")
    func legacySecret() throws {
        let dsn = try #require(SentryDSN.parse("https://public:secret@host.example/1"))

        #expect(dsn.publicKey == "public")
        #expect(!dsn.envelopeURL.contains("secret"))
        #expect(!dsn.redacted.contains("secret"))
    }

    @Test("shows a DSN without its key")
    func redacted() throws {
        let dsn = try #require(SentryDSN.parse("https://abc123@o1.ingest.sentry.io/4501"))

        #expect(dsn.redacted == "https://o1.ingest.sentry.io/4501")
    }

    @Test(
        "rejects what is not a DSN",
        arguments: [
            "",
            "not a url",
            "ftp://key@host/1",
            "https://host/1",
            "https://@host/1",
            "https://key@/1",
            "https://key@host",
            "https://key@host/",
        ]
    )
    func rejects(text: String) {
        #expect(SentryDSN.parse(text) == nil)
    }
}

@Suite("SentryEnvelope")
struct SentryEnvelopeTests {
    private static let occurredAt = Date(timeIntervalSince1970: 1_791_028_800.123)
    private static let eventID = "0123456789abcdef0123456789abcdef"

    private struct ParsedEnvelope {
        let lines: [String]
        let header: CalculationValue
        let item: CalculationValue
        let event: CalculationValue
    }

    private func make(
        _ failure: ReportableFailure,
        repeats: Int = 0
    ) throws -> ParsedEnvelope {
        let envelope = try SentryEnvelope.make(
            for: failure,
            repeats: repeats,
            eventID: Self.eventID,
            occurredAt: Self.occurredAt,
            project: sampleProject
        )
        let text = String(bytes: envelope.body, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func parse(_ line: String) throws -> CalculationValue {
            try JSONDecoder().decode(CalculationValue.self, from: Data(line.utf8))
        }
        return ParsedEnvelope(
            lines: lines,
            header: try parse(lines[0]),
            item: try parse(lines[1]),
            event: try parse(lines[2])
        )
    }

    @Test("writes the three lines of an envelope, and the item header states the payload length")
    func structure() throws {
        let parts = try make(failure())

        #expect(parts.lines.count == 4, "header, item header, event, and the trailing newline")
        #expect(parts.lines[3].isEmpty)
        #expect(parts.header.at("event_id") == "0123456789abcdef0123456789abcdef")
        #expect(parts.header.at("sent_at") == "2026-10-03T12:00:00.123Z")
        #expect(parts.header.at("dsn") == "https://o1.ingest.sentry.io/4501")
        #expect(parts.item.at("type") == "event")
        #expect(parts.item.at("length")?.number == Double(parts.lines[2].utf8.count))
    }

    @Test("describes the failure with a stable fingerprint and low-cardinality tags")
    func event() throws {
        let event = try make(failure()).event

        #expect(event.at("event_id") == "0123456789abcdef0123456789abcdef")
        #expect(event.at("platform") == "swift")
        #expect(event.at("level") == "error")
        #expect(event.at("release") == "borba-scientific-engine@1.2.3")
        #expect(event.at("environment") == "production")
        #expect(event.at("message") == "STORAGE_UNAVAILABLE: The calculation history is temporarily unavailable.")
        #expect(event.at("fingerprint") == ["STORAGE_UNAVAILABLE", "/api/v1/calculations"])
        #expect(event.at("tags", "error_code") == "STORAGE_UNAVAILABLE")
        #expect(event.at("tags", "classification") == "infrastructure")
        #expect(event.at("tags", "route") == "/api/v1/calculations")
        #expect(event.at("tags", "http_status") == "503")
        #expect(event.at("contexts", "request", "request_id") == "req-1")
        #expect(event.at("contexts", "request", "correlation_id") == "corr-1")
        #expect(event.at("sdk", "name") == "borba-scientific-engine.sentry")
    }

    @Test("carries nothing but the documented fields, so nothing personal can join them unnoticed")
    func onlyDocumentedFields() throws {
        let fields = try make(failure(), repeats: 3).event.fields ?? [:]

        #expect(
            Set(fields.keys)
                == [
                    "event_id", "timestamp", "platform", "level", "logger", "message", "release", "environment",
                    "fingerprint", "tags", "contexts", "extra", "sdk",
                ]
        )
        #expect(
            Set((fields["tags"]?.fields ?? [:]).keys) == [
                "error_code", "classification", "method", "route", "http_status",
            ]
        )
        #expect(Set((fields["extra"]?.fields ?? [:]).keys) == ["repeats_since_last_report", "diagnostic"])
    }

    @Test("mentions the failures folded into the report")
    func repeats() throws {
        #expect(try make(failure(), repeats: 41).event.at("extra", "repeats_since_last_report") == 41)
        #expect(try make(failure(), repeats: 0).event.at("extra", "repeats_since_last_report") == nil)
    }

    @Test("sends the diagnostic of an infrastructure failure, masked and capped")
    func diagnostic() throws {
        let long = "failed: postgres://engine:hunter2@db:5432/app " + String(repeating: "x", count: 1_000)

        let sent = try make(failure(diagnostic: long)).event.at("extra", "diagnostic")?.text ?? ""

        #expect(!sent.contains("hunter2"))
        #expect(sent.contains("[redacted]"))
        #expect(sent.count == SentryEnvelope.maximumDiagnosticLength)
    }

    @Test("never sends the diagnostic of an unexpected failure, which could contain anything")
    func unexpectedWithoutDiagnostic() throws {
        let event = try make(
            failure(.internalError, classification: .unexpected, status: 500, diagnostic: "secret value")
        ).event

        #expect(event.at("extra", "diagnostic") == nil)
        #expect(event.at("tags", "classification") == "unexpected")
    }
}

@Suite("ReportThrottle", .timeLimit(.minutes(1)))
struct ReportThrottleTests {
    private let window = Duration.seconds(60)

    @Test("sends the first failure of a kind and folds the identical ones that follow")
    func foldsRepeats() async {
        let throttle = ReportThrottle(window: window, limitPerWindow: 100, clock: ManualClock())

        #expect(await throttle.admit(kind: "A") == .send(repeats: 0))
        #expect(await throttle.admit(kind: "A") == .suppress)
        #expect(await throttle.admit(kind: "A") == .suppress)
    }

    @Test("mentions how many were folded when the window has passed")
    func reportsTheCount() async {
        let clock = ManualClock()
        let throttle = ReportThrottle(window: window, limitPerWindow: 100, clock: clock)

        _ = await throttle.admit(kind: "A")
        _ = await throttle.admit(kind: "A")
        _ = await throttle.admit(kind: "A")
        clock.advance(by: window)

        #expect(await throttle.admit(kind: "A") == .send(repeats: 2))
        #expect(await throttle.admit(kind: "A") == .suppress)
    }

    @Test("treats different kinds independently")
    func independentKinds() async {
        let throttle = ReportThrottle(window: window, limitPerWindow: 100, clock: ManualClock())

        #expect(await throttle.admit(kind: "A") == .send(repeats: 0))
        #expect(await throttle.admit(kind: "B") == .send(repeats: 0))
    }

    @Test("limits the total sent in a window, whatever their kinds, and starts over afterwards")
    func globalLimit() async {
        let clock = ManualClock()
        let throttle = ReportThrottle(window: window, limitPerWindow: 2, clock: clock)

        #expect(await throttle.admit(kind: "A") == .send(repeats: 0))
        #expect(await throttle.admit(kind: "B") == .send(repeats: 0))
        #expect(await throttle.admit(kind: "C") == .overLimit)

        clock.advance(by: window)
        #expect(await throttle.admit(kind: "C") == .send(repeats: 0))
    }
}

/// Records what it is asked to deliver, and can be made to fail or to stall.
private final class RecordingTransport: EnvelopeTransport {
    private let delivered = Mutex<[SentryEnvelope]>([])
    private let result: Mutex<TransportFailure?>
    private let gate: Gate?

    init(
        failing failure: TransportFailure? = nil,
        gate: Gate? = nil
    ) {
        result = Mutex(failure)
        self.gate = gate
    }

    var envelopes: [SentryEnvelope] {
        delivered.withLock { $0 }
    }

    func deliver(
        _ envelope: SentryEnvelope,
        to dsn: SentryDSN,
        clientVersion: String
    ) async throws(TransportFailure) {
        await gate?.wait()
        delivered.withLock { $0.append(envelope) }
        if let failure = result.withLock({ $0 }) {
            throw failure
        }
    }

    func waitUntilDelivered(_ count: Int) async {
        while envelopes.count < count {
            await Task.yield()
        }
    }
}

@Suite("SentryReporter", .timeLimit(.minutes(1)))
struct SentryReporterTests {
    private struct Fixture {
        let reporter: SentryReporter
        let transport: RecordingTransport
        let clock: ManualClock
        let registry: PrometheusCollectorRegistry

        func outcomes() -> MetricsScrape {
            MetricsScrape(registry.emitToString())
        }

        func waitUntilCounted(_ outcome: String, _ count: Double = 1) async {
            while (outcomes().value("error_reports_total", ["outcome": outcome]) ?? 0) < count {
                await Task.yield()
            }
        }
    }

    private func fixture(
        sampleRate: Double = 1,
        queueSize: Int = 100,
        transport: RecordingTransport = RecordingTransport(),
        limitPerWindow: Int = 100,
        random: @escaping @Sendable () -> Double = { 0 }
    ) -> Fixture {
        let clock = ManualClock()
        let registry = PrometheusCollectorRegistry()
        let reporter = SentryReporter(
            settings: SentryReporterSettings(
                project: sampleProject,
                sampleRate: sampleRate,
                queueSize: queueSize,
                sendTimeout: .seconds(5)
            ),
            transport: transport,
            throttle: ReportThrottle(window: .seconds(60), limitPerWindow: limitPerWindow, clock: clock),
            clock: clock,
            identifiers: SequentialIdentifiers(),
            metrics: EngineMetrics(factory: PrometheusMetricsFactory(registry: registry)),
            logger: Logger(label: "test"),
            random: random
        )
        return Fixture(reporter: reporter, transport: transport, clock: clock, registry: registry)
    }

    @Test("delivers a failure and counts it as sent")
    func delivers() async {
        let fixture = fixture()

        fixture.reporter.report(failure())
        await fixture.waitUntilCounted("sent")

        #expect(fixture.transport.envelopes.count == 1)
        #expect(fixture.transport.envelopes[0].eventID.count == 32)
    }

    @Test(
        "does not report failures that a tracker must not see",
        arguments: [ErrorClassification.expectedDomain, .application]
    )
    func ignoresExpectedFailures(classification: ErrorClassification) async {
        let fixture = fixture()

        fixture.reporter.report(failure(.divisionByZero, classification: classification, status: 422))
        fixture.reporter.report(failure())
        await fixture.waitUntilCounted("sent")

        #expect(fixture.transport.envelopes.count == 1, "only the infrastructure failure went out")
    }

    @Test("samples infrastructure failures but always sends unexpected ones")
    func sampling() async {
        let fixture = fixture(sampleRate: 0)

        fixture.reporter.report(failure())
        fixture.reporter.report(failure(.internalError, classification: .unexpected, status: 500, diagnostic: nil))
        await fixture.waitUntilCounted("sampled")
        await fixture.waitUntilCounted("sent")

        #expect(fixture.transport.envelopes.count == 1)
        #expect(fixture.outcomes().value("error_reports_total", ["outcome": "sampled"]) == 1)
    }

    @Test("folds identical failures into one report")
    func throttles() async {
        let fixture = fixture()

        for _ in 0..<5 {
            fixture.reporter.report(failure())
        }
        await fixture.waitUntilCounted("throttled", 4)

        #expect(fixture.transport.envelopes.count == 1)
    }

    @Test("counts a delivery the tracker refused and keeps going")
    func failedDelivery() async {
        let fixture = fixture(transport: RecordingTransport(failing: .rejected(status: 429)))

        fixture.reporter.report(failure(route: "/a"))
        fixture.reporter.report(failure(route: "/b"))
        await fixture.waitUntilCounted("failed", 2)

        #expect(fixture.transport.envelopes.count == 2)
    }

    @Test("gives up on a delivery that takes too long, instead of stalling every report behind it")
    func deliveryTimeout() async {
        let gate = Gate()
        let fixture = fixture(transport: RecordingTransport(gate: gate))

        fixture.reporter.report(failure(route: "/a"))
        await fixture.clock.waitUntilSleeping()
        fixture.clock.advance(by: .seconds(5))
        await fixture.waitUntilCounted("failed")

        await gate.open()
    }

    @Test("drops the oldest queued failures when the tracker is slower than the failures arrive")
    func overflow() async {
        let gate = Gate()
        let fixture = fixture(queueSize: 2, transport: RecordingTransport(gate: gate))

        fixture.reporter.report(failure(route: "/0"))
        await fixture.clock.waitUntilSleeping()
        for index in 1...5 {
            fixture.reporter.report(failure(route: "/\(index)"))
        }

        #expect(fixture.outcomes().value("error_reports_total", ["outcome": "dropped"]) == 3)
        await gate.open()
    }

    @Test("delivers what is queued on shutdown")
    func shutdownDrains() async {
        let fixture = fixture()

        fixture.reporter.report(failure(route: "/a"))
        fixture.reporter.report(failure(route: "/b"))
        await fixture.reporter.shutdown(within: .seconds(2), clock: fixture.clock)

        #expect(fixture.transport.envelopes.count == 2)
    }
}
