#!/usr/bin/env bash
# test-write-deny-main.sh: feeds synthetic PreToolUse Write JSON with a .ts
# file path to branch-guard.sh from a git repo on main, verifies deny.
set -euo pipefail

TEST_NAME="test-write-deny-main"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/branch-guard.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Setup: git repo checked out on main
mkdir -p "$TMP_DIR/src"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" checkout -b main -q 2>/dev/null || true
git -C "$TMP_DIR" commit --allow-empty -m "init" -q

TARGET_FILE="$TMP_DIR/src/app.ts"

PAYLOAD=$(jq -n \
    --arg tool_name "Write" \
    --arg file_path "$TARGET_FILE" \
    --arg content "export const x = 1;" \
    '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

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
