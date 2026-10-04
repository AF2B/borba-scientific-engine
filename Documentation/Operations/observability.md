# Observability guide

How to see what the service is doing, and what to look at when something is wrong. The reasoning behind it is in
[ADR-006](../ADR/ADR-006-observability.md); the health endpoints are in [`openapi.json`](../API/openapi.json).

## Where to look

| Question | Look at |
|---|---|
| Is the process alive? | `GET /health` — never depends on the database, so a failure means restart it |
| Should it get traffic? | `GET /ready` — database reachable, every migration applied, not shutting down |
| Which build is running? | `GET /version`, or `build_info` in the metrics |
| Is it getting slower or failing more? | Metrics: `http_request_duration_seconds`, `http_requests_total` |
| What happened to one request? | Logs, by `request_id` |
| What needs a human? | Sentry: infrastructure and unexpected failures only |
| What did a caller ask for, and what came back? | The calculation history: `GET /api/v1/calculations/{id}` |

## Following one request

Every response carries `X-Request-ID` (and every error body carries `request_id`). Send your own `X-Request-ID` or
`X-Correlation-ID` to tie our logs to yours.

```bash
# every line of the request, from the access line to its SQL statements
docker compose logs --no-log-prefix app | jq -c 'select(.request_id == "0192e4a1-7c3b-7d2e-8f4a-5b6c7d8e9f01")'

# everything that belongs to one logical operation, across requests
docker compose logs --no-log-prefix app | jq -c 'select(.correlation_id == "order-8841")'
```

The calculation itself is stored with the same identifiers:

```sql
SELECT id, module, operation, status, error_code, execution_time_ns, created_at
FROM calculations WHERE request_id = '0192e4a1-7c3b-7d2e-8f4a-5b6c7d8e9f01';
```

A Sentry report carries the `request_id` in its `request` context, which leads to the logs and to the record.

## Logs

One JSON object per line on standard output. Fixed leading fields: `timestamp`, `level`, `logger`, `message`; the rest is
flat metadata sorted by key. Locally (`LOG_FORMAT=console`) the same events are printed in a human-readable form.

```bash
# failed requests, with their codes
docker compose logs --no-log-prefix app | jq -c 'select(.message == "Request failed") | {request_id, error_code, status}'

# slow requests
docker compose logs --no-log-prefix app | jq -c 'select(.message == "Request completed" and .duration_ms > 500)'

# one calculation's life: requested, then completed or failed (debug level)
docker compose logs --no-log-prefix app | jq -c 'select(.calculation_id == "…")'
```

| Level | What is logged there |
|---|---|
| `critical` | Unexpected failures: defects in the engine |
| `error` | Infrastructure failures: the database is unreachable, a statement failed |
| `warning` | A subscriber cannot keep up, shutdown hit its deadline, an error report could not be delivered |
| `info` | One line per request; expected failures (a division by zero, an invalid parameter) |
| `debug` | Probes, calculation events, SQL statements — without their parameters |

**Never logged:** client addresses, headers, query strings, request bodies, the parameters of database statements, secrets
(redacted by key name) and the password of any URL.

## Metrics

`GET /metrics`, Prometheus text format. Keep it behind the network boundary.

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `http_requests_total` | counter | `method`, `route`, `status` | Requests served. `route` is a template; unknown paths share `unmatched` |
| `http_request_errors_total` | counter | same | Requests answered with a 5xx |
| `http_request_duration_seconds` | histogram | same | Time to produce the response |
| `http_requests_in_flight` | gauge | — | Requests being served right now |
| `calculations_total` | counter | `module`, `operation`, `status` | Calculations that ended: `succeeded`, `failed` or `suppressed` (a lost idempotency race) |
| `calculation_duration_seconds` | histogram | `module`, `operation` | Time spent computing |
| `calculation_failures_total` | counter | `code`, `classification` | Why calculations failed |
| `database_operation_duration_seconds` | histogram | `operation` | `save`, `record`, `find`, `list` — each attempt counts |
| `database_failures_total` | counter | `operation`, `kind` | `unavailable`, `timeout`, `integrity`, `corrupted`, `unexpected` |
| `repository_retries_total` | counter | `operation` | Calls repeated after the database was unreachable |
| `events_dropped_total` | counter | `subscriber` | Events a subscriber missed because it could not keep up |
| `error_reports_total` | counter | `outcome` | `sent`, `sampled`, `throttled`, `dropped`, `failed` |
| `build_info` | gauge | `version`, `commit`, `environment` | Always 1; shows the running build |
| `process_start_time_seconds` | gauge | — | When the process started; changes on restart |
| `process_resident_memory_bytes`, `process_cpu_seconds_total`, `process_open_fds` | gauge / counter | — | Resource use, read at scrape time (Linux) |

