#!/usr/bin/env bash
# test-lease-concurrent.sh: Two worktrees with independent leases.
# Verifies one-active-per-worktree invariant and cross-worktree isolation.
#
# @decision DEC-LEASE-TEST-002
# @title Scenario test: concurrent leases on independent worktrees are isolated
# @status accepted
# @rationale DEC-LEASE-001 states one active lease per worktree_path. When two
#   worktrees each have an active lease, releasing one must not affect the other.
#   Re-issuing a lease for worktree-A must revoke the prior lease for A without
#   touching worktree-B's lease. validate_op() on each worktree resolves its own
#   lease independently. This is the compound-interaction test that crosses the
#   lease table, worktree isolation, and validate_op() resolution priority.
set -euo pipefail

TEST_NAME="test-lease-concurrent"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"
WT_A="$TMP_DIR/worktree-a"
WT_B="$TMP_DIR/worktree-b"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
mkdir -p "$TMP_DIR" "$WT_A" "$WT_B"

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

# --- Issue independent leases for two worktrees ---
ISSUE_A=$($CC lease issue-for-dispatch "implementer" \
    --worktree-path "$WT_A" \
    --workflow-id "wf-a" \
    --allowed-ops '["routine_local"]' 2>/dev/null)
LEASE_A=$(printf '%s' "$ISSUE_A" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)
if [[ -n "$LEASE_A" ]]; then pass "worktree-A: lease issued"; else fail "worktree-A: lease issued"; fi

# Phase 8 Slice 11: worktree-B uses reviewer (live read-only role); ``tester`` was
# retired. The concurrent-isolation invariant is role-agnostic.
ISSUE_B=$($CC lease issue-for-dispatch "reviewer" \
    --worktree-path "$WT_B" \
    --workflow-id "wf-b" \
    --allowed-ops '["routine_local"]' 2>/dev/null)
LEASE_B=$(printf '%s' "$ISSUE_B" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)
if [[ -n "$LEASE_B" ]]; then pass "worktree-B: lease issued"; else fail "worktree-B: lease issued"; fi

# --- Both leases are independently active ---
CURR_A=$($CC lease current --worktree-path "$WT_A" 2>/dev/null || echo '{"found":false}')
CURR_B=$($CC lease current --worktree-path "$WT_B" 2>/dev/null || echo '{"found":false}')

