#!/usr/bin/env bash
# pre-bash.sh — Thin adapter that delegates all Bash pre-execution policy to
# the Python policy engine (cc-policy evaluate). Replaces the former guard.sh
# delegation now that all 13 guard checks live in runtime/core/policies/.
#
# @decision DEC-HOOK-004
# @title Consolidated Bash entrypoint — now a thin cc-policy evaluate adapter
# @status accepted (updated PE-W3-fix)
# @rationale guard.sh's 13 inline checks have been migrated to Python policy
#   modules registered in runtime/core/policies/. This hook now normalises the
#   Claude hook JSON into a policy engine request and forwards the decision.
#   guard.sh and hooks/lib/bash-policy.sh are deleted — this file is the sole
#   authority for Bash pre-execution policy.
#
# Fail-closed contract (DEC-HOOK-004-FC):
#   If cc_policy evaluate fails, times out, or returns empty output this hook
#   emits a deny decision and exits 0 with the deny JSON rather than silently
#   allowing. "Fail open" is not acceptable for an enforcement hook.
#
# Fail-closed crash wrapper (DEC-HOOK-004-FC-WRAPPER — Gap 4):
#   hook-safety.sh installs an EXIT trap that detects crashes (unexpected bash
#   exit before a response is emitted) and emits a deny JSON + forces exit 0.
#   -e is removed from set flags so the wrapper controls error handling instead
#   of bash's ERR trap silently killing the hook with non-zero exit.
#
# Target-aware context (DEC-PE-W3-CTX-001):
#   Commands like ``git -C /other-repo commit`` target a different repo than
#   the session cwd. We extract the git target directory from the command and
#   pass it as ``target_cwd`` in the evaluate payload so the policy engine
#   resolves lease/scope/eval_state/test_state from the command target, not
#   the session repo. Patterns matched (same as policy_utils.extract_git_target_dir):
#     Pattern A: cd /path && git ...
#     Pattern B: git -C /path ...
# Remove -e: hook-safety.sh's EXIT trap handles unexpected exits. Without this,
# any failing subcommand exits non-zero before the trap can emit the deny JSON,
# defeating the fail-closed contract (Claude Code ignores stdout on non-zero exit).
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hooks/log.sh
source "$HOOKS_DIR/log.sh"
# shellcheck source=hooks/context-lib.sh
source "$HOOKS_DIR/context-lib.sh"
# shellcheck source=hooks/lib/hook-safety.sh
# Gap 4: fail-closed safety wrapper — installs EXIT trap, manages rt_obs_metric_batch.
# Must be sourced AFTER context-lib.sh (which defines _obs_accum, rt_obs_metric_batch).
# The wrapper replaces the standalone `trap 'rt_obs_metric_batch' EXIT` previously here.
source "$HOOKS_DIR/lib/hook-safety.sh"

