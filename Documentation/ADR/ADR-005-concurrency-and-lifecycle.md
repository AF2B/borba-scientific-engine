# ADR-005 — Concurrency and Lifecycle

- **Status:** Accepted
- **Date:** 2026-10-04

## Context

Each request does CPU-bound work, talks to PostgreSQL and produces events. Orchestrators probe the service constantly and
stop it with signals. The concurrency decisions have to answer four questions: what runs in parallel and why, how shared
state is protected, how the service behaves when a dependency struggles, and how it stops without dropping work it has
already accepted.

## Decisions

### Where concurrency is used

| Concern | Mechanism | Why it is not simpler |
|---|---|---|
| Request handling | `async`/`await` on Vapor's event loops | The framework's model. |
| A calculation's time budget | Race between the work and a watchdog on the injected clock | A time limit has to fire while the work is running. The budget is cooperative: operations call a checkpoint in loops. |
| Batches | A task group that keeps at most `BATCH_CONCURRENCY` calculations in flight | Unbounded fan-out would exhaust the database pool. |
| Expression compile cache | An `actor` (ADR-002) | Shared mutable cache with composite operations. |
| Event delivery | An `actor` with one bounded `AsyncStream` and one task per subscriber | See "Events". |
| Readiness | An `actor` with single-flight and a short-lived cache | See "Readiness". |
| Shutdown flag, in-flight counter | `Mutex` | See "Actor or lock". |

Concurrency is not decoration here: every row is a problem that appears the moment the service has more than one request.

### Actor or lock

An `actor` where the state is shared **and** the operations are asynchronous or composite (the dispatcher's queues, the
readiness cache and the check in flight). A `Mutex` where the state is a flag or a counter that is touched on every
request or read from synchronous code: the shutdown flag, the in-flight counter, the one-shot flag of a race. An actor
there would add a suspension to every request for nothing, and make a flag that readiness reads synchronously
asynchronous.

### Events

`EventDispatcher` hands each published event to every subscriber without waiting. A subscriber has its own bounded queue
and its own task, so:

- a slow subscriber delays neither the request that published nor the other subscribers;
- a subscriber that falls behind loses its **oldest** events, and the drop is counted and logged (the first one, then
  every thousandth) — never silent, never back-pressure on requests and never unbounded memory;
- each subscriber sees events in publication order.

Delivery is **in-process and at most once**. That is the right strength for observers — logs, metrics, alerts — because
the calculation is already stored when its event is published, so losing an event never loses data. A consumer that
needed guaranteed delivery would need a transactional outbox in the database; this service has no such consumer, so it
does not build one. Subscribers cannot throw and cannot fail a request. On shutdown the dispatcher stops accepting
events and gives the subscribers a bounded time to deliver what is queued.

### Time limits: a race, not a task group

A task group always waits for **every** child before it returns. A time limit written as "run the work and a timer in a
group, take the first result" therefore does not limit anything when the work ignores cancellation — a database query,
for instance — because the group cannot return until the work does. `Race.firstToFinish` returns as soon as one
contender finishes and cancels the other. The price is explicit: a loser that ignores cancellation is left to finish on
its own, so contenders must be bounded by their own timeouts (the database has a statement timeout and a pool timeout).
The engine's calculation budget stays a task group because calculations are cooperative by construction.

### Retries

`RetryingCalculationRepository` repeats a failed call only when repeating is safe:

- reads are always safe;
- a save **with** an idempotency claim is safe, because if the first attempt committed before the connection dropped, the
  repeat finds the key bound and returns the stored record — exactly what a retry of an idempotent request should do;
- a save **without** a claim is attempted once: after an ambiguous failure it could store the calculation twice.

Only an unreachable store is retried. A statement that timed out already spent its budget, and trying again would double
the pressure on a server that is struggling; every other failure will not go away by itself. Waits grow geometrically up
to a cap and use full jitter, so requests that failed together do not return together. Three attempts in all.

A circuit breaker was considered and rejected for now. With one dependency and a pool that already fails fast, a breaker
adds state and tuning without a clear gain; it becomes worthwhile when the service has several dependencies whose
failures should not cascade.

### Readiness is not liveness

`/health` never touches the database: a database outage must not get the process restarted. `/ready` does: an instance
that cannot reach the database, or whose schema is behind the code, must be taken out of rotation instead.

Probes run often, from several places, and exactly when a dependency is struggling, so each probe must not cost a
database round trip. `ReadinessService` therefore **coalesces** concurrent probes into one check (single flight),
**remembers** the answer for a second, **bounds** every check in time so an unresponsive dependency is reported down
instead of hanging, and answers "shutting down" immediately without consulting the cache. The details of a failing check
come from a fixed vocabulary and never contain a host name or an error text.

### Graceful shutdown

On `SIGTERM` or `SIGINT`:

1. A watcher marks the process as shutting down at once, so `/ready` answers 503 while the listener is still draining.
2. Vapor closes the listener. Requests already accepted keep running.
3. `ShutdownSequence` waits, up to `SHUTDOWN_TIMEOUT_SECONDS`, until every accepted request has been answered.
4. The event subscribers get up to five seconds to deliver what is queued.
5. Only then does Vapor close the database pool and exit with status 0.

Step 3 exists because of something the first implementation got wrong. Vapor closes the listener and then shuts the
application down, which closes the database pool — **while accepted requests are still running**. Measured with four
slow calculations in flight when `SIGTERM` arrived, all four failed with 503 because the pool vanished under them. An
in-flight counter, kept by the outermost middleware, lets the sequence hold the pool open until the requests are done.
`Scripts/smoke-graceful-shutdown.sh` reproduces the scenario against the real executable and fails on any request that
is dropped.

An orchestrator's termination grace period must exceed the shutdown timeout plus the event drain, with some margin.

### Cancellation

Cancelling a task cancels the calculation it runs, which reports `CALCULATION_CANCELLED` and is not recorded. A client
that disconnects does not cancel its request: Vapor does not propagate disconnects to handler tasks, so the work finishes
and is recorded. That is a known limitation, acceptable because calculations are short and budgeted.

## Consequences

- A request never waits for an observer, and a struggling observer costs a counter and a log line, not latency.
- Observers can miss events under sustained overload. That is visible in logs and counters and is the price of never
  slowing a request down.
- Retries can hide a brief database blip from clients, at the cost of a few hundred milliseconds when it happens.
- Shutdown takes as long as the slowest accepted request, up to the configured timeout.
- Several small lock-based types exist next to the actors. Each is a flag or a counter with a one-line reason to be one.

## Alternatives considered

- **Awaiting subscribers inside the request.** Simple, and wrong: an observer's latency becomes the caller's.
- **An external broker or an outbox.** Delivery guarantees nobody asked for, and a new moving part to operate.
- **Retrying every repository failure.** Would double-store non-idempotent saves and amplify load during timeouts.
- **A task group for time limits.** Does not limit anything when the work ignores cancellation.
- **Letting Vapor shut down on its own.** It closes the database under requests that are still running.
