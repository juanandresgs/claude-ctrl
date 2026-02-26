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
#  11.  Full pipeline — subagent-start creates marker, tester writes summary, post-task auto-verifies
#  17.  Session-based trace fallback — marker cleaned by SubagentStop, trace found by session scan
#  18.  Dual-trace scenario — marker trace has no summary, summary in separate trace → verified (DEC-AV-DUAL-001)
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
# Test 11: Full pipeline — subagent-start.sh creates marker, tester writes summary,
#          post-task.sh finds it and auto-verifies (DEC-AV-DUAL-002 integration test)
#
# Contract: task-track.sh no longer calls init_trace() for testers (DEC-AV-DUAL-002).
#   Instead, subagent-start.sh creates the authoritative .active-tester-* marker.
#   This test simulates subagent-start.sh's init_trace, then verifies that post-task.sh
#   finds the marker and auto-verifies.
# ===========================================================================

run_test "T11: full pipeline — subagent-start creates marker → tester writes summary → post-task auto-verify"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-pta-trace-XXXXXX")
TASK_TRACK_SH="${HOOKS_DIR}/task-track.sh"
_T11_SESSION="test-session-t11-$$"
echo "pending|$(date +%s)" > "$REPO/.claude/.proof-status"

# Step 1: Confirm task-track.sh does NOT create .active-tester-* marker (DEC-AV-DUAL-002)
TESTER_INPUT_JSON='{"tool_name":"Task","tool_input":{"subagent_type":"tester","prompt":"verify the feature"}}'
(
    export CLAUDE_PROJECT_DIR="$REPO"
    export TRACE_STORE="$TRACE"
    export CLAUDE_SESSION_ID="${_T11_SESSION}"
    cd "$REPO"
    echo "$TESTER_INPUT_JSON" | bash "$TASK_TRACK_SH" 2>/dev/null
) || true

ACTIVE_MARKER_AFTER_TRACK=$(ls "$TRACE"/.active-tester-* 2>/dev/null | head -1 || echo "")
if [[ -n "$ACTIVE_MARKER_AFTER_TRACK" ]]; then
    fail_test "task-track.sh still creates .active-tester-* marker — DEC-AV-DUAL-002 not applied"
    rm -rf "$REPO" "$TRACE"
