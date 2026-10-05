#!/usr/bin/env bash
# Deploy provider for a Docker host that runs the project's Compose stack: staging environments, demonstrations and
# single-host installations. It deploys to the Docker daemon it is run against, which is either the local one, as on a
# self-hosted runner installed on the host, or a remote one reached through DOCKER_HOST.
#
# The Compose file also runs PostgreSQL. A production deployment against a managed database needs its own provider.
#
# Commands (see _template.sh for the contract):
#   current           Prints the image reference of the application container.
#   apply REFERENCE   Pulls the image when the host does not have it, runs the migration job and recreates the
#                     application, and returns once Docker reports every service healthy.
#
# Environment:
#   DEPLOY_ENV_FILE                Dotenv file with what the Compose file requires: POSTGRES_USER, POSTGRES_PASSWORD,
#                                  POSTGRES_DB and, optionally, HTTP_PORT, APP_ENV and the like
#   COMPOSE_PROJECT                Compose project name (default: borba-scientific-engine)
#   COMPOSE_FILE_PATH              The Compose file (default: docker-compose.yml of the repository)
#   COMPOSE_WAIT_TIMEOUT_SECONDS   How long to wait for the services to be healthy (default: 180)
#
# The host must be able to pull the image: for a private package, log in to ghcr.io on it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${COMPOSE_PROJECT:-borba-scientific-engine}"
COMPOSE_FILE_PATH="${COMPOSE_FILE_PATH:-${SCRIPT_DIR}/../../../docker-compose.yml}"
WAIT_TIMEOUT_SECONDS="${COMPOSE_WAIT_TIMEOUT_SECONDS:-180}"
APPLICATION_SERVICE="app"

compose() {
    local arguments=(--project-name "${PROJECT}" --file "${COMPOSE_FILE_PATH}")
    if [[ -n "${DEPLOY_ENV_FILE:-}" ]]; then
        arguments+=(--env-file "${DEPLOY_ENV_FILE}")
    fi
    docker compose "${arguments[@]}" "$@"
}

current() {
    local container
    container="$(compose ps --all --quiet "${APPLICATION_SERVICE}" | head -n 1)"
    if [[ -n "${container}" ]]; then
        docker inspect --format '{{.Config.Image}}' "${container}"
    fi
}

apply() {
    local reference="$1"

    # The migration job never pulls (its pull policy is "never", so that a missing image is an error and not a surprise),
    # which makes the pull this provider's job.
    if ! docker image inspect "${reference}" >/dev/null 2>&1; then
        docker pull --quiet "${reference}" >/dev/null
    fi

    IMAGE="${reference}" compose up --detach --no-build --remove-orphans --wait --wait-timeout "${WAIT_TIMEOUT_SECONDS}"
}

case "${1:-}" in
    current) current ;;
    apply) apply "${2:?apply needs an image reference}" ;;
    *)
        echo "usage: $0 current | apply REFERENCE" >&2
        exit 2
        ;;
esac
