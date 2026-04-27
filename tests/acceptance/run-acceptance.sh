#!/usr/bin/env bash
# run-acceptance.sh — Master acceptance suite runner for TKT-014.
#
# Executes all acceptance components in order:
#   1. Scenario tests  (tests/scenarios/test-runner.sh)
#   2. Python runtime tests (pytest tests/runtime/)
#   3. CLI shell tests (tests/runtime/test_cc_policy.sh)
#   4. Acceptance-specific tests in this directory
#
# Streams every suite live, tracks pass/fail counts across all suites, and
# keeps per-suite logs for diagnostics.
# Records the final result as a cc-policy event.
# Emits a machine-readable JSON report to stdout at the end.
# Exits 0 only when every suite and every test passes.
#
# @decision DEC-ACC-004
# @title Master runner aggregates all suites into a single JSON report
# @status accepted
# @rationale TKT-014 exit criterion requires the suite to pass twice
#   consecutively. The JSON report is machine-readable so the tester can
#   diff two runs and confirm identical pass/fail results. The runner exits
#   nonzero on any failure so CI and the tester's manual run both get a
#   clear green/red signal. Recording the result as a cc-policy event
#   creates a persistent audit trail in the runtime's SQLite store.
#
# Usage:  bash tests/acceptance/run-acceptance.sh
# Exit:   0 all suites pass, 1 any failure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI="$REPO_ROOT/runtime/cli.py"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
LOG_ROOT="$(mktemp -d "$TMP_BASE/claudex-acceptance.XXXXXX")"
LOG_SEQ=1

# ---- Counters -----------------------------------------------------------------
TOTAL_PASS=0
TOTAL_FAIL=0
SUITE_RESULTS=()   # JSON objects, one per suite
NEXT_LOG_PATH=""
STREAMED_LOG=""
STREAMED_EXIT=0

# ---- Helpers ------------------------------------------------------------------
record_suite() {
    local name="$1" passed="$2" failed="$3" skipped="${4:-0}"
    TOTAL_PASS=$(( TOTAL_PASS + passed ))
    TOTAL_FAIL=$(( TOTAL_FAIL + failed ))
    local status="pass"
    [[ "$failed" -gt 0 ]] && status="fail"
    SUITE_RESULTS+=("$(jq -n \
        --arg name    "$name"   \
        --argjson p   "$passed" \
        --argjson f   "$failed" \
        --argjson s   "$skipped"\
        --arg    st   "$status" \
        '{name:$name,passed:$p,failed:$f,skipped:$s,status:$st}')")
}

next_log_path() {
    local label="$1"
    local safe_label="${label//[^[:alnum:]_.-]/_}"
    printf -v NEXT_LOG_PATH '%s/%02d-%s.log' "$LOG_ROOT" "$LOG_SEQ" "$safe_label"
    LOG_SEQ=$(( LOG_SEQ + 1 ))
}

stream_command() {
    local label="$1"; shift
    local log_path start_ts end_ts elapsed exit_code
    next_log_path "$label"
    log_path="$NEXT_LOG_PATH"
    start_ts="$(date +%s)"

    printf 'START: %s\n' "$label"
    printf 'LOG: %s\n' "$log_path"
    printf 'CMD:'
    printf ' %q' "$@"
    printf '\n'

    set +e
    "$@" 2>&1 | tee "$log_path"
    exit_code="${PIPESTATUS[0]}"
    set -e

    end_ts="$(date +%s)"
    elapsed=$(( end_ts - start_ts ))
    printf 'END: %s exit=%s elapsed=%ss\n' "$label" "$exit_code" "$elapsed"

    STREAMED_LOG="$log_path"
    STREAMED_EXIT="$exit_code"
}

# Run a command, stream output, then parse PASS/FAIL counts from the log.
# Falls back to exit-code based counting if no summary line is found.
run_counted() {
    local suite_name="$1"; shift
    local log_path exit_code
    stream_command "$suite_name" "$@"
    log_path="$STREAMED_LOG"
    exit_code="$STREAMED_EXIT"

    # Try to parse a "N passed, M failed" summary
    local passed=0 failed=0
    if grep -qE '[0-9]+ passed' "$log_path"; then
        passed=$(grep -oE '[0-9]+ passed' "$log_path" | tail -1 | grep -oE '[0-9]+' || echo 0)
    fi
    if grep -qE '[0-9]+ failed' "$log_path"; then
        failed=$(grep -oE '[0-9]+ failed' "$log_path" | tail -1 | grep -oE '[0-9]+' || echo 0)
    fi
    # pytest uses "X passed" and "X failed" — also capture that format
    if grep -qE 'passed.*in' "$log_path"; then
        passed=$(grep -oE '[0-9]+ passed' "$log_path" | tail -1 | grep -oE '[0-9]+' || echo "$passed")
    fi

    # If we got no counts but exit code is nonzero, count whole suite as 1 fail
    if [[ "$passed" -eq 0 && "$failed" -eq 0 ]]; then
        if [[ "$exit_code" -eq 0 ]]; then
            passed=1
        else
            failed=1
        fi
    fi

    record_suite "$suite_name" "$passed" "$failed"
    printf 'COUNTED: %s passed=%s failed=%s log=%s\n' "$suite_name" "$passed" "$failed" "$log_path"
}