else
    # Step 2: Simulate subagent-start.sh creating the marker (the new authoritative path).
    # In production, subagent-start.sh's init_trace() does this with the subagent's session_id.
    _T11_PHASH=$(echo "$REPO" | shasum -a 256 | cut -c1-8)
    _T11_TRACE_ID="tester-$(date +%s)-t11-subagent"
    _T11_TRACE_DIR="${TRACE}/${_T11_TRACE_ID}"
    mkdir -p "${_T11_TRACE_DIR}/artifacts"
    cat > "${_T11_TRACE_DIR}/manifest.json" <<MANIFEST_EOF
{
  "trace_id": "${_T11_TRACE_ID}",
  "agent_type": "tester",
  "session_id": "${_T11_SESSION}",
  "project": "${REPO}",
  "status": "active",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
MANIFEST_EOF
    echo "$_T11_TRACE_ID" > "${TRACE}/.active-tester-${_T11_SESSION}-${_T11_PHASH}"

    # Step 3: Tester writes summary.md to its trace directory
    cat > "${_T11_TRACE_DIR}/summary.md" <<'SUMMARY_EOF'
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
        export CLAUDE_SESSION_ID="${_T11_SESSION}"
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

# ===========================================================================
# Test 12: ## Confidence: High (no bold) + AUTOVERIFY: CLEAN → should verify
# Contract: plain-text confidence header is accepted by format-tolerant matching.
# ===========================================================================

run_test "T12: Confidence: High (no bold) + AUTOVERIFY: CLEAN → verified"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-pta-trace-XXXXXX")
echo "pending|$(date +%s)" > "$REPO/.claude/.proof-status"

SUMMARY=$(cat <<'SUMMARY_EOF'
## Verification Assessment

AUTOVERIFY: CLEAN

## Confidence: High

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
        fail_test "Expected 'verified' for 'Confidence: High' (no bold), got '$STATUS'"
    fi
else
    fail_test ".proof-status was deleted"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 13: High confidence (inline) + AUTOVERIFY: CLEAN → should verify
# Contract: "High confidence" inline phrase is accepted by format-tolerant matching.
# ===========================================================================

run_test "T13: High confidence (inline) + AUTOVERIFY: CLEAN → verified"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-pta-trace-XXXXXX")
echo "pending|$(date +%s)" > "$REPO/.claude/.proof-status"

SUMMARY=$(cat <<'SUMMARY_EOF'
## Verification Assessment

AUTOVERIFY: CLEAN

High confidence — all tests passed, no anomalies observed.
SUMMARY_EOF
)

make_tester_trace "$TRACE" "$REPO" "$SUMMARY" > /dev/null
run_post_task "tester" "$REPO" "$TRACE"

if [[ -f "$REPO/.claude/.proof-status" ]]; then
    STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
    if [[ "$STATUS" == "verified" ]]; then
        pass_test
    else
        fail_test "Expected 'verified' for 'High confidence' inline, got '$STATUS'"
    fi
else
    fail_test ".proof-status was deleted"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 14: ## Confidence: Medium (no bold) + AUTOVERIFY: CLEAN → should reject
# Contract: plain-text Medium confidence is rejected by format-tolerant matching.
# ===========================================================================

run_test "T14: Confidence: Medium (no bold) + AUTOVERIFY: CLEAN → stays pending"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-pta-trace-XXXXXX")
echo "pending|$(date +%s)" > "$REPO/.claude/.proof-status"

SUMMARY=$(cat <<'SUMMARY_EOF'
## Verification Assessment

AUTOVERIFY: CLEAN

## Confidence: Medium

Core paths verified but some edge cases remain.
SUMMARY_EOF
)

make_tester_trace "$TRACE" "$REPO" "$SUMMARY" > /dev/null
run_post_task "tester" "$REPO" "$TRACE"

if [[ -f "$REPO/.claude/.proof-status" ]]; then
    STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
    if [[ "$STATUS" == "pending" ]]; then
        pass_test
    else
        fail_test "Expected 'pending' for 'Confidence: Medium' (no bold), got '$STATUS'"
    fi
else
    fail_test ".proof-status was deleted"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 15: Diagnostic output when secondary validation fails (additionalContext)
# Contract: when AV_FAIL=true, post-task.sh emits JSON with additionalContext
#   explaining why auto-verify was blocked (not a silent exit 0).
# ===========================================================================

run_test "T15: secondary validation fail → additionalContext with diagnostic reason"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-pta-trace-XXXXXX")
echo "pending|$(date +%s)" > "$REPO/.claude/.proof-status"

SUMMARY=$(cat <<'SUMMARY_EOF'
## Verification Assessment

AUTOVERIFY: CLEAN

**Confidence:** **Medium**

Most features verified.
SUMMARY_EOF
)

make_tester_trace "$TRACE" "$REPO" "$SUMMARY" > /dev/null
OUTPUT=$(run_post_task "tester" "$REPO" "$TRACE")

# Should output JSON with additionalContext explaining the block
if echo "$OUTPUT" | grep -q '"additionalContext"'; then
    if echo "$OUTPUT" | grep -qi 'auto-verify blocked\|blocked\|manual approval'; then
        pass_test
    else
        fail_test "additionalContext present but missing diagnostic reason: $OUTPUT"
    fi
else
    fail_test "Expected additionalContext in output for secondary validation failure, got: $OUTPUT"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 16: "Not tested" in area name descriptions is not a false positive
# Contract: "Not tested" appearing in coverage table area/name columns (not the
#   status column) must NOT trigger the non-environmental rejection.  A summary
#   where every status cell says "Fully verified" must auto-verify even when area
#   names contain the phrase "Not tested → blocked" or similar descriptions.
# ===========================================================================

run_test "T16: 'Not tested' in area name (not status) + AUTOVERIFY: CLEAN + High → verified"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-pta-trace-XXXXXX")
echo "pending|$(date +%s)" > "$REPO/.claude/.proof-status"

SUMMARY=$(cat <<'SUMMARY_EOF'
## Verification Assessment

AUTOVERIFY: CLEAN

**Confidence:** **High**

### Coverage
| Area | Status | Notes |
|------|--------|-------|
| AUTOVERIFY: CLEAN + High confidence → auto-verify | Fully verified | T1 |
| Non-environmental Not tested → blocked | Fully verified | T4 |
| Environmental Not tested (browser) → allowed | Fully verified | T5 |
| Bash syntax validity | Fully verified | Syntax tests |
SUMMARY_EOF
)

make_tester_trace "$TRACE" "$REPO" "$SUMMARY" > /dev/null
run_post_task "tester" "$REPO" "$TRACE"

if [[ -f "$REPO/.claude/.proof-status" ]]; then
    STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
    if [[ "$STATUS" == "verified" ]]; then
        pass_test
    else
        fail_test "Expected 'verified' ('Not tested' in area names should not block auto-verify), got '$STATUS'"
    fi
else
    fail_test ".proof-status was deleted"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 17: Session-based trace fallback — marker gone (simulating SubagentStop race)
#
# Contract: when the .active-tester-* marker has been cleaned by SubagentStop's
#   finalize_trace() before PostToolUse:Task fires, post-task.sh must fall back to
#   scanning the 5 most recent tester manifests for a matching session_id + project.
#   If found, it should auto-verify exactly as if the marker were present.
#
# DEC-AV-RACE-001: fallback scans tester-* dirs (sorted newest-first, limit 5)
#   for manifest.json with .session_id == CLAUDE_SESSION_ID and .project == PROJECT_ROOT.
# ===========================================================================

run_test "T17: session-based fallback — marker gone, trace found by session scan → verified"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-pta-trace-XXXXXX")
echo "pending|$(date +%s)" > "$REPO/.claude/.proof-status"

_T17_SESSION="t17-session-$$"
_T17_TRACE_ID="tester-$(date +%s)-t17test"
_T17_TRACE_DIR="${TRACE}/${_T17_TRACE_ID}"

mkdir -p "${_T17_TRACE_DIR}/artifacts"

# Write summary.md with AUTOVERIFY: CLEAN + High confidence
cat > "${_T17_TRACE_DIR}/summary.md" <<'SUMMARY_EOF'
## Verification Assessment

AUTOVERIFY: CLEAN

**Confidence:** **High**

All features verified. Session-based fallback test — no active marker present.
SUMMARY_EOF

# Write manifest.json with matching session_id and project — but NO .active-tester-* marker
cat > "${_T17_TRACE_DIR}/manifest.json" <<MANIFEST_EOF
{
  "trace_id": "${_T17_TRACE_ID}",
  "agent_type": "tester",
  "session_id": "${_T17_SESSION}",
  "project": "${REPO}",
  "status": "completed",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
MANIFEST_EOF

# Deliberately no .active-tester-* marker (simulating SubagentStop cleanup)
# Verify no marker exists before running
if ls "${TRACE}/.active-tester-"* 2>/dev/null | grep -q .; then
    fail_test "Setup error: unexpected active tester markers found before test"
    rm -rf "$REPO" "$TRACE"
else
    (
        export CLAUDE_PROJECT_DIR="$REPO"
        export TRACE_STORE="$TRACE"
        export CLAUDE_SESSION_ID="${_T17_SESSION}"
        cd "$REPO"
        echo '{"tool_name":"Task","tool_input":{"subagent_type":"tester","prompt":"verify"}}' \
            | bash "$POST_TASK_SH" 2>/dev/null
    ) || true

    if [[ -f "$REPO/.claude/.proof-status" ]]; then
        STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
        if [[ "$STATUS" == "verified" ]]; then
            pass_test
        else
            fail_test "Expected 'verified' via session-based fallback, got '$STATUS'"
        fi
    else
        fail_test ".proof-status was deleted (expected verified via session scan)"
    fi
    rm -rf "$REPO" "$TRACE"
fi

# ===========================================================================
# Test 18: Dual-trace scenario — marker trace has no summary, summary in second trace
#
# Contract: When task-track.sh creates trace #1 with a marker (orchestrator session_id)
#   but no summary.md, and subagent-start.sh creates trace #2 with summary.md but no
#   marker (different subagent session_id), post-task.sh must find the summary via
#   the project-scoped scan fallback (DEC-AV-DUAL-001) and auto-verify.
#
# This test simulates the exact dual-trace scenario:
#   - Trace #1: has .active-tester-* marker (pointing to it) but no summary.md
#   - Trace #2: has summary.md + valid manifest with project match, but no marker
#   - CLAUDE_SESSION_ID matches trace #1's session, not trace #2's
#   - post-task.sh must reach the project-scoped scan and find trace #2
# ===========================================================================

run_test "T18: dual-trace — marker trace has no summary, summary in different trace → verified"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-pta-trace-XXXXXX")
echo "pending|$(date +%s)" > "$REPO/.claude/.proof-status"

_T18_SESSION="t18-orchestrator-session-$$"
_T18_SUBAGENT_SESSION="t18-subagent-session-$$"
_PHASH=$(echo "$REPO" | shasum -a 256 | cut -c1-8)

# Trace #1: created by task-track.sh — has the active marker but NO summary.md
# (This is what task-track.sh's init_trace would create with orchestrator's session_id)
_T18_TRACE1_ID="tester-$(date +%s)-t18-track"
_T18_TRACE1_DIR="${TRACE}/${_T18_TRACE1_ID}"
mkdir -p "${_T18_TRACE1_DIR}/artifacts"
# No summary.md written — simulating task-track.sh's trace
cat > "${_T18_TRACE1_DIR}/manifest.json" <<MANIFEST_EOF
{
  "trace_id": "${_T18_TRACE1_ID}",
  "agent_type": "tester",
  "session_id": "${_T18_SESSION}",
  "project": "${REPO}",
  "status": "active",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
MANIFEST_EOF
# Write the active marker pointing to trace #1 (as task-track.sh's init_trace would)
echo "$_T18_TRACE1_ID" > "${TRACE}/.active-tester-${_T18_SESSION}-${_PHASH}"

# Trace #2: created by subagent-start.sh — has summary.md but NO active marker
# (Different session_id = subagent's session, not the orchestrator's)
sleep 1  # ensure trace #2 sorts after trace #1 (newer timestamp)
_T18_TRACE2_ID="tester-$(date +%s)-t18-subagent"
_T18_TRACE2_DIR="${TRACE}/${_T18_TRACE2_ID}"
mkdir -p "${_T18_TRACE2_DIR}/artifacts"
cat > "${_T18_TRACE2_DIR}/summary.md" <<'SUMMARY_EOF'
## Verification Assessment

AUTOVERIFY: CLEAN

**Confidence:** **High**

All features verified. Dual-trace scenario — summary in subagent trace.
SUMMARY_EOF
cat > "${_T18_TRACE2_DIR}/manifest.json" <<MANIFEST_EOF
{
  "trace_id": "${_T18_TRACE2_ID}",
  "agent_type": "tester",
  "session_id": "${_T18_SUBAGENT_SESSION}",
  "project": "${REPO}",
  "status": "completed",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
MANIFEST_EOF
# No .active-tester-* marker for trace #2

# Run post-task.sh with orchestrator's session_id.
# Detection order: marker finds trace #1 (no summary) → session-scan finds trace #1 again
# (session_id matches) → project-scoped scan finds trace #2 (has summary + project match).
(
    export CLAUDE_PROJECT_DIR="$REPO"
    export TRACE_STORE="$TRACE"
    export CLAUDE_SESSION_ID="${_T18_SESSION}"
    cd "$REPO"
    echo '{"tool_name":"Task","tool_input":{"subagent_type":"tester","prompt":"verify"}}' \
        | bash "$POST_TASK_SH" 2>/dev/null
) || true

if [[ -f "$REPO/.claude/.proof-status" ]]; then
    STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
    if [[ "$STATUS" == "verified" ]]; then
        pass_test
    else
        fail_test "Expected 'verified' via project-scoped scan (dual-trace fallback), got '$STATUS'"
    fi
else
    fail_test ".proof-status was deleted (expected verified via dual-trace fallback)"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 19: Keywords in test DESCRIPTIONS should not block auto-verify
#
# Contract: When tester summary has "Medium confidence" and "Partially verified"
#   in test result descriptions (earlier sections, not Verification Assessment),
#   but the actual Verification Assessment says High confidence + no caveats,
#   secondary validation must NOT reject. The section-scoped extraction ensures
#   only the Verification Assessment section is evaluated.
#
# Fixture: summary has test descriptions mentioning Medium/Partially in the
#   Test Results section, but Verification Assessment is clean with High confidence.
# Expected: proof-status = verified
#
# @decision DEC-AV-SECTION-001 (verified by this test)
# ===========================================================================

run_test "T19: keywords in test descriptions, High confidence in VA section → verified"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-pta-trace-XXXXXX")
echo "pending|$(date +%s)" > "$REPO/.claude/.proof-status"

SUMMARY=$(cat <<'SUMMARY_EOF'
## Test Results

- Happy path: AUTOVERIFY: CLEAN + High → verified (T1)
- Rejection: Medium confidence → pending (T2)
- Rejection: Partially verified → pending (T3)

## Verification Assessment

### Coverage
| Area | Status |
|------|--------|
| All tests | Fully verified |

### **Confidence:** **High**

All tests pass.

AUTOVERIFY: CLEAN
SUMMARY_EOF
)

make_tester_trace "$TRACE" "$REPO" "$SUMMARY" > /dev/null
run_post_task "tester" "$REPO" "$TRACE"

if [[ -f "$REPO/.claude/.proof-status" ]]; then
    STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
    if [[ "$STATUS" == "verified" ]]; then
        pass_test
    else
        fail_test "Expected 'verified' (keywords in test descriptions should not block), got '$STATUS'"
    fi
else
    fail_test ".proof-status was deleted"
fi
rm -rf "$REPO" "$TRACE"

# ===========================================================================
# Test 20: Real Medium confidence IN Verification Assessment section → reject
#
# Contract: When "Partially verified" and "Medium" confidence appear in the
#   ACTUAL Verification Assessment section, secondary validation must still
#   reject. This confirms section-scoping didn't break real rejection paths.
#
# Fixture: Verification Assessment has "Partially verified" in coverage table
#   and "Medium" confidence. No keywords anywhere else.
# Expected: proof-status = pending (Medium + Partially verified in actual assessment)
# ===========================================================================

run_test "T20: actual Medium confidence in VA section → stays pending (real rejection path intact)"
REPO=$(make_temp_repo)
TRACE=$(mktemp -d "$PROJECT_ROOT/tmp/test-pta-trace-XXXXXX")
echo "pending|$(date +%s)" > "$REPO/.claude/.proof-status"

SUMMARY=$(cat <<'SUMMARY_EOF'
## Verification Assessment

### Coverage
| Area | Status |
|------|--------|
| Core | Fully verified |
| Edge cases | Partially verified |

### **Confidence:** **Medium**

Some tests incomplete.

AUTOVERIFY: CLEAN
SUMMARY_EOF
)

make_tester_trace "$TRACE" "$REPO" "$SUMMARY" > /dev/null
run_post_task "tester" "$REPO" "$TRACE"

if [[ -f "$REPO/.claude/.proof-status" ]]; then
    STATUS=$(cut -d'|' -f1 "$REPO/.claude/.proof-status")
    if [[ "$STATUS" == "pending" ]]; then
        pass_test
    else
        fail_test "Expected 'pending' (Medium + Partially verified in VA must still reject), got '$STATUS'"
    fi
else
    fail_test ".proof-status was deleted"
fi
rm -rf "$REPO" "$TRACE"

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
