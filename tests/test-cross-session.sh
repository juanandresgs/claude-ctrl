#!/usr/bin/env bash
# test-cross-session.sh — Tests for Phase 4 cross-session learning.
#
# @decision DEC-V2-PHASE4-003
# @title Test suite for cross-session learning (get_prior_sessions, session index)
# @status accepted
# @rationale Tests verify the full contract of the cross-session feature:
#   get_prior_sessions() return values under various session counts, friction
#   detection logic, index trimming at 20 entries, and the session-end.sh
#   index write behavior. Uses temp directories with synthetic index.jsonl
#   files to avoid dependency on live session state.
#
#   IMPLEMENTATION NOTE: Tests call get_prior_sessions via a wrapper script
#   written to a temp file rather than sourcing context-lib inside $(...).
#   Sourcing inside command substitution causes bash to dump all exported
#   function bodies to stdout (via export -f), polluting the captured result.
#   Writing output to a temp file and reading it back avoids this.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="${SCRIPT_DIR}/../hooks"
CONTEXT_LIB="${HOOKS_DIR}/context-lib.sh"

# Colors
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    GREEN='' RED='' YELLOW='' NC=''
fi

passed=0
failed=0

pass() { echo -e "${GREEN}PASS${NC} $1"; passed=$((passed + 1)); }
fail() { echo -e "${RED}FAIL${NC} $1: $2"; failed=$((failed + 1)); }

# Source context-lib for safe_cleanup in the MAIN shell only
source "$CONTEXT_LIB"

# Helper: create a synthetic session index entry JSON line
make_index_entry() {
    local id="$1" outcome="${2:-tests-passing}" friction="${3:-}"
    local friction_json="[]"
    if [[ -n "$friction" ]]; then
        friction_json=$(jq -Rsc '[.]' <<< "$friction" 2>/dev/null || echo '[]')
    fi
    # -c for compact output: JSONL requires one object per line
    jq -cn \
        --arg id "$id" \
        --arg project "test-project" \
        --arg started "2026-02-17T10:00:00Z" \
        --argjson duration_min 30 \
        --argjson files_touched '["hooks/foo.sh","hooks/bar.sh"]' \
        --argjson tool_calls 42 \
        --argjson checkpoints 2 \
        --argjson pivots 1 \
        --argjson friction "$friction_json" \
        --arg outcome "$outcome" \
        '{id:$id,project:$project,started:$started,duration_min:$duration_min,files_touched:$files_touched,tool_calls:$tool_calls,checkpoints:$checkpoints,pivots:$pivots,friction:$friction,outcome:$outcome}' \
        2>/dev/null
}

# Helper: compute project hash (same algorithm as get_prior_sessions)
project_hash() {
    echo "$1" | shasum -a 256 2>/dev/null | cut -c1-12
}

# Helper: set up isolated sessions dir
# Usage: setup_sessions_dir <home_dir> <project_dir>  -> prints sessions path
setup_sessions_dir() {
    local home_dir="$1" project_dir="$2"
    local hash
    hash=$(project_hash "$project_dir")
    local sessions_dir="$home_dir/.claude/sessions/$hash"
    mkdir -p "$sessions_dir"
    echo "$sessions_dir"
}

# Helper: call get_prior_sessions in a fresh bash subprocess (avoids exported
# function body pollution from sourcing context-lib inside $(...)).
# Writes output to a temp file; caller reads it.
# Usage: call_get_prior_sessions <home_dir> <project_dir> <output_file>
call_get_prior_sessions() {
    local home_dir="$1" project_dir="$2" out_file="$3"
    bash --norc --noprofile -s <<SCRIPT > "$out_file" 2>/dev/null
source "$CONTEXT_LIB"
HOME="$home_dir"
get_prior_sessions "$project_dir"
SCRIPT
}

echo "=== Cross-Session Learning Tests ==="
echo ""

# =============================================================================
# TEST 1: get_prior_sessions returns empty when no index.jsonl exists
# =============================================================================
echo "--- Test 1: empty when no index file ---"

T1_HOME=$(mktemp -d)
T1_PROJ=$(mktemp -d)
T1_OUT=$(mktemp)

call_get_prior_sessions "$T1_HOME" "$T1_PROJ" "$T1_OUT"
result=$(cat "$T1_OUT")

if [[ -z "$result" ]]; then
    pass "get_prior_sessions() — empty when no index.jsonl"
else
    fail "get_prior_sessions() — no index" "expected empty, got: $result"
fi

