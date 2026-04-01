#!/usr/bin/env bash
# runtime-bridge.sh — shell adapter between hook scripts and the typed runtime.
#
# @decision DEC-BRIDGE-001
# @title Shell wrappers isolate hook scripts from cc_policy JSON parsing
# @status accepted
# @rationale Hook scripts (context-lib.sh, subagent-start.sh) need scalar
#   string values (a role name, a status word) not raw JSON blobs. Parsing
#   JSON with jq inline at every call site creates duplication and makes
#   fallback logic harder to read. These wrappers centralise parsing and
#   return plain strings so callers stay declarative. All wrappers suppress
#   errors and return empty string on failure; callers then apply flat-file
#   fallback. This makes every integration point resilient to runtime
#   unavailability without duplicating error handling.
#
# Sourced by context-lib.sh (and transitively by every hook that sources it).
# Never call this file directly.

# ---------------------------------------------------------------------------
# Core entry point
# ---------------------------------------------------------------------------

cc_policy() {
    local runtime_root="${CLAUDE_RUNTIME_ROOT:-$HOME/.claude/runtime}"
    # Scope db to project root when CLAUDE_PROJECT_DIR is set
    if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -z "${CLAUDE_POLICY_DB:-}" ]]; then
        export CLAUDE_POLICY_DB="$CLAUDE_PROJECT_DIR/.claude/state.db"
    fi
    python3 "$runtime_root/cli.py" "$@"
}

# ---------------------------------------------------------------------------
# Schema bootstrap (lazy, idempotent)
# ---------------------------------------------------------------------------

# _rt_ensure_schema: create DB tables if the DB file does not yet exist.
# Called at the top of every wrapper so the first hook invocation in a new
# environment auto-provisions the schema without requiring a manual init step.
_rt_ensure_schema() {
    local db_path="${CLAUDE_POLICY_DB:-$HOME/.claude/state.db}"
    if [[ ! -f "$db_path" ]]; then
        cc_policy schema ensure >/dev/null 2>&1 || true
    fi
}

# ---------------------------------------------------------------------------
# Proof-of-work wrappers
# ---------------------------------------------------------------------------

# rt_proof_get <workflow_id>
# Prints the proof status string ("idle", "pending", "verified") or nothing
# on failure. Callers fall back to flat-file when this returns empty.
rt_proof_get() {
    _rt_ensure_schema
    local result
    result=$(cc_policy proof get "$1" 2>/dev/null) || return 1
    printf '%s\n' "$result" | jq -r '.status // "idle"'
}

# rt_proof_set <workflow_id> <status>
# Upserts proof status in SQLite. Suppresses output; callers dual-write to
# flat file for backward compatibility.
rt_proof_set() {
    _rt_ensure_schema
    cc_policy proof set "$1" "$2" >/dev/null 2>&1
}

# rt_proof_timestamp <workflow_id>
# Prints the ISO-8601 updated_at string, or "0" when not found.
rt_proof_timestamp() {
    _rt_ensure_schema
    local result
    result=$(cc_policy proof get "$1" 2>/dev/null) || return 1
    printf '%s\n' "$result" | jq -r '.updated_at // "0"'
}

# ---------------------------------------------------------------------------
# Evaluation-state wrappers (TKT-024: sole readiness authority)
# ---------------------------------------------------------------------------

# rt_eval_get <workflow_id>
# Prints the evaluation status string ("idle", "pending", "needs_changes",
# "ready_for_guardian", "blocked_by_plan") or "idle" on failure.
rt_eval_get() {
    _rt_ensure_schema
    local result
    result=$(cc_policy evaluation get "$1" 2>/dev/null) || return 1
    printf '%s\n' "$result" | jq -r '.status // "idle"'
}

# rt_eval_set <workflow_id> <status> [head_sha] [blockers] [major] [minor]
# Upserts evaluation state in SQLite. Suppresses output; callers check exit code.
rt_eval_set() {
    _rt_ensure_schema
    local wf_id="$1" status="$2"
    local head_sha="${3:-}" blockers="${4:-0}" major="${5:-0}" minor="${6:-0}"
    local args=("evaluation" "set" "$wf_id" "$status")
    [[ -n "$head_sha" ]] && args+=("--head-sha" "$head_sha")
    [[ "${blockers:-0}" -gt 0 ]] && args+=("--blockers" "$blockers")
    [[ "${major:-0}" -gt 0 ]]   && args+=("--major"    "$major")
    [[ "${minor:-0}" -gt 0 ]]   && args+=("--minor"    "$minor")
    cc_policy "${args[@]}" >/dev/null 2>&1
}

