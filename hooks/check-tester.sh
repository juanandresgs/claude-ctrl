#!/usr/bin/env bash
set -euo pipefail

# SubagentStop:tester — deterministic validation of tester output.
# Advisory only (exit 0 always).
#
# TKT-024: This hook is now the sole writer for evaluation_state verdicts.
# It parses EVAL_* trailers from the tester's response and writes the
# appropriate evaluation_state status. Fail-closed: missing or malformed
# trailers write "needs_changes" so Guardian cannot proceed on ambiguous output.
#
# EVAL_VERDICT    : ready_for_guardian | needs_changes | blocked_by_plan
# EVAL_TESTS_PASS : true | false
# EVAL_NEXT_ROLE  : guardian | implementer | planner
# EVAL_HEAD_SHA   : <git sha>
#
# @decision DEC-EVAL-002
# @title check-tester.sh is the sole writer of evaluation_state verdicts
# @status accepted
# @rationale Centralising all verdict writes in one SubagentStop hook makes
#   the evaluation pipeline auditable and testable. Every tester completion
#   produces exactly one evaluation_state row update. Fail-closed semantics
#   (missing/malformed trailer → needs_changes) prevent silent bypass.

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

AGENT_RESPONSE=$(read_input 2>/dev/null || echo "{}")
AGENT_TYPE=$(printf '%s' "$AGENT_RESPONSE" | jq -r '.agent_type // empty' 2>/dev/null || true)
PROJECT_ROOT=$(detect_project_root)

# track_subagent_stop removed (TKT-008): .subagent-tracker no longer written.

# Deactivate runtime marker for this completing agent.
# PE-W5: use ``cc-policy context role`` (lease → marker → env var resolution)
# instead of ``cc_policy marker get-active`` (marker-only). This ensures the
# same identity resolution path as the write/bash policy engine.
# No-op when resolved role does not match the stopping agent type (guards
# against clearing a concurrently active marker of a different role).
_ctx_json=$(cc-policy context role 2>/dev/null) || _ctx_json=""
_ctx_role=$(printf '%s' "$_ctx_json" | jq -r '.role // empty' 2>/dev/null || true)
_ctx_agent_id=$(printf '%s' "$_ctx_json" | jq -r '.agent_id // empty' 2>/dev/null || true)
if [[ -n "$AGENT_TYPE" && "$_ctx_role" == "$AGENT_TYPE" && -n "$_ctx_agent_id" ]]; then
    rt_marker_deactivate "$_ctx_agent_id" 2>/dev/null || true
fi

ISSUES=()
RESPONSE_TEXT=$(echo "$AGENT_RESPONSE" | jq -r '.response // .result // .output // empty' 2>/dev/null || echo "")

# ---------------------------------------------------------------------------
# Parse EVAL_* trailers (TKT-024)
# Each trailer must appear on its own line as: TRAILER_NAME: value
# ---------------------------------------------------------------------------

_EVAL_VERDICT=""
_EVAL_TESTS_PASS=""
_EVAL_NEXT_ROLE=""
_EVAL_HEAD_SHA=""

if [[ -n "$RESPONSE_TEXT" ]]; then
    _EVAL_VERDICT=$(printf '%s' "$RESPONSE_TEXT" \
        | grep -oE '^EVAL_VERDICT:[[:space:]]*[a-z_]+' \
        | head -1 \
        | sed 's/EVAL_VERDICT:[[:space:]]*//' || true)
    _EVAL_TESTS_PASS=$(printf '%s' "$RESPONSE_TEXT" \
        | grep -oE '^EVAL_TESTS_PASS:[[:space:]]*(true|false)' \
        | head -1 \
        | sed 's/EVAL_TESTS_PASS:[[:space:]]*//' || true)
    _EVAL_NEXT_ROLE=$(printf '%s' "$RESPONSE_TEXT" \
        | grep -oE '^EVAL_NEXT_ROLE:[[:space:]]*[a-z_]+' \
        | head -1 \
        | sed 's/EVAL_NEXT_ROLE:[[:space:]]*//' || true)
    _EVAL_HEAD_SHA=$(printf '%s' "$RESPONSE_TEXT" \
        | grep -oE '^EVAL_HEAD_SHA:[[:space:]]*[0-9a-f]+' \
        | head -1 \
        | sed 's/EVAL_HEAD_SHA:[[:space:]]*//' || true)
fi

# Validate verdict — fail-closed on missing/invalid
_VALID_VERDICTS="ready_for_guardian needs_changes blocked_by_plan"
_EVAL_STATUS="needs_changes"  # default: fail-closed

