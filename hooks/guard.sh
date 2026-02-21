#!/usr/bin/env bash
# @file guard.sh
# @description Sacred practice guardrails for Bash commands. PreToolUse hook
#   (matcher: Bash) that enforces all command-level safety rules: nuclear deny
#   for catastrophic commands, CWD protection for worktree directories, /tmp/
#   redirection to project tmp/, force-push safety, and proof/test gates for
#   commits and merges. All enforcements use deny() — updatedInput is NOT
#   supported in PreToolUse hooks.
set -euo pipefail

# Sacred practice guardrails for Bash commands.
# PreToolUse hook — matcher: Bash
#
# @decision DEC-GUARD-001
# @title Multi-tier command safety gate with deny and CWD protection
# @status accepted
# @rationale Enforces Sacred Practices mechanically via deny (hard blocks).
#   Deny prevents destructive commands (rm -rf /, git reset --hard, commits on main)
#   and unsafe patterns (/tmp/ writes, --force push, worktree CWD hazards).
#   Nuclear deny category blocks catastrophic commands (fork bomb, dd to device,
#   SQL DROP) unconditionally.
#   updatedInput (rewrite) is NOT supported in PreToolUse hooks — only in
#   PermissionRequest hooks — so all "soft fix" behaviors use deny() with a
#   corrected command in the reason string. The model reads the reason and
#   resubmits the corrected command.
#   Check 0.75 denies all cd/pushd into .worktrees/ to prevent posix_spawn ENOENT
#   if the worktree is deleted. Check 5 and 5b deny worktree removal without safe
#   CWD first. Check 0.5 (Path A/B canary recovery) was removed — prevention is
#   the only reliable fix.
#
#   All pattern-matching checks (2-10, 0.75, 5b) use $_stripped_cmd (quoted strings
#   removed) for detection so that commit message content like "fix branch -D handling"
#   does not trigger git-specific checks (fixes Issue #126/#91). Raw $COMMAND is kept
#   for command construction (corrected commands in deny reasons), extract_git_target_dir()
#   calls, and the [[ "$COMMAND" == "( "* ]] subshell check in Check 0.75.
#   Dead code removed: rewrite() (broken updatedInput, Issue #98) and
#   is_same_project() were never called — both removed.
#   Guardian-active detection extracted to is_guardian_active() helper —
#   eliminates copy-pasted loop in Checks 4, 4b, and 5.
#   Check 1 sed replacement uses PROJECT_TMP_ESCAPED so paths containing & or \
#   do not corrupt the sed substitution.
#
# All enforcements use deny (hard blocks):
#   - /tmp/ writes → denied, corrected command uses <PROJECT_ROOT>/tmp/ instead
#   - git push --force → denied, corrected command uses --force-with-lease instead
#   - Main is sacred (no commits on main/master)
#   - No force push to main/master
#   - No destructive git commands (reset --hard, clean -f, branch -D without Guardian + merge check)
#   - cd/pushd into .worktrees/ (use subshell or git -C instead)
#   - git worktree remove without cd to main first
#   - rm -rf .worktrees/ without cd to main first
#
# @decision DEC-INTEGRITY-002
# @title Deny-on-crash EXIT trap for fail-closed behavior
# @status accepted
# @rationale guard.sh previously failed open: if source-lib.sh failed to load,
#   jq was missing, or any command errored under set -euo pipefail, the hook
#   would exit non-zero and Claude Code would silently allow the command through.
#   This meant safety checks could be bypassed by any runtime error. The EXIT
#   trap pattern combined with a completion flag (_GUARD_COMPLETED) flips this
#   to fail-closed: crash = deny. Normal exit paths (deny(), early exits) set
#   the flag to true so the trap is a no-op for them. The trap MUST be installed
#   before source-lib.sh because that is the most common crash point.

