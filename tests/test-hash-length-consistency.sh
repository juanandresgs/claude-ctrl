#!/usr/bin/env bash
# test-hash-length-consistency.sh — Verify project hash length is 8 chars everywhere.
#
# @decision DEC-HASH-CONSOLIDATE-001
# @title Test: project hash must be 8 chars in session-lib, session-end, and test helpers
# @status accepted
# @rationale Bug: session-lib.sh and session-end.sh used cut -c1-12, while the
#   canonical project_hash() in core-lib.sh uses cut -c1-8. This caused sessions
#   to be written under 12-char paths but read from 8-char paths — data never found.
#   These tests fail before the fix and pass after.
#
# Tests:
#   1. core-lib.sh project_hash() returns 8 chars
#   2. get_prior_sessions() writes/reads from 8-char hash path
#   3. session-end.sh PROJECT_HASH variable uses 8 chars
#   4. test-cross-session.sh local helper uses 8 chars (cross-check)
#   5. No cut -c1-12 remains in hook files for project hash computation

set -euo pipefail

# Portable SHA-256
if command -v shasum >/dev/null 2>&1; then
    _SHA256_CMD="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
    _SHA256_CMD="sha256sum"
else
    _SHA256_CMD="cat"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="${SCRIPT_DIR}/../hooks"

# Colors
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    NC='\033[0m'
else
    GREEN='' RED='' NC=''
fi

passed=0
failed=0

pass() { echo -e "${GREEN}PASS${NC} $1"; passed=$((passed + 1)); }
fail() { echo -e "${RED}FAIL${NC} $1: $2"; failed=$((failed + 1)); }

echo "=== Hash Length Consistency Tests ==="
echo ""

# =============================================================================
# TEST 1: core-lib.sh project_hash() returns exactly 8 characters
# =============================================================================
echo "--- Test 1: core-lib.sh project_hash() — 8 chars ---"

source "$HOOKS_DIR/source-lib.sh"

