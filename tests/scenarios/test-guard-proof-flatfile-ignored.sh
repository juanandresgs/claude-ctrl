#!/usr/bin/env bash
# test-guard-proof-flatfile-ignored.sh: proves guard.sh Check 10 reads
# evaluation_state only. A stale proof flat file with "verified" must NOT
# satisfy the gate when evaluation_state is absent/idle.
#
# @decision DEC-GUARD-014
# @title Evaluation state is authoritative for Check 10
# @status accepted
# @rationale guard.sh Check 10 was migrated from flat-file proof to evaluation
#   reads. This test ensures the flat file is truly ignored — a stale
#   .proof-status-* file with "verified" cannot bypass the evaluation gate.
set -euo pipefail

TEST_NAME="test-guard-proof-flatfile-ignored"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-bash.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/.claude/state.db"
BRANCH="feature/flatfile-test"
WF_ID="feature-flatfile-test"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" config user.email "t@t.com"
git -C "$TMP_DIR" config user.name "T"
git -C "$TMP_DIR" commit --allow-empty -m "init" -q
git -C "$TMP_DIR" checkout -b "$BRANCH" -q

# Schema + guardian:land role + test-status + workflow binding + scope
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian:land" --project-root "$TMP_DIR" >/dev/null 2>&1
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    test-state set pass --project-root "$TMP_DIR" --passed 1 --total 1 >/dev/null 2>&1
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" workflow bind "$WF_ID" "$TMP_DIR" "$BRANCH" >/dev/null 2>&1
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1
# Lease (TKT-STAB-A3): Check 3 requires an active lease; issue one so the
# deny comes from Check 10 (missing evaluation_state), not Check 3 (no lease).
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    lease issue-for-dispatch "guardian" \
    --workflow-id "$WF_ID" \
    --worktree-path "$TMP_DIR" \
    --branch "$BRANCH" \
    --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1

# Write STALE flat file with "verified" — but do NOT set evaluation_state.
# evaluation_state is absent (idle) — Check 10 should deny.
echo "verified|$(date +%s)" > "$TMP_DIR/.claude/.proof-status-$WF_ID"

CMD="git -C \"$TMP_DIR\" commit --allow-empty -m 'test'"
PAYLOAD=$(jq -n --arg t "Bash" --arg c "$CMD" --arg w "$TMP_DIR" \
    '{tool_name:$t,tool_input:{command:$c},cwd:$w}')

output=$(printf '%s' "$PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" \
      CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" "$HOOK" 2>/dev/null) || true

decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")
reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || echo "")

if [[ "$decision" != "deny" ]]; then
    echo "FAIL: $TEST_NAME — expected deny (flat file should be ignored), got '$decision'"
    echo "  output: $output"
    exit 1
fi

if ! printf '%s' "$reason" | grep -qi "evaluation_state"; then
    echo "FAIL: $TEST_NAME — deny reason should mention evaluation_state (not proof)"
    echo "  reason: $reason"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
