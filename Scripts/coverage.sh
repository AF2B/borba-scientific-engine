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
#   COVERAGE_SUMMARY               Where the per-file summary is written (default: .artifacts/coverage-summary.json)
#   LLVM_COV                       The llvm-cov command (default: llvm-cov; on macOS: "xcrun llvm-cov")
#
# Requires jq and llvm-cov, which the Swift toolchain provides. The benchmarks are excluded: they measure time and add no
# coverage.
#
# SwiftPM's own export lists every dependency as well and runs to hundreds of megabytes, which jq cannot read without
# gigabytes of memory. llvm-cov summarizes just the project's objects, in a few kilobytes and a fraction of a second, from
# the same profile data, with the same numbers.
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

CODECOV_DIR="$(dirname "$("${SWIFT}" test --show-codecov-path)")"
PROFILE_DATA="${CODECOV_DIR}/default.profdata"
[[ -f "${PROFILE_DATA}" ]] || { echo "No coverage data at ${PROFILE_DATA}; run the tests first" >&2; exit 2; }

read -r -a LLVM_COV_COMMAND <<<"${LLVM_COV:-llvm-cov}"
command -v "${LLVM_COV_COMMAND[0]}" >/dev/null || { echo "coverage.sh needs llvm-cov (set LLVM_COV)" >&2; exit 2; }

# The objects of the project's own targets, wherever the build system keeps them: one per module, or one per source file.
PRODUCTS_DIR="$(dirname "${CODECOV_DIR}")"
objects=()
for target in "${TARGETS[@]}"; do
    while IFS= read -r object; do
        objects+=("${object}")
    done < <(find "${PRODUCTS_DIR}" -path '*/checkouts' -prune -o -type f \
        \( -name "${target}.o" -o -path "*/${target}.build/*.o" \) -print)
done
[[ ${#objects[@]} -gt 0 ]] || { echo "No object files of ${TARGETS[*]} under ${PRODUCTS_DIR}" >&2; exit 2; }

export_arguments=(export --summary-only "-instr-profile=${PROFILE_DATA}" "${objects[0]}")
for object in "${objects[@]:1}"; do
    export_arguments+=(-object "${object}")
done

REPORT="${COVERAGE_SUMMARY:-.artifacts/coverage-summary.json}"
mkdir -p "$(dirname "${REPORT}")"
"${LLVM_COV_COMMAND[@]}" "${export_arguments[@]}" >"${REPORT}"

# Only the project's own sources count.
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
