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
#
# @decision DEC-INTEGRITY-002
# @title Deny-on-crash EXIT trap for fail-closed behavior
# @status accepted
# @rationale guard.sh previously failed open: if source-lib.sh failed to load,
#   jq was missing, or any command errored under set -euo pipefail, the hook
#   would exit non-zero and Claude Code would silently allow the command through.
#   This meant safety checks could be bypassed by any runtime error. The EXIT
#   trap pattern combined with a completion flag (_GUARD_COMPLETED) flips this
#   to fail-closed: crash = deny. Normal exit paths (deny(), rewrite(), early
#   exits) set the flag to true so the trap is a no-op for them. The trap MUST
#   be installed before source-lib.sh because that is the most common crash point.

# --- Fail-closed crash trap ---
# MUST be set before source-lib.sh — that's the most common failure point.
_GUARD_COMPLETED=false
_guard_deny_on_crash() {
    if [[ "$_GUARD_COMPLETED" != "true" ]]; then
        cat <<'CRASHJSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "SAFETY: guard.sh crashed before completing safety checks. Command denied as precaution. Run: bash -n ~/.claude/hooks/guard.sh to diagnose."
  }
}
CRASHJSON
    fi
}
trap '_guard_deny_on_crash' EXIT

source "$(dirname "$0")/source-lib.sh"

HOOK_INPUT=$(read_input)
COMMAND=$(get_field '.tool_input.command')

# Exit silently if no command
if [[ -z "$COMMAND" ]]; then
    _GUARD_COMPLETED=true
    exit 0
fi

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
    _GUARD_COMPLETED=true
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
    _GUARD_COMPLETED=true
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

# --- Check 0.5: Universal CWD recovery (two-path) ---
# @decision DEC-GUARD-CWD-001
# @title Rewrite commands when orchestrator Bash CWD is invalid after worktree deletion
# @status accepted
# @rationale When Guardian (subagent) removes a worktree, the orchestrator's Bash CWD
#   still points to the deleted directory. ALL subsequent orchestrator Bash commands
#   fail with ENOENT. Existing fixes (source-lib.sh line 25, safe_cleanup) only fix
#   the subagent's own shell — they cannot propagate to the orchestrator's Bash tool
#   shell. guard.sh's rewrite() CAN propagate because rewritten commands execute in
#   the Bash tool's shell. Check 0.5 intercepts the first command after CWD death.
#   Placed AFTER Check 0 (nuclear deny) so catastrophic commands are still denied
#   even when CWD is broken — nuclear safety is never sacrificed for convenience.
#
#   Two detection paths:
#   Path A (.cwd provided and broken): Walks up the deleted path to find a valid
#     git-root ancestor (or falls back to $HOME). Emits `cd <recovery_dir> && CMD`
#     via rewrite() and exits — provides the highest quality recovery.
#   Path B (canary file at $HOME/.claude/.cwd-recovery-needed): Used when .cwd is
#     absent or valid (framework CWD is always valid so Claude Code may not report
#     a broken .cwd). Check 5/5b and check-guardian.sh write a canary containing
#     the deleted worktree path when a removal is detected. Path B prepends an
#     inline `cd .` guard to the command (a no-op when CWD is valid, silently falls
#     back to $HOME when CWD is deleted) and continues to other checks — this allows
#     git safety checks to still run on the recovered command.
#
# @decision DEC-GUARD-CWD-002
# @title Canary file as second CWD recovery detection path
# @status accepted
# @rationale Path A relies on `.cwd` in hook input JSON. In practice, Claude Code
#   framework always reports its own (valid) CWD — not the Bash tool's persisted
#   CWD — so `.cwd` is often absent or valid even when the Bash tool's shell is
#   stuck in a deleted directory. The canary at $HOME/.claude/.cwd-recovery-needed
#   is written by guard.sh Check 5/5b and check-guardian.sh at the point of worktree
#   deletion detection — before the Bash tool processes the next command — giving
#   Check 0.5 a reliable second signal. The canary is one-shot (deleted on read) to
#   prevent stale triggers across commands. The inline `{ cd . 2>/dev/null ||
#   cd "$HOME" 2>/dev/null || cd /; };` guard is a zero-overhead no-op when CWD
#   is valid, and recovers silently when CWD is deleted.
_CWD_GUARD_APPLIED=false
_CWD_GUARD_REASON=""
_CANARY_FILE="$HOME/.claude/.cwd-recovery-needed"

