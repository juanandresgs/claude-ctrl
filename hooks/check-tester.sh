#!/usr/bin/env bash
# SubagentStop:tester — validation of tester output with auto-verify support.
# Checks that the tester completed its verification job:
#   - .proof-status exists (at least pending)
#   - If tester signals AUTOVERIFY: CLEAN with High confidence and full coverage,
#     auto-writes verified status (bypasses manual approval)
#   - If still pending → exit 0 with advisory (user approval flow)
#   - If verified → exit 0 (Guardian dispatch unblocked)
#
# Structure: auto-verify critical path runs FIRST (Phase 1, <2s budget).
# Heavy advisory work (git state, trace finalization, completeness gate) runs
# only after auto-verify is resolved (Phase 2). This ensures the hook exits
# before the 15s timeout even when git and trace I/O is slow.
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
#   Auto-verify runs FIRST to avoid timeout before reaching this logic.
set -euo pipefail

source "$(dirname "$0")/source-lib.sh"

# Capture stdin (contains agent response)
AGENT_RESPONSE=$(read_input 2>/dev/null || echo "{}")

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)

# ============================================================================
# PHASE 1 — Critical path (must complete in <2s)
# ============================================================================

# Check 1: .proof-status exists (tester should have written pending)
# Use resolve_proof_file() so worktree scenarios find the right path.
# The tester writes "pending" to its worktree .claude/; resolve_proof_file()
# reads the breadcrumb and returns the worktree path when active.
PROOF_FILE=$(resolve_proof_file)
PROOF_STATUS="missing"
if [[ -f "$PROOF_FILE" ]]; then
    PROOF_STATUS=$(cut -d'|' -f1 "$PROOF_FILE")
fi

# Meta-repo exemption: .proof-status is never created for ~/.claude
# (task-track.sh Gate C exempts meta-repos). Treat as pending for auto-verify.
if [[ "$PROOF_STATUS" == "missing" ]] && is_claude_meta_repo "$PROJECT_ROOT"; then
    PROOF_STATUS="pending"
fi

# Extract response text early — needed for auto-verify
RESPONSE_TEXT=$(echo "$AGENT_RESPONSE" | jq -r '.response // .result // .output // empty' 2>/dev/null || echo "")

# --- Auto-verify: check if tester signals clean verification ---
# Runs in Phase 1 so it completes well within the 15s timeout.
AUTO_VERIFIED=false
AV_FAIL=false
NOT_TESTED_LINES=""
WHITELISTED_COUNT=0

if [[ "$PROOF_STATUS" == "pending" ]] && echo "$RESPONSE_TEXT" | grep -q 'AUTOVERIFY: CLEAN'; then
    # Secondary validation — reject false claims
    # Must have High confidence (markdown bold)
    echo "$RESPONSE_TEXT" | grep -qi '\*\*High\*\*' || AV_FAIL=true
    # Must NOT have "Partially verified" in coverage
    echo "$RESPONSE_TEXT" | grep -qi 'Partially verified' && AV_FAIL=true
    # Must NOT have non-environmental "Not tested" entries.
    # Environmental gaps (browser viewport, screen reader, physical device, etc.)
    # are whitelisted — they cannot be tested in a headless CLI context and do not
    # indicate incomplete verification of the feature under test.
    NOT_TESTED_LINES=$(echo "$RESPONSE_TEXT" | grep -i 'Not tested' || true)
    if [[ -n "$NOT_TESTED_LINES" ]]; then
        ENV_PATTERN='requires browser\|requires viewport\|requires screen reader\|requires mobile\|requires physical device\|requires hardware\|requires manual interaction\|requires human interaction\|requires GUI\|requires native app\|requires network'
        NON_ENV_LINES=$(echo "$NOT_TESTED_LINES" | grep -iv "$ENV_PATTERN" || true)
        if [[ -n "$NON_ENV_LINES" ]]; then
            AV_FAIL=true
        fi
    fi
    # Must NOT have Medium or Low confidence
    echo "$RESPONSE_TEXT" | grep -qi '\*\*Medium\*\*\|\*\*Low\*\*' && AV_FAIL=true

    if [[ "$AV_FAIL" == "false" ]]; then
        ENV_PATTERN='requires browser\|requires viewport\|requires screen reader\|requires mobile\|requires physical device\|requires hardware\|requires manual interaction\|requires human interaction\|requires GUI\|requires native app\|requires network'
        WHITELISTED_COUNT=$(echo "$NOT_TESTED_LINES" | grep -ic "$ENV_PATTERN" 2>/dev/null || echo "0")
        echo "verified|$(date +%s)" > "$PROOF_FILE"
        # Dual-write: keep orchestrator's copy in sync so guard.sh can find it
        # regardless of which path it checks (worktree vs orchestrator CLAUDE_DIR).
        ORCH_PROOF="${CLAUDE_DIR}/.proof-status"
        if [[ "$PROOF_FILE" != "$ORCH_PROOF" ]]; then
            echo "verified|$(date +%s)" > "$ORCH_PROOF"
        fi
        AUTO_VERIFIED=true
    fi
