#!/usr/bin/env bash
# test-state-unify-w2-1.sh — Tests for State Unification Wave 2-1.
#
# Validates: 7 hooks migrated from flat-file proof I/O to proof_state_get/proof_state_set API.
# Each hook must:
#   1. Call proof_state_set() as the PRIMARY write
#   2. Maintain dual-write to flat files (DEC-STATE-UNIFY-004)
#   3. Read via proof_state_get() (with flat-file fallback)
#
# Tests:
#   T01: log.sh write_proof_status() calls proof_state_set (SQLite has entry after write)
#   T02: log.sh write_proof_status() still writes flat file (dual-write)
#   T03: pre-bash.sh reads proof status via proof_state_get (mock test)
#   T04: task-track.sh writes needs-verification via proof_state_set
#   T05: prompt-submit.sh cas_proof_status writes verified via proof_state_set
#   T06: Full lifecycle: needs-verification → pending → verified → committed via SQLite
#   T07: Dual-write consistency — SQLite and flat file agree after each transition
#   T08: Fallback — when SQLite empty, hooks read flat file correctly
#
# Usage: bash tests/test-state-unify-w2-1.sh
#
# @decision DEC-STATE-UNIFY-TEST-002
# @title Isolated temp DB per test for W2-1 hook migration tests
# @status accepted
# @rationale Hook migration tests must be hermetic: each test needs a fresh DB and
#   fresh flat files to confirm that proof_state_set/get work independently of
#   any prior state. Same pattern as DEC-STATE-UNIFY-TEST-001 (W1-1 tests).
#   Lifecycle test (T06) uses a shared DB to verify multi-transition correctness.

set -uo pipefail

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
TMPDIR_BASE="$PROJECT_ROOT_OUTER/tmp/test-state-unify-w2-1-$$"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# _run_state — execute state-lib + log.sh operations in an isolated bash subshell.
# Usage: _run_state CLAUDE_DIR PROJECT_ROOT_PATH "bash code using state functions"
# NOTE: CLAUDE_DIR should equal PROJECT_ROOT/.claude for write_proof_status() alignment.
# NOTE: HOOKS_DIR is exported so the code snippet can reference it.
_run_state() {
    local cd="$1"
    local pr="$2"
    local code="$3"
    HOOKS_DIR="$HOOKS_DIR" bash -c "
source \"\${HOOKS_DIR}/source-lib.sh\" 2>/dev/null
require_state
_STATE_SCHEMA_INITIALIZED=''
_WORKFLOW_ID=''
export CLAUDE_DIR='${cd}'
export PROJECT_ROOT='${pr}'
export CLAUDE_PROJECT_DIR='${pr}'
export CLAUDE_SESSION_ID='test-session-\$\$'
${code}
" 2>/dev/null
}

