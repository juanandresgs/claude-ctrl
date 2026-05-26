#!/usr/bin/env bash
# v6-result-submit.sh — canonical SubagentStop result adapter.
# Thin adapter: strict final-result extraction and transition logic live in runtime.
set -euo pipefail

_HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$_HOOK_DIR/log.sh"
source "$_HOOK_DIR/context-lib.sh"

HOOK_INPUT=$(read_input 2>/dev/null || echo "{}")
_LOCAL_RUNTIME_CLI="$_HOOK_DIR/../runtime/cli.py"

_local_cc_policy() {
    if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -z "${CLAUDE_POLICY_DB:-}" ]]; then
        export CLAUDE_POLICY_DB="$CLAUDE_PROJECT_DIR/.claude/state.db"
    fi
    python3 "$_LOCAL_RUNTIME_CLI" "$@"
}

AGENT_TYPE=$(printf '%s' "$HOOK_INPUT" | jq -r '.agent_type // .agentType // empty' 2>/dev/null || true)
PROJECT_ROOT=$(detect_project_root 2>/dev/null || echo "${CLAUDE_PROJECT_DIR:-$PWD}")
_deactivate_v6_marker() {
    case "${AGENT_TYPE:-}" in
        planner|implementer|critic|reviewer|guardian|tester)
            _local_cc_policy lifecycle on-stop "$AGENT_TYPE" --project-root "$PROJECT_ROOT" >/dev/null 2>&1 || true
            ;;
    esac
}
trap _deactivate_v6_marker EXIT

RESPONSE_TEXT=$(agent_response_text "$HOOK_INPUT")
if [[ -z "$RESPONSE_TEXT" || "$RESPONSE_TEXT" != *'```claude_ctrl_result'* ]]; then
    exit 0
fi

STAGE_RUN_ID=$(RESPONSE_TEXT="$RESPONSE_TEXT" python3 -c 'import json, os
text = os.environ.get("RESPONSE_TEXT", "")
marker = "```claude_ctrl_result"
if marker not in text:
    raise SystemExit(2)
after = text.rsplit(marker, 1)[1]
if "```" not in after:
    raise SystemExit(3)
block, tail = after.split("```", 1)
if tail.strip():
    raise SystemExit(4)
payload = json.loads(block.strip())
print(payload.get("stage_run_id", ""))
') || {
    esc=$(printf 'BLOCKED: malformed claude_ctrl_result. Final response must end with a valid fenced JSON object and no trailing text.' | jq -Rs .)
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"SubagentStop","additionalContext":$esc}}
EOF
    exit 0
}

if [[ -z "$STAGE_RUN_ID" ]]; then
    esc=$(printf 'BLOCKED: claude_ctrl_result missing stage_run_id. Relaunch %s naturally; runtime will bind the active stage context and inject the required schema.' "${AGENT_TYPE:-agent}" | jq -Rs .)
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"SubagentStop","additionalContext":$esc}}
EOF
    exit 0
fi

RESULT=$(printf '%s' "$RESPONSE_TEXT" | _local_cc_policy stage result-submit "$STAGE_RUN_ID" --raw-response 2>/dev/null || true)
if [[ -z "$RESULT" ]] || ! printf '%s' "$RESULT" | jq -e '.status == "ok"' >/dev/null 2>&1; then
    esc=$(printf 'PROCESS ERROR: v6 stage result-submit failed for stage_run_id=%s' "$STAGE_RUN_ID" | jq -Rs .)
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"SubagentStop","additionalContext":$esc}}
EOF
    exit 0
fi

VALID=$(printf '%s' "$RESULT" | jq -r '.validation.valid // false' 2>/dev/null || echo false)
NEXT_STAGE=$(printf '%s' "$RESULT" | jq -r '.next_stage_run.stage_id // empty' 2>/dev/null || echo "")
NEXT_ACTION=$(printf '%s' "$RESULT" | jq -r '.next_action.id // empty' 2>/dev/null || echo "")
NEXT_STAGE_RUN=$(printf '%s' "$RESULT" | jq -r '.next_stage_run.id // empty' 2>/dev/null || echo "")
NEXT_WORKFLOW=$(printf '%s' "$RESULT" | jq -r '.next_stage_run.workflow_id // empty' 2>/dev/null || echo "")

if [[ "$VALID" != "true" ]]; then
    MISSING=$(printf '%s' "$RESULT" | jq -r '.validation.missing_fields | join(", ")' 2>/dev/null || echo "unknown")
    REPAIR_STAGE=$(printf '%s' "$RESULT" | jq -r '.repair_ticket.stage_id // empty' 2>/dev/null || echo "")
    REPAIR_SUBAGENT=$(printf '%s' "$RESULT" | jq -r '.repair_ticket.subagent_type // empty' 2>/dev/null || echo "")
    if [[ -n "$REPAIR_STAGE" ]]; then
        esc=$(printf 'BLOCKED: v6 result contract invalid for stage_run_id=%s. Missing/invalid: %s. V6_DISPATCH_READY: launch %s for stage %s to repair the result contract. Runtime reopened the same stage and will inject the required schema; do not advance to later stages until this stage submits a valid claude_ctrl_result.' "$STAGE_RUN_ID" "$MISSING" "${REPAIR_SUBAGENT:-agent}" "$REPAIR_STAGE" | jq -Rs .)
    else
        esc=$(printf 'BLOCKED: v6 result contract invalid for stage_run_id=%s. Missing/invalid: %s' "$STAGE_RUN_ID" "$MISSING" | jq -Rs .)
    fi
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"SubagentStop","additionalContext":$esc}}
EOF
    exit 0
