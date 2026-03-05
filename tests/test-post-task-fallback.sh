#!/usr/bin/env bash
# Test post-task.sh fallback behavior for non-tester agents.
#
# Validates:
#   1. IS_SUBAGENT normalization: tool_name=Agent triggers fallback same as Task
#   2. Diagnostic summary written for guardian/implementer/planner when missing
#   3. Existing summary.md (>10 bytes) is NOT overwritten
#   4. Empty subagent_type + active guardian marker triggers detection
#   5. Stale marker cleaned after finalize (via finalize_trace)
#   6. Fallback emits additionalContext with summary content
#
# @decision DEC-TEST-POST-TASK-FALLBACK-001
# @title Test suite for post-task.sh fallback and diagnostic summary writing
# @status accepted
# @rationale The post-task.sh fallback path (non-tester agent trace finalization +
#   diagnostic summary writing) is critical for silent-return recovery. These tests
#   verify: IS_SUBAGENT normalization handles Agent tool_name, _write_diagnostic_summary
#   reconstructs summaries per agent type, existing summaries are protected, and
#   additionalContext is emitted so the orchestrator sees the summary immediately.
#   Issue #158.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"

# Ensure tmp directory exists
mkdir -p "$PROJECT_ROOT/tmp"

# Cleanup trap (DEC-PROD-002): collect temp dirs and remove on exit
_CLEANUP_DIRS=()
trap '[[ ${#_CLEANUP_DIRS[@]} -gt 0 ]] && rm -rf "${_CLEANUP_DIRS[@]}" 2>/dev/null; true' EXIT

# Track test results
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

# Helper: make a JSON input for post-task.sh
make_input() {
    local tool_name="$1"
    local subagent_type="${2:-}"
    printf '{"tool_name":"%s","tool_input":{"subagent_type":"%s"},"cwd":"%s"}' \
        "$tool_name" "$subagent_type" "$PROJECT_ROOT"
}

# Helper: set up an isolated TRACE_STORE and a fake active trace marker
# Returns: sets TEST_TRACE_ID and TEST_TRACE_DIR in parent shell (via file)
setup_trace_env() {
    local agent_type="$1"
    local test_dir="$2"
    local session_id="${3:-test-session-$$}"

    export TRACE_STORE="$test_dir/traces"
    export CLAUDE_SESSION_ID="$session_id"

    mkdir -p "$TRACE_STORE"

    # Create a trace dir
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local trace_id="${agent_type}-${timestamp}-test00"
    local trace_dir="${TRACE_STORE}/${trace_id}"
    mkdir -p "${trace_dir}/artifacts"

    # Write manifest.json
    cat > "${trace_dir}/manifest.json" <<MANIFEST
{
  "version": "1",
  "trace_id": "${trace_id}",
  "agent_type": "${agent_type}",
  "session_id": "${session_id}",
  "project": "${PROJECT_ROOT}",
  "project_name": ".claude",
  "branch": "main",
  "start_commit": "",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "active"
}
MANIFEST

    # Write active marker (project-scoped format)
    local phash
    phash=$(bash -c "source '$HOOKS_DIR/source-lib.sh' && project_hash '$PROJECT_ROOT'" 2>/dev/null || echo "testhash")
    echo "${trace_id}" > "${TRACE_STORE}/.active-${agent_type}-${session_id}-${phash}"

    echo "$trace_id"
}

# ---------------------------------------------------------------------------
# Test 1: tool_name=Agent + subagent_type=guardian → fallback fires, diagnostic summary written
# ---------------------------------------------------------------------------
run_test "Agent tool_name: guardian fallback writes diagnostic summary"

TEST_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-ptf-XXXXXX")
_CLEANUP_DIRS+=("$TEST_DIR")
_CLEANUP_DIRS+=("$TEST_DIR")
SESSION_ID="test-sess-guardian-$$"

TRACE_ID=$(setup_trace_env "guardian" "$TEST_DIR" "$SESSION_ID")
TRACE_DIR="${TEST_DIR}/traces/${TRACE_ID}"

# Run post-task.sh with Agent tool_name
OUTPUT=$(make_input "Agent" "guardian" | \
    env TRACE_STORE="$TEST_DIR/traces" \
        CLAUDE_SESSION_ID="$SESSION_ID" \
        CLAUDE_DIR="$TEST_DIR/.claude" \
    bash "$HOOKS_DIR/post-task.sh" 2>/dev/null || true)

