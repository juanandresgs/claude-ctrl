#!/usr/bin/env bash
# test-lease-no-lease-routine-local-allow.sh — No lease, eval ready, git commit
# → allowed. Check 3 no-lease + routine_local path allows; Check 10 gates on
# eval readiness.
#
# This tests the backward-compatible path: pre-lease workflows where no lease
# is issued still work for routine_local ops. The new Check 3 only denies
# high_risk ops when no lease exists.
#
# @decision DEC-LEASE-002
# @title Check 3 uses lease validate_op, not marker role
# @status accepted
# @rationale routine_local ops without a lease fall through Check 3 to Check 10.
#   This preserves the original evaluation_state authority for commit/merge
#   and ensures backward compatibility when no lease has been issued.
set -euo pipefail

TEST_NAME="test-lease-no-lease-routine-local-allow"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/guard.sh"
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

_setup() {
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
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian" >/dev/null 2>&1
    echo "pass|0|$(date +%s)" > "$TMP_DIR/.claude/.test-status"
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$CURRENT_HEAD" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$WF_ID" "$TMP_DIR" "$branch" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1
    # NO lease issued
}

# shellcheck disable=SC2329
_teardown() { [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"; TMP_DIR=""; }

# ---------------------------------------------------------------------------
# Sub-case A: No lease + eval ready + commit → allowed (backward compatibility)
# ---------------------------------------------------------------------------
run_sub_case_a() {
    local branch="feature/no-lease-commit-allow"
    _setup "$branch"
    trap '_teardown' RETURN

    local cmd output decision
    cmd="git -C \"$TMP_DIR\" commit --allow-empty -m 'no-lease routine commit'"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")

    if [[ -z "$output" || "$decision" != "deny" ]]; then
        pass "A" "no lease + eval ready + commit → allowed (Check 3 no-lease routine_local path)"
    else
        fail "A" "unexpected deny: $(_reason "$output")"
    fi
}

# ---------------------------------------------------------------------------
# Sub-case B: No lease + eval NOT ready + commit → denied by Check 10
# (Check 3 passes for routine_local; Check 10 fires because eval is not ready)
# ---------------------------------------------------------------------------
run_sub_case_b() {
    local branch="feature/nolicense-commit-eval-deny"
    _setup "$branch"
    trap '_teardown' RETURN

    # Override eval to needs_changes
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$WF_ID" "needs_changes" >/dev/null 2>&1

    local cmd output decision reason
    cmd="git -C \"$TMP_DIR\" commit --allow-empty -m 'premature commit'"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")
    reason=$(_reason "$output")

    if [[ "$decision" != "deny" ]]; then
        fail "B" "expected deny (Check 10), got decision='$decision'"
        return
    fi
    if ! printf '%s' "$reason" | grep -qi "evaluation_state"; then
        fail "B" "deny reason should mention 'evaluation_state', got: $reason"
        return
    fi
    # Must NOT mention lease — this is Check 10, not Check 3
    if printf '%s' "$reason" | grep -qi "lease"; then
        fail "B" "deny mentions 'lease' — should be Check 10, not Check 3: $reason"
        return
    fi
    pass "B" "no lease + needs_changes eval + commit → denied by Check 10 (not Check 3)"
}

# ---------------------------------------------------------------------------
# Sub-case C: No lease + plain merge + eval ready → allowed (routine_local)
# ---------------------------------------------------------------------------
run_sub_case_c() {
    local branch="feature/nolicense-merge-allow"
    _setup "$branch"
    trap '_teardown' RETURN

    # Create a second branch to merge from, with eval set up for its workflow_id
    (cd "$TMP_DIR" && git checkout -b "feature/merge-source" -q && git commit --allow-empty -m "src" -q)
    local merge_wf
    merge_wf=$(printf '%s' "feature/merge-source" | tr '/: ' '---' | tr -cd '[:alnum:]._-')
    local merge_head
    merge_head=$(git -C "$TMP_DIR" rev-parse HEAD)
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$merge_wf" "ready_for_guardian" --head-sha "$merge_head" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$merge_wf" "$TMP_DIR" "feature/merge-source" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "$merge_wf" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1
    (cd "$TMP_DIR" && git checkout "$branch" -q)

    local cmd output decision
    cmd="git -C \"$TMP_DIR\" merge feature/merge-source"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")

    if [[ -z "$output" || "$decision" != "deny" ]]; then
        pass "C" "no lease + eval ready + merge → allowed (routine_local no-lease path)"
    else
        fail "C" "unexpected deny: $(_reason "$output")"
    fi
}

echo "=== $TEST_NAME: starting ==="
run_sub_case_a
run_sub_case_b
run_sub_case_c
echo ""
echo "=== $TEST_NAME: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -gt 0 ]] && exit 1
exit 0
