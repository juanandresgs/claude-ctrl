#!/usr/bin/env bash
# test-gwt-1-routing.sh — End-to-end scenario test for W-GWT-1.
#
# Verifies that `cc-policy dispatch process-stop` implements the new
# planner→guardian→implementer routing chain introduced by W-GWT-1:
#
#   planner stop  → next_role=guardian, guardian_mode=provision, AUTO_DISPATCH: guardian
#   guardian stop (provisioned, WORKTREE_PATH) → next_role=implementer, AUTO_DISPATCH: implementer
#                                                 worktree_path encoded in suggestion
#   reviewer stop (needs_changes) with workflow binding → worktree_path in suggestion
#   reviewer stop (needs_changes) without binding → routes correctly, worktree_path omitted
#
# All cases exercise the real production path:
#   synthetic JSON stdin → cc-policy dispatch process-stop → SQLite state
#
# @decision DEC-GUARD-WT-001
# @title Scenario test: planner→guardian→implementer routing (W-GWT-1)
# @status accepted
# @rationale W-GWT-1 changes the planner→implementer direct route to
#   planner→guardian(provision)→implementer. This test exercises each
#   transition: planner routing, guardian provisioned routing, worktree_path
#   carrier through suggestion text, and the rework path (reviewer
#   needs_changes with workflow_bindings populated by simulated guardian
#   provisioning). Phase 8 Slice 11 retired the legacy ``tester`` role;
#   the evaluator slot in the rework path is owned by ``reviewer``.

set -euo pipefail

TEST_NAME="test-gwt-1-routing"
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

# Helper: seed the current planner contract path. Planner routing requires an
# active planner lease, a valid completion record, and an active goal contract.
seed_planner_next_work_item() {
    local wf_id="$1"
    local wt_path="$2"
    PYTHONPATH="$REPO_ROOT" python3 - "$TEST_DB" "$wt_path" "$wf_id" <<'PYEOF'
import sqlite3, sys
from runtime.core import completions, decision_work_registry as dwr, leases
from runtime.schemas import ensure_schema

db_path, worktree_path, workflow_id = sys.argv[1], sys.argv[2], sys.argv[3]
conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
ensure_schema(conn)
dwr.insert_goal(
    conn,
    dwr.GoalRecord(
        goal_id=workflow_id,
        desired_end_state="GWT routing scenario goal",
        status="active",
        autonomy_budget=5,
    ),
)
lease = leases.issue(
    conn,
    role="planner",
    workflow_id=workflow_id,
    worktree_path=worktree_path,
)
completions.submit(
    conn,
    lease_id=lease["lease_id"],
    workflow_id=workflow_id,
    role="planner",
    payload={"PLAN_VERDICT": "next_work_item", "PLAN_SUMMARY": "scenario"},
)
conn.close()
PYEOF
}

# Helper: build a reviewer completion payload with valid REVIEW_FINDINGS_JSON.
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

# Helper: bind a workflow to a worktree path (simulates guardian provisioning).
# Positional args: workflow_id worktree_path branch
bind_workflow() {
    local wf_id="$1"
    local wt_path="$2"
    local branch="$3"
    CLAUDE_POLICY_DB="$TEST_DB" $CC workflow bind "$wf_id" "$wt_path" "$branch" >/dev/null 2>&1 || true
}

# ==========================================================================
# Test 1: planner stop → next_role=guardian, guardian_mode=provision
# ==========================================================================
WD1="$TMP_DIR/wt-planner"
mkdir -p "$WD1"
seed_planner_next_work_item "wf-gwt-planner-e2e-001" "$WD1"
OUT=$(call_process_stop "planner" "$WD1")
NEXT=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('next_role',''))" 2>/dev/null || echo "")
CTX=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hookSpecificOutput',{}).get('additionalContext',''))" 2>/dev/null || true)
GMODE=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('guardian_mode',''))" 2>/dev/null || echo "")
AUTO=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('auto_dispatch',''))" 2>/dev/null || echo "")

if [[ "$NEXT" == "guardian" ]]; then
    pass "planner: next_role=guardian"
else
    fail "planner: next_role=guardian (got: $NEXT, full output: $OUT)"
fi

if [[ "$AUTO" == "True" ]]; then
    pass "planner: auto_dispatch=True"
else
    fail "planner: auto_dispatch=True (got: $AUTO)"
fi

if [[ "$GMODE" == "provision" ]]; then
    pass "planner: guardian_mode=provision"
else
    fail "planner: guardian_mode=provision (got: $GMODE)"
fi

if [[ "$CTX" == AUTO_DISPATCH:*guardian* ]]; then
    pass "planner: suggestion prefixed AUTO_DISPATCH: guardian"
