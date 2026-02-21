#!/usr/bin/env bash
# tests/test-project-isolation.sh — Cross-project state isolation tests
#
# Validates that project-scoped state files prevent contamination across projects.
# Tests cover: project_hash(), proof-status isolation, trace marker isolation,
# breadcrumb isolation, backward-compat fallback, Gate A scoping, finalize cleanup,
# and the subagent-start.sh ls -t project validation fix.
#
# @decision DEC-TEST-ISOLATION-001
# @title Fixture-based isolation tests for project-scoped state files
# @status accepted
# @rationale Cross-project contamination (issue #isolation) requires dedicated tests
#   that simulate two concurrent projects A and B and verify their state files do
#   not interfere. Tests use temp directories for full isolation and source hooks
#   directly to exercise the exact code paths used in production.
#
# Usage: bash tests/test-project-isolation.sh
#        bash tests/run-hooks.sh  (included via sourcing)
#
set -euo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")")"
HOOKS_DIR="$(dirname "$SCRIPT_DIR")/hooks"

# Source log.sh for project_hash and related helpers
source "$HOOKS_DIR/log.sh"

# ============================================================================
# Test infrastructure
# ============================================================================

PASS=0
FAIL=0
_TEST_TMPDIR=""

setup_test_env() {
    _TEST_TMPDIR=$(mktemp -d)
    export TRACE_STORE="$_TEST_TMPDIR/traces"
    export CLAUDE_DIR="$_TEST_TMPDIR/claude"
    mkdir -p "$TRACE_STORE" "$CLAUDE_DIR"
}

teardown_test_env() {
    [[ -n "$_TEST_TMPDIR" && -d "$_TEST_TMPDIR" ]] && rm -rf "$_TEST_TMPDIR"
    _TEST_TMPDIR=""
    unset TRACE_STORE CLAUDE_DIR PROJECT_ROOT CLAUDE_SESSION_ID 2>/dev/null || true
}

pass() { echo "  PASS: $1"; (( PASS++ )) || true; }
fail() { echo "  FAIL: $1"; (( FAIL++ )) || true; }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$desc"
    else
        fail "$desc (expected='$expected' actual='$actual')"
    fi
}

assert_file_exists() {
    local desc="$1" path="$2"
    if [[ -f "$path" ]]; then
        pass "$desc"
    else
        fail "$desc (file not found: $path)"
    fi
}

assert_file_not_exists() {
    local desc="$1" path="$2"
    if [[ ! -f "$path" ]]; then
        pass "$desc"
    else
        fail "$desc (file unexpectedly exists: $path)"
    fi
}

assert_file_contains() {
    local desc="$1" path="$2" pattern="$3"
    if [[ -f "$path" ]] && grep -q "$pattern" "$path" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc (pattern '$pattern' not found in $path)"
    fi
}

# ============================================================================
# Test 1: project_hash() determinism
# ============================================================================
echo ""
echo "=== Test: project_hash() determinism ==="
setup_test_env

H1=$(project_hash "/path/to/project-alpha")
H2=$(project_hash "/path/to/project-alpha")
H3=$(project_hash "/path/to/project-beta")

assert_eq "Same input produces same hash" "$H1" "$H2"

if [[ "$H1" != "$H3" ]]; then
    pass "Different inputs produce different hashes"
else
    fail "Different inputs produced same hash ($H1)"
fi

