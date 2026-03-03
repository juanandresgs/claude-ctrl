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
if bash -n "$HOOKS_DIR/pre-bash.sh"; then
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
# Sets CLAUDE_DIR and PROJECT_ROOT so project_hash() computes from a known
# directory, making the expected scoped file name predictable in tests.
# Also uses a scoped breadcrumb (.active-worktree-path-{phash}) matching the
# real production format since PROJECT_ROOT is set.
call_resolve_proof_file() {
    local claude_dir="$1"
    local breadcrumb_content="${2:-}"  # empty = no breadcrumb
    # Use claude_dir as PROJECT_ROOT so phash is deterministic
    local project_root="$claude_dir"

    # Compute phash the same way log.sh does
    local phash
    phash=$(echo "$project_root" | shasum -a 256 | cut -c1-8 2>/dev/null || echo "00000000")

    # Write breadcrumb using the scoped format (production format)
    local breadcrumb_file="$claude_dir/.active-worktree-path-${phash}"
    if [[ -n "$breadcrumb_content" ]]; then
        echo "$breadcrumb_content" > "$breadcrumb_file"
    else
        rm -f "$breadcrumb_file"
        rm -f "$claude_dir/.active-worktree-path"  # also remove legacy
    fi

    # Source log.sh and call resolve_proof_file
    bash -c "
        source '$HOOKS_DIR/log.sh'
        CLAUDE_DIR='$claude_dir'
        PROJECT_ROOT='$project_root'
        resolve_proof_file
    " 2>/dev/null
}

# Helper: compute the scoped proof-status path for a given CLAUDE_DIR
# Used to build expected paths in tests that match the scoped format.
scoped_proof_path() {
    local claude_dir="$1"
    local phash
    phash=$(echo "$claude_dir" | shasum -a 256 | cut -c1-8 2>/dev/null || echo "00000000")
    echo "$claude_dir/.proof-status-${phash}"
}

run_test "resolve_proof_file: no breadcrumb returns scoped CLAUDE_DIR path"
TEMP_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-XXXXXX")
RESULT=$(call_resolve_proof_file "$TEMP_CLAUDE" "")
EXPECTED=$(scoped_proof_path "$TEMP_CLAUDE")
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected scoped path '$EXPECTED', got '$RESULT'"
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

run_test "resolve_proof_file: stale breadcrumb (deleted worktree) returns scoped CLAUDE_DIR path"
TEMP_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-XXXXXX")
# Breadcrumb points to a path that doesn't exist
RESULT=$(call_resolve_proof_file "$TEMP_CLAUDE" "/nonexistent/path/that/does/not/exist")
EXPECTED=$(scoped_proof_path "$TEMP_CLAUDE")
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected fallback to scoped CLAUDE_DIR path '$EXPECTED', got '$RESULT'"
fi
rm -rf "$TEMP_CLAUDE"

run_test "resolve_proof_file: breadcrumb worktree without proof-status returns scoped CLAUDE_DIR path"
TEMP_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-XXXXXX")
TEMP_WORKTREE=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-wt-XXXXXX")
mkdir -p "$TEMP_WORKTREE/.claude"
# No .proof-status in worktree
RESULT=$(call_resolve_proof_file "$TEMP_CLAUDE" "$TEMP_WORKTREE")
EXPECTED=$(scoped_proof_path "$TEMP_CLAUDE")
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected scoped fallback '$EXPECTED', got '$RESULT'"
fi
rm -rf "$TEMP_CLAUDE" "$TEMP_WORKTREE"

run_test "resolve_proof_file: breadcrumb worktree with needs-verification returns WORKTREE path (W4-2 fix)"
TEMP_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-XXXXXX")
TEMP_WORKTREE=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-wt-XXXXXX")
mkdir -p "$TEMP_WORKTREE/.claude"
# needs-verification is written by task-track.sh at implementer dispatch.
# W4-2 fix: must return the worktree path (not CLAUDE_DIR) so check-tester.sh
# reads/writes the correct file and the dedup guard does not fire on stale
# orchestrator-side "verified" from a prior session. (Issue #41)
echo "needs-verification|12345" > "$TEMP_WORKTREE/.claude/.proof-status"
RESULT=$(call_resolve_proof_file "$TEMP_CLAUDE" "$TEMP_WORKTREE")
EXPECTED="$TEMP_WORKTREE/.claude/.proof-status"
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected worktree path '$EXPECTED', got '$RESULT' (W4-2: needs-verification should resolve to worktree)"
fi
rm -rf "$TEMP_CLAUDE" "$TEMP_WORKTREE"

