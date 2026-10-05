#!/usr/bin/env bash
# Validates a release build of the executable, which is what the container image ships: it links only libraries that are
# present, it starts and knows its routes, its health check fails when nothing is listening, it applies the migrations
# to an empty database and it shuts down gracefully with requests in flight.
#
# Usage: Scripts/validate-release.sh
#
# Environment:
#   DATABASE_URL   PostgreSQL database for the migrations and the shutdown check (required)
#   BINARY         The executable to validate (default: .build/release/borba-scientific-engine)
#
# Requires: curl, and the swift toolchain's ldd. Build first: swift build --configuration release.
set -euo pipefail

BINARY="${BINARY:-.build/release/borba-scientific-engine}"
UNUSED_PORT=1
SHUTDOWN_PORT=18081

: "${DATABASE_URL:?DATABASE_URL must point at a PostgreSQL database}"

failures=0

check() {
    local description="$1" outcome="$2"
    if [[ "${outcome}" == "ok" ]]; then
        echo "  ok    ${description}"
    else
        echo "  FAIL  ${description}"
        failures=$((failures + 1))
    fi
}

expect_success() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then check "${description}" ok; else check "${description}" fail; fi
}

expect_failure() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then check "${description}" fail; else check "${description}" ok; fi
}

has_no_missing_libraries() {
    ! ldd "${BINARY}" | grep --quiet "not found"
}

lists_the_routes() {
    local routes
    routes="$("${BINARY}" routes)" || return 1
    grep --quiet "/api/v1/calculations" <<<"${routes}" && grep --quiet "/health" <<<"${routes}"
}

echo "Validating ${BINARY}"
expect_success "the executable exists" test -x "${BINARY}"
expect_success "every shared library it needs is present" has_no_missing_libraries

export DATABASE_URL LOG_LEVEL=error
expect_success "it lists the routes it serves" lists_the_routes
expect_failure "its health check fails when nothing is listening" env HTTP_PORT="${UNUSED_PORT}" "${BINARY}" healthcheck
expect_success "it applies the migrations" "${BINARY}" migrate --yes
expect_success "it applies the migrations again without effect" "${BINARY}" migrate --yes

echo "Graceful shutdown"
if ! BINARY="${BINARY}" PORT="${SHUTDOWN_PORT}" "$(dirname "$0")/smoke-graceful-shutdown.sh"; then
    failures=$((failures + 1))
fi

if [[ "${failures}" -ne 0 ]]; then
    echo "Release validation FAILED (${failures})"
    exit 1
fi
echo "Release validation passed"
