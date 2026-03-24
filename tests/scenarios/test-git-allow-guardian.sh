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
HOOK="$REPO_ROOT/hooks/guard.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" commit --allow-empty -m "init" -q
# Use a feature branch so Check 4 (no commit on main) doesn't fire
git -C "$TMP_DIR" checkout -b feature/ready-to-merge -q

# Gate 1: Guardian role active via .subagent-tracker
echo "ACTIVE|guardian|$(date +%s)" > "$TMP_DIR/.claude/.subagent-tracker"

# Gate 2: test status = pass (format: result|failures|epoch)
echo "pass|0|$(date +%s)" > "$TMP_DIR/.claude/.test-status"

# Gate 3: proof-of-work = verified
# current_workflow_id uses sanitize_token on the branch name
# branch "feature/ready-to-merge" -> sanitize: "feature-ready-to-merge"
WORKFLOW_ID="feature-ready-to-merge"
echo "verified|$(date +%s)" > "$TMP_DIR/.claude/.proof-status-${WORKFLOW_ID}"

PAYLOAD=$(jq -n \
    --arg tool_name "Bash" \
    --arg command "git -C \"$TMP_DIR\" commit --allow-empty -m 'merge ready'" \
    --arg cwd "$TMP_DIR" \
    '{tool_name: $tool_name, tool_input: {command: $command}, cwd: $cwd}')

output=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" 2>/dev/null) || {
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