# ─────────────────────────────────────────────────────────────────────────────
# Part C: task-track.sh — breadcrumb written at implementer dispatch
# ─────────────────────────────────────────────────────────────────────────────

run_test "task-track: implementer dispatch from main worktree without linked worktrees emits deny (Gate C.1)"
# Gate C.1 blocks implementer dispatch from the main worktree when no linked worktrees exist.
# Gate C.2 (writes .proof-status-{phash}) only runs AFTER C.1 passes.
# This test verifies C.1 fires correctly; C.2 is exercised in the real integration flow.
TEMP_ORCHESTRATOR=$(mktemp -d "$PROJECT_ROOT/tmp/test-tt-orch-XXXXXX")
git -C "$TEMP_ORCHESTRATOR" init > /dev/null 2>&1
git -C "$TEMP_ORCHESTRATOR" commit --allow-empty -m "init" > /dev/null 2>&1
mkdir -p "$TEMP_ORCHESTRATOR/.claude"

TT_INPUT_FILE=$(mktemp "$PROJECT_ROOT/tmp/test-tt-input-XXXXXX.json")
cat > "$TT_INPUT_FILE" <<'TTEOF'
{
  "tool_name": "Task",
  "tool_input": {
    "subagent_type": "implementer",
    "instructions": "Test implementation"
  }
}
TTEOF

# task-track.sh exits 0 even on deny (emit_deny exits 0 with JSON deny body)
TT_OUTPUT=$(CLAUDE_PROJECT_DIR="$TEMP_ORCHESTRATOR" \
    bash -c "cd '$TEMP_ORCHESTRATOR' && bash '$HOOKS_DIR/task-track.sh' < '$TT_INPUT_FILE'" 2>/dev/null || true)

rm -f "$TT_INPUT_FILE"

# Gate C.1 should emit a deny response (no linked worktrees)
if echo "$TT_OUTPUT" | grep -q '"permissionDecision":"deny"'; then
    pass_test
else
    fail_test "Expected Gate C.1 deny for implementer on main worktree without linked worktrees. Output: $TT_OUTPUT"
fi

rm -rf "$TEMP_ORCHESTRATOR"

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
         echo "$INPUT_JSON" | bash "$HOOKS_DIR/pre-bash.sh" 2>&1) || true

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
         echo "$INPUT_JSON" | bash "$HOOKS_DIR/pre-bash.sh" 2>&1) || true

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
# Part J: Resolver consistency — all hooks find the same proof file
#
# Verifies that resolve_proof_file() returns the SAME path regardless of how
# env vars are arranged, so every hook (task-track, prompt-submit, guard,
# check-tester) reads and writes the same file.
#
# States under test:
#   J1. Worktree active with breadcrumb → all calls find worktree proof
#   J2. Breadcrumb stale (target deleted) → all fall back to scoped CLAUDE_DIR
#   J3. Only legacy .proof-status exists (no scoped file) → found correctly
#   J4. No proof file, no breadcrumb → all return scoped default (write target)
#   J5. Scoped file exists, no breadcrumb → returns scoped (not legacy)
#   J6. Both scoped and legacy exist, no breadcrumb → returns scoped (priority)
#   J7. Breadcrumb exists but worktree proof is absent → scoped fallback
#   J8. needs-verification in worktree with breadcrumb → returns worktree path
# ─────────────────────────────────────────────────────────────────────────────

# Helper: call resolve_proof_file() with explicit CLAUDE_DIR and PROJECT_ROOT,
# no breadcrumb manipulation beyond what the caller provides.
# Both CLAUDE_DIR and PROJECT_ROOT are set so project_hash is deterministic.
_resolve_j() {
    local claude_dir="$1"
    local project_root="$2"
    bash -c "
        source '$HOOKS_DIR/log.sh' 2>/dev/null
        export CLAUDE_DIR='$claude_dir'
        export PROJECT_ROOT='$project_root'
        resolve_proof_file 2>/dev/null
    "
}

