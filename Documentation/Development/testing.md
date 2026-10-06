# Testing

How the suite is organised, how to run each part and how to add to it. The reasoning is in
[ADR-007](../ADR/ADR-007-testing-and-performance.md).

## Running

| Command | What runs | Needs |
|---|---|---|
| `make test` | Unit, contract and integration tests | PostgreSQL (started by `make db-up`) |
| `make test-unit` | Domain rules, parsers, policies, decorators, actors | nothing |
| `make test-contract` | The HTTP API against the OpenAPI document, in memory | nothing |
| `make test-integration` | Adapters and the whole service against a real PostgreSQL | PostgreSQL |
| `make test-report` | The fast suites, with the slowest tests and the time per suite | nothing |
| `make coverage` | Everything, with a minimum line coverage per target | PostgreSQL, `jq`, `llvm-cov` (part of the Swift toolchain) |
| `make benchmark` | The benchmarks, in release mode | PostgreSQL |
| `make smoke-shutdown` | The real executable: SIGTERM with requests in flight | PostgreSQL |

A single test or suite: `swift test --filter "ErrorMapper"`. The integration tests read the server from
`TEST_DATABASE_URL` (the Makefile passes `DATABASE_URL` from `.env`); the role needs permission to create databases,
because every test creates and drops one of its own.

## What lives where

```text
Tests/
  Unit/                 Fast tests, one folder per area (Calculation, Modules, Application, HTTP, Events, …)
  Contract/             ApiContractTests: behaviour of each endpoint · OpenAPIContractTests: the document, held to the API
  Integration/          Persistence, HTTP against PostgreSQL, Sentry over a real connection
  Performance/          Benchmarks (not run by `make test`)
  Support/              Shared fixtures: manual clock, in-memory repository, repository contract suite, …
  HTTPSupport/          TestApplication, TestClient, FakeSentryServer, HostileRequests: the full HTTP stack in a test
  IntegrationSupport/   PostgresTestDatabase: a temporary database per test
  PerformanceSupport/   Benchmark runner, latency statistics, report
```

## Conventions

- **Swift Testing only.** `@Suite` and `@Test` with a sentence as the name, `#expect` and `#require`, parameterized
  tests (`arguments:`) for boundary tables.
- **No sleeps.** Time and identifiers are injected (`ManualClock`, `SequentialIdentifiers`). Where an effect is
  asynchronous by design, poll for it in a bounded loop and put a `.timeLimit` on the test.
- **Real collaborators where the bug would hide.** Integration tests use a real PostgreSQL, one temporary database per
  test, and suites that open database pools are `.serialized` so they stay within the server's connection limit.
- **One contract, two implementations.** A property of the history belongs in `RepositoryContract`, which runs against the
  in-memory double and the PostgreSQL adapter alike.
- **Assert on the wire, not on the types that produced it.** Contract tests read responses as generic JSON
  (`response.json().at("error", "code")`), so a renamed field fails.
- **Test the failure, not just the success.** Every guard, every classification and every error code has a test that
  reaches it.
- **Input is hostile, and that is tested as its own layer.** `HostileInputTests` runs every operation with each parameter
  of its example replaced, one at a time, by floating-point extremes, empty, oversized and ragged collections, malicious
  text and values of the wrong type. `HostileRequests` is a corpus of malformed, oversized and malicious requests, run by
  `HostileRequestTests` against the in-memory adapters and by `HostileRequestsAgainstPostgresTests` against a real
  PostgreSQL. Nothing may crash, hang or answer `5xx`, and every error stays inside the envelope. The second run matters:
  a test double accepts what a database refuses, and that is how a NUL in text reached the database.

## Adding to the suite

| You are adding… | Put the test in… | Also |
|---|---|---|
| A calculation operation | The module's tests, with the documented examples | The operation's `examples` are executed automatically |
| An endpoint | `ApiContractTests` | Document it in `Documentation/API/openapi.json`; the contract tests fail until you do |
| Anything that reads a path, a query, a header or a body | Its worst inputs, in `HostileRequests` | They run against the in-memory adapters and against PostgreSQL |
| A calculation operation's parameters | Nothing: the example you write is swept with hostile values | A new loop whose cost grows with its input must call `Cooperation.checkpoint`, or the sweep's time limit fails |
| An error code | `ErrorCatalog`, then `Documentation/API/errors.md` and the OpenAPI `ErrorCode` enum | Tests keep the three in step |
| A repository behaviour | `RepositoryContract` | It runs against both implementations |
| A resilience or lifecycle rule | `Tests/Unit/Resilience` or `Tests/Unit/Lifecycle`, with `ManualClock` | A `.timeLimit` if it waits |
| Something only the real process shows | A script in `Scripts/`, like `smoke-graceful-shutdown.sh` | Wire it into CI |

## Reading the results

`make test-report` prints, for the fast suites: how many tests ran and how long they took, the slowest tests, the time per
suite, and every test slower than `SLOW_TEST_SECONDS` (default 1). A unit test that is slow is almost always waiting for
something it should not. The JUnit XML is written to `.artifacts/test-reports/`.

`make coverage` prints the line coverage of each source target against its minimum (core 95%, persistence 90%, engine 90%)
and the least covered files, and fails when a target is below its minimum. The process boundary (`Entrypoint.swift`, the
signal watcher's delivery of real signals) is deliberately left to the smoke scripts rather than to tests: signals are
process-wide, so a test that sends them depends on every test running beside it.