BASH_CWD=$(get_field '.cwd' 2>/dev/null || echo "")

# Path A: .cwd provided and broken → directed recovery (walk up to git root, then exit)
if [[ -n "$BASH_CWD" && ! -d "$BASH_CWD" ]]; then
    RECOVERY_DIR=""
    _candidate="${BASH_CWD}"
    while [[ "$_candidate" != "/" && "$_candidate" != "." ]]; do
        _candidate=$(dirname "$_candidate")
        if [[ -d "$_candidate" && -d "$_candidate/.git" ]]; then
            RECOVERY_DIR="$_candidate"
            break
        fi
    done
    RECOVERY_DIR="${RECOVERY_DIR:-$HOME}"
    log_info "GUARD-CWD" "Path A recovery: '$BASH_CWD' → '$RECOVERY_DIR'"
    # Consume canary if present (Path A handles recovery, canary no longer needed)
    rm -f "$_CANARY_FILE"
    rewrite "cd \"$RECOVERY_DIR\" && $COMMAND" \
        "CWD recovery: '$BASH_CWD' no longer exists (deleted worktree). Recovered to $RECOVERY_DIR."
fi

# Path B: Canary file exists → inline guard prepended, continue to other checks
if [[ -f "$_CANARY_FILE" ]]; then
    _DELETED_WT=$(head -1 "$_CANARY_FILE" 2>/dev/null | tr -d '[:space:]' || echo "")
    rm -f "$_CANARY_FILE"  # One-shot: consume immediately
    if [[ -n "$_DELETED_WT" && ! -d "$_DELETED_WT" ]]; then
        # Deleted path is truly gone — prepend inline CWD guard to command
        # The guard is a no-op when CWD is valid; silently falls back to $HOME when CWD is deleted.
        # We modify COMMAND in-place so subsequent checks operate on the guarded version.
        COMMAND='{ cd . 2>/dev/null || cd "'"$HOME"'" 2>/dev/null || cd /; }; '"$COMMAND"
        _CWD_GUARD_APPLIED=true
        _CWD_GUARD_REASON="CWD canary recovery: '$_DELETED_WT' no longer exists. Prepended inline cd guard."
        log_info "GUARD-CWD" "Path B recovery applied for deleted: '$_DELETED_WT'"
    else
        # Path still exists — false alarm (race condition or test scenario)
        log_info "GUARD-CWD" "Path B: canary consumed, path still exists ('$_DELETED_WT') — no action"
    fi
fi

# --- Check 0.75: Prevent cd into worktree directories with chained commands ---
# @decision DEC-GUARD-CWD-003
# @title Deny cd-into-worktree with chained commands; suggest subshell resubmit
# @status accepted
# @rationale When the Bash tool's CWD points to a .worktrees/ path and that
#   worktree is later deleted, ALL hook spawning fails — not just Bash hooks.
#   posix_spawn returns ENOENT on macOS when the parent process CWD is deleted.
#   The canary approach (Path B) only recovers PreToolUse:Bash; Edit hooks, Stop
#   hooks, and SessionEnd hooks cannot be recovered because the shell can't start.
#   Prevention is the only reliable fix. The original approach used updatedInput
#   (rewrite) to transparently wrap the command in a subshell, but updatedInput
#   is NOT supported in PreToolUse hooks — only in PermissionRequest hooks. The
#   framework silently ignores updatedInput and runs the original command unchanged,
#   making rewrite() a no-op for command safety. We now deny with a reason that
#   includes the suggested subshell-wrapped command so the model can resubmit.
#   Already-subshell-wrapped commands (starting with "( ") pass through — this is
#   the model's correct resubmit after a deny. Bare cd is allowed because subagents
#   (implementer, guardian) need persistent CWD in their worktrees.

