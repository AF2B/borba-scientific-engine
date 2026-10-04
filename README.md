# Borba Scientific Engine

An extensible **scientific calculation engine** exposed as a versioned HTTP API, built with Swift, Vapor and
PostgreSQL.

The project is a Swift engineering laboratory: a modular calculation platform with a pure domain core, strict
layering, typed errors, structured observability, real-database integration tests, a container image and CI/CD.
Everything in the repository — code, comments, documentation and commit messages — is written in English.

> **Status:** under active construction. The calculation engine, the PostgreSQL history and the versioned HTTP API are
> in place; observability, performance work and the delivery pipelines are next. This README grows with each delivered
> phase; see the [changelog](CHANGELOG.md) for what is available today.

## Technology

| Concern             | Choice                                                                   |
| ------------------- | ------------------------------------------------------------------------ |
| Language            | Swift 6 (language mode 6, strict concurrency)                            |
| HTTP framework      | Vapor 4.122 — the current stable line (Vapor 5 is still in beta)        |
| Database            | PostgreSQL 18 through Fluent and the PostgreSQL driver                   |
| Tests               | Swift Testing (primary), XCTest where it adds capability                 |
| Packaging           | Swift Package Manager, `Package.resolved` committed                      |
| Container           | Multi-stage Docker image, published to GitHub Container Registry         |
| CI/CD               | GitHub Actions                                                           |
| Error tracking      | Sentry                                                                   |

## Architecture in one picture

```text
HTTP → Handlers → Business → Ports → Adapters → Infrastructure
```

Dependencies only point inward and the boundary is enforced by the SwiftPM target graph. See
[ADR-001](Documentation/ADR/ADR-001-application-architecture.md).

## Calculation modules

The engine ships nine modules, each a self-contained slice with its own domain types, validation, errors and tests.
Every operation carries worked examples that double as executable tests.

| Module           | Covers                                                                                    |
| ---------------- | ----------------------------------------------------------------------------------------- |
| `arithmetic`     | Operators, remainders, powers, aggregates, gcd/lcm, factorial, decimal rounding           |
| `percentage`     | Shares, relative change, markups, discounts, reverse percentages                          |
| `statistics`     | Mean, median, mode, variance, percentiles, quartiles, correlation, linear regression      |
| `financial`      | Interest, time value of money, loans and amortization, NPV, IRR, CAGR, ROI                |
| `scientific`     | Trigonometry, hyperbolics, logarithms, roots, combinatorics, CODATA 2022 constants        |
| `conversion`     | Length, mass, temperature, time, area, volume, speed, pressure, energy, power, data, angle |
| `expression`     | Infix expressions with variables, constants and functions                                 |
| `numerical`      | Integration, differentiation and root finding for expressions                             |
| `linear_algebra` | Vector and matrix arithmetic, determinants, inverses, linear systems                      |

See [ADR-002](Documentation/ADR/ADR-002-domain-oriented-module-structure.md) for the design and
[Adding a calculation module](Documentation/Development/adding-a-calculation-module.md) to extend it.

## HTTP API

A versioned JSON API under `/api/v1`: run a calculation (singly or in batches, with idempotency keys), read the history
with filters and cursor pagination, and discover every operation with its parameters and worked examples. One error
body with stable codes serves every failure, and every response carries request and correlation identifiers.

```bash
curl -s -X POST http://localhost:8080/api/v1/calculations \
  -H 'Content-Type: application/json' \
  -d '{"module": "statistics", "operation": "mean", "parameters": {"values": [1, 2, 3, 4]}}'
```

The guide is in [Documentation/API](Documentation/API/README.md), the contract in
[`openapi.json`](Documentation/API/openapi.json) and the error catalog in [`errors.md`](Documentation/API/errors.md).
The contract tests hold the running API to the document.

## Observability

Three signals with distinct jobs, tied together by the request identifier: **structured JSON logs** that carry the
request and correlation identifiers in every layer (including the database driver), **Prometheus metrics** at
`/metrics` (request rate, errors and duration, calculations, database calls, retries, process resources), and an
**error tracker** (Sentry) that hears only about failures worth a person's attention and never about callers' data.
`/health` is liveness, `/ready` is readiness (database and migrations), `/version` names the build.

