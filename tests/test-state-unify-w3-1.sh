#!/usr/bin/env bash
# test-state-unify-w3-1.sh — Tests for State Unification Wave 3-1.
#
# Validates: agent_markers table creation, marker_create, marker_query,
# marker_update, marker_cleanup, PID liveness checks, UNIQUE constraint,
# concurrent marker creation, and pre-dispatch status support.
#
# Usage: bash tests/test-state-unify-w3-1.sh
#
# Design mirrors test-sqlite-state.sh: isolated CLAUDE_DIR per test,
# _run_state helper for subshell sourcing, pass_test/fail_test counters
# at top level. Pass/fail decisions are always at top level (not subshells)
# to ensure counter increments work correctly.
#
# Critical: grep pipelines that may return no matches use "|| echo '0'" to
# prevent set -euo pipefail from terminating the script on grep's exit code 1.
# All _run_state calls use "|| true" when the subshell may fail (e.g. calling
# functions that don't exist yet — failure is the expected pre-impl state).
#
# @decision DEC-STATE-UNIFY-TEST-003
# @title Isolated temp DB per test for W3-1 agent_markers tests
# @status accepted
# @rationale Each test needs a fresh DB to confirm table creation and
#   marker lifecycle without cross-test state contamination. Concurrent
#   tests (T11) use a single shared DB since they test multi-writer behavior.
#   PID liveness tests (T06, T09) use real PID values from the test process
#   to create live markers, then dead PIDs from killed subprocesses.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT_OUTER="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT_OUTER/hooks"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "Running: $test_name"
}

pass_test() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  PASS"
}

fail_test() {
    local reason="$1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $reason"
}

# Global tmp dir — cleaned on EXIT
TMPDIR_BASE="$PROJECT_ROOT_OUTER/tmp/test-state-unify-w3-1-$$"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# _run_state — execute state-lib operations in an isolated bash subshell.
# Usage: _run_state CLAUDE_DIR PROJECT_ROOT_PATH "bash code using state functions"
# The subshell sources hooks, resets module guards, exports env, and runs the code.
_run_state() {
    local cd="$1"
    local pr="$2"
    local code="$3"
    bash -c "
source '${HOOKS_DIR}/source-lib.sh' 2>/dev/null
require_state
_STATE_SCHEMA_INITIALIZED=''
_WORKFLOW_ID=''
export CLAUDE_DIR='${cd}'
export PROJECT_ROOT='${pr}'
export CLAUDE_SESSION_ID='test-session-\$\$'
${code}
" 2>/dev/null
}

