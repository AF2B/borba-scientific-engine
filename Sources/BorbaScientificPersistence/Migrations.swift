import BorbaScientificCore
public import FluentKit
import FluentSQL

/// The schema of the calculation history, as versioned migrations.
///
/// The application never depends on a schema that was modified by hand: every change is a migration with a stable
/// name, applied by the `migrate` command, recorded by Fluent in `_fluent_migrations` and reversible.
public enum PersistenceMigrations {
    /// Every migration, in the order they must be applied.
    public static var all: [any Migration] {
        [CreateCalculations(), CreateIdempotencyKeys()]
    }

    /// The names of ``all``, which is what a database must contain to be considered up to date.
    public static var names: [String] {
        all.map(\.name)
    }
}

/// Runs plain SQL in a migration. SQL is used on purpose: constraints, partial indexes and column types are the
/// substance of the schema, and a DBA can review them as written.
private func execute(
    _ statements: [SQLQueryString],
    on database: any Database
) async throws {
    guard let sql = database as? any SQLDatabase else {
        throw MigrationError.sqlUnavailable
    }
    for statement in statements {
        try await sql.raw(statement).run()
    }
}

private enum MigrationError: Error {
    case sqlUnavailable
}

/// Creates the table that holds one row per calculation.
struct CreateCalculations: AsyncMigration {
    let name = "20261003-000001-create-calculations"

    func prepare(on database: any Database) async throws {
        try await execute([Self.table] + Self.indexes, on: database)
    }

    func revert(on database: any Database) async throws {
        try await execute(["DROP TABLE IF EXISTS calculations"], on: database)
    }

    private static let table: SQLQueryString =
        """
        CREATE TABLE calculations (
            id                 uuid        PRIMARY KEY,
            module             text        NOT NULL,
            operation          text        NOT NULL,
            status             text        NOT NULL,
            parameters         jsonb       NOT NULL,
            result             jsonb,
            error_code         text,
            error_message      text,
            error_details      jsonb,
            execution_time_ns  bigint      NOT NULL,
            request_id         text        NOT NULL,
            correlation_id     text        NOT NULL,
            created_at         timestamptz NOT NULL,

            -- Also guarantees that status is one of the two known values.
            CONSTRAINT calculations_outcome_consistent
                CHECK (
                    (status = 'succeeded' AND result IS NOT NULL
                        AND error_code IS NULL AND error_message IS NULL AND error_details IS NULL)
                    OR
                    (status = 'failed' AND result IS NULL
                        AND error_code IS NOT NULL AND error_message IS NOT NULL)
                ),
            CONSTRAINT calculations_parameters_is_object
                CHECK (jsonb_typeof(parameters) = 'object'),
            CONSTRAINT calculations_names_well_formed
                CHECK (module ~ '^[a-z][a-z0-9_]*$' AND operation ~ '^[a-z][a-z0-9_]*$'),
            CONSTRAINT calculations_execution_time_non_negative
                CHECK (execution_time_ns >= 0)
        )
        """

    private static let indexes: [SQLQueryString] = [
        // Serves the default listing, newest first, and keyset pagination on (created_at, id).
        "CREATE INDEX calculations_created_at_id_idx ON calculations (created_at DESC, id DESC)",
        // Serves listings filtered by module or by module and operation.
        """
        CREATE INDEX calculations_type_created_at_idx
            ON calculations (module, operation, created_at DESC, id DESC)
        """,
        // Failures are rare and are what operators look for, so a partial index keeps that query tiny.
        """
        CREATE INDEX calculations_failed_created_at_idx
            ON calculations (created_at DESC, id DESC) WHERE status = 'failed'
        """,
        // Answers "what happened to this request?" and "what else belongs to this operation?".
        "CREATE INDEX calculations_request_id_idx ON calculations (request_id)",
        "CREATE INDEX calculations_correlation_id_idx ON calculations (correlation_id)",
    ]
}

/// Creates the table that binds idempotency keys to the first calculation that used them.
struct CreateIdempotencyKeys: AsyncMigration {
    let name = "20261003-000002-create-idempotency-keys"

    func prepare(on database: any Database) async throws {
        try await execute([Self.table], on: database)
    }

    func revert(on database: any Database) async throws {
        try await execute(["DROP TABLE IF EXISTS idempotency_keys"], on: database)
    }

    private static let table: SQLQueryString =
        """
        CREATE TABLE idempotency_keys (
            key             text        PRIMARY KEY,
            fingerprint     text        NOT NULL,
            calculation_id  uuid        NOT NULL UNIQUE
                REFERENCES calculations (id) ON DELETE CASCADE,
            created_at      timestamptz NOT NULL,

            CONSTRAINT idempotency_keys_key_length
                CHECK (char_length(key) BETWEEN 1 AND \(literal: IdempotencyKey.maximumLength))
        )
        """
}
