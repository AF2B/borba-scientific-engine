import BorbaScientificCore
public import BorbaScientificPersistence
public import FluentKit
import FluentPostgresDriver
import Foundation
public import Logging
import NIOCore
import NIOPosix
public import SQLKit

/// A freshly created PostgreSQL database that exists only for the duration of one test.
public struct TestDatabase: Sendable {
    /// The registry that owns the connection pool of the temporary database.
    public let databases: Databases

    /// The identifier the temporary database is registered under.
    public let databaseID: DatabaseID

    /// The connection URL of the temporary database.
    public let url: String

    /// The logger used for every call.
    public let logger: Logger

    /// The repository over the temporary database.
    public var repository: FluentCalculationRepository {
        FluentCalculationRepository(databases: databases, databaseID: databaseID, logger: logger)
    }

    /// Runs a raw SQL statement against the temporary database, for tests that need to bypass the repository.
    ///
    /// - Parameter statement: The statement to run.
    /// - Throws: Whatever the driver throws.
    public func execute(_ statement: SQLQueryString) async throws {
        try await sql().raw(statement).run()
    }

    /// The SQL interface of the temporary database.
    ///
    /// - Returns: A database that speaks SQL.
    /// - Throws: ``TestDatabaseError/notSQL`` when the configured database does not speak SQL.
    public func sql() throws -> any SQLDatabase {
        guard
            let database = databases.database(databaseID, logger: logger, on: databases.eventLoopGroup.any()),
            let sql = database as? any SQLDatabase
        else {
            throw TestDatabaseError.notSQL
        }
        return sql
    }

    /// Empties every table, so several checks can share one database.
    public func truncate() async throws {
        try await execute("TRUNCATE calculations, idempotency_keys CASCADE")
    }
}

/// Why a test database could not be provided.
public enum TestDatabaseError: Error, CustomStringConvertible {
    /// `TEST_DATABASE_URL` is not set.
    case environmentNotConfigured

    /// The URL in `TEST_DATABASE_URL` cannot be used.
    case invalidURL

    /// The database does not speak SQL.
    case notSQL

    /// A readable explanation including how to fix the problem.
    public var description: String {
        switch self {
        case .environmentNotConfigured:
            "TEST_DATABASE_URL is not set. "
                + "Start PostgreSQL with `make db-up` and run the tests with `make test-integration`."
        case .invalidURL:
            "TEST_DATABASE_URL is not a valid PostgreSQL URL."
        case .notSQL:
            "The test database does not speak SQL."
        }
    }
}

/// Creates, migrates and drops temporary databases on a real PostgreSQL server.
///
/// Each test gets its own database, so tests are isolated and can run in parallel without cleaning up after each
/// other. The server comes from `TEST_DATABASE_URL`, which only needs a role allowed to create databases.
public enum PostgresTestDatabase {
    /// The environment variable that points at the PostgreSQL server used by the integration tests.
    public static let environmentVariable = "TEST_DATABASE_URL"

    /// Announced to the server by every test connection, so test sessions are recognisable in `pg_stat_activity`.
    public static let applicationName = "borba-scientific-engine-tests"

    private static let maintenanceDatabase = "postgres"
    private static let databaseNamePrefix = "bse_test_"

    /// Runs a body against a fresh database with every migration applied.
    ///
    /// - Parameters:
    ///   - eventLoopGroup: The event loops the connection pool uses; defaults to the shared singleton.
    ///   - body: The test.
    /// - Returns: Whatever the body returns.
    /// - Throws: Whatever the body throws, or ``TestDatabaseError`` when the environment is not set up.
    public static func withMigratedDatabase<Result: Sendable>(
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        _ body: @Sendable (TestDatabase) async throws -> Result
    ) async throws -> Result {
        try await withDatabase(eventLoopGroup: eventLoopGroup, migrated: true, body)
    }

    /// Runs a body against a fresh, empty database.
    ///
    /// - Parameters:
    ///   - eventLoopGroup: The event loops the connection pool uses; defaults to the shared singleton.
    ///   - body: The test.
    /// - Returns: Whatever the body returns.
    /// - Throws: Whatever the body throws, or ``TestDatabaseError`` when the environment is not set up.
    public static func withEmptyDatabase<Result: Sendable>(
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        _ body: @Sendable (TestDatabase) async throws -> Result
    ) async throws -> Result {
        try await withDatabase(eventLoopGroup: eventLoopGroup, migrated: false, body)
    }

    /// The server URL from the environment.
    ///
    /// - Returns: The URL.
    /// - Throws: ``TestDatabaseError/environmentNotConfigured`` when the variable is not set.
    public static func serverURL() throws -> String {
        guard let url = ProcessInfo.processInfo.environment[environmentVariable], !url.isEmpty else {
            throw TestDatabaseError.environmentNotConfigured
        }
        return url
    }

