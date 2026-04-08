#!/usr/bin/env bash
# test-git-allow-guardian.sh: feeds synthetic PreToolUse Bash JSON with a
# git commit command to guard.sh with Guardian role active and all gates
# satisfied, verifies allow (no deny in output).
#
# Gates guard.sh checks before allowing git commit:
#   Check 3: WHO — current_active_agent_role must be guardian/Guardian
#   Check 4: not on main (we use a feature branch)
#   Check 9: .test-status must be pass
#   Check 10: proof-of-work must be verified
#   Check 12: workflow binding + scope must exist
#
# @decision DEC-SMOKE-003
# @title Guardian-allow test requires all three gates: role, test, proof
# @status accepted
# @rationale guard.sh enforces three independent gates for git commit: WHO
# (guardian role), test status (pass), and proof-of-work (verified). A test
# that only sets one gate would pass for the wrong reason. All three must be
# satisfied to confirm the real production allow path. This mirrors what a
# Guardian agent actually does before committing.
set -euo pipefail

TEST_NAME="test-git-allow-guardian"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-bash.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" config user.email "t@t.com"
git -C "$TMP_DIR" config user.name "T"
git -C "$TMP_DIR" commit --allow-empty -m "init" -q
# Use a feature branch so Check 4 (no commit on main) doesn't fire
git -C "$TMP_DIR" checkout -b feature/ready-to-merge -q

# Gate 1: Guardian role active via cc-policy (TKT-018: .subagent-tracker removed)
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" python3 "$REPO_ROOT/runtime/cli.py" schema ensure >/dev/null 2>&1
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" python3 "$REPO_ROOT/runtime/cli.py" \
    marker set "agent-test" "guardian" --project-root "$TMP_DIR" >/dev/null 2>&1

# Gate 2: test status = pass via runtime (policy engine reads SQLite, not flat file)
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" python3 "$REPO_ROOT/runtime/cli.py" \
    test-state set pass --project-root "$TMP_DIR" --passed 1 --total 1 >/dev/null 2>&1

# Gate 3: evaluation_state = ready_for_guardian (TKT-024: replaces proof_state)
# current_workflow_id uses sanitize_token on the branch name
# branch "feature/ready-to-merge" -> sanitize: "feature-ready-to-merge"
WORKFLOW_ID="feature-ready-to-merge"
HEAD_SHA=$(git -C "$TMP_DIR" rev-parse HEAD)
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" python3 "$REPO_ROOT/runtime/cli.py" evaluation set "$WORKFLOW_ID" "ready_for_guardian" --head-sha "$HEAD_SHA" >/dev/null 2>&1

# Gate 4: workflow binding + scope (Check 12)
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" python3 "$REPO_ROOT/runtime/cli.py" \
    workflow bind "$WORKFLOW_ID" "$TMP_DIR" "feature/ready-to-merge" >/dev/null 2>&1
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" python3 "$REPO_ROOT/runtime/cli.py" \
    workflow scope-set "$WORKFLOW_ID" \
    --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1

# Gate 5: dispatch lease (policy engine requires active lease for all git ops)
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" python3 "$REPO_ROOT/runtime/cli.py" \
    lease issue-for-dispatch "guardian" \
    --worktree-path "$TMP_DIR" \
    --workflow-id "$WORKFLOW_ID" \
    --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1

PAYLOAD=$(jq -n \
    --arg tool_name "Bash" \
    --arg command "git -C \"$TMP_DIR\" commit --allow-empty -m 'merge ready'" \
    --arg cwd "$TMP_DIR" \
    '{tool_name: $tool_name, tool_input: {command: $command}, cwd: $cwd}')

output=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" CLAUDE_RUNTIME_ROOT="$REPO_ROOT/runtime" "$HOOK" 2>/dev/null) || {
    echo "FAIL: $TEST_NAME — hook exited nonzero"
    exit 1
}

# Allow means empty output or JSON without permissionDecision: deny
if [[ -n "$output" ]]; then
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    if [[ "$decision" == "deny" ]]; then
        reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
        echo "FAIL: $TEST_NAME — unexpected deny with guardian role active"
        echo "  reason: $reason"
        exit 1
    fi
fi

echo "PASS: $TEST_NAME"
exit 0
