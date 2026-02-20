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

source "$(dirname "$0")/source-lib.sh"

HOOK_INPUT=$(read_input)
FILE_PATH=$(get_field '.tool_input.file_path')

# Exit silently if no file path
[[ -z "$FILE_PATH" ]] && exit 0

# Skip non-source files (uses shared SOURCE_EXTENSIONS from context-lib.sh)
is_source_file "$FILE_PATH" || exit 0

# Skip test files, config files, vendor directories
is_skippable_path "$FILE_PATH" && exit 0

# Skip the .claude config directory itself
[[ "$FILE_PATH" =~ \.claude/ ]] && exit 0

# --- Fast-mode: skip small/scoped changes ---
# Edit tool is inherently scoped (substring replacement) — skip plan check
TOOL_NAME=$(get_field '.tool_name')
if [[ "$TOOL_NAME" == "Edit" ]]; then
    exit 0
fi

# Write tool: skip small files (<20 lines) — trivial fixes don't need a plan
if [[ "$TOOL_NAME" == "Write" ]]; then
    CONTENT_LINES=$(get_field '.tool_input.content' | wc -l | tr -d ' ')
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
    "permissionDecisionReason": "BLOCKED: No MASTER_PLAN.md in $PROJECT_ROOT. Sacred Practice #6: We NEVER run straight into implementing anything.\n\nAction: Invoke the Planner agent to create MASTER_PLAN.md before implementing."
  }
}
EOF
    exit 0
fi

# --- Plan lifecycle check: dormant plan has no active work ---
# DEC-PLAN-003: "dormant" replaces "completed" for living plan format.
# dormant = all initiatives completed (new format) or all phases completed (old format).
# active  = has at least one active initiative (new) or in-progress phase (old).
# none    = no MASTER_PLAN.md (handled above).
get_plan_status "$PROJECT_ROOT"
if [[ "$PLAN_LIFECYCLE" == "dormant" ]]; then
    cat <<DORMANT_EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: MASTER_PLAN.md is dormant — all initiatives are completed (or plan has no active initiatives).\\n\\nAction: Add a new initiative to MASTER_PLAN.md before writing code. Invoke the Planner agent with create-or-amend workflow."
  }
}
DORMANT_EOF
    exit 0
fi

# --- Plan staleness check (composite: churn % + drift IDs) ---
# DECISION: Composite churn+drift staleness. Rationale: Raw commit count
# doesn't normalize by project size or change significance. Source file churn
# percentage is self-normalizing (consensus from multi-model deep research).
# Decision drift from surface audit provides structural signal. Status: accepted.
get_drift_data "$PROJECT_ROOT"

# Churn tier (primary signal, self-normalizing by project size)
CHURN_WARN_PCT="${PLAN_CHURN_WARN:-15}"
CHURN_DENY_PCT="${PLAN_CHURN_DENY:-35}"

CHURN_TIER="ok"
[[ "$PLAN_SOURCE_CHURN_PCT" -ge "$CHURN_DENY_PCT" ]] && CHURN_TIER="deny"
[[ "$CHURN_TIER" == "ok" && "$PLAN_SOURCE_CHURN_PCT" -ge "$CHURN_WARN_PCT" ]] && CHURN_TIER="warn"

# Drift tier (secondary signal, from last session's surface audit)
DRIFT_TIER="ok"
TOTAL_DRIFT=0
if [[ "$DRIFT_LAST_AUDIT_EPOCH" -gt 0 ]]; then
    TOTAL_DRIFT=$((DRIFT_UNPLANNED_COUNT + DRIFT_UNIMPLEMENTED_COUNT))
    [[ "$TOTAL_DRIFT" -ge 5 ]] && DRIFT_TIER="deny"
    [[ "$DRIFT_TIER" == "ok" && "$TOTAL_DRIFT" -ge 2 ]] && DRIFT_TIER="warn"
else
    # No prior audit — fall back to commit count as bootstrap heuristic
    [[ "$PLAN_COMMITS_SINCE" -ge 100 ]] && DRIFT_TIER="deny"
    [[ "$DRIFT_TIER" == "ok" && "$PLAN_COMMITS_SINCE" -ge 40 ]] && DRIFT_TIER="warn"
fi

# Composite: worst tier wins
STALENESS="ok"
[[ "$CHURN_TIER" == "deny" || "$DRIFT_TIER" == "deny" ]] && STALENESS="deny"
[[ "$STALENESS" == "ok" ]] && [[ "$CHURN_TIER" == "warn" || "$DRIFT_TIER" == "warn" ]] && STALENESS="warn"

# Build diagnostic reason string
DIAG_PARTS=()
[[ "$CHURN_TIER" != "ok" ]] && DIAG_PARTS+=("Source churn: ${PLAN_SOURCE_CHURN_PCT}% of files changed (threshold: ${CHURN_WARN_PCT}%/${CHURN_DENY_PCT}%).")
if [[ "$DRIFT_LAST_AUDIT_EPOCH" -gt 0 ]]; then
    [[ "$DRIFT_TIER" != "ok" ]] && DIAG_PARTS+=("Decision drift: $TOTAL_DRIFT decisions out of sync (${DRIFT_UNPLANNED_COUNT} unplanned, ${DRIFT_UNIMPLEMENTED_COUNT} unimplemented).")
else
    [[ "$DRIFT_TIER" != "ok" ]] && DIAG_PARTS+=("Commit count fallback: $PLAN_COMMITS_SINCE commits since plan update.")
fi
DIAGNOSTIC=""
[[ ${#DIAG_PARTS[@]} -gt 0 ]] && DIAGNOSTIC=$(printf '%s ' "${DIAG_PARTS[@]}")

if [[ "$STALENESS" == "deny" ]]; then
    cat <<DENY_EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
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
