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

asks_about() {
    local topic_pattern="$1"
    local ask_pattern='want me to|would you like( me)? to|should i|shall i|do you want( me)? to|or stop here|stop here'
    printf '%s' "$NORMALIZED" | grep -Eq "(${ask_pattern})[^.?!]{0,160}(${topic_pattern})|(${topic_pattern})[^.?!]{0,160}(${ask_pattern})"
}

has_user_boundary() {
    printf '%s' "$NORMALIZED" | grep -Eq 'force[- ]?push|force push|history rewrite|destructive|reset --hard|git reset|rebase|non[- ]?ff|non fast-forward|ambiguous publish|publish target|irreconcilable|product signoff|explicit user|user approval|user adjudicat|requires approval|needs approval|ask the user'
}

has_followup_surface() {
    printf '%s' "$NORMALIZED" | grep -Eq 'worth filing|follow[- ]?up item|follow[- ]?ups? (surfaced|identified|found|remain|to file)|backlog candidate|non[- ]?blocking (item|concern|issue)s?|surfaced .* (item|concern|issue)s?|file .* (later|as follow[- ]?ups?)'
}

has_capture_evidence() {
    printf '%s' "$MESSAGE" | grep -Eq 'https://github\.com/[^[:space:]]+/issues/[0-9]+|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+|\[fingerprint:|fingerprint[" :]+[a-f0-9]{8,}|issue_url'
}

emit_block() {
    local reason="$1"
    jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
}

# Real decision boundaries remain user-visible. Do not suppress those asks.
if has_user_boundary; then
    exit 0
fi

if has_question_shape && asks_about '(/backlog|backlog|todo|follow[- ]?up|followup|file .*issue|open .*issue|track .*issue|record .*issue|file those|file all)'; then
    emit_block "Stop advisor: do not ask the user to approve obvious bookkeeping. File or track the backlog/follow-up items now, then stop."
    exit 0
fi

if has_followup_surface && ! has_capture_evidence; then
    emit_block "Stop advisor: follow-up/backlog items were surfaced without captured issue evidence. File them through /backlog or cc-policy issue file, include the issue URL(s) or fingerprint(s), then stop."
    exit 0
fi

if ! has_question_shape; then
    exit 0
fi

if asks_about '\bgit\b|commit|merge|push|land|landing'; then
    emit_block "Stop advisor: do not ask the user to handle routine git landing. Route the operation to Guardian. Only ask the user after Guardian or policy identifies a real boundary such as destructive history rewrite, ambiguous publish target, or irreconcilable reviewer/implementer conflict."
    exit 0
fi

if asks_about 'dispatch|auto[- ]?dispatch|send .* to |call .* (planner|implementer|reviewer|guardian)|start .* (planner|implementer|reviewer|guardian)|next role'; then
    emit_block "Stop advisor: do not ask for routine canonical dispatch. Use the runtime-provided dispatch/stage-packet path and continue, unless the runtime or policy has already surfaced a user decision boundary."
    exit 0
fi

if asks_about 'obvious|straightforward|low[- ]?risk|simple|routine'; then
    emit_block "Stop advisor: the proposed action is framed as routine. If it is within the approved task and no policy/user-boundary was surfaced, take the action instead of asking."
    exit 0
fi

exit 0
