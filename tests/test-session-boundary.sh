#!/usr/bin/env bash
# test-session-boundary.sh — Session boundary proof-status cleanup tests.
#
# Exercises the cleanup logic from session-init.sh lines 573-612 which removes
# stale proof-status files when no current-session agents are active. The full
# hook cannot be run in isolation (it has many external dependencies), so this
# test embeds the extracted cleanup logic directly and runs it against mock state.
#
# Logic under test (extracted from session-init.sh DEC-SESSION-INIT-PROOF-CLEAN-001):
#
#   _PHASH=$(project_hash "$PROJECT_ROOT")
#   _CURRENT_SID="${CLAUDE_SESSION_ID:-}"
#   if [[ -n "$_CURRENT_SID" ]]; then
#     ACTIVE_MARKERS=$(ls "$TRACE_STORE"/.active-*-"${_CURRENT_SID}-${_PHASH}" 2>/dev/null | wc -l | tr -d ' \n' || true)
#   else
#     ACTIVE_MARKERS=$(ls "$TRACE_STORE"/.active-*-"${_PHASH}" 2>/dev/null | wc -l | tr -d ' \n' || true)
#   fi
#   for PROOF_FILE in "${CLAUDE_DIR}/.proof-status-${_PHASH}" "${CLAUDE_DIR}/.proof-status"; do
#     if [[ -f "$PROOF_FILE" ]]; then
#       if [[ "$ACTIVE_MARKERS" -eq 0 ]]; then
#         rm -f "$PROOF_FILE"
#       fi
#     fi
#   done
#
# @decision DEC-STATE-SESSION-BOUNDARY-001
# @title Session boundary proof cleanup tests
# @status accepted
# @rationale session-init.sh cleanup prevents cross-session contamination from
#   stale "verified" or "pending" proof files. If a session crashes before Guardian
#   commits, the proof-status is left as "verified" — at the next session start,
#   the cleanup logic detects no active markers and removes it. Tests verify the
#   session-scoping (only current-session markers count) and project-scoping
#   (only this project's hash) work correctly. Embedding the logic directly rather
#   than invoking the full hook keeps tests fast and free of hook-layer side-effects.

set -euo pipefail

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

# Helper: compute project_hash identically to core-lib.sh / log.sh
compute_phash() {
    echo "$1" | shasum -a 256 | cut -c1-8 2>/dev/null || echo "00000000"
}

