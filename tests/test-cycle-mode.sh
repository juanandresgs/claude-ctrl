#!/usr/bin/env bash
# test-cycle-mode.sh — Tests for the CYCLE_MODE protocol (W2-1 through W2-5)
#
# Validates:
#   1. Gate B bypass: tester dispatch with CYCLE_MODE: auto-flow in prompt while
#      implementer trace is active → should NOT be denied
#   2. Gate B enforcement: tester dispatch WITHOUT auto-flow while implementer active
#      → should be denied (existing behavior preserved)
#   3. CYCLE COMPLETE detection: post-task.sh implementer completion with
#      CYCLE COMPLETE in trace summary → emits cycle-complete directive
#   4. Normal implementer flow: post-task.sh without CYCLE COMPLETE →
#      emits "DISPATCH TESTER NOW" (existing behavior)
#
# @decision DEC-CYCLE-MODE-001
# @title Test suite for CYCLE_MODE protocol
# @status accepted
# @rationale The CYCLE_MODE protocol allows the implementer to own the full
#   implement→test→verify→commit cycle for routine work items (auto-flow mode)
#   while preserving the conservative phase-boundary mode for phase-completing
#   work. These tests verify: (1) Gate B bypass allows nested tester dispatch,
#   (2) Gate B still enforces the rule without the bypass flag, (3) post-task.sh
#   detects CYCLE COMPLETE in the implementer's trace and emits the correct
#   directive, (4) normal flow (without CYCLE COMPLETE) still emits DISPATCH
#   TESTER NOW so existing orchestrator behavior is unchanged.
#
# Usage: bash tests/test-cycle-mode.sh
# Returns: 0 if all tests pass, 1 if any fail

set -euo pipefail
# Portable SHA-256 (macOS: shasum, Ubuntu: sha256sum)
if command -v shasum >/dev/null 2>&1; then
    _SHA256_CMD="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
    _SHA256_CMD="sha256sum"
else
    _SHA256_CMD="cat"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="${WORKTREE_ROOT}/hooks"
TASK_TRACK="${HOOKS_DIR}/task-track.sh"
POST_TASK="${HOOKS_DIR}/post-task.sh"

PASS=0
FAIL=0
TESTS_RUN=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }
run_test() { echo "Running: $1"; TESTS_RUN=$((TESTS_RUN + 1)); }

# Suppress hook library stderr during source
exec 3>&2
exec 2>/dev/null

# Source libraries for TRACE_STORE etc.
# shellcheck source=/dev/null
source "${HOOKS_DIR}/log.sh"
# shellcheck source=/dev/null
source "${HOOKS_DIR}/source-lib.sh"; require_git; require_plan; require_trace; require_session
# shellcheck source=/dev/null
source "${HOOKS_DIR}/source-lib.sh"

# Override TRACE_STORE with a temp dir AFTER sourcing (sourcing resets it)
FAKE_TRACE_STORE=$(mktemp -d)
export TRACE_STORE="$FAKE_TRACE_STORE"
export CLAUDE_SESSION_ID="test-cycle-mode-$$"
cleanup_dirs=("$FAKE_TRACE_STORE")
trap 'rm -rf "${cleanup_dirs[@]}" 2>/dev/null || true' EXIT

# Restore stderr for test output
exec 2>&3
exec 3>&-

# ============================================================
# Helper: create a fake implementer trace manifest + active marker
# Arguments:
#   $1 — trace_id
#   $2 — status ("active")
#   $3 — trace_store directory (default: FAKE_TRACE_STORE)
# ============================================================
make_impl_trace() {
    local trace_id="$1"
    local status="${2:-active}"
    local store="${3:-$FAKE_TRACE_STORE}"

    local trace_dir="${store}/${trace_id}"
    mkdir -p "${trace_dir}/artifacts"

    echo "Implementer summary" > "${trace_dir}/summary.md"

    cat > "${trace_dir}/manifest.json" <<MANIFEST
{
  "trace_id": "${trace_id}",
  "agent_type": "implementer",
  "project_name": "test-project",
  "session_id": "${CLAUDE_SESSION_ID}",
  "project": "${WORKTREE_ROOT}",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "${status}",
  "outcome": "unknown"
}
MANIFEST

    # Create the active marker
    local phash
    phash=$(echo "$WORKTREE_ROOT" | $_SHA256_CMD 2>/dev/null | cut -c1-8 || echo "testhash")
    echo "${trace_id}" > "${store}/.active-implementer-${CLAUDE_SESSION_ID}-${phash}"

    echo "${trace_dir}"
}

