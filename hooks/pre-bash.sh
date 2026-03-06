#!/usr/bin/env bash
# Consolidated PreToolUse:Bash hook — replaces 2 individual hooks.
# Merges guard.sh (ALL safety checks) + doc-freshness.sh into a single process.
# auto-review.sh is pruned (Phase 2) — low-signal command classification engine.
#
# Replaces (in order of execution):
#   1. guard.sh        — ALL safety guardrails (PRESERVED IN FULL — essential)
#   2. doc-freshness.sh — doc freshness enforcement on git commit/merge
#
# Pruned (Phase 2):
#   - auto-review.sh  — 925-line command classification engine; all safety-critical
#     denials already handled by guard.sh; advisories are low signal
#
# @decision DEC-CONSOLIDATE-003
# @title Merge guard.sh + doc-freshness.sh into pre-bash.sh; prune auto-review.sh
# @status accepted
# @rationale Each PreToolUse:Bash hook independently re-sourced source-lib.sh →
#   log.sh → context-lib.sh, adding 60-160ms overhead. With 3 hooks firing on every
#   Bash command, that was 180-480ms per command. Merging to one process with one
#   library load reduces to ~60ms. guard.sh's fail-closed crash trap is installed
#   BEFORE source-lib.sh (the most common failure point) — this ordering must be
#   preserved. auto-review.sh's advisories ("auto-review risk: '#' is not in the
#   known command database") are low signal; guard.sh already handles all safety
#   denials. Removing it eliminates 33% of pre-bash overhead and noise.
#
# @decision DEC-INTEGRITY-002
# @title Deny-on-crash EXIT trap for fail-closed behavior
# @status accepted (carried forward from guard.sh)
# @rationale If source-lib.sh fails to load, jq is missing, or any command errors
#   under set -euo pipefail, the hook must fail-closed (deny) not fail-open (allow).
#   The EXIT trap combined with _HOOK_COMPLETED flag implements this. During a
#   merge on ~/.claude, degrade to allow to prevent deadlock when guard.sh itself
#   has conflicts or runtime errors during merge resolution.
#   The INLINE trap (before source-lib.sh) catches library-load failures.
#   enable_fail_closed() (after source-lib.sh) replaces it with the canonical
#   implementation from core-lib.sh that uses _hook_crash_deny().

set -euo pipefail

# --- Fail-closed crash trap (INLINE — must be set BEFORE source-lib.sh) ---
# This fires if source-lib.sh fails to load or any early command errors.
# enable_fail_closed() below replaces this after the library loads.
_HOOK_COMPLETED=false
_hook_preload_crash() {
    if [[ "$_HOOK_COMPLETED" != "true" ]]; then
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
    "permissionDecisionReason": "SAFETY: pre-bash.sh crashed before completing safety checks. Command denied as precaution. Run: bash -n ~/.claude/hooks/pre-bash.sh to diagnose."
  }
}
CRASHJSON
    fi
}
trap '_hook_preload_crash' EXIT

# Pre-set hook identity before source-lib.sh auto-detection.
# BASH_SOURCE[1] in source-lib.sh resolves inconsistently for consolidated hooks
# depending on call depth. Setting these here guarantees correct timing log entries.
_HOOK_NAME="pre-bash"
_HOOK_EVENT_TYPE="PreToolUse:Bash"


source "$(dirname "$0")/source-lib.sh"

# Replace inline trap with canonical fail-closed trap from core-lib.sh
enable_fail_closed "pre-bash"

# Lazy-load domain libraries needed by pre-bash.sh gates.
# require_session: append_session_event, read_test_status — first used in Check 6/7/8 (git-specific).
# Deferred to after the git-early-exit gate so non-git commands do not pay session-lib parse cost.
# require_doc is loaded just before the doc-freshness section (avoids loading
# it for the common case where a non-git command early-exits at the git gate).

# In scan mode: emit all gate declarations and exit cleanly BEFORE reading stdin.
# Hooks are invoked with < /dev/null in scan mode, so stdin is empty.
# This block MUST be before read_input() to avoid early-exit on empty COMMAND.
if [[ "${HOOK_GATE_SCAN:-}" == "1" ]]; then
    declare_gate "nuclear-deny" "Nuclear command hard deny (7 categories)" "deny"
    declare_gate "worktree-cd-guard" "Deny ALL cd/pushd into .worktrees/" "deny"
    declare_gate "tmp-redirect" "Redirect /tmp/ writes to project tmp/" "deny"
    declare_gate "proof-status-write" "Block agents writing verified to .proof-status" "deny"
    declare_gate "proof-status-delete" "Block deletion of .proof-status when active" "deny"
    declare_gate "worktree-rf-cwd" "rm -rf .worktrees/ CWD safety deny" "deny"
    declare_gate "git-early-exit" "Skip git-specific checks for non-git commands" "side-effect"
    declare_gate "main-sacred-commit" "No commits on main/master" "deny"
    declare_gate "force-push-safety" "Force push handling" "deny"
    declare_gate "ci-local-gate" "Local CI pre-push validation" "deny"
    declare_gate "destructive-git" "No destructive git commands" "deny"
    declare_gate "branch-delete-guardian" "Branch deletion requires Guardian context" "deny"
    declare_gate "worktree-removal-cwd" "Worktree removal CWD safety deny" "deny"
    declare_gate "merge-test-gate" "Test status gate for merge commands" "deny"
    declare_gate "commit-test-gate" "Test status gate for commit commands" "deny"
    declare_gate "proof-gate" "Proof-of-work verification gate" "deny"
    declare_gate "doc-freshness" "Documentation freshness enforcement on commit/merge" "advisory"
    _HOOK_COMPLETED=true
    exit 0
