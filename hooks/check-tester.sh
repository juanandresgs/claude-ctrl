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
# Phase 2 ordering (Fix 2):
#   1. track_subagent_stop + trace detection
#   2. git/plan state
#   3. Check 1b: missing proof-status
#   4. finalize_trace (extracted before Check 3 so manifest is fresh)
#   5. Check 3: completeness gate (BEFORE auto-capture — reads fresh manifest)
#   6. Check 2: auto-capture + artifact validation (AFTER completeness check)
#   7. Response size advisory
#   8. Build context + decision gate
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
#
# @decision DEC-TESTER-003
# @title Auto-verify accepts needs-verification status + safety net for missing status
# @status accepted
# @rationale task-track.sh writes "needs-verification" at implementer dispatch.
#   The tester is supposed to overwrite with "pending" but frequently fails
#   (confirmed by audit log entries). Auto-verify was silently skipped when
#   proof-status was "needs-verification" or "missing" — blocking the fast path.
#   Fix: accept both "pending" AND "needs-verification" in the auto-verify gate.
#   Safety net: if proof-status is "missing" and RESPONSE_TEXT is non-empty,
#   auto-write "pending" so the manual approval flow can still proceed.
#
# @decision DEC-TESTER-004
# @title Check 3 completeness gate runs BEFORE auto-capture (Fix 2)
# @status accepted
# @rationale Check 2's auto-capture wrote verification-output.txt from ANY
#   non-empty RESPONSE_TEXT, causing Check 3's HAS_VERIFICATION=true even for
#   partial/incomplete testers. This meant the AND condition was never met and
#   incomplete testers passed through to the approval flow.
#   Fix: extract finalize_trace() to run before Check 3, then move Check 3
#   before Check 2's auto-capture. Check 3 now reads the manifest written by
#   finalize_trace BEFORE auto-capture contaminates HAS_VERIFICATION.
set -euo pipefail

source "$(dirname "$0")/source-lib.sh"

# Capture stdin (contains agent response)
AGENT_RESPONSE=$(read_input 2>/dev/null || echo "{}")

# Diagnostic: log SubagentStop payload keys for field-name investigation (Issue #TBD)
if [[ -n "$AGENT_RESPONSE" && "$AGENT_RESPONSE" != "{}" ]]; then
    PAYLOAD_KEYS=$(echo "$AGENT_RESPONSE" | jq -r 'keys[]' 2>/dev/null | tr '\n' ',' || echo "unknown")
    PAYLOAD_SIZE=${#AGENT_RESPONSE}
    echo "check-tester: SubagentStop payload keys=[$PAYLOAD_KEYS] size=${PAYLOAD_SIZE}" >&2
fi

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)

# ============================================================================
# PHASE 1 — Critical path (must complete in <2s)
#
# @deprecated Auto-verify migrated to post-task.sh (PostToolUse:Task). This
# code is preserved for SubagentStop compatibility if upstream fixes the event.
# SubagentStop:tester does not reliably fire in Claude Code (confirmed dead in
# practice). PostToolUse:Task fires after every Task tool call and is the
# correct hook for detecting tester completions. Issue #150, DEC-PROOF-LIFE-001.
#
# Gate: set CLAUDE_ENABLE_SUBAGENT_AUTOVERIFY=true to re-enable this block.
# Disabled by default since post-task.sh is the authoritative auto-verify path.
# ============================================================================

if [[ "${CLAUDE_ENABLE_SUBAGENT_AUTOVERIFY:-}" == "true" ]]; then

# Check 1: .proof-status exists (tester should have written pending)
# Use resolve_proof_file() so worktree scenarios find the right path.
# The tester writes "pending" to its worktree .claude/; resolve_proof_file()
# reads the breadcrumb and returns the worktree path when active.
PROOF_FILE=$(resolve_proof_file)
PROOF_STATUS="missing"
if [[ -f "$PROOF_FILE" ]]; then
    PROOF_STATUS=$(cut -d'|' -f1 "$PROOF_FILE")
fi

# Extract response text early — needed for auto-verify
# Field name: SubagentStop payload uses `last_assistant_message` (confirmed from Claude Code docs).
# `.response` kept as fallback for backward compatibility.
RESPONSE_TEXT=$(echo "$AGENT_RESPONSE" | jq -r '.last_assistant_message // .response // empty' 2>/dev/null || echo "")

