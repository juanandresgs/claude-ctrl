#!/usr/bin/env bash
# pre-agent.sh — Agent/Task PreToolUse adapter.
#
# This hook is transport-only. It normalizes the Claude hook payload, resolves
# the project policy DB path for carrier writes, and delegates all Agent launch
# decisions to ``cc-policy evaluate``. Runtime policy owns:
#   - Agent(isolation:"worktree") denial
#   - canonical subagent contract requirement
#   - six-field contract shape validation
#   - stage -> subagent_type validation
#
# After a policy allow, ``cc-policy evaluate`` writes the pending Agent request
# carrier row for canonical contract-bearing launches. Shell must not duplicate
# contract parsing or stage tables.

set -euo pipefail

_HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hooks/log.sh
source "$_HOOK_DIR/log.sh"
# shellcheck source=hooks/lib/runtime-bridge.sh
source "$_HOOK_DIR/lib/runtime-bridge.sh"

_deny() {
    local reason="$1"
    jq -n \
        --arg reason "$reason" \
        '{
          "action": "deny",
          "reason": $reason,
          "policy_name": "pre_agent_adapter",
          "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": $reason,
            "blockingHook": "pre_agent_adapter"
          }
        }'
    exit 0
}

HOOK_INPUT=$(cat 2>/dev/null || echo "")
if [[ -z "$HOOK_INPUT" ]] || ! printf '%s' "$HOOK_INPUT" | jq -e . >/dev/null 2>&1; then
    _deny "Policy engine unavailable or received malformed Agent hook input. Denying as fail-safe."
fi

TOOL_NAME=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
if [[ "$TOOL_NAME" != "Agent" && "$TOOL_NAME" != "Task" ]]; then
    exit 0
fi

_CARRIER_DB="$(_resolve_policy_db 2>/dev/null || true)"
_CARRIER_DB_RESOLVED=false
if [[ -n "$_CARRIER_DB" ]]; then
    _CARRIER_DB_RESOLVED=true
fi

_LOCAL_RUNTIME_ROOT="$_HOOK_DIR/../runtime"
EVAL_INPUT=$(printf '%s' "$HOOK_INPUT" | jq \
    --argjson carrier_db_resolved "$_CARRIER_DB_RESOLVED" \
    '. + {
        event_type: "PreToolUse",
        tool_name: (.tool_name // "Agent"),
        actor_role: "",
        actor_id: "",
        carrier_db_resolved: $carrier_db_resolved
    }')

_EVAL_EXIT=0
RESULT=$(printf '%s' "$EVAL_INPUT" | cc_policy_local_runtime "$_LOCAL_RUNTIME_ROOT" evaluate 2>/tmp/pre-agent-eval-err$$) \
    || _EVAL_EXIT=$?

if [[ $_EVAL_EXIT -ne 0 ]] \
    || [[ -z "$RESULT" ]] \
    || ! printf '%s' "$RESULT" | jq -e '.hookSpecificOutput | objects' >/dev/null 2>&1; then
    _ERR=$(cat /tmp/pre-agent-eval-err$$ 2>/dev/null || echo "cc_policy evaluate returned empty or invalid output")
    rm -f /tmp/pre-agent-eval-err$$
    _deny "Policy engine unavailable or returned invalid output (exit=${_EVAL_EXIT}). Agent launch blocked by fail-closed guard. Detail: $_ERR"
fi

rm -f /tmp/pre-agent-eval-err$$
printf '%s\n' "$RESULT"
exit 0
