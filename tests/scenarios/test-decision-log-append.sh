#!/usr/bin/env bash
# test-decision-log-append.sh: verify that pre-write.sh denies decision log
# deletions and allows new-entry appends.
#
# Scenario A: delete an existing decision entry -> expect deny
# Scenario B: add new entry at end -> expect allow
# Scenario C: CLAUDE_PLAN_MIGRATION=1 delete -> expect allow (migration override)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-write.sh"
TMP_DIR="$REPO_ROOT/tmp/test-decision-log-append-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Setup: minimal git repo with planctl.py copied in (required for plan-policy.sh
# to resolve check-decision-log via $project_root/scripts/planctl.py).
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

Original identity.

## Architecture

Architecture.

## Original Intent

Bootstrap a test.

## Principles

1. Simple.

## Decision Log

- `2026-03-24 -- DEC-TEST-001` First decision.
- `2026-03-24 -- DEC-TEST-002` Second decision.

## Active Initiatives

### INIT-001: Test

- **Status:** in-progress
- **Goal:** Test decision log.
- **Current truth:** Log exists.
- **Scope:** hooks only.
- **Exit:** Hook blocks deletions.
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
# Scenario A: delete first decision entry -> should deny
# ----------------------------------------------------------------
python3 -c "
import pathlib
text = pathlib.Path('$PLAN_FILE').read_text()
modified = text.replace(\"- \`2026-03-24 -- DEC-TEST-001\` First decision.\n\", '')
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
    _pass "Scenario A: delete decision entry -> deny"
else
    _fail "Scenario A: delete decision entry" "expected deny, got '$decision' (output: $output)"
fi

# ----------------------------------------------------------------
# Scenario B: append new decision entry -> should allow
# ----------------------------------------------------------------
_restore_plan
python3 -c "
import pathlib
text = pathlib.Path('$PLAN_FILE').read_text()
modified = text.replace(
    \"- \`2026-03-24 -- DEC-TEST-002\` Second decision.\",
    \"- \`2026-03-24 -- DEC-TEST-002\` Second decision.\n- \`2026-03-24 -- DEC-TEST-003\` Third decision.\"
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
    _pass "Scenario B: append new decision entry -> allow"
else
    reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
    _fail "Scenario B: append new decision entry" "unexpected deny: $reason"
fi

# ----------------------------------------------------------------
# Scenario C: delete with CLAUDE_PLAN_MIGRATION=1 -> should allow
# ----------------------------------------------------------------
_restore_plan
python3 -c "
import pathlib
text = pathlib.Path('$PLAN_FILE').read_text()
modified = text.replace(\"- \`2026-03-24 -- DEC-TEST-001\` First decision.\n\", '')
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
    _pass "Scenario C: CLAUDE_PLAN_MIGRATION=1 delete -> allow"
else
    reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
    _fail "Scenario C: CLAUDE_PLAN_MIGRATION=1 delete" "unexpected deny: $reason"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ $FAIL_COUNT -eq 0 ]]
