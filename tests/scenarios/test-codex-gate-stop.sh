#!/usr/bin/env bash
# test-codex-gate-stop.sh — End-to-end scenario test for stop-review separation.
#
# DEC-PHASE5-STOP-REVIEW-SEPARATION-001: Verifies that `cc-policy dispatch
# process-stop` is NOT influenced by codex_stop_review events. The stop-review
# gate is a user-facing review lane only — its VERDICT: BLOCK does not affect
# workflow auto_dispatch, next_role, or suggestion.
#
# Invariants tested:
#   1. No codex_stop_review event: auto_dispatch stays True for a clear transition.
#   2. VERDICT: ALLOW event: auto_dispatch stays True (no effect).
#   3. VERDICT: BLOCK event: auto_dispatch stays True (separation invariant).
#      codex_blocked/codex_reason are NOT present in the result.
#   4. Stale BLOCK event: auto_dispatch stays True.
#   5. BLOCK event + error path (reviewer, no lease): auto_dispatch stays False
#      due to routing error only (not due to stop-review gate).
#
# Production sequence exercised:
#   cc-policy event emit (codex_stop_review) → cc-policy dispatch process-stop
#   → dispatch_engine ignores codex_stop_review events → result unchanged

set -euo pipefail

TEST_NAME="test-codex-gate-stop"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/state.db"

# shellcheck disable=SC2329
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

seed_clear_implementer_transition() {
    local root="$1"
    local db="${2:-$TEST_DB}"
    local wf_id lease_json lease_id
    wf_id="$(workflow_id_for_root "$root")"
    lease_json=$(CLAUDE_POLICY_DB="$db" $CC \
        lease issue-for-dispatch implementer \
        --workflow-id "$wf_id" \
        --worktree-path "$root" 2>/dev/null || echo '{}')
    lease_id=$(printf '%s' "$lease_json" | jq -r '.lease.lease_id // empty' 2>/dev/null || echo "")
    [[ -n "$lease_id" ]] || return 1
    CLAUDE_POLICY_DB="$db" $CC completion submit \
        --lease-id "$lease_id" \
        --workflow-id "$wf_id" \
        --role implementer \
        --payload '{"IMPL_STATUS":"complete","IMPL_HEAD_SHA":"deadbeef"}' >/dev/null 2>&1
}

# Helper: derive the runtime workflow_id/source key for a project root.
workflow_id_for_root() {
    local root="$1"
    PYTHONPATH="$REPO_ROOT" python3 - "$root" <<'PYEOF'
import sys
from runtime.core.policy_utils import current_workflow_id
print(current_workflow_id(sys.argv[1]))
PYEOF
}

workflow_source_for_root() {
    local root="$1"
    printf 'workflow:%s\n' "$(workflow_id_for_root "$root")"
}

# Helper: emit a codex_stop_review event with the given detail string for a root.
emit_codex_event() {
    local root="$1"
    local detail="$2"
    local db="${3:-$TEST_DB}"
    local source
    source="$(workflow_source_for_root "$root")"
    CLAUDE_POLICY_DB="$db" $CC event emit "codex_stop_review" --source "$source" --detail "$detail" >/dev/null 2>&1 || true
}

# Helper: emit a codex_stop_review event with a stale created_at timestamp by
# inserting directly into SQLite (60 + 10 seconds in the past).
emit_stale_codex_event() {
    local root="$1"
    local detail="$2"
    local db="${3:-$TEST_DB}"
    local stale_ts
    local source
    stale_ts=$(python3 -c "import time; print(int(time.time()) - 130)")
    source="$(workflow_source_for_root "$root")"
    python3 - "$db" "$source" "$detail" "$stale_ts" <<'PYEOF'
import sys, sqlite3
db, source, detail, ts = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
conn = sqlite3.connect(db)
conn.execute(
    "INSERT INTO events (type, source, detail, created_at) VALUES (?, ?, ?, ?)",
    ("codex_stop_review", source, detail, ts)
)
conn.commit()
conn.close()
PYEOF
}

# Helper: extract a scalar field from process-stop JSON output.
get_field() {
    local json="$1"
    local field="$2"
    printf '%s' "$json" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$field','missing'))" 2>/dev/null \
        || echo "missing"
}

get_context() {
    local json="$1"
    printf '%s' "$json" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hookSpecificOutput',{}).get('additionalContext',''))" 2>/dev/null \
        || true
}

# ==========================================================================
# Each test uses a fresh worktree subdirectory to avoid lease collisions.
# ==========================================================================

# --------------------------------------------------------------------------
# Test 1: No codex_stop_review event → auto_dispatch stays True
# --------------------------------------------------------------------------
WD1="$TMP_DIR/wt-no-event"
mkdir -p "$WD1"

seed_clear_implementer_transition "$WD1"
OUT1=$(call_process_stop "implementer" "$WD1")
AUTO1=$(get_field "$OUT1" "auto_dispatch")
CB1=$(get_field "$OUT1" "codex_blocked")

if [[ "$AUTO1" == "True" ]]; then
    pass "no-event: auto_dispatch=true"
else
    fail "no-event: auto_dispatch=true (got: $AUTO1, full: $OUT1)"
fi

# codex_blocked must not be present in result (separation invariant)
if [[ "$CB1" == "missing" ]]; then
    pass "no-event: codex_blocked absent from result"
else
    fail "no-event: codex_blocked should be absent (got: $CB1)"
fi

# --------------------------------------------------------------------------
# Test 2: VERDICT: ALLOW event → auto_dispatch stays True (no effect)
# --------------------------------------------------------------------------
WD2="$TMP_DIR/wt-allow"
mkdir -p "$WD2"
emit_codex_event "$WD2" "VERDICT: ALLOW — workflow=$(workflow_id_for_root "$WD2") | work looks good"

