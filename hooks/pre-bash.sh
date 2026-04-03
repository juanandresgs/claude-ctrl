#!/usr/bin/env bash
# pre-bash.sh — Thin adapter that delegates all Bash pre-execution policy to
# the Python policy engine (cc-policy evaluate). Replaces the former guard.sh
# delegation now that all 13 guard checks live in runtime/core/policies/.
#
# @decision DEC-HOOK-004
# @title Consolidated Bash entrypoint — now a thin cc-policy evaluate adapter
# @status accepted (updated PE-W3)
# @rationale guard.sh's 13 inline checks have been migrated to Python policy
#   modules registered in runtime/core/policies/. This hook now normalises the
#   Claude hook JSON into a policy engine request and forwards the decision.
#   guard.sh and hooks/lib/bash-policy.sh are deleted — this file is the sole
#   authority for Bash pre-execution policy.
set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hooks/log.sh
source "$HOOKS_DIR/log.sh"
# shellcheck source=hooks/context-lib.sh
source "$HOOKS_DIR/context-lib.sh"

HOOK_INPUT=$(read_input)
COMMAND=$(get_field '.tool_input.command')
[[ -z "$COMMAND" ]] && exit 0

# Resolve actor context for the policy engine.
ACTOR_ROLE=$(current_active_agent_role "$(detect_project_root)" 2>/dev/null || echo "")

# Build evaluate payload — merge actor_role into the hook JSON.
EVAL_INPUT=$(printf '%s' "$HOOK_INPUT" | jq \
    --arg role "$ACTOR_ROLE" \
    '. + {event_type: "PreToolUse", tool_name: "Bash", actor_role: $role, actor_id: ""}')

# Call policy engine — single authority for all Bash decisions.
RESULT=$(printf '%s' "$EVAL_INPUT" | cc_policy evaluate 2>/dev/null || true)

if [[ -n "$RESULT" ]]; then
    echo "$RESULT"
fi

exit 0
