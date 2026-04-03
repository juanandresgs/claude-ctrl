#!/usr/bin/env bash
set -euo pipefail

# Sacred practice guardrails for Bash commands.
# PreToolUse hook — matcher: Bash
#
# This backports the minimum safety improvements needed for v2:
#   - deny unsafe /tmp usage with project-local guidance
#   - deny risky worktree removal / CWD patterns instead of rewriting commands
#   - enforce WHO: Guardian required for high-risk ops (push); routine ops gated by evaluation_state
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

# --- Expire stale leases before lease validation (TKT-STAB-A4) ---
# Run before Check 3 so expired leases are cleaned up before validate_op.
# Silenced: if the runtime is unavailable, the lease gate falls back gracefully.
rt_lease_expire_stale 2>/dev/null || true

# --- Check 3: WHO enforcement for permanent git operations ---
# Migrated from marker-based role check to lease validate-op (Phase 2).
# Lease validate_op() is now the sole authority for who may run git ops.
# Markers remain active for observability but have no enforcement effect here.
#
# Logic:
#   - Meta-repo bypass: ~/.claude config edits skip lease enforcement.
#   - Active lease present: validate_op() is the sole authority.
#     allowed=true  → proceed to later checks (Check 10, Check 13).
#     allowed=false + op_class=high_risk → DENY (hard).
#     allowed=false + op_class=routine_local → DENY (eval/lease gate).
#   - No active lease → DENY (all git ops require a lease in enforced projects).
#
# @decision DEC-GUARD-003
# @title WHO enforcement uses lease validate_op — no unleased git ops in enforced projects
# @status accepted (updated TKT-STAB-A3)
# @rationale Phase 2 execution contracts replace marker-based WHO detection.
#   All git operations in the enforced project now require an active lease.
#   The legacy "routine_local without a lease → allow" path is removed.
#   Meta-repo bypass is the sole exception.
if echo "$COMMAND" | grep -qE '\bgit\b.*\b(commit|merge|push)\b'; then
    if ! is_claude_meta_repo "$PROJECT_ROOT"; then
        _LEASE_JSON=$(rt_lease_current "$PROJECT_ROOT")
        _LEASE_FOUND=$(printf '%s' "${_LEASE_JSON:-}" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")

        if [[ "$_LEASE_FOUND" == "yes" ]]; then
            # Active lease exists: validate_op() is the sole authority.
            _VOP=$(rt_lease_validate_op "$COMMAND" "$PROJECT_ROOT")
            _VOP_ALLOWED=$(printf '%s' "${_VOP:-}" | jq -r '.allowed // false' 2>/dev/null || echo "false")
            if [[ "$_VOP_ALLOWED" != "true" ]]; then
                _VOP_REASON=$(printf '%s' "${_VOP:-}" | jq -r '.reason // "validate_op denied"' 2>/dev/null || echo "validate_op denied")
                deny "Execution contract denied: $_VOP_REASON. Check lease allowed_ops or evaluation_state."
            fi
            # allowed=true: proceed to Check 10 (eval readiness) and Check 13 (approval tokens).
        else
            deny "No active dispatch lease for this worktree. All git operations in the enforced project require a lease. Dispatch via: cc-policy lease issue-for-dispatch --role <role> --worktree-path <path>"
        fi
    fi
fi

# --- Check 4: Main is sacred (no commits on main/master) ---
# Exceptions:
#   - ~/.claude directory (meta-infrastructure)
#   - MASTER_PLAN.md only commits (planning documents per Core Dogma)
#   - Merge commits (MERGE_HEAD exists): governed landing path for features.
#     Check 3 (lease) and Check 10 (eval readiness) gate whether the merge
#     should proceed; Check 4 only needs to allow the finalization commit.
if echo "$COMMAND" | grep -qE '\bgit\b.*\bcommit\b'; then
    TARGET_DIR=$(extract_git_target_dir "$COMMAND")
    if ! is_claude_meta_repo "$TARGET_DIR"; then
        CURRENT_BRANCH=$(git -C "$TARGET_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
        if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
            if [[ -f "$TARGET_DIR/.git/MERGE_HEAD" ]]; then
                :  # Merge commit — governed landing path
            else
                STAGED_FILES=$(git -C "$TARGET_DIR" diff --cached --name-only 2>/dev/null || echo "")
                if [[ "$STAGED_FILES" == "MASTER_PLAN.md" ]]; then
                    :
                else
                    deny "Cannot commit directly to $CURRENT_BRANCH. Sacred Practice #2: Main is sacred. Create a worktree first: git worktree add .worktrees/feature-name $CURRENT_BRANCH"
                fi
            fi
        fi
    fi
fi

# --- Check 5: Force push handling ---
if echo "$COMMAND" | grep -qE '\bgit\b.*\bpush\b.*(-f|--force)\b'; then
    if echo "$COMMAND" | grep -qE '(origin|upstream)\s+(main|master)\b'; then
        deny "Cannot force push to main/master. This is a destructive action that rewrites shared history."
    fi
    if ! echo "$COMMAND" | grep -qE '\-\-force-with-lease'; then
        SAFER=$(echo "$COMMAND" | perl -pe 's/--force(?!-with-lease)/--force-with-lease/g; s/\s-f(\s|$)/ --force-with-lease$1/g')
        deny "Do not use raw force push. Use --force-with-lease so remote changes are protected: $SAFER"
    fi
fi

# --- Check 6: No destructive git commands (hard blocks) ---
if echo "$COMMAND" | grep -qE '\bgit\b.*\breset\b.*--hard'; then
    deny "git reset --hard is destructive and discards uncommitted work. Use git stash or create a backup branch first."
fi

if echo "$COMMAND" | grep -qE '\bgit\b.*\bclean\b.*-f'; then
    deny "git clean -f permanently deletes untracked files. Use git clean -n (dry run) first to see what would be deleted."
fi

if echo "$COMMAND" | grep -qE '\bgit\b.*\bbranch\b.*-D\b'; then
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
# Admin recovery (merge --abort) is not a merge landing — skip the test gate.
# Reads test status from runtime (TKT-STAB-A4: migrated from flat-file read).
if echo "$COMMAND" | grep -qE '\bgit\b.*\bmerge\b' && \
   ! echo "$COMMAND" | grep -qE '\bmerge\b.*--abort'; then
    if ! is_claude_meta_repo "$PROJECT_ROOT"; then
        _TS_JSON=$(python3 -m runtime.cli test-state get --project-root "$PROJECT_ROOT" 2>/dev/null) || _TS_JSON=""
        _TS_STATUS=$(printf '%s' "${_TS_JSON:-}" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
        _TS_FOUND=$(printf '%s' "${_TS_JSON:-}" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
        if [[ "$_TS_FOUND" != "yes" ]]; then
            deny "Cannot merge: no test results found in runtime. Run the project's test suite first."
        fi
        if [[ "$_TS_STATUS" != "pass" && "$_TS_STATUS" != "pass_complete" ]]; then
            deny "Cannot merge: test status is '$_TS_STATUS'. Tests must pass before merging."
        fi
    fi
fi

# --- Check 9: Test status gate for commit commands ---
# Reads test status from runtime (TKT-STAB-A4: migrated from flat-file read).
if echo "$COMMAND" | grep -qE '\bgit\b.*\bcommit\b'; then
    PROJECT_ROOT=$(extract_git_target_dir "$COMMAND")
    if ! is_claude_meta_repo "$PROJECT_ROOT"; then
        _TS_JSON=$(python3 -m runtime.cli test-state get --project-root "$PROJECT_ROOT" 2>/dev/null) || _TS_JSON=""
        _TS_STATUS=$(printf '%s' "${_TS_JSON:-}" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
        _TS_FOUND=$(printf '%s' "${_TS_JSON:-}" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
        if [[ "$_TS_FOUND" != "yes" ]]; then
            deny "Cannot commit: no test results found in runtime. Run the project's test suite first."
        fi
        if [[ "$_TS_STATUS" != "pass" && "$_TS_STATUS" != "pass_complete" ]]; then
            deny "Cannot commit: test status is '$_TS_STATUS'. Tests must pass before committing."
        fi
    fi
fi

# --- Check 10: Evaluator-state readiness gate (TKT-024) ---
# Requires evaluation_state.status == "ready_for_guardian" AND
# evaluation_state.head_sha matches the current HEAD SHA before commit/merge.
# proof_state has zero enforcement effect after TKT-024 cutover.
#
# Admin recovery (merge --abort, reset --merge) is exempt from this gate.
# These are governed recovery operations, not landing operations — there is no
# feature to evaluate. They are still gated by Check 3 (lease) and Check 13
# (approval token). See DEC-LEASE-002 for the full authority model.
#
# @decision DEC-EVAL-003
# @title guard.sh Check 10 gates on evaluation_state, not proof_state
# @status accepted
# @rationale evaluation_state is written by check-tester.sh based on the
#   evaluator's structured EVAL_* trailers. Only a tester-issued verdict of
#   ready_for_guardian with a matching head_sha satisfies this gate. User
#   prompt "verified" no longer affects Guardian eligibility (prompt-submit.sh
#   no longer writes any readiness state). SHA match prevents a stale clearance
#   from applying after subsequent source changes.
_IS_ADMIN_RECOVERY=false
if echo "$COMMAND" | grep -qE '\bmerge\b.*--abort'; then _IS_ADMIN_RECOVERY=true; fi
if echo "$COMMAND" | grep -qE '\breset\b.*--merge'; then _IS_ADMIN_RECOVERY=true; fi

if echo "$COMMAND" | grep -qE '\bgit\b.*\b(commit|merge)\b' && [[ "$_IS_ADMIN_RECOVERY" != "true" ]]; then
    if echo "$COMMAND" | grep -qE '\bgit\b.*\bcommit\b'; then
        _EVAL_DIR=$(extract_git_target_dir "$COMMAND")
    else
        _EVAL_DIR=$(detect_project_root)
    fi
    if ! is_claude_meta_repo "$_EVAL_DIR"; then
        # Resolve workflow_id — for merge, use the branch being merged.
        if echo "$COMMAND" | grep -qE '\bgit\b.*\bmerge\b'; then
            _MERGE_REF=$(extract_merge_ref "$COMMAND")
            if [[ -n "$_MERGE_REF" ]]; then
                _EVAL_WF=$(sanitize_token "$_MERGE_REF")
            else
                _EVAL_WF=$(current_workflow_id "$_EVAL_DIR")
            fi
        else
            _EVAL_WF=$(current_workflow_id "$_EVAL_DIR")
        fi

        # Read evaluation_state from runtime
        _EVAL_STATUS=$(read_evaluation_status "$_EVAL_DIR" "$_EVAL_WF")

        if [[ "$_EVAL_STATUS" != "ready_for_guardian" ]]; then
            deny "Cannot proceed: evaluation_state for workflow '$_EVAL_WF' is '$_EVAL_STATUS'. The tester must emit EVAL_VERDICT=ready_for_guardian before local landing can proceed."
        fi

        # Verify head_sha matches the relevant HEAD (prevents stale clearance).
        # For commit: compare against worktree HEAD (source changes invalidate).
        # For merge: compare against the tip of the branch being merged, not
        # main's HEAD — the evaluator cleared the feature branch, not main.
        _EVAL_STATE_JSON=$(read_evaluation_state "$_EVAL_DIR" "$_EVAL_WF")
        _STORED_SHA=$(printf '%s' "${_EVAL_STATE_JSON:-}" | jq -r '.head_sha // empty' 2>/dev/null || true)
        if echo "$COMMAND" | grep -qE '\bgit\b.*\bmerge\b' && [[ -n "${_MERGE_REF:-}" ]]; then
            _COMPARE_HEAD=$(git -C "$_EVAL_DIR" rev-parse "$_MERGE_REF" 2>/dev/null || true)
            _SHA_LABEL="merge-ref ($_MERGE_REF)"
        else
            _COMPARE_HEAD=$(git -C "$_EVAL_DIR" rev-parse HEAD 2>/dev/null || true)
            _SHA_LABEL="HEAD"
        fi
        if [[ -n "$_STORED_SHA" && -n "$_COMPARE_HEAD" ]]; then
            # Accept prefix match (short SHA vs full SHA)
            if ! printf '%s' "$_COMPARE_HEAD" | grep -q "^${_STORED_SHA}" && \
               ! printf '%s' "$_STORED_SHA" | grep -q "^${_COMPARE_HEAD}"; then
                deny "Cannot proceed: evaluation_state head_sha '$_STORED_SHA' does not match $_SHA_LABEL '$_COMPARE_HEAD'. Source changes after evaluator clearance require a new tester pass."
            fi
        fi

        # WS2: Pre-merge eval reset REMOVED. Reset moved to check-guardian.sh
        # which fires AFTER the guardian completes and verifies LANDING_RESULT.
        # Resetting here (before merge runs) consumed readiness on denied merges.
        # See DEC-WS2-001 in check-guardian.sh for full rationale.
    fi
fi

# --- Check 12: Workflow binding + scope gate ---
# @decision DEC-GUARD-012
# @title Workflow binding and scope are mandatory before commit/merge
# @status accepted
# @rationale Guard.sh is the last enforcement point before git makes a
#   permanent change. Checks 1-11 cover WHO, WHAT branch, test status, and
#   proof-of-work. Check 12 closes the remaining gap: WHICH scope was the
#   implementer authorized to touch. Without a binding the workflow_id is
#   unknown; without a scope the authorized file set is unknown. Both are
#   required for a traceable commit. Meta-repo bypass applies (config edits
#   by the orchestrator do not go through the implementer workflow path).
#   This check only fires on git commit/merge, not on push or other git ops.
if echo "$COMMAND" | grep -qE '\bgit\b.*\b(commit|merge)\b'; then
    if echo "$COMMAND" | grep -qE '\bgit\b.*\bcommit\b'; then
        _CHECK12_DIR=$(extract_git_target_dir "$COMMAND")
    else
        _CHECK12_DIR=$(detect_project_root)
    fi

    if ! is_claude_meta_repo "$_CHECK12_DIR"; then
        # WS1: use lease workflow_id when a lease is active (same source as Check 10).
        _WF12_LEASE_CTX=$(lease_context "$_CHECK12_DIR")
        _WF12_LEASE_FOUND=$(printf '%s' "$_WF12_LEASE_CTX" | jq -r '.found' 2>/dev/null || echo "false")
        if [[ "$_WF12_LEASE_FOUND" == "true" ]]; then
            _WF12_ID=$(printf '%s' "$_WF12_LEASE_CTX" | jq -r '.workflow_id // empty' 2>/dev/null || true)
        fi
        [[ -z "${_WF12_ID:-}" ]] && _WF12_ID=$(current_workflow_id "$_CHECK12_DIR")

        # Sub-check A: binding must exist
        _WF12_BINDING=$(rt_workflow_get "$_WF12_ID")
        if [[ -z "$_WF12_BINDING" ]]; then
            deny "No workflow binding for '$_WF12_ID'. Bind workflow before committing: cc-policy workflow bind $_WF12_ID <worktree_path> <branch>"
        fi

        # Sub-check B: scope must exist
        _WF12_SCOPE=$(cc_policy workflow scope-get "$_WF12_ID" 2>/dev/null) || _WF12_SCOPE=""
        _WF12_SCOPE_FOUND=$(printf '%s' "${_WF12_SCOPE:-}" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
        if [[ "$_WF12_SCOPE_FOUND" != "yes" ]]; then
            deny "No scope manifest for workflow '$_WF12_ID'. Set scope before committing: cc-policy workflow scope-set $_WF12_ID --allowed '[...]' --forbidden '[...]'"
        fi

        # Sub-check C: changed files must comply with scope
        _WF12_BASE=$(cc_policy workflow get "$_WF12_ID" 2>/dev/null | jq -r '.base_branch // "main"' 2>/dev/null || echo "main")
        _WF12_CHANGED_RAW=$(git -C "$_CHECK12_DIR" diff --name-only "${_WF12_BASE}...HEAD" 2>/dev/null || echo "")
        if [[ -n "$_WF12_CHANGED_RAW" ]]; then
            _WF12_CHANGED_JSON=$(printf '%s\n' "$_WF12_CHANGED_RAW" | jq -Rs 'split("\n") | map(select(. != ""))' 2>/dev/null || echo "[]")
            _WF12_COMPLIANCE=$(rt_workflow_scope_check "$_WF12_ID" "$_WF12_CHANGED_JSON")
            _WF12_COMPLIANT=$(printf '%s' "${_WF12_COMPLIANCE:-}" | jq -r '.compliant // "true"' 2>/dev/null || echo "true")
            if [[ "$_WF12_COMPLIANT" == "false" ]]; then
                _WF12_VIOLS=$(printf '%s' "$_WF12_COMPLIANCE" | jq -r '[.violations[]? // empty] | join(", ")' 2>/dev/null || echo "")
                deny "Scope violation for workflow '$_WF12_ID'. Unauthorized files changed: $_WF12_VIOLS"
            fi
        fi
    fi
fi

# --- Check 13: High-risk and admin_recovery operation approval gate ---
# Uses classify_git_op() to determine risk level. Routine local ops (commit,
# merge without --no-ff) are gated by evaluation_state (Check 10) — no approval
# needed here. High-risk ops (push, rebase, reset, merge --no-ff) AND
# admin_recovery ops (merge --abort, reset --merge) require a one-shot approval
# token from the SQLite approvals table.
#
# admin_recovery ops are exempt from Check 10 (no eval readiness required) but
# still require an approval token here — they are significant repo-state changes
# that must be explicitly sanctioned. See DEC-LEASE-002 for the authority model.
#
# Checks 5-6 remain hard denies for destructive variants (reset --hard,
# push --force without lease, clean -f, branch -D) — they fire BEFORE this
# check and are stricter (no token can override them).
#
# @decision DEC-GUARD-013
# @title High-risk git ops require approval tokens (DEC-APPROVAL-001)
# @status accepted
# @rationale evaluation_state=ready_for_guardian is sufficient for routine
#   local landing (commit, merge). High-risk ops that affect remote state or
#   rewrite history need explicit user approval via a one-shot token. This is
#   the mechanical enforcement that replaces "Guardian asks the user in prose."
#   classify_git_op() in context-lib.sh is the authority for risk classification.
if echo "$COMMAND" | grep -qE '\bgit\b'; then
    _OP_CLASS=$(classify_git_op "$COMMAND")
    if [[ "$_OP_CLASS" == "high_risk" || "$_OP_CLASS" == "admin_recovery" ]]; then
        # Determine the op_type for the approval lookup
        _APPROVAL_OP=""
        if echo "$COMMAND" | grep -qE '\bgit\b.*\bpush\b'; then
            _APPROVAL_OP="push"
        elif echo "$COMMAND" | grep -qE '\bgit\b.*\brebase\b'; then
            _APPROVAL_OP="rebase"
        elif echo "$COMMAND" | grep -qE '\bmerge\b.*--abort'; then
            _APPROVAL_OP="admin_recovery"
        elif echo "$COMMAND" | grep -qE '\breset\b.*--merge'; then
            _APPROVAL_OP="admin_recovery"
        elif echo "$COMMAND" | grep -qE '\bgit\b.*\breset\b'; then
            _APPROVAL_OP="reset"
        elif echo "$COMMAND" | grep -qE '\bgit\b.*\bmerge\b.*--no-ff'; then
            _APPROVAL_OP="non_ff_merge"
        fi

        if [[ -n "$_APPROVAL_OP" ]]; then
            # WS1: use lease workflow_id when a lease is active so approval
            # tokens are looked up under the same workflow_id that was authorized.
            _APPROVAL_WF=""
            _APPROVAL_LEASE_CTX=$(lease_context "$PROJECT_ROOT")
            _APPROVAL_LEASE_FOUND=$(printf '%s' "$_APPROVAL_LEASE_CTX" | jq -r '.found' 2>/dev/null || echo "false")
            if [[ "$_APPROVAL_LEASE_FOUND" == "true" ]]; then
                _APPROVAL_WF=$(printf '%s' "$_APPROVAL_LEASE_CTX" | jq -r '.workflow_id // empty' 2>/dev/null || true)
            fi
            [[ -z "$_APPROVAL_WF" ]] && _APPROVAL_WF=$(current_workflow_id "$PROJECT_ROOT")
            _APPROVAL_RESULT=$(rt_approval_check "$_APPROVAL_WF" "$_APPROVAL_OP" 2>/dev/null || echo "false")
            if [[ "$_APPROVAL_RESULT" != "true" ]]; then
                deny "Operation '$_APPROVAL_OP' (class: $_OP_CLASS) requires explicit approval. Grant via: cc-policy approval grant $_APPROVAL_WF $_APPROVAL_OP"
            fi
            # Token consumed — allow the operation to proceed
        fi
    fi
fi

# All checks passed
exit 0
