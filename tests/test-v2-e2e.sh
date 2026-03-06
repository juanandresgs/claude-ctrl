#!/usr/bin/env bash
# E2E Intent Validation — exercises all 5 v2 intents in isolation.
# Each intent gets its own temp directory. Target: <30s total.
#
# Also includes W5-5: complete session lifecycle integration test (9 assertions)
# that simulates all lifecycle stages end-to-end in a single temp dir.
#
# W6-4 adds INTENT-06: a 10-stage lifecycle arc that extends W5-5 with explicit
# agent_start and cross-session context stages:
#   session_start → agent_start → writes → test_fail → pivot_detection →
#   checkpoint → test_pass → session_summary → archive → cross_session_context
# All 10 assertions run in a single temp dir and must complete in <10s.
#
# @decision DEC-V2-E2E-001
# @title E2E intent validation for v2 governance system
# @status accepted
# @rationale The v2 system has 5 key intents (trace, recovery, storytelling, steering,
# cross-session learning) that each span multiple functions and hooks. Unit tests
# validate individual functions; this E2E suite validates the intents end-to-end
# using real temp directories and real git repos. One run covers all 5 intents.
# W5-5 adds a complete session lifecycle test: session_start → writes → test_fail
# → pivot_detection → checkpoint → test_pass → summary → archive → cross-session.
# All 9 lifecycle stages are exercised in a single test function with a single temp dir.
# W6-4 extends this with INTENT-06: a 10-stage lifecycle that adds explicit
# agent_start (stage 2) and cross-session context (stage 10) assertions, completing
# the full arc from spawn to multi-session learning. Target runtime: <10s per intent.
# Each intent is isolated (separate temp dir) so failures don't cascade.

set -euo pipefail
# Portable SHA-256 (macOS: shasum, Ubuntu: sha256sum)
if command -v shasum >/dev/null 2>&1; then
    _SHA256_CMD="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
    _SHA256_CMD="sha256sum"
else
    _SHA256_CMD="cat"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(dirname "$SCRIPT_DIR")/hooks"

source "$HOOKS_DIR/source-lib.sh"; require_git; require_plan; require_trace; require_session

# Test framework
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
passed=0
failed=0
skipped=0

pass() { echo -e "  ${GREEN}PASS${NC} $1"; passed=$((passed + 1)); }
fail() { echo -e "  ${RED}FAIL${NC} $1${2:+ — $2}"; failed=$((failed + 1)); }
skip() { echo -e "  ${YELLOW}SKIP${NC} $1${2:+ — $2}"; skipped=$((skipped + 1)); }

# Safe cleanup helper — prevents CWD-deletion bug
safe_cleanup() {
    local dir="$1"
    local fallback="${2:-$SCRIPT_DIR}"
    [[ "$(pwd)" == "$dir"* ]] && cd "$fallback"
    rm -rf "$dir"
}

# ============================================================================
# INTENT-01: Every session leaves a trace
# ============================================================================

echo "=== INTENT-01: Every session leaves a trace ==="
I01_DIR=$(mktemp -d)
mkdir -p "$I01_DIR/.claude" "$I01_DIR/.git"

# Write 5 events
append_session_event "session_start" '{"project":"test","branch":"main"}' "$I01_DIR"
append_session_event "write" '{"file":"foo.py"}' "$I01_DIR"
append_session_event "write" '{"file":"bar.py"}' "$I01_DIR"
append_session_event "write" '{"file":"foo.py"}' "$I01_DIR"
append_session_event "gate_eval" '{"hook":"guard","check":"test_gate","result":"block","reason":"tests failing"}' "$I01_DIR"

# Verify: event file exists with valid JSONL
EVENT_FILE="$I01_DIR/.claude/.session-events.jsonl"
[[ -f "$EVENT_FILE" ]] && pass "event file created" || fail "event file missing"

# Verify: correct line count
LINE_COUNT=$(wc -l < "$EVENT_FILE" | tr -d ' ')
[[ "$LINE_COUNT" -eq 5 ]] && pass "5 events written" || fail "expected 5 events, got $LINE_COUNT"

# Verify: each line is valid JSON
VALID_JSON=true
while IFS= read -r line; do
    echo "$line" | jq . > /dev/null 2>&1 || { VALID_JSON=false; break; }
done < "$EVENT_FILE"
[[ "$VALID_JSON" == "true" ]] && pass "all lines valid JSON" || fail "invalid JSON in event file"

# Verify: session archive simulation
# Create session archive directory structure
PROJECT_HASH=$(echo "$I01_DIR" | $_SHA256_CMD | cut -c1-12)
ARCHIVE_DIR="$I01_DIR/sessions/$PROJECT_HASH"
mkdir -p "$ARCHIVE_DIR"
SESSION_ID="test-session-$(date +%s)"