if [[ -z "$_EVAL_VERDICT" ]]; then
    ISSUES+=("No EVAL_VERDICT trailer found — evaluation_state set to needs_changes (fail-closed)")
elif ! printf ' %s ' "$_VALID_VERDICTS" | grep -q " $_EVAL_VERDICT "; then
    ISSUES+=("Invalid EVAL_VERDICT '$_EVAL_VERDICT' — evaluation_state set to needs_changes (fail-closed)")
else
    _EVAL_STATUS="$_EVAL_VERDICT"
fi

# Validate EVAL_TESTS_PASS for ready_for_guardian
if [[ "$_EVAL_STATUS" == "ready_for_guardian" && "$_EVAL_TESTS_PASS" != "true" ]]; then
    ISSUES+=("EVAL_VERDICT=ready_for_guardian but EVAL_TESTS_PASS is '$_EVAL_TESTS_PASS' — degraded to needs_changes")
    _EVAL_STATUS="needs_changes"
fi

# Require EVAL_HEAD_SHA when clearing for guardian
if [[ "$_EVAL_STATUS" == "ready_for_guardian" && -z "$_EVAL_HEAD_SHA" ]]; then
    ISSUES+=("EVAL_VERDICT=ready_for_guardian but EVAL_HEAD_SHA is missing — degraded to needs_changes")
    _EVAL_STATUS="needs_changes"
fi

# --- Completion contract submission (Phase 2: DEC-COMPLETION-001) ---
# Submit a structured completion record BEFORE writing evaluation_state.
# If submission fails validation (invalid payload), block the eval_state
# write so Guardian cannot land on an unvalidated tester completion.
# Legacy path (no active lease): proceed without a completion record —
# the eval_state write is not blocked when there is no lease to complete.
_COMPLETION_BLOCKED=false
if ! is_claude_meta_repo "$PROJECT_ROOT"; then
    # WS1: use lease_context() to derive workflow_id from the active lease.
    # When a lease exists its workflow_id is authoritative; branch-derived id
    # is the fallback only when no lease is active.
    _CT_LEASE_CTX=$(lease_context "$PROJECT_ROOT")
    _CT_LEASE_FOUND=$(printf '%s' "$_CT_LEASE_CTX" | jq -r '.found' 2>/dev/null || echo "false")
    if [[ "$_CT_LEASE_FOUND" == "true" ]]; then
        _CT_LEASE_ID=$(printf '%s' "$_CT_LEASE_CTX" | jq -r '.lease_id // empty' 2>/dev/null || true)
        _CT_WF_ID=$(printf '%s' "$_CT_LEASE_CTX" | jq -r '.workflow_id // empty' 2>/dev/null || true)
    else
        _CT_LEASE_ID=""
        _CT_WF_ID=""
    fi
    [[ -z "$_CT_WF_ID" ]] && _CT_WF_ID=$(current_workflow_id "$PROJECT_ROOT")

    if [[ -n "$_CT_LEASE_ID" ]]; then
        _CT_PAYLOAD=$(jq -n \
            --arg v "${_EVAL_VERDICT:-}" \
            --arg t "${_EVAL_TESTS_PASS:-}" \
            --arg n "${_EVAL_NEXT_ROLE:-}" \
            --arg h "${_EVAL_HEAD_SHA:-}" \
            '{EVAL_VERDICT:$v, EVAL_TESTS_PASS:$t, EVAL_NEXT_ROLE:$n, EVAL_HEAD_SHA:$h}')
        _CT_RESULT=$(rt_completion_submit "$_CT_LEASE_ID" "$_CT_WF_ID" "tester" "$_CT_PAYLOAD")
        _CT_VALID=$(printf '%s' "${_CT_RESULT:-}" | jq -r '.valid // "false"' 2>/dev/null || echo "false")
        if [[ "$_CT_VALID" != "true" ]]; then
            _CT_MISSING=$(printf '%s' "$_CT_RESULT" | jq -r '.missing_fields | join(", ")' 2>/dev/null || echo "unknown")
            ISSUES+=("COMPLETION CONTRACT ERROR: Tester completion INVALID. Missing: $_CT_MISSING. Eval state NOT advanced.")
            _COMPLETION_BLOCKED=true
        fi
    fi
fi

