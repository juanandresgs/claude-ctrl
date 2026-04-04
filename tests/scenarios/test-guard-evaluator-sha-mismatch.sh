#!/usr/bin/env bash
# test-guard-evaluator-sha-mismatch.sh: proves guard.sh Check 10 denies
# git commit when evaluation_state == "ready_for_guardian" but the stored
# head_sha does not match the current HEAD.
#
# This is the regression gate for Evaluation Contract check 17:
#   "Source changes after evaluator clearance invalidate readiness"
# The SHA mismatch path catches the case where track.sh's invalidate call
# did not fire (e.g. schema migration edge case) but the SHA still differs.
#
# @decision DEC-EVAL-003
# @title guard.sh Check 10 gates on evaluation_state, not proof_state
# @status accepted
# @rationale SHA-match requirement prevents stale evaluator clearance from
#   letting a modified HEAD through Guard. The stored sha must prefix-match
#   the current HEAD or vice versa (short vs full sha tolerance).
set -euo pipefail

TEST_NAME="test-guard-evaluator-sha-mismatch"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-bash.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/.claude/state.db"
BRANCH="feature/sha-mismatch-test"
WF_ID="feature-sha-mismatch-test"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" config user.email "t@t.com"
git -C "$TMP_DIR" config user.name "T"
git -C "$TMP_DIR" commit --allow-empty -m "init" -q
git -C "$TMP_DIR" checkout -b "$BRANCH" -q

# Record original HEAD sha
ORIGINAL_HEAD=$(git -C "$TMP_DIR" rev-parse HEAD)

# Set evaluation_state ready_for_guardian with ORIGINAL sha
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian" >/dev/null 2>&1
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    test-state set pass --project-root "$TMP_DIR" --passed 1 --total 1 >/dev/null 2>&1
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$ORIGINAL_HEAD" >/dev/null 2>&1
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    workflow bind "$WF_ID" "$TMP_DIR" "$BRANCH" >/dev/null 2>&1
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1
# Lease (TKT-STAB-A3): Check 3 requires an active lease; issue one so the
# deny comes from Check 10 (SHA mismatch), not Check 3 (no lease).
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    lease issue-for-dispatch "guardian" \
    --workflow-id "$WF_ID" \
    --worktree-path "$TMP_DIR" \
    --branch "$BRANCH" \
    --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1

# Now make a new commit — HEAD advances, sha no longer matches stored sha
git -C "$TMP_DIR" commit --allow-empty -m "source change after evaluation" -q
NEW_HEAD=$(git -C "$TMP_DIR" rev-parse HEAD)

if [[ "$ORIGINAL_HEAD" == "$NEW_HEAD" ]]; then
    echo "FAIL: $TEST_NAME — setup error: HEAD did not advance"
    exit 1
fi

CMD="git -C \"$TMP_DIR\" commit --allow-empty -m 'post-eval commit'"
PAYLOAD=$(jq -n --arg t "Bash" --arg c "$CMD" --arg w "$TMP_DIR" \
    '{tool_name:$t,tool_input:{command:$c},cwd:$w}')

output=$(printf '%s' "$PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" \
      CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" "$HOOK" 2>/dev/null) || true

decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")
reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || echo "")

if [[ "$decision" != "deny" ]]; then
    echo "FAIL: $TEST_NAME — expected deny on SHA mismatch, got '$decision'"
    echo "  original: $ORIGINAL_HEAD  current: $NEW_HEAD"
    echo "  output: $output"
    exit 1
fi

if ! printf '%s' "$reason" | grep -qi "head_sha\|head sha\|sha"; then
    echo "FAIL: $TEST_NAME — deny reason should mention sha mismatch"
    echo "  reason: $reason"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
