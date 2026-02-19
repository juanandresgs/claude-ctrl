#!/usr/bin/env bash
# SubagentStop:Explore — overflow detection, spillover-to-disk fallback, and trace finalization.
# When Explore agents return >1200 words without writing a temp file,
# this hook saves the overflow to disk and flags it for the orchestrator.
# Also finalizes any active trace so explore agents do not leave orphaned traces.
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
#
# @decision DEC-EXPLORE-STOP-002
# @title Add trace finalization to check-explore.sh
# @status accepted
# @rationale Explore agents use init_trace/finalize_trace like other agent types,
#   but check-explore.sh previously never called finalize_trace. This caused explore
#   traces to remain permanently "active" in the trace store (orphaned). Adding
#   finalize_trace here ensures explore traces are sealed at SubagentStop time,
#   consistent with implementer, planner, and tester handlers. If detect_active_trace
#   returns empty (no trace was initialized), we log to audit rather than error.
set -euo pipefail

source "$(dirname "$0")/source-lib.sh"

# Capture stdin (contains agent response)
AGENT_RESPONSE=$(read_input 2>/dev/null || echo "{}")

# Diagnostic: log SubagentStop payload keys for field-name investigation (Issue #TBD)
if [[ -n "$AGENT_RESPONSE" && "$AGENT_RESPONSE" != "{}" ]]; then
    PAYLOAD_KEYS=$(echo "$AGENT_RESPONSE" | jq -r 'keys[]' 2>/dev/null | tr '\n' ',' || echo "unknown")
    PAYLOAD_SIZE=${#AGENT_RESPONSE}
    echo "check-explore: SubagentStop payload keys=[$PAYLOAD_KEYS] size=${PAYLOAD_SIZE}" >&2
fi

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)

# Track subagent completion
track_subagent_stop "$PROJECT_ROOT" "explore"
append_session_event "agent_stop" "{\"type\":\"explore\"}" "$PROJECT_ROOT"

# --- Trace protocol: finalize active explore trace ---
# Runs before overflow-detection logic to avoid timeout races.
# If no active trace exists, log to audit (not an error — explore agents don't
# always use the trace protocol, especially for quick lookups).
TRACE_ID=$(detect_active_trace "$PROJECT_ROOT" "explore" 2>/dev/null || echo "")
if [[ -n "$TRACE_ID" ]]; then
    TRACE_DIR_PATH="${TRACE_STORE}/${TRACE_ID}"
    # Auto-write summary.md from response text if agent didn't write it or wrote empty file
    # -s checks file exists AND has size > 0 (catches 1-byte empty files)
    EXPLORE_RESPONSE_TEXT=$(echo "$AGENT_RESPONSE" | jq -r '.response // .result // .output // empty' 2>/dev/null || echo "")
    if [[ ! -s "$TRACE_DIR_PATH/summary.md" && -n "$EXPLORE_RESPONSE_TEXT" ]]; then
        echo "$EXPLORE_RESPONSE_TEXT" | head -c 4000 > "$TRACE_DIR_PATH/summary.md" 2>/dev/null || true
    fi
    if ! finalize_trace "$TRACE_ID" "$PROJECT_ROOT" "explore"; then
        append_audit "$PROJECT_ROOT" "trace_orphan" "finalize_trace failed for explore trace $TRACE_ID"
    fi
else
    append_audit "$PROJECT_ROOT" "trace_orphan" "detect_active_trace returned empty for explore — no trace to finalize"
fi

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