# shellcheck disable=SC2329  # _hook_main is invoked indirectly via run_fail_closed
_hook_main() {
    HOOK_INPUT=$(read_input)
    COMMAND=$(get_field '.tool_input.command')
    if [[ -z "$COMMAND" ]]; then
        _mark_hook_responded
        exit 0
    fi

    # Resolve actor context for the policy engine.
    ACTOR_ROLE=$(current_active_agent_role "$(detect_project_root)" 2>/dev/null || echo "")

    # --- Target-aware context: extract git target directory from command ---
    # Pattern A: cd /path (unquoted, single-quoted, or double-quoted)
    # Pattern B: git -C /path
    # Fallback: empty string (engine will use session cwd)
    TARGET_CWD=""
    if echo "$COMMAND" | grep -qE 'cd\s+("([^"]+)"|'"'"'([^'"'"']+)'"'"'|([^\s&;]+))'; then
        _candidate=$(echo "$COMMAND" | sed -E 's/.*cd[[:space:]]+"([^"]+)".*/\1/;t end
s/.*cd[[:space:]]+'"'"'([^'"'"']+)'"'"'.*/\1/;t end
s/.*cd[[:space:]]+([^[:space:]&;]+).*/\1/;t end
d
:end' 2>/dev/null || echo "")
        if [[ -n "$_candidate" && -d "$_candidate" ]]; then
            TARGET_CWD="$_candidate"
        fi
    fi
    if [[ -z "$TARGET_CWD" ]] && echo "$COMMAND" | grep -qE 'git\s+-C\s+'; then
        _candidate=$(echo "$COMMAND" | sed -E 's/.*git[[:space:]]+-C[[:space:]]+"([^"]+)".*/\1/;t end
s/.*git[[:space:]]+-C[[:space:]]+'"'"'([^'"'"']+)'"'"'.*/\1/;t end
s/.*git[[:space:]]+-C[[:space:]]+([^[:space:]]+).*/\1/;t end
d
:end' 2>/dev/null || echo "")
        if [[ -n "$_candidate" && -d "$_candidate" ]]; then
            TARGET_CWD="$_candidate"
        fi
    fi

    # Build evaluate payload — merge actor_role, target_cwd, and hook fields.
    EVAL_INPUT=$(printf '%s' "$HOOK_INPUT" | jq \
        --arg role "$ACTOR_ROLE" \
        --arg target_cwd "$TARGET_CWD" \
        '. + {event_type: "PreToolUse", tool_name: "Bash", actor_role: $role, actor_id: "",
              target_cwd: (if $target_cwd != "" then $target_cwd else null end)}
         | if .target_cwd == null then del(.target_cwd) else . end')

    # Call policy engine — single authority for all Bash decisions.
    # Fail-closed: if the engine errors or returns empty output, emit a deny
    # rather than silently allowing. The `|| true` anti-pattern is intentionally
    # absent here.
    RESULT=$(printf '%s' "$EVAL_INPUT" | cc_policy evaluate 2>/tmp/pre-bash-eval-err$$) \
        || RESULT=""

    # Validate result: must be non-empty, have an "action" field, AND have a
    # "hookSpecificOutput" object.  Checking only ".action" was insufficient —
    # the hook would silently strip the wrapper and emit the bare inner object,
    # violating the PreToolUse stdout contract defined in hooks/HOOKS.md.
    if [[ -z "$RESULT" ]] \
        || ! printf '%s' "$RESULT" | jq -e '.action' >/dev/null 2>&1 \
        || ! printf '%s' "$RESULT" | jq -e '.hookSpecificOutput | objects' >/dev/null 2>&1; then
        # Engine failed or returned invalid/unwrapped output — emit deny (fail-closed).
        # The deny itself is wrapped in the required PreToolUse hookSpecificOutput envelope.
        # Observatory: accumulate fail-closed denial (W-OBS-2).
        _obs_accum guard_denial 1 '{"policy":"pre_bash_adapter","hook":"pre-bash"}'
        _ERR=$(cat /tmp/pre-bash-eval-err$$ 2>/dev/null || echo "cc_policy evaluate returned empty or invalid output")
        rm -f /tmp/pre-bash-eval-err$$
        printf '%s\n' "$(jq -n \
            --arg reason "Policy engine unavailable or returned invalid output. Denying as fail-safe. Detail: $_ERR" \
            '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
              permissionDecisionReason: $reason, blockingHook: "pre-bash-fail-closed"}}')"
        _mark_hook_responded
        exit 0
    fi

    rm -f /tmp/pre-bash-eval-err$$

    # Observatory: accumulate denial metric when the policy engine returned a deny (W-OBS-2).
    # Extract policy_name from the result JSON; fall back to "unknown" when absent.
    _pb_action=$(printf '%s' "$RESULT" | jq -r '.action // "allow"' 2>/dev/null || echo "allow")
    if [[ "$_pb_action" == "deny" ]]; then
        _pb_policy=$(printf '%s' "$RESULT" | jq -r '.policy_name // "unknown"' 2>/dev/null || echo "unknown")
        _obs_accum guard_denial 1 "{\"policy\":\"${_pb_policy}\",\"hook\":\"pre-bash\"}"
    fi

    # Pass through the full engine output unchanged.
    # cc_policy evaluate already emits the correct PreToolUse wrapper:
    #   { "action": "...", "hookSpecificOutput": { "permissionDecision": "...", ... } }
    # Extracting and re-printing the inner .hookSpecificOutput would strip the wrapper
    # and violate the hook contract.  Pass the full JSON — Claude Code reads the
    # top-level "hookSpecificOutput" key directly from the hook's stdout.
    printf '%s\n' "$RESULT"
}

run_fail_closed _hook_main
exit 0
