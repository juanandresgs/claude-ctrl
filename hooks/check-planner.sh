#!/usr/bin/env bash
# SubagentStop:planner — deterministic validation of planner output.
# Replaces AI agent hook. Checks MASTER_PLAN.md exists and has required structure.
# Advisory only (exit 0 always). Reports findings via additionalContext.
#
# Ordering: trace finalization runs FIRST (immediately after PROJECT_ROOT detection)
# so it completes within the 5s timeout even when git/plan state checks are slow.
#
# @decision DEC-PLANNER-STOP-001
# @title Deterministic planner validation
# @status accepted
# @rationale AI agent hooks have non-deterministic runtime and cascade risk.
#   Every check here is a grep/stat that completes in <1s.
#
# @decision DEC-PLANNER-STOP-002
# @title Move finalize_trace before git/plan state checks to beat timeout
# @status accepted
# @rationale The 5s hook timeout was causing finalize_trace to be skipped when
#   get_git_state and get_plan_status ran first and consumed most of the budget.
#   Moving trace detection + finalization immediately after PROJECT_ROOT detection
#   ensures the trace is sealed even when downstream advisory checks time out.
#   Error logging via append_audit captures finalization failures for diagnosis.
set -euo pipefail

source "$(dirname "$0")/source-lib.sh"

# Capture stdin (contains agent response)
AGENT_RESPONSE=$(read_input 2>/dev/null || echo "{}")

# Diagnostic: log SubagentStop payload keys for field-name investigation (Issue #TBD)
if [[ -n "$AGENT_RESPONSE" && "$AGENT_RESPONSE" != "{}" ]]; then
    PAYLOAD_KEYS=$(echo "$AGENT_RESPONSE" | jq -r 'keys[]' 2>/dev/null | tr '\n' ',' || echo "unknown")
    PAYLOAD_SIZE=${#AGENT_RESPONSE}
    echo "check-planner: SubagentStop payload keys=[$PAYLOAD_KEYS] size=${PAYLOAD_SIZE}" >&2
fi

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)
PLAN="$PROJECT_ROOT/MASTER_PLAN.md"

# Track subagent completion
track_subagent_stop "$PROJECT_ROOT" "planner"
append_session_event "agent_stop" "{\"type\":\"planner\"}" "$PROJECT_ROOT"

# Extract response text early — needed for both finalization and checks
# Field name confirmed from Claude Code docs: SubagentStop payload uses `last_assistant_message`.
# `.response` kept as fallback for backward compatibility with any non-standard payloads.
RESPONSE_TEXT=$(echo "$AGENT_RESPONSE" | jq -r '.last_assistant_message // .response // empty' 2>/dev/null || echo "")

