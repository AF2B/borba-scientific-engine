import FluentKit
import FluentPostgresDriver
import Foundation
import InMemoryLogging
import IntegrationSupport
import Logging
import NIOCore
import NIOPosix
import SQLKit
import TestSupport
import Testing

@testable import BorbaScientificCore
@testable import BorbaScientificPersistence

@Suite("FluentCalculationRepository", .serialized)
struct FluentCalculationRepositoryTests {
    @Test("honours the repository contract on a real PostgreSQL")
    func contract() async throws {
        try await PostgresTestDatabase.withMigratedDatabase { database in
            try await RepositoryContract.verify {
                try await database.truncate()
                return database.repository
            }
        }
    }

    @Test("a failed key binding rolls back the record it was written with")
    func transactionIsAtomic() async throws {
        try await PostgresTestDatabase.withMigratedDatabase { database in
            let record = RecordFixtures.record(sequence: 1)
            let oversizedKey = IdempotencyKey(String(repeating: "k", count: IdempotencyKey.maximumLength + 1))
            let claim = IdempotencyClaim(key: oversizedKey, fingerprint: RequestFingerprint("fingerprint"))

            let error = await #expect(throws: RepositoryError.self) {
                try await database.repository.save(record, claiming: claim)
            }

            guard case .integrity? = error else {
                Issue.record("Expected an integrity violation, got \(String(describing: error))")
                return
            }
            let stored = try await database.repository.find(id: record.id)
            #expect(stored == nil, "the record must have been rolled back")
        }
    }

    @Test("reports a record the schema refuses as an integrity failure and stores nothing")
    func integrityFailure() async throws {
        try await PostgresTestDatabase.withMigratedDatabase { database in
            let malformed = CalculationRecord(
                id: RecordFixtures.id(1),
                type: CalculationType(module: ModuleName("Bad Module"), operation: OperationName("add")),
                parameters: [:],
                outcome: .succeeded(.number(1)),
                executionTime: .zero,
                createdAt: RecordFixtures.epoch,
                trace: RecordFixtures.trace
            )

            let error = await #expect(throws: RepositoryError.self) {
                try await database.repository.save(malformed, claiming: nil)
            }

            guard case .integrity? = error else {
                Issue.record("Expected an integrity violation, got \(String(describing: error))")
                return
            }
            #expect(error?.isTransient == false)
            let stored = try await database.repository.find(id: malformed.id)
            #expect(stored == nil)
        }
    }

    @Test("reports stored data that cannot be decoded as corrupted")
    func corruptedData() async throws {
        try await PostgresTestDatabase.withMigratedDatabase { database in
            try await database.execute(
                """
                INSERT INTO calculations
                    (id, module, operation, status, parameters, error_code, error_message, error_details,
                     execution_time_ns, request_id, correlation_id, created_at)
                VALUES
                    ('00000000-0000-7000-8000-000000000001', 'arithmetic', 'add', 'failed', '{}', 'X', 'x',
                     '"not a list of details"', 1, 'r', 'c', now())
                """
            )

            let error = await #expect(throws: RepositoryError.self) {
                try await database.repository.find(id: RecordFixtures.id(1))
            }

            guard case .corrupted? = error else {
                Issue.record("Expected corrupted data, got \(String(describing: error))")
                return
            }
            #expect(error?.code == .storageFailure)
        }
    }

    @Test("reports an unreachable server as a transient failure")
    func unreachableServer() async throws {
        let databases = try PostgresTestDatabase.makeDatabases(
            url: "postgres://nobody:nothing@127.0.0.1:1/none",
            connectionPoolTimeout: .seconds(2)
        )
        let repository = FluentCalculationRepository(databases: databases, logger: Logger(label: "unreachable"))

        let error = await #expect(throws: RepositoryError.self) {
            try await repository.find(id: RecordFixtures.id(1))
        }
        await databases.shutdownAsync()

        #expect(error?.isTransient == true)
        #expect(error?.code == .storageUnavailable)
    }

    @Test("reports a statement that outruns the server's statement timeout as a timeout")
    func statementTimeout() async throws {
        try await PostgresTestDatabase.withEmptyDatabase { database in
            let settings = PostgresSettings(
                url: database.url,
                applicationName: PostgresTestDatabase.applicationName,
                maximumConnectionsPerEventLoop: 1,
                connectionPoolTimeout: .seconds(5),
                statementTimeout: .milliseconds(200)
            )
            let databases = Databases(threadPool: NIOThreadPool.singleton, on: MultiThreadedEventLoopGroup.singleton)
            databases.use(try settings.makeConfiguration(), as: .psql)
            let sql = try #require(
                databases.database(.psql, logger: database.logger, on: databases.eventLoopGroup.any())
                    as? any SQLDatabase
            )

            let failure = await Result { try await sql.raw("SELECT pg_sleep(5)").run() }
            await databases.shutdownAsync()

            guard case .failure(let error) = failure else {
                Issue.record("Expected the statement to be cancelled")
                return
            }
            #expect(RepositoryErrorMapping.map(error) == .timeout)
        }
    }

    @Test("reports pool exhaustion as a timeout instead of waiting forever")
    func poolExhaustion() async throws {
        let singleLoop = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        try await PostgresTestDatabase.withMigratedDatabase(eventLoopGroup: singleLoop) { database in
            let databases = try PostgresTestDatabase.makeDatabases(
                url: database.url,
                group: singleLoop,
                maximumConnectionsPerEventLoop: 1,
                connectionPoolTimeout: .milliseconds(300)
            )
            let repository = FluentCalculationRepository(databases: databases, logger: database.logger)
            let sql = try #require(
                databases.database(.psql, logger: database.logger, on: singleLoop.any()) as? any SQLDatabase
            )

            // Occupy the only connection of the pool with a long-running statement.
            let occupier = Task { try? await sql.raw("SELECT pg_sleep(2)").run() }
            try await Task.sleep(for: .milliseconds(150))

            let error = await #expect(throws: RepositoryError.self) {
                try await repository.find(id: RecordFixtures.id(1))
            }
            await occupier.value
            await databases.shutdownAsync()

            #expect(error == .timeout)
        }
        try await singleLoop.shutdownGracefully()
    }

    @Test("tags SQL logs with the request and correlation identifiers of the calling task")
    func logsCarryTheTraceContext() async throws {
        try await PostgresTestDatabase.withMigratedDatabase { database in
            let handler = InMemoryLogHandler()
            let logger = Logger(label: "trace-test") { _ in
                var handler = handler
                handler.logLevel = .trace
                return handler
            }
            let repository = FluentCalculationRepository(
                databases: database.databases,
                databaseID: database.databaseID,
                logger: logger
            )
            let context = TraceContext(requestID: RequestID("req-42"), correlationID: CorrelationID("corr-42"))

            _ = try await TraceContext.withValue(context) {
                try await repository.find(id: RecordFixtures.id(1))
            }

            let tagged = handler.entries.filter {
                $0.metadata[TraceMetadataKey.requestID] == .string("req-42")
                    && $0.metadata[TraceMetadataKey.correlationID] == .string("corr-42")
            }
            #expect(!tagged.isEmpty, "database logs must carry the identifiers of the request that caused them")
        }
    }

    @Test("lists deep pages without losing or repeating records")
    func deepPagination() async throws {
        try await PostgresTestDatabase.withMigratedDatabase { database in
            let total = 250
            for sequence in 1...total {
                _ = try await database.repository.save(
                    RecordFixtures.record(sequence: sequence, offset: .milliseconds(sequence)),
                    claiming: nil
                )
            }

            var seen: [CalculationID] = []
            var cursor: PageCursor?
            repeat {
                let page = try await database.repository.list(
                    matching: HistoryFilter(),
                    page: PageRequest(limit: 40, cursor: cursor)
                )
                seen.append(contentsOf: page.items.map(\.id))
                cursor = page.nextCursor
            } while cursor != nil

            #expect(seen == (1...total).reversed().map(RecordFixtures.id))
        }
    }
}

