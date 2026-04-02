#!/usr/bin/env bash
# test-lease-auto-land-semantics.sh — Full auto-land flow with lease:
# issue lease + eval ready + binding + scope + test-status → git commit allowed.
#
# This is the compound-interaction test for the lease subsystem. It crosses
# the boundaries of: dispatch_leases (leases.py), evaluation_state (evaluation.py),
# workflow_bindings (workflows.py), and guard.sh Check 3 + Check 10 + Check 12.
#
# @decision DEC-LEASE-002
# @title Check 3 uses lease validate_op, not marker role
# @status accepted
# @rationale The full auto-land sequence now requires: lease issued for worktree
#   (Check 3), eval=ready_for_guardian + SHA match (Check 10), binding + scope
#   (Check 12), test-status=pass (Check 9). This test proves all gates cooperate.
set -euo pipefail

TEST_NAME="test-lease-auto-land-semantics"
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
# Sub-case A: Full cooperative path — all gates satisfied → commit allowed
# ---------------------------------------------------------------------------
run_sub_case_a() {
    local branch="feature/auto-land-with-lease"
    local wf_id dir db head_sha
    wf_id=$(printf '%s' "$branch" | tr '/: ' '---' | tr -cd '[:alnum:]._-')
    dir="$REPO_ROOT/tmp/${TEST_NAME}-a-$$"
    db="$dir/.claude/state.db"

    mkdir -p "$dir/.claude"
    (cd "$dir" && git init -q && git config user.email "t@t.com" && git config user.name "T")
    (cd "$dir" && git commit --allow-empty -m "init" -q)
    (cd "$dir" && git checkout -b "$branch" -q)
    head_sha=$(git -C "$dir" rev-parse HEAD)

    # Schema + marker
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian" >/dev/null 2>&1

    # test-status = pass (Check 9)
    echo "pass|0|$(date +%s)" > "$dir/.claude/.test-status"

    # evaluation_state = ready_for_guardian + SHA (Check 10)
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$wf_id" "ready_for_guardian" --head-sha "$head_sha" >/dev/null 2>&1

    # workflow binding + scope (Check 12)
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$wf_id" "$dir" "$branch" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "$wf_id" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1

    # dispatch lease (Check 3)
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" \
        lease issue-for-dispatch "guardian" \
        --workflow-id "$wf_id" \
        --worktree-path "$dir" \
        --branch "$branch" \
        --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1

    local cmd output decision
    cmd="git -C \"$dir\" commit --allow-empty -m 'auto-land with lease'"
    output=$(_run_guard "$cmd" "$dir" "$db")
    decision=$(_decision "$output")

    rm -rf "$dir"

    if [[ -z "$output" || "$decision" != "deny" ]]; then
        pass "A" "full auto-land with lease → commit allowed (all gates satisfied)"
    else
        fail "A" "unexpected deny: $(_reason "$output")"
    fi
}

# ---------------------------------------------------------------------------
# Sub-case B: Missing lease only → commit still allowed (routine_local no-lease path)
# ---------------------------------------------------------------------------
run_sub_case_b() {
    local branch="feature/auto-land-no-lease"
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
    echo "pass|0|$(date +%s)" > "$dir/.claude/.test-status"
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$wf_id" "ready_for_guardian" --head-sha "$head_sha" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$wf_id" "$dir" "$branch" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "$wf_id" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1
    # No lease issued

    local cmd output decision
    cmd="git -C \"$dir\" commit --allow-empty -m 'auto-land no lease'"
    output=$(_run_guard "$cmd" "$dir" "$db")
    decision=$(_decision "$output")

    rm -rf "$dir"

    if [[ -z "$output" || "$decision" != "deny" ]]; then
        pass "B" "no lease + routine_local commit + eval ready → allowed (Check 3 no-lease path)"
    else
        fail "B" "unexpected deny: $(_reason "$output")"
    fi
}

echo "=== $TEST_NAME: starting ==="
run_sub_case_a
run_sub_case_b
echo ""
echo "=== $TEST_NAME: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -gt 0 ]] && exit 1
exit 0