# _setup — create an isolated env for a test and set up a git repo.
# Outputs: sets _CD (CLAUDE_DIR) and _PR (PROJECT_ROOT) for the test.
_setup() {
    local test_id="$1"
    _CD="${TMPDIR_BASE}/${test_id}/claude"
    _PR="${TMPDIR_BASE}/${test_id}/project"
    mkdir -p "${_CD}/state" "${_PR}"
    git -C "${_PR}" init -q 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# T01: agent_markers table created on first state operation
# ─────────────────────────────────────────────────────────────────────────────
run_test "T01: agent_markers table created on first state operation"
_setup t01

_run_state "$_CD" "$_PR" "state_update 'boot' 'ok' 'test'" || true

_T01_DB="${_CD}/state/state.db"
_T01_FAIL=""

if [[ ! -f "$_T01_DB" ]]; then
    _T01_FAIL="state.db was not created at ${_T01_DB}"
else
    _T01_TABLES=$(sqlite3 "$_T01_DB" ".tables" 2>/dev/null | tr ' ' '\n' | grep -cE '^agent_markers$' || true)
    _T01_TABLES="${_T01_TABLES:-0}"
    # Strip any whitespace/newlines from grep -c output
    _T01_TABLES="${_T01_TABLES//[[:space:]]/}"
    if [[ "$_T01_TABLES" -ne 1 ]]; then
        _T01_FAIL="agent_markers table not found in schema (tables: $(sqlite3 "$_T01_DB" ".tables" 2>/dev/null))"
    fi
fi

[[ -z "$_T01_FAIL" ]] && pass_test || fail_test "$_T01_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T02: marker_create writes correct marker
# ─────────────────────────────────────────────────────────────────────────────
run_test "T02: marker_create writes correct marker with expected columns"
_setup t02

_T02_PID="$$"
_run_state "$_CD" "$_PR" "
marker_create 'implementer' 'sess-abc' 'wf-xyz' '${_T02_PID}' 'trace-001' 'active'
" || true

_T02_DB="${_CD}/state/state.db"
_T02_FAIL=""

if [[ ! -f "$_T02_DB" ]]; then
    _T02_FAIL="state.db not created"
else
    _T02_ROW=$(sqlite3 "$_T02_DB" "SELECT agent_type||'|'||session_id||'|'||workflow_id||'|'||status||'|'||pid FROM agent_markers WHERE agent_type='implementer' LIMIT 1;" 2>/dev/null || echo "")
    if [[ "$_T02_ROW" != "implementer|sess-abc|wf-xyz|active|${_T02_PID}" ]]; then
        _T02_FAIL="Expected 'implementer|sess-abc|wf-xyz|active|${_T02_PID}', got '${_T02_ROW}'"
    fi
fi

[[ -z "$_T02_FAIL" ]] && pass_test || fail_test "$_T02_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T03: marker_query returns pipe-delimited format
# ─────────────────────────────────────────────────────────────────────────────
run_test "T03: marker_query returns pipe-delimited format with 7 fields"
_setup t03

_T03_PID="$$"
_T03_RESULT=$(_run_state "$_CD" "$_PR" "
marker_create 'guardian' 'sess-t03' 'wf-t03' '${_T03_PID}' 'trace-t03' 'active'
marker_query 'guardian' 'wf-t03'
" || true)

_T03_FAIL=""
# Format: agent_type|session_id|workflow_id|status|pid|created_at|trace_id
if [[ -z "$_T03_RESULT" ]]; then
    _T03_FAIL="marker_query returned empty output"
else
    _T03_FIELD_COUNT=$(echo "$_T03_RESULT" | awk -F'|' '{print NF}')
    if [[ "$_T03_FIELD_COUNT" -ne 7 ]]; then
        _T03_FAIL="Expected 7 pipe-delimited fields, got ${_T03_FIELD_COUNT} in '${_T03_RESULT}'"
    else
        _T03_TYPE=$(echo "$_T03_RESULT" | cut -d'|' -f1)
        _T03_STATUS=$(echo "$_T03_RESULT" | cut -d'|' -f4)
        if [[ "$_T03_TYPE" != "guardian" ]]; then
            _T03_FAIL="Expected agent_type 'guardian', got '${_T03_TYPE}'"
        elif [[ "$_T03_STATUS" != "active" ]]; then
            _T03_FAIL="Expected status 'active', got '${_T03_STATUS}'"
        fi
    fi
fi

[[ -z "$_T03_FAIL" ]] && pass_test || fail_test "$_T03_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T04: marker_query filters by agent_type
# ─────────────────────────────────────────────────────────────────────────────
run_test "T04: marker_query filters by agent_type — returns only matching type"
_setup t04

_T04_PID="$$"
_T04_RESULT=$(_run_state "$_CD" "$_PR" "
marker_create 'implementer' 'sess-t04' 'wf-t04a' '${_T04_PID}' '' 'active'
marker_create 'tester'      'sess-t04' 'wf-t04b' '${_T04_PID}' '' 'active'
marker_create 'guardian'    'sess-t04' 'wf-t04c' '${_T04_PID}' '' 'active'
marker_query 'tester'
" || true)

_T04_FAIL=""
_T04_WRONG=$(echo "$_T04_RESULT" | grep -v '^tester|' | grep -v '^$' || true)
_T04_COUNT=$(echo "$_T04_RESULT" | grep -cE '^tester\|' || true)
_T04_COUNT="${_T04_COUNT:-0}"
_T04_COUNT="${_T04_COUNT//[[:space:]]/}"
if [[ -z "$_T04_RESULT" ]]; then
    _T04_FAIL="marker_query returned empty output"
elif [[ -n "$_T04_WRONG" ]]; then
    _T04_FAIL="marker_query 'tester' returned non-tester line(s): '${_T04_WRONG}'"
elif [[ "$_T04_COUNT" -ne 1 ]]; then
    _T04_FAIL="Expected 1 tester marker, got ${_T04_COUNT}"
fi

[[ -z "$_T04_FAIL" ]] && pass_test || fail_test "$_T04_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T05: marker_query filters by workflow_id
# ─────────────────────────────────────────────────────────────────────────────
run_test "T05: marker_query filters by workflow_id — returns only matching workflow"
_setup t05

_T05_PID="$$"
_T05_RESULT=$(_run_state "$_CD" "$_PR" "
marker_create 'implementer' 'sess-t05' 'wf-target' '${_T05_PID}' '' 'active'
marker_create 'implementer' 'sess-t05' 'wf-other1' '${_T05_PID}' '' 'active'
marker_create 'implementer' 'sess-t05' 'wf-other2' '${_T05_PID}' '' 'active'
marker_query 'implementer' 'wf-target'
" || true)

_T05_FAIL=""
if [[ -z "$_T05_RESULT" ]]; then
    _T05_FAIL="marker_query returned empty output"
else
    _T05_COUNT=$(echo "$_T05_RESULT" | grep -cE '^implementer\|' || true)
    _T05_COUNT="${_T05_COUNT:-0}"
    _T05_COUNT="${_T05_COUNT//[[:space:]]/}"
    _T05_WF=$(echo "$_T05_RESULT" | cut -d'|' -f3)
    if [[ "$_T05_COUNT" -ne 1 ]]; then
        _T05_FAIL="Expected 1 result, got ${_T05_COUNT}: '${_T05_RESULT}'"
    elif [[ "$_T05_WF" != "wf-target" ]]; then
        _T05_FAIL="Expected workflow_id 'wf-target', got '${_T05_WF}'"
    fi
fi

[[ -z "$_T05_FAIL" ]] && pass_test || fail_test "$_T05_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T06: marker_query with PID liveness — dead PID auto-marks as crashed
# ─────────────────────────────────────────────────────────────────────────────
run_test "T06: marker_query — dead PID auto-marks marker as crashed (self-healing)"
_setup t06

# Start a short-lived background process and capture its PID
sleep 30 &
_T06_DEAD_PID=$!
# Kill it immediately so PID is dead
kill "$_T06_DEAD_PID" 2>/dev/null || true
wait "$_T06_DEAD_PID" 2>/dev/null || true

_T06_LIVE_PID="$$"
_T06_DB="${_CD}/state/state.db"

# Insert markers — one with dead PID, one with live PID
_run_state "$_CD" "$_PR" "
marker_create 'tester' 'sess-t06' 'wf-dead' '${_T06_DEAD_PID}' '' 'active'
marker_create 'tester' 'sess-t06' 'wf-live' '${_T06_LIVE_PID}' '' 'active'
" || true

# Run marker_query — should self-heal the dead-PID marker to 'crashed'
# and only return the live one
_T06_RESULT=$(_run_state "$_CD" "$_PR" "
marker_query 'tester'
" || true)

_T06_FAIL=""
# The dead PID marker should not appear in results (filtered as crashed)
_T06_COUNT=$(echo "$_T06_RESULT" | grep -cE '^tester\|' || true)
_T06_COUNT="${_T06_COUNT:-0}"
_T06_COUNT="${_T06_COUNT//[[:space:]]/}"
if [[ "$_T06_COUNT" -ne 1 ]]; then
    _T06_FAIL="Expected 1 active marker (dead PID filtered), got ${_T06_COUNT}: '${_T06_RESULT}'"
else
    _T06_WF=$(echo "$_T06_RESULT" | cut -d'|' -f3)
    if [[ "$_T06_WF" != "wf-live" ]]; then
        _T06_FAIL="Expected only 'wf-live' marker returned, got wf='${_T06_WF}'"
    fi
fi

# Verify the dead-PID marker was updated to 'crashed' in DB
if [[ -z "$_T06_FAIL" && -f "$_T06_DB" ]]; then
    _T06_CRASHED_STATUS=$(sqlite3 "$_T06_DB" "SELECT status FROM agent_markers WHERE workflow_id='wf-dead';" 2>/dev/null || echo "")
    if [[ "$_T06_CRASHED_STATUS" != "crashed" ]]; then
        _T06_FAIL="Dead-PID marker not updated to 'crashed' in DB, got '${_T06_CRASHED_STATUS}'"
    fi
fi

[[ -z "$_T06_FAIL" ]] && pass_test || fail_test "$_T06_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T07: marker_update transitions status correctly
# ─────────────────────────────────────────────────────────────────────────────
run_test "T07: marker_update transitions status correctly"
_setup t07

_T07_PID="$$"
_T07_DB="${_CD}/state/state.db"

_run_state "$_CD" "$_PR" "
marker_create 'implementer' 'sess-t07' 'wf-t07' '${_T07_PID}' '' 'active'
" || true

_run_state "$_CD" "$_PR" "
marker_update 'implementer' 'sess-t07' 'wf-t07' 'completed' 'trace-done'
" || true

_T07_FAIL=""
if [[ -f "$_T07_DB" ]]; then
    _T07_STATUS=$(sqlite3 "$_T07_DB" "SELECT status FROM agent_markers WHERE agent_type='implementer' AND session_id='sess-t07' AND workflow_id='wf-t07';" 2>/dev/null || echo "")
    _T07_TRACE=$(sqlite3 "$_T07_DB" "SELECT trace_id FROM agent_markers WHERE agent_type='implementer' AND session_id='sess-t07' AND workflow_id='wf-t07';" 2>/dev/null || echo "")
    if [[ "$_T07_STATUS" != "completed" ]]; then
        _T07_FAIL="Expected status 'completed', got '${_T07_STATUS}'"
    elif [[ "$_T07_TRACE" != "trace-done" ]]; then
        _T07_FAIL="Expected trace_id 'trace-done', got '${_T07_TRACE}'"
    fi
else
    _T07_FAIL="state.db not created"
fi

[[ -z "$_T07_FAIL" ]] && pass_test || fail_test "$_T07_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T08: marker_cleanup removes stale markers
# ─────────────────────────────────────────────────────────────────────────────
run_test "T08: marker_cleanup removes stale markers (older than threshold)"
_setup t08

_T08_PID="$$"
_T08_DB="${_CD}/state/state.db"

# Create markers
_run_state "$_CD" "$_PR" "
marker_create 'implementer' 'sess-t08' 'wf-stale' '${_T08_PID}' '' 'completed'
marker_create 'implementer' 'sess-t08' 'wf-fresh' '${_T08_PID}' '' 'active'
" || true

# Backdate the 'wf-stale' marker so it's older than the stale threshold
if [[ -f "$_T08_DB" ]]; then
    # Set created_at and updated_at to 7200 seconds ago (2 hours) — well beyond default 3600s
    _T08_OLD_TS=$(( $(date +%s) - 7200 ))
    sqlite3 "$_T08_DB" "UPDATE agent_markers SET created_at=${_T08_OLD_TS}, updated_at=${_T08_OLD_TS} WHERE workflow_id='wf-stale';" 2>/dev/null || true
fi

# Run cleanup with default stale threshold (3600s)
_run_state "$_CD" "$_PR" "
marker_cleanup 3600
" || true

_T08_FAIL=""
# The stale 'wf-stale' marker should be gone; 'wf-fresh' should remain
if [[ -f "$_T08_DB" ]]; then
    _T08_STALE_COUNT=$(sqlite3 "$_T08_DB" "SELECT COUNT(*) FROM agent_markers WHERE workflow_id='wf-stale';" 2>/dev/null || echo "1")
    _T08_FRESH_COUNT=$(sqlite3 "$_T08_DB" "SELECT COUNT(*) FROM agent_markers WHERE workflow_id='wf-fresh';" 2>/dev/null || echo "0")
    if [[ "$_T08_STALE_COUNT" -ne 0 ]]; then
        _T08_FAIL="Stale marker 'wf-stale' was not cleaned up (count=${_T08_STALE_COUNT})"
    elif [[ "$_T08_FRESH_COUNT" -ne 1 ]]; then
        _T08_FAIL="Fresh marker 'wf-fresh' was incorrectly removed (count=${_T08_FRESH_COUNT})"
    fi
else
    _T08_FAIL="state.db not created"
fi

[[ -z "$_T08_FAIL" ]] && pass_test || fail_test "$_T08_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T09: marker_cleanup marks dead-PID markers as crashed
# ─────────────────────────────────────────────────────────────────────────────
run_test "T09: marker_cleanup marks active markers with dead PIDs as crashed"
_setup t09

# Start a background process and kill it
sleep 30 &
_T09_DEAD_PID=$!
kill "$_T09_DEAD_PID" 2>/dev/null || true
wait "$_T09_DEAD_PID" 2>/dev/null || true

_T09_LIVE_PID="$$"
_T09_DB="${_CD}/state/state.db"

_run_state "$_CD" "$_PR" "
marker_create 'autoverify' 'sess-t09' 'wf-dead-t09' '${_T09_DEAD_PID}' '' 'active'
marker_create 'autoverify' 'sess-t09' 'wf-live-t09' '${_T09_LIVE_PID}' '' 'active'
" || true

_run_state "$_CD" "$_PR" "
marker_cleanup 9999
" || true

_T09_FAIL=""
if [[ -f "$_T09_DB" ]]; then
    _T09_DEAD_STATUS=$(sqlite3 "$_T09_DB" "SELECT status FROM agent_markers WHERE workflow_id='wf-dead-t09';" 2>/dev/null || echo "")
    _T09_LIVE_STATUS=$(sqlite3 "$_T09_DB" "SELECT status FROM agent_markers WHERE workflow_id='wf-live-t09';" 2>/dev/null || echo "")
    if [[ "$_T09_DEAD_STATUS" != "crashed" ]]; then
        _T09_FAIL="Expected dead-PID marker to be 'crashed', got '${_T09_DEAD_STATUS}'"
    elif [[ "$_T09_LIVE_STATUS" != "active" ]]; then
        _T09_FAIL="Expected live-PID marker to stay 'active', got '${_T09_LIVE_STATUS}'"
    fi
else
    _T09_FAIL="state.db not created"
fi

[[ -z "$_T09_FAIL" ]] && pass_test || fail_test "$_T09_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T10: UNIQUE constraint prevents duplicate active markers for same type+session+workflow
# ─────────────────────────────────────────────────────────────────────────────
run_test "T10: UNIQUE constraint — INSERT OR REPLACE replaces duplicate type+session+workflow"
_setup t10

_T10_PID="$$"
_T10_DB="${_CD}/state/state.db"

_run_state "$_CD" "$_PR" "
marker_create 'guardian' 'sess-t10' 'wf-t10' '${_T10_PID}' 'trace-v1' 'active'
marker_create 'guardian' 'sess-t10' 'wf-t10' '${_T10_PID}' 'trace-v2' 'active'
" || true

_T10_FAIL=""
if [[ -f "$_T10_DB" ]]; then
    _T10_COUNT=$(sqlite3 "$_T10_DB" "SELECT COUNT(*) FROM agent_markers WHERE agent_type='guardian' AND session_id='sess-t10' AND workflow_id='wf-t10';" 2>/dev/null || echo "0")
    _T10_TRACE=$(sqlite3 "$_T10_DB" "SELECT trace_id FROM agent_markers WHERE agent_type='guardian' AND session_id='sess-t10' AND workflow_id='wf-t10';" 2>/dev/null || echo "")
    if [[ "$_T10_COUNT" -ne 1 ]]; then
        _T10_FAIL="Expected exactly 1 row (REPLACE on conflict), got ${_T10_COUNT}"
    elif [[ "$_T10_TRACE" != "trace-v2" ]]; then
        _T10_FAIL="Expected trace_id 'trace-v2' after REPLACE, got '${_T10_TRACE}'"
    fi
else
    _T10_FAIL="state.db not created"
fi

[[ -z "$_T10_FAIL" ]] && pass_test || fail_test "$_T10_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T11: Concurrent marker_create (5 parallel, all succeed or replace)
# ─────────────────────────────────────────────────────────────────────────────
run_test "T11: Concurrent marker_create — 5 parallel writers, all succeed (no corruption)"
_setup t11

_T11_PID="$$"
_T11_DB="${_CD}/state/state.db"

# Initialize the DB first so all parallel writers see the schema
_run_state "$_CD" "$_PR" "state_update 'boot' 'ok' 'test'" || true

# Launch 5 parallel marker_create calls for different workflow_ids
_T11_BG_PIDS=()
for _T11_I in 1 2 3 4 5; do
    _run_state "$_CD" "$_PR" "
marker_create 'implementer' 'sess-t11' 'wf-parallel-${_T11_I}' '${_T11_PID}' '' 'active'
" &
    _T11_BG_PIDS+=($!)
done

# Wait for all background jobs
for _T11_BG_PID in "${_T11_BG_PIDS[@]}"; do
    wait "$_T11_BG_PID" 2>/dev/null || true
done

_T11_FAIL=""
if [[ -f "$_T11_DB" ]]; then
    _T11_COUNT=$(sqlite3 "$_T11_DB" "SELECT COUNT(*) FROM agent_markers WHERE agent_type='implementer' AND session_id='sess-t11';" 2>/dev/null || echo "0")
    if [[ "$_T11_COUNT" -ne 5 ]]; then
        _T11_FAIL="Expected 5 markers after parallel create, got ${_T11_COUNT}"
    fi
    # Also confirm no DB corruption
    _T11_INTEGRITY=$(sqlite3 "$_T11_DB" "PRAGMA integrity_check;" 2>/dev/null || echo "error")
    if [[ -z "$_T11_FAIL" && "$_T11_INTEGRITY" != "ok" ]]; then
        _T11_FAIL="DB integrity check failed after concurrent writes: ${_T11_INTEGRITY}"
    fi
else
    _T11_FAIL="state.db not created"
fi

[[ -z "$_T11_FAIL" ]] && pass_test || fail_test "$_T11_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# T12: marker_create with pre-dispatch status
# ─────────────────────────────────────────────────────────────────────────────
run_test "T12: marker_create with pre-dispatch status — accepted by CHECK constraint"
_setup t12

_T12_PID="$$"
_T12_DB="${_CD}/state/state.db"

_run_state "$_CD" "$_PR" "
marker_create 'implementer' 'sess-t12' 'wf-t12' '${_T12_PID}' '' 'pre-dispatch'
" || true

_T12_FAIL=""
if [[ -f "$_T12_DB" ]]; then
    _T12_STATUS=$(sqlite3 "$_T12_DB" "SELECT status FROM agent_markers WHERE workflow_id='wf-t12';" 2>/dev/null || echo "")
    if [[ "$_T12_STATUS" != "pre-dispatch" ]]; then
        _T12_FAIL="Expected status 'pre-dispatch', got '${_T12_STATUS}'"
    fi
else
    _T12_FAIL="state.db not created"
fi

[[ -z "$_T12_FAIL" ]] && pass_test || fail_test "$_T12_FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
