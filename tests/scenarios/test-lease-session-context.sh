#!/usr/bin/env bash
# test-lease-session-context.sh — Issue lease, run session-init.sh,
# verify output contains "Active lease:" line.
#
# @decision DEC-LEASE-001
# @title Dispatch leases replace marker-based WHO enforcement for Check 3
# @status accepted
# @rationale session-init.sh calls rt_lease_current and injects lease info
#   into additionalContext so incoming agents know their execution contract.
set -euo pipefail

TEST_NAME="test-lease-session-context"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/session-init.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $TEST_NAME [$1] — $2"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $TEST_NAME [$1] — $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# ---------------------------------------------------------------------------
# Sub-case A: Active lease → "Active lease:" appears in session context
# ---------------------------------------------------------------------------
run_sub_case_a() {
    local branch="feature/session-lease-ctx"
    local wf_id dir db head_sha
    wf_id=$(printf '%s' "$branch" | tr '/: ' '---' | tr -cd '[:alnum:]._-')
    dir="$REPO_ROOT/tmp/${TEST_NAME}-a-$$"
    db="$dir/.claude/state.db"

    mkdir -p "$dir/.claude"
    (cd "$dir" && git init -q && git config user.email "t@t.com" && git config user.name "T")
    (cd "$dir" && git commit --allow-empty -m "init" -q)
    (cd "$dir" && git checkout -b "$branch" -q)
    head_sha=$(git -C "$dir" rev-parse HEAD)

    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$wf_id" "ready_for_guardian" --head-sha "$head_sha" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$wf_id" "$dir" "$branch" >/dev/null 2>&1

    # Issue active lease for the worktree
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" \
        lease issue-for-dispatch "guardian" \
        --workflow-id "$wf_id" \
        --worktree-path "$dir" \
        --branch "$branch" \
        --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1

    # Run session-init.sh with the project dir pointing to our temp repo
    local payload output context
    payload=$(jq -n --arg t "SessionStart" --arg trigger "startup" \
        '{hookEventName:$t,trigger:$trigger}')
    output=$(printf '%s' "$payload" \
        | CLAUDE_PROJECT_DIR="$dir" \
          CLAUDE_POLICY_DB="$db" \
          CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" \
          "$HOOK" 2>/dev/null || true)
    context=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null || true)

    rm -rf "$dir"

    if printf '%s' "$context" | grep -q "Active lease:"; then
        pass "A" "session-init output contains 'Active lease:' when lease is active"
    else
        fail "A" "session-init output missing 'Active lease:' — context: $context"
    fi
}

# ---------------------------------------------------------------------------
# Sub-case B: No active lease → "Active lease:" does NOT appear
# ---------------------------------------------------------------------------
run_sub_case_b() {
    local branch="feature/session-no-lease-ctx"
    local wf_id dir db
    wf_id=$(printf '%s' "$branch" | tr '/: ' '---' | tr -cd '[:alnum:]._-')
    dir="$REPO_ROOT/tmp/${TEST_NAME}-b-$$"
    db="$dir/.claude/state.db"

    mkdir -p "$dir/.claude"
    (cd "$dir" && git init -q && git config user.email "t@t.com" && git config user.name "T")
    (cd "$dir" && git commit --allow-empty -m "init" -q)
    (cd "$dir" && git checkout -b "$branch" -q)

    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
    # No lease issued

    local payload output context
    payload=$(jq -n --arg t "SessionStart" --arg trigger "startup" \
        '{hookEventName:$t,trigger:$trigger}')
    output=$(printf '%s' "$payload" \
        | CLAUDE_PROJECT_DIR="$dir" \
          CLAUDE_POLICY_DB="$db" \
          CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" \
          "$HOOK" 2>/dev/null || true)
    context=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null || true)

    rm -rf "$dir"

    if ! printf '%s' "$context" | grep -q "Active lease:"; then
        pass "B" "session-init output has no 'Active lease:' when no lease active"
    else
        fail "B" "session-init shows 'Active lease:' when no lease was issued"
    fi
}

echo "=== $TEST_NAME: starting ==="
run_sub_case_a
run_sub_case_b
echo ""
echo "=== $TEST_NAME: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -gt 0 ]] && exit 1
exit 0