# Archive the event file (simulating session-end.sh logic)
cp "$EVENT_FILE" "$ARCHIVE_DIR/${SESSION_ID}.jsonl"
rm -f "$EVENT_FILE"

[[ -f "$ARCHIVE_DIR/${SESSION_ID}.jsonl" ]] && pass "session archived" || fail "archive missing"
[[ ! -f "$EVENT_FILE" ]] && pass "event file cleaned up" || fail "event file not cleaned"

# Verify: archived file has valid JSONL
ARCHIVE_LINES=$(wc -l < "$ARCHIVE_DIR/${SESSION_ID}.jsonl" | tr -d ' ')
[[ "$ARCHIVE_LINES" -eq 5 ]] && pass "archive has all events" || fail "archive has $ARCHIVE_LINES events"

safe_cleanup "$I01_DIR" "$SCRIPT_DIR"
echo ""

# ============================================================================
# INTENT-02: Mid-session recovery in seconds
# ============================================================================

echo "=== INTENT-02: Mid-session recovery in seconds ==="
I02_DIR=$(mktemp -d)
cd "$I02_DIR"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
git checkout -q -b feature/test-recovery
mkdir -p .claude

# Create initial file and commit
echo "original content" > app.py
git add app.py && git commit -q -m "initial"

# Simulate checkpoint creation (simplified — checkpoint.sh uses git refs)
# Write 6 versions, creating checkpoints via direct git ref creation
for i in $(seq 1 6); do
    echo "version $i" > app.py
    git add app.py
    TREE=$(git write-tree)
    COMMIT=$(git commit-tree "$TREE" -m "checkpoint write $i" -p HEAD)
    git update-ref "refs/checkpoints/auto-$(printf '%03d' $i)" "$COMMIT"
    append_session_event "write" "{\"file\":\"app.py\"}" "$I02_DIR"
done

# Verify: checkpoint refs exist
REF_COUNT=$(git for-each-ref refs/checkpoints/ --format='%(refname)' | wc -l | tr -d ' ')
[[ "$REF_COUNT" -eq 6 ]] && pass "6 checkpoint refs created" || fail "expected 6 refs, got $REF_COUNT"

# Verify: checkpoint commit tree matches
# Sort by refname (auto-001..auto-006) so tail -1 reliably gives the last checkpoint
# (--sort=-committerdate is unreliable when commits are created in the same second)
LAST_CP=$(git for-each-ref refs/checkpoints/ --sort=refname --format='%(objectname)' | tail -1)
[[ -n "$LAST_CP" ]] && pass "latest checkpoint ref found" || fail "no checkpoint ref"

# Break the file
echo "BROKEN CONTENT" > app.py
[[ "$(cat app.py)" == "BROKEN CONTENT" ]] && pass "file broken for recovery test" || fail "break failed"

# Recover from checkpoint
START_TIME=$(date +%s%N 2>/dev/null || date +%s)
git checkout "$LAST_CP" -- app.py 2>/dev/null
END_TIME=$(date +%s%N 2>/dev/null || date +%s)

# Verify: file restored
RECOVERED=$(cat app.py)
[[ "$RECOVERED" == "version 6" ]] && pass "file recovered from checkpoint" || fail "recovery failed: got '$RECOVERED'"

# Measure recovery time (nanoseconds to seconds)
if [[ "$START_TIME" =~ [0-9]{10,} ]]; then
    ELAPSED_NS=$((END_TIME - START_TIME))
    ELAPSED_MS=$((ELAPSED_NS / 1000000))
    [[ "$ELAPSED_MS" -lt 2000 ]] && pass "recovery under 2s (${ELAPSED_MS}ms)" || fail "recovery too slow: ${ELAPSED_MS}ms"
else
    pass "recovery completed (timing not available on this OS)"
fi

cd "$SCRIPT_DIR"
safe_cleanup "$I02_DIR" "$SCRIPT_DIR"
echo ""

# ============================================================================
# INTENT-03: Commits tell engineering stories
# ============================================================================

echo "=== INTENT-03: Commits tell engineering stories ==="
I03_DIR=$(mktemp -d)
mkdir -p "$I03_DIR/.claude" "$I03_DIR/.git"

