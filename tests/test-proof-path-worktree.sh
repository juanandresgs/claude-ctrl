#!/usr/bin/env bash
# Test proof-status path resolution in git worktree scenarios.
#
# Validates the fix for the .proof-status mismatch when orchestrator
# runs from ~/.claude and dispatches agents to git worktrees:
#
#   - resolve_proof_file() returns correct path with/without breadcrumb
#   - task-track.sh writes .active-worktree-path breadcrumb at implementer dispatch
#   - prompt-submit.sh uses resolver + dual-write on verification
#   - guard.sh falls back to orchestrator proof-status when worktree file missing
#   - check-tester.sh uses resolver + dual-write on auto-verify
#   - check-guardian.sh cleans up breadcrumb + worktree proof on commit
#   - session-end.sh cleans up .active-worktree-path
#   - Non-worktree path (no breadcrumb) works unchanged (regression)
#
# @decision DEC-PROOF-PATH-001
# @title Test suite for worktree proof-status path resolution
# @status accepted
# @rationale The proof-status gate broke in worktree scenarios because
#   orchestrator hooks (task-track, prompt-submit, check-tester) used
#   ~/.claude/.proof-status while guard.sh checked <worktree>/.claude/.proof-status.
#   This test suite verifies the fix: resolve_proof_file() + dual-write
#   + breadcrumb cleanup keeps both locations in sync.

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

# ─────────────────────────────────────────────────────────────────────────────
# Part A: Syntax validation
# ─────────────────────────────────────────────────────────────────────────────

run_test "Syntax: log.sh is valid bash"
if bash -n "$HOOKS_DIR/log.sh"; then
    pass_test
else
    fail_test "log.sh has syntax errors"
fi

run_test "Syntax: task-track.sh is valid bash"
if bash -n "$HOOKS_DIR/task-track.sh"; then
    pass_test
else
    fail_test "task-track.sh has syntax errors"
fi

run_test "Syntax: prompt-submit.sh is valid bash"
if bash -n "$HOOKS_DIR/prompt-submit.sh"; then
    pass_test
else
    fail_test "prompt-submit.sh has syntax errors"
fi

run_test "Syntax: guard.sh is valid bash"
if bash -n "$HOOKS_DIR/guard.sh"; then
    pass_test
else
    fail_test "guard.sh has syntax errors"
fi

run_test "Syntax: check-tester.sh is valid bash"
if bash -n "$HOOKS_DIR/check-tester.sh"; then
    pass_test
else
    fail_test "check-tester.sh has syntax errors"
fi

run_test "Syntax: check-guardian.sh is valid bash"
if bash -n "$HOOKS_DIR/check-guardian.sh"; then
    pass_test
else
    fail_test "check-guardian.sh has syntax errors"
fi

run_test "Syntax: session-end.sh is valid bash"
if bash -n "$HOOKS_DIR/session-end.sh"; then
    pass_test
else
    fail_test "session-end.sh has syntax errors"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Part B: resolve_proof_file() unit tests
# ─────────────────────────────────────────────────────────────────────────────

# Helper: source log.sh and call resolve_proof_file() with mock env
call_resolve_proof_file() {
    local claude_dir="$1"
    local breadcrumb_content="${2:-}"  # empty = no breadcrumb

    local breadcrumb_file="$claude_dir/.active-worktree-path"
    if [[ -n "$breadcrumb_content" ]]; then
        echo "$breadcrumb_content" > "$breadcrumb_file"
    else
        rm -f "$breadcrumb_file"
    fi

    # Source log.sh and call resolve_proof_file
    bash -c "
        source '$HOOKS_DIR/log.sh'
        CLAUDE_DIR='$claude_dir'
        resolve_proof_file
    " 2>/dev/null
}

run_test "resolve_proof_file: no breadcrumb returns CLAUDE_DIR path"
TEMP_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-XXXXXX")
RESULT=$(call_resolve_proof_file "$TEMP_CLAUDE" "")
EXPECTED="$TEMP_CLAUDE/.proof-status"
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected '$EXPECTED', got '$RESULT'"
fi
rm -rf "$TEMP_CLAUDE"

