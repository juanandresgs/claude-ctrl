#!/usr/bin/env bash
# Write-side policy checks — delegates to existing hook scripts.
#
# @decision DEC-HOOK-001
# @title Thin policy delegation to existing hooks
# @status accepted
# @rationale Extracting and duplicating logic from 5 working hooks creates
#   divergence risk. Instead, delegate to the existing scripts via subprocess
#   and inspect their output. This makes pre-write.sh a consolidation layer
#   without reimplementation. Existing hooks remain the source of truth until
#   they are individually retired. TKT-008 establishes this pattern; flat-file
#   deletion happens once thin hooks prove end-to-end correctness.

_HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Run a hook script with the given JSON input on stdin.
# Captures stdout; stderr discarded. Exits true always — hooks exit 0 even on deny.
_run_hook() {
    local hook="$1" input="$2"
    printf '%s' "$input" | "$hook" 2>/dev/null || true
}

# Return true (0) if the hook output contains permissionDecision=deny.
_is_deny() {
    local output="$1"
    [[ -n "$output" ]] && echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1
}

# Run branch-guard check (main-branch source-file write protection).
check_branch_guard() {
    local input="$1"
    _run_hook "$_HOOKS_DIR/branch-guard.sh" "$input"
}

# Run write WHO check (only implementer role may write source files).
check_write_who() {
    local input="$1"
    _run_hook "$_HOOKS_DIR/write-guard.sh" "$input"
}

# Run plan governance check (only planner may write governance markdown).
check_plan_guard() {
    local input="$1"
    _run_hook "$_HOOKS_DIR/plan-guard.sh" "$input"
}

# Run plan existence check (MASTER_PLAN.md must exist for large source writes).
check_plan_exists() {
    local input="$1"
    _run_hook "$_HOOKS_DIR/plan-check.sh" "$input"
}
