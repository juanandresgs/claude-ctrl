#!/usr/bin/env bash
# tests/test-governor-wiring.sh — Governor wiring integration tests
#
# Tests for W2-1: Wire governor into dispatch infrastructure.
# Verifies:
#   1. settings.json has governor SubagentStop entry
#   2. check-governor.sh file exists and is executable
#   3. task-track.sh early-exit includes governor (doesn't gate it)
#   4. subagent-start.sh has governor case
#   5. CLAUDE.md has governor resources entry
#   6. docs/DISPATCH.md has governor routing row and auto-dispatch section
#
# @decision DEC-GOV-WIRE-001
# @title Test-first validation for governor wiring (W2-1)
# @status accepted
# @rationale Tests written before implementation to define the contract.
#   Each test maps directly to a change required by the work item spec.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"
SETTINGS="$PROJECT_ROOT/settings.json"
DISPATCH_MD="$PROJECT_ROOT/docs/DISPATCH.md"
CLAUDE_MD="$PROJECT_ROOT/CLAUDE.md"
TASK_TRACK="$HOOKS_DIR/task-track.sh"
SUBAGENT_START="$HOOKS_DIR/subagent-start.sh"
CHECK_GOVERNOR="$HOOKS_DIR/check-governor.sh"

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

echo "=== Governor Wiring Tests ==="
echo ""

# --- Test 1: check-governor.sh exists and is executable ---
echo "--- Test 1: check-governor.sh exists and is executable ---"
if [[ -f "$CHECK_GOVERNOR" ]]; then
    pass "check-governor.sh exists"
else
    fail "check-governor.sh exists" "file not found at $CHECK_GOVERNOR"
fi

if [[ -x "$CHECK_GOVERNOR" ]]; then
    pass "check-governor.sh is executable"
else
    fail "check-governor.sh is executable" "not executable"
fi

echo ""

