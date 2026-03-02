#!/usr/bin/env bash
# PostToolUse:Task — auto-verify migration from SubagentStop:tester.
#
# Fires after every Task tool completes. When the completed task was a tester
# agent, reads the tester's summary.md from its trace directory (via the
# .active-tester-* breadcrumb) and performs auto-verify secondary validation.
#
# If ALL conditions pass, writes verified status to three paths:
#   1. Worktree proof-status (resolve_proof_file)
#   2. Orchestrator scoped proof-status (.proof-status-{phash})
#   3. Orchestrator legacy proof-status (.proof-status)
#
# Emits AUTO-VERIFIED directive in additionalContext on success.
#
# Secondary validation rules (mirrors check-tester.sh Phase 1):
#   - AUTOVERIFY: CLEAN present in summary.md
#   - **High** confidence (markdown bold)
#   - NO **Medium** or **Low** confidence
#   - NO "Partially verified"
#   - NO non-environmental "Not tested" (environmental patterns whitelisted)
#
# PostToolUse:Task stdin format:
#   {"tool_name":"Task","tool_input":{"subagent_type":"tester","prompt":"..."},"cwd":"..."}
#
# @decision DEC-PROOF-LIFE-001
# @title New post-task.sh handler (not extending task-track.sh)
# @status accepted
# @rationale SubagentStop:tester does not fire reliably (confirmed dead event
#   in practice). PostToolUse:Task fires after every Task tool call and contains
#   the subagent_type in tool_input, enabling us to identify tester completions.
#   Extending task-track.sh (PreToolUse:Task) would conflate pre/post semantics;
#   a dedicated post-task.sh handler is cleaner and easier to test independently.
#   Issue #150.
#
# @decision DEC-PROOF-LIFE-002
# @title Read summary.md via tester breadcrumb (PostToolUse lacks last_assistant_message)
# @status accepted
# @rationale PostToolUse:Task stdin does not include the agent's response text
#   (unlike SubagentStop which provides last_assistant_message). The AUTOVERIFY
#   signal must be read from the tester's trace summary.md artifact, which the
#   Trace Protocol requires the tester to write before returning. The active
#   tester trace is found via detect_active_trace() or .active-tester-* marker
#   files in TRACE_STORE. This is the same approach used by check-tester.sh's
#   DEC-V3-001 summary.md fallback. Issue #150.

set -euo pipefail

source "$(dirname "$0")/source-lib.sh"

require_trace