fi

# If auto-verified: emit JSON immediately and exit 0.
# Still do tracking + audit, but skip expensive git/trace/plan work.
if [[ "$AUTO_VERIFIED" == "true" ]]; then
    track_subagent_stop "$PROJECT_ROOT" "tester"
    append_session_event "agent_stop" "{\"type\":\"tester\"}" "$PROJECT_ROOT"
    if [[ "${WHITELISTED_COUNT:-0}" -gt 0 ]]; then
        append_audit "$PROJECT_ROOT" "auto_verify" "Tester signaled AUTOVERIFY: CLEAN — secondary validation passed, proof auto-verified (${WHITELISTED_COUNT} environmental 'Not tested' item(s) whitelisted)"
    else
        append_audit "$PROJECT_ROOT" "auto_verify" "Tester signaled AUTOVERIFY: CLEAN — secondary validation passed, proof auto-verified"
    fi
    CONTEXT="Tester validation: proof-status=verified (auto-verified)."
    DIRECTIVE="AUTO-VERIFIED: Tester e2e verification passed — High confidence, full coverage, no caveats. .proof-status is verified. Dispatch Guardian NOW with 'AUTO-VERIFY-APPROVED' in the prompt. Guardian will skip its approval prompt and execute the full merge cycle directly. Present the tester's verification report to the user in parallel."
    ESCAPED=$(echo -e "$CONTEXT\n\n$DIRECTIVE" | jq -Rs .)
    cat <<EOF
{
  "systemMessage": $ESCAPED
}
EOF
    exit 0
fi

# ============================================================================
# PHASE 2 — Advisory work (runs only when not auto-verified)
# ============================================================================

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

# Check 1b: Flag missing .proof-status (for non-meta-repo)
if [[ "$PROOF_STATUS" == "missing" ]] && ! is_claude_meta_repo "$PROJECT_ROOT"; then
    ISSUES+=("Tester returned without writing .proof-status — verification evidence not collected")
fi

# Check 2: Trace artifacts include verification evidence (not just test output)
if [[ -n "$TRACE_DIR" && -d "$TRACE_DIR/artifacts" ]]; then
    # Auto-capture verification-output.txt from response text if agent didn't write it.
    # The tester's response IS the verification evidence — capturing it here ensures
    # finalize_trace() sees an artifact and marks outcome="completed" rather than "partial".
    if [[ ! -f "$TRACE_DIR/artifacts/verification-output.txt" && -n "$RESPONSE_TEXT" ]]; then
        echo "# Auto-captured from tester response at $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TRACE_DIR/artifacts/verification-output.txt"
        echo "$RESPONSE_TEXT" | head -c 8000 >> "$TRACE_DIR/artifacts/verification-output.txt" 2>/dev/null || true
    fi

    # Auto-capture .proof-status content as evidence if verification-output still missing
    if [[ ! -f "$TRACE_DIR/artifacts/verification-output.txt" && -f "$PROOF_FILE" ]]; then
        echo "# Auto-captured from .proof-status at $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TRACE_DIR/artifacts/verification-output.txt"
        cat "$PROOF_FILE" >> "$TRACE_DIR/artifacts/verification-output.txt" 2>/dev/null || true
    fi

    if [[ ! -f "$TRACE_DIR/artifacts/verification-output.txt" ]]; then
        ISSUES+=("Trace artifact missing: verification-output.txt — tester should capture live feature output")
    fi
    # Validate summary exists
    if [[ ! -f "$TRACE_DIR/summary.md" ]]; then
        echo "$RESPONSE_TEXT" | head -c 4000 > "$TRACE_DIR/summary.md" 2>/dev/null || true
    fi
    finalize_trace "$TRACE_ID" "$PROJECT_ROOT" "tester"