# ============================================================
# Helper: run Gate B logic directly (extracted from task-track.sh)
# Simulates what Gate B does without the full hook invocation.
# Arguments:
#   $1 — prompt_text (to check for auto-flow)
#   $2 — trace_id of active implementer trace
# Returns: "denied" | "allowed"
# ============================================================
run_gate_b() {
    local prompt_text="$1"
    local trace_id="$2"
    local store="${3:-$FAKE_TRACE_STORE}"

    # Gate B bypass check (mirrors task-track.sh lines 148-152)
    if echo "$prompt_text" | grep -q 'CYCLE_MODE: auto-flow'; then
        echo "allowed"
        return 0
    fi

    # No bypass — check for active implementer trace
    local impl_manifest="${store}/${trace_id}/manifest.json"
    [[ -f "$impl_manifest" ]] || { echo "allowed"; return 0; }  # no trace = no block

    local impl_status
    impl_status=$(jq -r '.status // "unknown"' "$impl_manifest" 2>/dev/null || echo "unknown")

    if [[ "$impl_status" == "active" ]]; then
        echo "denied"
    else
        echo "allowed"
    fi
}

# ============================================================
# Test 1: Syntax — task-track.sh has valid bash syntax
# ============================================================
run_test "Syntax: task-track.sh is valid bash"
if bash -n "$TASK_TRACK" 2>/dev/null; then
    pass "Syntax: task-track.sh is valid bash"
else
    fail "Syntax: task-track.sh is valid bash" "syntax error in task-track.sh"
fi

# ============================================================
# Test 2: Syntax — post-task.sh has valid bash syntax
# ============================================================
run_test "Syntax: post-task.sh is valid bash"
if bash -n "$POST_TASK" 2>/dev/null; then
    pass "Syntax: post-task.sh is valid bash"
else
    fail "Syntax: post-task.sh is valid bash" "syntax error in post-task.sh"
fi

# ============================================================
# Test 3: Gate B bypass — auto-flow allows tester dispatch with active implementer
# ============================================================
run_test "Gate B bypass: CYCLE_MODE: auto-flow allows tester dispatch while implementer active"

FAKE_STORE_T3=$(mktemp -d)
cleanup_dirs+=("$FAKE_STORE_T3")
TRACE_STORE="$FAKE_STORE_T3"

TRACE_ID_T3="implementer-20260302-test003-abcd"
make_impl_trace "$TRACE_ID_T3" "active" "$FAKE_STORE_T3" >/dev/null 2>&1

PROMPT_WITH_AUTOFLOW="Verify the implemented feature. CYCLE_MODE: auto-flow dispatch."
RESULT_T3=$(run_gate_b "$PROMPT_WITH_AUTOFLOW" "$TRACE_ID_T3" "$FAKE_STORE_T3")

if [[ "$RESULT_T3" == "allowed" ]]; then
    pass "Gate B bypass: CYCLE_MODE: auto-flow allows tester dispatch while implementer active"
else
    fail "Gate B bypass: CYCLE_MODE: auto-flow allows tester dispatch while implementer active" \
        "expected 'allowed' but got '$RESULT_T3'"
fi

TRACE_STORE="$FAKE_TRACE_STORE"

# ============================================================
# Test 4: Gate B enforcement — no auto-flow is denied when implementer active
# ============================================================
run_test "Gate B enforcement: no CYCLE_MODE flag is denied while implementer active"

FAKE_STORE_T4=$(mktemp -d)
cleanup_dirs+=("$FAKE_STORE_T4")
TRACE_STORE="$FAKE_STORE_T4"

TRACE_ID_T4="implementer-20260302-test004-dcba"
make_impl_trace "$TRACE_ID_T4" "active" "$FAKE_STORE_T4" >/dev/null 2>&1

PROMPT_NO_AUTOFLOW="Verify the implemented feature. Standard dispatch."
RESULT_T4=$(run_gate_b "$PROMPT_NO_AUTOFLOW" "$TRACE_ID_T4" "$FAKE_STORE_T4")

if [[ "$RESULT_T4" == "denied" ]]; then
    pass "Gate B enforcement: no CYCLE_MODE flag is denied while implementer active"
else
    fail "Gate B enforcement: no CYCLE_MODE flag is denied while implementer active" \
        "expected 'denied' but got '$RESULT_T4'"
fi

TRACE_STORE="$FAKE_TRACE_STORE"

