#!/usr/bin/env bash
# Verifies the container image the way it is meant to run: through the Compose stack, as an unprivileged user, on a
# read-only filesystem, without capabilities, with the migrations applied by their own service and with Docker's health
# check watching it. It also checks the behaviour the health check relies on: the container stays healthy while the
# database is down (liveness) even though it stops being ready, and it exits with status 0 when it is stopped.
#
# Usage: Scripts/smoke-container.sh
#
# Environment:
#   IMAGE   The image to test; build it first with `make docker-build` (required)
#
# Requires: docker with the Compose plugin, curl, jq and python3.
set -euo pipefail

: "${IMAGE:?IMAGE must name a locally built image}"

PROJECT="borba-smoke-$$"
EXPECTED_USER="10001:10001"
EXPECTED_UID=10001
STARTUP_TIMEOUT_SECONDS=180
STATE_TIMEOUT_SECONDS=60
HEALTH_SAMPLE_SECONDS=12
STOP_GRACE_SECONDS=30
HOST="127.0.0.1"

WORK_DIR="$(mktemp -d)"
ENV_FILE="${WORK_DIR}/smoke.env"
failures=0

free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

HTTP_PORT="$(free_port)"
POSTGRES_PORT="$(free_port)"
BASE_URL="http://${HOST}:${HTTP_PORT}"

cat >"${ENV_FILE}" <<EOF
IMAGE=${IMAGE}
HTTP_PORT=${HTTP_PORT}
POSTGRES_PORT=${POSTGRES_PORT}
POSTGRES_USER=smoke
POSTGRES_PASSWORD=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
POSTGRES_DB=smoke
EOF

compose() {
    docker compose --project-name "${PROJECT}" --env-file "${ENV_FILE}" "$@"
}

cleanup() {
    compose down --volumes --remove-orphans >/dev/null 2>&1 || true
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

# Runs a command and records whether it succeeded.
expect_success() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then check "${description}" ok; else check "${description}" fail; fi
}

# Runs a command and records whether it failed.
expect_failure() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then check "${description}" fail; else check "${description}" ok; fi
}

status_of() {
    curl -s -m 5 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true
}

# Waits until a URL answers with the given status.
wait_for_status() {
    local url="$1" expected="$2" timeout="$3" waited=0
    while [[ "$(status_of "${url}")" != "${expected}" ]]; do
        waited=$((waited + 1))
        ((waited < timeout)) || return 1
        sleep 1
    done
}

container_id() {
    compose ps --all --quiet "$1"
}

inspect() {
    docker inspect --format "$2" "$(container_id "$1")"
}

image_inspect() {
    docker image inspect --format "$1" "${IMAGE}"
}

# Reads a status line of the first process of the application container, without whitespace.
process_status() {
    compose exec -T app sh -c "grep $1 /proc/1/status" | tr -d '[:space:]'
}

has_no_setuid_files() {
    local files
    files="$(docker run --rm --user root --entrypoint find "${IMAGE}" / -xdev -perm /6000 -type f)" || return 1
    [[ -z "${files}" ]]
}

reports_version() {
    curl -s -m 5 "${BASE_URL}/version" | jq -e '.version'
}

echo "Starting the stack from ${IMAGE}"
if ! compose up --detach --no-build --wait --wait-timeout "${STARTUP_TIMEOUT_SECONDS}" >"${WORK_DIR}/up.log" 2>&1; then
    check "the stack becomes healthy within ${STARTUP_TIMEOUT_SECONDS}s" fail
    cat "${WORK_DIR}/up.log"
    compose logs --tail 40 || true
    exit 1
fi
check "the stack becomes healthy within ${STARTUP_TIMEOUT_SECONDS}s" ok

echo "The image"
expect_success "runs as the numeric user ${EXPECTED_USER}" \
    test "$(image_inspect '{{.Config.User}}')" = "${EXPECTED_USER}"
expect_success "defines a health check" \
    test "$(image_inspect '{{if .Config.Healthcheck}}defined{{end}}')" = "defined"
expect_success "carries OCI labels" \
    test -n "$(image_inspect '{{index .Config.Labels "org.opencontainers.image.version"}}')"
expect_success "contains no setuid or setgid files" has_no_setuid_files

echo "The running container"
expect_success "is reported healthy by Docker" \
    test "$(inspect app '{{.State.Health.Status}}')" = "healthy"
expect_success "runs as uid ${EXPECTED_UID}" \
    test "$(compose exec -T app id -u)" = "${EXPECTED_UID}"
expect_failure "cannot write to the application directory (read-only filesystem)" \
    compose exec -T app sh -c 'echo x > /app/write-test'
expect_success "can write to its scratch directory" \
    compose exec -T app sh -c 'echo x > /tmp/write-test'
expect_success "holds no Linux capabilities" \
    test "$(process_status CapEff)" = "CapEff:0000000000000000"
expect_success "cannot gain privileges" \
    test "$(process_status NoNewPrivs)" = "NoNewPrivs:1"
expect_success "applies the migrations again without effect (idempotent migrate service)" \
    compose run --rm --no-deps migrate

echo "The API through the published port"
expect_success "GET /health answers 200" test "$(status_of "${BASE_URL}/health")" = "200"
expect_success "GET /ready answers 200" test "$(status_of "${BASE_URL}/ready")" = "200"
expect_success "GET /version names the build" reports_version

created="$(curl -s -m 10 -X POST "${BASE_URL}/api/v1/calculations" -H 'Content-Type: application/json' \
    -d '{"module":"statistics","operation":"mean","parameters":{"values":[1,2,3,4]}}' || true)"
identifier="$(jq -r '.id // empty' <<<"${created}" 2>/dev/null || true)"
expect_success "POST /api/v1/calculations records a calculation in PostgreSQL" test -n "${identifier}"
expect_success "the recorded calculation can be read back" \
    test "$(status_of "${BASE_URL}/api/v1/calculations/${identifier:-missing}")" = "200"

echo "With the database down"
compose stop postgres >/dev/null 2>&1
expect_success "GET /ready answers 503" wait_for_status "${BASE_URL}/ready" 503 "${STATE_TIMEOUT_SECONDS}"
expect_success "GET /health still answers 200 (liveness does not depend on the database)" \
    test "$(status_of "${BASE_URL}/health")" = "200"
sleep "${HEALTH_SAMPLE_SECONDS}"
expect_success "Docker keeps reporting the container healthy, so it is not restarted for a database outage" \
    test "$(inspect app '{{.State.Health.Status}}')" = "healthy"

compose start postgres >/dev/null 2>&1
expect_success "GET /ready answers 200 again once the database is back" \
    wait_for_status "${BASE_URL}/ready" 200 "${STATE_TIMEOUT_SECONDS}"

echo "Stopping"
started="${SECONDS}"
compose stop --timeout "${STOP_GRACE_SECONDS}" app >/dev/null 2>&1
elapsed=$((SECONDS - started))
expect_success "exits with status 0 after SIGTERM (took ${elapsed}s)" \
    test "$(inspect app '{{.State.ExitCode}}')" = "0"

if [[ "${failures}" -ne 0 ]]; then
    echo "Container check FAILED (${failures})"
    compose logs --tail 40 app || true
    exit 1
fi
echo "Container check passed"