# Helper: compute project_hash the same way log.sh does
_phash_j() {
    echo "$1" | shasum -a 256 | cut -c1-8 2>/dev/null || echo "00000000"
}

run_test "Part J1: worktree active with breadcrumb → all resolve calls find worktree proof"
J1_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-j1-cl-XXXXXX")
J1_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-j1-proj-XXXXXX")
J1_WT=$(mktemp -d "$PROJECT_ROOT/tmp/test-j1-wt-XXXXXX")
mkdir -p "$J1_WT/.claude"
J1_PHASH=$(_phash_j "$J1_PROJ")
echo "$J1_WT" > "$J1_CLAUDE/.active-worktree-path-${J1_PHASH}"
echo "pending|12345" > "$J1_WT/.claude/.proof-status"

# Simulate three different callers: task-track, prompt-submit, guard.sh
R1=$(_resolve_j "$J1_CLAUDE" "$J1_PROJ")
R2=$(_resolve_j "$J1_CLAUDE" "$J1_PROJ")
R3=$(_resolve_j "$J1_CLAUDE" "$J1_PROJ")
EXPECTED_J1="$J1_WT/.claude/.proof-status"

if [[ "$R1" == "$EXPECTED_J1" && "$R2" == "$EXPECTED_J1" && "$R3" == "$EXPECTED_J1" ]]; then
    pass_test
else
    fail_test "Inconsistent resolution: R1='$R1' R2='$R2' R3='$R3' (want '$EXPECTED_J1')"
fi
rm -rf "$J1_CLAUDE" "$J1_PROJ" "$J1_WT"

run_test "Part J2: stale breadcrumb (worktree dir deleted) → all fall back to scoped CLAUDE_DIR path"
J2_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-j2-cl-XXXXXX")
J2_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-j2-proj-XXXXXX")
J2_PHASH=$(_phash_j "$J2_PROJ")
echo "/nonexistent/worktree/path" > "$J2_CLAUDE/.active-worktree-path-${J2_PHASH}"
# No scoped proof — should return default scoped path
EXPECTED_J2="$J2_CLAUDE/.proof-status-${J2_PHASH}"

R1=$(_resolve_j "$J2_CLAUDE" "$J2_PROJ")
R2=$(_resolve_j "$J2_CLAUDE" "$J2_PROJ")
if [[ "$R1" == "$EXPECTED_J2" && "$R2" == "$EXPECTED_J2" ]]; then
    pass_test
else
    fail_test "Expected scoped fallback '$EXPECTED_J2', got R1='$R1' R2='$R2'"
fi
rm -rf "$J2_CLAUDE" "$J2_PROJ"

run_test "Part J3: only legacy .proof-status exists (no scoped file) → found at legacy path"
J3_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-j3-cl-XXXXXX")
J3_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-j3-proj-XXXXXX")
# No scoped proof, no breadcrumb; only legacy
echo "pending|12345" > "$J3_CLAUDE/.proof-status"
EXPECTED_J3="$J3_CLAUDE/.proof-status"

R1=$(_resolve_j "$J3_CLAUDE" "$J3_PROJ")
if [[ "$R1" == "$EXPECTED_J3" ]]; then
    pass_test
else
    fail_test "Expected legacy path '$EXPECTED_J3', got '$R1'"
fi
rm -rf "$J3_CLAUDE" "$J3_PROJ"

run_test "Part J4: no proof file, no breadcrumb → all callers return scoped default (new write target)"
J4_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-j4-cl-XXXXXX")
J4_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-j4-proj-XXXXXX")
J4_PHASH=$(_phash_j "$J4_PROJ")
EXPECTED_J4="$J4_CLAUDE/.proof-status-${J4_PHASH}"

R1=$(_resolve_j "$J4_CLAUDE" "$J4_PROJ")
R2=$(_resolve_j "$J4_CLAUDE" "$J4_PROJ")
if [[ "$R1" == "$EXPECTED_J4" && "$R2" == "$EXPECTED_J4" ]]; then
    pass_test
