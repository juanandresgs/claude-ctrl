#!/usr/bin/env bash
set -euo pipefail

# Plan-first enforcement: BLOCK writing source code without MASTER_PLAN.md.
# PreToolUse hook — matcher: Write|Edit
#
# DECISION: Hard deny for planless source writes. Rationale: Advisory warnings
# were ignored by agents — Sacred Practice #6 requires hard enforcement. Status: accepted.
#
# Denies (hard block) when:
#   - Writing a source code file (not config, not test, not docs)
#   - The project root has no MASTER_PLAN.md
#   - The project is a git repo (not a one-off directory)
#
# Does NOT fire for:
#   - Config files, test files, documentation
#   - Projects that already have MASTER_PLAN.md
#   - The ~/.claude directory itself (meta-infrastructure)
#   - Non-git directories

source "$(dirname "$0")/log.sh"

HOOK_INPUT=$(read_input)
FILE_PATH=$(get_field '.tool_input.file_path')

# Exit silently if no file path
[[ -z "$FILE_PATH" ]] && exit 0

# Skip non-source files (matches doc-gate.sh extension list)
[[ ! "$FILE_PATH" =~ \.(ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh)$ ]] && exit 0

# Skip test files, config files, documentation
[[ "$FILE_PATH" =~ (\.config\.|\.test\.|\.spec\.|__tests__|\.generated\.|\.min\.) ]] && exit 0
[[ "$FILE_PATH" =~ (node_modules|vendor|dist|build|\.next|__pycache__|\.git) ]] && exit 0

# Skip the .claude config directory itself
[[ "$FILE_PATH" =~ \.claude/ ]] && exit 0

# --- Fast-mode: skip small/scoped changes ---
# Edit tool is inherently scoped (substring replacement) — skip plan check
TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
if [[ "$TOOL_NAME" == "Edit" ]]; then
    exit 0
fi

# Write tool: skip small files (<20 lines) — trivial fixes don't need a plan
if [[ "$TOOL_NAME" == "Write" ]]; then
    CONTENT_LINES=$(echo "$HOOK_INPUT" | jq -r '.tool_input.content // ""' 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$CONTENT_LINES" -lt 20 ]]; then
        # Log the bypass so surface.sh can report unplanned small writes
        cat <<FAST_EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "Fast-mode bypass: small file write ($CONTENT_LINES lines) skipped plan check. Surface audit will track this."
  }
}
FAST_EOF
        exit 0
    fi
fi

# Detect project root
PROJECT_ROOT=$(detect_project_root)

# Skip non-git directories
[[ ! -d "$PROJECT_ROOT/.git" ]] && exit 0

# Check for MASTER_PLAN.md
if [[ ! -f "$PROJECT_ROOT/MASTER_PLAN.md" ]]; then
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: No MASTER_PLAN.md in $PROJECT_ROOT. Sacred Practice #6: We NEVER run straight into implementing anything. Create a plan first: invoke the Planner agent to produce MASTER_PLAN.md, then retry."
  }
}
EOF
    exit 0
fi

# --- Plan staleness check (advisory, not deny) ---
STALENESS_THRESHOLD="${PLAN_STALENESS_THRESHOLD:-20}"
if [[ -d "$PROJECT_ROOT/.git" ]]; then
    PLAN_MOD=$(stat -f '%m' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null || stat -c '%Y' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null || echo "0")
    if [[ "$PLAN_MOD" -gt 0 ]]; then
        PLAN_DATE=$(date -r "$PLAN_MOD" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$PLAN_MOD" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
        if [[ -n "$PLAN_DATE" ]]; then
            COMMITS_SINCE=$(git -C "$PROJECT_ROOT" rev-list --count --after="$PLAN_DATE" HEAD 2>/dev/null || echo "0")
            if [[ "$COMMITS_SINCE" -ge "$STALENESS_THRESHOLD" ]]; then
                cat <<STALE_EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "Plan staleness warning: MASTER_PLAN.md has not been updated in $COMMITS_SINCE commits (threshold: $STALENESS_THRESHOLD). Consider running /plan-sync to reconcile plan with codebase before continuing."
  }
}
STALE_EOF
                exit 0
            fi
        fi
    fi
fi

exit 0
