import BorbaScientificCore
public import Foundation
public import InMemoryLogging
import Logging
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
            try ApplicationFactory.configure(application, with: configuration)
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
    ///   - test: The test body.
    /// - Returns: Whatever the test returns.
    /// - Throws: Anything the test throws, or a failure to configure or shut down the application.
    @discardableResult
    public static func run<Result>(
        settings: [String: String] = [:],
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

        return try await withApp { application in
            application.logger = Logger(label: "http-test") { _ in
                var handler = logs
                handler.logLevel = .trace
                return handler
            }
            let services = LiveServices.assemble(
                repository: repository,
                events: events,
                clock: clock,
                calculation: configuration.calculation
            )
            try ApplicationFactory.configure(application, with: configuration, services: services)
        } _: { application in
            try await test(
                TestHarness(
                    client: TestClient(tester: try application.testing()),
                    repository: repository,
                    events: events,
                    clock: clock,
                    logs: logs,
                    application: application
                )
            )
        }
    }
}