# Build event log with 10 events of mixed types (>3 for non-trivial)
append_session_event "session_start" '{"project":"test","branch":"feature/auth"}' "$I03_DIR"
append_session_event "write" '{"file":"auth.py"}' "$I03_DIR"
append_session_event "write" '{"file":"auth.py"}' "$I03_DIR"
append_session_event "test_run" '{"result":"fail","failures":2,"assertion":"test_validate_jwt"}' "$I03_DIR"
append_session_event "write" '{"file":"auth.py"}' "$I03_DIR"
append_session_event "test_run" '{"result":"pass","failures":0}' "$I03_DIR"
append_session_event "checkpoint" '{"ref":"refs/checkpoints/auto-001","file":"auth.py","trigger":"n=5"}' "$I03_DIR"
append_session_event "agent_start" '{"type":"implementer"}' "$I03_DIR"
append_session_event "write" '{"file":"test_auth.py"}' "$I03_DIR"
append_session_event "agent_start" '{"type":"tester"}' "$I03_DIR"

# Call get_session_summary_context
SUMMARY=$(get_session_summary_context "$I03_DIR")

# Verify: contains Session Context header (use -F -e — pattern starts with dashes, looks like grep flag)
echo "$SUMMARY" | grep -qF -e '--- Session Context ---' && pass "session context header present" || fail "missing header"

# Verify: Stats line present
echo "$SUMMARY" | grep -q 'Stats:' && pass "Stats line present" || fail "missing Stats"

# Verify: Stats line has correct tool call count (4 writes: auth.py x3, test_auth.py x1)
echo "$SUMMARY" | grep 'Stats:' | grep -q '4 tool calls' && pass "correct tool call count (4)" || fail "wrong tool count in: $(echo "$SUMMARY" | grep 'Stats:')"

# Verify: Checkpoints counted (1 checkpoint event)
echo "$SUMMARY" | grep 'Stats:' | grep -q '1 checkpoints' && pass "checkpoint count correct" || fail "wrong checkpoint count in: $(echo "$SUMMARY" | grep 'Stats:')"

# Verify: Friction line appears (we have test failures)
echo "$SUMMARY" | grep -q 'Friction:' && pass "Friction line present" || fail "missing Friction"
echo "$SUMMARY" | grep 'Friction:' | grep -q 'test_validate_jwt' && pass "top assertion in friction" || fail "assertion not in friction"

# Verify: Agents line
echo "$SUMMARY" | grep -q 'Agents:' && pass "Agents line present" || fail "missing Agents line"
echo "$SUMMARY" | grep 'Agents:' | grep -q 'implementer' && pass "implementer in agents" || fail "implementer not listed"
echo "$SUMMARY" | grep 'Agents:' | grep -q 'tester' && pass "tester in agents" || fail "tester not listed"

# Verify: trivial session returns empty
I03_TRIVIAL=$(mktemp -d)
mkdir -p "$I03_TRIVIAL/.claude" "$I03_TRIVIAL/.git"
append_session_event "session_start" '{"project":"test"}' "$I03_TRIVIAL"
append_session_event "write" '{"file":"x.py"}' "$I03_TRIVIAL"
TRIVIAL_SUMMARY=$(get_session_summary_context "$I03_TRIVIAL")
[[ -z "$TRIVIAL_SUMMARY" ]] && pass "trivial session returns empty" || fail "trivial session non-empty: $TRIVIAL_SUMMARY"

safe_cleanup "$I03_DIR" "$SCRIPT_DIR"
safe_cleanup "$I03_TRIVIAL" "$SCRIPT_DIR"
echo ""

# ============================================================================
# INTENT-04: Hooks steer, not just block
# ============================================================================

echo "=== INTENT-04: Hooks steer, not just block ==="
I04_DIR=$(mktemp -d)
mkdir -p "$I04_DIR/.claude" "$I04_DIR/.git"

# Set up test state: failing tests, 1 gate strike
echo "fail|3|$(date +%s)" > "$I04_DIR/.claude/.test-status"
echo "1|$(date +%s)" > "$I04_DIR/.claude/.test-gate-strikes"

# Write events: edit->fail->edit->fail pattern
append_session_event "write" '{"file":"compute.py"}' "$I04_DIR"
append_session_event "test_run" '{"result":"fail","failures":1,"assertion":"test_compute_result"}' "$I04_DIR"
append_session_event "write" '{"file":"compute.py"}' "$I04_DIR"
append_session_event "test_run" '{"result":"fail","failures":1,"assertion":"test_compute_result"}' "$I04_DIR"

# Run detect_approach_pivots
# Wrap in set +e since internal grep pipelines can exit 1 on no-match under pipefail
set +e
detect_approach_pivots "$I04_DIR"
set -e

# Verify: pivots detected
[[ "$PIVOT_COUNT" -gt 0 ]] && pass "pivot detected (count=$PIVOT_COUNT)" || fail "no pivots detected"
echo "$PIVOT_FILES" | grep -q "compute.py" && pass "compute.py identified as pivot file" || fail "compute.py not in pivots: $PIVOT_FILES"
echo "$PIVOT_ASSERTIONS" | grep -q "test_compute_result" && pass "test_compute_result in assertions" || fail "assertion not found: $PIVOT_ASSERTIONS"

