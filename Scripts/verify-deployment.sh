#!/usr/bin/env bash
# Verifies a deployment from the outside, the way a client sees it: the instance becomes ready, it is the version that was
# meant to be deployed, it answers a read-only request and it keeps answering for a while. It only reads: it never creates
# a calculation, so it is safe to run against production.
#
# Usage: Scripts/verify-deployment.sh --url BASE_URL [--commit SHA] [--timeout SECONDS] [--stability SECONDS] [--metrics]
#   --url        Base URL of the instance, such as https://engine.example.com (required)
#   --commit     The commit GET /version must report. Leave it out when the version is not known, as when checking a
#                rollback.
#   --timeout    How long to wait for the instance to become ready (default: 120)
#   --stability  How long it must keep answering once it is ready; catches a crash loop (default: 15)
#   --metrics    Also require GET /metrics to answer. Off by default: it is usually kept off the public network.
#
# Exit status: 0 when every check passed, 1 when one failed, 2 on a usage error.
# Requires: curl and jq.
set -uo pipefail

DEFAULT_TIMEOUT_SECONDS=120
DEFAULT_STABILITY_SECONDS=15
REQUEST_TIMEOUT_SECONDS=5

url=""
commit=""
timeout_seconds="${DEFAULT_TIMEOUT_SECONDS}"
stability_seconds="${DEFAULT_STABILITY_SECONDS}"
check_metrics=0

usage() {
    sed -n '2,/^set -/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --url) url="${2:-}"; shift 2 ;;
        --commit) commit="${2:-}"; shift 2 ;;
        --timeout) timeout_seconds="${2:-}"; shift 2 ;;
        --stability) stability_seconds="${2:-}"; shift 2 ;;
        --metrics) check_metrics=1; shift ;;
        -h | --help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done
[[ -n "${url}" ]] || usage
url="${url%/}"

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

status_of() {
    curl -s -m "${REQUEST_TIMEOUT_SECONDS}" -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true
}

body_of() {
    curl -s -m "${REQUEST_TIMEOUT_SECONDS}" "$1" 2>/dev/null || true
}

echo "Verifying ${url}"

waited=0
until [[ "$(status_of "${url}/ready")" == "200" ]]; do
    waited=$((waited + 1))
    if ((waited >= timeout_seconds)); then
        check "the instance becomes ready within ${timeout_seconds}s" fail
        echo "Verification FAILED"
        exit 1
    fi
    sleep 1
done
check "the instance becomes ready (after about ${waited}s)" ok

version_body="$(body_of "${url}/version")"
reported_commit="$(jq -r '.commit // empty' <<<"${version_body}" 2>/dev/null || true)"
reported_version="$(jq -r '.version // empty' <<<"${version_body}" 2>/dev/null || true)"
echo "        it reports version ${reported_version:-?} at commit ${reported_commit:-?}"
if [[ -n "${commit}" ]]; then
    if [[ "${reported_commit}" == "${commit}" ]]; then
        check "it is the commit that was deployed" ok
    else
        check "it is the commit that was deployed (expected ${commit})" fail
    fi
fi

if [[ "$(status_of "${url}/health")" == "200" ]]; then check "GET /health answers 200" ok; else check "GET /health answers 200" fail; fi

types_body="$(body_of "${url}/api/v1/types")"
if jq -e '.' >/dev/null 2>&1 <<<"${types_body}"; then
    check "GET /api/v1/types answers with JSON" ok
else
    check "GET /api/v1/types answers with JSON" fail
fi

if [[ "${check_metrics}" -eq 1 ]]; then
    if [[ "$(status_of "${url}/metrics")" == "200" ]]; then check "GET /metrics answers 200" ok; else check "GET /metrics answers 200" fail; fi
fi

stable=1
for ((second = 0; second < stability_seconds; second++)); do
    if [[ "$(status_of "${url}/ready")" != "200" || "$(status_of "${url}/health")" != "200" ]]; then
        stable=0
        break
    fi
    sleep 1
done
if [[ "${stable}" -eq 1 ]]; then
    check "it keeps answering for ${stability_seconds}s" ok
else
    check "it keeps answering for ${stability_seconds}s" fail
fi

if [[ "${failures}" -ne 0 ]]; then
    echo "Verification FAILED (${failures})"
    exit 1
fi
echo "Verification passed"