A_FOUND=$(printf '%s' "$CURR_A" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
B_FOUND=$(printf '%s' "$CURR_B" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
A_ROLE=$(printf '%s' "$CURR_A" | jq -r '.role // empty' 2>/dev/null || true)
B_ROLE=$(printf '%s' "$CURR_B" | jq -r '.role // empty' 2>/dev/null || true)

if [[ "$A_FOUND" == "yes" ]]; then pass "worktree-A: active lease found"; else fail "worktree-A: active lease found"; fi
if [[ "$B_FOUND" == "yes" ]]; then pass "worktree-B: active lease found"; else fail "worktree-B: active lease found"; fi
if [[ "$A_ROLE" == "implementer" ]]; then pass "worktree-A: role=implementer"; else fail "worktree-A: role=implementer (got $A_ROLE)"; fi
if [[ "$B_ROLE" == "reviewer" ]]; then pass "worktree-B: role=reviewer"; else fail "worktree-B: role=reviewer (got $B_ROLE)"; fi

# --- Lease IDs are distinct ---
if [[ "$LEASE_A" != "$LEASE_B" ]]; then pass "lease IDs are distinct"; else fail "lease IDs are distinct"; fi

# --- Releasing A does not affect B ---
$CC lease release "$LEASE_A" >/dev/null 2>&1 || true

CURR_A_AFTER=$($CC lease current --worktree-path "$WT_A" 2>/dev/null || echo '{"found":false}')
CURR_B_AFTER=$($CC lease current --worktree-path "$WT_B" 2>/dev/null || echo '{"found":false}')

A_FOUND_AFTER=$(printf '%s' "$CURR_A_AFTER" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
B_FOUND_AFTER=$(printf '%s' "$CURR_B_AFTER" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")

if [[ "$A_FOUND_AFTER" == "no" ]]; then pass "worktree-A: lease gone after release"; else fail "worktree-A: lease gone after release (found=$A_FOUND_AFTER)"; fi
if [[ "$B_FOUND_AFTER" == "yes" ]]; then pass "worktree-B: lease unaffected by A release"; else fail "worktree-B: lease unaffected by A release (found=$B_FOUND_AFTER)"; fi

# --- Re-issuing for A does NOT affect B ---
ISSUE_A2=$($CC lease issue-for-dispatch "guardian" \
    --worktree-path "$WT_A" \
    --workflow-id "wf-a" \
    --allowed-ops '["routine_local","high_risk"]' \
    --no-eval 2>/dev/null)
LEASE_A2=$(printf '%s' "$ISSUE_A2" | jq -r '.lease.lease_id // empty' 2>/dev/null || true)
if [[ -n "$LEASE_A2" ]]; then pass "worktree-A: new lease issued after re-issue"; else fail "worktree-A: new lease issued after re-issue"; fi
if [[ "$LEASE_A2" != "$LEASE_A" ]]; then pass "worktree-A: new lease id differs from original"; else fail "worktree-A: new lease id differs from original"; fi

CURR_B_FINAL=$($CC lease current --worktree-path "$WT_B" 2>/dev/null || echo '{"found":false}')
B_FOUND_FINAL=$(printf '%s' "$CURR_B_FINAL" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
B_ID_FINAL=$(printf '%s' "$CURR_B_FINAL" | jq -r '.lease_id // empty' 2>/dev/null || true)
if [[ "$B_FOUND_FINAL" == "yes" ]]; then pass "worktree-B: lease still active after A re-issue"; else fail "worktree-B: lease still active after A re-issue"; fi
if [[ "$B_ID_FINAL" == "$LEASE_B" ]]; then pass "worktree-B: lease id unchanged after A re-issue"; else fail "worktree-B: lease id unchanged after A re-issue (got $B_ID_FINAL)"; fi

# --- validate_op on A uses new lease (guardian allows high_risk) ---
VOP_A_PUSH=$($CC lease validate-op "git push origin feature/test" \
    --worktree-path "$WT_A" 2>/dev/null || echo '{}')
VOP_A_CLASS=$(printf '%s' "$VOP_A_PUSH" | jq -r '.op_class // empty' 2>/dev/null || true)
VOP_A_ALLOWED=$(printf '%s' "$VOP_A_PUSH" | jq -r 'if .allowed == true then "true" else "false" end' 2>/dev/null || echo "false")
VOP_A_REQ_APPROVAL=$(printf '%s' "$VOP_A_PUSH" | jq -r '.requires_approval // false' 2>/dev/null || echo "false")
if [[ "$VOP_A_CLASS" == "high_risk" ]]; then pass "worktree-A new lease: push classified as high_risk"; else fail "worktree-A new lease: push classified as high_risk (got $VOP_A_CLASS)"; fi
if [[ "$VOP_A_ALLOWED" == "true" ]]; then pass "worktree-A new lease: push allowed under guardian landing"; else fail "worktree-A new lease: push allowed under guardian landing (got $VOP_A_ALLOWED)"; fi
if [[ "$VOP_A_REQ_APPROVAL" == "false" ]]; then pass "worktree-A new lease: push requires_approval=false"; else fail "worktree-A new lease: push requires_approval=false (got $VOP_A_REQ_APPROVAL)"; fi

# --- validate_op on B uses its own lease (reviewer only has routine_local) ---
# Default to "true" (worst case) so a CLI failure does not hide a real denial.
# The correct result is "false" — high_risk not in reviewer's allowed_ops.
VOP_B_PUSH=$($CC lease validate-op "git push origin feature/test" \
    --worktree-path "$WT_B" 2>/dev/null || echo '{"allowed":true}')
VOP_B_ALLOWED=$(printf '%s' "$VOP_B_PUSH" | jq -r 'if .allowed == false then "false" else "true" end' 2>/dev/null || echo "true")
if [[ "$VOP_B_ALLOWED" == "false" ]]; then pass "worktree-B lease: push denied (not in allowed_ops)"; else fail "worktree-B lease: push denied (not in allowed_ops) — VOP_B_PUSH=$VOP_B_PUSH"; fi

TOTAL=17
echo ""
echo "Results: $((TOTAL - FAILURES))/$TOTAL passed"
if [[ "$FAILURES" -gt 0 ]]; then
    echo "FAIL: $TEST_NAME — $FAILURES check(s) failed"
    exit 1
fi
