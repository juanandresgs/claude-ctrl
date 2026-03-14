#!/usr/bin/env bash
# Test suite for W6-1: Event-Driven Governor Triggers + Observatory Signals
#
# Validates:
#   T01: check-tester.sh emits governor.assessment event
#   T02: check-implementer.sh emits governor.assessment event
#   T03: check-guardian.sh emits governor.assessment event
#   T04: session-init.sh triggers governor advisory when >= 3 assessments pending
#   T05: session-init.sh does NOT trigger advisory when count < 3
#   T06: Hook failure emits hook.failure event in source-lib.sh
#   T07: session-init.sh triggers self-heal advisory when >= 5 failures
#   T08: stop.sh emits observatory.session event
#   T09: Event GC runs at session end (stop.sh calls state_gc_events)
#   T10: All emitted events use correct structure (best-effort pattern)
#
# Usage: bash tests/test-state-unify-w6-1.sh
# Exit: 0 if all pass, 1 if any fail
#
# @decision DEC-STATE-W6-1-001
# @title Static analysis tests for W6-1 event emission patterns
# @status accepted
# @rationale W6-1 adds state_emit() calls at lifecycle points in hooks to populate
#   the event ledger with governor.assessment, hook.failure, and observatory.session
#   events. Tests validate by structural analysis that:
#   1. Each hook emits the correct event type after its key lifecycle action
#   2. All emissions use best-effort pattern (>/dev/null 2>/dev/null || true)
#   3. The session-init governor advisory reads count and builds advisory context
#   4. The self-heal advisory threshold is correctly set (>= 5 failures)
#   Static analysis is sufficient — correctness of the SQLite event infrastructure
#   is covered by test-sqlite-wave4.sh; we only need to verify the call sites here.

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)/hooks"
PASS=0
FAIL=0
ERRORS=()

pass() { echo "  PASS: $1"; ((PASS++)) || true; }
fail() { echo "  FAIL: $1"; ERRORS+=("$1"); ((FAIL++)) || true; }

echo "=== W6-1: Event-Driven Governor Triggers + Observatory Signals ==="
echo ""

# ---------------------------------------------------------------------------
# T01: check-tester.sh emits governor.assessment event after tester completes
# ---------------------------------------------------------------------------
echo "T01: check-tester.sh emits governor.assessment event..."

TESTER_SH="$HOOKS_DIR/check-tester.sh"
if [[ ! -f "$TESTER_SH" ]]; then
    fail "T01: check-tester.sh not found"
else
    # Must contain state_emit with governor.assessment type
    if grep -q 'state_emit.*governor\.assessment\|state_emit "governor\.assessment"' "$TESTER_SH" 2>/dev/null; then
        pass "T01: check-tester.sh emits governor.assessment event"
    else
        fail "T01: check-tester.sh does not emit governor.assessment event"
    fi
fi

# ---------------------------------------------------------------------------
# T02: check-implementer.sh emits governor.assessment event
# ---------------------------------------------------------------------------
echo "T02: check-implementer.sh emits governor.assessment event..."

IMPL_SH="$HOOKS_DIR/check-implementer.sh"
if [[ ! -f "$IMPL_SH" ]]; then
    fail "T02: check-implementer.sh not found"
else
    if grep -q 'state_emit.*governor\.assessment\|state_emit "governor\.assessment"' "$IMPL_SH" 2>/dev/null; then
        pass "T02: check-implementer.sh emits governor.assessment event"
    else
        fail "T02: check-implementer.sh does not emit governor.assessment event"
    fi
fi

# ---------------------------------------------------------------------------
# T03: check-guardian.sh emits governor.assessment event after merge
# ---------------------------------------------------------------------------
echo "T03: check-guardian.sh emits governor.assessment event..."

GUARD_SH="$HOOKS_DIR/check-guardian.sh"
if [[ ! -f "$GUARD_SH" ]]; then
    fail "T03: check-guardian.sh not found"
else
    if grep -q 'state_emit.*governor\.assessment\|state_emit "governor\.assessment"' "$GUARD_SH" 2>/dev/null; then
        pass "T03: check-guardian.sh emits governor.assessment event"
    else
        fail "T03: check-guardian.sh does not emit governor.assessment event"
    fi
fi

