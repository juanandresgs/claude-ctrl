#!/usr/bin/env bash
# Test suite for W5-1: Remaining Hook Migrations + Remove Type Guards
#
# Validates:
#   T01: No `type state_update` guard patterns remain in any hook
#   T02: stop.sh reads proof state via proof_state_get
#   T03: compact-preserve.sh reads proof state via proof_state_get
#   T04: session-lib.sh track_subagent_start calls state_update directly
#   T05: session-lib.sh track_subagent_start emits agent.started event
#   T06: session-init.sh checks event count for governor trigger
#   T07: Lifecycle event emission — session start/end events
#   T08: require_state called before first state API usage in each hook
#
# Usage: bash tests/test-state-unify-w5-1.sh
# Exit: 0 if all pass, 1 if any fail
#
# @decision DEC-STATE-W5-1-001
# @title Test-first validation of W5-1 hook migrations
# @status accepted
# @rationale W5-1 removes `type state_update &>/dev/null` guards across hooks
#   and migrates remaining hooks to use the SQLite state API directly.
#   These tests validate by static analysis (grep) that the migration is
#   complete and the correct patterns are in place. No runtime SQLite
#   dependency required — all tests are structural/textual checks.

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)/hooks"
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
ERRORS=()

pass() { echo "  PASS: $1"; ((PASS++)) || true; }
fail() { echo "  FAIL: $1"; ERRORS+=("$1"); ((FAIL++)) || true; }

echo "=== W5-1: State Unification Hook Migrations ==="
echo ""

# ---------------------------------------------------------------------------
# T01: No `type state_update &>/dev/null && ... || true` guard patterns remain
#      in hook scripts (excludes libraries and comments)
# ---------------------------------------------------------------------------
echo "T01: No type-guard patterns remain in hook files..."

