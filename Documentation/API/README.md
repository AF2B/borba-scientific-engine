# HTTP API

The engine exposes a versioned JSON API. This guide explains the conventions and shows the common calls; the exact
contract is [`openapi.json`](openapi.json) (OpenAPI 3.1) and every error is listed in [`errors.md`](errors.md).

The specification is not decoration: the contract tests drive the running API and fail when a response, a header, a
status or an error code differs from the document, and when a route exists without being documented.

## Conventions

| Topic | Rule |
|---|---|
| Versioning | Business endpoints live under `/api/v1`. Within a major version changes are additive (new endpoints, new optional fields, new error codes). Anything else ships as `/api/v2`. |
| Content type | Bodies are `application/json`. Field names are `snake_case`. Keys in responses are sorted, so the same value always produces the same bytes. |
| Timestamps | ISO 8601 in UTC with millisecond precision: `2026-10-03T12:00:00.123Z`. |
| Numbers | JSON numbers, read as IEEE 754 doubles. Financial operations also accept decimal amounts written as text, for exactness. |
| Identifiers | Calculations are identified by time-ordered UUIDs (version 7). |
| Request identity | Every response carries `X-Request-ID` and `X-Correlation-ID`. Send your own (1 to 128 letters, digits or `-_.:`) to tie our logs to yours; otherwise they are generated. |
| Caching | Nothing is cacheable (`Cache-Control: no-store`). |
| Errors | One body for every error, with a stable `code`. See [`errors.md`](errors.md). |

## Endpoints

| Method and path | Purpose |
|---|---|
| `POST /api/v1/calculations` | Run one calculation and record it. |
| `POST /api/v1/calculations/batch` | Run many calculations concurrently and report each one. |
| `GET /api/v1/calculations` | List the history, newest first, with filters and a cursor. |
| `GET /api/v1/calculations/{id}` | Read one recorded calculation. |
| `GET /api/v1/modules` | The modules and their operations. |
| `GET /api/v1/types` | Every supported calculation type, flat. |
| `GET /api/v1/types/{module}/{operation}` | Parameters (with constraints and defaults), result shape and worked examples of one operation. |
| `GET /health` | Liveness. Never touches the database. |
| `GET /version` | The running build. |

## Running a calculation

```bash
curl -s -X POST http://localhost:8080/api/v1/calculations \
  -H 'Content-Type: application/json' \
  -d '{"module": "arithmetic", "operation": "add", "parameters": {"a": 2, "b": 3}}'
```

```json
{
  "correlation_id": "0192e4a1-7c3b-7d2e-8f4a-5b6c7d8e9f01",
  "created_at": "2026-10-03T12:00:00.123Z",
  "execution_time_ms": 0.147,
  "id": "0192e4a1-7c4a-7b21-9c1e-2f3a4b5c6d7e",
  "module": "arithmetic",
  "operation": "add",
  "parameters": { "a": 2, "b": 3 },
  "request_id": "0192e4a1-7c3b-7d2e-8f4a-5b6c7d8e9f01",
  "result": 5,
  "status": "succeeded"
}
```

The answer is `201 Created` with a `Location` header. Discover what each operation takes with
`GET /api/v1/types/{module}/{operation}`; its worked examples are executed by the engine's own tests, so they are
always correct.

### When a calculation fails

A request that cannot be computed is answered with an error. If it was refused before it ran (unknown operation,
invalid parameters) nothing is recorded. If it ran and failed, it is recorded and the error carries its
`calculation_id`:

```bash
curl -s -X POST http://localhost:8080/api/v1/calculations \
  -H 'Content-Type: application/json' \
  -d '{"module": "arithmetic", "operation": "divide", "parameters": {"dividend": 1, "divisor": 0}}'
```

```json
{
  "error": {
    "calculation_id": "0192e4a1-7c4b-7a3d-8e6f-1a2b3c4d5e6f",
    "code": "DIVISION_BY_ZERO",
    "message": "Division by zero is undefined: the divisor must not be zero.",
    "request_id": "0192e4a1-7c4b-7406-a4bf-1c46b641f1dc"
  }
}
```

(`422 Unprocessable Content`.) Failed calculations stay in the history: `GET /api/v1/calculations?status=failed`.

## Retrying safely

Send an `Idempotency-Key` (any 1 to 255 visible ASCII characters, typically a UUID) and the request can be repeated
without effect:

- The first request is computed and recorded, and answered with `201`.
- An identical request with the same key is answered from the record with `200` and `Idempotent-Replayed: true`. Nothing
  runs again.
- A different request with the same key is refused with `IDEMPOTENCY_KEY_REUSED`.
- Concurrent retries converge on one record: exactly one wins and the others return its result.

"Identical" is about meaning, not spelling: key order, whitespace and `1` versus `1.0` do not matter.

## Batches

```bash
curl -s -X POST http://localhost:8080/api/v1/calculations/batch \
  -H 'Content-Type: application/json' \
  -d '{"calculations": [
        {"module": "arithmetic", "operation": "add", "parameters": {"a": 1, "b": 2}},
        {"module": "arithmetic", "operation": "divide", "parameters": {"dividend": 1, "divisor": 0}}
      ]}'
```

The batch is answered with `200` whenever it was understood. Results come back in request order, each with either a
`calculation` or an `error` (the same shape as an error response), and a `summary`. One failing calculation never
affects the others. Each calculation may carry its own `idempotency_key`. The size is limited (`BATCH_MAX_SIZE`,
100 by default) and so is the number running at once (`BATCH_CONCURRENCY`, 8 by default).

## Reading the history

```bash
curl -s 'http://localhost:8080/api/v1/calculations?module=statistics&status=succeeded&limit=20'
```

| Query parameter | Meaning |
|---|---|
| `module`, `operation` | Only calculations of this module or operation. |
| `status` | `succeeded` or `failed`. |
| `created_from`, `created_before` | A time range, ISO 8601. `created_from` is inclusive, `created_before` exclusive. |
| `limit` | Page size, 1 to 100. Defaults to 20. |
| `cursor` | The `page.next_cursor` of the previous page. |

The newest calculation comes first. A response carries `page.next_cursor`, which is `null` on the last page. Treat the
cursor as an opaque token. Paging uses a keyset, so it stays correct while calculations are being added and costs the
same on the thousandth page as on the first. Unknown query parameters are rejected rather than ignored, so a misspelt
filter cannot silently list everything.

## Limits

| Limit | Default | Setting |
|---|---|---|
| Request body | 1 MiB | `HTTP_MAX_BODY_SIZE_BYTES` |
| Time budget of one calculation | 2 s | `CALCULATION_TIMEOUT_MS` |
| Calculations in a batch | 100 | `BATCH_MAX_SIZE` |
| Calculations of a batch running at once | 8 | `BATCH_CONCURRENCY` |
| History page | 100 | — |

Text in a request, and the names of its fields, never contains a NUL character (`\u0000`): JSON can write one, but a
database cannot store it, so it is refused with `400`, naming the field. The `module` and `operation` filters of the history
are names (lowercase letters, digits and underscores, at most 64 characters), and a filter that is not one is refused.

## Security

The API sets `X-Content-Type-Options: nosniff`, a `Content-Security-Policy` that allows nothing, `X-Frame-Options: DENY`
and `Referrer-Policy: no-referrer` on every response. TLS, HSTS, authentication, CORS and rate limiting belong to the
gateway in front of the service; the service never trusts a client-supplied identifier beyond logging it, and it
accepts one only after checking its length and characters.
