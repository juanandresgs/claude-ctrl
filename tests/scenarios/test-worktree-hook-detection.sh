#!/usr/bin/env bash
# test-worktree-hook-detection.sh — TKT-017 scenario tests
#
# Tests three bugs fixed in TKT-017:
#   #465 — plan-check.sh silently exits in worktrees (.git is a file, not dir)
#   #466 — deny JSON missing blockingHook field (no hook identification)
#   #468 — write-time policy resolves repo identity from CWD not file path
#
# Production sequence exercised:
#   1. A real git worktree is created (not a temp dir — actual git worktree)
#   2. An implementer agent writes a source file in the worktree
#   3. pre-write.sh fires, which delegates to plan-check.sh via write-policy.sh
#   4. plan-check.sh must NOT silently exit due to .git-is-a-file detection
#   5. The deny JSON must include blockingHook so agents can diagnose failures
#   6. Repo identity must resolve from the file path, not session CWD
#
# @decision DEC-HOOK-005
# @title TKT-017 worktree hook detection scenario tests
# @status accepted
# @rationale These tests exercise the real production sequence: a worktree write
#   flows through pre-write.sh -> write-policy.sh -> plan-check.sh. Mocking any
#   of these layers would hide the exact failure (#465) we are testing. Real git
#   worktree creation is mandatory because the bug only manifests when .git is a
#   file (gitdir pointer), which only happens in actual git worktrees.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# IMPORTANT: TMP_BASE must NOT be placed under a path containing ".claude/"
# because plan-check.sh skips files in .claude/ meta-infrastructure.
# This worktree lives at .claude/worktrees/feature-tkt-017, so we must anchor
# the temp repos at the project root above .claude/ to get clean paths.
PROJECT_ROOT="$(cd "$REPO_ROOT/../../.." && pwd)"
TMP_BASE="$PROJECT_ROOT/tmp/test-worktree-hook-$$"
PASS=0
FAIL=0

# Colors for output (only when terminal supports it)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'; RED='\033[0;31m'; RESET='\033[0m'
else
    GREEN=''; RED=''; RESET=''
fi

