#!/usr/bin/env bash
set -euo pipefail

# Plan-first enforcement: BLOCK writing source code without MASTER_PLAN.md.
# PreToolUse hook — matcher: Write|Edit
#
# DECISION: Hard deny for planless source writes. Rationale: Advisory warnings
# were ignored by agents — Sacred Practice #6 requires hard enforcement. Status: accepted.
#
# @decision DEC-HOOK-006
# @title TKT-017 — Resolve project root from file path, not CWD; use git rev-parse for worktree detection
# @status accepted
# @rationale Two bugs fixed here:
#   #465: [[ ! -d ".git" ]] silently exits in git worktrees where .git is a FILE
#   (gitdir pointer), not a directory. Replaced with git rev-parse to handle
#   both normal repos and worktrees uniformly.
#   #468: detect_project_root() uses CWD, which is wrong when a session on
#   main writes to a file in a worktree. PROJECT_ROOT is now resolved from the
#   target file's path via git -C "$(dirname "$FILE_PATH")" rev-parse, matching
#   the pattern already used correctly by branch-guard.sh and write-policy.sh.
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
#   - Non-git directories (or paths git can't resolve)

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

HOOK_INPUT=$(read_input)
FILE_PATH=$(get_field '.tool_input.file_path')

# Exit silently if no file path
[[ -z "$FILE_PATH" ]] && exit 0

# Skip non-source files (uses shared SOURCE_EXTENSIONS from context-lib.sh)
is_source_file "$FILE_PATH" || exit 0

# Skip test files, config files, vendor directories
is_skippable_path "$FILE_PATH" && exit 0

# Skip the .claude config directory itself.
# Use project-rooted check (not substring match) — substring match exempts
# ALL files whose absolute path contains ".claude/" (e.g. source files in
# a repo cloned under ~/.claude). DEC-GUARD-SKIP-001.
_SKIP_ROOT=$(detect_project_root 2>/dev/null || echo "")
[[ -n "$_SKIP_ROOT" && "$FILE_PATH" == "$_SKIP_ROOT/.claude/"* ]] && exit 0

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

# Resolve project root from the target file's path, not from session CWD.
# Fix #468: detect_project_root() uses CWD — wrong when a main-branch session
# writes to a file in a worktree. File-path resolution is authoritative.
# Fix #465: In a worktree .git is a FILE (gitdir pointer), not a directory, so
# [[ ! -d .git ]] silently exited. git rev-parse handles both cases uniformly.
FILE_DIR=$(dirname "$FILE_PATH")
if [[ ! -d "$FILE_DIR" ]]; then
    FILE_DIR=$(dirname "$FILE_DIR")
fi
PROJECT_ROOT=$(git -C "$FILE_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")

# Skip non-git directories (or paths git can't resolve)
[[ -z "$PROJECT_ROOT" ]] && exit 0

# Check for MASTER_PLAN.md
if [[ ! -f "$PROJECT_ROOT/MASTER_PLAN.md" ]]; then
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "blockingHook": "plan-check.sh",
    "permissionDecisionReason": "BLOCKED: No MASTER_PLAN.md in $PROJECT_ROOT. Sacred Practice #6: We NEVER run straight into implementing anything.\n\nAction: Invoke the Planner agent to create MASTER_PLAN.md before implementing."
  }
}
EOF
    exit 0
fi

# --- Plan staleness check (churn % + commit-count heuristic) ---
# @decision DEC-HOOK-007
# @title TKT-008 — .plan-drift scoring removed; commit-count heuristic is the secondary signal
# @status accepted
# @rationale The .plan-drift flat file was written by surface.sh and read here
#   to score decision drift. TKT-008 removes all flat-file reads from hot-path
#   hooks. The plan-baseline immutability check (TKT-010) is a stronger structural
#   gate than drift scoring. The commit-count heuristic (already present as the
#   bootstrap fallback when no prior audit existed) is retained as the sole
#   secondary signal alongside source-file churn %.
#   get_drift_data() was deleted in PE-W6 (no live callers).
get_plan_status "$PROJECT_ROOT"

# Churn tier (primary signal, self-normalizing by project size)
CHURN_WARN_PCT="${PLAN_CHURN_WARN:-15}"
CHURN_DENY_PCT="${PLAN_CHURN_DENY:-35}"

CHURN_TIER="ok"
[[ "$PLAN_SOURCE_CHURN_PCT" -ge "$CHURN_DENY_PCT" ]] && CHURN_TIER="deny"
[[ "$CHURN_TIER" == "ok" && "$PLAN_SOURCE_CHURN_PCT" -ge "$CHURN_WARN_PCT" ]] && CHURN_TIER="warn"

# Commit-count heuristic (secondary signal; .plan-drift scoring removed TKT-008)
DRIFT_TIER="ok"
[[ "$PLAN_COMMITS_SINCE" -ge 100 ]] && DRIFT_TIER="deny"
[[ "$DRIFT_TIER" == "ok" && "$PLAN_COMMITS_SINCE" -ge 40 ]] && DRIFT_TIER="warn"

# Composite: worst tier wins
STALENESS="ok"
[[ "$CHURN_TIER" == "deny" || "$DRIFT_TIER" == "deny" ]] && STALENESS="deny"
[[ "$STALENESS" == "ok" ]] && [[ "$CHURN_TIER" == "warn" || "$DRIFT_TIER" == "warn" ]] && STALENESS="warn"

# Build diagnostic reason string
DIAG_PARTS=()
[[ "$CHURN_TIER" != "ok" ]] && DIAG_PARTS+=("Source churn: ${PLAN_SOURCE_CHURN_PCT}% of files changed (threshold: ${CHURN_WARN_PCT}%/${CHURN_DENY_PCT}%).")
[[ "$DRIFT_TIER" != "ok" ]] && DIAG_PARTS+=("Commit count: $PLAN_COMMITS_SINCE commits since plan update.")
DIAGNOSTIC=""
[[ ${#DIAG_PARTS[@]} -gt 0 ]] && DIAGNOSTIC=$(printf '%s ' "${DIAG_PARTS[@]}")

if [[ "$STALENESS" == "deny" ]]; then
    cat <<DENY_EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "blockingHook": "plan-check.sh",
    "permissionDecisionReason": "MASTER_PLAN.md is critically stale. ${DIAGNOSTIC}Read MASTER_PLAN.md, scan the codebase for @decision annotations, and update the plan's phase statuses before continuing."
  }
}
DENY_EOF
    exit 0
elif [[ "$STALENESS" == "warn" ]]; then
    cat <<WARN_EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "Plan staleness warning: ${DIAGNOSTIC}Consider reviewing MASTER_PLAN.md — it may not reflect the current codebase state."
  }
}
WARN_EOF
    exit 0
fi

exit 0
