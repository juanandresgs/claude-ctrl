#!/usr/bin/env bash
# test-plan-required.sh: feeds synthetic PreToolUse Write JSON to plan-check.sh
# in a git repo with no MASTER_PLAN.md and content >= 20 lines, verifies deny.
set -euo pipefail

TEST_NAME="test-plan-required"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/plan-check.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Setup: git repo with NO MASTER_PLAN.md
mkdir -p "$TMP_DIR/src"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" commit --allow-empty -m "init" -q

TARGET_FILE="$TMP_DIR/src/app.ts"

# Content must be >= 20 lines to pass the fast-mode bypass in plan-check.sh
CONTENT=$(printf 'export const x = %d;\n' $(seq 1 25) | head -25)

PAYLOAD=$(jq -n \
    --arg tool_name "Write" \
    --arg file_path "$TARGET_FILE" \
    --arg content "$CONTENT" \
    '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

output=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" 2>/dev/null) || {
    echo "FAIL: $TEST_NAME — hook exited nonzero"
    exit 1
}

if [[ -z "$output" ]]; then
    echo "FAIL: $TEST_NAME — no output (expected deny for missing MASTER_PLAN.md)"
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
