#!/usr/bin/env bash
# test-subagent-tracker-scope.sh — Tests for per-session subagent tracker scoping
#
# Purpose: Verify that track_subagent_start, track_subagent_stop, and
#   get_subagent_status operate on session-scoped tracker files
#   (.subagent-tracker-<SESSION_ID>) rather than a single global file.
#
# Issue: #73 — Scope subagent statusline tracking to per-session thread
#
# @decision DEC-SUBAGENT-002
# @title Session-scoped subagent tracker files
# @status accepted
# @rationale A global .subagent-tracker file accumulates stale ACTIVE records
#   across sessions if a session crashes without cleanup. Scoping to
#   .subagent-tracker-${CLAUDE_SESSION_ID:-$$} eliminates phantom agent counts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT_LIB="${SCRIPT_DIR}/../hooks/context-lib.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass_test() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}PASS${NC} $1"
}

fail_test() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}FAIL${NC} $1"
    echo -e "  ${YELLOW}Details:${NC} $2"
}

run_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
}

# Setup: create an isolated temp directory simulating a project root.
# The functions expect $root to be the project root and will use $root/.claude/
setup_test_env() {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    echo "$tmpdir"
}

cleanup_test_env() {
    local tmpdir="$1"
    rm -rf "$tmpdir"
}

