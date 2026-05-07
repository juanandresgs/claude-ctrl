#!/usr/bin/env bash
set -euo pipefail

# SubagentStop:reviewer — deterministic validation of reviewer output.
# Advisory only (exit 0 always). Reports findings via additionalContext.
#
# Parses REVIEW_* trailers from the reviewer's response and submits a
# structured completion record via cc-policy completion submit --role reviewer.
# The completion record is consumed by dispatch_engine.process_agent_stop()
# for routing decisions.
#
# REVIEW_VERDICT        : ready_for_guardian | needs_changes | blocked_by_plan
# REVIEW_HEAD_SHA       : <non-empty sha-ish token>
# REVIEW_FINDINGS_JSON  : <single-line JSON object with "findings" key>
#
# This hook does NOT write evaluation_state. It submits the reviewer completion
# record; dispatch_engine then projects valid reviewer readiness into
# evaluation_state after reviewer_convergence checks completion_records and the
# reviewer findings table. The retired tester eval state pipeline remains gone.
#
# @decision DEC-CHECK-REVIEWER-001
# @title check-reviewer.sh is a thin deterministic SubagentStop adapter for reviewer output
# @status accepted
# @rationale Phase 4 introduces the reviewer as a first-class workflow stage.
#   The reviewer needs a SubagentStop hook to parse REVIEW_* trailers and submit
#   a structured completion record before post-task.sh runs dispatch routing.
#   The hook follows the same local runtime resolution and lease_context pattern
#   as other SubagentStop adapters (e.g. check-guardian.sh) but is deliberately
#   simpler: no evaluation_state writes, no BUG_FINDING parsing, no legacy
#   advisory checks.
#   The completion validation (verdict vocabulary, findings JSON structure) is
#   owned by completions.py, not this hook — the hook is a transport adapter.

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

AGENT_RESPONSE=$(read_input 2>/dev/null || echo "{}")
seed_project_dir_from_hook_payload_cwd "$AGENT_RESPONSE"
AGENT_TYPE=$(printf '%s' "$AGENT_RESPONSE" | jq -r '.agent_type // empty' 2>/dev/null || true)
PROJECT_ROOT=$(detect_project_root)

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

# Deactivate runtime marker via lifecycle authority (DEC-LIFECYCLE-003).
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
RESPONSE_TEXT=$(agent_response_text "$AGENT_RESPONSE")

# ---------------------------------------------------------------------------
# Parse REVIEW_* trailers
# Each trailer must appear on its own line as: TRAILER_NAME: value
# ---------------------------------------------------------------------------

_REVIEW_VERDICT=""
_REVIEW_HEAD_SHA=""
_REVIEW_FINDINGS_JSON=""

if [[ -n "$RESPONSE_TEXT" ]]; then
    _REVIEW_VERDICT=$(printf '%s' "$RESPONSE_TEXT" \
        | grep -oE '^REVIEW_VERDICT:[[:space:]]*[a-z_]+' \
        | head -1 \
        | sed 's/REVIEW_VERDICT:[[:space:]]*//' || true)
    _REVIEW_HEAD_SHA=$(printf '%s' "$RESPONSE_TEXT" \
        | grep -oE '^REVIEW_HEAD_SHA:[[:space:]]*[0-9a-fA-F]+' \
        | head -1 \
        | sed 's/REVIEW_HEAD_SHA:[[:space:]]*//' || true)
    # REVIEW_FINDINGS_JSON is everything after the trailer prefix on a single line.
    # The JSON is validated by completions.submit(), not by this hook.
    _REVIEW_FINDINGS_JSON=$(printf '%s' "$RESPONSE_TEXT" \
        | grep -oE '^REVIEW_FINDINGS_JSON:[[:space:]]*\{.*\}' \
        | head -1 \
        | sed 's/REVIEW_FINDINGS_JSON:[[:space:]]*//' || true)
fi

# Advisory: flag missing trailers but do not invent fallback values.
# The completion validator in completions.py fail-closes on missing fields.
if [[ -z "$_REVIEW_VERDICT" ]]; then
    ISSUES+=("No REVIEW_VERDICT trailer found")
fi
if [[ -z "$_REVIEW_HEAD_SHA" ]]; then
    ISSUES+=("No REVIEW_HEAD_SHA trailer found")
