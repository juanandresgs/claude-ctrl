#!/usr/bin/env bash
# test-lease-guardian-commit.sh — Lease with routine_local+high_risk issued for
# guardian role; routine commit + eval ready → Check 3 allows (lease found, allowed).
#
# Sub-cases:
#   A: Lease with ["routine_local","high_risk"], eval ready → git commit allowed
#   B: No lease (control) → git commit denied (Check 3: all git ops require lease)
#
# @decision DEC-LEASE-002
# @title Check 3 uses lease validate_op, not marker role
# @status accepted
# @rationale When a guardian lease exists for the worktree the lease is the
#   sole authority. routine_local+high_risk allowed_ops means commit passes
#   validate_op. Check 10 then gates on eval readiness. This test proves the
#   full cooperative path: lease present + eval ready + test-status pass.
#   Sub-case B is the control: without a lease, ALL git ops are denied by
#   Check 3 (post-INIT-PE). The no-lease allow path is removed.
set -euo pipefail

TEST_NAME="test-lease-guardian-commit"
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

_setup_repo() {
    local branch="$1"
    WF_ID=$(printf '%s' "$branch" | tr '/: ' '---' | tr -cd '[:alnum:]._-')
    TMP_DIR="$REPO_ROOT/tmp/${TEST_NAME}-${WF_ID}-$$"
    TEST_DB="$TMP_DIR/.claude/state.db"

    mkdir -p "$TMP_DIR/.claude"
    (cd "$TMP_DIR" && git init -q && git config user.email "t@t.com" && git config user.name "T")
    (cd "$TMP_DIR" && git commit --allow-empty -m "init" -q)
    (cd "$TMP_DIR" && git checkout -b "$branch" -q)
    CURRENT_HEAD=$(git -C "$TMP_DIR" rev-parse HEAD)

    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian:land" --project-root "$TMP_DIR" >/dev/null 2>&1

    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        test-state set pass --project-root "$TMP_DIR" --passed 1 --total 1 >/dev/null 2>&1

    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$CURRENT_HEAD" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$WF_ID" "$TMP_DIR" "$branch" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1
}

# shellcheck disable=SC2329
_teardown() { [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"; TMP_DIR=""; }

# ---------------------------------------------------------------------------
# Sub-case A: Lease with routine_local+high_risk + eval ready → commit allowed
# ---------------------------------------------------------------------------
run_sub_case_a() {
    local branch="feature/lease-guardian-commit"
    _setup_repo "$branch"
    trap '_teardown' RETURN

    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        lease issue-for-dispatch "guardian" \
        --workflow-id "$WF_ID" \
        --worktree-path "$TMP_DIR" \
        --branch "$branch" \
        --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1

    local cmd output decision
    cmd="git -C \"$TMP_DIR\" commit --allow-empty -m 'guardian commit with lease'"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")

    if [[ -z "$output" || "$decision" != "deny" ]]; then
        pass "A" "guardian lease + eval ready → commit allowed"
    else
        fail "A" "unexpected deny: $(_reason "$output")"
    fi
}

# ---------------------------------------------------------------------------
# Sub-case B: No lease, routine commit + eval ready → denied (Check 3: all
# git ops require an active lease post-INIT-PE; no-lease allow path removed)
# ---------------------------------------------------------------------------
run_sub_case_b() {
    local branch="feature/lease-no-lease-commit"
    _setup_repo "$branch"
    trap '_teardown' RETURN

    # No lease issued — Check 3 must deny ALL git ops without an active lease

    local cmd output decision reason
    cmd="git -C \"$TMP_DIR\" commit --allow-empty -m 'no-lease routine commit'"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")
    reason=$(_reason "$output")

    if [[ "$decision" != "deny" ]]; then
        fail "B" "expected deny for no-lease commit, got decision='$decision'"
        return
    fi
    if ! printf '%s' "$reason" | grep -qiE "lease|No active"; then
        fail "B" "deny reason should mention 'lease', got: $reason"
        return
    fi
    pass "B" "no lease + routine_local commit → denied (No active dispatch lease)"
}

echo "=== $TEST_NAME: starting ==="
run_sub_case_a
run_sub_case_b
echo ""
echo "=== $TEST_NAME: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -gt 0 ]] && exit 1
exit 0
