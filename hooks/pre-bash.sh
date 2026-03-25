#!/usr/bin/env bash
# Thin entrypoint consolidating all Bash policy checks.
# PreToolUse hook — matcher: Bash
#
# @decision DEC-HOOK-004
# @title Consolidated Bash entrypoint
# @status accepted
# @rationale settings.json currently wires guard.sh directly as the Bash
#   PreToolUse hook. This entrypoint delegates to guard.sh via bash-policy.sh,
#   making it the single settings.json entry for Bash policy and enabling
#   future decomposition of guard.sh's 10 checks into discrete lib functions
#   without rewiring settings.json each time.
#
# Policy chain (via check_git_guard -> guard.sh):
#   1. /tmp safety           6. Destructive git block
#   2. Worktree CWD safety   7. Worktree removal safety
#   3. WHO for git ops       8. Test gate for commit/merge
#   4. Main-is-sacred        9. Test gate (commit variant)
#   5. Force-push safety    10. Proof gate for commit/merge
set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$HOOKS_DIR/log.sh"
source "$HOOKS_DIR/lib/bash-policy.sh"

HOOK_INPUT=$(read_input)
COMMAND=$(get_field '.tool_input.command')
[[ -z "$COMMAND" ]] && exit 0

output=$(check_git_guard "$HOOK_INPUT")

if [[ -n "$output" ]]; then
    # Annotate deny with blockingHook so agents can diagnose which check fired.
    # Fix #466: guard.sh runs 10 internal checks; without blockingHook agents
    # see a generic denial and cannot determine which policy triggered it.
    if echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
        output=$(echo "$output" | jq '.hookSpecificOutput.blockingHook = "guard.sh"')
    fi
    echo "$output"
fi

exit 0
