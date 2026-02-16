#!/usr/bin/env bash
# skill-result.sh — PostToolUse hook for Skill tool
#
# Purpose: Reads .skill-result.md written by forked skills and injects the content
# as additionalContext into the parent session. This surfaces research/analysis
# results from skills with context:fork back to the orchestrator.
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

set -euo pipefail
source "$(dirname "$0")/log.sh"

HOOK_INPUT=$(read_input)
TOOL_NAME=$(get_field '.tool_name')
[[ "$TOOL_NAME" != "Skill" ]] && exit 0

SKILL_NAME=$(get_field '.tool_input.skill')
PROJECT_ROOT=$(detect_project_root)
RESULT_FILE="$PROJECT_ROOT/.claude/.skill-result.md"

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