# --- Trace protocol: finalize trace (RUNS FIRST to beat timeout) ---
TRACE_ID=$(detect_active_trace "$PROJECT_ROOT" "planner" 2>/dev/null || echo "")
TRACE_DIR=""
if [[ -n "$TRACE_ID" ]]; then
    TRACE_DIR="${TRACE_STORE}/${TRACE_ID}"
    # Use 10-byte minimum threshold instead of -s (size > 0).
    # See DEC-PLANNER-STOP-003: -s passes for a 1-byte newline written when
    # RESPONSE_TEXT is empty (max_turns exhausted or force-stopped).
    #
    # @decision DEC-PLANNER-STOP-003
    # @title Use 10-byte minimum threshold for planner summary.md fallback check
    # @status accepted
    # @rationale Same root cause as DEC-IMPL-STOP-003: the -s check passes for a
    #   1-byte newline written when RESPONSE_TEXT is empty. The 10-byte threshold
    #   catches both missing and trivially empty summary files. When RESPONSE_TEXT
    #   is empty, a diagnostic message is written instead so the orchestrator has
    #   context about why the planner stopped without producing output.
    _sum_size=$(wc -c < "$TRACE_DIR/summary.md" 2>/dev/null || echo 0)
    if [[ ! -f "$TRACE_DIR/summary.md" ]] || [[ "$_sum_size" -lt 10 ]]; then
        if [[ -z "${RESPONSE_TEXT// /}" ]]; then
            {
                echo "# Agent returned empty response ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
                echo "Agent type: planner"
                echo "Duration: ${SECONDS:-unknown}s"
                echo "Likely cause: max_turns exhausted or force-stopped"
            } > "$TRACE_DIR/summary.md" 2>/dev/null || true
        else
            echo "$RESPONSE_TEXT" | head -c 4000 > "$TRACE_DIR/summary.md" 2>/dev/null || true
        fi
    fi
    if ! finalize_trace "$TRACE_ID" "$PROJECT_ROOT" "planner"; then
        append_audit "$PROJECT_ROOT" "trace_orphan" "finalize_trace failed for planner trace $TRACE_ID"
    fi

    # --- Observatory Phase 1: Write compliance.json for planner trace ---
    # Planners write summary.md as their primary artifact. No auto-capture runs
    # for planners, so any artifact present was written by the agent.
    # @decision DEC-OBS-V2-001
    # @title Snapshot artifact existence before auto-capture for compliance attribution
    # @status accepted
    # @rationale The observatory needs to know whether agents wrote artifacts themselves.
    #   Planners have no auto-capture blocks, so all artifacts are agent-sourced.
    _pl_sm_present=false; _pl_sm_source="null"
    [[ -f "$TRACE_DIR/summary.md" ]] && _pl_sm_present=true && _pl_sm_source='"agent"'

    cat > "$TRACE_DIR/compliance.json" << COMPLIANCE_PLANNER_EOF
{
  "agent_type": "planner",
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "artifacts": {
    "summary.md": {"present": $_pl_sm_present, "source": $_pl_sm_source}
  },
  "test_result": "not-provided",
  "test_result_source": null,
  "issues_count": 0
}
COMPLIANCE_PLANNER_EOF
fi

# --- Advisory checks (run after finalize to avoid timeout races) ---
get_git_state "$PROJECT_ROOT"
get_plan_status "$PROJECT_ROOT"
write_statusline_cache "$PROJECT_ROOT"

ISSUES=()
CONTEXT=""
INITIATIVE_COUNT=0
PHASE_COUNT=0

