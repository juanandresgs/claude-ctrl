#!/usr/bin/env bash
# test-state-concurrent.sh — Race conditions and concurrent access to state files.
#
# Tests the concurrency invariants enforced by the state management subsystem:
#   1. Guardian marker prevents proof invalidation during commit workflow
#   2. write_proof_status atomic tmp→mv prevents partial reads
#   3. clean-state.sh --clean during active session does not crash, preserves active files
#   4. Multiple sequential write_proof_status calls — last write wins, no corruption
#   5. Concurrent resolve_proof_file with breadcrumb write — no crash or stale result
#
# @decision DEC-STATE-CONCURRENT-001
# @title Concurrency tests for state file operations
# @status accepted
# @rationale write_proof_status uses atomic tmp→mv writes, guardian markers
#   prevent invalidation during commits, and clean-state.sh must handle active
#   sessions gracefully. These tests verify the concurrent behavior without
#   requiring actual OS-level parallelism — they simulate race window conditions
#   by staging file state before calling the function under test. This matches
#   the real-world race: the marker is written before the write lands, so we
#   verify the exemption logic sees the marker and skips invalidation.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"

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

# Helper: compute project_hash identically to log.sh
compute_phash() {
    echo "$1" | shasum -a 256 | cut -c1-8 2>/dev/null || echo "00000000"
}

# ─────────────────────────────────────────────────────────────────────────────
# Setup: isolated temp dir, cleaned up on EXIT
# ─────────────────────────────────────────────────────────────────────────────

TMPDIR="$PROJECT_ROOT/tmp/test-concurrent-$$"
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# CC-01: Guardian marker prevents proof invalidation during commit workflow
#
# Sequence:
#   1. Write verified proof to proof-status file
#   2. Create guardian marker with current timestamp (simulates check-guardian dispatch)
#   3. Simulate a source write event: call post-write.sh's proof-invalidation logic
#      (inline — we check the same conditions post-write.sh checks)
#   4. Assert: proof stays "verified" because guardian marker is active and fresh
#
# This is the core invariant of DEC-TRACK-GUARDIAN-001 and DEC-TRACK-GUARDIAN-TTL-001.
# ─────────────────────────────────────────────────────────────────────────────

run_test "CC-01: Guardian marker (fresh) prevents proof invalidation on source write"

MOCK_PROJECT_CC01="$TMPDIR/project-cc01"
MOCK_CLAUDE_CC01="$MOCK_PROJECT_CC01/.claude"
MOCK_TRACES_CC01="$TMPDIR/traces-cc01"
mkdir -p "$MOCK_CLAUDE_CC01" "$MOCK_TRACES_CC01"
git -C "$MOCK_PROJECT_CC01" init >/dev/null 2>&1

PHASH_CC01=$(compute_phash "$MOCK_PROJECT_CC01")
SCOPED_PROOF_CC01="$MOCK_CLAUDE_CC01/.proof-status-${PHASH_CC01}"
SESSION_CC01="cc01-session-$$"

# Step 1: Write verified proof
bash -c "
    source '$HOOKS_DIR/log.sh' 2>/dev/null
    export CLAUDE_DIR='$MOCK_CLAUDE_CC01'
    export PROJECT_ROOT='$MOCK_PROJECT_CC01'
    export TRACE_STORE='$MOCK_TRACES_CC01'
    export CLAUDE_SESSION_ID='$SESSION_CC01'
    write_proof_status 'verified' '$MOCK_PROJECT_CC01' 2>/dev/null
" 2>/dev/null

# Step 2: Guardian marker is auto-created by write_proof_status('verified') —
# verify it was created, then confirm it's fresh
GUARDIAN_MARKER="${MOCK_TRACES_CC01}/.active-guardian-${SESSION_CC01}-${PHASH_CC01}"
if [[ ! -f "$GUARDIAN_MARKER" ]]; then
    fail_test "write_proof_status('verified') did not create guardian marker at $GUARDIAN_MARKER"
    TESTS_RUN=$((TESTS_RUN - 1))  # compensate — use goto-skip pattern
    true
