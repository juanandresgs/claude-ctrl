#!/usr/bin/env bash
# test-proof-dualwrite.sh — Tests for bug #81: proof-status path mismatch fix
#
# Bug: Direct writes to $PROOF_FILE in check-tester.sh and post-task.sh
#   only update one path (whichever resolve_proof_file() returned). This
#   causes the proof gate to get stuck when resolve_proof_file() returns
#   the new path but reads find the old path stale (or vice versa).
#
# Fix: Replace direct writes with write_proof_status() which dual-writes to
#   both state/{phash}/proof-status (new) and .proof-status-{phash} (old).
#
# Tests:
#   T01: write_proof_status("pending") dual-writes to both new and old paths
#   T02: write_proof_status("needs-verification") dual-writes to both paths
#   T03: resolve_proof_file() prefers new path when both exist
#   T04: check-tester.sh safety-net uses write_proof_status() (not direct echo)
#   T05: post-task.sh safety-net uses write_proof_status() (not direct echo)
#   T06: No direct echo "pending|" writes in check-tester.sh safety-net block
#   T07: No direct echo "needs-verification|" writes in post-task.sh safety-net block
#
# @decision DEC-TEST-PROOF-DUALWRITE-001
# @title Tests for proof-status dual-write fix (bug #81)
# @status accepted
# @rationale Validates that check-tester.sh and post-task.sh use write_proof_status()
#   in their safety-net blocks instead of direct echo writes to $PROOF_FILE.
#   T01-T03 exercise the write_proof_status function's dual-write behavior directly.
#   T04-T07 are static checks confirming the hook files contain the right call sites.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

_CLEANUP_DIRS=()
trap '[[ ${#_CLEANUP_DIRS[@]} -gt 0 ]] && rm -rf "${_CLEANUP_DIRS[@]}" 2>/dev/null; true' EXIT

pass_test() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS: ${CURRENT_TEST:-}"; }
fail_test() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: ${1:-${CURRENT_TEST:-}}"; }
run_test() { CURRENT_TEST="$1"; TOTAL_COUNT=$((TOTAL_COUNT + 1)); echo ""; echo "Running: $1"; }

make_temp_repo() {
    local d
    d=$(mktemp -d)
    _CLEANUP_DIRS+=("$d")
    git -C "$d" init --quiet 2>/dev/null
    mkdir -p "$d/.claude"
    echo "$d"
}

# Portable SHA-256
if command -v shasum >/dev/null 2>&1; then
    _SHA256_CMD="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
    _SHA256_CMD="sha256sum"
else
    _SHA256_CMD="cat"
fi

project_hash_for() {
    local root="$1"
    echo "$root" | ${_SHA256_CMD} | cut -c1-8
}

# ---------------------------------------------------------------------------
# T01: write_proof_status("pending") dual-writes to both new and old paths
# ---------------------------------------------------------------------------
run_test "T01: write_proof_status pending dual-writes both paths"
(
    REPO=$(make_temp_repo)
    PHASH=$(project_hash_for "$REPO")
    NEW_PATH="$REPO/.claude/state/${PHASH}/proof-status"
    OLD_PATH="$REPO/.claude/.proof-status-${PHASH}"

    export PROJECT_ROOT="$REPO"
    export CLAUDE_DIR="$REPO/.claude"
    export CLAUDE_PROJECT_DIR="$REPO"
    export CLAUDE_SESSION_ID="test-session-t01"
    export TRACE_STORE="$REPO/.claude/traces"

    # core-lib.sh must be sourced first — it defines _lock_fd used by write_proof_status
    source "$HOOKS_DIR/core-lib.sh" 2>/dev/null
    source "$HOOKS_DIR/log.sh" 2>/dev/null

    write_proof_status "pending" "$REPO" 2>/dev/null

    if [[ -f "$NEW_PATH" ]] && [[ -f "$OLD_PATH" ]]; then
        NEW_CONTENT=$(cut -d'|' -f1 "$NEW_PATH")
        OLD_CONTENT=$(cut -d'|' -f1 "$OLD_PATH")
        if [[ "$NEW_CONTENT" == "pending" && "$OLD_CONTENT" == "pending" ]]; then
            pass_test
        else
            fail_test "T01: new_path='$NEW_CONTENT' old_path='$OLD_CONTENT' (expected both 'pending')"
        fi
    else
        fail_test "T01: new_path exists=$([ -f "$NEW_PATH" ] && echo yes || echo no), old_path exists=$([ -f "$OLD_PATH" ] && echo yes || echo no)"
    fi
) || fail_test "T01: subshell error"