# Diagnostic logging for auto-verify pipeline (DEC-V3-001, Issue #129)
# Emits to stderr so it appears in Claude Code's hook diagnostic output.
# This captures actual runtime payload structure to diagnose why AUTOVERIFY
# signal is not found. Runs unconditionally so every tester stop is logged.
RESPONSE_LEN=${#RESPONSE_TEXT}
echo "check-tester: RESPONSE_TEXT length=$RESPONSE_LEN" >&2
if [[ "$RESPONSE_LEN" -gt 0 ]]; then
    AV_SIGNAL=$(echo "$RESPONSE_TEXT" | grep -c 'AUTOVERIFY: CLEAN' 2>/dev/null || echo "0")
    echo "check-tester: AUTOVERIFY signal count=$AV_SIGNAL" >&2
    if [[ "$AV_SIGNAL" -gt 0 ]]; then
        CONF_CHECK=$(echo "$RESPONSE_TEXT" | grep -ci '\*\*High\*\*' 2>/dev/null || echo "0")
        PARTIAL_CHECK=$(echo "$RESPONSE_TEXT" | grep -ci 'Partially verified' 2>/dev/null || echo "0")
        NOT_TESTED_CHECK=$(echo "$RESPONSE_TEXT" | grep -ciE '(:\s*Not tested|\|\s*Not tested)' 2>/dev/null || echo "0")
        echo "check-tester: secondary validation: High=$CONF_CHECK Partial=$PARTIAL_CHECK NotTested=$NOT_TESTED_CHECK" >&2
    fi
else
    echo "check-tester: WARNING — RESPONSE_TEXT is empty. Payload keys: $(echo "$AGENT_RESPONSE" | jq -r 'keys[]' 2>/dev/null | tr '\n' ',' || echo 'none')" >&2
fi

# W6-2: Summary.md fallback for AUTOVERIFY signal (DEC-V3-001, Issue #129)
#
# @decision DEC-V3-001
# @title Diagnostic-first approach for auto-verify repair
# @status accepted
# @rationale Auto-verify never fires in production. Tester agents follow the
#   Trace Protocol: write verbose output to TRACE_DIR/summary.md (file), keep
#   return message under 1500 tokens. The AUTOVERIFY: CLEAN signal is written
#   to summary.md as part of the tester's trace artifact — but last_assistant_message
#   may be empty or a brief token-limited message that omits the signal. Fix:
#   when last_assistant_message is empty OR lacks AUTOVERIFY signal, supplement
#   with the active trace's summary.md content. This is safe: summary.md is written
#   by the tester before returning (Trace Protocol). The fallback does NOT replace
#   last_assistant_message for secondary validation — it merges the two sources
#   into RESPONSE_TEXT so Phase 1 auto-verify has complete signal coverage.
#   Issue #129.
if [[ -z "$RESPONSE_TEXT" ]] || ! echo "$RESPONSE_TEXT" | grep -q 'AUTOVERIFY: CLEAN'; then
    # Attempt to find the active trace's summary.md
    _AV_TRACE_ID=$(detect_active_trace "$PROJECT_ROOT" "tester" 2>/dev/null || echo "")
    if [[ -n "$_AV_TRACE_ID" ]]; then
        _AV_SUMMARY="${TRACE_STORE}/${_AV_TRACE_ID}/summary.md"
        if [[ -s "$_AV_SUMMARY" ]]; then
            _SUMMARY_TEXT=$(cat "$_AV_SUMMARY" 2>/dev/null || echo "")
            if [[ -n "$_SUMMARY_TEXT" ]]; then
                echo "check-tester: supplementing RESPONSE_TEXT from summary.md (trace=${_AV_TRACE_ID})" >&2
                # Append summary.md content to RESPONSE_TEXT so auto-verify can find the signal
                RESPONSE_TEXT="${RESPONSE_TEXT}
${_SUMMARY_TEXT}"
                RESPONSE_LEN=${#RESPONSE_TEXT}
                echo "check-tester: RESPONSE_TEXT length after supplement=$RESPONSE_LEN" >&2
                AV_SIGNAL_AFTER=$(echo "$RESPONSE_TEXT" | grep -c 'AUTOVERIFY: CLEAN' 2>/dev/null || echo "0")
                echo "check-tester: AUTOVERIFY signal count after supplement=$AV_SIGNAL_AFTER" >&2
            fi
        else
            echo "check-tester: summary.md not found or empty at ${_AV_SUMMARY}" >&2
        fi
    else
        echo "check-tester: no active tester trace found for summary.md fallback" >&2
    fi
fi

# --- Dedup guard: skip auto-verify if already verified (Fix #124) ---
# SubagentStop can fire twice for a single tester run (tester stops, is resumed,
# stops again). Each stop event runs check-tester.sh independently. If the first
# run already auto-verified and wrote "verified" to proof-status, the second run
# must skip the auto-verify block entirely — otherwise a duplicate audit entry is
# written. This guard makes auto-verify idempotent via proof-status.
#
# @decision DEC-TESTER-006
# @title Early exit when proof already verified — prevents duplicate audit entries
# @status accepted
# @rationale SubagentStop fires once per tester stop event. When the tester stops,
#   is resumed by the orchestrator, and stops again, check-tester.sh runs twice.
#   The first run auto-verifies and writes "verified". The second run must not
#   repeat the auto-verify (and its audit append). Using the proof-status file as
#   the idempotency key is the most robust guard: it's written atomically before
#   the audit entry, so any concurrent second run reading "verified" skips cleanly.
#   Issue #124.
if [[ "$PROOF_STATUS" == "verified" ]]; then
    track_subagent_stop "$PROJECT_ROOT" "tester"
    append_session_event "agent_stop" "{\"type\":\"tester\"}" "$PROJECT_ROOT"
    CONTEXT="Tester validation: proof-status=verified (already verified — skipping duplicate auto-verify)."
    DIRECTIVE="Already verified. Guardian dispatch is unblocked."
    ESCAPED=$(printf '%s\n\n%s' "$CONTEXT" "$DIRECTIVE" | jq -Rs .)
    cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF
    exit 0
fi

# --- Auto-verify: check if tester signals clean verification ---
# @deprecated Auto-verify migrated to post-task.sh (PostToolUse:Task).
# This code is preserved for SubagentStop compatibility if upstream fixes
# the SubagentStop:tester event. See DEC-PROOF-LIFE-001 and issue #150.
# The logic below is intentionally left functional — if SubagentStop ever
# fires, this code will still handle auto-verify correctly.
#
# Runs in Phase 1 so it completes well within the 15s timeout.
# Fix 1 (DEC-TESTER-003): accept "needs-verification" in addition to "pending".
# task-track.sh writes "needs-verification" at implementer dispatch; the tester
# frequently fails to overwrite with "pending", silently defeating auto-verify.
AUTO_VERIFIED=false
AV_FAIL=false
NOT_TESTED_LINES=""
WHITELISTED_COUNT=0

if [[ "$PROOF_STATUS" == "pending" || "$PROOF_STATUS" == "needs-verification" ]] && echo "$RESPONSE_TEXT" | grep -q 'AUTOVERIFY: CLEAN'; then
    # --- Extract Verification Assessment section for secondary validation ---
    # Tester summaries include test descriptions mentioning keywords like
    # "Medium confidence" or "Partially verified" as test case names. Scoping
    # validation to the Verification Assessment section eliminates false positives.
    # See DEC-AV-SECTION-001 in post-task.sh for full rationale.
    # grep returns exit 1 when no match — || true prevents set -e from killing the script.
    _CT_VA_START=$(echo "$RESPONSE_TEXT" | grep -n -E '^#{1,3} Verification Assessment' | head -1 | cut -d: -f1 || true)
    if [[ -n "$_CT_VA_START" ]]; then
        # Extract from VA heading to EOF. Sub-headings within VA (e.g., "## Confidence: High",
        # "### Coverage") belong to the assessment and must be included. Stopping at the first
        # subsequent "##" heading would incorrectly truncate VA sub-headings.
        _CT_VALIDATION_TEXT=$(echo "$RESPONSE_TEXT" | tail -n +"${_CT_VA_START}")
        echo "check-tester: extracted Verification Assessment section (${#_CT_VALIDATION_TEXT} chars) for secondary validation" >&2
    else
        _CT_VALIDATION_TEXT="$RESPONSE_TEXT"
        echo "check-tester: no Verification Assessment section found — using full response for validation" >&2
    fi

    # Secondary validation — reject false claims
    # Must have High confidence (markdown bold or plain-text formats)
    echo "$_CT_VALIDATION_TEXT" | grep -qiE '(\*\*High\*\*|[Cc]onfidence:?\s*High|High confidence)' || AV_FAIL=true
    # Must NOT have "Partially verified" in coverage
    echo "$_CT_VALIDATION_TEXT" | grep -qi 'Partially verified' && AV_FAIL=true
    # Must NOT have non-environmental "Not tested" entries.
    # Environmental gaps (browser viewport, screen reader, physical device, etc.)
    # are whitelisted — they cannot be tested in a headless CLI context and do not
    # indicate incomplete verification of the feature under test.
    NOT_TESTED_LINES=$(echo "$_CT_VALIDATION_TEXT" | grep -iE '(:\s*Not tested|\|\s*Not tested)' || true)
    if [[ -n "$NOT_TESTED_LINES" ]]; then
        ENV_PATTERN='requires browser\|requires viewport\|requires screen reader\|requires mobile\|requires physical device\|requires hardware\|requires manual interaction\|requires human interaction\|requires GUI\|requires native app\|requires network'
        NON_ENV_LINES=$(echo "$NOT_TESTED_LINES" | grep -iv "$ENV_PATTERN" || true)
        if [[ -n "$NON_ENV_LINES" ]]; then
            AV_FAIL=true
        fi
    fi
    # Must NOT have Medium or Low confidence (markdown bold or plain-text formats)
    echo "$_CT_VALIDATION_TEXT" | grep -qiE '(\*\*(Medium|Low)\*\*|[Cc]onfidence:?\s*(Medium|Low)|(Medium|Low) confidence)' && AV_FAIL=true

    if [[ "$AV_FAIL" == "false" ]]; then
        ENV_PATTERN='requires browser\|requires viewport\|requires screen reader\|requires mobile\|requires physical device\|requires hardware\|requires manual interaction\|requires human interaction\|requires GUI\|requires native app\|requires network'
        WHITELISTED_COUNT=$(echo "$NOT_TESTED_LINES" | grep -ic "$ENV_PATTERN" 2>/dev/null || echo "0")
        write_proof_status "verified" "$PROJECT_ROOT"
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

    # @decision DEC-TESTER-005
    # @title Finalize trace in auto-verify fast path (Phase 1)
    # @status accepted
    # @rationale Phase 1 auto-verify exits at line ~159 without running Phase 2,
    #   which contains detect_active_trace + finalize_trace. This leaves traces
    #   permanently "active" with stale markers in TRACE_STORE. Fix: detect and
    #   finalize the active trace within the auto-verify block before early exit.
    #   Issue #123.
    AV_TRACE_ID=$(detect_active_trace "$PROJECT_ROOT" "tester" 2>/dev/null || echo "")
    if [[ -n "$AV_TRACE_ID" ]]; then
        AV_TRACE_DIR="${TRACE_STORE}/${AV_TRACE_ID}"
        # Use 10-byte minimum threshold — see DEC-TESTER-007 below.
        _av_sum_size=$(wc -c < "$AV_TRACE_DIR/summary.md" 2>/dev/null || echo 0)
        if [[ ! -f "$AV_TRACE_DIR/summary.md" ]] || [[ "$_av_sum_size" -lt 10 ]]; then
            if [[ -z "${RESPONSE_TEXT// /}" ]]; then
                {
                    echo "# Agent returned empty response ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
                    echo "Agent type: tester"
                    echo "Duration: ${SECONDS:-unknown}s"
                    echo "Likely cause: max_turns exhausted or force-stopped"
                } > "$AV_TRACE_DIR/summary.md" 2>/dev/null || true
            else
                echo "$RESPONSE_TEXT" | head -c 4000 > "$AV_TRACE_DIR/summary.md" 2>/dev/null || true
            fi
        fi
        finalize_trace "$AV_TRACE_ID" "$PROJECT_ROOT" "tester" 2>/dev/null || true
    fi

    CONTEXT="Tester validation: proof-status=verified (auto-verified)."
    DIRECTIVE="AUTO-VERIFIED: Tester e2e verification passed — High confidence, full coverage, no caveats. .proof-status is verified. Dispatch Guardian NOW with 'AUTO-VERIFY-APPROVED' in the prompt. Guardian will skip its approval prompt and execute the full merge cycle directly. Present the tester's verification report to the user in parallel."
    ESCAPED=$(printf '%s\n\n%s' "$CONTEXT" "$DIRECTIVE" | jq -Rs .)
    # Fix 3 (DEC-TESTER-001): use additionalContext not systemMessage.
    # SubagentStop hooks use additionalContext — systemMessage delivery is
    # unverified for this hook type and may be silently dropped.
    cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF
    exit 0
fi

fi # end CLAUDE_ENABLE_SUBAGENT_AUTOVERIFY gate

# ============================================================================
# PHASE 2 — Advisory work (runs only when not auto-verified)
# ============================================================================

# Ensure Phase 2 variables are initialized even when Phase 1 gate is disabled.
# When CLAUDE_ENABLE_SUBAGENT_AUTOVERIFY is unset, PROOF_FILE/PROOF_STATUS/RESPONSE_TEXT
# were never defined above — initialize them here so Phase 2 logic is safe.
if [[ -z "${PROOF_FILE:-}" ]]; then
    PROOF_FILE=$(resolve_proof_file)
    PROOF_STATUS="missing"
    if [[ -f "$PROOF_FILE" ]]; then
        PROOF_STATUS=$(cut -d'|' -f1 "$PROOF_FILE")
    fi
fi
if [[ -z "${RESPONSE_TEXT+x}" ]]; then
    RESPONSE_TEXT=$(echo "$AGENT_RESPONSE" | jq -r '.last_assistant_message // .response // empty' 2>/dev/null || echo "")
fi

# Safety net (DEC-TESTER-003): if proof-status is missing and RESPONSE_TEXT is
# non-empty, auto-write "pending" so the manual approval flow can proceed.
# This handles testers that forgot to write .proof-status.
if [[ "$PROOF_STATUS" == "missing" && -n "$RESPONSE_TEXT" ]]; then
    mkdir -p "$(dirname "$PROOF_FILE")"
    echo "pending|$(date +%s)" > "$PROOF_FILE"
    PROOF_STATUS="pending"
fi

# Track subagent completion
track_subagent_stop "$PROJECT_ROOT" "tester"
append_session_event "agent_stop" "{\"type\":\"tester\"}" "$PROJECT_ROOT"

# --- Trace protocol: detect and prepare for finalization ---
# If detect_active_trace returns empty, log trace_skip (not trace_orphan) — the
# tester may not have initialized a trace (e.g., quick verifications, or
# init_trace failed silently). This is informational, not a real orphan
# (Issue #123 Fix 3).
TRACE_ID=$(detect_active_trace "$PROJECT_ROOT" "tester" 2>/dev/null || echo "")
TRACE_DIR=""
if [[ -n "$TRACE_ID" ]]; then
    TRACE_DIR="${TRACE_STORE}/${TRACE_ID}"
else
    append_audit "$PROJECT_ROOT" "trace_skip" "detect_active_trace returned empty for tester — no trace to finalize"
fi

get_git_state "$PROJECT_ROOT"
get_plan_status "$PROJECT_ROOT"
write_statusline_cache "$PROJECT_ROOT"

ISSUES=()
CONTEXT=""  # Built after issues are collected; initialized here for early-exit branches

# Layer A: Surface trace context when agent response is short.
# Short returns are normal under Trace Protocol — only flag when genuinely lost.
# Note: RESPONSE_TEXT may have been supplemented from summary.md (DEC-V3-001) above;
# use the original last_assistant_message length check to avoid false negatives.
# See DEC-SILENT-RETURN-001 in check-guardian.sh for rationale.
_orig_response_len=$(echo "$AGENT_RESPONSE" | jq -r '.last_assistant_message // .response // empty' 2>/dev/null | wc -c | tr -d ' ')
if [[ "${_orig_response_len:-0}" -lt 50 ]]; then
    _has_trace="false"
    if [[ -n "$TRACE_DIR" && -f "$TRACE_DIR/summary.md" ]]; then
        _trace_size=$(wc -c < "$TRACE_DIR/summary.md" 2>/dev/null || echo 0)
        [[ "$_trace_size" -gt 10 ]] && _has_trace="true"
    fi
    if [[ "$_has_trace" == "false" && -z "${RESPONSE_TEXT// /}" ]]; then
        ISSUES+=("Agent returned no response and no trace summary available. Check git log for what happened.")
    fi
fi

# Check 1b: Flag missing .proof-status
if [[ "$PROOF_STATUS" == "missing" ]]; then
    ISSUES+=("Tester returned without writing .proof-status — verification evidence not collected")
fi

# --- finalize_trace: run BEFORE Check 3 so manifest.json reflects current artifacts ---
# Fix 2 (DEC-TESTER-004): finalize_trace was previously inside Check 2 (auto-capture
# block), meaning Check 3 would read a stale manifest. Moving finalize here ensures
# Check 3 reads a fresh manifest outcome before auto-capture contaminates the check.
if [[ -n "$TRACE_DIR" && -d "$TRACE_DIR/artifacts" ]]; then
    # Validate summary exists and has meaningful content (10-byte minimum).
    # See DEC-TESTER-007: -s (size > 0) was fooled by 1-byte newline from empty RESPONSE_TEXT.
    #
    # @decision DEC-TESTER-007
    # @title Use 10-byte minimum threshold for tester summary.md fallback check
    # @status accepted
    # @rationale Same root cause as DEC-IMPL-STOP-003: the -s check passes for a
    #   1-byte newline written when RESPONSE_TEXT is empty (max_turns exhausted).
    #   The 10-byte threshold catches both missing and trivially empty summary files.
    #   When RESPONSE_TEXT is empty, a diagnostic message is written so the
    #   orchestrator has context about why the tester stopped without reporting.
    _sum_size=$(wc -c < "$TRACE_DIR/summary.md" 2>/dev/null || echo 0)
    if [[ ! -f "$TRACE_DIR/summary.md" ]] || [[ "$_sum_size" -lt 10 ]]; then
        if [[ -z "${RESPONSE_TEXT// /}" ]]; then
            {
                echo "# Agent returned empty response ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
                echo "Agent type: tester"
                echo "Duration: ${SECONDS:-unknown}s"
                echo "Likely cause: max_turns exhausted or force-stopped"
            } > "$TRACE_DIR/summary.md" 2>/dev/null || true
        else
            echo "$RESPONSE_TEXT" | head -c 4000 > "$TRACE_DIR/summary.md" 2>/dev/null || true
        fi
    fi
    if ! finalize_trace "$TRACE_ID" "$PROJECT_ROOT" "tester"; then
        append_audit "$PROJECT_ROOT" "trace_orphan" "finalize_trace failed for tester trace $TRACE_ID"
    fi
fi

# Check 3: Tester completeness — detect partial/incomplete runs
# Fix 2 (DEC-TESTER-004): runs BEFORE auto-capture in Check 2.
# A tester that only wrote strategy but never produced verification output
# must not enter the approval flow. Force resume instead.
# Both signals required (AND logic) — finalize_trace marks outcome="partial"
# when test-output.txt is missing, but testers write verification-output.txt
# instead. A tester with verification-output.txt IS complete regardless of
# manifest outcome.
#
# @decision DEC-TESTER-002
# @title Block partial/skipped tester runs before approval flow (AND logic)
# @status accepted
# @rationale A tester that exits after planning but before executing verification
#   must not enter the approval flow. Two signals together detect incompleteness:
#   1. manifest.json outcome == "partial" OR "skipped" (finalize_trace signals)
#      "partial" = artifacts dir has files but no pass signal (started, didn't finish)
#      "skipped" = artifacts dir is empty (exited before writing anything)
#   2. artifacts/verification-output.txt missing (concrete evidence absent)
#   AND logic is required because finalize_trace() marks testers as "partial"
#   when test-output.txt is absent — but testers write verification-output.txt
#   as their primary artifact, not test-output.txt. A tester with
#   verification-output.txt IS complete even if finalize_trace shows "partial".
#   The gate exits 2 (force resume) to unblock the tester.
#   IMPORTANT: This check reads manifest.json AFTER finalize_trace() has run
#   (DEC-TESTER-004) and BEFORE auto-capture (Check 2) writes
#   verification-output.txt. This is the only ordering that makes the AND
#   condition meaningful.
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

    # Block when outcome is partial or skipped AND verification output is missing.
    # "partial" = artifacts dir has files but no pass signal (tester started but didn't finish).
    # "skipped" = artifacts dir is empty (tester exited before writing anything).
    # Both indicate the tester planned but never executed verification.
    # AND logic prevents false positives: verification-output.txt present means
    # the tester ran, even if finalize_trace couldn't classify it as success.
    if [[ ("$TRACE_OUTCOME" == "partial" || "$TRACE_OUTCOME" == "skipped") && "$HAS_VERIFICATION" == "false" ]]; then
        TESTER_COMPLETE=false
    fi
fi

if [[ "$TESTER_COMPLETE" == "false" ]]; then
    DIRECTIVE="INCOMPLETE: Tester returned without completing verification (trace outcome: ${TRACE_OUTCOME:-unknown}). Do NOT present confidence levels or approve merge from partial results. Resume the tester to complete verification."
    ESCAPED=$(printf '%s\n\n%s' "$CONTEXT" "$DIRECTIVE" | jq -Rs .)
    cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF
    exit 2  # Force tester resume
fi

# Check 2: Trace artifacts include verification evidence (not just test output)
# Fix 2 (DEC-TESTER-004): runs AFTER Check 3 so auto-capture cannot defeat
# the completeness gate. Auto-capture here is for archival purposes only.
if [[ -n "$TRACE_DIR" && -d "$TRACE_DIR/artifacts" ]]; then
    # Auto-capture verification-output.txt from response text if agent didn't write it.
    # The tester's response IS the verification evidence — capturing it here ensures
    # the trace archive is complete for observability purposes.
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

# Decision gate based on proof status
if [[ "$PROOF_STATUS" == "verified" ]]; then
    # User has confirmed — Guardian dispatch is unblocked
    ESCAPED=$(printf '%s\nProof verified by user. Guardian dispatch is now unblocked.' "$CONTEXT" | jq -Rs .)
    cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF
    exit 0
elif [[ "$PROOF_STATUS" == "pending" ]]; then
    # Auto-verify was attempted above but AV_FAIL was set.
    # Check if AUTOVERIFY signal was present but failed secondary validation.
    # Only log rejection if Phase 1 was enabled — otherwise post-task.sh handles auto-verify
    # and logging rejection here would be misleading (auto-verify was never attempted here).
    if echo "$RESPONSE_TEXT" | grep -q 'AUTOVERIFY: CLEAN'; then
        if [[ "${CLAUDE_ENABLE_SUBAGENT_AUTOVERIFY:-}" == "true" ]]; then
            append_audit "$PROJECT_ROOT" "auto_verify_rejected" "Tester signaled AUTOVERIFY: CLEAN but secondary validation failed"
        fi
    fi
    DIRECTIVE="TESTER COMPLETE: The tester has presented a verification report with evidence, methodology assessment, and confidence level. Present the full report to the user — do NOT reduce it to a keyword demand. The user can approve (approved, lgtm, looks good, verified, ship it), request more testing, or ask questions. Do NOT tell the user to 'say verified'. Guardian dispatch requires .proof-status = verified (prompt-submit.sh writes this on user approval)."
    ESCAPED=$(printf '%s\n\n%s' "$CONTEXT" "$DIRECTIVE" | jq -Rs .)
    cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF
    exit 0
else
    # proof-status missing or unknown — tester didn't complete its job
    DIRECTIVE="BLOCKED: Tester returned without completing verification.\nResume the tester to:\n1. Run the feature/system live\n2. Show actual output to the user\n3. Write pending to .proof-status\n4. Present the verification report and let the user respond naturally"
    ESCAPED=$(printf '%s\n\n%s' "$CONTEXT" "$DIRECTIVE" | jq -Rs .)
    cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF
    exit 2  # Feedback loop — force tester resume
fi
