#!/usr/bin/env bash
# hooks/check-governor.sh — SubagentStop validation for governor agent
#
# Validates governor assessment output (evaluation.json + evaluation-summary.md),
# extracts verdict, and emits advisory context to the orchestrator.
# Governor results are ALWAYS advisory — this hook never blocks.
#
# @decision DEC-GOV-005
# @title Read-only tools plus trace artifact writes — advisory only
# @status accepted
# @rationale Governor evaluates and reports, never acts. Exit 0 always.
#   The governor is a read-only evaluator whose job is to assess whether
#   the orchestrator should proceed, caution, or block a pending operation.
#   Making this hook non-blocking ensures a governor crash or empty return
#   never interrupts the workflow — the orchestrator can always check the
#   trace directly if the hook context is sparse.
#
# @decision DEC-GOV-HOOK-001
# @title Layer A silent return recovery for governor hook
# @status accepted
# @rationale When the governor's final turn is a bare tool call (no text),
#   the Task tool returns empty to the orchestrator. This hook detects that
#   case (response < 50 chars) and injects the trace summary into
#   additionalContext so the orchestrator receives work context via
#   system-reminder even on silent returns. Pattern mirrors check-implementer.sh
#   Layer A, without the blocking behavior.
set -euo pipefail

source "$(dirname "$0")/source-lib.sh"

require_session
require_trace

# Capture stdin (contains agent response)
AGENT_RESPONSE=$(read_input 2>/dev/null || echo "{}")

