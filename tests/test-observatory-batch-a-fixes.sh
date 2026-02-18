#!/usr/bin/env bash
# test-observatory-batch-a-fixes.sh — Tests for Observatory Batch A signal fixes
#
# Purpose: Verify three init_trace() fixes from Observatory Batch A:
#   - SIG-AGENT-TYPE-MISMATCH: Normalize capitalized agent_type (Plan→planner)
#   - SIG-BRANCH-UNKNOWN: Emit 'no-git' for non-git directories
#   - SIG-STALE-MARKERS: Clean up .active-* markers older than 2 hours
#
# @decision DEC-OBS-018
# @title Test agent_type normalization in init_trace
# @status accepted
# @rationale The Task tool emits capitalized subagent_type values (Plan, Explore).
#             Normalizing at trace creation prevents analysis mismatches.
#
# @decision DEC-OBS-019
# @title Test no-git branch label in init_trace
# @status accepted
# @rationale Distinguishes truly non-git directories from transient git failures.
#
# @decision DEC-OBS-020
# @title Test stale .active-* marker cleanup in init_trace
# @status accepted
# @rationale Orphaned markers from crashed agents block false-positive detection.
#
# Usage: bash tests/test-observatory-batch-a-fixes.sh
# Returns: 0 if all tests pass, 1 if any fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="${WORKTREE_ROOT}/hooks"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Shared cleanup list for temp directories
CLEANUP_DIRS=()
trap 'rm -rf "${CLEANUP_DIRS[@]}"' EXIT

# Create an isolated trace store (each test gets its own to avoid interference)
make_trace_store() {
    local d
    d=$(mktemp -d)
    CLEANUP_DIRS+=("$d")
    echo "$d"
}

# Create a real git repo with one initial commit
make_git_repo() {
    local d
    d=$(mktemp -d)
    CLEANUP_DIRS+=("$d")
    git -C "$d" init -q 2>/dev/null
    git -C "$d" config user.email "test@test.com" 2>/dev/null
    git -C "$d" config user.name "Test" 2>/dev/null
    echo "initial" > "${d}/base.txt"
    git -C "$d" add base.txt 2>/dev/null
    git -C "$d" commit -q -m "initial" 2>/dev/null
    echo "$d"
}

# Create a plain (non-git) directory
make_plain_dir() {
    local d
    d=$(mktemp -d)
    CLEANUP_DIRS+=("$d")
    echo "$d"
}

# ============================================================
# Test 1: agent_type "Plan" normalizes to "planner"
# ============================================================
echo ""
echo "=== Test 1: agent_type 'Plan' normalizes to 'planner' ==="
TS1=$(make_trace_store)
PROJ1=$(make_plain_dir)
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS1"
    trace_id=$(init_trace "$PROJ1" "Plan" 2>/dev/null)
    jq -r '.agent_type // "not-set"' "${TS1}/${trace_id}/manifest.json" 2>/dev/null
)
if [[ "$output" == "planner" ]]; then
    pass "agent_type 'Plan' → normalized to 'planner'"
else
    fail "agent_type 'Plan' → expected 'planner', got: '$output'"
fi

# ============================================================
# Test 2: agent_type "Explore" normalizes to "explore"
# ============================================================
echo ""
echo "=== Test 2: agent_type 'Explore' normalizes to 'explore' ==="
TS2=$(make_trace_store)
PROJ2=$(make_plain_dir)
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS2"
    trace_id=$(init_trace "$PROJ2" "Explore" 2>/dev/null)
    jq -r '.agent_type // "not-set"' "${TS2}/${trace_id}/manifest.json" 2>/dev/null
)
if [[ "$output" == "explore" ]]; then
    pass "agent_type 'Explore' → normalized to 'explore'"
else
    fail "agent_type 'Explore' → expected 'explore', got: '$output'"
fi

