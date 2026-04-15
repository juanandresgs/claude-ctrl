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
#   implementer, reviewer completion variants, guardian terminal and retry,
#   and the Phase 8 Slice 11 unknown-role silent-exit semantics for the
#   retired ``tester`` role.

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

# Helper: build a reviewer completion payload with valid REVIEW_FINDINGS_JSON.
# Uses jq to avoid quote-escape hell when embedding JSON-in-JSON.
# Usage: make_reviewer_payload <verdict> <severity> <title>
make_reviewer_payload() {
    local verdict="$1"
    local severity="$2"
    local title="$3"
    jq -nc \
        --arg v "$verdict" \
        --arg s "$severity" \
        --arg t "$title" \
        '{
            REVIEW_VERDICT: $v,
            REVIEW_HEAD_SHA: "abc123",
            REVIEW_FINDINGS_JSON: ({findings: [{severity: $s, title: $t, detail: "ok"}]} | tojson)
        }'
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
# Test 4: reviewer stop (ready_for_guardian) → auto_dispatch=true
# ==========================================================================
WD4="$TMP_DIR/wt-reviewer-rfg"
mkdir -p "$WD4"
WF4="wf-ad-reviewer-e2e"
LEASE4=$(issue_lease "reviewer" "$WF4" "$WD4")
if [[ -n "$LEASE4" ]]; then
    REVIEWER_PAYLOAD=$(make_reviewer_payload "ready_for_guardian" "note" "ok")
    submit_completion "reviewer" "$LEASE4" "$WF4" "$REVIEWER_PAYLOAD"
    OUT=$(call_process_stop "reviewer" "$WD4")
    AUTO=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('auto_dispatch','missing'))" 2>/dev/null || echo "missing")
    CTX=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hookSpecificOutput',{}).get('additionalContext',''))" 2>/dev/null || true)

    if [[ "$AUTO" == "True" ]]; then
        pass "reviewer (ready_for_guardian): auto_dispatch=true"
    else
        fail "reviewer (ready_for_guardian): auto_dispatch=true (got: $AUTO)"
    fi

    if [[ "$CTX" == AUTO_DISPATCH:* ]]; then
        pass "reviewer (ready_for_guardian): suggestion prefixed AUTO_DISPATCH:"
    else
        fail "reviewer (ready_for_guardian): suggestion prefixed AUTO_DISPATCH: (got: $CTX)"
    fi

    if [[ "$CTX" == *"guardian"* ]]; then
        pass "reviewer (ready_for_guardian): suggestion mentions guardian"
    else
        fail "reviewer (ready_for_guardian): suggestion mentions guardian (got: $CTX)"
    fi
else
    fail "reviewer (ready_for_guardian): could not issue lease — skipping check"
fi

# ==========================================================================
# Test 5: reviewer stop (needs_changes) → auto_dispatch=true, next_role=implementer
# ==========================================================================
WD5="$TMP_DIR/wt-reviewer-nc"
mkdir -p "$WD5"
WF5="wf-ad-reviewer-nc-e2e"
LEASE5=$(issue_lease "reviewer" "$WF5" "$WD5")
if [[ -n "$LEASE5" ]]; then
    NC_PAYLOAD=$(make_reviewer_payload "needs_changes" "blocking" "bug")
    submit_completion "reviewer" "$LEASE5" "$WF5" "$NC_PAYLOAD"
    OUT=$(call_process_stop "reviewer" "$WD5")
    AUTO=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('auto_dispatch','missing'))" 2>/dev/null || echo "missing")
    CTX=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hookSpecificOutput',{}).get('additionalContext',''))" 2>/dev/null || true)

    if [[ "$AUTO" == "True" ]]; then
        pass "reviewer (needs_changes): auto_dispatch=true"
    else
        fail "reviewer (needs_changes): auto_dispatch=true (got: $AUTO)"
    fi

    if [[ "$CTX" == AUTO_DISPATCH:* && "$CTX" == *"implementer"* ]]; then
        pass "reviewer (needs_changes): suggestion prefixed AUTO_DISPATCH: implementer"
    else
        fail "reviewer (needs_changes): suggestion prefixed AUTO_DISPATCH: implementer (got: $CTX)"
    fi
