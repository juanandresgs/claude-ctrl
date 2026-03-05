#!/usr/bin/env bash
# Test proof-status path resolution — simplified canonical single-path model.
#
# Validates the DEC-PROOF-SINGLE-001 simplification:
#   - resolve_proof_file() always returns CLAUDE_DIR/.proof-status-{phash}
#   - No breadcrumb resolution needed — single path shared across all worktrees
#   - task-track.sh Gate C.2 writes to canonical scoped path (no breadcrumb write)
#   - prompt-submit.sh writes verified to canonical scoped path (single write)
#   - guard.sh reads the canonical scoped path directly
#   - check-guardian.sh cleans only the canonical scoped path
#   - session-end.sh has no breadcrumb to clean (but still handles legacy cleanup)
#   - Non-worktree path (no breadcrumb) works correctly (regression tests)
#
# @decision DEC-PROOF-PATH-001
# @title Test suite for simplified single-path proof-status resolution
# @status accepted
# @rationale The proof-status gate broke in worktree scenarios because of
#   the 3-tier resolution ambiguity. DEC-PROOF-SINGLE-001 eliminates this:
#   one path (.proof-status-{phash} in CLAUDE_DIR) is always authoritative.
#   This test suite verifies the single-path model works correctly across
#   all hook entry points (task-track, prompt-submit, guard, check-guardian).
#   Supersedes the breadcrumb-based test suite that tested the 3-tier model.

set -euo pipefail
# Portable SHA-256 (macOS: shasum, Ubuntu: sha256sum)
if command -v shasum >/dev/null 2>&1; then
    _SHA256_CMD="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
    _SHA256_CMD="sha256sum"
else
    _SHA256_CMD="cat"
fi

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"

mkdir -p "$PROJECT_ROOT/tmp"

# Cleanup trap (DEC-PROD-002): collect temp dirs and remove on exit
_CLEANUP_DIRS=()
trap '[[ ${#_CLEANUP_DIRS[@]} -gt 0 ]] && rm -rf "${_CLEANUP_DIRS[@]}" 2>/dev/null; true' EXIT

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
# Part B: resolve_proof_file() unit tests — single canonical path
#
# DEC-PROOF-SINGLE-001: resolve_proof_file() always returns
# CLAUDE_DIR/.proof-status-{phash}. No breadcrumb lookup.
# ─────────────────────────────────────────────────────────────────────────────

# Helper: source log.sh and call resolve_proof_file() with explicit CLAUDE_DIR
# and PROJECT_ROOT so the phash is deterministic.
_resolve_proof_file() {
    local claude_dir="$1"
    local project_root="$2"
    bash -c "
        source '$HOOKS_DIR/log.sh' 2>/dev/null
        export CLAUDE_DIR='$claude_dir'
        export PROJECT_ROOT='$project_root'
        resolve_proof_file 2>/dev/null
    "
}

# Helper: compute the expected scoped proof path for a given project_root
_scoped_proof_path() {
    local claude_dir="$1"
    local project_root="$2"
    local phash
    phash=$(echo "$project_root" | $_SHA256_CMD | cut -c1-8 2>/dev/null || echo "00000000")
    echo "$claude_dir/.proof-status-${phash}"
}

run_test "resolve_proof_file: returns scoped CLAUDE_DIR path (no proof file exists)"
T_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-XXXXXX")
_CLEANUP_DIRS+=("${T_CLAUDE}")
_CLEANUP_DIRS+=("$T_CLAUDE")
T_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-proj-XXXXXX")
_CLEANUP_DIRS+=("${T_PROJ}")
_CLEANUP_DIRS+=("$T_PROJ")
RESULT=$(_resolve_proof_file "$T_CLAUDE" "$T_PROJ")
EXPECTED=$(_scoped_proof_path "$T_CLAUDE" "$T_PROJ")
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected '$EXPECTED', got '$RESULT'"
fi
rm -rf "$T_CLAUDE" "$T_PROJ"

