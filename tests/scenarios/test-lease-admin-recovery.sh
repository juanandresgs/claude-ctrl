#!/usr/bin/env bash
# test-lease-admin-recovery.sh: CLI-level admin_recovery op class tests.
#
# Verifies that merge --abort and reset --merge are classified as admin_recovery,
# require a lease + approval token, but do NOT require evaluation readiness.
# Also verifies that normal high_risk (reset --hard) and routine_local (commit)
# are unchanged by the admin_recovery introduction.
#
# @decision DEC-LEASE-002
# @title admin_recovery op class exempts merge --abort / reset --merge from eval gate
# @status accepted
# @rationale Scenario tests exercise the full CLI path (issue lease → grant
#   approval → validate-op) to prove the Python backend honours the authority
#   model described in the task spec. These tests are independent of guard.sh
#   hooks so they run in any environment that has cc-policy available.
set -euo pipefail

TEST_NAME="test-lease-admin-recovery"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
mkdir -p "$TMP_DIR"

# Use the worktree's own runtime/cli.py
CC="python3 $REPO_ROOT/runtime/cli.py"
export CLAUDE_POLICY_DB="$TEST_DB"

FAILURES=0
TOTAL=0

pass() { echo "  PASS: $1"; TOTAL=$((TOTAL + 1)); }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); TOTAL=$((TOTAL + 1)); }

echo "=== $TEST_NAME ==="
echo ""

# Bootstrap schema
$CC schema ensure >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Scenario 1: lease with admin_recovery in allowed_ops + approval → allowed
# ---------------------------------------------------------------------------
echo "--- Scenario 1: lease + approval → admin_recovery allowed ---"

$CC lease issue-for-dispatch "guardian" \
    --worktree-path "$TMP_DIR/wt1" \
    --workflow-id "wf-admin-1" \
    --allowed-ops '["routine_local","high_risk","admin_recovery"]' \
    --no-eval >/dev/null 2>&1

# Grant approval token for admin_recovery
$CC approval grant "wf-admin-1" "admin_recovery" >/dev/null 2>&1

VOP1=$($CC lease validate-op "git reset --merge" \
    --worktree-path "$TMP_DIR/wt1" 2>/dev/null || echo '{}')

VOP1_CLASS=$(printf '%s' "$VOP1" | jq -r '.op_class // empty' 2>/dev/null || true)
VOP1_ALLOWED=$(printf '%s' "$VOP1" | jq -r '.allowed // "false"' 2>/dev/null || echo "false")
# Use 'type' to detect null — jq's // operator treats null as falsy so
# '.eval_ok // "NOT_NULL"' would incorrectly return "NOT_NULL" for a null value.
VOP1_EVAL_OK_TYPE=$(printf '%s' "$VOP1" | jq -r '.eval_ok | type' 2>/dev/null || echo "unknown")

if [[ "$VOP1_CLASS" == "admin_recovery" ]]; then
    pass "reset --merge → op_class=admin_recovery"
else
    fail "reset --merge → op_class=admin_recovery (got: $VOP1_CLASS)"
fi

if [[ "$VOP1_ALLOWED" == "true" ]]; then
    pass "reset --merge with lease+approval → allowed=true"
else
    fail "reset --merge with lease+approval → allowed=true (got: $VOP1_ALLOWED, full: $VOP1)"
fi

if [[ "$VOP1_EVAL_OK_TYPE" == "null" ]]; then
    pass "reset --merge → eval_ok=null (eval gate skipped)"
else
    fail "reset --merge → eval_ok=null (eval gate skipped) (type: $VOP1_EVAL_OK_TYPE)"
fi

# Same test with merge --abort
VOP1B=$($CC lease validate-op "git merge --abort" \
    --worktree-path "$TMP_DIR/wt1" 2>/dev/null || echo '{}')

VOP1B_CLASS=$(printf '%s' "$VOP1B" | jq -r '.op_class // empty' 2>/dev/null || true)
VOP1B_ALLOWED=$(printf '%s' "$VOP1B" | jq -r '.allowed // "false"' 2>/dev/null || echo "false")

# Grant another token (tokens are one-shot; the previous was consumed by reset --merge check)
$CC approval grant "wf-admin-1" "admin_recovery" >/dev/null 2>&1

VOP1B=$($CC lease validate-op "git merge --abort" \
    --worktree-path "$TMP_DIR/wt1" 2>/dev/null || echo '{}')
VOP1B_CLASS=$(printf '%s' "$VOP1B" | jq -r '.op_class // empty' 2>/dev/null || true)
VOP1B_ALLOWED=$(printf '%s' "$VOP1B" | jq -r '.allowed // "false"' 2>/dev/null || echo "false")

if [[ "$VOP1B_CLASS" == "admin_recovery" ]]; then
    pass "merge --abort → op_class=admin_recovery"
else
    fail "merge --abort → op_class=admin_recovery (got: $VOP1B_CLASS)"
fi

if [[ "$VOP1B_ALLOWED" == "true" ]]; then
    pass "merge --abort with lease+approval → allowed=true"
else
    fail "merge --abort with lease+approval → allowed=true (got: $VOP1B_ALLOWED)"
fi

echo ""

# ---------------------------------------------------------------------------
# Scenario 2: lease WITHOUT admin_recovery in allowed_ops → denied
# ---------------------------------------------------------------------------
echo "--- Scenario 2: admin_recovery not in allowed_ops → denied ---"

$CC lease issue-for-dispatch "implementer" \
    --worktree-path "$TMP_DIR/wt2" \
    --workflow-id "wf-admin-2" \
    --allowed-ops '["routine_local"]' \
    --no-eval >/dev/null 2>&1

$CC approval grant "wf-admin-2" "admin_recovery" >/dev/null 2>&1