fi

HOOK_INPUT=$(read_input)
COMMAND=$(get_field '.tool_input.command')
# CWD from the hook input JSON — used by CWD-safety checks
CWD=$(get_field '.cwd')

# Exit silently if no command
if [[ -z "$COMMAND" ]]; then
    _HOOK_COMPLETED=true
    exit 0
fi

# Strip quoted strings AND bash comments from COMMAND for pattern-matching.
# Quoted strings removed first (Issue #126), then comments stripped (Issue #133).
# Prevents comment text from triggering git-specific checks (e.g., a comment
# mentioning "git commit" must not cause Check 2 to deny a read-only command).
# All downstream checks use $_stripped_cmd for grep/pattern detection.
# Raw $COMMAND used only for command construction and extract_git_target_dir().
#
# @decision DEC-GUARD-002
# @title Strip bash comments from _stripped_cmd to prevent false-positive pattern matches
# @status accepted
# @rationale Agents prefix commands with descriptive # comments. Without stripping,
#   comment text like "# mentions git commit" would match Check 2 and deny the command.
#   Two-pass strip: (1) remove full comment lines, (2) remove inline comments.
#   Applied after quote-stripping so quoted # chars are already gone.
_stripped_cmd=$(echo "$COMMAND" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g" | sed -E '/^[[:space:]]*#/d; s/[[:space:]]#.*$//')

# Check if a Guardian agent is currently active (marker files in TRACE_STORE).
is_guardian_active() {
    local count=0
    for _gm in "${TRACE_STORE:-$HOME/.claude/traces}/.active-guardian-"*; do
        [[ -f "$_gm" ]] && count=$(( count + 1 ))
    done
    [[ "$count" -gt 0 ]]
}

# =============================================================================
# GUARD.SH SECTION — ALL safety checks preserved in full
# @decision DEC-GUARD-001 (carried forward from guard.sh)
# =============================================================================

# --- Check 0: Nuclear command hard deny ---
declare_gate "nuclear-deny" "Nuclear command hard deny (7 categories)" "deny"

# Category 1: Filesystem destruction
if echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*|-[a-zA-Z]*f[a-zA-Z]*r[a-zA-Z]*)\s+(/|~|/home|/Users)\s*$' || \
   echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*|-[a-zA-Z]*f[a-zA-Z]*r[a-zA-Z]*)\s+/\*'; then
    emit_deny "NUCLEAR DENY — Filesystem destruction blocked. This command would recursively delete critical system or user directories."
fi

# Category 2: Disk/device destruction
if echo "$COMMAND" | grep -qE 'dd\s+.*of=/dev/' || \
   echo "$COMMAND" | grep -qE '>\s*/dev/(sd|disk|nvme|vd|hd)' || \
   echo "$COMMAND" | grep -qE '\bmkfs\b'; then
    emit_deny "NUCLEAR DENY — Disk/device destruction blocked. This command would overwrite or format a storage device."
fi

# Category 3: Fork bomb
if echo "$COMMAND" | grep -qF ':(){ :|:& };:'; then
    emit_deny "NUCLEAR DENY — Fork bomb blocked. This command would exhaust system resources via infinite process spawning."
fi

# Category 4: Recursive permission destruction on root
if echo "$COMMAND" | grep -qE 'chmod\s+(-[a-zA-Z]*R[a-zA-Z]*\s+)?777\s+/' || \
   echo "$COMMAND" | grep -qE 'chmod\s+777\s+/'; then
    emit_deny "NUCLEAR DENY — Recursive permission destruction blocked. chmod 777 on root compromises system security."
fi

# Category 5: System shutdown/reboot
if echo "$COMMAND" | grep -qE '(^|&&|\|\|?|;)\s*(sudo\s+)?(shutdown|reboot|halt|poweroff)\b' || \
   echo "$COMMAND" | grep -qE '(^|&&|\|\|?|;)\s*(sudo\s+)?init\s+[06]\b'; then
    emit_deny "NUCLEAR DENY — System shutdown/reboot blocked. This command would halt or restart the machine."
fi

# Category 6: Remote code execution (pipe to shell)
if echo "$COMMAND" | grep -qE '(curl|wget)\s+.*\|\s*(bash|sh|zsh|python|perl|ruby|node)\b'; then
    emit_deny "NUCLEAR DENY — Remote code execution blocked. Piping downloaded content directly to a shell interpreter is unsafe. Download first, inspect, then execute."
fi

# Category 7: SQL database destruction
if echo "$COMMAND" | grep -qiE '\b(DROP\s+(DATABASE|TABLE|SCHEMA)|TRUNCATE\s+TABLE)\b'; then
    emit_deny "NUCLEAR DENY — SQL database destruction blocked. DROP/TRUNCATE operations permanently destroy data."