# Verify: trajectory has the right counts
# get_session_trajectory uses grep pipelines that exit 1 on no-match (e.g. no "block" events).
# With set -o pipefail those propagate — disable set -e around the call, re-enable after.
set +e
get_session_trajectory "$I04_DIR"
set -e
[[ "$TRAJ_TEST_FAILURES" -eq 2 ]] && pass "2 test failures counted" || fail "expected 2 failures, got $TRAJ_TEST_FAILURES"
[[ "$TRAJ_TOOL_CALLS" -eq 2 ]] && pass "2 write events counted" || fail "expected 2 writes, got $TRAJ_TOOL_CALLS"

# Compare: scenario without event log (generic message)
I04_GENERIC=$(mktemp -d)
mkdir -p "$I04_GENERIC/.claude" "$I04_GENERIC/.git"
echo "fail|3|$(date +%s)" > "$I04_GENERIC/.claude/.test-status"
set +e
detect_approach_pivots "$I04_GENERIC"
set -e
[[ "$PIVOT_COUNT" -eq 0 ]] && pass "no pivots without event log (generic fallback)" || fail "unexpected pivots without events"

safe_cleanup "$I04_DIR" "$SCRIPT_DIR"
safe_cleanup "$I04_GENERIC" "$SCRIPT_DIR"
echo ""

# ============================================================================
# INTENT-05: Cross-session learning
# ============================================================================

echo "=== INTENT-05: Cross-session learning ==="
I05_DIR=$(mktemp -d)
mkdir -p "$I05_DIR/.git"

# Create session archive with 4 synthetic entries
PROJECT_HASH=$(echo "$I05_DIR" | $_SHA256_CMD | cut -c1-12)
SESSION_DIR="$HOME/.claude/sessions/$PROJECT_HASH"
mkdir -p "$SESSION_DIR"

# Write 4 index entries — 2 have friction "test_auth_token", 1 has unique friction
cat > "$SESSION_DIR/index.jsonl" << 'ENTRIES'
{"id":"s1","started":"2026-02-14T10:00:00Z","duration_min":15,"outcome":"pass","files_touched":["auth.py","test_auth.py"],"friction":["test_auth_token"]}
{"id":"s2","started":"2026-02-15T10:00:00Z","duration_min":22,"outcome":"fail","files_touched":["auth.py"],"friction":["test_auth_token","test_session_expiry"]}
{"id":"s3","started":"2026-02-16T10:00:00Z","duration_min":8,"outcome":"pass","files_touched":["api.py"],"friction":[]}
{"id":"s4","started":"2026-02-17T10:00:00Z","duration_min":30,"outcome":"pass","files_touched":["compute.py","test_compute.py"],"friction":["test_compute_accuracy"]}
ENTRIES

# Call get_prior_sessions
PRIOR=$(get_prior_sessions "$I05_DIR")

# Verify: "Prior sessions" header present
echo "$PRIOR" | grep -q 'Prior sessions' && pass "prior sessions header present" || fail "missing header"

# Verify: recent summaries shown (at least the last 3 session dates)
echo "$PRIOR" | grep -q '2026-02-15' && pass "session 2 in output" || fail "session 2 missing"
echo "$PRIOR" | grep -q '2026-02-16' && pass "session 3 in output" || fail "session 3 missing"
echo "$PRIOR" | grep -q '2026-02-17' && pass "session 4 in output" || fail "session 4 missing"

# Verify: "Recurring friction" section present with test_auth_token
echo "$PRIOR" | grep -q 'Recurring friction' && pass "recurring friction header present" || fail "missing recurring friction"
echo "$PRIOR" | grep -q 'test_auth_token' && pass "test_auth_token in recurring friction" || fail "test_auth_token missing"

# Verify: unique friction NOT flagged as recurring
if echo "$PRIOR" | grep -q 'test_compute_accuracy'; then
    fail "unique friction falsely flagged as recurring"
else
    pass "unique friction correctly excluded"
fi

# Verify: threshold check — fewer than 3 sessions returns empty
SPARSE_DIR=$(mktemp -d)
mkdir -p "$SPARSE_DIR/.git"
SPARSE_HASH=$(echo "$SPARSE_DIR" | $_SHA256_CMD | cut -c1-12)
SPARSE_SESSION_DIR="$HOME/.claude/sessions/$SPARSE_HASH"
mkdir -p "$SPARSE_SESSION_DIR"
echo '{"id":"s1","started":"2026-02-14T10:00:00Z","duration_min":5,"outcome":"pass","files_touched":[],"friction":[]}' > "$SPARSE_SESSION_DIR/index.jsonl"
echo '{"id":"s2","started":"2026-02-15T10:00:00Z","duration_min":5,"outcome":"pass","files_touched":[],"friction":[]}' >> "$SPARSE_SESSION_DIR/index.jsonl"
SPARSE_RESULT=$(get_prior_sessions "$SPARSE_DIR")
[[ -z "$SPARSE_RESULT" ]] && pass "fewer than 3 sessions returns empty" || fail "sparse sessions not empty"

