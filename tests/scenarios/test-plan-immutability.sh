#!/usr/bin/env bash
# test-plan-immutability.sh: verify that pre-write.sh denies rewrites of
# permanent MASTER_PLAN.md sections and allows appends.
#
# Scenario A: rewrite Identity section -> expect deny
# Scenario B: append to Identity section -> expect allow
# Scenario C: CLAUDE_PLAN_MIGRATION=1 rewrite -> expect allow (migration override)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-write.sh"
TMP_DIR="$REPO_ROOT/tmp/test-plan-immutability-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Setup: minimal git repo that mimics a real project layout.
# planctl.py must exist at scripts/planctl.py inside the test project because
# check_plan_immutability resolves it as $project_root/scripts/planctl.py.
mkdir -p "$TMP_DIR/.claude" "$TMP_DIR/scripts"
cp "$REPO_ROOT/scripts/planctl.py" "$TMP_DIR/scripts/planctl.py"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" checkout -b feature/test -q 2>/dev/null || true
git -C "$TMP_DIR" commit --allow-empty -m "init" -q
echo "ACTIVE|planner|$(date +%s)" > "$TMP_DIR/.claude/.subagent-tracker"

PLAN_FILE="$TMP_DIR/MASTER_PLAN.md"

ORIGINAL_CONTENT='# MASTER_PLAN.md

Last updated: 2026-03-24 (initial)

## Identity

This is the original identity text.

## Architecture

Architecture overview.

## Original Intent

Bootstrap a test project.

## Principles

1. Keep it simple.

## Decision Log

- `2026-03-24 -- DEC-TEST-001` Initial decision.

## Active Initiatives

### INIT-001: Test

- **Status:** in-progress
- **Goal:** Test immutability.
- **Current truth:** Hook exists.
- **Scope:** hooks only.
- **Exit:** Hook blocks rewrites.
- **Dependencies:** none

## Completed Initiatives

None.

## Parked Issues

None.
'

_restore_plan() {
    printf '%s' "$ORIGINAL_CONTENT" > "$PLAN_FILE"
    python3 "$TMP_DIR/scripts/planctl.py" refresh-baseline "$PLAN_FILE"
}

_restore_plan
git -C "$TMP_DIR" add MASTER_PLAN.md scripts/planctl.py
git -C "$TMP_DIR" commit -m "add plan and planctl" -q

PASS_COUNT=0
FAIL_COUNT=0
_pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
_fail() { echo "FAIL: $1 -- $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# ----------------------------------------------------------------
# Scenario A: rewrite Identity section -> should deny
# ----------------------------------------------------------------
python3 -c "
import pathlib
text = pathlib.Path('$PLAN_FILE').read_text()
modified = text.replace('This is the original identity text.', 'COMPLETELY REPLACED identity.')
pathlib.Path('$PLAN_FILE').write_text(modified)
"

PAYLOAD=$(jq -n \
    --arg tool_name "Write" \
    --arg file_path "$PLAN_FILE" \
    --arg content "$(cat "$PLAN_FILE")" \
    '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

output=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" 2>/dev/null) || true
decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)

if [[ "$decision" == "deny" ]]; then
    _pass "Scenario A: rewrite Identity -> deny"
else
    _fail "Scenario A: rewrite Identity" "expected deny, got '$decision' (output: $output)"
fi

# ----------------------------------------------------------------
# Scenario B: append to Identity section -> should allow
# ----------------------------------------------------------------
_restore_plan
python3 -c "
import pathlib
text = pathlib.Path('$PLAN_FILE').read_text()
modified = text.replace(
    'This is the original identity text.',
    'This is the original identity text.\n\nAppended paragraph.'
)
pathlib.Path('$PLAN_FILE').write_text(modified)
"

PAYLOAD=$(jq -n \
    --arg tool_name "Write" \
    --arg file_path "$PLAN_FILE" \
    --arg content "$(cat "$PLAN_FILE")" \
    '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

output=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" 2>/dev/null) || true
decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)

if [[ "$decision" != "deny" ]]; then
    _pass "Scenario B: append to Identity -> allow"
else
    reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
    _fail "Scenario B: append to Identity" "unexpected deny: $reason"
fi

# ----------------------------------------------------------------
# Scenario C: rewrite with CLAUDE_PLAN_MIGRATION=1 -> should allow
# ----------------------------------------------------------------
_restore_plan
python3 -c "
import pathlib
text = pathlib.Path('$PLAN_FILE').read_text()
modified = text.replace('This is the original identity text.', 'REPLACED via migration.')
pathlib.Path('$PLAN_FILE').write_text(modified)
"

PAYLOAD=$(jq -n \
    --arg tool_name "Write" \
    --arg file_path "$PLAN_FILE" \
    --arg content "$(cat "$PLAN_FILE")" \
    '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

output=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_PLAN_MIGRATION=1 "$HOOK" 2>/dev/null) || true
decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)

if [[ "$decision" != "deny" ]]; then
    _pass "Scenario C: CLAUDE_PLAN_MIGRATION=1 rewrite -> allow"
else
    reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
    _fail "Scenario C: CLAUDE_PLAN_MIGRATION=1 rewrite" "unexpected deny: $reason"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ $FAIL_COUNT -eq 0 ]]
