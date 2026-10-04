# ADR-007 — Testing and Performance Measurement

- **Status:** Accepted
- **Date:** 2026-10-04

## Context

The service is mostly rules — numerical, protocol and operational — whose failure modes are subtle: an off-by-one in a
cursor, a retry that duplicates a write, a shutdown that closes the database under a running request. Most of those bugs
were found by tests that exercise the real thing rather than a mock of it. The suite has to stay fast enough to run
constantly, honest about what it proves, and easy to extend, and the service has to be measured, not assumed, to be fast.

## Decisions

### Layers

| Target | What it proves | External services | Run by |
|---|---|---|---|
| `UnitTests` | Domain rules, parsers, policies, decorators, actors, each with in-memory collaborators | none | `make test-unit` |
| `ContractTests` | The HTTP API as a client sees it, held to the OpenAPI document | none (in-memory adapters) | `make test-contract` |
| `IntegrationTests` | The adapters and the whole service against a real PostgreSQL | PostgreSQL | `make test-integration` |
| `PerformanceTests` | Latency, throughput and scaling, against budgets | PostgreSQL for the database benchmarks | `make benchmark` |
| Smoke scripts | The real executable and the container: startup, graceful shutdown | PostgreSQL | `make smoke-shutdown`, CI |

Each layer answers a question the layer below cannot. The unit layer is where almost everything is decided, because it is
fast; the others exist to check that the pieces fit and that the unit tests' doubles told the truth.

### Swift Testing, not XCTest

Swift Testing is the only framework in use. Parameterized tests keep boundary tables readable, traits state intent where
it matters (`.timeLimit` on every test that waits for concurrency, `.serialized` on suites that share a resource,
`.enabled(if:)` on benchmarks that need a database), and `#expect` reports the failing expression.

XCTest is not used because nothing needs it. It would be justified by a dependency that only offers XCTest integrations, or
by `XCTMetric`-based performance tests with stored baselines on Apple platforms. Neither applies: performance is measured by
a purpose-built harness (below) because the questions — percentiles, behaviour under concurrency, throughput, JSON for CI —
are not what `measure {}` answers.

### Real collaborators, honest doubles

- **PostgreSQL is real in integration tests.** Every test gets its own temporary database, created and dropped around it,
  so tests are isolated and parallel. Mocking the database would not have found a single bug this layer exists to find.
- **One contract, two implementations.** The repository contract suite runs identically against the in-memory double and
  the PostgreSQL adapter, which keeps the double honest. A property the double cannot show — sub-millisecond timestamps in a
  keyset cursor — is added to the contract, and the real adapter decides.
- **Time and identifiers are injected.** A manual clock and sequential identifiers make tests deterministic; there are no
  sleeps to "give it time". Where something is asynchronous by design (events, error reports) a bounded polling loop under a
  time limit waits for the effect, never for a duration.
- **Real sockets only where the framework needs them.** The in-memory transport skips the HTTP server, so limits the server
  enforces (body size) and the stand-in tracker are exercised over a loopback socket.

### The OpenAPI document is executable

Contract tests drive every documented operation and validate each response — status, headers, body — against the schema in
the document, and fail when a route is undocumented or a documented operation has no route. Schemas forbid undeclared
properties, so a field added without being documented fails the build. The error catalog, the error guide and the
document are checked against one another.

### Rules of the architecture are tests too

Fitness tests keep the domain free of framework imports, the module folders complete and the error catalog in step with the
codes declared in the sources. A rule the compiler cannot enforce and a reviewer will forget is a test.

### Seeing the cost of the tests

Tests that are slow without anyone noticing become tests nobody runs. Swift Testing prints each test's duration;
`make test-report` runs the fast suites with a JUnit report, lists the slowest tests and the time per suite, and flags any
test slower than a limit (a slow unit test usually waits for something it should not). CI uploads the XML and shows it in its
own test view.

### Coverage is a floor, not a goal

`make coverage` enforces a minimum line coverage per source target (core 95%, persistence 90%, engine 90%), set a little
below what the suite achieves, so a change that adds code without tests is noticed. It says nothing about whether the
tests are good: the point of the suite is the properties it checks — idempotency, ordering, atomicity, shutdown — and
those are reviewed, not measured.

### Performance is measured by a harness, in release, one benchmark at a time

- A benchmark runs an operation many times, discards a warm-up, and reports min, p50, p95, p99, max, mean, standard
  deviation and **throughput**, with the concurrency it ran at. Percentiles use the nearest-rank method, so a reported
  value is always one that was observed.
- Benchmarks cover the engine (every operation's documented example, and the heavy operations at scale), concurrency scaling
  through the service and a batch, serialization (responses, request bodies, the SHA-256 fingerprint, timestamps, cursors,
  log lines), the HTTP stack over in-memory adapters (from `/health`, the framework's floor, up to a recorded calculation,
  sequentially and under load), PostgreSQL (every repository call, deep keyset pagination, concurrent writers) and the whole
  service on top of PostgreSQL.
- They run **serially**, because two benchmarks at once measure each other, and in **release**, because a debug build is an
  order of magnitude slower. A debug run executes fewer iterations with looser budgets and still catches crashes and
  gross regressions.
- **Budgets are coarse on purpose.** Each benchmark asserts a p99 budget several times what a reference machine achieves,
  scaled by `BENCHMARK_BUDGET_SCALE` for slower machines. A budget exists to catch a regression of an order of magnitude —
  an accidental quadratic loop, a query that stopped using its index — not to chase noise. Finer comparisons are made
  between the JSON reports of two runs.
- Results are printed as tables and written as JSON (`.artifacts/benchmarks`), which CI keeps as artifacts.

A benchmark is not a load test. It shows how fast the code is and how it scales across cores; how the deployed service
behaves under real traffic, with real networks and a real database, needs a load test against a deployed environment.

## Consequences

- The default `make test` is fast and needs no services beyond PostgreSQL for the integration layer.
- The suite finds the kind of bug that matters here, at the cost of a PostgreSQL in CI and a few seconds of real I/O.
- Benchmarks do not run in the default test command; they need a release build and a quiet machine, and are a separate job.
- Anyone can see, with one command each, how fast the tests are, how much of the code they reach and how fast the code is.

## Alternatives considered

- **XCTest alongside Swift Testing.** Two frameworks and two mental models for no capability the project uses.
- **Mocking the database.** Fast, and blind to constraints, casts and transactions.
- **`measure {}` for performance.** Reports a mean and a deviation; the questions here are about tails and concurrency.
- **Strict performance budgets.** They fail for reasons that are not regressions and teach people to ignore them.
