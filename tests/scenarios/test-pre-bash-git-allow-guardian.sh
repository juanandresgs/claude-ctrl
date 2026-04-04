#!/usr/bin/env bash
# test-pre-bash-git-allow-guardian.sh: guardian+proof+tests issues git-commit
# via pre-bash.sh — expects allow (no deny output).
# Also satisfies guard.sh Check 12 (workflow binding + scope gate).
#
# @decision DEC-TKT008-002
# @title Compound allow path: all three bash-policy gates satisfied
# @status accepted
# @rationale Validates pre-bash.sh chains bp_git_who+bp_test_gate+bp_proof_gate
# and exits 0 when all three pass — the real production allow sequence.
set -euo pipefail
TEST_NAME="test-pre-bash-git-allow-guardian"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-bash.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
mkdir -p "$TMP_DIR/.claude"
(cd "$TMP_DIR" && git init -q && git commit --allow-empty -m init -q && git checkout -b feature/ready -q)
# Set guardian role via cc-policy (TKT-018: .subagent-tracker removed)
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" python3 "$REPO_ROOT/runtime/cli.py" schema ensure >/dev/null 2>&1
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" python3 "$REPO_ROOT/runtime/cli.py" marker set "agent-test" "guardian" >/dev/null 2>&1
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" python3 "$REPO_ROOT/runtime/cli.py" \
    test-state set pass --project-root "$TMP_DIR" --passed 1 --total 1 >/dev/null 2>&1
# TKT-024: evaluation_state replaces proof_state as readiness authority
HEAD_SHA=$(git -C "$TMP_DIR" rev-parse HEAD)
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" python3 "$REPO_ROOT/runtime/cli.py" evaluation set "feature-ready" "ready_for_guardian" --head-sha "$HEAD_SHA" >/dev/null 2>&1
# Satisfy Check 12: workflow binding + scope
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" python3 "$REPO_ROOT/runtime/cli.py" \
    workflow bind "feature-ready" "$TMP_DIR" "feature/ready" >/dev/null 2>&1
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" python3 "$REPO_ROOT/runtime/cli.py" \
    workflow scope-set "feature-ready" \
    --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1
# Gate 6: dispatch lease (policy engine requires active lease for all git ops)
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" python3 "$REPO_ROOT/runtime/cli.py" \
    lease issue-for-dispatch "guardian" \
    --worktree-path "$TMP_DIR" --workflow-id "feature-ready" \
    --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1
CMD="git -C \"$TMP_DIR\" commit --allow-empty -m done"
PAYLOAD=$(jq -n \
    --arg tool_name "Bash" \
    --arg command "$CMD" \
    --arg cwd "$TMP_DIR" \
    '{tool_name: $tool_name, tool_input: {command: $command}, cwd: $cwd}')
output=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" CLAUDE_RUNTIME_ROOT="$REPO_ROOT/runtime" "$HOOK" 2>/dev/null) || {
    echo "FAIL: $TEST_NAME — hook exited nonzero"; exit 1
}
if [[ -n "$output" ]]; then
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    if [[ "$decision" == "deny" ]]; then
        reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
        echo "FAIL: $TEST_NAME — unexpected deny: $reason"; exit 1
    fi
fi
echo "PASS: $TEST_NAME"
exit 0
