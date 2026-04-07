#!/usr/bin/env bash
# pre-agent.sh — Agent tool PreToolUse guard.
#
# Denies Agent tool invocations that request harness-managed worktree
# isolation (`isolation: "worktree"`). Guardian is the sole worktree
# lifecycle authority; harness-created worktrees in /tmp bypass:
#   - Guardian lease at PROJECT_ROOT
#   - Implementer lease at worktree_path
#   - Workflow binding
#   - Scope manifest
# Allowing them silently produces dispatch chains where the implementer
# subagent runs with no lease, no scope, and no policy enforcement.
#
# @decision DEC-PREAGENT-001
# @title pre-agent.sh blocks Agent(isolation:"worktree") (ENFORCE-RCA-8 / #29)
# @status accepted
# @rationale bash_worktree_creation (priority 350) catches `git worktree add`
#   from the Bash tool, but does NOT fire for harness-managed worktree creation
#   via the Agent tool's `isolation` parameter. The harness creates the
#   worktree in /tmp outside pre-bash.sh's reach. Debug capture on 2026-04-07
#   confirmed the Agent tool's matcher name is `Agent` and that
#   `tool_input.isolation` (when set) is exposed to PreToolUse hooks. This
#   hook denies at that boundary so the only sanctioned worktree creation
#   path remains `cc-policy worktree provision` executed by Guardian.
#
# Fails closed on malformed input: if jq cannot parse the hook input, deny.

set -euo pipefail

source "$(dirname "$0")/log.sh"

# Read hook input from stdin
HOOK_INPUT=$(cat 2>/dev/null || echo "")

# If input is empty or not JSON, fail closed
if [[ -z "$HOOK_INPUT" ]] || ! printf '%s' "$HOOK_INPUT" | jq -e . >/dev/null 2>&1; then
    cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "blockingHook": "pre-agent.sh",
    "permissionDecisionReason": "BLOCKED: pre-agent.sh received malformed input. Fail-closed guard."
  }
}
EOF
    exit 0
fi

# Extract tool_name and tool_input.isolation
TOOL_NAME=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
ISOLATION=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.isolation // empty' 2>/dev/null || echo "")

# Only guard the Agent/Task tool; other tools pass through unchanged.
# Empirical capture on 2026-04-07 confirmed `Agent` is the tool_name in this
# Claude Code version (~/.claude/runtime/dispatch-debug.jsonl). `Task` is
# accepted defensively in case the harness ever renames or earlier/later
# versions emit a different name — costs nothing and prevents silent no-op.
if [[ "$TOOL_NAME" != "Agent" && "$TOOL_NAME" != "Task" ]]; then
    exit 0
fi

# Allow Agent calls without isolation=worktree (the common case).
if [[ "$ISOLATION" != "worktree" ]]; then
    exit 0
fi

# Deny: Agent(isolation:"worktree") bypasses Guardian worktree authority.
cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "blockingHook": "pre-agent.sh",
    "permissionDecisionReason": "BLOCKED: Agent(isolation:\"worktree\") creates worktrees in /tmp via the harness, bypassing Guardian worktree authority (no lease, no workflow binding, no scope manifest). Use the dispatch chain instead: planner → guardian(provision) → implementer. Guardian runs `cc-policy worktree provision` to create a properly-leased worktree under .worktrees/feature-<name>."
  }
}
EOF
exit 0
