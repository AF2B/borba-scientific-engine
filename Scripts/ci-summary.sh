#!/usr/bin/env bash
# Runs a command, shows its output and, inside GitHub Actions, adds the output to the job summary under a heading. The
# command's exit status is kept, so a failing check still fails the step after its output has been reported.
#
# Usage: Scripts/ci-summary.sh "Heading" command [arguments...]
#
# Environment:
#   GITHUB_STEP_SUMMARY   The summary file; set by GitHub Actions. Without it the output is only shown.
set -uo pipefail

if [[ $# -lt 2 ]]; then
    echo "usage: $0 \"Heading\" command [arguments...]" >&2
    exit 2
fi

heading="$1"
shift

output="$(mktemp)"
trap 'rm -f "${output}"' EXIT

status=0
"$@" >"${output}" 2>&1 || status=$?
cat "${output}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        printf '### %s\n\n```text\n' "${heading}"
        cat "${output}"
        printf '```\n\n'
    } >>"${GITHUB_STEP_SUMMARY}"
fi

exit "${status}"