fi

if [[ -n "$NEXT_STAGE" && -n "$NEXT_ACTION" ]]; then
    if [[ "$NEXT_STAGE" == "critic" ]]; then
        CRITIC_TIMEOUT="${CLAUDE_CTRL_CRITIC_TIMEOUT:-60}"
        CRITIC_ARGS=(stage critic-worker --limit 1 --timeout "$CRITIC_TIMEOUT")
        [[ -n "$NEXT_WORKFLOW" ]] && CRITIC_ARGS+=(--workflow-id "$NEXT_WORKFLOW")
        CRITIC_OUT=$(_local_cc_policy "${CRITIC_ARGS[@]}" 2>/dev/null || true)
        CRITIC_SUBMITTED=$(printf '%s' "${CRITIC_OUT:-}" | jq -r '.processed[0].result.submitted_result.validation.valid // false' 2>/dev/null || echo "false")
        CRITIC_REVIEWER_ACTION=$(printf '%s' "${CRITIC_OUT:-}" | jq -r '.processed[0].result.submitted_result.next_action.id // empty' 2>/dev/null || echo "")
        CRITIC_FALLBACK_READY=$(printf '%s' "${CRITIC_OUT:-}" | jq -r '.processed[0].result.fallback_launch.subagent_type // empty' 2>/dev/null || echo "")
        CRITIC_STATUS=$(printf '%s' "${CRITIC_OUT:-}" | jq -r '.processed[0].result.status // empty' 2>/dev/null || echo "")
        if [[ "$CRITIC_SUBMITTED" == "true" && -n "$CRITIC_REVIEWER_ACTION" ]]; then
            TICKET_JSON=$(_local_cc_policy dispatch ticket-issue "$CRITIC_REVIEWER_ACTION" 2>/dev/null || true)
            SUBAGENT_TYPE=$(printf '%s' "${TICKET_JSON:-}" | jq -r '.ticket.subagent_type // empty' 2>/dev/null || echo "")
            if [[ -n "$SUBAGENT_TYPE" ]]; then
                esc=$(printf 'V6_CRITIC_COMPLETE: external critic accepted. V6_DISPATCH_READY: launch %s for stage reviewer' "${SUBAGENT_TYPE:-reviewer}" | jq -Rs .)
            else
                esc=$(printf 'BLOCKED: external critic completed but reviewer launch binding failed. Runtime repair required.' | jq -Rs .)
            fi
        elif [[ -n "$CRITIC_FALLBACK_READY" ]]; then
            esc=$(printf 'V6_CRITIC_FALLBACK: external critics unavailable or invalid (%s). V6_DISPATCH_READY: launch critic for stage critic' "${CRITIC_STATUS:-fallback_required}" | jq -Rs .)
        else
            esc=$(printf 'BLOCKED: v6 critic automation did not produce reviewer or critic fallback for stage_run_id=%s. Runtime repair required.' "$NEXT_STAGE_RUN" | jq -Rs .)
        fi
    else
        TICKET_JSON=$(_local_cc_policy dispatch ticket-issue "$NEXT_ACTION" 2>/dev/null || true)
        SUBAGENT_TYPE=$(printf '%s' "${TICKET_JSON:-}" | jq -r '.ticket.subagent_type // empty' 2>/dev/null || echo "")
        if [[ -n "$SUBAGENT_TYPE" ]]; then
            if [[ "$NEXT_STAGE" == "guardian:land" && -n "$NEXT_STAGE_RUN" ]]; then
                _local_cc_policy stage landing-ready "$NEXT_STAGE_RUN" >/dev/null 2>&1 || true
            fi
            esc=$(printf 'V6_DISPATCH_READY: launch %s for stage %s' "${SUBAGENT_TYPE:-agent}" "$NEXT_STAGE" | jq -Rs .)
        else
            esc=$(printf 'BLOCKED: v6 launch binding failed for next_action=%s stage=%s. Runtime repair required.' "$NEXT_ACTION" "$NEXT_STAGE" | jq -Rs .)
        fi
    fi
else
    esc=$(printf 'V6_STAGE_COMPLETE: stage_run_id=%s terminal or no next stage.' "$STAGE_RUN_ID" | jq -Rs .)
fi

cat <<EOF
{"hookSpecificOutput":{"hookEventName":"SubagentStop","additionalContext":$esc}}
EOF
exit 0
