import Foundation
import HTTPSupport
import Testing

@testable import BorbaScientificEngine

/// The health probe against a server that is really listening, which is how a container's health check meets it.
@Suite("Health probe over HTTP", .timeLimit(.minutes(1)))
struct HealthProbeTests {
    private static let executable = "borba-scientific-engine"
    private static let loopback = "127.0.0.1"
    private static let databaseURL = "postgres://engine:unused@localhost:5432/engine"
    private static let closedPort = 1

    /// The HTTP client keeps retrying a refused connection until its timeout, so the probe is given a short one.
    private static let unreachableTimeout = Duration.milliseconds(300)

    private static func environment(port: Int) -> [String: String] {
        [
            EnvironmentVariable.databaseURL.rawValue: databaseURL,
            EnvironmentVariable.httpHost.rawValue: loopback,
            EnvironmentVariable.httpPort.rawValue: String(port),
        ]
    }

    @Test("accepts an instance that answers the liveness request")
    func healthy() async throws {
        try await TestApplication.runServing { _, base in
            try await HealthProbe.check(url: base + "/health")
        }
    }

    @Test("rejects an instance that answers with an error status")
    func unexpectedStatus() async throws {
        try await TestApplication.runServing { _, base in
            await #expect(throws: HealthProbeFailure.unexpectedStatus(404)) {
                try await HealthProbe.check(url: base + "/missing")
            }
        }
    }

    @Test("rejects an address nothing listens on, within the time it was given")
    func unreachable() async throws {
        let failure = await #expect(throws: HealthProbeFailure.self) {
            try await HealthProbe.check(
                url: "http://\(Self.loopback):\(Self.closedPort)/health",
                timeout: Self.unreachableTimeout
            )
        }

        guard case .unreachable = failure else {
            Issue.record("expected the probe to report that nothing answered, got \(String(describing: failure))")
            return
        }
    }

    @Test("the healthcheck command exits with success when the instance is healthy")
    func commandSucceeds() async throws {
        let status = try await TestApplication.runServing { _, base in
            let port = try #require(URL(string: base)?.port)

            return await Entrypoint.run(
                environment: Self.environment(port: port),
                arguments: [Self.executable, HealthProbe.commandName]
            )
        }

        #expect(status == EXIT_SUCCESS)
    }

    @Test("the healthcheck command exits with failure when the configuration is invalid")
    func commandFailsOnInvalidConfiguration() async {
        let status = await Entrypoint.run(
            environment: [:],
            arguments: [Self.executable, HealthProbe.commandName]
        )

        #expect(status == EXIT_FAILURE)
    }
}
