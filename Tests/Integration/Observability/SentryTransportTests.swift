import BorbaScientificCore
import Foundation
import HTTPSupport
import Logging
import Metrics
import Prometheus
import TestSupport
import Testing
import Vapor
import VaporTesting

@testable import BorbaScientificEngine

/// The error reporter over real HTTP, against a stand-in Sentry on a local port.
@Suite("Sentry over HTTP", .timeLimit(.minutes(1)))
struct SentryTransportTests {
    private static let closedPort = 1

    /// The HTTP client keeps retrying a refused connection until this timeout, so the test shortens it.
    private static let connectTimeoutMilliseconds: Int64 = 300

    private static let context = SentryContext(
        release: "borba-scientific-engine@1.0.0",
        environment: "test",
        clientVersion: "1.0.0"
    )

    private static let failure = ReportableFailure(
        code: .storageUnavailable,
        classification: .infrastructure,
        status: 503,
        message: "The calculation history is temporarily unavailable.",
        diagnostic: "unavailable: connection refused",
        method: "POST",
        route: "/api/v1/calculations",
        trace: TraceContext(requestID: RequestID("req-9"), correlationID: CorrelationID("corr-9"))
    )

    private func envelope(for dsn: SentryDSN) throws -> SentryEnvelope {
        try SentryEnvelope.make(
            for: Self.failure,
            repeats: 0,
            eventID: String(repeating: "a", count: 32),
            occurredAt: Date(timeIntervalSince1970: 1_791_028_800),
            project: SentryProject(dsn: dsn, context: Self.context)
        )
    }

    @Test("posts the envelope to the project's endpoint with the authentication header")
    func delivers() async throws {
        let server = try await FakeSentryServer()
        let dsn = try #require(SentryDSN.parse(server.dsn))

        try await withApp { application in
            try await VaporEnvelopeTransport(client: application.client)
                .deliver(try envelope(for: dsn), to: dsn, clientVersion: "1.0.0")
        }
        let received = try #require(server.envelopes.first)
        await server.stop()

        #expect(received.path == "/api/1/envelope/")
        #expect(received.contentType == "application/x-sentry-envelope")
        #expect(
            received.authentication
                == "Sentry sentry_version=7, sentry_client=borba-scientific-engine/1.0.0, sentry_key=test-public-key"
        )
        #expect(received.body.contains("\"event_id\":\"\(String(repeating: "a", count: 32))\""))
        #expect(received.body.contains("STORAGE_UNAVAILABLE"))
    }

    @Test("reports a refusal, such as being over quota, with its status")
    func rejected() async throws {
        let server = try await FakeSentryServer(answering: .tooManyRequests)
        let dsn = try #require(SentryDSN.parse(server.dsn))

        let failure = try await withApp { application in
            await Self.failure(
                of: VaporEnvelopeTransport(client: application.client),
                delivering: try envelope(for: dsn),
                to: dsn
            )
        }
        await server.stop()

        #expect(failure == .rejected(status: 429))
    }

    @Test("reports a tracker that cannot be reached")
    func unreachable() async throws {
        let dsn = try #require(SentryDSN.parse("http://key@127.0.0.1:\(Self.closedPort)/1"))

        let failure = try await withApp { application in
            application.http.client.configuration.timeout.connect = .milliseconds(Self.connectTimeoutMilliseconds)
            return await Self.failure(
                of: VaporEnvelopeTransport(client: application.client),
                delivering: try envelope(for: dsn),
                to: dsn
            )
        }

        #expect(failure == .unreachable)
    }

    @Test("carries a reported failure from the reporter to the tracker, and counts it as sent")
    func reporterEndToEnd() async throws {
        let server = try await FakeSentryServer()
        let dsn = try #require(SentryDSN.parse(server.dsn))
        let registry = PrometheusCollectorRegistry()
        let clock = SystemClock()

        try await withApp { application in
            let reporter = SentryReporter(
                settings: SentryReporterSettings(
                    project: SentryProject(dsn: dsn, context: Self.context),
                    sampleRate: 1,
                    queueSize: 10,
                    sendTimeout: .seconds(5)
                ),
                transport: VaporEnvelopeTransport(client: application.client),
                throttle: ReportThrottle(window: .seconds(60), limitPerWindow: 10, clock: clock),
                clock: clock,
                identifiers: UUIDv7Generator(clock: clock),
                metrics: EngineMetrics(factory: PrometheusMetricsFactory(registry: registry)),
                logger: Logger(label: "test")
            )

            reporter.report(Self.failure)
            await reporter.shutdown(within: .seconds(5), clock: clock)
        }
        await server.stop()

        #expect(server.envelopes.count == 1)
        #expect(MetricsScrape(registry.emitToString()).value("error_reports_total", ["outcome": "sent"]) == 1)
    }

    private static func failure(
        of transport: VaporEnvelopeTransport,
        delivering envelope: SentryEnvelope,
        to dsn: SentryDSN
    ) async -> TransportFailure? {
        do {
            try await transport.deliver(envelope, to: dsn, clientVersion: "1.0.0")
            return nil
        } catch {
            return error
        }
    }
}
