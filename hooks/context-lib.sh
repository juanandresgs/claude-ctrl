#!/usr/bin/env bash
# shellcheck disable=SC2034
# SC2034: Variables set by get_git_state, get_plan_status, get_session_changes,
# and get_research_status are intentional "output variable" pattern — they are
# set by functions and consumed by callers that source this library. shellcheck
# cannot see cross-file use. Disabling file-wide rather than per-line to reduce
# noise on a pattern that is architecturally deliberate and documented below.
# Shared context-building library for Claude Code hooks.
# Source this file from hooks that need project context:
#   source "$(dirname "$0")/context-lib.sh"
#
# DECISION: Consolidate duplicate context code. Rationale: session-init.sh,
# prompt-submit.sh, and subagent-start.sh all duplicate git state, plan status,
# and worktree listing code. A shared library eliminates drift and reduces
# maintenance surface. Status: accepted.
#
# @decision DEC-CTX-001
# @title Runtime-only state: flat-file dual-write bridge removed (TKT-008)
# @status accepted
# @rationale TKT-007 migrated shared workflow state (proof, markers, audit)
#   from flat files to the SQLite runtime. TKT-008 completes the cutover:
#   all flat-file writes and fallback reads have been removed. The SQLite
#   runtime (cc-policy) is the sole authority for proof, markers, and audit
#   events. Functions that previously dual-wrote to .proof-status-*,
#   .subagent-tracker, .audit-log, or .statusline-cache now use runtime-only
#   paths. Flat-file proof helpers (resolve_proof_file,
#   read_proof_status_file, read_proof_timestamp_file,
#   resolve_proof_file_for_command) were deleted in PE-W6 (no live callers).
#
# Provides:
#   get_git_state <project_root>     - Populates GIT_BRANCH, GIT_DIRTY_COUNT,
#                                      GIT_WORKTREES, GIT_WT_COUNT
#   get_plan_status <project_root>   - Populates PLAN_EXISTS, PLAN_PHASE,
#                                      PLAN_TOTAL_PHASES, PLAN_COMPLETED_PHASES,
#                                      PLAN_AGE_DAYS, PLAN_COMMITS_SINCE,
#                                      PLAN_CHANGED_SOURCE_FILES,
#                                      PLAN_TOTAL_SOURCE_FILES,
#                                      PLAN_SOURCE_CHURN_PCT
#   get_session_changes <project_root> - Populates SESSION_CHANGED_COUNT

# Source the runtime bridge so rt_proof_*, rt_marker_*, rt_event_* are available.
# __CONTEXT_LIB_DIR is resolved once here; sourcing hooks set $0 differently so
# we cannot rely on $(dirname "$0") being stable when this library is sourced
# from multiple callers in the same process.
__CONTEXT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/runtime-bridge.sh
source "${__CONTEXT_LIB_DIR}/lib/runtime-bridge.sh"

# --- Git state ---
get_git_state() {
    local root="$1"
    GIT_BRANCH=""
    GIT_DIRTY_COUNT=0
    GIT_WORKTREES=""
    GIT_WT_COUNT=0

    # Fix #465: In a worktree .git is a FILE (gitdir pointer), not a directory.
    # Use git rev-parse to test git membership uniformly for both cases.
    git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

    GIT_BRANCH=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null) || GIT_BRANCH="unknown"
    GIT_DIRTY_COUNT=$(git -C "$root" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

    GIT_WORKTREES=$(git -C "$root" worktree list 2>/dev/null | grep -v "(bare)" | tail -n +2 || echo "")
    if [[ -n "$GIT_WORKTREES" ]]; then
        GIT_WT_COUNT=$(echo "$GIT_WORKTREES" | wc -l | tr -d ' ')
    fi
}