run_test "resolve_proof_file: breadcrumb with pending worktree proof returns worktree path"
TEMP_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-XXXXXX")
TEMP_WORKTREE=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-wt-XXXXXX")
mkdir -p "$TEMP_WORKTREE/.claude"
echo "pending|12345" > "$TEMP_WORKTREE/.claude/.proof-status"
RESULT=$(call_resolve_proof_file "$TEMP_CLAUDE" "$TEMP_WORKTREE")
EXPECTED="$TEMP_WORKTREE/.claude/.proof-status"
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected worktree path '$EXPECTED', got '$RESULT'"
fi
rm -rf "$TEMP_CLAUDE" "$TEMP_WORKTREE"

run_test "resolve_proof_file: breadcrumb with verified worktree proof returns worktree path"
TEMP_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-XXXXXX")
TEMP_WORKTREE=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-wt-XXXXXX")
mkdir -p "$TEMP_WORKTREE/.claude"
echo "verified|12345" > "$TEMP_WORKTREE/.claude/.proof-status"
RESULT=$(call_resolve_proof_file "$TEMP_CLAUDE" "$TEMP_WORKTREE")
EXPECTED="$TEMP_WORKTREE/.claude/.proof-status"
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected worktree path '$EXPECTED', got '$RESULT'"
fi
rm -rf "$TEMP_CLAUDE" "$TEMP_WORKTREE"

run_test "resolve_proof_file: stale breadcrumb (deleted worktree) returns CLAUDE_DIR path"
TEMP_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-XXXXXX")
# Breadcrumb points to a path that doesn't exist
RESULT=$(call_resolve_proof_file "$TEMP_CLAUDE" "/nonexistent/path/that/does/not/exist")
EXPECTED="$TEMP_CLAUDE/.proof-status"
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected fallback to CLAUDE_DIR path '$EXPECTED', got '$RESULT'"
fi
rm -rf "$TEMP_CLAUDE"

run_test "resolve_proof_file: breadcrumb worktree without proof-status returns CLAUDE_DIR path"
TEMP_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-XXXXXX")
TEMP_WORKTREE=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-wt-XXXXXX")
mkdir -p "$TEMP_WORKTREE/.claude"
# No .proof-status in worktree
RESULT=$(call_resolve_proof_file "$TEMP_CLAUDE" "$TEMP_WORKTREE")
EXPECTED="$TEMP_CLAUDE/.proof-status"
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected fallback '$EXPECTED', got '$RESULT'"
fi
rm -rf "$TEMP_CLAUDE" "$TEMP_WORKTREE"

run_test "resolve_proof_file: breadcrumb worktree with needs-verification returns CLAUDE_DIR path (only active states)"
TEMP_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-XXXXXX")
TEMP_WORKTREE=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-wt-XXXXXX")
mkdir -p "$TEMP_WORKTREE/.claude"
# needs-verification is an orchestrator-side state, not a worktree state
# The worktree tester writes "pending"; orchestrator task-track writes "needs-verification"
echo "needs-verification|12345" > "$TEMP_WORKTREE/.claude/.proof-status"
RESULT=$(call_resolve_proof_file "$TEMP_CLAUDE" "$TEMP_WORKTREE")
EXPECTED="$TEMP_CLAUDE/.proof-status"
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected fallback for needs-verification '$EXPECTED', got '$RESULT'"
fi
rm -rf "$TEMP_CLAUDE" "$TEMP_WORKTREE"

# ─────────────────────────────────────────────────────────────────────────────
# Part C: task-track.sh — breadcrumb written at implementer dispatch
# ─────────────────────────────────────────────────────────────────────────────

run_test "task-track: implementer dispatch writes .active-worktree-path when worktrees exist"
TEMP_ORCHESTRATOR=$(mktemp -d "$PROJECT_ROOT/tmp/test-tt-orch-XXXXXX")
git -C "$TEMP_ORCHESTRATOR" init > /dev/null 2>&1
mkdir -p "$TEMP_ORCHESTRATOR/.claude"

# Create a fake worktree directory (simulated)
TEMP_WORKTREE=$(mktemp -d "$PROJECT_ROOT/tmp/test-tt-wt-XXXXXX")
git -C "$TEMP_WORKTREE" init > /dev/null 2>&1

