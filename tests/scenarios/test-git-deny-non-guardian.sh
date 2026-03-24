#!/usr/bin/env bash
# test-git-deny-non-guardian.sh: feeds synthetic PreToolUse Bash JSON with
# a git commit command to guard.sh without Guardian role active, verifies deny.
set -euo pipefail

TEST_NAME="test-git-deny-non-guardian"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/guard.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" commit --allow-empty -m "init" -q

# No .subagent-tracker means role is empty (non-guardian)
PAYLOAD=$(jq -n \
    --arg tool_name "Bash" \
    --arg command "git commit -m 'wip'" \
    --arg cwd "$TMP_DIR" \
    '{tool_name: $tool_name, tool_input: {command: $command}, cwd: $cwd}')

output=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" 2>/dev/null) || {
    echo "FAIL: $TEST_NAME — hook exited nonzero"
    exit 1
}

if [[ -z "$output" ]]; then
    echo "FAIL: $TEST_NAME — no output (expected deny)"
    exit 1
fi

decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" != "deny" ]]; then
    echo "FAIL: $TEST_NAME — expected permissionDecision=deny, got: '$decision'"
    echo "  full output: $output"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