HOOK_INPUT=$(read_input)
TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
SUBAGENT_TYPE=$(echo "$HOOK_INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || echo "")

# Diagnostic: confirm hook fires (DEC-AV-DIAG-001)
append_audit "$(detect_project_root 2>/dev/null || echo /)" "post_task_fire" \
    "subagent_type=${SUBAGENT_TYPE:-empty} tool_name=${TOOL_NAME:-empty}" 2>/dev/null || true

# Fallback: PostToolUse:Task may not provide tool_input.subagent_type (undocumented).
# Detect active tester trace as proxy.
if [[ "$TOOL_NAME" == "Task" && -z "$SUBAGENT_TYPE" ]]; then
    _fb_trace=$(detect_active_trace "$(detect_project_root 2>/dev/null || echo /)" "tester" 2>/dev/null || echo "")
    if [[ -n "$_fb_trace" ]]; then
        SUBAGENT_TYPE="tester"
        log_info "POST-TASK" "subagent_type empty — detected active tester trace, assuming tester"
    fi
fi

# Universal fallback: for any Task tool completion with a known agent type
# that isn't the tester, attempt to finalize any active trace.
# This catches edge cases where the SubagentStop hook for the agent type doesn't
# fire reliably (same root cause as DEC-PROOF-LIFE-001 for tester).
#
# @decision DEC-POST-TASK-FALLBACK-001
# @title Universal PostToolUse:Task trace finalization for non-tester agents
# @status accepted
# @rationale SubagentStop does not fire reliably for any agent type. The tester
#   path above has comprehensive trace finalization. Non-tester agents (implementer,
#   guardian, planner, or unrecognized types) have no PostToolUse handler — their
#   traces may not get finalized if SubagentStop is skipped. This fallback detects
#   any active trace for the completing agent type and calls finalize_trace, ensuring
#   the observatory gets complete data regardless of hook reliability. The fallback
#   is a no-op when the active trace was already finalized by SubagentStop.
if [[ "$TOOL_NAME" == "Task" && "$SUBAGENT_TYPE" != "tester" && -n "$SUBAGENT_TYPE" ]]; then
    _fb_project_root=$(detect_project_root 2>/dev/null || echo "")
    if [[ -n "$_fb_project_root" ]]; then
        _fb_trace_id=$(detect_active_trace "$_fb_project_root" "$SUBAGENT_TYPE" 2>/dev/null || echo "")
        if [[ -n "$_fb_trace_id" ]]; then
            log_info "POST-TASK" "fallback: detected active ${SUBAGENT_TYPE} trace ${_fb_trace_id} — finalizing"
            finalize_trace "$_fb_trace_id" "$_fb_project_root" "$SUBAGENT_TYPE" 2>/dev/null || true
            log_info "POST-TASK" "fallback: trace finalized for agent_type=${SUBAGENT_TYPE}"
            append_audit "$_fb_project_root" "post_task_fallback_finalize" \
                "agent_type=${SUBAGENT_TYPE} trace=${_fb_trace_id}" 2>/dev/null || true
        fi
    fi
fi

# --- Implementer completion: auto-dispatch tester directive ---
# @decision DEC-IMPL-DISPATCH-001
# @title Auto-dispatch tester directive after implementer returns
# @status accepted
# @rationale CLAUDE.md mandates auto-dispatch of tester after implementer returns
#   with passing tests. Previously no hook emitted a directive, causing the
#   orchestrator to ask "want me to dispatch tester?" instead. This handler
#   checks test status and emits "DISPATCH TESTER NOW" when tests pass.
if [[ "$TOOL_NAME" == "Task" && "$SUBAGENT_TYPE" == "implementer" ]]; then
    _impl_root=$(detect_project_root 2>/dev/null || echo "")
    if [[ -n "$_impl_root" ]]; then
        _impl_tests_pass=false
        # Use subshell to isolate set -u crash from non-numeric TEST_TIME
        if (read_test_status "$_impl_root") 2>/dev/null; then
            # Re-read in parent shell (subshell can't export globals back)
            read_test_status "$_impl_root" 2>/dev/null || true
            [[ "${TEST_RESULT:-}" == "pass" ]] && _impl_tests_pass=true
        fi

        if [[ "$_impl_tests_pass" == "true" ]]; then
            _IMPL_DIR="DISPATCH TESTER NOW: Implementer returned with tests passing. Auto-dispatch tester per CLAUDE.md. Do NOT ask the user."
        else
            _IMPL_DIR="Implementer returned (tests: ${TEST_RESULT:-unknown}). Review findings before dispatching tester."
        fi

        _IMPL_ESC=$(printf '%s' "$_IMPL_DIR" | jq -Rs .)
        cat <<EOF
{ "additionalContext": $_IMPL_ESC }
EOF
        exit 0
    fi
fi

# Only act on Task tool completions for the tester subagent
if [[ "$TOOL_NAME" != "Task" || "$SUBAGENT_TYPE" != "tester" ]]; then
    exit 0
fi

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)

log_info "POST-TASK" "tester Task completed — checking for AUTOVERIFY signal"

# --- Resolve active proof-status file ---
PROOF_FILE=$(resolve_proof_file)
PROOF_STATUS="missing"
if [[ -f "$PROOF_FILE" ]]; then
    PROOF_STATUS=$(cut -d'|' -f1 "$PROOF_FILE")
fi

log_info "POST-TASK" "proof-status=$PROOF_STATUS proof_file=$PROOF_FILE"

# --- Dedup guard: skip if already verified ---
# Prevents double-write if PostToolUse fires multiple times for the same tester.
if [[ "$PROOF_STATUS" == "verified" ]]; then
    log_info "POST-TASK" "already verified — skipping (dedup guard)"
    cat <<'EOF'
{
  "additionalContext": "post-task: tester completed, proof already verified (dedup guard — no action needed)."
}
EOF
    exit 0
fi

# --- Safety net: if proof-status missing, create needs-verification ---
# If somehow there is no proof-status file at all, create a needs-verification
# entry so the approval flow can still proceed (mirrors check-tester.sh DEC-TESTER-003).
if [[ "$PROOF_STATUS" == "missing" ]]; then
    log_info "POST-TASK" "proof-status missing — writing needs-verification (safety net)"
    mkdir -p "$(dirname "$PROOF_FILE")"
    echo "needs-verification|$(date +%s)" > "$PROOF_FILE"
    PROOF_STATUS="needs-verification"