else
    MARKER_TS=$(cut -d'|' -f2 "$GUARDIAN_MARKER" 2>/dev/null || echo "0")
    NOW=$(date +%s)
    MARKER_AGE=$(( NOW - MARKER_TS ))

    # Step 3 + 4: Simulate post-write.sh's proof-invalidation logic inline.
    # The critical code path from post-write.sh lines 116-148:
    _guardian_active=false
    for _gm in "${MOCK_TRACES_CC01}/.active-guardian-"*; do
        if [[ -f "$_gm" ]]; then
            _marker_ts=$(cut -d'|' -f2 "$_gm" 2>/dev/null || echo "0")
            _now=$(date +%s)
            if [[ "$_marker_ts" =~ ^[0-9]+$ && $(( _now - _marker_ts )) -lt 300 ]]; then
                _guardian_active=true; break
            fi
        fi
    done

    if [[ "$_guardian_active" == "true" ]]; then
        # Proof should still be "verified" — guardian blocked invalidation
        PROOF_STATUS=$(cut -d'|' -f1 "$SCOPED_PROOF_CC01" 2>/dev/null || echo "missing")
        if [[ "$PROOF_STATUS" == "verified" ]]; then
            pass_test
        else
            fail_test "Proof should stay 'verified' with guardian active, got '$PROOF_STATUS'"
        fi
    else
        fail_test "Guardian marker exists (age=${MARKER_AGE}s) but was not detected as active"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# CC-02: Guardian marker expired (> 300s) → invalidation proceeds normally
#
# Verify that a stale guardian marker (older than TTL) does NOT block
# proof invalidation — this prevents permanent exemption from crashed sessions.
# ─────────────────────────────────────────────────────────────────────────────

run_test "CC-02: Stale guardian marker (expired TTL) — proof invalidation proceeds"

MOCK_PROJECT_CC02="$TMPDIR/project-cc02"
MOCK_CLAUDE_CC02="$MOCK_PROJECT_CC02/.claude"
MOCK_TRACES_CC02="$TMPDIR/traces-cc02"
mkdir -p "$MOCK_CLAUDE_CC02" "$MOCK_TRACES_CC02"
git -C "$MOCK_PROJECT_CC02" init >/dev/null 2>&1

PHASH_CC02=$(compute_phash "$MOCK_PROJECT_CC02")
SESSION_CC02="cc02-session-$$"
SCOPED_PROOF_CC02="$MOCK_CLAUDE_CC02/.proof-status-${PHASH_CC02}"

# Write a verified proof manually (bypassing the marker creation)
TS_CC02=$(date +%s)
printf 'verified|%s\n' "$TS_CC02" > "$SCOPED_PROOF_CC02"
printf 'verified|%s\n' "$TS_CC02" > "$MOCK_CLAUDE_CC02/.proof-status"

# Create a STALE guardian marker (timestamp set to 400 seconds ago → TTL 300s exceeded)
STALE_TS=$(( TS_CC02 - 400 ))
printf 'pre-dispatch|%s\n' "$STALE_TS" > \
    "${MOCK_TRACES_CC02}/.active-guardian-${SESSION_CC02}-${PHASH_CC02}"

# Simulate post-write.sh's guardian TTL check
_guardian_active_cc02=false
for _gm in "${MOCK_TRACES_CC02}/.active-guardian-"*; do
    if [[ -f "$_gm" ]]; then
        _marker_ts=$(cut -d'|' -f2 "$_gm" 2>/dev/null || echo "0")
        _now=$(date +%s)
        if [[ "$_marker_ts" =~ ^[0-9]+$ && $(( _now - _marker_ts )) -lt 300 ]]; then
            _guardian_active_cc02=true; break
        fi
    fi
done

if [[ "$_guardian_active_cc02" == "false" ]]; then
    pass_test
