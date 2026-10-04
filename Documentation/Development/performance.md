# Performance

How the service is measured, what the numbers are on a reference machine and what measuring found. The reasoning behind
the method is in [ADR-007](../ADR/ADR-007-testing-and-performance.md).

## Running the benchmarks

```bash
make benchmark                       # release build, one benchmark at a time; tables on screen, JSON in .artifacts/benchmarks
BENCHMARK_BUDGET_SCALE=3 make benchmark   # a slower machine, such as a shared CI runner: budgets three times looser
Scripts/compare-benchmarks.sh .artifacts/benchmarks-baseline .artifacts/benchmarks   # how this run differs from another
```

Benchmarks belong in a **release** build, on a quiet machine. A debug run (`swift test --filter PerformanceTests`) executes a
twentieth of the iterations against budgets ten times looser: it is a smoke test, not a measurement. The database
benchmarks need `TEST_DATABASE_URL` (`make benchmark` passes it) and are skipped without it.

To keep a baseline for later comparison: `cp -r .artifacts/benchmarks .artifacts/benchmarks-baseline` before a change, run
`make benchmark` after it, then compare. The comparison matches benchmarks by group and name, warns when the two runs were
taken in different environments, and with `--fail-above 50` exits non-zero when a p95 got more than 50% slower.

## What is measured

Every benchmark runs an operation many times after a discarded warm-up and reports the **minimum, p50, p95, p99, maximum, mean**
latency, the **concurrency** it ran at and the **throughput** in operations per second of wall time. Percentiles are nearest-rank,
so every reported value was actually observed.