fi

# --- Read tester summary.md from trace ---
# PostToolUse lacks last_assistant_message; use TRACE_STORE to find summary.md.
SUMMARY_TEXT=""
_AV_TRACE_ID=$(detect_active_trace "$PROJECT_ROOT" "tester" 2>/dev/null || echo "")

# Tier 0: breadcrumb from check-tester.sh (SubagentStop writes trace_id here)
# This bypasses the marker race entirely — check-tester.sh writes the breadcrumb
# AFTER finalize_trace deletes the marker, so it's always available.
if [[ -z "$_AV_TRACE_ID" ]]; then
    _BREADCRUMB="${CLAUDE_DIR}/.last-tester-trace"
    if [[ -f "$_BREADCRUMB" ]]; then
        _candidate=$(cat "$_BREADCRUMB" 2>/dev/null)
        _cmf="${TRACE_STORE}/${_candidate}/manifest.json"
        if [[ -n "$_candidate" && -f "$_cmf" ]]; then
            _AV_TRACE_ID="$_candidate"
            log_info "POST-TASK" "found tester trace via breadcrumb: $_AV_TRACE_ID"
        fi
        rm -f "$_BREADCRUMB"  # consume the breadcrumb
    fi
fi

# Fallback: marker may have been cleaned by SubagentStop's finalize_trace()
# before PostToolUse:Task fires. Scan recent tester traces for matching session+project.
# @decision DEC-AV-RACE-001
# @title Session-based trace fallback when active marker is gone
# @status accepted
# @rationale SubagentStop fires before PostToolUse:Task and finalize_trace() removes
#   the .active-tester-* marker. Post-task.sh needs the trace to read summary.md.
#   Scanning the 5 most recent tester manifests for session_id+project match is safe
#   (session scoping prevents cross-contamination) and fast (5 jq calls max).
if [[ -z "$_AV_TRACE_ID" && -n "${CLAUDE_SESSION_ID:-}" ]]; then
    for _dir in $(ls -1d "${TRACE_STORE}/tester-"* 2>/dev/null | sort -r | head -5); do
        _mf="${_dir}/manifest.json"
        [[ -f "$_mf" ]] || continue
        _ms=$(jq -r '.session_id // empty' "$_mf" 2>/dev/null)
        _mp=$(jq -r '.project // empty' "$_mf" 2>/dev/null)
        if [[ "$_ms" == "$CLAUDE_SESSION_ID" && "$_mp" == "$PROJECT_ROOT" ]]; then
            _AV_TRACE_ID=$(basename "$_dir")
            log_info "POST-TASK" "marker gone — found tester trace by session scan: $_AV_TRACE_ID"
            break
        fi
    done
fi

if [[ -n "$_AV_TRACE_ID" ]]; then
    _AV_SUMMARY="${TRACE_STORE}/${_AV_TRACE_ID}/summary.md"
    log_info "POST-TASK" "found active tester trace=${_AV_TRACE_ID}"
    if [[ -s "$_AV_SUMMARY" ]]; then
        _SUMMARY_SIZE=$(wc -c < "$_AV_SUMMARY" 2>/dev/null || echo 0)
        if [[ "$_SUMMARY_SIZE" -ge 10 ]]; then
            SUMMARY_TEXT=$(cat "$_AV_SUMMARY" 2>/dev/null || echo "")
            log_info "POST-TASK" "loaded summary.md size=$_SUMMARY_SIZE"
        else
            log_info "POST-TASK" "summary.md too small (${_SUMMARY_SIZE} bytes) — likely empty"
        fi
    else
        log_info "POST-TASK" "summary.md not found or empty at ${_AV_SUMMARY}"
    fi
else
    log_info "POST-TASK" "no active tester trace found — cannot read summary.md"
fi