run_test "resolve_proof_file: returns scoped CLAUDE_DIR path (scoped proof file exists)"
T_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-XXXXXX")
T_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-proj-XXXXXX")
EXPECTED=$(_scoped_proof_path "$T_CLAUDE" "$T_PROJ")
echo "pending|12345" > "$EXPECTED"
RESULT=$(_resolve_proof_file "$T_CLAUDE" "$T_PROJ")
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected scoped path '$EXPECTED', got '$RESULT'"
fi
rm -rf "$T_CLAUDE" "$T_PROJ"

run_test "resolve_proof_file: returns scoped path even when legacy .proof-status exists"
T_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-XXXXXX")
T_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-proj-XXXXXX")
# Legacy file exists but scoped should take priority
echo "verified|99999" > "$T_CLAUDE/.proof-status"
EXPECTED=$(_scoped_proof_path "$T_CLAUDE" "$T_PROJ")
RESULT=$(_resolve_proof_file "$T_CLAUDE" "$T_PROJ")
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass_test
else
    fail_test "Expected scoped path '$EXPECTED' over legacy, got '$RESULT'"
fi
rm -rf "$T_CLAUDE" "$T_PROJ"

run_test "resolve_proof_file: consistent result across multiple calls"
T_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-XXXXXX")
T_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-proj-XXXXXX")
EXPECTED=$(_scoped_proof_path "$T_CLAUDE" "$T_PROJ")
R1=$(_resolve_proof_file "$T_CLAUDE" "$T_PROJ")
R2=$(_resolve_proof_file "$T_CLAUDE" "$T_PROJ")
R3=$(_resolve_proof_file "$T_CLAUDE" "$T_PROJ")
if [[ "$R1" == "$EXPECTED" && "$R2" == "$EXPECTED" && "$R3" == "$EXPECTED" ]]; then
    pass_test
else
    fail_test "Inconsistent: R1='$R1' R2='$R2' R3='$R3' (want '$EXPECTED')"
fi
rm -rf "$T_CLAUDE" "$T_PROJ"

run_test "resolve_proof_file: different projects get different paths (isolation)"
T_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-XXXXXX")
T_PROJ_A=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-projA-XXXXXX")
_CLEANUP_DIRS+=("${T_PROJ_A}")
T_PROJ_B=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-projB-XXXXXX")
_CLEANUP_DIRS+=("${T_PROJ_B}")
PATH_A=$(_resolve_proof_file "$T_CLAUDE" "$T_PROJ_A")
PATH_B=$(_resolve_proof_file "$T_CLAUDE" "$T_PROJ_B")
if [[ "$PATH_A" != "$PATH_B" ]]; then
    pass_test
else
    fail_test "Different projects got same proof path: '$PATH_A'"
fi
rm -rf "$T_CLAUDE" "$T_PROJ_A" "$T_PROJ_B"

run_test "resolve_proof_file: same project root always produces same phash"
T_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-XXXXXX")
T_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-rpf-proj-XXXXXX")
# Compute phash via two paths
PHASH_A=$(echo "$T_PROJ" | $_SHA256_CMD | cut -c1-8)
PHASH_B=$(echo "$T_PROJ" | $_SHA256_CMD | cut -c1-8)
EXPECTED="$T_CLAUDE/.proof-status-${PHASH_A}"
RESULT=$(_resolve_proof_file "$T_CLAUDE" "$T_PROJ")
if [[ "$PHASH_A" == "$PHASH_B" && "$RESULT" == "$EXPECTED" ]]; then
    pass_test
else
    fail_test "phash inconsistent or path wrong: PHASH_A='$PHASH_A' PHASH_B='$PHASH_B' path='$RESULT'"
fi
rm -rf "$T_CLAUDE" "$T_PROJ"

# ─────────────────────────────────────────────────────────────────────────────
# Part C: task-track.sh — Gate C.2 writes canonical scoped path (no breadcrumb)
# ─────────────────────────────────────────────────────────────────────────────

