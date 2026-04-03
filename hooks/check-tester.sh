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
# SubagentStart sets markers as "agent-$$" (current PID); SubagentStop runs
# in a different process so $$ does not match. We resolve by querying the
# active marker and comparing its role to the stopping agent type, then
# deactivating by the stored agent_id. No-op when role does not match (guards
# against clearing a concurrently active marker of a different role).
if [[ -n "$AGENT_TYPE" ]]; then
    _active_json=$(cc_policy marker get-active 2>/dev/null) || _active_json=""
    if [[ -n "$_active_json" ]]; then
        _active_role=$(printf '%s' "$_active_json" | jq -r 'if .found then .role else empty end' 2>/dev/null)
        _active_id=$(printf '%s' "$_active_json" | jq -r 'if .found then .agent_id else empty end' 2>/dev/null)
        if [[ "$_active_role" == "$AGENT_TYPE" && -n "$_active_id" ]]; then
            rt_marker_deactivate "$_active_id" 2>/dev/null || true
        fi
    fi
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
    _LEASE_RESULT=$(rt_lease_current "$PROJECT_ROOT")
    _CT_LEASE_ID=$(printf '%s' "${_LEASE_RESULT:-}" | jq -r '.lease_id // empty' 2>/dev/null || true)
    _CT_WF_ID=$(current_workflow_id "$PROJECT_ROOT")

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
if ! is_claude_meta_repo "$PROJECT_ROOT" && [[ "$_COMPLETION_BLOCKED" != "true" ]]; then
    _WF_ID=$(current_workflow_id "$PROJECT_ROOT")
    write_evaluation_status "$PROJECT_ROOT" "$_EVAL_STATUS" "$_WF_ID" "$_EVAL_HEAD_SHA"
    rt_event_emit "eval_verdict" "${_WF_ID}:${_EVAL_STATUS}" || true
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

TEST_STATUS_FILE="${PROJECT_ROOT}/.claude/.test-status"
if [[ -f "$TEST_STATUS_FILE" ]]; then
    TEST_RESULT=$(cut -d'|' -f1 "$TEST_STATUS_FILE")
    TEST_FAILS=$(cut -d'|' -f2 "$TEST_STATUS_FILE")
    if [[ "$TEST_RESULT" != "pass" ]]; then
        ISSUES+=("Test status is '$TEST_RESULT' (${TEST_FAILS} failures) during tester handoff")
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
    mkdir -p "${PROJECT_ROOT}/.claude"
    echo "tester|$(IFS=';'; echo "${ISSUES[*]}")" >> "${PROJECT_ROOT}/.claude/.agent-findings"
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
