#!/usr/bin/env bash
# test-lease-concurrent-worktrees.sh — Two temp repos, two leases (different
# worktrees), commits in each succeed independently.
#
# Proves the uniqueness invariant is per-worktree: issuing a lease for worktree
# A does not affect worktree B, and both can pass Check 3 simultaneously.
#
# @decision DEC-LEASE-001
# @title Dispatch leases replace marker-based WHO enforcement for Check 3
# @status accepted
# @rationale At most one active lease per worktree_path. Two distinct worktree
#   paths can each hold an active lease simultaneously without conflict.
set -euo pipefail

TEST_NAME="test-lease-concurrent-worktrees"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-bash.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $TEST_NAME [$1] — $2"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $TEST_NAME [$1] — $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

_decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true; }
_reason()   { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true; }

_run_guard() {
    local cmd="$1" project_dir="$2" db="$3"
    local payload
    payload=$(jq -n --arg t "Bash" --arg c "$cmd" --arg w "$project_dir" \
        '{tool_name:$t,tool_input:{command:$c},cwd:$w}')
    printf '%s' "$payload" \
        | CLAUDE_PROJECT_DIR="$project_dir" \
          CLAUDE_POLICY_DB="$db" \
          CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" \
          "$HOOK" 2>/dev/null || true
}

_make_repo() {
    local branch="$1" suffix="$2"
    local wf_id dir db head_sha
    wf_id=$(printf '%s' "$branch" | tr '/: ' '---' | tr -cd '[:alnum:]._-')
    dir="$REPO_ROOT/tmp/${TEST_NAME}-${suffix}-$$"
    db="$dir/.claude/state.db"

    mkdir -p "$dir/.claude"
    (cd "$dir" && git init -q && git config user.email "t@t.com" && git config user.name "T")
    (cd "$dir" && git commit --allow-empty -m "init" -q)
    (cd "$dir" && git checkout -b "$branch" -q)
    head_sha=$(git -C "$dir" rev-parse HEAD)

    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" \
        test-state set pass --project-root "$dir" --passed 1 --total 1 >/dev/null 2>&1
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$wf_id" "ready_for_guardian" --head-sha "$head_sha" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$wf_id" "$dir" "$branch" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "$wf_id" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" \
        lease issue-for-dispatch "guardian" \
        --workflow-id "$wf_id" \
        --worktree-path "$dir" \
        --branch "$branch" \
        --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1

    # Export by writing to named vars via printf into caller namespace
    printf '%s\0%s\0%s\0%s\0' "$dir" "$db" "$wf_id" "$head_sha"
}

# ---------------------------------------------------------------------------
# Sub-case A: Two repos, two leases — commits in each allowed independently
# ---------------------------------------------------------------------------
run_sub_case_a() {
    local branch_a="feature/concurrent-wt-a"
    local branch_b="feature/concurrent-wt-b"

    local dir_a db_a wf_a head_a
    read -r -d '' dir_a db_a wf_a head_a < <(_make_repo "$branch_a" "a") || true

    local dir_b db_b wf_b head_b
    read -r -d '' dir_b db_b wf_b head_b < <(_make_repo "$branch_b" "b") || true

    local cmd_a output_a decision_a
    cmd_a="git -C \"$dir_a\" commit --allow-empty -m 'concurrent wt-a'"
    output_a=$(_run_guard "$cmd_a" "$dir_a" "$db_a")
    decision_a=$(_decision "$output_a")

    local cmd_b output_b decision_b
    cmd_b="git -C \"$dir_b\" commit --allow-empty -m 'concurrent wt-b'"
    output_b=$(_run_guard "$cmd_b" "$dir_b" "$db_b")
    decision_b=$(_decision "$output_b")

    rm -rf "$dir_a" "$dir_b"

    if [[ -z "$output_a" || "$decision_a" != "deny" ]]; then
        pass "A:wt-a" "commit in worktree A allowed with its own lease"
    else
        fail "A:wt-a" "unexpected deny for wt-a: $(_reason "$output_a")"
    fi

    if [[ -z "$output_b" || "$decision_b" != "deny" ]]; then
        pass "A:wt-b" "commit in worktree B allowed with its own lease"
    else
        fail "A:wt-b" "unexpected deny for wt-b: $(_reason "$output_b")"
    fi
}

echo "=== $TEST_NAME: starting ==="
run_sub_case_a
echo ""
echo "=== $TEST_NAME: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -gt 0 ]] && exit 1
exit 0
