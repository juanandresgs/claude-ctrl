#!/usr/bin/env bash
# tests/bench-hooks.sh — Single-path hook benchmark script.
#
# Measures per-hook latency using fixture files. Auto-detects the appropriate
# hook for each fixture by name pattern. Outputs timing statistics per hook.
# Supports optional JSON output for CI integration.
#
# Usage: bash tests/bench-hooks.sh [--iterations N] [--fixture FILE] [--json PATH]
#   --iterations N  Number of runs per fixture (default: 5)
#   --fixture FILE  Benchmark only this fixture (default: all fixtures)
#   --json PATH     Write JSON results to this file
#
# @decision DEC-BENCH-001
# @title Single-path hook benchmark using shared timing.sh library
# @status accepted
# @rationale The benchmark previously duplicated timing code from test-helpers.sh
#   with divergent median formulas. Refactored to source tests/lib/timing.sh for
#   consistent lower-median (count+1)/2 formula. No old-hook comparison path —
#   this project uses a single hook config. Auto-detect logic maps fixture names
#   to hooks: guard-*/auto-review-*→pre-bash.sh, write-*/edit-*→pre-write.sh,
#   post-*→post-write.sh, stop-*→stop.sh, task-*→task-track.sh,
#   prompt-*→prompt-submit.sh. Library-load baseline runs first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source test-helpers for colors and make_temp; uses _test_* counters
source "$SCRIPT_DIR/lib/test-helpers.sh"
# Source timing module — defines timing_get_ns, timing_ns_to_ms, timing_compute_stats
source "$SCRIPT_DIR/lib/timing.sh"

FIXTURES_DIR="$SCRIPT_DIR/fixtures"
# HOOKS_DIR is set by test-helpers.sh

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
ITERATIONS=5
SPECIFIC_FIXTURE=""
JSON_OUTPUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iterations)
            shift
            if [[ -z "${1:-}" || ! "$1" =~ ^[0-9]+$ ]]; then
                echo "ERROR: --iterations requires a positive integer" >&2
                exit 1
            fi
            ITERATIONS="$1"
            shift
            ;;
        --fixture)
            shift
            SPECIFIC_FIXTURE="${1:-}"
            shift
            ;;
        --json)
            shift
            JSON_OUTPUT="${1:-}"
            shift
            ;;
        --help|-h)
            echo "Usage: bash tests/bench-hooks.sh [--iterations N] [--fixture FILE] [--json PATH]"
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Hook auto-detection by fixture name
# ---------------------------------------------------------------------------

# detect_hook FIXTURE_BASENAME → prints hook path or empty string
detect_hook() {
    local name="$1"
    case "$name" in
        guard-*|auto-review-*)
            echo "$HOOKS_DIR/pre-bash.sh"
            ;;
        write-*|edit-*)
            echo "$HOOKS_DIR/pre-write.sh"
            ;;
        post-*)
            echo "$HOOKS_DIR/post-write.sh"
            ;;
        stop-*)
            echo "$HOOKS_DIR/stop.sh"
            ;;
        task-*)
            echo "$HOOKS_DIR/task-track.sh"
            ;;
        prompt-*)
            echo "$HOOKS_DIR/prompt-submit.sh"
            ;;
        *)
            echo ""
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Benchmark a single fixture
# ---------------------------------------------------------------------------

# bench_fixture FIXTURE_PATH HOOK_PATH ITERATIONS
#   Runs the hook ITERATIONS times on the fixture, collects timing.
#   Prints one result line: "BENCH fixture_name hook_name median mean min max p95 ms"
bench_fixture() {
    local fixture_path="$1"
    local hook_path="$2"
    local n="$3"
    local fixture_name
    fixture_name=$(basename "$fixture_path" .json)
    local hook_name
    hook_name=$(basename "$hook_path")

    local times_raw=""
    local i t_start t_end elapsed_ms
    for i in $(seq 1 "$n"); do
        t_start=$(timing_get_ns)
        bash "$hook_path" < "$fixture_path" >/dev/null 2>/dev/null || true
        t_end=$(timing_get_ns)
        elapsed_ms=$(timing_ns_to_ms $(( t_end - t_start )))
        times_raw="${times_raw}${elapsed_ms}"$'\n'
    done

    # Sort values for statistics
    local sorted
    sorted=$(echo "$times_raw" | grep -v '^$' | sort -n)

    local stats
    stats=$(timing_compute_stats "$sorted")
    local median mean min max p95
    read -r median mean min max p95 <<< "$stats"

    printf "BENCH  %-40s  %-20s  median=%dms  mean=%dms  min=%dms  max=%dms  p95=%dms\n" \
        "$fixture_name" "$hook_name" "$median" "$mean" "$min" "$max" "$p95"

    # Emit JSON record if accumulator file is set
    if [[ -n "${BENCH_JSON_FILE:-}" ]]; then
        printf '{"fixture":"%s","hook":"%s","iterations":%d,"median":%d,"mean":%d,"min":%d,"max":%d,"p95":%d}\n' \
            "$fixture_name" "$hook_name" "$n" "$median" "$mean" "$min" "$max" "$p95" \
            >> "$BENCH_JSON_FILE"
    fi
}

