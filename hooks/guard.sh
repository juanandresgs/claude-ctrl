#!/usr/bin/env bash
set -euo pipefail

# Sacred practice guardrails for Bash commands.
# PreToolUse hook — matcher: Bash
#
# Enforces:
#   - No writing to /tmp/ (use project tmp/ or Claude scratchpad)
#   - Main is sacred (no commits on main/master)
#   - No force push to main/master
#   - No destructive git commands (reset --hard, clean -f)

source "$(dirname "$0")/log.sh"

HOOK_INPUT=$(read_input)
COMMAND=$(get_field '.tool_input.command')

# Exit silently if no command
[[ -z "$COMMAND" ]] && exit 0

deny() {
    local reason="$1"
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "$reason"
  }
}
EOF
    exit 0
}

# --- Check 1: No /tmp/ writes ---
# Block: > /tmp/, >> /tmp/, mv ... /tmp/, cp ... /tmp/, mkdir /tmp/
# Allow: /private/tmp/claude-501/ (Claude scratchpad)
if echo "$COMMAND" | grep -qE '(>|>>)\s*/tmp/|mv\s+.*\s+/tmp/|cp\s+.*\s+/tmp/|mkdir\s+(-p\s+)?/tmp/'; then
    # Allow Claude's own scratchpad
    if echo "$COMMAND" | grep -q '/private/tmp/claude-'; then
        : # allowed
    else
        deny "Cannot write to /tmp/. Use project tmp/ directory or the Claude scratchpad at /private/tmp/claude-501/. Sacred Practice #3: artifacts belong with their project."
    fi
fi

# --- Check 2: Main is sacred (no commits on main/master) ---
if echo "$COMMAND" | grep -qE 'git\s+commit'; then
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
        deny "Cannot commit directly to $CURRENT_BRANCH. Sacred Practice #2: Main is sacred. Create a worktree: git worktree add ../feature-name $CURRENT_BRANCH"
    fi
fi

# --- Check 3: No force push to main/master ---
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*(-f|--force)'; then
    if echo "$COMMAND" | grep -qE 'origin\s+(main|master)'; then
        deny "Cannot force push to main/master. This is a destructive action that rewrites shared history."
    fi
fi

# --- Check 4: No destructive git commands ---
if echo "$COMMAND" | grep -qE 'git\s+reset\s+--hard'; then
    deny "git reset --hard is destructive and discards uncommitted work. Use git stash or create a backup branch first."
fi

if echo "$COMMAND" | grep -qE 'git\s+clean\s+.*-f'; then
    deny "git clean -f permanently deletes untracked files. Use git clean -n (dry run) first to see what would be deleted."
fi

# All checks passed
exit 0
