#!/usr/bin/env bash
# test-post-task-autoverify.sh — Tests for post-task.sh auto-verify migration (issue #150)
#
# Purpose: Verify that post-task.sh correctly auto-verifies tester Task completions
#   when AUTOVERIFY: CLEAN is signaled with High confidence and no caveats.
#
# Contracts verified:
#   1.  Tester + AUTOVERIFY: CLEAN + High confidence → writes verified
#   2.  Tester + AUTOVERIFY: CLEAN + Medium confidence → stays pending
#   3.  Tester + AUTOVERIFY: CLEAN + "Partially verified" → stays pending
#   4.  Tester + AUTOVERIFY: CLEAN + non-environmental "Not tested" → stays pending
#   5.  Tester + AUTOVERIFY: CLEAN + environmental "Not tested" (browser/viewport) → writes verified
#   6.  Non-tester subagent_type → no-op (no proof-status change)
#   7.  Tester + no summary.md → no-op (graceful fallback)
#   8.  Tester + proof already verified → dedup (no double-write)
#   9.  Tester + proof-status missing → creates needs-verification (safety net)
#  10.  Regression: track.sh still invalidates proof-status when no guardian breadcrumb
#
# @decision DEC-PROOF-LIFE-001
# @title post-task.sh test suite validates PostToolUse:Task auto-verify migration
# @status accepted
# @rationale Tests are the proof of Done for the Phase 1 auto-verify migration.
#   They validate the critical path (test 1), all secondary validation rejection
#   cases (tests 2-4), the environmental whitelist (test 5), the non-tester no-op
#   (test 6), the graceful fallback (test 7), the dedup guard (test 8), the safety
#   net (test 9), and the track.sh regression (test 10). Issue #150.
#
# Usage: bash tests/test-post-task-autoverify.sh
# Returns: 0 if all tests pass, 1 if any fail

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="${PROJECT_ROOT}/hooks"
POST_TASK_SH="${HOOKS_DIR}/post-task.sh"
TRACK_SH="${HOOKS_DIR}/track.sh"

# Ensure tmp directory exists
mkdir -p "$PROJECT_ROOT/tmp"

# ---------------------------------------------------------------------------
# Test tracking
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Helper: make_temp_repo — create an isolated git repo + TRACE_STORE + .claude dir.
# Returns: path via stdout. Caller is responsible for cleanup.
# ---------------------------------------------------------------------------
make_temp_repo() {
    local tmp_dir
    tmp_dir=$(mktemp -d "$PROJECT_ROOT/tmp/test-pta-XXXXXX")
    git -C "$tmp_dir" init -q 2>/dev/null
    mkdir -p "$tmp_dir/.claude"
    echo "$tmp_dir"
}