See the [observability guide](Documentation/Operations/observability.md) for queries, alerts and runbooks, and
[ADR-006](Documentation/ADR/ADR-006-observability.md) for the reasoning.

## Getting started

### Prerequisites

- Swift 6.2 or newer (developed with 6.4) — <https://www.swift.org/install>
- Docker with the Compose plugin (PostgreSQL and the container image)
- Optional: [SwiftLint](https://github.com/realm/SwiftLint) for `make lint`

### Run it

```bash
git clone <repository-url>
cd borba-scientific-engine
make up
```

`make up` creates `.env` from `.env.example` on first use, builds the image, starts PostgreSQL, applies the migrations
and then starts the API. Then:

```bash
curl http://localhost:8080/health
curl http://localhost:8080/api/v1/types
```

Stop everything with `make down`. For a native development loop, start only the database and run the API with
SwiftPM:

```bash
make run
```

`make run` starts PostgreSQL, applies the migrations and runs the API. The application never migrates on startup:
migrations are an explicit step (`make migrate`, or the `migrate` command of the executable).

### Configuration

All configuration comes from environment variables, validated at startup. Every problem is reported at once and no
secret is ever printed. See [`.env.example`](.env.example) for the complete, documented list.

| Variable                  | Default                               | Purpose                                         |
| ------------------------- | ------------------------------------- | ----------------------------------------------- |
| `APP_ENV`                 | `development`                         | `development`, `test`, `staging`, `production`  |
| `DATABASE_URL`            | — (required)                          | PostgreSQL connection URL                       |
| `HTTP_HOST` / `HTTP_PORT` | `127.0.0.1` locally, `0.0.0.0` deployed / `8080` | Bind address                         |
| `LOG_LEVEL` / `LOG_FORMAT`| `debug`/`console` locally, `info`/`json` deployed | Logging                             |
| `HTTP_MAX_BODY_SIZE_BYTES`| 1 MiB                                 | Largest accepted request body                   |
| `DATABASE_STATEMENT_TIMEOUT_MS` | 5000                            | Longest the server lets one statement run       |
| `CALCULATION_TIMEOUT_MS`  | 2000                                  | Time budget of one calculation                  |
| `BATCH_MAX_SIZE` / `BATCH_CONCURRENCY` | 100 / 8                  | Batch size and how many run at once             |
| `SENTRY_DSN`              | unset (disabled)                      | Error reporting                                 |

## Developer workflow

`make help` lists every target. The most common ones:

| Command             | Purpose                                              |
| ------------------- | ---------------------------------------------------- |
| `make setup`        | Check the toolchain, create `.env`, resolve packages |
| `make build`        | Compile (debug)                                      |
| `make test`         | Run every test suite                                 |
| `make test-unit`    | Fast tests, no services                              |
| `make test-contract`| The HTTP API against the OpenAPI document            |
| `make test-integration` | Tests against a real PostgreSQL                  |
| `make migrate`      | Apply the database migrations locally                |
| `make lint`         | SwiftLint in strict mode                             |
| `make format`       | Format sources with `swift format`                   |
| `make up` / `down`  | Start / stop the Docker Compose stack                |
| `make logs`         | Follow the stack logs                                |
| `make ci`           | Everything the CI pipeline enforces                  |

## Repository layout

```text
Sources/
  BorbaScientificEngine/   Vapor application: configuration, HTTP, composition root
  Run/                     Executable entry point
  BorbaScientificCore/     Pure calculation domain: modules, engine, history, ports, events
  BorbaScientificPersistence/ PostgreSQL adapter: migrations and the repository
Tests/
  Unit/                    Fast tests with no external services
  Contract/                The HTTP API held to the OpenAPI document, over in-memory adapters
  Integration/             Persistence and the HTTP API against a real PostgreSQL
  Support/, HTTPSupport/, IntegrationSupport/   Shared test fixtures and harnesses
Documentation/API/         HTTP guide, OpenAPI document and error catalog
Documentation/ADR/         Architecture decision records
Scripts/                   Developer and CI helper scripts
```

## License

[MIT](LICENSE)
