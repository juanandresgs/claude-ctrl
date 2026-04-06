#!/usr/bin/env bash
set -euo pipefail

# Project-aware file change tracking.
# PostToolUse hook — matcher: Write|Edit
#
# Tracks file changes per-session in the PROJECT's .claude directory.
# Uses CLAUDE_PROJECT_DIR when available, falls back to git root detection.
# Session-scoped to avoid collisions with concurrent sessions.

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

read_input > /dev/null
FILE_PATH=$(get_field '.tool_input.file_path')

# Exit silently if no file path
[[ -z "$FILE_PATH" ]] && exit 0

# Exit silently if parent directory doesn't exist
[[ ! -e "$(dirname "$FILE_PATH")" ]] && exit 0

# Detect project root (prefers CLAUDE_PROJECT_DIR)
PROJECT_ROOT=$(detect_project_root)

# Session-scoped tracking file (tracks file changes, not decisions)
SESSION_ID=$(canonical_session_id)
TRACKING_DIR="$PROJECT_ROOT/.claude"
TRACKING_FILE="$TRACKING_DIR/.session-changes-${SESSION_ID}"

# Create tracking directory if needed
mkdir -p "$TRACKING_DIR"

# Atomic append: write to temp then append (safer than direct >>)
TMPFILE=$(mktemp "${TRACKING_DIR}/.track.XXXXXX")
echo "$FILE_PATH" > "$TMPFILE"
cat "$TMPFILE" >> "$TRACKING_FILE"
rm -f "$TMPFILE"

# Observatory: emit files_changed count async so track.sh adds zero latency (W-OBS-2).
# Hot-path hook — use fire-and-forget (& disown). Value is the running total of
# unique files tracked in this session (line count of the session tracking file).
_tk_file_count=$(wc -l < "$TRACKING_FILE" 2>/dev/null | tr -d ' ') || _tk_file_count=1
rt_obs_metric files_changed "$_tk_file_count" "" "" "" & disown

# --- Invalidate evaluation_state when source files change after clearance ---
# If evaluation_state is ready_for_guardian and source code changes, the
# evaluator clearance is stale. Reset to pending so a new tester pass is
# required before Guardian can proceed. (TKT-024: proof invalidation removed)
#
# @decision DEC-EVAL-005
# @title track.sh is the sole invalidator of evaluation_state
# @status accepted
# @rationale Source writes after evaluator clearance invalidate readiness.
#   This enforces that the evaluated HEAD and the committed HEAD are the same.
#   invalidate_if_ready() is a targeted atomic update — it only fires when
#   status is exactly ready_for_guardian, so pending/idle writes are no-ops.
if is_source_file "$FILE_PATH" && ! is_skippable_path "$FILE_PATH"; then
    # WS1: use lease_context() to derive workflow_id from the active lease.
    # When a lease is active its workflow_id is authoritative over branch-derived id.
    # This ensures invalidation targets the same workflow_id the tester cleared,
    # not the branch-derived id which may differ when a lease is active.
    #
    # @decision DEC-WS1-TRACK-001
    # @title track.sh uses lease-first identity for eval invalidation
    # @status accepted
    # @rationale Without this fix, a source write fires rt_eval_invalidate against
    #   the branch-derived workflow_id (e.g. "feature-my-branch") while the tester
    #   clearance lives under the lease workflow_id (e.g. "wf-abc123"). The
    #   invalidation is a no-op against the wrong id, so the stale ready_for_guardian
    #   state persists and Guardian can merge un-evaluated code. Lease-first identity
    #   (matching the pattern in check-guardian.sh and check-tester.sh) closes this.
    _TK_LEASE_CTX=$(lease_context "$PROJECT_ROOT")
    _TK_LEASE_FOUND=$(printf '%s' "$_TK_LEASE_CTX" | jq -r '.found' 2>/dev/null || echo "false")
    if [[ "$_TK_LEASE_FOUND" == "true" ]]; then
        _WF_ID=$(printf '%s' "$_TK_LEASE_CTX" | jq -r '.workflow_id // empty' 2>/dev/null || true)
    fi
    [[ -z "${_WF_ID:-}" ]] && _WF_ID=$(current_workflow_id "$PROJECT_ROOT")
    _INVALIDATED=$(rt_eval_invalidate "$_WF_ID" 2>/dev/null || echo "false")
    if [[ "$_INVALIDATED" == "true" ]]; then
        append_audit "$PROJECT_ROOT" "eval_reset" "$FILE_PATH"
    fi
fi

exit 0
