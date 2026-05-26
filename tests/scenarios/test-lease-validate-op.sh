#!/usr/bin/env bash
# test-lease-validate-op.sh: CLI-level validate-op tests.
# Issues a lease, then validates allowed and denied operations against it.
#
# @decision DEC-LEASE-TEST-001
# @title Scenario test: validate-op gates git commands against active lease
# @status accepted
# @rationale validate_op() is the Phase 2 authority for Check 3 WHO enforcement.
#   This test exercises the full CLI path: issue lease → validate allowed op
#   (routine_local in allowed_ops) → validate denied op (high_risk not in
#   allowed_ops) → release lease → validate denied (no active lease).
#   Uses cc-policy CLI directly to verify the Python backend, not hooks.
set -euo pipefail

TEST_NAME="test-lease-validate-op"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
mkdir -p "$TMP_DIR"

# Use the worktree's own runtime/cli.py — Phase 1 commands (lease, completion)
# are not yet in the production runtime at $CLAUDE_RUNTIME_ROOT.
CC="python3 $REPO_ROOT/runtime/cli.py"
export CLAUDE_POLICY_DB="$TEST_DB"

FAILURES=0

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "=== $TEST_NAME ==="

# Bootstrap schema
$CC schema ensure >/dev/null 2>&1

# Issue a lease that allows routine_local but NOT high_risk
ISSUE_OUT=$($CC lease issue-for-dispatch "implementer" \
    --worktree-path "$TMP_DIR" \
    --workflow-id "test-wf-validate" \
    --allowed-ops '["routine_local"]' 2>/dev/null)

LEASE_ID=$(printf '%s' "$ISSUE_OUT" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)
if [[ -n "$LEASE_ID" ]]; then pass "lease issued successfully"; else fail "lease issued successfully"; fi

# Test 1: routine_local commit — verify op_class classification
VOP_COMMIT=$($CC lease validate-op "git commit -m 'test'" \
    --worktree-path "$TMP_DIR" 2>/dev/null || echo '{}')
VOP_COMMIT_CLASS=$(printf '%s' "$VOP_COMMIT" | jq -r '.op_class // empty' 2>/dev/null || true)
if [[ "$VOP_COMMIT_CLASS" == "routine_local" ]]; then
    pass "validate-op: commit classified as routine_local"
else
    fail "validate-op: commit classified as routine_local (got: $VOP_COMMIT_CLASS)"
fi

# Test 2: high_risk push — not in allowed_ops, must be denied
VOP_PUSH=$($CC lease validate-op "git push origin main" \
    --worktree-path "$TMP_DIR" 2>/dev/null || echo '{}')
VOP_PUSH_ALLOWED=$(printf '%s' "$VOP_PUSH" | jq -r '.allowed // "false"' 2>/dev/null || echo "false")
VOP_PUSH_CLASS=$(printf '%s' "$VOP_PUSH" | jq -r '.op_class // empty' 2>/dev/null || true)

if [[ "$VOP_PUSH_CLASS" == "high_risk" ]]; then
    pass "validate-op: push classified as high_risk"
else
    fail "validate-op: push classified as high_risk (got: $VOP_PUSH_CLASS)"
fi

if [[ "$VOP_PUSH_ALLOWED" == "false" ]]; then
    pass "validate-op: push denied (not in allowed_ops)"
else
    fail "validate-op: push denied (not in allowed_ops) — allowed=$VOP_PUSH_ALLOWED"
fi

# Test 3: Issue a lease that allows high_risk
ISSUE_HR=$($CC lease issue-for-dispatch "guardian" \
    --worktree-path "$TMP_DIR" \
    --workflow-id "test-wf-validate" \
    --allowed-ops '["routine_local","high_risk"]' \
    --no-eval 2>/dev/null)
LEASE_HR_ID=$(printf '%s' "$ISSUE_HR" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)
if [[ -n "$LEASE_HR_ID" ]]; then pass "high_risk lease issued"; else fail "high_risk lease issued"; fi

# push should now reach approval check (requires_eval=false so eval won't block)
VOP_PUSH2=$($CC lease validate-op "git push origin feature/test" \
    --worktree-path "$TMP_DIR" 2>/dev/null || echo '{}')
VOP_PUSH2_REQUIRES_APPROVAL=$(printf '%s' "$VOP_PUSH2" | jq -r '.requires_approval // false' 2>/dev/null || echo "false")
if [[ "$VOP_PUSH2_REQUIRES_APPROVAL" == "true" ]]; then
    pass "validate-op: push requires_approval=true with high_risk lease"
else
    fail "validate-op: push requires_approval=true with high_risk lease (got: $VOP_PUSH2_REQUIRES_APPROVAL)"
fi

# Test 4: Release lease, then validate — should return no active lease
$CC lease release "$LEASE_HR_ID" >/dev/null 2>&1 || true
VOP_NO_LEASE=$($CC lease validate-op "git commit -m 'orphan'" \
    --worktree-path "$TMP_DIR" 2>/dev/null || echo '{}')
VOP_NO_LEASE_ALLOWED=$(printf '%s' "$VOP_NO_LEASE" | jq -r '.allowed // "false"' 2>/dev/null || echo "false")
VOP_NO_LEASE_REASON=$(printf '%s' "$VOP_NO_LEASE" | jq -r '.reason // empty' 2>/dev/null || true)

if [[ "$VOP_NO_LEASE_ALLOWED" == "false" ]]; then
    pass "validate-op: no active lease -> allowed=false"
else
    fail "validate-op: no active lease -> allowed=false (got: $VOP_NO_LEASE_ALLOWED)"
fi

if [[ "$VOP_NO_LEASE_REASON" == *"no active lease"* ]]; then
    pass "validate-op: no active lease -> reason contains 'no active lease'"
else
    fail "validate-op: no active lease -> reason contains 'no active lease' (got: $VOP_NO_LEASE_REASON)"
fi

echo ""
echo "Results: $((8 - FAILURES))/8 passed"
if [[ "$FAILURES" -gt 0 ]]; then
    echo "FAIL: $TEST_NAME — $FAILURES check(s) failed"
    exit 1
fi
