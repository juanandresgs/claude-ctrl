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

# Source context-lib.sh so is_source_file, is_skippable_path, and
# SOURCE_EXTENSIONS are available to check_enforcement_gap when it runs
# in a $() subshell from pre-write.sh's CHECKS loop.
# shellcheck source=../context-lib.sh
source "${_HOOKS_DIR}/context-lib.sh"

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

# check_enforcement_gap <input>
# Denies writes to source files whose extension has an unresolved enforcement
# gap with encounter_count > 1. Reads .claude/.enforcement-gaps directly —
# no subprocess to lint.sh. Fires AFTER branch-guard and write-guard so WHO
# checks run first, but BEFORE plan checks (enforcement health > plan staleness).
#
# @decision DEC-LINT-002
# @title PreToolUse enforcement-gap deny gate
# @status accepted
# @rationale On the first gap encounter lint.sh emits additionalContext and
#   exits 2 (feedback to model). A single encounter might be a transient
#   environment issue. On count > 1 the gap is confirmed persistent — the
#   model has been told and did not fix it. At that point writes are denied
#   outright so enforcement is not silently bypassed across multiple turns.
check_enforcement_gap() {
    local input="$1"
    local file_path ext project_root gaps_file

    file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    [[ -z "$file_path" ]] && return 0

    # Only check source files
    is_source_file "$file_path" || return 0
    is_skippable_path "$file_path" && return 0

    ext="${file_path##*.}"
    [[ -z "$ext" || "$ext" == "$file_path" ]] && return 0

    # Resolve project root: prefer CLAUDE_PROJECT_DIR (set by log.sh auto-export),
    # then walk up from the file's parent to find the first existing directory,
    # then run git from there. The target file may not exist yet (Write creates
    # it), so dirname may not be an existing directory.
    if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -d "${CLAUDE_PROJECT_DIR}" ]]; then
        project_root="$CLAUDE_PROJECT_DIR"
    else
        local _dir
        _dir="$(dirname "$file_path")"
        while [[ -n "$_dir" && "$_dir" != "/" && ! -d "$_dir" ]]; do
            _dir="$(dirname "$_dir")"
        done
        project_root=$(git -C "${_dir:-/}" rev-parse --show-toplevel 2>/dev/null || echo "")
    fi
    [[ -z "$project_root" ]] && return 0

    gaps_file="$project_root/.claude/.enforcement-gaps"
    [[ ! -f "$gaps_file" ]] && return 0

    # Check both gap types for this extension
    local gap_line count gap_type tool reason
    for gap_type in unsupported missing_dep; do
        gap_line=$(grep "^${gap_type}|${ext}|" "$gaps_file" 2>/dev/null || true)
        [[ -z "$gap_line" ]] && continue
        count=$(printf '%s' "$gap_line" | cut -d'|' -f5)
        [[ "${count:-0}" -le 1 ]] && continue
        tool=$(printf '%s' "$gap_line" | cut -d'|' -f3)
        if [[ "$gap_type" == "unsupported" ]]; then
            reason="Write denied: unresolved enforcement gap for .${ext} files (no linter profile). This gap has been encountered ${count} times. Add a linter config for .${ext} files to unblock writes."
        else
            reason="Write denied: unresolved enforcement gap for .${ext} files (linter '${tool}' not installed). This gap has been encountered ${count} times. Install '${tool}' to unblock writes."
        fi
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' \
            "$(printf '%s' "$reason" | sed 's/"/\\"/g')"
        return 0
    done
}

# Export hook wrappers so they are available in the $() subshells that
# pre-write.sh spawns when iterating CHECKS=(... check_plan_immutability_hook ...).
export -f check_branch_guard check_write_who check_plan_guard check_plan_exists \
          check_plan_immutability_hook check_decision_log_hook check_enforcement_gap \
          _run_hook _is_deny