# Pattern: cd/pushd where the DESTINATION ends at a worktree name (no deeper subpath).
# Matches: cd .worktrees/foo, cd /abs/.worktrees/foo, pushd .worktrees/feat-x
# Does NOT match: cd /parent/.worktrees/foo/subdir (path goes deeper inside worktree)
# The [^/[:space:];&|]+ after .worktrees/ requires a non-empty worktree name with no
# further slashes — ensuring we match only the worktree root, not subdirectories within.
# Skip if already subshell-wrapped (model resubmit after previous deny)
if [[ "$COMMAND" == "( "* ]]; then
    : # Already subshell-wrapped, pass through
elif echo "$COMMAND" | grep -qE '\b(cd|pushd)\b[^;&|]*\.worktrees/[^/[:space:];&|]+([[:space:]]|$|&&|;|\|\|)'; then
    # Check if there are commands chained after the cd (&&, ;, ||)
    if echo "$COMMAND" | grep -qE '\.worktrees/[^/[:space:];&|]+[[:space:]]*(&&|;|\|\|)'; then
        log_info "GUARD-CWD" "Check 0.75: Denying cd-into-worktree with chained commands"
        deny "CWD protection: cd into .worktrees/ with chained commands would set framework CWD to a deletable directory. If the worktree is later removed, ALL hooks fail (posix_spawn ENOENT). Resubmit with subshell wrapping: ( $COMMAND )"
    fi
    # Bare cd/pushd into worktree: allow (subagents need persistent CWD).
    # Defense-in-depth: canary + Path B handles recovery if orchestrator violates CLAUDE.md.
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
    if ! is_claude_meta_repo "$(detect_project_root)"; then
        _ps_file="${_ps_dir}/.proof-status"
        if [[ -f "$_ps_file" ]]; then
            _ps_val=$(cut -d'|' -f1 "$_ps_file")
            if [[ "$_ps_val" == "pending" || "$_ps_val" == "needs-verification" ]]; then
                deny "Cannot delete .proof-status while verification is active (status: $_ps_val). Complete the verification flow first."
            fi
        fi
    fi
fi

# --- Check 5b: rm -rf .worktrees/ CWD safety rewrite ---
# Same death-spiral prevention as Check 5 (git worktree remove), but for direct
# rm commands that bypass git worktree remove entirely (e.g. rm -rf .worktrees/).
# Must run BEFORE the early-exit gate which skips all non-git commands.
#
# @decision DEC-GUARD-002
# @title Two-tier worktree CWD safety: git worktree remove + raw rm
# @status accepted
# @rationale Check 5 only catches `git worktree remove`. The death spiral also
# occurs when the agent runs `rm -rf .worktrees/` directly, or when
# worktree-roster.sh cleanup falls through to rm -rf internally. This check
# intercepts rm with recursive+force targeting any .worktrees/ path and prepends
# a `cd` to the main worktree, identical to the Check 5 pattern.
if echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+){1,2}.*\.worktrees/|rm\s+(-[a-zA-Z]*r[a-zA-Z]*\s+|--recursive\s+).*\.worktrees/'; then
    WT_TARGET=$(echo "$COMMAND" | grep -oE '[^[:space:]]*\.worktrees/[^[:space:];&|]*' | head -1)
    if [[ -n "$WT_TARGET" ]]; then
        MAIN_WT=$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1 || echo "")
        MAIN_WT="${MAIN_WT:-$(detect_project_root)}"
        # Write canary: the next orchestrator Bash command may land in a dead CWD.
        # Resolve to absolute path so Check 0.5 Path B can test if it still exists.
        _WT_ABS=$(cd "$(dirname "$WT_TARGET" 2>/dev/null)" 2>/dev/null && pwd || echo "$WT_TARGET")
        echo "${_WT_ABS}" > "$HOME/.claude/.cwd-recovery-needed" 2>/dev/null || true
        REWRITTEN="cd \"$MAIN_WT\" && $COMMAND"
        rewrite "$REWRITTEN" "Rewrote to cd to main worktree before rm of worktree directory. Prevents CWD death spiral if shell CWD is inside the target."
    fi
fi

