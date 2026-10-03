import FluentKit
import Foundation
import IntegrationSupport
import SQLKit
import Testing

@testable import BorbaScientificCore
@testable import BorbaScientificPersistence

@Suite("Persistence migrations")
struct MigrationTests {
    private struct NameRow: Decodable {
        let name: String
    }

    private struct DefinitionRow: Decodable {
        let name: String
        let definition: String
    }

    private static let validCalculation =
        """
        INSERT INTO calculations
            (id, module, operation, status, parameters, result,
             execution_time_ns, request_id, correlation_id, created_at)
        VALUES
            ('00000000-0000-7000-8000-000000000001', 'arithmetic', 'add', 'succeeded', '{}', '5',
             1, 'r', 'c', now())
        """

    private func names(
        _ query: SQLQueryString,
        in database: TestDatabase
    ) async throws -> Set<String> {
        Set(try await database.sql().raw(query).all(decoding: NameRow.self).map(\.name))
    }

    private func tables(in database: TestDatabase) async throws -> Set<String> {
        try await names(
            "SELECT table_name AS name FROM information_schema.tables WHERE table_schema = 'public'",
            in: database
        )
    }

    private func violation(of statement: String, in database: TestDatabase) async -> RepositoryError? {
        do {
            try await database.execute("\(unsafeRaw: statement)")
            return nil
        } catch {
            return RepositoryErrorMapping.map(error)
        }
    }

    @Test("creates the schema, drops it again and can recreate it")
    func upDownUp() async throws {
        try await PostgresTestDatabase.withEmptyDatabase { database in
            let owned: Set = ["calculations", "idempotency_keys"]
            #expect(try await tables(in: database).isDisjoint(with: owned))

            try await PostgresTestDatabase.migrate(database.databases, logger: database.logger)
            #expect(try await tables(in: database).isSuperset(of: owned))

            try await PostgresTestDatabase.revertAll(database.databases, logger: database.logger)
            #expect(try await tables(in: database).isDisjoint(with: owned))

            try await PostgresTestDatabase.migrate(database.databases, logger: database.logger)
            #expect(try await tables(in: database).isSuperset(of: owned))
        }
    }

    @Test("applying the migrations twice changes nothing")
    func idempotentMigration() async throws {
        try await PostgresTestDatabase.withMigratedDatabase { database in
            try await PostgresTestDatabase.migrate(database.databases, logger: database.logger)

            let applied = try await names("SELECT name FROM _fluent_migrations", in: database)

            #expect(applied == Set(PersistenceMigrations.names))
        }
    }