else
    fail "reviewer (needs_changes): could not issue lease — skipping check"
fi

# ==========================================================================
# Test 6: reviewer stop (blocked_by_plan) → auto_dispatch=true, next_role=planner
# ==========================================================================
WD6="$TMP_DIR/wt-reviewer-bp"
mkdir -p "$WD6"
WF6="wf-ad-reviewer-bp-e2e"
LEASE6=$(issue_lease "reviewer" "$WF6" "$WD6")
if [[ -n "$LEASE6" ]]; then
    BP_PAYLOAD=$(make_reviewer_payload "blocked_by_plan" "blocking" "plan-gap")
    submit_completion "reviewer" "$LEASE6" "$WF6" "$BP_PAYLOAD"
    OUT=$(call_process_stop "reviewer" "$WD6")
    AUTO=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('auto_dispatch','missing'))" 2>/dev/null || echo "missing")
    CTX=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hookSpecificOutput',{}).get('additionalContext',''))" 2>/dev/null || true)

    if [[ "$AUTO" == "True" ]]; then
        pass "reviewer (blocked_by_plan): auto_dispatch=true"
    else
        fail "reviewer (blocked_by_plan): auto_dispatch=true (got: $AUTO)"
    fi

    if [[ "$CTX" == AUTO_DISPATCH:* && "$CTX" == *"planner"* ]]; then
        pass "reviewer (blocked_by_plan): suggestion prefixed AUTO_DISPATCH: planner"
    else
        fail "reviewer (blocked_by_plan): suggestion prefixed AUTO_DISPATCH: planner (got: $CTX)"
    fi
else
    fail "reviewer (blocked_by_plan): could not issue lease — skipping check"
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
# Test 9: unknown role (retired ``tester``) → silent exit
#
# Phase 8 Slice 11 retired the ``tester`` role from the runtime. It is no
# longer in ``_known_types`` in ``dispatch_engine.process_agent_stop``.
# Any residual stop event carrying ``agent_type="tester"`` must therefore
# exit silently: auto_dispatch=False, no suggestion, no PROCESS ERROR,
# no next_role. This is the unknown-role silent-exit invariant from
# DEC-PHASE8-SLICE11-001.
# ==========================================================================
WD9="$TMP_DIR/wt-unknown-tester"
mkdir -p "$WD9"
OUT9=$(call_process_stop "tester" "$WD9")
AUTO9=$(printf '%s' "$OUT9" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('auto_dispatch','missing'))" 2>/dev/null || echo "missing")
ERR9=$(printf '%s' "$OUT9" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error','') or '')" 2>/dev/null || true)
NEXT9=$(printf '%s' "$OUT9" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('next_role','') or '')" 2>/dev/null || true)
CTX9=$(printf '%s' "$OUT9" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hookSpecificOutput',{}).get('additionalContext',''))" 2>/dev/null || true)

if [[ "$AUTO9" == "False" ]]; then
    pass "unknown role (retired tester): auto_dispatch=false"
else
    fail "unknown role (retired tester): auto_dispatch=false (got: $AUTO9)"
fi

if [[ -z "$ERR9" ]]; then
    pass "unknown role (retired tester): no PROCESS ERROR emitted (silent exit)"
else
    fail "unknown role (retired tester): expected empty error, got: $ERR9"
fi

if [[ -z "$NEXT9" ]]; then
    pass "unknown role (retired tester): next_role empty (no routing)"
else
    fail "unknown role (retired tester): next_role empty (got: $NEXT9)"
fi

if [[ -z "$CTX9" ]]; then
    pass "unknown role (retired tester): no additionalContext suggestion"
else
    fail "unknown role (retired tester): expected empty additionalContext, got: $CTX9"
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