### Alerts worth starting from

Thresholds depend on the traffic; these are starting points, not rules.

```promql
# availability: share of requests answered with a 5xx
sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m])) > 0.01

# latency: p95 per route
histogram_quantile(0.95, sum by (le, route) (rate(http_request_duration_seconds_bucket[5m]))) > 0.5

# the database
sum by (operation, kind) (rate(database_failures_total[5m])) > 0
histogram_quantile(0.99, sum by (le, operation) (rate(database_operation_duration_seconds_bucket[5m]))) > 0.25
increase(repository_retries_total[5m]) > 10

# the engine: calculations timing out, by operation
sum by (module, operation) (rate(calculation_failures_total{code="CALCULATION_TIMEOUT"}[5m])) > 0

# observers falling behind, and the error tracker not receiving
increase(events_dropped_total[5m]) > 0
increase(error_reports_total{outcome="failed"}[15m]) > 0

# restarts, a rollout in progress, and slow leaks
changes(process_start_time_seconds[1h]) > 0
count by (version) (build_info)
deriv(process_resident_memory_bytes[1h]) > 0
```

For readiness, let the orchestrator probe `/ready` and alert on pods that stay unready.

## Error tracking

Set `SENTRY_DSN` to enable it. Sentry receives a failure only when it is an **infrastructure failure** (sampled by
`SENTRY_SAMPLE_RATE`) or an **unexpected failure** (always). Identical failures — same code, same route — are folded
for a minute, and the next report says how many were folded, so an outage creates a handful of reports, not thousands.

A report contains: the error code, the route template, the HTTP method and status, the classification, the release and
environment, the request and correlation identifiers, and — for infrastructure failures only — a driver-level
diagnostic, masked and truncated. It never contains request parameters, bodies, headers, query strings, client
addresses or the database's address.

Reports are queued and sent by a background task; delivery problems show up as `error_reports_total{outcome="failed"}`
and never affect a request.

## When something is wrong

### `/ready` answers 503

The body names the check and why: `{"checks": [{"name": "database", "status": "down", "detail": "…"}]}`.

| Detail | Meaning | What to do |
|---|---|---|
| `unreachable` | The database does not answer | Check the database and the network; the logs hold the driver's reason at `error` level |
| `migrations pending` | The schema is behind the code | Run `make migrate` (or the `migrate` command, or the Compose `migrate` service) |
| `timed out` | The check itself did not finish in time | The database is answering far too slowly; see the database latency metrics |
| `shutting down` | The process received a termination signal | Nothing: it is draining and will exit |

### `STORAGE_UNAVAILABLE` or `STORAGE_FAILURE` in responses

`database_failures_total` shows the `kind` and the `operation`. `unavailable` is a connection problem (also look at
`repository_retries_total`, which shows the service trying again); `timeout` is a statement that ran past
`DATABASE_STATEMENT_TIMEOUT_MS`, which usually means the database is overloaded; `integrity`, `corrupted` and
`unexpected` are defects: take the `request_id` from the response and read the `error` line in the logs.

### `CALCULATION_TIMEOUT` is rising

`calculation_failures_total{code="CALCULATION_TIMEOUT"}` and `calculation_duration_seconds` by `operation` show which
operation is too slow for its budget. Either callers are sending larger inputs than expected or the host is starved;
`CALCULATION_TIMEOUT_MS` raises the budget.

### Events are dropped

`events_dropped_total{subscriber}` counts events a subscriber missed. Calculations are unaffected: they are stored before
their event is published. Dropped events mean some metrics under-count; look for what slows the subscriber down.

### Sentry does not receive reports

Look at `error_reports_total` by `outcome`: `sampled` and `throttled` are by design; `failed` means the tracker could not
be reached or refused the report (a `warning` in the logs says which); `dropped` means failures arrive faster than they
can be sent.

## Configuration

| Variable | Default | Effect |
|---|---|---|
| `LOG_LEVEL` | `debug` locally, `info` deployed | Minimum level written |
| `LOG_FORMAT` | `console` locally, `json` deployed | Output format |
| `SENTRY_DSN` | unset (disabled) | Where error reports go; validated at startup |
| `SENTRY_SAMPLE_RATE` | `1.0` | Fraction of infrastructure failures that is reported |
| `SHUTDOWN_TIMEOUT_SECONDS` | `15` | How long accepted requests get to finish when the process is told to stop |

The orchestrator's termination grace period must exceed the shutdown timeout plus about seven seconds, for the event
subscribers and the error reports to drain.
