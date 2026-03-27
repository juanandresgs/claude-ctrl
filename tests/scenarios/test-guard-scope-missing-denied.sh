#!/usr/bin/env bash
# test-guard-scope-missing-denied.sh: verifies guard.sh Check 12B denies commit
# when binding exists but scope manifest is absent, then allows after scope is set.
#
# Production sequence: binding registered (subagent-start.sh) but planner has not
# yet called scope-set → guard.sh Check 12B fires → deny with scope-set guidance.
# After planner writes scope → commit allowed at Check 12 level.
#
# Gates exercised:
#   Check 3: WHO — guardian role (satisfied)
#   Check 9: test-status = pass (satisfied)
#   Check 10: proof verified (satisfied via runtime SQLite)
#   Check 12A: workflow binding present (satisfied — binding written before test)
#   Check 12B: scope must exist → deny (no scope), allow (after scope-set)
#
# @decision DEC-SMOKE-WF-004
# @title Guard Check 12B denies commit without scope, allows after scope-set
# @status accepted
# @rationale Having a binding without a scope means the authorized file set is
#   unknown. This is distinct from having no binding at all (Check 12A). The
#   two sub-checks fire in order: binding absence → deny before scope is checked.
#   This test exercises the second sub-check independently, confirming binding
#   alone is not sufficient to pass Check 12.
set -euo pipefail

TEST_NAME="test-guard-scope-missing-denied"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/guard.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/.claude/state.db"
BRANCH="feature/wf-scope-missing"
WF_ID="feature-wf-scope-missing"  # sanitize_token replaces / with -

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
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian" >/dev/null 2>&1

# Satisfy Check 9: test-status = pass
echo "pass|0|$(date +%s)" > "$TMP_DIR/.claude/.test-status"

# Satisfy Check 10: proof-of-work = verified (runtime only — flat file ignored since TKT-008)
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" proof set "$WF_ID" "verified" >/dev/null 2>&1

# Satisfy Check 12A: write binding (no scope yet)
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    workflow bind "$WF_ID" "$TMP_DIR" "$BRANCH" >/dev/null 2>&1

COMMIT_CMD="git -C \"$TMP_DIR\" commit --allow-empty -m 'test commit'"

PAYLOAD=$(jq -n \
    --arg tool_name "Bash" \
    --arg command "$COMMIT_CMD" \
    --arg cwd "$TMP_DIR" \
    '{tool_name: $tool_name, tool_input: {command: $command}, cwd: $cwd}')

# --- Phase 1: Binding present but no scope → expect DENY with scope message ---
output_deny=$(printf '%s' "$PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" \
      CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" "$HOOK" 2>/dev/null) || true

decision_deny=$(printf '%s' "$output_deny" \
    | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")
reason_deny=$(printf '%s' "$output_deny" \
    | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || echo "")

if [[ "$decision_deny" != "deny" ]]; then
    echo "FAIL: $TEST_NAME — Phase 1: expected deny without scope, got decision='$decision_deny'"
    echo "  output: $output_deny"
    exit 1
fi
if ! printf '%s' "$reason_deny" | grep -qi "scope\|scope-set\|scope manifest"; then
    echo "FAIL: $TEST_NAME — Phase 1: deny reason did not mention scope"
    echo "  reason: $reason_deny"
    exit 1
fi

# --- Phase 2: Set scope → Check 12 should pass ---
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    workflow scope-set "$WF_ID" \
    --allowed '["runtime/*.py", "hooks/*.sh", "tests/scenarios/*.sh"]' \
    --forbidden '["settings.json"]' >/dev/null 2>&1

output_allow=$(printf '%s' "$PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" \
      CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" "$HOOK" 2>/dev/null) || {
    echo "FAIL: $TEST_NAME — Phase 2: hook exited nonzero after scope-set"
    exit 1
}

if [[ -n "$output_allow" ]]; then
    decision_allow=$(printf '%s' "$output_allow" \
        | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")
    if [[ "$decision_allow" == "deny" ]]; then
        reason_allow=$(printf '%s' "$output_allow" \
            | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || echo "")
        echo "FAIL: $TEST_NAME — Phase 2: unexpected deny after scope-set"
        echo "  reason: $reason_allow"
        exit 1
    fi
fi

echo "PASS: $TEST_NAME"
exit 0
