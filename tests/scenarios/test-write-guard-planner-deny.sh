#!/usr/bin/env bash
# test-write-guard-planner-deny.sh: planner role active via .subagent-tracker,
# source file (.ts) write — expects permissionDecision: deny.
#
# Validates that the planner role cannot write source files. Planners produce
# MASTER_PLAN.md and task breakdowns; all source changes must go through an
# implementer. Tests both the "planner" role label and "Plan" (runtime alias).
#
# @decision DEC-SMOKE-013
# @title Planner source-write deny test
# @status accepted
# @rationale Planner is explicitly listed as a denied role in TKT-003 spec.
# The SubagentStart matcher in settings.json uses "planner|Plan" so both
# labels appear in .subagent-tracker. This test uses "planner"; the runtime
# alias "Plan" is covered by the same code path in write-guard.sh since
# neither matches the "implementer" allow condition.
set -euo pipefail

TEST_NAME="test-write-guard-planner-deny"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/write-guard.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Setup: git repo with planner role active
mkdir -p "$TMP_DIR/.claude"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" checkout -b feature/test -q 2>/dev/null || true
git -C "$TMP_DIR" commit --allow-empty -m "init" -q

# Set planner role via cc-policy (TKT-018: .subagent-tracker removed)
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" python3 "$REPO_ROOT/runtime/cli.py" schema ensure >/dev/null 2>&1
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" python3 "$REPO_ROOT/runtime/cli.py" marker set "agent-test" "planner" >/dev/null 2>&1

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