VOP2=$($CC lease validate-op "git reset --merge" \
    --worktree-path "$TMP_DIR/wt2" 2>/dev/null || echo '{}')

VOP2_ALLOWED=$(printf '%s' "$VOP2" | jq -r '.allowed // "false"' 2>/dev/null || echo "false")
VOP2_REASON=$(printf '%s' "$VOP2" | jq -r '.reason // empty' 2>/dev/null || true)

if [[ "$VOP2_ALLOWED" == "false" ]]; then
    pass "admin_recovery not in allowed_ops → allowed=false"
else
    fail "admin_recovery not in allowed_ops → allowed=false (got: $VOP2_ALLOWED)"
fi

if [[ "$VOP2_REASON" == *"not in allowed_ops"* ]]; then
    pass "admin_recovery not in allowed_ops → reason mentions 'not in allowed_ops'"
else
    fail "admin_recovery not in allowed_ops → reason mentions 'not in allowed_ops' (got: $VOP2_REASON)"
fi

echo ""

# ---------------------------------------------------------------------------
# Scenario 3: no lease → denied, op_class still admin_recovery
# ---------------------------------------------------------------------------
echo "--- Scenario 3: no lease → denied with correct op_class ---"

VOP3=$($CC lease validate-op "git merge --abort" \
    --worktree-path "$TMP_DIR/wt-nolease" 2>/dev/null || echo '{}')

VOP3_ALLOWED=$(printf '%s' "$VOP3" | jq -r '.allowed // "false"' 2>/dev/null || echo "false")
VOP3_CLASS=$(printf '%s' "$VOP3" | jq -r '.op_class // empty' 2>/dev/null || true)
VOP3_REASON=$(printf '%s' "$VOP3" | jq -r '.reason // empty' 2>/dev/null || true)

if [[ "$VOP3_ALLOWED" == "false" ]]; then
    pass "no lease → allowed=false"
else
    fail "no lease → allowed=false (got: $VOP3_ALLOWED)"
fi

if [[ "$VOP3_CLASS" == "admin_recovery" ]]; then
    pass "no lease → op_class=admin_recovery (still classified correctly)"
else
    fail "no lease → op_class=admin_recovery (got: $VOP3_CLASS)"
fi

if [[ "$VOP3_REASON" == *"no active lease"* ]]; then
    pass "no lease → reason='no active lease'"
else
    fail "no lease → reason='no active lease' (got: $VOP3_REASON)"
fi

echo ""

# ---------------------------------------------------------------------------
# Scenario 4: reset --hard is still high_risk (not admin_recovery)
# ---------------------------------------------------------------------------
echo "--- Scenario 4: reset --hard stays high_risk ---"

VOP4=$($CC lease validate-op "git reset --hard HEAD~1" \
    --worktree-path "$TMP_DIR/wt-nolease" 2>/dev/null || echo '{}')

VOP4_CLASS=$(printf '%s' "$VOP4" | jq -r '.op_class // empty' 2>/dev/null || true)

if [[ "$VOP4_CLASS" == "high_risk" ]]; then
    pass "reset --hard → op_class=high_risk (not admin_recovery)"
else
    fail "reset --hard → op_class=high_risk (got: $VOP4_CLASS)"
fi

echo ""

# ---------------------------------------------------------------------------
# Scenario 5: git commit stays routine_local (regression guard)
# ---------------------------------------------------------------------------
echo "--- Scenario 5: commit stays routine_local ---"

VOP5=$($CC lease validate-op "git commit -m test" \
    --worktree-path "$TMP_DIR/wt-nolease" 2>/dev/null || echo '{}')

VOP5_CLASS=$(printf '%s' "$VOP5" | jq -r '.op_class // empty' 2>/dev/null || true)

if [[ "$VOP5_CLASS" == "routine_local" ]]; then
    pass "git commit → op_class=routine_local (unchanged)"
else
    fail "git commit → op_class=routine_local (got: $VOP5_CLASS)"
fi

echo ""

# ---------------------------------------------------------------------------
# Scenario 6: admin_recovery without approval token → denied
# ---------------------------------------------------------------------------
echo "--- Scenario 6: admin_recovery lease but no approval → denied ---"

$CC lease issue-for-dispatch "guardian" \
    --worktree-path "$TMP_DIR/wt6" \
    --workflow-id "wf-admin-6" \
    --allowed-ops '["routine_local","high_risk","admin_recovery"]' \
    --no-eval >/dev/null 2>&1

# Do NOT grant approval token

VOP6=$($CC lease validate-op "git reset --merge" \
    --worktree-path "$TMP_DIR/wt6" 2>/dev/null || echo '{}')

VOP6_ALLOWED=$(printf '%s' "$VOP6" | jq -r '.allowed // "false"' 2>/dev/null || echo "false")
VOP6_REQ_APPROVAL=$(printf '%s' "$VOP6" | jq -r '.requires_approval // false' 2>/dev/null || echo "false")

if [[ "$VOP6_ALLOWED" == "false" ]]; then
    pass "admin_recovery without approval → allowed=false"
else
    fail "admin_recovery without approval → allowed=false (got: $VOP6_ALLOWED)"
fi

if [[ "$VOP6_REQ_APPROVAL" == "true" ]]; then
    pass "admin_recovery without approval → requires_approval=true"
else
    fail "admin_recovery without approval → requires_approval=true (got: $VOP6_REQ_APPROVAL)"
fi

echo ""

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
PASSED=$((TOTAL - FAILURES))
echo "Results: $PASSED/$TOTAL passed"
if [[ "$FAILURES" -gt 0 ]]; then
    echo "FAIL: $TEST_NAME — $FAILURES check(s) failed"
    exit 1
else
    echo "PASS: $TEST_NAME"
fi