fi

# --- Check 0.75: Prevent ALL cd/pushd into worktree directories ---
# @decision DEC-GUARD-CWD-003 (carried forward from guard.sh)
# @title Deny ALL cd/pushd into .worktrees/ — both bare and chained
# @status accepted
# @rationale posix_spawn ENOENT if worktree is deleted while CWD is inside it.
#   Prevention is the only reliable fix — updatedInput is not supported in PreToolUse.
declare_gate "worktree-cd-guard" "Deny ALL cd/pushd into .worktrees/" "deny"
if [[ "$COMMAND" == "( "* ]]; then
    : # Already subshell-wrapped, pass through
elif echo "$_stripped_cmd" | grep -qE '\b(cd|pushd)\b[^;&|]*\.worktrees/[^/[:space:];&|]+([[:space:]]|$|&&|;|\|\|)'; then
    log_info "GUARD-CWD" "Check 0.75: Denying ALL cd/pushd into .worktrees/"
    emit_deny "CWD protection: cd/pushd into .worktrees/ denied — persistent CWD in a deletable directory causes posix_spawn ENOENT if the worktree is later removed, bricking ALL hooks. Use per-command subshell: ( cd .worktrees/<name> && <cmd> ) or git -C .worktrees/<name> for git commands."
fi

# --- Check 1: /tmp/ and /private/tmp/ writes → deny, redirect to project tmp/ ---
declare_gate "tmp-redirect" "Redirect /tmp/ writes to project tmp/" "deny"
TMP_PATTERN='(>|>>|mv\s+.*|cp\s+.*|tee)\s*(/private)?/tmp/|mkdir\s+(-p\s+)?(/private)?/tmp/'
if echo "$_stripped_cmd" | grep -qE "$TMP_PATTERN"; then
    if echo "$COMMAND" | grep -q '/private/tmp/claude-'; then
        : # Claude scratchpad — allowed as-is
    else
        PROJECT_ROOT=$(detect_project_root)
        PROJECT_TMP="$PROJECT_ROOT/tmp"
        PROJECT_TMP_ESCAPED=$(printf '%s\n' "$PROJECT_TMP" | sed 's/[&/\]/\\&/g')
        CORRECTED=$(echo "$COMMAND" | sed "s|/private/tmp/|/tmp/|g" | sed "s|/tmp/|$PROJECT_TMP_ESCAPED/|g")
        CORRECTED="mkdir -p $PROJECT_TMP && $CORRECTED"
        emit_deny "Sacred Practice #3: use project tmp/ instead of /tmp/. Run instead: $CORRECTED"
    fi
fi

# --- Check 9: Block agents from writing verified to .proof-status ---
# @decision DEC-STATE-REGISTRY-002
# @title Checks 9+10 adopt is_protected_state_file() registry
# @status accepted
# @rationale Inline pattern matching (*proof-status*) would require updating both
#   Check 9 and Check 10 whenever a new protected state file is added. Routing
#   through is_protected_state_file() (registry in core-lib.sh) means adding a new
#   file to _PROTECTED_STATE_FILES is sufficient. Fallback inline grep is retained
#   for cases where the target cannot be extracted from the command string.
declare_gate "proof-status-write" "Block agents writing verified to .proof-status" "deny"
_redir_target=$(echo "$_stripped_cmd" | grep -oE '(>|>>|tee)\s*\S+' | grep -oE '\S+$' || true)
_c9_protected=false
if [[ -n "$_redir_target" ]] && { is_protected_state_file "$_redir_target" 2>/dev/null || echo "$_stripped_cmd" | grep -qE '(>|>>|tee)\s*\S*proof-status'; }; then
    # Registry hit (or fallback pattern match): redirect targets a protected file
    _c9_protected=true
elif [[ -z "$_redir_target" ]] && echo "$_stripped_cmd" | grep -qE '(>|>>|tee)\s*\S*proof-status'; then
    # Could not extract target — fallback to original inline pattern
    _c9_protected=true
fi
if [[ "$_c9_protected" == "true" ]] && echo "$COMMAND" | grep -qiE 'verified|approved?|lgtm|looks.good|ship.it'; then
    emit_deny "Cannot write approval status to .proof-status directly. Only the user can verify proof-of-work (via prompt-submit.sh). Present the verification report and let the user respond naturally."
fi

# --- Check 10: Block deletion of .proof-status when verification active ---
declare_gate "proof-status-delete" "Block deletion of .proof-status when active" "deny"
_rm_target=$(echo "$_stripped_cmd" | grep -oE 'rm\s+(-[a-zA-Z]*\s+)*\S+' | grep -oE '\S+$' || true)
_c10_matches=false
if [[ -n "$_rm_target" ]] && { is_protected_state_file "$_rm_target" 2>/dev/null || echo "$_stripped_cmd" | grep -qE 'rm\s+(-[a-zA-Z]*\s+)*\S*proof-status'; }; then
    _c10_matches=true
elif [[ -z "$_rm_target" ]] && echo "$_stripped_cmd" | grep -qE 'rm\s+(-[a-zA-Z]*\s+)*\S*proof-status'; then
    _c10_matches=true