# Fallback: summary.md may be in a DIFFERENT trace than the one detected.
# task-track.sh creates trace #1 (orchestrator session), subagent-start.sh creates
# trace #2 (subagent session). The tester writes summary.md to trace #2.
# Scan recent tester traces for the one with actual summary content.
#
# @decision DEC-AV-DUAL-001
# @title Project-scoped summary.md scan for dual-trace scenarios
# @status accepted
# @rationale Each tester dispatch creates two traces with different session_ids.
#   The marker and session-based fallback find trace #1 (no summary). The actual
#   summary is in trace #2. Scanning recent traces for summary.md + project match
#   is safe (project-scoped, 5 trace limit) and handles all detection failures.
if [[ -z "$SUMMARY_TEXT" ]]; then
    for _dir in $(ls -1d "${TRACE_STORE}/tester-"* 2>/dev/null | sort -r | head -5); do
        _smf="${_dir}/summary.md"
        [[ -s "$_smf" ]] || continue
        _sz=$(wc -c < "$_smf" 2>/dev/null || echo 0)
        [[ "$_sz" -ge 50 ]] || continue  # 50-byte minimum: real summaries are much larger
        _mp=$(jq -r '.project // empty' "${_dir}/manifest.json" 2>/dev/null)
        if [[ "$_mp" == "$PROJECT_ROOT" ]]; then
            SUMMARY_TEXT=$(cat "$_smf" 2>/dev/null || echo "")
            _AV_TRACE_ID=$(basename "$_dir")
            log_info "POST-TASK" "primary trace had no summary — found summary in $_AV_TRACE_ID (project-scoped scan)"
            break
        fi
    done
fi

# No summary available after all fallbacks — cannot auto-verify, exit gracefully
if [[ -z "$SUMMARY_TEXT" ]]; then
    log_info "POST-TASK" "no summary.md content available — skipping auto-verify"
    exit 0
fi

# --- Trace finalization: write summary.md if missing and finalize ---
# Runs after all summary fallbacks resolve, before auto-verify check.
# In PostToolUse:Task, SubagentStop may not have fired reliably, so we
# ensure the trace is sealed here on all code paths.
#
# @decision DEC-TESTER-ABSORB-002
# @title Trace finalization in post-task.sh absorbs check-tester.sh Phase 2 logic
# @status accepted
# @rationale SubagentStop:tester does not fire reliably. Post-task.sh fires
#   AFTER every Task tool completion. Finalizing the trace here guarantees that
#   the trace is sealed even when SubagentStop is skipped. This mirrors the
#   finalize_trace() call in check-tester.sh lines 390-418.
if [[ -n "$_AV_TRACE_ID" ]]; then
    _PT_TRACE_DIR="${TRACE_STORE}/${_AV_TRACE_ID}"
    if [[ -d "$_PT_TRACE_DIR" ]]; then
        # Write summary.md from SUMMARY_TEXT if missing or trivially empty
        _pt_sum_size=$(wc -c < "$_PT_TRACE_DIR/summary.md" 2>/dev/null || echo 0)
        if [[ ! -f "$_PT_TRACE_DIR/summary.md" ]] || [[ "$_pt_sum_size" -lt 10 ]]; then
            if [[ -n "$SUMMARY_TEXT" ]]; then
                echo "$SUMMARY_TEXT" | head -c 4000 > "$_PT_TRACE_DIR/summary.md" 2>/dev/null || true
                log_info "POST-TASK" "wrote summary.md to trace (was missing/trivially empty)"
            fi
        fi
        finalize_trace "$_AV_TRACE_ID" "$PROJECT_ROOT" "tester" 2>/dev/null || true
        log_info "POST-TASK" "trace finalized: $_AV_TRACE_ID"
    fi
fi