@Suite("DatabaseHealth", .serialized)
struct DatabaseHealthTests {
    @Test("is healthy once every migration has been applied, and measures latency")
    func healthy() async throws {
        try await PostgresTestDatabase.withMigratedDatabase { database in
            let health = DatabaseHealth(
                databases: database.databases,
                databaseID: database.databaseID,
                expectedMigrations: PersistenceMigrations.names,
                clock: SystemClock(),
                logger: database.logger
            )

            let report = await health.check()

            #expect(report.status == .healthy)
            #expect(report.pendingMigrations.isEmpty)
            #expect(report.latency != nil)
        }
    }

    @Test("reports pending migrations on a database that has none applied")
    func pendingMigrations() async throws {
        try await PostgresTestDatabase.withEmptyDatabase { database in
            let health = DatabaseHealth(
                databases: database.databases,
                databaseID: database.databaseID,
                expectedMigrations: PersistenceMigrations.names,
                clock: SystemClock(),
                logger: database.logger
            )

            let report = await health.check()

            #expect(report.status == .migrationsPending)
            #expect(report.pendingMigrations == PersistenceMigrations.names)
        }
    }

    @Test("reports an unreachable database as unreachable")
    func unreachable() async throws {
        let databases = try PostgresTestDatabase.makeDatabases(
            url: "postgres://nobody:nothing@127.0.0.1:1/none",
            connectionPoolTimeout: .seconds(1)
        )
        let health = DatabaseHealth(
            databases: databases,
            databaseID: .psql,
            expectedMigrations: PersistenceMigrations.names,
            clock: SystemClock(),
            logger: Logger(label: "health")
        )

        let report = await health.check()
        await databases.shutdownAsync()

        #expect(report.status == .unreachable)
        #expect(report.latency == nil)
        #expect(report.diagnostic != nil)
    }
}
