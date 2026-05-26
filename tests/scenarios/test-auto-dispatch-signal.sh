#!/usr/bin/env bash
# test-auto-dispatch-signal.sh — End-to-end scenario test for W-AD-1.
#
# Verifies that `cc-policy dispatch process-stop` emits:
#   - auto_dispatch=true and suggestion prefixed with "AUTO_DISPATCH: <role>"
#     for clear, unblocked, non-terminal transitions.
#   - auto_dispatch=false and suggestion prefixed with "Canonical flow suggests"
#     (or empty) for interrupted, errored, or terminal states.
#
# Each test case uses its own worktree subdirectory to prevent lease collisions
# when multiple tests for the same role run against the same DB.
#
# All cases exercise the real production path:
#   synthetic JSON stdin → cc-policy dispatch process-stop → SQLite state
#
# @decision DEC-AD-001
# @title Scenario test: auto_dispatch signal in process-stop output
# @status accepted
# @rationale W-AD-1 (issue #13) adds auto_dispatch to distinguish
#   "orchestrator should auto-dispatch" from "prompt user for permission".
#   The signal must flow through the full CLI path so post-task.sh (and any
#   orchestrator reading hookSpecificOutput) can act on it. This test
#   exercises each transition class: fixed-route (planner), interrupted
#   implementer, tester completion variants, guardian terminal and retry.

set -euo pipefail

TEST_NAME="test-auto-dispatch-signal"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"

# shellcheck disable=SC2329  # cleanup is invoked via trap EXIT
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
mkdir -p "$TMP_DIR"

CC="python3 $REPO_ROOT/runtime/cli.py"

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "=== $TEST_NAME ==="

# --- Bootstrap schema ---
CLAUDE_POLICY_DB="$TEST_DB" $CC schema ensure >/dev/null 2>&1

# Helper: call process-stop for a given agent_type against a specific worktree path.
# Uses the shared TEST_DB (set via CLAUDE_POLICY_DB env in callers).
# Usage: call_process_stop <agent_type> <worktree_path>
call_process_stop() {
    local agent_type="$1"
    local root="$2"
    printf '{"agent_type":"%s","project_root":"%s"}' "$agent_type" "$root" \
        | CLAUDE_POLICY_DB="$TEST_DB" $CC dispatch process-stop 2>/dev/null || echo '{}'
}

# Helper: issue a lease for a specific worktree path and return the lease_id.
issue_lease() {
    local role="$1"
    local wf_id="$2"
    local wt_path="$3"
    local out
    out=$(CLAUDE_POLICY_DB="$TEST_DB" $CC lease issue-for-dispatch "$role" \
        --worktree-path "$wt_path" \
        --workflow-id "$wf_id" \
        --allowed-ops '["routine_local"]' 2>/dev/null || echo '{}')
    printf '%s' "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('lease',{}).get('lease_id',''))" 2>/dev/null || true
}

# Helper: submit a completion record.
submit_completion() {
    local role="$1"
    local lease_id="$2"
    local wf_id="$3"
    local payload="$4"
    CLAUDE_POLICY_DB="$TEST_DB" $CC completion submit \
        --lease-id "$lease_id" \
        --workflow-id "$wf_id" \
        --role "$role" \
        --payload "$payload" >/dev/null 2>&1 || true
}

# ==========================================================================
# Test 1: planner stop → auto_dispatch=true, suggestion starts AUTO_DISPATCH:
# (planner has no lease requirement — uses a scratch worktree path)
# ==========================================================================
WD1="$TMP_DIR/wt-planner"
mkdir -p "$WD1"
OUT=$(call_process_stop "planner" "$WD1")
AUTO=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('auto_dispatch','missing'))" 2>/dev/null || echo "missing")
CTX=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hookSpecificOutput',{}).get('additionalContext',''))" 2>/dev/null || true)

if [[ "$AUTO" == "True" ]]; then
    pass "planner: auto_dispatch=true"
else
    fail "planner: auto_dispatch=true (got: $AUTO, full output: $OUT)"
fi

if [[ "$CTX" == AUTO_DISPATCH:* ]]; then
    pass "planner: suggestion prefixed AUTO_DISPATCH: (got: $CTX)"
