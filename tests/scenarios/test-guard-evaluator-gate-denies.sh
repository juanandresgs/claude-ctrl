#!/usr/bin/env bash
# test-guard-evaluator-gate-denies.sh: proves guard.sh Check 10 denies
# git commit when evaluation_state is "needs_changes" or "blocked_by_plan".
#
# Two sub-cases exercised in sequence:
#   Sub-case A: needs_changes   → deny
#   Sub-case B: blocked_by_plan → deny
#
# Stale proof_state == "verified" is also set to confirm it cannot satisfy
# the new gate (regression guard for Evaluation Contract check 15).
#
# @decision DEC-EVAL-003
# @title guard.sh Check 10 gates on evaluation_state, not proof_state
# @status accepted
# @rationale Verifies that non-ready evaluation statuses block Guardian.
#   Setting proof_state=verified alongside confirms proof_state has zero
#   enforcement effect after TKT-024 cutover.
set -euo pipefail

TEST_NAME="test-guard-evaluator-gate-denies"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/guard.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"

run_deny_check() {
    local sub_case="$1"
    local eval_status="$2"
    local TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-${eval_status}-$$"
    local TEST_DB="$TMP_DIR/.claude/state.db"
    local BRANCH="feature/eval-deny-${eval_status}"
    local WF_ID="feature-eval-deny-${eval_status}"

    cleanup() { rm -rf "$TMP_DIR"; }
    trap cleanup EXIT

    mkdir -p "$TMP_DIR/.claude"
    git -C "$TMP_DIR" init -q
    git -C "$TMP_DIR" config user.email "t@t.com"
    git -C "$TMP_DIR" config user.name "T"
    git -C "$TMP_DIR" commit --allow-empty -m "init" -q
    git -C "$TMP_DIR" checkout -b "$BRANCH" -q

    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian" >/dev/null 2>&1

    echo "pass|0|$(date +%s)" > "$TMP_DIR/.claude/.test-status"

    # Set evaluation_state to a non-ready status
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$WF_ID" "$eval_status" >/dev/null 2>&1

    # Also set proof_state=verified to confirm it has zero enforcement effect
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        proof set "$WF_ID" "verified" >/dev/null 2>&1

    # workflow binding + scope (Check 12 must not be the reason for deny)
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$WF_ID" "$TMP_DIR" "$BRANCH" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1

    # Lease (TKT-STAB-A3): Check 3 requires an active lease; issue one so the
    # deny comes from Check 10 (evaluation_state), not Check 3 (no lease).
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        lease issue-for-dispatch "guardian" \
        --workflow-id "$WF_ID" \
        --worktree-path "$TMP_DIR" \
        --branch "$BRANCH" \
        --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1

    CMD="git -C \"$TMP_DIR\" commit --allow-empty -m 'test'"
    PAYLOAD=$(jq -n --arg t "Bash" --arg c "$CMD" --arg w "$TMP_DIR" \
        '{tool_name:$t,tool_input:{command:$c},cwd:$w}')

    output=$(printf '%s' "$PAYLOAD" \
        | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" \
          CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" "$HOOK" 2>/dev/null) || true

    decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")
    reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || echo "")

    if [[ "$decision" != "deny" ]]; then
        echo "FAIL: $TEST_NAME [$sub_case] — expected deny for eval_status=$eval_status, got '$decision'"
        echo "  output: $output"
        exit 1
    fi

    # Deny reason must mention evaluation_state (not proof)
    if ! printf '%s' "$reason" | grep -qi "evaluation_state"; then
        echo "FAIL: $TEST_NAME [$sub_case] — deny reason should mention evaluation_state"
        echo "  reason: $reason"
        exit 1
    fi

    # Deny reason must NOT say "proof-of-work" — that language is retired
    if printf '%s' "$reason" | grep -qi "proof-of-work"; then
        echo "FAIL: $TEST_NAME [$sub_case] — deny reason must not mention proof-of-work (TKT-024: proof has zero enforcement)"
        echo "  reason: $reason"
        exit 1
    fi

    echo "PASS: $TEST_NAME [$sub_case] — eval_status=$eval_status correctly denied"
    rm -rf "$TMP_DIR"
    trap - EXIT
}

run_deny_check "needs_changes"   "needs_changes"
run_deny_check "blocked_by_plan" "blocked_by_plan"

echo "PASS: $TEST_NAME (all sub-cases)"
exit 0