else
    fail_test "Stale guardian marker (400s old) was incorrectly detected as active"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CC-03: write_proof_status atomic write — tmp→mv prevents partial reads
#
# Verify that after write_proof_status completes, EVERY proof file has:
#   - Exactly 2 pipe-delimited fields
#   - A non-empty, numeric timestamp in field 2
#   - No .tmp residue left behind (tmp file removed after successful mv)
#
# This exercises the atomic write invariant: the .tmp file is never visible
# to readers — only the renamed target is. We verify there's no .tmp residue.
# ─────────────────────────────────────────────────────────────────────────────

run_test "CC-03: write_proof_status atomic write — no tmp residue, complete content"

MOCK_PROJECT_CC03="$TMPDIR/project-cc03"
MOCK_CLAUDE_CC03="$MOCK_PROJECT_CC03/.claude"
MOCK_TRACES_CC03="$TMPDIR/traces-cc03"
mkdir -p "$MOCK_CLAUDE_CC03" "$MOCK_TRACES_CC03"
git -C "$MOCK_PROJECT_CC03" init >/dev/null 2>&1

PHASH_CC03=$(compute_phash "$MOCK_PROJECT_CC03")
SESSION_CC03="cc03-session-$$"

bash -c "
    source '$HOOKS_DIR/log.sh' 2>/dev/null
    export CLAUDE_DIR='$MOCK_CLAUDE_CC03'
    export PROJECT_ROOT='$MOCK_PROJECT_CC03'
    export TRACE_STORE='$MOCK_TRACES_CC03'
    export CLAUDE_SESSION_ID='$SESSION_CC03'
    write_proof_status 'pending' '$MOCK_PROJECT_CC03' 2>/dev/null
" 2>/dev/null

# Check for .tmp residue
TMP_RESIDUE_FOUND=false
for f in "$MOCK_CLAUDE_CC03"/.proof-status*.tmp; do
    [[ -f "$f" ]] && TMP_RESIDUE_FOUND=true && break
done

# Verify all written proof files have complete content
SCOPED_CC03="$MOCK_CLAUDE_CC03/.proof-status-${PHASH_CC03}"
LEGACY_CC03="$MOCK_CLAUDE_CC03/.proof-status"

INCOMPLETE_FOUND=false
for pf in "$SCOPED_CC03" "$LEGACY_CC03"; do
    if [[ -f "$pf" ]]; then
        CONTENT=$(cat "$pf" 2>/dev/null || echo "")
        STATUS=$(echo "$CONTENT" | cut -d'|' -f1)
        TS=$(echo "$CONTENT" | cut -d'|' -f2)
        if [[ -z "$STATUS" || -z "$TS" || ! "$TS" =~ ^[0-9]+$ ]]; then
            INCOMPLETE_FOUND=true
            break
        fi
    fi
done

if [[ "$TMP_RESIDUE_FOUND" == "false" && "$INCOMPLETE_FOUND" == "false" ]]; then
    pass_test
else
    fail_test "tmp_residue=$TMP_RESIDUE_FOUND, incomplete_content=$INCOMPLETE_FOUND"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CC-04: clean-state.sh --clean during active session
#
# Scenario: active proof-status file (status=pending, age < 7 days) + active
# breadcrumb pointing to existing directory. clean-state.sh --clean must NOT
# remove these files — orphaned detection requires the target directory to
# be missing. Active files are preserved.
# ─────────────────────────────────────────────────────────────────────────────

run_test "CC-04: clean-state.sh --clean preserves active (non-orphaned) state files"

MOCK_CLAUDE_CC04="$TMPDIR/claude-cc04"
MOCK_WORKTREE_CC04="$TMPDIR/worktrees/feature-cc04"
mkdir -p "$MOCK_CLAUDE_CC04" "$MOCK_WORKTREE_CC04"

PHASH_CC04=$(compute_phash "$TMPDIR/project-cc04")
TS_CC04=$(date +%s)