rm -f "$T1_OUT"
safe_cleanup "$T1_HOME" "$SCRIPT_DIR"
safe_cleanup "$T1_PROJ" "$SCRIPT_DIR"
echo ""

# =============================================================================
# TEST 2: get_prior_sessions returns empty when fewer than 3 sessions
# =============================================================================
echo "--- Test 2: empty when fewer than 3 sessions ---"

T2_HOME=$(mktemp -d)
T2_PROJ=$(mktemp -d)
T2_SESSIONS=$(setup_sessions_dir "$T2_HOME" "$T2_PROJ")
T2_OUT=$(mktemp)

# Write only 2 entries (below threshold of 3)
make_index_entry "sess-001" "tests-passing" >> "$T2_SESSIONS/index.jsonl"
make_index_entry "sess-002" "committed"     >> "$T2_SESSIONS/index.jsonl"

call_get_prior_sessions "$T2_HOME" "$T2_PROJ" "$T2_OUT"
result=$(cat "$T2_OUT")

if [[ -z "$result" ]]; then
    pass "get_prior_sessions() — empty when only 2 sessions"
else
    fail "get_prior_sessions() — 2 sessions" "expected empty, got: $result"
fi

rm -f "$T2_OUT"
safe_cleanup "$T2_HOME" "$SCRIPT_DIR"
safe_cleanup "$T2_PROJ" "$SCRIPT_DIR"
echo ""

# =============================================================================
# TEST 3: get_prior_sessions returns structured text with 3+ sessions
# =============================================================================
echo "--- Test 3: structured text with 3+ sessions ---"

T3_HOME=$(mktemp -d)
T3_PROJ=$(mktemp -d)
T3_SESSIONS=$(setup_sessions_dir "$T3_HOME" "$T3_PROJ")
T3_OUT=$(mktemp)

make_index_entry "sess-001" "tests-failing" >> "$T3_SESSIONS/index.jsonl"
make_index_entry "sess-002" "tests-passing" >> "$T3_SESSIONS/index.jsonl"
make_index_entry "sess-003" "committed"     >> "$T3_SESSIONS/index.jsonl"
make_index_entry "sess-004" "tests-passing" >> "$T3_SESSIONS/index.jsonl"

call_get_prior_sessions "$T3_HOME" "$T3_PROJ" "$T3_OUT"
result=$(cat "$T3_OUT")

if [[ -n "$result" ]]; then
    if echo "$result" | grep -q "Prior sessions"; then
        pass "get_prior_sessions() — returns structured text with 3+ sessions"
    else
        fail "get_prior_sessions() — 3+ sessions" "missing 'Prior sessions' header in: $result"
    fi

    # Should show at most 3 most-recent sessions (tail -3 of 4 entries)
    session_lines=$(echo "$result" | grep -c "^  - " || true)
    if [[ "$session_lines" -ge 1 && "$session_lines" -le 3 ]]; then
        pass "get_prior_sessions() — shows 1-3 recent sessions ($session_lines lines)"
    else
        fail "get_prior_sessions() — session count" "expected 1-3 lines, got: $session_lines"
    fi
else
    fail "get_prior_sessions() — 3+ sessions" "expected non-empty output"
fi

rm -f "$T3_OUT"
safe_cleanup "$T3_HOME" "$SCRIPT_DIR"
safe_cleanup "$T3_PROJ" "$SCRIPT_DIR"
echo ""

# =============================================================================
# TEST 4: Recurring friction detected from 2+ sessions with same string
# =============================================================================
echo "--- Test 4: recurring friction detection ---"

T4_HOME=$(mktemp -d)
T4_PROJ=$(mktemp -d)
T4_SESSIONS=$(setup_sessions_dir "$T4_HOME" "$T4_PROJ")
T4_OUT=$(mktemp)

# 3 sessions: 2 share the same friction string, 1 has none
make_index_entry "sess-001" "tests-failing" "test_foo_bar assertion failed" >> "$T4_SESSIONS/index.jsonl"
make_index_entry "sess-002" "tests-failing" "test_foo_bar assertion failed" >> "$T4_SESSIONS/index.jsonl"
make_index_entry "sess-003" "tests-passing" ""                               >> "$T4_SESSIONS/index.jsonl"

call_get_prior_sessions "$T4_HOME" "$T4_PROJ" "$T4_OUT"
result=$(cat "$T4_OUT")

if echo "$result" | grep -q "Recurring friction"; then
    pass "get_prior_sessions() — detects recurring friction section"
else
    fail "get_prior_sessions() — recurring friction" "missing 'Recurring friction' section in: $result"
fi

