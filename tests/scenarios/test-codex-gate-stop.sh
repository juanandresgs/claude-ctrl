#!/usr/bin/env bash
# test-codex-gate-stop.sh — End-to-end scenario test for W-AD-3 Codex stop-review gate.
#
# Verifies that `cc-policy dispatch process-stop` honours a codex_stop_review
# event written to the events table by the Codex gate hook:
#
#   - No codex_stop_review event: auto_dispatch stays True for a clear transition.
#   - VERDICT: ALLOW event: auto_dispatch stays True.
#   - VERDICT: BLOCK event: auto_dispatch becomes False, suggestion contains
#     "CODEX BLOCK", codex_blocked=True in raw JSON output.
#   - BLOCK event older than 60 s: treated as stale, auto_dispatch stays True.
#   - BLOCK event present but auto_dispatch was already False (error path):
#     codex_blocked remains False (gate only runs when auto_dispatch is True).
#
# Production sequence exercised:
#   cc-policy event emit (codex_stop_review) → cc-policy dispatch process-stop
#   → dispatch_engine._check_codex_gate() reads the event table → result
#
# @decision DEC-AD-002
# @title Scenario test: Codex gate overrides auto_dispatch via events table
# @status accepted
# @rationale W-AD-3 gates auto_dispatch on Codex review verdict. The gate is
#   advisory — errors never block routing. This test exercises the full CLI
#   path (event emit → process-stop) so integration between emitCodexReviewEventSync
#   (hook) and _check_codex_gate (dispatch_engine) is verified end-to-end.

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

OUT1=$(call_process_stop "planner" "$WD1")
AUTO1=$(get_field "$OUT1" "auto_dispatch")
CB1=$(get_field "$OUT1" "codex_blocked")

if [[ "$AUTO1" == "True" ]]; then
    pass "no-event: auto_dispatch=true"
else
    fail "no-event: auto_dispatch=true (got: $AUTO1, full: $OUT1)"
fi

if [[ "$CB1" == "False" || "$CB1" == "missing" || "$CB1" == "None" ]]; then
    pass "no-event: codex_blocked is falsy (got: $CB1)"
else
    fail "no-event: codex_blocked should be falsy (got: $CB1)"
fi

# --------------------------------------------------------------------------
# Test 2: VERDICT: ALLOW event → auto_dispatch stays True
# --------------------------------------------------------------------------
WD2="$TMP_DIR/wt-allow"
mkdir -p "$WD2"
emit_codex_event "$WD2" "VERDICT: ALLOW — workflow=$(workflow_id_for_root "$WD2") | work looks good"

OUT2=$(call_process_stop "planner" "$WD2")
AUTO2=$(get_field "$OUT2" "auto_dispatch")
CB2=$(get_field "$OUT2" "codex_blocked")

if [[ "$AUTO2" == "True" ]]; then
    pass "allow: auto_dispatch=true"
else
    fail "allow: auto_dispatch=true (got: $AUTO2, full: $OUT2)"
fi

if [[ "$CB2" == "False" || "$CB2" == "missing" || "$CB2" == "None" ]]; then
    pass "allow: codex_blocked is falsy"
else
    fail "allow: codex_blocked should be falsy (got: $CB2)"
fi

# --------------------------------------------------------------------------
# Test 3: VERDICT: BLOCK event → auto_dispatch=False, codex_blocked=True,
#         suggestion contains "CODEX BLOCK" and the block reason
# --------------------------------------------------------------------------
WD3="$TMP_DIR/wt-block"
mkdir -p "$WD3"
BLOCK_REASON="Insufficient test coverage for edge cases"
emit_codex_event "$WD3" "VERDICT: BLOCK — workflow=$(workflow_id_for_root "$WD3") | $BLOCK_REASON"

OUT3=$(call_process_stop "planner" "$WD3")
AUTO3=$(get_field "$OUT3" "auto_dispatch")
CB3=$(get_field "$OUT3" "codex_blocked")
REASON3=$(get_field "$OUT3" "codex_reason")
CTX3=$(get_context "$OUT3")

if [[ "$AUTO3" == "False" ]]; then
    pass "block: auto_dispatch=false"
