#!/usr/bin/env bash
# Verifies the graceful shutdown of the real executable: requests that were accepted before SIGTERM must complete
# successfully, readiness must stop reporting "ready", and the process must exit cleanly within the shutdown timeout.
#
# Usage: Scripts/smoke-graceful-shutdown.sh
#
# Environment:
#   DATABASE_URL   PostgreSQL database with the migrations applied (required)
#   BINARY         The executable to run (default: .build/debug/borba-scientific-engine)
#   PORT           Port to listen on (default: 18080)
#   CONCURRENCY    Slow requests in flight when the signal arrives (default: 4)
#   INTERVALS      Size of each slow calculation; about 0.8 s per million (default: 1000000)
set -euo pipefail

BINARY="${BINARY:-.build/debug/borba-scientific-engine}"
PORT="${PORT:-18080}"
CONCURRENCY="${CONCURRENCY:-4}"
INTERVALS="${INTERVALS:-1000000}"
EXIT_TIMEOUT_SECONDS="${EXIT_TIMEOUT_SECONDS:-30}"
SIGNAL_DELAY_SECONDS="${SIGNAL_DELAY_SECONDS:-0.25}"
STARTUP_TIMEOUT_SECONDS=30

: "${DATABASE_URL:?DATABASE_URL must point at a migrated PostgreSQL}"

BASE_URL="http://127.0.0.1:${PORT}"
WORK_DIR="$(mktemp -d)"
LOG_FILE="${WORK_DIR}/server.log"
failures=0

cleanup() {
    if [[ -n "${SERVER_PID:-}" ]] && kill -0 "${SERVER_PID}" 2>/dev/null; then
        kill -KILL "${SERVER_PID}" 2>/dev/null || true
    fi
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

check() {
    local description="$1" outcome="$2"
    if [[ "${outcome}" == "ok" ]]; then
        echo "  ok    ${description}"
    else
        echo "  FAIL  ${description}"
        failures=$((failures + 1))
    fi
}

echo "Starting ${BINARY} on port ${PORT}"
APP_ENV=test HTTP_HOST=127.0.0.1 HTTP_PORT="${PORT}" LOG_LEVEL=info LOG_FORMAT=json "${BINARY}" serve >"${LOG_FILE}" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 "${STARTUP_TIMEOUT_SECONDS}"); do
    curl -sf "${BASE_URL}/health" >/dev/null 2>&1 && break
    sleep 1
done
curl -sf "${BASE_URL}/ready" >/dev/null || { echo "The service did not become ready"; cat "${LOG_FILE}"; exit 1; }

BODY="{\"module\":\"numerical\",\"operation\":\"integrate\",\"parameters\":{\"expression\":\"sin(x)*exp(-x)\",\"lower\":0,\"upper\":10,\"intervals\":${INTERVALS}}}"
for index in $(seq 1 "${CONCURRENCY}"); do
    curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/api/v1/calculations" \
        -H 'Content-Type: application/json' -d "${BODY}" >"${WORK_DIR}/request-${index}.status" 2>/dev/null &
done

sleep "${SIGNAL_DELAY_SECONDS}"
echo "Sending SIGTERM with ${CONCURRENCY} requests in flight"
kill -TERM "${SERVER_PID}"

ready_status="$(curl -s -m 2 -o /dev/null -w '%{http_code}' "${BASE_URL}/ready" 2>/dev/null || true)"
case "${ready_status}" in
    503 | 000) check "readiness stops reporting ready during the drain (got ${ready_status})" ok ;;
    *) check "readiness stops reporting ready during the drain (got ${ready_status})" fail ;;
esac

waited=0
while kill -0 "${SERVER_PID}" 2>/dev/null && ((waited < EXIT_TIMEOUT_SECONDS * 2)); do
    sleep 0.5
    waited=$((waited + 1))
done
if kill -0 "${SERVER_PID}" 2>/dev/null; then
    check "the process exits within ${EXIT_TIMEOUT_SECONDS}s" fail
else
    check "the process exits within ${EXIT_TIMEOUT_SECONDS}s (took about $((waited / 2))s)" ok
fi

exit_code=0
wait "${SERVER_PID}" 2>/dev/null || exit_code=$?
[[ "${exit_code}" -eq 0 ]] && check "the exit code is 0" ok || check "the exit code is 0 (got ${exit_code})" fail

wait 2>/dev/null || true
completed=0
for index in $(seq 1 "${CONCURRENCY}"); do
    [[ "$(cat "${WORK_DIR}/request-${index}.status" 2>/dev/null)" == "201" ]] && completed=$((completed + 1))
done
[[ "${completed}" -eq "${CONCURRENCY}" ]] \
    && check "every request accepted before the signal completed with 201 (${completed}/${CONCURRENCY})" ok \
    || check "every request accepted before the signal completed with 201 (${completed}/${CONCURRENCY})" fail

dropped="$(grep -c '"error_code"\|Request failed' "${LOG_FILE}" || true)"
[[ "${dropped}" -eq 0 ]] && check "no request failed during shutdown" ok || check "no request failed during shutdown (${dropped} logged)" fail

if [[ "${failures}" -ne 0 ]]; then
    echo "Graceful shutdown check FAILED"
    tail -20 "${LOG_FILE}"
    exit 1
fi
echo "Graceful shutdown check passed"
