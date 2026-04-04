#!/usr/bin/env bash
# test-lease-no-lease-high-risk-deny.sh — No lease, schema initialized, git push
# on a non-meta-repo → denied by Check 3 with "No active lease" message.
#
# This tests the no-lease + high_risk branch in the new Check 3.
# No lease is issued; validate_op finds no active lease; op_class=high_risk
# → deny with message containing "No active lease".
#
# @decision DEC-LEASE-002
# @title Check 3 uses lease validate_op, not marker role
# @status accepted
# @rationale Without a lease, high-risk ops are denied at Check 3. The deny
#   message must guide the operator to issue a lease via cc-policy.
set -euo pipefail

TEST_NAME="test-lease-no-lease-high-risk-deny"
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
# Sub-case A: No lease, schema initialized, push → denied with "No active lease"
# ---------------------------------------------------------------------------
run_sub_case_a() {
    local branch="feature/no-lease-push-deny"
    local wf_id dir db head_sha
    wf_id=$(printf '%s' "$branch" | tr '/: ' '---' | tr -cd '[:alnum:]._-')
    dir="$REPO_ROOT/tmp/${TEST_NAME}-a-$$"
    db="$dir/.claude/state.db"

    mkdir -p "$dir/.claude"
    (cd "$dir" && git init -q && git config user.email "t@t.com" && git config user.name "T")
    (cd "$dir" && git commit --allow-empty -m "init" -q)
    (cd "$dir" && git checkout -b "$branch" -q)
    head_sha=$(git -C "$dir" rev-parse HEAD)

    # Schema initialized, guardian marker, all downstream gates satisfied
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
    # NO lease issued

    local cmd output decision reason
    cmd="git -C \"$dir\" push origin $branch"
    output=$(_run_guard "$cmd" "$dir" "$db")
    decision=$(_decision "$output")
    reason=$(_reason "$output")

    rm -rf "$dir"

    if [[ "$decision" != "deny" ]]; then
        fail "A" "expected deny for push with no lease, got decision='$decision'"
        return
    fi
    if ! printf '%s' "$reason" | grep -qiE "No active lease|lease"; then
        fail "A" "deny reason should mention 'No active lease', got: $reason"
        return
    fi
    pass "A" "no lease + push → denied by Check 3 with 'No active lease' message"
}

# ---------------------------------------------------------------------------
# Sub-case B: No lease, rebase → denied (also high_risk)
# ---------------------------------------------------------------------------
run_sub_case_b() {
    local branch="feature/no-lease-rebase-deny"
    local wf_id dir db head_sha
    wf_id=$(printf '%s' "$branch" | tr '/: ' '---' | tr -cd '[:alnum:]._-')
    dir="$REPO_ROOT/tmp/${TEST_NAME}-b-$$"
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
    # NO lease

    local cmd output decision reason
    cmd="git -C \"$dir\" rebase main"
    output=$(_run_guard "$cmd" "$dir" "$db")
    decision=$(_decision "$output")
    reason=$(_reason "$output")

    rm -rf "$dir"

    # Note: rebase doesn't match the commit|merge|push pattern in Check 3,
    # so it falls through to Check 13 which requires approval.
    # rebase is high_risk but Check 3 only triggers on commit|merge|push.
    # The deny should still come (from Check 13 if not Check 3).
    if [[ "$decision" != "deny" ]]; then
        fail "B" "expected deny for rebase with no lease/token, got decision='$decision'"
        return
    fi
    pass "B" "no lease + rebase → denied (high_risk op blocked)"
}

echo "=== $TEST_NAME: starting ==="
run_sub_case_a
run_sub_case_b
echo ""
echo "=== $TEST_NAME: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -gt 0 ]] && exit 1
exit 0
