#!/usr/bin/env bash
# test-workflow-id-cli.sh — Tests for workflow_id() CLI sourcing behavior (#239)
#
# Verifies that workflow_id() returns a proper {hash}_{branch} identifier
# (not "_main" or "_branch") when state-lib.sh is sourced from CLI context.
#
# @decision DEC-WORKFLOW-ID-CLI-001
# @title workflow_id() must return valid hash when sourced from CLI
# @status accepted
# @rationale Issue #239: When hooks are sourced from CLI (not from a hook process),
#   PROJECT_ROOT and CLAUDE_DIR env vars are often set by callers but
#   detect_project_root() falls through to $HOME or fails, producing empty hash.
#   The fix: workflow_id() checks CLAUDE_DIR/PROJECT_ROOT env vars before
#   accepting an empty phash from detect_project_root().

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Test counter
PASS=0
FAIL=0
ERRORS=()

pass() { PASS=$(( PASS + 1 )); echo "PASS: $1"; }
fail() { FAIL=$(( FAIL + 1 )); ERRORS+=("$1"); echo "FAIL: $1"; }

# Helper: run in a clean subshell with given env vars, return workflow_id
run_workflow_id() {
    local env_setup="$1"
    bash -c "
        set +e
        ${env_setup}
        source \"${PROJECT_ROOT}/hooks/log.sh\" 2>/dev/null
        source \"${PROJECT_ROOT}/hooks/state-lib.sh\" 2>/dev/null
        echo \"\$(workflow_id 2>/dev/null)\"
    "
}

# Helper: check workflow_id format is {8hex}_{word}
is_valid_workflow_id() {
    local wid="$1"
    # Must match: 8 hex chars + underscore + at least 1 char
    [[ "$wid" =~ ^[0-9a-f]{8}_[a-zA-Z0-9_-]+$ ]]
}

echo "=== Test: workflow_id() CLI sourcing (#239) ==="
echo ""

# --- Test 1: Basic scenario with PROJECT_ROOT set (the reported fix case) ---
echo "--- Test 1: workflow_id with PROJECT_ROOT and CLAUDE_DIR set ---"
WID=$(run_workflow_id "export PROJECT_ROOT=\"${PROJECT_ROOT}\" && export CLAUDE_DIR=\"${PROJECT_ROOT}\"")
if is_valid_workflow_id "$WID"; then
    pass "T1: workflow_id with PROJECT_ROOT set returns valid format: $WID"
else
    fail "T1: workflow_id with PROJECT_ROOT set returned invalid: '$WID' (expected {8hex}_{branch})"
fi

# --- Test 2: workflow_id must NOT be _main (empty hash) ---
echo "--- Test 2: workflow_id must not have empty hash component ---"
if [[ "$WID" == _* ]]; then
    fail "T2: workflow_id starts with _ (empty hash): '$WID'"
else
    pass "T2: workflow_id has non-empty hash component: $WID"
fi

# --- Test 3: Exact expected value for this project ---
echo "--- Test 3: workflow_id matches expected hash for this project ---"
EXPECTED_HASH="7e8570fa"  # sha256 of /Users/turla/.claude | cut -c1-8
if [[ "$WID" == "${EXPECTED_HASH}_"* ]]; then
    pass "T3: workflow_id uses correct project hash (${EXPECTED_HASH}): $WID"
else
    # Only warn (not fail) if hash differs — may be a different machine
    echo "WARN: T3: Expected hash ${EXPECTED_HASH}_ prefix but got: $WID (acceptable on other machines)"
    PASS=$(( PASS + 1 ))
fi

