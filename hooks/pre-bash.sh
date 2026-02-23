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
#   The EXIT trap combined with _GUARD_COMPLETED flag implements this. During a
#   merge on ~/.claude, degrade to allow to prevent deadlock when guard.sh itself
#   has conflicts or runtime errors during merge resolution.

set -euo pipefail

# --- Fail-closed crash trap ---
# MUST be set before source-lib.sh — that's the most common failure point.
_GUARD_COMPLETED=false
_guard_deny_on_crash() {
    if [[ "$_GUARD_COMPLETED" != "true" ]]; then
        # During merge on ~/.claude, degrade to allow instead of deny.
        # Prevents deadlock when guard.sh itself has conflicts or runtime
        # errors during merge resolution.
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
trap '_guard_deny_on_crash' EXIT

source "$(dirname "$0")/source-lib.sh"

HOOK_INPUT=$(read_input)
COMMAND=$(get_field '.tool_input.command')
# CWD from the hook input JSON — used by CWD-safety checks
CWD=$(get_field '.cwd')

# Exit silently if no command
if [[ -z "$COMMAND" ]]; then
    _GUARD_COMPLETED=true
    exit 0
fi

# Strip quoted strings from COMMAND for pattern-matching detection.
# Prevents commit message content from triggering git-specific checks.
# All downstream checks use $_stripped_cmd for grep/pattern detection.
# Raw $COMMAND used only for command construction and extract_git_target_dir().
_stripped_cmd=$(echo "$COMMAND" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g")

# Emit PreToolUse deny response with reason, then exit.
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
is_guardian_active() {
    local count=0
    for _gm in "${TRACE_STORE}/.active-guardian-"*; do
        [[ -f "$_gm" ]] && count=$(( count + 1 ))
    done
    [[ "$count" -gt 0 ]]
}

# =============================================================================
# GUARD.SH SECTION — ALL safety checks preserved in full
# @decision DEC-GUARD-001 (carried forward from guard.sh)
# =============================================================================

# --- Check 0: Nuclear command hard deny ---

# Category 1: Filesystem destruction
if echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*|-[a-zA-Z]*f[a-zA-Z]*r[a-zA-Z]*)\s+(/|~|/home|/Users)\s*$' || \
   echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*|-[a-zA-Z]*f[a-zA-Z]*r[a-zA-Z]*)\s+/\*'; then
    deny "NUCLEAR DENY — Filesystem destruction blocked. This command would recursively delete critical system or user directories."
fi

# Category 2: Disk/device destruction
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

# Category 5: System shutdown/reboot
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
# @decision DEC-GUARD-CWD-003 (carried forward from guard.sh)
# @title Deny ALL cd/pushd into .worktrees/ — both bare and chained
# @status accepted
# @rationale posix_spawn ENOENT if worktree is deleted while CWD is inside it.
#   Prevention is the only reliable fix — updatedInput is not supported in PreToolUse.
if [[ "$COMMAND" == "( "* ]]; then
    : # Already subshell-wrapped, pass through
elif echo "$_stripped_cmd" | grep -qE '\b(cd|pushd)\b[^;&|]*\.worktrees/[^/[:space:];&|]+([[:space:]]|$|&&|;|\|\|)'; then
    log_info "GUARD-CWD" "Check 0.75: Denying ALL cd/pushd into .worktrees/"
    deny "CWD protection: cd/pushd into .worktrees/ denied — persistent CWD in a deletable directory causes posix_spawn ENOENT if the worktree is later removed, bricking ALL hooks. Use per-command subshell: ( cd .worktrees/<name> && <cmd> ) or git -C .worktrees/<name> for git commands."
fi

# --- Check 1: /tmp/ and /private/tmp/ writes → deny, redirect to project tmp/ ---
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
        deny "Sacred Practice #3: use project tmp/ instead of /tmp/. Run instead: $CORRECTED"
    fi
fi

# --- Check 9: Block agents from writing verified to .proof-status ---
if echo "$_stripped_cmd" | grep -qE '(>|>>|tee)\s*\S*proof-status' && echo "$COMMAND" | grep -qiE 'verified|approved?|lgtm|looks.good|ship.it'; then
    deny "Cannot write approval status to .proof-status directly. Only the user can verify proof-of-work (via prompt-submit.sh). Present the verification report and let the user respond naturally."
fi

# --- Check 10: Block deletion of .proof-status when verification active ---
if echo "$_stripped_cmd" | grep -qE 'rm\s+(-[a-zA-Z]*\s+)*\S*proof-status'; then
    _ps_dir=$(get_claude_dir)
    _ps_phash=$(project_hash "$(detect_project_root)")
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
# @decision DEC-GUARD-002 (carried forward from guard.sh)
# @title Two-tier worktree CWD safety: conditional deny for rm -rf .worktrees/
# @status accepted
if echo "$_stripped_cmd" | grep -qE 'rm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+){1,2}.*\.worktrees/|rm\s+(-[a-zA-Z]*r[a-zA-Z]*\s+|--recursive\s+).*\.worktrees/'; then
    WT_TARGET=$(echo "$COMMAND" | grep -oE '[^[:space:]]*\.worktrees/[^[:space:];&|]*' | head -1)
    if [[ -n "$WT_TARGET" ]]; then
        if [[ "$CWD" == *"/.worktrees/"* ]]; then
            MAIN_WT=$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1 || echo "")
            MAIN_WT="${MAIN_WT:-$(detect_project_root)}"
            deny "CWD safety: removing worktree directory requires safe CWD first. Run: cd \"$MAIN_WT\" && $COMMAND"
        fi
    fi
