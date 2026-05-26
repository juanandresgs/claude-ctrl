#!/usr/bin/env bash
# v6 landing gate allow path: Guardian commit is allowed only when the
# v6_landing_readiness aggregate is ready and HEAD-aligned.
set -euo pipefail

TEST_NAME="test-guard-evaluator-gate-allows"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-bash.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/.claude/state.db"
BRANCH="feature/eval-allows-test"
WF_ID="feature-eval-allows-test"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/.claude"
git -C "$TMP_DIR" init -q -b main 2>/dev/null || { git -C "$TMP_DIR" init -q; git -C "$TMP_DIR" checkout -b main -q 2>/dev/null || true; }
git -C "$TMP_DIR" config user.email t@t.com
git -C "$TMP_DIR" config user.name T
git -C "$TMP_DIR" commit --allow-empty -m init -q
git -C "$TMP_DIR" checkout -b "$BRANCH" -q
CURRENT_HEAD=$(git -C "$TMP_DIR" rev-parse HEAD)

CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" marker set agent-test guardian --project-root "$TMP_DIR" >/dev/null
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" workflow bind "$WF_ID" "$TMP_DIR" "$BRANCH" >/dev/null
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" test-state set pass --project-root "$TMP_DIR" --head-sha "$CURRENT_HEAD" --passed 1 --total 1 >/dev/null

REVIEWER_JSON=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" stage run-create --workflow-id "$WF_ID" --stage-id reviewer --worktree-path "$TMP_DIR")
REVIEWER_RUN=$(printf '%s' "$REVIEWER_JSON" | jq -r '.stage_run.id')
REVIEW_PAYLOAD=$(jq -nc --arg run "$REVIEWER_RUN" --arg sha "$CURRENT_HEAD" '{stage_run_id:$run,stage_id:"reviewer",verdict:"ready_for_guardian",summary:"reviewed",head_sha:$sha,findings:[]}')
REVIEW_RESULT=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" stage result-submit "$REVIEWER_RUN" --payload "$REVIEW_PAYLOAD")
GUARDIAN_RUN=$(printf '%s' "$REVIEW_RESULT" | jq -r '.next_stage_run.id')
LEASE_META=$(jq -nc --arg run "$GUARDIAN_RUN" '{stage_run_id:$run}')
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" lease issue-for-dispatch guardian \
    --workflow-id "$WF_ID" --worktree-path "$TMP_DIR" --branch "$BRANCH" \
    --allowed-ops '["routine_local","high_risk"]' --metadata "$LEASE_META" >/dev/null
READINESS=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" stage landing-ready "$GUARDIAN_RUN")
[[ $(printf '%s' "$READINESS" | jq -r '.readiness.status') == ready ]]

CMD="git -C \"$TMP_DIR\" commit --allow-empty -m 'test commit'"
PAYLOAD=$(jq -n --arg t Bash --arg c "$CMD" --arg w "$TMP_DIR" '{tool_name:$t,tool_input:{command:$c},cwd:$w}')
output=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" "$HOOK" 2>/dev/null) || {
    echo "FAIL: $TEST_NAME — hook exited nonzero"
    exit 1
}

if [[ -n "$output" ]]; then
    decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")
    if [[ "$decision" == deny ]]; then
        reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || echo "")
        echo "FAIL: $TEST_NAME — unexpected deny: $reason"
        exit 1
    fi
fi

echo "PASS: <REDACTED>"