if echo "$result" | grep -q "test_foo_bar"; then
    pass "get_prior_sessions() — friction includes repeated pattern"
else
    fail "get_prior_sessions() — friction content" "missing pattern in: $result"
fi

rm -f "$T4_OUT"
safe_cleanup "$T4_HOME" "$SCRIPT_DIR"
safe_cleanup "$T4_PROJ" "$SCRIPT_DIR"
echo ""

# =============================================================================
# TEST 5: Index trimming — write 25 entries, verify only 20 remain
# =============================================================================
echo "--- Test 5: index trimming to 20 entries ---"

T5_HOME=$(mktemp -d)
T5_PROJ=$(mktemp -d)
T5_SESSIONS=$(setup_sessions_dir "$T5_HOME" "$T5_PROJ")
T5_INDEX="$T5_SESSIONS/index.jsonl"

for i in $(seq 1 25); do
    make_index_entry "sess-$(printf '%03d' "$i")" "tests-passing" >> "$T5_INDEX"
done

# Apply trim logic (same as session-end.sh)
LINE_COUNT=$(wc -l < "$T5_INDEX" | tr -d ' ')
if [[ "${LINE_COUNT:-0}" -gt 20 ]]; then
    tail -20 "$T5_INDEX" > "${T5_INDEX}.tmp"
    mv "${T5_INDEX}.tmp" "$T5_INDEX"
fi

FINAL_COUNT=$(wc -l < "$T5_INDEX" | tr -d ' ')
if [[ "$FINAL_COUNT" -eq 20 ]]; then
    pass "index trimming — 25 entries trimmed to 20"
else
    fail "index trimming" "expected 20 entries, got: $FINAL_COUNT"
fi

LAST_ID=$(tail -1 "$T5_INDEX" | jq -r '.id' 2>/dev/null)
if [[ "$LAST_ID" == "sess-025" ]]; then
    pass "index trimming — most recent entry retained (sess-025)"
else
    fail "index trimming — recency" "expected sess-025, got: $LAST_ID"
fi

FIRST_ID=$(head -1 "$T5_INDEX" | jq -r '.id' 2>/dev/null)
if [[ "$FIRST_ID" == "sess-006" ]]; then
    pass "index trimming — oldest entries dropped (first is sess-006)"
else
    fail "index trimming — oldest dropped" "expected sess-006, got: $FIRST_ID"
fi

safe_cleanup "$T5_HOME" "$SCRIPT_DIR"
safe_cleanup "$T5_PROJ" "$SCRIPT_DIR"
echo ""

# =============================================================================
# TEST 6: Session index entry has correct schema fields
# =============================================================================
echo "--- Test 6: session index entry schema validation ---"

T6_DIR=$(mktemp -d)
mkdir -p "$T6_DIR/.claude"
T6_OUT=$(mktemp)

cat > "$T6_DIR/.claude/.session-events.jsonl" <<'EVENTS'
{"ts":"2026-02-17T10:00:00Z","event":"session_start","project":"test-project"}
{"ts":"2026-02-17T10:05:00Z","event":"write","file":"hooks/foo.sh"}
{"ts":"2026-02-17T10:10:00Z","event":"test_run","result":"pass","assertion":"test_basic"}
{"ts":"2026-02-17T10:15:00Z","event":"checkpoint","label":"after tests pass"}
{"ts":"2026-02-17T10:20:00Z","event":"write","file":"hooks/bar.sh"}
EVENTS

echo "verified|$(date +%s)" > "$T6_DIR/.claude/.proof-status"

# Build entry using same logic as session-end.sh, via subprocess
bash --norc --noprofile -s > "$T6_OUT" 2>/dev/null <<SCRIPT
source "$CONTEXT_LIB"
PROJECT_ROOT="$T6_DIR"
CLAUDE_DIR="$T6_DIR/.claude"
SESSION_EVENT_FILE="$T6_DIR/.claude/.session-events.jsonl"
SESSION_ID="test-session-t6"

get_session_trajectory "\$PROJECT_ROOT"