else
    fail_test "Expected scoped default '$EXPECTED_J4', got R1='$R1' R2='$R2'"
fi
rm -rf "$J4_CLAUDE" "$J4_PROJ"

run_test "Part J5: scoped file exists, no breadcrumb → returns scoped (not legacy)"
J5_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-j5-cl-XXXXXX")
J5_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-j5-proj-XXXXXX")
J5_PHASH=$(_phash_j "$J5_PROJ")
echo "verified|12345" > "$J5_CLAUDE/.proof-status-${J5_PHASH}"
echo "pending|99999" > "$J5_CLAUDE/.proof-status"
EXPECTED_J5="$J5_CLAUDE/.proof-status-${J5_PHASH}"

R1=$(_resolve_j "$J5_CLAUDE" "$J5_PROJ")
if [[ "$R1" == "$EXPECTED_J5" ]]; then
    pass_test
else
    fail_test "Expected scoped '$EXPECTED_J5' over legacy, got '$R1'"
fi
rm -rf "$J5_CLAUDE" "$J5_PROJ"

run_test "Part J6: both scoped and legacy exist, no breadcrumb → scoped takes priority"
J6_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-j6-cl-XXXXXX")
J6_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-j6-proj-XXXXXX")
J6_PHASH=$(_phash_j "$J6_PROJ")
echo "verified|11111" > "$J6_CLAUDE/.proof-status-${J6_PHASH}"
echo "needs-verification|22222" > "$J6_CLAUDE/.proof-status"
EXPECTED_J6="$J6_CLAUDE/.proof-status-${J6_PHASH}"

R1=$(_resolve_j "$J6_CLAUDE" "$J6_PROJ")
if [[ "$R1" == "$EXPECTED_J6" ]]; then
    pass_test
else
    fail_test "Expected scoped '$EXPECTED_J6' to have priority over legacy, got '$R1'"
fi
rm -rf "$J6_CLAUDE" "$J6_PROJ"

run_test "Part J7: breadcrumb present but worktree has no proof → scoped CLAUDE_DIR fallback"
J7_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-j7-cl-XXXXXX")
J7_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-j7-proj-XXXXXX")
J7_WT=$(mktemp -d "$PROJECT_ROOT/tmp/test-j7-wt-XXXXXX")
mkdir -p "$J7_WT/.claude"
J7_PHASH=$(_phash_j "$J7_PROJ")
echo "$J7_WT" > "$J7_CLAUDE/.active-worktree-path-${J7_PHASH}"
# No .proof-status in the worktree
EXPECTED_J7="$J7_CLAUDE/.proof-status-${J7_PHASH}"

R1=$(_resolve_j "$J7_CLAUDE" "$J7_PROJ")
if [[ "$R1" == "$EXPECTED_J7" ]]; then
    pass_test
else
    fail_test "Expected scoped fallback '$EXPECTED_J7' when worktree has no proof, got '$R1'"
fi
rm -rf "$J7_CLAUDE" "$J7_PROJ" "$J7_WT"

run_test "Part J8: needs-verification in worktree with breadcrumb → worktree path (W4-2 regression)"
J8_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-j8-cl-XXXXXX")
J8_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-j8-proj-XXXXXX")
J8_WT=$(mktemp -d "$PROJECT_ROOT/tmp/test-j8-wt-XXXXXX")
mkdir -p "$J8_WT/.claude"
J8_PHASH=$(_phash_j "$J8_PROJ")
echo "$J8_WT" > "$J8_CLAUDE/.active-worktree-path-${J8_PHASH}"
echo "needs-verification|12345" > "$J8_WT/.claude/.proof-status"
# Simulating stale orchestrator-side "verified" from a prior session (the dedup-guard scenario)
echo "verified|00001" > "$J8_CLAUDE/.proof-status-${J8_PHASH}"
EXPECTED_J8="$J8_WT/.claude/.proof-status"

R1=$(_resolve_j "$J8_CLAUDE" "$J8_PROJ")
if [[ "$R1" == "$EXPECTED_J8" ]]; then
    pass_test
else
    fail_test "W4-2 regression: expected worktree path '$EXPECTED_J8', got '$R1'"
fi
rm -rf "$J8_CLAUDE" "$J8_PROJ" "$J8_WT"

