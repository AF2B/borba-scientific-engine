public import BorbaScientificCore
public import Foundation
public import InMemoryLogging
import Logging
import Metrics
import Prometheus
import Synchronization
public import TestSupport
public import Vapor
import VaporTesting

@testable import BorbaScientificEngine

/// Everything a test needs to drive the HTTP stack and to look behind it.
public struct TestHarness: Sendable {
    /// Sends requests through the full HTTP stack.
    public let client: TestClient

    /// The in-memory history the stack writes to, which tests can inspect and make fail.
    public let repository: InMemoryCalculationRepository

    /// Records the events the stack publishes.
    public let events: RecordingEventPublisher

    /// The clock of the engine, which tests advance by hand.
    public let clock: ManualClock

    /// Collects everything the stack logs.
    public let logs: InMemoryLogHandler

    /// The application under test.
    public let application: Application

    let databaseProbe: ControllableProbe
    let shutdownState: ShutdownState
    let errorReporter: RecordingErrorReporter

    /// The failures that were offered to the error tracker, in order.
    public var reportedErrors: [ReportedError] {
        errorReporter.failures
    }

    /// Makes the readiness probe of the database report up or down.
    ///
    /// Readiness reuses an answer for a moment, so a test that changes it must also advance ``clock`` past that
    /// moment before the change shows.
    ///
    /// - Parameter ready: Whether the database should look reachable.
    public func setDatabaseReady(_ ready: Bool) {
        databaseProbe.set(ready ? .up : .down)
    }

    /// Behaves as if a termination signal had just arrived: readiness reports "not ready" at once.
    public func beginShutdown() {
        shutdownState.begin()
    }
}

/// A failure offered to the error tracker, as a test sees it.
public struct ReportedError: Sendable, Equatable {
    /// The stable error code.
    public let code: String

    /// How the failure is classified: `infrastructure` or `unexpected`.
    public let classification: String

    /// The HTTP status of the response.
    public let status: UInt

    /// The HTTP method of the request.
    public let method: String

    /// The route template of the request.
    public let route: String

    /// The request identifier.
    public let requestID: String

    /// Whether technical detail went with the failure.
    public let hasDiagnostic: Bool

    /// Describes a failure, so a test can say what it expects to have been reported.
    ///
    /// - Parameters:
    ///   - code: The stable error code.
    ///   - classification: `infrastructure` or `unexpected`.
    ///   - status: The HTTP status of the response.
    ///   - method: The HTTP method of the request.
    ///   - route: The route template of the request.
    ///   - requestID: The request identifier.
    ///   - hasDiagnostic: Whether technical detail went with the failure.
    public init(
        code: String,
        classification: String,
        status: UInt,
        method: String,
        route: String,
        requestID: String,
        hasDiagnostic: Bool
    ) {
        self.code = code
        self.classification = classification
        self.status = status
        self.method = method
        self.route = route
        self.requestID = requestID
        self.hasDiagnostic = hasDiagnostic
    }
}

/// Remembers every failure it is offered, instead of sending it anywhere.
final class RecordingErrorReporter: ErrorReporter, Sendable {
    private let recorded = Mutex<[ReportedError]>([])

    var failures: [ReportedError] {
        recorded.withLock { $0 }
    }

    func report(_ failure: ReportableFailure) {
        let entry = ReportedError(
            code: failure.code.rawValue,
            classification: failure.classification == .infrastructure ? "infrastructure" : "unexpected",
            status: failure.status,
            method: failure.method,
            route: failure.route,
            requestID: failure.trace.requestID.rawValue,
            hasDiagnostic: failure.diagnostic != nil
        )
        recorded.withLock { $0.append(entry) }
    }

    func shutdown(
        within timeout: Duration,
        clock: any EngineClock
    ) async {}
}

/// A readiness probe whose answer a test controls.
final class ControllableProbe: ReadinessProbe, Sendable {
    let name = "database"

    private let state = Mutex(ReadinessCheckResult.State.up)

    func set(_ newState: ReadinessCheckResult.State) {
        state.withLock { $0 = newState }
    }

