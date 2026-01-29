#!/usr/bin/env bash
set -euo pipefail

# Plan-first enforcement: warn if writing source code without MASTER_PLAN.md.
# PreToolUse hook — matcher: Write|Edit
#
# Warns (does not block) when:
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

# Skip non-source files
[[ ! "$FILE_PATH" =~ \.(ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php)$ ]] && exit 0

# Skip test files, config files, documentation
[[ "$FILE_PATH" =~ (\.config\.|\.test\.|\.spec\.|__tests__|\.generated\.|\.min\.) ]] && exit 0
[[ "$FILE_PATH" =~ (node_modules|vendor|dist|build|\.next|__pycache__|\.git) ]] && exit 0

# Skip the .claude config directory itself
[[ "$FILE_PATH" =~ \.claude/ ]] && exit 0

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
    "additionalContext": "No MASTER_PLAN.md found in $PROJECT_ROOT. Per Core Dogma, create a plan before implementing. Sacred Practice #5: We NEVER run straight into implementing anything."
  }
}
EOF
fi

exit 0