else
    fail "planner: suggestion prefixed AUTO_DISPATCH: guardian (got: $CTX)"
fi

if [[ "$CTX" == *"mode=provision"* ]]; then
    pass "planner: suggestion encodes mode=provision"
else
    fail "planner: suggestion encodes mode=provision (got: $CTX)"
fi

# ==========================================================================
# Test 2: guardian stop (provisioned + WORKTREE_PATH) → next_role=implementer,
#         worktree_path encoded in suggestion
# ==========================================================================
WD2="$TMP_DIR/wt-guardian-prov"
mkdir -p "$WD2"
WF2="wf-gwt-prov-e2e-001"
WORKTREE2="$TMP_DIR/.worktrees/feature-gwt-e2e"
LEASE2=$(issue_lease "guardian" "$WF2" "$WD2")
if [[ -n "$LEASE2" ]]; then
    PROV_PAYLOAD="{\"LANDING_RESULT\":\"provisioned\",\"OPERATION_CLASS\":\"routine_local\",\"WORKTREE_PATH\":\"$WORKTREE2\"}"
    submit_completion "guardian" "$LEASE2" "$WF2" "$PROV_PAYLOAD"
    OUT=$(call_process_stop "guardian" "$WD2")
    NEXT=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('next_role',''))" 2>/dev/null || echo "")
    CTX=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hookSpecificOutput',{}).get('additionalContext',''))" 2>/dev/null || true)
    WTP=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('worktree_path',''))" 2>/dev/null || echo "")
    AUTO=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('auto_dispatch',''))" 2>/dev/null || echo "")

    if [[ "$NEXT" == "implementer" ]]; then
        pass "guardian (provisioned): next_role=implementer"
    else
        fail "guardian (provisioned): next_role=implementer (got: $NEXT, full output: $OUT)"
    fi

    if [[ "$AUTO" == "True" ]]; then
        pass "guardian (provisioned): auto_dispatch=True"
    else
        fail "guardian (provisioned): auto_dispatch=True (got: $AUTO)"
    fi

    if [[ "$CTX" == AUTO_DISPATCH:*implementer* ]]; then
        pass "guardian (provisioned): suggestion prefixed AUTO_DISPATCH: implementer"
    else
        fail "guardian (provisioned): suggestion prefixed AUTO_DISPATCH: implementer (got: $CTX)"
    fi

    if [[ "$CTX" == *"worktree_path=$WORKTREE2"* ]]; then
        pass "guardian (provisioned): suggestion encodes worktree_path"
    else
        fail "guardian (provisioned): suggestion encodes worktree_path (got: $CTX)"
    fi

    if [[ "$WTP" == "$WORKTREE2" ]]; then
        pass "guardian (provisioned): worktree_path in result dict"
    else
        fail "guardian (provisioned): worktree_path in result dict (got: $WTP)"
    fi
else
    fail "guardian (provisioned): could not issue lease — skipping checks"
fi

# ==========================================================================
# Test 3: reviewer stop (needs_changes) with workflow binding → worktree_path
#         encoded in suggestion (rework path, DEC-GUARD-WT-004)
# ==========================================================================
WD3="$TMP_DIR/wt-reviewer-nc"
mkdir -p "$WD3"
WF3="wf-gwt-nc-e2e-001"
WORKTREE3="$TMP_DIR/.worktrees/feature-gwt-rework"
# Register workflow binding (simulates prior guardian provisioning)
bind_workflow "$WF3" "$WORKTREE3" "feature/gwt-rework"
LEASE3=$(issue_lease "reviewer" "$WF3" "$WD3")
if [[ -n "$LEASE3" ]]; then
    NC_PAYLOAD=$(make_reviewer_payload "needs_changes" "blocking" "needs rework")
    submit_completion "reviewer" "$LEASE3" "$WF3" "$NC_PAYLOAD"
    OUT=$(call_process_stop "reviewer" "$WD3")
    NEXT=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('next_role',''))" 2>/dev/null || echo "")
    CTX=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hookSpecificOutput',{}).get('additionalContext',''))" 2>/dev/null || true)
    WTP=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('worktree_path',''))" 2>/dev/null || echo "")

    if [[ "$NEXT" == "implementer" ]]; then
        pass "reviewer (needs_changes+binding): next_role=implementer"
    else
        fail "reviewer (needs_changes+binding): next_role=implementer (got: $NEXT)"
    fi

    if [[ "$CTX" == *"worktree_path=$WORKTREE3"* ]]; then
        pass "reviewer (needs_changes+binding): suggestion encodes worktree_path"
    else
        fail "reviewer (needs_changes+binding): suggestion encodes worktree_path (got: $CTX)"
    fi

    if [[ "$WTP" == "$WORKTREE3" ]]; then
        pass "reviewer (needs_changes+binding): worktree_path in result dict"
    else
        fail "reviewer (needs_changes+binding): worktree_path in result dict (got: $WTP)"
    fi
