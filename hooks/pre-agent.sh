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
source "$(dirname "$0")/context-lib.sh"

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

# Extract tool_name and launch fields
TOOL_NAME=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
ISOLATION=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.isolation // empty' 2>/dev/null || echo "")
SUBAGENT_TYPE=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || echo "")
PROMPT=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.prompt // empty' 2>/dev/null || echo "")
SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
AGENT_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.agent_id // empty' 2>/dev/null || echo "")
TOOL_USE_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_use_id // .toolUseId // empty' 2>/dev/null || echo "")
_HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
_LOCAL_RUNTIME_CLI="$_HOOK_DIR/../runtime/cli.py"
_local_cc_policy() {
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -z "${CLAUDE_POLICY_DB:-}" ]]; then
    export CLAUDE_POLICY_DB="$CLAUDE_PROJECT_DIR/.claude/state.db"
  fi
  python3 "$_LOCAL_RUNTIME_CLI" "$@"
}

# Only guard the Agent/Task tool; other tools pass through unchanged.
# Empirical capture on 2026-04-07 confirmed `Agent` is the tool_name in this
# Claude Code version (~/.claude/runtime/dispatch-debug.jsonl). `Task` is
# accepted defensively in case the harness ever renames or earlier/later
# versions emit a different name — costs nothing and prevents silent no-op.
if [[ "$TOOL_NAME" != "Agent" && "$TOOL_NAME" != "Task" ]]; then
    exit 0
fi

# Deny: Agent(isolation:"worktree") bypasses Guardian worktree authority.
if [[ "$ISOLATION" == "worktree" ]]; then
cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "blockingHook": "pre-agent.sh",
    "permissionDecisionReason": "BLOCKED: Agent(isolation:\"worktree\") creates unmanaged worktrees in /tmp via the harness, bypassing Guardian worktree authority (no lease, no workflow binding, no scope manifest). Use the v6 capability sequence instead: launch Guardian naturally with provisioning capability; Guardian runs `cc-policy worktree provision` and reports the leased .worktrees/feature-<name> path; then launch implementer as an ordinary Agent with no isolation flag."
  }
}
EOF
exit 0
fi

# v6 canonical dispatch seats bind to the runtime launch ledger when possible.
# Missing or malformed prompt claims are not authorization failures; SubagentStart
# can repair context from launch metadata or natural role/workflow state.
case "$SUBAGENT_TYPE" in
  planner|implementer|critic|reviewer|guardian)
    PROJECT_ROOT=$(detect_project_root 2>/dev/null || echo "${CLAUDE_PROJECT_DIR:-$PWD}")
    WF_ID=$(current_workflow_id "$PROJECT_ROOT" 2>/dev/null || echo "default")
    printf '%s' "$PROMPT" | _local_cc_policy stage launch-claim \
      --subagent-type "$SUBAGENT_TYPE" \
      --workflow-id "$WF_ID" \
      --worktree-path "$PROJECT_ROOT" \
      ${SESSION_ID:+--session-id "$SESSION_ID"} \
      ${AGENT_ID:+--agent-id "$AGENT_ID"} \
      ${TOOL_USE_ID:+--launch-tool-id "$TOOL_USE_ID"} \
      --stdin >/dev/null 2>&1 || true
    exit 0
    ;;
esac

exit 0
