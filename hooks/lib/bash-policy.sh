#!/usr/bin/env bash
# Bash-side policy checks — delegates to existing guard.sh.
#
# @decision DEC-HOOK-002
# @title Thin bash policy delegation
# @status accepted
# @rationale Same as DEC-HOOK-001 — delegate to the existing guard.sh script
#   via subprocess rather than reimplementing its 10 checks. guard.sh remains
#   the source of truth. pre-bash.sh becomes the single settings.json entry
#   point, removing the need to wire guard.sh directly.

_HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Run a hook script with the given JSON input on stdin.
_run_hook() {
    local hook="$1" input="$2"
    printf '%s' "$input" | "$hook" 2>/dev/null || true
}

# Run all bash-side guard checks (guard.sh checks 1-10: /tmp safety,
# CWD/worktree safety, WHO for git, main-sacred, force-push, destructive git,
# worktree removal, test gate for commit/merge, proof gate for commit/merge).
check_git_guard() {
    local input="$1"
    _run_hook "$_HOOKS_DIR/guard.sh" "$input"
}