# rt_eval_list
# Prints raw JSON list of all evaluation_state rows, or nothing on failure.
rt_eval_list() {
    _rt_ensure_schema
    cc_policy evaluation list 2>/dev/null
}

# rt_eval_invalidate <workflow_id>
# Resets status from ready_for_guardian → pending if currently ready.
# Prints "true" when invalidated, "false" when no-op.
rt_eval_invalidate() {
    _rt_ensure_schema
    local result
    result=$(cc_policy evaluation invalidate "$1" 2>/dev/null) || return 1
    printf '%s\n' "$result" | jq -r '.invalidated // false'
}

# ---------------------------------------------------------------------------
# Agent marker wrappers
# ---------------------------------------------------------------------------

# rt_marker_get_active_role
# Prints the role string of the currently active marker, or nothing when
# no active marker exists.
rt_marker_get_active_role() {
    _rt_ensure_schema
    local result
    result=$(cc_policy marker get-active 2>/dev/null) || return 1
    printf '%s\n' "$result" | jq -r 'if .found then .role else empty end'
}

# rt_marker_set <agent_id> <role>
rt_marker_set() {
    _rt_ensure_schema
    cc_policy marker set "$1" "$2" >/dev/null 2>&1
}

# rt_marker_deactivate <agent_id>
rt_marker_deactivate() {
    _rt_ensure_schema
    cc_policy marker deactivate "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Event wrapper
# ---------------------------------------------------------------------------

# rt_event_emit <type> [detail]
rt_event_emit() {
    _rt_ensure_schema
    cc_policy event emit "$1" --detail "${2:-}" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Statusline snapshot wrapper
# ---------------------------------------------------------------------------

# rt_statusline_snapshot
# Prints the full JSON snapshot dict to stdout, or nothing on failure.
# scripts/statusline.sh calls this instead of reading flat-file cache so
# all HUD state flows through the canonical runtime projection.
#
# Returns raw JSON (not a scalar) so the caller can jq-parse any field it needs:
#   proof_status, proof_workflow, active_agent, active_agent_id,
#   worktree_count, worktrees[], dispatch_status, dispatch_initiative,
#   dispatch_cycle_id, recent_event_count, recent_events[], snapshot_at
rt_statusline_snapshot() {
    _rt_ensure_schema
    cc_policy statusline snapshot 2>/dev/null
}

# ---------------------------------------------------------------------------
# Workflow binding wrappers
# ---------------------------------------------------------------------------

# rt_workflow_bind <workflow_id> <worktree_path> <branch> [ticket] [initiative]
# Registers the workflow→worktree→branch binding in SQLite.
# Silent on success; suppresses errors so hook callers are not disrupted.
rt_workflow_bind() {
    _rt_ensure_schema
    local wf_id="$1" wt_path="$2" branch="$3"
    local ticket="${4:-}" initiative="${5:-}"
    local args=("workflow" "bind" "$wf_id" "$wt_path" "$branch")
    [[ -n "$ticket" ]] && args+=("--ticket" "$ticket")
    [[ -n "$initiative" ]] && args+=("--initiative" "$initiative")
    cc_policy "${args[@]}" >/dev/null 2>&1
}

# rt_workflow_get <workflow_id>
# Prints the worktree_path string for the workflow, or empty string on failure.
# Used by get_workflow_binding() in context-lib.sh and guard.sh Check 12.
rt_workflow_get() {
    _rt_ensure_schema
    local result
    result=$(cc_policy workflow get "$1" 2>/dev/null) || return 0
    printf '%s\n' "$result" | jq -r 'if .found then .worktree_path else empty end' 2>/dev/null || true
}

# rt_workflow_scope_check <workflow_id> <changed_files_json>
# Returns the compliance JSON dict from cc-policy, or empty string on failure.
# Example: rt_workflow_scope_check "feature-foo" '["runtime/cli.py"]'
rt_workflow_scope_check() {
    _rt_ensure_schema
    local result
    result=$(cc_policy workflow scope-check "$1" --changed "$2" 2>/dev/null) || return 0
    printf '%s\n' "$result"
}