    func check() async -> ReadinessCheckResult {
        let current = state.withLock { $0 }
        return ReadinessCheckResult(name: name, state: current, detail: current == .down ? "unreachable" : nil)
    }
}

/// Everything a test needs to drive the production wiring against a real database.
public struct LiveHarness: Sendable {
    /// Sends requests through the full HTTP stack.
    public let client: TestClient

    /// Collects everything the stack logs.
    public let logs: InMemoryLogHandler

    /// The application under test.
    public let application: Application
}

/// How a test reaches the application.
public enum TestTransport: Sendable {
    /// Hands requests straight to the application. Fast, and enough for everything except the limits the HTTP server
    /// itself enforces, such as the body size.
    case inMemory

    /// Starts the server on a free local port and sends real HTTP requests to it.
    case network
}

/// Builds the real HTTP stack — middleware, routing, handlers, error mapping — over in-memory adapters.
///
/// Only the adapters are replaced: the history lives in memory and time stands still until a test moves it. Everything
/// else is the production wiring, so what these tests observe is what a client of the running service observes.
public enum TestApplication {
    /// The instant the manual clock starts at: 2026-10-03T12:00:00Z.
    public static let startDate = Date(timeIntervalSince1970: 1_791_028_800)

    /// How long a serving test's server waits for connections to close when it stops.
    private static let servingShutdownTimeoutMilliseconds: Int64 = 100

    /// Test applications are small and many run at once against one PostgreSQL, so each opens as few connections per event
    /// loop as it can, instead of exhausting the server's connection limit.
    private static let connectionsPerEventLoop = 1

    /// A database URL that satisfies configuration validation. The in-memory stack never connects to it.
    private static let unusedDatabaseURL = "postgres://engine:unused@localhost:5432/engine"

    /// Runs a test against an application that is really listening on a free local port, over in-memory adapters, for
    /// callers that need to talk to it with a real HTTP client — benchmarks, mostly.
    ///
    /// Unlike ``TestTransport/network``, which starts and stops the server around every request, the server here stays up
    /// for the whole test, so connections are reused as they would be in production.
    ///
    /// - Parameters:
    ///   - engineClock: The clock the engine measures with; defaults to the manual clock.
    ///   - test: The test body, given the application and the base URL of the server, such as `http://127.0.0.1:49152`.
    /// - Returns: Whatever the test returns.
    /// - Throws: Anything the test throws, or a failure to configure, start or shut down the application.
    @discardableResult
    public static func runServing<Result>(
        engineClock: (any EngineClock)? = nil,
        _ test: (Application, String) async throws -> Result
    ) async throws -> Result {
        try await run(engineClock: engineClock) { harness in
            let application = harness.application
            application.http.server.configuration.shutdownTimeout = .milliseconds(servingShutdownTimeoutMilliseconds)
            try await application.server.start(
                address: .hostname(TestTransport.loopback, port: TestTransport.anyFreePort)
            )
            let port = application.http.server.shared.localAddress?.port ?? TestTransport.anyFreePort

            do {
                let result = try await test(application, "http://\(TestTransport.loopback):\(port)")
                await application.server.shutdown()
                return result
            } catch {
                await application.server.shutdown()
                throw error
            }
        }
    }

    /// Runs a test against the production wiring — real database, real clock — and shuts the application down
    /// afterwards.
    ///
    /// - Parameters:
    ///   - databaseURL: The PostgreSQL database the application uses.
    ///   - settings: Environment variables that override the test configuration, such as `BATCH_MAX_SIZE`.
    ///   - test: The test body.
    /// - Returns: Whatever the test returns.
    /// - Throws: Anything the test throws, or a failure to configure or shut down the application.
    @discardableResult
    public static func runLive<Result>(
        databaseURL: String,
        settings: [String: String] = [:],
        _ test: (LiveHarness) async throws -> Result
    ) async throws -> Result {
        let logs = InMemoryLogHandler()
        let defaults = [
            EnvironmentVariable.databaseURL.rawValue: databaseURL,
            EnvironmentVariable.databaseMaximumConnectionsPerEventLoop.rawValue: String(connectionsPerEventLoop),
        ]
        let variables = defaults.merging(settings) { _, override in override }
        let configuration = try ConfigurationLoader.load(from: variables)

        return try await withApp { application in
            application.logger = Logger(label: "http-live-test") { _ in
                var handler = logs
                handler.logLevel = .trace
                return handler
            }
            let services = try LiveServices.assemble(for: application, with: configuration)
            try ApplicationFactory.configure(application, with: configuration, services: services)
        } _: { application in
            try await test(
                LiveHarness(client: TestClient(tester: try application.testing()), logs: logs, application: application)
            )
        }
    }

