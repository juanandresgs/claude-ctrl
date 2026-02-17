#!/usr/bin/env bash
set -euo pipefail

# Sacred practice guardrails for Bash commands.
# PreToolUse hook — matcher: Bash
#
# @decision DEC-GUARD-001
# @title Multi-tier command safety gate with transparent rewrites
# @status accepted
# @rationale Enforces Sacred Practices mechanically via deny (hard blocks) and
#   updatedInput (transparent rewrites). Deny prevents destructive commands
#   (rm -rf /, git reset --hard, commits on main). Rewrite fixes unsafe patterns
#   (/tmp/ → project tmp/, --force → --force-with-lease). Nuclear deny category
#   blocks catastrophic commands (fork bomb, dd to device, SQL DROP) unconditionally.
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
source "$(dirname "$0")/context-lib.sh"

HOOK_INPUT=$(read_input)
COMMAND=$(get_field '.tool_input.command')

# Exit silently if no command
[[ -z "$COMMAND" ]] && exit 0

# Emit PreToolUse deny response with reason, then exit.
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

# Transparently rewrite command with JSON-escaped replacement, emit updatedInput response.
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

# --- Check 9: Block agents from writing verified to .proof-status ---
# Only prompt-submit.sh (user-triggered) can write verified status.
# This prevents any agent from bypassing the human verification gate.
# Must be before the early-exit gate since this is not a git command.
# Two conditions: (1) command structurally writes to .proof-status (redirect
# target outside quotes), AND (2) "verified" appears anywhere in the command.
# This avoids false-positives on commit messages that mention both keywords.
_proof_stripped=$(echo "$COMMAND" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g")
if echo "$_proof_stripped" | grep -qE '(>|>>|tee)\s*\S*proof-status' && echo "$COMMAND" | grep -qiE 'verified|approved?|lgtm|looks.good|ship.it'; then
    deny "Cannot write approval status to .proof-status directly. Only the user can verify proof-of-work (via prompt-submit.sh). Present the verification report and let the user respond naturally."
fi

# --- Check 10: Block deletion of .proof-status when verification active ---
# Prevents agents from bypassing the gate by deleting the file.
# Only blocks when status is pending or needs-verification (gate is active).
# Verified status can be cleaned up freely.
if echo "$_proof_stripped" | grep -qE 'rm\s+(-[a-zA-Z]*\s+)*\S*proof-status'; then
    _ps_dir=$(get_claude_dir)
    _ps_file="${_ps_dir}/.proof-status"
    if [[ -f "$_ps_file" ]]; then
        _ps_val=$(cut -d'|' -f1 "$_ps_file")
        if [[ "$_ps_val" == "pending" || "$_ps_val" == "needs-verification" ]]; then
            deny "Cannot delete .proof-status while verification is active (status: $_ps_val). Complete the verification flow first."
        fi
    fi
fi

# --- Early-exit gate: skip git-specific checks for non-git commands ---
# Strip quoted strings so text like "fix git committing" doesn't trigger.
# Then check if `git` appears in a command position (start, or after && || | ;).
_stripped_cmd=$(echo "$COMMAND" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g")
if ! echo "$_stripped_cmd" | grep -qE '(^|&&|\|\|?|;)\s*git\s'; then
    exit 0
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
# shellcheck disable=SC2317,SC2329
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

# --- Check 2: Main is sacred (no commits on main/master) ---
# Exceptions:
#   - ~/.claude directory (meta-infrastructure)
#   - MASTER_PLAN.md only commits (planning documents per Core Dogma)
if echo "$COMMAND" | grep -qE 'git\s+[^|;&]*\bcommit([^a-zA-Z0-9-]|$)'; then
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
if echo "$COMMAND" | grep -qE 'git\s+[^|;&]*\bpush\s+.*(-f|--force)\b'; then
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
if echo "$COMMAND" | grep -qE 'git\s+[^|;&]*\breset\s+--hard'; then
    deny "git reset --hard is destructive and discards uncommitted work. Use git stash or create a backup branch first."
fi

if echo "$COMMAND" | grep -qE 'git\s+[^|;&]*\bclean\s+.*-f'; then
    deny "git clean -f permanently deletes untracked files. Use git clean -n (dry run) first to see what would be deleted."
fi

if echo "$COMMAND" | grep -qE 'git\s+[^|;&]*\bbranch\s+.*-D\b'; then
    deny "git branch -D force-deletes a branch even if unmerged. Use git branch -d (lowercase) for safe deletion."
fi

# --- Check 5: Worktree removal CWD safety rewrite ---
if echo "$COMMAND" | grep -qE 'git[[:space:]]+[^|;&]*worktree[[:space:]]+remove'; then
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

# is_claude_meta_repo is provided by context-lib.sh (shared library)

# --- Check 6: Test status gate for merge commands ---
if echo "$COMMAND" | grep -qE 'git\s+[^|;&]*\bmerge([^a-zA-Z0-9-]|$)'; then
    PROJECT_ROOT=$(detect_project_root)
    if git -C "$PROJECT_ROOT" rev-parse --git-dir > /dev/null 2>&1 && ! is_claude_meta_repo "$PROJECT_ROOT"; then
        if read_test_status "$PROJECT_ROOT"; then
            if [[ "$TEST_RESULT" == "fail" && "$TEST_AGE" -lt "$TEST_STALENESS_THRESHOLD" ]]; then
                deny "Cannot merge: tests are failing ($TEST_FAILS failures, ${TEST_AGE}s ago). Fix test failures before merging."
            fi
            if [[ "$TEST_RESULT" != "pass" ]]; then
                deny "Cannot merge: last test run did not pass (status: $TEST_RESULT). Run tests and ensure they pass."
            fi
        else
            : # No test results yet — allow (no test data to enforce)
        fi
    fi
fi

# --- Check 7: Test status gate for commit commands ---
if echo "$COMMAND" | grep -qE 'git\s+[^|;&]*\bcommit([^a-zA-Z0-9-]|$)'; then
    PROJECT_ROOT=$(extract_git_target_dir "$COMMAND")
    if git -C "$PROJECT_ROOT" rev-parse --git-dir > /dev/null 2>&1 && ! is_claude_meta_repo "$PROJECT_ROOT"; then
        if read_test_status "$PROJECT_ROOT"; then
            if [[ "$TEST_RESULT" == "fail" && "$TEST_AGE" -lt "$TEST_STALENESS_THRESHOLD" ]]; then
                deny "Cannot commit: tests are failing ($TEST_FAILS failures, ${TEST_AGE}s ago). Fix test failures before committing."
            fi
            if [[ "$TEST_RESULT" != "pass" ]]; then
                deny "Cannot commit: last test run did not pass (status: $TEST_RESULT). Run tests and ensure they pass."
            fi
        else
            : # No test results yet — allow (no test data to enforce)
        fi
    fi
fi

# --- Check 8: Proof-of-work verification gate ---
# Requires .proof-status = "verified" before commit/merge (when gate is active).
# Gate is only active when .proof-status file exists (created by implementer dispatch).
# Missing file = no implementation in progress = allow (fixes bootstrap deadlock).
# Same meta-repo exemption as test gates (no feature verification needed for config).
if echo "$COMMAND" | grep -qE 'git\s+[^|;&]*\b(commit|merge)([^a-zA-Z0-9-]|$)'; then
    if echo "$COMMAND" | grep -qE 'git\s+[^|;&]*\bcommit([^a-zA-Z0-9-]|$)'; then
        PROOF_DIR=$(extract_git_target_dir "$COMMAND")
    else
        PROOF_DIR=$(detect_project_root)
    fi
    if git -C "$PROOF_DIR" rev-parse --git-dir > /dev/null 2>&1 && ! is_claude_meta_repo "$PROOF_DIR"; then
        PROOF_FILE="${PROOF_DIR}/.claude/.proof-status"
        if [[ -f "$PROOF_FILE" ]]; then
            PROOF_STATUS=$(cut -d'|' -f1 "$PROOF_FILE")
            if [[ "$PROOF_STATUS" != "verified" ]]; then
                deny "Cannot proceed: proof-of-work verification is '$PROOF_STATUS'. The user must see the feature work before committing. Run the verification checkpoint (Phase 4.5) and get user confirmation."
            fi
        fi
        # File missing → no implementation in progress → allow (bootstrap path)
    fi
fi

# All checks passed
exit 0