fi

# --- Early-exit gate: skip git-specific checks for non-git commands ---
if ! echo "$_stripped_cmd" | grep -qE '(^|&&|\|\|?|;)\s*git\s'; then
    # Run doc-freshness for non-git commands? No — doc-freshness only fires on commit/merge.
    # Since this is not a git command, skip doc-freshness too.
    _GUARD_COMPLETED=true
    exit 0
fi

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
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bcommit([^a-zA-Z0-9-]|$)'; then
    TARGET_DIR=$(extract_git_target_dir "$COMMAND")
    CURRENT_BRANCH=$(git -C "$TARGET_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
        STAGED_FILES=$(git -C "$TARGET_DIR" diff --cached --name-only 2>/dev/null || echo "")
        if [[ "$STAGED_FILES" == "MASTER_PLAN.md" ]]; then
            : # Allow — plan file commits on main
        elif GIT_DIR=$(git -C "$TARGET_DIR" rev-parse --absolute-git-dir 2>/dev/null) && [[ -f "$GIT_DIR/MERGE_HEAD" ]]; then
            : # Allow — completing a merge
        else
            deny "Cannot commit directly to $CURRENT_BRANCH. Sacred Practice #2: Main is sacred. Create a worktree: git worktree add .worktrees/feature-name $CURRENT_BRANCH"
        fi
    fi
fi

# --- Check 3: Force push handling ---
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bpush\s+.*(-f|--force)\b'; then
    if echo "$_stripped_cmd" | grep -qE '(origin|upstream)\s+(main|master)\b'; then
        deny "Cannot force push to main/master. This is a destructive action that rewrites shared history."
    fi
    if ! echo "$_stripped_cmd" | grep -qE '\-\-force-with-lease'; then
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
    # @decision DEC-GUARD-BRANCH-D-001 (carried forward from guard.sh)
    # @title Conditional git branch -D: Guardian-only with merge verification
    # @status accepted
    if ! is_guardian_active; then
        deny "git branch -D / --delete --force force-deletes a branch even if unmerged. Use git branch -d (lowercase) for safe deletion."
    fi
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
    _MERGE_CHECK_DIR=$(extract_git_target_dir "$COMMAND")
    if [[ -z "$_MERGE_CHECK_DIR" ]]; then
        _MERGE_CHECK_DIR="."
    fi
    if ! git -C "$_MERGE_CHECK_DIR" branch --merged HEAD 2>/dev/null | grep -qE "(^|[[:space:]])${_BRANCH_NAME}$"; then
        deny "Branch '${_BRANCH_NAME}' has unmerged commits — cannot force-delete even for Guardian. Merge or cherry-pick first, or delete manually after inspecting."
    fi
fi

# --- Check 4b: Branch deletion requires Guardian context ---
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bbranch\s+.*-d\b'; then
    if ! echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bbranch\s+(-D\b|.*\s-D\b|.*--delete\s+--force|.*--force\s+--delete)'; then
        if ! is_guardian_active; then
            deny "Cannot delete branches outside Guardian context. Dispatch Guardian for branch management (Sacred Practice #8)."
        fi
    fi
fi

# --- Check 5: Worktree removal CWD safety deny ---
# @decision DEC-GUARD-CHECK5-001 (carried forward from guard.sh)
if echo "$_stripped_cmd" | grep -qE 'git[[:space:]]+[^|;&]*worktree[[:space:]]+remove'; then
    if echo "$_stripped_cmd" | grep -qE 'worktree[[:space:]]+remove[[:space:]].*--force|worktree[[:space:]]+remove[[:space:]]+--force'; then
        if ! is_guardian_active; then
            deny "Cannot force-remove worktrees outside Guardian context. Dirty worktrees may contain uncommitted work. Dispatch Guardian for worktree cleanup."
        fi
    fi
    if [[ "$CWD" == *"/.worktrees/"* ]]; then
        CHECK5_DIR=$(extract_git_target_dir "$COMMAND")
        MAIN_WT=$(git -C "$CHECK5_DIR" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1 || echo "")
        MAIN_WT="${MAIN_WT:-$CHECK5_DIR}"
        deny "CWD safety: worktree removal requires safe CWD first. Run: cd \"$MAIN_WT\" && $COMMAND"
    fi
fi

# --- Check 6: Test status gate for merge commands ---
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bmerge([^a-zA-Z0-9-]|$)'; then
    _GATE_PROJECT_ROOT=$(detect_project_root)
    if git -C "$_GATE_PROJECT_ROOT" rev-parse --git-dir > /dev/null 2>&1; then
        if read_test_status "$_GATE_PROJECT_ROOT"; then
            if [[ "$TEST_RESULT" == "fail" && "$TEST_AGE" -lt "$TEST_STALENESS_THRESHOLD" ]]; then
                append_session_event "gate_eval" "{\"hook\":\"guard\",\"check\":\"test_gate_merge\",\"result\":\"block\",\"reason\":\"tests failing\"}" "$_GATE_PROJECT_ROOT"
                deny "Cannot merge: tests are failing ($TEST_FAILS failures, ${TEST_AGE}s ago). Fix test failures before merging."
            fi
            if [[ "$TEST_RESULT" != "pass" ]]; then
                append_session_event "gate_eval" "{\"hook\":\"guard\",\"check\":\"test_gate_merge\",\"result\":\"block\",\"reason\":\"tests not passing\"}" "$_GATE_PROJECT_ROOT"
                deny "Cannot merge: last test run did not pass (status: $TEST_RESULT). Run tests and ensure they pass."
            fi
        fi
    fi
fi

# --- Check 7: Test status gate for commit commands ---
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bcommit([^a-zA-Z0-9-]|$)'; then
    _COMMIT_PROJECT_ROOT=$(extract_git_target_dir "$COMMAND")
    if git -C "$_COMMIT_PROJECT_ROOT" rev-parse --git-dir > /dev/null 2>&1; then
        if read_test_status "$_COMMIT_PROJECT_ROOT"; then
            if [[ "$TEST_RESULT" == "fail" && "$TEST_AGE" -lt "$TEST_STALENESS_THRESHOLD" ]]; then
                append_session_event "gate_eval" "{\"hook\":\"guard\",\"check\":\"test_gate_commit\",\"result\":\"block\",\"reason\":\"tests failing\"}" "$_COMMIT_PROJECT_ROOT"
                deny "Cannot commit: tests are failing ($TEST_FAILS failures, ${TEST_AGE}s ago). Fix test failures before committing."
            fi
            if [[ "$TEST_RESULT" != "pass" ]]; then
                append_session_event "gate_eval" "{\"hook\":\"guard\",\"check\":\"test_gate_commit\",\"result\":\"block\",\"reason\":\"tests not passing\"}" "$_COMMIT_PROJECT_ROOT"
                deny "Cannot commit: last test run did not pass (status: $TEST_RESULT). Run tests and ensure they pass."
            fi
        fi
    fi
fi

# --- Check 8: Proof-of-work verification gate ---
if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\b(commit|merge)([^a-zA-Z0-9-]|$)'; then
    if echo "$_stripped_cmd" | grep -qE 'git\s+[^|;&]*\bcommit([^a-zA-Z0-9-]|$)'; then
        PROOF_DIR=$(extract_git_target_dir "$COMMAND")
    else
        PROOF_DIR=$(detect_project_root)
    fi
    if git -C "$PROOF_DIR" rev-parse --git-dir > /dev/null 2>&1; then
        _proof_dir_phash=$(project_hash "$PROOF_DIR")
        _orch_claude_dir=$(get_claude_dir)
        if [[ "$PROOF_DIR" == "${HOME}/.claude" ]]; then
            PROOF_FILE="${PROOF_DIR}/.proof-status-${_proof_dir_phash}"
            [[ -f "$PROOF_FILE" ]] || PROOF_FILE="${PROOF_DIR}/.proof-status"
        else
            PROOF_FILE="${PROOF_DIR}/.claude/.proof-status"
        fi
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
                PROOF_STATUS="corrupt"
            fi
            if [[ "$PROOF_STATUS" != "verified" ]]; then
                append_session_event "gate_eval" "{\"hook\":\"guard\",\"check\":\"proof_gate\",\"result\":\"block\",\"reason\":\"not verified\"}" "$PROOF_DIR"
                deny "Cannot proceed: proof-of-work verification is '$PROOF_STATUS'. The user must see the feature work before committing. Run the verification checkpoint (Phase 4.5) and get user confirmation."
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
# =============================================================================

# Early-exit: only process git commit/merge commands (already confirmed git above)
if ! echo "$_stripped_cmd" | grep -qE '(^|&&|\|\|?|;)\s*git\s+[^|;&]*\b(commit|merge)\b'; then
    _GUARD_COMPLETED=true
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
    _GUARD_COMPLETED=true
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
    _GUARD_COMPLETED=true
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
        _GUARD_COMPLETED=true
        exit 0
    fi
fi

get_doc_freshness "$_DF_PROJECT_ROOT"

if [[ "$DOC_STALE_COUNT" -eq 0 && -z "$DOC_MOD_ADVISORY" ]]; then
    _GUARD_COMPLETED=true
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
_GUARD_COMPLETED=true
exit 0
