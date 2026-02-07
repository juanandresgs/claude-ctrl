#!/usr/bin/env bash
set -euo pipefail

# Sacred practice guardrails for Bash commands.
# PreToolUse hook — matcher: Bash
#
# Enforces via updatedInput (transparent rewrites):
#   - /tmp/ writes → rewritten to project tmp/ directory
#   - git push --force → rewritten to --force-with-lease (except to main/master)
#   - git worktree remove → rewritten to cd to main worktree first (prevents CWD death spiral)
#
# Enforces via deny (hard blocks):
#   - Main is sacred (no commits on main/master)
#   - No force push to main/master
#   - No destructive git commands (reset --hard, clean -f, branch -D)

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

rewrite() {
    local new_command="$1"
    local reason="$2"
    local escaped_command
    escaped_command=$(echo "$new_command" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "$reason",
    "updatedInput": {
      "command": $escaped_command
    }
  }
}
EOF
    exit 0
}

# --- Check 1: /tmp/ writes → rewrite to project tmp/ ---
# Allow: /private/tmp/claude-501/ (Claude scratchpad)
if echo "$COMMAND" | grep -qE '(>|>>)\s*/tmp/|mv\s+.*\s+/tmp/|cp\s+.*\s+/tmp/|mkdir\s+(-p\s+)?/tmp/|tee\s+/tmp/'; then
    if echo "$COMMAND" | grep -q '/private/tmp/claude-'; then
        : # Claude scratchpad — allowed as-is
    else
        # Rewrite /tmp/ to project tmp/ directory
        PROJECT_ROOT=$(detect_project_root)
        PROJECT_TMP="$PROJECT_ROOT/tmp"
        REWRITTEN=$(echo "$COMMAND" | sed "s|/tmp/|$PROJECT_TMP/|g")
        # Ensure project tmp/ directory exists
        REWRITTEN="mkdir -p $PROJECT_TMP && $REWRITTEN"
        rewrite "$REWRITTEN" "Rewrote /tmp/ to project tmp/ directory. Sacred Practice #3: artifacts belong with their project."
    fi
fi

