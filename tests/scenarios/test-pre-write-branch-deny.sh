#!/usr/bin/env bash
# test-pre-write-branch-deny.sh: source file write on main branch via
# pre-write.sh should produce permissionDecision=deny (branch guard fires).
#
# Compound-interaction test: pre-write.sh chains through write-policy.sh ->
# context-lib.sh -> git branch detection and produces the same deny as the
# old branch-guard.sh standalone hook.
set -euo pipefail

TEST_NAME="test-pre-write-branch-deny"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-write.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

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
    echo "FAIL: $TEST_NAME — hook exited nonzero"; exit 1
}

[[ -z "$output" ]] && { echo "FAIL: $TEST_NAME — no output (expected deny)"; exit 1; }

decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [[ "$decision" != "deny" ]]; then
    echo "FAIL: $TEST_NAME — expected deny, got: '$decision'"; echo "  output: $output"; exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
