#!/usr/bin/env bash
# test-orchestrator-guard.sh — Tests for Gate 1.5: Orchestrator source write guard
#
# Validates that session-init.sh writes .orchestrator-sid at startup, and that
# pre-write.sh Gate 1.5 correctly blocks source writes from orchestrator context
# while allowing writes from subagent context or when .orchestrator-sid is absent.
#
# Test coverage:
#   1. session-init.sh writes .orchestrator-sid containing CLAUDE_SESSION_ID
#   2. Gate 1.5 denies source write when SESSION_ID matches orchestrator-sid
#   3. Gate 1.5 allows source write when SESSION_ID differs (subagent context)
#   4. Gate 1.5 allows source write when .orchestrator-sid is missing (backward compat)
#   5. Gate 1.5 allows non-source writes even when SESSION_ID matches
#   6. .orchestrator-sid is registered in _PROTECTED_STATE_FILES (core-lib.sh)
#
# @decision DEC-TEST-ORCH-GUARD-001
# @title Test suite for Gate 1.5 orchestrator source write guard
# @status accepted
# @rationale Gate 1.5 (DEC-DISPATCH-003) closes the enforcement gap where the
#   orchestrator could bypass implementer dispatch by writing source code directly.
#   These tests verify the three-way decision logic: deny when SIDs match,
#   allow when SIDs differ, allow when .orchestrator-sid is absent. They also
#   verify that session-init.sh correctly seeds the .orchestrator-sid file and
#   that core-lib.sh's protected-state registry includes .orchestrator-sid to
#   prevent accidental overwrites. Uses real hook executables, no mocks.
#
# Implementation notes:
#   - session-init.sh uses detect_project_root() which reads CLAUDE_PROJECT_DIR
#     (not PROJECT_ROOT). Use CLAUDE_PROJECT_DIR in Test 1 to control where the
#     SID file is written.
#   - pre-write.sh uses cache_project_context() → get_claude_dir() which reads
#     PROJECT_ROOT env var. Use PROJECT_ROOT in Tests 2-5.
#   - make_temp_env() creates a git repo on a feature branch without commits to
#     avoid triggering the main-branch guard on the outer repo.
#
# Usage: bash tests/test-orchestrator-guard.sh
# Returns: 0 if all tests pass, 1 if any fail

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="${WORKTREE_ROOT}/hooks"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1 — ${2:-}"; FAIL=$((FAIL + 1)); }

# Shared cleanup list for temp directories
CLEANUP_DIRS=()

cleanup() {
    rm -rf "${CLEANUP_DIRS[@]:-}" 2>/dev/null || true
}
trap cleanup EXIT

# Helper: create an isolated temp directory with a .claude subdir and a git repo.
# Initializes on a feature branch (no commits needed) so branch-guard does not
# interfere when pre-write.sh is invoked for tests 2-5.
# Returns the temp dir path (stdout).
make_temp_env() {
    local d
    d=$(mktemp -d)
    CLEANUP_DIRS+=("$d")
    mkdir -p "$d/.claude"
    # Init on feature branch to avoid branch-guard main-branch denies
    git -C "$d" init -q -b feature/test-branch 2>/dev/null
    git -C "$d" config user.email "test@test.com" 2>/dev/null
    git -C "$d" config user.name "Test" 2>/dev/null
    echo "$d"
}

# Helper: build Write tool JSON input for pre-write.sh
# Args: file_path [content]
make_write_input() {
    local file_path="$1"
    local content="${2:-# test content\necho hello\n}"
    printf '{"tool_name":"Write","tool_input":{"file_path":%s,"content":%s}}' \
        "$(printf '%s' "$file_path" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
        "$(printf '%s' "$content" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
}

# Helper: assert output contains orchestrator-source-guard deny specifically
assert_orch_deny() {
    local output="$1"
    local label="$2"
    if echo "$output" | grep -q '"permissionDecision".*"deny"' && \
       echo "$output" | grep -q 'orchestrator context\|dispatch an implementer'; then
        pass "$label"
    else
        fail "$label" "expected orchestrator-source-guard deny, got: $(echo "$output" | head -3)"
    fi
}

# Helper: assert output does NOT contain orchestrator-source-guard deny.
# Other gates may still deny (e.g. plan-check), but this asserts the specific
# orchestrator-context message is absent.
assert_no_orch_deny() {
    local output="$1"
    local label="$2"
    if echo "$output" | grep -q 'orchestrator context\|dispatch an implementer'; then
        fail "$label" "expected no orchestrator-source-guard deny, got: $(echo "$output" | head -3)"
    else
        pass "$label"
    fi
}

# Helper: assert output contains Gate 0 protected-state deny
assert_protected_state_deny() {
    local output="$1"
    local label="$2"
    if echo "$output" | grep -q '"permissionDecision".*"deny"'; then
        pass "$label"
    else
        fail "$label" "expected deny, got: $(echo "$output" | head -3)"
    fi
}

echo "=== Gate 1.5: Orchestrator Source Write Guard Tests ==="
echo ""

