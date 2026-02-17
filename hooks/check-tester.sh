#!/usr/bin/env bash
set -euo pipefail

# SubagentStop:tester — validation of tester output with auto-verify support.
# Checks that the tester completed its verification job:
#   - .proof-status exists (at least pending)
#   - If tester signals AUTOVERIFY: CLEAN with High confidence and full coverage,
#     auto-writes verified status (bypasses manual approval)
#   - If still pending → exit 0 with advisory (user approval flow)
#   - If verified → exit 0 (Guardian dispatch unblocked)
#
# @decision DEC-TESTER-001
# @title Tester SubagentStop with auto-verify for clean e2e verifications
# @status accepted
# @rationale The tester presents evidence and writes .proof-status = pending.
#   If the tester signals AUTOVERIFY: CLEAN and secondary validation confirms
#   (High confidence, full coverage, no caveats), this hook auto-writes
#   verified — bypassing manual approval. Otherwise, the user must approve.
#   Guard.sh Check 9 only blocks Bash tool writes, not hook file operations.
#   track.sh resets proof if source files change post-verification.

source "$(dirname "$0")/source-lib.sh"

# Capture stdin (contains agent response)
AGENT_RESPONSE=$(read_input 2>/dev/null || echo "{}")

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)

# Track subagent completion
track_subagent_stop "$PROJECT_ROOT" "tester"
append_session_event "agent_stop" "{\"type\":\"tester\"}" "$PROJECT_ROOT"

# --- Trace protocol: detect and prepare for finalization ---
TRACE_ID=$(detect_active_trace "$PROJECT_ROOT" "tester" 2>/dev/null || echo "")
TRACE_DIR=""
if [[ -n "$TRACE_ID" ]]; then
    TRACE_DIR="${TRACE_STORE}/${TRACE_ID}"
fi

get_git_state "$PROJECT_ROOT"
get_plan_status "$PROJECT_ROOT"
write_statusline_cache "$PROJECT_ROOT"

ISSUES=()

# Check 1: .proof-status exists (tester should have written pending)
PROOF_FILE="${CLAUDE_DIR}/.proof-status"
PROOF_STATUS="missing"
if [[ -f "$PROOF_FILE" ]]; then
    PROOF_STATUS=$(cut -d'|' -f1 "$PROOF_FILE")
fi

if [[ "$PROOF_STATUS" == "missing" ]]; then
    ISSUES+=("Tester returned without writing .proof-status — verification evidence not collected")
fi

# Check 2: Trace artifacts include verification evidence (not just test output)
if [[ -n "$TRACE_DIR" && -d "$TRACE_DIR/artifacts" ]]; then
    if [[ ! -f "$TRACE_DIR/artifacts/verification-output.txt" ]]; then
        ISSUES+=("Trace artifact missing: verification-output.txt — tester should capture live feature output")
    fi
    # Validate summary exists
    if [[ ! -f "$TRACE_DIR/summary.md" ]]; then
        RESPONSE_TEXT=$(echo "$AGENT_RESPONSE" | jq -r '.response // .result // .output // empty' 2>/dev/null || echo "")
        echo "$RESPONSE_TEXT" | head -c 4000 > "$TRACE_DIR/summary.md" 2>/dev/null || true
    fi
    finalize_trace "$TRACE_ID" "$PROJECT_ROOT" "tester"
fi

# Response size advisory
RESPONSE_TEXT=$(echo "$AGENT_RESPONSE" | jq -r '.response // .result // .output // empty' 2>/dev/null || echo "")
if [[ -n "$RESPONSE_TEXT" ]]; then
    WORD_COUNT=$(echo "$RESPONSE_TEXT" | wc -w | tr -d ' ')
    if [[ "$WORD_COUNT" -gt 1200 ]]; then
        ISSUES+=("Agent response too large (~${WORD_COUNT} words). Use TRACE_DIR/artifacts/ for verbose output, return ≤1500 token summary.")
    fi
fi

