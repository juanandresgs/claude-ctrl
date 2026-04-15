#!/usr/bin/env bash
# test-agent-spawn.sh: feeds synthetic SubagentStart JSON for each known agent
# type to subagent-start.sh, verifies additionalContext is present in output.
#
# @decision DEC-SMOKE-002
# @title Test all named agent types produce additionalContext on spawn
# @status accepted
# @rationale The subagent-start.sh hook injects role-specific guidance into
# every spawned agent. If a named role produces no additionalContext the agent
# starts without governance instructions. This test validates each role case
# in the switch statement: planner, Plan, implementer, guardian, reviewer.
# Lightweight roles (Bash, Explore) only verify exit 0 — they intentionally
# produce no output per the hook's design.
set -euo pipefail

TEST_NAME="test-agent-spawn"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/subagent-start.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"
git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" commit --allow-empty -m "init" -q
echo "# MASTER_PLAN.md" > "$TMP_DIR/MASTER_PLAN.md"

# Agent types that must produce additionalContext (named roles)
NAMED_ROLES=("planner" "Plan" "implementer" "guardian" "reviewer")
# Lightweight types — hook exits 0 but output may be empty
LIGHT_ROLES=("Bash" "Explore")

FAILURES=0

check_named_role() {
    local agent_type="$1"
    local payload
    payload=$(printf '{"agent_type":"%s"}' "$agent_type")

    local output
    output=$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" 2>/dev/null) || {
        echo "  FAIL: agent_type=$agent_type — hook exited nonzero"
        return 1
    }

    if [[ -z "$output" ]]; then
        echo "  FAIL: agent_type=$agent_type — no output (expected additionalContext)"
        return 1
    fi

    if ! echo "$output" | jq '.' >/dev/null 2>&1; then
        echo "  FAIL: agent_type=$agent_type — output is not valid JSON"
        return 1
    fi

    local ctx
    ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
    if [[ -z "$ctx" ]]; then
        echo "  FAIL: agent_type=$agent_type — additionalContext missing or empty"
        return 1
    fi

    return 0
}

check_light_role() {
    local agent_type="$1"
    local payload
    payload=$(printf '{"agent_type":"%s"}' "$agent_type")

    printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$TMP_DIR" "$HOOK" 2>/dev/null || {
        echo "  FAIL: agent_type=$agent_type — hook exited nonzero"
        return 1
    }
    return 0
}

for role in "${NAMED_ROLES[@]}"; do
    if ! check_named_role "$role"; then
        FAILURES=$((FAILURES + 1))
    fi
done

for role in "${LIGHT_ROLES[@]}"; do
    if ! check_light_role "$role"; then
        FAILURES=$((FAILURES + 1))
    fi
done

if [[ "$FAILURES" -gt 0 ]]; then
    echo "FAIL: $TEST_NAME — $FAILURES agent type(s) failed"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
