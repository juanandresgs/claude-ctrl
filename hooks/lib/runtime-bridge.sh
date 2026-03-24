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
