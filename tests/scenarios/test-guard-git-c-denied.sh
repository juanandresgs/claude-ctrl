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

# --- Sub-test 1: Non-guardian git -C push → Check 3 WHO deny ---
# After DEC-GUARD-003, routine local ops (commit, merge) skip WHO enforcement.
# Push is high_risk and still requires Guardian role.
setup_repo
git -C "$TMP_DIR" checkout -b feature/test-who -q
# No marker set → role is empty (non-guardian)
CMD="git -C \"$TMP_DIR\" push origin feature/test-who"
output=$(run_hook "$CMD")
check_deny "sub-test 1 (WHO)" "$output" "Guardian"

# --- Sub-test 2: git -C commit on main → Check 4 main-is-sacred deny ---
setup_repo
# Stay on main, set guardian role
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian" >/dev/null 2>&1
echo "pass|0|$(date +%s)" > "$TMP_DIR/.claude/.test-status"
CMD="git -C \"$TMP_DIR\" commit --allow-empty -m 'test'"
output=$(run_hook "$CMD")
check_deny "sub-test 2 (main-is-sacred)" "$output" "Sacred Practice\|Cannot commit directly to main"

# --- Sub-test 3: git -C commit with failing tests → Check 9 test gate deny ---
setup_repo
git -C "$TMP_DIR" checkout -b feature/test-tests -q
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian" >/dev/null 2>&1
echo "fail|3|$(date +%s)" > "$TMP_DIR/.claude/.test-status"
CMD="git -C \"$TMP_DIR\" commit --allow-empty -m 'test'"
output=$(run_hook "$CMD")
check_deny "sub-test 3 (test gate)" "$output" "tests are failing\|test run did not pass"

# --- Sub-test 4: git -C commit without evaluation clearance → Check 10 eval gate deny ---
setup_repo
git -C "$TMP_DIR" checkout -b feature/test-proof -q
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian" >/dev/null 2>&1
echo "pass|0|$(date +%s)" > "$TMP_DIR/.claude/.test-status"
# No evaluation_state set → status is "idle"
CMD="git -C \"$TMP_DIR\" commit --allow-empty -m 'test'"
output=$(run_hook "$CMD")
check_deny "sub-test 4 (eval gate)" "$output" "evaluation_state"

echo "PASS: $TEST_NAME (4 sub-tests)"
exit 0
