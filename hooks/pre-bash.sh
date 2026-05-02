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
#   Hooks no longer parse git target directories themselves. This adapter
#   forwards the raw command text and the runtime derives structured
#   BashCommandIntent once during cc-policy evaluate. That runtime-owned
#   intent resolves lease/scope/eval_state/test_state against the command
#   target repo, not the session repo.
# set -euo pipefail: -e is intentionally retained. hook-safety.sh's run_fail_closed
# temporarily disables -e with `set +e` around the hook function call, then restores
# it with `set -e`. This keeps the forbidden-shortcuts clause (do not remove set -e)
# while still letting the EXIT trap handle unexpected crashes in the hook function.
set -euo pipefail

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

_policy_db_for_project_dir() {
    # Bootstrap-only DB comparison: this runs before cc_policy evaluate can
    # safely open state.db, and exists only to decide whether an inherited
    # CLAUDE_PROJECT_DIR points at the same DB authority as the envelope target.
    # Enforcement semantics remain in runtime/core/hook_envelope.py and
    # runtime/core/policies/.
    local project_dir="${1:-}"
    [[ -n "$project_dir" && -d "$project_dir" ]] || return 0
    "$(_resolve_runtime_python)" - "$HOOKS_DIR/.." "$project_dir" <<'PY' 2>/dev/null || true
import sys

repo_root, project_dir = sys.argv[1:3]
sys.path.insert(0, repo_root)

from runtime.core.config import resolve_db_path

print(resolve_db_path(project_root=project_dir))
PY
}

_seed_project_dir_for_pre_bash() {
    local payload="${1:-}"
    local payload_cwd=""
    [[ -n "$payload" ]] || return 0
    [[ -z "${CLAUDE_POLICY_DB:-}" ]] || return 0

    # Runtime envelope owns Bash target resolution. The shell only exports the
    # resulting target root so cc_policy evaluate opens the same DB authority.
    payload_cwd=$(bash_payload_project_root "$payload" 2>/dev/null || echo "")
    [[ -z "$payload_cwd" ]] && payload_cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || echo "")
    [[ -n "$payload_cwd" && -d "$payload_cwd" ]] || return 0

    if [[ -z "${CLAUDE_PROJECT_DIR:-}" ]]; then
        export CLAUDE_PROJECT_DIR="$payload_cwd"
        return 0
    fi

    local current_db payload_db
    current_db=$(_policy_db_for_project_dir "$CLAUDE_PROJECT_DIR")
    payload_db=$(_policy_db_for_project_dir "$payload_cwd")
    if [[ -n "$payload_db" && "$payload_db" != "$current_db" ]]; then
        export CLAUDE_PROJECT_DIR="$payload_cwd"
    fi
}

_session_root_from_payload_cwd() {
    local payload="${1:-}"
    local payload_cwd="" session_root="" common_dir="" common_abs=""
    payload_cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || echo "")
    if [[ -n "$payload_cwd" && -d "$payload_cwd" ]]; then
        common_dir=$(git -C "$payload_cwd" rev-parse --git-common-dir 2>/dev/null || echo "")
        if [[ -n "$common_dir" ]]; then
            if [[ "$common_dir" = /* ]]; then
                common_abs="$common_dir"
            else
                common_abs="$payload_cwd/$common_dir"
            fi
            session_root=$(cd "$(dirname "$common_abs")" 2>/dev/null && pwd -P || echo "")
        fi
        [[ -z "$session_root" ]] && session_root=$(git -C "$payload_cwd" rev-parse --show-toplevel 2>/dev/null || echo "")
        if [[ -n "$session_root" && -d "$session_root" ]]; then
            printf '%s\n' "$session_root"
            return 0
        fi
        printf '%s\n' "$payload_cwd"
        return 0
    fi
    detect_project_root 2>/dev/null || true
}

# shellcheck disable=SC2329  # _hook_main is invoked indirectly via run_fail_closed
_hook_main() {
    HOOK_INPUT=$(read_input)
    _seed_project_dir_for_pre_bash "$HOOK_INPUT"
    COMMAND=$(get_field '.tool_input.command')
    if [[ -z "$COMMAND" ]]; then
        _mark_hook_responded
        exit 0
    fi

    # Resolve actor context for the policy engine. The marker is scoped to the
    # live session root from the hook payload; command intent below still owns
    # the target worktree/DB context for policy checks.
    SESSION_ROOT="$(_session_root_from_payload_cwd "$HOOK_INPUT")"
    TARGET_ROOT="$(bash_payload_project_root "$HOOK_INPUT" 2>/dev/null || echo "")"
    ACTOR_MARKER=$(rt_marker_get_active "$SESSION_ROOT" "" 2>/dev/null || printf '{"found":false}')
    if [[ "$(printf '%s' "$ACTOR_MARKER" | jq -r '.found // false' 2>/dev/null || echo "false")" != "true" \
        && -n "$TARGET_ROOT" \
        && "$TARGET_ROOT" != "$SESSION_ROOT" ]]; then
        ACTOR_MARKER=$(rt_marker_get_active "$TARGET_ROOT" "" 2>/dev/null || printf '{"found":false}')
    fi
    ACTOR_ROLE=$(printf '%s' "$ACTOR_MARKER" | jq -r 'if .found then (.role // "") else "" end' 2>/dev/null || echo "")
    ACTOR_ID=$(printf '%s' "$ACTOR_MARKER" | jq -r 'if .found then (.agent_id // "") else "" end' 2>/dev/null || echo "")
    ACTOR_WORKFLOW_ID=$(printf '%s' "$ACTOR_MARKER" | jq -r 'if .found then (.workflow_id // "") else "" end' 2>/dev/null || echo "")
    if [[ -z "$ACTOR_ROLE" ]]; then
        ACTOR_ROLE=$(current_active_agent_role "$SESSION_ROOT" 2>/dev/null || echo "")
    fi

    # Build evaluate payload — merge actor_role and hook fields. The runtime
    # constructs BashCommandIntent from .tool_input.command, including any
    # target_cwd derivation, so the hook no longer carries that authority.
    EVAL_INPUT=$(printf '%s' "$HOOK_INPUT" | jq \
        --arg role "$ACTOR_ROLE" \
        --arg actor_id "$ACTOR_ID" \
        --arg actor_workflow_id "$ACTOR_WORKFLOW_ID" \
        '. + {event_type: "PreToolUse", tool_name: "Bash", actor_role: $role, actor_id: $actor_id, actor_workflow_id: $actor_workflow_id}')

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
    emit_runtime_notification "$RESULT" "$HOOKS_DIR"
    RESULT=$(strip_runtime_notification "$RESULT")
    printf '%s\n' "$RESULT"

    # Capture source-mutation fingerprint baseline for post-bash.sh (DEC-EVAL-006).
    # Only when allowed — denied commands don't execute so post-bash.sh won't fire.
    if [[ "$_pb_action" != "deny" ]]; then
        printf '%s' "$HOOK_INPUT" | cc_policy hook bash-pre-baseline >/dev/null 2>&1 || true
    fi
}

run_fail_closed _hook_main
exit 0
