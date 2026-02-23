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

# Only act on Task tool completions for the tester subagent
if [[ "$TOOL_NAME" != "Task" || "$SUBAGENT_TYPE" != "tester" ]]; then
    exit 0
fi

PROJECT_ROOT=$(detect_project_root)

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

# No summary available — cannot auto-verify, exit gracefully
if [[ -z "$SUMMARY_TEXT" ]]; then
    log_info "POST-TASK" "no summary.md content available — skipping auto-verify"
    exit 0
fi

# --- Check for AUTOVERIFY: CLEAN signal ---
if ! echo "$SUMMARY_TEXT" | grep -q 'AUTOVERIFY: CLEAN'; then
    log_info "POST-TASK" "AUTOVERIFY: CLEAN not found in summary.md — skipping"
    exit 0
fi

log_info "POST-TASK" "AUTOVERIFY: CLEAN found — running secondary validation"

# --- Secondary validation (mirrors check-tester.sh lines 194-232) ---
AV_FAIL=false
NOT_TESTED_LINES=""
WHITELISTED_COUNT=0

# Must have High confidence (markdown bold or plain-text formats)
if ! echo "$SUMMARY_TEXT" | grep -qiE '(\*\*High\*\*|[Cc]onfidence:?\s*High|High confidence)'; then
    log_info "POST-TASK" "secondary validation FAIL: missing High confidence"
    AV_FAIL=true
fi

# Must NOT have "Partially verified"
if echo "$SUMMARY_TEXT" | grep -qi 'Partially verified'; then
    log_info "POST-TASK" "secondary validation FAIL: 'Partially verified' found"
    AV_FAIL=true
fi

# Must NOT have Medium or Low confidence (markdown bold or plain-text formats)
if echo "$SUMMARY_TEXT" | grep -qiE '(\*\*(Medium|Low)\*\*|[Cc]onfidence:?\s*(Medium|Low)|(Medium|Low) confidence)'; then
    log_info "POST-TASK" "secondary validation FAIL: Medium or Low confidence found"
    AV_FAIL=true
fi

# Must NOT have non-environmental "Not tested" entries
# Environmental patterns are whitelisted — they cannot be tested in a headless CLI context
ENV_PATTERN='requires browser\|requires viewport\|requires screen reader\|requires mobile\|requires physical device\|requires hardware\|requires manual interaction\|requires human interaction\|requires GUI\|requires native app\|requires network'
NOT_TESTED_LINES=$(echo "$SUMMARY_TEXT" | grep -i 'Not tested' || true)
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
    echo "$SUMMARY_TEXT" | grep -qiE '(\*\*High\*\*|[Cc]onfidence:?\s*High|High confidence)' \
        || _AV_REASONS="${_AV_REASONS}missing High confidence; "
    echo "$SUMMARY_TEXT" | grep -qi 'Partially verified' \
        && _AV_REASONS="${_AV_REASONS}has Partially verified; "
    echo "$SUMMARY_TEXT" | grep -qiE '(\*\*(Medium|Low)\*\*|[Cc]onfidence:?\s*(Medium|Low)|(Medium|Low) confidence)' \
        && _AV_REASONS="${_AV_REASONS}has Medium/Low confidence; "
    [[ -n "${NON_ENV_LINES:-}" ]] && _AV_REASONS="${_AV_REASONS}non-environmental Not tested; "
    ESCAPED=$(printf 'Auto-verify blocked: %s Manual approval required.' \
        "${_AV_REASONS:-unknown reason}" | jq -Rs .)
    cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF
    exit 0
fi

# All checks passed — write verified to all three paths
write_proof_status "verified" "$PROJECT_ROOT"

# Audit trail
if [[ "${WHITELISTED_COUNT:-0}" -gt 0 ]]; then
    append_audit "$PROJECT_ROOT" "auto_verify" "post-task: AUTOVERIFY: CLEAN — secondary validation passed, proof auto-verified (${WHITELISTED_COUNT} environmental 'Not tested' item(s) whitelisted)"
else
    append_audit "$PROJECT_ROOT" "auto_verify" "post-task: AUTOVERIFY: CLEAN — secondary validation passed, proof auto-verified"
fi

log_info "POST-TASK" "AUTO-VERIFIED — proof written to $PROOF_FILE"

# Emit directive
CONTEXT="post-task: tester Task completed — proof auto-verified (AUTOVERIFY: CLEAN, secondary validation passed)."
DIRECTIVE="AUTO-VERIFIED: Tester e2e verification passed — High confidence, full coverage, no caveats. .proof-status is verified. Dispatch Guardian NOW with 'AUTO-VERIFY-APPROVED' in the prompt. Guardian will skip its approval prompt and execute the full merge cycle directly. Present the tester's verification report to the user in parallel."
ESCAPED=$(printf '%s\n\n%s' "$CONTEXT" "$DIRECTIVE" | jq -Rs .)
cat <<EOF
{
  "additionalContext": $ESCAPED
}
EOF
exit 0
