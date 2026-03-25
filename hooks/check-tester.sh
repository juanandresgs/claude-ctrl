#!/usr/bin/env bash
set -euo pipefail

# SubagentStop:tester — deterministic validation of tester output.
# Advisory only (exit 0 always). Ensures the tester surfaced evidence and
# asked for explicit user verification before Guardian proceeds.

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

if [[ -n "$RESPONSE_TEXT" ]]; then
    HAS_EVIDENCE=$(echo "$RESPONSE_TEXT" | grep -iE 'evidence|test output|observed|try it yourself|verification summary' || echo "")
    HAS_VERIFY_REQUEST=$(echo "$RESPONSE_TEXT" | grep -iE "reply .*verified|awaiting user verification|verify the feature" || echo "")
    CLAIMS_READY=$(echo "$RESPONSE_TEXT" | grep -iE 'ready for commit|ready for merge|guardian can proceed' || echo "")

    [[ -n "$HAS_EVIDENCE" ]] || ISSUES+=("Tester response did not clearly surface evidence")
    [[ -n "$HAS_VERIFY_REQUEST" ]] || ISSUES+=("Tester did not ask the user to reply 'verified'")

    if [[ -n "$CLAIMS_READY" && "$(read_proof_status "$PROJECT_ROOT")" != "verified" ]]; then
        ISSUES+=("Tester marked work ready before proof-of-work was verified by the user")
    fi
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

PROOF_STATUS=$(read_proof_status "$PROJECT_ROOT")
if [[ "$PROOF_STATUS" != "pending" && "$PROOF_STATUS" != "verified" ]] && ! is_claude_meta_repo "$PROJECT_ROOT"; then
    ISSUES+=("Proof state is '$PROOF_STATUS' — tester flow should put the workflow into pending or verified")
fi

if [[ ${#ISSUES[@]} -gt 0 ]]; then
    CONTEXT="Tester validation: ${#ISSUES[@]} issue(s)."
    for issue in "${ISSUES[@]}"; do
        CONTEXT+="\n- $issue"
        append_audit "$PROJECT_ROOT" "agent_tester" "$issue"
    done
    mkdir -p "${PROJECT_ROOT}/.claude"
    echo "tester|$(IFS=';'; echo "${ISSUES[*]}")" >> "${PROJECT_ROOT}/.claude/.agent-findings"
else
    CONTEXT="Tester validation: evidence surfaced, awaiting explicit user verification."
fi

ESCAPED=$(echo -e "$CONTEXT" | jq -Rs .)
cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF

exit 0
