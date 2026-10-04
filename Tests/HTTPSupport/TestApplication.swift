import BorbaScientificCore
public import Foundation
public import InMemoryLogging
import Logging
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

    /// A database URL that satisfies configuration validation. The in-memory stack never connects to it.
    private static let unusedDatabaseURL = "postgres://engine:unused@localhost:5432/engine"

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
        let variables = [EnvironmentVariable.databaseURL.rawValue: databaseURL].merging(settings) { _, override in
            override
        }
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
    ///   - test: The test body.
    /// - Returns: Whatever the test returns.
    /// - Throws: Anything the test throws, or a failure to configure or shut down the application.
    @discardableResult
    public static func run<Result>(
        settings: [String: String] = [:],
        transport: TestTransport = .inMemory,
        _ test: (TestHarness) async throws -> Result
    ) async throws -> Result {
        let repository = InMemoryCalculationRepository()
        let events = RecordingEventPublisher()
        let clock = ManualClock(date: startDate)
        let logs = InMemoryLogHandler()

        let variables = [EnvironmentVariable.databaseURL.rawValue: unusedDatabaseURL].merging(settings) { _, override in
            override
        }
        let configuration = try ConfigurationLoader.load(from: variables)

        let probe = ControllableProbe()
        let services = LiveServices.assemble(
            repository: repository,
            events: events,
            clock: clock,
            calculation: configuration.calculation,
            probes: [probe]
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
                    shutdownState: services.shutdown
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
