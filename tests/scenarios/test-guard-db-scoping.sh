#!/usr/bin/env bash
# v6 DB scoping: landing readiness in the project DB satisfies Guardian landing;
# identical readiness in a fake home DB does not.
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
trap 'rm -rf "$TMP_DIR"' EXIT

setup() {
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR/.claude" "$TMP_DIR/fake-home/.claude"
    git -C "$TMP_DIR" init -q -b main 2>/dev/null || { git -C "$TMP_DIR" init -q; git -C "$TMP_DIR" checkout -b main -q 2>/dev/null || true; }
    git -C "$TMP_DIR" config user.email t@t.com
    git -C "$TMP_DIR" config user.name T
    git -C "$TMP_DIR" commit --allow-empty -m init -q
    git -C "$TMP_DIR" checkout -b "$BRANCH" -q
    HEAD_SHA=$(git -C "$TMP_DIR" rev-parse HEAD)

    CLAUDE_POLICY_DB="$PROJECT_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null
    CLAUDE_POLICY_DB="$HOME_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null
    CLAUDE_POLICY_DB="$PROJECT_DB" python3 "$RUNTIME_ROOT/cli.py" marker set agent-test guardian --project-root "$TMP_DIR" >/dev/null
    CLAUDE_POLICY_DB="$PROJECT_DB" python3 "$RUNTIME_ROOT/cli.py" workflow bind "$WF_ID" "$TMP_DIR" "$BRANCH" >/dev/null
    CLAUDE_POLICY_DB="$PROJECT_DB" python3 "$RUNTIME_ROOT/cli.py" workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null
    CLAUDE_POLICY_DB="$PROJECT_DB" python3 "$RUNTIME_ROOT/cli.py" test-state set pass --project-root "$TMP_DIR" --head-sha "$HEAD_SHA" --passed 1 --total 1 >/dev/null
    CLAUDE_POLICY_DB="$PROJECT_DB" python3 "$RUNTIME_ROOT/cli.py" lease issue-for-dispatch guardian --workflow-id "$WF_ID" --worktree-path "$TMP_DIR" --branch "$BRANCH" --allowed-ops '["routine_local","high_risk"]' >/dev/null
}

seed_v6_ready() {
    local db="$1" with_lease_metadata="${2:-no}"
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" workflow bind "$WF_ID" "$TMP_DIR" "$BRANCH" >/dev/null
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" test-state set pass --project-root "$TMP_DIR" --head-sha "$HEAD_SHA" --passed 1 --total 1 >/dev/null
    local reviewer_json reviewer_run payload result guardian_run lease_meta
    reviewer_json=$(CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" stage run-create --workflow-id "$WF_ID" --stage-id reviewer --worktree-path "$TMP_DIR")
    reviewer_run=$(printf '%s' "$reviewer_json" | jq -r '.stage_run.id')
    payload=$(jq -nc --arg run "$reviewer_run" --arg sha "$HEAD_SHA" '{stage_run_id:$run,stage_id:"reviewer",verdict:"ready_for_guardian",summary:"reviewed",head_sha:$sha,findings:[]}')
    result=$(CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" stage result-submit "$reviewer_run" --payload "$payload")
    guardian_run=$(printf '%s' "$result" | jq -r '.next_stage_run.id')
    if [[ "$with_lease_metadata" == yes ]]; then
        lease_meta=$(jq -nc --arg run "$guardian_run" '{stage_run_id:$run}')
        CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" lease issue-for-dispatch guardian --workflow-id "$WF_ID" --worktree-path "$TMP_DIR" --branch "$BRANCH" --allowed-ops '["routine_local","high_risk"]' --metadata "$lease_meta" >/dev/null
    fi
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" stage landing-ready "$guardian_run" >/dev/null
}

run_guard() {
    local cmd="git -C \"$TMP_DIR\" commit --allow-empty -m 'test'"
    local payload
    payload=$(jq -n --arg t Bash --arg c "$cmd" --arg w "$TMP_DIR" '{tool_name:$t,tool_input:{command:$c},cwd:$w}')
    printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$PROJECT_DB" CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" "$HOOK" 2>/dev/null || true
}

# Project DB readiness -> allow
setup
seed_v6_ready "$PROJECT_DB" yes
output=$(run_guard)
if [[ -n "$output" && $(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty') == deny ]]; then
    echo "FAIL: $TEST_NAME sub-test 1 — expected allow with project DB v6 readiness"
    echo "  reason: $(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')"
    exit 1
fi

# Home DB readiness only -> project guard denies
setup
seed_v6_ready "$HOME_DB" yes
output=$(run_guard)
decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")
if [[ "$decision" != deny ]]; then
    echo "FAIL: $TEST_NAME sub-test 2 — expected deny (home DB readiness must not satisfy project guard), got '$decision'"
    echo "  output: $output"
    exit 1
fi

echo "PASS: <REDACTED> (2 sub-tests)"