# ============================================================
# Test 5: Gate B enforcement — phase-boundary does NOT bypass
# ============================================================
run_test "Gate B enforcement: CYCLE_MODE: phase-boundary does NOT bypass Gate B"

FAKE_STORE_T5=$(mktemp -d)
cleanup_dirs+=("$FAKE_STORE_T5")
TRACE_STORE="$FAKE_STORE_T5"

TRACE_ID_T5="implementer-20260302-test005-efgh"
make_impl_trace "$TRACE_ID_T5" "active" "$FAKE_STORE_T5" >/dev/null 2>&1

PROMPT_PHASE_BOUNDARY="Verify the feature. CYCLE_MODE: phase-boundary dispatch."
RESULT_T5=$(run_gate_b "$PROMPT_PHASE_BOUNDARY" "$TRACE_ID_T5" "$FAKE_STORE_T5")

if [[ "$RESULT_T5" == "denied" ]]; then
    pass "Gate B enforcement: CYCLE_MODE: phase-boundary does NOT bypass Gate B"
else
    fail "Gate B enforcement: CYCLE_MODE: phase-boundary does NOT bypass Gate B" \
        "expected 'denied' but got '$RESULT_T5'"
fi

TRACE_STORE="$FAKE_TRACE_STORE"

# ============================================================
# Test 6: Gate B code — task-track.sh contains auto-flow bypass
# ============================================================
run_test "task-track.sh Gate B: contains auto-flow bypass code"
if grep -q 'CYCLE_MODE: auto-flow' "$TASK_TRACK" 2>/dev/null; then
    pass "task-track.sh Gate B: contains auto-flow bypass code"
else
    fail "task-track.sh Gate B: contains auto-flow bypass code" \
        "'CYCLE_MODE: auto-flow' not found in task-track.sh"
fi

# ============================================================
# Test 7: Gate B code — task-track.sh logs the bypass
# ============================================================
run_test "task-track.sh Gate B: logs auto-flow bypass (GATE-B)"
if grep -q 'GATE-B.*auto-flow\|auto-flow.*GATE-B' "$TASK_TRACK" 2>/dev/null; then
    pass "task-track.sh Gate B: logs auto-flow bypass (GATE-B)"
else
    fail "task-track.sh Gate B: logs auto-flow bypass (GATE-B)" \
        "log_info GATE-B auto-flow not found in task-track.sh"
fi

# ============================================================
# Test 8: CYCLE COMPLETE detection — post-task.sh emits cycle-complete directive
# ============================================================
run_test "post-task.sh: CYCLE COMPLETE in implementer trace → cycle-complete directive"

FAKE_STORE_T8=$(mktemp -d)
FAKE_CLAUDE_T8=$(mktemp -d)
cleanup_dirs+=("$FAKE_STORE_T8" "$FAKE_CLAUDE_T8")

SESSION_T8="test-cycle-detect-$$"
TRACE_ID_T8="implementer-20260302-test008-xxxx"
TRACE_DIR_T8="${FAKE_STORE_T8}/${TRACE_ID_T8}"
mkdir -p "${TRACE_DIR_T8}/artifacts"

# Write manifest with active status
cat > "${TRACE_DIR_T8}/manifest.json" <<MANIFEST8
{
  "trace_id": "${TRACE_ID_T8}",
  "agent_type": "implementer",
  "session_id": "${SESSION_T8}",
  "project": "${WORKTREE_ROOT}",
  "project_name": ".claude",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "active",
  "outcome": "unknown"
}
MANIFEST8

# Write CYCLE COMPLETE in the summary
cat > "${TRACE_DIR_T8}/summary.md" <<SUM8
# Implementer Summary
## Status: CYCLE COMPLETE
CYCLE COMPLETE: Built feature X, tests passed, tester verified (AUTOVERIFY: CLEAN), guardian committed.
## Files Changed
- hooks/test-feature.sh
## Test Results
207/207 tests passed
SUM8

# Create active marker
phash_t8=$(echo "$WORKTREE_ROOT" | $_SHA256_CMD 2>/dev/null | cut -c1-8 || echo "testhash")
echo "${TRACE_ID_T8}" > "${FAKE_STORE_T8}/.active-implementer-${SESSION_T8}-${phash_t8}"