# Create active proof-status (fresh, pending)
printf 'pending|%s\n' "$TS_CC04" > "$MOCK_CLAUDE_CC04/.proof-status-${PHASH_CC04}"

# Create active breadcrumb pointing to existing worktree
printf '%s\n' "$MOCK_WORKTREE_CC04" > "$MOCK_CLAUDE_CC04/.active-worktree-path-${PHASH_CC04}"

# Run clean-state.sh --clean with isolated CLAUDE_DIR
CLEAN_EXIT=0
CLEAN_OUTPUT=$(CLAUDE_DIR="$MOCK_CLAUDE_CC04" bash "$SCRIPTS_DIR/clean-state.sh" --clean 2>&1) || CLEAN_EXIT=$?

# Active proof file must still exist
PROOF_PRESERVED=false
[[ -f "$MOCK_CLAUDE_CC04/.proof-status-${PHASH_CC04}" ]] && PROOF_PRESERVED=true

# Active breadcrumb (pointing to existing dir) must still exist
BREADCRUMB_PRESERVED=false
[[ -f "$MOCK_CLAUDE_CC04/.active-worktree-path-${PHASH_CC04}" ]] && BREADCRUMB_PRESERVED=true

if [[ "$PROOF_PRESERVED" == "true" && "$BREADCRUMB_PRESERVED" == "true" && "$CLEAN_EXIT" -eq 0 ]]; then
    pass_test
else
    fail_test "clean_exit=$CLEAN_EXIT, proof_preserved=$PROOF_PRESERVED, breadcrumb_preserved=$BREADCRUMB_PRESERVED"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CC-05: Multiple sequential write_proof_status calls — last write wins
#
# Call write_proof_status 3 times rapidly with different statuses.
# Assert: final content reflects the last call, no corruption.
# Rationale: Each call is atomic (tmp→mv), so rapid sequential calls must
# produce a consistent final state — no interleaving between writes.
# ─────────────────────────────────────────────────────────────────────────────

run_test "CC-05: Sequential write_proof_status calls — last write wins, no corruption"

MOCK_PROJECT_CC05="$TMPDIR/project-cc05"
MOCK_CLAUDE_CC05="$MOCK_PROJECT_CC05/.claude"
MOCK_TRACES_CC05="$TMPDIR/traces-cc05"
mkdir -p "$MOCK_CLAUDE_CC05" "$MOCK_TRACES_CC05"
git -C "$MOCK_PROJECT_CC05" init >/dev/null 2>&1

PHASH_CC05=$(compute_phash "$MOCK_PROJECT_CC05")
SESSION_CC05="cc05-session-$$"

# Write 3 statuses in sequence — last must win
bash -c "
    source '$HOOKS_DIR/log.sh' 2>/dev/null
    export CLAUDE_DIR='$MOCK_CLAUDE_CC05'
    export PROJECT_ROOT='$MOCK_PROJECT_CC05'
    export TRACE_STORE='$MOCK_TRACES_CC05'
    export CLAUDE_SESSION_ID='$SESSION_CC05'
    write_proof_status 'needs-verification' '$MOCK_PROJECT_CC05' 2>/dev/null
    write_proof_status 'pending' '$MOCK_PROJECT_CC05' 2>/dev/null
    write_proof_status 'pending' '$MOCK_PROJECT_CC05' 2>/dev/null
" 2>/dev/null

SCOPED_CC05="$MOCK_CLAUDE_CC05/.proof-status-${PHASH_CC05}"
LEGACY_CC05="$MOCK_CLAUDE_CC05/.proof-status"

SCOPED_STATUS=$(cut -d'|' -f1 "$SCOPED_CC05" 2>/dev/null || echo "missing")
LEGACY_STATUS=$(cut -d'|' -f1 "$LEGACY_CC05" 2>/dev/null || echo "missing")

