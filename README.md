# Borba Scientific Engine

An extensible **scientific calculation engine** exposed as a versioned HTTP API, built with Swift, Vapor and
PostgreSQL.

The project is a Swift engineering laboratory: a modular calculation platform with a pure domain core, strict
layering, typed errors, structured observability, real-database integration tests, a container image and CI/CD.
Everything in the repository — code, comments, documentation and commit messages — is written in English.

> **Status:** under active construction. This README grows with each delivered phase; see the
> [changelog](CHANGELOG.md) for what is available today.

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

`make up` creates `.env` from `.env.example` on first use, builds the image and starts the API and PostgreSQL. Then:

```bash
curl http://localhost:8080/health
```

Stop everything with `make down`. For a native development loop, start only the database and run the API with
SwiftPM:

```bash
make db-up
make run
```

### Configuration

All configuration comes from environment variables, validated at startup. Every problem is reported at once and no
secret is ever printed. See [`.env.example`](.env.example) for the complete, documented list.

| Variable                  | Default                               | Purpose                                         |
| ------------------------- | ------------------------------------- | ----------------------------------------------- |
| `APP_ENV`                 | `development`                         | `development`, `test`, `staging`, `production`  |
| `DATABASE_URL`            | — (required)                          | PostgreSQL connection URL                       |
| `HTTP_HOST` / `HTTP_PORT` | `127.0.0.1` locally, `0.0.0.0` deployed / `8080` | Bind address                         |
| `LOG_LEVEL` / `LOG_FORMAT`| `debug`/`console` locally, `info`/`json` deployed | Logging                             |
| `SENTRY_DSN`              | unset (disabled)                      | Error reporting                                 |

## Developer workflow

`make help` lists every target. The most common ones:

| Command             | Purpose                                              |
| ------------------- | ---------------------------------------------------- |
| `make setup`        | Check the toolchain, create `.env`, resolve packages |
| `make build`        | Compile (debug)                                      |
| `make test`         | Run the test suites                                  |
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
Tests/
  Unit/                    Fast tests with no external services
Documentation/ADR/         Architecture decision records
Scripts/                   Developer and CI helper scripts
```

## License

[MIT](LICENSE)
