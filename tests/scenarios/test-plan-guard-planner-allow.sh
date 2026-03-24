#!/usr/bin/env bash
# test-plan-guard-planner-allow.sh: planner role writes MASTER_PLAN.md — expects allow.
set -euo pipefail

TEST_NAME="test-plan-guard-planner-allow"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/plan-guard.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Setup: git repo with planner role active
mkdir -p "$TMP_DIR/.claude"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" checkout -b feature/test -q 2>/dev/null || true
git -C "$TMP_DIR" commit --allow-empty -m "init" -q
echo "ACTIVE|planner|$(date +%s)" > "$TMP_DIR/.claude/.subagent-tracker"

TARGET_FILE="$TMP_DIR/MASTER_PLAN.md"

PAYLOAD=$(jq -n \
    --arg tool_name "Write" \
    --arg file_path "$TARGET_FILE" \
    --arg content "# Plan" \
    '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

output=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" 2>/dev/null) || {
    echo "FAIL: $TEST_NAME — hook exited nonzero"
    exit 1
}

# Planner should be allowed — no deny in output
if [[ -n "$output" ]]; then
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    if [[ "$decision" == "deny" ]]; then
        echo "FAIL: $TEST_NAME — planner was denied governance write"
        exit 1
    fi
fi

echo "PASS: $TEST_NAME"
exit 0