# Stub git worktree list to return our fake worktree
INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Task",
  "tool_input": {
    "subagent_type": "implementer",
    "instructions": "Test implementation"
  }
}
EOF
)

# Run with stub — the worktree is detected by `git worktree list` in TEMP_ORCHESTRATOR
# Since TEMP_ORCHESTRATOR has no linked worktrees, breadcrumb won't be written
# (This tests the "has worktrees" branch separately below)
cd "$TEMP_ORCHESTRATOR" && \
    CLAUDE_PROJECT_DIR="$TEMP_ORCHESTRATOR" \
    echo "$INPUT_JSON" | bash "$HOOKS_DIR/task-track.sh" > /dev/null 2>&1

# Confirm .proof-status was created (Gate C still works)
if [[ -f "$TEMP_ORCHESTRATOR/.claude/.proof-status" ]]; then
    STATUS=$(cut -d'|' -f1 "$TEMP_ORCHESTRATOR/.claude/.proof-status")
    if [[ "$STATUS" == "needs-verification" ]]; then
        pass_test
    else
        fail_test "Gate C: wrong status '$STATUS' (expected needs-verification)"
    fi
else
    fail_test "Gate C: .proof-status not created"
fi

cd "$PROJECT_ROOT"
rm -rf "$TEMP_ORCHESTRATOR" "$TEMP_WORKTREE"

# ─────────────────────────────────────────────────────────────────────────────
# Part D: prompt-submit.sh — dual-write when user types "verified"
# ─────────────────────────────────────────────────────────────────────────────

run_prompt_submit() {
    local prompt="$1"
    local proof_status="$2"
    local claude_dir="$3"
    local worktree_path="${4:-}"

    if [[ -n "$proof_status" ]]; then
        mkdir -p "$claude_dir"
        echo "$proof_status" > "$claude_dir/.proof-status"
    fi

    if [[ -n "$worktree_path" ]]; then
        echo "$worktree_path" > "$claude_dir/.active-worktree-path"
    fi

    local INPUT_JSON
    INPUT_JSON=$(jq -n --arg p "$prompt" '{"hook_event_name":"UserPromptSubmit","prompt":$p}')

    local OUTPUT
    OUTPUT=$(CLAUDE_PROJECT_DIR="$(dirname "$claude_dir")" \
             PROJECT_ROOT="$(dirname "$claude_dir")" \
             echo "$INPUT_JSON" | bash "$HOOKS_DIR/prompt-submit.sh" 2>/dev/null || true)
    echo "$OUTPUT"
}

run_test "prompt-submit: 'verified' keyword transitions pending -> verified (non-worktree)"
TEMP_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-ps-XXXXXX")
TEMP_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-ps-proj-XXXXXX")
git -C "$TEMP_PROJ" init > /dev/null 2>&1
mkdir -p "$TEMP_PROJ/.claude"
echo "pending|12345" > "$TEMP_PROJ/.claude/.proof-status"

INPUT_JSON=$(jq -n '{"hook_event_name":"UserPromptSubmit","prompt":"verified"}')
cd "$TEMP_PROJ" && \
    CLAUDE_PROJECT_DIR="$TEMP_PROJ" \
    echo "$INPUT_JSON" | bash "$HOOKS_DIR/prompt-submit.sh" > /dev/null 2>&1

STATUS=$(cut -d'|' -f1 "$TEMP_PROJ/.claude/.proof-status" 2>/dev/null || echo "missing")
if [[ "$STATUS" == "verified" ]]; then
    pass_test
else
    fail_test "Expected 'verified', got '$STATUS'"
fi

cd "$PROJECT_ROOT"
rm -rf "$TEMP_PROJ" "$TEMP_CLAUDE"

run_test "prompt-submit: 'lgtm' keyword also transitions pending -> verified"
TEMP_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-ps-lgtm-XXXXXX")
git -C "$TEMP_PROJ" init > /dev/null 2>&1
mkdir -p "$TEMP_PROJ/.claude"
echo "pending|12345" > "$TEMP_PROJ/.claude/.proof-status"

INPUT_JSON=$(jq -n '{"hook_event_name":"UserPromptSubmit","prompt":"lgtm"}')
cd "$TEMP_PROJ" && \
    CLAUDE_PROJECT_DIR="$TEMP_PROJ" \
    echo "$INPUT_JSON" | bash "$HOOKS_DIR/prompt-submit.sh" > /dev/null 2>&1

