# Dependencies

What the project builds on, why each piece is there, and the rules for adding another. Fourteen packages are declared
directly; the lockfile holds thirty-six, **every one of them MIT or Apache-2.0**, which is compatible with the project's own
MIT license.

## Direct dependencies

| Package | Used for | Where |
|---|---|---|
| `vapor` | The HTTP server, routing and middleware, and the HTTP client the error reporter sends with | Engine |
| `fluent`, `fluent-kit`, `fluent-postgres-driver` | The database abstraction and the PostgreSQL driver's integration, through which SQL is built with bound values | Persistence, Engine |
| `postgres-nio`, `postgres-kit`, `sql-kit`, `async-kit` | The PostgreSQL wire protocol, its configuration, the SQL builder and the connection pool | Persistence |
| `swift-nio` | Event loops, byte buffers and time amounts | Persistence, Engine, test harnesses |
| `swift-log` | The logging API, whose metadata providers carry the request identifiers into every layer; its in-memory handler is how tests read logs | Everywhere |
| `swift-metrics`, `SwiftPrometheus` | The metrics API and its Prometheus exposition, behind an explicit factory so that no global metrics system is bootstrapped | Engine |
| `swift-crypto` | SHA-256, for the fingerprint that ties an idempotency key to the request it first carried | Engine |
| `async-http-client` | The client that delivers error reports, and the `healthcheck` command's probe. It arrives through Vapor too, at the same version; it is declared because the code imports it | Engine |

What is deliberately **not** here: a Sentry SDK (there is none for Linux; the reports are hand-written envelopes, ADR-006),
an authentication or JWT library (the API has none, see the [security guide](../Operations/security.md)), a cache or a
message broker (nothing needs one).

## Rules

- **A new dependency needs a reason in an ADR or in the pull request that adds it**, and a minimum version that is the one
  it was tried with. It is declared in the manifest by the target that imports it, and only by that target.
- **Builds use the lockfile exactly** (`--force-resolved-versions`), and the Build pipeline fails if resolving would change it.
- **Every locked package is audited** against the OSV database on each change and weekly, and Dependabot proposes updates
  weekly, grouped, for the pipelines to verify.
- **A declaration nothing imports is removed.** The last review removed eleven: products declared by a target whose sources
  never import them.

## How to check

```bash
make audit                                  # known vulnerabilities in the locked versions
swift package show-dependencies             # the whole tree
```