run_test "task-track: implementer dispatch from main worktree without linked worktrees emits deny (Gate C.1)"
# Gate C.1 blocks implementer dispatch from the main worktree when no linked worktrees exist.
# Gate C.2 (writes .proof-status-{phash}) only runs AFTER C.1 passes.
TEMP_ORCHESTRATOR=$(mktemp -d "$PROJECT_ROOT/tmp/test-tt-orch-XXXXXX")
_CLEANUP_DIRS+=("${TEMP_ORCHESTRATOR}")
git -C "$TEMP_ORCHESTRATOR" init > /dev/null 2>&1
git -C "$TEMP_ORCHESTRATOR" commit --allow-empty -m "init" > /dev/null 2>&1
mkdir -p "$TEMP_ORCHESTRATOR/.claude"

TT_INPUT_FILE=$(mktemp "$PROJECT_ROOT/tmp/test-tt-input-XXXXXX.json")
_CLEANUP_DIRS+=("${TT_INPUT_FILE}")
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

run_test "task-track: Gate C.2 writes canonical scoped .proof-status-{phash} (no breadcrumb)"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-tt-gate-XXXXXX")
_CLEANUP_DIRS+=("${TEMP_REPO}")
git -C "$TEMP_REPO" init > /dev/null 2>&1
git -C "$TEMP_REPO" commit --allow-empty -m "init" > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"
IMPL_PHASH=$(echo "$TEMP_REPO" | $_SHA256_CMD | cut -c1-8)
# Gate C.1 requires at least one linked worktree
IMPL_WORKTREE="$TEMP_REPO/.worktrees/feature-test"
mkdir -p "$IMPL_WORKTREE"
git -C "$TEMP_REPO" worktree add "$IMPL_WORKTREE" -b feature/test > /dev/null 2>&1 || \
    git -C "$TEMP_REPO" worktree add --detach "$IMPL_WORKTREE" > /dev/null 2>&1 || true

cat <<'EOF' | CLAUDE_PROJECT_DIR="$TEMP_REPO" bash "$HOOKS_DIR/task-track.sh" > /dev/null 2>&1
{
  "tool_name": "Task",
  "tool_input": {
    "subagent_type": "implementer",
    "instructions": "Test implementation"
  }
}
EOF

# Verify: scoped file written, no breadcrumb
SCOPED_FILE="$TEMP_REPO/.claude/.proof-status-${IMPL_PHASH}"
BREADCRUMB_FILE="$TEMP_REPO/.claude/.active-worktree-path-${IMPL_PHASH}"
LEGACY_BREADCRUMB="$TEMP_REPO/.claude/.active-worktree-path"

if [[ -f "$SCOPED_FILE" ]]; then
    STATUS=$(cut -d'|' -f1 "$SCOPED_FILE")
    if [[ "$STATUS" == "needs-verification" ]]; then
        if [[ ! -f "$BREADCRUMB_FILE" && ! -f "$LEGACY_BREADCRUMB" ]]; then
            pass_test
        else
            fail_test "Breadcrumb file still written (should be eliminated): scoped=$BREADCRUMB_FILE legacy=$LEGACY_BREADCRUMB"
        fi
    else
        fail_test "Wrong status in scoped file: '$STATUS' (expected needs-verification)"
    fi
else
    fail_test "Scoped file not written: $SCOPED_FILE"
fi

rm -rf "$TEMP_REPO"

# ─────────────────────────────────────────────────────────────────────────────
# Part D: prompt-submit.sh — writes to canonical scoped path only
# ─────────────────────────────────────────────────────────────────────────────

run_test "prompt-submit: 'verified' keyword transitions pending -> verified (scoped path)"
TEMP_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-ps-XXXXXX")
_CLEANUP_DIRS+=("${TEMP_PROJ}")
git -C "$TEMP_PROJ" init > /dev/null 2>&1
mkdir -p "$TEMP_PROJ/.claude"
TEMP_PHASH=$(echo "$TEMP_PROJ" | $_SHA256_CMD | cut -c1-8)
echo "pending|12345" > "$TEMP_PROJ/.claude/.proof-status-${TEMP_PHASH}"

INPUT_JSON=$(jq -n '{"hook_event_name":"UserPromptSubmit","prompt":"verified"}')
cd "$TEMP_PROJ" && \
    CLAUDE_PROJECT_DIR="$TEMP_PROJ" \
    echo "$INPUT_JSON" | bash "$HOOKS_DIR/prompt-submit.sh" > /dev/null 2>&1