    /// Replaces the database name in a connection URL.
    ///
    /// - Parameters:
    ///   - url: The original connection URL.
    ///   - database: The database to point at.
    /// - Returns: The new URL.
    /// - Throws: ``TestDatabaseError/invalidURL`` when the URL cannot be parsed.
    public static func url(
        _ url: String,
        pointingAt database: String
    ) throws -> String {
        guard var components = URLComponents(string: url) else {
            throw TestDatabaseError.invalidURL
        }
        components.path = "/" + database
        guard let result = components.string else {
            throw TestDatabaseError.invalidURL
        }
        return result
    }

    private static func withDatabase<Result: Sendable>(
        eventLoopGroup: any EventLoopGroup,
        migrated: Bool,
        _ body: @Sendable (TestDatabase) async throws -> Result
    ) async throws -> Result {
        let server = try serverURL()
        let name = databaseNamePrefix + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let logger = Logger(label: "integration-tests")

        let admin = try makeDatabases(url: url(server, pointingAt: maintenanceDatabase), group: eventLoopGroup)
        try await run("CREATE DATABASE \(ident: name)", on: admin, logger: logger)

        let testDatabases = try makeDatabases(url: url(server, pointingAt: name), group: eventLoopGroup)
        let database = TestDatabase(
            databases: testDatabases,
            databaseID: .psql,
            url: try url(server, pointingAt: name),
            logger: logger
        )

        do {
            if migrated {
                try await migrate(testDatabases, group: eventLoopGroup, logger: logger)
            }
            let result = try await body(database)
            await testDatabases.shutdownAsync()
            try await run("DROP DATABASE \(ident: name) WITH (FORCE)", on: admin, logger: logger)
            await admin.shutdownAsync()
            return result
        } catch {
            await testDatabases.shutdownAsync()
            try? await run("DROP DATABASE \(ident: name) WITH (FORCE)", on: admin, logger: logger)
            await admin.shutdownAsync()
            throw error
        }
    }

    /// Applies every migration, the same way the `migrate` command does.
    ///
    /// - Parameters:
    ///   - databases: The database to migrate.
    ///   - group: The event loops to run on.
    ///   - logger: Receives migration logs.
    /// - Throws: Whatever the migrator throws.
    public static func migrate(
        _ databases: Databases,
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        logger: Logger
    ) async throws {
        let migrations = Migrations()
        migrations.add(PersistenceMigrations.all)
        let migrator = Migrator(databases: databases, migrations: migrations, logger: logger, on: group.any())

        try await migrator.setupIfNeeded().get()
        try await migrator.prepareBatch().get()
    }

    /// Reverts every applied migration.
    ///
    /// - Parameters:
    ///   - databases: The database to revert.
    ///   - group: The event loops to run on.
    ///   - logger: Receives migration logs.
    /// - Throws: Whatever the migrator throws.
    public static func revertAll(
        _ databases: Databases,
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        logger: Logger
    ) async throws {
        let migrations = Migrations()
        migrations.add(PersistenceMigrations.all)
        let migrator = Migrator(databases: databases, migrations: migrations, logger: logger, on: group.any())

        try await migrator.revertAllBatches().get()
    }

    /// Builds a connection pool for a URL.
    ///
    /// - Parameters:
    ///   - url: The connection URL.
    ///   - group: The event loops the pool uses.
    ///   - maximumConnectionsPerEventLoop: Pool size per event loop.
    ///   - connectionPoolTimeout: Longest a call waits for a connection.
    /// - Returns: The registry, with the database registered as `DatabaseID.psql`.
    /// - Throws: ``RepositoryError`` for an invalid URL.
    public static func makeDatabases(
        url: String,
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        maximumConnectionsPerEventLoop: Int = 2,
        connectionPoolTimeout: Duration = .seconds(5)
    ) throws -> Databases {
        let databases = Databases(threadPool: NIOThreadPool.singleton, on: group)
        let settings = PostgresSettings(
            url: url,
            applicationName: applicationName,
            maximumConnectionsPerEventLoop: maximumConnectionsPerEventLoop,
            connectionPoolTimeout: connectionPoolTimeout,
            statementTimeout: .seconds(30)
        )
        databases.use(try settings.makeConfiguration(), as: .psql)
        return databases
    }

    private static func run(
        _ statement: SQLQueryString,
        on databases: Databases,
        logger: Logger
    ) async throws {
        guard
            let database = databases.database(.psql, logger: logger, on: databases.eventLoopGroup.any()),
            let sql = database as? any SQLDatabase
        else {
            throw TestDatabaseError.notSQL
        }
        try await sql.raw(statement).run()
    }
}
