#!/usr/bin/env bash
# SubagentStop:Explore — overflow detection and spillover-to-disk fallback.
# When Explore agents return >1200 words without writing a temp file,
# this hook saves the overflow to disk and flags it for the orchestrator.
#
# @decision DEC-EXPLORE-STOP-001
# @title Explore SubagentStop overflow-to-disk fallback
# @status accepted
# @rationale Explore agents bypass all five output size safeguards
#   (agent prompt, SubagentStart injection, SubagentStop validation,
#   Trace Protocol, max_turns). This hook adds Layer 2 defense:
#   when the agent returns >1200 words without having written a temp
#   file, the hook writes the overflow to tmp/explore-overflow-{timestamp}.md
#   and flags it. SubagentStop cannot truncate the return — the blast
#   has already happened — but the temp file provides recovery for
#   future sessions and the flag alerts the orchestrator.
set -euo pipefail

source "$(dirname "$0")/source-lib.sh"

# Capture stdin (contains agent response)
AGENT_RESPONSE=$(read_input 2>/dev/null || echo "{}")

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)

# Track subagent completion
track_subagent_stop "$PROJECT_ROOT" "explore"
append_session_event "agent_stop" "{\"type\":\"explore\"}" "$PROJECT_ROOT"

ISSUES=()

# Extract response text
RESPONSE_TEXT=$(echo "$AGENT_RESPONSE" | jq -r '.response // .result // .output // empty' 2>/dev/null || echo "")

if [[ -n "$RESPONSE_TEXT" ]]; then
    WORD_COUNT=$(echo "$RESPONSE_TEXT" | wc -w | tr -d ' ')

    if [[ "$WORD_COUNT" -gt 1200 ]]; then
        # Check if agent already wrote a spillover file
        SPILLOVER_EXISTS=false
        TMP_DIR="${PROJECT_ROOT}/tmp"
        if [[ -d "$TMP_DIR" ]]; then
            # Look for recent explore findings files (written in last 5 min)
            RECENT_FINDINGS=$(find "$TMP_DIR" -name "explore-findings*.md" -mmin -5 2>/dev/null | head -1)
            if [[ -n "$RECENT_FINDINGS" ]]; then
                SPILLOVER_EXISTS=true
            fi
        fi

        if [[ "$SPILLOVER_EXISTS" == "true" ]]; then
            # Agent complied with spillover but still returned too much
            ISSUES+=("Explore agent returned ~${WORD_COUNT} words despite writing spillover file. Return message should be ≤1500 tokens summary only.")
        else
            # Agent didn't comply — write overflow to disk as fallback
            mkdir -p "$TMP_DIR"
            TIMESTAMP=$(date +%Y%m%d-%H%M%S)
            OVERFLOW_FILE="${TMP_DIR}/explore-overflow-${TIMESTAMP}.md"
            echo "$RESPONSE_TEXT" > "$OVERFLOW_FILE"
            ISSUES+=("Explore agent returned ~${WORD_COUNT} words without spillover file. Full findings saved to tmp/explore-overflow-${TIMESTAMP}.md. Agent should write findings to tmp/explore-findings.md and return ≤1500 token summary.")
        fi
    fi
fi

# Build context message
CONTEXT=""
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    CONTEXT="Explore validation: ${#ISSUES[@]} issue(s)."
    for issue in "${ISSUES[@]}"; do
        CONTEXT+="\n- $issue"
    done
else
    CONTEXT="Explore validation: response size OK."
fi

# Persist findings for next-prompt injection
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    FINDINGS_FILE="${CLAUDE_DIR}/.agent-findings"
    mkdir -p "$(dirname "$FINDINGS_FILE")"
    FINDING="explore|$(IFS=';'; echo "${ISSUES[*]}")"
    if ! grep -qxF "$FINDING" "$FINDINGS_FILE" 2>/dev/null; then
        echo "$FINDING" >> "$FINDINGS_FILE"
    fi
    for issue in "${ISSUES[@]}"; do
        append_audit "$PROJECT_ROOT" "agent_explore" "$issue"
    done
fi

# Output as additionalContext
ESCAPED=$(echo -e "$CONTEXT" | jq -Rs .)
cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF

exit 0
