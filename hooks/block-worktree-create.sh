#!/usr/bin/env bash
# block-worktree-create.sh — adapter for harness-managed worktree events.
#
# The runtime policy is worktree_harness_guard. This hook exists because
# WorktreeCreate/EnterWorktree are harness-native events, not Bash commands.
set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$HOOKS_DIR/log.sh"
source "$HOOKS_DIR/context-lib.sh"
source "$HOOKS_DIR/lib/hook-safety.sh"

_deny_json() {
    local event_name="${1:-PreToolUse}"
    local reason="${2:-Worktree guard failed closed.}"
    if [[ "$event_name" != "PreToolUse" ]]; then
        jq -n \
            --arg reason "$reason" \
            '{
              decision: "block",
              reason: $reason
            }'
        return
    fi
    jq -n \
        --arg event "$event_name" \
        --arg reason "$reason" \
        '{
          action: "deny",
          reason: $reason,
          policy_name: "worktree_harness_guard",
          hookSpecificOutput: {
            hookEventName: $event,
            permissionDecision: "deny",
            permissionDecisionReason: $reason,
            blockingHook: "block-worktree-create.sh"
          }
        }'
}

_hook_main() {
    local hook_input event_name tool_name cwd eval_input result eval_exit output_event decision reason
    hook_input=$(cat 2>/dev/null || echo "")
    if [[ -z "$hook_input" ]] || ! printf '%s' "$hook_input" | jq -e . >/dev/null 2>&1; then
        _deny_json "WorktreeCreate" "BLOCKED: block-worktree-create.sh received malformed input. Worktree creation/entry fails closed."
        _mark_hook_responded
        exit 0
    fi

    event_name=$(printf '%s' "$hook_input" | jq -r '.hook_event_name // .hookEventName // .event_name // "WorktreeCreate"' 2>/dev/null || echo "WorktreeCreate")
    tool_name=$(printf '%s' "$hook_input" | jq -r --arg event "$event_name" '.tool_name // .toolName // $event' 2>/dev/null || echo "$event_name")
    cwd=$(printf '%s' "$hook_input" | jq -r '.cwd // .workspace.current_dir // empty' 2>/dev/null || echo "")
    output_event="$event_name"
    [[ "$event_name" == "PreToolUse" && "$tool_name" == "EnterWorktree" ]] && output_event="PreToolUse"

    eval_input=$(printf '%s' "$hook_input" | jq \
        --arg event "$event_name" \
        --arg tool "$tool_name" \
        --arg cwd "$cwd" \
        '. + {event_type: $event, tool_name: $tool, actor_role: "", actor_id: "", cwd: $cwd}')

    eval_exit=0
    result=$(printf '%s' "$eval_input" | cc_policy evaluate 2>&1) || eval_exit=$?
    if [[ $eval_exit -ne 0 || -z "$result" ]] \
        || ! printf '%s' "$result" | jq -e '.hookSpecificOutput | objects' >/dev/null 2>&1; then
        _obs_accum guard_denial 1 '{"policy":"worktree_harness_guard","hook":"block-worktree-create"}'
        _deny_json "$output_event" "BLOCKED: policy engine unavailable or invalid for worktree guard. Worktree creation/entry fails closed."
        _mark_hook_responded
        exit 0
    fi

    if [[ "$output_event" != "PreToolUse" ]]; then
        decision=$(printf '%s' "$result" | jq -r '.action // .hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")
        reason=$(printf '%s' "$result" | jq -r '.reason // .hookSpecificOutput.permissionDecisionReason // "Harness-managed worktree creation/entry bypasses Guardian worktree authority."' 2>/dev/null || echo "")
        if [[ "$decision" == "deny" ]]; then
            _deny_json "$output_event" "$reason"
        else
            jq -n '{decision: "approve"}'
        fi
    else
        printf '%s\n' "$result"
    fi
    _mark_hook_responded
}

run_fail_closed _hook_main
exit 0
