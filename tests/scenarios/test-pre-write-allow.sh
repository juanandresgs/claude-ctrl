#!/usr/bin/env bash
# test-pre-write-allow.sh: implementer writes source file on a feature branch
# with MASTER_PLAN.md present via pre-write.sh — expects allow (no deny).
set -euo pipefail

TEST_NAME="test-pre-write-allow"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-write.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude" "$TMP_DIR/src"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" checkout -b feature/test -q 2>/dev/null || true
git -C "$TMP_DIR" commit --allow-empty -m "init" -q
echo "ACTIVE|implementer|$(date +%s)" > "$TMP_DIR/.claude/.subagent-tracker"
echo "# Plan" > "$TMP_DIR/MASTER_PLAN.md"
git -C "$TMP_DIR" add MASTER_PLAN.md
git -C "$TMP_DIR" commit -m "add plan" -q

TARGET_FILE="$TMP_DIR/src/app.ts"

PAYLOAD=$(jq -n \
    --arg tool_name "Write" \
    --arg file_path "$TARGET_FILE" \
    --arg content "export const x = 1;" \
    '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

output=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" 2>/dev/null) || {
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