# Layer A: Surface trace context when agent response is short.
# Short returns are normal under Trace Protocol — only flag when genuinely lost.
# See DEC-SILENT-RETURN-001 in check-guardian.sh for rationale.
if [[ ${#RESPONSE_TEXT} -lt 50 ]]; then
    _has_trace="false"
    if [[ -n "$TRACE_DIR" && -f "$TRACE_DIR/summary.md" ]]; then
        _trace_size=$(wc -c < "$TRACE_DIR/summary.md" 2>/dev/null || echo 0)
        [[ "$_trace_size" -gt 10 ]] && _has_trace="true"
    fi
    if [[ "$_has_trace" == "false" && -z "${RESPONSE_TEXT// /}" ]]; then
        ISSUES+=("Agent returned no response and no trace summary available. Check git log for what happened.")
    fi
fi

# Check 1: MASTER_PLAN.md exists
if [[ ! -f "$PLAN" ]]; then
    ISSUES+=("MASTER_PLAN.md not found in project root")
else
    # Detect format: living-document (### Initiative: headers) vs legacy (## Phase N)
    INITIATIVE_COUNT=$(grep -cE '^\#\#\#\s+Initiative:' "$PLAN" 2>/dev/null || echo "0")
    PHASE_COUNT=$(grep -cE '^\#\#\s+Phase\s+[0-9]|^\#{4,5}\s+Phase\s+[0-9]' "$PLAN" 2>/dev/null || echo "0")

    if [[ "$INITIATIVE_COUNT" -gt 0 ]]; then
        # --- Living-document format validation ---

        # Check 2: Has ## Identity section (replaces ## Project Overview)
        if ! grep -q '^## Identity' "$PLAN" 2>/dev/null; then
            ISSUES+=("MASTER_PLAN.md lacks ## Identity section — living-document format requires it for session context")
        fi

        # Check 2b: Has ## Architecture section
        if ! grep -q '^## Architecture' "$PLAN" 2>/dev/null; then
            ISSUES+=("MASTER_PLAN.md lacks ## Architecture section — agents need architecture context at startup")
        fi

        # Check 2c: Has ## Active Initiatives section
        if ! grep -q '^## Active Initiatives' "$PLAN" 2>/dev/null; then
            ISSUES+=("MASTER_PLAN.md lacks ## Active Initiatives section — required for initiative-level lifecycle")
        fi

        # Check 2d: Has ## Decision Log section
        if ! grep -q '^## Decision Log' "$PLAN" 2>/dev/null; then
            ISSUES+=("MASTER_PLAN.md lacks ## Decision Log section — required for institutional memory")
        fi

        # Check 3: Each initiative has a **Status:** field
        INITIATIVES_WITHOUT_STATUS=0
        while IFS= read -r line; do
            if echo "$line" | grep -qE '^\#\#\#\s+Initiative:'; then
                INITIATIVES_WITHOUT_STATUS=$((INITIATIVES_WITHOUT_STATUS + 1))
            elif echo "$line" | grep -qE '^\*\*Status:\*\*'; then
                INITIATIVES_WITHOUT_STATUS=$((INITIATIVES_WITHOUT_STATUS - 1))
            fi
        done < "$PLAN"
        # Note: simple heuristic — counts net unmatched initiatives
        if [[ "$INITIATIVES_WITHOUT_STATUS" -gt 0 ]]; then
            ISSUES+=("$INITIATIVES_WITHOUT_STATUS initiative(s) may lack **Status:** field — required for lifecycle detection")
        fi

        # Check 4: Has git issues or tasks within active initiatives
        if ! grep -qiE 'issue|task|TODO|work.?item' "$PLAN" 2>/dev/null; then
            ISSUES+=("MASTER_PLAN.md may lack git issues or task breakdown")
        fi

        # Check 5: Has at least one active initiative with requirements
        ACTIVE_COUNT=$(get_plan_status "$PROJECT_ROOT" 2>/dev/null; echo "${PLAN_ACTIVE_INITIATIVES:-0}")
        # Re-run get_plan_status (already called above) — use the exported variable
        if [[ "${PLAN_ACTIVE_INITIATIVES:-0}" -gt 0 ]]; then
            # Validate that active initiative has Goals section
            ACTIVE_SECTION=$(awk '/^## Active Initiatives/{f=1} f && /^## Completed Initiatives|^## Parked/{exit} f{print}' "$PLAN" 2>/dev/null || echo "")
            if [[ -n "$ACTIVE_SECTION" ]]; then
                if ! echo "$ACTIVE_SECTION" | grep -qiE '^\#\#\#\#\s*(Goals|Requirements|Must.Have)'; then
                    ISSUES+=("Active initiative(s) may lack structured Goals/Requirements sections")
                fi
            fi
        fi

    else
        # --- Legacy format validation (backward compat) ---

        # Check 2: Has phase headers
        if [[ "$PHASE_COUNT" -eq 0 ]]; then
            ISSUES+=("MASTER_PLAN.md has no ## Phase headers or ### Initiative: headers — neither format detected")
        fi

        # Check 2b: Has Project Overview or Identity section
        if ! grep -qE '^## (Project Overview|Identity)' "$PLAN" 2>/dev/null; then
            ISSUES+=("MASTER_PLAN.md lacks ## Project Overview or ## Identity section — new sessions won't have project context")
        fi

        # Check 3: Has intent/vision/purpose section
        if ! grep -qiE '^\#\#\s*(intent|vision|purpose|problem|overview|goal)' "$PLAN" 2>/dev/null; then
            if ! grep -qiE '^\#\#\s*(what|why|background|summary|identity)' "$PLAN" 2>/dev/null; then
                ISSUES+=("MASTER_PLAN.md may lack an intent/vision section")
            fi
        fi

        # Check 4: Has git issues or tasks
        if ! grep -qiE 'issue|task|TODO|work.?item' "$PLAN" 2>/dev/null; then
            ISSUES+=("MASTER_PLAN.md may lack git issues or task breakdown")
        fi

        # Check 6: Has structured requirements sections (Goals, Non-Goals, Requirements)
        # Only flag for multi-phase plans — single-phase plans (Tier 1) are expected to be brief
        if [[ "$PHASE_COUNT" -gt 1 ]]; then
            HAS_REQS=true
            if ! grep -qiE '^\#\#\s*(Goals|Goals\s*&\s*Non.Goals)' "$PLAN" 2>/dev/null; then
                HAS_REQS=false
            fi
            if ! grep -qiE '^\#\#\s*Requirements|^\#\#\#\s*Must.Have' "$PLAN" 2>/dev/null; then
                HAS_REQS=false
            fi
            if [[ "$HAS_REQS" == "false" ]]; then
                ISSUES+=("MASTER_PLAN.md may lack structured requirements (Goals, Non-Goals, Requirements with P0/P1/P2)")
            fi
        fi
    fi
fi

# Check 5: Approval-loop detection — agent should not end with unanswered question
if [[ -n "$RESPONSE_TEXT" ]]; then
    HAS_APPROVAL_QUESTION=$(echo "$RESPONSE_TEXT" | grep -iE 'do you (approve|confirm|want me to proceed)|shall I (proceed|continue|write)|ready to (begin|start|implement)\?' || echo "")
    HAS_COMPLETION=$(echo "$RESPONSE_TEXT" | grep -iE 'plan (complete|ready|written)|MASTER_PLAN\.md (created|written|updated)|created.*issues|phases defined' || echo "")

    if [[ -n "$HAS_APPROVAL_QUESTION" && -z "$HAS_COMPLETION" ]]; then
        ISSUES+=("Agent ended with approval question but no plan completion confirmation — may need follow-up")
    fi
fi

# Response size advisory
if [[ -n "$RESPONSE_TEXT" ]]; then
    WORD_COUNT=$(echo "$RESPONSE_TEXT" | wc -w | tr -d ' ')
    if [[ "$WORD_COUNT" -gt 1200 ]]; then
        ISSUES+=("Agent response too large (~${WORD_COUNT} words). Use TRACE_DIR for verbose output.")
    fi
fi

# Build context message
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    CONTEXT="Planner validation: ${#ISSUES[@]} issue(s) found."
    for issue in "${ISSUES[@]}"; do
        CONTEXT+="\n- $issue"
    done
else
    if [[ "$INITIATIVE_COUNT" -gt 0 ]]; then
        CONTEXT="Planner validation: MASTER_PLAN.md looks good ($INITIATIVE_COUNT initiative(s), $PHASE_COUNT phases)."
    else
        CONTEXT="Planner validation: MASTER_PLAN.md looks good ($PHASE_COUNT phases defined)."
    fi
fi

# Persist findings for next-prompt injection
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    FINDINGS_FILE="${CLAUDE_DIR}/.agent-findings"
    mkdir -p "${PROJECT_ROOT}/.claude"
    FINDING="planner|$(IFS=';'; echo "${ISSUES[*]}")"
    if ! grep -qxF "$FINDING" "$FINDINGS_FILE" 2>/dev/null; then
        echo "$FINDING" >> "$FINDINGS_FILE"
    fi
    for issue in "${ISSUES[@]}"; do
        append_audit "$PROJECT_ROOT" "agent_planner" "$issue"
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