# --- MASTER_PLAN.md status ---
get_plan_status() {
    local root="$1"
    PLAN_EXISTS=false
    PLAN_PHASE=""
    PLAN_TOTAL_PHASES=0
    PLAN_COMPLETED_PHASES=0
    PLAN_IN_PROGRESS_PHASES=0
    PLAN_AGE_DAYS=0
    PLAN_COMMITS_SINCE=0
    PLAN_CHANGED_SOURCE_FILES=0
    PLAN_TOTAL_SOURCE_FILES=0
    PLAN_SOURCE_CHURN_PCT=0

    [[ ! -f "$root/MASTER_PLAN.md" ]] && return

    PLAN_EXISTS=true

    PLAN_PHASE=$(grep -iE '^\#.*phase|^\*\*Phase' "$root/MASTER_PLAN.md" 2>/dev/null | tail -1 || echo "")
    PLAN_TOTAL_PHASES=$(grep -cE '^\#\#\s+Phase\s+[0-9]' "$root/MASTER_PLAN.md" 2>/dev/null) || PLAN_TOTAL_PHASES=0
    PLAN_COMPLETED_PHASES=$(grep -cE '\*\*Status:\*\*\s*completed' "$root/MASTER_PLAN.md" 2>/dev/null) || PLAN_COMPLETED_PHASES=0
    PLAN_IN_PROGRESS_PHASES=$(grep -cE '\*\*Status:\*\*\s*in-progress' "$root/MASTER_PLAN.md" 2>/dev/null) || PLAN_IN_PROGRESS_PHASES=0

    # Plan age
    local plan_mod
    plan_mod=$(stat -f '%m' "$root/MASTER_PLAN.md" 2>/dev/null || stat -c '%Y' "$root/MASTER_PLAN.md" 2>/dev/null || echo "0")
    if [[ "$plan_mod" -gt 0 ]]; then
        local now
        now=$(date +%s)
        PLAN_AGE_DAYS=$(( (now - plan_mod) / 86400 ))

        # Commits since last plan update
        # Fix #465: use git rev-parse instead of -d .git; works in worktrees too.
        if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            local plan_date
            plan_date=$(date -r "$plan_mod" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$plan_mod" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
            if [[ -n "$plan_date" ]]; then
                PLAN_COMMITS_SINCE=$(git -C "$root" rev-list --count --after="$plan_date" HEAD 2>/dev/null || echo "0")

                # Source file churn since plan update (primary staleness signal)
                PLAN_CHANGED_SOURCE_FILES=$(git -C "$root" log --after="$plan_date" \
                    --name-only --format="" HEAD 2>/dev/null \
                    | sort -u \
                    | grep -cE "\.($SOURCE_EXTENSIONS)$" 2>/dev/null) || PLAN_CHANGED_SOURCE_FILES=0

                PLAN_TOTAL_SOURCE_FILES=$(git -C "$root" ls-files 2>/dev/null \
                    | grep -cE "\.($SOURCE_EXTENSIONS)$" 2>/dev/null) || PLAN_TOTAL_SOURCE_FILES=0

                if [[ "$PLAN_TOTAL_SOURCE_FILES" -gt 0 ]]; then
                    PLAN_SOURCE_CHURN_PCT=$((PLAN_CHANGED_SOURCE_FILES * 100 / PLAN_TOTAL_SOURCE_FILES))
                fi
            fi
        fi
    fi
}

# --- Session tracking ---
get_session_changes() {
    local root="$1"
    SESSION_CHANGED_COUNT=0
    SESSION_FILE=""

    local session_id
    session_id=$(canonical_session_id)
    if [[ -n "$session_id" && -f "$root/.claude/.session-changes-${session_id}" ]]; then
        SESSION_FILE="$root/.claude/.session-changes-${session_id}"
    elif [[ -f "$root/.claude/.session-changes" ]]; then
        SESSION_FILE="$root/.claude/.session-changes"
    fi

    if [[ -n "$SESSION_FILE" && -f "$SESSION_FILE" ]]; then
        SESSION_CHANGED_COUNT=$(sort -u "$SESSION_FILE" | wc -l | tr -d ' ')
    fi
}

# --- Research log status ---
get_research_status() {
    local root="$1"
    RESEARCH_EXISTS=false
    RESEARCH_ENTRY_COUNT=0
    RESEARCH_RECENT_TOPICS=""

    local log="$root/.claude/research-log.md"
    [[ ! -f "$log" ]] && return

    RESEARCH_EXISTS=true
    RESEARCH_ENTRY_COUNT=$(grep -c '^### \[' "$log" 2>/dev/null) || RESEARCH_ENTRY_COUNT=0
    RESEARCH_RECENT_TOPICS=$(grep '^### \[' "$log" | tail -3 | sed 's/^### \[[^]]*\] //' | paste -sd ', ' - 2>/dev/null || echo "")
}

# --- Source file detection ---
# Single source of truth for source file extensions across all hooks.
# DECISION: Consolidated extension list. Rationale: Source file regex was
# copy-pasted in 8+ hooks creating drift risk. Status: accepted.
SOURCE_EXTENSIONS='ts|tsx|js|jsx|mjs|cjs|mts|cts|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh'

# Check if a file is a source file by extension
is_source_file() {
    local file="$1"
    [[ "$file" =~ \.($SOURCE_EXTENSIONS)$ ]]
}

# Check if a file should be skipped (test, config, generated, vendor)
is_skippable_path() {
    local file="$1"
    # Skip config files, test files, generated files
    [[ "$file" =~ (\.config\.|\.test\.|\.spec\.|__tests__|\.generated\.|\.min\.) ]] && return 0
    # Skip vendor/build directories
    [[ "$file" =~ (node_modules|vendor|dist|build|\.next|__pycache__|\.git) ]] && return 0
    return 1
}

# --- Audit trail ---
# Runtime-only (TKT-008): .audit-log flat file removed.
# All audit events go directly to the SQLite event store via rt_event_emit.
# The root parameter is kept for call-site compatibility but is no longer used.
append_audit() {
    local root="$1" event="$2" detail="${3:-}"
    rt_event_emit "$event" "$detail" || true
}

# --- Session and workflow identity ---
canonical_session_id() {
    printf '%s\n' "${CLAUDE_SESSION_ID:-$$}"
}

sanitize_token() {
    local raw="${1:-}"
    raw=$(printf '%s' "$raw" | tr '/: ' '---' | tr -cd '[:alnum:]._-')
    [[ -n "$raw" ]] || raw="default"
    printf '%s\n' "$raw"
}

current_workflow_id() {
    local root="${1:-}"
    local branch=""

    [[ -n "$root" ]] || root=$(detect_project_root)
    branch=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

    if [[ -n "$branch" && "$branch" != "HEAD" ]]; then
        sanitize_token "$branch"
    else
        sanitize_token "$(basename "$root")"
    fi
}

# --- Cross-platform filesystem helpers ---
file_mtime() {
    local path="$1"
    stat -f '%m' "$path" 2>/dev/null || stat -c '%Y' "$path" 2>/dev/null || echo "0"
}

# --- Evaluation state (TKT-024: sole readiness authority) ---

# read_evaluation_status <root> [workflow_id]
# Returns the evaluation status string for the workflow, or "idle" on failure.
# W-CONV-3: when workflow_id is empty, tries lease_context() before falling
# back to current_workflow_id() so leased hooks always hit the right record.
read_evaluation_status() {
    local root="$1"
    local workflow_id="${2:-}"
    local status=""

    if [[ -z "$workflow_id" ]]; then
        local _res_ctx _res_found
        _res_ctx=$(lease_context "$root")
        _res_found=$(printf '%s' "$_res_ctx" | jq -r '.found' 2>/dev/null || echo "false")
        if [[ "$_res_found" == "true" ]]; then
            workflow_id=$(printf '%s' "$_res_ctx" | jq -r '.workflow_id // empty' 2>/dev/null || true)
        fi
    fi
    [[ -n "$workflow_id" ]] || workflow_id=$(current_workflow_id "$root")
    status=$(rt_eval_get "$workflow_id" 2>/dev/null) || status=""
    printf '%s\n' "${status:-idle}"
}

# read_evaluation_state <root> [workflow_id]
# Returns the full evaluation state JSON, or empty string on failure.
# W-CONV-3: lease-first identity when workflow_id not passed.
read_evaluation_state() {
    local root="$1"
    local workflow_id="${2:-}"

    if [[ -z "$workflow_id" ]]; then
        local _rese_ctx _rese_found
        _rese_ctx=$(lease_context "$root")
        _rese_found=$(printf '%s' "$_rese_ctx" | jq -r '.found' 2>/dev/null || echo "false")
        if [[ "$_rese_found" == "true" ]]; then
            workflow_id=$(printf '%s' "$_rese_ctx" | jq -r '.workflow_id // empty' 2>/dev/null || true)
        fi
    fi
    [[ -n "$workflow_id" ]] || workflow_id=$(current_workflow_id "$root")
    cc_policy evaluation get "$workflow_id" 2>/dev/null || true
}

# write_evaluation_status <root> <status> [workflow_id] [head_sha] [blockers] [major] [minor]
# Upserts evaluation state. root kept for call-site compatibility.
# W-CONV-3: lease-first identity when workflow_id not passed.
write_evaluation_status() {
    local root="$1"
    local status="$2"
    local workflow_id="${3:-}"
    local head_sha="${4:-}"
    local blockers="${5:-0}"
    local major="${6:-0}"
    local minor="${7:-0}"

    if [[ -z "$workflow_id" ]]; then
        local _wes_ctx _wes_found
        _wes_ctx=$(lease_context "$root")
        _wes_found=$(printf '%s' "$_wes_ctx" | jq -r '.found' 2>/dev/null || echo "false")
        if [[ "$_wes_found" == "true" ]]; then
            workflow_id=$(printf '%s' "$_wes_ctx" | jq -r '.workflow_id // empty' 2>/dev/null || true)
        fi
    fi
    [[ -n "$workflow_id" ]] || workflow_id=$(current_workflow_id "$root")
    rt_eval_set "$workflow_id" "$status" "$head_sha" "$blockers" "$major" "$minor" || true
}

find_worktree_for_branch() {
    local root="$1"
    local branch="$2"
    local current_path=""
    local current_branch=""
    local line=""

    while IFS= read -r line; do
        case "$line" in
            worktree\ *)
                current_path="${line#worktree }"
                ;;
            branch\ refs/heads/*)
                current_branch="${line#branch refs/heads/}"
                if [[ -n "$current_path" && "$current_branch" == "$branch" ]]; then
                    printf '%s\n' "$current_path"
                    return 0
                fi
                ;;
            "")
                current_path=""
                current_branch=""
                ;;
        esac
    done < <(git -C "$root" worktree list --porcelain 2>/dev/null || true)

    return 1
}

# --- Role detection ---
#
# @decision DEC-IDENTITY-NO-ENV-VAR
# Title: CLAUDE_AGENT_ROLE env var removed as role-detection authority
# Status: accepted
# Rationale: RCA-2 (#22) found that current_active_agent_role() trusted the
#   CLAUDE_AGENT_ROLE environment variable as highest-precedence role source.
#   This is a spoofing vector: any process (or prompt injection) that sets
#   CLAUDE_AGENT_ROLE=guardian before invoking a hook can impersonate the
#   Guardian role and bypass WHO enforcement. The env var path predates
#   TKT-008 (SQLite agent_markers). Now that agent_markers is the authoritative
#   source of role identity, the env var path is removed entirely. SQLite is
#   the sole source. Any code that previously relied on CLAUDE_AGENT_ROLE to
#   inject a role at hook dispatch time must instead write a row to
#   agent_markers via rt_marker_set (the correct API since TKT-008).
current_active_agent_role() {
    # SQLite agent_markers is the sole authority (TKT-008, DEC-IDENTITY-NO-ENV-VAR).
    # CLAUDE_AGENT_ROLE env var is intentionally NOT consulted — it is a spoofing vector.
    #
    # ENFORCE-RCA-6-ext / #26: pass project_root through to the runtime so the
    # query is scoped to THIS project. Without scoping, a stale active marker
    # from another project or a prior crashed session silently poisons role
    # detection — e.g. the orchestrator inherits implementer authority from an
    # orphaned marker and bypasses write_who/branch_guard on source writes.
    #
    # NOTE: workflow_id is NOT auto-derived here. Many legitimate markers are
    # stored with workflow_id=NULL (agents spawned before a workflow was bound,
    # test fixtures, statusline callers). Passing a branch-derived workflow_id
    # would filter them out and silently return empty. project_root-only
    # scoping matches the schema's WHERE-clause semantics in markers.get_active
    # (optional predicates are only applied when the query arg is non-None).
    local root="${1:-}"
    rt_marker_get_active_role "$root" "" 2>/dev/null || echo ""
}

is_guardian_role() {
    local role="${1:-}"
    [[ "$role" == "guardian" || "$role" == "Guardian" ]]
}

is_claude_meta_repo() {
    local dir="$1"
    local repo_root

    # Check 1: CLAUDE_PROJECT_DIR env var — symlinks cause git to resolve to
    # the real path (e.g. ~/Code/foo) even when ~/.claude is the logical root.
    if [[ "${CLAUDE_PROJECT_DIR:-}" == */.claude ]]; then
        return 0
    fi

    # Check 2: git toplevel — works for the main checkout of the meta-repo.
    repo_root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ "$repo_root" == */.claude ]]; then
        return 0
    fi

    # Check 3: git common dir — works for worktrees of the meta-repo.
    # For a worktree of ~/.claude, --git-common-dir returns the shared .git
    # directory, e.g. /Users/foo/.claude/.git.  The worktree's own toplevel
    # is something like ~/.claude/.worktrees/feature-foo and does NOT end in
    # /.claude, so Check 2 would miss it.  --git-common-dir does not.
    #
    # @decision DEC-META-001
    # @title Use --git-common-dir to detect meta-repo worktrees
    # @status accepted
    # @rationale git --show-toplevel returns the worktree root, not the shared
    #   repo root. For ~/.claude worktrees the path ends in feature-foo, not
    #   /.claude. --git-common-dir always returns the shared .git path which
    #   DOES end in /.claude/.git, catching the worktree case. Fixes #163/#143.
    local common_dir
    common_dir=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null || echo "")
    [[ "$common_dir" == */.claude/.git ]]
}

