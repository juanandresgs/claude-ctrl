#!/usr/bin/env bash
set -euo pipefail

# Sacred practice guardrails for Bash commands.
# PreToolUse hook — matcher: Bash
#
# This backports the minimum safety improvements needed for v2:
#   - deny unsafe /tmp usage with project-local guidance
#   - deny risky worktree removal / CWD patterns instead of rewriting commands
#   - enforce WHO: only Guardian may commit / merge / push
#   - use workflow-scoped proof state for commit / merge gates

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

HOOK_INPUT=$(read_input)
COMMAND=$(get_field '.tool_input.command')
PROJECT_ROOT=$(detect_project_root)

# Exit silently if no command
[[ -z "$COMMAND" ]] && exit 0

deny() {
    local reason="$1"
    local escaped_reason
    escaped_reason=$(echo "$reason" | jq -Rs .)
    if [[ -n "${PROJECT_ROOT:-}" && -d "$PROJECT_ROOT" ]]; then
        append_audit "$PROJECT_ROOT" "guard_deny" "$(echo "$reason" | tr '\n' ' ')"
    fi
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
}

resolve_path_from_base() {
    local base="$1"
    local candidate="$2"

    if [[ "$candidate" == /* ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    (
        cd "$base" >/dev/null 2>&1 || exit 1
        cd "$(dirname "$candidate")" >/dev/null 2>&1 || exit 1
        printf '%s/%s\n' "$(pwd -P)" "$(basename "$candidate")"
    )
}

extract_cd_target() {
    local cmd="$1"

    if [[ "$cmd" =~ (^|[;&|][[:space:]]*)cd[[:space:]]+(\"([^\"]+)\"|\'([^\']+)\'|([^[:space:]\&\;|]+)) ]]; then
        printf '%s\n' "${BASH_REMATCH[3]:-${BASH_REMATCH[4]:-${BASH_REMATCH[5]}}}"
    fi
}

extract_merge_ref() {
    local cmd="$1"
    local saw_merge=false
    local token=""

    for token in $cmd; do
        if [[ "$token" == "merge" ]]; then
            saw_merge=true
            continue
        fi
        if [[ "$saw_merge" == "true" ]]; then
            [[ "$token" == -* ]] && continue
            printf '%s\n' "$token"
            return 0
        fi
    done
}

# --- Check 1: /tmp/ and /private/tmp/ writes -> deny with a safe replacement ---
# On macOS, /tmp -> /private/tmp (symlink). Both forms must be caught.
# Allow: /private/tmp/claude-*/ (Claude Code scratchpad)
TMP_PATTERN='(>|>>|mv\s+.*|cp\s+.*|tee)\s*(/private)?/tmp/|mkdir\s+(-p\s+)?(/private)?/tmp/'
if echo "$COMMAND" | grep -qE "$TMP_PATTERN"; then
    if echo "$COMMAND" | grep -q '/private/tmp/claude-'; then
        : # Claude scratchpad — allowed as-is
    else
        PROJECT_TMP="$PROJECT_ROOT/tmp"
        SUGGESTED=$(echo "$COMMAND" | sed "s|/private/tmp/|/tmp/|g" | sed "s|/tmp/|$PROJECT_TMP/|g")
        deny "Do not write artifacts under /tmp. Sacred Practice #3 keeps artifacts with their project. Use: mkdir -p \"$PROJECT_TMP\" && $SUGGESTED"
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

# --- Check 2: Worktree CWD safety ---
CD_TARGET=$(extract_cd_target "$COMMAND")
if [[ -n "$CD_TARGET" && "$CD_TARGET" == *".worktrees/"* ]]; then
    deny "Do not enter worktrees with bare cd. Use 'git -C \"$CD_TARGET\" <command>' for git, or '(cd \"$CD_TARGET\" && <command>)' in a subshell so the session cannot be bricked by later cleanup."
fi

# --- Check 3: WHO enforcement for permanent git operations ---
if echo "$COMMAND" | grep -qE 'git\s+(commit|merge|push)\b'; then
    CURRENT_ROLE=$(current_active_agent_role "$PROJECT_ROOT")
    if ! is_guardian_role "$CURRENT_ROLE"; then
        deny "Only the Guardian agent may run git commit, merge, or push. Dispatch Guardian for permanent git operations."
    fi
fi

# --- Check 4: Main is sacred (no commits on main/master) ---
# Exceptions:
#   - ~/.claude directory (meta-infrastructure)
#   - MASTER_PLAN.md only commits (planning documents per Core Dogma)
if echo "$COMMAND" | grep -qE 'git\s+commit'; then
    TARGET_DIR=$(extract_git_target_dir "$COMMAND")
    if ! is_claude_meta_repo "$TARGET_DIR"; then
        CURRENT_BRANCH=$(git -C "$TARGET_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
        if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
            STAGED_FILES=$(git -C "$TARGET_DIR" diff --cached --name-only 2>/dev/null || echo "")
            if [[ "$STAGED_FILES" == "MASTER_PLAN.md" ]]; then
                :
            else
                deny "Cannot commit directly to $CURRENT_BRANCH. Sacred Practice #2: Main is sacred. Create a worktree first: git worktree add .worktrees/feature-name $CURRENT_BRANCH"
            fi
        fi
    fi
fi

# --- Check 5: Force push handling ---
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*(-f|--force)\b'; then
    if echo "$COMMAND" | grep -qE '(origin|upstream)\s+(main|master)\b'; then
        deny "Cannot force push to main/master. This is a destructive action that rewrites shared history."
    fi
    if ! echo "$COMMAND" | grep -qE '\-\-force-with-lease'; then
        SAFER=$(echo "$COMMAND" | perl -pe 's/--force(?!-with-lease)/--force-with-lease/g; s/\s-f(\s|$)/ --force-with-lease$1/g')
        deny "Do not use raw force push. Use --force-with-lease so remote changes are protected: $SAFER"
    fi
fi

# --- Check 6: No destructive git commands (hard blocks) ---
if echo "$COMMAND" | grep -qE 'git\s+reset\s+--hard'; then
    deny "git reset --hard is destructive and discards uncommitted work. Use git stash or create a backup branch first."
fi

if echo "$COMMAND" | grep -qE 'git\s+clean\s+.*-f'; then
    deny "git clean -f permanently deletes untracked files. Use git clean -n (dry run) first to see what would be deleted."
fi

if echo "$COMMAND" | grep -qE 'git\s+branch\s+.*-D\b'; then
    deny "git branch -D force-deletes a branch even if unmerged. Use git branch -d (lowercase) for safe deletion."
fi

# --- Check 7: Worktree removal requires explicit safe CWD handling ---
if echo "$COMMAND" | grep -qE 'git[[:space:]]+worktree[[:space:]]+remove'; then
    TARGET_DIR=$(extract_git_target_dir "$COMMAND")
    WT_PATH=$(echo "$COMMAND" | sed -E 's/.*git[[:space:]]+worktree[[:space:]]+remove[[:space:]]+(-f[[:space:]]+)?//' | xargs)
    if [[ -n "$WT_PATH" ]]; then
        INPUT_CWD=$(get_field '.cwd' 2>/dev/null || echo "")
        MAIN_WT=$(git -C "$TARGET_DIR" worktree list 2>/dev/null | awk 'NR==1 {print $1; exit}')
        MAIN_WT="${MAIN_WT:-$TARGET_DIR}"
        WT_ABS=$(resolve_path_from_base "$TARGET_DIR" "$WT_PATH" 2>/dev/null || echo "$WT_PATH")

        if [[ -n "$INPUT_CWD" && -n "$WT_ABS" && "$INPUT_CWD" == "$WT_ABS"* ]]; then
            deny "Cannot remove a worktree while the shell cwd is inside it. First move to a safe directory, then run: cd \"$MAIN_WT\" && git worktree remove \"$WT_PATH\""
        fi

        if ! echo "$COMMAND" | grep -qE '(^|[;&|][[:space:]]*)cd[[:space:]]+'; then
            deny "git worktree remove must be anchored from a safe cwd. Run: cd \"$MAIN_WT\" && git worktree remove \"$WT_PATH\""
        fi
    fi
fi

# --- Check 8: Test status gate for merge commands ---
if echo "$COMMAND" | grep -qE 'git\s+merge'; then
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

# --- Check 9: Test status gate for commit commands ---
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

# --- Check 10: Proof-of-work verification gate ---
# Requires workflow-scoped proof status = "verified" before commit/merge.
if echo "$COMMAND" | grep -qE 'git\s+(commit|merge)'; then
    if echo "$COMMAND" | grep -qE 'git\s+commit'; then
        PROOF_DIR=$(extract_git_target_dir "$COMMAND")
    else
        PROOF_DIR=$(detect_project_root)
    fi
    if ! is_claude_meta_repo "$PROOF_DIR"; then
        PROOF_FILE=$(resolve_proof_file_for_command "$PROOF_DIR" "$COMMAND")
        PROOF_STATUS=$(read_proof_status_file "$PROOF_FILE")
        if [[ "$PROOF_STATUS" != "verified" ]]; then
            MERGE_REF=$(extract_merge_ref "$COMMAND")
            if [[ -n "$MERGE_REF" ]]; then
                deny "Cannot proceed: proof-of-work for workflow '$MERGE_REF' is '$PROOF_STATUS'. The tester must present evidence and the user must reply 'verified' before Guardian can commit or merge."
            else
                deny "Cannot proceed: proof-of-work is '$PROOF_STATUS'. The tester must present evidence and the user must reply 'verified' before Guardian can commit or merge."
            fi
        fi

        # After a merge passes the verified gate, reset proof to idle so the
        # next workflow cycle starts clean. Commits do not reset (they may be
        # intermediate; the merge is the completion event).
        # TKT-008: runtime-only write; no flat-file reset needed.
        if echo "$COMMAND" | grep -qE 'git\s+merge'; then
            MERGE_WF=$(current_workflow_id "$PROOF_DIR")
            rt_proof_set "$MERGE_WF" "idle" 2>/dev/null || true
        fi
    fi
fi

# All checks passed
exit 0
