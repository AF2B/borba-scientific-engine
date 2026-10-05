import HTTPSupport
import Testing
import Vapor

@testable import BorbaScientificEngine

/// What a client that means harm can send, against the in-memory adapters. The same requests run against PostgreSQL in the
/// integration tests, since what a database refuses is not what a test double refuses.
@Suite("Hostile requests", .timeLimit(.minutes(2)))
struct HostileRequestTests {
    @Test("every hostile request is refused inside the error envelope, and the service stays up")
    func hostileRequestsNeverCauseAServerError() async throws {
        try await TestApplication.run { harness in
            let problems = try await HostileRequests.problems(in: harness.client)

            let health = try await harness.client.get("/health")
            let ready = try await harness.client.get("/ready")
            let metrics = try await harness.client.get("/metrics")

            #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
            #expect(health.status == .ok && ready.status == .ok && metrics.status == .ok)
        }
    }

    @Test("never echoes a hostile request identifier back to the caller")
    func replacesHostileTraceIdentifiers() async throws {
        let hostile = "abc\" ,\"level\":\"critical"

        try await TestApplication.run { harness in
            let response = try await harness.client.get("/health", headers: ["X-Request-ID": hostile])

            let adopted = try #require(response.header("X-Request-ID"))
            #expect(adopted != hostile)
            #expect(adopted.allSatisfy { $0.isLetter || $0.isNumber || "._:-".contains($0) })
        }
    }
}