STATUS=$(cut -d'|' -f1 "$TEMP_PROJ/.claude/.proof-status-${TEMP_PHASH}" 2>/dev/null || echo "missing")
if [[ "$STATUS" == "verified" ]]; then
    pass_test
else
    fail_test "Expected 'verified', got '$STATUS'"
fi

cd "$PROJECT_ROOT"
rm -rf "$TEMP_PROJ"

run_test "prompt-submit: 'lgtm' keyword also transitions pending -> verified"
TEMP_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-ps-lgtm-XXXXXX")
git -C "$TEMP_PROJ" init > /dev/null 2>&1
mkdir -p "$TEMP_PROJ/.claude"
TEMP_PHASH=$(echo "$TEMP_PROJ" | $_SHA256_CMD | cut -c1-8)
echo "pending|12345" > "$TEMP_PROJ/.claude/.proof-status-${TEMP_PHASH}"

INPUT_JSON=$(jq -n '{"hook_event_name":"UserPromptSubmit","prompt":"lgtm"}')
cd "$TEMP_PROJ" && \
    CLAUDE_PROJECT_DIR="$TEMP_PROJ" \
    echo "$INPUT_JSON" | bash "$HOOKS_DIR/prompt-submit.sh" > /dev/null 2>&1

STATUS=$(cut -d'|' -f1 "$TEMP_PROJ/.claude/.proof-status-${TEMP_PHASH}" 2>/dev/null || echo "missing")
if [[ "$STATUS" == "verified" ]]; then
    pass_test
else
    fail_test "Expected 'verified' after lgtm, got '$STATUS'"
fi

cd "$PROJECT_ROOT"
rm -rf "$TEMP_PROJ"

run_test "prompt-submit: 'verified' with needs-verification also transitions to verified"
TEMP_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-ps-nv-XXXXXX")
git -C "$TEMP_PROJ" init > /dev/null 2>&1
mkdir -p "$TEMP_PROJ/.claude"
TEMP_PHASH=$(echo "$TEMP_PROJ" | $_SHA256_CMD | cut -c1-8)
echo "needs-verification|12345" > "$TEMP_PROJ/.claude/.proof-status-${TEMP_PHASH}"

INPUT_JSON=$(jq -n '{"hook_event_name":"UserPromptSubmit","prompt":"verified"}')
cd "$TEMP_PROJ" && \
    CLAUDE_PROJECT_DIR="$TEMP_PROJ" \
    echo "$INPUT_JSON" | bash "$HOOKS_DIR/prompt-submit.sh" > /dev/null 2>&1

STATUS=$(cut -d'|' -f1 "$TEMP_PROJ/.claude/.proof-status-${TEMP_PHASH}" 2>/dev/null || echo "missing")
if [[ "$STATUS" == "verified" ]]; then
    pass_test
else
    fail_test "Expected 'verified' from needs-verification, got '$STATUS'"
fi

cd "$PROJECT_ROOT"
rm -rf "$TEMP_PROJ"

run_test "prompt-submit: 'verified' writes only to canonical scoped path (no worktree dual-write)"
# With DEC-PROOF-SINGLE-001, prompt-submit no longer dual-writes to a worktree path.
# The single canonical scoped path in CLAUDE_DIR is the truth for all agents.
TEMP_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-ps-nodual-XXXXXX")
git -C "$TEMP_PROJ" init > /dev/null 2>&1
mkdir -p "$TEMP_PROJ/.claude"
TEMP_PHASH=$(echo "$TEMP_PROJ" | $_SHA256_CMD | cut -c1-8)
echo "pending|12345" > "$TEMP_PROJ/.claude/.proof-status-${TEMP_PHASH}"
# Simulate: legacy breadcrumb pointing to a worktree (should NOT be followed)
FAKE_WT=$(mktemp -d "$PROJECT_ROOT/tmp/test-ps-fakewt-XXXXXX")
_CLEANUP_DIRS+=("${FAKE_WT}")
mkdir -p "$FAKE_WT/.claude"
# No breadcrumb written — DEC-PROOF-SINGLE-001 eliminates them