# Clean up session archive dirs
safe_cleanup "$I05_DIR" "$SCRIPT_DIR"
safe_cleanup "$SPARSE_DIR" "$SCRIPT_DIR"
rm -rf "$SESSION_DIR" "$SPARSE_SESSION_DIR"
echo ""

# ============================================================================
# W5-5: Complete session lifecycle integration test (9 assertions)
# ============================================================================
# Exercises every stage of the v2 session lifecycle in a single temp dir:
#   1. session_start logged
#   2. write events logged
#   3. test_run fail logged
#   4. detect_approach_pivots detects the edit-fail loop
#   5. checkpoint event logged
#   6. test_run pass logged
#   7. get_session_summary_context produces non-empty output with Stats
#   8. session archived (event file copied to archive dir, original removed)
#   9. get_prior_sessions returns context after 3 archived sessions

echo "=== W5-5: Complete Session Lifecycle Integration ==="
LC_DIR=$(mktemp -d)
mkdir -p "$LC_DIR/.claude" "$LC_DIR/.git"

# --- Stage 1: session_start ---
append_session_event "session_start" '{"project":"lifecycle-test","branch":"main"}' "$LC_DIR"
LC_EVENTS="$LC_DIR/.claude/.session-events.jsonl"
LC_COUNT=$(wc -l < "$LC_EVENTS" | tr -d ' ')
[[ "$LC_COUNT" -ge 1 ]] && pass "stage 1: session_start event logged" || fail "stage 1: session_start not logged"

# --- Stage 2: write events ---
append_session_event "write" '{"file":"src/auth.py"}' "$LC_DIR"
append_session_event "write" '{"file":"src/auth.py"}' "$LC_DIR"
append_session_event "write" '{"file":"src/utils.py"}' "$LC_DIR"
LC_COUNT=$(wc -l < "$LC_EVENTS" | tr -d ' ')
[[ "$LC_COUNT" -eq 4 ]] && pass "stage 2: 3 write events appended (total=4)" \
    || fail "stage 2: expected 4 events, got $LC_COUNT"

# --- Stage 3: test_run fail ---
append_session_event "test_run" '{"result":"fail","failures":2,"assertion":"test_auth_validate"}' "$LC_DIR"
append_session_event "write"    '{"file":"src/auth.py"}' "$LC_DIR"
append_session_event "test_run" '{"result":"fail","failures":2,"assertion":"test_auth_validate"}' "$LC_DIR"
LC_COUNT=$(wc -l < "$LC_EVENTS" | tr -d ' ')
[[ "$LC_COUNT" -eq 7 ]] && pass "stage 3: test_run fail events logged (total=7)" \
    || fail "stage 3: expected 7 events, got $LC_COUNT"

# --- Stage 4: detect_approach_pivots detects the loop ---
set +e
detect_approach_pivots "$LC_DIR"
set -e
if [[ "$PIVOT_COUNT" -ge 1 ]]; then
    pass "stage 4: detect_approach_pivots detects edit-fail loop (PIVOT_COUNT=$PIVOT_COUNT)"
else
    fail "stage 4: detect_approach_pivots did not detect loop"
fi
if echo "$PIVOT_FILES" | grep -q "src/auth.py"; then
    pass "stage 4: auth.py identified as pivot file"
else
    fail "stage 4: auth.py not in pivot files: $PIVOT_FILES"
fi

# --- Stage 5: checkpoint event ---
append_session_event "checkpoint" '{"ref":"refs/checkpoints/auto-001"}' "$LC_DIR"
LC_CHECKPOINTS=$(grep -c '"event":"checkpoint"' "$LC_EVENTS" 2>/dev/null || true)
[[ "$LC_CHECKPOINTS" -eq 1 ]] && pass "stage 5: checkpoint event logged" \
    || fail "stage 5: expected 1 checkpoint, found $LC_CHECKPOINTS"

# --- Stage 6: test_run pass ---
append_session_event "test_run" '{"result":"pass","failures":0,"assertion":"test_auth_validate"}' "$LC_DIR"
LC_PASSES=$(grep '"event":"test_run"' "$LC_EVENTS" 2>/dev/null | grep '"result":"pass"' | wc -l | tr -d ' ')
[[ "$LC_PASSES" -ge 1 ]] && pass "stage 6: test_run pass event logged" \
    || fail "stage 6: no pass events found"

