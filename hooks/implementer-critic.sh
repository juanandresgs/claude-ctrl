#!/usr/bin/env bash
# @decision DEC-IMPLEMENTER-CRITIC-HOOK-002 — repo-owned wrapper fail-safes implementer critic routing to CRITIC_UNAVAILABLE
# Why: The workflow authority must still persist a routing verdict when the Node critic path crashes, so the bash wrapper records CRITIC_UNAVAILABLE before post-task routing runs.
# Alternatives considered: Wiring the plugin script directly was rejected because catastrophic script/runtime failures would skip persistence entirely; folding critic execution into check-implementer.sh was rejected because validation and tactical criticism are separate authorities.
set -euo pipefail

# shellcheck source=hooks/log.sh
source "$(dirname "$0")/log.sh"
# shellcheck source=hooks/context-lib.sh
source "$(dirname "$0")/context-lib.sh"

HOOK_INPUT=$(read_input 2>/dev/null || echo "{}")
seed_project_dir_from_hook_payload_cwd "$HOOK_INPUT"
AGENT_TYPE=$(printf '%s' "$HOOK_INPUT" | jq -r '.agent_type // .agentType // empty' 2>/dev/null || true)
AGENT_TYPE_LC=$(printf '%s' "$AGENT_TYPE" | tr '[:upper:]' '[:lower:]')
[[ -z "$AGENT_TYPE_LC" || "$AGENT_TYPE_LC" != "implementer" ]] && exit 0

PROJECT_ROOT=$(detect_project_root 2>/dev/null || printf '%s\n' "${CLAUDE_PROJECT_DIR:-$(pwd)}")

_HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
_LOCAL_RUNTIME_CLI="$_HOOK_DIR/../runtime/cli.py"
_LOCAL_CRITIC_HOOK="$_HOOK_DIR/../sidecars/codex-review/scripts/implementer-critic-hook.mjs"

_local_cc_policy() {
    if [[ -z "${CLAUDE_POLICY_DB:-}" ]]; then
        _resolve_policy_db >/dev/null
    fi
    python3 "$_LOCAL_RUNTIME_CLI" "$@"
}

_resolve_context() {
    local lease_json found workflow_id lease_id
    lease_json=$(_local_cc_policy lease current --worktree-path "$PROJECT_ROOT" 2>/dev/null || echo "")
    found=$(printf '%s' "$lease_json" | jq -r '.found // false' 2>/dev/null || echo "false")
    workflow_id=""
    lease_id=""
    if [[ "$found" == "true" ]]; then
        workflow_id=$(printf '%s' "$lease_json" | jq -r '.workflow_id // empty' 2>/dev/null || true)
        lease_id=$(printf '%s' "$lease_json" | jq -r '.lease_id // empty' 2>/dev/null || true)
    fi
    [[ -n "$workflow_id" ]] || workflow_id=$(current_workflow_id "$PROJECT_ROOT")
    printf '%s\t%s\n' "$workflow_id" "$lease_id"
}

_critic_enabled() {
    local workflow_id="$1"
    local project_root="$2"
    local raw value
    raw=$(_local_cc_policy config get critic_enabled_implementer_stop --workflow-id "$workflow_id" --project-root "$project_root" 2>/dev/null || echo "")
    value=$(printf '%s' "$raw" | jq -r '.value // empty' 2>/dev/null || true)
    [[ -z "$value" || "$value" == "true" ]]
}

_emit_unavailable() {
    local detail="$1"
    local workflow_id lease_id metadata_json escaped run_json run_id
    IFS=$'\t' read -r workflow_id lease_id < <(_resolve_context)
    metadata_json=$(jq -n \
        --arg hook "implementer-critic.sh" \
        --arg failure "$detail" \
        '{hook: $hook, failure: $failure}')
    run_json=$(_local_cc_policy critic-run start \
        --workflow-id "$workflow_id" \
        --lease-id "${lease_id:-}" \
        --role implementer \
        --provider codex 2>/dev/null || echo "")
    run_id=$(printf '%s' "$run_json" | jq -r '.run_id // empty' 2>/dev/null || true)
    _local_cc_policy critic-review submit \
        --workflow-id "$workflow_id" \
        --lease-id "${lease_id:-}" \
        --role implementer \
        --provider codex \
        --verdict CRITIC_UNAVAILABLE \
        --summary "Implementer critic unavailable." \
        --detail "$detail" \
        --fingerprint "" \
        --project-root "$PROJECT_ROOT" \
        --metadata "$metadata_json" >/dev/null 2>&1 || true
    if [[ -n "$run_id" ]]; then
        _local_cc_policy critic-run complete \
            --run-id "$run_id" \
            --provider codex \
            --verdict CRITIC_UNAVAILABLE \
            --summary "Implementer critic unavailable." \
            --detail "$detail" \
            --fallback reviewer \
            --error "$detail" >/dev/null 2>&1 || true
    fi
    escaped=$(printf 'Implementer critic progress: Starting Codex tactical critic (read-only).\nImplementer critic: provider=codex, workflow=%s.\nImplementer critic: verdict=CRITIC_UNAVAILABLE, next_role=reviewer.\nImplementer critic detail: %s' "$workflow_id" "$detail" | jq -Rs .)
    cat <<EOF
{
  "additionalContext": $escaped,
  "hookSpecificOutput": {
    "hookEventName": "SubagentStop",
    "additionalContext": $escaped
  }
}
EOF
}

_emit_disabled() {
    local workflow_id="$1"
    local escaped
    escaped=$(printf 'Implementer critic disabled for this scope.\nImplementer critic: provider=codex, workflow=%s.\nImplementer critic: disabled, routing directly to reviewer.' "$workflow_id" | jq -Rs .)
    cat <<EOF
{
  "additionalContext": $escaped,
  "hookSpecificOutput": {
    "hookEventName": "SubagentStop",
    "additionalContext": $escaped
  }
}
EOF
}

IFS=$'\t' read -r WORKFLOW_ID LEASE_ID < <(_resolve_context)
if ! _critic_enabled "$WORKFLOW_ID" "$PROJECT_ROOT"; then
    _emit_disabled "$WORKFLOW_ID"
    exit 0
fi

if [[ ! -f "$_LOCAL_CRITIC_HOOK" ]]; then
    _emit_unavailable "Implementer critic hook not found at $_LOCAL_CRITIC_HOOK"
    exit 0
fi

RESULT=$(printf '%s' "$HOOK_INPUT" | node "$_LOCAL_CRITIC_HOOK") || RESULT=""
if [[ -z "$RESULT" ]] || ! printf '%s' "$RESULT" | jq -e '.additionalContext' >/dev/null 2>&1; then
    _emit_unavailable "Implementer critic hook failed or returned malformed output"
    exit 0
fi

printf '%s\n' "$RESULT"