fi
if [[ -z "$_REVIEW_FINDINGS_JSON" ]]; then
    ISSUES+=("No REVIEW_FINDINGS_JSON trailer found")
fi

# --- Completion contract submission ---
# Submit a structured completion record for the reviewer role.
# If there is no active lease, do not invent a fallback; post-task.sh/dispatch
# will fail closed. Advisory: report but remain exit 0.
if ! is_claude_meta_repo "$PROJECT_ROOT"; then
    # WS1: use lease_context() to derive workflow_id from the active lease.
    _RV_LEASE_CTX=$(_local_cc_policy lease current --worktree-path "$PROJECT_ROOT" 2>/dev/null || echo '{"found":false}')
    _RV_LEASE_FOUND=$(printf '%s' "$_RV_LEASE_CTX" | jq -r 'if (.found == true or .lease_id != null) then "true" else "false" end' 2>/dev/null || echo "false")
    if [[ "$_RV_LEASE_FOUND" == "true" ]]; then
        _RV_LEASE_ID=$(printf '%s' "$_RV_LEASE_CTX" | jq -r '.lease_id // empty' 2>/dev/null || true)
        _RV_WF_ID=$(printf '%s' "$_RV_LEASE_CTX" | jq -r '.workflow_id // empty' 2>/dev/null || true)
    else
        _RV_LEASE_ID=""
        _RV_WF_ID=""
    fi
    [[ -z "$_RV_WF_ID" ]] && _RV_WF_ID=$(current_workflow_id "$PROJECT_ROOT")

    if [[ -n "$_RV_LEASE_ID" ]]; then
        _RV_PAYLOAD=$(jq -n \
            --arg v "${_REVIEW_VERDICT:-}" \
            --arg h "${_REVIEW_HEAD_SHA:-}" \
            --arg f "${_REVIEW_FINDINGS_JSON:-}" \
            '{REVIEW_VERDICT:$v, REVIEW_HEAD_SHA:$h, REVIEW_FINDINGS_JSON:$f}')
        _RV_RESULT=$(_local_cc_policy completion submit \
            --lease-id "$_RV_LEASE_ID" \
            --workflow-id "$_RV_WF_ID" \
            --role "reviewer" \
            --payload "$_RV_PAYLOAD" 2>/dev/null || echo '{"valid":false}')
        _RV_VALID=$(printf '%s' "${_RV_RESULT:-}" | jq -r 'if .valid == 1 or .valid == true then "true" else "false" end' 2>/dev/null || echo "false")
        if [[ "$_RV_VALID" != "true" ]]; then
            _RV_MISSING=$(printf '%s' "$_RV_RESULT" | jq -r '.missing_fields | join(", ")' 2>/dev/null || echo "unknown")
            ISSUES+=("COMPLETION CONTRACT ERROR: Reviewer completion INVALID. Missing: $_RV_MISSING.")
        fi
    else
        ISSUES+=("No active lease found — reviewer completion not submitted. Dispatch will fail closed.")
    fi
fi

# ---------------------------------------------------------------------------
# Build additionalContext output
# ---------------------------------------------------------------------------

if [[ ${#ISSUES[@]} -gt 0 ]]; then
    CONTEXT="Reviewer validation: ${#ISSUES[@]} issue(s)."
    for issue in "${ISSUES[@]}"; do
        CONTEXT+="\n- $issue"
        append_audit "$PROJECT_ROOT" "agent_reviewer" "$issue"
    done
    rt_event_emit "agent_finding" "reviewer: $(IFS='; '; echo "${ISSUES[*]}")" || true
else
    CONTEXT="Reviewer validation: completion record submitted (verdict=${_REVIEW_VERDICT:-none}, head_sha=${_REVIEW_HEAD_SHA:-none})."
fi

# Observatory: emit agent duration metric.
_obs_duration=$(( $(date +%s) - _HOOK_START_AT ))
rt_obs_metric agent_duration_s "$_obs_duration" \
    "{\"verdict\":\"${_REVIEW_VERDICT:-unknown}\"}" "" "reviewer" || true

ESCAPED=$(echo -e "$CONTEXT" | jq -Rs .)
cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF

exit 0
