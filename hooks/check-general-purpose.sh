#!/usr/bin/env bash
# SubagentStop:general-purpose — trace finalization for general-purpose agents.
# General-purpose agents are ad-hoc subagents dispatched without a specific role
# (implementer/planner/tester/guardian/explore). Without this handler, any trace
# they initialize will remain permanently "active" (orphaned) in the trace store.
#
# This hook is lightweight: it tracks the stop, finalizes the trace, and exits.
# No validation checks — general-purpose agents have no defined output contract.
#
# @decision DEC-GENERAL-STOP-001
# @title Add SubagentStop handler for general-purpose agents
# @status accepted
# @rationale General-purpose agents (matcher: "general-purpose" in settings.json)
#   have no SubagentStop handler, so their traces are never finalized. This creates
#   orphaned "active" traces in the trace store that inflate active-agent counts and
#   are never indexed. This handler mirrors the minimal pattern from check-explore.sh
#   but without overflow-detection logic (general-purpose agents have no response
#   size contract). If detect_active_trace returns empty, we log to audit — this is
#   expected for general-purpose agents that didn't initialize a trace.
set -euo pipefail

source "$(dirname "$0")/source-lib.sh"

# Capture stdin (contains agent response)
AGENT_RESPONSE=$(read_input 2>/dev/null || echo "{}")

# Diagnostic: log SubagentStop payload keys for field-name investigation (Issue #TBD)
if [[ -n "$AGENT_RESPONSE" && "$AGENT_RESPONSE" != "{}" ]]; then
    PAYLOAD_KEYS=$(echo "$AGENT_RESPONSE" | jq -r 'keys[]' 2>/dev/null | tr '\n' ',' || echo "unknown")
    PAYLOAD_SIZE=${#AGENT_RESPONSE}
    echo "check-general-purpose: SubagentStop payload keys=[$PAYLOAD_KEYS] size=${PAYLOAD_SIZE}" >&2
fi

PROJECT_ROOT=$(detect_project_root)

# Track subagent completion
track_subagent_stop "$PROJECT_ROOT" "general-purpose"
append_session_event "agent_stop" "{\"type\":\"general-purpose\"}" "$PROJECT_ROOT"

# --- Trace protocol: finalize active general-purpose trace ---
# general-purpose agents may not always initialize a trace, so an empty
# detect_active_trace result is expected and logged rather than treated as error.
TRACE_ID=$(detect_active_trace "$PROJECT_ROOT" "general-purpose" 2>/dev/null || echo "")
if [[ -n "$TRACE_ID" ]]; then
    TRACE_DIR_PATH="${TRACE_STORE}/${TRACE_ID}"
    # Auto-write summary.md from response text if agent didn't write it or wrote empty file
    # -s checks file exists AND has size > 0 (catches 1-byte empty files)
    # Field name confirmed from Claude Code docs: SubagentStop payload uses `last_assistant_message`.
    # `.response` kept as fallback for backward compatibility with any non-standard payloads.
    RESPONSE_TEXT=$(echo "$AGENT_RESPONSE" | jq -r '.last_assistant_message // .response // empty' 2>/dev/null || echo "")
    if [[ ! -s "$TRACE_DIR_PATH/summary.md" && -n "$RESPONSE_TEXT" ]]; then
        echo "$RESPONSE_TEXT" | head -c 4000 > "$TRACE_DIR_PATH/summary.md" 2>/dev/null || true
    fi
    if ! finalize_trace "$TRACE_ID" "$PROJECT_ROOT" "general-purpose"; then
        append_audit "$PROJECT_ROOT" "trace_orphan" "finalize_trace failed for general-purpose trace $TRACE_ID"
    fi
else
    # trace_skip (not trace_orphan): general-purpose agents DO get trace init
    # (fall-through to * in subagent-start.sh), but init_trace can fail silently
    # (stderr redirected to /dev/null). This is informational, not a real orphan
    # (Issue #123 Fix 2).
    append_audit "$PROJECT_ROOT" "trace_skip" "detect_active_trace returned empty for general-purpose — no trace to finalize"
fi

# Output minimal additionalContext
cat <<'EOF'
{
  "additionalContext": "General-purpose agent stop: trace finalized."
}
EOF

exit 0
