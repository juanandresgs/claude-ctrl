#!/usr/bin/env bash
# dispatch-helpers.sh — Convenience wrappers for dispatch queue operations.
#
# @decision DEC-DISPATCH-001
# @title Shell wrappers for dispatch queue operations
# @status accepted
# @rationale post-task.sh and any other hook that needs to inspect or
#   mutate the dispatch queue should not embed cc_policy JSON parsing
#   inline. These wrappers follow the same pattern as runtime-bridge.sh:
#   call cc_policy, parse the JSON scalar the caller needs, return a plain
#   string. Error handling is uniform: suppress stderr, return empty string
#   or a sentinel like "queue empty" on failure so callers stay declarative.
#   This file is sourced, never executed directly.
#
# Sources: hooks/lib/runtime-bridge.sh (provides cc_policy, _rt_ensure_schema)

# Resolve the directory of this file regardless of how it was sourced so
# we can locate runtime-bridge.sh relative to our own location.
_DISPATCH_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DISPATCH_HELPERS_DIR/runtime-bridge.sh"

# ---------------------------------------------------------------------------
# dispatch_status
# Prints a human-readable one-liner describing the current queue head:
#   "next: <role>"   — a pending item exists
#   "queue empty"    — no pending items
# ---------------------------------------------------------------------------
dispatch_status() {
    _rt_ensure_schema
    local next found role
    next=$(cc_policy dispatch next 2>/dev/null) || { echo "queue empty"; return; }
    found=$(echo "$next" | jq -r '.found // false' 2>/dev/null)
    if [[ "$found" == "true" ]]; then
        role=$(echo "$next" | jq -r '.role // "unknown"' 2>/dev/null)
        echo "next: $role"
    else
        echo "queue empty"
    fi
}

# ---------------------------------------------------------------------------
# dispatch_cycle_start <initiative>
# Creates a new active dispatch cycle for the named initiative.
# Silently suppresses output; callers check exit code.
# ---------------------------------------------------------------------------
dispatch_cycle_start() {
    local initiative="$1"
    _rt_ensure_schema
    cc_policy dispatch cycle-start "$initiative" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# dispatch_cycle_current
# Prints the raw JSON for the current active cycle, or empty string when
# no active cycle exists.
# ---------------------------------------------------------------------------
dispatch_cycle_current() {
    _rt_ensure_schema
    local result found
    result=$(cc_policy dispatch cycle-current 2>/dev/null) || return 1
    found=$(echo "$result" | jq -r '.found // false' 2>/dev/null)
    if [[ "$found" == "true" ]]; then
        echo "$result"
    fi
}