# Build context message
CONTEXT=""
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    CONTEXT="Tester validation: ${#ISSUES[@]} issue(s)."
    for issue in "${ISSUES[@]}"; do
        CONTEXT+="\n- $issue"
    done
else
    CONTEXT="Tester validation: proof-status=$PROOF_STATUS."
fi

# Persist findings for next-prompt injection
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    FINDINGS_FILE="${CLAUDE_DIR}/.agent-findings"
    mkdir -p "${PROJECT_ROOT}/.claude"
    FINDING="tester|$(IFS=';'; echo "${ISSUES[*]}")"
    if ! grep -qxF "$FINDING" "$FINDINGS_FILE" 2>/dev/null; then
        echo "$FINDING" >> "$FINDINGS_FILE"
    fi
    for issue in "${ISSUES[@]}"; do
        append_audit "$PROJECT_ROOT" "agent_tester" "$issue"
    done
fi

# Decision gate based on proof status
if [[ "$PROOF_STATUS" == "verified" ]]; then
    # User has confirmed — Guardian dispatch is unblocked
    ESCAPED=$(echo -e "$CONTEXT\nProof verified by user. Guardian dispatch is now unblocked." | jq -Rs .)
    cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF
    exit 0
elif [[ "$PROOF_STATUS" == "pending" ]]; then
    # --- Auto-verify: check if tester signals clean verification ---
    AUTO_VERIFIED=false
    if echo "$RESPONSE_TEXT" | grep -q 'AUTOVERIFY: CLEAN'; then
        # Secondary validation — reject false claims
        AV_FAIL=false
        # Must have High confidence (markdown bold)
        echo "$RESPONSE_TEXT" | grep -qi '\*\*High\*\*' || AV_FAIL=true
        # Must NOT have "Not tested" or "Partially verified" in coverage
        echo "$RESPONSE_TEXT" | grep -qi 'Not tested\|Partially verified' && AV_FAIL=true
        # Must NOT have Medium or Low confidence
        echo "$RESPONSE_TEXT" | grep -qi '\*\*Medium\*\*\|\*\*Low\*\*' && AV_FAIL=true

        if [[ "$AV_FAIL" == "false" ]]; then
            echo "verified|$(date +%s)" > "$PROOF_FILE"
            AUTO_VERIFIED=true
            append_audit "$PROJECT_ROOT" "auto_verify" "Tester signaled AUTOVERIFY: CLEAN — secondary validation passed, proof auto-verified"
        else
            append_audit "$PROJECT_ROOT" "auto_verify_rejected" "Tester signaled AUTOVERIFY: CLEAN but secondary validation failed"
        fi
    fi

    if [[ "$AUTO_VERIFIED" == "true" ]]; then
        DIRECTIVE="AUTO-VERIFIED: The tester completed e2e verification with High confidence, full coverage, and no caveats. Proof-of-work is now verified. Present the tester's full verification report to the user AND dispatch Guardian simultaneously. The user sees the evidence while the commit is in flight."
    else
        DIRECTIVE="TESTER COMPLETE: The tester has presented a verification report with evidence, methodology assessment, and confidence level. Present the full report to the user — do NOT reduce it to a keyword demand. The user can approve (approved, lgtm, looks good, verified, ship it), request more testing, or ask questions. Do NOT tell the user to 'say verified'. Guardian dispatch requires .proof-status = verified (prompt-submit.sh writes this on user approval)."
    fi
    ESCAPED=$(echo -e "$CONTEXT\n\n$DIRECTIVE" | jq -Rs .)
    cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF
    exit 0
else
    # proof-status missing or unknown — tester didn't complete its job
    DIRECTIVE="BLOCKED: Tester returned without completing verification.\nResume the tester to:\n1. Run the feature/system live\n2. Show actual output to the user\n3. Write pending to .proof-status\n4. Present the verification report and let the user respond naturally"
    ESCAPED=$(echo -e "$CONTEXT\n\n$DIRECTIVE" | jq -Rs .)
    cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF
    exit 2  # Feedback loop — force tester resume
fi
