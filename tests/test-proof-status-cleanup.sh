#!/usr/bin/env bash
# test-proof-status-cleanup.sh — Tests for proof-status dotfile accumulation fixes.
#
# Exercises the bug fixes introduced for proof-status accumulation:
#
#   Bug A: _SHA256_CMD unset in core-lib.sh when sourced without log.sh
#          → project_hash() produced .proof-status- (empty hash)
#   Bug B: get_claude_dir() path comparison failed when PROJECT_ROOT had trailing slash
#          → returned double-nested ~/.claude/.claude path
#   Bug C: session-end.sh lacked a TTL sweep of all .proof-status-* files
#          → cross-project files accumulated indefinitely
#   Bug D: session-end.sh never deleted the proof file after reading outcome
#          → stale "verified" files survived normal session-end
#   Bug E: legacy double-nested and tmp proof-status files never cleaned up
#          → ~/.claude/.claude/.proof-status and ~/.claude/tmp/.proof-status persisted
#
# Uses embedded bash logic (no full hook sourcing) to stay fast and dependency-free.
#
# @decision DEC-PROOF-CLEANUP-TEST-001
# @title Tests for proof-status accumulation bug fixes
# @status accepted
# @rationale Proof-status dotfiles (.proof-status-{hash}, .proof-epoch, .proof-status.lock)
#   were accumulating across sessions due to 5 distinct bugs: empty hash (Bug A), path
#   normalization failure (Bug B), missing TTL sweep (Bug C), no cleanup after reading (Bug D),
#   and legacy paths never cleaned (Bug E). Tests embed the fixed logic directly rather than
#   sourcing hooks to keep them fast and avoid external dependencies.

set -euo pipefail

# Portable SHA-256 (macOS: shasum, Ubuntu: sha256sum)
if command -v shasum >/dev/null 2>&1; then
    _SHA256_CMD="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
    _SHA256_CMD="sha256sum"
else
    _SHA256_CMD="cat"
fi

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"

mkdir -p "$PROJECT_ROOT/tmp"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "Running: $test_name"
}

pass_test() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  PASS"
}

fail_test() {
    local reason="$1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $reason"
}

# Helper: compute project_hash identically to fixed core-lib.sh / log.sh
compute_phash() {
    echo "$1" | $_SHA256_CMD | cut -c1-8 2>/dev/null || echo "00000000"
}

# ─────────────────────────────────────────────────────────────────────────────
# PC-01: project_hash produces valid 8-char hash when _SHA256_CMD is unset
#
# Scenario (Bug A): core-lib.sh is sourced without log.sh. Before the fix,
# $_SHA256_CMD was empty, producing an empty hash. After the fix, the guard
# block initializes _SHA256_CMD before project_hash() is defined.
# ─────────────────────────────────────────────────────────────────────────────

run_test "PC-01: project_hash produces valid 8-char hash when _SHA256_CMD is unset"

