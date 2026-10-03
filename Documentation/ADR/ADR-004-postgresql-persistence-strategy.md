# ADR-004 — PostgreSQL Persistence Strategy

- **Status:** Accepted
- **Date:** 2026-10-03

## Context

The engine records every calculation it runs: what was asked, what came out, how long it took and which request caused
it. The history must be correct under concurrent retries, queryable by time, type, status and request, and safe to
evolve. It is also a showcase of realistic persistence: constraints, indexes, transactions, migrations and tests against
the real database.

## Decision

### Fluent for plumbing, SQL for queries

`BorbaScientificPersistence` uses Fluent's connection pool, transactions and migration machinery with the PostgreSQL
driver, and writes its queries as plain SQL through SQLKit with every value bound as a parameter. Fluent models are not
used. Reasons:

- **Keyset pagination.** `WHERE (created_at, id) < ($1, $2)` lets PostgreSQL seek straight to the cursor in the index. The
  query builder can only express the equivalent `OR` form, which degrades to scanning from the top on deep pages.
- **The schema leans on PostgreSQL features** — `jsonb`, check constraints, partial indexes, `ON CONFLICT` — that are the
  point of the schema and read best as SQL, reviewable by a DBA as written.
- **One definition of the schema.** Models would duplicate the migrations and drift from them.

The persistence target does not depend on Vapor. Vapor's Fluent integration is used only at the edge, to register the
database, expose the `migrate` command and share the connection pool.

### Schema

- `calculations`: one row per calculation. A single `CHECK` makes the outcome self-consistent — a succeeded row has a
  result and no error, a failed row has an error and no result — so an impossible row cannot be stored. Further checks
  keep `parameters` an object, names well formed and the execution time non-negative.
- `idempotency_keys`: binds a client key to the first calculation that used it. The key is the primary key, the
  calculation is unique and referenced with `ON DELETE CASCADE`.
- Indexes, each tied to a query: `(created_at DESC, id DESC)` for the default listing and pagination;
  `(module, operation, created_at DESC, id DESC)` for filtered listings; a partial index on failures; and single-column
  indexes on `request_id` and `correlation_id`, which answer "what happened to this request?".
- Identifiers are time-ordered UUIDs (version 7), so inserts append to the index instead of scattering across it.
- `updated_at` is deliberately absent: history is append-only, so rows never change.

### Transactions and idempotency

A record and its idempotency key are written in one transaction. The calculation itself runs *before* the transaction,
so no database connection is held while CPU-bound work runs. Concurrent retries race on the key's primary key: the
winner commits, the losers roll back and return the winner's record. There is no "in progress" state that a crash
could leave stuck.

### Migrations

Migrations are SQL with stable, dated names, applied by the `migrate` command and reversible. Production never migrates
on startup: several replicas would race, and a failed migration would crash every one of them. Instead, readiness
reports `migrations pending` until the schema matches the code, so an orchestrator will not route traffic to a
replica that is ahead of its database.

### Resilience

Connections announce `application_name` and a server-side `statement_timeout`, so PostgreSQL cancels a runaway query
even when the client is stuck. Waiting for a pooled connection has its own short timeout, so overload fails fast
instead of queueing. Every driver error is translated to a `RepositoryError` with a transient/permanent distinction;
no caller depends on driver types.

### Testing

Integration tests run against a real PostgreSQL. Each test gets its own temporary database, created and dropped around
it, so tests are isolated and parallel. A repository **contract suite** runs identically against the in-memory test
double and the PostgreSQL adapter, which keeps the double honest. Tests cover migrations up and down, every constraint,
atomicity, error mapping (unreachable server, statement timeout, pool exhaustion, corrupted rows) and log correlation.

## Consequences

- Queries are explicit and fast, at the cost of hand-written row mapping, which lives in one file.
- The adapter is tied to PostgreSQL. That is accepted: the port keeps the rest of the system independent, and
  switching stores means writing one adapter against the contract suite.
- History grows without bound. Retention is out of scope for now; the time-ordered primary key and the `created_at`
  index make age-based partitioning or pruning straightforward when it becomes necessary.

## Alternatives considered

- **Fluent models and the query builder.** Familiar and concise, but cannot express the keyset predicate and duplicates
  the schema.
- **Mocking the database in repository tests.** Fast, but it would not catch a single constraint, cast or transaction
  bug, which are exactly the bugs this layer can have.
- **Storing results as typed columns.** Results are heterogeneous (numbers, lists, objects); `jsonb` stores them
  faithfully without a table per operation.
