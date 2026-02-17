#!/usr/bin/env bash
# Structured JSON logging helper for Claude Code hooks.
# Source this file from other hooks: source "$(dirname "$0")/log.sh"
#
# Provides:
#   log_json <stage> <message>  - Print structured JSON to stderr
#   log_info <stage> <message>  - Print human-readable info to stderr
#   read_input                  - Read and cache stdin JSON (sets HOOK_INPUT)
#   get_field <jq_path>         - Extract field from cached input
#   detect_project_root         - Find git root or fall back to CLAUDE_PROJECT_DIR
#   get_claude_dir              - Get .claude directory path (handles ~/.claude special case)
#   resolve_proof_file          - Resolve the active .proof-status path (worktree-aware)
#
# All output goes to stderr so it doesn't interfere with hook JSON output.
#
# @decision DEC-LOG-001
# @title Shared logging and path utilities for all hooks
# @status accepted
# @rationale Centralized helper functions prevent duplication and ensure consistent
#   behavior across all hooks. get_claude_dir() fixes #77 double-nesting bug.
#   detect_project_root() includes #34 deleted CWD recovery.
#   resolve_proof_file() fixes the worktree proof-status mismatch (#proof-path).
#
# @decision DEC-PROOF-PATH-002
# @title resolve_proof_file: breadcrumb-based worktree proof-status resolution
# @status accepted
# @rationale When orchestrator runs from ~/.claude and dispatches agents to a git
#   worktree, .proof-status files end up in two locations: the orchestrator's
#   CLAUDE_DIR and the worktree's .claude/. The breadcrumb file
#   .active-worktree-path (written by task-track.sh at implementer dispatch)
#   lets hooks find the active path without scanning all worktrees. Resolution
#   logic: if breadcrumb exists AND worktree .proof-status is in pending or
#   verified state → return worktree path; otherwise return CLAUDE_DIR path.
#   Stale breadcrumbs (deleted worktree) fall back to CLAUDE_DIR safely.

# Cache stdin so multiple functions can read it
HOOK_INPUT=""

read_input() {
    if [[ -z "$HOOK_INPUT" ]]; then
        HOOK_INPUT=$(cat)
    fi
    echo "$HOOK_INPUT"
}

get_field() {
    local path="$1"
    echo "$HOOK_INPUT" | jq -r "$path // empty" 2>/dev/null
}

log_json() {
    local stage="$1"
    local message="$2"
    echo "{\"stage\":\"$stage\",\"message\":\"$message\"}" >&2
}

log_info() {
    local stage="$1"
    local message="$2"
    echo "[$stage] $message" >&2
}

detect_project_root() {
    # Check if CWD still exists — recover if deleted (Fix #34)
    if [[ ! -d "$PWD" ]]; then
        cd "${HOME}" 2>/dev/null || cd / 2>/dev/null
        echo "WARNING: CWD was deleted, recovered to $(pwd)" >&2
    fi

    # Prefer CLAUDE_PROJECT_DIR if set and valid
    if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -d "${CLAUDE_PROJECT_DIR}" ]]; then
        echo "$CLAUDE_PROJECT_DIR"
        return
    fi
    # Check if CWD is valid before using git
    if [[ -d "$PWD" ]]; then
        local root
        root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
        if [[ -n "$root" && -d "$root" ]]; then
            echo "$root"
            return
        fi
    fi
    # Last resort: fall back to HOME
    echo "${HOME:-/}"
}

# @decision DEC-QUICKFIX-001
# @title Fix double-nested paths when PROJECT_ROOT is ~/.claude
# @status accepted
# @rationale When PROJECT_ROOT is ~/.claude, using ${PROJECT_ROOT}/.claude/ produces
#   ~/.claude/.claude/ which breaks state file paths. This helper returns the correct
#   .claude directory: PROJECT_ROOT/.claude for normal projects, PROJECT_ROOT for ~/.claude.
#   Fixes #77.
get_claude_dir() {
    local project_root="${PROJECT_ROOT:-$(detect_project_root)}"
    local home_claude="${HOME}/.claude"

    # If PROJECT_ROOT is already ~/.claude, return it as-is (don't double-nest)
    if [[ "$project_root" == "$home_claude" ]]; then
        echo "$project_root"
    else
        echo "${project_root}/.claude"
    fi
}

# resolve_proof_file — return the active .proof-status path for the current context.
#
# In non-worktree scenarios (no breadcrumb): returns CLAUDE_DIR/.proof-status.
# In worktree scenarios: reads .active-worktree-path breadcrumb written by
# task-track.sh at implementer dispatch. If the breadcrumb exists and the
# worktree has a .proof-status in "pending" or "verified" state, returns the
# worktree path. Stale breadcrumbs (deleted worktree) fall back to CLAUDE_DIR.
#
# Callers that write "verified" should also dual-write to the orchestrator's
# copy so guard.sh can find it regardless of which path it checks.
resolve_proof_file() {
    local claude_dir="${CLAUDE_DIR:-$(get_claude_dir)}"
    local breadcrumb="$claude_dir/.active-worktree-path"
    local default_proof="$claude_dir/.proof-status"

    # No breadcrumb — standard (non-worktree) path
    if [[ ! -f "$breadcrumb" ]]; then
        echo "$default_proof"
        return
    fi

    local worktree_path
    worktree_path=$(cat "$breadcrumb" 2>/dev/null | tr -d '[:space:]')

    # Stale breadcrumb: worktree directory no longer exists
    if [[ -z "$worktree_path" || ! -d "$worktree_path" ]]; then
        echo "$default_proof"
        return
    fi

    local worktree_proof="$worktree_path/.claude/.proof-status"

    # Check if worktree has an active proof-status (pending or verified only)
    if [[ -f "$worktree_proof" ]]; then
        local wt_status
        wt_status=$(cut -d'|' -f1 "$worktree_proof" 2>/dev/null || echo "")
        if [[ "$wt_status" == "pending" || "$wt_status" == "verified" ]]; then
            echo "$worktree_proof"
            return
        fi
    fi

    # Worktree has no active proof — use orchestrator's path
    echo "$default_proof"
}

# Export for subshells
export -f log_json log_info read_input get_field detect_project_root get_claude_dir resolve_proof_file