# --- Statusline cache writer removed (TKT-008) ---
# @decision DEC-CACHE-001
# @title .statusline-cache flat file removed; statusline reads runtime directly
# @status superseded
# @rationale write_statusline_cache() wrote a .statusline-cache flat file that
#   scripts/statusline.sh would then read. Since TKT-007, statusline.sh calls
#   rt_statusline_snapshot() directly against the runtime — the cache file is
#   no longer read by any consumer. The function is removed in TKT-008 to
#   eliminate the last hot-path flat-file write. session-init.sh callers that
#   called write_statusline_cache() have been updated to call
#   rt_statusline_snapshot() directly if they need a snapshot for logging,
#   or to simply omit the call if the snapshot was only ever written to the
#   cache file.

# --- Subagent tracking removed (TKT-008) ---
# @decision DEC-SUBAGENT-001
# @title .subagent-tracker flat file removed; lifecycle tracked via runtime markers
# @status superseded
# @rationale track_subagent_start/stop/get_subagent_status wrote to
#   .subagent-tracker. The runtime marker store (rt_marker_set/deactivate) is
#   the sole authority for agent lifecycle since TKT-007. subagent-start.sh
#   already called rt_marker_set; the redundant flat-file call is removed.
#   check-implementer.sh called track_subagent_stop; that call is removed too.
#   session-init.sh deleted .subagent-tracker on startup; that line is removed.