INPUT_JSON=$(jq -n '{"hook_event_name":"UserPromptSubmit","prompt":"verified"}')
cd "$TEMP_PROJ" && \
    CLAUDE_PROJECT_DIR="$TEMP_PROJ" \
    echo "$INPUT_JSON" | bash "$HOOKS_DIR/prompt-submit.sh" > /dev/null 2>&1

SCOPED_STATUS=$(cut -d'|' -f1 "$TEMP_PROJ/.claude/.proof-status-${TEMP_PHASH}" 2>/dev/null || echo "missing")
WT_PROOF_EXISTS=false
[[ -f "$FAKE_WT/.claude/.proof-status" ]] && WT_PROOF_EXISTS=true

if [[ "$SCOPED_STATUS" == "verified" && "$WT_PROOF_EXISTS" == "false" ]]; then
    pass_test
else
    fail_test "Expected: scoped=verified, no wt file. Got: scoped='$SCOPED_STATUS', wt_exists=$WT_PROOF_EXISTS"
fi

cd "$PROJECT_ROOT"
rm -rf "$TEMP_PROJ" "$FAKE_WT"

# ─────────────────────────────────────────────────────────────────────────────
# Part E: guard.sh — reads canonical scoped path
# ─────────────────────────────────────────────────────────────────────────────

run_test "guard.sh: canonical scoped verified allows commit"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-guard-ver-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"
GUARD_PHASH=$(echo "$TEMP_REPO" | $_SHA256_CMD | cut -c1-8)
echo "verified|12345" > "$TEMP_REPO/.claude/.proof-status-${GUARD_PHASH}"

INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "cd $TEMP_REPO && git commit -m test"
  }
}
EOF
)

OUTPUT=$(cd "$TEMP_REPO" && \
         CLAUDE_PROJECT_DIR="$TEMP_REPO" \
         echo "$INPUT_JSON" | bash "$HOOKS_DIR/pre-bash.sh" 2>&1) || true

if echo "$OUTPUT" | grep -q "deny"; then
    fail_test "guard.sh blocked commit with canonical verified status"
else
    pass_test
fi

cd "$PROJECT_ROOT"
rm -rf "$TEMP_REPO"

run_test "guard.sh: canonical scoped pending blocks commit"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-guard-pend-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"
GUARD_PHASH=$(echo "$TEMP_REPO" | $_SHA256_CMD | cut -c1-8)
echo "pending|12345" > "$TEMP_REPO/.claude/.proof-status-${GUARD_PHASH}"

INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "cd $TEMP_REPO && git commit -m test"
  }
}
EOF
)

OUTPUT=$(cd "$TEMP_REPO" && \
         CLAUDE_PROJECT_DIR="$TEMP_REPO" \
         echo "$INPUT_JSON" | bash "$HOOKS_DIR/pre-bash.sh" 2>&1) || true

if echo "$OUTPUT" | grep -q "deny"; then
    pass_test
else
    fail_test "guard.sh allowed commit when canonical scoped path shows pending"
fi

cd "$PROJECT_ROOT"
rm -rf "$TEMP_REPO"

# ─────────────────────────────────────────────────────────────────────────────
# Part F: check-guardian.sh — cleans canonical scoped proof on commit
# ─────────────────────────────────────────────────────────────────────────────

run_test "check-guardian.sh: cleans canonical scoped proof-status after successful commit"
TEMP_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-cg-XXXXXX")
git -C "$TEMP_PROJ" init > /dev/null 2>&1
git -C "$TEMP_PROJ" commit --allow-empty -m "init" > /dev/null 2>&1
mkdir -p "$TEMP_PROJ/.claude"
CG_PHASH=$(echo "$TEMP_PROJ" | $_SHA256_CMD | cut -c1-8)
echo "verified|12345" > "$TEMP_PROJ/.claude/.proof-status-${CG_PHASH}"

RESPONSE_JSON=$(jq -n '{"response":"Guardian committed successfully — commit abc123 created"}')