FILES_TOUCHED=\$(grep '"event":"write"' "\$SESSION_EVENT_FILE" 2>/dev/null \
    | jq -r '.file // empty' 2>/dev/null \
    | sort -u \
    | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")

FRICTION_JSON="[]"
TEST_FAIL_MSG=\$(grep '"event":"test_run"' "\$SESSION_EVENT_FILE" 2>/dev/null \
    | grep '"result":"fail"' \
    | jq -r '.assertion // empty' 2>/dev/null \
    | sort -u | head -3 \
    | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
if [[ "\$TEST_FAIL_MSG" != "[]" && -n "\$TEST_FAIL_MSG" ]]; then
    FRICTION_JSON="\$TEST_FAIL_MSG"
fi

OUTCOME="unknown"
if [[ -f "$T6_DIR/.claude/.proof-status" ]]; then
    PS_VAL=\$(cut -d'|' -f1 "$T6_DIR/.claude/.proof-status" 2>/dev/null || echo "")
    [[ "\$PS_VAL" == "verified" ]] && OUTCOME="committed"
fi

jq -cn \
    --arg id "\$SESSION_ID" \
    --arg project "\$(basename "\$PROJECT_ROOT")" \
    --arg started "\$(head -1 "\$SESSION_EVENT_FILE" 2>/dev/null | jq -r '.ts // empty' 2>/dev/null || echo "")" \
    --argjson duration_min "\${TRAJ_ELAPSED_MIN:-0}" \
    --argjson files_touched "\$FILES_TOUCHED" \
    --argjson tool_calls "\${TRAJ_TOOL_CALLS:-0}" \
    --argjson checkpoints "\${TRAJ_CHECKPOINTS:-0}" \
    --argjson pivots "\${TRAJ_PIVOTS:-0}" \
    --argjson friction "\$FRICTION_JSON" \
    --arg outcome "\$OUTCOME" \
    '{id:\$id,project:\$project,started:\$started,duration_min:\$duration_min,files_touched:\$files_touched,tool_calls:\$tool_calls,checkpoints:\$checkpoints,pivots:\$pivots,friction:\$friction,outcome:\$outcome}' \
    2>/dev/null
SCRIPT

result=$(cat "$T6_OUT")

if echo "$result" | jq -e '.id' > /dev/null 2>&1; then
    pass "session index — entry is valid JSON with id field"
else
    fail "session index — schema" "invalid JSON or missing id: $result"
fi

OUTCOME_VAL=$(echo "$result" | jq -r '.outcome' 2>/dev/null)
if [[ "$OUTCOME_VAL" == "committed" ]]; then
    pass "session index — outcome=committed when proof-status=verified"
else
    fail "session index — outcome" "expected committed, got: $OUTCOME_VAL"
fi

FILES_VAL=$(echo "$result" | jq -r '.files_touched | length' 2>/dev/null)
if [[ "$FILES_VAL" -eq 2 ]]; then
    pass "session index — files_touched has 2 entries"
else
    fail "session index — files_touched" "expected 2, got: $FILES_VAL"
fi

CHECKPOINTS_VAL=$(echo "$result" | jq -r '.checkpoints' 2>/dev/null)
if [[ "$CHECKPOINTS_VAL" -eq 1 ]]; then
    pass "session index — checkpoints count correct"
else
    fail "session index — checkpoints" "expected 1, got: $CHECKPOINTS_VAL"
fi

rm -f "$T6_OUT"
safe_cleanup "$T6_DIR" "$SCRIPT_DIR"
echo ""

# =============================================================================
# TEST 7: Unique friction strings NOT flagged as recurring
# =============================================================================
echo "--- Test 7: non-recurring friction not shown as recurring ---"

T7_HOME=$(mktemp -d)
T7_PROJ=$(mktemp -d)
T7_SESSIONS=$(setup_sessions_dir "$T7_HOME" "$T7_PROJ")
T7_OUT=$(mktemp)

# 3 sessions each with a DIFFERENT friction string
make_index_entry "sess-001" "tests-failing" "test_alpha failed" >> "$T7_SESSIONS/index.jsonl"
make_index_entry "sess-002" "tests-failing" "test_beta failed"  >> "$T7_SESSIONS/index.jsonl"
make_index_entry "sess-003" "tests-failing" "test_gamma failed" >> "$T7_SESSIONS/index.jsonl"

call_get_prior_sessions "$T7_HOME" "$T7_PROJ" "$T7_OUT"
result=$(cat "$T7_OUT")

if echo "$result" | grep -q "Recurring friction"; then
    fail "get_prior_sessions() — non-recurring friction" "should NOT show 'Recurring friction' when all strings unique"
else
    pass "get_prior_sessions() — unique friction strings not flagged as recurring"
fi

rm -f "$T7_OUT"
safe_cleanup "$T7_HOME" "$SCRIPT_DIR"
safe_cleanup "$T7_PROJ" "$SCRIPT_DIR"
echo ""

# =============================================================================
# Summary
# =============================================================================
echo "==========================="
total=$((passed + failed))
echo "Total: $total | Passed: $passed | Failed: $failed"

[[ $failed -gt 0 ]] && exit 1
exit 0