# --- Early-exit gate: skip git-specific checks for non-git commands ---
# Strip quoted strings so text like "fix git committing" doesn't trigger.
# Then check if `git` appears in a command position (start, or after && || | ;).
# NOTE: If Path B canary guard was applied, emit the rewrite before exiting — the
# deferred rewrite at the bottom is only reachable for git commands.
_stripped_cmd=$(echo "$COMMAND" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g")
if ! echo "$_stripped_cmd" | grep -qE '(^|&&|\|\|?|;)\s*git\s'; then
    if [[ "$_CWD_GUARD_APPLIED" == true ]]; then
        rewrite "$COMMAND" "$_CWD_GUARD_REASON"
    fi
    _GUARD_COMPLETED=true
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
#   - Merge commits (MERGE_HEAD present — landing feature branches via git merge)
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
            elif GIT_DIR=$(git -C "$TARGET_DIR" rev-parse --absolute-git-dir 2>/dev/null) && [[ -f "$GIT_DIR/MERGE_HEAD" ]]; then
                : # Allow — completing a merge is the intended workflow
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
# @decision DEC-GUARD-CHECK5-001
# @title Use extract_git_target_dir + git -C for worktree removal rewrite
# @status accepted
# @rationale The original sed+xargs approach failed for `git -C "path with spaces"
#   worktree remove` because the sed pattern expected `git worktree` directly
#   adjacent (no -C option), causing WT_PATH to leak the full command or be empty.
#   The bare `git worktree list` (no -C) crashed with exit 128 under set -euo pipefail
#   when the hook CWD was not inside the target git repo, triggering deny-on-crash.
#   Fix: use extract_git_target_dir() (already handles -C and cd patterns) to get
#   the correct repo directory, then pass it to git -C so worktree list targets the
#   right repo regardless of hook CWD. The || echo "" prevents pipeline failure
#   from crashing under set -euo pipefail.
if echo "$COMMAND" | grep -qE 'git[[:space:]]+[^|;&]*worktree[[:space:]]+remove'; then
    CHECK5_DIR=$(extract_git_target_dir "$COMMAND")
    MAIN_WT=$(git -C "$CHECK5_DIR" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1 || echo "")
    MAIN_WT="${MAIN_WT:-$CHECK5_DIR}"
    # Extract the worktree path being removed and write canary so Check 0.5 Path B
    # can recover the orchestrator's CWD on the next Bash command after the removal.
    WT_REMOVE_PATH=$(echo "$COMMAND" | sed -nE 's/.*worktree[[:space:]]+remove[[:space:]]+(--[a-z-]+[[:space:]]+)*([^[:space:];&|]+).*/\2/p' | head -1 || echo "")
    if [[ -n "$WT_REMOVE_PATH" ]]; then
        echo "$WT_REMOVE_PATH" > "$HOME/.claude/.cwd-recovery-needed" 2>/dev/null || true
    fi
    REWRITTEN="cd \"$MAIN_WT\" && $COMMAND"
    rewrite "$REWRITTEN" "Rewrote to cd to main worktree before removal. Prevents death spiral if Bash CWD is inside the worktree being removed."
fi

# is_claude_meta_repo is provided by context-lib.sh (shared library)

# --- Check 6: Test status gate for merge commands ---
if echo "$COMMAND" | grep -qE 'git\s+[^|;&]*\bmerge([^a-zA-Z0-9-]|$)'; then
    PROJECT_ROOT=$(detect_project_root)
    if git -C "$PROJECT_ROOT" rev-parse --git-dir > /dev/null 2>&1 && ! is_claude_meta_repo "$PROJECT_ROOT"; then
        if read_test_status "$PROJECT_ROOT"; then
            if [[ "$TEST_RESULT" == "fail" && "$TEST_AGE" -lt "$TEST_STALENESS_THRESHOLD" ]]; then
                append_session_event "gate_eval" "{\"hook\":\"guard\",\"check\":\"test_gate_merge\",\"result\":\"block\",\"reason\":\"tests failing\"}" "$PROJECT_ROOT"
                deny "Cannot merge: tests are failing ($TEST_FAILS failures, ${TEST_AGE}s ago). Fix test failures before merging."
            fi
            if [[ "$TEST_RESULT" != "pass" ]]; then
                append_session_event "gate_eval" "{\"hook\":\"guard\",\"check\":\"test_gate_merge\",\"result\":\"block\",\"reason\":\"tests not passing\"}" "$PROJECT_ROOT"
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
                append_session_event "gate_eval" "{\"hook\":\"guard\",\"check\":\"test_gate_commit\",\"result\":\"block\",\"reason\":\"tests failing\"}" "$PROJECT_ROOT"
                deny "Cannot commit: tests are failing ($TEST_FAILS failures, ${TEST_AGE}s ago). Fix test failures before committing."
            fi
            if [[ "$TEST_RESULT" != "pass" ]]; then
                append_session_event "gate_eval" "{\"hook\":\"guard\",\"check\":\"test_gate_commit\",\"result\":\"block\",\"reason\":\"tests not passing\"}" "$PROJECT_ROOT"
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
#
# Worktree fix: when the worktree's .claude/.proof-status is missing, fall back
# to the orchestrator's CLAUDE_DIR/.proof-status. This handles the case where
# prompt-submit.sh wrote "verified" to the orchestrator's copy (dual-write path).
# The worktree's file takes precedence when both exist.
if echo "$COMMAND" | grep -qE 'git\s+[^|;&]*\b(commit|merge)([^a-zA-Z0-9-]|$)'; then
    if echo "$COMMAND" | grep -qE 'git\s+[^|;&]*\bcommit([^a-zA-Z0-9-]|$)'; then
        PROOF_DIR=$(extract_git_target_dir "$COMMAND")
    else
        PROOF_DIR=$(detect_project_root)
    fi
    if git -C "$PROOF_DIR" rev-parse --git-dir > /dev/null 2>&1 && ! is_claude_meta_repo "$PROOF_DIR"; then
        PROOF_FILE="${PROOF_DIR}/.claude/.proof-status"
        # Fallback: if worktree file is absent, check orchestrator's CLAUDE_DIR
        if [[ ! -f "$PROOF_FILE" ]]; then
            ORCH_PROOF_FILE="$(get_claude_dir)/.proof-status"
            if [[ -f "$ORCH_PROOF_FILE" ]]; then
                PROOF_FILE="$ORCH_PROOF_FILE"
            fi
        fi
        if [[ -f "$PROOF_FILE" ]]; then
            if validate_state_file "$PROOF_FILE" 1; then
                PROOF_STATUS=$(cut -d'|' -f1 "$PROOF_FILE")
            else
                # Corrupt or empty file — treat as "not verified" (fail-closed)
                PROOF_STATUS="corrupt"
            fi
            if [[ "$PROOF_STATUS" != "verified" ]]; then
                append_session_event "gate_eval" "{\"hook\":\"guard\",\"check\":\"proof_gate\",\"result\":\"block\",\"reason\":\"not verified\"}" "$PROOF_DIR"
                deny "Cannot proceed: proof-of-work verification is '$PROOF_STATUS'. The user must see the feature work before committing. Run the verification checkpoint (Phase 4.5) and get user confirmation."
            fi
        fi
        # File missing → no implementation in progress → allow (bootstrap path)
    fi
fi

# Log gate pass for git commands that reached the gates
if echo "$COMMAND" | grep -qE 'git\s+[^|;&]*\b(commit|merge)([^a-zA-Z0-9-]|$)'; then
    PROJECT_ROOT=$(detect_project_root)
    append_session_event "gate_eval" "{\"hook\":\"guard\",\"result\":\"allow\"}" "$PROJECT_ROOT"
fi

# --- Deferred rewrite: emit Path B canary guard if applied and no other check fired ---
# If Path B modified COMMAND in-place but no other check called rewrite()/deny() (both
# exit early), we emit the rewrite here. Checks that DO fire (e.g. Check 5: worktree
# remove) already operate on the already-modified COMMAND, so their rewrites include
# the guard prefix automatically — no double-emission needed.
if [[ "$_CWD_GUARD_APPLIED" == true ]]; then
    rewrite "$COMMAND" "$_CWD_GUARD_REASON"
fi

# All checks passed
_GUARD_COMPLETED=true
exit 0
