# Errors

Every error response, whatever its status, has the same body:

```json
{
  "error": {
    "code": "DIVISION_BY_ZERO",
    "message": "Division by zero is undefined: the divisor must not be zero.",
    "request_id": "0192e4a1-7c3b-7d2e-8f4a-5b6c7d8e9f01",
    "details": [{ "field": "divisor", "reason": "must not be zero" }],
    "calculation_id": "0192e4a1-7c3b-7d2e-8f4a-5b6c7d8e9f02"
  }
}
```

| Field | Meaning |
|---|---|
| `code` | A stable identifier. **Branch on this**, never on `message`. New codes may be added in a minor release; existing ones never change meaning. |
| `message` | A sentence that is safe to show to a person. It never contains internal details. |
| `request_id` | The request that failed. It is also the `X-Request-ID` response header. Quote it when asking for support: every log line, metric and stored calculation of the request carries it. |
| `details` | Structured context, such as every parameter that failed validation. Omitted when empty. |
| `calculation_id` | Present when the failure happened while running a calculation: the failed calculation is recorded and can be read at `GET /api/v1/calculations/{calculation_id}`. |

## Which failures are recorded

- A request refused **before** it runs (`VALIDATION_FAILED`, `UNSUPPORTED_OPERATION`, a malformed body) is **not** recorded.
- A calculation that **runs and fails** (`DIVISION_BY_ZERO`, `NO_CONVERGENCE`, `CALCULATION_TIMEOUT`, …) **is** recorded, so the history shows what was asked and why it failed. Repeating the request with the same `Idempotency-Key` returns the same stored failure; use a new key to compute again.

## Retrying

| Status | Retry? |
|---|---|
| `400`, `404`, `413`, `415`, `422` | No. The request must change. |
| `503` | Yes, with backoff. Nothing was recorded, so retrying with the same `Idempotency-Key` is safe. |
| `500` | Only if you can quote the `request_id` to us first: it is a defect or a storage failure that will not go away by itself. |

## Catalog

The table below is checked against the code by the test suite: a code that exists in one place and not the other fails the build.

| Code | Status | Meaning |
|---|---|---|
| `INVALID_REQUEST` | 400 | The request is malformed. The details name each offending field, header or query parameter. |
| `UNSUPPORTED_MEDIA_TYPE` | 415 | The body must be sent as application/json. |
| `PAYLOAD_TOO_LARGE` | 413 | The request body is larger than the server accepts. |
| `NOT_FOUND` | 404 | No endpoint exists at this path. |
| `VALIDATION_FAILED` | 422 | A parameter is missing, malformed or out of range. The details list every problem. |
| `UNSUPPORTED_OPERATION` | 404 | The module or operation does not exist. The types endpoint lists the supported ones. |
| `CALCULATION_NOT_FOUND` | 404 | No calculation with this identifier exists. |
| `IDEMPOTENCY_KEY_REUSED` | 422 | The idempotency key was already used with a different request. Use a new key. |
| `DIVISION_BY_ZERO` | 422 | A division, modulo or negative power of zero was requested. |
| `UNDEFINED_RESULT` | 422 | The result is mathematically undefined for the input, such as the logarithm of zero. |
| `NUMERIC_OVERFLOW` | 422 | The result is too large to be represented. |
| `LIMIT_EXCEEDED` | 422 | The input exceeds a safety limit, such as the largest matrix or the largest batch. |
| `NO_CONVERGENCE` | 422 | An iterative method gave up before reaching the requested accuracy. |
| `INVALID_EXPRESSION` | 422 | The expression cannot be parsed or evaluated. The details give the position of the problem. |
| `SINGULAR_MATRIX` | 422 | The matrix has no inverse, so the system cannot be solved. |
| `CALCULATION_TIMEOUT` | 422 | The calculation did not finish within its time budget. Simplify the input or use a new key. |
| `CALCULATION_CANCELLED` | 503 | The calculation was cancelled before it finished, for example during a shutdown. Retry. |
| `STORAGE_UNAVAILABLE` | 503 | The calculation history is temporarily unavailable. Retry later. |
| `STORAGE_FAILURE` | 500 | The calculation history failed in a way that will not go away by itself. |
| `INTERNAL_ERROR` | 500 | An unexpected failure inside the engine. Quote the request identifier when reporting it. |

`DUPLICATE_SUPPRESSED` also exists, but only in events and logs: it marks a concurrent retry that lost the race for an idempotency key and was answered from the winner's record. It never appears in an API response.

## How errors are treated inside the service

The service tells four situations apart, because that is what keeps the error tracker useful: a person dividing by zero is not an incident, a database outage is.

| Classification | Examples | Log level | Reported to Sentry |
|---|---|---|---|
| Expected domain failure | `VALIDATION_FAILED`, `DIVISION_BY_ZERO`, `NO_CONVERGENCE` | info | no |
| Application decision | malformed request, `NOT_FOUND`, `IDEMPOTENCY_KEY_REUSED`, `CALCULATION_TIMEOUT` | info | no |
| Infrastructure failure | `STORAGE_UNAVAILABLE`, `STORAGE_FAILURE` | error | yes, rate limited |
| Unexpected failure | `INTERNAL_ERROR` | critical | always |
