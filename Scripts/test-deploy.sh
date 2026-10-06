#!/usr/bin/env bash
# Rehearses the deployment tooling against a real Docker daemon: a first deployment, an upgrade, a dry run, the refusal of
# unusable configuration, a release that has to be pulled from a registry by its digest, and the two ways a release can
# fail, which must both end with the previous version back in service. The releases that fail are the image under test
# with one thing wrong: one never starts, the other starts and listens on the wrong port, so only the verification from
# the outside can tell. The registry is a local one, started for the rehearsal.
#
# Usage: Scripts/test-deploy.sh
#
# Environment:
#   IMAGE   The image to deploy; build it first with `make docker-build` (required)
#
# Requires: docker with the Compose plugin (and access to the registry:2 image), curl, jq and python3. It uses its own
# Compose project and free ports.
set -euo pipefail

: "${IMAGE:?IMAGE must name a locally built image}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="borba-deploytest-$$"
HOST="127.0.0.1"
VERIFY_TIMEOUT_SECONDS=30
STABILITY_SECONDS=2
LISTENING_ELSEWHERE_PORT=9999

readonly EXIT_ROLLED_BACK=1
readonly EXIT_USAGE=2
readonly EXIT_BROKEN=3

WORK_DIR="$(mktemp -d)"
ENV_FILE="${WORK_DIR}/deploy.env"
failures=0

free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

HTTP_PORT="$(free_port)"
BASE_URL="http://${HOST}:${HTTP_PORT}"

cat >"${ENV_FILE}" <<EOF
HTTP_PORT=${HTTP_PORT}
POSTGRES_PORT=$(free_port)
POSTGRES_USER=rehearsal
POSTGRES_PASSWORD=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
POSTGRES_DB=rehearsal
EOF

COMMIT="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "${IMAGE}")"
: "${COMMIT:?the image carries no revision label; build it with make docker-build}"

NEXT_IMAGE="borba-deploytest-${$}:next"
STARTS_NEVER_IMAGE="borba-deploytest-${$}:never-starts"
WRONG_PORT_IMAGE="borba-deploytest-${$}:wrong-port"

REGISTRY_NAME="${PROJECT}-registry"
REGISTRY_PORT="$(free_port)"
REGISTRY_REPOSITORY="${HOST}:${REGISTRY_PORT}/rehearsal"
PUBLISHED_VERSION="v0.0.1"
REGISTRY_STARTUP_SECONDS=30

provider() {
    DEPLOY_ENV_FILE="${ENV_FILE}" COMPOSE_PROJECT="${PROJECT}" "${ROOT}/Scripts/deploy/providers/compose.sh" "$@"
}