# ---------------------------------------------------------------------------
# Helper: make_tester_trace — create a fake tester trace with summary.md content.
# Args:
#   $1 = trace store path
#   $2 = project root (for project_hash)
#   $3 = summary.md content
# Returns: trace_id via stdout
# ---------------------------------------------------------------------------
make_tester_trace() {
    local trace_store="$1"
    local project_root="$2"
    local summary_content="$3"
    local trace_id="tester-$(date +%s)-test$$"
    local trace_dir="${trace_store}/${trace_id}"

    mkdir -p "${trace_dir}/artifacts"
    echo "$summary_content" > "${trace_dir}/summary.md"

    # Write manifest so detect_active_trace can validate it
    cat > "${trace_dir}/manifest.json" <<MANIFEST_EOF
{
  "trace_id": "${trace_id}",
  "agent_type": "tester",
  "project_root": "${project_root}",
  "status": "active",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
MANIFEST_EOF

    # Write active marker (scoped to session + project).
    # Must write trace_id as content — detect_active_trace reads the file to get the ID.
    local session_id="${CLAUDE_SESSION_ID:-test-session-$$}"
    local phash
    phash=$(echo "$project_root" | shasum -a 256 | cut -c1-8)
    echo "$trace_id" > "${trace_store}/.active-tester-${session_id}-${phash}"

    echo "$trace_id"
}

# ---------------------------------------------------------------------------
# Helper: run_post_task — invoke post-task.sh simulating a PostToolUse:Task event.
# Args:
#   $1 = subagent_type (e.g. "tester")
#   $2 = repo path (CLAUDE_PROJECT_DIR)
#   $3 = trace store path
# Returns: post-task.sh stdout + exit code check via || true
# ---------------------------------------------------------------------------
run_post_task() {
    local subagent_type="$1"
    local repo="$2"
    local trace_store="${3:-}"

    local input_json
    input_json=$(printf '{"tool_name":"Task","tool_input":{"subagent_type":"%s","prompt":"test"}}' \
        "$subagent_type")

    ( export CLAUDE_PROJECT_DIR="$repo"
      [[ -n "$trace_store" ]] && export TRACE_STORE="$trace_store"
      export CLAUDE_SESSION_ID="${CLAUDE_SESSION_ID:-test-session-$$}"
      cd "$repo"
      echo "$input_json" | bash "$POST_TASK_SH" 2>/dev/null
    ) || true
}

# ---------------------------------------------------------------------------
# Helper: run_track — invoke track.sh simulating a Write event.
# ---------------------------------------------------------------------------
run_track() {
    local file_path="$1"
    local repo="$2"
    local trace_store="${3:-}"

    local input_json
    input_json=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$file_path")

    ( export CLAUDE_PROJECT_DIR="$repo"
      [[ -n "$trace_store" ]] && export TRACE_STORE="$trace_store"
      cd "$repo"
      echo "$input_json" | bash "$TRACK_SH" 2>/dev/null
    ) || true
}

# ---------------------------------------------------------------------------
# Helper: clean_tester_markers — remove active tester markers from trace store
# so tests don't leak markers to each other.
# ---------------------------------------------------------------------------
clean_tester_markers() {
    local trace_store="$1"
    rm -f "${trace_store}/.active-tester-"* 2>/dev/null || true
}

# ===========================================================================
# Test 1: Tester + AUTOVERIFY: CLEAN + High confidence → writes verified
# Contract: happy path — all secondary validation passes, proof becomes verified.
# ===========================================================================

run_test "T1: tester + AUTOVERIFY: CLEAN + High confidence → verified"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-pta-trace-XXXXXX")
echo "pending|$(date +%s)" > "$REPO/.claude/.proof-status"

SUMMARY=$(cat <<'SUMMARY_EOF'
## Verification Assessment

AUTOVERIFY: CLEAN

**Confidence:** **High**

All features verified. No caveats.
SUMMARY_EOF
)

make_tester_trace "$TRACE" "$REPO" "$SUMMARY" > /dev/null
run_post_task "tester" "$REPO" "$TRACE"

if [[ -f "$REPO/.claude/.proof-status" ]]; then
    STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
    if [[ "$STATUS" == "verified" ]]; then
        pass_test
    else
        fail_test "Expected 'verified', got '$STATUS'"
    fi
else
    fail_test ".proof-status was deleted"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 2: Tester + AUTOVERIFY: CLEAN + Medium confidence → stays pending
# Contract: Medium confidence fails secondary validation.
# ===========================================================================

run_test "T2: tester + AUTOVERIFY: CLEAN + Medium confidence → stays pending"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-pta-trace-XXXXXX")
echo "pending|$(date +%s)" > "$REPO/.claude/.proof-status"

SUMMARY=$(cat <<'SUMMARY_EOF'
## Verification Assessment

AUTOVERIFY: CLEAN

**Confidence:** **Medium**

Most features verified but some edge cases remain.
SUMMARY_EOF
)

make_tester_trace "$TRACE" "$REPO" "$SUMMARY" > /dev/null
run_post_task "tester" "$REPO" "$TRACE"

if [[ -f "$REPO/.claude/.proof-status" ]]; then
    STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
    if [[ "$STATUS" == "pending" ]]; then
        pass_test
    else
        fail_test "Expected 'pending' (Medium confidence should fail), got '$STATUS'"
    fi
else
    fail_test ".proof-status was deleted"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 3: Tester + AUTOVERIFY: CLEAN + "Partially verified" → stays pending
# Contract: "Partially verified" fails secondary validation.
# ===========================================================================

run_test "T3: tester + AUTOVERIFY: CLEAN + 'Partially verified' → stays pending"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-pta-trace-XXXXXX")
echo "pending|$(date +%s)" > "$REPO/.claude/.proof-status"

SUMMARY=$(cat <<'SUMMARY_EOF'
## Verification Assessment

AUTOVERIFY: CLEAN

**Confidence:** **High**

Coverage: Partially verified — main flow works, edge cases skipped.
SUMMARY_EOF
)

make_tester_trace "$TRACE" "$REPO" "$SUMMARY" > /dev/null
run_post_task "tester" "$REPO" "$TRACE"

if [[ -f "$REPO/.claude/.proof-status" ]]; then
    STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
    if [[ "$STATUS" == "pending" ]]; then
        pass_test
    else
        fail_test "Expected 'pending' (Partially verified should fail), got '$STATUS'"
    fi
else
    fail_test ".proof-status was deleted"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 4: Tester + AUTOVERIFY: CLEAN + non-environmental "Not tested" → stays pending
# Contract: Non-environmental "Not tested" items fail secondary validation.
# ===========================================================================

run_test "T4: tester + AUTOVERIFY: CLEAN + non-environmental 'Not tested' → stays pending"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-pta-trace-XXXXXX")
echo "pending|$(date +%s)" > "$REPO/.claude/.proof-status"

SUMMARY=$(cat <<'SUMMARY_EOF'
## Verification Assessment

AUTOVERIFY: CLEAN

**Confidence:** **High**

- Main flow: Verified
- Error handling: Not tested — needs more time to implement
SUMMARY_EOF
)

make_tester_trace "$TRACE" "$REPO" "$SUMMARY" > /dev/null
run_post_task "tester" "$REPO" "$TRACE"

if [[ -f "$REPO/.claude/.proof-status" ]]; then
    STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
    if [[ "$STATUS" == "pending" ]]; then
        pass_test
    else
        fail_test "Expected 'pending' (non-env Not tested should fail), got '$STATUS'"
    fi
else
    fail_test ".proof-status was deleted"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 5: Tester + AUTOVERIFY: CLEAN + environmental "Not tested" → verified
# Contract: Environmental "Not tested" items (browser/viewport) are whitelisted.
# ===========================================================================

run_test "T5: tester + AUTOVERIFY: CLEAN + environmental 'Not tested' (browser) → verified"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-pta-trace-XXXXXX")
echo "pending|$(date +%s)" > "$REPO/.claude/.proof-status"

SUMMARY=$(cat <<'SUMMARY_EOF'
## Verification Assessment

AUTOVERIFY: CLEAN

**Confidence:** **High**

- Main flow: Verified
- UI rendering: Not tested — requires browser viewport (headless CLI environment)
SUMMARY_EOF
)

make_tester_trace "$TRACE" "$REPO" "$SUMMARY" > /dev/null
run_post_task "tester" "$REPO" "$TRACE"

if [[ -f "$REPO/.claude/.proof-status" ]]; then
    STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
    if [[ "$STATUS" == "verified" ]]; then
        pass_test
    else
        fail_test "Expected 'verified' (environmental Not tested should be whitelisted), got '$STATUS'"
    fi
else
    fail_test ".proof-status was deleted"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 6: Non-tester subagent_type → no-op
# Contract: post-task.sh does nothing when subagent_type is not "tester".
# ===========================================================================

run_test "T6: non-tester subagent_type → no-op (no proof-status change)"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-pta-trace-XXXXXX")
ORIGINAL_TS="99999"
echo "needs-verification|${ORIGINAL_TS}" > "$REPO/.claude/.proof-status"

run_post_task "implementer" "$REPO" "$TRACE"

if [[ -f "$REPO/.claude/.proof-status" ]]; then
    STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
    TS=$(cut -d'|' -f2 "$REPO/.claude/.proof-status")
    if [[ "$STATUS" == "needs-verification" && "$TS" == "$ORIGINAL_TS" ]]; then
        pass_test
    else
        fail_test "Expected needs-verification|${ORIGINAL_TS}, got $STATUS|$TS"
    fi
else
    fail_test ".proof-status was deleted (expected no-op)"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 7: Tester + no summary.md found → no-op (graceful fallback)
# Contract: when detect_active_trace finds nothing, exit 0 with no changes.
# ===========================================================================

run_test "T7: tester + no summary.md found → no-op (graceful fallback)"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-pta-trace-XXXXXX")
# No active tester markers → no trace → no summary.md
echo "pending|$(date +%s)" > "$REPO/.claude/.proof-status"
ORIGINAL_CONTENT=$(cat "$REPO/.claude/.proof-status")

run_post_task "tester" "$REPO" "$TRACE"

if [[ -f "$REPO/.claude/.proof-status" ]]; then
    CURRENT_CONTENT=$(cat "$REPO/.claude/.proof-status")
    STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
    if [[ "$STATUS" == "pending" ]]; then
        pass_test
    else
        fail_test "Expected 'pending' with no summary.md, got '$STATUS'"
    fi
else
    fail_test ".proof-status was deleted (expected no-op)"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 8: Tester + proof-status already verified → dedup (no double-write)
# Contract: dedup guard exits early when proof is already verified.
# ===========================================================================

run_test "T8: tester + proof already verified → dedup (no double-write)"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-pta-trace-XXXXXX")
ORIGINAL_TS="12345"
echo "verified|${ORIGINAL_TS}" > "$REPO/.claude/.proof-status"

SUMMARY="AUTOVERIFY: CLEAN\n**Confidence:** **High**"
make_tester_trace "$TRACE" "$REPO" "$SUMMARY" > /dev/null
run_post_task "tester" "$REPO" "$TRACE"

if [[ -f "$REPO/.claude/.proof-status" ]]; then
    STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
    TS=$(cut -d'|' -f2 "$REPO/.claude/.proof-status")
    if [[ "$STATUS" == "verified" && "$TS" == "$ORIGINAL_TS" ]]; then
        pass_test
    else
        fail_test "Expected original verified|${ORIGINAL_TS} (dedup), got $STATUS|$TS"
    fi
else
    fail_test ".proof-status was deleted (expected dedup no-op)"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 9: Tester + proof-status missing → creates needs-verification (safety net)
# Contract: when .proof-status doesn't exist, safety net creates needs-verification.
# ===========================================================================

run_test "T9: tester + proof-status missing → creates needs-verification (safety net)"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-pta-trace-XXXXXX")
# Deliberately no .proof-status file
rm -f "$REPO/.claude/.proof-status" 2>/dev/null || true

# Summary lacks AUTOVERIFY: CLEAN so auto-verify won't fire; safety net should still run
SUMMARY="Summary without AUTOVERIFY signal — just showing work done."
make_tester_trace "$TRACE" "$REPO" "$SUMMARY" > /dev/null
run_post_task "tester" "$REPO" "$TRACE"

# Safety net may write to scoped (.proof-status-{phash}) or legacy (.proof-status).
# Check either location.
_PROOF_FOUND=""
for _pf in "$REPO/.claude/.proof-status" "$REPO/.claude/.proof-status-"*; do
    [[ -f "$_pf" ]] && { _PROOF_FOUND="$_pf"; break; }
done
if [[ -n "$_PROOF_FOUND" ]]; then
    STATUS=$(cut -d'|' -f1 "$_PROOF_FOUND")
    if [[ "$STATUS" == "needs-verification" ]]; then
        pass_test
    else
        fail_test "Expected 'needs-verification' (safety net), got '$STATUS' in $_PROOF_FOUND"
    fi
else
    fail_test ".proof-status not created by safety net (checked $REPO/.claude/)"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 10: Regression — track.sh still invalidates proof when no guardian breadcrumb
# Contract: existing track.sh invalidation behaviour is unaffected by this migration.
# ===========================================================================

run_test "T10: regression — track.sh invalidates verified proof on source write (no guardian)"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-pta-trace-XXXXXX")
# No .active-guardian-* markers
echo "verified|$(date +%s)" > "$REPO/.claude/.proof-status"

run_track "$REPO/main.sh" "$REPO" "$TRACE"

if [[ -f "$REPO/.claude/.proof-status" ]]; then
    STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
    if [[ "$STATUS" == "pending" ]]; then
        pass_test
    else
        fail_test "Expected 'pending' after source write (track.sh regression), got '$STATUS'"
    fi
else
    fail_test ".proof-status was deleted (expected pending)"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 11: Full pipeline — task-track.sh initializes tester trace, post-task.sh
#          finds it and auto-verifies (DEC-PROOF-LIFE-004 integration test)
#
# Contract: When task-track.sh fires for a tester dispatch (PreToolUse:Task),
#   it calls init_trace() which creates a .active-tester-* marker. The tester
#   then writes summary.md to that trace directory. When post-task.sh fires
#   (PostToolUse:Task), it finds the marker via detect_active_trace() and
#   processes the summary to produce auto-verify.
# ===========================================================================

run_test "T11: full pipeline — task-track.sh init_trace breadcrumb → post-task.sh auto-verify"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-pta-trace-XXXXXX")
TASK_TRACK_SH="${HOOKS_DIR}/task-track.sh"
echo "pending|$(date +%s)" > "$REPO/.claude/.proof-status"

# Step 1: Simulate PreToolUse:Task for a tester dispatch (as task-track.sh would see it)
TESTER_INPUT_JSON='{"tool_name":"Task","tool_input":{"subagent_type":"tester","prompt":"verify the feature"}}'
TASK_TRACK_OUT=$(
    export CLAUDE_PROJECT_DIR="$REPO"
    export TRACE_STORE="$TRACE"
    export CLAUDE_SESSION_ID="test-session-t11-$$"
    cd "$REPO"
    echo "$TESTER_INPUT_JSON" | bash "$TASK_TRACK_SH" 2>/dev/null
) || true

# Step 2: Verify .active-tester-* marker was created by init_trace
ACTIVE_MARKER=$(ls "$TRACE"/.active-tester-* 2>/dev/null | head -1 || echo "")
if [[ -z "$ACTIVE_MARKER" ]]; then
    fail_test "task-track.sh did not create .active-tester-* marker in TRACE_STORE"
    rm -rf "$REPO" "$TRACE"
else
    # Step 3: Get the trace_id from the marker and write summary.md as the tester would
    TRACE_ID=$(cat "$ACTIVE_MARKER" 2>/dev/null || echo "")
    if [[ -z "$TRACE_ID" ]]; then
        fail_test ".active-tester-* marker exists but is empty (no trace_id)"
        rm -rf "$REPO" "$TRACE"
    else
        TRACE_DIR_PATH="${TRACE}/${TRACE_ID}"
        mkdir -p "${TRACE_DIR_PATH}/artifacts"
        cat > "${TRACE_DIR_PATH}/summary.md" <<'SUMMARY_EOF'
## Verification Assessment

AUTOVERIFY: CLEAN

**Confidence:** **High**

All features verified in the full pipeline test.
SUMMARY_EOF

        # Step 4: Run post-task.sh (simulating PostToolUse:Task for tester completion)
        POST_TASK_INPUT='{"tool_name":"Task","tool_input":{"subagent_type":"tester","prompt":"verify the feature"}}'
        (
            export CLAUDE_PROJECT_DIR="$REPO"
            export TRACE_STORE="$TRACE"
            export CLAUDE_SESSION_ID="test-session-t11-$$"
            cd "$REPO"
            echo "$POST_TASK_INPUT" | bash "$POST_TASK_SH" 2>/dev/null
        ) || true

        # Step 5: Verify proof-status is now verified
        if [[ -f "$REPO/.claude/.proof-status" ]]; then
            STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
            if [[ "$STATUS" == "verified" ]]; then
                pass_test
            else
                fail_test "Expected 'verified' after full pipeline, got '$STATUS'"
            fi
        else
            fail_test ".proof-status was deleted during pipeline test"
        fi
        rm -rf "$REPO" "$TRACE"
    fi
fi

# ===========================================================================
# Syntax check
# ===========================================================================

run_test "Syntax: post-task.sh is valid bash"
if bash -n "$POST_TASK_SH"; then
    pass_test
else
    fail_test "post-task.sh has syntax errors"
fi

run_test "Syntax: task-track.sh is valid bash"
if bash -n "${HOOKS_DIR}/task-track.sh"; then
    pass_test
else
    fail_test "task-track.sh has syntax errors"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "=========================================="
echo "Test Results: $TESTS_PASSED/$TESTS_RUN passed"
echo "=========================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
    echo "FAILED: $TESTS_FAILED test(s) failed"
    exit 1
else
    echo "SUCCESS: All $TESTS_PASSED tests passed"
    exit 0
fi
