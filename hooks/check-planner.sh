#!/usr/bin/env bash
set -euo pipefail

# SubagentStop:planner — deterministic validation of planner output.
# Replaces AI agent hook. Checks MASTER_PLAN.md exists and has required structure.
# Parses PLAN_VERDICT and PLAN_SUMMARY trailers, submits a structured completion
# record via the local cc-policy runtime (Phase 6 slice 3). completions.py is the
# schema authority — this hook is advisory only (exit 0 always).
#
# DECISION: Deterministic planner validation. Rationale: AI agent hooks have
# non-deterministic runtime and cascade risk. Every check here is a grep/stat
# that completes in <1s. Status: accepted.

# shellcheck source=hooks/log.sh
source "$(dirname "$0")/log.sh"
# shellcheck source=hooks/context-lib.sh
source "$(dirname "$0")/context-lib.sh"

# Capture stdin (contains agent response)
AGENT_RESPONSE=$(read_input 2>/dev/null || echo "{}")
AGENT_TYPE=$(printf '%s' "$AGENT_RESPONSE" | jq -r '.agent_type // empty' 2>/dev/null || true)

PROJECT_ROOT=$(detect_project_root)
PLAN="$PROJECT_ROOT/MASTER_PLAN.md"

# Record hook start time for observatory duration metric.
_HOOK_START_AT=$(date +%s)

# ---------------------------------------------------------------------------
# Local runtime resolution — see post-task.sh DEC-BRIDGE-002 for rationale.
# ---------------------------------------------------------------------------
_HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
_LOCAL_RUNTIME_ROOT="$_HOOK_DIR/../runtime"
_local_cc_policy() {
    if [[ -z "${CLAUDE_POLICY_DB:-}" ]]; then
        _resolve_policy_db >/dev/null
    fi
    cc_policy_local_runtime "$_LOCAL_RUNTIME_ROOT" "$@"
}

# track_subagent_stop removed (TKT-008): .subagent-tracker no longer written.

# Deactivate runtime marker via lifecycle authority (DEC-LIFECYCLE-003).
# cc-policy lifecycle on-stop is the single authority for role-matched
# marker deactivation. It queries the active marker, matches its role to
# AGENT_TYPE, and deactivates — all in Python. No bash-side query needed.
# Pass project_root so the lifecycle authority only touches markers for this
# project; otherwise the globally newest active marker can be deactivated.
if [[ -n "$AGENT_TYPE" ]]; then
    _local_cc_policy lifecycle on-stop "$AGENT_TYPE" --project-root "$PROJECT_ROOT" >/dev/null 2>&1 || true
fi

# Release the seat and abandon every active supervision_thread touching it.
# DEC-SUPERVISION-THREADS-DOMAIN-001 continuation. Best-effort — seat-release
# failures must never block the hook. release_session_seat() is idempotent
# (repeat calls return released=false, abandoned_count=0) so retries on
# unexpected interrupts are safe.
SESSION_ID=$(printf '%s' "$AGENT_RESPONSE" | jq -r '.session_id // empty' 2>/dev/null || echo "")
if [[ -n "$SESSION_ID" && -n "$AGENT_TYPE" ]]; then
    _local_cc_policy dispatch seat-release \
        --session-id "$SESSION_ID" \
        --agent-type "$AGENT_TYPE" >/dev/null 2>&1 || true
fi

ISSUES=()
CONTEXT=""

# Check 1: MASTER_PLAN.md exists
if [[ ! -f "$PLAN" ]]; then
    ISSUES+=("MASTER_PLAN.md not found in project root")
else
    # Check 2: Has phase headers
    PHASE_COUNT=$(grep -cE '^\#\#\s+Phase\s+[0-9]' "$PLAN" 2>/dev/null || echo "0")
    if [[ "$PHASE_COUNT" -eq 0 ]]; then
        ISSUES+=("MASTER_PLAN.md has no ## Phase headers")
    fi

    # Check 3: Has intent/vision/purpose section
    if ! grep -qiE '^\#\#\s*(intent|vision|purpose|problem|overview|goal)' "$PLAN" 2>/dev/null; then
        # Also check for common first-section patterns
        if ! grep -qiE '^\#\#\s*(what|why|background|summary)' "$PLAN" 2>/dev/null; then
            ISSUES+=("MASTER_PLAN.md may lack an intent/vision section")
        fi
    fi

    # Check 4: Has git issues or tasks
    if ! grep -qiE 'issue|task|TODO|work.?item' "$PLAN" 2>/dev/null; then
        ISSUES+=("MASTER_PLAN.md may lack git issues or task breakdown")
    fi
fi

# Check 5: Approval-loop detection — agent should not end with unanswered question
RESPONSE_TEXT=$(echo "$AGENT_RESPONSE" | jq -r '.last_assistant_message // .assistant_response // .response // .result // .output // empty' 2>/dev/null || echo "")
if [[ -n "$RESPONSE_TEXT" ]]; then
    HAS_APPROVAL_QUESTION=$(echo "$RESPONSE_TEXT" | grep -iE 'do you (approve|confirm|want me to proceed)|shall I (proceed|continue|write)|ready to (begin|start|implement)\?' || echo "")
    HAS_COMPLETION=$(echo "$RESPONSE_TEXT" | grep -iE 'plan (complete|ready|written)|MASTER_PLAN\.md (created|written|updated)|created.*issues|phases defined' || echo "")

    if [[ -n "$HAS_APPROVAL_QUESTION" && -z "$HAS_COMPLETION" ]]; then
        ISSUES+=("Agent ended with approval question but no plan completion confirmation — may need follow-up")
    fi
