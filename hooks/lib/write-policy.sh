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
#
# TKT-010 adds plan discipline checks (immutability + decision-log append-only)
# sourced from plan-policy.sh. These fire after check_plan_guard (WHO check)
# so that planner-authorized MASTER_PLAN.md writes are still subject to
# permanent-section and decision-log enforcement.

_HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source plan discipline policy functions (check_plan_immutability,
# check_decision_log_append_only). Safe to source here; functions are no-ops
# for non-MASTER_PLAN.md files.
# shellcheck source=plan-policy.sh
source "$(dirname "${BASH_SOURCE[0]}")/plan-policy.sh"

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

# Run plan immutability check (permanent sections may not be rewritten).
# Wraps check_plan_immutability from plan-policy.sh into the hook envelope format.
check_plan_immutability_hook() {
    local input="$1"
    local file_path project_root deny_line
    file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    [[ -z "$file_path" ]] && return 0
    project_root=$(git -C "$(dirname "$file_path")" rev-parse --show-toplevel 2>/dev/null || echo "")
    [[ -z "$project_root" ]] && return 0
    deny_line=$(check_plan_immutability "$file_path" "$project_root")
    if [[ -n "$deny_line" ]]; then
        local reason="${deny_line#deny|}"
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' \
            "$(printf '%s' "$reason" | sed 's/"/\\"/g')"
    fi
}

# Run decision log append-only check (entries may not be deleted or reordered).
# Wraps check_decision_log_append_only from plan-policy.sh into the hook envelope format.
check_decision_log_hook() {
    local input="$1"
    local file_path project_root deny_line
    file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    [[ -z "$file_path" ]] && return 0
    project_root=$(git -C "$(dirname "$file_path")" rev-parse --show-toplevel 2>/dev/null || echo "")
    [[ -z "$project_root" ]] && return 0
    deny_line=$(check_decision_log_append_only "$file_path" "$project_root")
    if [[ -n "$deny_line" ]]; then
        local reason="${deny_line#deny|}"
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' \
            "$(printf '%s' "$reason" | sed 's/"/\\"/g')"
    fi
}

# Export hook wrappers so they are available in the $() subshells that
# pre-write.sh spawns when iterating CHECKS=(... check_plan_immutability_hook ...).
export -f check_branch_guard check_write_who check_plan_guard check_plan_exists \
          check_plan_immutability_hook check_decision_log_hook \
          _run_hook _is_deny