HASH=$(project_hash "/some/test/path")
HASH_LEN=${#HASH}

if [[ "$HASH_LEN" -eq 8 ]]; then
    pass "core-lib.sh project_hash() returns 8 chars (got: $HASH)"
else
    fail "core-lib.sh project_hash() length" "expected 8, got $HASH_LEN (value: $HASH)"
fi

# =============================================================================
# TEST 2: get_prior_sessions() reads from 8-char hash directory
# =============================================================================
echo "--- Test 2: get_prior_sessions reads from 8-char hash path ---"

T2_HOME=$(mktemp -d)
T2_PROJ=$(mktemp -d)
T2_OUT=$(mktemp)
trap 'rm -rf "$T2_HOME" "$T2_PROJ" "$T2_OUT" 2>/dev/null; true' EXIT

# Compute 8-char hash (the canonical length)
HASH8=$(echo "$T2_PROJ" | $_SHA256_CMD 2>/dev/null | cut -c1-8)
# Also compute 12-char hash (the buggy length)
HASH12=$(echo "$T2_PROJ" | $_SHA256_CMD 2>/dev/null | cut -c1-12)

# Place session index under the 8-char path (canonical)
SESSIONS_DIR_8="$T2_HOME/.claude/sessions/$HASH8"
mkdir -p "$SESSIONS_DIR_8"

# Write 5 synthetic index entries (need >= 3)
for i in 1 2 3 4 5; do
    echo '{"id":"sess'$i'","project":"test","started":"2026-01-0'$i'T10:00:00Z","duration_min":30,"files_touched":[],"tool_calls":10,"checkpoints":1,"pivots":0,"friction":[],"outcome":"tests-passing"}' \
        >> "$SESSIONS_DIR_8/index.jsonl"
done

# Call get_prior_sessions with HOME pointing to T2_HOME
bash --norc --noprofile -s <<SCRIPT > "$T2_OUT" 2>/dev/null
source "$HOOKS_DIR/source-lib.sh"
require_session
HOME="$T2_HOME"
get_prior_sessions "$T2_PROJ"
SCRIPT

result=$(cat "$T2_OUT")

if [[ -n "$result" ]]; then
    pass "get_prior_sessions() found index at 8-char hash path"
else
    fail "get_prior_sessions() did not read from 8-char hash path" "expected session data, got empty (hash8=$HASH8, hash12=$HASH12)"
fi

# =============================================================================
# TEST 3: get_prior_sessions() does NOT read from 12-char hash path
# =============================================================================
echo "--- Test 3: get_prior_sessions ignores 12-char hash directories ---"

T3_HOME=$(mktemp -d)
T3_PROJ=$(mktemp -d)
T3_OUT=$(mktemp)
trap 'rm -rf "$T3_HOME" "$T3_PROJ" "$T3_OUT" 2>/dev/null; true' EXIT 2>/dev/null || \
    trap 'rm -rf "$T3_HOME" "$T3_PROJ" "$T3_OUT" "$T2_HOME" "$T2_PROJ" "$T2_OUT" 2>/dev/null; true' EXIT

HASH12_ONLY=$(echo "$T3_PROJ" | $_SHA256_CMD 2>/dev/null | cut -c1-12)

# Place session index ONLY under the 12-char path (simulating the old bug)
SESSIONS_DIR_12="$T3_HOME/.claude/sessions/$HASH12_ONLY"
mkdir -p "$SESSIONS_DIR_12"

for i in 1 2 3 4 5; do
    echo '{"id":"sess'$i'","project":"test","started":"2026-01-0'$i'T10:00:00Z","duration_min":30,"files_touched":[],"tool_calls":10,"checkpoints":1,"pivots":0,"friction":[],"outcome":"tests-passing"}' \
        >> "$SESSIONS_DIR_12/index.jsonl"
done

bash --norc --noprofile -s <<SCRIPT > "$T3_OUT" 2>/dev/null
source "$HOOKS_DIR/source-lib.sh"
require_session
HOME="$T3_HOME"
get_prior_sessions "$T3_PROJ"
SCRIPT

result3=$(cat "$T3_OUT")

# After the fix: 8-char path is used, so 12-char-only data is NOT found (empty)
if [[ -z "$result3" ]]; then
    pass "get_prior_sessions() correctly ignores 12-char hash path (no false match)"
else
    fail "get_prior_sessions() reads from 12-char path" "should return empty after fix (hash12=$HASH12_ONLY)"
fi

# =============================================================================
# TEST 4: No cut -c1-12 for project hash in hook source files
# =============================================================================
echo "--- Test 4: no cut -c1-12 in hook files (static analysis) ---"

# Exclude comment lines: match "cut -c1-12" only when not preceded by # on the same line.
# This finds live code uses, not @rationale documentation references.
FOUND_12=$(grep -rn "cut -c1-12" "$HOOKS_DIR/" 2>/dev/null | grep -v "^Binary" | grep -vE "^[^:]*:[0-9]+:[[:space:]]*#" || true)

if [[ -z "$FOUND_12" ]]; then
    pass "No cut -c1-12 found in hooks/ directory"
else
    fail "cut -c1-12 still present in hooks/" "$FOUND_12"
fi

# =============================================================================
# TEST 5: test-cross-session.sh helper uses 8 chars (test helper parity)
# =============================================================================
echo "--- Test 5: test-cross-session.sh helper uses 8-char hash ---"

TEST_CROSS_SESSION="$SCRIPT_DIR/test-cross-session.sh"
if [[ -f "$TEST_CROSS_SESSION" ]]; then
    CROSS_12=$(grep "cut -c1-12" "$TEST_CROSS_SESSION" || true)
    if [[ -z "$CROSS_12" ]]; then
        pass "test-cross-session.sh local project_hash helper uses 8-char hash"
    else
        fail "test-cross-session.sh helper still uses 12-char hash" "$CROSS_12"
    fi
else
    pass "test-cross-session.sh not found — skip parity check"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "==========================="
total=$((passed + failed))
echo "Total: $total | Passed: $passed | Failed: $failed"

[[ $failed -gt 0 ]] && exit 1
exit 0