fi

# ---------------------------------------------------------------------------
# Parse PLAN_* trailers (Phase 6 slice 3)
# Each trailer must appear on its own line as: TRAILER_NAME: value
# ---------------------------------------------------------------------------

_PLAN_VERDICT=""
_PLAN_SUMMARY=""

if [[ -n "$RESPONSE_TEXT" ]]; then
    _PLAN_VERDICT=$(printf '%s' "$RESPONSE_TEXT" \
        | grep -oE '^PLAN_VERDICT:[[:space:]]*[a-z_]+' \
        | head -1 \
        | sed 's/PLAN_VERDICT:[[:space:]]*//' || true)
    _PLAN_SUMMARY=$(printf '%s' "$RESPONSE_TEXT" \
        | grep -oE '^PLAN_SUMMARY:[[:space:]]*.*' \
        | head -1 \
        | sed 's/PLAN_SUMMARY:[[:space:]]*//' || true)
fi

# Advisory: flag missing trailers but do not invent fallback values.
# The completion validator in completions.py fail-closes on missing fields.
if [[ -z "$_PLAN_VERDICT" ]]; then
    ISSUES+=("No PLAN_VERDICT trailer found")
fi
if [[ -z "$_PLAN_SUMMARY" ]]; then
    ISSUES+=("No PLAN_SUMMARY trailer found")
fi

# --- Completion contract submission ---
# Submit a structured completion record for the planner role.
# If there is no active lease, do not invent a fallback — no completion record
# is submitted. Current live dispatch_engine routes planner unconditionally to
# guardian(provision) until Slice 4 wires completion consumption.
# Advisory: report but remain exit 0.
if ! is_claude_meta_repo "$PROJECT_ROOT"; then
    _PL_LEASE_CTX=$(_local_cc_policy lease current --worktree-path "$PROJECT_ROOT" 2>/dev/null || echo '{"found":false}')
    _PL_LEASE_FOUND=$(printf '%s' "$_PL_LEASE_CTX" | jq -r 'if (.found == true or .lease_id != null) then "true" else "false" end' 2>/dev/null || echo "false")
    if [[ "$_PL_LEASE_FOUND" == "true" ]]; then
        _PL_LEASE_ID=$(printf '%s' "$_PL_LEASE_CTX" | jq -r '.lease_id // empty' 2>/dev/null || true)
        _PL_WF_ID=$(printf '%s' "$_PL_LEASE_CTX" | jq -r '.workflow_id // empty' 2>/dev/null || true)
    else
        _PL_LEASE_ID=""
        _PL_WF_ID=""
    fi
    [[ -z "$_PL_WF_ID" ]] && _PL_WF_ID=$(current_workflow_id "$PROJECT_ROOT")

    if [[ -n "$_PL_LEASE_ID" ]]; then
        _PL_PAYLOAD=$(jq -n \
            --arg v "${_PLAN_VERDICT:-}" \
            --arg s "${_PLAN_SUMMARY:-}" \
            '{PLAN_VERDICT:$v, PLAN_SUMMARY:$s}')
        _PL_RESULT=$(_local_cc_policy completion submit \
            --lease-id "$_PL_LEASE_ID" \
            --workflow-id "$_PL_WF_ID" \
            --role "planner" \
            --payload "$_PL_PAYLOAD" 2>/dev/null || echo '{"valid":false}')
        _PL_VALID=$(printf '%s' "${_PL_RESULT:-}" | jq -r 'if .valid == 1 or .valid == true then "true" else "false" end' 2>/dev/null || echo "false")
        if [[ "$_PL_VALID" != "true" ]]; then
            _PL_MISSING=$(printf '%s' "$_PL_RESULT" | jq -r '.missing_fields | join(", ")' 2>/dev/null || echo "unknown")
            ISSUES+=("COMPLETION CONTRACT ERROR: Planner completion INVALID. Missing: $_PL_MISSING.")
        fi
    else
        ISSUES+=("No active lease found — planner completion not submitted. Live dispatch remains unconditional until Slice 4.")
    fi
fi

# Build context message
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    CONTEXT="Planner validation: ${#ISSUES[@]} issue(s) found."
    for issue in "${ISSUES[@]}"; do
        CONTEXT+="\n- $issue"
    done
else
    CONTEXT="Planner validation: MASTER_PLAN.md looks good ($PHASE_COUNT phases defined). verdict=${_PLAN_VERDICT:-none}."
fi

# Persist findings via runtime event store (flat file .agent-findings removed).
# Readers (prompt-submit.sh, compact-preserve.sh) query event query --type agent_finding.
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    for issue in "${ISSUES[@]}"; do
        rt_event_emit "agent_finding" "planner|${issue}" || true
        append_audit "$PROJECT_ROOT" "agent_planner" "$issue"
    done
fi

# Observatory: emit agent duration metric (W-OBS-2).
# _HOOK_START_AT is set near the top of this hook after PROJECT_ROOT is resolved.
_obs_duration=$(( $(date +%s) - _HOOK_START_AT ))
rt_obs_metric agent_duration_s "$_obs_duration" "{}" "" "planner" || true

# Output as additionalContext
ESCAPED=$(echo -e "$CONTEXT" | jq -Rs .)
cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF

exit 0