else
    fail "planner: suggestion prefixed AUTO_DISPATCH: (got: $CTX)"
fi

# W-GWT-1: planner now routes to guardian (not implementer directly)
if [[ "$CTX" == *"guardian"* ]]; then
    pass "planner: suggestion mentions guardian (W-GWT-1)"
else
    fail "planner: suggestion mentions guardian (got: $CTX)"
fi

# ==========================================================================
# Test 2: implementer stop (complete contract) → auto_dispatch=true
# ==========================================================================
WD2="$TMP_DIR/wt-impl-complete"
mkdir -p "$WD2"
WF2="wf-ad-impl-e2e"
LEASE2=$(issue_lease "implementer" "$WF2" "$WD2")
if [[ -n "$LEASE2" ]]; then
    submit_completion "implementer" "$LEASE2" "$WF2" '{"IMPL_STATUS":"complete","IMPL_HEAD_SHA":"deadbeef"}'
    OUT=$(call_process_stop "implementer" "$WD2")
    AUTO=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('auto_dispatch','missing'))" 2>/dev/null || echo "missing")
    CTX=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hookSpecificOutput',{}).get('additionalContext',''))" 2>/dev/null || true)

    if [[ "$AUTO" == "True" ]]; then
        pass "implementer (complete): auto_dispatch=true"
    else
        fail "implementer (complete): auto_dispatch=true (got: $AUTO)"
    fi

    if [[ "$CTX" == AUTO_DISPATCH:* ]]; then
        pass "implementer (complete): suggestion prefixed AUTO_DISPATCH:"
    else
        fail "implementer (complete): suggestion prefixed AUTO_DISPATCH: (got: $CTX)"
    fi
else
    fail "implementer (complete): could not issue lease — skipping auto_dispatch check"
fi

# ==========================================================================
# Test 3: implementer stop (partial contract = interrupted) → auto_dispatch=false
# ==========================================================================
WD3="$TMP_DIR/wt-impl-partial"
mkdir -p "$WD3"
WF3="wf-ad-impl-int-e2e"
LEASE3=$(issue_lease "implementer" "$WF3" "$WD3")
if [[ -n "$LEASE3" ]]; then
    submit_completion "implementer" "$LEASE3" "$WF3" '{"IMPL_STATUS":"partial","IMPL_HEAD_SHA":"deadbeef"}'
    OUT=$(call_process_stop "implementer" "$WD3")
    AUTO=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('auto_dispatch','missing'))" 2>/dev/null || echo "missing")
    CTX=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hookSpecificOutput',{}).get('additionalContext',''))" 2>/dev/null || true)

    if [[ "$AUTO" == "False" ]]; then
        pass "implementer (partial/interrupted): auto_dispatch=false"
    else
        fail "implementer (partial/interrupted): auto_dispatch=false (got: $AUTO)"
    fi

    if [[ "$CTX" == "Canonical flow suggests"* ]]; then
        pass "implementer (partial/interrupted): suggestion starts 'Canonical flow suggests'"
    else
        fail "implementer (partial/interrupted): suggestion starts 'Canonical flow suggests' (got: $CTX)"
    fi
else
    fail "implementer (partial/interrupted): could not issue lease — skipping check"
fi

# ==========================================================================
# Test 4: tester stop (ready_for_guardian) → auto_dispatch=true
# ==========================================================================
WD4="$TMP_DIR/wt-tester-rfg"
mkdir -p "$WD4"
WF4="wf-ad-tester-e2e"
LEASE4=$(issue_lease "tester" "$WF4" "$WD4")
if [[ -n "$LEASE4" ]]; then
    TESTER_PAYLOAD='{"EVAL_VERDICT":"ready_for_guardian","EVAL_TESTS_PASS":"yes","EVAL_NEXT_ROLE":"guardian","EVAL_HEAD_SHA":"abc123"}'
    submit_completion "tester" "$LEASE4" "$WF4" "$TESTER_PAYLOAD"
    OUT=$(call_process_stop "tester" "$WD4")
    AUTO=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('auto_dispatch','missing'))" 2>/dev/null || echo "missing")
    CTX=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hookSpecificOutput',{}).get('additionalContext',''))" 2>/dev/null || true)

    if [[ "$AUTO" == "True" ]]; then
        pass "tester (ready_for_guardian): auto_dispatch=true"
    else
        fail "tester (ready_for_guardian): auto_dispatch=true (got: $AUTO)"
    fi

    if [[ "$CTX" == AUTO_DISPATCH:* ]]; then
        pass "tester (ready_for_guardian): suggestion prefixed AUTO_DISPATCH:"
    else
        fail "tester (ready_for_guardian): suggestion prefixed AUTO_DISPATCH: (got: $CTX)"
    fi

    if [[ "$CTX" == *"guardian"* ]]; then
        pass "tester (ready_for_guardian): suggestion mentions guardian"
    else
        fail "tester (ready_for_guardian): suggestion mentions guardian (got: $CTX)"
    fi