# --- Stage 7: get_session_summary_context is non-empty and has Stats ---
LC_SUMMARY=$(get_session_summary_context "$LC_DIR")
if [[ -n "$LC_SUMMARY" ]]; then
    pass "stage 7: session summary non-empty"
else
    fail "stage 7: session summary empty"
fi
if echo "$LC_SUMMARY" | grep -q '^Stats:'; then
    pass "stage 7: session summary has Stats line"
else
    fail "stage 7: session summary missing Stats line"
fi

# --- Stage 8: session archive simulation ---
# Simulate what session-end.sh does: copy event file to archive dir, remove original.
LC_PROJECT_HASH=$(echo "$LC_DIR" | $_SHA256_CMD 2>/dev/null | cut -c1-12)
LC_ARCHIVE_DIR="$HOME/.claude/sessions/${LC_PROJECT_HASH}"
mkdir -p "$LC_ARCHIVE_DIR"
LC_SESSION_ID="lifecycle-session-$(date +%s)"
cp "$LC_EVENTS" "${LC_ARCHIVE_DIR}/${LC_SESSION_ID}.jsonl"
# Write index entry so get_prior_sessions can read it
LC_TOTAL_EVENTS=$(wc -l < "$LC_EVENTS" | tr -d ' ')
echo "{\"id\":\"$LC_SESSION_ID\",\"started\":\"2026-02-19T10:00:00Z\",\"duration_min\":5,\"outcome\":\"tests-passing\",\"files_touched\":[\"src/auth.py\",\"src/utils.py\"],\"friction\":[\"test_auth_validate\"]}" \
    >> "${LC_ARCHIVE_DIR}/index.jsonl"
rm -f "$LC_EVENTS"

[[ -f "${LC_ARCHIVE_DIR}/${LC_SESSION_ID}.jsonl" ]] && pass "stage 8: session archived to index dir" \
    || fail "stage 8: archive file missing"
[[ ! -f "$LC_EVENTS" ]] && pass "stage 8: event file removed after archive" \
    || fail "stage 8: event file still present after archive"
LC_ARCHIVE_LINES=$(wc -l < "${LC_ARCHIVE_DIR}/${LC_SESSION_ID}.jsonl" | tr -d ' ')
[[ "$LC_ARCHIVE_LINES" -eq "$LC_TOTAL_EVENTS" ]] && pass "stage 8: archive contains all $LC_TOTAL_EVENTS events" \
    || fail "stage 8: archive has $LC_ARCHIVE_LINES events, expected $LC_TOTAL_EVENTS"

# --- Stage 9: get_prior_sessions returns context after 3 sessions ---
# Add 2 more index entries so we hit the >=3 threshold
echo '{"id":"prev-1","started":"2026-02-17T10:00:00Z","duration_min":10,"outcome":"pass","files_touched":["src/auth.py"],"friction":["test_auth_validate"]}' \
    >> "${LC_ARCHIVE_DIR}/index.jsonl"
echo '{"id":"prev-2","started":"2026-02-18T10:00:00Z","duration_min":8,"outcome":"pass","files_touched":["src/utils.py"],"friction":[]}' \
    >> "${LC_ARCHIVE_DIR}/index.jsonl"
LC_PRIOR=$(get_prior_sessions "$LC_DIR")
if [[ -n "$LC_PRIOR" ]]; then
    pass "stage 9: get_prior_sessions returns context (3+ archived sessions)"
else
    fail "stage 9: get_prior_sessions returned empty with 3 sessions"
fi
if echo "$LC_PRIOR" | grep -q 'Prior sessions'; then
    pass "stage 9: prior sessions output has 'Prior sessions' header"
else
    fail "stage 9: prior sessions missing header"
fi

safe_cleanup "$LC_DIR" "$SCRIPT_DIR"
rm -rf "${LC_ARCHIVE_DIR}"
echo ""

# ============================================================================
# INTENT-06 (W6-4): 10-stage lifecycle arc — session_start to cross-session
# ============================================================================
# Exercises the complete v2 session lifecycle in sequence:
#   Stage 1:  session_start event logged
#   Stage 2:  agent_start event logged (implementer spawn)
#   Stage 3:  write events logged (3 writes to 2 unique files)
#   Stage 4:  test_fail events logged (edit-fail loop)
#   Stage 5:  detect_approach_pivots identifies the looping file
#   Stage 6:  checkpoint event logged
#   Stage 7:  test_pass event logged
#   Stage 8:  session_summary non-empty with Stats line
#   Stage 9:  session archived (event file → archive dir, original removed)
#   Stage 10: cross-session context available after 3 archived sessions
#
# All 10 assertions run in <10s in a single temp dir.
# ============================================================================