# ---------------------------------------------------------------------------
# T02: write_proof_status("needs-verification") dual-writes to both paths
# ---------------------------------------------------------------------------
run_test "T02: write_proof_status needs-verification dual-writes both paths"
(
    REPO=$(make_temp_repo)
    PHASH=$(project_hash_for "$REPO")
    NEW_PATH="$REPO/.claude/state/${PHASH}/proof-status"
    OLD_PATH="$REPO/.claude/.proof-status-${PHASH}"

    export PROJECT_ROOT="$REPO"
    export CLAUDE_DIR="$REPO/.claude"
    export CLAUDE_PROJECT_DIR="$REPO"
    export CLAUDE_SESSION_ID="test-session-t02"
    export TRACE_STORE="$REPO/.claude/traces"

    source "$HOOKS_DIR/core-lib.sh" 2>/dev/null
    source "$HOOKS_DIR/log.sh" 2>/dev/null

    write_proof_status "needs-verification" "$REPO" 2>/dev/null

    if [[ -f "$NEW_PATH" ]] && [[ -f "$OLD_PATH" ]]; then
        NEW_CONTENT=$(cut -d'|' -f1 "$NEW_PATH")
        OLD_CONTENT=$(cut -d'|' -f1 "$OLD_PATH")
        if [[ "$NEW_CONTENT" == "needs-verification" && "$OLD_CONTENT" == "needs-verification" ]]; then
            pass_test
        else
            fail_test "T02: new_path='$NEW_CONTENT' old_path='$OLD_CONTENT'"
        fi
    else
        fail_test "T02: new_path exists=$([ -f "$NEW_PATH" ] && echo yes || echo no), old_path exists=$([ -f "$OLD_PATH" ] && echo yes || echo no)"
    fi
) || fail_test "T02: subshell error"

# ---------------------------------------------------------------------------
# T03: resolve_proof_file() prefers new path when both exist
# ---------------------------------------------------------------------------
run_test "T03: resolve_proof_file prefers state/{phash}/proof-status over legacy path"
(
    REPO=$(make_temp_repo)
    PHASH=$(project_hash_for "$REPO")
    NEW_PATH="$REPO/.claude/state/${PHASH}/proof-status"
    OLD_PATH="$REPO/.claude/.proof-status-${PHASH}"

    export PROJECT_ROOT="$REPO"
    export CLAUDE_DIR="$REPO/.claude"
    export CLAUDE_PROJECT_DIR="$REPO"
    export CLAUDE_SESSION_ID="test-session-t03"
    export TRACE_STORE="$REPO/.claude/traces"

    source "$HOOKS_DIR/core-lib.sh" 2>/dev/null
    source "$HOOKS_DIR/log.sh" 2>/dev/null

    # Create both paths — new has verified, old has needs-verification
    mkdir -p "$(dirname "$NEW_PATH")"
    echo "verified|$(date +%s)" > "$NEW_PATH"
    echo "needs-verification|$(date +%s)" > "$OLD_PATH"

    RESOLVED=$(resolve_proof_file 2>/dev/null)
    if [[ "$RESOLVED" == "$NEW_PATH" ]]; then
        pass_test
    else
        fail_test "T03: resolved='$RESOLVED' expected='$NEW_PATH'"
    fi
) || fail_test "T03: subshell error"

# ---------------------------------------------------------------------------
# T04: check-tester.sh safety-net uses write_proof_status("pending")
# ---------------------------------------------------------------------------
run_test "T04: check-tester.sh safety-net uses write_proof_status()"
CHECK_TESTER="$HOOKS_DIR/check-tester.sh"
if grep -q 'write_proof_status "pending"' "$CHECK_TESTER"; then
    pass_test
else
    fail_test "T04: write_proof_status not found in check-tester.sh"
fi

# ---------------------------------------------------------------------------
# T05: post-task.sh safety-net uses write_proof_status("needs-verification")
# ---------------------------------------------------------------------------
run_test "T05: post-task.sh safety-net uses write_proof_status()"
POST_TASK="$HOOKS_DIR/post-task.sh"
if grep -q 'write_proof_status "needs-verification"' "$POST_TASK"; then
    pass_test
else
    fail_test "T05: write_proof_status not found in post-task.sh"
fi

# ---------------------------------------------------------------------------
# T06: No direct echo "pending|" safety-net writes remain in check-tester.sh
# ---------------------------------------------------------------------------
run_test "T06: check-tester.sh has no direct echo pending| writes"
DIRECT_WRITE_COUNT=$(grep -c 'echo "pending|' "$CHECK_TESTER" 2>/dev/null || true)
if [[ "$DIRECT_WRITE_COUNT" -eq 0 ]]; then
    pass_test
else
    fail_test "T06: Found $DIRECT_WRITE_COUNT direct 'echo pending|' writes in check-tester.sh"
fi

# ---------------------------------------------------------------------------
# T07: No direct echo "needs-verification|" safety-net writes remain in post-task.sh
# ---------------------------------------------------------------------------
run_test "T07: post-task.sh has no direct echo needs-verification| writes"
DIRECT_WRITE_COUNT=$(grep -c 'echo "needs-verification|' "$POST_TASK" 2>/dev/null || true)
if [[ "$DIRECT_WRITE_COUNT" -eq 0 ]]; then
    pass_test
else
    fail_test "T07: Found $DIRECT_WRITE_COUNT direct 'echo needs-verification|' writes in post-task.sh"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=============================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $TOTAL_COUNT tests"
echo "=============================="

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