fi
if [[ "$_c10_matches" == "true" ]]; then
    _ps_phash=$(project_hash "$(detect_project_root)")
    _ps_dir=$(get_claude_dir)
    _ps_file="${_ps_dir}/.proof-status-${_ps_phash}"
    if [[ -f "$_ps_file" ]]; then
        _ps_val=$(cut -d'|' -f1 "$_ps_file")
        if [[ "$_ps_val" == "pending" || "$_ps_val" == "needs-verification" ]]; then
            # @decision DEC-PROOF-DELETE-SOFTEN-001
            # @title Allow .proof-status deletion when no current-session agents active
            # @status accepted
            # @rationale Stale .proof-status from crashed sessions created a deadlock:
            #   can't dispatch Guardian (proof pending), can't delete (Check 10 blocks).
            #   Now only blocks deletion when a current-session agent is actually active.
            _current_sid="${CLAUDE_SESSION_ID:-}"
            _has_current_agent=false
            if [[ -n "$_current_sid" ]]; then
                for _am in "${TRACE_STORE:-$HOME/.claude/traces}/.active-"*"-${_current_sid}-${_ps_phash}"; do
                    [[ -f "$_am" ]] && { _has_current_agent=true; break; }
                done
            else
                _has_current_agent=true  # conservative fallback
            fi
            if [[ "$_has_current_agent" == "true" ]]; then
                emit_deny "Cannot delete .proof-status while verification is active (status: $_ps_val). Complete the verification flow first."
            fi
        fi
    fi
fi

# --- Check 5b: rm -rf .worktrees/ CWD safety deny ---
# @decision DEC-GUARD-002 (carried forward from guard.sh)
# @title Two-tier worktree CWD safety: conditional deny for rm -rf .worktrees/
# @status accepted
declare_gate "worktree-rf-cwd" "rm -rf .worktrees/ CWD safety deny" "deny"
if echo "$_stripped_cmd" | grep -qE 'rm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+){1,2}.*\.worktrees/|rm\s+(-[a-zA-Z]*r[a-zA-Z]*\s+|--recursive\s+).*\.worktrees/'; then
    WT_TARGET=$(echo "$COMMAND" | grep -oE '[^[:space:]]*\.worktrees/[^[:space:];&|]*' | head -1)
    if [[ -n "$WT_TARGET" ]]; then
        if [[ "$CWD" == *"/.worktrees/"* ]]; then
            MAIN_WT=$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1 || echo "")
            MAIN_WT="${MAIN_WT:-$(detect_project_root)}"
            emit_deny "CWD safety: removing worktree directory requires safe CWD first. Run: cd \"$MAIN_WT\" && $COMMAND"
        fi
    fi
fi

# --- Early-exit gate: skip git-specific checks for non-git commands ---
declare_gate "git-early-exit" "Skip git-specific checks for non-git commands" "side-effect"
if ! echo "$_stripped_cmd" | grep -qE '(^|&&|\|\|?|;)\s*git\s'; then
    # Run doc-freshness for non-git commands? No — doc-freshness only fires on commit/merge.
    # Since this is not a git command, skip doc-freshness too.
    _HOOK_COMPLETED=true
    exit 0
fi

# Load session library now — only reached for git commands.
# Deferred from top-of-file: non-git commands exit above without paying session-lib parse cost.
require_session