fi

# Response size advisory
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

# Check 3: Tester completeness — detect partial/incomplete runs
# A tester that only wrote strategy but never produced verification output
# must not enter the approval flow. Force resume instead.
# Both signals required (AND logic) — finalize_trace marks outcome="partial"
# when test-output.txt is missing, but testers write verification-output.txt
# instead. A tester with verification-output.txt IS complete regardless of
# manifest outcome.
#
# @decision DEC-TESTER-002
# @title Block partial tester runs before approval flow (AND logic)
# @status accepted
# @rationale A tester that exits after planning but before executing verification
#   must not enter the approval flow. Two signals together detect incompleteness:
#   1. manifest.json outcome == "partial" (finalize_trace signal)
#   2. artifacts/verification-output.txt missing (concrete evidence absent)
#   AND logic is required because finalize_trace() marks ALL testers as "partial"
#   when test-output.txt is absent — but testers write verification-output.txt
#   as their primary artifact, not test-output.txt. A tester with
#   verification-output.txt IS complete even if finalize_trace shows "partial".
#   The gate exits 2 (force resume) to unblock the tester.
TESTER_COMPLETE=true
TRACE_OUTCOME=""

if [[ -n "$TRACE_DIR" && -d "$TRACE_DIR" ]]; then
    if [[ -f "$TRACE_DIR/manifest.json" ]]; then
        TRACE_OUTCOME=$(jq -r '.outcome // "unknown"' "$TRACE_DIR/manifest.json" 2>/dev/null)
    fi

    HAS_VERIFICATION=false
    if [[ -d "$TRACE_DIR/artifacts" && -f "$TRACE_DIR/artifacts/verification-output.txt" ]]; then
        HAS_VERIFICATION=true
    fi

    # Block only when outcome is partial AND verification output is missing
    # (i.e., tester planned but never executed)
    if [[ "$TRACE_OUTCOME" == "partial" && "$HAS_VERIFICATION" == "false" ]]; then
        TESTER_COMPLETE=false
    fi
fi

if [[ "$TESTER_COMPLETE" == "false" ]]; then
    DIRECTIVE="INCOMPLETE: Tester returned without completing verification (trace outcome: ${TRACE_OUTCOME:-unknown}). Do NOT present confidence levels or approve merge from partial results. Resume the tester to complete verification."
    ESCAPED=$(echo -e "$CONTEXT\n\n$DIRECTIVE" | jq -Rs .)
    cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF
    exit 2  # Force tester resume
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
    # Auto-verify was attempted above but AV_FAIL was set.
    # Check if AUTOVERIFY signal was present but failed secondary validation.
    if echo "$RESPONSE_TEXT" | grep -q 'AUTOVERIFY: CLEAN'; then
        append_audit "$PROJECT_ROOT" "auto_verify_rejected" "Tester signaled AUTOVERIFY: CLEAN but secondary validation failed"
    fi
    DIRECTIVE="TESTER COMPLETE: The tester has presented a verification report with evidence, methodology assessment, and confidence level. Present the full report to the user — do NOT reduce it to a keyword demand. The user can approve (approved, lgtm, looks good, verified, ship it), request more testing, or ask questions. Do NOT tell the user to 'say verified'. Guardian dispatch requires .proof-status = verified (prompt-submit.sh writes this on user approval)."
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