# ---------------------------------------------------------------------------
# T04: session-init.sh governor advisory REMOVED (governor parked, DEC-PERF-006)
# ---------------------------------------------------------------------------
echo "T04: session-init.sh has no governor advisory block (governor parked)..."

SINIT_SH="$HOOKS_DIR/session-init.sh"
if [[ ! -f "$SINIT_SH" ]]; then
    fail "T04: session-init.sh not found"
else
    # Governor advisory was removed when governor was parked (Issue #253).
    # The _PENDING_GOVERNOR variable and GOVERNOR ADVISORY text should not exist.
    if ! grep -q '_PENDING_GOVERNOR=' "$SINIT_SH" 2>/dev/null && \
       ! grep -q 'GOVERNOR ADVISORY' "$SINIT_SH" 2>/dev/null; then
        pass "T04: session-init.sh governor advisory removed (governor parked)"
    else
        fail "T04: session-init.sh still has governor advisory block — should be removed (DEC-PERF-006)"
    fi
fi

# ---------------------------------------------------------------------------
# T05: session-init.sh no governor event count check (advisory removed)
# ---------------------------------------------------------------------------
echo "T05: session-init.sh has no governor event count check..."

if [[ ! -f "$SINIT_SH" ]]; then
    fail "T05: session-init.sh not found"
else
    # The state_events_count("governor", ...) call was part of the advisory block.
    # With the block removed, there should be no _PENDING_GOVERNOR variable.
    if ! grep -qE '_pending_gov.*>=.*3|_PENDING_GOVERNOR.*>=.*3' "$SINIT_SH" 2>/dev/null; then
        pass "T05: session-init.sh has no governor event count threshold check"
    else
        fail "T05: session-init.sh still has governor count threshold check"
    fi
fi

# ---------------------------------------------------------------------------
# T06: source-lib.sh emits hook.failure event on non-zero exit
# ---------------------------------------------------------------------------
echo "T06: source-lib.sh emits hook.failure event on error..."

SRCLIB_SH="$HOOKS_DIR/source-lib.sh"
if [[ ! -f "$SRCLIB_SH" ]]; then
    fail "T06: source-lib.sh not found"
else
    # Must have state_emit for hook.failure with bootstrap-order guard.
    # The guard (type state_emit &>/dev/null &&) and the call (state_emit "hook.failure")
    # are on separate lines — check for each independently.
    HAS_FAILURE_EMIT=false
    HAS_TYPE_GUARD=false
    if grep -q 'state_emit.*hook\.failure\|state_emit "hook\.failure"' "$SRCLIB_SH" 2>/dev/null; then
        HAS_FAILURE_EMIT=true
    fi
    # Bootstrap guard: type state_emit &>/dev/null && (on its own line or with &&)
    if grep -qE 'type state_emit.*&>/dev/null.*&&|type state_emit.*&>.*&&' "$SRCLIB_SH" 2>/dev/null; then
        HAS_TYPE_GUARD=true
    fi

    if $HAS_FAILURE_EMIT && $HAS_TYPE_GUARD; then
        pass "T06: source-lib.sh emits hook.failure with bootstrap guard"
    elif ! $HAS_FAILURE_EMIT; then
        fail "T06: source-lib.sh does not emit hook.failure event"
    else
        fail "T06: source-lib.sh emits hook.failure but missing bootstrap guard (type state_emit &>/dev/null &&)"
    fi
fi

# ---------------------------------------------------------------------------
# T07: session-init.sh triggers self-heal advisory when >= 5 hook failures
# ---------------------------------------------------------------------------
echo "T07: session-init.sh has self-heal advisory at >= 5 failure threshold..."

if [[ ! -f "$SINIT_SH" ]]; then
    fail "T07: session-init.sh not found"
else
    HAS_FAILURE_CHECK=false
    HAS_SELFHEAL_ADVISORY=false
    # Check for failure event count check with >= 5 threshold
    if grep -qE '_pending_failures.*>=.*5|\(\(.*_pending_failures.*>=.*5.*\)\)' "$SINIT_SH" 2>/dev/null; then
        HAS_FAILURE_CHECK=true
    fi
    # Check for self-heal advisory text
    if grep -q 'SELF-HEAL ADVISORY' "$SINIT_SH" 2>/dev/null; then
        HAS_SELFHEAL_ADVISORY=true
    fi

    if $HAS_FAILURE_CHECK && $HAS_SELFHEAL_ADVISORY; then
        pass "T07: session-init.sh has self-heal advisory at >= 5 failure threshold"
    elif ! $HAS_FAILURE_CHECK; then
        fail "T07: session-init.sh missing >= 5 threshold check for self-heal advisory"
    else
        fail "T07: session-init.sh missing SELF-HEAL ADVISORY text"
    fi