seed_clear_implementer_transition "$WD2"
OUT2=$(call_process_stop "implementer" "$WD2")
AUTO2=$(get_field "$OUT2" "auto_dispatch")
CB2=$(get_field "$OUT2" "codex_blocked")

if [[ "$AUTO2" == "True" ]]; then
    pass "allow: auto_dispatch=true"
else
    fail "allow: auto_dispatch=true (got: $AUTO2, full: $OUT2)"
fi

if [[ "$CB2" == "missing" ]]; then
    pass "allow: codex_blocked absent from result"
else
    fail "allow: codex_blocked should be absent (got: $CB2)"
fi

# --------------------------------------------------------------------------
# Test 3: VERDICT: BLOCK event → auto_dispatch stays True (separation).
#         codex_blocked/codex_reason are NOT present in result.
#         Suggestion does NOT contain CODEX BLOCK.
# --------------------------------------------------------------------------
WD3="$TMP_DIR/wt-block"
mkdir -p "$WD3"
BLOCK_REASON="Insufficient test coverage for edge cases"
emit_codex_event "$WD3" "VERDICT: BLOCK — workflow=$(workflow_id_for_root "$WD3") | $BLOCK_REASON"

seed_clear_implementer_transition "$WD3"
OUT3=$(call_process_stop "implementer" "$WD3")
AUTO3=$(get_field "$OUT3" "auto_dispatch")
CB3=$(get_field "$OUT3" "codex_blocked")
CTX3=$(get_context "$OUT3")

# Primary separation invariant: BLOCK does NOT set auto_dispatch=False
if [[ "$AUTO3" == "True" ]]; then
    pass "block: auto_dispatch stays True (separation)"
else
    fail "block: auto_dispatch must stay True (got: $AUTO3, full: $OUT3)"
fi

# codex_blocked must not be in result
if [[ "$CB3" == "missing" ]]; then
    pass "block: codex_blocked absent from result"
else
    fail "block: codex_blocked should be absent (got: $CB3)"
fi

# Suggestion must NOT contain CODEX BLOCK
if [[ "$CTX3" != *"CODEX BLOCK"* ]]; then
    pass "block: suggestion does not contain CODEX BLOCK"
else
    fail "block: suggestion should not contain CODEX BLOCK (got: $CTX3)"
fi

# --------------------------------------------------------------------------
# Test 4: Stale BLOCK event (>60s old) → auto_dispatch stays True
# --------------------------------------------------------------------------
# Use a fresh DB to ensure no fresh BLOCK event from Test 3 lingers.
STALE_DB="$TMP_DIR/state-stale.db"
CLAUDE_POLICY_DB="$STALE_DB" $CC schema ensure >/dev/null 2>&1

WD4="$TMP_DIR/wt-stale"
mkdir -p "$WD4"
emit_stale_codex_event "$WD4" "VERDICT: BLOCK — workflow=$(workflow_id_for_root "$WD4") | stale reason should be ignored" "$STALE_DB"

seed_clear_implementer_transition "$WD4" "$STALE_DB"
OUT4=$(printf '{"agent_type":"implementer","project_root":"%s"}' "$WD4" \
    | CLAUDE_POLICY_DB="$STALE_DB" $CC dispatch process-stop 2>/dev/null || echo '{}')
AUTO4=$(get_field "$OUT4" "auto_dispatch")
CB4=$(get_field "$OUT4" "codex_blocked")

if [[ "$AUTO4" == "True" ]]; then
    pass "stale: auto_dispatch=true"
else
    fail "stale: auto_dispatch=true (got: $AUTO4, full: $OUT4)"
fi

if [[ "$CB4" == "missing" ]]; then
    pass "stale: codex_blocked absent from result"
else
    fail "stale: codex_blocked should be absent (got: $CB4)"
fi

# --------------------------------------------------------------------------
# Test 5: BLOCK event present, reviewer with no lease → PROCESS ERROR →
#         auto_dispatch=False due to routing error (not stop-review gate).
# --------------------------------------------------------------------------
ERR_DB="$TMP_DIR/state-err.db"
CLAUDE_POLICY_DB="$ERR_DB" $CC schema ensure >/dev/null 2>&1

WD5="$TMP_DIR/wt-err"
mkdir -p "$WD5"
emit_codex_event "$WD5" "VERDICT: BLOCK — workflow=$(workflow_id_for_root "$WD5") | should not matter" "$ERR_DB"

# Reviewer with no lease → PROCESS ERROR → auto_dispatch=False from routing, not gate
OUT5=$(printf '{"agent_type":"reviewer","project_root":"%s"}' "$WD5" \
    | CLAUDE_POLICY_DB="$ERR_DB" $CC dispatch process-stop 2>/dev/null || echo '{}')
AUTO5=$(get_field "$OUT5" "auto_dispatch")
ERR5=$(get_field "$OUT5" "error")
CB5=$(get_field "$OUT5" "codex_blocked")

if [[ "$AUTO5" == "False" ]]; then
    pass "error-path: auto_dispatch=false (routing error, not gate)"
else
    fail "error-path: auto_dispatch=false (got: $AUTO5)"
fi

if [[ "$ERR5" == *"PROCESS ERROR"* ]]; then
    pass "error-path: error field contains PROCESS ERROR"
else
    fail "error-path: error field contains PROCESS ERROR (got: $ERR5)"
fi

if [[ "$CB5" == "missing" ]]; then
    pass "error-path: codex_blocked absent from result"
else
    fail "error-path: codex_blocked should be absent (got: $CB5)"
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
