#!/usr/bin/env bash
# test-orchestrator-governance.sh — Tests for orchestrator governance hardening
#
# Purpose: Verify that residual ~/.claude exemptions are removed and new Guardian
#   gates are enforced for branch deletion and force worktree removal.
#
# Tests:
#   1. branch-guard denies .sh edit on main in ~/.claude
#   2. branch-guard allows .md edit on main in ~/.claude
#   3. branch-guard allows .json edit on main in ~/.claude
#   4. branch-guard denies .sh edit on main in other repos (existing behavior)
#   5. guard.sh Check 2 denies commit on main for ~/.claude
#   6. guard.sh Check 2 allows MASTER_PLAN.md-only commit for ~/.claude
#   7. guard.sh Check 2 allows merge commit (MERGE_HEAD) for ~/.claude
#   8. guard.sh Check 4b denies git branch -d without Guardian
#   9. guard.sh Check 4b allows git branch -d with active Guardian marker
#  10. guard.sh Check 4 still denies git branch -D regardless (existing)
#  11. guard.sh Check 5 denies git worktree remove --force without Guardian
#  12. guard.sh Check 5 allows git worktree remove --force with Guardian marker
#  13. guard.sh Check 5 allows normal git worktree remove (CWD rewrite, no deny)
#
# @decision DEC-GOVERNANCE-TEST-001
# @title Test suite for orchestrator governance hardening
# @status accepted
# @rationale Verifies removal of blanket ~/.claude exemptions from branch-guard.sh
#   and guard.sh Check 2, plus new Guardian-context gates for branch deletion
#   (Check 4b) and force worktree removal (Check 5). Tests use real git repos
#   and real hook executables — no mocks. Guardian marker files are created/removed
#   in TRACE_STORE to simulate active/inactive Guardian context.
#
# Usage: bash tests/test-orchestrator-governance.sh
# Returns: 0 if all tests pass, 1 if any fail
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="${WORKTREE_ROOT}/hooks"
TRACE_STORE="$HOME/.claude/traces"

# Clean up any stale CWD recovery canary to prevent Check 0.5 interference
rm -f "$HOME/.claude/.cwd-recovery-needed" 2>/dev/null || true

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Shared cleanup list for temp directories and temp guardian markers
CLEANUP_DIRS=()
CLEANUP_MARKERS=()

cleanup() {
    rm -rf "${CLEANUP_DIRS[@]:-}" 2>/dev/null || true
    rm -f "${CLEANUP_MARKERS[@]:-}" 2>/dev/null || true
}
trap cleanup EXIT

# Helper: build JSON hook input for branch-guard.sh (Write/Edit tool)
make_branch_guard_input() {
    local file_path="$1"
    printf '{"tool_name":"Write","tool_input":{"file_path":%s}}' \
        "$(printf '%s' "$file_path" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
}

# Helper: build JSON hook input for guard.sh (Bash tool)
make_guard_input() {
    local cmd="$1"
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
}

# Helper: assert output contains a deny decision
assert_deny() {
    local output="$1"
    local label="$2"
    if echo "$output" | grep -q '"permissionDecision": "deny"'; then
        pass "$label"
    else
        fail "$label — expected deny, got: $output"
    fi
}

# Helper: assert output does NOT contain a deny decision
assert_allow() {
    local output="$1"
    local label="$2"
    if echo "$output" | grep -q '"permissionDecision": "deny"'; then
        fail "$label — expected allow, got deny: $output"
    else
        pass "$label"
    fi
}

# Helper: create a git repo on main branch with an initial commit
make_git_repo_on_main() {
    local d
    d=$(mktemp -d)
    CLEANUP_DIRS+=("$d")
    git -C "$d" init -q 2>/dev/null
    git -C "$d" config user.email "test@test.com" 2>/dev/null
    git -C "$d" config user.name "Test" 2>/dev/null
    echo "initial" > "$d/base.txt"
    git -C "$d" add base.txt 2>/dev/null
    git -C "$d" commit -q -m "initial" 2>/dev/null
    git -C "$d" branch -m main 2>/dev/null || true
    echo "$d"
}

# Helper: create a temporary Guardian marker in TRACE_STORE
# Adds to CLEANUP_MARKERS so EXIT trap removes it
make_guardian_marker() {
    local marker="${TRACE_STORE}/.active-guardian-test-$$-$RANDOM"
    touch "$marker"
    CLEANUP_MARKERS+=("$marker")
    echo "$marker"
}

META_REPO="$HOME/.claude"

echo "=== Orchestrator Governance Hardening Tests ==="
echo ""

# ============================================================
# Test 1: branch-guard denies .sh edit on main in ~/.claude
# ============================================================
echo "=== Test 1: branch-guard denies .sh edit on main in ~/.claude ==="