fi

# ---------------------------------------------------------------------------
# T08: stop.sh emits observatory.session event
# ---------------------------------------------------------------------------
echo "T08: stop.sh emits observatory.session event..."

STOP_SH="$HOOKS_DIR/stop.sh"
if [[ ! -f "$STOP_SH" ]]; then
    fail "T08: stop.sh not found"
else
    if grep -q 'state_emit.*observatory\.session\|state_emit "observatory\.session"' "$STOP_SH" 2>/dev/null; then
        pass "T08: stop.sh emits observatory.session event"
    else
        fail "T08: stop.sh does not emit observatory.session event"
    fi
fi

# ---------------------------------------------------------------------------
# T09: Event GC REMOVED — stop.sh must NOT call state_gc_events (issue #229)
# Events are institutional memory; the superseded annotation must be present.
# ---------------------------------------------------------------------------
echo "T09: stop.sh must not call state_gc_events (events are institutional memory)..."

if [[ ! -f "$STOP_SH" ]]; then
    fail "T09: stop.sh not found"
else
    if grep -q 'state_gc_events' "$STOP_SH" 2>/dev/null; then
        fail "T09: stop.sh still calls state_gc_events — GC was removed per issue #229"
    else
        pass "T09: stop.sh does not call state_gc_events"
    fi
    if grep -q 'DEC-STATE-W6-1-006' "$STOP_SH" 2>/dev/null && grep -q 'superseded' "$STOP_SH" 2>/dev/null; then
        pass "T09b: superseded annotation DEC-STATE-W6-1-006 present in stop.sh"
    else
        fail "T09b: superseded annotation DEC-STATE-W6-1-006 missing from stop.sh"
    fi
fi

# ---------------------------------------------------------------------------
# T10: All state_emit calls use best-effort pattern (>/dev/null 2>/dev/null || true)
# ---------------------------------------------------------------------------
echo "T10: All new state_emit calls in modified hooks use best-effort pattern..."

ALL_PASS=true
CHECK_HOOKS=("$HOOKS_DIR/check-tester.sh" "$HOOKS_DIR/check-implementer.sh"
             "$HOOKS_DIR/check-guardian.sh" "$HOOKS_DIR/stop.sh")

for hook_file in "${CHECK_HOOKS[@]}"; do
    hook_name=$(basename "$hook_file")
    [[ -f "$hook_file" ]] || continue
    # Find state_emit lines with governor.assessment or observatory.session
    # They must all end with || true or use best-effort pattern
    BAD_LINES=$(grep -n 'state_emit.*governor\.assessment\|state_emit.*observatory\.session\|state_emit.*hook\.failure' \
        "$hook_file" 2>/dev/null | \
        grep -v '>/dev/null.*>/dev/null.*|| true\|>/dev/null 2>/dev/null || true\|2>/dev/null || true' || true)
    if [[ -n "$BAD_LINES" ]]; then
        fail "T10: $hook_name has state_emit without best-effort pattern: $BAD_LINES"
        ALL_PASS=false
    fi
done

# Check source-lib.sh separately (uses type guard + best-effort)
SRC_BAD=$(grep -n 'state_emit.*hook\.failure' "$HOOKS_DIR/source-lib.sh" 2>/dev/null | \
    grep -v '|| true' || true)
if [[ -n "$SRC_BAD" ]]; then
    fail "T10: source-lib.sh hook.failure emission missing || true: $SRC_BAD"
    ALL_PASS=false
fi

if $ALL_PASS; then
    pass "T10: All governor.assessment/observatory.session/hook.failure emissions use best-effort pattern"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "Failed tests:"
    for err in "${ERRORS[@]}"; do
        echo "  - $err"
    done
fi

[[ "$FAIL" -eq 0 ]]