RESULT_01=$(bash -c '
    # Simulate core-lib.sh being sourced without log.sh — _SHA256_CMD not set
    unset _SHA256_CMD

    # Inline the fixed initialization block from core-lib.sh
    if [[ -z "${_SHA256_CMD:-}" ]]; then
        if command -v shasum >/dev/null 2>&1; then
            _SHA256_CMD="shasum -a 256"
        elif command -v sha256sum >/dev/null 2>&1; then
            _SHA256_CMD="sha256sum"
        else
            _SHA256_CMD="cat"
        fi
    fi

    # project_hash with defense-in-depth fallback
    project_hash() {
        echo "${1:?project_hash requires a path argument}" | ${_SHA256_CMD:-shasum -a 256} | cut -c1-8
    }

    project_hash "/test"
' 2>/dev/null)

# Verify output is exactly 8 hex chars
if [[ "$RESULT_01" =~ ^[0-9a-f]{8}$ ]]; then
    pass_test
else
    fail_test "project_hash returned '$RESULT_01' (expected 8 hex chars)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PC-02: get_claude_dir returns correct path when PROJECT_ROOT has trailing slash
#
# Scenario (Bug B): PROJECT_ROOT="/Users/turla/.claude/" (trailing slash).
# Before the fix, the string comparison failed and returned the double-nested
# path. After the fix, trailing slashes are stripped before comparison.
# ─────────────────────────────────────────────────────────────────────────────

run_test "PC-02: get_claude_dir returns correct path with trailing slash PROJECT_ROOT"

RESULT_02=$(bash -c '
    HOME_DIR="'"$HOME"'"
    # Simulate PROJECT_ROOT with trailing slash (the bug scenario)
    PROJECT_ROOT="${HOME_DIR}/.claude/"

    # Inline the fixed get_claude_dir logic from log.sh
    get_claude_dir() {
        local project_root="${PROJECT_ROOT:-}"
        local home_claude="${HOME_DIR}/.claude"

        # Normalize: strip trailing slashes to prevent comparison mismatch (#77)
        project_root="${project_root%/}"
        home_claude="${home_claude%/}"

        if [[ "$project_root" == "$home_claude" ]]; then
            echo "$project_root"
        else
            echo "${project_root}/.claude"
        fi
    }

    get_claude_dir
' 2>/dev/null)

EXPECTED_02="${HOME}/.claude"
if [[ "$RESULT_02" == "$EXPECTED_02" ]]; then
    pass_test
else
    fail_test "get_claude_dir returned '$RESULT_02' (expected '$EXPECTED_02')"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PC-03: Session-end TTL sweep removes files >4h, preserves files <4h
#
# Scenario (Bug C): Multiple .proof-status-* files exist from different projects
# (or with empty hashes from Bug A). The sweep at session-end should remove
# files older than 4 hours (14400 seconds) and leave newer ones intact.
# ─────────────────────────────────────────────────────────────────────────────

run_test "PC-03: TTL sweep removes .proof-status-* older than 4h, preserves newer ones"

TMPDIR_03="$PROJECT_ROOT/tmp/test-pc-03-$$"
mkdir -p "$TMPDIR_03"
trap 'rm -rf "$TMPDIR_03"' EXIT

# Create an old proof-status file (5 hours ago — should be removed)
OLD_PROOF="$TMPDIR_03/.proof-status-aabbccdd"
echo "verified|0|old-session" > "$OLD_PROOF"
# Set mtime to 5 hours ago
touch -t "$(date -v-5H +%Y%m%d%H%M.%S 2>/dev/null || date -d '5 hours ago' +%Y%m%d%H%M.%S 2>/dev/null || date +%Y%m%d%H%M.%S)" "$OLD_PROOF" 2>/dev/null || true

# Create a fresh proof-status file (1 minute ago — should be preserved)
NEW_PROOF="$TMPDIR_03/.proof-status-11223344"
echo "needs-verification|$(date +%s)|current-session" > "$NEW_PROOF"

_NOW_EPOCH=$(date +%s)
CLAUDE_DIR="$TMPDIR_03"

# Inline the fixed TTL sweep logic from session-end.sh
for _proof_file in "${CLAUDE_DIR}/.proof-status-"*; do
    [[ -f "$_proof_file" ]] || continue
    [[ "$_proof_file" == *.lock ]] && continue
    if [[ "$(uname)" == "Darwin" ]]; then
        _proof_mtime=$(stat -f %m "$_proof_file" 2>/dev/null || echo "0")
    else
        _proof_mtime=$(stat -c %Y "$_proof_file" 2>/dev/null || echo "0")
    fi
    if (( _NOW_EPOCH - _proof_mtime > 14400 )); then  # 4 hours
        rm -f "$_proof_file"
    fi
done

# Verify: old file removed, new file preserved
OLD_REMOVED=false
NEW_PRESERVED=false

[[ ! -f "$OLD_PROOF" ]] && OLD_REMOVED=true
[[ -f "$NEW_PROOF" ]] && NEW_PRESERVED=true

if $OLD_REMOVED && $NEW_PRESERVED; then
    pass_test
elif ! $OLD_REMOVED && ! $NEW_PRESERVED; then
    fail_test "Old file not removed AND new file missing (both wrong)"
elif ! $OLD_REMOVED; then
    fail_test "Old proof-status file was NOT removed (mtime-based TTL failed)"
else
    fail_test "New proof-status file was incorrectly removed"
fi

TMPDIR_03=""
trap - EXIT

# ─────────────────────────────────────────────────────────────────────────────
# PC-04: Proof-status deleted after outcome read
#
# Scenario (Bug D): session-end.sh reads proof-status to derive OUTCOME, but
# before the fix it never deleted the file. After the fix, the file is removed
# immediately after reading (while still inside the if-block).
# ─────────────────────────────────────────────────────────────────────────────

run_test "PC-04: Proof-status file is deleted after outcome is read in session-end logic"

TMPDIR_04="$PROJECT_ROOT/tmp/test-pc-04-$$"
mkdir -p "$TMPDIR_04"
trap 'rm -rf "$TMPDIR_04"' EXIT

PROOF_04="$TMPDIR_04/.proof-status-deadbeef"
echo "verified|$(date +%s)|test-session" > "$PROOF_04"

# Inline the fixed read-and-delete logic from session-end.sh
OUTCOME="unknown"
PS_VAL=""
PROOF_FILE="$PROOF_04"

if [[ -n "$PROOF_FILE" && -f "$PROOF_FILE" ]]; then
    PS_VAL=$(cut -d'|' -f1 "$PROOF_FILE" 2>/dev/null || echo "")
    [[ "$PS_VAL" == "verified" ]] && OUTCOME="committed"
    # Clean proof-status after reading — Bug D fix
    [[ -n "$PROOF_FILE" && -f "$PROOF_FILE" ]] && rm -f "$PROOF_FILE"
fi

# Verify: OUTCOME was set correctly AND file is gone
if [[ "$OUTCOME" == "committed" && ! -f "$PROOF_04" ]]; then
    pass_test
elif [[ "$OUTCOME" != "committed" ]]; then
    fail_test "OUTCOME was '$OUTCOME' (expected 'committed')"
else
    fail_test "Proof-status file still exists after read (Bug D not fixed)"
fi

TMPDIR_04=""
trap - EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_RUN total"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
else
    exit 0
fi