echo "=== INTENT-06 (W6-4): 10-Stage Session Lifecycle Arc ==="
INTENT06_START=$(date +%s 2>/dev/null || echo "0")
I06_DIR=$(mktemp -d)
mkdir -p "$I06_DIR/.claude" "$I06_DIR/.git"

# --- Stage 1: session_start ---
append_session_event "session_start" '{"project":"intent06","branch":"feature/lifecycle"}' "$I06_DIR"
I06_EVENTS="$I06_DIR/.claude/.session-events.jsonl"
I06_COUNT=$(wc -l < "$I06_EVENTS" | tr -d ' ')
[[ "$I06_COUNT" -ge 1 ]] && pass "INTENT-06 stage 1: session_start event logged" \
    || fail "INTENT-06 stage 1: session_start not logged"

# --- Stage 2: agent_start (implementer spawn) ---
append_session_event "agent_start" '{"type":"implementer"}' "$I06_DIR"
I06_AGENT=$(grep '"event":"agent_start"' "$I06_EVENTS" 2>/dev/null | grep '"implementer"' | wc -l | tr -d ' ')
[[ "$I06_AGENT" -ge 1 ]] && pass "INTENT-06 stage 2: agent_start(implementer) event logged" \
    || fail "INTENT-06 stage 2: agent_start not logged"

# --- Stage 3: write events ---
append_session_event "write" '{"file":"src/compute.py"}' "$I06_DIR"
append_session_event "write" '{"file":"src/compute.py"}' "$I06_DIR"
append_session_event "write" '{"file":"tests/test_compute.py"}' "$I06_DIR"
I06_COUNT=$(wc -l < "$I06_EVENTS" | tr -d ' ')
[[ "$I06_COUNT" -eq 5 ]] && pass "INTENT-06 stage 3: 3 write events logged (total=5)" \
    || fail "INTENT-06 stage 3: expected 5 events, got $I06_COUNT"

# --- Stage 4: test_fail events ---
append_session_event "test_run" '{"result":"fail","failures":1,"assertion":"test_compute_value"}' "$I06_DIR"
append_session_event "write"    '{"file":"src/compute.py"}' "$I06_DIR"
append_session_event "test_run" '{"result":"fail","failures":1,"assertion":"test_compute_value"}' "$I06_DIR"
I06_FAILS=$(grep '"event":"test_run"' "$I06_EVENTS" 2>/dev/null | grep '"result":"fail"' | wc -l | tr -d ' ')
[[ "$I06_FAILS" -ge 2 ]] && pass "INTENT-06 stage 4: test_fail events logged (count=$I06_FAILS)" \
    || fail "INTENT-06 stage 4: expected >=2 fail events, got $I06_FAILS"

# --- Stage 5: pivot detection ---
set +e
detect_approach_pivots "$I06_DIR"
set -e
if [[ "$PIVOT_COUNT" -ge 1 ]]; then
    pass "INTENT-06 stage 5: pivot detected (PIVOT_COUNT=$PIVOT_COUNT)"
else
    fail "INTENT-06 stage 5: no pivot detected after edit-fail loop"
fi
if echo "$PIVOT_FILES" | grep -q "src/compute.py"; then
    pass "INTENT-06 stage 5: compute.py identified as pivot file"
else
    fail "INTENT-06 stage 5: compute.py not in pivot files: $PIVOT_FILES"
fi

# --- Stage 6: checkpoint ---
append_session_event "checkpoint" '{"ref":"refs/checkpoints/auto-001"}' "$I06_DIR"
I06_CHECKPOINTS=$(grep -c '"event":"checkpoint"' "$I06_EVENTS" 2>/dev/null || echo "0")
[[ "$I06_CHECKPOINTS" -eq 1 ]] && pass "INTENT-06 stage 6: checkpoint event logged" \
    || fail "INTENT-06 stage 6: expected 1 checkpoint, found $I06_CHECKPOINTS"

# --- Stage 7: test_pass ---
append_session_event "test_run" '{"result":"pass","failures":0,"assertion":"test_compute_value"}' "$I06_DIR"
I06_PASSES=$(grep '"event":"test_run"' "$I06_EVENTS" 2>/dev/null | grep '"result":"pass"' | wc -l | tr -d ' ')
[[ "$I06_PASSES" -ge 1 ]] && pass "INTENT-06 stage 7: test_pass event logged" \
    || fail "INTENT-06 stage 7: no pass events found"

# --- Stage 8: session_summary ---
I06_SUMMARY=$(get_session_summary_context "$I06_DIR")
if [[ -n "$I06_SUMMARY" ]]; then
    pass "INTENT-06 stage 8: session summary non-empty"
