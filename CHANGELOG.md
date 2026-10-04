# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Repository foundation: SwiftPM package, Vapor 4 application skeleton and the `borba-scientific-engine` executable.
- Typed, environment-driven configuration for `development`, `test`, `staging` and `production`, with aggregated
  validation errors and redacted secrets.
- `GET /health` liveness endpoint.
- Makefile with the day-to-day developer workflow.
- Multi-stage container image and a Docker Compose stack with PostgreSQL.
- Architecture decision record describing the layered architecture.
- Calculation core, free of web and database frameworks, with nine modules: arithmetic, percentage, statistics,
  financial, scientific, conversion, expression, numerical and linear algebra.
- Typed parameter declarations that validate input, produce documentation metadata and give typed access to values.
- Calculation engine with a cooperative time budget, cancellation and results that are values rather than exceptions.
- Calculation history model, repository port, domain events and the use cases that run calculations with
  idempotency keys, event publication and bounded-concurrency batches.
- Typed error model with stable codes and an expected, application, infrastructure or unexpected classification.
- Architecture decision records for the module structure and the error handling strategy, and a guide to adding a
  calculation module.
- Architecture tests that keep the domain free of framework imports.
- PostgreSQL persistence adapter with versioned SQL migrations, check constraints, foreign keys, indexes, atomic
  idempotency and keyset pagination.
- Integration tests against a real PostgreSQL, one temporary database per test, sharing a repository contract suite
  with the in-memory test double.
- Database health probe that reports unreachable databases and pending migrations.
- `make test-integration`, which starts PostgreSQL when needed.
- Architecture decision record for the PostgreSQL persistence strategy.
- Versioned HTTP API: `POST /api/v1/calculations` and `/batch` (idempotency keys, per-item results, bounded
  concurrency), `GET /api/v1/calculations` (validated filters, keyset pagination) and `/{id}`, and the discovery
  endpoints `GET /api/v1/modules`, `/types` and `/types/{module}/{operation}`.
- `GET /version`.
- Request and correlation identifiers on every response, adopted from well-formed request headers and bound to the
  logs of every layer below the HTTP layer.
- One error body for every failure, driven by an error catalog that maps stable codes to HTTP statuses and keeps
  internal causes out of responses; security headers on every response.
- OpenAPI 3.1 document, API guide and error catalog, and contract tests that drive the running API and fail when a
  response, header, status or error code differs from the document or a route is not documented.
- In-memory and network HTTP test harnesses, and end-to-end tests of the API against a real PostgreSQL, including
  concurrent idempotent retries, deep pagination and an unreachable database.
- Settings for the calculation time budget, batch size and concurrency, and the database statement timeout.
- `migrate` service in the Compose stack (the API starts only after it succeeds), plus `make migrate` and
  `make test-contract`.
- `GET /ready`: readiness that depends on the database and its migrations, shares one check between concurrent probes,
  caches the answer for a second, bounds every probe in time and reports "shutting down" at once.
- Event dispatcher that delivers calculation events to subscribers through bounded per-subscriber queues, so an observer
  can never slow a request down.
- Retries of repository calls that failed because the store was unreachable, only where repeating is safe (reads and
  saves that carry an idempotency key), with exponential backoff and full jitter.
- Graceful shutdown: readiness flips when the signal arrives, accepted requests finish before the database pool closes,
  event subscribers drain, and the process exits with status 0. `make smoke-shutdown` verifies it against the real
  executable.
- Architecture decision record for concurrency and lifecycle.
- Structured JSON logs with the request and correlation identifiers added to every line by a task-local metadata
  provider, redaction of secrets and of the parameters of database statements, and an access log per request.
- `GET /metrics` in the Prometheus format: request rate, errors and duration, calculations by module, operation and
  outcome, database calls, retries, dropped events, requests in flight, build information and process resources.
- Error reporting to Sentry without an SDK: only infrastructure and unexpected failures, sampled and folded, carrying no
  caller data, delivered by a bounded background queue and flushed on shutdown.
- Architecture decision record and operations guide for observability.
- Benchmark harness and benchmarks with a warm-up, min, p50, p95, p99, max, mean, throughput and concurrency per
  benchmark: every calculation operation, heavier operations over growing inputs, scaling across concurrency levels,
  serialization, the HTTP stack (in memory and over loopback) and PostgreSQL (the repository and the whole service),
  each with a p99 budget and a JSON artifact.
- `make benchmark`, `make coverage` (a line-coverage floor per source target) and `make test-report` (time per suite
  and the slowest tests), and `Scripts/compare-benchmarks.sh` to compare two benchmark runs.
- Architecture decision record for testing and performance, and the testing and performance guides.

### Changed

- Decoding a request with a large array of numbers is about 25 times faster, and ordering calculation identifiers no
  longer builds strings.
- Rendering a log line is about 30 times faster: redaction inspects keys as bytes instead of lowercasing and splitting
  them.
