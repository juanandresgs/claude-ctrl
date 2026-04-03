#!/usr/bin/env bash
# test-lease-approval-high-risk.sh — Lease with high_risk allowed_ops.
#
# Sub-cases:
#   A: Lease has high_risk BUT no approval token → Check 13 still denies push
#      (Check 3 passes because lease allows high_risk; Check 13 fires next)
#   B: Lease has high_risk + approval token granted → push allowed
#
# Note: validate_op (Check 3) does a READ-ONLY check on pending approvals and
# denies if none found. So Check 3 itself will deny before Check 13 for high_risk
# with no approval. This test verifies the full cooperative behavior.
#
# @decision DEC-LEASE-002
# @title Check 3 uses lease validate_op, not marker role
# @status accepted
# @rationale validate_op reads approvals read-only for high_risk ops. If no
#   pending approval exists, it returns allowed=false. Check 3 propagates that.
#   When approval IS pending, Check 3 allows. Check 13 then CONSUMES the token.
set -euo pipefail

TEST_NAME="test-lease-approval-high-risk"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/guard.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $TEST_NAME [$1] — $2"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $TEST_NAME [$1] — $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

_decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true; }
_reason()   { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true; }

_run_guard() {
    local cmd="$1" project_dir="$2" db="$3"
    local payload
    payload=$(jq -n --arg t "Bash" --arg c "$cmd" --arg w "$project_dir" \
        '{tool_name:$t,tool_input:{command:$c},cwd:$w}')
    printf '%s' "$payload" \
        | CLAUDE_PROJECT_DIR="$project_dir" \
          CLAUDE_POLICY_DB="$db" \
          CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" \
          "$HOOK" 2>/dev/null || true
}

_setup() {
    local branch="$1"
    WF_ID=$(printf '%s' "$branch" | tr '/: ' '---' | tr -cd '[:alnum:]._-')
    TMP_DIR="$REPO_ROOT/tmp/${TEST_NAME}-${WF_ID}-$$"
    TEST_DB="$TMP_DIR/.claude/state.db"

    mkdir -p "$TMP_DIR/.claude"
    (cd "$TMP_DIR" && git init -q && git config user.email "t@t.com" && git config user.name "T")
    (cd "$TMP_DIR" && git commit --allow-empty -m "init" -q)
    (cd "$TMP_DIR" && git checkout -b "$branch" -q)
    CURRENT_HEAD=$(git -C "$TMP_DIR" rev-parse HEAD)

    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian" >/dev/null 2>&1
    echo "pass|0|$(date +%s)" > "$TMP_DIR/.claude/.test-status"
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$CURRENT_HEAD" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$WF_ID" "$TMP_DIR" "$branch" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1

    # Issue lease with high_risk in allowed_ops
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        lease issue-for-dispatch "guardian" \
        --workflow-id "$WF_ID" \
        --worktree-path "$TMP_DIR" \
        --branch "$branch" \
        --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1
}

# shellcheck disable=SC2329
_teardown() { [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"; TMP_DIR=""; }

# ---------------------------------------------------------------------------
# Sub-case A: Lease allows high_risk but NO approval token → denied
# validate_op reads pending approvals; none found → allowed=false
# ---------------------------------------------------------------------------
run_sub_case_a() {
    local branch="feature/lease-highrisk-no-token"
    _setup "$branch"
    trap '_teardown' RETURN

    local cmd output decision reason
    cmd="git -C \"$TMP_DIR\" push origin $branch"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")
    reason=$(_reason "$output")

    if [[ "$decision" != "deny" ]]; then
        fail "A" "expected deny for push with high_risk lease but no approval, got='$decision'"
        return
    fi
    # Reason may come from Check 3 (validate_op sees no approval) or Check 13
    if ! printf '%s' "$reason" | grep -qiE "approval|lease"; then
        fail "A" "deny reason should mention 'approval' or 'lease', got: $reason"
        return
    fi
    pass "A" "high_risk lease + no approval token → denied (approval required)"
}

# ---------------------------------------------------------------------------
# Sub-case B: Lease allows high_risk + approval token granted → push allowed
# validate_op reads approvals (read-only) → allowed=true; Check 13 consumes token
# ---------------------------------------------------------------------------
run_sub_case_b() {
    local branch="feature/lease-highrisk-with-token"
    _setup "$branch"
    trap '_teardown' RETURN

    # Grant approval token
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        approval grant "$WF_ID" "push" >/dev/null 2>&1

    local cmd output decision
    cmd="git -C \"$TMP_DIR\" push origin $branch"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")

    if [[ -z "$output" || "$decision" != "deny" ]]; then
        pass "B" "high_risk lease + approval token → push allowed"
    else
        fail "B" "unexpected deny with valid approval token: $(_reason "$output")"
    fi
}

echo "=== $TEST_NAME: starting ==="
run_sub_case_a
run_sub_case_b
echo ""
echo "=== $TEST_NAME: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -gt 0 ]] && exit 1
exit 0
