#!/usr/bin/env bash
# test-lease-implementer-push-deny.sh — Implementer lease with only
# ["routine_local"] tries git push (high_risk) → denied by Check 3.
#
# The lease exists but allowed_ops does not include high_risk.
# validate_op returns allowed=false with reason mentioning "allowed_ops".
# Check 3 must deny with a reason containing "Lease check".
#
# @decision DEC-LEASE-002
# @title Check 3 uses lease validate_op, not marker role
# @status accepted
# @rationale The lease is the sole authority. allowed_ops=["routine_local"]
#   explicitly excludes high_risk. validate_op rejects the push op and
#   guard.sh Check 3 propagates the denial.
set -euo pipefail

TEST_NAME="test-lease-implementer-push-deny"
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

# ---------------------------------------------------------------------------
# Sub-case A: Implementer lease (routine_local only) + git push → denied
# ---------------------------------------------------------------------------
run_sub_case_a() {
    local branch="feature/lease-impl-push-deny"
    local wf_id
    wf_id=$(printf '%s' "$branch" | tr '/: ' '---' | tr -cd '[:alnum:]._-')
    local tmp_dir test_db
    tmp_dir="$REPO_ROOT/tmp/${TEST_NAME}-${wf_id}-$$"
    test_db="$tmp_dir/.claude/state.db"

    mkdir -p "$tmp_dir/.claude"
    (cd "$tmp_dir" && git init -q && git config user.email "t@t.com" && git config user.name "T")
    (cd "$tmp_dir" && git commit --allow-empty -m "init" -q)
    (cd "$tmp_dir" && git checkout -b "$branch" -q)
    local head_sha
    head_sha=$(git -C "$tmp_dir" rev-parse HEAD)

    CLAUDE_POLICY_DB="$test_db" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
    CLAUDE_POLICY_DB="$test_db" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "implementer" >/dev/null 2>&1
    echo "pass|0|$(date +%s)" > "$tmp_dir/.claude/.test-status"
    CLAUDE_POLICY_DB="$test_db" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$wf_id" "ready_for_guardian" --head-sha "$head_sha" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$test_db" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$wf_id" "$tmp_dir" "$branch" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$test_db" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "$wf_id" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1

    # Issue implementer lease with only routine_local — high_risk NOT allowed
    CLAUDE_POLICY_DB="$test_db" python3 "$RUNTIME_ROOT/cli.py" \
        lease issue-for-dispatch "implementer" \
        --workflow-id "$wf_id" \
        --worktree-path "$tmp_dir" \
        --branch "$branch" \
        --allowed-ops '["routine_local"]' >/dev/null 2>&1

    local cmd output decision reason
    cmd="git -C \"$tmp_dir\" push origin $branch"
    output=$(_run_guard "$cmd" "$tmp_dir" "$test_db")
    decision=$(_decision "$output")
    reason=$(_reason "$output")

    rm -rf "$tmp_dir"

    if [[ "$decision" != "deny" ]]; then
        fail "A" "expected deny for push with routine_local-only lease, got decision='$decision'"
        return
    fi
    if ! printf '%s' "$reason" | grep -qi "lease"; then
        fail "A" "deny reason should mention 'lease', got: $reason"
        return
    fi
    pass "A" "implementer lease (routine_local only) + push denied by Check 3 with lease message"
}

echo "=== $TEST_NAME: starting ==="
run_sub_case_a
echo ""
echo "=== $TEST_NAME: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -gt 0 ]] && exit 1
exit 0
