#!/usr/bin/env bash
# test-write-guard-config-allow.sh: any role (orchestrator/empty), non-source
# file (.json) write — expects allow (exit 0, no deny).
#
# Validates that WHO enforcement does not apply to non-source files. Config,
# docs, markdown, JSON, and YAML are out of scope for write-guard.sh.
# TKT-004 handles governance markdown separately.
#
# @decision DEC-SMOKE-014
# @title Non-source file WHO pass-through test
# @status accepted
# @rationale write-guard.sh must be surgical: it gates source files only.
# Blocking config or JSON writes would break orchestrator-level operations
# like updating settings.json, creating tmp files, and writing docs. The
# is_source_file check from context-lib.sh is the single authority for this
# distinction — this test verifies it works correctly for .json files.
set -euo pipefail

TEST_NAME="test-write-guard-config-allow"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/write-guard.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Setup: git repo, NO .subagent-tracker (orchestrator role — most restrictive)
# If even orchestrator can write .json, all other roles can too.
mkdir -p "$TMP_DIR/.claude"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" checkout -b feature/test -q 2>/dev/null || true
git -C "$TMP_DIR" commit --allow-empty -m "init" -q

TARGET_FILE="$TMP_DIR/config/settings.json"

PAYLOAD=$(jq -n \
    --arg tool_name "Write" \
    --arg file_path "$TARGET_FILE" \
    --arg content '{"key": "value"}' \
    '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

output=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" 2>/dev/null) || {
    echo "FAIL: $TEST_NAME — hook exited nonzero"
    exit 1
}

# Allow means empty output or JSON without permissionDecision: deny
if [[ -n "$output" ]]; then
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    if [[ "$decision" == "deny" ]]; then
        reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
        echo "FAIL: $TEST_NAME — unexpected deny for non-source .json file"
        echo "  reason: $reason"
        exit 1
    fi
fi

echo "PASS: $TEST_NAME"
exit 0