# --- Test 2: settings.json has governor SubagentStop entry ---
echo "--- Test 2: settings.json has governor SubagentStop registration ---"
GOV_HOOK=$(python3 -c "
import json, sys
with open('$SETTINGS') as f:
    s = json.load(f)
hooks = s.get('hooks', {}).get('SubagentStop', [])
for entry in hooks:
    if entry.get('matcher') == 'governor':
        cmds = [h.get('command','') for h in entry.get('hooks',[])]
        if any('check-governor' in c for c in cmds):
            print('found')
            sys.exit(0)
print('missing')
" 2>/dev/null || echo "error")

if [[ "$GOV_HOOK" == "found" ]]; then
    pass "settings.json SubagentStop has governor matcher with check-governor.sh"
else
    fail "settings.json SubagentStop has governor matcher with check-governor.sh" "got: $GOV_HOOK"
fi

# Verify governor entry has timeout=5 consistent with other advisory hooks
GOV_TIMEOUT=$(python3 -c "
import json
with open('$SETTINGS') as f:
    s = json.load(f)
hooks = s.get('hooks', {}).get('SubagentStop', [])
for entry in hooks:
    if entry.get('matcher') == 'governor':
        for h in entry.get('hooks', []):
            if 'check-governor' in h.get('command',''):
                print(h.get('timeout', 'missing'))
" 2>/dev/null || echo "error")

if [[ "$GOV_TIMEOUT" == "5" ]]; then
    pass "settings.json governor hook has timeout=5"
else
    fail "settings.json governor hook has timeout=5" "got: $GOV_TIMEOUT"
fi

echo ""

# --- Test 3: task-track.sh early exit includes governor (should NOT gate it) ---
echo "--- Test 3: task-track.sh governor early-exit (no gates for governor) ---"

# Governor should be in the early-exit case (not in the gated case)
# The gated case is: guardian|tester|implementer
# Governor should hit the catch-all '*' early exit, OR be explicitly excluded from gating

# Check that governor is NOT in the gated list (guardian|tester|implementer)
GATED_PATTERN=$(grep -oE "guardian\|tester\|implementer[^)]*\)" "$TASK_TRACK" | head -1 || echo "")
if echo "$GATED_PATTERN" | grep -q "governor"; then
    fail "task-track.sh governor NOT in gated agent list" "governor appears in gated pattern: $GATED_PATTERN"
else
    pass "task-track.sh governor not in gated pattern (no proof/worktree gates for governor)"
fi

# Verify the early-exit catch-all is present (catches governor and other non-gated types)
if grep -q 'emit_flush; exit 0' "$TASK_TRACK"; then
    pass "task-track.sh has early-exit emit_flush for non-gated agents"
else
    fail "task-track.sh has early-exit emit_flush for non-gated agents" "pattern not found"
fi

echo ""

# --- Test 4: subagent-start.sh has governor case ---
echo "--- Test 4: subagent-start.sh has governor case ---"

if grep -q "governor)" "$SUBAGENT_START"; then
    pass "subagent-start.sh has governor case"
else
    fail "subagent-start.sh has governor case" "no 'governor)' case found"
fi

# Extract the governor case block (from 'governor)' to the next ';;' terminator)
# Use awk to get exactly the governor case body — more precise than grep -A N
GOV_CASE=$(awk '/^    governor\)/{f=1} f{print} f && /^        ;;/{exit}' "$SUBAGENT_START")

# Verify governor case sets Role context
if echo "$GOV_CASE" | grep -q "Role:.*[Gg]overnor"; then
    pass "subagent-start.sh governor case sets Role context"
else
    fail "subagent-start.sh governor case sets Role context" "no Role: Governor text in governor case"
fi

# Verify governor case injects MASTER_PLAN.md context (Original Intent / Principles)
if echo "$GOV_CASE" | grep -qiE "original.intent|principles|MASTER_PLAN"; then
    pass "subagent-start.sh governor case injects MASTER_PLAN context"
else
    fail "subagent-start.sh governor case injects MASTER_PLAN context" "no MASTER_PLAN/Principles injection found"
fi

# Verify governor case sets TRACE_DIR
if echo "$GOV_CASE" | grep -q "TRACE_DIR"; then
    pass "subagent-start.sh governor case sets TRACE_DIR"
else
    fail "subagent-start.sh governor case sets TRACE_DIR" "no TRACE_DIR in governor case"
fi

echo ""

# --- Test 5: CLAUDE.md has governor Resources table entry ---
echo "--- Test 5: CLAUDE.md has governor resources entry ---"

if grep -q "agents/governor.md" "$CLAUDE_MD"; then
    pass "CLAUDE.md has agents/governor.md in Resources table"
else
    fail "CLAUDE.md has agents/governor.md in Resources table" "not found"
fi

echo ""

# --- Test 6: docs/DISPATCH.md has governor routing and auto-dispatch ---
echo "--- Test 6: docs/DISPATCH.md governor routing and auto-dispatch ---"

# Check routing table has governor row
if grep -q "Governor" "$DISPATCH_MD"; then
    pass "docs/DISPATCH.md mentions Governor"
else
    fail "docs/DISPATCH.md mentions Governor" "no Governor reference found"
fi

# Check auto-dispatch section for governor
if grep -q "Auto-dispatch to Governor" "$DISPATCH_MD"; then
    pass "docs/DISPATCH.md has Auto-dispatch to Governor section"
else
    fail "docs/DISPATCH.md has Auto-dispatch to Governor section" "not found"
fi

# Check Pre-Dispatch Gates note for governor
if grep -qiE "Governor dispatch.*advisory|advisory.*[Gg]overnor|no proof-status gate.*[Gg]overnor|[Gg]overnor.*no proof-status" "$DISPATCH_MD"; then
    pass "docs/DISPATCH.md Pre-Dispatch Gates notes governor is advisory (no proof gate)"
else
    fail "docs/DISPATCH.md Pre-Dispatch Gates notes governor is advisory (no proof gate)" "no advisory/no-gate note found"
fi

echo ""

# --- Test 7: settings.json sync (check-governor.sh registered) ---
echo "--- Test 7: settings.json sync — no orphans or unregistered hooks ---"

REGISTERED_HOOKS=$(python3 -c "
import json, re
with open('$SETTINGS') as f:
    s = json.load(f)

def find_commands(obj):
    if isinstance(obj, dict):
        cmd = obj.get('command', '')
        if cmd and re.search(r'hooks/.*\.sh$', cmd):
            yield re.sub(r'.*/hooks/', '', cmd)
        for v in obj.values():
            yield from find_commands(v)
    elif isinstance(obj, list):
        for item in obj:
            yield from find_commands(item)

print('\n'.join(sorted(set(find_commands(s)))))
" 2>/dev/null || echo "error")

ACTUAL_HOOKS=$(find "$HOOKS_DIR" -maxdepth 1 -name '*.sh' -print0 2>/dev/null | xargs -0 -n1 basename | sort)

ORPHANS=""
UNREGISTERED=""

while IFS= read -r hook; do
    [[ -z "$hook" ]] && continue
    if [[ ! -f "$HOOKS_DIR/$hook" ]]; then
        ORPHANS+="$hook "
    fi
done <<< "$REGISTERED_HOOKS"

while IFS= read -r hook; do
    [[ -z "$hook" ]] && continue
    if ! echo "$REGISTERED_HOOKS" | grep -q "^$hook$"; then
        case "$hook" in
            log.sh|source-lib.sh|state-registry.sh|state-lib.sh|\
            ci-lib.sh|core-lib.sh|doc-lib.sh|git-lib.sh|plan-lib.sh|session-lib.sh|trace-lib.sh)
                # Library files, not registered hooks
                ;;
            *)
                UNREGISTERED+="$hook "
                ;;
        esac
    fi
done <<< "$ACTUAL_HOOKS"

if [[ -z "$ORPHANS" && -z "$UNREGISTERED" ]]; then
    pass "settings.json sync — no orphans or unregistered hooks"
else
    [[ -n "$ORPHANS" ]] && fail "settings.json sync orphans" "orphan registrations: $ORPHANS"
    [[ -n "$UNREGISTERED" ]] && fail "settings.json sync unregistered" "unregistered hooks: $UNREGISTERED"
fi

echo ""

# --- Summary ---
echo "==========================="
echo "Governor Wiring Tests: $PASS passed, $FAIL failed"
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for err in "${ERRORS[@]}"; do
        echo "  - $err"
    done
    exit 1
fi
echo "All governor wiring tests passed."
exit 0
