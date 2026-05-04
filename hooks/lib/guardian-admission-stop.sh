#!/usr/bin/env bash
set -euo pipefail

# Guardian admission trailer parser. check-guardian.sh delegates here when the
# guardian response contains ADMISSION_* trailers.
# This is a pre-workflow custody hook only. It emits an audit event and
# additionalContext; it does not submit canonical completion records and must
# not invoke post-task routing.

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
_HOOK_DIR="$(cd "$_SCRIPT_DIR/.." && pwd)"

source "$_HOOK_DIR/log.sh"
source "$_HOOK_DIR/context-lib.sh"

AGENT_RESPONSE=$(read_input 2>/dev/null || echo "{}")
seed_project_dir_from_hook_payload_cwd "$AGENT_RESPONSE"
PROJECT_ROOT=$(detect_project_root)

_LOCAL_RUNTIME_ROOT="$_HOOK_DIR/../runtime"
_local_cc_policy() {
    if [[ -z "${CLAUDE_POLICY_DB:-}" ]]; then
        _resolve_policy_db >/dev/null
    fi
    cc_policy_local_runtime "$_LOCAL_RUNTIME_ROOT" "$@"
}

RESPONSE_TEXT=$(printf '%s' "$AGENT_RESPONSE" | jq -r '.last_assistant_message // .assistant_response // .response // .result // .output // empty' 2>/dev/null || echo "")

_trailer() {
    local name="$1"
    printf '%s' "$RESPONSE_TEXT" \
        | grep -oE "^${name}:[[:space:]]*.*" \
        | head -1 \
        | sed "s/^${name}:[[:space:]]*//" || true
}

ADMISSION_VERDICT="$(_trailer ADMISSION_VERDICT)"
ADMISSION_NEXT_AUTHORITY="$(_trailer ADMISSION_NEXT_AUTHORITY)"
ADMISSION_TARGET_ROOT="$(_trailer ADMISSION_TARGET_ROOT)"
ADMISSION_TARGET_PATH="$(_trailer ADMISSION_TARGET_PATH)"
ADMISSION_SCRATCHLANE="$(_trailer ADMISSION_SCRATCHLANE)"
ADMISSION_REASON="$(_trailer ADMISSION_REASON)"

ISSUES=()
[[ -z "$ADMISSION_VERDICT" ]] && ISSUES+=("No ADMISSION_VERDICT trailer found")
[[ -z "$ADMISSION_NEXT_AUTHORITY" ]] && ISSUES+=("No ADMISSION_NEXT_AUTHORITY trailer found")
[[ -z "$ADMISSION_TARGET_ROOT" ]] && ISSUES+=("No ADMISSION_TARGET_ROOT trailer found")
[[ -z "$ADMISSION_TARGET_PATH" ]] && ISSUES+=("No ADMISSION_TARGET_PATH trailer found")
[[ -z "$ADMISSION_SCRATCHLANE" ]] && ISSUES+=("No ADMISSION_SCRATCHLANE trailer found")
[[ -z "$ADMISSION_REASON" ]] && ISSUES+=("No ADMISSION_REASON trailer found")

if [[ ${#ISSUES[@]} -gt 0 ]]; then
    ISSUES_JSON=$(printf '%s\n' "${ISSUES[@]}" | jq -R . | jq -s .)
else
    ISSUES_JSON='[]'
fi

DETAIL=$(jq -n \
    --arg verdict "$ADMISSION_VERDICT" \
    --arg next_authority "$ADMISSION_NEXT_AUTHORITY" \
    --arg target_root "$ADMISSION_TARGET_ROOT" \
    --arg target_path "$ADMISSION_TARGET_PATH" \
    --arg scratchlane "$ADMISSION_SCRATCHLANE" \
    --arg reason "$ADMISSION_REASON" \
    --argjson issues "$ISSUES_JSON" \
    '{
      verdict:$verdict,
      next_authority:$next_authority,
      target_root:$target_root,
      target_path:$target_path,
      scratchlane:$scratchlane,
      reason:$reason,
      issues:$issues
    }')

_local_cc_policy event emit "guardian_admission.stop" \
    --source "admission:${ADMISSION_VERDICT:-unknown}" \
    --detail "$DETAIL" >/dev/null 2>&1 || true

CONTEXT="Guardian Admission: verdict=${ADMISSION_VERDICT:-unknown}; next=${ADMISSION_NEXT_AUTHORITY:-unknown}; scratchlane=${ADMISSION_SCRATCHLANE:-none}. ${ADMISSION_REASON:-No reason trailer supplied.}"
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    CONTEXT="$CONTEXT Missing trailers: $(IFS=', '; echo "${ISSUES[*]}")."
fi

ESCAPED=$(printf '%s' "$CONTEXT" | jq -Rs .)
cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SubagentStop",
    "additionalContext": $ESCAPED
  }
}
EOF

exit 0