# ─────────────────────────────────────────────────────────────────────────────
# Part K: Session-scoped breadcrumb tests (Issue #98)
#
# Verifies that session-scoped breadcrumbs (.active-worktree-path-{SESSION}-{PHASH})
# take priority over project-scoped breadcrumbs (.active-worktree-path-{PHASH}),
# preventing cross-session contamination when multiple sessions run concurrently.
#
#   K1. Session-scoped breadcrumb takes priority over project-scoped
#   K2. Falls back to project-scoped when no session breadcrumb exists
#   K3. Stale session breadcrumb (deleted target dir) falls back to project-scoped
#
# @decision DEC-SESSION-BREADCRUMB-001 — see log.sh for full rationale
# ─────────────────────────────────────────────────────────────────────────────

# Helper: call resolve_proof_file() with explicit CLAUDE_DIR, PROJECT_ROOT, and SESSION
_resolve_k() {
    local claude_dir="$1"
    local project_root="$2"
    local session_id="${3:-}"
    bash -c "
        source '$HOOKS_DIR/log.sh' 2>/dev/null
        export CLAUDE_DIR='$claude_dir'
        export PROJECT_ROOT='$project_root'
        export CLAUDE_SESSION_ID='$session_id'
        resolve_proof_file 2>/dev/null
    "
}

run_test "Part K1: session-scoped breadcrumb takes priority over project-scoped"
K1_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-k1-cl-XXXXXX")
K1_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-k1-proj-XXXXXX")
K1_SESSION_WT=$(mktemp -d "$PROJECT_ROOT/tmp/test-k1-session-wt-XXXXXX")
K1_STALE_WT=$(mktemp -d "$PROJECT_ROOT/tmp/test-k1-stale-wt-XXXXXX")
mkdir -p "$K1_SESSION_WT/.claude"
mkdir -p "$K1_STALE_WT/.claude"
K1_PHASH=$(_phash_j "$K1_PROJ")
K1_SESSION="test-session-k1-$$"
# Session-scoped breadcrumb → K1_SESSION_WT (the correct active worktree)
echo "$K1_SESSION_WT" > "$K1_CLAUDE/.active-worktree-path-${K1_SESSION}-${K1_PHASH}"
# Project-scoped breadcrumb → K1_STALE_WT (a stale/wrong worktree from another session)
echo "$K1_STALE_WT" > "$K1_CLAUDE/.active-worktree-path-${K1_PHASH}"
# Active proof in both worktrees
echo "pending|12345" > "$K1_SESSION_WT/.claude/.proof-status"
echo "pending|99999" > "$K1_STALE_WT/.claude/.proof-status"
EXPECTED_K1="$K1_SESSION_WT/.claude/.proof-status"

R1=$(_resolve_k "$K1_CLAUDE" "$K1_PROJ" "$K1_SESSION")
if [[ "$R1" == "$EXPECTED_K1" ]]; then
    pass_test
else
    fail_test "Session-scoped priority: expected '$EXPECTED_K1', got '$R1' (should NOT resolve to stale '$K1_STALE_WT/.claude/.proof-status')"
fi
rm -rf "$K1_CLAUDE" "$K1_PROJ" "$K1_SESSION_WT" "$K1_STALE_WT"

run_test "Part K2: falls back to project-scoped breadcrumb when no session breadcrumb exists"
K2_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-k2-cl-XXXXXX")
K2_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-k2-proj-XXXXXX")
K2_WT=$(mktemp -d "$PROJECT_ROOT/tmp/test-k2-wt-XXXXXX")
mkdir -p "$K2_WT/.claude"
K2_PHASH=$(_phash_j "$K2_PROJ")
K2_SESSION="test-session-k2-$$"
# Only project-scoped breadcrumb (no session-scoped)
echo "$K2_WT" > "$K2_CLAUDE/.active-worktree-path-${K2_PHASH}"
echo "pending|12345" > "$K2_WT/.claude/.proof-status"
EXPECTED_K2="$K2_WT/.claude/.proof-status"

R1=$(_resolve_k "$K2_CLAUDE" "$K2_PROJ" "$K2_SESSION")
if [[ "$R1" == "$EXPECTED_K2" ]]; then
    pass_test