# ============================================================
# Test 1: session-init.sh writes .orchestrator-sid
#
# session-init.sh's detect_project_root() uses CLAUDE_PROJECT_DIR (not
# PROJECT_ROOT) to determine where to write .orchestrator-sid. We set
# CLAUDE_PROJECT_DIR to our isolated temp dir and verify the file appears.
# ============================================================
echo "=== Test 1: session-init.sh writes .orchestrator-sid ==="

T1_ENV=$(make_temp_env)
T1_CLAUDE="$T1_ENV/.claude"
T1_SESSION_ID="test-orch-session-123"

CLAUDE_PROJECT_DIR="$T1_ENV" \
CLAUDE_SESSION_ID="$T1_SESSION_ID" \
TRACE_STORE="$T1_CLAUDE/traces" \
bash "$HOOKS_DIR/session-init.sh" \
    < <(echo '{"session_event":"startup"}') >/dev/null 2>/dev/null || true

T1_SID_FILE="$T1_CLAUDE/.orchestrator-sid"
if [[ -f "$T1_SID_FILE" ]]; then
    T1_SID_CONTENT=$(cat "$T1_SID_FILE")
    if [[ "$T1_SID_CONTENT" == "$T1_SESSION_ID" ]]; then
        pass "Test 1: session-init.sh writes .orchestrator-sid with correct SESSION_ID"
    else
        fail "Test 1: session-init.sh writes .orchestrator-sid with correct SESSION_ID" \
             "expected '$T1_SESSION_ID', got '$T1_SID_CONTENT'"
    fi
else
    fail "Test 1: session-init.sh writes .orchestrator-sid with correct SESSION_ID" \
         ".orchestrator-sid not found at $T1_SID_FILE"
fi

echo ""

# ============================================================
# Test 2: Gate 1.5 denies source write when SESSION_ID matches orchestrator-sid
#
# When CLAUDE_SESSION_ID == content of .orchestrator-sid, the caller is the
# orchestrator. Gate 1.5 must deny source writes that target a .worktrees/ path.
# ============================================================
echo "=== Test 2: Gate 1.5 denies source write from orchestrator context ==="

T2_ENV=$(make_temp_env)
T2_CLAUDE="$T2_ENV/.claude"
T2_ORCH_SID="orch-session-abc"

# Seed .orchestrator-sid with the orchestrator's session ID
printf '%s\n' "$T2_ORCH_SID" > "$T2_CLAUDE/.orchestrator-sid"

# File must be in a .worktrees/ path for _IN_WORKTREE=true (Gate 1.5 precondition)
T2_TARGET="$T2_ENV/.worktrees/feature-test/src/feature.sh"
T2_INPUT=$(make_write_input "$T2_TARGET" "# Source file\necho 'hello'\n")

T2_OUTPUT=$(
    PROJECT_ROOT="$T2_ENV" \
    CLAUDE_SESSION_ID="$T2_ORCH_SID" \
    bash "$HOOKS_DIR/pre-write.sh" \
    < <(echo "$T2_INPUT") 2>/dev/null
) || true

assert_orch_deny "$T2_OUTPUT" \
    "Test 2: Gate 1.5 denies source write when SESSION_ID matches orchestrator-sid"

echo ""

# ============================================================
# Test 3: Gate 1.5 allows source write when SESSION_ID differs (subagent context)
#
# When CLAUDE_SESSION_ID != .orchestrator-sid content, the caller is a subagent
# (implementer). Gate 1.5 must not fire; write should proceed past this gate.
# ============================================================
echo "=== Test 3: Gate 1.5 allows source write when SESSION_ID differs ==="

T3_ENV=$(make_temp_env)
T3_CLAUDE="$T3_ENV/.claude"
T3_ORCH_SID="orch-session-abc"
T3_IMPL_SID="impl-session-xyz"

printf '%s\n' "$T3_ORCH_SID" > "$T3_CLAUDE/.orchestrator-sid"

T3_TARGET="$T3_ENV/.worktrees/feature-test/src/feature.sh"
T3_INPUT=$(make_write_input "$T3_TARGET" "# Source file\necho 'hello'\n")

T3_OUTPUT=$(
    PROJECT_ROOT="$T3_ENV" \
    CLAUDE_SESSION_ID="$T3_IMPL_SID" \
    bash "$HOOKS_DIR/pre-write.sh" \
    < <(echo "$T3_INPUT") 2>/dev/null
) || true

assert_no_orch_deny "$T3_OUTPUT" \
    "Test 3: Gate 1.5 allows source write when SESSION_ID differs (subagent context)"

echo ""

# ============================================================
# Test 4: Gate 1.5 allows when .orchestrator-sid is missing (backward compat)
#
# If .orchestrator-sid was never written (e.g., session-init.sh not yet run,
# or running without CLAUDE_SESSION_ID), Gate 1.5 must fall through. This is
# the backward-compatible path.
# ============================================================
echo "=== Test 4: Gate 1.5 allows when .orchestrator-sid is missing ==="

T4_ENV=$(make_temp_env)
T4_CLAUDE="$T4_ENV/.claude"

