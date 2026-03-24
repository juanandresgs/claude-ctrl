#!/usr/bin/env bash
# WHO enforcement for Write|Edit operations on source files.
# PreToolUse hook — matcher: Write|Edit
#
# Only the implementer agent role may write source files. All other roles
# (orchestrator/empty, planner, Plan, tester, guardian) are denied with a
# message directing them to dispatch an implementer. Non-source files are
# not governed here; TKT-004 handles governance markdown separately.
#
# @decision DEC-FORK-005
# @title Write-side WHO enforcement: only implementer may write source files
# @status accepted
# @rationale The bootstrap kernel had git WHO enforcement (guard.sh) but no
# write-side WHO enforcement. Any agent could freely write source files and
# accumulate work before the git commit gate triggered. DEC-FORK-005 identifies
# this as the most important current control gap. This hook closes it at
# write-time. Role detection reads .claude/.subagent-tracker via
# current_active_agent_role from context-lib.sh.
#
# Hook chain position: AFTER branch-guard.sh, BEFORE doc-gate.sh.
# branch-guard fires first so branch protection takes precedence; doc-gate
# only fires for writes that WHO enforcement has already allowed.
#
# Denies when:
#   - File has a recognized source extension (SOURCE_EXTENSIONS)
#   - Active role is NOT implementer (empty, planner, Plan, tester, guardian)
#
# Does NOT fire for:
#   - Non-source files (config, docs, markdown, JSON, YAML)
#   - Files in .claude/ (meta-infrastructure)
#   - Test files and skippable paths (is_skippable_path)
set -euo pipefail

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

HOOK_INPUT=$(read_input)
FILE_PATH=$(get_field '.tool_input.file_path')

# Exit silently if no file path
[[ -z "$FILE_PATH" ]] && exit 0

# Skip .claude/ meta-infrastructure — hooks, agents, settings must remain
# writable by the configuration layer without dispatch overhead
[[ "$FILE_PATH" =~ \.claude/ ]] && exit 0

# WHO enforcement applies only to source files. Non-source files (markdown,
# JSON, YAML, config) are not governed here.
is_source_file "$FILE_PATH" || exit 0

# Skip test files, generated files, vendor directories
is_skippable_path "$FILE_PATH" && exit 0

# Detect active agent role. Uses CLAUDE_AGENT_ROLE env var first (runtime
# injection), then falls back to .subagent-tracker file.
PROJECT_ROOT=$(detect_project_root)
ROLE=$(current_active_agent_role "$PROJECT_ROOT")

# ALLOW: implementer is the only role permitted to write source files
if [[ "$ROLE" == "implementer" ]]; then
    exit 0
fi

# DENY: all other roles — orchestrator (empty), planner, Plan, tester, guardian
if [[ -z "$ROLE" ]]; then
    ROLE_LABEL="orchestrator (no active agent)"
else
    ROLE_LABEL="$ROLE"
fi

DENY_REASON="BLOCKED: $ROLE_LABEL cannot write source files. Only the implementer agent may write source code.

Action: Dispatch an implementer agent for this change."

escaped_reason=$(printf '%s' "$DENY_REASON" | jq -Rs .)

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": $escaped_reason
  }
}
EOF

exit 0