# _setup — create an isolated env for a test with a git repo.
# Outputs: sets _CD (CLAUDE_DIR) and _PR (PROJECT_ROOT) for the test.
# IMPORTANT: _CD is set to _PR/.claude so get_claude_dir() == CLAUDE_DIR.
# This alignment is required for write_proof_status() which calls get_claude_dir()
# internally — if _CD != _PR/.claude, write_proof_status writes to a different path.
_setup() {
    local test_id="$1"
    _PR="${TMPDIR_BASE}/${test_id}"
    _CD="${_PR}/.claude"
    mkdir -p "${_CD}/state" "${_PR}"
    git -C "${_PR}" init -q 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# T01: log.sh write_proof_status() calls proof_state_set — SQLite has entry
# ─────────────────────────────────────────────────────────────────────────────
run_test "T01: write_proof_status() calls proof_state_set — SQLite has entry after write"

_setup "t01"
# Write a temp script so we avoid complex quoting
_T01_SCRIPT="${TMPDIR_BASE}/t01-check.sh"
cat > "$_T01_SCRIPT" << 'SCRIPT_EOF'
source "${HOOKS_DIR}/source-lib.sh" 2>/dev/null
require_state
_STATE_SCHEMA_INITIALIZED=''
_WORKFLOW_ID=''
source "${HOOKS_DIR}/log.sh" 2>/dev/null || true
write_proof_status "pending" "$PROJECT_ROOT" 2>/dev/null || true
# Check SQLite directly via proof_state_get
# Real SQLite entries have updated_by = source (e.g., "log.sh" or "write_proof_status")
# Flat-file fallback entries have updated_by = "flat-file-fallback"
result=$(proof_state_get 2>/dev/null || echo "")
if [[ -n "$result" ]]; then
    status=$(echo "$result" | cut -d'|' -f1)
    source_field=$(echo "$result" | cut -d'|' -f4)
    if [[ "$source_field" == "flat-file-fallback" ]]; then
        echo "NOT_IN_SQLITE"
    elif [[ "$status" == "pending" ]]; then
        echo "FOUND:pending"
    else
        echo "WRONG_STATUS:$status"
    fi
else
    echo "NOT_FOUND"
fi
SCRIPT_EOF
chmod +x "$_T01_SCRIPT"
_T01_RESULT=$(HOOKS_DIR="$HOOKS_DIR" CLAUDE_DIR="$_CD" PROJECT_ROOT="$_PR" CLAUDE_PROJECT_DIR="$_PR" CLAUDE_SESSION_ID="test-session-$$" bash "$_T01_SCRIPT" 2>/dev/null)

if [[ "$_T01_RESULT" == "FOUND:pending" ]]; then
    pass_test
else
    fail_test "write_proof_status did not write to SQLite proof_state table (got: '$_T01_RESULT')"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T02: log.sh write_proof_status() dual-writes to flat file
# ─────────────────────────────────────────────────────────────────────────────
run_test "T02: write_proof_status() still dual-writes to flat file"

_setup "t02"
_T02_RESULT=$(_run_state "$_CD" "$_PR" "
source '${HOOKS_DIR}/log.sh' 2>/dev/null || true
write_proof_status 'pending' \"\$PROJECT_ROOT\" 2>/dev/null || true
phash=\$(project_hash \"\$PROJECT_ROOT\")
new_path=\"\${CLAUDE_DIR}/state/\${phash}/proof-status\"
old_path=\"\${CLAUDE_DIR}/.proof-status-\${phash}\"
found_flat=''
if [[ -f \"\$new_path\" ]]; then
    val=\$(cut -d'|' -f1 \"\$new_path\" 2>/dev/null || echo '')
    [[ \"\$val\" == 'pending' ]] && found_flat='new:pending'
fi
if [[ -z \"\$found_flat\" && -f \"\$old_path\" ]]; then
    val=\$(cut -d'|' -f1 \"\$old_path\" 2>/dev/null || echo '')
    [[ \"\$val\" == 'pending' ]] && found_flat='old:pending'
fi
echo \"\${found_flat:-NOT_FOUND}\"
" 2>/dev/null)

if [[ "$_T02_RESULT" == "new:pending" || "$_T02_RESULT" == "old:pending" ]]; then
    pass_test
else
    fail_test "write_proof_status did not write to flat file (got: '$_T02_RESULT')"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T03: pre-bash.sh reads proof status via proof_state_get (code inspection)
# ─────────────────────────────────────────────────────────────────────────────
run_test "T03: pre-bash.sh proof status read uses proof_state_get"

# Verify that pre-bash.sh calls proof_state_get (not just cut on flat file)
_T03_FOUND=""
if grep -q 'proof_state_get' "${HOOKS_DIR}/pre-bash.sh" 2>/dev/null; then
    _T03_FOUND="yes"
fi

if [[ "$_T03_FOUND" == "yes" ]]; then
    pass_test
else
    fail_test "pre-bash.sh does not call proof_state_get (still reading flat file directly)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T04: task-track.sh writes needs-verification via proof_state_set
# ─────────────────────────────────────────────────────────────────────────────
run_test "T04: task-track.sh Gate C.2 writes needs-verification via proof_state_set"

# Verify that task-track.sh calls proof_state_set for needs-verification
_T04_FOUND=""
if grep -q 'proof_state_set' "${HOOKS_DIR}/task-track.sh" 2>/dev/null; then
    _T04_FOUND="yes"
fi

if [[ "$_T04_FOUND" == "yes" ]]; then
    pass_test
else
    fail_test "task-track.sh does not call proof_state_set (still writing flat file directly)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T05: prompt-submit.sh cas_proof_status writes verified via proof_state_set
# ─────────────────────────────────────────────────────────────────────────────
run_test "T05: prompt-submit.sh cas_proof_status calls proof_state_set for verified"

# Verify that prompt-submit.sh calls proof_state_set in cas_proof_status or elsewhere
_T05_FOUND=""
if grep -q 'proof_state_set' "${HOOKS_DIR}/prompt-submit.sh" 2>/dev/null; then
    _T05_FOUND="yes"
fi

if [[ "$_T05_FOUND" == "yes" ]]; then
    pass_test
else
    fail_test "prompt-submit.sh does not call proof_state_set"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T06: Full lifecycle — needs-verification → pending → verified → committed via SQLite
# ─────────────────────────────────────────────────────────────────────────────
run_test "T06: Full lifecycle via SQLite proof_state API"

_setup "t06"
_T06_RESULT=$(_run_state "$_CD" "$_PR" '
# Manually exercise the lifecycle via proof_state_set/get
transitions=()

# 1. needs-verification
proof_state_set "needs-verification" "test-t06" 2>/dev/null && transitions+=("nv_ok") || transitions+=("nv_fail")

# 2. pending
proof_state_set "pending" "test-t06" 2>/dev/null && transitions+=("pending_ok") || transitions+=("pending_fail")

# 3. verified
proof_state_set "verified" "test-t06" 2>/dev/null && transitions+=("verified_ok") || transitions+=("verified_fail")

# 4. committed
proof_state_set "committed" "test-t06" 2>/dev/null && transitions+=("committed_ok") || transitions+=("committed_fail")

# Final check: read current state
final=$(proof_state_get 2>/dev/null | cut -d"|" -f1 || echo "missing")
printf "%s\n" "${transitions[@]}" | tr "\n" ","
echo "$final"
' 2>/dev/null)

_T06_EXPECT_COMMITTED=$(echo "$_T06_RESULT" | grep -o "committed" | tail -1 || echo "")
_T06_TRANSITIONS_OK=$(echo "$_T06_RESULT" | grep -o "_ok" | wc -l | tr -d ' ')

if [[ "$_T06_EXPECT_COMMITTED" == "committed" && "$_T06_TRANSITIONS_OK" -ge 4 ]]; then
    pass_test
else
    fail_test "Full lifecycle failed (got: '$_T06_RESULT', committed='$_T06_EXPECT_COMMITTED', ok_count=$_T06_TRANSITIONS_OK)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T07: Dual-write consistency — SQLite and flat file agree after write
# ─────────────────────────────────────────────────────────────────────────────
run_test "T07: Dual-write consistency — SQLite and flat file agree after write_proof_status"

_setup "t07"
# Write a temp script so we avoid complex quoting in the heredoc
_T07_SCRIPT="${TMPDIR_BASE}/t07-check.sh"
cat > "$_T07_SCRIPT" << 'SCRIPT_EOF'
source "${HOOKS_DIR}/source-lib.sh" 2>/dev/null
require_state
_STATE_SCHEMA_INITIALIZED=''
_WORKFLOW_ID=''
source "${HOOKS_DIR}/log.sh" 2>/dev/null || true
write_proof_status "verified" "$PROJECT_ROOT" 2>/dev/null || true

# Read SQLite directly via proof_state_get, but detect if it's from SQLite or flat-file
# proof_state_get returns "status|epoch|updated_at|updated_by"
# If updated_by == "flat-file-fallback", the row is from a flat file, not SQLite
result=$(proof_state_get 2>/dev/null || echo "")
sqlite_status="missing_sqlite"
if [[ -n "$result" ]]; then
    status=$(echo "$result" | cut -d'|' -f1)
    source_field=$(echo "$result" | cut -d'|' -f4)
    if [[ "$source_field" == "flat-file-fallback" ]]; then
        sqlite_status="missing_sqlite"
    else
        sqlite_status="$status"
    fi
fi

# Read flat file
phash=$(project_hash "$PROJECT_ROOT")
new_path="${CLAUDE_DIR}/state/${phash}/proof-status"
old_path="${CLAUDE_DIR}/.proof-status-${phash}"
flat_status="missing_flat"
if [[ -f "$new_path" ]]; then
    flat_status=$(cut -d'|' -f1 "$new_path" 2>/dev/null || echo "missing_flat")
elif [[ -f "$old_path" ]]; then
    flat_status=$(cut -d'|' -f1 "$old_path" 2>/dev/null || echo "missing_flat")
fi

if [[ "$sqlite_status" == "$flat_status" && "$sqlite_status" == "verified" ]]; then
    echo "CONSISTENT:${sqlite_status}"
else
    echo "MISMATCH:sqlite=${sqlite_status}:flat=${flat_status}"
fi
SCRIPT_EOF
chmod +x "$_T07_SCRIPT"
_T07_RESULT=$(HOOKS_DIR="$HOOKS_DIR" CLAUDE_DIR="$_CD" PROJECT_ROOT="$_PR" CLAUDE_PROJECT_DIR="$_PR" CLAUDE_SESSION_ID="test-session-$$" bash "$_T07_SCRIPT" 2>/dev/null)

if [[ "$_T07_RESULT" == CONSISTENT:* ]]; then
    pass_test
else
    fail_test "SQLite and flat file disagree (got: '$_T07_RESULT')"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T08: Fallback — when SQLite empty, proof_state_get reads flat file
# ─────────────────────────────────────────────────────────────────────────────
run_test "T08: proof_state_get fallback — reads flat file when SQLite has no entry"

_setup "t08"
_T08_RESULT=$(_run_state "$_CD" "$_PR" '
# Write ONLY to flat file — do NOT call proof_state_set
phash=$(project_hash "$PROJECT_ROOT")
mkdir -p "${CLAUDE_DIR}/state/${phash}"
new_path="${CLAUDE_DIR}/state/${phash}/proof-status"
printf "needs-verification|%s\n" "$(date +%s)" > "$new_path"

# Now proof_state_get should fall back to the flat file
result=$(proof_state_get 2>/dev/null || echo "")
if [[ -n "$result" ]]; then
    status=$(echo "$result" | cut -d"|" -f1)
    echo "$status"
else
    echo "NOT_FOUND"
fi
' 2>/dev/null)

if [[ "$_T08_RESULT" == "needs-verification" ]]; then
    pass_test
else
    fail_test "proof_state_get did not fall back to flat file (got: '$_T08_RESULT')"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Additional code-inspection tests for all 7 hooks
# ─────────────────────────────────────────────────────────────────────────────
run_test "T09: check-tester.sh calls proof_state_set"

_T09_FOUND=""
if grep -q 'proof_state_set' "${HOOKS_DIR}/check-tester.sh" 2>/dev/null; then
    _T09_FOUND="yes"
fi

if [[ "$_T09_FOUND" == "yes" ]]; then
    pass_test
else
    fail_test "check-tester.sh does not call proof_state_set"
fi

run_test "T10: check-guardian.sh calls proof_state_set or proof_state_get"

_T10_FOUND=""
if grep -qE 'proof_state_set|proof_state_get' "${HOOKS_DIR}/check-guardian.sh" 2>/dev/null; then
    _T10_FOUND="yes"
fi

if [[ "$_T10_FOUND" == "yes" ]]; then
    pass_test
else
    fail_test "check-guardian.sh does not call proof_state_set or proof_state_get"
fi

run_test "T11: post-write.sh calls proof_state_get or proof_epoch_reset"

_T11_FOUND=""
if grep -qE 'proof_state_get|proof_epoch_reset|proof_state_set' "${HOOKS_DIR}/post-write.sh" 2>/dev/null; then
    _T11_FOUND="yes"
fi

if [[ "$_T11_FOUND" == "yes" ]]; then
    pass_test
else
    fail_test "post-write.sh does not call proof_state_get/proof_epoch_reset/proof_state_set"
fi

run_test "T12: DEC-STATE-UNIFY-004 annotation present in at least one hook"

_T12_FOUND=""
for hook in log.sh pre-bash.sh task-track.sh prompt-submit.sh check-tester.sh check-guardian.sh post-write.sh; do
    if grep -q 'DEC-STATE-UNIFY-004' "${HOOKS_DIR}/${hook}" 2>/dev/null; then
        _T12_FOUND="$hook"
        break
    fi
done

if [[ -n "$_T12_FOUND" ]]; then
    pass_test
else
    fail_test "DEC-STATE-UNIFY-004 annotation not found in any of the 7 migrated hooks"
fi

run_test "T13: W5-2 removal comment present in dual-write sites"

# Each hook that dual-writes should have a comment noting W5-2 removal
_T13_FOUND=0
for hook in log.sh prompt-submit.sh check-tester.sh check-guardian.sh; do
    if grep -qiE 'W5-2|remove.*dual|dual.*remove' "${HOOKS_DIR}/${hook}" 2>/dev/null; then
        _T13_FOUND=$((_T13_FOUND + 1))
    fi
done

if [[ "$_T13_FOUND" -ge 1 ]]; then
    pass_test
else
    fail_test "No W5-2 removal comments found in dual-write hook files"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Regression tests — run existing suites and verify they still pass
# ─────────────────────────────────────────────────────────────────────────────
run_test "T14: Existing test-sqlite-state.sh still passes (regression)"

_T14_EXIT=0
bash "${TEST_DIR}/test-sqlite-state.sh" >/dev/null 2>&1 || _T14_EXIT=$?

if [[ "$_T14_EXIT" -eq 0 ]]; then
    pass_test
else
    fail_test "test-sqlite-state.sh regression: exit code $_T14_EXIT"
fi

run_test "T15: Existing test-state-unify-w1-1.sh still passes (regression)"

_T15_EXIT=0
bash "${TEST_DIR}/test-state-unify-w1-1.sh" >/dev/null 2>&1 || _T15_EXIT=$?

if [[ "$_T15_EXIT" -eq 0 ]]; then
    pass_test
else
    fail_test "test-state-unify-w1-1.sh regression: exit code $_T15_EXIT"
fi

run_test "T16: Existing test-state-unify-w1-2.sh still passes (regression)"

_T16_EXIT=0
bash "${TEST_DIR}/test-state-unify-w1-2.sh" >/dev/null 2>&1 || _T16_EXIT=$?

if [[ "$_T16_EXIT" -eq 0 ]]; then
    pass_test
else
    fail_test "test-state-unify-w1-2.sh regression: exit code $_T16_EXIT"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
