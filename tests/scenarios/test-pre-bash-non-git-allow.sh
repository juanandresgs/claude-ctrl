#!/usr/bin/env bash
# test-pre-bash-non-git-allow.sh: plain non-git command via pre-bash.sh
# — no policy fires, hook exits 0 with no deny.
set -euo pipefail
TEST_NAME="test-pre-bash-non-git-allow"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-bash.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
mkdir -p "$TMP_DIR"
PAYLOAD=$(jq -n \
    --arg tool_name "Bash" \
    --arg command "ls -la" \
    --arg cwd "$TMP_DIR" \
    '{tool_name: $tool_name, tool_input: {command: $command}, cwd: $cwd}')
output=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" 2>/dev/null) || {
    echo "FAIL: $TEST_NAME — hook exited nonzero"; exit 1
}
if [[ -n "$output" ]]; then
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    if [[ "$decision" == "deny" ]]; then
        reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
        echo "FAIL: $TEST_NAME — unexpected deny for non-git command: $reason"; exit 1
    fi
fi
echo "PASS: $TEST_NAME"
exit 0
