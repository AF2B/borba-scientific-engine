# ADR-003 — Error Handling Strategy

- **Status:** Accepted
- **Date:** 2026-10-03

## Context

A calculation service fails in very different ways. A user dividing by zero is normal operation; a database outage is an
incident; a bug in an operation is a defect. Treating them alike either floods the error tracker with noise or hides
real problems, and a single `catch` that returns HTTP 500 hides the difference from API consumers too.

## Decision

### Four classes of failure

Every error maps to an `ErrorClassification`, which decides how it is logged, counted and reported:

| Class            | Meaning                                              | Examples                                           | Reported to Sentry |
| ---------------- | ---------------------------------------------------- | -------------------------------------------------- | ------------------ |
| `expectedDomain` | Well-formed request that cannot be computed          | division by zero, `ln(-1)`, invalid expression     | no                 |
| `application`    | The application declined or aborted for a good reason| not found, idempotency conflict, time budget       | no                 |
| `infrastructure` | A dependency failed                                  | PostgreSQL unreachable, query timeout              | yes, rate limited  |
| `unexpected`     | A programming error or an unforeseen failure         | an operation throws a non-domain error             | yes                |

### Failures are typed values

- Domain code throws **typed errors** (`throws(StatisticsError)`, `throws(DivisionByZeroError)`). The compiler checks
  that call sites handle them exhaustively, and tests assert on specific cases.
- Each module error conforms to `CalculationFailure` and maps itself to the cross-cutting `CalculationError`, which
  carries a stable `ErrorCode`, a message that is safe to show, and structured `details`. The mapping is one `switch`
  per module, so a new failure mode cannot be forgotten.
- The engine converts whatever an operation throws into a `CalculationError` in one place. Anything that is not a known
  failure becomes `internalFailure` and its description is never shown to the caller.
- Infrastructure failures use a separate `RepositoryError`, so a database problem can never be mistaken for a
  calculation problem.

### Domain failures are results, not exceptions

A calculation that runs and fails is a *recorded outcome* (`CalculationOutcome.failed`), persisted in the history and
announced by a `CalculationFailed` event. `CalculationService.execute` throws `ExecutionFailure` only when nothing was
recorded: the request was refused before running, it was cancelled, it hit a defect, or storage failed. The HTTP layer
maps outcomes to `422` and `ExecutionFailure` cases to `400`, `404`, `409`, `499`, `500` or `503`.

### Stable codes and safe messages

Error codes (`DIVISION_BY_ZERO`, `INVALID_EXPRESSION`, …) are an open, documented set and part of the API contract.
Messages never contain stack traces, SQL, hostnames or credentials; technical detail lives in a separate `diagnostic`
that goes to logs and the error tracker only.

## Consequences

- Sentry shows incidents, not user mistakes, and dashboards can alert on infrastructure failures separately.
- Adding a module means adding a typed error enum and its mapping; an exhaustive `switch` enforces completeness.
- Typed throws do not infer through closures in Swift 6, so a few call sites use small helper functions with explicit
  error types instead of `do`/`catch` inside closures.

## Alternatives considered

- **Untyped `throws` everywhere.** Simplest, but call sites cannot know what to handle and tests cannot assert on cases.
- **`Result` for everything.** Explicit, but verbose in `async` code and it fights `?`-style propagation that typed
  throws provide.
- **One large `AppError` enum for the whole system.** Couples the domain to HTTP and persistence concerns.
