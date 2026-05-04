#!/usr/bin/env bash
# WHO enforcement for Write|Edit operations on source files.
# PreToolUse hook — matcher: Write|Edit
#
# Only the implementer agent role may write source files. All other roles
# (orchestrator/empty, planner, Plan, reviewer, guardian) are denied with a
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
# write-time. Role detection uses SQLite agent_markers as sole authority
# via current_active_agent_role from context-lib.sh (DEC-IDENTITY-NO-ENV-VAR).
#
# Hook chain position: AFTER branch-guard.sh, BEFORE doc-gate.sh.
# branch-guard fires first so branch protection takes precedence; doc-gate
# only fires for writes that WHO enforcement has already allowed.
#
# Denies when:
#   - File has a recognized source extension (SOURCE_EXTENSIONS)
#   - Active role is NOT implementer (empty, planner, Plan, reviewer, guardian)
#
# Does NOT fire for:
#   - Non-source files (config, docs, markdown, JSON, YAML)
#   - Files in .claude/ (meta-infrastructure)
#   - Test files and skippable paths (is_skippable_path)
set -euo pipefail

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

# shellcheck disable=SC2034  # HOOK_INPUT is consumed by get_field via context-lib shared state
HOOK_INPUT=$(read_input)
seed_project_dir_from_hook_payload_cwd "$HOOK_INPUT"
FILE_PATH=$(get_field '.tool_input.file_path')

# Exit silently if no file path
[[ -z "$FILE_PATH" ]] && exit 0

# Skip .claude/ meta-infrastructure — hooks, agents, settings must remain
# writable by the configuration layer without dispatch overhead.
# Use project-rooted check (not substring match) — substring match exempts
# ALL files whose absolute path contains ".claude/" (e.g. source files in
# a repo cloned under ~/.claude). DEC-GUARD-SKIP-001.
_SKIP_ROOT=$(detect_project_root 2>/dev/null || echo "")
[[ -n "$_SKIP_ROOT" && "$FILE_PATH" == "$_SKIP_ROOT/.claude/"* ]] && exit 0

# WHO enforcement applies only to source files. Non-source files (markdown,
# JSON, YAML, config) are not governed here.
is_source_file "$FILE_PATH" || exit 0

# Skip test files, generated files, vendor directories
is_skippable_path "$FILE_PATH" && exit 0

# Resolve project root from the target file's path, not from session CWD.
# Fix #468: detect_project_root() uses CWD — wrong when a main-branch session
# writes to a file in a worktree. File-path resolution is authoritative here.
FILE_DIR=$(dirname "$FILE_PATH")
[[ ! -d "$FILE_DIR" ]] && FILE_DIR=$(dirname "$FILE_DIR")
PROJECT_ROOT=$(git -C "$FILE_DIR" rev-parse --show-toplevel 2>/dev/null || detect_project_root)

# Detect active agent role. SQLite agent_markers is the sole authority
# (DEC-IDENTITY-NO-ENV-VAR). CLAUDE_AGENT_ROLE env var is NOT consulted.
ROLE=$(current_active_agent_role "$PROJECT_ROOT")

# ALLOW: implementer is the only role permitted to write source files
if [[ "$ROLE" == "implementer" ]]; then
    exit 0
fi

# DENY: all other roles — orchestrator (empty), planner, Plan, reviewer, guardian
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
    "blockingHook": "write-guard.sh",
    "permissionDecisionReason": $escaped_reason
  }
}
EOF

exit 0
