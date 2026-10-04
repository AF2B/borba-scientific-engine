#!/usr/bin/env bash
# Runs the test suites with code coverage and enforces a minimum line coverage per source target.
#
# Usage: Scripts/coverage.sh [--no-run]
#   --no-run   Reuse the coverage data of the last `swift test --enable-code-coverage` instead of running the tests.
#
# Environment:
#   SWIFT                          The swift executable (default: swift)
#   COVERAGE_CORE_MINIMUM          Minimum line coverage of BorbaScientificCore, in percent (default: 95)
#   COVERAGE_PERSISTENCE_MINIMUM   ... of BorbaScientificPersistence (default: 90)
#   COVERAGE_ENGINE_MINIMUM        ... of BorbaScientificEngine (default: 90)
#   TEST_DATABASE_URL              PostgreSQL server for the integration tests (they are skipped without it)
#
# Requires jq. The benchmarks are excluded: they measure time and add no coverage.
set -euo pipefail

SWIFT="${SWIFT:-swift}"
LOWEST_FILES=5

declare -A MINIMUMS=(
    [BorbaScientificCore]="${COVERAGE_CORE_MINIMUM:-95}"
    [BorbaScientificPersistence]="${COVERAGE_PERSISTENCE_MINIMUM:-90}"
    [BorbaScientificEngine]="${COVERAGE_ENGINE_MINIMUM:-90}"
)
TARGETS=(BorbaScientificCore BorbaScientificPersistence BorbaScientificEngine)

command -v jq >/dev/null || { echo "coverage.sh needs jq" >&2; exit 2; }

if [[ "${1:-}" != "--no-run" ]]; then
    "${SWIFT}" test --enable-code-coverage --skip PerformanceTests
fi

REPORT="$("${SWIFT}" test --show-codecov-path)"
[[ -f "${REPORT}" ]] || { echo "No coverage data at ${REPORT}; run the tests first" >&2; exit 2; }

# Only the project's own sources count: the coverage data also lists every dependency.
ROOT="$(pwd -P)"

failures=0
printf '\n%-30s %12s %9s %9s  %s\n' "target" "lines" "coverage" "minimum" "status"
printf '%s\n' "-----------------------------------------------------------------------------"

for target in "${TARGETS[@]}"; do
    read -r covered total < <(jq -r --arg root "${ROOT}" --arg target "${target}" '
        [.data[0].files[] | select(.filename | startswith($root + "/Sources/" + $target + "/"))]
        | "\(map(.summary.lines.covered) | add) \(map(.summary.lines.count) | add)"' "${REPORT}")

    percent="$(awk -v c="${covered}" -v t="${total}" 'BEGIN { printf "%.2f", (t == 0 ? 0 : c * 100 / t) }')"
    minimum="${MINIMUMS[${target}]}"
    if awk -v p="${percent}" -v m="${minimum}" 'BEGIN { exit !(p >= m) }'; then
        status="ok"
    else
        status="BELOW MINIMUM"
        failures=$((failures + 1))
    fi
    printf '%-30s %5s/%-6s %8s%% %8s%%  %s\n' "${target}" "${covered}" "${total}" "${percent}" "${minimum}" "${status}"
done

printf '\nLeast covered files (lines):\n'
jq -r --arg root "${ROOT}" '.data[0].files[]
    | select(.filename | startswith($root + "/Sources/"))
    | select(.summary.lines.count >= 10)
    | "\(.summary.lines.percent | floor)\t\(.summary.lines.count)\t\(.filename | ltrimstr($root + "/"))"' "${REPORT}" \
    | sort -n | sed -n "1,${LOWEST_FILES}p" | awk -F'\t' '{ printf "  %3s%%  %5s lines  %s\n", $1, $2, $3 }'

if [[ "${failures}" -ne 0 ]]; then
    printf '\nCoverage is below the minimum for %s target(s).\n' "${failures}" >&2
    exit 1
fi
printf '\nCoverage meets every minimum.\n'
