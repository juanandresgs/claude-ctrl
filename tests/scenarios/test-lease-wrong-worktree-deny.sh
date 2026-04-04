#!/usr/bin/env bash
# test-lease-wrong-worktree-deny.sh — Lease issued for worktree A, op attempted
# in worktree B → denied by Check 3 (no active lease for worktree B).
#
# The validate_op call for worktree B finds no active lease (the only active
# lease is for worktree A). No lease + high_risk → denied.
#
# @decision DEC-LEASE-002
# @title Check 3 uses lease validate_op, not marker role
# @status accepted
# @rationale Leases are worktree-scoped. A lease for A gives no authority over
#   B. validate_op returns lease_id=None for B, op_class=high_risk → deny.
set -euo pipefail

TEST_NAME="test-lease-wrong-worktree-deny"
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

# ---------------------------------------------------------------------------
# Sub-case A: Lease for worktree A, push attempt in worktree B → denied
# ---------------------------------------------------------------------------
run_sub_case_a() {
    local branch_a="feature/wrong-wt-leased"
    local branch_b="feature/wrong-wt-unleaseed"
    local wf_a wf_b dir_a dir_b db_a db_b head_a head_b

    wf_a=$(printf '%s' "$branch_a" | tr '/: ' '---' | tr -cd '[:alnum:]._-')
    wf_b=$(printf '%s' "$branch_b" | tr '/: ' '---' | tr -cd '[:alnum:]._-')
    dir_a="$REPO_ROOT/tmp/${TEST_NAME}-a-$$"
    dir_b="$REPO_ROOT/tmp/${TEST_NAME}-b-$$"
    db_a="$dir_a/.claude/state.db"
    db_b="$dir_b/.claude/state.db"

    # Setup repo A (has the lease)
    mkdir -p "$dir_a/.claude"
    (cd "$dir_a" && git init -q && git config user.email "t@t.com" && git config user.name "T")
    (cd "$dir_a" && git commit --allow-empty -m "init" -q)
    (cd "$dir_a" && git checkout -b "$branch_a" -q)
    head_a=$(git -C "$dir_a" rev-parse HEAD)

    CLAUDE_POLICY_DB="$db_a" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
    CLAUDE_POLICY_DB="$db_a" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$db_a" python3 "$RUNTIME_ROOT/cli.py" \
        test-state set pass --project-root "$dir_a" --passed 1 --total 1 >/dev/null 2>&1
    CLAUDE_POLICY_DB="$db_a" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$wf_a" "ready_for_guardian" --head-sha "$head_a" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$db_a" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$wf_a" "$dir_a" "$branch_a" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$db_a" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "$wf_a" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1
    # Issue lease for worktree A only
    CLAUDE_POLICY_DB="$db_a" python3 "$RUNTIME_ROOT/cli.py" \
        lease issue-for-dispatch "guardian" \
        --workflow-id "$wf_a" \
        --worktree-path "$dir_a" \
        --branch "$branch_a" \
        --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1

    # Setup repo B (NO lease, uses same DB to share schema but different path)
    mkdir -p "$dir_b/.claude"
    (cd "$dir_b" && git init -q && git config user.email "t@t.com" && git config user.name "T")
    (cd "$dir_b" && git commit --allow-empty -m "init" -q)
    (cd "$dir_b" && git checkout -b "$branch_b" -q)
    head_b=$(git -C "$dir_b" rev-parse HEAD)

    # Use same DB as A so the lease is visible, but worktree_path differs
    CLAUDE_POLICY_DB="$db_a" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$wf_b" "ready_for_guardian" --head-sha "$head_b" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$db_a" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$wf_b" "$dir_b" "$branch_b" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$db_a" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "$wf_b" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1
    CLAUDE_POLICY_DB="$db_a" python3 "$RUNTIME_ROOT/cli.py" \
        test-state set pass --project-root "$dir_b" --passed 1 --total 1 >/dev/null 2>&1

    # Attempt push in worktree B using db_a (lease is for dir_a, not dir_b)
    local cmd output decision reason
    cmd="git -C \"$dir_b\" push origin $branch_b"
    output=$(_run_guard "$cmd" "$dir_b" "$db_a")
    decision=$(_decision "$output")
    reason=$(_reason "$output")

    rm -rf "$dir_a" "$dir_b"

    if [[ "$decision" != "deny" ]]; then
        fail "A" "expected deny for push on wrong worktree, got decision='$decision'"
        return
    fi
    if ! printf '%s' "$reason" | grep -qiE "lease|No active"; then
        fail "A" "deny reason should mention 'lease' or 'No active', got: $reason"
        return
    fi
    pass "A" "push on wrong worktree denied (no lease for that path)"
}

echo "=== $TEST_NAME: starting ==="
run_sub_case_a
echo ""
echo "=== $TEST_NAME: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -gt 0 ]] && exit 1
exit 0
