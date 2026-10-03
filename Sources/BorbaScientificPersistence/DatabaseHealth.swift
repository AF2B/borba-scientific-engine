public import BorbaScientificCore
public import FluentKit
import FluentSQL
public import Logging
import NIOCore

/// What a database health check found.
public struct DatabaseHealthReport: Sendable, Equatable {
    /// The overall verdict.
    public enum Status: String, Sendable, Equatable {
        /// The database answers and every expected migration has been applied.
        case healthy

        /// The database does not answer in time or at all.
        case unreachable

        /// The database answers but is missing migrations, so the schema is not what the code expects.
        case migrationsPending
    }

    /// The overall verdict.
    public let status: Status

    /// How long the connectivity probe took, when the database answered.
    public let latency: Duration?

    /// Migrations the code expects that the database has not applied.
    public let pendingMigrations: [String]

    /// Technical detail for logs; never for API consumers.
    public let diagnostic: String?
}

/// Checks that PostgreSQL is reachable and that its schema is the one the code expects.
///
/// Readiness needs both: a reachable database with a missing table serves errors just as surely as an unreachable one.
public struct DatabaseHealth: Sendable {
    private static let probeTable = "_fluent_migrations"

    private let databases: Databases
    private let databaseID: DatabaseID
    private let expectedMigrations: [String]
    private let clock: any EngineClock
    private let logger: Logger

    /// Creates a health check.
    ///
    /// - Parameters:
    ///   - databases: The registry that owns the connection pool.
    ///   - databaseID: Which database to check.
    ///   - expectedMigrations: Names of the migrations the code requires, usually ``PersistenceMigrations/names``.
    ///   - clock: Measures how long the probe takes.
    ///   - logger: Receives diagnostics.
    public init(
        databases: Databases,
        databaseID: DatabaseID,
        expectedMigrations: [String],
        clock: any EngineClock,
        logger: Logger
    ) {
        self.databases = databases
        self.databaseID = databaseID
        self.expectedMigrations = expectedMigrations
        self.clock = clock
        self.logger = logger
    }

    /// Probes the database. This never throws: a failing database is the answer, not an error.
    ///
    /// - Returns: The findings.
    public func check() async -> DatabaseHealthReport {
        guard
            let database = databases.database(databaseID, logger: logger, on: databases.eventLoopGroup.any()),
            let sql = database as? any SQLDatabase
        else {
            return DatabaseHealthReport(
                status: .unreachable,
                latency: nil,
                pendingMigrations: expectedMigrations,
                diagnostic: "the database connections have been shut down"
            )
        }

        let startedAt = clock.uptime()
        do {
            try await sql.raw("SELECT 1").run()
            let latency = clock.uptime() - startedAt
            let applied = try await appliedMigrations(on: sql)
            let pending = expectedMigrations.filter { !applied.contains($0) }

            return DatabaseHealthReport(
                status: pending.isEmpty ? .healthy : .migrationsPending,
                latency: latency,
                pendingMigrations: pending,
                diagnostic: nil
            )
        } catch {
            return DatabaseHealthReport(
                status: .unreachable,
                latency: nil,
                pendingMigrations: expectedMigrations,
                diagnostic: RepositoryErrorMapping.map(error).diagnostic
            )
        }
    }

    private func appliedMigrations(on sql: any SQLDatabase) async throws -> Set<String> {
        struct MigrationRow: Decodable {
            let name: String
        }

        do {
            let rows = try await sql.raw("SELECT name FROM \(ident: Self.probeTable)").all(decoding: MigrationRow.self)
            return Set(rows.map(\.name))
        } catch {
            // The migrations table does not exist before the first migration; that means "nothing applied".
            if case .unexpected(let reason) = RepositoryErrorMapping.map(error), reason.contains(Self.undefinedTable) {
                return []
            }
            throw error
        }
    }

    private static let undefinedTable = "42P01"
}