# Helper: run the session-init proof-cleanup logic in an isolated subshell.
#
# Arguments:
#   $1 = PROJECT_ROOT path (used to compute phash)
#   $2 = CLAUDE_DIR path   (where .proof-status files live)
#   $3 = TRACE_STORE path  (where .active-* markers live)
#   $4 = CLAUDE_SESSION_ID value (empty string means "no session ID")
#
# Returns:
#   stdout = lines describing removed files (one per removed proof file)
#   exit 0 always (errors are internal)
run_cleanup_logic() {
    local project_root="$1"
    local claude_dir="$2"
    local trace_store="$3"
    local session_id="$4"

    bash -c "
        set -euo pipefail

        # Inline project_hash (same as core-lib.sh/log.sh)
        project_hash() {
            echo \"\${1:?project_hash requires a path}\" | shasum -a 256 | cut -c1-8
        }

        PROJECT_ROOT='$project_root'
        CLAUDE_DIR='$claude_dir'
        TRACE_STORE='$trace_store'
        CLAUDE_SESSION_ID='$session_id'

        _PHASH=\$(project_hash \"\$PROJECT_ROOT\")

        _CURRENT_SID=\"\${CLAUDE_SESSION_ID:-}\"
        if [[ -n \"\$_CURRENT_SID\" ]]; then
            ACTIVE_MARKERS=\$(ls \"\$TRACE_STORE\"/.active-*-\"\${_CURRENT_SID}-\${_PHASH}\" 2>/dev/null | wc -l | tr -d ' \\n' || true)
            ACTIVE_MARKERS=\"\${ACTIVE_MARKERS:-0}\"
        else
            ACTIVE_MARKERS=\$(ls \"\$TRACE_STORE\"/.active-*-\"\${_PHASH}\" 2>/dev/null | wc -l | tr -d ' \\n' || true)
            ACTIVE_MARKERS=\"\${ACTIVE_MARKERS:-0}\"
        fi

        for PROOF_FILE in \"\${CLAUDE_DIR}/.proof-status-\${_PHASH}\" \"\${CLAUDE_DIR}/.proof-status\"; do
            if [[ -f \"\$PROOF_FILE\" ]]; then
                if [[ \"\$ACTIVE_MARKERS\" -eq 0 ]]; then
                    PROOF_VAL=\$(cut -d'|' -f1 \"\$PROOF_FILE\" 2>/dev/null || echo '')
                    rm -f \"\$PROOF_FILE\"
                    echo \"Cleaned \$(basename \"\$PROOF_FILE\") (\$PROOF_VAL) — no active markers\"
                fi
            fi
        done
    " 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# SB-01: Stale proof-status + no active markers → removed on session init
#
# Scenario: A previous session crashed with proof-status="verified". At the next
# session start, CLAUDE_SESSION_ID is set to a new session, no .active-* markers
# exist for the current session → proof file is removed.
# ─────────────────────────────────────────────────────────────────────────────

run_test "SB-01: Stale proof + no active markers → removed at session boundary"

TMPDIR_01="$PROJECT_ROOT/tmp/test-sb-01-$$"
MOCK_PROJECT="$TMPDIR_01/project"
MOCK_CLAUDE="$TMPDIR_01/claude"
MOCK_TRACES="$TMPDIR_01/traces"
mkdir -p "$MOCK_PROJECT" "$MOCK_CLAUDE" "$MOCK_TRACES"
trap 'rm -rf "$TMPDIR_01"' EXIT

PHASH_01=$(compute_phash "$MOCK_PROJECT")
PROOF_FILE_01="$MOCK_CLAUDE/.proof-status-${PHASH_01}"
STALE_TS=$(( $(date +%s) - 3600 ))  # 1 hour ago
echo "verified|${STALE_TS}|old-session-abc" > "$PROOF_FILE_01"

NEW_SESSION_ID="new-session-$$"

# No .active-* markers for the new session → cleanup proceeds
run_cleanup_logic "$MOCK_PROJECT" "$MOCK_CLAUDE" "$MOCK_TRACES" "$NEW_SESSION_ID" > /dev/null

if [[ -f "$PROOF_FILE_01" ]]; then
    fail_test "Proof file was NOT removed despite no active markers (file: $PROOF_FILE_01)"
else
    pass_test
fi

TMPDIR_01=""

# ─────────────────────────────────────────────────────────────────────────────
# SB-02: Active current-session marker + proof-status → preserved
#
# Scenario: The current session has an active implementer agent. The proof file
# must NOT be removed because ACTIVE_MARKERS > 0 for the current session.
# ─────────────────────────────────────────────────────────────────────────────

run_test "SB-02: Active current-session marker → proof-status preserved"

TMPDIR_02="$PROJECT_ROOT/tmp/test-sb-02-$$"
MOCK_PROJECT_02="$TMPDIR_02/project"
MOCK_CLAUDE_02="$TMPDIR_02/claude"
MOCK_TRACES_02="$TMPDIR_02/traces"
mkdir -p "$MOCK_PROJECT_02" "$MOCK_CLAUDE_02" "$MOCK_TRACES_02"
trap 'rm -rf "$TMPDIR_02"' EXIT

PHASH_02=$(compute_phash "$MOCK_PROJECT_02")
PROOF_FILE_02="$MOCK_CLAUDE_02/.proof-status-${PHASH_02}"
echo "needs-verification|$(date +%s)|active-session" > "$PROOF_FILE_02"

ACTIVE_SID_02="active-session-$$"

# Create a current-session active marker for this project
ACTIVE_MARKER_02="$MOCK_TRACES_02/.active-implementer-${ACTIVE_SID_02}-${PHASH_02}"
echo "$ACTIVE_SID_02" > "$ACTIVE_MARKER_02"

# Run cleanup — should preserve proof because ACTIVE_MARKERS=1
run_cleanup_logic "$MOCK_PROJECT_02" "$MOCK_CLAUDE_02" "$MOCK_TRACES_02" "$ACTIVE_SID_02" > /dev/null

if [[ ! -f "$PROOF_FILE_02" ]]; then
    fail_test "Proof file was removed despite active current-session marker"
else
    pass_test
fi

TMPDIR_02=""

# ─────────────────────────────────────────────────────────────────────────────
# SB-03: Stale marker from another session + proof-status → cleanup occurs
#
# Scenario: A different session left an .active-* marker for the same project.
# The current session ID is NEW_SID. Since the old session's markers don't
# match the current session, ACTIVE_MARKERS=0 → proof is removed.
#
# This is the key fix: DEC-SESSION-INIT-PROOF-CLEAN-001 ensures only
# current-session markers prevent cleanup.
# ─────────────────────────────────────────────────────────────────────────────

run_test "SB-03: Stale other-session marker + proof → cleanup still occurs (session isolation)"

TMPDIR_03="$PROJECT_ROOT/tmp/test-sb-03-$$"
MOCK_PROJECT_03="$TMPDIR_03/project"
MOCK_CLAUDE_03="$TMPDIR_03/claude"
MOCK_TRACES_03="$TMPDIR_03/traces"
mkdir -p "$MOCK_PROJECT_03" "$MOCK_CLAUDE_03" "$MOCK_TRACES_03"
trap 'rm -rf "$TMPDIR_03"' EXIT

PHASH_03=$(compute_phash "$MOCK_PROJECT_03")
PROOF_FILE_03="$MOCK_CLAUDE_03/.proof-status-${PHASH_03}"
STALE_TS_03=$(( $(date +%s) - 7200 ))  # 2 hours ago
echo "verified|${STALE_TS_03}|old-session-xyz" > "$PROOF_FILE_03"

OLD_SID_03="old-session-xyz"
NEW_SID_03="new-session-$$"

# Create marker for the OLD session (different from NEW_SID_03)
OLD_MARKER_03="$MOCK_TRACES_03/.active-implementer-${OLD_SID_03}-${PHASH_03}"
echo "$OLD_SID_03" > "$OLD_MARKER_03"

# Run cleanup with NEW session ID — old marker does NOT count
run_cleanup_logic "$MOCK_PROJECT_03" "$MOCK_CLAUDE_03" "$MOCK_TRACES_03" "$NEW_SID_03" > /dev/null

if [[ -f "$PROOF_FILE_03" ]]; then
    fail_test "Proof file was NOT removed: other-session marker incorrectly preserved it"
else
    pass_test
fi

TMPDIR_03=""

# ─────────────────────────────────────────────────────────────────────────────
# SB-04: Missing CLAUDE_SESSION_ID → conservative cleanup (all project markers count)
#
# Scenario: CLAUDE_SESSION_ID is empty (e.g., running outside Claude Code).
# The logic falls back to counting ALL project markers (any session).
# If any .active-*-{phash} marker exists, proof is preserved.
# ─────────────────────────────────────────────────────────────────────────────

run_test "SB-04: Missing CLAUDE_SESSION_ID → any project marker preserves proof"

TMPDIR_04="$PROJECT_ROOT/tmp/test-sb-04-$$"
MOCK_PROJECT_04="$TMPDIR_04/project"
MOCK_CLAUDE_04="$TMPDIR_04/claude"
MOCK_TRACES_04="$TMPDIR_04/traces"
mkdir -p "$MOCK_PROJECT_04" "$MOCK_CLAUDE_04" "$MOCK_TRACES_04"
trap 'rm -rf "$TMPDIR_04"' EXIT

PHASH_04=$(compute_phash "$MOCK_PROJECT_04")
PROOF_FILE_04="$MOCK_CLAUDE_04/.proof-status-${PHASH_04}"
echo "needs-verification|$(date +%s)|no-session" > "$PROOF_FILE_04"

# Create a project marker (any session) — no session ID suffix
SOME_SESSION_04="some-session-123"
ANY_MARKER_04="$MOCK_TRACES_04/.active-implementer-${SOME_SESSION_04}-${PHASH_04}"
echo "$SOME_SESSION_04" > "$ANY_MARKER_04"

# Run cleanup with EMPTY session ID → conservative path (all markers count)
run_cleanup_logic "$MOCK_PROJECT_04" "$MOCK_CLAUDE_04" "$MOCK_TRACES_04" "" > /dev/null

if [[ ! -f "$PROOF_FILE_04" ]]; then
    fail_test "Proof file was removed despite existing project marker (no-session-id conservative path)"
else
    pass_test
fi

TMPDIR_04=""

# ─────────────────────────────────────────────────────────────────────────────
# SB-05: Legacy .proof-status (no hash suffix) cleaned when no active markers
#
# Scenario: An old unsuffixed .proof-status file exists (pre-scoping era).
# The cleanup iterates both the scoped and legacy files. With no active markers,
# the legacy file must also be removed.
# ─────────────────────────────────────────────────────────────────────────────

run_test "SB-05: Legacy .proof-status (no hash suffix) cleaned when no active markers"

TMPDIR_05="$PROJECT_ROOT/tmp/test-sb-05-$$"
MOCK_PROJECT_05="$TMPDIR_05/project"
MOCK_CLAUDE_05="$TMPDIR_05/claude"
MOCK_TRACES_05="$TMPDIR_05/traces"
mkdir -p "$MOCK_PROJECT_05" "$MOCK_CLAUDE_05" "$MOCK_TRACES_05"
trap 'rm -rf "$TMPDIR_05"' EXIT

# Legacy file without hash suffix
LEGACY_PROOF="$MOCK_CLAUDE_05/.proof-status"
STALE_TS_05=$(( $(date +%s) - 3600 ))
echo "verified|${STALE_TS_05}|legacy-session" > "$LEGACY_PROOF"

NEW_SID_05="new-session-05-$$"

# No active markers for the current session → cleanup proceeds
run_cleanup_logic "$MOCK_PROJECT_05" "$MOCK_CLAUDE_05" "$MOCK_TRACES_05" "$NEW_SID_05" > /dev/null

if [[ -f "$LEGACY_PROOF" ]]; then
    fail_test "Legacy .proof-status was NOT removed despite no active markers"
else
    pass_test
fi

TMPDIR_05=""

# ─────────────────────────────────────────────────────────────────────────────
# SB-06: Marker for different project does NOT prevent proof cleanup
#
# Scenario: Project A has an active session marker. Project B has a stale proof.
# When session-init runs for Project B, it must only count Project B's markers,
# not Project A's. This validates DEC-ISOLATION-008.
# ─────────────────────────────────────────────────────────────────────────────

run_test "SB-06: Marker for different project does NOT prevent proof cleanup (project isolation)"

TMPDIR_06="$PROJECT_ROOT/tmp/test-sb-06-$$"
MOCK_PROJECT_A="$TMPDIR_06/project-a"
MOCK_PROJECT_B="$TMPDIR_06/project-b"
MOCK_CLAUDE_B="$TMPDIR_06/claude-b"
MOCK_TRACES="$TMPDIR_06/traces"
mkdir -p "$MOCK_PROJECT_A" "$MOCK_PROJECT_B" "$MOCK_CLAUDE_B" "$MOCK_TRACES"
trap 'rm -rf "$TMPDIR_06"' EXIT

PHASH_A=$(compute_phash "$MOCK_PROJECT_A")
PHASH_B=$(compute_phash "$MOCK_PROJECT_B")

# Create proof for Project B (stale)
PROOF_B="$MOCK_CLAUDE_B/.proof-status-${PHASH_B}"
STALE_TS_06=$(( $(date +%s) - 3600 ))
echo "verified|${STALE_TS_06}|session-b-old" > "$PROOF_B"

CURRENT_SID_06="current-session-06-$$"

# Create active marker for Project A (different project hash)
MARKER_A="$MOCK_TRACES/.active-implementer-${CURRENT_SID_06}-${PHASH_A}"
echo "$CURRENT_SID_06" > "$MARKER_A"

# Run cleanup for Project B — Project A's marker must NOT prevent cleanup
run_cleanup_logic "$MOCK_PROJECT_B" "$MOCK_CLAUDE_B" "$MOCK_TRACES" "$CURRENT_SID_06" > /dev/null

if [[ -f "$PROOF_B" ]]; then
    fail_test "Project B proof was NOT removed: Project A's marker incorrectly blocked cleanup"
else
    pass_test
fi

TMPDIR_06=""

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "──────────────────────────────────────────────────────"
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_RUN total"

if [[ "$TESTS_FAILED" -eq 0 ]]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "SOME TESTS FAILED"
    exit 1
fi