else
    fail "tester (ready_for_guardian): could not issue lease — skipping check"
fi

# ==========================================================================
# Test 5: tester stop (needs_changes) → auto_dispatch=true, next_role=implementer
# ==========================================================================
WD5="$TMP_DIR/wt-tester-nc"
mkdir -p "$WD5"
WF5="wf-ad-tester-nc-e2e"
LEASE5=$(issue_lease "tester" "$WF5" "$WD5")
if [[ -n "$LEASE5" ]]; then
    NC_PAYLOAD='{"EVAL_VERDICT":"needs_changes","EVAL_TESTS_PASS":"no","EVAL_NEXT_ROLE":"implementer","EVAL_HEAD_SHA":"abc123"}'
    submit_completion "tester" "$LEASE5" "$WF5" "$NC_PAYLOAD"
    OUT=$(call_process_stop "tester" "$WD5")
    AUTO=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('auto_dispatch','missing'))" 2>/dev/null || echo "missing")
    CTX=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hookSpecificOutput',{}).get('additionalContext',''))" 2>/dev/null || true)

    if [[ "$AUTO" == "True" ]]; then
        pass "tester (needs_changes): auto_dispatch=true"
    else
        fail "tester (needs_changes): auto_dispatch=true (got: $AUTO)"
    fi

    if [[ "$CTX" == AUTO_DISPATCH:* && "$CTX" == *"implementer"* ]]; then
        pass "tester (needs_changes): suggestion prefixed AUTO_DISPATCH: implementer"
    else
        fail "tester (needs_changes): suggestion prefixed AUTO_DISPATCH: implementer (got: $CTX)"
    fi
else
    fail "tester (needs_changes): could not issue lease — skipping check"
fi

# ==========================================================================
# Test 6: tester stop (blocked_by_plan) → auto_dispatch=true, next_role=planner
# ==========================================================================
WD6="$TMP_DIR/wt-tester-bp"
mkdir -p "$WD6"
WF6="wf-ad-tester-bp-e2e"
LEASE6=$(issue_lease "tester" "$WF6" "$WD6")
if [[ -n "$LEASE6" ]]; then
    BP_PAYLOAD='{"EVAL_VERDICT":"blocked_by_plan","EVAL_TESTS_PASS":"no","EVAL_NEXT_ROLE":"planner","EVAL_HEAD_SHA":"abc123"}'
    submit_completion "tester" "$LEASE6" "$WF6" "$BP_PAYLOAD"
    OUT=$(call_process_stop "tester" "$WD6")
    AUTO=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('auto_dispatch','missing'))" 2>/dev/null || echo "missing")
    CTX=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hookSpecificOutput',{}).get('additionalContext',''))" 2>/dev/null || true)

    if [[ "$AUTO" == "True" ]]; then
        pass "tester (blocked_by_plan): auto_dispatch=true"
    else
        fail "tester (blocked_by_plan): auto_dispatch=true (got: $AUTO)"
    fi

    if [[ "$CTX" == AUTO_DISPATCH:* && "$CTX" == *"planner"* ]]; then
        pass "tester (blocked_by_plan): suggestion prefixed AUTO_DISPATCH: planner"
    else
        fail "tester (blocked_by_plan): suggestion prefixed AUTO_DISPATCH: planner (got: $CTX)"
    fi
else
    fail "tester (blocked_by_plan): could not issue lease — skipping check"