# Write a passing test-status file where read_test_status() expects it:
# read_test_status() reads from $root/.claude/.test-status
# post-task.sh uses detect_project_root() from $cwd, which returns WORKTREE_ROOT
# So we need to write the file at WORKTREE_ROOT/.claude/.test-status
REAL_CLAUDE_T8="${WORKTREE_ROOT}/.claude"
mkdir -p "$REAL_CLAUDE_T8"
echo "pass|0|$(date +%s)" > "${REAL_CLAUDE_T8}/.test-status-cycle-t8"
# Temporarily use our status file
cp "${REAL_CLAUDE_T8}/.test-status" "${REAL_CLAUDE_T8}/.test-status.bak" 2>/dev/null || true
echo "pass|0|$(date +%s)" > "${REAL_CLAUDE_T8}/.test-status"

# Run post-task.sh
INPUT_T8=$(printf '{"tool_name":"Task","tool_input":{"subagent_type":"implementer"},"cwd":"%s"}' "$WORKTREE_ROOT")
OUTPUT_T8=$(echo "$INPUT_T8" | \
    env TRACE_STORE="$FAKE_STORE_T8" \
        CLAUDE_SESSION_ID="$SESSION_T8" \
        CLAUDE_DIR="$FAKE_CLAUDE_T8" \
    bash "$POST_TASK" 2>/dev/null || true)

# Restore original test-status
if [[ -f "${REAL_CLAUDE_T8}/.test-status.bak" ]]; then
    mv "${REAL_CLAUDE_T8}/.test-status.bak" "${REAL_CLAUDE_T8}/.test-status" 2>/dev/null || true
fi
rm -f "${REAL_CLAUDE_T8}/.test-status-cycle-t8" 2>/dev/null || true

if echo "$OUTPUT_T8" | grep -q 'CYCLE COMPLETE'; then
    pass "post-task.sh: CYCLE COMPLETE in implementer trace → cycle-complete directive"
else
    fail "post-task.sh: CYCLE COMPLETE in implementer trace → cycle-complete directive" \
        "expected 'CYCLE COMPLETE' in output, got: ${OUTPUT_T8:0:200}"
fi

# ============================================================
# Test 9: Normal implementer flow — no CYCLE COMPLETE → DISPATCH TESTER NOW
# ============================================================
run_test "post-task.sh: no CYCLE COMPLETE in trace → DISPATCH TESTER NOW"

FAKE_STORE_T9=$(mktemp -d)
FAKE_CLAUDE_T9=$(mktemp -d)
cleanup_dirs+=("$FAKE_STORE_T9" "$FAKE_CLAUDE_T9")

SESSION_T9="test-normal-flow-$$"
TRACE_ID_T9="implementer-20260302-test009-yyyy"
TRACE_DIR_T9="${FAKE_STORE_T9}/${TRACE_ID_T9}"
mkdir -p "${TRACE_DIR_T9}/artifacts"

cat > "${TRACE_DIR_T9}/manifest.json" <<MANIFEST9
{
  "trace_id": "${TRACE_ID_T9}",
  "agent_type": "implementer",
  "session_id": "${SESSION_T9}",
  "project": "${WORKTREE_ROOT}",
  "project_name": ".claude",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "active",
  "outcome": "unknown"
}
MANIFEST9

# Normal summary WITHOUT CYCLE COMPLETE
cat > "${TRACE_DIR_T9}/summary.md" <<SUM9
# Implementer Summary
## Status: COMPLETE
All tests pass. Implemented feature Y.
## Test Results
207/207 tests passed
SUM9

# Create active marker
phash_t9=$(echo "$WORKTREE_ROOT" | $_SHA256_CMD 2>/dev/null | cut -c1-8 || echo "testhash")
echo "${TRACE_ID_T9}" > "${FAKE_STORE_T9}/.active-implementer-${SESSION_T9}-${phash_t9}"

REAL_CLAUDE_T9="${WORKTREE_ROOT}/.claude"
cp "${REAL_CLAUDE_T9}/.test-status" "${REAL_CLAUDE_T9}/.test-status.bak9" 2>/dev/null || true
echo "pass|0|$(date +%s)" > "${REAL_CLAUDE_T9}/.test-status"

INPUT_T9=$(printf '{"tool_name":"Task","tool_input":{"subagent_type":"implementer"},"cwd":"%s"}' "$WORKTREE_ROOT")
OUTPUT_T9=$(echo "$INPUT_T9" | \
    env TRACE_STORE="$FAKE_STORE_T9" \
        CLAUDE_SESSION_ID="$SESSION_T9" \
        CLAUDE_DIR="$FAKE_CLAUDE_T9" \
    bash "$POST_TASK" 2>/dev/null || true)

# Restore
if [[ -f "${REAL_CLAUDE_T9}/.test-status.bak9" ]]; then
    mv "${REAL_CLAUDE_T9}/.test-status.bak9" "${REAL_CLAUDE_T9}/.test-status" 2>/dev/null || true