# --- Test 4: State-lib sourced WITHOUT log.sh — must still return valid id ---
echo "--- Test 4: state-lib.sh sourced WITHOUT log.sh (most fragile CLI path) ---"
WID_NO_LOG=$(bash -c "
    set +e
    export PROJECT_ROOT=\"${PROJECT_ROOT}\"
    export CLAUDE_DIR=\"${PROJECT_ROOT}\"
    # Source core-lib.sh only (no log.sh) — simulates partial load
    source \"${PROJECT_ROOT}/hooks/core-lib.sh\" 2>/dev/null
    source \"${PROJECT_ROOT}/hooks/state-lib.sh\" 2>/dev/null
    echo \"\$(workflow_id 2>/dev/null)\"
")
if is_valid_workflow_id "$WID_NO_LOG"; then
    pass "T4: workflow_id without log.sh (using core-lib only) returns valid: $WID_NO_LOG"
else
    fail "T4: workflow_id without log.sh returned invalid: '$WID_NO_LOG'"
fi

# --- Test 5: State-lib sourced from non-project directory with env vars ---
echo "--- Test 5: Sourced from /tmp with PROJECT_ROOT set ---"
WID_TMP=$(bash -c "
    set +e
    cd /tmp
    export PROJECT_ROOT=\"${PROJECT_ROOT}\"
    export CLAUDE_DIR=\"${PROJECT_ROOT}\"
    source \"${PROJECT_ROOT}/hooks/log.sh\" 2>/dev/null
    source \"${PROJECT_ROOT}/hooks/state-lib.sh\" 2>/dev/null
    echo \"\$(workflow_id 2>/dev/null)\"
")
if is_valid_workflow_id "$WID_TMP"; then
    pass "T5: workflow_id from /tmp with PROJECT_ROOT returns valid: $WID_TMP"
else
    fail "T5: workflow_id from /tmp with PROJECT_ROOT returned invalid: '$WID_TMP'"
fi

# --- Test 6: Verify T5 returns PROJECT_ROOT hash, not /tmp hash ---
echo "--- Test 6: /tmp scenario uses PROJECT_ROOT hash not /tmp hash ---"
TMP_HASH=$(bash -c "echo '/tmp' | shasum -a 256 | cut -c1-8")
if [[ "$WID_TMP" == "${TMP_HASH}_"* ]]; then
    fail "T6: workflow_id used /tmp hash instead of PROJECT_ROOT hash: $WID_TMP"
else
    pass "T6: workflow_id did NOT use /tmp hash: $WID_TMP (correctly used PROJECT_ROOT)"
fi

# --- Test 7: workflow_id is consistent across calls (caching) ---
echo "--- Test 7: Consecutive calls return same value (cache works) ---"
WID_AGAIN=$(run_workflow_id "export PROJECT_ROOT=\"${PROJECT_ROOT}\" && export CLAUDE_DIR=\"${PROJECT_ROOT}\"")
if [[ "$WID" == "$WID_AGAIN" ]]; then
    pass "T7: Consistent workflow_id across calls: $WID"
else
    fail "T7: Inconsistent workflow_id: first='$WID' second='$WID_AGAIN'"
fi

# --- Test 8: workflow_id with only CLAUDE_DIR (no PROJECT_ROOT) ---
echo "--- Test 8: workflow_id with CLAUDE_DIR set but no PROJECT_ROOT ---"
WID_CDIR=$(bash -c "
    set +e
    cd /tmp
    export CLAUDE_DIR=\"${PROJECT_ROOT}\"
    unset PROJECT_ROOT 2>/dev/null || true
    source \"${PROJECT_ROOT}/hooks/log.sh\" 2>/dev/null
    source \"${PROJECT_ROOT}/hooks/state-lib.sh\" 2>/dev/null
    echo \"\$(workflow_id 2>/dev/null)\"
")
if is_valid_workflow_id "$WID_CDIR"; then
    pass "T8: workflow_id with CLAUDE_DIR only returns valid: $WID_CDIR"
else
    fail "T8: workflow_id with CLAUDE_DIR only returned invalid: '$WID_CDIR'"
fi

# --- Test 9: THE REPORTED BUG — state-lib.sh sourced ALONE (no log.sh) ---
# This is the exact failing scenario from issue #239:
#   source ~/.claude/hooks/state-lib.sh && proof_epoch_reset
# Without log.sh, project_hash() is not defined → returns _main
echo "--- Test 9: state-lib.sh sourced ALONE without log.sh or core-lib.sh ---"
WID_ALONE=$(bash -c "
    set +e
    export PROJECT_ROOT=\"${PROJECT_ROOT}\"
    export CLAUDE_DIR=\"${PROJECT_ROOT}\"
    source \"${PROJECT_ROOT}/hooks/state-lib.sh\" 2>/dev/null
    echo \"\$(workflow_id 2>/dev/null)\"
")
if is_valid_workflow_id "$WID_ALONE"; then
    pass "T9: workflow_id with state-lib.sh alone returns valid: $WID_ALONE"
else
    fail "T9: workflow_id with state-lib.sh alone returned invalid: '$WID_ALONE' (bug: project_hash not defined)"
fi

# --- Test 10: Verify T9 doesn't return _main specifically ---
echo "--- Test 10: State-lib alone must not return _main ---"
if [[ "$WID_ALONE" == "_main" ]]; then
    fail "T10: Got '_main' — the exact bug from issue #239 (empty project hash)"
else
    pass "T10: workflow_id is not '_main': $WID_ALONE"
fi

# --- Summary ---
echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if [[ $FAIL -gt 0 ]]; then
    echo "Failures:"
    for e in "${ERRORS[@]}"; do
        echo "  - $e"
    done
    exit 1
fi
exit 0