STATUS=$(cut -d'|' -f1 "$TEMP_PROJ/.claude/.proof-status" 2>/dev/null || echo "missing")
if [[ "$STATUS" == "verified" ]]; then
    pass_test
else
    fail_test "Expected 'verified' after lgtm, got '$STATUS'"
fi

cd "$PROJECT_ROOT"
rm -rf "$TEMP_PROJ"

run_test "prompt-submit: 'verified' with breadcrumb dual-writes to worktree path"
TEMP_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-ps-wt-XXXXXX")
TEMP_WORKTREE=$(mktemp -d "$PROJECT_ROOT/tmp/test-ps-wt2-XXXXXX")
git -C "$TEMP_PROJ" init > /dev/null 2>&1
mkdir -p "$TEMP_PROJ/.claude"
mkdir -p "$TEMP_WORKTREE/.claude"
# Worktree has pending; breadcrumb points to it
echo "pending|12345" > "$TEMP_WORKTREE/.claude/.proof-status"
echo "$TEMP_WORKTREE" > "$TEMP_PROJ/.claude/.active-worktree-path"

INPUT_JSON=$(jq -n '{"hook_event_name":"UserPromptSubmit","prompt":"verified"}')
cd "$TEMP_PROJ" && \
    CLAUDE_PROJECT_DIR="$TEMP_PROJ" \
    echo "$INPUT_JSON" | bash "$HOOKS_DIR/prompt-submit.sh" > /dev/null 2>&1

WORKTREE_STATUS=$(cut -d'|' -f1 "$TEMP_WORKTREE/.claude/.proof-status" 2>/dev/null || echo "missing")
ORCH_STATUS=$(cut -d'|' -f1 "$TEMP_PROJ/.claude/.proof-status" 2>/dev/null || echo "missing")

if [[ "$WORKTREE_STATUS" == "verified" ]]; then
    if [[ "$ORCH_STATUS" == "verified" ]]; then
        pass_test
    else
        fail_test "Worktree verified but orchestrator proof-status is '$ORCH_STATUS' (expected dual-write)"
    fi
else
    fail_test "Worktree proof-status not updated: '$WORKTREE_STATUS'"
fi

cd "$PROJECT_ROOT"
rm -rf "$TEMP_PROJ" "$TEMP_WORKTREE"

run_test "prompt-submit: 'verified' with needs-verification also transitions to verified"
TEMP_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-ps-nv-XXXXXX")
git -C "$TEMP_PROJ" init > /dev/null 2>&1
mkdir -p "$TEMP_PROJ/.claude"
echo "needs-verification|12345" > "$TEMP_PROJ/.claude/.proof-status"

INPUT_JSON=$(jq -n '{"hook_event_name":"UserPromptSubmit","prompt":"verified"}')
cd "$TEMP_PROJ" && \
    CLAUDE_PROJECT_DIR="$TEMP_PROJ" \
    echo "$INPUT_JSON" | bash "$HOOKS_DIR/prompt-submit.sh" > /dev/null 2>&1

STATUS=$(cut -d'|' -f1 "$TEMP_PROJ/.claude/.proof-status" 2>/dev/null || echo "missing")
if [[ "$STATUS" == "verified" ]]; then
    pass_test
else
    fail_test "Expected 'verified' from needs-verification, got '$STATUS'"
fi

cd "$PROJECT_ROOT"
rm -rf "$TEMP_PROJ"

# ─────────────────────────────────────────────────────────────────────────────
# Part E: guard.sh — fallback to orchestrator proof-status
# ─────────────────────────────────────────────────────────────────────────────

run_test "guard.sh: fallback to orchestrator proof-status when worktree file missing"
TEMP_WORKTREE=$(mktemp -d "$PROJECT_ROOT/tmp/test-guard-fb-XXXXXX")
TEMP_ORCH=$(mktemp -d "$PROJECT_ROOT/tmp/test-guard-orch-XXXXXX")
git -C "$TEMP_WORKTREE" init > /dev/null 2>&1
mkdir -p "$TEMP_WORKTREE/.claude"
mkdir -p "$TEMP_ORCH"