META_BRANCH=$(git -C "$META_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
if [[ "$META_BRANCH" == "main" ]]; then
    INPUT1=$(make_branch_guard_input "${META_REPO}/hooks/some-new-hook.sh")
    OUTPUT1=$(echo "$INPUT1" | bash "$HOOKS_DIR/branch-guard.sh" 2>/dev/null) || true
    assert_deny "$OUTPUT1" "branch-guard denies .sh edit on main in ~/.claude"
else
    pass "Test 1 skipped — ~/.claude not on main (branch: $META_BRANCH)"
fi

# ============================================================
# Test 2: branch-guard allows .md edit on main in ~/.claude
# ============================================================
echo ""
echo "=== Test 2: branch-guard allows .md edit on main in ~/.claude ==="

if [[ "$META_BRANCH" == "main" ]]; then
    INPUT2=$(make_branch_guard_input "${META_REPO}/README.md")
    OUTPUT2=$(echo "$INPUT2" | bash "$HOOKS_DIR/branch-guard.sh" 2>/dev/null) || true
    assert_allow "$OUTPUT2" "branch-guard allows .md edit on main in ~/.claude"
else
    pass "Test 2 skipped — ~/.claude not on main (branch: $META_BRANCH)"
fi

# ============================================================
# Test 3: branch-guard allows .json edit on main in ~/.claude
# ============================================================
echo ""
echo "=== Test 3: branch-guard allows .json edit on main in ~/.claude ==="

if [[ "$META_BRANCH" == "main" ]]; then
    INPUT3=$(make_branch_guard_input "${META_REPO}/settings.json")
    OUTPUT3=$(echo "$INPUT3" | bash "$HOOKS_DIR/branch-guard.sh" 2>/dev/null) || true
    assert_allow "$OUTPUT3" "branch-guard allows .json edit on main in ~/.claude"
else
    pass "Test 3 skipped — ~/.claude not on main (branch: $META_BRANCH)"
fi

# ============================================================
# Test 4: branch-guard denies .sh edit on main in other repos
# ============================================================
echo ""
echo "=== Test 4: branch-guard denies .sh edit on main in other repos ==="

REPO4=$(make_git_repo_on_main)
INPUT4=$(make_branch_guard_input "${REPO4}/scripts/deploy.sh")
OUTPUT4=$(echo "$INPUT4" | bash "$HOOKS_DIR/branch-guard.sh" 2>/dev/null) || true
assert_deny "$OUTPUT4" "branch-guard denies .sh edit on main in other repos"

# ============================================================
# Test 5: guard.sh Check 2 denies commit on main for ~/.claude
# ============================================================
echo ""
echo "=== Test 5: guard.sh Check 2 denies commit on main for ~/.claude ==="

if [[ "$META_BRANCH" == "main" ]]; then
    STAGED_CHECK=$(git -C "$META_REPO" diff --cached --name-only 2>/dev/null || echo "")
    GIT_DIR5=$(git -C "$META_REPO" rev-parse --absolute-git-dir 2>/dev/null || echo "")
    INPUT5=$(make_guard_input "git -C \"${META_REPO}\" commit -m 'test'")
    OUTPUT5=$(echo "$INPUT5" | bash "$HOOKS_DIR/guard.sh" 2>/dev/null) || true
    if [[ "$STAGED_CHECK" == "MASTER_PLAN.md" ]]; then
        pass "Test 5 skipped — only MASTER_PLAN.md staged (allowed by design)"
    elif [[ -n "$GIT_DIR5" && -f "$GIT_DIR5/MERGE_HEAD" ]]; then
        pass "Test 5 skipped — MERGE_HEAD present (allowed by design)"
    else
        assert_deny "$OUTPUT5" "guard.sh Check 2 denies commit on main for ~/.claude"
    fi
else
    pass "Test 5 skipped — ~/.claude not on main (branch: $META_BRANCH)"
fi

# ============================================================
# Test 6: guard.sh Check 2 allows MASTER_PLAN.md-only commit
# ============================================================
echo ""
echo "=== Test 6: guard.sh Check 2 allows MASTER_PLAN.md-only commit ==="

REPO6=$(make_git_repo_on_main)
echo "# Plan" > "${REPO6}/MASTER_PLAN.md"
git -C "$REPO6" add MASTER_PLAN.md 2>/dev/null

INPUT6=$(make_guard_input "git -C \"${REPO6}\" commit -m 'update plan'")
OUTPUT6=$(echo "$INPUT6" | bash "$HOOKS_DIR/guard.sh" 2>/dev/null) || true
assert_allow "$OUTPUT6" "guard.sh Check 2 allows MASTER_PLAN.md-only commit on main"

# ============================================================
# Test 7: guard.sh Check 2 allows merge commit (MERGE_HEAD)
# ============================================================
echo ""
echo "=== Test 7: guard.sh Check 2 allows merge commit (MERGE_HEAD) ==="

REPO7=$(make_git_repo_on_main)
GIT_DIR7=$(git -C "$REPO7" rev-parse --absolute-git-dir 2>/dev/null)
echo "deadbeef" > "${GIT_DIR7}/MERGE_HEAD"

INPUT7=$(make_guard_input "git -C \"${REPO7}\" commit -m 'merge'")
OUTPUT7=$(echo "$INPUT7" | bash "$HOOKS_DIR/guard.sh" 2>/dev/null) || true
assert_allow "$OUTPUT7" "guard.sh Check 2 allows merge commit (MERGE_HEAD present)"

rm -f "${GIT_DIR7}/MERGE_HEAD" 2>/dev/null || true

# ============================================================
# Test 8: guard.sh Check 4b denies git branch -d without Guardian
# ============================================================
echo ""
echo "=== Test 8: guard.sh Check 4b denies git branch -d without Guardian ==="

# Ensure no guardian markers are present for this test
rm -f "${TRACE_STORE}/.active-guardian-"* 2>/dev/null || true
# Clean canary so Check 0.5 Path B doesn't interfere with guard.sh output
rm -f "$HOME/.claude/.cwd-recovery-needed" 2>/dev/null || true

INPUT8=$(make_guard_input "git branch -d feature/old-branch")
OUTPUT8=$(echo "$INPUT8" | bash "$HOOKS_DIR/guard.sh" 2>/dev/null) || true
assert_deny "$OUTPUT8" "guard.sh Check 4b denies git branch -d without Guardian"

# ============================================================
# Test 9: guard.sh Check 4b allows git branch -d with active Guardian marker
# ============================================================
echo ""
echo "=== Test 9: guard.sh Check 4b allows git branch -d with active Guardian ==="

MARKER9=$(make_guardian_marker)

INPUT9=$(make_guard_input "git branch -d feature/old-branch")
OUTPUT9=$(echo "$INPUT9" | bash "$HOOKS_DIR/guard.sh" 2>/dev/null) || true
assert_allow "$OUTPUT9" "guard.sh Check 4b allows git branch -d with active Guardian"

rm -f "$MARKER9" 2>/dev/null || true
CLEANUP_MARKERS=()

# ============================================================
# Test 10: guard.sh Check 4 still denies git branch -D regardless
# ============================================================
echo ""
echo "=== Test 10: guard.sh Check 4 still denies git branch -D regardless ==="

# Even with a Guardian marker active, -D should be hard-denied
MARKER10=$(make_guardian_marker)

INPUT10=$(make_guard_input "git branch -D feature/old-branch")
OUTPUT10=$(echo "$INPUT10" | bash "$HOOKS_DIR/guard.sh" 2>/dev/null) || true
assert_deny "$OUTPUT10" "guard.sh Check 4 denies git branch -D even with Guardian marker"

rm -f "$MARKER10" 2>/dev/null || true
CLEANUP_MARKERS=()

# ============================================================
# Test 11: guard.sh Check 5 denies worktree remove --force without Guardian
# ============================================================
echo ""
echo "=== Test 11: guard.sh Check 5 denies worktree remove --force without Guardian ==="

rm -f "${TRACE_STORE}/.active-guardian-"* 2>/dev/null || true

REPO11=$(make_git_repo_on_main)
INPUT11=$(make_guard_input "git worktree remove --force ${REPO11}/.worktrees/some-wt")
OUTPUT11=$(echo "$INPUT11" | bash "$HOOKS_DIR/guard.sh" 2>/dev/null) || true
assert_deny "$OUTPUT11" "guard.sh Check 5 denies worktree remove --force without Guardian"

# ============================================================
# Test 12: guard.sh Check 5 allows worktree remove --force with Guardian marker
# ============================================================
echo ""
echo "=== Test 12: guard.sh Check 5 allows worktree remove --force with Guardian ==="

MARKER12=$(make_guardian_marker)

REPO12=$(make_git_repo_on_main)
INPUT12=$(make_guard_input "git worktree remove --force ${REPO12}/.worktrees/some-wt")
OUTPUT12=$(echo "$INPUT12" | bash "$HOOKS_DIR/guard.sh" 2>/dev/null) || true
# With Guardian active: no deny from Check 5 — falls through to CWD rewrite
assert_allow "$OUTPUT12" "guard.sh Check 5 allows worktree remove --force with Guardian (proceeds to rewrite)"

rm -f "$MARKER12" 2>/dev/null || true
CLEANUP_MARKERS=()

# ============================================================
# Test 13: guard.sh Check 5 allows normal git worktree remove (CWD rewrite)
# ============================================================
echo ""
echo "=== Test 13: guard.sh Check 5 allows normal worktree remove (rewrite, no deny) ==="

rm -f "${TRACE_STORE}/.active-guardian-"* 2>/dev/null || true

REPO13=$(make_git_repo_on_main)
INPUT13=$(make_guard_input "git worktree remove ${REPO13}/.worktrees/some-wt")
OUTPUT13=$(echo "$INPUT13" | bash "$HOOKS_DIR/guard.sh" 2>/dev/null) || true
assert_allow "$OUTPUT13" "guard.sh Check 5 allows normal worktree remove (no --force)"

# ============================================================
# Summary
# ============================================================
echo ""
echo "=================================================="
echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) tests"
echo "=================================================="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
