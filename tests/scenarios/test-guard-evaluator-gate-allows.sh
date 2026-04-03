#!/usr/bin/env bash
# test-guard-evaluator-gate-allows.sh: proves guard.sh Check 10 allows
# git commit when evaluation_state == "ready_for_guardian" AND head_sha
# matches the current HEAD.
#
# Gates guard.sh checks for a commit to succeed:
#   Check 3:  WHO — guardian role active
#   Check 4:  not on main/master
#   Check 9:  .test-status == pass
#   Check 10: evaluation_state == ready_for_guardian AND head_sha matches HEAD
#   Check 12: workflow binding + scope exists
#
# @decision DEC-EVAL-003
# @title guard.sh Check 10 gates on evaluation_state, not proof_state
# @status accepted
# @rationale This test proves the allow path for the new evaluation gate.
#   All five checks must be satisfied simultaneously; satisfying four of five
#   would give a false pass signal. The full sequence mirrors what a real
#   Guardian agent does before committing.
set -euo pipefail

TEST_NAME="test-guard-evaluator-gate-allows"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/guard.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/.claude/state.db"
BRANCH="feature/eval-allows-test"
WF_ID="feature-eval-allows-test"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" config user.email "t@t.com"
git -C "$TMP_DIR" config user.name "T"
git -C "$TMP_DIR" commit --allow-empty -m "init" -q
git -C "$TMP_DIR" checkout -b "$BRANCH" -q

# Get the actual HEAD sha for this repo
CURRENT_HEAD=$(git -C "$TMP_DIR" rev-parse HEAD)

# Gate 1: schema + guardian role
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian" >/dev/null 2>&1

# Gate 2: test status = pass
echo "pass|0|$(date +%s)" > "$TMP_DIR/.claude/.test-status"

# Gate 3: evaluation_state = ready_for_guardian with matching head_sha
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$CURRENT_HEAD" >/dev/null 2>&1

# Gate 4: workflow binding + scope (Check 12)
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    workflow bind "$WF_ID" "$TMP_DIR" "$BRANCH" >/dev/null 2>&1
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    workflow scope-set "$WF_ID" \
    --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1

# Gate 5 (TKT-STAB-A3): active lease required for all git ops in enforced projects
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    lease issue-for-dispatch "guardian" \
    --workflow-id "$WF_ID" \
    --worktree-path "$TMP_DIR" \
    --branch "$BRANCH" \
    --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1

CMD="git -C \"$TMP_DIR\" commit --allow-empty -m 'test commit'"
PAYLOAD=$(jq -n --arg t "Bash" --arg c "$CMD" --arg w "$TMP_DIR" \
    '{tool_name:$t,tool_input:{command:$c},cwd:$w}')

output=$(printf '%s' "$PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" \
      CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" "$HOOK" 2>/dev/null) || {
    echo "FAIL: $TEST_NAME — hook exited nonzero"
    exit 1
}

# Allow = empty output or JSON without deny
if [[ -n "$output" ]]; then
    decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")
    if [[ "$decision" == "deny" ]]; then
        reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || echo "")
        echo "FAIL: $TEST_NAME — unexpected deny: $reason"
        exit 1
    fi
fi

echo "PASS: $TEST_NAME"
exit 0