# --- Check for AUTOVERIFY: CLEAN signal ---
if ! echo "$SUMMARY_TEXT" | grep -q 'AUTOVERIFY: CLEAN'; then
    log_info "POST-TASK" "AUTOVERIFY: CLEAN not found in summary.md — running completeness check"

    # --- Completeness gate (adapted from check-tester.sh DEC-TESTER-002) ---
    # In PostToolUse, exit 2 doesn't block — Task already completed.
    # Instead, inject advisory and write to .agent-findings.
    #
    # @decision DEC-TESTER-ABSORB-001
    # @title Completeness gate in post-task.sh (advisory, not blocking)
    # @status accepted
    # @rationale PostToolUse:Task fires AFTER the tester has returned. exit 2
    #   cannot force resume. Advisory injection alerts the orchestrator that
    #   the tester may not have finished, preventing premature approval.
    #   Both signals required (AND logic) — same as check-tester.sh DEC-TESTER-002:
    #   manifest outcome partial/skipped AND verification-output.txt missing.
    PT_ISSUES=()
    PT_TESTER_COMPLETE=true
    PT_TRACE_OUTCOME=""

    if [[ -n "$_AV_TRACE_ID" ]]; then
        _PT2_TRACE_DIR="${TRACE_STORE}/${_AV_TRACE_ID}"

        # Read trace outcome from manifest (finalize_trace already ran above)
        if [[ -f "$_PT2_TRACE_DIR/manifest.json" ]]; then
            PT_TRACE_OUTCOME=$(jq -r '.outcome // "unknown"' "$_PT2_TRACE_DIR/manifest.json" 2>/dev/null || echo "unknown")
        fi

        # Check for verification artifact
        PT_HAS_VERIFICATION=false
        if [[ -d "$_PT2_TRACE_DIR/artifacts" && -f "$_PT2_TRACE_DIR/artifacts/verification-output.txt" ]]; then
            PT_HAS_VERIFICATION=true
        fi

        # Completeness check: partial/skipped + no verification output = incomplete
        if [[ ("$PT_TRACE_OUTCOME" == "partial" || "$PT_TRACE_OUTCOME" == "skipped") && "$PT_HAS_VERIFICATION" == "false" ]]; then
            PT_TESTER_COMPLETE=false
        fi

        # Artifact auto-capture: if verification-output.txt missing but summary has content
        if [[ -d "$_PT2_TRACE_DIR/artifacts" && ! -f "$_PT2_TRACE_DIR/artifacts/verification-output.txt" ]]; then
            if [[ -n "$SUMMARY_TEXT" && ${#SUMMARY_TEXT} -gt 100 ]]; then
                {
                    echo "# Auto-captured from summary.md by post-task.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
                    echo "$SUMMARY_TEXT" | head -c 8000
                } > "$_PT2_TRACE_DIR/artifacts/verification-output.txt" 2>/dev/null || true
                log_info "POST-TASK" "auto-captured verification-output.txt from summary.md"
            fi
        fi
    fi

    # Inject advisory for incomplete tester
    if [[ "$PT_TESTER_COMPLETE" == "false" ]]; then
        log_info "POST-TASK" "tester incomplete (outcome=${PT_TRACE_OUTCOME}) — injecting advisory"
        PT_ESCAPED=$(printf 'TESTER INCOMPLETE — trace outcome=%s, verification artifact missing. The tester may not have finished. Review before approving.' \
            "${PT_TRACE_OUTCOME:-unknown}" | jq -Rs .)

        # Write findings
        _PT_CLAUDE_DIR=$(get_claude_dir)
        _PT_FINDINGS="${_PT_CLAUDE_DIR}/.agent-findings"
        _PT_FINDING="tester|Incomplete tester run (outcome=${PT_TRACE_OUTCOME})"
        if ! grep -qxF "$_PT_FINDING" "$_PT_FINDINGS" 2>/dev/null; then
            echo "$_PT_FINDING" >> "$_PT_FINDINGS" 2>/dev/null || true
        fi
        append_audit "$PROJECT_ROOT" "tester_incomplete" "post-task: tester trace outcome=${PT_TRACE_OUTCOME}, verification artifact missing"

        cat <<EOF
{
  "additionalContext": $PT_ESCAPED
}
EOF
        exit 0
    fi

    exit 0
fi

log_info "POST-TASK" "AUTOVERIFY: CLEAN found — running secondary validation"

# --- Extract Verification Assessment section for secondary validation ---
# Tester summaries often include test case descriptions that mention keywords
# like "Medium confidence" or "Partially verified" as test names (e.g.,
# "Rejection: Medium confidence → pending (T2)"). These appear in earlier
# sections (Test Results, coverage tables) and cause false positive rejections
# when the full SUMMARY_TEXT is searched. The actual confidence level and
# caveats appear only in the Verification Assessment section.
# Scoping validation to this section eliminates all such false positives.
#
# @decision DEC-AV-SECTION-001
# @title Scope secondary validation to Verification Assessment section
# @status accepted
# @rationale Tester summaries include test descriptions that mention "Medium",
#   "Partially verified", etc. as test case names. These are in earlier sections
#   (Test Results, coverage tables). The actual confidence level and caveats
#   appear only in the Verification Assessment section. Scoping validation to
#   this section eliminates all keyword-in-description false positives.
#   The AUTOVERIFY: CLEAN check above runs on full SUMMARY_TEXT (can appear anywhere).
# grep returns exit 1 when no match — || true prevents set -e from killing the script.
_VA_START=$(echo "$SUMMARY_TEXT" | grep -n -E '^#{1,3} Verification Assessment' | head -1 | cut -d: -f1 || true)
if [[ -n "$_VA_START" ]]; then
    # Extract from the VA heading to EOF. Sub-headings within VA (e.g., "## Confidence: High",
    # "### Coverage") belong to the assessment and must be included. Stopping at the first
    # subsequent "##" heading would incorrectly truncate VA sub-headings.
    # Sections that follow VA (Summary, Files Changed, Next Steps) do not contain
    # confidence-level keywords, so including them via EOF extraction is safe.
    VALIDATION_TEXT=$(echo "$SUMMARY_TEXT" | tail -n +"${_VA_START}")
    log_info "POST-TASK" "extracted Verification Assessment section (${#VALIDATION_TEXT} chars) for secondary validation"
else
    # No Verification Assessment section — use full summary (backward compat)
    VALIDATION_TEXT="$SUMMARY_TEXT"
    log_info "POST-TASK" "no Verification Assessment section found — using full summary for validation"
fi

# --- Secondary validation (mirrors check-tester.sh lines 194-232) ---
AV_FAIL=false
NOT_TESTED_LINES=""
WHITELISTED_COUNT=0

# Must have High confidence (markdown bold or plain-text formats)
if ! echo "$VALIDATION_TEXT" | grep -qiE '(\*\*High\*\*|[Cc]onfidence:?\s*High|High confidence)'; then
    log_info "POST-TASK" "secondary validation FAIL: missing High confidence"
    AV_FAIL=true
fi

# Must NOT have "Partially verified"
if echo "$VALIDATION_TEXT" | grep -qi 'Partially verified'; then
    log_info "POST-TASK" "secondary validation FAIL: 'Partially verified' found"
    AV_FAIL=true
fi

# Must NOT have Medium or Low confidence (markdown bold or plain-text formats)
if echo "$VALIDATION_TEXT" | grep -qiE '(\*\*(Medium|Low)\*\*|[Cc]onfidence:?\s*(Medium|Low)|(Medium|Low) confidence)'; then
    log_info "POST-TASK" "secondary validation FAIL: Medium or Low confidence found"
    AV_FAIL=true
fi

# Must NOT have non-environmental "Not tested" entries
# Environmental patterns are whitelisted — they cannot be tested in a headless CLI context
ENV_PATTERN='requires browser\|requires viewport\|requires screen reader\|requires mobile\|requires physical device\|requires hardware\|requires manual interaction\|requires human interaction\|requires GUI\|requires native app\|requires network'
NOT_TESTED_LINES=$(echo "$VALIDATION_TEXT" | grep -iE '(:\s*Not tested|\|\s*Not tested)' || true)
if [[ -n "$NOT_TESTED_LINES" ]]; then
    NON_ENV_LINES=$(echo "$NOT_TESTED_LINES" | grep -iv "$ENV_PATTERN" || true)
    if [[ -n "$NON_ENV_LINES" ]]; then
        log_info "POST-TASK" "secondary validation FAIL: non-environmental 'Not tested' found: $NON_ENV_LINES"
        AV_FAIL=true
    else
        # Count whitelisted environmental items
        WHITELISTED_COUNT=$(echo "$NOT_TESTED_LINES" | grep -ic "$ENV_PATTERN" 2>/dev/null || echo "0")
        log_info "POST-TASK" "secondary validation: ${WHITELISTED_COUNT} environmental 'Not tested' item(s) whitelisted"
    fi
fi

# --- Apply result ---
if [[ "$AV_FAIL" == "true" ]]; then
    log_info "POST-TASK" "secondary validation FAILED — proof stays $PROOF_STATUS"
    append_audit "$PROJECT_ROOT" "auto_verify_rejected" \
        "post-task: AUTOVERIFY: CLEAN found but secondary validation failed (proof=$PROOF_STATUS)"
    # Build diagnostic reason for orchestrator visibility
    _AV_REASONS=""
    echo "$VALIDATION_TEXT" | grep -qiE '(\*\*High\*\*|[Cc]onfidence:?\s*High|High confidence)' \
        || _AV_REASONS="${_AV_REASONS}missing High confidence; "
    echo "$VALIDATION_TEXT" | grep -qi 'Partially verified' \
        && _AV_REASONS="${_AV_REASONS}has Partially verified; "
    echo "$VALIDATION_TEXT" | grep -qiE '(\*\*(Medium|Low)\*\*|[Cc]onfidence:?\s*(Medium|Low)|(Medium|Low) confidence)' \
        && _AV_REASONS="${_AV_REASONS}has Medium/Low confidence; "
    [[ -n "${NON_ENV_LINES:-}" ]] && _AV_REASONS="${_AV_REASONS}non-environmental Not tested; "
    ESCAPED=$(printf 'Auto-verify blocked: %s Manual approval required.' \
        "${_AV_REASONS:-unknown reason}" | jq -Rs .)

    # Persist findings for auto-verify rejection
    _AV_CLAUDE_DIR=$(get_claude_dir)
    _AV_FINDINGS="${_AV_CLAUDE_DIR}/.agent-findings"
    _AV_FINDING="tester|Auto-verify blocked: ${_AV_REASONS:-unknown reason}"
    if ! grep -qxF "$_AV_FINDING" "$_AV_FINDINGS" 2>/dev/null; then
        echo "$_AV_FINDING" >> "$_AV_FINDINGS" 2>/dev/null || true
    fi

    cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF
    exit 0
fi

# All checks passed — finalize trace and write verified to all three paths
# Auto-capture verification artifact from summary if missing
if [[ -n "$_AV_TRACE_ID" ]]; then
    _AVS_TRACE_DIR="${TRACE_STORE}/${_AV_TRACE_ID}"
    if [[ -d "$_AVS_TRACE_DIR/artifacts" && ! -f "$_AVS_TRACE_DIR/artifacts/verification-output.txt" ]]; then
        if [[ -n "$SUMMARY_TEXT" && ${#SUMMARY_TEXT} -gt 100 ]]; then
            {
                echo "# Auto-captured from summary.md by post-task.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
                echo "$SUMMARY_TEXT" | head -c 8000
            } > "$_AVS_TRACE_DIR/artifacts/verification-output.txt" 2>/dev/null || true
            log_info "POST-TASK" "auto-verified: captured verification-output.txt from summary.md"
        fi
    fi
fi

write_proof_status "verified" "$PROJECT_ROOT"

# Audit trail
if [[ "${WHITELISTED_COUNT:-0}" -gt 0 ]]; then
    append_audit "$PROJECT_ROOT" "auto_verify" "post-task: AUTOVERIFY: CLEAN — secondary validation passed, proof auto-verified (${WHITELISTED_COUNT} environmental 'Not tested' item(s) whitelisted)"
else
    append_audit "$PROJECT_ROOT" "auto_verify" "post-task: AUTOVERIFY: CLEAN — secondary validation passed, proof auto-verified"
fi

log_info "POST-TASK" "AUTO-VERIFIED — proof written to $PROOF_FILE"

# Emit directive with embedded evidence (DEC-EVGATE-004)
CONTEXT="post-task: tester Task completed — proof auto-verified (AUTOVERIFY: CLEAN, secondary validation passed)."
DIRECTIVE="AUTO-VERIFIED: .proof-status is verified. Dispatch Guardian NOW with 'AUTO-VERIFY-APPROVED' in the prompt."

# Read real verification evidence from trace artifacts
_EV_CONTENT=""
if [[ -n "$_AV_TRACE_ID" ]]; then
    _EV_CONTENT=$(read_trace_evidence "${TRACE_STORE}/${_AV_TRACE_ID}" 2000 2>/dev/null || echo "")
fi

if [[ -n "$_EV_CONTENT" ]]; then
    DIRECTIVE="${DIRECTIVE}
CRITICAL: Present the following verification evidence to the user:
\`\`\`
${_EV_CONTENT}
\`\`\`"
else
    # Fallback: embed summary.md content directly
    if [[ -n "$SUMMARY_TEXT" ]]; then
        _FALLBACK_CONTENT=$(echo "$SUMMARY_TEXT" | head -c 1500)
        DIRECTIVE="${DIRECTIVE}
Note: This is the tester's analysis summary, not raw terminal output.
Present it to the user — they need to see what was verified and how.
${_FALLBACK_CONTENT}"
    else
        DIRECTIVE="${DIRECTIVE}
Present the tester's verification report to the user."
    fi
fi

ESCAPED=$(printf '%s\n\n%s' "$CONTEXT" "$DIRECTIVE" | jq -Rs .)
cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF
exit 0
