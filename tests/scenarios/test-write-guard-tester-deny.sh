#!/usr/bin/env bash
# test-write-guard-tester-deny.sh: tester role active via .subagent-tracker,
# source file (.ts) write — expects permissionDecision: deny.
#
# Validates that the tester role cannot write source files. Testers verify
# and report; they must dispatch an implementer for any code changes.
#
# @decision DEC-SMOKE-012
# @title Tester source-write deny test
# @status accepted
# @rationale Tester is explicitly listed as a denied role in TKT-003 spec.
# Testers should never modify source code — if they discover a bug, they
# report it and dispatch an implementer. This test ensures that invariant
# is mechanically enforced, not just aspirational.
set -euo pipefail

TEST_NAME="test-write-guard-tester-deny"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/write-guard.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Setup: git repo with tester role active
mkdir -p "$TMP_DIR/.claude"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" checkout -b feature/test -q 2>/dev/null || true
git -C "$TMP_DIR" commit --allow-empty -m "init" -q

echo "ACTIVE|tester|$(date +%s)" > "$TMP_DIR/.claude/.subagent-tracker"

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