# --- Fail-closed crash trap ---
# MUST be set before source-lib.sh — that's the most common failure point.
_GUARD_COMPLETED=false
_guard_deny_on_crash() {
    if [[ "$_GUARD_COMPLETED" != "true" ]]; then
        # During merge on ~/.claude, degrade to allow instead of deny.
        # Prevents deadlock when guard.sh itself has conflicts or runtime
        # errors during merge resolution. Without this, crash-deny +
        # branch-guard.sh creates a circular block where neither Write
        # nor Bash can fix guard.sh.
        local _merge_git_dir
        _merge_git_dir="$(git -C "$HOME/.claude" rev-parse --absolute-git-dir 2>/dev/null || echo "")"
        if [[ -n "$_merge_git_dir" && -f "$_merge_git_dir/MERGE_HEAD" ]]; then
            return  # Degrade to allow — merge deadlock prevention
        fi

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

# Strip quoted strings from COMMAND for pattern-matching detection.
# This prevents commit message content (e.g. "fix branch -D handling") from
# triggering git-specific checks (Issue #126/#91). All downstream checks use
# $_stripped_cmd for grep/pattern detection. Raw $COMMAND is used only for
# command construction (corrected commands in deny reasons) and for
# extract_git_target_dir() calls which need actual path arguments.
# Placed here (after COMMAND extraction, before any checks) so ALL checks share it.
_stripped_cmd=$(echo "$COMMAND" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g")

# Emit PreToolUse deny response with reason, then exit.
# Uses jq for JSON-safe encoding — reason may contain quotes, paths, commands.
deny() {
    local reason="$1"
    local escaped_reason
    escaped_reason=$(printf '%s' "$reason" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": $escaped_reason
  }
}
EOF
    _GUARD_COMPLETED=true
    exit 0
}

# Check if a Guardian agent is currently active (marker files in TRACE_STORE).
# Extracted from copy-pasted blocks in Checks 4, 4b, and 5 to eliminate duplication.
is_guardian_active() {
    local count=0
    for _gm in "${TRACE_STORE}/.active-guardian-"*; do
        [[ -f "$_gm" ]] && count=$(( count + 1 ))
    done
    [[ "$count" -gt 0 ]]
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


# --- Check 0.75: Prevent ALL cd/pushd into worktree directories ---
# @decision DEC-GUARD-CWD-003
# @title Deny ALL cd/pushd into .worktrees/ — both bare and chained
# @status accepted
# @rationale When the Bash tool's CWD points to a .worktrees/ path and that
#   worktree is later deleted, ALL hook spawning fails — not just Bash hooks.
#   posix_spawn returns ENOENT on macOS when the parent process CWD is deleted.
#   The canary approach (Path B, now removed) only recovered PreToolUse:Bash;
#   Edit hooks, Stop hooks, and SessionEnd hooks cannot be recovered because
#   the shell can't start. Prevention is the only reliable fix.
#   updatedInput is NOT supported in PreToolUse hooks — only in PermissionRequest
#   hooks — so rewrite() is a no-op for command safety. We deny with a reason
#   that includes the correct subshell or git -C pattern to use instead.
#   Already-subshell-wrapped commands (starting with "( ") pass through — this
#   is the correct resubmit pattern. The previous "bare cd allowed" exemption is
#   removed: subagents should use git -C or subshell patterns instead, and the
#   canary recovery fallback that justified the exemption no longer exists.

# Pattern: cd/pushd where the DESTINATION ends at a worktree name (no deeper subpath).
# Matches: cd .worktrees/foo, cd /abs/.worktrees/foo, pushd .worktrees/feat-x
# Does NOT match: cd /parent/.worktrees/foo/subdir (path goes deeper inside worktree)
# The [^/[:space:];&|]+ after .worktrees/ requires a non-empty worktree name with no
# further slashes — ensuring we match only the worktree root, not subdirectories within.
# Skip if already subshell-wrapped (model resubmit after previous deny).
# Note: [[ "$COMMAND" == "( "* ]] intentionally uses raw COMMAND (not _stripped_cmd)
# to test actual command structure — not quoted-string-stripped content.
if [[ "$COMMAND" == "( "* ]]; then
    : # Already subshell-wrapped, pass through
elif echo "$_stripped_cmd" | grep -qE '\b(cd|pushd)\b[^;&|]*\.worktrees/[^/[:space:];&|]+([[:space:]]|$|&&|;|\|\|)'; then
    log_info "GUARD-CWD" "Check 0.75: Denying ALL cd/pushd into .worktrees/"
    deny "CWD protection: cd/pushd into .worktrees/ denied — persistent CWD in a deletable directory causes posix_spawn ENOENT if the worktree is later removed, bricking ALL hooks. Use per-command subshell: ( cd .worktrees/<name> && <cmd> ) or git -C .worktrees/<name> for git commands."
fi

# --- Check 1: /tmp/ and /private/tmp/ writes → deny, redirect to project tmp/ ---
# On macOS, /tmp → /private/tmp (symlink). Both forms must be caught.
# Allow: /private/tmp/claude-*/ (Claude Code scratchpad)
# updatedInput is NOT supported in PreToolUse hooks — deny with corrected command.
TMP_PATTERN='(>|>>|mv\s+.*|cp\s+.*|tee)\s*(/private)?/tmp/|mkdir\s+(-p\s+)?(/private)?/tmp/'
if echo "$_stripped_cmd" | grep -qE "$TMP_PATTERN"; then
    if echo "$COMMAND" | grep -q '/private/tmp/claude-'; then
        : # Claude scratchpad — allowed as-is
    else
        # Build corrected command: replace /tmp/ with <PROJECT_ROOT>/tmp/
        # Escape PROJECT_TMP so & and \ in the path don't corrupt sed substitution.
        PROJECT_ROOT=$(detect_project_root)
        PROJECT_TMP="$PROJECT_ROOT/tmp"
        PROJECT_TMP_ESCAPED=$(printf '%s\n' "$PROJECT_TMP" | sed 's/[&/\]/\\&/g')
        CORRECTED=$(echo "$COMMAND" | sed "s|/private/tmp/|/tmp/|g" | sed "s|/tmp/|$PROJECT_TMP_ESCAPED/|g")
        CORRECTED="mkdir -p $PROJECT_TMP && $CORRECTED"
        deny "Sacred Practice #3: use project tmp/ instead of /tmp/. Run instead: $CORRECTED"
    fi
fi

# --- Check 9: Block agents from writing verified to .proof-status ---
# Only prompt-submit.sh (user-triggered) can write verified status.
# This prevents any agent from bypassing the human verification gate.
# Must be before the early-exit gate since this is not a git command.
# Two conditions: (1) command structurally writes to .proof-status (redirect
# target outside quotes), AND (2) "verified" appears anywhere in the command.
# This avoids false-positives on commit messages that mention both keywords.
# Uses $_stripped_cmd for the redirect detection (structural write check).
if echo "$_stripped_cmd" | grep -qE '(>|>>|tee)\s*\S*proof-status' && echo "$COMMAND" | grep -qiE 'verified|approved?|lgtm|looks.good|ship.it'; then
    deny "Cannot write approval status to .proof-status directly. Only the user can verify proof-of-work (via prompt-submit.sh). Present the verification report and let the user respond naturally."
fi

# --- Check 10: Block deletion of .proof-status when verification active ---
# Prevents agents from bypassing the gate by deleting the file.
# Only blocks when status is pending or needs-verification (gate is active).
# Verified status can be cleaned up freely.
# Uses $_stripped_cmd for the rm detection.
if echo "$_stripped_cmd" | grep -qE 'rm\s+(-[a-zA-Z]*\s+)*\S*proof-status'; then
    _ps_dir=$(get_claude_dir)
    _ps_phash=$(project_hash "$(detect_project_root)")
    # Check scoped file first, fall back to legacy
    _ps_file="${_ps_dir}/.proof-status-${_ps_phash}"
    if [[ ! -f "$_ps_file" ]]; then
        _ps_file="${_ps_dir}/.proof-status"
    fi
    if [[ -f "$_ps_file" ]]; then
        _ps_val=$(cut -d'|' -f1 "$_ps_file")
        if [[ "$_ps_val" == "pending" || "$_ps_val" == "needs-verification" ]]; then
            deny "Cannot delete .proof-status while verification is active (status: $_ps_val). Complete the verification flow first."
        fi
    fi
fi

# --- Check 5b: rm -rf .worktrees/ CWD safety deny ---
# Same death-spiral prevention as Check 5 (git worktree remove), but for direct
# rm commands that bypass git worktree remove entirely (e.g. rm -rf .worktrees/).
# Must run BEFORE the early-exit gate which skips all non-git commands.
#
# @decision DEC-GUARD-002
# @title Two-tier worktree CWD safety: git worktree remove + raw rm — deny pattern
# @status accepted
# @rationale Check 5 only catches `git worktree remove`. The death spiral also
# occurs when the agent runs `rm -rf .worktrees/` directly, or when
# worktree-roster.sh cleanup falls through to rm -rf internally. This check
# intercepts rm with recursive+force targeting any .worktrees/ path and denies
# with the correct safe command (cd to main worktree first). rewrite() is NOT
# used because updatedInput is not supported in PreToolUse hooks — it silently
# fails. deny() with the corrected command in the reason is the only reliable fix.
if echo "$_stripped_cmd" | grep -qE 'rm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+){1,2}.*\.worktrees/|rm\s+(-[a-zA-Z]*r[a-zA-Z]*\s+|--recursive\s+).*\.worktrees/'; then
    WT_TARGET=$(echo "$COMMAND" | grep -oE '[^[:space:]]*\.worktrees/[^[:space:];&|]*' | head -1)
    if [[ -n "$WT_TARGET" ]]; then
        MAIN_WT=$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1 || echo "")
        MAIN_WT="${MAIN_WT:-$(detect_project_root)}"
        deny "CWD safety: removing worktree directory requires safe CWD first. Run: cd \"$MAIN_WT\" && $COMMAND"
    fi
fi

# --- Early-exit gate: skip git-specific checks for non-git commands ---
# Uses $_stripped_cmd (computed above). The gate checks whether `git` appears
# in a command position (start, or after && || | ;) — after quote-stripping so
# commit message content does not falsely keep the exit gate open.
if ! echo "$_stripped_cmd" | grep -qE '(^|&&|\|\|?|;)\s*git\s'; then
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

# --- Check 2: Main is sacred (no commits on main/master) ---
# Exceptions:
#   - MASTER_PLAN.md only commits (planning documents per Core Dogma)
#   - Merge commits (MERGE_HEAD present — landing feature branches via git merge)
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bcommit([^a-zA-Z0-9-]|$)'; then
    TARGET_DIR=$(extract_git_target_dir "$COMMAND")
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

# --- Check 3: Force push handling ---
# updatedInput is NOT supported in PreToolUse hooks — deny with corrected command.
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bpush\s+.*(-f|--force)\b'; then
    # Hard block: force push to main/master
    if echo "$_stripped_cmd" | grep -qE '(origin|upstream)\s+(main|master)\b'; then
        deny "Cannot force push to main/master. This is a destructive action that rewrites shared history."
    fi
    # Soft deny: --force should be --force-with-lease (safer, won't clobber remote changes)
    if ! echo "$_stripped_cmd" | grep -qE '\-\-force-with-lease'; then
        # Use perl for word-boundary support (macOS sed lacks \b). Correction built from raw COMMAND.
        CORRECTED=$(echo "$COMMAND" | perl -pe 's/--force(?!-with-lease)/--force-with-lease/g; s/\s-f\s/ --force-with-lease /g')
        deny "Use --force-with-lease instead of --force to avoid clobbering remote changes. Run instead: $CORRECTED"
    fi
fi

# --- Check 4: No destructive git commands (hard blocks) ---
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\breset\s+--hard'; then
    deny "git reset --hard is destructive and discards uncommitted work. Use git stash or create a backup branch first."
fi

if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bclean\s+.*-f'; then
    deny "git clean -f permanently deletes untracked files. Use git clean -n (dry run) first to see what would be deleted."
fi

if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bbranch\s+(-D\b|.*\s-D\b|.*--delete\s+--force|.*--force\s+--delete)'; then
    # @decision DEC-GUARD-BRANCH-D-001
    # @title Conditional git branch -D: Guardian-only with merge verification
    # @status accepted
    # @rationale Guardian needs git branch -D to clean up branches after merging.
    #   Previously Check 4 hard-denied -D for ALL callers, forcing Guardian to ask
    #   the user to run cleanup manually every time. Now: non-Guardian callers still
    #   get a hard deny (unchanged behavior). Guardian callers get -D only if the
    #   branch is fully merged into HEAD — verified with git branch --merged, which
    #   is the same check git branch -d uses internally. If unmerged, the deny
    #   message names the specific branch so the user can inspect before deciding.
    #   Branch name extraction handles: git branch -D name, git -C dir branch -D name,
    #   git branch --delete --force name, git branch --force --delete name.
    if ! is_guardian_active; then
        deny "git branch -D / --delete --force force-deletes a branch even if unmerged. Use git branch -d (lowercase) for safe deletion."
    fi
    # Guardian is active — extract branch name and verify it is merged into HEAD.
    # Extraction: strip git flags/options to find the branch name argument.
    # Handles: git branch -D <name>, git -C <dir> branch -D <name>,
    #          git branch --delete --force <name>, git branch --force --delete <name>
    _BRANCH_NAME=$(echo "$COMMAND" | \
        sed 's/git[[:space:]]\{1,\}-C[[:space:]]\{1,\}[^[:space:]]\{1,\}[[:space:]]\{1,\}/git /' | \
        grep -oE 'branch .+' | \
        sed 's/^branch[[:space:]]*//' | \
        sed 's/--delete//g; s/--force//g; s/-D[[:space:]]//g; s/^-D$//g; s/-f[[:space:]]//g' | \
        tr -s ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | \
        awk '{print $1}')
    if [[ -z "$_BRANCH_NAME" ]]; then
        deny "Cannot parse branch name from: $COMMAND — refusing -D as a precaution."
    fi
    # Resolve repo dir for the merge check (respect git -C if present)
    _MERGE_CHECK_DIR=$(extract_git_target_dir "$COMMAND")
    if [[ -z "$_MERGE_CHECK_DIR" ]]; then
        _MERGE_CHECK_DIR="."
    fi
    # Check if the branch is fully merged into HEAD
    if ! git -C "$_MERGE_CHECK_DIR" branch --merged HEAD 2>/dev/null | grep -qE "(^|[[:space:]])${_BRANCH_NAME}$"; then
        deny "Branch '${_BRANCH_NAME}' has unmerged commits — cannot force-delete even for Guardian. Merge or cherry-pick first, or delete manually after inspecting."
    fi
    # Branch is merged — allow Guardian to proceed
fi

# --- Check 4b: Branch deletion requires Guardian context ---
# git branch -D is handled by Check 4 (Guardian + merge-verified path above).
# This gates git branch -d (lowercase, safe delete) to require an active Guardian
# agent. Prevents orchestrator from bulk-deleting branches without Guardian oversight.
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bbranch\s+.*-d\b'; then
    # Skip if already handled by Check 4 (-D / --delete --force patterns)
    if ! echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bbranch\s+(-D\b|.*\s-D\b|.*--delete\s+--force|.*--force\s+--delete)'; then
        if ! is_guardian_active; then
            deny "Cannot delete branches outside Guardian context. Dispatch Guardian for branch management (Sacred Practice #8)."
        fi
    fi
fi

# --- Check 5: Worktree removal CWD safety deny ---
# @decision DEC-GUARD-CHECK5-001
# @title Use extract_git_target_dir + git -C for worktree removal — deny pattern
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
#   rewrite() is NOT used because updatedInput is not supported in PreToolUse hooks
#   — it silently fails. deny() with the corrected command in the reason is the
#   only reliable fix.
if echo "$_stripped_cmd" | grep -qE 'git[[:space:]]+[^|;&]*worktree[[:space:]]+remove'; then
    # Deny --force worktree removal outside Guardian (dirty worktrees need oversight)
    if echo "$_stripped_cmd" | grep -qE 'worktree[[:space:]]+remove[[:space:]].*--force|worktree[[:space:]]+remove[[:space:]]+--force'; then
        if ! is_guardian_active; then
            deny "Cannot force-remove worktrees outside Guardian context. Dirty worktrees may contain uncommitted work. Dispatch Guardian for worktree cleanup."
        fi
    fi
    CHECK5_DIR=$(extract_git_target_dir "$COMMAND")
    MAIN_WT=$(git -C "$CHECK5_DIR" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1 || echo "")
    MAIN_WT="${MAIN_WT:-$CHECK5_DIR}"
    deny "CWD safety: worktree removal requires safe CWD first. Run: cd \"$MAIN_WT\" && $COMMAND"
fi

# --- Check 6: Test status gate for merge commands ---
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bmerge([^a-zA-Z0-9-]|$)'; then
    PROJECT_ROOT=$(detect_project_root)
    if git -C "$PROJECT_ROOT" rev-parse --git-dir > /dev/null 2>&1; then
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
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bcommit([^a-zA-Z0-9-]|$)'; then
    PROJECT_ROOT=$(extract_git_target_dir "$COMMAND")
    if git -C "$PROJECT_ROOT" rev-parse --git-dir > /dev/null 2>&1; then
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
#
# Worktree fix: when the worktree's .claude/.proof-status is missing, fall back
# to the orchestrator's CLAUDE_DIR/.proof-status. This handles the case where
# prompt-submit.sh wrote "verified" to the orchestrator's copy (dual-write path).
# The worktree's file takes precedence when both exist.
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\b(commit|merge)([^a-zA-Z0-9-]|$)'; then
    if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bcommit([^a-zA-Z0-9-]|$)'; then
        PROOF_DIR=$(extract_git_target_dir "$COMMAND")
    else
        PROOF_DIR=$(detect_project_root)
    fi
    if git -C "$PROOF_DIR" rev-parse --git-dir > /dev/null 2>&1; then
        # DEC-PROOF-PATH-003: use get_claude_dir()-style logic to avoid double-nesting
        # when PROOF_DIR is ~/.claude (meta-repo). ${HOME}/.claude/.claude/ never exists.
        # DEC-ISOLATION-005: project-scoped fallback chain for proof-status lookup.
        # Priority: worktree path > orch scoped > orch legacy (for backward compat).
        _proof_dir_phash=$(project_hash "$PROOF_DIR")
        _orch_claude_dir=$(get_claude_dir)
        if [[ "$PROOF_DIR" == "${HOME}/.claude" ]]; then
            PROOF_FILE="${PROOF_DIR}/.proof-status-${_proof_dir_phash}"
            [[ -f "$PROOF_FILE" ]] || PROOF_FILE="${PROOF_DIR}/.proof-status"
        else
            PROOF_FILE="${PROOF_DIR}/.claude/.proof-status"
        fi
        # Fallback chain: orch scoped → orch legacy
        if [[ ! -f "$PROOF_FILE" ]]; then
            ORCH_SCOPED_FILE="${_orch_claude_dir}/.proof-status-${_proof_dir_phash}"
            ORCH_FILE="${_orch_claude_dir}/.proof-status"
            if [[ -f "$ORCH_SCOPED_FILE" ]]; then
                PROOF_FILE="$ORCH_SCOPED_FILE"
            elif [[ -f "$ORCH_FILE" ]]; then
                PROOF_FILE="$ORCH_FILE"
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
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\b(commit|merge)([^a-zA-Z0-9-]|$)'; then
    PROJECT_ROOT=$(detect_project_root)
    append_session_event "gate_eval" "{\"hook\":\"guard\",\"result\":\"allow\"}" "$PROJECT_ROOT"
fi

# All checks passed
_GUARD_COMPLETED=true
exit 0
