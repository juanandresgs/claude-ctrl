#!/usr/bin/env bash
# Governance markdown write enforcement: only the planner role may write
# MASTER_PLAN.md, CLAUDE.md, agents/*.md, and docs/*.md.
# PreToolUse hook — matcher: Write|Edit
#
# @decision DEC-FORK-014
# @title Planner-only governance markdown writes
# @status accepted
# @rationale MASTER_PLAN.md, CLAUDE.md, agents/*.md, and docs/*.md define the
# project's invariants, dispatch rules, and architecture. Allowing orchestrators
# or implementers to write these files directly creates silent divergence between
# the claimed plan and the enforced plan — the exact failure mode the planner
# role exists to prevent. Hard enforcement via PreToolUse hook closes the gap
# that existed since fork bootstrap (DEC-FORK-005). The CLAUDE_PLAN_MIGRATION=1
# escape hatch exists for permanent-section migrations that must happen outside a
# planner dispatch (e.g., initial project bootstrap). It is narrow by design:
# the env var must be set explicitly and is not derivable from agent state.
set -euo pipefail

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

HOOK_INPUT=$(read_input)
FILE_PATH=$(get_field '.tool_input.file_path')

# --- Early exits ---

# Exit silently if no file path (not a file-targeted Write/Edit)
[[ -z "$FILE_PATH" ]] && exit 0

# Skip .claude/ directory — meta-infrastructure is self-governed, not subject
# to governance markdown restrictions
[[ "$FILE_PATH" =~ (^|/)\.claude/ ]] && exit 0

# --- Governance markdown classification ---
#
# A file is governance markdown if it matches:
#   1. MASTER_PLAN.md  — exact filename (canonical project root file)
#   2. CLAUDE.md       — exact filename (canonical project root file)
#   3. agents/*.md     — any .md directly under an agents/ directory
#   4. docs/*.md       — any .md directly under a docs/ directory
#
# Matching is by basename + immediate parent dir name, not by absolute path,
# because Claude may pass relative or CWD-relative paths.

is_governance_markdown() {
    local filepath="$1"
    local base
    local parent
    base=$(basename "$filepath")
    parent=$(basename "$(dirname "$filepath")")

    # Root-level canonical governance files
    [[ "$base" == "MASTER_PLAN.md" ]] && return 0
    [[ "$base" == "CLAUDE.md" ]] && return 0

    # agents/*.md — .md file with immediate parent named "agents"
    if [[ "$parent" == "agents" && "$base" == *.md ]]; then
        return 0
    fi

    # docs/*.md — .md file with immediate parent named "docs"
    if [[ "$parent" == "docs" && "$base" == *.md ]]; then
        return 0
    fi

    return 1
}

# If not governance markdown, this hook has nothing to say — pass through
is_governance_markdown "$FILE_PATH" || exit 0

# --- File IS governance markdown. Evaluate authorization. ---

# Allow: CLAUDE_PLAN_MIGRATION=1 explicit environment override
# Used for permanent-section migrations where no planner dispatch is active
if [[ "${CLAUDE_PLAN_MIGRATION:-}" == "1" ]]; then
    log_info "plan-guard" "CLAUDE_PLAN_MIGRATION=1 override: allowing governance write to $FILE_PATH"
    exit 0
fi

# Read active agent role from subagent tracker or CLAUDE_AGENT_ROLE env var
PROJECT_ROOT=$(detect_project_root)
ROLE=$(current_active_agent_role "$PROJECT_ROOT")

# Allow: planner or Plan role (both spellings seen in SubagentStart payloads)
if [[ "$ROLE" == "planner" || "$ROLE" == "Plan" ]]; then
    log_info "plan-guard" "planner role authorized: allowing governance write to $FILE_PATH"
    exit 0
fi

# DENY: all other roles including empty (orchestrator with no role set)
# No special case for orchestrator — plan writes must go through planner dispatch
DENY_ROLE="${ROLE:-orchestrator}"

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: $DENY_ROLE cannot write governance markdown ($FILE_PATH). Only the planner agent may modify plan and governance files.\n\nAction: Dispatch a planner agent for this change, or set CLAUDE_PLAN_MIGRATION=1 for permanent-section migrations."
  }
}
EOF

exit 0
