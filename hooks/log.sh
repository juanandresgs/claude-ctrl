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
#
# All output goes to stderr so it doesn't interfere with hook JSON output.
#
# @decision DEC-SELF-003
# @title log.sh auto-exports CLAUDE_PROJECT_DIR for project DB scoping
# @status accepted
# @rationale TKT-022: all hooks that source log.sh get CLAUDE_PROJECT_DIR
#   set automatically when run inside a project. This satisfies step 2 of
#   the canonical 4-step resolver in config.py, avoiding a git subprocess
#   per cc_policy call. The HOME guard ensures non-project contexts (global
#   config, bare terminals) do not erroneously scope to HOME as a project.

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

# Export for subshells
export -f log_json log_info read_input get_field detect_project_root

# Auto-export CLAUDE_PROJECT_DIR so downstream cc_policy calls scope to
# project DB. HOME guard prevents non-project contexts from scoping incorrectly.
# This is a performance optimization — config.py can find the project DB via
# git (step 3 of DEC-SELF-003), but the export avoids a subprocess per
# cc_policy call by satisfying step 2 instead.
# @decision DEC-SELF-003
if [[ -z "${CLAUDE_PROJECT_DIR:-}" ]]; then
    _auto_project_root=$(detect_project_root)
    if [[ -n "$_auto_project_root" && "$_auto_project_root" != "${HOME:-/}" ]]; then
        export CLAUDE_PROJECT_DIR="$_auto_project_root"
    fi
    unset _auto_project_root
fi
