#!/usr/bin/env bash
# test-pre-write-no-plan-deny.sh: implementer writes source file in git repo
# with no MASTER_PLAN.md via pre-write.sh — plan-exists check must deny.
set -euo pipefail

TEST_NAME="test-pre-write-no-plan-deny"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-write.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude" "$TMP_DIR/src"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" checkout -b feature/test -q 2>/dev/null || true
git -C "$TMP_DIR" commit --allow-empty -m "init" -q
# Set implementer role via cc-policy (TKT-018: .subagent-tracker removed)
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" python3 "$REPO_ROOT/runtime/cli.py" schema ensure >/dev/null 2>&1
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" python3 "$REPO_ROOT/runtime/cli.py" marker set "agent-test" "implementer" >/dev/null 2>&1
# No MASTER_PLAN.md

TARGET_FILE="$TMP_DIR/src/app.ts"
CONTENT=$(printf 'export const x = %d;\n' $(seq 1 25))

PAYLOAD=$(jq -n \
    --arg tool_name "Write" \
    --arg file_path "$TARGET_FILE" \
    --arg content "$CONTENT" \
    '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

output=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" 2>/dev/null) || {
    echo "FAIL: $TEST_NAME — hook exited nonzero"; exit 1
}

[[ -z "$output" ]] && { echo "FAIL: $TEST_NAME — no output (expected deny)"; exit 1; }

decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" != "deny" ]]; then
    echo "FAIL: $TEST_NAME — expected deny, got: '$decision'"; echo "  output: $output"; exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
