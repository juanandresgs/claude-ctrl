#!/usr/bin/env bash
# Write|Edit policy enforcement — delegates to cc-policy evaluate (PE-W2).
# PreToolUse hook — matcher: Write|Edit
#
# @decision DEC-HOOK-003
# @title Consolidated Write|Edit entrypoint — PE-W2 migration to cc-policy evaluate
# @status accepted
# @rationale PE-W2 migrates all 7 write-path checks from shell functions
#   (write-policy.sh CHECKS loop) to the Python PolicyRegistry. pre-write.sh
#   now builds an evaluate payload and pipes it to cc_policy evaluate, which
#   runs branch_guard → write_who → enforcement_gap → plan_guard → plan_exists
#   → plan_immutability → decision_log in one Python process. Shell lib files
#   write-policy.sh and plan-policy.sh are deleted; their logic lives in
#   runtime/core/policies/. The hook adapter pattern (inject actor_role into the
#   payload) was established in PE-W1 via runtime-bridge.sh cc_policy().
#
# Policy check order (first deny wins — enforced by PolicyRegistry priority):
#   100  branch_guard       — block source writes on main/master
#   200  write_who          — only implementer may write source files
#   250  enforcement_gap    — deny persistent linter gaps
#   300  plan_guard         — only planner may write governance markdown
#   400  plan_exists        — MASTER_PLAN.md must exist + staleness gate
#   500  plan_immutability  — permanent sections may not be rewritten
#   600  decision_log       — decision log entries are append-only
set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$HOOKS_DIR/log.sh"
source "$HOOKS_DIR/context-lib.sh"

# Observatory: flush any accumulated batch metrics on exit (W-OBS-2).
# Hot-path hook — use batch pattern so metric emission never adds latency to the
# deny/allow path. _obs_accum queues metrics; rt_obs_metric_batch flushes once at exit.
trap 'rt_obs_metric_batch' EXIT

HOOK_INPUT=$(read_input)
FILE_PATH=$(get_field '.tool_input.file_path')
[[ -z "$FILE_PATH" ]] && exit 0

# Resolve actor context for the policy engine.
# File-path-rooted project root (fix #468): avoid CWD-based detect_project_root()
# for the same reason branch-guard.sh and write-guard.sh resolved from file path.
_FILE_DIR=$(dirname "$FILE_PATH")
[[ ! -d "$_FILE_DIR" ]] && _FILE_DIR=$(dirname "$_FILE_DIR")
_PROJECT_ROOT=$(git -C "$_FILE_DIR" rev-parse --show-toplevel 2>/dev/null || detect_project_root)

ACTOR_ROLE=$(current_active_agent_role "$_PROJECT_ROOT" 2>/dev/null || echo "")

# Build the evaluate payload — inject event_type, tool_name, actor_role, actor_id.
# cc-policy evaluate reads JSON from stdin and returns hookSpecificOutput JSON.
EVAL_INPUT=$(printf '%s' "$HOOK_INPUT" | jq \
    --arg role "$ACTOR_ROLE" \
    --arg root "$_PROJECT_ROOT" \
    '. + {event_type: "Write", tool_name: (.tool_name // "Write"), actor_role: $role, actor_id: "", cwd: $root}')

# Call the policy engine. cc_policy is defined in runtime-bridge.sh (sourced via context-lib.sh).
#
# Fail-closed contract (DEC-HOOK-003):
#   - If cc_policy evaluate fails (non-zero exit), output is empty, or output is
#     not valid JSON with hookSpecificOutput, emit a deny payload and exit 2.
#   - Suppressing errors with "|| true" is explicitly forbidden here because this
#     is a security-critical gate: failing open allows writes that should be blocked.
# `|| true` here is intentional and safe: it prevents `set -e` from aborting
# the script before we can inspect the exit code. We capture _EVAL_EXIT on
# the same line so it always reflects cc_policy's actual exit code, then the
# validity check below enforces the fail-closed invariant explicitly.
_EVAL_EXIT=0
RESULT=$(printf '%s' "$EVAL_INPUT" | cc_policy evaluate 2>&1) || _EVAL_EXIT=$?

# Validate: exit code must be 0, output must be non-empty, and must be parseable JSON
# containing hookSpecificOutput (the Claude hook contract field).
_VALID=false
if [[ $_EVAL_EXIT -eq 0 && -n "$RESULT" ]]; then
    if printf '%s' "$RESULT" | jq -e '.hookSpecificOutput' >/dev/null 2>&1; then
        _VALID=true
    fi
fi

if [[ "$_VALID" == "false" ]]; then
    # Runtime unavailable or returned invalid output — deny the write.
    # Emitting JSON to stdout signals Claude to use hookSpecificOutput.
    # Non-zero exit (2) ensures the hook is treated as blocking.
    # Observatory: accumulate fail-closed denial (W-OBS-2).
    _obs_accum guard_denial 1 '{"policy":"pre_write_adapter","hook":"pre-write"}'
    printf '%s\n' "$(jq -n \
        --arg reason "Policy engine unavailable or returned invalid output (exit=${_EVAL_EXIT}). Write blocked by fail-closed guard." \
        '{
            "action": "deny",
            "reason": $reason,
            "policy_name": "pre_write_adapter",
            "hookSpecificOutput": {
                "permissionDecision": "deny",
                "permissionDecisionReason": $reason,
                "blockingHook": "pre_write_adapter"
            }
        }')"
    exit 2
fi

# Observatory: accumulate denial metric when the policy engine returned a deny (W-OBS-2).
# Extract policy_name from the result JSON; fall back to "unknown" when absent.
_pw_action=$(printf '%s' "$RESULT" | jq -r '.action // "allow"' 2>/dev/null || echo "allow")
if [[ "$_pw_action" == "deny" ]]; then
    _pw_policy=$(printf '%s' "$RESULT" | jq -r '.policy_name // "unknown"' 2>/dev/null || echo "unknown")
    _obs_accum guard_denial 1 "{\"policy\":\"${_pw_policy}\",\"hook\":\"pre-write\"}"
fi

printf '%s\n' "$RESULT"
exit 0
