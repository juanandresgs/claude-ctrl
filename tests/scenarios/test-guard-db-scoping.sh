#!/usr/bin/env bash
# test-guard-db-scoping.sh: proves guard.sh Check 10 reads evaluation state from the
# project-scoped DB, not ~/.claude/state.db.
#
# Sub-test 1 (positive): evaluation set in project DB → guard allows
# Sub-test 2 (negative): evaluation set in home DB only → guard denies
#
# @decision DEC-GUARD-015
# @title Guard evaluation reads are project-scoped
# @status accepted
# @rationale DEC-SELF-003 requires all proof reads/writes for in-project work
#   to resolve to the same project-scoped DB. This test proves the positive
#   and negative paths: evaluation in the project DB satisfies the guard; evaluation
#   only in the home DB does not.
set -euo pipefail

TEST_NAME="test-guard-db-scoping"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-bash.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
PROJECT_DB="$TMP_DIR/.claude/state.db"
HOME_DB="$TMP_DIR/fake-home/.claude/state.db"
BRANCH="feature/db-scope-test"
WF_ID="feature-db-scope-test"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

setup() {
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR/.claude" "$TMP_DIR/fake-home/.claude"
    git -C "$TMP_DIR" init -q
    git -C "$TMP_DIR" config user.email "t@t.com"
    git -C "$TMP_DIR" config user.name "T"
    git -C "$TMP_DIR" commit --allow-empty -m "init" -q
    git -C "$TMP_DIR" checkout -b "$BRANCH" -q

    # Schema in BOTH DBs
    CLAUDE_POLICY_DB="$PROJECT_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
    CLAUDE_POLICY_DB="$HOME_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1

    # Common gates in project DB: guardian:land role, test-status, workflow binding + scope
    CLAUDE_POLICY_DB="$PROJECT_DB" python3 "$RUNTIME_ROOT/cli.py" \
        marker set "agent-test" "guardian:land" --project-root "$TMP_DIR" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$PROJECT_DB" python3 "$RUNTIME_ROOT/cli.py" \
        test-state set pass --project-root "$TMP_DIR" --passed 1 --total 1 >/dev/null 2>&1
    CLAUDE_POLICY_DB="$PROJECT_DB" python3 "$RUNTIME_ROOT/cli.py" workflow bind "$WF_ID" "$TMP_DIR" "$BRANCH" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$PROJECT_DB" python3 "$RUNTIME_ROOT/cli.py" workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1
    # Lease (TKT-STAB-A3): Check 3 requires an active lease; issue one in project DB
    # so Check 3 passes and the scoping of evaluation reads is what's under test.
    CLAUDE_POLICY_DB="$PROJECT_DB" python3 "$RUNTIME_ROOT/cli.py" \
        lease issue-for-dispatch "guardian" \
        --workflow-id "$WF_ID" \
        --worktree-path "$TMP_DIR" \
        --branch "$BRANCH" \
        --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1
}

run_guard() {
    local cmd="git -C \"$TMP_DIR\" commit --allow-empty -m 'test'"
    local payload
    payload=$(jq -n --arg t "Bash" --arg c "$cmd" --arg w "$TMP_DIR" \
        '{tool_name:$t,tool_input:{command:$c},cwd:$w}')
    printf '%s' "$payload" \
        | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$PROJECT_DB" \
          CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" "$HOOK" 2>/dev/null || true
}

# --- Sub-test 1: Evaluation in PROJECT DB → guard allows ---
setup
HEAD_SHA=$(git -C "$TMP_DIR" rev-parse HEAD)
CLAUDE_POLICY_DB="$PROJECT_DB" python3 "$RUNTIME_ROOT/cli.py" evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$HEAD_SHA" >/dev/null 2>&1

output=$(run_guard)
if [[ -n "$output" ]]; then
    decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")
    if [[ "$decision" == "deny" ]]; then
        reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || echo "")
        echo "FAIL: $TEST_NAME sub-test 1 — expected allow with project DB evaluation, got deny"
        echo "  reason: $reason"
        exit 1
    fi
fi

# --- Sub-test 2: Evaluation in HOME DB only → guard denies ---
setup
# Set evaluation ONLY in the fake home DB, NOT in the project DB
HEAD_SHA=$(git -C "$TMP_DIR" rev-parse HEAD)
CLAUDE_POLICY_DB="$HOME_DB" python3 "$RUNTIME_ROOT/cli.py" evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$HEAD_SHA" >/dev/null 2>&1
# Project DB evaluation remains idle (default)

output=$(run_guard)
decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")
if [[ "$decision" != "deny" ]]; then
    echo "FAIL: $TEST_NAME sub-test 2 — expected deny (home DB evaluation should not satisfy project guard), got '$decision'"
    echo "  output: $output"
    exit 1
fi

echo "PASS: $TEST_NAME (2 sub-tests)"
exit 0