# Diagnostic: log SubagentStop payload keys for field-name investigation
if [[ -n "$AGENT_RESPONSE" && "$AGENT_RESPONSE" != "{}" ]]; then
    PAYLOAD_KEYS=$(echo "$AGENT_RESPONSE" | jq -r 'keys[]' 2>/dev/null | tr '\n' ',' || echo "unknown")
    PAYLOAD_SIZE=${#AGENT_RESPONSE}
    echo "check-governor: SubagentStop payload keys=[$PAYLOAD_KEYS] size=${PAYLOAD_SIZE}" >&2
fi

PROJECT_ROOT=$(detect_project_root)

# Track subagent completion and tokens
track_subagent_stop "$PROJECT_ROOT" "governor"
track_agent_tokens "$AGENT_RESPONSE"
append_session_event "agent_stop" "{\"type\":\"governor\"}" "$PROJECT_ROOT"

# --- Trace protocol: finalize active governor trace (runs first to beat timeout) ---
# Field name confirmed from Claude Code docs: SubagentStop uses `last_assistant_message`.
# `.response` kept as fallback for backward compatibility.
RESPONSE_TEXT=$(echo "$AGENT_RESPONSE" | jq -r '.last_assistant_message // .response // empty' 2>/dev/null || echo "")

TRACE_ID=$(detect_active_trace "$PROJECT_ROOT" "governor" 2>/dev/null || echo "")
TRACE_DIR=""
if [[ -n "$TRACE_ID" ]]; then
    TRACE_DIR="${TRACE_STORE}/${TRACE_ID}"

    # Summary.md fallback: 10-byte minimum threshold (catches trivial 1-byte newlines)
    _sum_size=0
    [[ -f "$TRACE_DIR/summary.md" ]] && _sum_size=$(wc -c < "$TRACE_DIR/summary.md" 2>/dev/null || echo 0)
    if [[ ! -f "$TRACE_DIR/summary.md" ]] || [[ "$_sum_size" -lt 10 ]]; then
        if [[ -z "${RESPONSE_TEXT// /}" ]]; then
            {
                echo "# Governor returned empty response ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
                echo "Agent type: governor"
                echo "Likely cause: max_turns exhausted or force-stopped"
            } > "$TRACE_DIR/summary.md" 2>/dev/null || true
        else
            echo "$RESPONSE_TEXT" | head -c 4000 > "$TRACE_DIR/summary.md" 2>/dev/null || true
        fi
    fi

    if ! finalize_trace "$TRACE_ID" "$PROJECT_ROOT" "governor"; then
        append_audit "$PROJECT_ROOT" "trace_orphan" "finalize_trace failed for governor trace $TRACE_ID"
    fi
else
    append_audit "$PROJECT_ROOT" "trace_skip" "detect_active_trace returned empty for governor — no trace to finalize"
fi

# --- Validate assessment artifacts ---
# Governor must write evaluation.json + evaluation-summary.md to TRACE_DIR/artifacts/
VERDICT=""
CONTEXT=""

if [[ -n "$TRACE_DIR" && -d "$TRACE_DIR/artifacts" ]]; then
    EVAL_JSON="$TRACE_DIR/artifacts/evaluation.json"
    EVAL_SUMMARY="$TRACE_DIR/artifacts/evaluation-summary.md"

    EVAL_JSON_OK=false
    EVAL_SUMMARY_OK=false

    # Validate evaluation.json exists and is valid JSON
    if [[ -f "$EVAL_JSON" ]]; then
        if python3 -c "import json; json.load(open('$EVAL_JSON'))" 2>/dev/null; then
            EVAL_JSON_OK=true
            # Extract verdict
            VERDICT=$(python3 -c "import json; d=json.load(open('$EVAL_JSON')); print(d.get('verdict','unknown'))" 2>/dev/null || echo "unknown")
        else
            append_audit "$PROJECT_ROOT" "agent_governor" "evaluation.json exists but is invalid JSON"
        fi
    fi

    # Validate evaluation-summary.md exists and is non-empty (>10 bytes)
    if [[ -f "$EVAL_SUMMARY" ]]; then
        _sum_sz=$(wc -c < "$EVAL_SUMMARY" 2>/dev/null || echo 0)
        [[ "$_sum_sz" -gt 10 ]] && EVAL_SUMMARY_OK=true
    fi

    if $EVAL_JSON_OK && $EVAL_SUMMARY_OK; then
        # Extract first flag or first line of narrative for inline context
        FIRST_FLAG=$(python3 -c "
import json
d = json.load(open('$EVAL_JSON'))
flags = d.get('flags', d.get('issues', d.get('concerns', [])))
if flags and isinstance(flags, list):
    print(str(flags[0])[:120])
elif d.get('narrative'):
    print(str(d['narrative'])[:120])
" 2>/dev/null || echo "")

        if [[ -n "$FIRST_FLAG" ]]; then
            CONTEXT="Governor assessment: verdict=${VERDICT}. ${FIRST_FLAG}. Full assessment: ${TRACE_DIR}/artifacts/evaluation-summary.md"
        else
            CONTEXT="Governor assessment: verdict=${VERDICT}. Full assessment: ${TRACE_DIR}/artifacts/evaluation-summary.md"
        fi
    else
        # Layer A: try to surface trace summary when artifacts are missing
        _inj_summary=""
        if [[ -n "$TRACE_DIR" && -f "$TRACE_DIR/summary.md" ]]; then
            _inj_summary=$(head -c 2000 "$TRACE_DIR/summary.md" 2>/dev/null || echo "")
        fi

        if [[ -n "$_inj_summary" ]]; then
            CONTEXT="Governor returned without complete assessment artifacts (evaluation.json=${EVAL_JSON_OK}, evaluation-summary.md=${EVAL_SUMMARY_OK}). Trace summary: ${_inj_summary}"
        else
            CONTEXT="Governor returned without assessment artifacts. Check trace at ${TRACE_DIR}"
        fi
        append_audit "$PROJECT_ROOT" "agent_governor" "missing artifacts: evaluation.json=${EVAL_JSON_OK} evaluation-summary.md=${EVAL_SUMMARY_OK}"
    fi
else
    # No TRACE_DIR — silent return recovery (Layer A)
    _inj_summary=""
    if [[ ${#RESPONSE_TEXT} -lt 50 ]]; then
        CONTEXT="Governor returned no response and no trace available."
    else
        # Governor returned text but no trace — use the response as context
        _preview=$(echo "$RESPONSE_TEXT" | head -c 500)
        CONTEXT="Governor assessment (no trace): ${_preview}"
    fi
fi

# Output as additionalContext — always exit 0 (advisory only)
ESCAPED=$(printf '%s' "$CONTEXT" | jq -Rs .)
cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF

exit 0