fi

if echo "$OUTPUT_T9" | grep -q 'DISPATCH TESTER NOW'; then
    pass "post-task.sh: no CYCLE COMPLETE in trace → DISPATCH TESTER NOW"
else
    fail "post-task.sh: no CYCLE COMPLETE in trace → DISPATCH TESTER NOW" \
        "expected 'DISPATCH TESTER NOW' in output, got: ${OUTPUT_T9:0:200}"
fi

# ============================================================
# Test 10: post-task.sh code — contains DEC-CYCLE-DETECT-001 annotation
# ============================================================
run_test "post-task.sh: contains DEC-CYCLE-DETECT-001 decision annotation"
if grep -q 'DEC-CYCLE-DETECT-001' "$POST_TASK" 2>/dev/null; then
    pass "post-task.sh: contains DEC-CYCLE-DETECT-001 decision annotation"
else
    fail "post-task.sh: contains DEC-CYCLE-DETECT-001 decision annotation" \
        "DEC-CYCLE-DETECT-001 not found in post-task.sh"
fi

# ============================================================
# Test 11: task-track.sh code — contains DEC-GATE-B-AUTOFLOW-001 annotation
# ============================================================
run_test "task-track.sh: contains DEC-GATE-B-AUTOFLOW-001 decision annotation"
if grep -q 'DEC-GATE-B-AUTOFLOW-001' "$TASK_TRACK" 2>/dev/null; then
    pass "task-track.sh: contains DEC-GATE-B-AUTOFLOW-001 decision annotation"
else
    fail "task-track.sh: contains DEC-GATE-B-AUTOFLOW-001 decision annotation" \
        "DEC-GATE-B-AUTOFLOW-001 not found in task-track.sh"
fi

# ============================================================
# Test 12: agents/implementer.md — contains Phase 3.5 section
# ============================================================
run_test "agents/implementer.md: contains Phase 3.5 CYCLE_MODE section"
IMPL_MD="${WORKTREE_ROOT}/agents/implementer.md"
if grep -q 'Phase 3.5' "$IMPL_MD" 2>/dev/null && grep -q 'DEC-CYCLE-MODE-001' "$IMPL_MD" 2>/dev/null; then
    pass "agents/implementer.md: contains Phase 3.5 CYCLE_MODE section"
else
    fail "agents/implementer.md: contains Phase 3.5 CYCLE_MODE section" \
        "Phase 3.5 section or DEC-CYCLE-MODE-001 annotation not found"
fi

# ============================================================
# Test 13: agents/guardian.md — contains auto-flow invocation note
# ============================================================
run_test "agents/guardian.md: contains auto-flow invocation note"
GUARDIAN_MD="${WORKTREE_ROOT}/agents/guardian.md"
if grep -q 'auto-flow\|Auto-flow' "$GUARDIAN_MD" 2>/dev/null; then
    pass "agents/guardian.md: contains auto-flow invocation note"
else
    fail "agents/guardian.md: contains auto-flow invocation note" \
        "auto-flow mention not found in guardian.md"
fi

# ============================================================
# Test 14: CLAUDE.md — contains auto-flow routing rules
# ============================================================
run_test "CLAUDE.md: contains auto-flow vs phase-boundary routing"
CLAUDE_MD="${WORKTREE_ROOT}/CLAUDE.md"
if grep -q 'auto-flow vs phase-boundary\|Auto-flow vs Phase-boundary' "$CLAUDE_MD" 2>/dev/null; then
    pass "CLAUDE.md: contains auto-flow vs phase-boundary routing"
else
    fail "CLAUDE.md: contains auto-flow vs phase-boundary routing" \
        "auto-flow routing section not found in CLAUDE.md"
fi

# ============================================================
# Test 15: CLAUDE.md — contains CYCLE COMPLETE handling
# ============================================================
run_test "CLAUDE.md: contains CYCLE COMPLETE handling directive"
if grep -q 'CYCLE COMPLETE' "$CLAUDE_MD" 2>/dev/null; then
    pass "CLAUDE.md: contains CYCLE COMPLETE handling directive"
else
    fail "CLAUDE.md: contains CYCLE COMPLETE handling directive" \
        "CYCLE COMPLETE handling not found in CLAUDE.md"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "========================================"
echo "test-cycle-mode.sh: $TESTS_RUN tests run"
echo "  PASSED: $PASS"
echo "  FAILED: $FAIL"
echo "========================================"

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
