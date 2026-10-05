public import BorbaScientificCore
public import FluentKit
public import FluentPostgresDriver
import FluentSQL
import Foundation
public import Logging
import NIOCore
import SQLKit

/// The PostgreSQL implementation of the calculation history.
///
/// Fluent supplies the connection pool, the transaction handling and the migration machinery; the queries are plain SQL
/// through SQLKit, with every value bound as a parameter, never interpolated. SQL is used here on purpose: keyset
/// pagination needs a row-value comparison that the query builder cannot express and that keeps deep pages as cheap as
/// the first one, and the schema leans on `jsonb`, check constraints and `ON CONFLICT`.
///
/// - **Atomicity:** a record and its idempotency key are written in one transaction, so a retry can never find a key
///   without its record or the other way round.
/// - **Concurrency:** the key's primary key arbitrates concurrent retries; the loser rolls back and returns the winner.
/// - **Logging:** every call is logged with the request and correlation identifiers of the calling task, when it has
///   them, so a slow or failing query can be tied back to the HTTP request that caused it.
public struct FluentCalculationRepository: CalculationRepository {
    private struct KeyAlreadyClaimed: Error {}

    private static let microsecondsPerSecond = 1_000_000.0

    private let databases: Databases
    private let databaseID: DatabaseID
    private let logger: Logger

    /// Creates a repository over a database that has already been configured.
    ///
    /// - Parameters:
    ///   - databases: The registry that owns the connection pool.
    ///   - databaseID: Which database to use.
    ///   - logger: The logger SQL statements and failures are written to.
    public init(
        databases: Databases,
        databaseID: DatabaseID = .psql,
        logger: Logger
    ) {
        self.databases = databases
        self.databaseID = databaseID
        self.logger = logger
    }

    // MARK: - CalculationRepository

    /// Stores a record and binds its idempotency key in one transaction.
    ///
    /// - Parameters:
    ///   - record: The record to store.
    ///   - claim: The idempotency key and request fingerprint, when the client supplied a key.
    /// - Returns: ``SaveResult/created``, or the record that already owns the key.
    /// - Throws: ``RepositoryError`` when the database fails.
    public func save(
        _ record: CalculationRecord,
        claiming claim: IdempotencyClaim?
    ) async throws(RepositoryError) -> SaveResult {
        let database = try connection()

        do {
            try await database.transaction { transaction in
                let sql = try Self.sql(transaction)
                try await Self.insert(record, on: sql)
                if let claim, try await !Self.bind(claim, to: record, on: sql) {
                    throw KeyAlreadyClaimed()
                }
            }
            return .created
        } catch is KeyAlreadyClaimed {
            return try await duplicate(of: claim)
        } catch {
            throw RepositoryErrorMapping.map(error)
        }
    }

    /// Finds the record created under an idempotency key.
    ///
    /// - Parameter key: The client's key.
    /// - Returns: The record and the fingerprint of the request that created it, or `nil` when the key is unused.
    /// - Throws: ``RepositoryError`` when the database fails.
    public func record(for key: IdempotencyKey) async throws(RepositoryError) -> IdempotentRecord? {
        try await perform { sql in
            let binding = try await sql.raw(
                "SELECT calculation_id, fingerprint FROM idempotency_keys WHERE key = \(bind: key.rawValue)"
            ).first(decoding: IdempotencyRow.self)

            guard let binding else {
                return nil
            }
            guard let record = try await Self.row(id: binding.calculationID, on: sql)?.record() else {
                throw RepositoryError.corrupted(reason: "an idempotency key points at a missing record")
            }
            return IdempotentRecord(record: record, fingerprint: RequestFingerprint(binding.fingerprint))
        }
    }

    /// Finds a record by identifier.
    ///
    /// - Parameter id: The identifier of the record.
    /// - Returns: The record, or `nil` when it does not exist.
    /// - Throws: ``RepositoryError`` when the database fails.
    public func find(id: CalculationID) async throws(RepositoryError) -> CalculationRecord? {
        try await perform { sql in
            try await Self.row(id: id.rawValue, on: sql)?.record()
        }
    }

    /// Lists records, newest first, with keyset pagination.
    ///
    /// - Parameters:
    ///   - filter: Narrows the records considered.
    ///   - page: Which page to read.
    /// - Returns: The page, with a cursor when more records follow.
    /// - Throws: ``RepositoryError`` when the database fails.
    public func list(
        matching filter: HistoryFilter,
        page: BorbaScientificCore.PageRequest
    ) async throws(RepositoryError) -> BorbaScientificCore.Page<CalculationRecord> {
        try await perform { sql in
            // One extra row tells whether another page follows without a second query.
            let rows = try await sql.raw(Self.listQuery(filter: filter, page: page))
                .all(decoding: CalculationRow.self)

            let records = try rows.prefix(page.limit).map { try $0.record() }
            let nextCursor =
                rows.count > page.limit ? records.last.map { PageCursor(createdAt: $0.createdAt, id: $0.id) } : nil
            return BorbaScientificCore.Page(items: records, nextCursor: nextCursor)
        }
    }

    // MARK: - Connection

    private func connection() throws(RepositoryError) -> any Database {
        var contextual = logger
        if let trace = TraceContext.current {
            contextual[metadataKey: TraceMetadataKey.requestID] = .string(trace.requestID.rawValue)
            contextual[metadataKey: TraceMetadataKey.correlationID] = .string(trace.correlationID.rawValue)
        }

        guard let database = databases.database(databaseID, logger: contextual, on: databases.eventLoopGroup.any())
        else {
            throw .unavailable(reason: "the database connections have been shut down")
        }
        return database
    }