# --- Helper: extract git target directory from command text ---
extract_git_target_dir() {
    local cmd="$1"
    if [[ "$cmd" =~ cd[[:space:]]+(\"([^\"]+)\"|\'([^\']+)\'|([^[:space:]\&\;]+)) ]]; then
        local dir="${BASH_REMATCH[2]:-${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}}"
        if [[ -n "$dir" && -d "$dir" ]]; then
            echo "$dir"; return
        fi
    fi
    if [[ "$cmd" =~ git[[:space:]]+-C[[:space:]]+(\"([^\"]+)\"|\'([^\']+)\'|([^[:space:]]+)) ]]; then
        local dir="${BASH_REMATCH[2]:-${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}}"
        if [[ -n "$dir" && -d "$dir" ]]; then
            echo "$dir"; return
        fi
    fi
    local input_cwd
    input_cwd=$(get_field '.cwd' 2>/dev/null)
    if [[ -n "$input_cwd" && -d "$input_cwd" ]]; then
        echo "$input_cwd"; return
    fi
    detect_project_root
}

# --- Check 2: Main is sacred (no commits on main/master) ---
declare_gate "main-sacred-commit" "No commits on main/master" "deny"
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bcommit([^a-zA-Z0-9-]|$)'; then
    TARGET_DIR=$(extract_git_target_dir "$COMMAND")
    CURRENT_BRANCH=$(git -C "$TARGET_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
        STAGED_FILES=$(git -C "$TARGET_DIR" diff --cached --name-only 2>/dev/null || echo "")
        if [[ "$STAGED_FILES" == "MASTER_PLAN.md" ]]; then
            # Allow ONLY for bootstrap — MASTER_PLAN.md not yet committed.
            # Use ls-tree HEAD (not ls-files) because git add has already staged the file
            # at this point, making ls-files report it as "tracked" even on first commit.
            if git -C "$TARGET_DIR" ls-tree HEAD -- MASTER_PLAN.md &>/dev/null; then
                emit_deny "MASTER_PLAN.md is already tracked. Amend it in a worktree, not on main. Create a worktree: git worktree add .worktrees/feature-name -b feature/name"
            fi
            # else: not tracked yet = bootstrap, allow through
        elif GIT_DIR=$(git -C "$TARGET_DIR" rev-parse --absolute-git-dir 2>/dev/null) && [[ -f "$GIT_DIR/MERGE_HEAD" ]]; then
            : # Allow — completing a merge
        else
            emit_deny "Cannot commit directly to $CURRENT_BRANCH. Sacred Practice #2: Main is sacred. Create a worktree: git worktree add .worktrees/feature-name $CURRENT_BRANCH"
        fi
    fi
fi

# --- Check 3: Force push handling ---
declare_gate "force-push-safety" "Force push handling" "deny"
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bpush\s+.*(-f|--force)\b'; then
    if echo "$_stripped_cmd" | grep -qE '(origin|upstream)\s+(main|master)\b'; then
        emit_deny "Cannot force push to main/master. This is a destructive action that rewrites shared history."
    fi
    if ! echo "$_stripped_cmd" | grep -qE '\-\-force-with-lease'; then
        CORRECTED=$(echo "$COMMAND" | perl -pe 's/--force(?!-with-lease)/--force-with-lease/g; s/\s-f\s/ --force-with-lease /g')
        emit_deny "Use --force-with-lease instead of --force to avoid clobbering remote changes. Run instead: $CORRECTED"
    fi
fi

# --- Check 3b: Local CI pre-push validation gate ---
# @decision DEC-CI-001
# @title Pre-push local CI gate in pre-bash.sh
# @status accepted
# @rationale Running CI locally before pushing catches environment-specific failures
#   before they hit the remote CI pipeline. The gate only fires when a local CI
#   script exists (convention-based discovery via find_local_ci), avoiding false
#   positives for projects without local CI. Force pushes are skipped (already
#   handled by Check 3). A 120s timeout prevents the gate from blocking indefinitely.
#   If no local CI is found but .github/workflows/ exists, an advisory is emitted
#   suggesting the user add a local pre-push script.
declare_gate "ci-local-gate" "Local CI pre-push validation" "deny"
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bpush\b'; then
    # Skip if this is a force push — already handled by Check 3
    if ! echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bpush\s+.*(-f|--force)\b'; then
        require_ci
        _CI_PROJECT_ROOT=$(detect_project_root)
        _CI_SCRIPT=$(find_local_ci "$_CI_PROJECT_ROOT" 2>/dev/null) || _CI_SCRIPT=""
        if [[ -n "$_CI_SCRIPT" ]]; then
            # Run local CI with 120s timeout
            _CI_START=$(date +%s 2>/dev/null || echo "0")
            if [[ "$_CI_SCRIPT" == *":ci-local" ]]; then
                # Makefile target
                _CI_OUTPUT=$(cd "$_CI_PROJECT_ROOT" && _with_timeout 120 make ci-local 2>&1) && _CI_EXIT=0 || _CI_EXIT=$?
            else
                _CI_OUTPUT=$(cd "$_CI_PROJECT_ROOT" && _with_timeout 120 bash "$_CI_SCRIPT" 2>&1) && _CI_EXIT=0 || _CI_EXIT=$?
            fi
            _CI_END=$(date +%s 2>/dev/null || echo "0")
            _CI_ELAPSED=$(( _CI_END - _CI_START ))
            if [[ "$_CI_EXIT" -eq 0 ]]; then
                emit_advisory "Local CI passed in ${_CI_ELAPSED}s — push allowed."
            elif [[ "$_CI_EXIT" -eq 124 ]]; then
                emit_deny "Local CI timed out after 120s. Fix CI script performance or increase timeout. Push blocked."
            else
                _CI_FIRST50=$(echo "$_CI_OUTPUT" | head -50)
                emit_deny "Local CI failed (exit ${_CI_EXIT}). Fix failures before pushing.\n\nOutput:\n${_CI_FIRST50}"
            fi
        elif has_github_actions "$_CI_PROJECT_ROOT"; then
            emit_advisory "No local pre-push CI found. Consider adding .githooks/pre-push for faster feedback. Remote CI will still run."
        fi
        # If neither: silently allow
    fi
fi

# --- Check 4: No destructive git commands (hard blocks) ---
declare_gate "destructive-git" "No destructive git commands" "deny"
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\breset\s+--hard'; then
    emit_deny "git reset --hard is destructive and discards uncommitted work. Use git stash or create a backup branch first."
fi

if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bclean\s+.*-f'; then
    emit_deny "git clean -f permanently deletes untracked files. Use git clean -n (dry run) first to see what would be deleted."
fi

if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bbranch\s+(-D\b|.*\s-D\b|.*--delete\s+--force|.*--force\s+--delete)'; then
    # @decision DEC-GUARD-BRANCH-D-001 (carried forward from guard.sh)
    # @title Conditional git branch -D: Guardian-only with merge verification
    # @status accepted
    if ! is_guardian_active; then
        emit_deny "git branch -D / --delete --force force-deletes a branch even if unmerged. Use git branch -d (lowercase) for safe deletion."
    fi
    _BRANCH_NAME=$(echo "$COMMAND" | \
        sed 's/git[[:space:]]\{1,\}-C[[:space:]]\{1,\}[^[:space:]]\{1,\}[[:space:]]\{1,\}/git /' | \
        grep -oE 'branch .+' | \
        sed 's/^branch[[:space:]]*//' | \
        sed 's/--delete//g; s/--force//g; s/-D[[:space:]]//g; s/^-D$//g; s/-f[[:space:]]//g' | \
        tr -s ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | \
        awk '{print $1}')
    if [[ -z "$_BRANCH_NAME" ]]; then
        emit_deny "Cannot parse branch name from: $COMMAND — refusing -D as a precaution."
    fi
    _MERGE_CHECK_DIR=$(extract_git_target_dir "$COMMAND")
    if [[ -z "$_MERGE_CHECK_DIR" ]]; then
        _MERGE_CHECK_DIR="."
    fi
    if ! git -C "$_MERGE_CHECK_DIR" branch --merged HEAD 2>/dev/null | grep -qE "(^|[[:space:]])${_BRANCH_NAME}$"; then
        emit_deny "Branch '${_BRANCH_NAME}' has unmerged commits — cannot force-delete even for Guardian. Merge or cherry-pick first, or delete manually after inspecting."
    fi
fi

# --- Check 4b: Branch deletion requires Guardian context ---
declare_gate "branch-delete-guardian" "Branch deletion requires Guardian context" "deny"
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bbranch\s+.*-d\b'; then
    if ! echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bbranch\s+(-D\b|.*\s-D\b|.*--delete\s+--force|.*--force\s+--delete)'; then
        if ! is_guardian_active; then
            emit_deny "Cannot delete branches outside Guardian context. Dispatch Guardian for branch management (Sacred Practice #8)."
        fi
    fi
fi

# --- Check 5: Worktree removal CWD safety deny ---
# @decision DEC-GUARD-CHECK5-001 (carried forward from guard.sh)
declare_gate "worktree-removal-cwd" "Worktree removal CWD safety deny" "deny"
if echo "$_stripped_cmd" | grep -qE 'git[[:space:]]+[^|;&]*worktree[[:space:]]+remove'; then
    if echo "$_stripped_cmd" | grep -qE 'worktree[[:space:]]+remove[[:space:]].*--force|worktree[[:space:]]+remove[[:space:]]+--force'; then
        if ! is_guardian_active; then
            emit_deny "Cannot force-remove worktrees outside Guardian context. Dirty worktrees may contain uncommitted work. Dispatch Guardian for worktree cleanup."
        fi
    fi
    if [[ "$CWD" == *"/.worktrees/"* ]]; then
        CHECK5_DIR=$(extract_git_target_dir "$COMMAND")
        MAIN_WT=$(git -C "$CHECK5_DIR" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1 || echo "")
        MAIN_WT="${MAIN_WT:-$CHECK5_DIR}"
        emit_deny "CWD safety: worktree removal requires safe CWD first. Run: cd \"$MAIN_WT\" && $COMMAND"
    fi
fi

# --- Check 6: Test status gate for merge commands ---
declare_gate "merge-test-gate" "Test status gate for merge commands" "deny"
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bmerge([^a-zA-Z0-9-]|$)'; then
    _GATE_PROJECT_ROOT=$(detect_project_root)
    if git -C "$_GATE_PROJECT_ROOT" rev-parse --git-dir > /dev/null 2>&1; then
        if read_test_status "$_GATE_PROJECT_ROOT"; then
            if [[ "$TEST_RESULT" == "fail" && "$TEST_AGE" -lt "$TEST_STALENESS_THRESHOLD" ]]; then
                append_session_event "gate_eval" "{\"hook\":\"guard\",\"check\":\"test_gate_merge\",\"result\":\"block\",\"reason\":\"tests failing\"}" "$_GATE_PROJECT_ROOT"
                emit_deny "Cannot merge: tests are failing ($TEST_FAILS failures, ${TEST_AGE}s ago). Fix test failures before merging."
            fi
            if [[ "$TEST_RESULT" != "pass" ]]; then
                append_session_event "gate_eval" "{\"hook\":\"guard\",\"check\":\"test_gate_merge\",\"result\":\"block\",\"reason\":\"tests not passing\"}" "$_GATE_PROJECT_ROOT"
                emit_deny "Cannot merge: last test run did not pass (status: $TEST_RESULT). Run tests and ensure they pass."
            fi
        fi
    fi
fi

# --- Check 7: Test status gate for commit commands ---
declare_gate "commit-test-gate" "Test status gate for commit commands" "deny"
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bcommit([^a-zA-Z0-9-]|$)'; then
    _COMMIT_PROJECT_ROOT=$(extract_git_target_dir "$COMMAND")
    if git -C "$_COMMIT_PROJECT_ROOT" rev-parse --git-dir > /dev/null 2>&1; then
        if read_test_status "$_COMMIT_PROJECT_ROOT"; then
            if [[ "$TEST_RESULT" == "fail" && "$TEST_AGE" -lt "$TEST_STALENESS_THRESHOLD" ]]; then
                append_session_event "gate_eval" "{\"hook\":\"guard\",\"check\":\"test_gate_commit\",\"result\":\"block\",\"reason\":\"tests failing\"}" "$_COMMIT_PROJECT_ROOT"
                emit_deny "Cannot commit: tests are failing ($TEST_FAILS failures, ${TEST_AGE}s ago). Fix test failures before committing."
            fi
            if [[ "$TEST_RESULT" != "pass" ]]; then
                append_session_event "gate_eval" "{\"hook\":\"guard\",\"check\":\"test_gate_commit\",\"result\":\"block\",\"reason\":\"tests not passing\"}" "$_COMMIT_PROJECT_ROOT"
                emit_deny "Cannot commit: last test run did not pass (status: $TEST_RESULT). Run tests and ensure they pass."
            fi
        fi
    fi
fi

# --- Check 8: Proof-of-work verification gate ---
declare_gate "proof-gate" "Proof-of-work verification gate" "deny"
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\b(commit|merge)([^a-zA-Z0-9-]|$)'; then
    if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bcommit([^a-zA-Z0-9-]|$)'; then
        PROOF_DIR=$(extract_git_target_dir "$COMMAND")
    else
        PROOF_DIR=$(detect_project_root)
    fi
    if git -C "$PROOF_DIR" rev-parse --git-dir > /dev/null 2>&1; then
        PROOF_FILE=$(PROJECT_ROOT="$PROOF_DIR" resolve_proof_file)
        [[ ! -f "$PROOF_FILE" ]] && PROOF_FILE=""
        if [[ -f "$PROOF_FILE" ]]; then
            if validate_state_file "$PROOF_FILE" 1; then
                PROOF_STATUS=$(cut -d'|' -f1 "$PROOF_FILE")
            else
                PROOF_STATUS="corrupt"
            fi
            if [[ "$PROOF_STATUS" != "verified" ]]; then
                append_session_event "gate_eval" "{\"hook\":\"guard\",\"check\":\"proof_gate\",\"result\":\"block\",\"reason\":\"not verified\"}" "$PROOF_DIR"
                emit_deny "Cannot proceed: proof-of-work verification is '$PROOF_STATUS'. The user must see the feature work before committing. Run the verification checkpoint (Phase 4.5) and get user confirmation."
            fi
        fi
    fi
fi

# Log gate pass for git commands that passed all gates
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\b(commit|merge)([^a-zA-Z0-9-]|$)'; then
    _LOG_PROJECT_ROOT=$(detect_project_root)
    append_session_event "gate_eval" "{\"hook\":\"guard\",\"result\":\"allow\"}" "$_LOG_PROJECT_ROOT"
fi

# =============================================================================
# DOC-FRESHNESS SECTION — only fires on git commit/merge
# Source: doc-freshness.sh
# @decision DEC-DOCFRESH-003 (carried forward)
# @title doc-freshness fires only on git commit/merge, not all Bash commands
# @status accepted
#
# @decision DEC-GATE-ISOLATE-004
# @title Doc-freshness crash isolation via set +e sandwiching
# @status accepted
# @rationale Doc-freshness crashes (e.g., doc-lib.sh failures, corrupt cache)
#   should NOT block git commands that already passed all safety gates.
#   set +e prevents any crash in this advisory section from triggering the
#   _hook_crash_deny EXIT trap. The section still emits deny/advisory as normal
#   when it finds real issues — only unexpected crashes are swallowed.
#   All safety-critical gates above this point run under set -e (fail-closed).
# =============================================================================

set +e  # Advisory section — crashes here should NOT block git commands that passed safety gates

# Load doc-lib here (not at top) so the common path (non-commit git commands)
# exits at the git-early-exit gate above without paying doc-lib parse cost.
require_doc

# Early-exit: only process git commit/merge commands (already confirmed git above)
declare_gate "doc-freshness" "Documentation freshness enforcement on commit/merge" "advisory"
if ! echo "$_stripped_cmd" | grep -qE '(^|&&|\|\|?|;)\s*git\s+[^|;&]*\b(commit|merge)\b' || echo "$_stripped_cmd" | grep -qE '\bmerge-'; then
    emit_flush
    exit 0
fi

# @decision DEC-DOCFRESH-004 (carried forward)
# @title Branch commits are advisory-only; merges to main/master can block
# @status accepted

_docfresh_advisory() {
    local msg="$1"
    local escaped_msg
    escaped_msg=$(printf '%s' "$msg" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": $escaped_msg
  }
}
EOF
    _HOOK_COMPLETED=true
    exit 0
}

_docfresh_deny() {
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
    _HOOK_COMPLETED=true
    exit 0
}

_DF_PROJECT_ROOT=$(detect_project_root)
_DF_CLAUDE_DIR=$(get_claude_dir)

IS_MERGE=false
IS_MAIN_MERGE=false
if echo "$_stripped_cmd" | grep -qE '(^|&&|\|\|?|;)\s*git\s+[^|;&]*\bmerge\b'; then
    IS_MERGE=true
    CURRENT_BRANCH=$(git -C "$_DF_PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
        IS_MAIN_MERGE=true
    fi
fi

# Bypass check 1: @no-doc in commit message
# @decision DEC-DOCFRESH-005 (carried forward)
if echo "$COMMAND" | grep -qiE '@no-doc'; then
    _DOC_DRIFT="${_DF_CLAUDE_DIR}/.doc-drift"
    if [[ -f "$_DOC_DRIFT" ]]; then
        _prev_bypass=$(grep '^bypass_count=' "$_DOC_DRIFT" 2>/dev/null | cut -d= -f2 || echo "0")
        _new_bypass=$(( _prev_bypass + 1 ))
        _tmp_drift="${_DOC_DRIFT}.tmp.$$"
        sed "s/^bypass_count=.*/bypass_count=${_new_bypass}/" "$_DOC_DRIFT" > "$_tmp_drift" 2>/dev/null \
            && mv "$_tmp_drift" "$_DOC_DRIFT" || rm -f "$_tmp_drift"
    fi
    _docfresh_advisory "DOC-BYPASS: @no-doc flag detected — doc freshness check skipped. Bypass logged to .doc-drift."
fi

# Bypass check 2: doc-only commit
STAGED_FILES=$(git -C "$_DF_PROJECT_ROOT" diff --cached --name-only 2>/dev/null || echo "")
if [[ -n "$STAGED_FILES" ]]; then
    NON_MD_STAGED=$(echo "$STAGED_FILES" | grep -v '\.md$' | grep -v '^$' || true)
    if [[ -z "$NON_MD_STAGED" ]]; then
        _HOOK_COMPLETED=true
        exit 0
    fi
fi

get_doc_freshness "$_DF_PROJECT_ROOT"

if [[ "$DOC_STALE_COUNT" -eq 0 && -z "$DOC_MOD_ADVISORY" ]]; then
    _HOOK_COMPLETED=true
    exit 0
fi

# Bypass check 3: commit includes stale docs → reduce severity one tier
EFFECTIVE_DENY="$DOC_STALE_DENY"
EFFECTIVE_WARN="$DOC_STALE_WARN"

if [[ -n "$STAGED_FILES" ]]; then
    if [[ -n "$EFFECTIVE_DENY" ]]; then
        NEW_DENY=""
        for doc in $EFFECTIVE_DENY; do
            if echo "$STAGED_FILES" | grep -qxF "$doc" 2>/dev/null; then
                EFFECTIVE_WARN="${EFFECTIVE_WARN:+$EFFECTIVE_WARN }$doc"
            else
                NEW_DENY="${NEW_DENY:+$NEW_DENY }$doc"
            fi
        done
        EFFECTIVE_DENY="$NEW_DENY"
    fi

    if [[ -n "$EFFECTIVE_WARN" ]]; then
        NEW_WARN=""
        for doc in $EFFECTIVE_WARN; do
            if ! echo "$STAGED_FILES" | grep -qxF "$doc" 2>/dev/null; then
                NEW_WARN="${NEW_WARN:+$NEW_WARN }$doc"
            fi
        done
        EFFECTIVE_WARN="$NEW_WARN"
    fi
fi

_doc_diag() {
    local doc="$1"
    local doc_age="unknown age"
    if git -C "$_DF_PROJECT_ROOT" log -1 --format='%cr' -- "$doc" 2>/dev/null | grep -q .; then
        doc_age=$(git -C "$_DF_PROJECT_ROOT" log -1 --format='%cr' -- "$doc" 2>/dev/null)
    fi
    echo "$doc (last updated $doc_age)"
}

if [[ "$IS_MAIN_MERGE" == "true" && -n "$EFFECTIVE_DENY" ]]; then
    DIAG=""
    for doc in $EFFECTIVE_DENY; do
        DIAG="${DIAG}
  - $(_doc_diag "$doc")"
    done
    _docfresh_deny "DOC-STALE BLOCK: Cannot merge to main — documentation is stale and must be updated before merging.

Stale docs requiring update:${DIAG}

Options:
  1. Update the listed docs and include them in this commit
  2. Add @no-doc to your commit message to bypass (logged to .doc-drift)

$DOC_FRESHNESS_SUMMARY"
fi

WARN_DOCS="${EFFECTIVE_DENY:+$EFFECTIVE_DENY }${EFFECTIVE_WARN}"
WARN_DOCS="${WARN_DOCS## }"
WARN_DOCS="${WARN_DOCS%% }"

if [[ -n "$WARN_DOCS" ]]; then
    DIAG=""
    for doc in $WARN_DOCS; do
        DIAG="${DIAG}
  - $(_doc_diag "$doc")"
    done
    _docfresh_advisory "DOC-STALE ADVISORY: Documentation may need updating.

Docs with stale indicators:${DIAG}

Branch commits are advisory-only. This becomes a block on merge to main.
Add @no-doc to bypass. $DOC_FRESHNESS_SUMMARY"
fi

if [[ -n "$DOC_MOD_ADVISORY" ]]; then
    _docfresh_advisory "DOC-MOD ADVISORY: High modification churn (>60%) in scope of: $DOC_MOD_ADVISORY — consider reviewing whether a doc update is needed."
fi

# All checks passed
_HOOK_COMPLETED=true
exit 0
