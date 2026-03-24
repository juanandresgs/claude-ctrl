#!/usr/bin/env bash
# Plan discipline policy checks for the pre-write hook chain.
#
# Provides two functions called by write-policy.sh when MASTER_PLAN.md is written:
#   check_plan_immutability  <file_path> <project_root>
#   check_decision_log_append_only  <file_path> <project_root>
#
# Each function is silent (returns 0) on pass.
# On violation it prints a deny JSON line: "deny|<reason>" — callers translate
# this into the full hookSpecificOutput envelope.
#
# @decision DEC-PLAN-002
# @title plan-policy.sh as thin shell bridge to planctl.py
# @status accepted
# @rationale Shell hooks cannot be unit-tested with pytest. All enforcement
#   logic lives in planctl.py (Python, fully tested). This file is a minimal
#   bridge: call planctl.py, parse its JSON output with jq, emit deny if
#   violated. CLAUDE_PLAN_MIGRATION=1 bypasses both checks — same escape hatch
#   used by plan-guard.sh for WHO checks, keeping the override surface consistent.

# check_plan_immutability <file_path> <project_root>
# Returns nothing (allow) or prints "deny|<reason>" (block).
#
# planctl.py is resolved from project_root/scripts/planctl.py so this function
# works correctly regardless of where plan-policy.sh was sourced from (e.g. from
# the global ~/.claude/hooks/lib/ when write-policy.sh is sourced there).
check_plan_immutability() {
    local file_path="$1" project_root="$2"
    local planctl="$project_root/scripts/planctl.py"

    # Only relevant for MASTER_PLAN.md writes
    [[ "$(basename "$file_path")" != "MASTER_PLAN.md" ]] && return 0

    # CLAUDE_PLAN_MIGRATION=1 bypasses immutability (intentional section edits)
    [[ "${CLAUDE_PLAN_MIGRATION:-}" == "1" ]] && return 0

    # Skip if planctl.py not found in this project (project may not use planctl)
    [[ ! -f "$planctl" ]] && return 0

    # Skip if no baseline exists yet (first write, or baseline not created)
    [[ ! -f "$project_root/.plan-baseline.json" ]] && return 0

    # planctl.py needs the file to exist on disk; for pre-write hooks the file
    # may not exist yet (first write). Skip if missing.
    [[ ! -f "$file_path" ]] && return 0

    # Capture output regardless of exit code: planctl exits 1 on violations
    # (not on errors). || true prevents set -e from aborting; we inspect JSON.
    local result
    result=$(python3 "$planctl" check-immutability "$file_path" 2>/dev/null) || true

    # If output is empty, planctl failed unexpectedly — allow through
    [[ -z "$result" ]] && return 0

    # Use 'if .immutable then "true" else "false" end' — jq's // operator
    # treats false as falsy and replaces it with the alternative, so
    # '.immutable // true' returns true even when .immutable is false.
    local immutable
    immutable=$(printf '%s' "$result" | jq -r 'if .immutable then "true" else "false" end' 2>/dev/null)
    if [[ "$immutable" == "false" ]]; then
        local reason
        reason=$(printf '%s' "$result" | jq -r '.violations[0].reason // "permanent section modified"' 2>/dev/null)
        printf 'deny|Plan immutability violation: %s' "$reason"
    fi
}

# check_decision_log_append_only <file_path> <project_root>
# Returns nothing (allow) or prints "deny|<reason>" (block).
check_decision_log_append_only() {
    local file_path="$1" project_root="$2"
    local planctl="$project_root/scripts/planctl.py"

    [[ "$(basename "$file_path")" != "MASTER_PLAN.md" ]] && return 0
    [[ "${CLAUDE_PLAN_MIGRATION:-}" == "1" ]] && return 0
    [[ ! -f "$planctl" ]] && return 0
    [[ ! -f "$project_root/.plan-baseline.json" ]] && return 0
    [[ ! -f "$file_path" ]] && return 0

    # Capture output regardless of exit code: planctl exits 1 on violations.
    local result
    result=$(python3 "$planctl" check-decision-log "$file_path" 2>/dev/null) || true

    [[ -z "$result" ]] && return 0

    local append_only
    append_only=$(printf '%s' "$result" | jq -r 'if .append_only then "true" else "false" end' 2>/dev/null)
    if [[ "$append_only" == "false" ]]; then
        local reason
        reason=$(printf '%s' "$result" | jq -r '.violations[0].reason // "entries modified or reordered"' 2>/dev/null)
        printf 'deny|Decision log violation: %s' "$reason"
    fi
}

# Export so functions are available in subshells spawned by $() in pre-write.sh.
# pre-write.sh calls each check via output=$("$check_fn" ...) which forks a
# subshell; without export -f the functions are not inherited.
export -f check_plan_immutability check_decision_log_append_only