else
    fail "block: auto_dispatch=false (got: $AUTO3, full: $OUT3)"
fi

if [[ "$CB3" == "True" ]]; then
    pass "block: codex_blocked=true"
else
    fail "block: codex_blocked=true (got: $CB3)"
fi

if [[ "$REASON3" == *"$BLOCK_REASON"* || "$REASON3" == *"Insufficient"* ]]; then
    pass "block: codex_reason contains block reason"
else
    fail "block: codex_reason contains block reason (got: $REASON3)"
fi

if [[ "$CTX3" == *"CODEX BLOCK"* ]]; then
    pass "block: suggestion contains CODEX BLOCK"
else
    fail "block: suggestion contains CODEX BLOCK (got: $CTX3)"
fi

# --------------------------------------------------------------------------
# Test 4: Stale BLOCK event (>60s old) → treated as no event, auto_dispatch
#         stays True
# --------------------------------------------------------------------------
# Use a fresh DB to ensure no fresh BLOCK event from Test 3 lingers.
STALE_DB="$TMP_DIR/state-stale.db"
CLAUDE_POLICY_DB="$STALE_DB" $CC schema ensure >/dev/null 2>&1

WD4="$TMP_DIR/wt-stale"
mkdir -p "$WD4"
emit_stale_codex_event "$WD4" "VERDICT: BLOCK — workflow=$(workflow_id_for_root "$WD4") | stale reason should be ignored" "$STALE_DB"

OUT4=$(printf '{"agent_type":"planner","project_root":"%s"}' "$WD4" \
    | CLAUDE_POLICY_DB="$STALE_DB" $CC dispatch process-stop 2>/dev/null || echo '{}')
AUTO4=$(get_field "$OUT4" "auto_dispatch")
CB4=$(get_field "$OUT4" "codex_blocked")

if [[ "$AUTO4" == "True" ]]; then
    pass "stale: auto_dispatch=true (stale event ignored)"
else
    fail "stale: auto_dispatch=true (got: $AUTO4, full: $OUT4)"
fi

if [[ "$CB4" == "False" || "$CB4" == "missing" || "$CB4" == "None" ]]; then
    pass "stale: codex_blocked is falsy (stale event not read)"
else
    fail "stale: codex_blocked should be falsy (got: $CB4)"
fi

# --------------------------------------------------------------------------
# Test 5: BLOCK event present, but auto_dispatch was already False due to
#         error path → codex_blocked stays False (gate only runs when clear)
# --------------------------------------------------------------------------
# Use a fresh DB so the Test 3 BLOCK event doesn't interfere.
ERR_DB="$TMP_DIR/state-err.db"
CLAUDE_POLICY_DB="$ERR_DB" $CC schema ensure >/dev/null 2>&1

WD5="$TMP_DIR/wt-err"
mkdir -p "$WD5"
emit_codex_event "$WD5" "VERDICT: BLOCK — workflow=$(workflow_id_for_root "$WD5") | should not matter" "$ERR_DB"

# Tester with no lease/no workflow → PROCESS ERROR → auto_dispatch=False before gate runs
OUT5=$(printf '{"agent_type":"tester","project_root":"%s"}' "$WD5" \
    | CLAUDE_POLICY_DB="$ERR_DB" $CC dispatch process-stop 2>/dev/null || echo '{}')
AUTO5=$(get_field "$OUT5" "auto_dispatch")
ERR5=$(get_field "$OUT5" "error")
CB5=$(get_field "$OUT5" "codex_blocked")

if [[ "$AUTO5" == "False" ]]; then
    pass "error-path: auto_dispatch=false (routing error)"
else
    fail "error-path: auto_dispatch=false (got: $AUTO5)"
fi

if [[ "$ERR5" == *"PROCESS ERROR"* ]]; then
    pass "error-path: error field contains PROCESS ERROR"
else
    fail "error-path: error field contains PROCESS ERROR (got: $ERR5)"
fi

if [[ "$CB5" == "False" || "$CB5" == "missing" || "$CB5" == "None" ]]; then
    pass "error-path: codex_blocked stays False (gate skipped when already blocked)"
else
    fail "error-path: codex_blocked stays False (got: $CB5)"
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