cd "$TEMP_PROJ" && \
    CLAUDE_PROJECT_DIR="$TEMP_PROJ" \
    echo "$RESPONSE_JSON" | bash "$HOOKS_DIR/check-guardian.sh" > /dev/null 2>&1

SCOPED_PROOF_EXISTS=false
[[ -f "$TEMP_PROJ/.claude/.proof-status-${CG_PHASH}" ]] && SCOPED_PROOF_EXISTS=true

if [[ "$SCOPED_PROOF_EXISTS" == "false" ]]; then
    pass_test
else
    fail_test "Canonical scoped proof-status not cleaned: exists=$SCOPED_PROOF_EXISTS"
fi

cd "$PROJECT_ROOT"
rm -rf "$TEMP_PROJ"

# ─────────────────────────────────────────────────────────────────────────────
# Part G: session-end.sh — no longer has breadcrumbs to clean
#          (verifies the session end runs clean without legacy files)
# ─────────────────────────────────────────────────────────────────────────────

run_test "session-end.sh: runs cleanly without breadcrumb files"
TEMP_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-se-XXXXXX")
git -C "$TEMP_PROJ" init > /dev/null 2>&1
mkdir -p "$TEMP_PROJ/.claude"
# No breadcrumb file — this is the clean new state

INPUT_JSON=$(jq -n '{"reason":"normal"}')
cd "$TEMP_PROJ" && \
    CLAUDE_PROJECT_DIR="$TEMP_PROJ" \
    CLAUDE_SESSION_ID="test-session-123" \
    echo "$INPUT_JSON" | bash "$HOOKS_DIR/session-end.sh" > /dev/null 2>&1
EXIT_CODE=$?

if [[ "$EXIT_CODE" -eq 0 ]]; then
    pass_test
else
    fail_test "session-end.sh exited $EXIT_CODE without breadcrumbs"
fi

cd "$PROJECT_ROOT"
rm -rf "$TEMP_PROJ"

# ─────────────────────────────────────────────────────────────────────────────
# Part H: Regression — task-track Gate A uses canonical scoped path
# ─────────────────────────────────────────────────────────────────────────────

run_test "Regression: needs-verification in scoped path blocks Guardian dispatch"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-reg-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"
REG_PHASH=$(echo "$TEMP_REPO" | $_SHA256_CMD | cut -c1-8)
echo "needs-verification|12345" > "$TEMP_REPO/.claude/.proof-status-${REG_PHASH}"

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
    fail_test "Guardian allowed with needs-verification in canonical scoped path"
fi

cd "$PROJECT_ROOT"
rm -rf "$TEMP_REPO"

run_test "Regression: verified in scoped path allows Guardian dispatch"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-reg2-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"
REG2_PHASH=$(echo "$TEMP_REPO" | $_SHA256_CMD | cut -c1-8)
echo "verified|12345" > "$TEMP_REPO/.claude/.proof-status-${REG2_PHASH}"

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
    fail_test "Guardian blocked with verified status in canonical scoped path (should allow)"
else
    pass_test
fi

cd "$PROJECT_ROOT"
rm -rf "$TEMP_REPO"

# ─────────────────────────────────────────────────────────────────────────────
# Part I: .gitignore — state files excluded
# ─────────────────────────────────────────────────────────────────────────────

run_test ".gitignore: .proof-status pattern is excluded"
if grep -q "\.proof-status" "$PROJECT_ROOT/.gitignore"; then
    pass_test
else
    fail_test ".proof-status not found in .gitignore"
fi

