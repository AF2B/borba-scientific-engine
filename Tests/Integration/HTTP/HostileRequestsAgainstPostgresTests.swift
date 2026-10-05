import HTTPSupport
import IntegrationSupport
import Testing
import Vapor

@testable import BorbaScientificEngine

/// The hostile requests of the contract tests, sent to the production wiring over a real PostgreSQL. A test double accepts
/// what a database refuses: a NUL in text, a number too large for a column, an instant outside its calendar. Each of those
/// must be turned away at the edge, with a `4xx`, before the database is asked.
@Suite("Hostile requests against PostgreSQL", .serialized, .timeLimit(.minutes(5)))
struct HostileRequestsAgainstPostgresTests {
    @Test("every hostile request is refused inside the error envelope, and the service and its database stay up")
    func hostileRequestsNeverCauseAServerError() async throws {
        try await PostgresTestDatabase.withMigratedDatabase { database in
            try await TestApplication.runLive(databaseURL: database.url) { harness in
                let problems = try await HostileRequests.problems(in: harness.client)

                let health = try await harness.client.get("/health")
                let ready = try await harness.client.get("/ready")

                #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
                #expect(health.status == .ok && ready.status == .ok)
            }
        }
    }
}