    @Test("keeps the migration names stable, because they identify what was applied")
    func stableNames() {
        #expect(
            PersistenceMigrations.names == [
                "20261003-000001-create-calculations",
                "20261003-000002-create-idempotency-keys",
            ]
        )
    }

    @Test("indexes every access path of the history")
    func indexes() async throws {
        try await PostgresTestDatabase.withMigratedDatabase { database in
            let indexes = try await database.sql().raw(
                "SELECT indexname AS name, indexdef AS definition FROM pg_indexes WHERE schemaname = 'public'"
            ).all(decoding: DefinitionRow.self)
            let definitions = Dictionary(uniqueKeysWithValues: indexes.map { ($0.name, $0.definition) })

            #expect(definitions["calculations_created_at_id_idx"]?.contains("created_at DESC, id DESC") == true)
            #expect(
                definitions["calculations_type_created_at_idx"]?.contains("module, operation, created_at DESC") == true
            )
            #expect(definitions["calculations_failed_created_at_idx"]?.contains("WHERE (status = 'failed'") == true)
            #expect(definitions["calculations_request_id_idx"] != nil)
            #expect(definitions["calculations_correlation_id_idx"] != nil)
            #expect(definitions["idempotency_keys_pkey"] != nil)
        }
    }

    @Test("declares a foreign key that cascades when a calculation is deleted")
    func foreignKey() async throws {
        try await PostgresTestDatabase.withMigratedDatabase { database in
            let rules = try await names(
                """
                SELECT delete_rule AS name FROM information_schema.referential_constraints
                WHERE constraint_name = 'idempotency_keys_calculation_id_fkey'
                """,
                in: database
            )

            #expect(rules == ["CASCADE"])
        }
    }

    @Test(
        "rejects rows that break an invariant of the schema",
        arguments: [
            (
                "an unknown status", "calculations_outcome_consistent",
                """
                UPDATE calculations SET status = 'pending' WHERE true
                """
            ),
            (
                "a success without a result", "calculations_outcome_consistent",
                """
                UPDATE calculations SET result = NULL WHERE true
                """
            ),
            (
                "a success with an error", "calculations_outcome_consistent",
                """
                UPDATE calculations SET error_code = 'X', error_message = 'x' WHERE true
                """
            ),
            (
                "a failure without an error", "calculations_outcome_consistent",
                """
                UPDATE calculations SET status = 'failed', result = NULL WHERE true
                """
            ),
            (
                "parameters that are not an object", "calculations_parameters_is_object",
                """
                UPDATE calculations SET parameters = '[1,2]' WHERE true
                """
            ),
            (
                "a malformed module name", "calculations_names_well_formed",
                """
                UPDATE calculations SET module = 'Bad Name' WHERE true
                """
            ),
            (
                "a malformed operation name", "calculations_names_well_formed",
                """
                UPDATE calculations SET operation = '1bad' WHERE true
                """
            ),
            (
                "a negative execution time", "calculations_execution_time_non_negative",
                """
                UPDATE calculations SET execution_time_ns = -1 WHERE true
                """
            ),
        ]
    )
    func constraints(
        label: String,
        constraint: String,
        statement: String
    ) async throws {
        try await PostgresTestDatabase.withMigratedDatabase { database in
            try await database.execute("\(unsafeRaw: Self.validCalculation)")

            let error = await violation(of: statement, in: database)

            guard case .integrity(let reason)? = error else {
                Issue.record("\(label): expected an integrity violation, got \(String(describing: error))")
                return
            }
            #expect(reason.contains(constraint), "\(label): \(reason)")
        }
    }

    @Test("rejects idempotency keys that point nowhere, repeat a record or have an invalid length")
    func idempotencyKeyConstraints() async throws {
        try await PostgresTestDatabase.withMigratedDatabase { database in
            try await database.execute("\(unsafeRaw: Self.validCalculation)")
            let longKey = String(repeating: "k", count: IdempotencyKey.maximumLength + 1)

            func insert(key: String, calculation: String) -> String {
                """
                INSERT INTO idempotency_keys (key, fingerprint, calculation_id, created_at)
                VALUES ('\(key)', 'f', '\(calculation)', now())
                """
            }
            let existing = "00000000-0000-7000-8000-000000000001"
            let missing = "00000000-0000-7000-8000-0000000000ff"

            #expect(await violation(of: insert(key: "k1", calculation: existing), in: database) == nil)
            #expect(
                await violation(of: insert(key: "k2", calculation: missing), in: database)?.diagnostic.contains("23503")
                    == true
            )
            #expect(
                await violation(of: insert(key: "k1", calculation: existing), in: database)?.diagnostic.contains(
                    "23505"
                ) == true
            )
            #expect(
                await violation(of: insert(key: "k3", calculation: existing), in: database)?.diagnostic.contains(
                    "23505"
                ) == true
            )
            #expect(
                await violation(of: insert(key: "", calculation: existing), in: database)?.diagnostic.contains(
                    "idempotency_keys_key_length"
                ) == true
            )
            #expect(
                await violation(of: insert(key: longKey, calculation: existing), in: database)?.diagnostic.contains(
                    "idempotency_keys_key_length"
                ) == true
            )
        }
    }

    @Test("deleting a calculation removes the idempotency key bound to it")
    func cascadingDelete() async throws {
        try await PostgresTestDatabase.withMigratedDatabase { database in
            try await database.execute("\(unsafeRaw: Self.validCalculation)")
            try await database.execute(
                """
                INSERT INTO idempotency_keys (key, fingerprint, calculation_id, created_at)
                VALUES ('k', 'f', '00000000-0000-7000-8000-000000000001', now())
                """
            )

            try await database.execute("DELETE FROM calculations")

            let remaining = try await database.sql().raw("SELECT count(*)::int AS total FROM idempotency_keys")
                .first(decoding: CountRow.self)
            #expect(remaining?.total == 0)
        }
    }

    private struct CountRow: Decodable {
        let total: Int
    }
}