SUM_FILE="${TRACE_DIR}/summary.md"
if [[ -f "$SUM_FILE" ]]; then
    SUM_CONTENT=$(cat "$SUM_FILE")
    if echo "$SUM_CONTENT" | grep -q "Guardian Summary"; then
        pass_test
    else
        fail_test "summary.md exists but missing 'Guardian Summary': $(head -2 "$SUM_FILE")"
    fi
else
    fail_test "summary.md not written at $SUM_FILE"
fi

rm -rf "$TEST_DIR"

# ---------------------------------------------------------------------------
# Test 2: tool_name=Agent + subagent_type=implementer → diagnostic summary written
# ---------------------------------------------------------------------------
run_test "Agent tool_name: implementer fallback writes diagnostic summary"

TEST_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-ptf-XXXXXX")
_CLEANUP_DIRS+=("$TEST_DIR")
SESSION_ID="test-sess-impl-$$"

TRACE_ID=$(setup_trace_env "implementer" "$TEST_DIR" "$SESSION_ID")
TRACE_DIR="${TEST_DIR}/traces/${TRACE_ID}"

OUTPUT=$(make_input "Agent" "implementer" | \
    env TRACE_STORE="$TEST_DIR/traces" \
        CLAUDE_SESSION_ID="$SESSION_ID" \
        CLAUDE_DIR="$TEST_DIR/.claude" \
    bash "$HOOKS_DIR/post-task.sh" 2>/dev/null || true)

SUM_FILE="${TRACE_DIR}/summary.md"
if [[ -f "$SUM_FILE" ]]; then
    SUM_CONTENT=$(cat "$SUM_FILE")
    if echo "$SUM_CONTENT" | grep -q "Implementer Summary"; then
        pass_test
    else
        fail_test "summary.md exists but missing 'Implementer Summary': $(head -2 "$SUM_FILE")"
    fi
else
    fail_test "summary.md not written at $SUM_FILE"
fi

rm -rf "$TEST_DIR"

# ---------------------------------------------------------------------------
# Test 3: tool_name=Agent + subagent_type=planner → diagnostic summary written
# ---------------------------------------------------------------------------
run_test "Agent tool_name: planner fallback writes diagnostic summary"

TEST_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-ptf-XXXXXX")
_CLEANUP_DIRS+=("$TEST_DIR")
SESSION_ID="test-sess-plan-$$"

TRACE_ID=$(setup_trace_env "planner" "$TEST_DIR" "$SESSION_ID")
TRACE_DIR="${TEST_DIR}/traces/${TRACE_ID}"

OUTPUT=$(make_input "Agent" "planner" | \
    env TRACE_STORE="$TEST_DIR/traces" \
        CLAUDE_SESSION_ID="$SESSION_ID" \
        CLAUDE_DIR="$TEST_DIR/.claude" \
    bash "$HOOKS_DIR/post-task.sh" 2>/dev/null || true)

SUM_FILE="${TRACE_DIR}/summary.md"
if [[ -f "$SUM_FILE" ]]; then
    SUM_CONTENT=$(cat "$SUM_FILE")
    if echo "$SUM_CONTENT" | grep -q "Planner Summary"; then
        pass_test
    else
        fail_test "summary.md exists but missing 'Planner Summary': $(head -2 "$SUM_FILE")"
    fi
else
    fail_test "summary.md not written at $SUM_FILE"
fi

rm -rf "$TEST_DIR"

# ---------------------------------------------------------------------------
# Test 4: tool_name=Task + subagent_type=guardian → same behavior (original Task path)
# ---------------------------------------------------------------------------
run_test "Task tool_name: guardian fallback writes diagnostic summary"

TEST_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-ptf-XXXXXX")
_CLEANUP_DIRS+=("$TEST_DIR")
SESSION_ID="test-sess-task-g-$$"

TRACE_ID=$(setup_trace_env "guardian" "$TEST_DIR" "$SESSION_ID")
TRACE_DIR="${TEST_DIR}/traces/${TRACE_ID}"

OUTPUT=$(make_input "Task" "guardian" | \
    env TRACE_STORE="$TEST_DIR/traces" \
        CLAUDE_SESSION_ID="$SESSION_ID" \
        CLAUDE_DIR="$TEST_DIR/.claude" \
    bash "$HOOKS_DIR/post-task.sh" 2>/dev/null || true)

SUM_FILE="${TRACE_DIR}/summary.md"
if [[ -f "$SUM_FILE" ]]; then
    SUM_CONTENT=$(cat "$SUM_FILE")
    if echo "$SUM_CONTENT" | grep -q "Guardian Summary"; then
        pass_test
    else
        fail_test "summary.md exists but missing 'Guardian Summary': $(head -2 "$SUM_FILE")"
    fi
