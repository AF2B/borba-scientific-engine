#!/usr/bin/env bash
# Deploys an image through a provider, verifies the deployment from the outside and, when it fails, puts the previous
# version back. The provider knows the platform (Scripts/deploy/providers/); everything else, which is what makes a
# deployment safe, is here: the plan, the verification and the rollback.
#
# Usage: Scripts/deploy.sh --image REFERENCE --url BASE_URL [--commit SHA] [--provider NAME] [--dry-run]
#                          [--timeout SECONDS] [--stability SECONDS]
#   --image      What to deploy, by an immutable reference: ghcr.io/<owner>/<repo>@sha256:<digest> (required)
#   --url        Base URL the deployed service answers on, for the verification (required)
#   --commit     The commit that image was built from; the verification requires the service to report it
#   --provider   The platform: a script in Scripts/deploy/providers (default: the DEPLOY_PROVIDER variable)
#   --dry-run    Ask the provider what is deployed and print the plan; change nothing
#   --timeout    How long the verification waits for the service to become ready (default: 120)
#   --stability  How long the service must keep answering afterwards (default: 15)
#
# Exit status:
#   0  deployed and verified (or a dry run that found everything in order)
#   1  the deployment failed and the previous version was restored and verified
#   2  nothing was done: a usage or configuration error
#   3  the deployment failed and the service could not be restored: it needs a person now
#
# Database migrations are not reverted by a rollback. They are forward-only and must keep the previous release working
# (expand, then contract), because that is the version a rollback puts back.
set -uo pipefail

readonly EXIT_ROLLED_BACK=1
readonly EXIT_USAGE=2
readonly EXIT_BROKEN=3
readonly DEFAULT_TIMEOUT_SECONDS=120
readonly DEFAULT_STABILITY_SECONDS=15

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="${SCRIPT_DIR}/deploy/providers"

image=""
url=""
commit=""
provider="${DEPLOY_PROVIDER:-}"
dry_run=0
timeout_seconds="${DEFAULT_TIMEOUT_SECONDS}"
stability_seconds="${DEFAULT_STABILITY_SECONDS}"

log() {
    echo "==> $*"
}

fail_usage() {
    echo "error: $*" >&2
    exit "${EXIT_USAGE}"
}

usage() {
    sed -n '2,/^set -/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
    exit "${EXIT_USAGE}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image) image="${2:-}"; shift 2 ;;
        --url) url="${2:-}"; shift 2 ;;
        --commit) commit="${2:-}"; shift 2 ;;
        --provider) provider="${2:-}"; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        --timeout) timeout_seconds="${2:-}"; shift 2 ;;
        --stability) stability_seconds="${2:-}"; shift 2 ;;
        -h | --help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

[[ -n "${image}" ]] || fail_usage "--image is required"

if [[ -z "${provider}" ]]; then
    if [[ "${dry_run}" -eq 1 ]]; then
        log "No provider is configured (the DEPLOY_PROVIDER variable of the environment), so nothing can be deployed."
        log "Dry run: ${image} would be deployed to ${url:-an address that is not configured either}. Nothing was changed."
        exit 0
    fi
    fail_usage "no provider is configured: set the DEPLOY_PROVIDER variable of the environment (see Documentation/Operations/deployment.md)"
fi

[[ -n "${url}" ]] || fail_usage "--url is required: where the deployed service answers, for the verification"

# The name comes from configuration and becomes a path: only a plain name is accepted.
[[ "${provider}" =~ ^[a-z][a-z0-9-]*$ ]] || fail_usage "invalid provider name '${provider}'"
provider_script="${PROVIDERS_DIR}/${provider}.sh"
[[ -x "${provider_script}" ]] || fail_usage "unknown provider '${provider}': there is no executable ${provider_script}"

verify() {
    local expected_commit="$1"
    local arguments=(--url "${url}" --timeout "${timeout_seconds}" --stability "${stability_seconds}")
    if [[ -n "${expected_commit}" ]]; then
        arguments+=(--commit "${expected_commit}")
    fi
    "${SCRIPT_DIR}/verify-deployment.sh" "${arguments[@]}"
}

log "Provider: ${provider}"
if ! current="$("${provider_script}" current)"; then
    fail_usage "the provider could not tell what is deployed now"
fi
log "Deployed now: ${current:-nothing}"
log "To deploy:    ${image}"

if [[ "${dry_run}" -eq 1 ]]; then
    log "Dry run: nothing was changed."
    exit 0
fi

if "${provider_script}" apply "${image}" && verify "${commit}"; then
    log "Deployed and verified: ${image}"
    exit 0
fi

echo
log "The deployment of ${image} failed."
if [[ -z "${current}" ]]; then
    log "Nothing was deployed before it, so there is nothing to go back to. The service needs attention."
    exit "${EXIT_BROKEN}"
fi
if [[ "${current}" == "${image}" ]]; then
    log "It was the version already running, so there is nothing to go back to. The service needs attention."
    exit "${EXIT_BROKEN}"
fi

log "Rolling back to ${current}. Migrations the new release applied are not reverted."
if "${provider_script}" apply "${current}" && verify ""; then
    log "Rolled back: the service runs ${current} again."
    exit "${EXIT_ROLLED_BACK}"
fi

log "The rollback failed too. The service needs attention now."
exit "${EXIT_BROKEN}"
