#!/usr/bin/env bash
# test-plan-guard-migration-override.sh: implementer role with CLAUDE_PLAN_MIGRATION=1
# writes MASTER_PLAN.md — expects allow (migration override).
set -euo pipefail

TEST_NAME="test-plan-guard-migration-override"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/plan-guard.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Setup: git repo with implementer role active
mkdir -p "$TMP_DIR/.claude"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" checkout -b feature/test -q 2>/dev/null || true
git -C "$TMP_DIR" commit --allow-empty -m "init" -q
# Set implementer role via cc-policy (TKT-018: .subagent-tracker removed)
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" python3 "$REPO_ROOT/runtime/cli.py" schema ensure >/dev/null 2>&1
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" python3 "$REPO_ROOT/runtime/cli.py" marker set "agent-test" "implementer" >/dev/null 2>&1

TARGET_FILE="$TMP_DIR/MASTER_PLAN.md"

PAYLOAD=$(jq -n \
    --arg tool_name "Write" \
    --arg file_path "$TARGET_FILE" \
    --arg content "# Plan" \
    '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

# CLAUDE_PLAN_MIGRATION=1 should override the deny
output=$(printf '%s' "$PAYLOAD" | CLAUDE_PLAN_MIGRATION=1 CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" 2>/dev/null) || {
    echo "FAIL: $TEST_NAME — hook exited nonzero"
    exit 1
}

# With migration override, should be allowed — no deny
if [[ -n "$output" ]]; then
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    if [[ "$decision" == "deny" ]]; then
        echo "FAIL: $TEST_NAME — migration override was denied"
        exit 1
    fi
fi

echo "PASS: $TEST_NAME"
exit 0