# --- Helper: extract git target directory from command text ---
# Parses "cd /path && git ..." or "git -C /path ..." to find the actual
# working directory the git command targets. Falls back to CWD.
extract_git_target_dir() {
    local cmd="$1"
    # Pattern A: cd /path && ... (unquoted, single-quoted, or double-quoted)
    if [[ "$cmd" =~ cd[[:space:]]+(\"([^\"]+)\"|\'([^\']+)\'|([^[:space:]\&\;]+)) ]]; then
        local dir="${BASH_REMATCH[2]:-${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}}"
        if [[ -n "$dir" && -d "$dir" ]]; then
            echo "$dir"
            return
        fi
    fi
    # Pattern B: git -C /path ...
    if [[ "$cmd" =~ git[[:space:]]+-C[[:space:]]+(\"([^\"]+)\"|\'([^\']+)\'|([^[:space:]]+)) ]]; then
        local dir="${BASH_REMATCH[2]:-${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}}"
        if [[ -n "$dir" && -d "$dir" ]]; then
            echo "$dir"
            return
        fi
    fi
    # Fallback: try hook input JSON cwd field, then CLAUDE_PROJECT_DIR, then git root
    local input_cwd
    input_cwd=$(get_field '.cwd' 2>/dev/null)
    if [[ -n "$input_cwd" && -d "$input_cwd" ]]; then
        echo "$input_cwd"
        return
    fi
    detect_project_root
}

# --- Check 2: Main is sacred (no commits on main/master) ---
# Exceptions:
#   - ~/.claude directory (meta-infrastructure)
#   - MASTER_PLAN.md only commits (planning documents per Core Dogma)
if echo "$COMMAND" | grep -qE 'git\s+commit'; then
    TARGET_DIR=$(extract_git_target_dir "$COMMAND")
    REPO_ROOT=$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")
    # Skip if this is the .claude config directory (meta-infrastructure)
    if [[ "$REPO_ROOT" != */.claude ]]; then
        CURRENT_BRANCH=$(git -C "$TARGET_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
        if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
            # Check if ONLY MASTER_PLAN.md is staged (plan files allowed per Core Dogma)
            STAGED_FILES=$(git -C "$TARGET_DIR" diff --cached --name-only 2>/dev/null || echo "")
            if [[ "$STAGED_FILES" == "MASTER_PLAN.md" ]]; then
                : # Allow - plan file commits on main are permitted
            else
                deny "Cannot commit directly to $CURRENT_BRANCH. Sacred Practice #2: Main is sacred. Create a worktree: git worktree add .worktrees/feature-name $CURRENT_BRANCH"
            fi
        fi
    fi
fi

# --- Check 3: Force push handling ---
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*(-f|--force)\b'; then
    # Hard block: force push to main/master
    if echo "$COMMAND" | grep -qE '(origin|upstream)\s+(main|master)\b'; then
        deny "Cannot force push to main/master. This is a destructive action that rewrites shared history."
    fi
    # Soft fix: rewrite --force to --force-with-lease (safer)
    if ! echo "$COMMAND" | grep -qE '\-\-force-with-lease'; then
        # Use perl for word-boundary support (macOS sed lacks \b)
        REWRITTEN=$(echo "$COMMAND" | perl -pe 's/--force(?!-with-lease)/--force-with-lease/g; s/\s-f\s/ --force-with-lease /g')
        rewrite "$REWRITTEN" "Rewrote --force to --force-with-lease for safety."
    fi
fi

# --- Check 4: No destructive git commands (hard blocks) ---
if echo "$COMMAND" | grep -qE 'git\s+reset\s+--hard'; then
    deny "git reset --hard is destructive and discards uncommitted work. Use git stash or create a backup branch first."
fi

if echo "$COMMAND" | grep -qE 'git\s+clean\s+.*-f'; then
    deny "git clean -f permanently deletes untracked files. Use git clean -n (dry run) first to see what would be deleted."
fi

if echo "$COMMAND" | grep -qE 'git\s+branch\s+.*-D\b'; then
    deny "git branch -D force-deletes a branch even if unmerged. Use git branch -d (lowercase) for safe deletion."
fi

# --- Check 5: Worktree removal CWD safety rewrite ---
if echo "$COMMAND" | grep -qE 'git[[:space:]]+worktree[[:space:]]+remove'; then
    WT_PATH=$(echo "$COMMAND" | sed -E 's/.*git[[:space:]]+worktree[[:space:]]+remove[[:space:]]+(-f[[:space:]]+)?//' | xargs)
    if [[ -n "$WT_PATH" ]]; then
        # Find main worktree (safe target for cd)
        MAIN_WT=$(git worktree list 2>/dev/null | awk '{print $1; exit}')
        MAIN_WT="${MAIN_WT:-$(detect_project_root)}"
        # Rewrite: cd to main worktree before removal prevents CWD death spiral
        REWRITTEN="cd \"$MAIN_WT\" && $COMMAND"
        rewrite "$REWRITTEN" "Rewrote to cd to main worktree before removal. Prevents death spiral if Bash CWD is inside the worktree being removed."
    fi
fi

# --- Helper: check if repo is the ~/.claude meta-infrastructure repo ---
is_claude_meta_repo() {
    local dir="$1"
    local repo_root
    repo_root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "")
    [[ "$repo_root" == */.claude ]]
}

# --- Check 6: Test status gate for merge commands ---
if echo "$COMMAND" | grep -qE 'git\s+merge'; then
    PROJECT_ROOT=$(detect_project_root)
    if ! is_claude_meta_repo "$PROJECT_ROOT"; then
        TEST_STATUS_FILE="${PROJECT_ROOT}/.claude/.test-status"
        if [[ -f "$TEST_STATUS_FILE" ]]; then
            TEST_RESULT=$(cut -d'|' -f1 "$TEST_STATUS_FILE")
            TEST_FAILS=$(cut -d'|' -f2 "$TEST_STATUS_FILE")
            TEST_TIME=$(cut -d'|' -f3 "$TEST_STATUS_FILE")
            NOW=$(date +%s)
            AGE=$(( NOW - TEST_TIME ))
            if [[ "$TEST_RESULT" == "fail" && "$AGE" -lt 600 ]]; then
                deny "Cannot merge: tests are failing ($TEST_FAILS failures, ${AGE}s ago). Fix test failures before merging."
            fi
            if [[ "$TEST_RESULT" != "pass" ]]; then
                deny "Cannot merge: last test run did not pass (status: $TEST_RESULT). Run tests and ensure they pass."
            fi
        else
            deny "Cannot merge: no test results found (.claude/.test-status missing). Run the project's test suite first. Tests must pass before merging."
        fi
    fi
fi

# --- Check 7: Test status gate for commit commands ---
if echo "$COMMAND" | grep -qE 'git\s+commit'; then
    PROJECT_ROOT=$(extract_git_target_dir "$COMMAND")
    if ! is_claude_meta_repo "$PROJECT_ROOT"; then
        TEST_STATUS_FILE="${PROJECT_ROOT}/.claude/.test-status"
        if [[ -f "$TEST_STATUS_FILE" ]]; then
            TEST_RESULT=$(cut -d'|' -f1 "$TEST_STATUS_FILE")
            TEST_FAILS=$(cut -d'|' -f2 "$TEST_STATUS_FILE")
            TEST_TIME=$(cut -d'|' -f3 "$TEST_STATUS_FILE")
            NOW=$(date +%s)
            AGE=$(( NOW - TEST_TIME ))
            if [[ "$TEST_RESULT" == "fail" && "$AGE" -lt 600 ]]; then
                deny "Cannot commit: tests are failing ($TEST_FAILS failures, ${AGE}s ago). Fix test failures before committing."
            fi
            if [[ "$TEST_RESULT" != "pass" ]]; then
                deny "Cannot commit: last test run did not pass (status: $TEST_RESULT). Run tests and ensure they pass."
            fi
        else
            deny "Cannot commit: no test results found (.claude/.test-status missing). Run the project's test suite first. Tests must pass before committing."
        fi
    fi
fi

# All checks passed
exit 0
