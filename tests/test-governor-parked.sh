#!/usr/bin/env bash
# tests/test-governor-parked.sh — Validates governor is fully parked (Issue #253)
#
# Verifies the "parked" state: governor agent removed from dispatch infrastructure
# to save ~4,200 tokens/session from the Agent tool schema.
#
# Tests:
#   T01: agents/governor.md is deleted (no longer loads into Agent tool schema)
#   T02: settings.json has NO governor SubagentStop entry
#   T03: hooks/check-governor.sh is deleted (no dead hook code)
#   T04: subagent-start.sh has NO governor case (no agent-type-specific injection)
#   T05: CLAUDE.md has NO agents/governor.md reference in Resources table
#   T06: docs/DISPATCH.md has NO governor auto-dispatch section
#   T07: settings.json is valid JSON (no comma errors from removal)
#   T08: test-governor-wiring.sh is deleted (obsolete test file)
#   T09: governor.assessment event emissions remain in check-tester/implementer/guardian
#         (state events still recorded — governor can be restored and use them)
#   T10: session-init.sh governor advisory block is removed
#
# @decision DEC-PERF-006
# @title Park governor agent — 0.8% dispatch rate, ~4,200 tokens saved per session
# @status accepted
# @rationale 9 invocations across 1,093 traces (0.8% dispatch rate). 12.3KB prompt
#   loaded as subagent schema every session. Purely advisory — no hook depends on
#   its output, no workflow is gated by it. Savings: ~4,200 tokens/session from
#   Agent tool schema. Git history preserves for restoration. State events that
#   would have triggered governor dispatch are still emitted — future restoration
#   can hook into them without needing hook changes in other agents.
#
# Usage: bash tests/test-governor-parked.sh
# Exit: 0 if all pass, 1 if any fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"
SETTINGS="$PROJECT_ROOT/settings.json"
DISPATCH_MD="$PROJECT_ROOT/docs/DISPATCH.md"
CLAUDE_MD="$PROJECT_ROOT/CLAUDE.md"
SUBAGENT_START="$HOOKS_DIR/subagent-start.sh"
SESSION_INIT="$HOOKS_DIR/session-init.sh"

PASS=0
FAIL=0
ERRORS=()

pass() {
    local name="$1"
    echo "  PASS: $name"
    (( PASS++ )) || true
}

fail() {
    local name="$1"
    local reason="${2:-}"
    echo "  FAIL: $name${reason:+ — $reason}"
    (( FAIL++ )) || true
    ERRORS+=("$name${reason:+: $reason}")
}

echo "=== Governor Parked Tests (Issue #253) ==="
echo ""

# --- T01: agents/governor.md is deleted ---
echo "--- T01: agents/governor.md deleted ---"
if [[ ! -f "$PROJECT_ROOT/agents/governor.md" ]]; then
    pass "agents/governor.md is gone (not loaded into Agent tool schema)"
else
    fail "agents/governor.md is gone" "file still exists — not parked"
fi
echo ""