pass() { echo -e "${GREEN}PASS${RESET}: $1"; (( PASS++ )) || true; }
fail() { echo -e "${RED}FAIL${RESET}: $1"; (( FAIL++ )) || true; shift; [[ $# -gt 0 ]] && echo "  $*"; }

cleanup() { rm -rf "$TMP_BASE"; }
trap cleanup EXIT

# --- Setup: real git repo + worktree ---
# This must be a real git worktree, not just a directory, because the bug
# only manifests when .git is a file (gitdir pointer) not a directory.
setup_repo_with_worktree() {
    # Use unique suffix per call to avoid branch name collisions across parallel tests
    local suffix="${1:-default}"
    local main_repo="$TMP_BASE/main-repo-${suffix}"
    local worktree_path="$TMP_BASE/feature-worktree-${suffix}"

    mkdir -p "$main_repo/src" "$main_repo/.claude"

    git -C "$main_repo" init -q
    git -C "$main_repo" config user.email "test@example.com"
    git -C "$main_repo" config user.name "Test"
    git -C "$main_repo" commit --allow-empty -m "init" -q

    # Create a real git worktree — .git becomes a FILE in the worktree
    git -C "$main_repo" worktree add "$worktree_path" -b "feature/test-017-${suffix}" -q

    # Verify the worktree has .git as a FILE (the condition that triggers bug #465)
    if [[ -d "$worktree_path/.git" ]]; then
        echo "  SETUP ERROR: expected .git to be a file in worktree, got directory" >&2
        return 1
    fi
    if [[ ! -f "$worktree_path/.git" ]]; then
        echo "  SETUP ERROR: .git not found in worktree at all" >&2
        return 1
    fi

    echo "$worktree_path"
}

# ============================================================
# TEST 1: #465 — plan-check.sh must NOT silently exit in a real worktree
# ============================================================
# Before the fix, plan-check.sh line 67 did:
#   [[ ! -d "$PROJECT_ROOT/.git" ]] && exit 0
# In a worktree, .git is a FILE so -d returns false, causing silent exit.
# After the fix, plan-check.sh uses git rev-parse to test git membership.
test_plan_check_worktree_detection() {
    local TEST_NAME="plan-check-worktree-detection"
    local worktree_path
    worktree_path=$(setup_repo_with_worktree "t1") || {
        fail "$TEST_NAME" "setup_repo_with_worktree failed"; return
    }

    # Verify .git is a file (the precondition for bug #465)
    if [[ ! -f "$worktree_path/.git" ]]; then
        fail "$TEST_NAME" ".git is not a file — worktree not set up correctly"
        return
    fi

    # Write an implementer marker so write-guard doesn't deny first
    mkdir -p "$worktree_path/.claude"
    echo "ACTIVE|implementer|$(date +%s)" > "$worktree_path/.claude/.subagent-tracker"
    # No MASTER_PLAN.md — this is the condition plan-check.sh should catch

    local target_file="$worktree_path/src/app.ts"
    mkdir -p "$worktree_path/src"

    # 25-line content to bypass the small-file fast-path in plan-check.sh
    local content
    content=$(printf 'export const line%d = %d;\n' $(seq 1 25 | awk '{print $1,$1}'))

    local payload
    payload=$(jq -n \
        --arg tool_name "Write" \
        --arg file_path "$target_file" \
        --arg content "$content" \
        '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

    local output
    output=$(printf '%s' "$payload" | \
        CLAUDE_PROJECT_DIR="$worktree_path" \
        "$REPO_ROOT/hooks/plan-check.sh" 2>/dev/null) || true

    # If plan-check.sh silently exited (bug #465), output would be empty.
    # After the fix it should detect no MASTER_PLAN.md and either deny or emit context.
    if [[ -z "$output" ]]; then
        fail "$TEST_NAME" "plan-check.sh produced no output in worktree — silent exit bug #465 still present"
        return
    fi

    local decision
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    if [[ "$decision" != "deny" ]]; then
        fail "$TEST_NAME" "expected deny (no MASTER_PLAN.md), got: '$decision' | output: $output"
        return
    fi

    pass "$TEST_NAME"
}

# ============================================================
# TEST 2: #466 — deny JSON must include blockingHook field
# ============================================================
# pre-write.sh runs checks in a loop and passes deny through.
# After the fix, the pass-through annotates the deny with blockingHook.
test_deny_includes_blocking_hook() {
    local TEST_NAME="deny-includes-blocking-hook"
    local worktree_path
    worktree_path=$(setup_repo_with_worktree "t2") || {
        fail "$TEST_NAME" "setup_repo_with_worktree failed"; return
    }

    mkdir -p "$worktree_path/.claude" "$worktree_path/src"
    echo "ACTIVE|implementer|$(date +%s)" > "$worktree_path/.claude/.subagent-tracker"
    # No MASTER_PLAN.md — triggers plan-check deny

    local target_file="$worktree_path/src/app.ts"
    local content
    content=$(printf 'export const line%d = %d;\n' $(seq 1 25 | awk '{print $1,$1}'))

    local payload
    payload=$(jq -n \
        --arg tool_name "Write" \
        --arg file_path "$target_file" \
        --arg content "$content" \
        '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

    local output
    output=$(printf '%s' "$payload" | \
        CLAUDE_PROJECT_DIR="$worktree_path" \
        "$REPO_ROOT/hooks/pre-write.sh" 2>/dev/null) || true

    if [[ -z "$output" ]]; then
        fail "$TEST_NAME" "pre-write.sh produced no output — expected deny"
        return
    fi

    local decision
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    if [[ "$decision" != "deny" ]]; then
        fail "$TEST_NAME" "expected deny, got: '$decision'"
        return
    fi

    local blocking_hook
    blocking_hook=$(echo "$output" | jq -r '.hookSpecificOutput.blockingHook // empty' 2>/dev/null)
    if [[ -z "$blocking_hook" ]]; then
        fail "$TEST_NAME" "blockingHook field missing from deny JSON — observability bug #466 still present | output: $output"
        return
    fi

    pass "$TEST_NAME (blockingHook=$blocking_hook)"
}

# ============================================================
# TEST 3: #468 — write-policy must resolve repo identity from file path
# ============================================================
# When a session CWD is on main and a file is written to a worktree,
# detect_project_root() returns the wrong repo. The fix resolves from
# git -C "$(dirname "$file_path")" rev-parse --show-toplevel.
test_repo_identity_from_file_path() {
    local TEST_NAME="repo-identity-from-file-path"
    local main_repo="$TMP_BASE/identity-main"
    local worktree_path="$TMP_BASE/identity-worktree"

    # Create two separate repo structures to verify file-path-based resolution
    mkdir -p "$main_repo/src" "$main_repo/.claude"
    git -C "$main_repo" init -q
    git -C "$main_repo" config user.email "test@example.com"
    git -C "$main_repo" config user.name "Test"
    git -C "$main_repo" commit --allow-empty -m "init" -q
    git -C "$main_repo" worktree add "$worktree_path" -b feature/identity-test -q

    mkdir -p "$worktree_path/.claude" "$worktree_path/src"
    echo "ACTIVE|implementer|$(date +%s)" > "$worktree_path/.claude/.subagent-tracker"
    # Worktree has no MASTER_PLAN.md — plan-check should catch this

    # The MASTER_PLAN is in main but NOT in the worktree
    # (In real production this is the case: worktree is a separate checkout)
    touch "$main_repo/MASTER_PLAN.md"  # exists in main
    # NOT in worktree — to test that file-path resolution uses worktree's root

    local target_file="$worktree_path/src/widget.ts"
    mkdir -p "$worktree_path/src"
    local content
    content=$(printf 'export const w%d = %d;\n' $(seq 1 25 | awk '{print $1,$1}'))

    local payload
    payload=$(jq -n \
        --arg tool_name "Write" \
        --arg file_path "$target_file" \
        --arg content "$content" \
        '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

    # Feed with CWD-based PROJECT_DIR pointing at main (wrong repo)
    # but file_path pointing at worktree — file-path resolution must win
    local output
    output=$(printf '%s' "$payload" | \
        CLAUDE_PROJECT_DIR="$main_repo" \
        "$REPO_ROOT/hooks/plan-check.sh" 2>/dev/null) || true

    # With correct file-path resolution: worktree has no MASTER_PLAN.md -> deny
    # With broken CWD resolution: main has MASTER_PLAN.md -> allow (no output or warn)
    if [[ -z "$output" ]]; then
        fail "$TEST_NAME" "plan-check.sh produced no output — resolved main (has plan) instead of worktree (no plan) — repo identity bug #468"
        return
    fi

    local decision
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    if [[ "$decision" != "deny" ]]; then
        fail "$TEST_NAME" "expected deny (worktree has no MASTER_PLAN.md), got: '$decision' — repo identity bug #468 | output: $output"
        return
    fi

    pass "$TEST_NAME"
}

# ============================================================
# TEST 4: Verify plan-check.sh ALLOWS when MASTER_PLAN.md present in worktree
# ============================================================
# Regression guard: the worktree detection fix must not block legitimate writes.
test_plan_check_worktree_allows_with_plan() {
    local TEST_NAME="plan-check-worktree-allows-with-plan"
    local worktree_path
    worktree_path=$(setup_repo_with_worktree "t4") || {
        fail "$TEST_NAME" "setup_repo_with_worktree failed"; return
    }

    mkdir -p "$worktree_path/.claude" "$worktree_path/src"
    echo "ACTIVE|implementer|$(date +%s)" > "$worktree_path/.claude/.subagent-tracker"
    # MASTER_PLAN.md IS present — plan-check should pass
    touch "$worktree_path/MASTER_PLAN.md"

    local target_file="$worktree_path/src/app.ts"
    local content
    content=$(printf 'export const line%d = %d;\n' $(seq 1 25 | awk '{print $1,$1}'))

    local payload
    payload=$(jq -n \
        --arg tool_name "Write" \
        --arg file_path "$target_file" \
        --arg content "$content" \
        '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

    local output
    output=$(printf '%s' "$payload" | \
        CLAUDE_PROJECT_DIR="$worktree_path" \
        "$REPO_ROOT/hooks/plan-check.sh" 2>/dev/null) || true

    if [[ -n "$output" ]]; then
        local decision
        decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
        if [[ "$decision" == "deny" ]]; then
            local reason
            reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
            fail "$TEST_NAME" "unexpected deny when MASTER_PLAN.md present: $reason"
            return
        fi
    fi

    pass "$TEST_NAME"
}

# ============================================================
# TEST 5: Compound integration — full pre-write chain in worktree with deny observability
# ============================================================
# Exercises the real production sequence end-to-end:
#   pre-write.sh -> write-policy.sh -> {branch-guard, write-guard, plan-guard,
#   plan-check} -> deny with blockingHook
# This crosses the boundaries of all internal components in the write chain.
test_full_chain_deny_observability() {
    local TEST_NAME="full-chain-deny-observability"
    local worktree_path
    worktree_path=$(setup_repo_with_worktree "t5") || {
        fail "$TEST_NAME" "setup_repo_with_worktree failed"; return
    }

    mkdir -p "$worktree_path/.claude" "$worktree_path/src"
    echo "ACTIVE|implementer|$(date +%s)" > "$worktree_path/.claude/.subagent-tracker"
    # No MASTER_PLAN.md

    local target_file="$worktree_path/src/service.ts"
    local content
    content=$(printf 'export class Service%d {}\n' $(seq 1 25))

    local payload
    payload=$(jq -n \
        --arg tool_name "Write" \
        --arg file_path "$target_file" \
        --arg content "$content" \
        '{tool_name: $tool_name, tool_input: {file_path: $file_path, content: $content}}')

    local output
    output=$(printf '%s' "$payload" | \
        CLAUDE_PROJECT_DIR="$worktree_path" \
        "$REPO_ROOT/hooks/pre-write.sh" 2>/dev/null) || true

    # Must produce deny
    if [[ -z "$output" ]]; then
        fail "$TEST_NAME" "pre-write.sh produced no output"
        return
    fi

    local decision
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    if [[ "$decision" != "deny" ]]; then
        fail "$TEST_NAME" "expected deny, got: '$decision'"
        return
    fi

    # Must have blockingHook
    local blocking_hook
    blocking_hook=$(echo "$output" | jq -r '.hookSpecificOutput.blockingHook // empty' 2>/dev/null)
    if [[ -z "$blocking_hook" ]]; then
        fail "$TEST_NAME" "blockingHook missing from deny JSON | full output: $output"
        return
    fi

    # Must have permissionDecisionReason
    local reason
    reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
    if [[ -z "$reason" ]]; then
        fail "$TEST_NAME" "permissionDecisionReason missing from deny JSON"
        return
    fi

    pass "$TEST_NAME (blockingHook=$blocking_hook)"
}

# ============================================================
# Run all tests
# ============================================================
mkdir -p "$TMP_BASE"

test_plan_check_worktree_detection
test_deny_includes_blocking_hook
test_repo_identity_from_file_path
test_plan_check_worktree_allows_with_plan
test_full_chain_deny_observability

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