cleanup() {
    provider_down || true
    docker rm --force "${REGISTRY_NAME}" >/dev/null 2>&1 || true
    docker rmi --force "${NEXT_IMAGE}" "${STARTS_NEVER_IMAGE}" "${WRONG_PORT_IMAGE}" \
        "${REGISTRY_REPOSITORY}:${PUBLISHED_VERSION}" >/dev/null 2>&1 || true
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

provider_down() {
    docker compose --project-name "${PROJECT}" --file "${ROOT}/docker-compose.yml" --env-file "${ENV_FILE}" \
        down --volumes --remove-orphans >/dev/null 2>&1
}

check() {
    local description="$1" outcome="$2"
    if [[ "${outcome}" == "ok" ]]; then
        echo "  ok    ${description}"
    else
        echo "  FAIL  ${description}"
        failures=$((failures + 1))
    fi
}

# Runs the deployment script with the Compose provider and records whether it exited with the expected status.
expect_deploy() {
    local expected="$1" description="$2"
    shift 2
    local status=0
    DEPLOY_PROVIDER="${DEPLOY_PROVIDER-compose}" DEPLOY_ENV_FILE="${ENV_FILE}" COMPOSE_PROJECT="${PROJECT}" \
        "${ROOT}/Scripts/deploy.sh" --url "${BASE_URL}" --timeout "${VERIFY_TIMEOUT_SECONDS}" \
        --stability "${STABILITY_SECONDS}" "$@" >"${WORK_DIR}/deploy.log" 2>&1 || status=$?
    if [[ "${status}" -eq "${expected}" ]]; then
        check "${description} (exit ${status})" ok
    else
        check "${description} (expected exit ${expected}, got ${status})" fail
        sed 's/^/        | /' "${WORK_DIR}/deploy.log" | tail -25
    fi
}

# Records whether a command exited with the expected status.
expect_status() {
    local expected="$1" description="$2"
    shift 2
    local status=0
    "$@" >"${WORK_DIR}/command.log" 2>&1 || status=$?
    if [[ "${status}" -eq "${expected}" ]]; then
        check "${description} (exit ${status})" ok
    else
        check "${description} (expected exit ${expected}, got ${status})" fail
        sed 's/^/        | /' "${WORK_DIR}/command.log" | tail -15
    fi
}

start_registry() {
    docker pull --quiet registry:2 >/dev/null
    docker run --detach --name "${REGISTRY_NAME}" --publish "${HOST}:${REGISTRY_PORT}:5000" registry:2 >/dev/null
    local waited=0
    until curl -sf "http://${HOST}:${REGISTRY_PORT}/v2/" >/dev/null 2>&1; do
        waited=$((waited + 1))
        ((waited < REGISTRY_STARTUP_SECONDS)) || return 1
        sleep 1
    done
}

expect_running() {
    local expected="$1" description="$2" actual
    actual="$(provider current)"
    if [[ "${actual}" == "${expected}" ]]; then
        check "${description}" ok
    else
        check "${description} (running ${actual:-nothing}, expected ${expected})" fail
    fi
}

expect_ready() {
    if [[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "${BASE_URL}/ready" || true)" == "200" ]]; then
        check "$1" ok
    else
        check "$1" fail
    fi
}

# The image under test with one setting changed. Committing a container needs no builder, so it works wherever there is a
# Docker daemon, including a runner whose default builder cannot see the images the daemon holds.
derive() {
    local tag="$1" change="$2" container
    container="$(docker create "${IMAGE}")"
    docker commit --change "${change}" "${container}" "${tag}" >/dev/null
    docker rm "${container}" >/dev/null
}

docker tag "${IMAGE}" "${NEXT_IMAGE}"
derive "${STARTS_NEVER_IMAGE}" 'ENTRYPOINT ["/bin/false"]'
derive "${WRONG_PORT_IMAGE}" "ENV HTTP_PORT=${LISTENING_ELSEWHERE_PORT}"

echo "A first deployment"
expect_deploy 0 "deploys and verifies the image" --image "${IMAGE}" --commit "${COMMIT}"
expect_running "${IMAGE}" "the image is running"

echo "Planning and refusing"
expect_deploy 0 "a dry run plans a release that would fail" --image "${STARTS_NEVER_IMAGE}" --dry-run
expect_running "${IMAGE}" "a dry run changes nothing"
DEPLOY_PROVIDER="" expect_deploy 0 "a dry run without a provider only says so" --image "${IMAGE}" --dry-run
DEPLOY_PROVIDER="" expect_deploy "${EXIT_USAGE}" "a deployment without a provider is refused" --image "${IMAGE}"
expect_status 0 "a dry run on an environment with nothing configured only says so" \
    env DEPLOY_PROVIDER= "${ROOT}/Scripts/deploy.sh" --image "${IMAGE}" --dry-run
DEPLOY_PROVIDER="no-such-provider" expect_deploy "${EXIT_USAGE}" "an unknown provider is refused" --image "${IMAGE}"
DEPLOY_PROVIDER="../providers/compose" expect_deploy "${EXIT_USAGE}" "a provider name that is a path is refused" --image "${IMAGE}"
DEPLOY_PROVIDER="_template" expect_deploy "${EXIT_USAGE}" "the template cannot be selected" --image "${IMAGE}"
expect_running "${IMAGE}" "refusals change nothing"

echo "A release that does not start"
expect_deploy "${EXIT_ROLLED_BACK}" "is rolled back" --image "${STARTS_NEVER_IMAGE}" --commit "${COMMIT}"
expect_running "${IMAGE}" "the previous version is running again"
expect_ready "the service is ready again"

echo "A release that starts and does not serve"
expect_deploy "${EXIT_ROLLED_BACK}" "is rolled back" --image "${WRONG_PORT_IMAGE}" --commit "${COMMIT}"
expect_running "${IMAGE}" "the previous version is running again"
expect_ready "the service is ready again"

echo "An upgrade"
expect_deploy 0 "deploys the new reference" --image "${NEXT_IMAGE}" --commit "${COMMIT}"
expect_running "${NEXT_IMAGE}" "the new reference is running"
expect_deploy 0 "deploying what already runs is harmless" --image "${NEXT_IMAGE}" --commit "${COMMIT}"

echo "A release published to a registry"
start_registry
derive "${REGISTRY_REPOSITORY}:${PUBLISHED_VERSION}" 'ENV REHEARSAL_RELEASE=published'
docker push --quiet "${REGISTRY_REPOSITORY}:${PUBLISHED_VERSION}" >/dev/null
RESOLVER="${ROOT}/Scripts/deploy/resolve-image.sh"
expect_status 2 "a moving tag is not a deployable version" "${RESOLVER}" "${REGISTRY_REPOSITORY}" latest
expect_status 2 "a branch is not a deployable version" "${RESOLVER}" "${REGISTRY_REPOSITORY}" main
expect_status 1 "a version that was never published cannot be resolved" "${RESOLVER}" "${REGISTRY_REPOSITORY}" v9.9.9

resolved="$("${RESOLVER}" "${REGISTRY_REPOSITORY}" "${PUBLISHED_VERSION}")"
reference="$(sed -n 's/^reference=//p' <<<"${resolved}")"
resolved_commit="$(sed -n 's/^commit=//p' <<<"${resolved}")"
if [[ "${reference}" == "${REGISTRY_REPOSITORY}@sha256:"* ]]; then
    check "a version resolves to a reference by digest" ok
else
    check "a version resolves to a reference by digest (got '${reference}')" fail
fi
if [[ "${resolved_commit}" == "${COMMIT}" ]]; then
    check "and to the commit it was built from" ok
else
    check "and to the commit it was built from (got '${resolved_commit}')" fail
fi

# Without the local copy, the provider has to pull what it deploys.
docker rmi --force "${REGISTRY_REPOSITORY}:${PUBLISHED_VERSION}" >/dev/null
expect_deploy 0 "pulls the image by its digest and deploys it" --image "${reference}" --commit "${resolved_commit}"
expect_running "${reference}" "the published release is running"

echo "A first deployment that fails"
provider_down
expect_deploy "${EXIT_BROKEN}" "has nothing to go back to and says so" --image "${STARTS_NEVER_IMAGE}"

if [[ "${failures}" -ne 0 ]]; then
    echo "Deployment rehearsal FAILED (${failures})"
    exit 1
fi
echo "Deployment rehearsal passed"