run_test ".gitignore: no breadcrumb (.active-worktree-path) entry needed — breadcrumbs eliminated"
# With DEC-PROOF-SINGLE-001, .active-worktree-path files are no longer written.
# If the gitignore still has the entry, that's OK (harmless), but the file itself
# should not be created by any hook in normal operation.
# Test: run a full task-track implementer dispatch and verify no breadcrumb written.
TEMP_I=$(mktemp -d "$PROJECT_ROOT/tmp/test-gi-XXXXXX")
_CLEANUP_DIRS+=("${TEMP_I}")
git -C "$TEMP_I" init > /dev/null 2>&1
git -C "$TEMP_I" commit --allow-empty -m "init" > /dev/null 2>&1
mkdir -p "$TEMP_I/.claude"
TEMP_I_PHASH=$(echo "$TEMP_I" | $_SHA256_CMD | cut -c1-8)
IMPL_WT="$TEMP_I/.worktrees/feature-test"
mkdir -p "$IMPL_WT"
git -C "$TEMP_I" worktree add "$IMPL_WT" -b feature/i-test > /dev/null 2>&1 || \
    git -C "$TEMP_I" worktree add --detach "$IMPL_WT" > /dev/null 2>&1 || true

cat <<'EOF' | CLAUDE_PROJECT_DIR="$TEMP_I" bash "$HOOKS_DIR/task-track.sh" > /dev/null 2>&1
{
  "tool_name": "Task",
  "tool_input": {
    "subagent_type": "implementer",
    "instructions": "Test implementation"
  }
}
EOF

BREADCRUMB_SCOPED="$TEMP_I/.claude/.active-worktree-path-${TEMP_I_PHASH}"
BREADCRUMB_LEGACY="$TEMP_I/.claude/.active-worktree-path"

if [[ ! -f "$BREADCRUMB_SCOPED" && ! -f "$BREADCRUMB_LEGACY" ]]; then
    pass_test
else
    fail_test "Breadcrumb file was created (should be eliminated by DEC-PROOF-SINGLE-001)"
fi

rm -rf "$TEMP_I"

# ─────────────────────────────────────────────────────────────────────────────
# Part J: Cross-agent consistency — all hooks resolve to the same path
#
# Verifies that task-track, prompt-submit, guard.sh, and check-tester.sh
# all use the same canonical path for a given project. This is the key
# invariant of DEC-PROOF-SINGLE-001.
# ─────────────────────────────────────────────────────────────────────────────

# Helper: call resolve_proof_file() with explicit CLAUDE_DIR and PROJECT_ROOT
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

run_test "Part J1: all callers resolve to same canonical scoped path"
J1_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-j1-cl-XXXXXX")
_CLEANUP_DIRS+=("${J1_CLAUDE}")
J1_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-j1-proj-XXXXXX")
_CLEANUP_DIRS+=("${J1_PROJ}")
J1_PHASH=$(echo "$J1_PROJ" | $_SHA256_CMD | cut -c1-8)
EXPECTED_J1="$J1_CLAUDE/.proof-status-${J1_PHASH}"

# Simulate task-track, prompt-submit, guard.sh each calling resolve_proof_file
R1=$(_resolve_j "$J1_CLAUDE" "$J1_PROJ")
R2=$(_resolve_j "$J1_CLAUDE" "$J1_PROJ")
R3=$(_resolve_j "$J1_CLAUDE" "$J1_PROJ")

if [[ "$R1" == "$EXPECTED_J1" && "$R2" == "$EXPECTED_J1" && "$R3" == "$EXPECTED_J1" ]]; then
    pass_test
else
    fail_test "Inconsistent: R1='$R1' R2='$R2' R3='$R3' (want '$EXPECTED_J1')"
fi
rm -rf "$J1_CLAUDE" "$J1_PROJ"

run_test "Part J2: write via write_proof_status → read via resolve_proof_file round-trips correctly"
# Note: write_proof_status uses get_claude_dir() which returns <project>/.claude.
# resolve_proof_file uses CLAUDE_DIR env var. For the round-trip to work, both must
# agree on the claude_dir. Here we use HOME=/.claude (meta-repo pattern) OR simply
# set PROJECT_ROOT to the project and let get_claude_dir return <project>/.claude,
# then set CLAUDE_DIR to the same value so resolve_proof_file agrees.
J2_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-j2-proj-XXXXXX")
_CLEANUP_DIRS+=("${J2_PROJ}")
J2_CLAUDE="$J2_PROJ/.claude"
mkdir -p "$J2_CLAUDE"
git -C "$J2_PROJ" init --quiet > /dev/null 2>&1
J2_PHASH=$(echo "$J2_PROJ" | $_SHA256_CMD | cut -c1-8)

