#!/usr/bin/env bash
# test-git-allow-guardian-meta-repo.sh: verifies that guard.sh allows a git
# commit in the ~/.claude meta-repo without proof-of-work, test status, or
# workflow binding — consistent with the is_claude_meta_repo() exemptions at:
#   guard.sh Check 4  (line 150): main-is-sacred bypassed
#   guard.sh Check 9  (line 232): test-status gate bypassed
#   guard.sh Check 10 (line 260): proof-of-work gate bypassed
#   guard.sh Check 12 (line 313): workflow binding bypassed
#
# Guardian role (Check 3/WHO) still applies — meta-repo is not exempt from WHO.
#
# Regression for: issue #143 (pre-bash.sh gap) and issue #144 (tester/guardian
# agent-level proof check). This test validates the hook layer is correct;
# issue #143 tracks the pre-bash.sh gap that sits upstream of guard.sh.
#
# @decision DEC-SMOKE-META-001
# @title Meta-repo commit must not require proof, test status, or branch
# @status accepted
# @rationale ~/.claude is configuration infrastructure, not a feature project.
#   Proof-of-work and test gates apply to project repos. is_claude_meta_repo()
#   reflects this in guard.sh; Guardian agent prompt must match (agents/guardian.md).
set -euo pipefail

TEST_NAME="test-git-allow-guardian-meta-repo"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/guard.sh"
# Repo path must end in /.claude for is_claude_meta_repo() to return true
TMP_DIR="$(mktemp -d)/.claude"

cleanup() { rm -rf "$(dirname "$TMP_DIR")"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" -c user.email="t@t.com" -c user.name="T" \
    commit --allow-empty -m "init" -q
# Stay on main — Check 4 (main-is-sacred) must be bypassed for meta-repo

# Gate: Guardian role active (Check 3/WHO still applies to meta-repo)
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" python3 "$REPO_ROOT/runtime/cli.py" \
    schema ensure >/dev/null 2>&1
CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" python3 "$REPO_ROOT/runtime/cli.py" \
    marker set "agent-test" "guardian" >/dev/null 2>&1

# Intentionally omit: proof-of-work, test status, workflow binding
# These are all bypassed by is_claude_meta_repo() for repos ending in /.claude

PAYLOAD=$(jq -n \
    --arg tool_name "Bash" \
    --arg command "git -C \"$TMP_DIR\" commit --allow-empty -m 'meta-repo config change'" \
    --arg cwd "$TMP_DIR" \
    '{tool_name: $tool_name, tool_input: {command: $command}, cwd: $cwd}')

output=$(printf '%s' "$PAYLOAD" \
    | CLAUDE_PROJECT_DIR="$TMP_DIR" \
      CLAUDE_POLICY_DB="$TMP_DIR/.claude/state.db" \
      CLAUDE_RUNTIME_ROOT="$REPO_ROOT/runtime" \
      "$HOOK" 2>/dev/null) || {
    echo "FAIL: $TEST_NAME — hook exited nonzero (meta-repo commit should not be denied)"
    exit 1
}

# Allow = empty output or JSON without permissionDecision: deny
if [[ -n "$output" ]]; then
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    if [[ "$decision" == "deny" ]]; then
        reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
        echo "FAIL: $TEST_NAME — unexpected deny for meta-repo commit"
        echo "  reason: $reason"
        echo "  expected: is_claude_meta_repo() should bypass proof/test/branch checks"
        exit 1
    fi
fi

echo "PASS: $TEST_NAME"
exit 0