# ============================================================
# Test 3: agent_type "implementer" passes through unchanged
# ============================================================
echo ""
echo "=== Test 3: agent_type 'implementer' passes through unchanged ==="
TS3=$(make_trace_store)
PROJ3=$(make_plain_dir)
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS3"
    trace_id=$(init_trace "$PROJ3" "implementer" 2>/dev/null)
    jq -r '.agent_type // "not-set"' "${TS3}/${trace_id}/manifest.json" 2>/dev/null
)
if [[ "$output" == "implementer" ]]; then
    pass "agent_type 'implementer' → passes through as 'implementer'"
else
    fail "agent_type 'implementer' → expected 'implementer', got: '$output'"
fi

# ============================================================
# Test 4: Non-git directory emits branch="no-git"
# ============================================================
echo ""
echo "=== Test 4: Non-git directory → branch='no-git' ==="
TS4=$(make_trace_store)
PROJ4=$(make_plain_dir)
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS4"
    trace_id=$(init_trace "$PROJ4" "implementer" 2>/dev/null)
    jq -r '.branch // "not-set"' "${TS4}/${trace_id}/manifest.json" 2>/dev/null
)
if [[ "$output" == "no-git" ]]; then
    pass "Non-git directory → branch='no-git'"
else
    fail "Non-git directory → expected 'no-git', got: '$output'"
fi

# ============================================================
# Test 5: Real git repo emits actual branch name (not "unknown" or "no-git")
# ============================================================
echo ""
echo "=== Test 5: Git repo → branch shows actual branch name ==="
TS5=$(make_trace_store)
REPO5=$(make_git_repo)
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS5"
    trace_id=$(init_trace "$REPO5" "implementer" 2>/dev/null)
    jq -r '.branch // "not-set"' "${TS5}/${trace_id}/manifest.json" 2>/dev/null
)
if [[ "$output" != "no-git" && "$output" != "not-set" && -n "$output" ]]; then
    pass "Git repo → branch='$output' (actual branch name detected)"
else
    fail "Git repo → expected actual branch name, got: '$output'"
fi

# ============================================================
# Test 6: Stale .active-* marker (>2h old) is cleaned up
# ============================================================
echo ""
echo "=== Test 6: Stale .active-* marker (>2h old) is removed ==="
TS6=$(make_trace_store)
PROJ6=$(make_plain_dir)
# Create a stale marker file and backdate its mtime by 3 hours
stale_marker="${TS6}/.active-oldagent-stalesession"
echo "some-old-trace-id" > "$stale_marker"
# Set mtime to 3 hours ago using touch -t (macOS format: [[CC]YY]MMDDhhmm[.SS])
three_hours_ago=$(date -v-3H +%Y%m%d%H%M.%S 2>/dev/null || date -d "3 hours ago" +%Y%m%d%H%M.%S 2>/dev/null)
touch -t "${three_hours_ago}" "$stale_marker" 2>/dev/null
(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS6"
    init_trace "$PROJ6" "implementer" > /dev/null 2>&1
)
if [[ ! -f "$stale_marker" ]]; then
    pass "Stale .active-* marker (>2h) was removed by init_trace"
else
    fail "Stale .active-* marker (>2h) was NOT removed by init_trace"
fi

# ============================================================
# Test 7: Fresh .active-* marker (<2h old) is preserved
# ============================================================
echo ""
echo "=== Test 7: Fresh .active-* marker (<2h old) is preserved ==="
TS7=$(make_trace_store)
PROJ7=$(make_plain_dir)
# Create a fresh marker file with current mtime
fresh_marker="${TS7}/.active-freshagengt-freshsession"
echo "some-fresh-trace-id" > "$fresh_marker"
# Leave mtime as current (just created = fresh)
(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS7"
    init_trace "$PROJ7" "implementer" > /dev/null 2>&1
)
if [[ -f "$fresh_marker" ]]; then
    pass "Fresh .active-* marker (<2h) was preserved by init_trace"
else
    fail "Fresh .active-* marker (<2h) was incorrectly removed by init_trace"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [[ "$FAIL" -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "Some tests FAILED."
    exit 1
fi
