#!/usr/bin/env bash
# skill-result.sh — PostToolUse hook for Skill tool
#
# Purpose: Reads .skill-result.md written by forked skills and injects the content
# as additionalContext into the parent session. This surfaces research/analysis
# results from skills with context:fork back to the orchestrator.
#
# Also logs every Skill invocation as a skill_invoked session event, providing a
# forensic trail for Skill calls from subagents (security hardening: previously
# no record existed of which agent invoked which skill).
#
# Hook type: PostToolUse
# Trigger: Skill tool calls
# Input: JSON on stdin with tool_name, tool_input
# Output: JSON with additionalContext if result file exists
#
# @decision DEC-SKILL-RESULT-001
# @title Surface forked-skill results via PostToolUse hook
# @status accepted
# @rationale Skills with context:fork run in isolation. The parent session only sees
#            "Done" — none of the research/analysis results flow back. A simple file
#            contract (.skill-result.md) is cleaner than retrofitting the trace protocol.
#
# @decision DEC-SKILL-VIS-001
# @title Log every Skill invocation as a session event for forensic visibility
# @status accepted
# @rationale An agent was observed invoking /approve via the Skill tool. The approval
#            gate held (Skill calls don't trigger UserPromptSubmit), but no forensic
#            trail existed for which agent called which skill with what arguments.
#            Logging to .session-events.jsonl closes this observability gap. Agent type
#            is detected from the session-scoped subagent tracker (last ACTIVE line).
#            Defaults to "orchestrator" when no subagent is active.

set -euo pipefail
source "$(dirname "$0")/source-lib.sh"

HOOK_INPUT=$(read_input)
TOOL_NAME=$(get_field '.tool_name')
[[ "$TOOL_NAME" != "Skill" ]] && exit 0

SKILL_NAME=$(get_field '.tool_input.skill')
SKILL_ARGS=$(get_field '.tool_input.args')
PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)

# --- Skill invocation logging (forensic trail) ---
# Detect active agent type from session-scoped subagent tracker.
TRACKER="${CLAUDE_DIR}/.subagent-tracker-${CLAUDE_SESSION_ID:-$$}"
AGENT_TYPE="orchestrator"
if [[ -f "$TRACKER" ]]; then
    # Read last ACTIVE line to get the most recently started agent type
    _last_active=$(grep '^ACTIVE|' "$TRACKER" 2>/dev/null | tail -1 || true)
    if [[ -n "$_last_active" ]]; then
        AGENT_TYPE=$(echo "$_last_active" | cut -d'|' -f2)
    fi
fi

append_session_event "skill_invoked" \
    "$(jq -cn --arg skill "${SKILL_NAME:-unknown}" \
               --arg agent_type "$AGENT_TYPE" \
               --arg args "${SKILL_ARGS:-}" \
        '{skill: $skill, agent_type: $agent_type, args: $args}')" \
    "$PROJECT_ROOT"

# --- Skill result injection ---
RESULT_FILE="${CLAUDE_DIR}/.skill-result.md"

[[ ! -f "$RESULT_FILE" ]] && exit 0

RESULT_CONTENT=$(cat "$RESULT_FILE" 2>/dev/null || echo "")
[[ -z "$RESULT_CONTENT" ]] && rm -f "$RESULT_FILE" && exit 0

# Truncate if over budget (~1000 tokens)
RESULT_SIZE=$(wc -c < "$RESULT_FILE" | tr -d ' ')
if [[ "$RESULT_SIZE" -gt 4000 ]]; then
    RESULT_CONTENT=$(head -c 3800 "$RESULT_FILE")
    RESULT_CONTENT+=$'\n[... truncated — read full results at paths listed above]'
fi

rm -f "$RESULT_FILE"

ESCAPED=$(echo "$RESULT_CONTENT" | jq -Rs .)
cat <<EOF
{
  "hookSpecificOutput": {
    "additionalContext": $ESCAPED
  }
}
EOF

log_info "SKILL-RESULT" "Injected result for skill: ${SKILL_NAME:-unknown} (${RESULT_SIZE} bytes)"
exit 0