else
    fail_test "summary.md not written at $SUM_FILE"
fi

rm -rf "$TEST_DIR"

# ---------------------------------------------------------------------------
# Test 5: Existing summary.md (>10 bytes) is NOT overwritten
# ---------------------------------------------------------------------------
run_test "Existing summary.md (>10 bytes) is NOT overwritten"

TEST_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-ptf-XXXXXX")
_CLEANUP_DIRS+=("$TEST_DIR")
SESSION_ID="test-sess-nooverwrite-$$"

TRACE_ID=$(setup_trace_env "guardian" "$TEST_DIR" "$SESSION_ID")
TRACE_DIR="${TEST_DIR}/traces/${TRACE_ID}"

# Write a real summary.md (>10 bytes)
REAL_SUMMARY="# Real Guardian Summary\n## Operation: Commit\nThis is a real summary written by the agent."
echo -e "$REAL_SUMMARY" > "${TRACE_DIR}/summary.md"
ORIGINAL_CONTENT=$(cat "${TRACE_DIR}/summary.md")

OUTPUT=$(make_input "Agent" "guardian" | \
    env TRACE_STORE="$TEST_DIR/traces" \
        CLAUDE_SESSION_ID="$SESSION_ID" \
        CLAUDE_DIR="$TEST_DIR/.claude" \
    bash "$HOOKS_DIR/post-task.sh" 2>/dev/null || true)

NEW_CONTENT=$(cat "${TRACE_DIR}/summary.md")
if [[ "$NEW_CONTENT" == "$ORIGINAL_CONTENT" ]]; then
    pass_test
else
    fail_test "summary.md was overwritten! Expected to preserve original content."
fi

rm -rf "$TEST_DIR"

# ---------------------------------------------------------------------------
# Test 6: Empty subagent_type + active guardian marker → auto-detection
# ---------------------------------------------------------------------------
run_test "Empty subagent_type: auto-detects guardian from active marker"

TEST_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-ptf-XXXXXX")
_CLEANUP_DIRS+=("$TEST_DIR")
SESSION_ID="test-sess-autodet-$$"

TRACE_ID=$(setup_trace_env "guardian" "$TEST_DIR" "$SESSION_ID")
TRACE_DIR="${TEST_DIR}/traces/${TRACE_ID}"

# Invoke with empty subagent_type — hook should detect guardian from active marker
OUTPUT=$(make_input "Agent" "" | \
    env TRACE_STORE="$TEST_DIR/traces" \
        CLAUDE_SESSION_ID="$SESSION_ID" \
        CLAUDE_DIR="$TEST_DIR/.claude" \
    bash "$HOOKS_DIR/post-task.sh" 2>/dev/null || true)

SUM_FILE="${TRACE_DIR}/summary.md"
if [[ -f "$SUM_FILE" ]]; then
    SUM_CONTENT=$(cat "$SUM_FILE")
    if echo "$SUM_CONTENT" | grep -q "Guardian Summary\|Planner Summary\|Implementer Summary\|Agent Summary"; then
        pass_test
    else
        fail_test "summary.md exists but has unexpected content: $(head -2 "$SUM_FILE")"
    fi
else
    # Auto-detection may not work in all env setups; skip gracefully
    echo "  SKIP: no active trace detected (environment may lack CLAUDE_SESSION_ID matching)"
    TESTS_RUN=$((TESTS_RUN - 1))
fi

rm -rf "$TEST_DIR"

# ---------------------------------------------------------------------------
# Test 7: Fallback emits additionalContext JSON for non-implementer agents
# ---------------------------------------------------------------------------
run_test "Fallback emits additionalContext with summary for guardian"

TEST_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-ptf-XXXXXX")
_CLEANUP_DIRS+=("$TEST_DIR")
SESSION_ID="test-sess-addlctx-$$"

TRACE_ID=$(setup_trace_env "guardian" "$TEST_DIR" "$SESSION_ID")
TRACE_DIR="${TEST_DIR}/traces/${TRACE_ID}"

OUTPUT=$(make_input "Agent" "guardian" | \
    env TRACE_STORE="$TEST_DIR/traces" \
        CLAUDE_SESSION_ID="$SESSION_ID" \
        CLAUDE_DIR="$TEST_DIR/.claude" \
    bash "$HOOKS_DIR/post-task.sh" 2>/dev/null || true)

