# ADR-006 — Observability

- **Status:** Accepted
- **Date:** 2026-10-04

## Context

Someone on call has to be able to answer, from outside the process and without a debugger: is it up, is it ready for
traffic, what is failing, why, for which request, how slow is it and is it getting worse. The calculation parameters a
caller sends are their data, and the service is meant for settings (health, public sector) where personal data and the
LGPD are real constraints, so the way the service watches itself must not become a way for that data to leak.

## Decisions

### Three signals with distinct jobs

| Signal | Answers | Where |
|---|---|---|
| **Logs** | What happened to *this* request? | Standard output, one JSON object per line |
| **Metrics** | How does the system behave in aggregate? Is it getting worse? | `GET /metrics`, Prometheus format |
| **Error tracker** | What needs a person's attention? | Sentry, only for failures worth a human |

The **request identifier** is the join key between all three: it is on every log line, in every error response and report,
and stored with every calculation. Metrics deliberately carry no identifiers.

### Logging

- **JSON lines**, a fixed set of leading fields (`timestamp`, `level`, `logger`, `message`) followed by flat metadata
  sorted by key. A human format exists for development.
- The **request and correlation identifiers are added by a metadata provider** that reads the task-local trace context, so
  every layer below the HTTP layer — use cases, the repository, even the database driver's own debug lines — carries them
  without any function passing them along. Verified: the SQL statements of a request show its `request_id`.
- **Levels follow the error classification** (ADR-003): expected and application failures are informational; infrastructure
  failures are errors; unexpected failures are critical.
- **One access line per request**, with the route *template* rather than the path, the status, the duration and sizes.
  Probes (`/health`, `/ready`, `/metrics`) log at debug level.
- **What is never logged:** client addresses, headers, query strings and bodies; the parameters of database statements
  (the drivers log them under `binds`); anything under a key that names a secret; the password of any URL, wherever it
  appears in text. Redaction is a safety net behind the rule "do not log secrets", not a substitute for it.

### Metrics

- **swift-metrics** is the facade and **SwiftPrometheus** the backend: the standard pair in the Swift server ecosystem, a
  small dependency, and the only way to expose histograms correctly without reimplementing the format.
- The metrics factory is **passed explicitly**, never installed as process-wide state. That keeps components testable
  against a registry of their own and lets tests run in parallel. The price: Vapor's built-in HTTP metrics, which use the
  global system, are switched off and replaced by an equivalent middleware.
- **Naming** follows the Prometheus conventions (`_total`, `_seconds`, `_bytes`). **Cardinality is bounded by construction**:
  routes are templates and unmatched routes share one series; module and operation names come from the registry; failure
  codes come from the error catalog. No label is ever an identifier, a path, a parameter or a message.
- **What is measured:** request rate, errors and duration (RED); calculations by module, operation and outcome, their
  durations and failure codes — recorded from events, outside the request; every database call, measured under the retry
  decorator so that each attempt counts; retries; dropped events; error-report outcomes; requests in flight; build
  information; process memory, CPU and file descriptors, read at scrape time.
- `/metrics` is unversioned and exposes operational detail: it belongs behind the network boundary, like `/ready`.

### Error tracking

- **Only what deserves a person.** Expected domain failures and application decisions are never reported: a caller dividing
  by zero is not an incident. Infrastructure failures are reported, sampled; unexpected failures are always reported.
- **Identical failures are folded.** An outage makes every request fail the same way, so the first failure of a kind (code
  and route) is sent at once, the identical ones that follow within a minute are counted, and the next report says how many
  were folded. A global limit bounds the total per window. This protects the tracker's quota and the signal.
- **Minimal by construction.** A report carries a stable code, the route template, the status, the classification and the
  request identifiers. It has no parameters, bodies, headers, query strings, client or database addresses. Infrastructure
  failures add a driver-level diagnostic, masked and capped; unexpected failures never do, because their reason could
  contain anything. A test pins the exact set of fields so an addition cannot slip in unnoticed.
- **Never in the way.** Reporting hands the failure to a bounded queue and returns. One task delivers, each delivery has its
  own time limit and the HTTP client's connect timeout is bounded, so an unreachable tracker costs a counter
  (`error_reports_total{outcome="failed"}`), not a request. Pending reports are flushed on shutdown.
- **No SDK.** Sentry's SDKs do not support Linux for Swift. The envelope is a small, documented format, so the service
  writes it and posts it with Vapor's client. That is about 200 lines the project owns instead of a dependency it cannot
  use, and it is tested over a real HTTP connection against a stand-in tracker.

### Health model

| Endpoint | Meaning | Depends on the database |
|---|---|---|
| `GET /health` | The process is alive | No: an outage must not restart the process |
| `GET /ready` | Send me traffic | Yes: it and its migrations, plus shutdown state |
| `GET /version` | Which build | No |
| `GET /metrics` | Aggregate behaviour | No |

### Not done, and why

- **Distributed tracing (OpenTelemetry).** The request and correlation identifiers tie a request together across logs,
  error reports and the stored calculation inside this service, and a caller can supply its own correlation identifier.
  Tracing earns its cost when a request crosses several services; this one makes no downstream calls except to the
  tracker. It is the natural next step when that changes.
- **Dashboards and alert rules as code.** The operations guide lists the queries and thresholds worth starting from; the
  rules themselves belong to whoever runs the Prometheus.
- **Log shipping.** The service writes to standard output and leaves collection to the platform, as a container should.

## Consequences

- An operator can follow one request from an access line to its SQL statements to its stored record to its error report
  with a single identifier, and can see a rollout, an outage or a leak on a dashboard.
- Nothing about a caller's data leaves the process through logs, metrics or reports, and tests enforce the rules that
  guarantee it.
- Observability costs requests nothing: logs are a handful of formatted lines, metrics are counters, reports and events are
  queued.
- The service owns a small Sentry client and a small metrics middleware that a larger dependency would otherwise provide.

## Alternatives considered

- **Bootstrapping the global metrics system.** Simpler wiring, but global state that tests cannot isolate.
- **The Sentry SDK.** Not available for Swift on Linux.
- **Reporting every error.** Floods the tracker and buries the incidents that matter.
- **Text logs.** Cheaper to read in a terminal, much harder to query; the development format covers that need.