fi

# ==========================================================================
# Test 7: guardian stop (committed) → auto_dispatch=false, suggestion empty
# ==========================================================================
WD7="$TMP_DIR/wt-guardian-com"
mkdir -p "$WD7"
WF7="wf-ad-guard-com-e2e"
LEASE7=$(issue_lease "guardian" "$WF7" "$WD7")
if [[ -n "$LEASE7" ]]; then
    COM_PAYLOAD='{"LANDING_RESULT":"committed","OPERATION_CLASS":"routine_local"}'
    submit_completion "guardian" "$LEASE7" "$WF7" "$COM_PAYLOAD"
    OUT=$(call_process_stop "guardian" "$WD7")
    AUTO=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('auto_dispatch','missing'))" 2>/dev/null || echo "missing")
    CTX=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hookSpecificOutput',{}).get('additionalContext',''))" 2>/dev/null || true)

    if [[ "$AUTO" == "False" ]]; then
        pass "guardian (committed): auto_dispatch=false"
    else
        fail "guardian (committed): auto_dispatch=false (got: $AUTO)"
    fi

    if [[ -z "$CTX" ]]; then
        pass "guardian (committed): suggestion empty (terminal state)"
    else
        fail "guardian (committed): suggestion empty — got: $CTX"
    fi
else
    fail "guardian (committed): could not issue lease — skipping check"
fi

# ==========================================================================
# Test 8: guardian stop (denied) → auto_dispatch=true, next_role=implementer
# ==========================================================================
WD8="$TMP_DIR/wt-guardian-den"
mkdir -p "$WD8"
WF8="wf-ad-guard-den-e2e"
LEASE8=$(issue_lease "guardian" "$WF8" "$WD8")
if [[ -n "$LEASE8" ]]; then
    DEN_PAYLOAD='{"LANDING_RESULT":"denied","OPERATION_CLASS":"routine_local"}'
    submit_completion "guardian" "$LEASE8" "$WF8" "$DEN_PAYLOAD"
    OUT=$(call_process_stop "guardian" "$WD8")
    AUTO=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('auto_dispatch','missing'))" 2>/dev/null || echo "missing")
    CTX=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hookSpecificOutput',{}).get('additionalContext',''))" 2>/dev/null || true)

    if [[ "$AUTO" == "True" ]]; then
        pass "guardian (denied): auto_dispatch=true"
    else
        fail "guardian (denied): auto_dispatch=true (got: $AUTO)"
    fi

    if [[ "$CTX" == AUTO_DISPATCH:* && "$CTX" == *"implementer"* ]]; then
        pass "guardian (denied): suggestion prefixed AUTO_DISPATCH: implementer"
    else
        fail "guardian (denied): suggestion prefixed AUTO_DISPATCH: implementer (got: $CTX)"
    fi
else
    fail "guardian (denied): could not issue lease — skipping check"
fi

# ==========================================================================
# Test 9: error case (tester, no lease) → auto_dispatch=false
# ==========================================================================
WD9="$TMP_DIR/wt-no-lease"
mkdir -p "$WD9"
# No lease issued — the tester must produce a PROCESS ERROR
OUT9=$(call_process_stop "tester" "$WD9")
AUTO9=$(printf '%s' "$OUT9" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('auto_dispatch','missing'))" 2>/dev/null || echo "missing")
ERR9=$(printf '%s' "$OUT9" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null || true)

if [[ "$AUTO9" == "False" ]]; then
    pass "error (tester no lease): auto_dispatch=false"
else
    fail "error (tester no lease): auto_dispatch=false (got: $AUTO9)"
fi

if [[ "$ERR9" == *"PROCESS ERROR"* ]]; then
    pass "error (tester no lease): error field contains PROCESS ERROR"
else
    fail "error (tester no lease): error field contains PROCESS ERROR (got: $ERR9)"
fi

# ==========================================================================
# Summary
# ==========================================================================
echo ""
if [[ "$FAILURES" -eq 0 ]]; then
    echo "PASS: $TEST_NAME — all checks passed"
    exit 0
else
    echo "FAIL: $TEST_NAME — $FAILURES check(s) failed"
    exit 1
fi