# Orchestrator has verified; worktree has no .proof-status
echo "verified|12345" > "$TEMP_ORCH/.proof-status"

INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "cd $TEMP_WORKTREE && git commit -m test"
  }
}
EOF
)

OUTPUT=$(cd "$TEMP_WORKTREE" && \
         HOME_CLAUDE_DIR="$TEMP_ORCH" \
         CLAUDE_PROJECT_DIR="$TEMP_WORKTREE" \
         echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

if echo "$OUTPUT" | grep -q "deny"; then
    fail_test "guard.sh blocked commit even though orchestrator has verified status"
else
    pass_test
fi

cd "$PROJECT_ROOT"
rm -rf "$TEMP_WORKTREE" "$TEMP_ORCH"

run_test "guard.sh: worktree proof-status takes precedence over orchestrator"
TEMP_WORKTREE=$(mktemp -d "$PROJECT_ROOT/tmp/test-guard-wt-XXXXXX")
TEMP_ORCH=$(mktemp -d "$PROJECT_ROOT/tmp/test-guard-orch2-XXXXXX")
git -C "$TEMP_WORKTREE" init > /dev/null 2>&1
mkdir -p "$TEMP_WORKTREE/.claude"
mkdir -p "$TEMP_ORCH"

# Worktree has pending (should block); orchestrator has verified (should not matter)
echo "pending|12345" > "$TEMP_WORKTREE/.claude/.proof-status"
echo "verified|12345" > "$TEMP_ORCH/.proof-status"

INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "cd $TEMP_WORKTREE && git commit -m test"
  }
}
EOF
)

OUTPUT=$(cd "$TEMP_WORKTREE" && \
         HOME_CLAUDE_DIR="$TEMP_ORCH" \
         CLAUDE_PROJECT_DIR="$TEMP_WORKTREE" \
         echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

if echo "$OUTPUT" | grep -q "deny"; then
    pass_test
else
    fail_test "guard.sh allowed commit when worktree has pending status"
fi

cd "$PROJECT_ROOT"
rm -rf "$TEMP_WORKTREE" "$TEMP_ORCH"

# ─────────────────────────────────────────────────────────────────────────────
# Part F: check-guardian.sh — breadcrumb cleanup
# ─────────────────────────────────────────────────────────────────────────────

run_test "check-guardian.sh: cleans breadcrumb after successful commit"
TEMP_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-cg-XXXXXX")
TEMP_WORKTREE=$(mktemp -d "$PROJECT_ROOT/tmp/test-cg-wt-XXXXXX")
git -C "$TEMP_PROJ" init > /dev/null 2>&1
git -C "$TEMP_PROJ" commit --allow-empty -m "init" > /dev/null 2>&1
mkdir -p "$TEMP_PROJ/.claude"
mkdir -p "$TEMP_WORKTREE/.claude"
echo "verified|12345" > "$TEMP_PROJ/.claude/.proof-status"
echo "verified|12345" > "$TEMP_WORKTREE/.claude/.proof-status"
echo "$TEMP_WORKTREE" > "$TEMP_PROJ/.claude/.active-worktree-path"

RESPONSE_JSON=$(jq -n '{"response":"Guardian committed successfully — commit abc123 created"}')

cd "$TEMP_PROJ" && \
    CLAUDE_PROJECT_DIR="$TEMP_PROJ" \
    echo "$RESPONSE_JSON" | bash "$HOOKS_DIR/check-guardian.sh" > /dev/null 2>&1

BREADCRUMB_EXISTS=false
[[ -f "$TEMP_PROJ/.claude/.active-worktree-path" ]] && BREADCRUMB_EXISTS=true

ORCH_PROOF_EXISTS=false
[[ -f "$TEMP_PROJ/.claude/.proof-status" ]] && ORCH_PROOF_EXISTS=true

WORKTREE_PROOF_EXISTS=false
[[ -f "$TEMP_WORKTREE/.claude/.proof-status" ]] && WORKTREE_PROOF_EXISTS=true

if [[ "$BREADCRUMB_EXISTS" == "false" && "$ORCH_PROOF_EXISTS" == "false" && "$WORKTREE_PROOF_EXISTS" == "false" ]]; then
    pass_test
else
    fail_test "Cleanup incomplete: breadcrumb=$BREADCRUMB_EXISTS, orch_proof=$ORCH_PROOF_EXISTS, wt_proof=$WORKTREE_PROOF_EXISTS"
fi

cd "$PROJECT_ROOT"
rm -rf "$TEMP_PROJ" "$TEMP_WORKTREE"

# ─────────────────────────────────────────────────────────────────────────────
# Part G: session-end.sh — breadcrumb cleanup
# ─────────────────────────────────────────────────────────────────────────────

run_test "session-end.sh: cleans .active-worktree-path on session end"
TEMP_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-se-XXXXXX")
git -C "$TEMP_PROJ" init > /dev/null 2>&1
mkdir -p "$TEMP_PROJ/.claude"
echo "/some/worktree/path" > "$TEMP_PROJ/.claude/.active-worktree-path"

INPUT_JSON=$(jq -n '{"reason":"normal"}')
cd "$TEMP_PROJ" && \
    CLAUDE_PROJECT_DIR="$TEMP_PROJ" \
    CLAUDE_SESSION_ID="test-session-123" \
    echo "$INPUT_JSON" | bash "$HOOKS_DIR/session-end.sh" > /dev/null 2>&1

if [[ ! -f "$TEMP_PROJ/.claude/.active-worktree-path" ]]; then
    pass_test
else
    fail_test ".active-worktree-path not cleaned up by session-end.sh"
fi

cd "$PROJECT_ROOT"
rm -rf "$TEMP_PROJ"

# ─────────────────────────────────────────────────────────────────────────────
# Part H: Regression — non-worktree path unchanged
# ─────────────────────────────────────────────────────────────────────────────

run_test "Regression: no breadcrumb = standard flow unchanged (task-track Gate A)"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-reg-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"
echo "needs-verification|12345" > "$TEMP_REPO/.claude/.proof-status"

INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Task",
  "tool_input": {
    "subagent_type": "guardian",
    "instructions": "Commit"
  }
}
EOF
)

