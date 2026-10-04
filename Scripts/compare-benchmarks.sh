#!/usr/bin/env bash
# Compares two sets of benchmark results (the JSON files `make benchmark` writes) and prints how each benchmark's latency
# and throughput changed.
#
# Usage: Scripts/compare-benchmarks.sh <baseline-dir> <current-dir> [--fail-above PERCENT]
#   --fail-above PERCENT   Exit non-zero when any benchmark's p95 is more than PERCENT slower than the baseline.
#
# Benchmarks are matched by name. A benchmark present in only one side is listed but not compared. Numbers from
# different machines or build configurations are not comparable; the script says so when the environments differ.
set -euo pipefail

BASELINE="${1:?usage: compare-benchmarks.sh <baseline-dir> <current-dir> [--fail-above PERCENT]}"
CURRENT="${2:?usage: compare-benchmarks.sh <baseline-dir> <current-dir> [--fail-above PERCENT]}"
FAIL_ABOVE=""
if [[ "${3:-}" == "--fail-above" ]]; then
    FAIL_ABOVE="${4:?--fail-above needs a percentage}"
fi

command -v jq >/dev/null || { echo "compare-benchmarks.sh needs jq" >&2; exit 2; }

# One line per benchmark: name<TAB>p50 ns<TAB>p95 ns<TAB>ops per second. Durations are stored as [seconds, attoseconds].
flatten() {
    jq -r '
        .results[]
        | [ (.group + " / " + .name),
            (.latency.p50[0] * 1e9 + .latency.p50[1] / 1e9),
            (.latency.p95[0] * 1e9 + .latency.p95[1] / 1e9),
            (.latency.count / ((.wall_time[0] * 1e9 + .wall_time[1] / 1e9) / 1e9)) ]
        | @tsv' "$1"/*.json
}

environment() {
    jq -r -s '.[0].environment | "\(.configuration) build, \(.processors) processors"' "$1"/*.json | head -n 1
}

baseline_environment="$(environment "${BASELINE}")"
current_environment="$(environment "${CURRENT}")"
if [[ "${baseline_environment}" != "${current_environment}" ]]; then
    echo "Warning: the environments differ (baseline: ${baseline_environment}; current: ${current_environment})."
    echo "         The comparison is indicative at best."
    echo
fi

join -t $'\t' -j 1 <(flatten "${BASELINE}" | sort -t$'\t' -k1,1) <(flatten "${CURRENT}" | sort -t$'\t' -k1,1) \
    | awk -F'\t' -v limit="${FAIL_ABOVE:-}" '
        function human(ns) {
            if (ns < 1e3) return sprintf("%.0fns", ns)
            if (ns < 1e6) return sprintf("%.1fµs", ns / 1e3)
            if (ns < 1e9) return sprintf("%.2fms", ns / 1e6)
            return sprintf("%.2fs", ns / 1e9)
        }
        BEGIN { printf "%-70s %10s %10s %8s   %10s %10s %8s\n", "benchmark", "p50 was", "p50 now", "change", "ops/s was", "ops/s now", "change" }
        {
            p50change = ($5 - $2) / $2 * 100
            p95change = ($6 - $3) / $3 * 100
            opschange = ($7 - $4) / $4 * 100
            printf "%-70.70s %10s %10s %+7.0f%%   %10.0f %10.0f %+7.0f%%\n", $1, human($2), human($5), p50change, $4, $7, opschange
            if (limit != "" && p95change > limit) { regressions++; printf "    ^ p95 %s -> %s (%+.0f%%) exceeds the %s%% limit\n", human($3), human($6), p95change, limit }
        }
        END { if (regressions > 0) exit 1 }'