else
    fail "reviewer (needs_changes+binding): could not issue lease — skipping checks"
fi

# ==========================================================================
# Test 4: reviewer stop (needs_changes) WITHOUT binding → routes correctly,
#         worktree_path is empty (graceful degradation)
# ==========================================================================
WD4="$TMP_DIR/wt-reviewer-nc-nobind"
mkdir -p "$WD4"
WF4="wf-gwt-nc-nobind-e2e-001"
# No bind_workflow call — simulates missing binding
LEASE4=$(issue_lease "reviewer" "$WF4" "$WD4")
if [[ -n "$LEASE4" ]]; then
    NC_PAYLOAD=$(make_reviewer_payload "needs_changes" "blocking" "needs rework")
    submit_completion "reviewer" "$LEASE4" "$WF4" "$NC_PAYLOAD"
    OUT=$(call_process_stop "reviewer" "$WD4")
    NEXT=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('next_role',''))" 2>/dev/null || echo "")
    ERR=$(printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error') or '')" 2>/dev/null || true)

    if [[ "$NEXT" == "implementer" ]]; then
        pass "reviewer (needs_changes, no binding): next_role=implementer"
    else
        fail "reviewer (needs_changes, no binding): next_role=implementer (got: $NEXT)"
    fi

    if [[ -z "$ERR" || "$ERR" == "None" ]]; then
        pass "reviewer (needs_changes, no binding): no error"
    else
        fail "reviewer (needs_changes, no binding): no error (got: $ERR)"
    fi
else
    fail "reviewer (needs_changes, no binding): could not issue lease — skipping checks"
fi

# ==========================================================================
# Test 5: Full chain — planner→guardian(provisioned)→implementer
#         Verifies auto_dispatch and worktree_path flow end-to-end
# ==========================================================================
WD5_PLANNER="$TMP_DIR/wt-chain-planner"
WD5_GUARDIAN="$TMP_DIR/wt-chain-guardian"
mkdir -p "$WD5_PLANNER" "$WD5_GUARDIAN"
WF5="wf-gwt-chain-e2e-001"
WORKTREE5="$TMP_DIR/.worktrees/feature-gwt-chain"

# Step 1: planner stop
seed_planner_next_work_item "$WF5" "$WD5_PLANNER"
OUT5P=$(call_process_stop "planner" "$WD5_PLANNER")
NEXT5P=$(printf '%s' "$OUT5P" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('next_role',''))" 2>/dev/null || echo "")
AUTO5P=$(printf '%s' "$OUT5P" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('auto_dispatch',''))" 2>/dev/null || echo "")

if [[ "$NEXT5P" == "guardian" && "$AUTO5P" == "True" ]]; then
    pass "chain step 1: planner→guardian auto_dispatch=True"
else
    fail "chain step 1: planner→guardian auto_dispatch=True (next=$NEXT5P, auto=$AUTO5P)"
fi

# Step 2: guardian stop (provisioned)
LEASE5=$(issue_lease "guardian" "$WF5" "$WD5_GUARDIAN")
if [[ -n "$LEASE5" ]]; then
    PROV5_PAYLOAD="{\"LANDING_RESULT\":\"provisioned\",\"OPERATION_CLASS\":\"routine_local\",\"WORKTREE_PATH\":\"$WORKTREE5\"}"
    submit_completion "guardian" "$LEASE5" "$WF5" "$PROV5_PAYLOAD"
    OUT5G=$(call_process_stop "guardian" "$WD5_GUARDIAN")
    NEXT5G=$(printf '%s' "$OUT5G" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('next_role',''))" 2>/dev/null || echo "")
    AUTO5G=$(printf '%s' "$OUT5G" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('auto_dispatch',''))" 2>/dev/null || echo "")
    CTX5G=$(printf '%s' "$OUT5G" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hookSpecificOutput',{}).get('additionalContext',''))" 2>/dev/null || true)

    if [[ "$NEXT5G" == "implementer" && "$AUTO5G" == "True" ]]; then
        pass "chain step 2: guardian→implementer auto_dispatch=True"
    else
        fail "chain step 2: guardian→implementer auto_dispatch=True (next=$NEXT5G, auto=$AUTO5G)"
    fi

    if [[ "$CTX5G" == *"worktree_path=$WORKTREE5"* ]]; then
        pass "chain step 2: worktree_path encoded in AUTO_DISPATCH suggestion"
    else
        fail "chain step 2: worktree_path encoded in AUTO_DISPATCH suggestion (got: $CTX5G)"
    fi
else
    fail "chain step 2: could not issue guardian lease — skipping"
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