# --- T02: settings.json has NO governor SubagentStop entry ---
echo "--- T02: settings.json has no governor SubagentStop entry ---"
GOV_HOOK=$(python3 -c "
import json, sys
with open('$SETTINGS') as f:
    s = json.load(f)
hooks = s.get('hooks', {}).get('SubagentStop', [])
for entry in hooks:
    if entry.get('matcher') == 'governor':
        print('found')
        sys.exit(0)
print('missing')
" 2>/dev/null || echo "error")

if [[ "$GOV_HOOK" == "missing" ]]; then
    pass "settings.json SubagentStop has no governor matcher"
else
    fail "settings.json SubagentStop has no governor matcher" "governor entry still present: $GOV_HOOK"
fi
echo ""

# --- T03: hooks/check-governor.sh is deleted ---
echo "--- T03: hooks/check-governor.sh deleted ---"
if [[ ! -f "$HOOKS_DIR/check-governor.sh" ]]; then
    pass "hooks/check-governor.sh is gone (no dead hook code)"
else
    fail "hooks/check-governor.sh is gone" "file still exists"
fi
echo ""

# --- T04: subagent-start.sh has NO governor case ---
echo "--- T04: subagent-start.sh has no governor case ---"
if ! grep -q 'governor)' "$SUBAGENT_START" 2>/dev/null; then
    pass "subagent-start.sh has no governor) case"
else
    fail "subagent-start.sh has no governor) case" "governor) case still present"
fi

# Also check that CWD Safety skip for governor is gone
if ! grep -q '"governor"' "$SUBAGENT_START" 2>/dev/null; then
    pass "subagent-start.sh has no governor string references"
else
    fail "subagent-start.sh has no governor string references" "found governor references"
fi
echo ""

# --- T05: CLAUDE.md has NO agents/governor.md reference ---
echo "--- T05: CLAUDE.md has no agents/governor.md reference ---"
if ! grep -q "agents/governor.md" "$CLAUDE_MD" 2>/dev/null; then
    pass "CLAUDE.md has no agents/governor.md reference"
else
    fail "CLAUDE.md has no agents/governor.md reference" "reference still present"
fi
echo ""

# --- T06: docs/DISPATCH.md has no governor auto-dispatch section ---
echo "--- T06: docs/DISPATCH.md has no governor auto-dispatch section ---"
if ! grep -q "Auto-dispatch to Governor" "$DISPATCH_MD" 2>/dev/null; then
    pass "docs/DISPATCH.md has no 'Auto-dispatch to Governor' section"
else
    fail "docs/DISPATCH.md has no 'Auto-dispatch to Governor' section" "section still present"
fi
echo ""

# --- T07: settings.json is valid JSON ---
echo "--- T07: settings.json is valid JSON ---"
if python3 -c "import json; json.load(open('$SETTINGS'))" 2>/dev/null; then
    pass "settings.json is valid JSON"
else
    fail "settings.json is valid JSON" "JSON parse error — check comma placement after removal"
fi
echo ""

# --- T08: test-governor-wiring.sh is deleted (obsolete test) ---
echo "--- T08: tests/test-governor-wiring.sh deleted ---"
if [[ ! -f "$PROJECT_ROOT/tests/test-governor-wiring.sh" ]]; then
    pass "tests/test-governor-wiring.sh is gone (obsolete test)"
else
    fail "tests/test-governor-wiring.sh is gone" "file still exists"
fi
echo ""

# --- T09: governor.assessment event emissions remain in check hooks ---
# These events are still emitted so a restored governor can consume them.
echo "--- T09: governor.assessment events still emitted in check hooks ---"
if grep -q 'state_emit.*governor\.assessment\|state_emit "governor\.assessment"' \
        "$HOOKS_DIR/check-tester.sh" 2>/dev/null; then
    pass "check-tester.sh still emits governor.assessment event"
else
    fail "check-tester.sh still emits governor.assessment event" "event emission removed"
fi

if grep -q 'state_emit.*governor\.assessment\|state_emit "governor\.assessment"' \
        "$HOOKS_DIR/check-implementer.sh" 2>/dev/null; then
    pass "check-implementer.sh still emits governor.assessment event"
else
    fail "check-implementer.sh still emits governor.assessment event" "event emission removed"
fi

if grep -q 'state_emit.*governor\.assessment\|state_emit "governor\.assessment"' \
        "$HOOKS_DIR/check-guardian.sh" 2>/dev/null; then
    pass "check-guardian.sh still emits governor.assessment event"
else
    fail "check-guardian.sh still emits governor.assessment event" "event emission removed"
fi
echo ""

# --- T10: session-init.sh governor advisory block is removed ---
echo "--- T10: session-init.sh governor advisory block removed ---"
# The session-init governor advisory fires when >= 3 governor.assessment events pile up.
# This advisory prompted the orchestrator to dispatch the governor.
# With governor parked, the advisory block is dead code and should be removed.
# The block is identified by: _PENDING_GOVERNOR= or "GOVERNOR ADVISORY"
if ! grep -q '_PENDING_GOVERNOR=' "$SESSION_INIT" 2>/dev/null && \
   ! grep -q 'GOVERNOR ADVISORY' "$SESSION_INIT" 2>/dev/null; then
    pass "session-init.sh has no governor advisory block (_PENDING_GOVERNOR / GOVERNOR ADVISORY)"
else
    fail "session-init.sh has no governor advisory block" "_PENDING_GOVERNOR or GOVERNOR ADVISORY still present"
fi
echo ""

# --- T11: settings.json has no orphaned check-governor.sh registration ---
echo "--- T11: settings.json sync — no orphan check-governor.sh registration ---"
ORPHAN=$(python3 -c "
import json
with open('$SETTINGS') as f:
    s = json.load(f)
import json as j

def walk(obj):
    if isinstance(obj, dict):
        cmd = obj.get('command', '')
        if 'check-governor' in cmd:
            return True
        return any(walk(v) for v in obj.values())
    elif isinstance(obj, list):
        return any(walk(item) for item in obj)
    return False

print('found' if walk(s) else 'clean')
" 2>/dev/null || echo "error")

if [[ "$ORPHAN" == "clean" ]]; then
    pass "settings.json has no check-governor.sh reference"
else
    fail "settings.json has no check-governor.sh reference" "check-governor.sh still referenced"
fi
echo ""

# --- Summary ---
echo "==========================="
echo "Governor Parked Tests: $PASS passed, $FAIL failed"
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for err in "${ERRORS[@]}"; do
        echo "  - $err"
    done
    exit 1
fi
echo "All governor parked tests passed."
exit 0