    /// Runs a test against a freshly configured application and shuts it down afterwards.
    ///
    /// - Parameters:
    ///   - settings: Environment variables that override the test configuration, such as `BATCH_MAX_SIZE`.
    ///   - transport: How requests reach the application.
    ///   - engineClock: The clock the engine measures with, instead of the manual one. Benchmarks pass the system clock, so
    ///     that what they measure is what production does.
    ///   - test: The test body.
    /// - Returns: Whatever the test returns.
    /// - Throws: Anything the test throws, or a failure to configure or shut down the application.
    @discardableResult
    public static func run<Result>(
        settings: [String: String] = [:],
        transport: TestTransport = .inMemory,
        engineClock: (any EngineClock)? = nil,
        _ test: (TestHarness) async throws -> Result
    ) async throws -> Result {
        let repository = InMemoryCalculationRepository()
        let events = RecordingEventPublisher()
        let clock = ManualClock(date: startDate)
        let logs = InMemoryLogHandler()
        let metricsRegistry = PrometheusCollectorRegistry()
        let metrics = EngineMetrics(factory: PrometheusMetricsFactory(registry: metricsRegistry))

        let variables = [EnvironmentVariable.databaseURL.rawValue: unusedDatabaseURL].merging(settings) { _, override in
            override
        }
        let configuration = try ConfigurationLoader.load(from: variables)

        let probe = ControllableProbe()
        let errorReporter = RecordingErrorReporter()
        let services = LiveServices.assemble(
            ServiceInputs(
                repository: repository,
                events: FanOutEventPublisher(
                    publishers: [events, InlineSubscriber(MetricsEventSubscriber(metrics: metrics))]
                ),
                clock: engineClock ?? clock,
                calculation: configuration.calculation,
                metrics: metrics,
                metricsRegistry: metricsRegistry,
                probes: [probe],
                errorReporter: errorReporter
            )
        )

        return try await withApp { application in
            application.logger = Logger(label: "http-test") { _ in
                var handler = logs
                handler.logLevel = .trace
                return handler
            }
            try ApplicationFactory.configure(application, with: configuration, services: services)
        } _: { application in
            try await test(
                TestHarness(
                    client: TestClient(tester: try application.testing(method: transport.method)),
                    repository: repository,
                    events: events,
                    clock: clock,
                    logs: logs,
                    application: application,
                    databaseProbe: probe,
                    shutdownState: services.shutdown,
                    errorReporter: errorReporter
                )
            )
        }
    }
}

extension TestTransport {
    fileprivate static let loopback = "127.0.0.1"
    fileprivate static let anyFreePort = 0

    fileprivate var method: Application.Method {
        switch self {
        case .inMemory:
            .inMemory
        case .network:
            .running(hostname: Self.loopback, port: Self.anyFreePort)
        }
    }
}

/// Hands every event to several publishers, one after the other.
struct FanOutEventPublisher: EventPublisher {
    let publishers: [any EventPublisher]

    func publish(_ event: CalculationEvent) async {
        for publisher in publishers {
            await publisher.publish(event)
        }
    }
}

/// Lets a subscriber see events inline, instead of through a dispatcher's queue, so a test can check its effect as soon as
/// the request returns.
struct InlineSubscriber: EventPublisher {
    let subscriber: any EventSubscriber

    init(_ subscriber: any EventSubscriber) {
        self.subscriber = subscriber
    }

    func publish(_ event: CalculationEvent) async {
        await subscriber.handle(event)
    }
}