# Source context-lib functions into current shell
# We use a subshell technique: source the lib and call functions directly.
# context-lib.sh has dependencies (log.sh), so we provide a stub.
source_context_lib() {
    # Provide minimal stubs for dependencies that context-lib sources
    # context-lib.sh sources log.sh — we need log functions available
    log_info() { :; }
    log_warn() { :; }
    log_error() { :; }
    log_debug() { :; }
    get_claude_dir() { echo "${HOME}/.claude"; }
    detect_project_root() { echo "${HOME}"; }

    # Source context-lib with stubs in place
    # shellcheck disable=SC1090
    source "$CONTEXT_LIB" 2>/dev/null || {
        echo "ERROR: Could not source $CONTEXT_LIB" >&2
        exit 1
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: track_subagent_start creates a SESSION-SCOPED file, not the global one
# ─────────────────────────────────────────────────────────────────────────────
test_start_creates_session_scoped_file() {
    run_test
    local tmpdir
    tmpdir=$(setup_test_env)
    local session_id="test-session-001"

    (
        source_context_lib
        CLAUDE_SESSION_ID="$session_id" track_subagent_start "$tmpdir" "implementer"
    )

    local expected_file="${tmpdir}/.claude/.subagent-tracker-${session_id}"
    local global_file="${tmpdir}/.claude/.subagent-tracker"

    if [[ -f "$expected_file" ]]; then
        pass_test "track_subagent_start creates session-scoped tracker file"
    else
        fail_test "track_subagent_start creates session-scoped tracker file" \
            "Expected '$expected_file' to exist, but it doesn't"
    fi

    if [[ ! -f "$global_file" ]]; then
        pass_test "track_subagent_start does NOT create global tracker file"
    else
        fail_test "track_subagent_start does NOT create global tracker file" \
            "Global file '$global_file' was created but should not exist"
    fi

    cleanup_test_env "$tmpdir"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: track_subagent_start writes ACTIVE record to session-scoped file
# ─────────────────────────────────────────────────────────────────────────────
test_start_writes_active_record() {
    run_test
    local tmpdir
    tmpdir=$(setup_test_env)
    local session_id="test-session-002"

    (
        source_context_lib
        CLAUDE_SESSION_ID="$session_id" track_subagent_start "$tmpdir" "planner"
    )

    local tracker="${tmpdir}/.claude/.subagent-tracker-${session_id}"
    if [[ -f "$tracker" ]] && grep -q "^ACTIVE|planner|" "$tracker"; then
        pass_test "track_subagent_start writes ACTIVE record with agent type"
    else
        fail_test "track_subagent_start writes ACTIVE record with agent type" \
            "File: $(cat "$tracker" 2>/dev/null || echo 'missing')"
    fi

    cleanup_test_env "$tmpdir"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: get_subagent_status reads from session-scoped file
# ─────────────────────────────────────────────────────────────────────────────
test_get_status_reads_session_scoped_file() {
    run_test
    local tmpdir
    tmpdir=$(setup_test_env)
    local session_id="test-session-003"

    # Pre-populate the session-scoped tracker with 2 active agents
    local tracker="${tmpdir}/.claude/.subagent-tracker-${session_id}"
    echo "ACTIVE|implementer|$(date +%s)" > "$tracker"
    echo "ACTIVE|tester|$(date +%s)" >> "$tracker"

    local count
    count=$(
        source_context_lib
        CLAUDE_SESSION_ID="$session_id" get_subagent_status "$tmpdir"
        echo "$SUBAGENT_ACTIVE_COUNT"
    )

    if [[ "$count" == "2" ]]; then
        pass_test "get_subagent_status reads count from session-scoped file (got $count)"
    else
        fail_test "get_subagent_status reads count from session-scoped file" \
            "Expected 2, got '$count'"
    fi

    cleanup_test_env "$tmpdir"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: get_subagent_status returns 0 when NO session-scoped file exists
# ─────────────────────────────────────────────────────────────────────────────
test_get_status_zero_when_no_file() {
    run_test
    local tmpdir
    tmpdir=$(setup_test_env)
    local session_id="test-session-004"

    # Do NOT create any tracker file — simulates a fresh session

    local count
    count=$(
        source_context_lib
        CLAUDE_SESSION_ID="$session_id" get_subagent_status "$tmpdir"
        echo "$SUBAGENT_ACTIVE_COUNT"
    )

    if [[ "$count" == "0" ]]; then
        pass_test "get_subagent_status returns 0 when no tracker file exists"
    else
        fail_test "get_subagent_status returns 0 when no tracker file exists" \
            "Expected 0, got '$count'"
    fi

    cleanup_test_env "$tmpdir"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: Different session IDs produce different tracker files
# ─────────────────────────────────────────────────────────────────────────────
test_different_sessions_use_different_files() {
    run_test
    local tmpdir
    tmpdir=$(setup_test_env)

    (
        source_context_lib
        CLAUDE_SESSION_ID="session-A" track_subagent_start "$tmpdir" "implementer"
        CLAUDE_SESSION_ID="session-B" track_subagent_start "$tmpdir" "tester"
    )

    local file_a="${tmpdir}/.claude/.subagent-tracker-session-A"
    local file_b="${tmpdir}/.claude/.subagent-tracker-session-B"

    if [[ -f "$file_a" && -f "$file_b" ]]; then
        pass_test "Different session IDs produce separate tracker files"
    else
        fail_test "Different session IDs produce separate tracker files" \
            "file-A exists: $(test -f "$file_a" && echo yes || echo no), file-B exists: $(test -f "$file_b" && echo yes || echo no)"
    fi

    # Verify session A's file only has implementer, not tester
    if grep -q "^ACTIVE|implementer|" "$file_a" && ! grep -q "^ACTIVE|tester|" "$file_a"; then
        pass_test "Session A's tracker only contains session A's agent"
    else
        fail_test "Session A's tracker only contains session A's agent" \
            "file-A contents: $(cat "$file_a" 2>/dev/null)"
    fi

    cleanup_test_env "$tmpdir"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: track_subagent_stop removes ACTIVE record from session-scoped file
# ─────────────────────────────────────────────────────────────────────────────
test_stop_removes_from_session_scoped_file() {
    run_test
    local tmpdir
    tmpdir=$(setup_test_env)
    local session_id="test-session-006"

    (
        source_context_lib
        CLAUDE_SESSION_ID="$session_id" track_subagent_start "$tmpdir" "guardian"
        CLAUDE_SESSION_ID="$session_id" track_subagent_stop "$tmpdir" "guardian"
    )

    local tracker="${tmpdir}/.claude/.subagent-tracker-${session_id}"

    # After stop, no ACTIVE records should remain for guardian
    if [[ ! -f "$tracker" ]] || ! grep -q "^ACTIVE|guardian|" "$tracker"; then
        pass_test "track_subagent_stop removes ACTIVE record from session-scoped file"
    else
        fail_test "track_subagent_stop removes ACTIVE record from session-scoped file" \
            "File still contains ACTIVE guardian: $(cat "$tracker" 2>/dev/null)"
    fi

    cleanup_test_env "$tmpdir"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: Fallback to PID when CLAUDE_SESSION_ID is unset
# ─────────────────────────────────────────────────────────────────────────────
test_fallback_to_pid_when_session_id_unset() {
    run_test
    local tmpdir
    tmpdir=$(setup_test_env)

    local subshell_pid
    subshell_pid=$(
        unset CLAUDE_SESSION_ID
        source_context_lib
        track_subagent_start "$tmpdir" "planner"
        echo "$$"
    )

    # When CLAUDE_SESSION_ID is unset, fallback is $$ (PID of that subshell)
    # We just verify that SOME session-scoped file was created (not the bare global)
    local global_file="${tmpdir}/.claude/.subagent-tracker"
    local has_session_scoped
    has_session_scoped=$(ls "${tmpdir}/.claude/.subagent-tracker-"* 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$has_session_scoped" -gt 0 && ! -f "$global_file" ]]; then
        pass_test "Falls back to PID suffix when CLAUDE_SESSION_ID is unset (no bare global file)"
    else
        fail_test "Falls back to PID suffix when CLAUDE_SESSION_ID is unset" \
            "global exists: $(test -f "$global_file" && echo yes || echo no), session-scoped count: $has_session_scoped"
    fi

    cleanup_test_env "$tmpdir"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 8: gitignore pattern matches session-scoped tracker files
# ─────────────────────────────────────────────────────────────────────────────
test_gitignore_matches_session_scoped_files() {
    run_test
    local gitignore="${SCRIPT_DIR}/../.gitignore"

    if [[ ! -f "$gitignore" ]]; then
        fail_test "gitignore pattern matches session-scoped files" \
            ".gitignore not found at $gitignore"
        return
    fi

    # Use git check-ignore on a synthetic path to verify the pattern matches
    local test_path=".subagent-tracker-abc123-session"
    local repo_root="${SCRIPT_DIR}/.."

    # git check-ignore exits 0 if matched, 1 if not matched
    if git -C "$repo_root" check-ignore -q "$test_path" 2>/dev/null; then
        pass_test "gitignore pattern matches .subagent-tracker-<session_id> files"
    else
        fail_test "gitignore pattern matches .subagent-tracker-<session_id> files" \
            "Pattern in .gitignore does not match '$test_path'. Check .gitignore for '.subagent-tracker*'"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
main() {
    echo "=== Subagent Tracker Scope Tests (Issue #73) ==="
    echo ""

    test_start_creates_session_scoped_file
    test_start_writes_active_record
    test_get_status_reads_session_scoped_file
    test_get_status_zero_when_no_file
    test_different_sessions_use_different_files
    test_stop_removes_from_session_scoped_file
    test_fallback_to_pid_when_session_id_unset
    test_gitignore_matches_session_scoped_files

    echo ""
    echo "=== Results ==="
    echo "Total:  $TESTS_RUN"
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"

    if [[ "$TESTS_FAILED" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
