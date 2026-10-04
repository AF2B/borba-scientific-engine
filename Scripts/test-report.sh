#!/usr/bin/env bash
# Runs the tests (or reads the results of a previous run) and reports how long they took: totals, the slowest tests and
# the time per suite. It fails when a test of the fast suites is slower than a limit, because a slow unit test is usually
# a test that waits for something it should not.
#
# Usage: Scripts/test-report.sh [--no-run] [--top N]
#   --no-run   Read the XML of the last run instead of running the tests.
#   --top N    How many of the slowest tests to list (default: 10).
#
# Environment:
#   SWIFT                  The swift executable (default: swift)
#   TEST_FILTER            What to run (default: UnitTests|ContractTests)
#   SLOW_TEST_SECONDS      A test slower than this is flagged (default: 1)
#   FAIL_ON_SLOW           Set to 1 to exit non-zero when any test is flagged (default: 0)
#   TEST_REPORT_DIR        Where the XML is written (default: .artifacts/test-reports)
#
# The XML is JUnit-compatible, so CI can also show it in its own test view.
set -euo pipefail

SWIFT="${SWIFT:-swift}"
TEST_FILTER="${TEST_FILTER:-UnitTests|ContractTests}"
SLOW_TEST_SECONDS="${SLOW_TEST_SECONDS:-1}"
FAIL_ON_SLOW="${FAIL_ON_SLOW:-0}"
REPORT_DIR="${TEST_REPORT_DIR:-.artifacts/test-reports}"
TOP=10
RUN=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-run) RUN=0; shift ;;
        --top) TOP="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

mkdir -p "${REPORT_DIR}"
XML="${REPORT_DIR}/tests.xml"
SWIFT_TESTING_XML="${REPORT_DIR}/tests-swift-testing.xml"

if [[ "${RUN}" -eq 1 ]]; then
    rm -f "${XML}" "${SWIFT_TESTING_XML}"
    LOG="$(mktemp)"
    if ! "${SWIFT}" test --filter "${TEST_FILTER}" --xunit-output "${XML}" >"${LOG}" 2>&1; then
        cat "${LOG}"
        rm -f "${LOG}"
        echo "The tests failed; no report was produced." >&2
        exit 1
    fi
    rm -f "${LOG}"
fi

[[ -f "${SWIFT_TESTING_XML}" ]] || { echo "No test report at ${SWIFT_TESTING_XML}" >&2; exit 2; }

# One line per test case: seconds, suite, name. The attributes of <testcase> may appear in any order.
CASES="$(mktemp)"
trap 'rm -f "${CASES}"' EXIT
awk '
    /<testcase / {
        time = ""; classname = ""; name = ""
        if (match($0, /time="[^"]*"/))      { time = substr($0, RSTART + 6, RLENGTH - 7) }
        if (match($0, /classname="[^"]*"/)) { classname = substr($0, RSTART + 11, RLENGTH - 12) }
        if (match($0, / name="[^"]*"/))     { name = substr($0, RSTART + 7, RLENGTH - 8) }
        printf "%s\t%s\t%s\n", time, classname, name
    }' "${SWIFT_TESTING_XML}" > "${CASES}"

total_tests="$(wc -l < "${CASES}")"
# The wall time of the whole run, as the runner reports it. The times of the individual tests overlap when they run in
# parallel, so their sum overstates it, and a parameterized test's cases share one measurement; read them as a ranking.
wall_seconds="$(awk 'match($0, /<testsuite [^>]*time="[^"]*"/) { s = substr($0, RSTART, RLENGTH); match(s, /time="[^"]*"/); printf "%.2f", substr(s, RSTART + 6, RLENGTH - 7); exit }' "${SWIFT_TESTING_XML}")"
slowest="$(sort -t$'\t' -k1,1 -g -r "${CASES}" | sed -n '1p' | cut -f1)"

printf '\n%s tests in %s s of wall time (the slowest test took %s s)\n' "${total_tests}" "${wall_seconds:-?}" "${slowest:-0}"

printf '\nSlowest tests:\n'
sort -t$'\t' -k1,1 -g -r "${CASES}" | sed -n "1,${TOP}p" | awk -F'\t' '{ printf "  %8.3f s  %s  —  %s\n", $1, $2, $3 }'

printf '\nTime per suite (the sum of its tests, which overlap when they run in parallel):\n'
awk -F'\t' '{ sum[$2] += $1; count[$2]++ } END { for (suite in sum) printf "%8.3f\t%d\t%s\n", sum[suite], count[suite], suite }' "${CASES}" \
    | sort -g -r | sed -n "1,${TOP}p" | awk -F'\t' '{ printf "  %8.3f s  %4d tests  %s\n", $1, $2, $3 }'

flagged="$(awk -F'\t' -v limit="${SLOW_TEST_SECONDS}" '$1 > limit' "${CASES}" | wc -l)"
if [[ "${flagged}" -gt 0 ]]; then
    printf '\n%s test(s) took longer than %s s:\n' "${flagged}" "${SLOW_TEST_SECONDS}"
    awk -F'\t' -v limit="${SLOW_TEST_SECONDS}" '$1 > limit { printf "  %8.3f s  %s  —  %s\n", $1, $2, $3 }' "${CASES}"
    [[ "${FAIL_ON_SLOW}" == "1" ]] && exit 1
fi
printf '\nReport: %s\n' "${SWIFT_TESTING_XML}"
