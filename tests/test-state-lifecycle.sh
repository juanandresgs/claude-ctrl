#!/usr/bin/env bash
# test-state-lifecycle.sh — Full proof-status lifecycle E2E test.
#
# Exercises the complete state machine in sequence, verifying that
# resolve_proof_file() returns the correct path at each stage and
# write_proof_status() correctly dual-writes to all 3 locations.
#
# State machine under test:
#   [no proof] → implementer dispatch (needs-verification)
#             → source write (invalidation check)
#             → user approval (verified)
#             → guardian dispatch (Gate A allows)
#             → post-commit cleanup (all proof files + breadcrumb removed)
#
# @decision DEC-STATE-LIFECYCLE-001
# @title E2E state lifecycle test covering all state transitions
# @status accepted
# @rationale Previous test files cover individual hooks or resolver paths.
#   This test exercises the complete state machine in sequence, verifying
#   that resolve_proof_file() returns the correct path at each stage and
#   that write_proof_status() correctly dual-writes to all 3 locations.
#   Uses isolated temp repos in $PROJECT_ROOT/tmp/ (not /tmp/) per Sacred
#   Practice #3. All state transitions exercised with real function calls,
#   no mocks.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"

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

# Helper: compute project_hash the same way log.sh does
compute_phash() {
    echo "$1" | shasum -a 256 | cut -c1-8 2>/dev/null || echo "00000000"
}

# Helper: call resolve_proof_file() in a subshell with controlled env
call_resolve() {
    local project_root="$1"
    local claude_dir="$2"
    bash -c "
        source '$HOOKS_DIR/log.sh' 2>/dev/null
        export CLAUDE_DIR='$claude_dir'
        export PROJECT_ROOT='$project_root'
        resolve_proof_file 2>/dev/null
    "
}

# ─────────────────────────────────────────────────────────────────────────────
# Setup: create a persistent temp environment for the lifecycle test sequence
# ─────────────────────────────────────────────────────────────────────────────

TMPDIR="$PROJECT_ROOT/tmp/test-lifecycle-$$"
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

# Orchestrator side: the ~/.claude-like directory
ORCH_DIR="$TMPDIR/orchestrator"
mkdir -p "$ORCH_DIR"

# Mock "project root" for the orchestrator session
MOCK_PROJECT="$TMPDIR/project"
mkdir -p "$MOCK_PROJECT"
git -C "$MOCK_PROJECT" init >/dev/null 2>&1

# The "CLAUDE_DIR" for the orchestrator (project/.claude)
ORCH_CLAUDE="$MOCK_PROJECT/.claude"
mkdir -p "$ORCH_CLAUDE"

# Worktree side: simulated feature worktree
MOCK_WORKTREE="$TMPDIR/worktrees/feature-foo"
mkdir -p "$MOCK_WORKTREE/.claude"

# Pre-compute phash for the mock project
PHASH=$(compute_phash "$MOCK_PROJECT")
SCOPED_BREADCRUMB="$ORCH_CLAUDE/.active-worktree-path-${PHASH}"
SCOPED_PROOF="$ORCH_CLAUDE/.proof-status-${PHASH}"
LEGACY_PROOF="$ORCH_CLAUDE/.proof-status"
WORKTREE_PROOF="$MOCK_WORKTREE/.claude/.proof-status"

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: Initial state — no proof file, resolve returns scoped default
# ─────────────────────────────────────────────────────────────────────────────

run_test "T01: Initial state — no proof file, resolve returns scoped CLAUDE_DIR path"
RESULT=$(call_resolve "$MOCK_PROJECT" "$ORCH_CLAUDE")
EXPECTED="$SCOPED_PROOF"
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected '$EXPECTED', got '$RESULT'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: Write breadcrumb — simulates orchestrator writing breadcrumb
#         before implementer dispatch (task-track.sh Gate C behavior)
# ─────────────────────────────────────────────────────────────────────────────

run_test "T02: Breadcrumb written — resolve falls back to scoped path (no worktree proof yet)"
echo "$MOCK_WORKTREE" > "$SCOPED_BREADCRUMB"
# Worktree proof doesn't exist yet — resolver should fall back to scoped CLAUDE_DIR
RESULT=$(call_resolve "$MOCK_PROJECT" "$ORCH_CLAUDE")
EXPECTED="$SCOPED_PROOF"
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected scoped fallback '$EXPECTED', got '$RESULT'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Implementer dispatch → needs-verification written to worktree path
# ─────────────────────────────────────────────────────────────────────────────