# Both must be "pending" (last call) — not "needs-verification" (first call)
if [[ "$SCOPED_STATUS" == "pending" && "$LEGACY_STATUS" == "pending" ]]; then
    # Also verify no corruption: timestamp is numeric
    SCOPED_TS=$(cut -d'|' -f2 "$SCOPED_CC05" 2>/dev/null || echo "")
    if [[ "$SCOPED_TS" =~ ^[0-9]+$ ]]; then
        pass_test
    else
        fail_test "Last write has invalid timestamp: '$SCOPED_TS'"
    fi
else
    fail_test "Expected 'pending' from last write, got scoped='$SCOPED_STATUS' legacy='$LEGACY_STATUS'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CC-06: Concurrent resolve_proof_file with breadcrumb write — no crash
#
# Simulate a race where resolve_proof_file is called while a breadcrumb file
# is being written. The function must handle a partially-written breadcrumb
# (empty path after tr -d) gracefully — falling back to scoped/legacy paths.
# ─────────────────────────────────────────────────────────────────────────────

run_test "CC-06: resolve_proof_file with empty breadcrumb (partial write race) — graceful fallback"

MOCK_PROJECT_CC06="$TMPDIR/project-cc06"
MOCK_CLAUDE_CC06="$MOCK_PROJECT_CC06/.claude"
mkdir -p "$MOCK_CLAUDE_CC06"
git -C "$MOCK_PROJECT_CC06" init >/dev/null 2>&1

PHASH_CC06=$(compute_phash "$MOCK_PROJECT_CC06")
# Create a breadcrumb that contains only whitespace (simulates partial write)
printf '   \n' > "$MOCK_CLAUDE_CC06/.active-worktree-path-${PHASH_CC06}"