# Write evaluation_state (sole writer for verdicts)
# Only proceed if completion contract was satisfied (or no lease exists = legacy fallback).
# WS1: use the lease-derived _CT_WF_ID (set above) so the eval state is written
# under the same workflow_id that the lease authorised — not the branch-derived one.
if ! is_claude_meta_repo "$PROJECT_ROOT" && [[ "$_COMPLETION_BLOCKED" != "true" ]]; then
    write_evaluation_status "$PROJECT_ROOT" "$_EVAL_STATUS" "$_CT_WF_ID" "$_EVAL_HEAD_SHA"
    rt_event_emit "eval_verdict" "${_CT_WF_ID}:${_EVAL_STATUS}" || true
fi

# ---------------------------------------------------------------------------
# BUG_FINDING trailer parsing — file bugs discovered by the tester
#
# Format (one per line in the tester response):
#   BUG_FINDING: {"bug_type":"regression","title":"...","evidence":"...",
#                 "scope":"global","source_component":"..."}
#
# Each BUG_FINDING line is routed through rt_bug_file() so all filings get
# fingerprint dedup, SQLite persistence, and audit events. Malformed JSON
# lines are skipped silently — bug filing is advisory and must never block
# evaluation_state writes.
# ---------------------------------------------------------------------------

if [[ -n "$RESPONSE_TEXT" ]]; then
    while IFS= read -r _bug_line; do
        _bug_json="${_bug_line#BUG_FINDING: }"
        # Extract fields with jq; fall back to empty strings on parse failure
        _bf_type=$(printf '%s' "$_bug_json" | jq -r '.bug_type // empty' 2>/dev/null || true)
        _bf_title=$(printf '%s' "$_bug_json" | jq -r '.title // empty' 2>/dev/null || true)
        _bf_evidence=$(printf '%s' "$_bug_json" | jq -r '.evidence // empty' 2>/dev/null || true)
        _bf_scope=$(printf '%s' "$_bug_json" | jq -r '.scope // "global"' 2>/dev/null || echo "global")
        _bf_component=$(printf '%s' "$_bug_json" | jq -r '.source_component // empty' 2>/dev/null || true)

        # Skip lines with missing required fields
        [[ -z "$_bf_type" || -z "$_bf_title" ]] && continue

        rt_bug_file "$_bf_type" "$_bf_title" "" "$_bf_scope" "$_bf_component" "" "$_bf_evidence" \
            >/dev/null 2>&1 || true
    done < <(printf '%s\n' "$RESPONSE_TEXT" | grep '^BUG_FINDING: ' 2>/dev/null || true)
fi

# ---------------------------------------------------------------------------
# Legacy advisory checks (informational — do not affect evaluation_state)
# ---------------------------------------------------------------------------

if [[ -n "$RESPONSE_TEXT" ]]; then
    HAS_EVIDENCE=$(echo "$RESPONSE_TEXT" | grep -iE 'evidence|test output|observed|try it yourself|verification summary' || echo "")
    [[ -n "$HAS_EVIDENCE" ]] || ISSUES+=("Tester response did not clearly surface evidence")
else
    ISSUES+=("Tester returned no response text")
fi

# Read test status from runtime SQLite authority (WS3: flat file removed)
_CT_TS_JSON=$(rt_test_state_get "$PROJECT_ROOT") || _CT_TS_JSON=""
_CT_TS_FOUND=$(printf '%s' "${_CT_TS_JSON:-}" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
if [[ "$_CT_TS_FOUND" == "yes" ]]; then
    _CT_TS_STATUS=$(printf '%s' "$_CT_TS_JSON" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
    _CT_TS_FAILS=$(printf '%s' "$_CT_TS_JSON" | jq -r '.fail_count // 0' 2>/dev/null || echo "0")
    if [[ "$_CT_TS_STATUS" != "pass" && "$_CT_TS_STATUS" != "pass_complete" ]]; then
        ISSUES+=("Test status is '$_CT_TS_STATUS' ($_CT_TS_FAILS failures) during tester handoff")
    fi
else
    ISSUES+=("No test results found for tester review")
fi

if [[ ${#ISSUES[@]} -gt 0 ]]; then
    CONTEXT="Tester validation: ${#ISSUES[@]} issue(s). Evaluation state written: $_EVAL_STATUS"
    for issue in "${ISSUES[@]}"; do
        CONTEXT+="\n- $issue"
        append_audit "$PROJECT_ROOT" "agent_tester" "$issue"
    done
    rt_event_emit "agent_finding" "tester: $(IFS='; '; echo "${ISSUES[*]}")" || true
else
    CONTEXT="Tester validation: evaluation_state written as '$_EVAL_STATUS' (head_sha=${_EVAL_HEAD_SHA:-none})."
fi

ESCAPED=$(echo -e "$CONTEXT" | jq -Rs .)
cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF

exit 0