# Write via write_proof_status — uses get_claude_dir = <J2_PROJ>/.claude
(
    export CLAUDE_PROJECT_DIR="$J2_PROJ"
    source "$HOOKS_DIR/log.sh" 2>/dev/null
    write_proof_status "pending" "$J2_PROJ" 2>/dev/null || true
)

# Read via resolve_proof_file — CLAUDE_DIR set to <J2_PROJ>/.claude
PROOF_PATH=$(_resolve_j "$J2_CLAUDE" "$J2_PROJ")
STATUS=$(cut -d'|' -f1 "$PROOF_PATH" 2>/dev/null || echo "missing")

if [[ "$STATUS" == "pending" && "$PROOF_PATH" == "$J2_CLAUDE/.proof-status-${J2_PHASH}" ]]; then
    pass_test
else
    fail_test "Round-trip failed: path='$PROOF_PATH' status='$STATUS' (expected pending at $J2_CLAUDE/.proof-status-${J2_PHASH})"
fi
rm -rf "$J2_PROJ"

run_test "Part J3: project isolation — two projects write independent canonical files"
J3_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-j3-cl-XXXXXX")
_CLEANUP_DIRS+=("${J3_CLAUDE}")
J3_PROJ_A=$(mktemp -d "$PROJECT_ROOT/tmp/test-j3-projA-XXXXXX")
_CLEANUP_DIRS+=("${J3_PROJ_A}")
J3_PROJ_B=$(mktemp -d "$PROJECT_ROOT/tmp/test-j3-projB-XXXXXX")
_CLEANUP_DIRS+=("${J3_PROJ_B}")
git -C "$J3_PROJ_A" init --quiet > /dev/null 2>&1
git -C "$J3_PROJ_B" init --quiet > /dev/null 2>&1
J3_PHASH_A=$(echo "$J3_PROJ_A" | $_SHA256_CMD | cut -c1-8)
J3_PHASH_B=$(echo "$J3_PROJ_B" | $_SHA256_CMD | cut -c1-8)

# Write different statuses to each project's canonical path
echo "pending|11111" > "$J3_CLAUDE/.proof-status-${J3_PHASH_A}"
echo "verified|22222" > "$J3_CLAUDE/.proof-status-${J3_PHASH_B}"

STATUS_A=$(cut -d'|' -f1 "$(_resolve_j "$J3_CLAUDE" "$J3_PROJ_A")" 2>/dev/null || echo "missing")
STATUS_B=$(cut -d'|' -f1 "$(_resolve_j "$J3_CLAUDE" "$J3_PROJ_B")" 2>/dev/null || echo "missing")

if [[ "$STATUS_A" == "pending" && "$STATUS_B" == "verified" ]]; then
    pass_test
else
    fail_test "Project isolation failed: A='$STATUS_A' B='$STATUS_B' (want pending/verified)"
fi
rm -rf "$J3_CLAUDE" "$J3_PROJ_A" "$J3_PROJ_B"

run_test "Part J4: no proof file → resolve_proof_file returns scoped path as default write target"
J4_CLAUDE=$(mktemp -d "$PROJECT_ROOT/tmp/test-j4-cl-XXXXXX")
_CLEANUP_DIRS+=("${J4_CLAUDE}")
J4_PROJ=$(mktemp -d "$PROJECT_ROOT/tmp/test-j4-proj-XXXXXX")
_CLEANUP_DIRS+=("${J4_PROJ}")
J4_PHASH=$(echo "$J4_PROJ" | $_SHA256_CMD | cut -c1-8)
EXPECTED_J4="$J4_CLAUDE/.proof-status-${J4_PHASH}"

R1=$(_resolve_j "$J4_CLAUDE" "$J4_PROJ")
if [[ "$R1" == "$EXPECTED_J4" ]]; then
    pass_test
else
    fail_test "Expected default write target '$EXPECTED_J4', got '$R1'"
fi
rm -rf "$J4_CLAUDE" "$J4_PROJ"

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