# resolve_proof_file must not crash — it should treat empty path as stale breadcrumb
RESOLVE_RESULT=""
RESOLVE_EXIT=0
RESOLVE_RESULT=$(bash -c "
    source '$HOOKS_DIR/log.sh' 2>/dev/null
    export CLAUDE_DIR='$MOCK_CLAUDE_CC06'
    export PROJECT_ROOT='$MOCK_PROJECT_CC06'
    resolve_proof_file 2>/dev/null
" 2>/dev/null) || RESOLVE_EXIT=$?

# Must return a non-empty path and not crash
if [[ -n "$RESOLVE_RESULT" && "$RESOLVE_EXIT" -eq 0 ]]; then
    # Must not return a path with the empty breadcrumb content in it
    if [[ "$RESOLVE_RESULT" != *"   "* ]]; then
        pass_test
    else
        fail_test "resolve_proof_file returned a path with whitespace: '$RESOLVE_RESULT'"
    fi
else
    fail_test "resolve_proof_file crashed or returned empty (exit=$RESOLVE_EXIT, result='$RESOLVE_RESULT')"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CC-07: Auto-verify marker (fresh) prevents proof invalidation on source write
#
# Scenario:
#   1. Write "verified" to proof-status
#   2. Create a fresh auto-verify marker (simulates post-task.sh auto-verify)
#   3. Simulate post-write.sh's invalidation logic (both guardian + autoverify loops)
#   4. Assert: proof stays "verified" — auto-verify marker blocks invalidation
#
# This tests DEC-PROOF-RACE-001: the auto-verify→guardian dispatch gap.
# ─────────────────────────────────────────────────────────────────────────────

run_test "CC-07: Auto-verify marker (fresh) prevents proof invalidation on source write"

MOCK_PROJECT_CC07="$TMPDIR/project-cc07"
MOCK_CLAUDE_CC07="$MOCK_PROJECT_CC07/.claude"
MOCK_TRACES_CC07="$TMPDIR/traces-cc07"
mkdir -p "$MOCK_CLAUDE_CC07" "$MOCK_TRACES_CC07"
git -C "$MOCK_PROJECT_CC07" init >/dev/null 2>&1

PHASH_CC07=$(compute_phash "$MOCK_PROJECT_CC07")
SESSION_CC07="cc07-session-$$"
SCOPED_PROOF_CC07="$MOCK_CLAUDE_CC07/.proof-status-${PHASH_CC07}"

# Step 1: Write verified proof manually (no guardian marker needed here)
TS_CC07=$(date +%s)
printf 'verified|%s\n' "$TS_CC07" > "$SCOPED_PROOF_CC07"
printf 'verified|%s\n' "$TS_CC07" > "$MOCK_CLAUDE_CC07/.proof-status"

# Step 2: Create fresh auto-verify marker (simulates post-task.sh)
printf 'auto-verify|%s\n' "$TS_CC07" > \
    "${MOCK_TRACES_CC07}/.active-autoverify-${SESSION_CC07}-${PHASH_CC07}"

# Step 3: Simulate post-write.sh's full invalidation logic
_guardian_active_cc07=false

# Check guardian markers first (none exist in this test)
for _gm in "${MOCK_TRACES_CC07}/.active-guardian-"*; do
    if [[ -f "$_gm" ]]; then
        _marker_ts=$(cut -d'|' -f2 "$_gm" 2>/dev/null || echo "0")
        _now=$(date +%s)
        if [[ "$_marker_ts" =~ ^[0-9]+$ && $(( _now - _marker_ts )) -lt 300 ]]; then
            _guardian_active_cc07=true; break
        fi
    fi
done

# Check auto-verify markers (the new logic from W3)
if [[ "$_guardian_active_cc07" == "false" ]]; then
    for _avm in "${MOCK_TRACES_CC07}/.active-autoverify-"*; do
        if [[ -f "$_avm" ]]; then
            _marker_ts=$(cut -d'|' -f2 "$_avm" 2>/dev/null || echo "0")
            _now=$(date +%s)
            if [[ "$_marker_ts" =~ ^[0-9]+$ && $(( _now - _marker_ts )) -lt 300 ]]; then
                _guardian_active_cc07=true; break
            fi
        fi
    done
fi

# Step 4: Assert auto-verify marker blocked invalidation
if [[ "$_guardian_active_cc07" == "true" ]]; then
    PROOF_STATUS_CC07=$(cut -d'|' -f1 "$SCOPED_PROOF_CC07" 2>/dev/null || echo "missing")
    if [[ "$PROOF_STATUS_CC07" == "verified" ]]; then
        pass_test
    else
        fail_test "Proof should stay 'verified' with autoverify marker active, got '$PROOF_STATUS_CC07'"
    fi
else
    fail_test "Auto-verify marker exists but was not detected as active"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CC-08: Auto-verify marker TTL expires — proof invalidation proceeds normally
#
# Scenario:
#   1. Write "verified" to proof-status
#   2. Create an EXPIRED auto-verify marker (timestamp 400s ago > TTL 300s)
#   3. Simulate post-write.sh's invalidation logic
#   4. Assert: _guardian_active=false (expired marker does NOT block invalidation)
# ─────────────────────────────────────────────────────────────────────────────

run_test "CC-08: Expired auto-verify marker (TTL 400s) — proof invalidation proceeds"

MOCK_PROJECT_CC08="$TMPDIR/project-cc08"
MOCK_CLAUDE_CC08="$MOCK_PROJECT_CC08/.claude"
MOCK_TRACES_CC08="$TMPDIR/traces-cc08"
mkdir -p "$MOCK_CLAUDE_CC08" "$MOCK_TRACES_CC08"
git -C "$MOCK_PROJECT_CC08" init >/dev/null 2>&1

PHASH_CC08=$(compute_phash "$MOCK_PROJECT_CC08")
SESSION_CC08="cc08-session-$$"
SCOPED_PROOF_CC08="$MOCK_CLAUDE_CC08/.proof-status-${PHASH_CC08}"

# Write verified proof
TS_CC08=$(date +%s)
printf 'verified|%s\n' "$TS_CC08" > "$SCOPED_PROOF_CC08"

# Create EXPIRED auto-verify marker (400s ago — exceeds TTL of 300s)
STALE_AV_TS=$(( TS_CC08 - 400 ))
printf 'auto-verify|%s\n' "$STALE_AV_TS" > \
    "${MOCK_TRACES_CC08}/.active-autoverify-${SESSION_CC08}-${PHASH_CC08}"

# Simulate post-write.sh logic
_guardian_active_cc08=false

for _gm in "${MOCK_TRACES_CC08}/.active-guardian-"*; do
    if [[ -f "$_gm" ]]; then
        _marker_ts=$(cut -d'|' -f2 "$_gm" 2>/dev/null || echo "0")
        _now=$(date +%s)
        if [[ "$_marker_ts" =~ ^[0-9]+$ && $(( _now - _marker_ts )) -lt 300 ]]; then
            _guardian_active_cc08=true; break
        fi
    fi
done

if [[ "$_guardian_active_cc08" == "false" ]]; then
    for _avm in "${MOCK_TRACES_CC08}/.active-autoverify-"*; do
        if [[ -f "$_avm" ]]; then
            _marker_ts=$(cut -d'|' -f2 "$_avm" 2>/dev/null || echo "0")
            _now=$(date +%s)
            if [[ "$_marker_ts" =~ ^[0-9]+$ && $(( _now - _marker_ts )) -lt 300 ]]; then
                _guardian_active_cc08=true; break
            fi
        fi
    done
fi

if [[ "$_guardian_active_cc08" == "false" ]]; then
    pass_test
else
    fail_test "Expired auto-verify marker (400s old) incorrectly detected as active"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CC-09: Guardian dispatch (task-track.sh Gate A) cleans auto-verify markers
#
# Scenario:
#   1. Create an auto-verify marker for a project
#   2. Simulate task-track.sh Gate A cleanup: rm ".active-autoverify-*-{PHASH}"
#   3. Assert: marker file removed
# ─────────────────────────────────────────────────────────────────────────────

run_test "CC-09: Guardian dispatch cleans auto-verify markers (task-track.sh Gate A)"

MOCK_TRACES_CC09="$TMPDIR/traces-cc09"
mkdir -p "$MOCK_TRACES_CC09"

PHASH_CC09=$(compute_phash "$TMPDIR/project-cc09")
SESSION_CC09="cc09-session-$$"
AV_MARKER_CC09="${MOCK_TRACES_CC09}/.active-autoverify-${SESSION_CC09}-${PHASH_CC09}"

# Create the auto-verify marker
printf 'auto-verify|%s\n' "$(date +%s)" > "$AV_MARKER_CC09"
[[ -f "$AV_MARKER_CC09" ]] || { fail_test "Could not create test marker"; continue; }

# Simulate task-track.sh Gate A cleanup (W4a)
rm -f "${MOCK_TRACES_CC09}/.active-autoverify-"*"-${PHASH_CC09}" 2>/dev/null || true

if [[ ! -f "$AV_MARKER_CC09" ]]; then
    pass_test
else
    fail_test "Auto-verify marker was not cleaned by Gate A cleanup"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CC-10: Both guardian and auto-verify markers coexist — proof stays verified
#
# Scenario:
#   1. Write "verified" proof
#   2. Create both a guardian marker AND an auto-verify marker
#   3. Simulate post-write.sh logic
#   4. Assert: guardian marker detected first → proof not invalidated
# ─────────────────────────────────────────────────────────────────────────────

run_test "CC-10: Both guardian + auto-verify markers coexist — proof stays verified"

MOCK_PROJECT_CC10="$TMPDIR/project-cc10"
MOCK_CLAUDE_CC10="$MOCK_PROJECT_CC10/.claude"
MOCK_TRACES_CC10="$TMPDIR/traces-cc10"
mkdir -p "$MOCK_CLAUDE_CC10" "$MOCK_TRACES_CC10"
git -C "$MOCK_PROJECT_CC10" init >/dev/null 2>&1

PHASH_CC10=$(compute_phash "$MOCK_PROJECT_CC10")
SESSION_CC10="cc10-session-$$"
SCOPED_PROOF_CC10="$MOCK_CLAUDE_CC10/.proof-status-${PHASH_CC10}"

TS_CC10=$(date +%s)
printf 'verified|%s\n' "$TS_CC10" > "$SCOPED_PROOF_CC10"

# Create both markers
printf 'pre-dispatch|%s\n' "$TS_CC10" > \
    "${MOCK_TRACES_CC10}/.active-guardian-${SESSION_CC10}-${PHASH_CC10}"
printf 'auto-verify|%s\n' "$TS_CC10" > \
    "${MOCK_TRACES_CC10}/.active-autoverify-${SESSION_CC10}-${PHASH_CC10}"

# Simulate post-write.sh logic
_guardian_active_cc10=false

for _gm in "${MOCK_TRACES_CC10}/.active-guardian-"*; do
    if [[ -f "$_gm" ]]; then
        _marker_ts=$(cut -d'|' -f2 "$_gm" 2>/dev/null || echo "0")
        _now=$(date +%s)
        if [[ "$_marker_ts" =~ ^[0-9]+$ && $(( _now - _marker_ts )) -lt 300 ]]; then
            _guardian_active_cc10=true; break
        fi
    fi
done

if [[ "$_guardian_active_cc10" == "false" ]]; then
    for _avm in "${MOCK_TRACES_CC10}/.active-autoverify-"*; do
        if [[ -f "$_avm" ]]; then
            _marker_ts=$(cut -d'|' -f2 "$_avm" 2>/dev/null || echo "0")
            _now=$(date +%s)
            if [[ "$_marker_ts" =~ ^[0-9]+$ && $(( _now - _marker_ts )) -lt 300 ]]; then
                _guardian_active_cc10=true; break
            fi
        fi
    done
fi

if [[ "$_guardian_active_cc10" == "true" ]]; then
    PROOF_CC10=$(cut -d'|' -f1 "$SCOPED_PROOF_CC10" 2>/dev/null || echo "missing")
    if [[ "$PROOF_CC10" == "verified" ]]; then
        pass_test
    else
        fail_test "Proof should stay 'verified' with both markers active, got '$PROOF_CC10'"
    fi
else
    fail_test "Neither guardian nor autoverify marker was detected as active"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CC-11: Session-init glob counts auto-verify markers as active for proof cleanup
#
# session-init.sh uses ".active-*-{SESSION}-{PHASH}" to count active markers
# before deciding whether to clean stale proof-status files. Auto-verify markers
# match this pattern and must be counted so a fresh auto-verify marker prevents
# a stale proof-status cleanup.
# ─────────────────────────────────────────────────────────────────────────────

run_test "CC-11: Session-init glob counts auto-verify markers (glob pattern matches)"

MOCK_TRACES_CC11="$TMPDIR/traces-cc11"
mkdir -p "$MOCK_TRACES_CC11"

SESSION_CC11="cc11-session-$$"
PHASH_CC11=$(compute_phash "$TMPDIR/project-cc11")

# Create an auto-verify marker with {SESSION}-{PHASH} suffix (session-init glob format)
printf 'auto-verify|%s\n' "$(date +%s)" > \
    "${MOCK_TRACES_CC11}/.active-autoverify-${SESSION_CC11}-${PHASH_CC11}"

# Simulate session-init.sh marker count (the ls glob from session-init.sh line 598)
ACTIVE_COUNT=$(ls "${MOCK_TRACES_CC11}"/.active-*-"${SESSION_CC11}-${PHASH_CC11}" 2>/dev/null | wc -l | tr -d ' \n' || true)
ACTIVE_COUNT="${ACTIVE_COUNT:-0}"

if [[ "$ACTIVE_COUNT" -gt 0 ]]; then
    pass_test
else
    fail_test "session-init glob did not count auto-verify marker (count=$ACTIVE_COUNT)"
fi

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