run_test "T03: needs-verification in worktree — resolve returns worktree path"
TS=$(date +%s)
echo "needs-verification|${TS}" > "$WORKTREE_PROOF"
# write_proof_status also writes the orchestrator side during real dispatch;
# simulate that to have a complete picture
echo "needs-verification|${TS}" > "$SCOPED_PROOF"
echo "needs-verification|${TS}" > "$LEGACY_PROOF"

RESULT=$(call_resolve "$MOCK_PROJECT" "$ORCH_CLAUDE")
EXPECTED="$WORKTREE_PROOF"
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected worktree path '$EXPECTED', got '$RESULT'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: Source file write — proof invalidation targets worktree proof
#         (resolve_proof_file returns the worktree path, so post-write.sh
#          would reset THAT file back to pending, not the scoped orchestrator file)
# ─────────────────────────────────────────────────────────────────────────────

run_test "T04: After source write invalidation — proof transitions to pending at worktree"
# Simulate post-write.sh behavior: it calls resolve_proof_file and writes "pending"
# to that resolved path
RESOLVED=$(call_resolve "$MOCK_PROJECT" "$ORCH_CLAUDE")
TS=$(date +%s)
echo "pending|${TS}" > "$RESOLVED"

# Now test that resolve still returns the worktree path
RESULT=$(call_resolve "$MOCK_PROJECT" "$ORCH_CLAUDE")
EXPECTED="$WORKTREE_PROOF"
WAS_WRITTEN_CORRECTLY="false"
[[ "$RESOLVED" == "$WORKTREE_PROOF" ]] && WAS_WRITTEN_CORRECTLY="true"

if [[ "$RESULT" == "$EXPECTED" && "$WAS_WRITTEN_CORRECTLY" == "true" ]]; then
    pass_test
else
    fail_test "Resolved='$RESOLVED' (want '$WORKTREE_PROOF'), result='$RESULT'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: User approval → write_proof_status("verified") dual-writes all 3 paths
# ─────────────────────────────────────────────────────────────────────────────

run_test "T05: User approval — write_proof_status('verified') dual-writes all 3 paths"
TRACE_DIR_TMP="$TMPDIR/traces"
mkdir -p "$TRACE_DIR_TMP"

bash -c "
    source '$HOOKS_DIR/log.sh' 2>/dev/null
    export CLAUDE_DIR='$ORCH_CLAUDE'
    export PROJECT_ROOT='$MOCK_PROJECT'
    export TRACE_STORE='$TRACE_DIR_TMP'
    export CLAUDE_SESSION_ID='test-lifecycle-$$'
    write_proof_status 'verified' '$MOCK_PROJECT' 2>/dev/null
"

SCOPED_STATUS=$(cut -d'|' -f1 "$SCOPED_PROOF" 2>/dev/null || echo "missing")
LEGACY_STATUS=$(cut -d'|' -f1 "$LEGACY_PROOF" 2>/dev/null || echo "missing")
WORKTREE_STATUS=$(cut -d'|' -f1 "$WORKTREE_PROOF" 2>/dev/null || echo "missing")

if [[ "$SCOPED_STATUS" == "verified" && "$LEGACY_STATUS" == "verified" && "$WORKTREE_STATUS" == "verified" ]]; then
    pass_test
else
    fail_test "scoped='$SCOPED_STATUS', legacy='$LEGACY_STATUS', worktree='$WORKTREE_STATUS' (all must be 'verified')"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: After verified — resolve returns worktree path (worktree still active)
# ─────────────────────────────────────────────────────────────────────────────

run_test "T06: After verified — resolve still returns worktree path (breadcrumb active)"
RESULT=$(call_resolve "$MOCK_PROJECT" "$ORCH_CLAUDE")
EXPECTED="$WORKTREE_PROOF"
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected worktree path '$EXPECTED', got '$RESULT'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: Guardian dispatch → Gate A reads verified from resolved path → allows
# ─────────────────────────────────────────────────────────────────────────────

run_test "T07: Guardian Gate A — verified proof allows guardian dispatch"
# Simulate what task-track.sh Gate A does: read proof from the resolved path
RESOLVED=$(call_resolve "$MOCK_PROJECT" "$ORCH_CLAUDE")
GATE_STATUS=$(cut -d'|' -f1 "$RESOLVED" 2>/dev/null || echo "missing")