else
    fail_test "Project-scoped fallback: expected '$EXPECTED_K2', got '$R1'"
fi
rm -rf "$K2_CLAUDE" "$K2_PROJ" "$K2_WT"

run_test "Part K3: stale session breadcrumb (deleted target) falls back to project-scoped"
K3_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-k3-cl-XXXXXX")
K3_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-k3-proj-XXXXXX")
K3_VALID_WT=$(mktemp -d "$PROJECT_ROOT/tmp/test-k3-valid-wt-XXXXXX")
mkdir -p "$K3_VALID_WT/.claude"
K3_PHASH=$(_phash_j "$K3_PROJ")
K3_SESSION="test-session-k3-$$"
# Session-scoped breadcrumb → deleted worktree (stale)
echo "/nonexistent/deleted-worktree-path" > "$K3_CLAUDE/.active-worktree-path-${K3_SESSION}-${K3_PHASH}"
# Project-scoped breadcrumb → valid worktree (should be used as fallback)
echo "$K3_VALID_WT" > "$K3_CLAUDE/.active-worktree-path-${K3_PHASH}"
echo "pending|12345" > "$K3_VALID_WT/.claude/.proof-status"
EXPECTED_K3="$K3_VALID_WT/.claude/.proof-status"

R1=$(_resolve_k "$K3_CLAUDE" "$K3_PROJ" "$K3_SESSION")
if [[ "$R1" == "$EXPECTED_K3" ]]; then
    pass_test
else
    fail_test "Stale session breadcrumb fallback: expected '$EXPECTED_K3', got '$R1'"
fi
rm -rf "$K3_CLAUDE" "$K3_PROJ" "$K3_VALID_WT"

# ─────────────────────────────────────────────────────────────────────────────
# Part L: Lattice regression test (bash 3.2 fix — Issue #97)
#
# Verifies that write_proof_status() correctly blocks verified → pending regression.
# With the declare -A bug, all ordinals resolved to 0, so the regression check
# always passed (0 < 0 = false → allowed). After the fix with _status_ordinal(),
# the regression must be blocked.
# ─────────────────────────────────────────────────────────────────────────────

run_test "Part L1: write_proof_status blocks verified → pending regression (bash 3.2 lattice fix)"
L1_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-l1-cl-XXXXXX")
L1_PROJ="$L1_CLAUDE"  # use same dir so phash is deterministic
L1_PHASH=$(echo "$L1_PROJ" | shasum -a 256 | cut -c1-8 2>/dev/null || echo "00000000")
# get_claude_dir() returns $PROJECT_ROOT/.claude (not $PROJECT_ROOT) when the path
# is not $HOME/.claude. Create the subdirectory and write the proof file there.
mkdir -p "$L1_CLAUDE/.claude"
echo "verified|$(date +%s)" > "$L1_CLAUDE/.claude/.proof-status-${L1_PHASH}"

# Attempt to write "pending" — should be BLOCKED (regression: verified(3) → pending(2))
L1_RESULT=$(bash -c "
    source '$HOOKS_DIR/log.sh' 2>/dev/null
    export CLAUDE_DIR='$L1_CLAUDE'
    export PROJECT_ROOT='$L1_PROJ'
    if write_proof_status 'pending' '$L1_PROJ' 2>/dev/null; then
        echo 'allowed'
    else
        echo 'blocked'
    fi
" 2>/dev/null)

# Read back the file from the correct location — it should still say "verified" (not "pending")
L1_CURRENT=$(cut -d'|' -f1 "$L1_CLAUDE/.claude/.proof-status-${L1_PHASH}" 2>/dev/null || echo "missing")

if [[ "$L1_RESULT" == "blocked" && "$L1_CURRENT" == "verified" ]]; then
    pass_test
elif [[ "$L1_RESULT" == "allowed" && "$L1_CURRENT" == "pending" ]]; then
    fail_test "Lattice regression NOT blocked: write_proof_status allowed verified→pending (declare -A bash 3.2 bug still present)"
else
    fail_test "Unexpected state: write returned '$L1_RESULT', file contains '$L1_CURRENT'"
fi
rm -rf "$L1_CLAUDE"

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
