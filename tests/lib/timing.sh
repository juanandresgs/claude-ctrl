#!/usr/bin/env bash
# tests/lib/timing.sh — Shared nanosecond/microsecond timing module for hook benchmarks.
#
# Provides consistent timing functions used by bench-hooks.sh and test-helpers.sh.
# Resolves divergent median formulas between the two consumers: uses lower-median
# formula (count+1)/2 consistently across all callers.
#
# @decision DEC-REMED-007
# @title Shared tests/lib/timing.sh with consistent lower-median formula
# @status accepted
# @rationale bench-hooks.sh and test-helpers.sh both implemented timing code
#   but diverged: bench-hooks.sh used correct lower-median (count+1)/2 while
#   test-helpers.sh used count/2 (wrong for even-count arrays — returns the
#   element before the midpoint). Extracting to a shared module eliminates
#   the duplication and fixes the divergence. test-helpers.sh's time_hook()
#   had dead code at line 357 (elapsed_ms computed then immediately overwritten)
#   which is cleaned up here. The python3 microsecond fallback is maintained
#   for macOS where date +%s%N returns literal '%N'.
#   Consumers source this file and call: timing_get_ns, timing_ns_to_ms,
#   timing_compute_stats "$sorted_newline_separated_values"
#   → returns "median mean min max p95" space-separated.

# ---------------------------------------------------------------------------
# Platform detection — done once at source time
# ---------------------------------------------------------------------------

# Test whether date +%s%N gives nanoseconds (Linux) or literal %N (macOS).
# On macOS, the result is short (< 15 chars); on Linux it's 19 chars.
_TIMING_USE_PYTHON=false
_timing_test=$(date +%s%N 2>/dev/null || echo "0")
if [[ ${#_timing_test} -lt 15 ]]; then
    _TIMING_USE_PYTHON=true
fi

# timing_get_ns
#   Return current time in nanoseconds (Linux) or microseconds (macOS via python3).
#   Always returns an integer; prints 0 on error.
timing_get_ns() {
    if [[ "$_TIMING_USE_PYTHON" == "true" ]]; then
        python3 -c "import time; print(int(time.time()*1e6))" 2>/dev/null || echo 0
    else
        date +%s%N 2>/dev/null || echo 0
    fi
}

# timing_ns_to_ms RAW_VALUE
#   Convert the raw value from timing_get_ns() to milliseconds (integer).
#   Linux path: raw is nanoseconds → divide by 1,000,000.
#   macOS path: raw is microseconds → divide by 1,000.
timing_ns_to_ms() {
    local ns="$1"
    if [[ "$_TIMING_USE_PYTHON" == "true" ]]; then
        echo $(( ns / 1000 ))
    else
        echo $(( ns / 1000000 ))
    fi
}

# timing_compute_stats SORTED_VALUES
#   Compute timing statistics from newline-separated sorted integer values.
#   Uses lower-median: index = (count+1)/2 (1-based, consistent with bench-hooks.sh).
#   Outputs: "median mean min max p95" space-separated (all in ms).
#
#   Example:
#     sorted="10\n20\n30\n40\n50"
#     timing_compute_stats "$sorted"
#     # → "30 30 10 50 47"
timing_compute_stats() {
    local sorted="$1"
    local count min max sum mean median p95

    count=$(echo "$sorted" | wc -l | tr -d ' ')
    min=$(echo "$sorted" | head -1)
    max=$(echo "$sorted" | tail -1)

    sum=0
    while IFS= read -r val; do sum=$((sum + val)); done <<< "$sorted"
    mean=$((sum / count))

    # Lower-median: (count+1)/2 gives element at or just below midpoint.
    # For count=5: (5+1)/2=3 → element 3 (correct median for odd)
    # For count=4: (4+1)/2=2 → element 2 (lower of the two middle elements)
    local mid=$(( (count + 1) / 2 ))
    [[ $mid -lt 1 ]] && mid=1
    median=$(echo "$sorted" | sed -n "${mid}p")

    local p95_idx=$(( (count * 95) / 100 ))
    [[ $p95_idx -lt 1 ]] && p95_idx=1
    p95=$(echo "$sorted" | sed -n "${p95_idx}p")

    echo "${median} ${mean} ${min} ${max} ${p95}"
}
