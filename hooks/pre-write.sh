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
# Fail-closed crash wrapper (DEC-HOOK-004-FC-WRAPPER — Gap 4):
#   hook-safety.sh installs an EXIT trap that detects crashes (unexpected bash
#   exit before a response is emitted) and emits a deny JSON + forces exit 0.
#   -e is removed from set flags so the wrapper controls error handling instead
#   of bash's ERR trap silently killing the hook with non-zero exit.
#
# Policy check order (first deny wins — enforced by PolicyRegistry priority):
#   100  branch_guard       — block source writes on main/master
#   200  write_who          — only implementer may write source files
#   250  enforcement_gap    — deny persistent linter gaps
#   300  plan_guard         — only planner may write governance markdown
#   400  plan_exists        — MASTER_PLAN.md must exist + staleness gate
#   500  plan_immutability  — permanent sections may not be rewritten
#   600  decision_log       — decision log entries are append-only
# set -euo pipefail: -e is intentionally retained. hook-safety.sh's run_fail_closed
# temporarily disables -e with `set +e` around the hook function call, then restores
# it with `set -e`. This keeps the forbidden-shortcuts clause (do not remove set -e)
# while still letting the EXIT trap handle unexpected crashes in the hook function.
set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$HOOKS_DIR/log.sh"
source "$HOOKS_DIR/context-lib.sh"
# shellcheck source=hooks/lib/hook-safety.sh
# Gap 4: fail-closed safety wrapper — installs EXIT trap, manages rt_obs_metric_batch.
# Must be sourced AFTER context-lib.sh (which defines _obs_accum, rt_obs_metric_batch).
# The wrapper replaces the standalone `trap 'rt_obs_metric_batch' EXIT` previously here.
source "$HOOKS_DIR/lib/hook-safety.sh"

# shellcheck disable=SC2329  # _hook_main is invoked indirectly via run_fail_closed
_hook_main() {
    HOOK_INPUT=$(read_input)
    FILE_PATH=$(get_field '.tool_input.file_path')
    if [[ -z "$FILE_PATH" ]]; then
        _mark_hook_responded
        exit 0
    fi

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
    #     not valid JSON with hookSpecificOutput, emit a deny payload and exit 0.
    #   - Suppressing errors with "|| true" is explicitly forbidden here because this
    #     is a security-critical gate: failing open allows writes that should be blocked.
    # `|| true` here is intentional and safe: it prevents the hook from exiting before
    # we can inspect the exit code. We capture _EVAL_EXIT on the same line so it always
    # reflects cc_policy's actual exit code, then the validity check below enforces the
    # fail-closed invariant explicitly.
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
        _mark_hook_responded
        exit 0
    fi

    # Observatory: accumulate denial metric when the policy engine returned a deny (W-OBS-2).
    # Extract policy_name from the result JSON; fall back to "unknown" when absent.
    _pw_action=$(printf '%s' "$RESULT" | jq -r '.action // "allow"' 2>/dev/null || echo "allow")
    if [[ "$_pw_action" == "deny" ]]; then
        _pw_policy=$(printf '%s' "$RESULT" | jq -r '.policy_name // "unknown"' 2>/dev/null || echo "unknown")
        _obs_accum guard_denial 1 "{\"policy\":\"${_pw_policy}\",\"hook\":\"pre-write\"}"
    fi

    printf '%s\n' "$RESULT"
}

run_fail_closed _hook_main
exit 0
