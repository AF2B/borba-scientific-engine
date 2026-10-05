# Security

What the service defends against, what it assumes about the place it runs, and what it does not do. Read the last two
sections before exposing it to anything you do not control.

> **Status of this document.** It describes the controls that exist in the code and the pipelines, and the limits that are
> known. A line-by-line security review of the source has **not** been completed: treat the lists below as what was
> designed and tested, not as a clean bill of health.

## Assumptions

The service is built to run **behind a gateway or ingress that you operate**. It assumes that gateway:

- **terminates TLS.** The server speaks plain HTTP; nothing in it encrypts traffic;
- **authenticates and authorizes callers.** The API has no notion of a user (see [Not implemented](#not-implemented));
- **rate-limits and sizes requests at the edge**, in front of the limits below;
- **keeps `/metrics` and the database off the public network.** `/metrics` is unauthenticated; the Compose stack publishes
  both PostgreSQL and the API on loopback only.

Secrets (`DATABASE_URL`, `SENTRY_DSN`) come from the environment of the platform's secret store. They are never in the image,
never in the repository (`.env` is ignored, `.env.example` holds placeholders) and never in a log or an error report.

## Controls that exist

| Threat | Control |
|---|---|
| Malformed or hostile input | Every operation declares typed parameters with ranges; a request that does not match is a `400` with the field named. Unknown fields are rejected, not ignored. Bodies are bounded (`HTTP_MAX_BODY_SIZE_BYTES`, 1 MiB by default) |
| Resource exhaustion by one request | Collections are limited to 100,000 numbers, text to 1,000 characters, expressions to 1,000 characters and 64 levels of nesting, integration to 1,000,000 intervals, matrices to 100 × 100, a batch to `BATCH_MAX_SIZE` items with bounded concurrency. Every calculation runs under a time budget (`CALCULATION_TIMEOUT_MS`) and is cancelled when it exceeds it |
| SQL injection | All access goes through Fluent and SQLKit, which bind values; no SQL is built from input. Migrations are fixed SQL. Check constraints back the application's rules at the database |
| Information leaks in errors | One error body for every failure, from a catalog of stable codes. Internal causes, stack traces and database messages never reach a response |
| Secrets and personal data in logs | Keys that name a secret, the bound parameters of database statements and the password of any URL are redacted before a line is written. Client addresses, headers, query strings and bodies are never logged |
| Personal data in error reports | The error tracker receives a code, a classification, the route template and trace identifiers: no parameters, bodies, headers or addresses. Only infrastructure and unexpected failures are reported, sampled and folded |
| Header and log injection | A caller's `X-Request-ID` or `X-Correlation-ID` is adopted only when it is well formed (at most 128 characters of letters, digits and `._:-`); logs are JSON, so a value cannot forge a line |
| Browser-borne attacks on responses | `X-Content-Type-Options: nosniff`, `Referrer-Policy` and `Cache-Control: no-store` on every response |
| Duplicate side effects | Idempotency keys make a retried `POST` return the recorded result; reuse of a key with a different request is refused |
| Compromised process | Non-root numeric user, read-only filesystem, no capabilities, no setuid files, no way to gain privileges, a memory limit (ADR-008) |
| Vulnerable dependencies | Dependencies are locked (`--force-resolved-versions`); the lockfile is audited against OSV on every change and weekly; Dependabot proposes updates |
| Vulnerable image | The image is scanned (fixable HIGH and CRITICAL fail the build) before it is published |
| Committed secrets | The whole git history is scanned on every change |
| Tampered or unofficial images | Images are published with attested provenance; Deploy refuses an image that this repository's Registry pipeline did not build, and deploys by digest |
| Pipeline abuse | Actions pinned by commit, read-only token by default, no `pull_request_target`, event values reach scripts only through the environment (ADR-009) |

Run the checks yourself: `make security` (dependencies, history, Dockerfile) and `make scan-image`.

## Not implemented

These are the gaps a deployment has to fill. None of them is hidden by a default.

- **Authentication and authorization.** Every endpoint is open to whoever can reach it, and the history is shared by all
  callers. Put an authenticating gateway in front, and add per-caller scoping to the history before it serves more than one
  tenant.
- **Rate limiting and quotas.** The per-request limits above bound the cost of one request, not of many. The gateway must
  bound the number.
- **Transport security.** See the assumptions.
- **Retention and erasure.** Calculations are stored with their parameters and results, which are the caller's data, and
  nothing deletes them. A deployment subject to the LGPD needs a retention period and a way to erase a caller's records;
  neither exists yet.
- **Authentication of `/metrics`.** Restrict it by network.
- **Audit log of who did what.** There are no users, so there is nothing to attribute; request and correlation
  identifiers are stored with each calculation.
- **A completed security review.** See the status at the top.

## Reporting a vulnerability

See [`SECURITY.md`](../../SECURITY.md).
