#!/usr/bin/env bash
set -euo pipefail

# Stop hook: deterministic common-sense advisor.
#
# @decision DEC-STOP-ADVISOR-001
# Title: Regular Stop uses deterministic obvious-action triage instead of model review
# Status: accepted
# Rationale: Regular Stop is a user-facing turn boundary, not a workflow quality
#   gate. Full model review at Stop created multi-minute stalls and pushed
#   feedback into the wrong lane. This hook only catches obvious low-risk
#   questions Claude should not ask: routine bookkeeping, canonical dispatch,
#   and Guardian-owned git landing. It never calls external model providers.

HOOK_INPUT="$(cat || true)"

if [[ -z "$HOOK_INPUT" ]]; then
    exit 0
fi

STOP_ACTIVE="$(printf '%s' "$HOOK_INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")"
if [[ "$STOP_ACTIVE" == "true" ]]; then
    exit 0
fi

if printf '%s' "$HOOK_INPUT" | jq -e 'has("agent_type")' >/dev/null 2>&1; then
    exit 0
fi

MESSAGE="$(
    printf '%s' "$HOOK_INPUT" |
        jq -r '.last_assistant_message // .response // .message // empty' 2>/dev/null ||
        true
)"

if [[ -z "${MESSAGE//[[:space:]]/}" ]]; then
    exit 0
fi

NORMALIZED="$(
    printf '%s' "$MESSAGE" |
        tr '\n' ' ' |
        tr '[:upper:]' '[:lower:]' |
        sed -E 's/[[:space:]]+/ /g'
)"

has_question_shape() {
    printf '%s' "$NORMALIZED" | grep -Eq '\?|want me to|would you like|should i|shall i|do you want|want me|or stop here|stop here'
}

has_user_boundary() {
    printf '%s' "$NORMALIZED" | grep -Eq 'force[- ]?push|force push|history rewrite|destructive|reset --hard|git reset|rebase|non[- ]?ff|non fast-forward|ambiguous publish|publish target|irreconcilable|product signoff|explicit user|user approval|user adjudicat|requires approval|needs approval|ask the user'
}

emit_block() {
    local reason="$1"
    jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
}

if ! has_question_shape; then
    exit 0
fi

# Real decision boundaries remain user-visible. Do not suppress those asks.
if has_user_boundary; then
    exit 0
fi

if printf '%s' "$NORMALIZED" | grep -Eq '(backlog|todo|follow[- ]?up|followup|file .*issue|open .*issue|track .*issue|record .*issue|file those|file all|worth filing)'; then
    emit_block "Stop advisor: do not ask the user to approve obvious bookkeeping. File or track the backlog/follow-up items now, then stop."
    exit 0
fi

if printf '%s' "$NORMALIZED" | grep -Eq '\bgit\b|commit|merge|push|land|landing'; then
    emit_block "Stop advisor: do not ask the user to handle routine git landing. Route the operation to Guardian. Only ask the user after Guardian or policy identifies a real boundary such as destructive history rewrite, ambiguous publish target, or irreconcilable reviewer/implementer conflict."
    exit 0
fi

if printf '%s' "$NORMALIZED" | grep -Eq 'dispatch|auto[- ]?dispatch|send .* to |call .* (planner|implementer|reviewer|guardian)|start .* (planner|implementer|reviewer|guardian)|next role'; then
    emit_block "Stop advisor: do not ask for routine canonical dispatch. Use the runtime-provided dispatch/stage-packet path and continue, unless the runtime or policy has already surfaced a user decision boundary."
    exit 0
fi

if printf '%s' "$NORMALIZED" | grep -Eq 'obvious|straightforward|low[- ]?risk|simple|routine'; then
    emit_block "Stop advisor: the proposed action is framed as routine. If it is within the approved task and no policy/user-boundary was surfaced, take the action instead of asking."
    exit 0
fi

exit 0