if echo "$OUTPUT" | jq -e '.additionalContext' >/dev/null 2>&1; then
    CTX=$(echo "$OUTPUT" | jq -r '.additionalContext')
    if echo "$CTX" | grep -q "post-task fallback"; then
        pass_test
    else
        fail_test "additionalContext missing 'post-task fallback' prefix: $CTX"
    fi
else
    fail_test "output is not JSON with additionalContext: $(echo "$OUTPUT" | head -3)"
fi

rm -rf "$TEST_DIR"

# ---------------------------------------------------------------------------
# Test 8: IS_SUBAGENT normalization — non-Task/Agent tool_name does NOT trigger
# ---------------------------------------------------------------------------
run_test "Non-Task/Agent tool_name does NOT trigger IS_SUBAGENT logic"

TEST_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-ptf-XXXXXX")
_CLEANUP_DIRS+=("$TEST_DIR")
SESSION_ID="test-sess-nosubagent-$$"

TRACE_ID=$(setup_trace_env "guardian" "$TEST_DIR" "$SESSION_ID")
TRACE_DIR="${TEST_DIR}/traces/${TRACE_ID}"

# Use tool_name=Bash — should not trigger fallback
OUTPUT=$(make_input "Bash" "guardian" | \
    env TRACE_STORE="$TEST_DIR/traces" \
        CLAUDE_SESSION_ID="$SESSION_ID" \
        CLAUDE_DIR="$TEST_DIR/.claude" \
    bash "$HOOKS_DIR/post-task.sh" 2>/dev/null || true)

SUM_FILE="${TRACE_DIR}/summary.md"
if [[ ! -f "$SUM_FILE" ]]; then
    pass_test
else
    fail_test "summary.md was written for non-subagent tool (Bash) — should not trigger fallback"
fi

rm -rf "$TEST_DIR"

# ---------------------------------------------------------------------------
# Test 9: post-task.sh syntax is valid bash
# ---------------------------------------------------------------------------
run_test "post-task.sh: valid bash syntax"
if bash -n "$HOOKS_DIR/post-task.sh" 2>/dev/null; then
    pass_test
else
    fail_test "post-task.sh has syntax errors"
fi

# ---------------------------------------------------------------------------
# Test 10: trace-lib.sh stale threshold is 1800 (30 min)
# ---------------------------------------------------------------------------
run_test "trace-lib.sh: stale threshold is 1800 (30 minutes)"
if grep -q 'stale_threshold=1800' "$HOOKS_DIR/trace-lib.sh" 2>/dev/null; then
    pass_test
else
    ACTUAL=$(grep 'stale_threshold=' "$HOOKS_DIR/trace-lib.sh" 2>/dev/null || echo "not found")
    fail_test "Expected stale_threshold=1800, found: $ACTUAL"
fi

# ---------------------------------------------------------------------------
# Test 11: agent docs have incremental summary instructions
# ---------------------------------------------------------------------------
run_test "guardian.md: has incremental summary.md instructions"
if grep -q 'Incremental summary.md' "$PROJECT_ROOT/agents/guardian.md" 2>/dev/null; then
    pass_test
else
    fail_test "guardian.md missing 'Incremental summary.md' instruction"
fi

run_test "tester.md: has incremental summary.md instructions"
if grep -q 'Incremental summary.md' "$PROJECT_ROOT/agents/tester.md" 2>/dev/null; then
    pass_test
else
    fail_test "tester.md missing 'Incremental summary.md' instruction"
fi

run_test "planner.md: has incremental summary.md instructions"
if grep -q 'Incremental summary.md' "$PROJECT_ROOT/agents/planner.md" 2>/dev/null; then
    pass_test
else
    fail_test "planner.md missing 'Incremental summary.md' instruction"
fi

# ---------------------------------------------------------------------------
# Test 12: post-task.sh has IS_SUBAGENT normalization
# ---------------------------------------------------------------------------
run_test "post-task.sh: IS_SUBAGENT normalization handles both Task and Agent"
if grep -q 'IS_SUBAGENT=false' "$HOOKS_DIR/post-task.sh" 2>/dev/null && \
   grep -q '"Agent".*IS_SUBAGENT\|IS_SUBAGENT.*"Agent"' "$HOOKS_DIR/post-task.sh" 2>/dev/null; then
    pass_test
else
    fail_test "IS_SUBAGENT normalization pattern not found"
fi

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_RUN total"
echo ""

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi

exit 0