# Ensure .orchestrator-sid does not exist
rm -f "$T4_CLAUDE/.orchestrator-sid"

T4_TARGET="$T4_ENV/.worktrees/feature-test/src/feature.sh"
T4_INPUT=$(make_write_input "$T4_TARGET" "# Source file\necho 'hello'\n")

T4_OUTPUT=$(
    PROJECT_ROOT="$T4_ENV" \
    CLAUDE_SESSION_ID="any-session-123" \
    bash "$HOOKS_DIR/pre-write.sh" \
    < <(echo "$T4_INPUT") 2>/dev/null
) || true

assert_no_orch_deny "$T4_OUTPUT" \
    "Test 4: Gate 1.5 allows when .orchestrator-sid is missing (backward compat)"

echo ""

# ============================================================
# Test 5: Gate 1.5 allows non-source writes regardless of SESSION_ID
#
# Gate 1.5 only fires for is_source_file() matches. Non-source files (.md, .json,
# .gitignore, etc.) must pass through even when in orchestrator context.
# ============================================================
echo "=== Test 5: Gate 1.5 allows non-source writes from orchestrator context ==="

T5_ENV=$(make_temp_env)
T5_CLAUDE="$T5_ENV/.claude"
T5_ORCH_SID="orch-session-abc"

# Orchestrator context — SID matches
printf '%s\n' "$T5_ORCH_SID" > "$T5_CLAUDE/.orchestrator-sid"

# Non-source: .md file
T5_TARGET="$T5_ENV/.worktrees/feature-test/docs/notes.md"
T5_INPUT=$(make_write_input "$T5_TARGET" "# Notes\n\nSome documentation.\n")

T5_OUTPUT=$(
    PROJECT_ROOT="$T5_ENV" \
    CLAUDE_SESSION_ID="$T5_ORCH_SID" \
    bash "$HOOKS_DIR/pre-write.sh" \
    < <(echo "$T5_INPUT") 2>/dev/null
) || true

assert_no_orch_deny "$T5_OUTPUT" \
    "Test 5: Gate 1.5 allows non-source writes (.md) regardless of SESSION_ID"

# Non-source: .json file
T5B_TARGET="$T5_ENV/.worktrees/feature-test/config/settings.json"
T5B_INPUT=$(make_write_input "$T5B_TARGET" '{"key": "value"}\n')

T5B_OUTPUT=$(
    PROJECT_ROOT="$T5_ENV" \
    CLAUDE_SESSION_ID="$T5_ORCH_SID" \
    bash "$HOOKS_DIR/pre-write.sh" \
    < <(echo "$T5B_INPUT") 2>/dev/null
) || true

assert_no_orch_deny "$T5B_OUTPUT" \
    "Test 5b: Gate 1.5 allows non-source writes (.json) regardless of SESSION_ID"

echo ""

# ============================================================
# Test 6: .orchestrator-sid is in _PROTECTED_STATE_FILES registry
#
# core-lib.sh's _PROTECTED_STATE_FILES array must include ".orchestrator-sid"
# so that Gate 0 in pre-write.sh blocks direct Write/Edit to this file.
# This prevents agents from forging the orchestrator's session marker.
# ============================================================
echo "=== Test 6: .orchestrator-sid is registered in _PROTECTED_STATE_FILES ==="

# Subtest 6a: is_protected_state_file() returns 0 (true) for .orchestrator-sid paths
T6_RESULT=$(
    bash -c '
        _SHA256_CMD="shasum -a 256"
        source "'"$HOOKS_DIR"'/core-lib.sh" 2>/dev/null || exit 1
        if is_protected_state_file "/some/path/.orchestrator-sid"; then
            echo "PROTECTED"
        else
            echo "NOT_PROTECTED"
        fi
    ' 2>/dev/null
) || T6_RESULT="ERROR"

if [[ "$T6_RESULT" == "PROTECTED" ]]; then
    pass "Test 6a: is_protected_state_file('/some/path/.orchestrator-sid') returns 0 (true)"
else
    fail "Test 6a: is_protected_state_file('/some/path/.orchestrator-sid') returns 0 (true)" \
         "returned: $T6_RESULT"
fi

# Subtest 6b: Gate 0 in pre-write.sh denies direct Write to .orchestrator-sid
T6B_ENV=$(make_temp_env)
T6B_CLAUDE="$T6B_ENV/.claude"
T6B_TARGET="$T6B_CLAUDE/.orchestrator-sid"
T6B_INPUT=$(make_write_input "$T6B_TARGET" "fake-session-id\n")

T6B_OUTPUT=$(
    PROJECT_ROOT="$T6B_ENV" \
    CLAUDE_SESSION_ID="any-session" \
    bash "$HOOKS_DIR/pre-write.sh" \
    < <(echo "$T6B_INPUT") 2>/dev/null
) || true

assert_protected_state_deny "$T6B_OUTPUT" \
    "Test 6b: Gate 0 denies direct Write to .orchestrator-sid (protected state file)"

echo ""
echo "=== Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) tests ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