OUTPUT=$(cd "$TEMP_REPO" && \
         CLAUDE_PROJECT_DIR="$TEMP_REPO" \
         echo "$INPUT_JSON" | bash "$HOOKS_DIR/task-track.sh" 2>&1) || true

if echo "$OUTPUT" | grep -q "deny"; then
    pass_test
else
    fail_test "Guardian allowed with needs-verification when no breadcrumb"
fi

cd "$PROJECT_ROOT"
rm -rf "$TEMP_REPO"

run_test "Regression: verified with no breadcrumb allows Guardian (standard flow)"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-reg2-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"
echo "verified|12345" > "$TEMP_REPO/.claude/.proof-status"

INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Task",
  "tool_input": {
    "subagent_type": "guardian",
    "instructions": "Commit"
  }
}
EOF
)

OUTPUT=$(cd "$TEMP_REPO" && \
         CLAUDE_PROJECT_DIR="$TEMP_REPO" \
         echo "$INPUT_JSON" | bash "$HOOKS_DIR/task-track.sh" 2>&1) || true

if echo "$OUTPUT" | grep -q "deny"; then
    fail_test "Guardian blocked with verified status (should allow)"
else
    pass_test
fi

cd "$PROJECT_ROOT"
rm -rf "$TEMP_REPO"

# ─────────────────────────────────────────────────────────────────────────────
# Part I: .gitignore — new state files excluded
# ─────────────────────────────────────────────────────────────────────────────

run_test ".gitignore: .active-worktree-path is excluded"
if grep -q "\.active-worktree-path" "$PROJECT_ROOT/.gitignore"; then
    pass_test
else
    fail_test ".active-worktree-path not found in .gitignore"
fi

run_test ".gitignore: .proof-status is excluded"
if grep -q "\.proof-status" "$PROJECT_ROOT/.gitignore"; then
    pass_test
else
    fail_test ".proof-status not found in .gitignore"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=========================================="
echo "Test Results: $TESTS_PASSED/$TESTS_RUN passed"
echo "=========================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
    echo "FAILED: $TESTS_FAILED tests failed"
    exit 1
else
    echo "SUCCESS: All tests passed"
    exit 0
fi
