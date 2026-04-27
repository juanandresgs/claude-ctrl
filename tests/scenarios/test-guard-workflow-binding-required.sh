#!/usr/bin/env bash
# test-guard-workflow-binding-required.sh: verifies guard.sh Check 12 denies git
# commit when no workflow binding exists, then allows after binding + scope are set.
#
# Production sequence: implementer on feature branch attempts commit → guard.sh
# Check 12 finds no binding for workflow_id → deny. After subagent-start.sh
# binds the workflow and planner sets scope → commit allowed (at Check 12 level).
#
# Gates exercised:
#   Check 3: WHO — guardian:land role (satisfied for both deny and allow paths)
#   Check 9: test-status = pass (satisfied)
#   Check 10: proof verified (satisfied via runtime SQLite)
#   Check 12A: workflow binding must exist → deny (no binding), allow (after bind)
#
# @decision DEC-SMOKE-WF-003
# @title Guard Check 12 denies commit without binding, allows after bind+scope
# @status accepted
# @rationale The binding-required check is the first sub-check in Check 12. If no
#   binding exists the workflow_id is untraceable — guard.sh cannot know which
#   scope to enforce. This test confirms the deny fires before the scope check
#   and that binding + scope together unblock the gate.
set -euo pipefail

TEST_NAME="test-guard-workflow-binding-required"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-bash.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/.claude/state.db"
BRANCH="feature/wf-binding-test"
WF_ID="feature-wf-binding-test"  # sanitize_token("feature/wf-binding-test") = replace / with -

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"

# Set up git repo on the feature branch
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" config user.email "test@test.com"
git -C "$TMP_DIR" config user.name "Test"
git -C "$TMP_DIR" commit --allow-empty -m "init" -q
git -C "$TMP_DIR" checkout -b "$BRANCH" -q

# Provision schema
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1

# Satisfy Check 3: guardian role
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian:land" --project-root "$TMP_DIR" >/dev/null 2>&1

# Satisfy test gate: test-status = pass via runtime (policy engine reads SQLite)
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    test-state set pass --project-root "$TMP_DIR" --passed 1 --total 1 >/dev/null 2>&1

# Satisfy Check 10: evaluation_state = ready_for_guardian (TKT-024: replaces proof_state)
HEAD_SHA=$(git -C "$TMP_DIR" rev-parse HEAD)
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$HEAD_SHA" >/dev/null 2>&1

# Satisfy Check 3 (TKT-STAB-A3): lease required for all git ops; issue one so
# the deny comes from Check 12A (no binding), not Check 3 (no lease).
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    lease issue-for-dispatch "guardian" \
    --workflow-id "$WF_ID" \
    --worktree-path "$TMP_DIR" \
    --branch "$BRANCH" \
    --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1

COMMIT_CMD="git -C \"$TMP_DIR\" commit --allow-empty -m 'test commit'"

PAYLOAD=$(jq -n \
    --arg tool_name "Bash" \
    --arg command "$COMMIT_CMD" \
    --arg cwd "$TMP_DIR" \
    '{tool_name: $tool_name, tool_input: {command: $command}, cwd: $cwd}')

# --- Phase 1: No binding → expect DENY with binding message ---
output_deny=$(printf '%s' "$PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" \
      CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" "$HOOK" 2>/dev/null) || true

decision_deny=$(printf '%s' "$output_deny" \
    | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")
reason_deny=$(printf '%s' "$output_deny" \
    | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || echo "")

if [[ "$decision_deny" != "deny" ]]; then
    echo "FAIL: $TEST_NAME — Phase 1: expected deny without binding, got decision='$decision_deny'"
    echo "  output: $output_deny"
    exit 1
fi
if ! printf '%s' "$reason_deny" | grep -qi "workflow binding\|No workflow binding\|bind workflow"; then
    echo "FAIL: $TEST_NAME — Phase 1: deny reason did not mention workflow binding"
    echo "  reason: $reason_deny"
    exit 1
fi

# --- Phase 2: Bind workflow + set scope → Check 12 should pass ---
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    workflow bind "$WF_ID" "$TMP_DIR" "$BRANCH" >/dev/null 2>&1

CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    workflow scope-set "$WF_ID" \
    --allowed '["runtime/*.py", "hooks/*.sh"]' \
    --forbidden '["settings.json"]' >/dev/null 2>&1

output_allow=$(printf '%s' "$PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" \
      CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" "$HOOK" 2>/dev/null) || {
    echo "FAIL: $TEST_NAME — Phase 2: hook exited nonzero after binding"
    exit 1
}

if [[ -n "$output_allow" ]]; then
    decision_allow=$(printf '%s' "$output_allow" \
        | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")
    if [[ "$decision_allow" == "deny" ]]; then
        reason_allow=$(printf '%s' "$output_allow" \
            | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || echo "")
        echo "FAIL: $TEST_NAME — Phase 2: unexpected deny after bind+scope"
        echo "  reason: $reason_allow"
        exit 1
    fi
fi

echo "PASS: $TEST_NAME"
exit 0