else
    fail "INTENT-06 stage 8: session summary empty"
fi
if echo "$I06_SUMMARY" | grep -q '^Stats:'; then
    pass "INTENT-06 stage 8: session summary has Stats line"
else
    fail "INTENT-06 stage 8: session summary missing Stats line"
fi

# --- Stage 9: archive ---
I06_PROJECT_HASH=$(echo "$I06_DIR" | $_SHA256_CMD 2>/dev/null | cut -c1-12)
I06_ARCHIVE_DIR="$HOME/.claude/sessions/${I06_PROJECT_HASH}"
mkdir -p "$I06_ARCHIVE_DIR"
I06_SESSION_ID="intent06-session-$(date +%s)"
I06_TOTAL_EVENTS=$(wc -l < "$I06_EVENTS" | tr -d ' ')
cp "$I06_EVENTS" "${I06_ARCHIVE_DIR}/${I06_SESSION_ID}.jsonl"
echo "{\"id\":\"$I06_SESSION_ID\",\"started\":\"2026-02-20T10:00:00Z\",\"duration_min\":5,\"outcome\":\"pass\",\"files_touched\":[\"src/compute.py\",\"tests/test_compute.py\"],\"friction\":[\"test_compute_value\"]}" \
    >> "${I06_ARCHIVE_DIR}/index.jsonl"
rm -f "$I06_EVENTS"

[[ -f "${I06_ARCHIVE_DIR}/${I06_SESSION_ID}.jsonl" ]] && pass "INTENT-06 stage 9: session archived" \
    || fail "INTENT-06 stage 9: archive file missing"
[[ ! -f "$I06_EVENTS" ]] && pass "INTENT-06 stage 9: event file removed after archive" \
    || fail "INTENT-06 stage 9: event file still present after archive"
I06_ARCHIVE_LINES=$(wc -l < "${I06_ARCHIVE_DIR}/${I06_SESSION_ID}.jsonl" | tr -d ' ')
[[ "$I06_ARCHIVE_LINES" -eq "$I06_TOTAL_EVENTS" ]] && pass "INTENT-06 stage 9: archive has all $I06_TOTAL_EVENTS events" \
    || fail "INTENT-06 stage 9: archive has $I06_ARCHIVE_LINES events, expected $I06_TOTAL_EVENTS"

# --- Stage 10: cross-session context ---
# Add 2 more index entries to reach the >=3 threshold for get_prior_sessions
echo '{"id":"i06-prev-1","started":"2026-02-18T10:00:00Z","duration_min":8,"outcome":"pass","files_touched":["src/compute.py"],"friction":["test_compute_value"]}' \
    >> "${I06_ARCHIVE_DIR}/index.jsonl"
echo '{"id":"i06-prev-2","started":"2026-02-19T10:00:00Z","duration_min":6,"outcome":"pass","files_touched":["tests/test_compute.py"],"friction":[]}' \
    >> "${I06_ARCHIVE_DIR}/index.jsonl"
I06_PRIOR=$(get_prior_sessions "$I06_DIR")
if [[ -n "$I06_PRIOR" ]]; then
    pass "INTENT-06 stage 10: cross-session context available (3+ archived sessions)"
else
    fail "INTENT-06 stage 10: get_prior_sessions returned empty with 3 sessions"
fi
if echo "$I06_PRIOR" | grep -q 'Prior sessions'; then
    pass "INTENT-06 stage 10: cross-session output has 'Prior sessions' header"
else
    fail "INTENT-06 stage 10: cross-session output missing 'Prior sessions' header"
fi

# Verify timing (must complete in <10s)
INTENT06_END=$(date +%s 2>/dev/null || echo "0")
if [[ "$INTENT06_START" -gt 0 && "$INTENT06_END" -gt 0 ]]; then
    INTENT06_ELAPSED=$(( INTENT06_END - INTENT06_START ))
    [[ "$INTENT06_ELAPSED" -lt 10 ]] && pass "INTENT-06 completed in ${INTENT06_ELAPSED}s (<10s)" \
        || fail "INTENT-06 took ${INTENT06_ELAPSED}s (expected <10s)"
else
    pass "INTENT-06 timing not available on this OS (skipping timing assertion)"
fi

safe_cleanup "$I06_DIR" "$SCRIPT_DIR"
rm -rf "${I06_ARCHIVE_DIR}"
echo ""

# ============================================================================
# Summary
# ============================================================================

echo "==========================="
total=$((passed + failed + skipped))
echo -e "Total: $total | ${GREEN}Passed: $passed${NC} | ${RED}Failed: $failed${NC} | ${YELLOW}Skipped: $skipped${NC}"

if [[ $failed -gt 0 ]]; then
    exit 1
fi
