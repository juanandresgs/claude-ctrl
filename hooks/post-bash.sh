#!/usr/bin/env bash
set -euo pipefail

# Post-bash source-mutation readiness invalidation (Invariant #15).
# PostToolUse hook — matcher: Bash
#
# Closes the Bash shell-mutation bypass in evaluation_state readiness
# invalidation: any Bash command that modifies a source file after
# evaluator clearance must reset the evaluation_state from
# ready_for_guardian → pending, just as track.sh does for Write|Edit.
#
# track.sh handles Write|Edit by reading tool_input.file_path (known
# at pre-tool time). Bash commands do not expose a file_path; they may
# produce source mutations through arbitrary shell operations. This hook
# runs post-execution and detects mutations by comparing the session's
# tracked-file set: if git reports any modified/untracked source files
# under the project root that are in scope, the clearance is stale.
#
# @decision DEC-EVAL-006
# @title post-bash.sh closes the Bash bypass for evaluation_state readiness
# @status accepted
# @rationale DEC-EVAL-001 (evaluation.py invalidate_if_ready) and
#   DEC-EVAL-005 (track.sh is the sole Write|Edit invalidator) only
#   cover Write|Edit tool mutations. A Bash command like
#   `sed -i ...` or `python3 gen.py > src.py` bypasses track.sh entirely.
#   post-bash.sh is the PostToolUse Bash counterpart: it detects any
#   source-file change visible to git after the command executes and
#   calls rt_eval_invalidate so the evaluation clearance is revoked.
#   Design deliberately mirrors track.sh (DEC-EVAL-005) and uses
#   lease-first identity (DEC-WS1-TRACK-001) for the same reasons.
#   Does NOT re-implement bash_workflow_scope semantics — the pre-tool
#   gate has already denied out-of-scope Bash mutations; this hook only
#   sees in-scope execution results.
#   Does NOT parse Bash command semantics — that is command_intent's job.
#   (DEC-CLAUDEX-HOOK-MANIFEST-001: hook_manifest is the sole authority
#   for the repo-local hook adapter surface.)

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

read_input > /dev/null

# Detect project root (prefers CLAUDE_PROJECT_DIR)
PROJECT_ROOT=$(detect_project_root)

# Per-command fingerprint comparison (DEC-EVAL-006):
# pre-bash.sh captures a content-aware fingerprint of source mutations before
# the command runs. We compare against the post-command fingerprint to detect
# whether THIS command introduced new source changes. Pre-existing staged
# changes that are unchanged across the command do NOT trigger invalidation.
# Use the same baseline-key resolution as pre-bash.sh so pre/post hooks for
# the same Bash tool call always read/write the same baseline file.
_BASELINE_KEY=$(get_field '.tool_use_id')
[[ -z "$_BASELINE_KEY" ]] && _BASELINE_KEY=$(get_field '.session_id')
[[ -z "$_BASELINE_KEY" ]] && _BASELINE_KEY=$(canonical_session_id)
_BASELINE_KEY=$(sanitize_token "$_BASELINE_KEY")
_BASELINE_FILE="$PROJECT_ROOT/tmp/.bash-source-baseline-${_BASELINE_KEY}"
_BASELINE=""
if [[ -f "$_BASELINE_FILE" ]]; then
    _BASELINE=$(cat "$_BASELINE_FILE" 2>/dev/null || echo "")
fi

_POST_FP=$(compute_source_fingerprint "$PROJECT_ROOT" 2>/dev/null || echo "ERROR")

_FOUND_SOURCE_MUTATION=false
if [[ -z "$_BASELINE" ]]; then
    # Legacy fallback: no baseline captured, use path-presence detection.
    # This preserves safety for commands that ran before the fingerprint
    # mechanism was deployed or when pre-bash.sh fails to capture.
    _CHANGED_FILES=$(
        {
            git -C "$PROJECT_ROOT" diff --name-only HEAD 2>/dev/null || true
            git -C "$PROJECT_ROOT" ls-files --others --exclude-standard "$PROJECT_ROOT" 2>/dev/null || true
        } | sort -u
    )
    while IFS= read -r _F; do
        [[ -z "$_F" ]] && continue
        if is_source_file "$_F" && ! is_skippable_path "$_F" && ! is_scratchlane_path "$_F"; then
            _FOUND_SOURCE_MUTATION=true
            break
        fi
    done <<< "$_CHANGED_FILES"
elif [[ "$_BASELINE" != "$_POST_FP" ]]; then
    _FOUND_SOURCE_MUTATION=true
fi

if [[ "$_FOUND_SOURCE_MUTATION" == "true" ]]; then
    # Lease-first identity — mirror track.sh:74-79
    _PB_LEASE_CTX=$(lease_context "$PROJECT_ROOT")
    _PB_LEASE_FOUND=$(printf '%s' "$_PB_LEASE_CTX" | jq -r '.found' 2>/dev/null || echo "false")
    if [[ "$_PB_LEASE_FOUND" == "true" ]]; then
        _WF_ID=$(printf '%s' "$_PB_LEASE_CTX" | jq -r '.workflow_id // empty' 2>/dev/null || true)
    fi
    [[ -z "${_WF_ID:-}" ]] && _WF_ID=$(current_workflow_id "$PROJECT_ROOT")
    _INVALIDATED=$(rt_eval_invalidate "$_WF_ID" 2>/dev/null || echo "false")
    if [[ "$_INVALIDATED" == "true" ]]; then
        append_audit "$PROJECT_ROOT" "eval_reset" "post-bash:source-mutation"
    fi
fi

exit 0