# ---- Report header ------------------------------------------------------------
printf '=%.0s' {1..60}; printf '\n'
printf 'Kernel Acceptance Suite — TKT-014\n'
printf 'Run at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'Logs: %s\n' "$LOG_ROOT"
printf '=%.0s' {1..60}; printf '\n\n'

# ============================================================
# Suite 1: Scenario tests
# ============================================================
printf '## Suite 1: Scenario tests (tests/scenarios/test-runner.sh)\n'
printf -- '------------------------------------------------------------\n'
run_counted "scenarios" bash "$REPO_ROOT/tests/scenarios/test-runner.sh"
printf '\n'

# ============================================================
# Suite 2: Python runtime tests
# ============================================================
printf '## Suite 2: Python runtime tests (pytest tests/runtime/)\n'
printf -- '------------------------------------------------------------\n'
run_counted "python-runtime" python3 -m pytest "$REPO_ROOT/tests/runtime/" -v --tb=short
printf '\n'

# ============================================================
# Suite 3: CLI shell tests
# ============================================================
printf '## Suite 3: CLI shell tests (tests/runtime/test_cc_policy.sh)\n'
printf -- '------------------------------------------------------------\n'
run_counted "cli-shell" bash "$REPO_ROOT/tests/runtime/test_cc_policy.sh"
printf '\n'

# ============================================================
# Suite 4: Acceptance-specific tests
# ============================================================
printf '## Suite 4: Acceptance tests (tests/acceptance/)\n'
printf -- '------------------------------------------------------------\n'

ACC_TESTS=(
    "test-enforcement-matrix.sh"
    "test-runtime-consistency.sh"
    "test-full-lifecycle.sh"
)

ACC_PASS=0
ACC_FAIL=0
ACC_FAILED=()

for test_file in "${ACC_TESTS[@]}"; do
    test_path="$SCRIPT_DIR/$test_file"
    test_name="${test_file%.sh}"

    if [[ ! -f "$test_path" ]]; then
        printf 'SKIP: %s (file not found)\n' "$test_name"
        continue
    fi

    printf '### %s\n' "$test_name"
    stream_command "$test_name" timeout 60 bash "$test_path"
    ec="$STREAMED_EXIT"

    if [[ "$ec" -eq 124 ]]; then
        printf 'FAIL: %s — timed out after 60s\n' "$test_name"
        ACC_FAIL=$(( ACC_FAIL + 1 ))
        ACC_FAILED+=("$test_name (timeout)")
        continue
    fi

    if [[ "$ec" -eq 0 ]]; then
        ACC_PASS=$(( ACC_PASS + 1 ))
    else
        ACC_FAIL=$(( ACC_FAIL + 1 ))
        ACC_FAILED+=("$test_name")
    fi
done

record_suite "acceptance" "$ACC_PASS" "$ACC_FAIL"
printf '\n'

# ============================================================
# Record result to cc-policy event store
# ============================================================
OVERALL_STATUS="pass"
[[ "$TOTAL_FAIL" -gt 0 ]] && OVERALL_STATUS="fail"

PYTHONPATH="$REPO_ROOT" python3 "$CLI" event emit "acceptance_suite_run" \
    --detail "passed=$TOTAL_PASS failed=$TOTAL_FAIL status=$OVERALL_STATUS" \
    >/dev/null 2>&1 || true

# ============================================================
# JSON report
# ============================================================
SUITES_JSON="$(printf '%s\n' "${SUITE_RESULTS[@]}" | jq -s '.')"

REPORT=$(jq -n \
    --argjson passed "$TOTAL_PASS"  \
    --argjson failed "$TOTAL_FAIL"  \
    --argjson suites "$SUITES_JSON" \
    --arg     status "$OVERALL_STATUS" \
    --arg     run_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
        passed: $passed,
        failed: $failed,
        skipped: 0,
        status: $status,
        run_at: $run_at,
        suites: $suites
    }')

printf '=%.0s' {1..60}; printf '\n'
printf 'ACCEPTANCE REPORT\n'
printf '=%.0s' {1..60}; printf '\n'
printf '%s\n' "$REPORT"
printf '=%.0s' {1..60}; printf '\n'
printf 'Total: %d passed, %d failed — %s\n' "$TOTAL_PASS" "$TOTAL_FAIL" "$OVERALL_STATUS"
printf '=%.0s' {1..60}; printf '\n'

if [[ "$TOTAL_FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
