# CONTEXT.md

## Domain overview

Borba Scientific Engine runs named calculations (arithmetic, percentages, statistics, finance, scientific functions, unit
conversion, expressions, numerical methods and linear algebra) for API callers, and keeps a durable, queryable history of
every calculation it ran, successful or not. A calculation is a typed request (module, operation, parameters) that yields a
value or a typed failure; the history is what makes results auditable and retries idempotent.

The system doubles as a laboratory for production-grade Swift backend practice (layering, typed errors, observability,
containerized delivery), so most decisions are recorded as ADRs in `Documentation/ADR`. Read those before changing a
contract between components.

## Bounded Contexts

### Calculation kernel
- Responsibility: turn a raw request into a validated, time-bounded computation and a typed outcome, with no framework involved.
- Main namespaces: `Sources/BorbaScientificCore/Calculation` (engine, module registry, operation definitions),
  `Calculation/Parameters` (typed parameter declarations and bounds), `Calculation/Numerics`, `Errors`.
- Contract types: `CalculationModule`, `OperationDefinition`, `ParameterDeclaration` / `ParameterSpec`, `CalculationValue`,
  `CalculationFailure`, `CalculationRequest` / `CalculationRun`.

### Calculation modules (nine)
- Responsibility: one self-contained slice per domain: arithmetic, percentage, statistics, financial, scientific,
  conversion, expression, numerical, linear algebra.
- Main namespaces: `Sources/BorbaScientificCore/Modules/<Module>`; each has a `<Module>Module.swift` that declares its
  operations, parameters and worked examples, next to its pure functions and errors.
- Contract types: every operation carries examples that double as executable tests and as the documentation the API serves.

### History and orchestration
- Responsibility: run a calculation through the engine, record the outcome, honour idempotency keys, publish domain events
  and run batches with bounded concurrency.
- Main namespaces: `Core/Application` (`CalculationService`, `CalculationHistory`), `Core/History` (`CalculationRecord`,
  pagination, `TraceContext`), `Core/Events`.
- Contract types: `CalculationRepository` and `EventPublisher` (ports), `EngineClock`, `IdentifierGenerator`, `RepositoryError`.

### Persistence
- Responsibility: store the history in PostgreSQL: versioned migrations, check constraints, indexes, atomic idempotency
  claims, keyset pagination and the database health probe.
- Main namespaces: `Sources/BorbaScientificPersistence` (`FluentCalculationRepository`, `Migrations`, `CalculationRow`,
  `RepositoryErrorMapping`, `DatabaseHealth`, `PostgresSettings`).
- Contract types: implements `CalculationRepository`; the repository contract suite is shared with the in-memory test double.

### HTTP API
- Responsibility: the versioned JSON API (single and batch calculations, history, discovery, operational endpoints), one
  error envelope with stable codes, request and correlation identifiers, security headers.
- Main namespaces: `Sources/BorbaScientificEngine/HTTP/{Calculations, History, Catalog, Operational, Context, Errors, Security, Support}`.
- Contract types: `Documentation/API/openapi.json`, held to the running API by contract tests, and `Documentation/API/errors.md`.

### Runtime operations
- Responsibility: configuration, the composition root, readiness and graceful shutdown, event dispatch, retries, logs,
  metrics, error reports, and the `healthcheck` command.
- Main namespaces: `Engine/Configuration`, `Engine/Application` (`ApplicationFactory`, `LiveServices`, `Entrypoint`,
  `HealthProbe`), `Engine/Lifecycle`, `Engine/Events`, `Engine/Resilience`, `Engine/Observability`.
- Contract types: `ReadinessProbe`, `ErrorReporter`, `EventSubscriber`.

## Architecture and layers
- `BorbaScientificCore`: the pure domain. Foundation only; architecture tests fail the build otherwise.
- `BorbaScientificPersistence`: the PostgreSQL adapter; knows Core, Fluent and PostgresNIO.
- `BorbaScientificEngine`: the Vapor application: HTTP, runtime concerns and the composition root.
- `Run`: `main.swift`, the process entry point.
- `Tests/`: `Unit`, `Contract` (API against OpenAPI, in-memory adapters), `Integration` (real PostgreSQL),
  `Performance` (benchmarks), plus shared harness targets.

Dependency rule: `Run` → `Engine` → `Persistence` → `Core`, never the reverse. Inside a request:
HTTP → handlers → `CalculationService` → ports ← adapters; frameworks reach Core only as implementations of its ports, and
`LiveServices.assemble` / `ApplicationFactory.configure` are the only places that know both sides.

## Data flow
1. Middleware assigns or adopts the request and correlation identifiers, counts the request as in flight, sets security
   headers; afterwards it writes the access log and metrics.
2. The handler decodes the body strictly (unknown fields are an error) and validates parameters against the operation's
   declaration.
3. `CalculationService` claims the idempotency key if there is one, runs the engine under its time budget, records the
   outcome through `CalculationRepository` and publishes an event.
4. The repository writes the calculation with its trace identifiers in one transaction.
5. The response is the resource, or the error envelope. A calculation that failed for its input is recorded and answered
   with `422` and its identifier.

## External dependencies
- PostgreSQL 18: used by Persistence for the history; reached through Fluent and SQLKit; migrations are applied explicitly.
- Sentry: used by Runtime operations for error reports; hand-written envelope over HTTPS; optional (`SENTRY_DSN`).
- Prometheus: scrapes `/metrics`; the metrics live in Runtime operations.
- GitHub Actions and the GitHub Container Registry: delivery pipelines and image publication.
- Deployment platform: `<a confirmar>`: none is configured; one provider exists for a Docker host running Compose.

## Relevant decisions
- The core is framework-free and failure is a value: typed errors with stable codes; only the HTTP edge maps them to statuses (ADR-003).
- Time budgets are cooperative: loops whose cost grows with input call `Cooperation.checkpoint`; limits on every parameter
  keep the rest bounded. Hostile-input tests enforce both for every operation.
- Idempotency keys are bound to a SHA-256 fingerprint of the request; reuse with a different request is refused.
- Pagination is keyset-based with an opaque cursor that is validated as input: a forged one once crashed the service.
- What the database cannot hold is refused at the edge: no NUL in text or field names (`CalculationValue` decoding), history
  filters must be names, cursors name instants in the years 0001-9999. A hostile-request corpus runs against PostgreSQL too,
  because a test double accepts what the database refuses.
- Liveness (`/health`) and readiness (`/ready`) are separate; the container health check asks liveness only (ADR-008).
- Migrations are forward-only and must keep the previous release working, because a rollback puts it back (ADR-009).
- The API has no authentication, rate limiting or TLS by design: it is meant to run behind a gateway (security guide).
