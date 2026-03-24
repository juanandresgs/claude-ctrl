#!/usr/bin/env bash
# test-write-guard-orchestrator-deny.sh: no active role (empty .subagent-tracker),
# source file (.ts) write — expects permissionDecision: deny.
#
# Exercises the production path where the orchestrator attempts to write a
# source file directly without dispatching an implementer. The .subagent-tracker
# is absent so current_active_agent_role returns empty, which write-guard.sh
# treats as "orchestrator (no active agent)" and denies.
#
# @decision DEC-SMOKE-010
# @title Orchestrator source-write deny test
# @status accepted
# @rationale Validates the primary WHO enforcement scenario: no agent active
# means the orchestrator is writing directly, which must be denied for source
# files. This is Wave 1 Known Risk #1 in MASTER_PLAN.md — empty role = deny.
set -euo pipefail

TEST_NAME="test-write-guard-orchestrator-deny"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/write-guard.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Setup: minimal git repo, no .subagent-tracker (empty role = orchestrator)
mkdir -p "$TMP_DIR/.claude"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" checkout -b feature/test -q 2>/dev/null || true
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
