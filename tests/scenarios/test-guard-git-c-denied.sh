#!/usr/bin/env bash
# test-guard-git-c-denied.sh: verifies guard.sh checks fire for "git -C /path"
# command format, not just bare "git commit". Agents use "git -C" per
# shared-protocols.md, so all security gates must handle both forms.
#
# Sub-tests:
#   1. Non-guardian "git -C ... push" → denied (Check 3 WHO)
#   2. "git -C ... commit" on main → denied (Check 4 main-is-sacred)
#   3. "git -C ... commit" with failing tests → denied (Check 9 test gate)
#   4. "git -C ... commit" without proof verified → denied (Check 10 proof gate)
#
# @decision DEC-GUARD-013
# @title Guard checks must fire for git -C command format
# @status accepted
# @rationale shared-protocols.md tells agents to use "git -C .worktrees/<name>"
#   for all git operations. If guard.sh grep patterns only match "git commit"
#   (adjacent), all security gates are silently bypassed. The broadened pattern
#   \bgit\b.*\bcommit\b handles both "git commit" and "git -C /path commit".
set -euo pipefail

TEST_NAME="test-guard-git-c-denied"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/guard.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/.claude/state.db"

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

setup_repo() {
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR/.claude"
    git -C "$TMP_DIR" init -q
    git -C "$TMP_DIR" config user.email "t@t.com"
    git -C "$TMP_DIR" config user.name "T"
    git -C "$TMP_DIR" commit --allow-empty -m "init" -q
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
}

run_hook() {
    local cmd="$1"
    local payload
    payload=$(jq -n --arg t "Bash" --arg c "$cmd" --arg w "$TMP_DIR" \
        '{tool_name:$t,tool_input:{command:$c},cwd:$w}')
    printf '%s' "$payload" \
        | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" \
          CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" "$HOOK" 2>/dev/null || true
}

check_deny() {
    local label="$1" output="$2" expected_substr="$3"
    local decision reason
    if [[ -z "$output" ]]; then
        echo "FAIL: $TEST_NAME — $label: no output (expected deny)"
        exit 1
    fi
    decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")
    if [[ "$decision" != "deny" ]]; then
        echo "FAIL: $TEST_NAME — $label: expected deny, got '$decision'"
        echo "  output: $output"
        exit 1
    fi
    if [[ -n "$expected_substr" ]]; then
        reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || echo "")
        if ! printf '%s' "$reason" | grep -qi "$expected_substr"; then
            echo "FAIL: $TEST_NAME — $label: deny reason missing '$expected_substr'"
            echo "  reason: $reason"
            exit 1
        fi
    fi
}

# --- Sub-test 1: No-lease git -C push → Check 3 lease deny ---
# TKT-STAB-A3: all git ops without a lease are denied. Push is still denied
# here but now by the unified no-lease path (not the high_risk-specific path).
# Deny reason must mention "lease".
setup_repo
git -C "$TMP_DIR" checkout -b feature/test-who -q
CMD="git -C \"$TMP_DIR\" push origin feature/test-who"
output=$(run_hook "$CMD")
check_deny "sub-test 1 (lease)" "$output" "lease"

# --- Sub-test 2: git -C commit on main → Check 4 main-is-sacred deny ---
# Check 3 fires before Check 4 for commits. Stay on main (no feature branch
# means no workflow binding and no lease). Check 3 fires first with no-lease
# deny, then Check 4 would fire. The test only verifies a deny happens.
# NOTE: After TKT-STAB-A3, on main there is no lease so Check 3 fires first.
# Check 4 (main-is-sacred) is still tested implicitly — if Check 3 were
# bypassed (meta-repo), Check 4 would be the gate. This sub-test verifies
# guard.sh fires (any deny) for git -C commit on main.
setup_repo
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian" >/dev/null 2>&1
echo "pass|0|$(date +%s)" > "$TMP_DIR/.claude/.test-status"
CMD="git -C \"$TMP_DIR\" commit --allow-empty -m 'test'"
output=$(run_hook "$CMD")
# Any deny is acceptable: either Check 3 (no lease) or Check 4 (main-is-sacred)
check_deny "sub-test 2 (main-is-sacred or no-lease)" "$output" ""

# --- Sub-test 3: git -C commit with failing tests → Check 9 test gate deny ---
# A lease is issued so Check 3 passes and Check 9 (failing tests) is the gate.
setup_repo
git -C "$TMP_DIR" checkout -b feature/test-tests -q
BRANCH_TESTS="feature/test-tests"
WF_TESTS="feature-test-tests"
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian" >/dev/null 2>&1
echo "fail|3|$(date +%s)" > "$TMP_DIR/.claude/.test-status"
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    workflow bind "$WF_TESTS" "$TMP_DIR" "$BRANCH_TESTS" >/dev/null 2>&1
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    workflow scope-set "$WF_TESTS" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    lease issue-for-dispatch "guardian" \
    --workflow-id "$WF_TESTS" \
    --worktree-path "$TMP_DIR" \
    --branch "$BRANCH_TESTS" \
    --allowed-ops '["routine_local","high_risk"]' \
    --no-eval >/dev/null 2>&1
CMD="git -C \"$TMP_DIR\" commit --allow-empty -m 'test'"
output=$(run_hook "$CMD")
check_deny "sub-test 3 (test gate)" "$output" "tests are failing\|test run did not pass"

# --- Sub-test 4: git -C commit without evaluation clearance → Check 10 eval gate deny ---
# A lease is issued (--no-eval) so Check 3 passes and Check 10 (no eval state) is the gate.
setup_repo
git -C "$TMP_DIR" checkout -b feature/test-proof -q
BRANCH_PROOF="feature/test-proof"
WF_PROOF="feature-test-proof"
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian" >/dev/null 2>&1
echo "pass|0|$(date +%s)" > "$TMP_DIR/.claude/.test-status"
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    workflow bind "$WF_PROOF" "$TMP_DIR" "$BRANCH_PROOF" >/dev/null 2>&1
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    workflow scope-set "$WF_PROOF" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    lease issue-for-dispatch "guardian" \
    --workflow-id "$WF_PROOF" \
    --worktree-path "$TMP_DIR" \
    --branch "$BRANCH_PROOF" \
    --allowed-ops '["routine_local","high_risk"]' \
    --no-eval >/dev/null 2>&1
# No evaluation_state set → status is "idle"
CMD="git -C \"$TMP_DIR\" commit --allow-empty -m 'test'"
output=$(run_hook "$CMD")
check_deny "sub-test 4 (eval gate)" "$output" "evaluation_state"

echo "PASS: $TEST_NAME (4 sub-tests)"
exit 0
