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

# --- Check 0: Nuclear command hard deny ---
# Unconditional deny for catastrophic commands. Fires first, no exceptions.
# These are pure regex matches against the command STRING — never executed.

# Category 1: Filesystem destruction (rm -rf on root/home/Users)
if echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*|-[a-zA-Z]*f[a-zA-Z]*r[a-zA-Z]*)\s+(/|~|/home|/Users)\s*$' || \
   echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*|-[a-zA-Z]*f[a-zA-Z]*r[a-zA-Z]*)\s+/\*'; then
    deny "NUCLEAR DENY — Filesystem destruction blocked. This command would recursively delete critical system or user directories."
fi

# Category 2: Disk/device destruction (dd to device, mkfs, write to block device)
if echo "$COMMAND" | grep -qE 'dd\s+.*of=/dev/' || \
   echo "$COMMAND" | grep -qE '>\s*/dev/(sd|disk|nvme|vd|hd)' || \
   echo "$COMMAND" | grep -qE '\bmkfs\b'; then
    deny "NUCLEAR DENY — Disk/device destruction blocked. This command would overwrite or format a storage device."
fi

# Category 3: Fork bomb
if echo "$COMMAND" | grep -qF ':(){ :|:& };:'; then
    deny "NUCLEAR DENY — Fork bomb blocked. This command would exhaust system resources via infinite process spawning."
fi

# Category 4: Recursive permission destruction on root
if echo "$COMMAND" | grep -qE 'chmod\s+(-[a-zA-Z]*R[a-zA-Z]*\s+)?777\s+/' || \
   echo "$COMMAND" | grep -qE 'chmod\s+777\s+/'; then
    deny "NUCLEAR DENY — Recursive permission destruction blocked. chmod 777 on root compromises system security."
fi

# Category 5: System shutdown/reboot — only matches command position
# Anchored to start-of-string or after command separators (&&, ||, |, ;)
# so filenames like "guard-nuclear-shutdown.json" or commit messages don't trigger.
if echo "$COMMAND" | grep -qE '(^|&&|\|\|?|;)\s*(sudo\s+)?(shutdown|reboot|halt|poweroff)\b' || \
   echo "$COMMAND" | grep -qE '(^|&&|\|\|?|;)\s*(sudo\s+)?init\s+[06]\b'; then
    deny "NUCLEAR DENY — System shutdown/reboot blocked. This command would halt or restart the machine."
fi

# Category 6: Remote code execution (pipe to shell)
if echo "$COMMAND" | grep -qE '(curl|wget)\s+.*\|\s*(bash|sh|zsh|python|perl|ruby|node)\b'; then
    deny "NUCLEAR DENY — Remote code execution blocked. Piping downloaded content directly to a shell interpreter is unsafe. Download first, inspect, then execute."
fi

# Category 7: SQL database destruction
if echo "$COMMAND" | grep -qiE '\b(DROP\s+(DATABASE|TABLE|SCHEMA)|TRUNCATE\s+TABLE)\b'; then
    deny "NUCLEAR DENY — SQL database destruction blocked. DROP/TRUNCATE operations permanently destroy data."
fi

# --- Check 1: /tmp/ and /private/tmp/ writes → rewrite to project tmp/ ---
# On macOS, /tmp → /private/tmp (symlink). Both forms must be caught.
# Allow: /private/tmp/claude-*/ (Claude Code scratchpad)
TMP_PATTERN='(>|>>|mv\s+.*|cp\s+.*|tee)\s*(/private)?/tmp/|mkdir\s+(-p\s+)?(/private)?/tmp/'
if echo "$COMMAND" | grep -qE "$TMP_PATTERN"; then
    if echo "$COMMAND" | grep -q '/private/tmp/claude-'; then
        : # Claude scratchpad — allowed as-is
    else
        # Rewrite both /private/tmp/ and /tmp/ to project tmp/ directory
        # Normalize /private/tmp/ → /tmp/ first, then single replacement avoids double-expansion
        PROJECT_ROOT=$(detect_project_root)
        PROJECT_TMP="$PROJECT_ROOT/tmp"
        REWRITTEN=$(echo "$COMMAND" | sed "s|/private/tmp/|/tmp/|g" | sed "s|/tmp/|$PROJECT_TMP/|g")
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

# --- Helper: compare repo identity via git common dir ---
# Worktrees of the same repo share the same common dir, so they are correctly
# treated as "same project." Returns 0 (true) if same, 1 (false) if different.
is_same_project() {
    local target_dir="$1"
    local current_root
    current_root=$(detect_project_root)

    # Get common dir for current project (absolute path)
    local current_common
    current_common=$(cd "$current_root" && git rev-parse --git-common-dir 2>/dev/null) || return 1
    # Resolve to absolute if relative
    if [[ "$current_common" != /* ]]; then
        current_common=$(cd "$current_root" && cd "$current_common" && pwd)
    fi

    # Get common dir for target (absolute path)
    local target_common
    target_common=$(cd "$target_dir" && git rev-parse --git-common-dir 2>/dev/null) || return 1
    if [[ "$target_common" != /* ]]; then
        target_common=$(cd "$target_dir" && cd "$target_common" && pwd)
    fi

    [[ "$current_common" == "$target_common" ]]
}

# --- Check 1.5: Cross-project git guard ---
# Denies git commands that explicitly target a different repository via -C or cd.
# Worktrees of the same repo are allowed (is_same_project handles this).
if echo "$COMMAND" | grep -qE '(git\s+-C\s|cd\s+.*&&\s*git\s)'; then
    CROSS_TARGET=$(extract_git_target_dir "$COMMAND")
    if [[ -n "$CROSS_TARGET" && -d "$CROSS_TARGET" ]]; then
        if ! is_same_project "$CROSS_TARGET"; then
            deny "Cross-project git command blocked. Targets '$CROSS_TARGET' which is outside the current project. Operations on other repositories require explicit user action."
        fi
    fi
fi

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

# --- Check 8: Proof-of-work verification gate ---
# Requires .proof-status = "verified" before commit/merge.
# Same meta-repo exemption as test gates (no feature verification needed for config).
if echo "$COMMAND" | grep -qE 'git\s+(commit|merge)'; then
    if echo "$COMMAND" | grep -qE 'git\s+commit'; then
        PROOF_DIR=$(extract_git_target_dir "$COMMAND")
    else
        PROOF_DIR=$(detect_project_root)
    fi
    if ! is_claude_meta_repo "$PROOF_DIR"; then
        PROOF_FILE="${PROOF_DIR}/.claude/.proof-status"
        if [[ -f "$PROOF_FILE" ]]; then
            PROOF_STATUS=$(cut -d'|' -f1 "$PROOF_FILE")
            if [[ "$PROOF_STATUS" != "verified" ]]; then
                deny "Cannot proceed: proof-of-work verification is '$PROOF_STATUS'. The user must see the feature work before committing. Run the verification checkpoint (Phase 4.5) and get user confirmation."
            fi
        else
            deny "Cannot proceed: no proof-of-work verification (.claude/.proof-status missing). The user must see the feature work before committing. Run the verification checkpoint (Phase 4.5) and get user confirmation."
        fi
    fi
fi

# All checks passed
exit 0
