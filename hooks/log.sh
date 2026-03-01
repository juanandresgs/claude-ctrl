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
#   write_proof_status          - Atomic write to all 3 proof-status paths (worktree, project-scoped, legacy)
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
#   project_hash() and scoped state files fix cross-project contamination (#isolation).
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
#
# @decision DEC-ISOLATION-001
# @title Project-scoped state files via 8-char hash suffix
# @status accepted
# @rationale State files (.proof-status, .active-worktree-path, .active-*-* markers)
#   are global and contaminate subsequent sessions on different projects. Appending
#   an 8-char SHA-256 hash of project_root to each file name scopes it to one project.
#   Reads check scoped file first, fall back to unscoped for backward compatibility.
#   Writes always go to scoped files. Cleanup removes both scoped and unscoped.

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

# project_hash — compute deterministic 8-char hash of a project root path.
# Usage: project_hash "/path/to/project"
# Returns: 8-character hex string, consistent across calls for the same input.
project_hash() {
    echo "${1:?project_hash requires a path argument}" | shasum -a 256 | cut -c1-8
}

# resolve_proof_file — return the active .proof-status path for the current context.
#
# In non-worktree scenarios (no breadcrumb): returns CLAUDE_DIR/.proof-status-{phash}
# (falls back to .proof-status for backward compat with pre-migration state).
# In worktree scenarios: reads .active-worktree-path-{phash} breadcrumb first,
# then .active-worktree-path (old format). If the breadcrumb exists and the
# worktree has a .proof-status in "pending" or "verified" state, returns the
# worktree path. Stale breadcrumbs (deleted worktree) fall back to CLAUDE_DIR.
#
# Callers that write "verified" should also dual-write to the orchestrator's
# copy so guard.sh can find it regardless of which path it checks.
resolve_proof_file() {
    local claude_dir="${CLAUDE_DIR:-$(get_claude_dir)}"
    local project_root="${PROJECT_ROOT:-$(detect_project_root)}"
    local phash
    phash=$(project_hash "$project_root")
    local scoped_breadcrumb="$claude_dir/.active-worktree-path-${phash}"
    local legacy_breadcrumb="$claude_dir/.active-worktree-path"
    local scoped_proof="$claude_dir/.proof-status-${phash}"
    local default_proof="$claude_dir/.proof-status"

    # Determine which breadcrumb to use: scoped takes priority over legacy
    local breadcrumb=""
    if [[ -f "$scoped_breadcrumb" ]]; then
        breadcrumb="$scoped_breadcrumb"
    elif [[ -f "$legacy_breadcrumb" ]]; then
        breadcrumb="$legacy_breadcrumb"
    fi

    # No breadcrumb — standard (non-worktree) path
    if [[ -z "$breadcrumb" ]]; then
        # Return scoped proof if it has active state, else legacy, else default scoped
        if [[ -f "$scoped_proof" ]]; then
            echo "$scoped_proof"
        elif [[ -f "$default_proof" ]]; then
            echo "$default_proof"
        else
            echo "$scoped_proof"
        fi
        return
    fi

    local worktree_path
    worktree_path=$(cat "$breadcrumb" 2>/dev/null | tr -d '[:space:]')

    # Stale breadcrumb: worktree directory no longer exists
    if [[ -z "$worktree_path" || ! -d "$worktree_path" ]]; then
        if [[ -f "$scoped_proof" ]]; then
            echo "$scoped_proof"
        elif [[ -f "$default_proof" ]]; then
            echo "$default_proof"
        else
            echo "$scoped_proof"
        fi
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

    # Worktree has no active proof — use orchestrator's scoped path
    if [[ -f "$scoped_proof" ]]; then
        echo "$scoped_proof"
    elif [[ -f "$default_proof" ]]; then
        echo "$default_proof"
    else
        echo "$scoped_proof"
    fi
}

# write_proof_status — atomically write a proof status to all 3 proof-status paths.
#
# Usage: write_proof_status <status> [project_root]
#
# Writes "status|timestamp" to:
#   1. Scoped: CLAUDE_DIR/.proof-status-{phash}  (primary — project-isolated)
#   2. Legacy: CLAUDE_DIR/.proof-status           (backward compat for older hooks)
#   3. Worktree: worktree_path/.claude/.proof-status
#      (only when breadcrumb .active-worktree-path-{phash} or .active-worktree-path
#       exists and points to a valid directory)
#
# @decision DEC-LOG-002
# @title write_proof_status: atomic multi-path proof status writer
# @status accepted
# @rationale prompt-submit.sh, check-tester.sh, and post-task.sh all need to write
#   "verified" status but previously called write_proof_status which was never defined.
#   The function mirrors resolve_proof_file's breadcrumb-resolution logic for reads,
#   extended to write all three locations so guard.sh and task-track.sh can find the
#   status regardless of which path they check. Atomic write via tmp file prevents
#   partial reads under concurrent hook execution.
write_proof_status() {
    local proof_status="${1:?write_proof_status requires a status argument}"
    local project_root="${2:-${PROJECT_ROOT:-$(detect_project_root)}}"
    local claude_dir
    claude_dir=$(PROJECT_ROOT="$project_root" get_claude_dir)
    local phash
    phash=$(project_hash "$project_root")
    local timestamp
    timestamp=$(date +%s)
    local content="${proof_status}|${timestamp}"

    # 1. Scoped proof-status file (primary)
    local scoped_proof="${claude_dir}/.proof-status-${phash}"
    mkdir -p "$(dirname "$scoped_proof")"
    printf '%s\n' "$content" > "${scoped_proof}.tmp" && mv "${scoped_proof}.tmp" "$scoped_proof"

    # 2. Legacy proof-status file (backward compat)
    local legacy_proof="${claude_dir}/.proof-status"
    printf '%s\n' "$content" > "${legacy_proof}.tmp" && mv "${legacy_proof}.tmp" "$legacy_proof"

    # 3. Worktree proof-status file (if breadcrumb exists and points to a valid dir)
    local scoped_breadcrumb="${claude_dir}/.active-worktree-path-${phash}"
    local legacy_breadcrumb="${claude_dir}/.active-worktree-path"
    local breadcrumb=""
    if [[ -f "$scoped_breadcrumb" ]]; then
        breadcrumb="$scoped_breadcrumb"
    elif [[ -f "$legacy_breadcrumb" ]]; then
        breadcrumb="$legacy_breadcrumb"
    fi

    if [[ -n "$breadcrumb" ]]; then
        local worktree_path
        worktree_path=$(cat "$breadcrumb" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$worktree_path" && -d "$worktree_path" ]]; then
            local worktree_claude="${worktree_path}/.claude"
            mkdir -p "$worktree_claude"
            local worktree_proof="${worktree_claude}/.proof-status"
            printf '%s\n' "$content" > "${worktree_proof}.tmp" && mv "${worktree_proof}.tmp" "$worktree_proof"
        fi
    fi

    log_info "write_proof_status" "Wrote '${proof_status}' to proof-status paths for project $(basename "$project_root") [${phash}]"
}

# Export for subshells
export -f log_json log_info read_input get_field detect_project_root get_claude_dir project_hash resolve_proof_file write_proof_status