| Group | What | Why |
|---|---|---|
| `engine-operations` | The first documented example of **every** operation (the 25 slowest are printed) | A performance profile of the whole catalog, with no parameters to maintain: examples are executable documentation |
| `engine-scaled` | The heavy operations at realistic sizes: 10,000 values, 360 amortization months, 100,000 integration intervals, 50×50 matrices, a cached expression | Where the time goes as inputs grow |
| `concurrency` | CPU-bound calculations through the service at concurrency 1, 2, 4, 8, 16, and a 1,000-item batch | Whether throughput scales with cores |
| `serialization-*` | Encoding responses, decoding request bodies, the SHA-256 fingerprint, timestamps, cursors, log lines | What the edges of the service cost |
| `api-endpoints`, `api-load` | The whole HTTP stack in memory, from `/health` (the framework's floor) to a recorded calculation, sequentially and under load | The cost of routing, middleware, handlers and JSON |
| `api-http` | The same over a real loopback socket with connections reused | Closest to what a client sees, without the network |
| `database-repository` | Every repository call against PostgreSQL with 10,000 rows, deep keyset pagination, concurrent writers | The cost of the history |
| `database-end-to-end` | HTTP, engine and PostgreSQL together | The cost of a request |

Each benchmark also asserts a **p99 budget**, set several times above what a reference machine achieves, so only a
regression of an order of magnitude fails (a quadratic loop, a query that stopped using its index).

## Reference results

Measured on an Arch Linux workstation with 12 logical processors, Swift 6.4 (release), PostgreSQL 18 in a local Docker
container, in-memory transport unless stated. They show orders of magnitude and ratios; **absolute numbers will differ on
other hardware**, and microsecond-scale benchmarks vary by tens of percent between runs.

### The engine (no HTTP, no database)

| Operation | p50 | p99 |
|---|---|---|
| A typical operation (arithmetic, percentage, conversion, a vector or small matrix operation) | 10–60 µs | under 120 µs |
| A financial calculation (loan payment, NPV, IRR) | 55–125 µs | under 220 µs |
| `statistics.mean`, 10,000 values | 80 µs | 190 µs |
| `statistics.linear_regression`, 10,000 points | 0.8 ms | 1.0 ms |
| `linear_algebra.matrix_determinant`, 50×50 | 75 µs | 110 µs |
| `linear_algebra.matrix_inverse`, 50×50 | 0.45 ms | 1.1 ms |
| `financial.amortization_schedule`, 360 months | 1.6 ms | 4.8 ms |
| `numerical.integrate`, 100,000 intervals | 10.5 ms | 15.9 ms |
| `expression.evaluate`, compiled once and cached | 73 µs | 113 µs |

The default time budget of a calculation is 2 s, which none of these approaches.

### Scaling across cores

`standard_deviation` over 1,000 values, through `CalculationService`:

| In flight | Throughput |
|---|---|
| 1 | about 8,000–13,000 per second |
| 2 | about 27,000–33,000 |
| 4 | about 38,000–50,000 |
| 8 | about 87,000–121,000 |
| 16 | about 116,000–138,000 |

Throughput grows roughly in proportion to the number of cores that are actually busy, which is what pure calculations on
independent tasks should do. A batch of 1,000 additions at concurrency 8 completes in about 4.6 ms.

### The edges

| | p50 |
|---|---|
| Encode a calculation response | 10–27 µs |
| Encode a history page of 100 | 0.67 ms |
| Decode a small request body | 7 µs |
| Decode a request body with 1,000 numbers | 0.28 ms |
| Fingerprint a request with 1,000 numbers (SHA-256) | 0.47 ms |
| Render a JSON log line | 10 µs |

### HTTP

| | p50 | p99 | Throughput |
|---|---|---|---|
| `GET /health`, loopback HTTP | 0.22 ms | 1.4 ms | 3,100 per second, sequential |
| `POST /api/v1/calculations`, loopback HTTP, in-memory history | 0.66 ms | 2.5 ms | 900 per second, sequential |
| the same, 16 in flight | 1.2 ms | 6.5 ms | about 11,000 per second |
| the same, 64 in flight | 4.8 ms | 25 ms | about 11,000 per second |

Sequential latencies at this scale are dominated by waking threads, not by the service: the same request is several times
cheaper per operation when many are in flight. Read **throughput under concurrency** as the capacity figure and the
sequential numbers as the floor of one idle request. A client and the server shared this machine, so the ceiling is also
the client's.

### PostgreSQL

| | p50 | p99 |
|---|---|---|
| `find` by identifier | 1.2 ms | 1.5 ms |
| `save` | 3.1 ms | 3.7 ms |
| `save` with an idempotency key | 3.6 ms | 5.1 ms |
| `list` the first page of 20 (10,000 rows) | 2.7 ms | 3.4 ms |
| `list` a page of 20 after 5,000 rows (keyset) | 2.9 ms | 3.3 ms |
| `list` failures only (partial index) | 1.0 ms | 1.3 ms |
| 8 concurrent writers | 3.8 ms | 40 ms — about 1,800–2,500 saves per second |
| `POST /api/v1/calculations`, HTTP + engine + PostgreSQL | 5.8 ms | 6.8 ms |
| the same, 8 in flight | 2.5 ms | 28 ms — about 2,100–2,400 requests per second |

A keyset page deep in the table costs the same as the first one, which is the point of keyset pagination (an offset of 5,000
would have read and discarded 5,000 rows). A write is a transaction — three round trips and a durable commit — and that
commit, not the engine, is what limits write throughput: capacity planning for writes is capacity planning for the database.

## What measuring found

Three changes came directly from the first run, each verified by repeating it:

| Finding | Cause | Change | Effect |
|---|---|---|---|
| Decoding a request with 1,000 numbers took **6.9 ms**, 24 times the cost of calculating on them | Each JSON value was tried as a boolean first, and every failed attempt costs an error | Numbers are tried first, and a list is first read as a list of numbers | **0.28 ms** (−96%); history reads also got faster, because stored parameters are decoded the same way (a 50×50 matrix inverse: 1.2 ms → 0.45 ms) |
| Writing a JSON log line took **305 µs**, a cost every request pays at least twice | A regular expression ran over every value to mask URL credentials, and key checks built temporary strings | A byte scan skips the regular expression when the text has no `@`, and key checks compare bytes in place | **10 µs** (−97%) |
| Listing 1,000 records in the in-memory history took **20 ms** | Comparing two identifiers built two strings | Identifiers are compared by their bytes, which orders them identically | Listing 100 records: 128 µs; the test double stopped dominating the HTTP benchmarks |

Benchmarks also showed what was **not** a problem: calculations themselves (tens of microseconds), response encoding
(single-digit microseconds per record), the SHA-256 fingerprint of an idempotency key (under half a millisecond for 1,000
numbers) and the metering and retry decorators on the repository (not measurable against a database call).

## Tuning

| Setting | Effect | When to change it |
|---|---|---|
| `DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP` (default 2) | Pool size is this times the event loops | Raise when requests wait for a connection (`database_operation_duration_seconds` rises while PostgreSQL is idle); keep the total below the server's `max_connections` across all replicas |
| `BATCH_CONCURRENCY` (default 8) | Calculations of one batch running at once | Raise for CPU-bound batches on large hosts; lower to protect the connection pool |
| `CALCULATION_TIMEOUT_MS` (default 2,000) | Time budget of a calculation | Raise only for operations that legitimately need it; see `CALCULATION_TIMEOUT` in the metrics |
| `DATABASE_STATEMENT_TIMEOUT_MS` (default 5,000) | Longest a statement may run | Lower to fail fast under overload |

## What this does not tell you

A benchmark shows how fast the code is. It does not show how the deployed service behaves under real traffic: network
latency, TLS, a gateway, a database on another host, noisy neighbours and cold caches all add to it. Before sizing a
deployment, run a load test against it, and use the metrics in the [observability guide](../Operations/observability.md)
to read the result.