    private func perform<Result: Sendable>(
        _ operation: @Sendable (any SQLDatabase) async throws -> Result
    ) async throws(RepositoryError) -> Result {
        let database = try connection()

        do {
            return try await operation(try Self.sql(database))
        } catch {
            throw RepositoryErrorMapping.map(error)
        }
    }

    private static func sql(_ database: any Database) throws -> any SQLDatabase {
        guard let sql = database as? any SQLDatabase else {
            throw RepositoryError.unexpected(reason: "the configured database does not speak SQL")
        }
        return sql
    }

    private func duplicate(of claim: IdempotencyClaim?) async throws(RepositoryError) -> SaveResult {
        guard let claim else {
            throw .unexpected(reason: "a key conflict was reported for a request without a key")
        }
        guard let owner = try await record(for: claim.key) else {
            throw .unexpected(reason: "the owner of a contested idempotency key disappeared")
        }
        return .duplicate(owner)
    }

    // MARK: - Statements

    private static func insert(
        _ record: CalculationRecord,
        on sql: any SQLDatabase
    ) async throws {
        let row = CalculationRow(record)

        try await sql.raw(
            """
            INSERT INTO calculations (\(unsafeRaw: CalculationRow.columns))
            VALUES (
                \(bind: row.id), \(bind: row.module), \(bind: row.operation), \(bind: row.status),
                \(bind: row.parameters)::jsonb, \(bind: row.result)::jsonb, \(bind: row.errorCode),
                \(bind: row.errorMessage), \(bind: row.errorDetails)::jsonb,
                \(bind: row.executionTimeNanoseconds), \(bind: row.requestID), \(bind: row.correlationID),
                \(bind: row.createdAt)
            )
            """
        ).run()
    }

    /// Binds an idempotency key to a record.
    ///
    /// - Returns: `false` when another request already owns the key; nothing is written in that case.
    private static func bind(
        _ claim: IdempotencyClaim,
        to record: CalculationRecord,
        on sql: any SQLDatabase
    ) async throws -> Bool {
        let inserted = try await sql.raw(
            """
            INSERT INTO idempotency_keys (key, fingerprint, calculation_id, created_at)
            VALUES (\(bind: claim.key.rawValue), \(bind: claim.fingerprint.rawValue),
                    \(bind: record.id.rawValue), \(bind: record.createdAt))
            ON CONFLICT (key) DO NOTHING
            RETURNING key
            """
        ).first()

        return inserted != nil
    }

    private static func row(
        id: UUID,
        on sql: any SQLDatabase
    ) async throws -> CalculationRow? {
        try await sql.raw(
            "SELECT \(unsafeRaw: CalculationRow.columns) FROM calculations WHERE id = \(bind: id)"
        ).first(decoding: CalculationRow.self)
    }

    /// An instant as SQL that reaches the database exactly.
    ///
    /// Binding a `Date` would leave the conversion to the driver, which truncates a floating-point number of
    /// microseconds, so an instant that a double cannot hold exactly lands one microsecond early and a cursor stops
    /// matching the row it came from. The instant is therefore sent as whole microseconds since the Unix epoch, which
    /// the database turns into a timestamp without any floating-point step.
    ///
    /// - Parameter date: The instant.
    /// - Returns: A `timestamptz` expression.
    private static func timestamp(_ date: Date) -> SQLQueryString {
        let microseconds = wholeMicroseconds(of: date)

        return "('epoch'::timestamptz + \(bind: microseconds) * interval '1 microsecond')"
    }

    /// The instant as whole microseconds, saturating instead of trapping.
    ///
    /// A date that no 64-bit count of microseconds can hold is not a date the database can hold either, so it saturates
    /// and the database refuses it with an error, which the caller can handle. Converting it directly would crash the
    /// process.
    private static func wholeMicroseconds(of date: Date) -> Int64 {
        let microseconds = (date.timeIntervalSince1970 * microsecondsPerSecond).rounded()

        return Int64(exactly: microseconds) ?? (microseconds < 0 ? .min : .max)
    }

    private static func listQuery(
        filter: HistoryFilter,
        page: BorbaScientificCore.PageRequest
    ) -> SQLQueryString {
        var conditions: [SQLQueryString] = []
        if let module = filter.module {
            conditions.append("module = \(bind: module.rawValue)")
        }
        if let operation = filter.operation {
            conditions.append("operation = \(bind: operation.rawValue)")
        }
        if let status = filter.status {
            conditions.append("status = \(bind: status.rawValue)")
        }
        if let createdFrom = filter.createdFrom {
            conditions.append("created_at >= \(timestamp(createdFrom))")
        }
        if let createdBefore = filter.createdBefore {
            conditions.append("created_at < \(timestamp(createdBefore))")
        }
        if let cursor = page.cursor {
            // A row-value comparison lets PostgreSQL seek straight to the cursor in the (created_at, id) index.
            conditions.append("(created_at, id) < (\(timestamp(cursor.createdAt)), \(bind: cursor.id.rawValue))")
        }

        let whereClause: SQLQueryString =
            conditions.isEmpty ? "" : "WHERE \(SQLKit.SQLList(conditions, separator: SQLRaw(" AND ")))"
        return """
            SELECT \(unsafeRaw: CalculationRow.columns) FROM calculations
            \(whereClause)
            ORDER BY created_at DESC, id DESC
            LIMIT \(bind: page.limit + 1)
            """
    }
}