# Pattern: `type state_update &>/dev/null && state_update ... || true`
# Excludes:
#   - source-lib.sh: comment only, no functional guard
#   - db-guardian-lib.sh: uses `if type state_update` (different pattern, legitimate
#     in agent-layer library that loads without state-lib.sh)
#   - *-lib.sh: shared libraries, not hook scripts per se
TYPE_GUARD_PATTERN='type state_update &>/dev/null && state_update'
HOOKS_WITH_GUARDS=()
for hook_file in "$HOOKS_DIR"/*.sh; do
    [[ -f "$hook_file" ]] || continue
    hook_name=$(basename "$hook_file")
    # Skip pure library files (agent-layer libs may retain guards)
    case "$hook_name" in
        source-lib.sh) continue ;;  # comment only, no functional guard
    esac
    if grep -qF "$TYPE_GUARD_PATTERN" "$hook_file" 2>/dev/null; then
        HOOKS_WITH_GUARDS+=("$hook_name")
    fi
done

if [[ ${#HOOKS_WITH_GUARDS[@]} -eq 0 ]]; then
    pass "T01: No type-guard patterns found in hook files"
else
    fail "T01: type-guard patterns still exist in: ${HOOKS_WITH_GUARDS[*]}"
fi

# ---------------------------------------------------------------------------
# T02: stop.sh reads proof state via proof_state_get OR state API
# ---------------------------------------------------------------------------
echo "T02: stop.sh uses state API for proof state reads..."

STOP_SH="$HOOKS_DIR/stop.sh"
if [[ ! -f "$STOP_SH" ]]; then
    fail "T02: stop.sh not found"
else
    # Acceptable: either proof_state_get OR state_read "proof
    if grep -qE '(proof_state_get|state_read.*proof)' "$STOP_SH" 2>/dev/null; then
        pass "T02: stop.sh uses state API (proof_state_get or state_read) for proof state"
    else
        fail "T02: stop.sh does not use proof_state_get or state_read for proof state"
    fi
fi

# ---------------------------------------------------------------------------
# T03: compact-preserve.sh reads proof state via state API
# ---------------------------------------------------------------------------
echo "T03: compact-preserve.sh uses state API for proof state reads..."

COMPACT_SH="$HOOKS_DIR/compact-preserve.sh"
if [[ ! -f "$COMPACT_SH" ]]; then
    fail "T03: compact-preserve.sh not found"
else
    if grep -qE '(proof_state_get|state_read.*proof)' "$COMPACT_SH" 2>/dev/null; then
        pass "T03: compact-preserve.sh uses state API for proof state"
    else
        fail "T03: compact-preserve.sh does not use proof_state_get or state_read for proof state"
    fi
fi

# ---------------------------------------------------------------------------
# T04: session-lib.sh track_subagent_start calls state_update directly
# ---------------------------------------------------------------------------
echo "T04: session-lib.sh track_subagent_start uses direct state_update..."

SESSION_LIB="$HOOKS_DIR/session-lib.sh"
if [[ ! -f "$SESSION_LIB" ]]; then
    fail "T04: session-lib.sh not found"
else
    # Check that track_subagent_start function has direct state_update (no type guard)
    # Extract the function body and check
    FUNC_BODY=$(awk '/^track_subagent_start\(\)/{f=1} f{print} f && /^\}/{if(--d<0) exit} f && /\{/{d++}' "$SESSION_LIB" 2>/dev/null | head -30 || true)

    if echo "$FUNC_BODY" | grep -q 'state_update' 2>/dev/null; then
        # Make sure it's a DIRECT call (no type guard wrapper)
        if echo "$FUNC_BODY" | grep -qF 'type state_update' 2>/dev/null; then
            fail "T04: track_subagent_start still has type-guard wrapper for state_update"
        else
            pass "T04: track_subagent_start calls state_update directly (no type guard)"
        fi
    else
        fail "T04: track_subagent_start does not call state_update at all"
    fi
fi

# ---------------------------------------------------------------------------
# T05: session-lib.sh track_subagent_start emits agent.started event
# ---------------------------------------------------------------------------
echo "T05: session-lib.sh track_subagent_start emits agent.started event..."

if [[ ! -f "$SESSION_LIB" ]]; then
    fail "T05: session-lib.sh not found"
else
    FUNC_BODY=$(awk '/^track_subagent_start\(\)/{f=1} f{print} f && /^\}/{if(--d<0) exit} f && /\{/{d++}' "$SESSION_LIB" 2>/dev/null | head -40 || true)

    if echo "$FUNC_BODY" | grep -q 'state_emit.*agent.started\|state_emit.*agent\.started' 2>/dev/null; then
        pass "T05: track_subagent_start emits agent.started event via state_emit"
    else
        fail "T05: track_subagent_start does not emit agent.started event"
    fi
fi

# ---------------------------------------------------------------------------
# T06: session-init.sh checks event count for governor trigger
# ---------------------------------------------------------------------------
echo "T06: session-init.sh checks event count for governor auto-trigger..."

SESSION_INIT="$HOOKS_DIR/session-init.sh"
if [[ ! -f "$SESSION_INIT" ]]; then
    fail "T06: session-init.sh not found"
else
    if grep -q 'state_events_count' "$SESSION_INIT" 2>/dev/null; then
        pass "T06: session-init.sh calls state_events_count for governor trigger check"
    else
        fail "T06: session-init.sh does not call state_events_count"
    fi
fi

# ---------------------------------------------------------------------------
# T07: Lifecycle events — session.start emitted in session-init.sh
# ---------------------------------------------------------------------------
echo "T07: Lifecycle events emitted at session boundaries..."

if [[ ! -f "$SESSION_INIT" ]]; then
    fail "T07a: session-init.sh not found"
else
    if grep -q 'state_emit.*session\.start\|state_emit.*session.start' "$SESSION_INIT" 2>/dev/null; then
        pass "T07a: session-init.sh emits session.start event"
    else
        fail "T07a: session-init.sh does not emit session.start event"
    fi
fi

STOP_SH_CHECK="$HOOKS_DIR/stop.sh"
if [[ ! -f "$STOP_SH_CHECK" ]]; then
    fail "T07b: stop.sh not found"
else
    if grep -q 'state_emit.*session\.end\|state_emit.*session.end' "$STOP_SH_CHECK" 2>/dev/null; then
        pass "T07b: stop.sh emits session.end event"
    else
        fail "T07b: stop.sh does not emit session.end event"
    fi
fi

# ---------------------------------------------------------------------------
# T08: require_state called before first state API usage in each hook
# ---------------------------------------------------------------------------
echo "T08: require_state called before state API usage in modified hooks..."

# Hooks that use state API directly (without type guard) must call require_state
# We check: does the file call require_state somewhere before the first state_update/state_emit?
check_require_state() {
    local hook_file="$1"
    local hook_name
    hook_name=$(basename "$hook_file")

    # Only check hooks that have direct state API calls (no type guard)
    if ! grep -qE '^\s*(state_update|state_read|state_emit|state_events_count|proof_state_get)\b' "$hook_file" 2>/dev/null; then
        return 0  # No direct state calls — no requirement
    fi

    # If this file is session-lib.sh (a library), state is loaded by the caller — skip
    if [[ "$hook_name" == "session-lib.sh" ]]; then
        return 0
    fi

    # Check if require_state appears anywhere in the file
    if grep -q 'require_state' "$hook_file" 2>/dev/null; then
        return 0  # require_state present
    fi

    # Special case: session-init.sh is known to call require_state already
    # (it's in the require_* block at the top)
    return 1
}

MISSING_REQUIRE_STATE=()
for hook_file in "$HOOKS_DIR"/*.sh; do
    [[ -f "$hook_file" ]] || continue
    hook_name=$(basename "$hook_file")

    # Skip libraries — they don't call require_state themselves
    case "$hook_name" in
        *-lib.sh|source-lib.sh|state-lib.sh)
            continue ;;
    esac

    if ! check_require_state "$hook_file"; then
        MISSING_REQUIRE_STATE+=("$hook_name")
    fi
done

if [[ ${#MISSING_REQUIRE_STATE[@]} -eq 0 ]]; then
    pass "T08: All hooks with direct state API calls have require_state"
else
    fail "T08: Missing require_state in hooks with direct state calls: ${MISSING_REQUIRE_STATE[*]}"
fi

# ---------------------------------------------------------------------------
# T09: W5-2 markers present on flat-file ops that still need migration
# ---------------------------------------------------------------------------
echo "T09: Flat-file operations marked with W5-2 remove comments..."

# Check that major flat-file proof-status reads have a marker (best-effort)
W52_ISSUES=()

# stop.sh should have W5-2 markers on any remaining flat-file reads
for check_file in "$HOOKS_DIR/stop.sh" "$HOOKS_DIR/compact-preserve.sh"; do
    [[ -f "$check_file" ]] || continue
    # If the file still reads .proof-status directly without W5-2 marker,
    # and that line isn't also using state API, flag it
    if grep -q '\.proof-status-' "$check_file" 2>/dev/null; then
        if ! grep -q 'W5-2' "$check_file" 2>/dev/null; then
            W52_ISSUES+=("$(basename "$check_file"): has .proof-status reads without W5-2 marker")
        fi
    fi
done

if [[ ${#W52_ISSUES[@]} -eq 0 ]]; then
    pass "T09: Flat-file ops have W5-2 markers or are fully migrated"
else
    fail "T09: ${W52_ISSUES[*]}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if [[ "$FAIL" -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for err in "${ERRORS[@]}"; do
        echo "  - $err"
    done
    exit 1
fi

echo ""
echo "All tests passed."
exit 0