# ---------------------------------------------------------------------------
# Baseline: library-load time
# ---------------------------------------------------------------------------
echo "=== Hook Benchmark ==="
echo "Hooks dir:    $HOOKS_DIR"
echo "Fixtures dir: $FIXTURES_DIR"
echo "Iterations:   $ITERATIONS"
echo ""
echo "--- Library-Load Baseline ---"

# Measure source-lib.sh (bootstrapper) source time — formerly context-lib.sh baseline
BASELINE_TIMES=""
for i in $(seq 1 "$ITERATIONS"); do
    t_start=$(timing_get_ns)
    bash -c "source '$HOOKS_DIR/source-lib.sh'" >/dev/null 2>/dev/null || true
    t_end=$(timing_get_ns)
    elapsed_ms=$(timing_ns_to_ms $(( t_end - t_start )))
    BASELINE_TIMES="${BASELINE_TIMES}${elapsed_ms}"$'\n'
done

BASELINE_SORTED=$(echo "$BASELINE_TIMES" | grep -v '^$' | sort -n)
BASELINE_STATS=$(timing_compute_stats "$BASELINE_SORTED")
read -r b_median b_mean b_min b_max b_p95 <<< "$BASELINE_STATS"
printf "BENCH  %-40s  %-20s  median=%dms  mean=%dms  min=%dms  max=%dms  p95=%dms\n" \
    "source-lib.sh (source)" "baseline" "$b_median" "$b_mean" "$b_min" "$b_max" "$b_p95"
echo ""

# ---------------------------------------------------------------------------
# JSON accumulator setup
# ---------------------------------------------------------------------------
BENCH_JSON_FILE=""
if [[ -n "$JSON_OUTPUT" ]]; then
    BENCH_JSON_FILE=$(mktemp "${TMPDIR:-/tmp}/bench-results-XXXXXX")
    export BENCH_JSON_FILE
fi

# ---------------------------------------------------------------------------
# Fixture benchmarks
# ---------------------------------------------------------------------------
echo "--- Fixture Benchmarks ---"

if [[ -n "$SPECIFIC_FIXTURE" ]]; then
    # Single fixture mode
    if [[ ! -f "$SPECIFIC_FIXTURE" ]]; then
        echo "ERROR: fixture not found: $SPECIFIC_FIXTURE" >&2
        exit 1
    fi
    fname=$(basename "$SPECIFIC_FIXTURE" .json)
    hook=$(detect_hook "$fname")
    if [[ -z "$hook" || ! -f "$hook" ]]; then
        echo "SKIP  $fname — no hook detected"
    else
        bench_fixture "$SPECIFIC_FIXTURE" "$hook" "$ITERATIONS"
    fi
else
    # All fixtures mode
    bench_count=0
    skip_count=0
    for fixture_path in "$FIXTURES_DIR"/*.json; do
        [[ -f "$fixture_path" ]] || continue
        fname=$(basename "$fixture_path" .json)
        hook=$(detect_hook "$fname")
        if [[ -z "$hook" || ! -f "$hook" ]]; then
            skip_count=$((skip_count + 1))
            continue
        fi
        bench_fixture "$fixture_path" "$hook" "$ITERATIONS"
        bench_count=$((bench_count + 1))
    done
    echo ""
    echo "Benchmarked: $bench_count fixtures | Skipped (no hook match): $skip_count"
fi

# ---------------------------------------------------------------------------
# JSON output finalization
# ---------------------------------------------------------------------------
if [[ -n "$JSON_OUTPUT" && -n "$BENCH_JSON_FILE" ]]; then
    mkdir -p "$(dirname "$JSON_OUTPUT")"
    local_count=$(grep -c '^{' "$BENCH_JSON_FILE" 2>/dev/null || echo 0)
    # Wrap in envelope
    {
        echo "{"
        printf '  "timestamp": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
        printf '  "iterations": %d,\n' "$ITERATIONS"
        printf '  "baseline": {"median":%d,"mean":%d,"min":%d,"max":%d,"p95":%d},\n' \
            "$b_median" "$b_mean" "$b_min" "$b_max" "$b_p95"
        echo '  "results": ['
        # Convert newline-delimited JSON objects to array
        first=true
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if [[ "$first" == "true" ]]; then
                echo "    $line"
                first=false
            else
                echo "    ,$line"
            fi
        done < "$BENCH_JSON_FILE"
        echo "  ]"
        echo "}"
    } > "$JSON_OUTPUT"
    rm -f "$BENCH_JSON_FILE"
    echo ""
    echo "JSON results written to: $JSON_OUTPUT"
fi

echo ""
echo "=== Benchmark complete ==="