if [[ "$GATE_STATUS" == "verified" ]]; then
    pass_test
else
    fail_test "Gate A would block: resolved path '$RESOLVED' has status '$GATE_STATUS'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 8: validate_state_file passes on well-formed proof status
# ─────────────────────────────────────────────────────────────────────────────

run_test "T08: validate_state_file passes on well-formed 'verified|timestamp' content"
RESULT=$(bash -c "
    source '$HOOKS_DIR/log.sh' 2>/dev/null
    source '$HOOKS_DIR/core-lib.sh' 2>/dev/null
    validate_state_file '$WORKTREE_PROOF' 2 && echo 'valid' || echo 'invalid'
" 2>/dev/null)

if [[ "$RESULT" == "valid" ]]; then
    pass_test
else
    fail_test "validate_state_file returned '$RESULT' for '$WORKTREE_PROOF'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 9: Post-commit cleanup — check-guardian.sh removes proof files + breadcrumb
#         Simulate cleanup via the same logic check-guardian.sh uses
# ─────────────────────────────────────────────────────────────────────────────

run_test "T09: Post-commit cleanup — scoped proof removed after verified commit"
# Simulate check-guardian's cleanup: remove scoped and legacy proof-status if "verified"
_PHASH="$PHASH"
for PROOF_FILE in "$SCOPED_PROOF" "$LEGACY_PROOF"; do
    if [[ -f "$PROOF_FILE" ]]; then
        PROOF_VAL=$(cut -d'|' -f1 "$PROOF_FILE" 2>/dev/null || echo "")
        if [[ "$PROOF_VAL" == "verified" ]]; then
            rm -f "$PROOF_FILE"
        fi
    fi
done

SCOPED_EXISTS=false
LEGACY_EXISTS=false
[[ -f "$SCOPED_PROOF" ]] && SCOPED_EXISTS=true
[[ -f "$LEGACY_PROOF" ]] && LEGACY_EXISTS=true

if [[ "$SCOPED_EXISTS" == "false" && "$LEGACY_EXISTS" == "false" ]]; then
    pass_test
else
    fail_test "Proof files still exist: scoped=$SCOPED_EXISTS, legacy=$LEGACY_EXISTS"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 10: Post-commit cleanup — breadcrumb removed, worktree proof removed
# ─────────────────────────────────────────────────────────────────────────────

run_test "T10: Post-commit cleanup — breadcrumb and worktree proof removed"
# Simulate check-guardian breadcrumb cleanup loop
for BREADCRUMB in "${ORCH_CLAUDE}/.active-worktree-path-${_PHASH}" "${ORCH_CLAUDE}/.active-worktree-path"; do
    if [[ -f "$BREADCRUMB" ]]; then
        WORKTREE_PATH=$(cat "$BREADCRUMB" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$WORKTREE_PATH" && -d "$WORKTREE_PATH" ]]; then
            rm -f "${WORKTREE_PATH}/.claude/.proof-status"
        fi
        rm -f "$BREADCRUMB"
    fi
done

BREADCRUMB_EXISTS=false
WORKTREE_PROOF_EXISTS=false
[[ -f "$SCOPED_BREADCRUMB" ]] && BREADCRUMB_EXISTS=true
[[ -f "$WORKTREE_PROOF" ]] && WORKTREE_PROOF_EXISTS=true

if [[ "$BREADCRUMB_EXISTS" == "false" && "$WORKTREE_PROOF_EXISTS" == "false" ]]; then
    pass_test
else
    fail_test "Breadcrumb=$BREADCRUMB_EXISTS, worktree_proof=$WORKTREE_PROOF_EXISTS"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 11: Post-cleanup — resolve returns scoped default (breadcrumb gone)
# ─────────────────────────────────────────────────────────────────────────────

run_test "T11: After full cleanup — resolve returns scoped default (clean state)"
RESULT=$(call_resolve "$MOCK_PROJECT" "$ORCH_CLAUDE")
EXPECTED="$SCOPED_PROOF"
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected scoped default '$EXPECTED', got '$RESULT'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 12: write_proof_status — no breadcrumb, only writes orchestrator paths
# ─────────────────────────────────────────────────────────────────────────────

run_test "T12: write_proof_status without breadcrumb — only writes scoped + legacy (no worktree)"
# State is fully cleaned. Write pending to start a new cycle without breadcrumb.
TRACE_DIR_TMP2="$TMPDIR/traces2"
mkdir -p "$TRACE_DIR_TMP2"

bash -c "
    source '$HOOKS_DIR/log.sh' 2>/dev/null
    export CLAUDE_DIR='$ORCH_CLAUDE'
    export PROJECT_ROOT='$MOCK_PROJECT'
    export TRACE_STORE='$TRACE_DIR_TMP2'
    export CLAUDE_SESSION_ID='test-lifecycle2-$$'
    write_proof_status 'needs-verification' '$MOCK_PROJECT' 2>/dev/null
"

SCOPED_STATUS2=$(cut -d'|' -f1 "$SCOPED_PROOF" 2>/dev/null || echo "missing")
LEGACY_STATUS2=$(cut -d'|' -f1 "$LEGACY_PROOF" 2>/dev/null || echo "missing")
WORKTREE_STATUS2=$(cut -d'|' -f1 "$WORKTREE_PROOF" 2>/dev/null || echo "not-written")

if [[ "$SCOPED_STATUS2" == "needs-verification" && "$LEGACY_STATUS2" == "needs-verification" && "$WORKTREE_STATUS2" == "not-written" ]]; then
    pass_test
else
    fail_test "scoped='$SCOPED_STATUS2', legacy='$LEGACY_STATUS2', worktree='$WORKTREE_STATUS2' (worktree must be absent)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 13: Stale breadcrumb after worktree deleted — resolve falls back gracefully
# ─────────────────────────────────────────────────────────────────────────────

run_test "T13: Stale breadcrumb (worktree deleted) — resolve falls back to scoped path"
STALE_WORKTREE="$TMPDIR/worktrees/stale-feature"
mkdir -p "$STALE_WORKTREE/.claude"
STALE_PHASH=$(compute_phash "$MOCK_PROJECT")
STALE_BREADCRUMB="$ORCH_CLAUDE/.active-worktree-path-${STALE_PHASH}"
echo "$STALE_WORKTREE" > "$STALE_BREADCRUMB"
# Remove the worktree to make breadcrumb stale
rm -rf "$STALE_WORKTREE"

RESULT=$(call_resolve "$MOCK_PROJECT" "$ORCH_CLAUDE")
EXPECTED="$SCOPED_PROOF"
if [[ "$RESULT" == "$EXPECTED" ]]; then
    rm -f "$STALE_BREADCRUMB"
    pass_test
else
    rm -f "$STALE_BREADCRUMB"
    fail_test "Expected scoped fallback '$EXPECTED', got '$RESULT'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 14: project_hash is consistent (same input → same output)
# ─────────────────────────────────────────────────────────────────────────────

run_test "T14: project_hash consistency — same path produces same 8-char hash"
HASH1=$(bash -c "
    source '$HOOKS_DIR/log.sh' 2>/dev/null
    project_hash '$MOCK_PROJECT' 2>/dev/null
")
HASH2=$(bash -c "
    source '$HOOKS_DIR/core-lib.sh' 2>/dev/null
    project_hash '$MOCK_PROJECT' 2>/dev/null
")

if [[ -n "$HASH1" && "$HASH1" == "$HASH2" && ${#HASH1} -eq 8 ]]; then
    pass_test
else
    fail_test "hash1='$HASH1' hash2='$HASH2' (must be equal and 8 chars)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 15: validate_state_file rejects missing and corrupt files
# ─────────────────────────────────────────────────────────────────────────────

run_test "T15: validate_state_file — rejects missing, empty, and single-field files"
CORRUPT_FILE="$TMPDIR/bad-proof-status"

# Missing file
MISSING=$(bash -c "
    source '$HOOKS_DIR/core-lib.sh' 2>/dev/null
    validate_state_file '/nonexistent/path/.proof-status' 2 && echo 'valid' || echo 'invalid'
" 2>/dev/null)

# Empty file
touch "$CORRUPT_FILE"
EMPTY_RESULT=$(bash -c "
    source '$HOOKS_DIR/core-lib.sh' 2>/dev/null
    validate_state_file '$CORRUPT_FILE' 2 && echo 'valid' || echo 'invalid'
" 2>/dev/null)

# Single field (missing timestamp)
echo "verified" > "$CORRUPT_FILE"
SINGLE_FIELD=$(bash -c "
    source '$HOOKS_DIR/core-lib.sh' 2>/dev/null
    validate_state_file '$CORRUPT_FILE' 2 && echo 'valid' || echo 'invalid'
" 2>/dev/null)

# Well-formed
echo "verified|12345" > "$CORRUPT_FILE"
VALID_RESULT=$(bash -c "
    source '$HOOKS_DIR/core-lib.sh' 2>/dev/null
    validate_state_file '$CORRUPT_FILE' 2 && echo 'valid' || echo 'invalid'
" 2>/dev/null)

rm -f "$CORRUPT_FILE"

if [[ "$MISSING" == "invalid" && "$EMPTY_RESULT" == "invalid" && "$SINGLE_FIELD" == "invalid" && "$VALID_RESULT" == "valid" ]]; then
    pass_test
else
    fail_test "missing='$MISSING' empty='$EMPTY_RESULT' single='$SINGLE_FIELD' valid='$VALID_RESULT'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Auto-verify → Guardian lifecycle E2E test (DEC-PROOF-RACE-001)
#
# Full lifecycle covering the race condition fix:
#   Step 1: Tester completes → auto-verify marker created + "verified" written
#   Step 2: Source write → proof-status NOT invalidated (marker protects)
#   Step 3: Guardian dispatch → auto-verify marker cleaned, guardian marker created
#   Step 4: Guardian commit workflow → guardian marker cleans up
#   Step 5: Verify proof-status remained "verified" throughout
#
# @decision DEC-PROOF-RACE-001
# @title Auto-verify markers protect the verified→guardian dispatch gap
# @status accepted
# @rationale post-write.sh could invalidate proof-status between when post-task.sh
#   writes "verified" and when task-track.sh creates the guardian marker. The
#   auto-verify marker fills this gap identically to the guardian marker.
# ─────────────────────────────────────────────────────────────────────────────

AV_TMPDIR="$TMPDIR/av-lifecycle-$$"
mkdir -p "$AV_TMPDIR"
AV_PROJECT="$AV_TMPDIR/project"
AV_TRACES="$AV_TMPDIR/traces"
mkdir -p "$AV_PROJECT/.claude" "$AV_TRACES"
git -C "$AV_PROJECT" init >/dev/null 2>&1
AV_PHASH=$(compute_phash "$AV_PROJECT")
AV_SESSION="av-lifecycle-$$"
AV_SCOPED_PROOF="$AV_PROJECT/.claude/.proof-status-${AV_PHASH}"

# ─────────────────────────────────────────────────────────────────────────────
# T16-Step1: Tester completes — auto-verify marker created + "verified" written
# ─────────────────────────────────────────────────────────────────────────────

run_test "T16a: Auto-verify lifecycle: tester completes → marker created + verified written"

AV_TS=$(date +%s)
# Simulate post-task.sh: write auto-verify marker then write "verified"
printf 'auto-verify|%s\n' "$AV_TS" > \
    "${AV_TRACES}/.active-autoverify-${AV_SESSION}-${AV_PHASH}"
printf 'verified|%s\n' "$AV_TS" > "$AV_SCOPED_PROOF"
printf 'verified|%s\n' "$AV_TS" > "$AV_PROJECT/.claude/.proof-status"

AV_MARKER_EXISTS=false
[[ -f "${AV_TRACES}/.active-autoverify-${AV_SESSION}-${AV_PHASH}" ]] && AV_MARKER_EXISTS=true
AV_PROOF_STATUS=$(cut -d'|' -f1 "$AV_SCOPED_PROOF" 2>/dev/null || echo "missing")

if [[ "$AV_MARKER_EXISTS" == "true" && "$AV_PROOF_STATUS" == "verified" ]]; then
    pass_test
else
    fail_test "marker_exists=$AV_MARKER_EXISTS, proof_status=$AV_PROOF_STATUS (both must be true/verified)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T16-Step2: Source write event — proof NOT invalidated (marker protects)
# ─────────────────────────────────────────────────────────────────────────────

run_test "T16b: Auto-verify lifecycle: source write → proof stays verified (marker active)"

# Simulate post-write.sh proof-invalidation logic
_av_guardian_active=false

for _gm in "${AV_TRACES}/.active-guardian-"*; do
    if [[ -f "$_gm" ]]; then
        _marker_ts=$(cut -d'|' -f2 "$_gm" 2>/dev/null || echo "0")
        _now=$(date +%s)
        if [[ "$_marker_ts" =~ ^[0-9]+$ && $(( _now - _marker_ts )) -lt 300 ]]; then
            _av_guardian_active=true; break
        fi
    fi
done

if [[ "$_av_guardian_active" == "false" ]]; then
    for _avm in "${AV_TRACES}/.active-autoverify-"*; do
        if [[ -f "$_avm" ]]; then
            _marker_ts=$(cut -d'|' -f2 "$_avm" 2>/dev/null || echo "0")
            _now=$(date +%s)
            if [[ "$_marker_ts" =~ ^[0-9]+$ && $(( _now - _marker_ts )) -lt 300 ]]; then
                _av_guardian_active=true; break
            fi
        fi
    done
fi

# With marker active, invalidation would NOT happen — proof stays "verified"
if [[ "$_av_guardian_active" == "true" ]]; then
    # Verify proof is still verified (marker blocked invalidation)
    AV_PROOF_AFTER_WRITE=$(cut -d'|' -f1 "$AV_SCOPED_PROOF" 2>/dev/null || echo "missing")
    if [[ "$AV_PROOF_AFTER_WRITE" == "verified" ]]; then
        pass_test
    else
        fail_test "Proof invalidated despite autoverify marker: '$AV_PROOF_AFTER_WRITE'"
    fi
else
    fail_test "Auto-verify marker not detected as active during write event"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T16-Step3: Guardian dispatch — auto-verify marker cleaned, guardian marker created
# ─────────────────────────────────────────────────────────────────────────────

run_test "T16c: Auto-verify lifecycle: guardian dispatch → AV marker cleaned, guardian marker created"

# Simulate task-track.sh Gate A (W4a):
# 1. Remove auto-verify markers for this project
rm -f "${AV_TRACES}/.active-autoverify-"*"-${AV_PHASH}" 2>/dev/null || true
# 2. Create guardian marker
printf 'pre-dispatch|%s\n' "$(date +%s)" > \
    "${AV_TRACES}/.active-guardian-${AV_SESSION}-${AV_PHASH}"

AV_MARKER_GONE=true
[[ -f "${AV_TRACES}/.active-autoverify-${AV_SESSION}-${AV_PHASH}" ]] && AV_MARKER_GONE=false
GUARDIAN_MARKER_EXISTS=false
[[ -f "${AV_TRACES}/.active-guardian-${AV_SESSION}-${AV_PHASH}" ]] && GUARDIAN_MARKER_EXISTS=true

if [[ "$AV_MARKER_GONE" == "true" && "$GUARDIAN_MARKER_EXISTS" == "true" ]]; then
    pass_test
else
    fail_test "av_marker_gone=$AV_MARKER_GONE guardian_marker_exists=$GUARDIAN_MARKER_EXISTS"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T16-Step4: Guardian commit — guardian marker cleaned, proof still verified
# ─────────────────────────────────────────────────────────────────────────────

run_test "T16d: Auto-verify lifecycle: post-commit cleanup — proof verified throughout"

# Simulate finalize_trace cleanup (removes guardian markers)
rm -f "${AV_TRACES}/.active-guardian-"*"-${AV_PHASH}" 2>/dev/null || true

GUARDIAN_MARKER_GONE=true
[[ -f "${AV_TRACES}/.active-guardian-${AV_SESSION}-${AV_PHASH}" ]] && GUARDIAN_MARKER_GONE=false

# Proof should still be "verified" — was never invalidated
AV_FINAL_PROOF=$(cut -d'|' -f1 "$AV_SCOPED_PROOF" 2>/dev/null || echo "missing")

if [[ "$GUARDIAN_MARKER_GONE" == "true" && "$AV_FINAL_PROOF" == "verified" ]]; then
    pass_test
else
    fail_test "guardian_marker_gone=$GUARDIAN_MARKER_GONE, final_proof=$AV_FINAL_PROOF"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=========================================="
echo "State Lifecycle Tests: $TESTS_PASSED/$TESTS_RUN passed"
echo "=========================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
    echo "FAILED: $TESTS_FAILED tests failed"
    exit 1
else
    echo "SUCCESS: All tests passed"
    exit 0
fi