# get_workflow_binding [root]
# Canonical way to discover the current workflow binding from the runtime.
# Exports: WORKFLOW_ID, WORKFLOW_WORKTREE, WORKFLOW_BRANCH, WORKFLOW_TICKET
# Returns 0 if binding exists, 1 if not found.
#
# @decision DEC-WF-003
# @title get_workflow_binding is the canonical worktree identity lookup
# @status accepted
# @rationale Later roles (tester, guardian) must read the worktree path from
#   the runtime binding rather than inferring from CWD or git state. This
#   function is the single canonical entry point. It derives workflow_id via
#   current_workflow_id (branch-based), queries the runtime for the
#   worktree_path, and exports all four binding fields. Guard.sh Check 12
#   and check-implementer.sh both call through this function.
#
# @decision DEC-CONV-003
# @title get_workflow_binding uses lease-first identity (W-CONV-3)
# @status accepted
# @rationale W-CONV-3: lease_context() is the authoritative identity source
#   when a lease is active. The previous implementation always derived
#   WORKFLOW_ID from the branch name via current_workflow_id(). When a lease
#   is active with an explicit workflow_id that differs from the branch-derived
#   token, the binding query would use the wrong key and return not-found.
#   Fix: call lease_context() first; if found==true use its workflow_id; fall
#   back to current_workflow_id() only when no lease is active.
get_workflow_binding() {
    local root="${1:-}"
    [[ -n "$root" ]] || root=$(detect_project_root)

    # W-CONV-3: lease-first identity. When a lease is active its workflow_id
    # takes precedence over the branch-derived id.
    local _gwb_lease_ctx _gwb_lease_found
    _gwb_lease_ctx=$(lease_context "$root")
    _gwb_lease_found=$(printf '%s' "$_gwb_lease_ctx" | jq -r '.found' 2>/dev/null || echo "false")
    if [[ "$_gwb_lease_found" == "true" ]]; then
        WORKFLOW_ID=$(printf '%s' "$_gwb_lease_ctx" | jq -r '.workflow_id // empty' 2>/dev/null || true)
    fi
    [[ -n "${WORKFLOW_ID:-}" ]] || WORKFLOW_ID=$(current_workflow_id "$root")

    WORKFLOW_WORKTREE=""
    WORKFLOW_BRANCH=""
    WORKFLOW_TICKET=""

    # Query runtime for full binding
    local binding_json
    binding_json=$(cc_policy workflow get "$WORKFLOW_ID" 2>/dev/null) || binding_json=""

    if [[ -z "$binding_json" ]]; then
        return 1
    fi

    local found
    found=$(printf '%s' "$binding_json" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
    if [[ "$found" != "yes" ]]; then
        return 1
    fi

    WORKFLOW_WORKTREE=$(printf '%s' "$binding_json" | jq -r '.worktree_path // empty' 2>/dev/null || echo "")
    WORKFLOW_BRANCH=$(printf '%s' "$binding_json" | jq -r '.branch // empty' 2>/dev/null || echo "")
    WORKFLOW_TICKET=$(printf '%s' "$binding_json" | jq -r '.ticket // empty' 2>/dev/null || echo "")

    export WORKFLOW_ID WORKFLOW_WORKTREE WORKFLOW_BRANCH WORKFLOW_TICKET
    [[ -n "$WORKFLOW_WORKTREE" ]]
}

# --- Lease identity helper (WS1) ---
#
# lease_context <worktree_path>
# Returns JSON with lease_id, workflow_id, role, branch, head_sha, found.
# If no active lease, returns {"found": false}.
# This is the SOLE identity source for leased execution paths — all hooks
# that route, submit completions, or reset eval state must derive workflow_id
# from this function when a lease is active, not from current_workflow_id().
#
# @decision DEC-WS1-001
# @title lease_context() is the canonical workflow identity source for leased paths
# @status accepted
# @rationale All hooks derived workflow_id from branch name via current_workflow_id()
#   regardless of whether a lease was active. Because the orchestrator issues leases
#   with an explicit workflow_id (which may differ from the branch-derived token),
#   this caused completion records, eval_state writes, and approval lookups to use
#   different workflow_ids than the lease that authorized the operation. WS1 fixes
#   this by making lease_context() the authority: when a lease is active its
#   workflow_id wins. Branch-derived id is only the fallback when no lease exists.
lease_context() {
    local wt="${1:-}"
    [[ -n "$wt" ]] || wt=$(detect_project_root)
    local result
    result=$(rt_lease_current "$wt") || result=""
    if [[ -z "$result" ]]; then
        echo '{"found": false}'
        return
    fi
    local found
    found=$(printf '%s' "$result" | jq -r 'if .lease_id then "true" else "false" end' 2>/dev/null || echo "false")
    if [[ "$found" == "true" ]]; then
        printf '%s' "$result" | jq '{found: true, lease_id: .lease_id, workflow_id: .workflow_id, role: .role, branch: (.branch // ""), head_sha: (.head_sha // "")}'
    else
        echo '{"found": false}'
    fi
}

# --- Git operation classifier (DEC-CLASSIFY-001) ---
# classify_git_op <command>
# Returns "routine_local", "high_risk", "admin_recovery", or "unclassified".
# Bash implementation for hook performance — avoids Python startup overhead.
# Authority for risk levels: this function. guard.sh Check 13 reads it.
#
# @decision DEC-CLASSIFY-001
# @title Bash classifier is the authority for git op risk levels
# @status accepted
# @rationale Hook performance requires avoiding Python startup for every
#   command. The classifier is simple regex matching — bash is sufficient.
#   routine_local:  evaluation_state gates these (Check 10). high_risk: approval
#   token required (Check 13). admin_recovery: merge --abort and reset --merge
#   require lease + approval but NOT evaluation readiness (DEC-LEASE-002).
#   unclassified: not a git op of interest.
#
# Classification precedence (first match wins):
#   admin_recovery: merge --abort, reset --merge
#   high_risk:      push, rebase, reset, merge --no-ff
#   routine_local:  commit, merge
#   unclassified:   everything else
classify_git_op() {
    # @decision DEC-CTXLIB-001
    # @title POSIX-compatible word boundaries in classify_git_op
    # @status accepted
    # @rationale BSD grep (macOS) does not support \b word-boundary assertions in
    #   ERE mode. The original \bgit\b patterns silently failed on macOS, causing
    #   every git op to fall through to "unclassified". Replaced with explicit
    #   POSIX ERE anchors.
    #
    #   Pattern structure: (^|\s)git(\s.*\s|\s)(subcommand)(\s|$)
    #   - (^|\s)git  : git at start of string or after whitespace
    #   - (\s.*\s|\s): either one-or-more args+spaces between git and subcommand
    #                  (e.g. "git -C /path commit") or a single space (e.g. "git commit")
    #   - (subcommand)(\s|$): subcommand followed by space or end of string
    #
    #   Matches both "git commit" and "git -C /path commit" forms.
    #   Verified against macOS BSD grep (ERE, no \b support).
    local cmd="$1"
    # Admin recovery: merge --abort (governed recovery, not a landing op)
    if echo "$cmd" | grep -qE '(^|\s)git(\s.*\s|\s)merge(\s|$).*--abort'; then echo "admin_recovery"; return; fi
    # Admin recovery: reset --merge (backed-out merge recovery)
    if echo "$cmd" | grep -qE '(^|\s)git(\s.*\s|\s)reset(\s|$).*--merge'; then echo "admin_recovery"; return; fi
    # High-risk: push (any form)
    if echo "$cmd" | grep -qE '(^|\s)git(\s.*\s|\s)push(\s|$)'; then echo "high_risk"; return; fi
    # High-risk: rebase
    if echo "$cmd" | grep -qE '(^|\s)git(\s.*\s|\s)rebase(\s|$)'; then echo "high_risk"; return; fi
    # High-risk: reset (any form not already caught by admin_recovery above)
    if echo "$cmd" | grep -qE '(^|\s)git(\s.*\s|\s)reset(\s|$)'; then echo "high_risk"; return; fi
    # High-risk: non-ff merge (explicit --no-ff)
    if echo "$cmd" | grep -qE '(^|\s)git(\s.*\s|\s)merge(\s|$).*--no-ff'; then echo "high_risk"; return; fi
    # Routine local: commit or merge (local-only, no --no-ff)
    if echo "$cmd" | grep -qE '(^|\s)git(\s.*\s|\s)(commit|merge)(\s|$)'; then echo "routine_local"; return; fi
    # Default: unclassified (git log, git status, git diff, etc.)
    echo "unclassified"
}

# Export for subshells
export SOURCE_EXTENSIONS
export -f cc_policy _rt_ensure_schema rt_marker_get_active_role rt_marker_set rt_marker_deactivate rt_event_emit rt_workflow_bind rt_workflow_get rt_workflow_scope_check rt_eval_get rt_eval_set rt_eval_list rt_eval_invalidate rt_approval_grant rt_approval_check rt_lease_validate_op rt_lease_current rt_lease_claim rt_lease_release rt_lease_expire_stale rt_completion_submit rt_completion_latest rt_completion_route rt_obs_metric rt_obs_metric_batch _obs_accum
export -f get_git_state get_plan_status get_session_changes get_research_status is_source_file is_skippable_path append_audit canonical_session_id sanitize_token current_workflow_id file_mtime read_evaluation_status read_evaluation_state write_evaluation_status find_worktree_for_branch current_active_agent_role is_guardian_role is_claude_meta_repo get_workflow_binding classify_git_op lease_context