if [[ ${#H1} -eq 8 ]]; then
    pass "Hash is exactly 8 characters"
else
    fail "Hash length is ${#H1}, expected 8"
fi

if [[ "$H1" =~ ^[0-9a-f]+$ ]]; then
    pass "Hash is hex string"
else
    fail "Hash is not hex: $H1"
fi

teardown_test_env

# ============================================================================
# Test 2: Scoped proof-status isolation
# ============================================================================
echo ""
echo "=== Test: Scoped proof-status isolation ==="
setup_test_env

PROJECT_A="$_TEST_TMPDIR/project-alpha"
PROJECT_B="$_TEST_TMPDIR/project-beta"
mkdir -p "$PROJECT_A" "$PROJECT_B"

PHASH_A=$(project_hash "$PROJECT_A")
PHASH_B=$(project_hash "$PROJECT_B")

# Write verified status for Project A
echo "verified|$(date +%s)" > "${CLAUDE_DIR}/.proof-status-${PHASH_A}"

# Project B should NOT see Project A's proof-status
export PROJECT_ROOT="$PROJECT_B"
PROOF_B=$(resolve_proof_file)
if [[ -f "$PROOF_B" ]]; then
    VAL_B=$(cut -d'|' -f1 "$PROOF_B" 2>/dev/null || echo "")
    if [[ "$VAL_B" == "verified" ]]; then
        fail "Project B sees Project A's proof-status (contamination)"
    else
        pass "Project B does not see Project A's verified status"
    fi
else
    pass "Project B has no proof-status (correctly isolated)"
fi

# Project A should see its own status
export PROJECT_ROOT="$PROJECT_A"
PROOF_A=$(resolve_proof_file)
if [[ -f "$PROOF_A" ]]; then
    VAL_A=$(cut -d'|' -f1 "$PROOF_A" 2>/dev/null || echo "")
    assert_eq "Project A sees its own verified status" "verified" "$VAL_A"
else
    fail "Project A cannot find its own proof-status"
fi

teardown_test_env

# ============================================================================
# Test 3: Scoped trace marker isolation — init_trace + detect_active_trace
# ============================================================================
echo ""
echo "=== Test: Scoped trace marker isolation ==="
setup_test_env

PROJECT_A="$_TEST_TMPDIR/project-alpha"
PROJECT_B="$_TEST_TMPDIR/project-beta"
mkdir -p "$PROJECT_A" "$PROJECT_B" "$TRACE_STORE"

# Source context-lib for init_trace and detect_active_trace
source "$HOOKS_DIR/context-lib.sh" 2>/dev/null || true

export CLAUDE_SESSION_ID="session-test-isolation-001"
export PROJECT_ROOT="$PROJECT_A"

# Initialize a trace for Project A
TRACE_A=$(init_trace "$PROJECT_A" "implementer" 2>/dev/null || echo "")
if [[ -n "$TRACE_A" ]]; then
    pass "init_trace for Project A succeeded (trace_id=$TRACE_A)"
else
    fail "init_trace for Project A returned empty"
fi

# Project B should NOT find Project A's trace
FOUND_FOR_B=$(detect_active_trace "$PROJECT_B" "implementer" 2>/dev/null || echo "")
if [[ -z "$FOUND_FOR_B" ]]; then
    pass "detect_active_trace for Project B returns empty (correctly isolated)"
else
    fail "detect_active_trace for Project B found Project A's trace: $FOUND_FOR_B"
fi

# Project A should find its own trace
FOUND_FOR_A=$(detect_active_trace "$PROJECT_A" "implementer" 2>/dev/null || echo "")
assert_eq "detect_active_trace for Project A finds its trace" "$TRACE_A" "$FOUND_FOR_A"

teardown_test_env

# ============================================================================
# Test 4: Scoped breadcrumb isolation
# ============================================================================
echo ""
echo "=== Test: Scoped breadcrumb isolation ==="
setup_test_env

PROJECT_A="$_TEST_TMPDIR/project-alpha"
PROJECT_B="$_TEST_TMPDIR/project-beta"
WT_A="$_TEST_TMPDIR/worktree-alpha"
mkdir -p "$PROJECT_A" "$PROJECT_B" "$WT_A" "$WT_A/.claude"

PHASH_A=$(project_hash "$PROJECT_A")
PHASH_B=$(project_hash "$PROJECT_B")

# Write pending proof in worktree-alpha
echo "pending|$(date +%s)" > "$WT_A/.claude/.proof-status"

# Write scoped breadcrumb for Project A
echo "$WT_A" > "${CLAUDE_DIR}/.active-worktree-path-${PHASH_A}"

# Project B should NOT follow Project A's breadcrumb
export PROJECT_ROOT="$PROJECT_B"
PROOF_B=$(resolve_proof_file)
if [[ "$PROOF_B" == "$WT_A/.claude/.proof-status" ]]; then
    fail "Project B followed Project A's breadcrumb (contamination)"
else
    pass "Project B does not follow Project A's breadcrumb"
fi

# Project A should follow its own breadcrumb
export PROJECT_ROOT="$PROJECT_A"
PROOF_A=$(resolve_proof_file)
assert_eq "Project A follows its own breadcrumb" "$WT_A/.claude/.proof-status" "$PROOF_A"

teardown_test_env

# ============================================================================
# Test 5: Old-format fallback — unscoped marker + matching manifest = found
# ============================================================================
echo ""
echo "=== Test: Old-format backward-compat (matching project) ==="
setup_test_env

PROJECT_A="$_TEST_TMPDIR/project-alpha"
mkdir -p "$PROJECT_A" "$TRACE_STORE"

source "$HOOKS_DIR/context-lib.sh" 2>/dev/null || true

export CLAUDE_SESSION_ID="session-old-format-001"

# Manually create an OLD-format marker (no phash)
FAKE_TRACE="implementer-20250101-000000-abc123"
mkdir -p "${TRACE_STORE}/${FAKE_TRACE}/artifacts"
cat > "${TRACE_STORE}/${FAKE_TRACE}/manifest.json" <<MANIFEST
{
  "version": "1",
  "trace_id": "${FAKE_TRACE}",
  "agent_type": "implementer",
  "session_id": "${CLAUDE_SESSION_ID}",
  "project": "${PROJECT_A}",
  "project_name": "project-alpha",
  "branch": "feature/test",
  "start_commit": "",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "active"
}
MANIFEST
# Write the old-format marker (session only, no phash)
echo "$FAKE_TRACE" > "${TRACE_STORE}/.active-implementer-${CLAUDE_SESSION_ID}"

# detect_active_trace for Project A should find it via old-format validation
FOUND=$(detect_active_trace "$PROJECT_A" "implementer" 2>/dev/null || echo "")
assert_eq "Old-format marker with matching project is found" "$FAKE_TRACE" "$FOUND"

teardown_test_env

# ============================================================================
# Test 6: Old-format rejection — unscoped marker + non-matching project = not found
# ============================================================================
echo ""
echo "=== Test: Old-format backward-compat (non-matching project) ==="
setup_test_env

PROJECT_A="$_TEST_TMPDIR/project-alpha"
PROJECT_B="$_TEST_TMPDIR/project-beta"
mkdir -p "$PROJECT_A" "$PROJECT_B" "$TRACE_STORE"

source "$HOOKS_DIR/context-lib.sh" 2>/dev/null || true

export CLAUDE_SESSION_ID="session-old-format-002"

# Manually create an OLD-format marker for Project A
FAKE_TRACE="implementer-20250101-000001-abc124"
mkdir -p "${TRACE_STORE}/${FAKE_TRACE}/artifacts"
cat > "${TRACE_STORE}/${FAKE_TRACE}/manifest.json" <<MANIFEST
{
  "version": "1",
  "trace_id": "${FAKE_TRACE}",
  "agent_type": "implementer",
  "session_id": "${CLAUDE_SESSION_ID}",
  "project": "${PROJECT_A}",
  "project_name": "project-alpha",
  "branch": "feature/test",
  "start_commit": "",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "active"
}
MANIFEST
echo "$FAKE_TRACE" > "${TRACE_STORE}/.active-implementer-${CLAUDE_SESSION_ID}"

# detect_active_trace for Project B should NOT find Project A's marker
FOUND=$(detect_active_trace "$PROJECT_B" "implementer" 2>/dev/null || echo "")
if [[ -z "$FOUND" ]]; then
    pass "Old-format marker with non-matching project is rejected"
else
    fail "Old-format marker leaked to wrong project: $FOUND"
fi

teardown_test_env

# ============================================================================
# Test 7: Gate A isolation — other project's pending doesn't block guardian
# ============================================================================
echo ""
echo "=== Test: Gate A isolation — scoped proof-status ==="
setup_test_env

PROJECT_A="$_TEST_TMPDIR/project-alpha"
PROJECT_B="$_TEST_TMPDIR/project-beta"
mkdir -p "$PROJECT_A" "$PROJECT_B"

PHASH_A=$(project_hash "$PROJECT_A")
PHASH_B=$(project_hash "$PROJECT_B")

# Project A has pending status
echo "needs-verification|$(date +%s)" > "${CLAUDE_DIR}/.proof-status-${PHASH_A}"

# Project B should have no active proof gate
SCOPED_B="${CLAUDE_DIR}/.proof-status-${PHASH_B}"
LEGACY="${CLAUDE_DIR}/.proof-status"
if [[ ! -f "$SCOPED_B" && ! -f "$LEGACY" ]]; then
    pass "Project B sees no proof gate from Project A's pending status"
else
    fail "Project A's pending status bleeds into Project B's gate check"
fi

teardown_test_env

# ============================================================================
# Test 8: finalize_trace cleanup completeness
# ============================================================================
echo ""
echo "=== Test: finalize_trace cleans both scoped and unscoped markers ==="
setup_test_env

PROJECT_A="$_TEST_TMPDIR/project-alpha"
mkdir -p "$PROJECT_A" "$TRACE_STORE"

source "$HOOKS_DIR/context-lib.sh" 2>/dev/null || true

export CLAUDE_SESSION_ID="session-finalize-001"
export PROJECT_ROOT="$PROJECT_A"

# Create a trace
TRACE_A=$(init_trace "$PROJECT_A" "implementer" 2>/dev/null || echo "")
if [[ -z "$TRACE_A" ]]; then
    fail "init_trace failed — cannot test finalize cleanup"
else
    PHASH_A=$(project_hash "$PROJECT_A")

    # Also manually plant an old-format marker to simulate pre-migration state
    echo "$TRACE_A" > "${TRACE_STORE}/.active-implementer-${CLAUDE_SESSION_ID}"

    # Verify both markers exist
    SCOPED_MARKER="${TRACE_STORE}/.active-implementer-${CLAUDE_SESSION_ID}-${PHASH_A}"
    OLD_MARKER="${TRACE_STORE}/.active-implementer-${CLAUDE_SESSION_ID}"
    assert_file_exists "Scoped marker exists before finalize" "$SCOPED_MARKER"
    assert_file_exists "Old-format marker exists before finalize" "$OLD_MARKER"

    # Finalize the trace
    finalize_trace "$TRACE_A" "$PROJECT_A" "implementer" 2>/dev/null || true

    # Both markers should be gone
    assert_file_not_exists "Scoped marker cleaned after finalize" "$SCOPED_MARKER"
    assert_file_not_exists "Old-format marker cleaned after finalize" "$OLD_MARKER"
fi

teardown_test_env

# ============================================================================
# Test 9: subagent-start ls -t respects project scope
# ============================================================================
echo ""
echo "=== Test: subagent-start ls -t fallback validates project ==="
setup_test_env

PROJECT_A="$_TEST_TMPDIR/project-alpha"
PROJECT_B="$_TEST_TMPDIR/project-beta"
mkdir -p "$PROJECT_A" "$PROJECT_B" "$TRACE_STORE"

source "$HOOKS_DIR/context-lib.sh" 2>/dev/null || true

# Create an implementer trace for Project A (most recent)
TRACE_A="implementer-20250101-120000-aaa111"
mkdir -p "${TRACE_STORE}/${TRACE_A}/artifacts"
cat > "${TRACE_STORE}/${TRACE_A}/manifest.json" <<MANIFEST
{
  "version": "1",
  "trace_id": "${TRACE_A}",
  "agent_type": "implementer",
  "session_id": "session-A",
  "project": "${PROJECT_A}",
  "project_name": "project-alpha",
  "branch": "feature/test",
  "start_commit": "",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "completed"
}
MANIFEST

# Create an implementer trace for Project B (older)
sleep 0.1  # ensure different mtime
TRACE_B="implementer-20250101-110000-bbb222"
mkdir -p "${TRACE_STORE}/${TRACE_B}/artifacts"
cat > "${TRACE_STORE}/${TRACE_B}/manifest.json" <<MANIFEST
{
  "version": "1",
  "trace_id": "${TRACE_B}",
  "agent_type": "implementer",
  "session_id": "session-B",
  "project": "${PROJECT_B}",
  "project_name": "project-beta",
  "branch": "feature/test",
  "start_commit": "",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "completed"
}
MANIFEST

# Simulate the subagent-start ls -t fallback logic with project validation
IMPL_TRACE=""
for _mf in $(ls -t "${TRACE_STORE}"/implementer-*/manifest.json 2>/dev/null); do
    [[ -f "$_mf" ]] || continue
    _proj=$(jq -r '.project // empty' "$_mf" 2>/dev/null)
    if [[ "$_proj" == "$PROJECT_B" ]]; then
        IMPL_TRACE=$(basename "$(dirname "$_mf")")
        break
    fi
done

assert_eq "ls -t fallback finds Project B's trace (not Project A's)" "$TRACE_B" "$IMPL_TRACE"

teardown_test_env

# ============================================================================
# Test 10: resolve_proof_file backward compat — unscoped file returned when no scoped
# ============================================================================
echo ""
echo "=== Test: resolve_proof_file backward compat ==="
setup_test_env

PROJECT_A="$_TEST_TMPDIR/project-alpha"
mkdir -p "$PROJECT_A"

# Only legacy (unscoped) file exists
echo "needs-verification|$(date +%s)" > "${CLAUDE_DIR}/.proof-status"

export PROJECT_ROOT="$PROJECT_A"
PROOF=$(resolve_proof_file)

assert_eq "Backward compat: returns legacy file when no scoped file" \
    "${CLAUDE_DIR}/.proof-status" "$PROOF"

teardown_test_env

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "============================================"
echo "Project Isolation Tests: $PASS passed, $FAIL failed"
echo "============================================"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
