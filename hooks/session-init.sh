#!/usr/bin/env bash
# Session context injection at startup.
# SessionStart hook — matcher: startup|resume|clear|compact
#
# Injects project context into the session:
#   - Git state (branch, dirty files, on-main warning)
#   - MASTER_PLAN.md existence and status
#   - Active worktrees
#   - Stale session files from crashed sessions
#   - Filesystem orphan scan (.worktrees/ husks auto-removed; content orphans warned)
#
# Known: SessionStart has a bug (Issue #10373) where output may not inject
# for brand-new sessions. Works for /clear, /compact, resume. Implement
# anyway — when it works it's valuable, when it doesn't there's no harm.

set -euo pipefail

# --- Syntax gate: validate shared libraries before sourcing ---
# Catches corruption (merge conflicts, partial writes) before all hooks break.
_HOOKS_DIR="$(dirname "$0")"
for _lib in source-lib.sh log.sh; do
    if ! bash -n "$_HOOKS_DIR/$_lib" 2>/dev/null; then
        # Pattern A: avoid bash -n | head -3 SIGPIPE; capture all stderr and truncate in bash
        _SYNTAX_ERR=$(bash -n "$_HOOKS_DIR/$_lib" 2>&1 || true)
        _SYNTAX_ERR="${_SYNTAX_ERR:0:500}"  # truncate to ~3 lines worth inline
        _HAS_MARKERS=$(grep -c '^<\{7\}\|^=\{7\}\|^>\{7\}' "$_HOOKS_DIR/$_lib" 2>/dev/null || echo 0)
        _REMEDIATION="Run: bash -n ~/.claude/hooks/$_lib"
        [[ "$_HAS_MARKERS" -gt 0 ]] && _REMEDIATION="Merge conflict markers detected in $_lib. Remove <<<<<<< ======= >>>>>>> lines."
        cat <<SYNTAX_EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "CRITICAL: hooks/$_lib has syntax errors — ALL hooks impaired. Error: ${_SYNTAX_ERR}. Fix: ${_REMEDIATION}. Do this BEFORE any other work."
  }
}
SYNTAX_EOF
        exit 0
    fi
done

source "$(dirname "$0")/source-lib.sh"

# init_hook reads stdin into HOOK_INPUT global and extracts CLAUDE_SESSION_ID
# in the parent shell — avoiding the command-substitution subshell that prevented
# CLAUDE_SESSION_ID from propagating (DEC-INIT-HOOK-001 in log.sh).
# Must be called before detect_project_root() so .cwd is available for root resolution.
init_hook

# Load all domain libraries — session-init.sh uses every domain:
#   require_git:     get_git_state (line 84), get_session_changes
#   require_plan:    get_plan_status (line 216), get_research_status (line 402)
#   require_trace:   TRACE_STORE variable (line 525+), active-marker cleanup
#   require_session: write_statusline_cache (line 217), append_session_event (line 831)
#   require_doc:     get_doc_freshness (line 394), DOC_STALE_COUNT, DOC_FRESHNESS_SUMMARY
#   require_ci:      read_ci_status (line 758), format_ci_summary, has_github_actions
#   require_state:   state_integrity_check (A4: DB integrity check after session backup)
require_git
require_plan
require_trace
require_session
require_doc
require_ci
require_state

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)
_PHASH=$(project_hash "$PROJECT_ROOT")
CONTEXT_PARTS=()

# --- Clean up orphaned global .statusline-cache (DEC-STATE-KV-003) ---
# The bare .statusline-cache file (no session ID suffix) is written by old statusline.sh
# invocations that fell back to the global path. It lacks lifetime_tokens / lifetime_cost
# fields and causes display inconsistency when statusline.sh falls back to it.
# Active cache files always carry a session-ID suffix (.statusline-cache-<SESSION_ID>).
# Removing the bare file is safe: statusline.sh discovers active caches via glob
# .statusline-cache-* and never relies on the bare name.
_orphan_cache="${CLAUDE_DIR}/.statusline-cache"
if [[ -f "$_orphan_cache" && ! -L "$_orphan_cache" ]]; then
    rm -f "$_orphan_cache" 2>/dev/null || true
fi
unset _orphan_cache

# W5-1: emit session.start lifecycle event (best-effort — must never break the hook)
_SINIT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
_SINIT_PROJECT=$(basename "$PROJECT_ROOT")
_SINIT_SID="${CLAUDE_SESSION_ID:-$$}"
state_emit "session.start" "{\"branch\":\"${_SINIT_BRANCH}\",\"project\":\"${_SINIT_PROJECT}\",\"session\":\"${_SINIT_SID}\"}" >/dev/null 2>/dev/null || true

# W6-1: Self-heal advisory — surface accumulated hook failures for /diagnose
# If 5+ hook.failure events are pending, the system may have a degraded hook.
# This threshold prevents noise from transient errors while catching systematic issues.
#
# @decision DEC-STATE-W6-1-003
# @title Self-heal advisory at 5 pending hook failures
# @status accepted
# @rationale 5 failures suggests a pattern (not transient); less than 5 is noise.
#   /diagnose is the prescribed remedy — surface it here rather than waiting for
#   the user to notice degraded behavior. Best-effort: state API may be unavailable
#   if the DB was just initialized (new session, no history yet).
_pending_failures=$(state_events_count "self-heal" "hook.failure" 2>/dev/null || echo "0")
[[ "$_pending_failures" =~ ^[0-9]+$ ]] || _pending_failures=0
if (( _pending_failures >= 5 )); then
    CONTEXT_PARTS+=("SELF-HEAL ADVISORY: ${_pending_failures} hook failures accumulated. Review with /diagnose.")
fi

# --- Record orchestrator session ID for dispatch enforcement ---
# @decision DEC-DISPATCH-002
# @title SESSION_ID-based orchestrator detection for pre-write.sh Gate 1.5
# @status accepted
# @rationale SessionStart fires ONLY for the top-level orchestrator process.
#   Subagents receive SubagentStart, not SessionStart. CLAUDE_SESSION_ID is
#   stored in SQLite KV so pre-write.sh Gate 1.5 can compare CLAUDE_SESSION_ID
#   against orchestrator_sid to detect orchestrator context and deny source writes.
#
# @decision DEC-V4-ORCH-001
# @title Remove .orchestrator-sid flat-file — SQLite KV is sole authority
# @status accepted
# @rationale The flat-file was a migration fallback per DEC-STATE-UNIFY-004.
#   SQLite KV (state_update/state_read) has been stable across all deployments.
#   The flat-file dual-write and pre-write.sh flat-file fallback read are removed.
#   SQLite-only path is now the enforced path; test-orchestrator-guard.sh Test 1a
#   (flat-file existence check) and Test 2 (flat-file seed) removed from active
#   coverage — Tests 1b, 2b, and 7 (SQLite paths) remain authoritative.
#   .orchestrator-sid remains in .gitignore and _PROTECTED_STATE_FILES for any
#   legacy files that may exist in users' environments.
if [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
    # Sole writer: SQLite KV store (atomic, session-scoped, no temp-file dance)
    state_update "orchestrator_sid" "$CLAUDE_SESSION_ID" "session-init" 2>/dev/null || true
fi

# --- A3: state.db backup at session start ---
# @decision DEC-DBSAFE-006
# @title Create state.db backup at every session start before any hook reads state
# @status accepted
# @rationale The session-start backup provides a recovery window for corruption
#   detected by state_integrity_check() (A4). By checkpointing WAL before copy,
#   we ensure the backup is a consistent, fully-flushed snapshot. Overwriting the
#   previous backup is intentional: only the most recent session's DB state is
#   needed for recovery, and keeping multiple generations would grow storage
#   unboundedly. The backup runs BEFORE any state reads so that integrity_check()
#   can use a known-good baseline. Only runs if state.db exists and is non-empty.
_STATE_DB_PATH="${CLAUDE_DIR}/state/state.db"
_STATE_BAK_PATH="${_STATE_DB_PATH}.bak"
if [[ -f "$_STATE_DB_PATH" && -s "$_STATE_DB_PATH" ]]; then
    # Flush WAL to main DB file before copy to ensure consistent snapshot
    sqlite3 "$_STATE_DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>/dev/null || true
    cp "$_STATE_DB_PATH" "$_STATE_BAK_PATH" 2>/dev/null || true
    # Run integrity check after backup; surface warnings if corrupted
    _INTEGRITY_MSG=$(state_integrity_check 2>/dev/null || true)
    if [[ -n "$_INTEGRITY_MSG" ]]; then
        CONTEXT_PARTS+=("WARNING: state.db integrity issue: $_INTEGRITY_MSG")
    fi
fi

# --- Fix 1: Read update status from previous session's check (one-shot display) ---
# @decision DEC-UPDATE-BG-001
# @title Background update-check with previous-session result display
# @status accepted
# @rationale update-check.sh runs `git fetch` which blocks up to 5s on slow
# networks or during rapid session cycling. The fix: read the .update-status
# file written by the PREVIOUS session's background check, display it (one-shot),
# then launch a new background check for the NEXT session. This makes startup
# completely non-blocking for update notifications — the user sees the previous
# check result immediately (usually <1s stale) and the new check runs concurrently
# in the background without delaying the session.
UPDATE_STATUS_FILE="$HOME/.claude/.update-status"
if [[ -f "$UPDATE_STATUS_FILE" && -s "$UPDATE_STATUS_FILE" ]]; then
    IFS='|' read -r UPD_STATUS UPD_LOCAL_VER UPD_REMOTE_VER UPD_COUNT UPD_TS UPD_SUMMARY < "$UPDATE_STATUS_FILE"
    case "$UPD_STATUS" in
        updated)
            CONTEXT_PARTS+=("Harness updated (v${UPD_LOCAL_VER} → v${UPD_REMOTE_VER}, ${UPD_COUNT} commits). To disable: \`touch ~/.claude/.disable-auto-update\`")
            ;;
        breaking)
            CONTEXT_PARTS+=("Harness update available (v${UPD_LOCAL_VER} → v${UPD_REMOTE_VER}, BREAKING). Review CHANGELOG.md then \`cd ~/.claude && git pull --autostash --rebase\`. To disable: \`touch ~/.claude/.disable-auto-update\`")
            ;;
        conflict)
            CONTEXT_PARTS+=("Harness auto-update failed (merge conflict with local changes). Run \`cd ~/.claude && git pull --autostash --rebase\` to resolve. To disable: \`touch ~/.claude/.disable-auto-update\`")
            ;;
    esac
    # One-shot: remove after reading so next session starts clean
    rm -f "$UPDATE_STATUS_FILE"
fi

# Launch update-check in background for the next session (non-blocking)
UPDATE_SCRIPT="$HOME/.claude/scripts/update-check.sh"
if [[ -x "$UPDATE_SCRIPT" ]]; then
    "$UPDATE_SCRIPT" >/dev/null 2>/dev/null &
    disown 2>/dev/null || true
fi

# --- Hook freshness check (W4-1) ---
# Compares .hooks-gen timestamp (written by git-hooks/post-merge) to the
# newest library file's mtime. If libraries are newer than last merge, a
# git pull may have been interrupted. Warns the user to re-run the timestamp.
_HOOKS_GEN="${CLAUDE_DIR}/.hooks-gen"
if [[ -f "$_HOOKS_GEN" ]]; then
    _GEN_TS=$(cat "$_HOOKS_GEN" 2>/dev/null || echo "0")
    _NEWEST_LIB=0
    for _lib in "${CLAUDE_DIR}/hooks/"*-lib.sh "${CLAUDE_DIR}/hooks/log.sh"; do
        if [[ -f "$_lib" ]]; then
            _lib_mtime=$(_file_mtime "$_lib")
            [[ "$_lib_mtime" -gt "$_NEWEST_LIB" ]] && _NEWEST_LIB="$_lib_mtime"
        fi
    done
    if [[ "$_NEWEST_LIB" -gt "$_GEN_TS" ]]; then
        CONTEXT_PARTS+=("WARNING: Hook libraries are newer than last merge (.hooks-gen). A git pull may have been interrupted. Run: date +%s > ~/.claude/.hooks-gen")
    fi
fi

# --- Library consistency check (W4-0) ---
# verify_library_consistency() checks all loaded _LIB_VERSION sentinels match
# the expected version. Warnings appear if a partial sync left mixed versions.
_LIB_WARNINGS=$(verify_library_consistency 1 2>&1 || true)
if [[ -n "$_LIB_WARNINGS" ]]; then
    CONTEXT_PARTS+=("$_LIB_WARNINGS")
fi

# --- Syntax preflight (W4-2: bash -n on critical files) ---
# @decision DEC-RSM-PREFLIGHT-001
# @title bash -n syntax validation at session start
# @status accepted
# @rationale Interrupted git pulls or partial file syncs can leave hook files
#   with syntax errors. Validating 4 entry points + all gate files at session
#   start catches these before any hook fails silently. ~175ms one-time cost.
_PREFLIGHT_FAILS=()
for _pf in \
    "${CLAUDE_DIR}/hooks/session-init.sh" \
    "${CLAUDE_DIR}/hooks/prompt-submit.sh" \
    "${CLAUDE_DIR}/hooks/source-lib.sh" \
    "${CLAUDE_DIR}/hooks/core-lib.sh" \
    "${CLAUDE_DIR}/hooks/log.sh" \
    "${CLAUDE_DIR}/hooks/pre-bash.sh" \
    "${CLAUDE_DIR}/hooks/pre-write.sh" \
    "${CLAUDE_DIR}/hooks/task-track.sh" \
    "${CLAUDE_DIR}/hooks/check-guardian.sh" \
    "${CLAUDE_DIR}/hooks/check-tester.sh" \
    "${CLAUDE_DIR}/hooks/check-implementer.sh" \
    "${CLAUDE_DIR}/hooks/stop.sh"; do
    if [[ -f "$_pf" ]] && ! bash -n "$_pf" 2>/dev/null; then
        _PREFLIGHT_FAILS+=("$(basename "$_pf")")
    fi
done
if [[ ${#_PREFLIGHT_FAILS[@]} -gt 0 ]]; then
    CONTEXT_PARTS+=("CRITICAL: Syntax errors in hook files: ${_PREFLIGHT_FAILS[*]}. Hooks may fail silently. Check for interrupted git pulls or merge conflicts.")
fi

# --- Git state (cached: populates shared cache for subsequent hooks in this cycle) ---
get_git_state "$PROJECT_ROOT"

if [[ -n "$GIT_BRANCH" ]]; then
    GIT_LINE="Git: branch=$GIT_BRANCH"
    [[ "$GIT_DIRTY_COUNT" -gt 0 ]] && GIT_LINE="$GIT_LINE | $GIT_DIRTY_COUNT uncommitted"
    [[ "$GIT_WT_COUNT" -gt 0 ]] && GIT_LINE="$GIT_LINE | $GIT_WT_COUNT worktrees"
    CONTEXT_PARTS+=("$GIT_LINE")

    if [[ "$GIT_BRANCH" == "main" || "$GIT_BRANCH" == "master" ]]; then
        CONTEXT_PARTS+=("WARNING: On $GIT_BRANCH branch. Sacred Practice #2: create a worktree before making changes.")
    fi

    # Stale worktree detection
    ROSTER_SCRIPT="$HOME/.claude/scripts/worktree-roster.sh"
    if [[ -x "$ROSTER_SCRIPT" ]]; then
        "$ROSTER_SCRIPT" prune 2>/dev/null || true
        STALE_COUNT=$("$ROSTER_SCRIPT" stale 2>/dev/null | wc -l || echo "0")
        STALE_COUNT=$(echo "$STALE_COUNT" | tr -d ' ')
        if [[ "$STALE_COUNT" -gt 0 ]]; then
            CONTEXT_PARTS+=("WARNING: $STALE_COUNT stale worktree(s) detected. Run \`worktree-roster.sh cleanup --dry-run\` to review before removing.")
        fi
    fi

    # --- Filesystem orphan scan (safety net for Guardian-missed cleanup) ---
    # Scans .worktrees/ for dirs not tracked by git worktree list.
    # Husks (empty dirs) are auto-removed. Content orphans warn the user.
    # This is a safety net for worktrees that Guardian failed to clean up
    # (crash, manual branch deletion, etc.) that never got registered in the roster.
    WORKTREE_BASE="$PROJECT_ROOT/.worktrees"
    if [[ -d "$WORKTREE_BASE" ]]; then
        # Get git-tracked worktree paths
        GIT_WT_PATHS=$(git -C "$PROJECT_ROOT" worktree list --porcelain 2>/dev/null | grep '^worktree ' | sed 's/^worktree //' || echo "")

        HUSK_COUNT=0
        ORPHAN_DIRS=()

        for wt_dir in "$WORKTREE_BASE"/*/; do
            [[ ! -d "$wt_dir" ]] && continue
            wt_dir="${wt_dir%/}"  # strip trailing slash
            wt_name=$(basename "$wt_dir")

            # Skip if tracked by git
            # Use -x for exact whole-line match to prevent prefix collisions, e.g.
            # "feat" matching "feature-worktree-cleanup" with plain -F substring match.
            if echo "$GIT_WT_PATHS" | grep -qxF "$wt_dir"; then
                continue
            fi

            # Count real files (not just .git metadata)
            FILE_COUNT=$(find "$wt_dir" -not -name '.git' -not -path '*/.git/*' -type f 2>/dev/null | wc -l | tr -d ' ')

            if [[ "$FILE_COUNT" -eq 0 ]]; then
                # Husk — empty dir, safe to auto-remove
                if [[ "$PWD" == "$wt_dir"* ]]; then
                    cd "$PROJECT_ROOT" || cd "$HOME"
                fi
                rm -rf "$wt_dir"
                HUSK_COUNT=$((HUSK_COUNT + 1))
            else
                # Content orphan — warn but don't delete
                ORPHAN_DIRS+=("$wt_name ($FILE_COUNT files)")
            fi
        done

        # Prune registry after husk removal (ghosts may exist for removed dirs)
        if [[ "$HUSK_COUNT" -gt 0 ]]; then
            ROSTER_SCRIPT_FS="$HOME/.claude/scripts/worktree-roster.sh"
            [[ -x "$ROSTER_SCRIPT_FS" ]] && REGISTRY="${REGISTRY:-$HOME/.claude/.worktree-roster.tsv}" "$ROSTER_SCRIPT_FS" prune 2>/dev/null || true
            CONTEXT_PARTS+=("Cleaned $HUSK_COUNT orphaned worktree husk(s) from .worktrees/")
        fi

        if [[ ${#ORPHAN_DIRS[@]} -gt 0 ]]; then
            CONTEXT_PARTS+=("WARNING: ${#ORPHAN_DIRS[@]} content orphan(s) in .worktrees/: ${ORPHAN_DIRS[*]}. Run \`worktree-roster.sh sweep --dry-run\` to review.")
        fi

        # Clean empty .worktrees/ parent directory after last child deleted
        if [[ -d "$WORKTREE_BASE" ]] && [[ -z "$(ls -A "$WORKTREE_BASE" 2>/dev/null)" ]]; then
            rmdir "$WORKTREE_BASE" 2>/dev/null || true
        fi
    fi
fi

# --- File rotation (DEC-PROD-003) ---
# Cap session events JSONL at 1000 lines to prevent unbounded growth
#
# @decision DEC-PROD-003
# @title Cap session-events.jsonl and hook-timing.log at 1000 lines
# @status accepted
# @rationale These files grow without bound across sessions. At 1000 lines each
#   (~100KB) they are still useful for recent-session analysis but don't bloat
#   the project directory. Rotation happens at session start (session-init.sh)
#   which is the natural "housekeeping" point before context injection runs.
_EVENTS_FILE="${CLAUDE_DIR}/.session-events.jsonl"
if [[ -f "$_EVENTS_FILE" ]]; then
  _EVENTS_LINES=$(wc -l < "$_EVENTS_FILE" 2>/dev/null || echo 0)
  if [[ "$_EVENTS_LINES" -gt 1000 ]]; then
    tail -n 1000 "$_EVENTS_FILE" > "${_EVENTS_FILE}.tmp" && mv "${_EVENTS_FILE}.tmp" "$_EVENTS_FILE"
  fi
fi

# Cap hook timing log at 1000 lines
_TIMING_FILE="${CLAUDE_DIR}/.hook-timing.log"
if [[ -f "$_TIMING_FILE" ]]; then
  _TIMING_LINES=$(wc -l < "$_TIMING_FILE" 2>/dev/null || echo 0)
  if [[ "$_TIMING_LINES" -gt 1000 ]]; then
    tail -n 1000 "$_TIMING_FILE" > "${_TIMING_FILE}.tmp" && mv "${_TIMING_FILE}.tmp" "$_TIMING_FILE"
  fi
fi

# --- Orphan marker cleanup (DEC-PROD-004) ---
# Sweep agent markers older than 1 hour to prevent stale blocking
#
# @decision DEC-PROD-004
# @title Sweep stale agent markers on session start
# @status accepted
# @rationale Agent markers (.active-implementer-*, .active-guardian-*, .active-autoverify-*)
#   are written when agents start and removed when they finish. A crash leaves them
#   behind permanently, blocking future agent dispatch. Sweeping on session start
#   (1-hour TTL) ensures a crashed session's markers don't block the next session.
if [[ -d "${CLAUDE_DIR}/traces" ]]; then
  find "${CLAUDE_DIR}/traces" \( -name '.active-implementer-*' -o -name '.active-guardian-*' -o -name '.active-autoverify-*' \) -mmin +60 -delete 2>/dev/null || true
fi

# --- MASTER_PLAN.md tiered injection (DEC-PLAN-004) ---
# Bounded extraction: Identity + Architecture + Active Initiatives (full) +
# last 10 Decision Log entries + Completed Initiatives one-liner list.
# Total injection stays under ~250 lines even with 50+ completed initiatives.
#
# @decision DEC-PLAN-004
# @title Tiered session injection with bounded extraction
# @status accepted
# @rationale Injecting the whole plan would grow unbounded as initiatives accumulate.
#   Tiered extraction keeps context useful regardless of plan age: Identity gives project
#   basics (~10 lines), Architecture gives structure (~10 lines), Active Initiatives give
#   full work detail (bounded by active work), recent Decision Log entries give context
#   (~10 lines), Completed Initiatives are one-liners from the table (~1 line each).
#   Old format falls back to the previous preamble + phase-count pattern.
get_plan_status "$PROJECT_ROOT"

# --- Compute todo split for statusline cache (REQ-P0-005) ---
# @decision DEC-TODO-SPLIT-001
# @title Compute project-specific and global todo counts before cache write
# @status accepted
# @rationale The statusline shows a single "todos: N" count sourced from ~/.claude/.todo-count
# (global cc-todos repo). Phase 2 splits this into project-specific (current repo) and
# global (cc-todos) counts. The split lets users distinguish work scoped to the current
# project from global backlog items. If both resolve to the same repo (e.g. ~/.claude
# uses juanandresgs/claude-config-pro which IS the project), show project count only.
# Globals set here are read by write_statusline_cache() as TODO_PROJECT_COUNT and
# TODO_GLOBAL_COUNT.
# @decision DEC-STARTUP-PERF-001
# @title Cache-first todo counts — gh API calls are non-blocking background refreshes
# @status accepted
# @rationale Previous implementation wait()ed on background gh jobs, blocking startup
# by 5s+ even with parallelism. Fix: read cached .todo-count immediately (pipe-delimited
# proj|glob format), set globals from cache, then launch gh refresh as disowned background
# job that writes updated values for the NEXT session. Startup path now does zero network
# calls. .todo-count format: "proj|glob" integers (stop.sh reads f1/f2, statusline reads
# f1 as legacy fallback, cache gets todo_project/todo_global for split display).
TODO_PROJECT_COUNT=0
TODO_GLOBAL_COUNT=0
_TODO_COUNT_FILE="$HOME/.claude/.todo-count"
_GH_TMPDIR=$(mktemp -d)
trap 'rm -rf "$_GH_TMPDIR"' EXIT

# Read cached counts immediately (zero network calls on startup path)
# @decision DEC-STATE-KV-006: SQLite KV primary; flat-file fallback for backward compat
_CACHED_RAW=$(state_read "todo_count" 2>/dev/null || echo "")
if [[ -n "$_CACHED_RAW" ]]; then
    _CACHED_PROJ=$(printf '%s' "$_CACHED_RAW" | cut -d'|' -f1 2>/dev/null || echo "0")
    _CACHED_GLOB=$(printf '%s' "$_CACHED_RAW" | cut -d'|' -f2 2>/dev/null || echo "0")
    [[ "$_CACHED_PROJ" =~ ^[0-9]+$ ]] && TODO_PROJECT_COUNT="$_CACHED_PROJ" || TODO_PROJECT_COUNT=0
    [[ "$_CACHED_GLOB" =~ ^[0-9]+$ ]] && TODO_GLOBAL_COUNT="$_CACHED_GLOB" || TODO_GLOBAL_COUNT=0
elif [[ -f "$_TODO_COUNT_FILE" ]]; then
    _CACHED_PROJ=$(cut -d'|' -f1 "$_TODO_COUNT_FILE" 2>/dev/null || echo "0")
    _CACHED_GLOB=$(cut -d'|' -f2 "$_TODO_COUNT_FILE" 2>/dev/null || echo "0")
    [[ "$_CACHED_PROJ" =~ ^[0-9]+$ ]] && TODO_PROJECT_COUNT="$_CACHED_PROJ" || TODO_PROJECT_COUNT=0
    [[ "$_CACHED_GLOB" =~ ^[0-9]+$ ]] && TODO_GLOBAL_COUNT="$_CACHED_GLOB" || TODO_GLOBAL_COUNT=0
fi

if command -v gh >/dev/null 2>&1; then
    _GLOBAL_REPO="juanandresgs/cc-todos"

    # Detect current repo from git remote (no network call)
    _CURRENT_REPO=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' || echo "")

    # Launch gh refresh as a disowned background job — writes cache for NEXT session.
    # Never wait() on this process; startup is non-blocking.
    (
        _bg_proj=0
        _bg_glob=0
        if [[ -n "$_CURRENT_REPO" ]]; then
            _bg_proj=$(gh issue list --repo "$_CURRENT_REPO" --label claude-todo --state open --json number --jq length 2>/dev/null || echo "0")
            [[ "$_bg_proj" =~ ^[0-9]+$ ]] || _bg_proj=0
            if [[ "$_CURRENT_REPO" != "$_GLOBAL_REPO" ]]; then
                _bg_glob=$(gh issue list --repo "$_GLOBAL_REPO" --label claude-todo --state open --json number --jq length 2>/dev/null || echo "0")
                [[ "$_bg_glob" =~ ^[0-9]+$ ]] || _bg_glob=0
            fi
        else
            _bg_glob=$(gh issue list --repo "$_GLOBAL_REPO" --label claude-todo --state open --json number --jq length 2>/dev/null || echo "0")
            [[ "$_bg_glob" =~ ^[0-9]+$ ]] || _bg_glob=0
        fi
        # Write pipe-delimited proj|glob for next session (stop.sh reads f1/f2, statusline reads f1)
        # @decision DEC-STATE-KV-006 (dual-write: KV primary + flat-file for statusline.sh fallback)
        state_update "todo_count" "${_bg_proj}|${_bg_glob}" "session-init" 2>/dev/null || true
        echo "${_bg_proj}|${_bg_glob}" > "$HOME/.claude/.todo-count" 2>/dev/null || true
    ) &
    disown $! 2>/dev/null || true

    # CI tier-2 query (background — launched speculatively; result consumed later only if needed)
    if has_github_actions "$PROJECT_ROOT" 2>/dev/null; then
        (gh run list --limit 1 --json conclusion,updatedAt --jq '.[0] | "\(.conclusion)|\(.updatedAt)"' 2>/dev/null || echo "") > "${_GH_TMPDIR:-/tmp}/ci" &
        _PID_CI=$!
    fi
fi

# --- Sum lifetime session cost for statusline display (REQ-P1-001) ---
# @decision DEC-LIFETIME-COST-001
# @title Sum lifetime cost from session_tokens.cost_usd (SQLite primary) with flat-file fallback
# @status accepted
# @rationale Original: summed from .session-cost-history (flat file). Updated (DEC-STATE-KV-004):
# SQLite is now primary — SELECT SUM(cost_usd) WHERE project_hash is atomic and race-free.
# The flat-file fallback (.session-cost-history) handles: brand-new installs, pre-migration
# DBs, and external tooling that reads the flat file directly. Both paths are preserved
# so no history is lost. _PHASH is available from line 67 (top-level project_hash call).
LIFETIME_COST=0
# SQLite primary: sum cost_usd from session_tokens for this project
_lc_db="$(state_dir)/state.db"
if [[ -f "$_lc_db" ]]; then
    _lc_phash_e=$(printf '%s' "$_PHASH" | sed "s/'/''/g")
    _lc_cost=$(sqlite3 "$_lc_db" \
        "SELECT COALESCE(SUM(cost_usd), 0) FROM session_tokens WHERE project_hash = '${_lc_phash_e}';" \
        2>/dev/null || echo "0")
    _lc_cost="${_lc_cost:-0}"
    # Use SQLite result if non-zero (awk comparison handles floating-point)
    if awk "BEGIN {exit (\"$_lc_cost\" + 0 > 0) ? 0 : 1}" 2>/dev/null; then
        LIFETIME_COST="$_lc_cost"
    fi
fi
# Flat-file fallback (pre-migration DBs, new installs, external tooling)
if [[ "$LIFETIME_COST" == "0" || -z "$LIFETIME_COST" ]]; then
    _COST_HISTORY="${CLAUDE_DIR}/.session-cost-history"
    if [[ -f "$_COST_HISTORY" ]]; then
        _LIFETIME=$(awk -F'|' '{sum += $2} END {printf "%.6f", sum+0}' "$_COST_HISTORY" 2>/dev/null || echo "0")
        LIFETIME_COST="${_LIFETIME:-0}"
    fi
fi

# --- Sum lifetime tokens from .session-token-history ---
# @decision DEC-LIFETIME-TOKENS-003
# @title Sum per-project lifetime tokens from .session-token-history at session start
# @status accepted
# @rationale Mirrors DEC-LIFETIME-COST-001 for tokens. .session-token-history is
# written by session-end.sh with format: timestamp|total_tokens|main|subagent|session_id|project_hash|project_name
# Per-project sum: filter by column 6 (project_hash = _PHASH from line 59). Old-format
# entries (fewer than 6 columns) lack a project hash and are included in all project sums
# for backward compatibility. Global sum (all entries, all projects) is also computed
# and injected into the session context so the user sees cross-project usage. Both sums
# use awk (O(N) over ~100 lines) — inexpensive at session startup.
LIFETIME_TOKENS=0
GLOBAL_LIFETIME_TOKENS=0

# --- One-time backfill: import .session-token-history into SQLite (DEC-STATE-KV-003) ---
# Runs automatically the first time a session starts after the migration. If the
# session_tokens table is empty and the flat file has entries, parse the flat file
# and INSERT each row into SQLite. This is a one-time O(N) operation; subsequent
# sessions skip it because the table is non-empty. Best-effort: failures are silently
# ignored so the fallback awk path continues to work.
_bf_db="$(state_dir)/state.db"
if [[ -f "$_bf_db" ]]; then
    _bf_count=$(sqlite3 "$_bf_db" "SELECT COUNT(*) FROM session_tokens;" 2>/dev/null || echo "1")
    _bf_history="${CLAUDE_DIR}/.session-token-history"
    if [[ "${_bf_count:-1}" -eq 0 && -f "$_bf_history" ]]; then
        # Parse pipe-delimited flat file: timestamp|total|main|subagent|session_id|project_hash|project_name
        while IFS='|' read -r _bf_ts _bf_total _bf_main _bf_sub _bf_sid _bf_phash _bf_pname; do
            # Skip blank lines and header-like entries
            [[ -z "$_bf_ts" || -z "$_bf_total" ]] && continue
            # Sanitize integers (strip non-digits)
            _bf_total="${_bf_total//[^0-9]/}"
            _bf_main="${_bf_main//[^0-9]/}"
            _bf_sub="${_bf_sub//[^0-9]/}"
            [[ -z "$_bf_total" ]] && continue
            # SQL-escape string fields
            _bf_sid_e=$(printf '%s' "${_bf_sid:-unknown}" | sed "s/'/''/g")
            _bf_phash_e=$(printf '%s' "${_bf_phash:-}" | sed "s/'/''/g")
            _bf_pname_e=$(printf '%s' "${_bf_pname:-unknown}" | sed "s/'/''/g")
            _bf_ts_e=$(printf '%s' "${_bf_ts:-}" | sed "s/'/''/g")
            sqlite3 "$_bf_db" \
                "INSERT OR IGNORE INTO session_tokens (session_id, project_hash, project_name, timestamp, total_tokens, main_tokens, subagent_tokens, source)
                 VALUES ('${_bf_sid_e}', '${_bf_phash_e}', '${_bf_pname_e}', '${_bf_ts_e}', ${_bf_total:-0}, ${_bf_main:-0}, ${_bf_sub:-0}, 'backfill');" \
                2>/dev/null || true
        done < "$_bf_history"
    fi
    unset _bf_db _bf_count _bf_history _bf_ts _bf_total _bf_main _bf_sub _bf_sid _bf_phash _bf_pname
    unset _bf_sid_e _bf_phash_e _bf_pname_e _bf_ts_e
fi

# --- SQLite primary: sum session_tokens for this project (DEC-STATE-KV-003) ---
# Prefer SQLite over the flat file: concurrent sessions cannot corrupt an INSERT,
# and WHERE project_hash benefits from idx_session_tokens_project.
# Falls back to awk on the flat file when the SQLite DB is absent or empty
# (e.g., brand-new installs, sessions before the migration ran).
_lt_db="$(state_dir)/state.db"
if [[ -f "$_lt_db" ]]; then
    _lt_phash_e=$(printf '%s' "$_PHASH" | sed "s/'/''/g")
    _LT_DB_TOK=$(sqlite3 "$_lt_db" \
        "SELECT COALESCE(SUM(total_tokens), 0) FROM session_tokens WHERE project_hash = '${_lt_phash_e}';" \
        2>/dev/null || echo "0")
    _LT_DB_TOK="${_LT_DB_TOK:-0}"
    _GLT_DB_TOK=$(sqlite3 "$_lt_db" \
        "SELECT COALESCE(SUM(total_tokens), 0) FROM session_tokens;" \
        2>/dev/null || echo "0")
    _GLT_DB_TOK="${_GLT_DB_TOK:-0}"
    if [[ "$_LT_DB_TOK" =~ ^[0-9]+$ ]] && [[ "$_LT_DB_TOK" -gt 0 ]]; then
        LIFETIME_TOKENS="$_LT_DB_TOK"
    fi
    if [[ "$_GLT_DB_TOK" =~ ^[0-9]+$ ]] && [[ "$_GLT_DB_TOK" -gt 0 ]]; then
        GLOBAL_LIFETIME_TOKENS="$_GLT_DB_TOK"
    fi
fi

# --- Flat-file fallback (backward compat for pre-migration sessions) ---
# Also used when SQLite has no rows yet (first session after install).
_TOKEN_HISTORY="${CLAUDE_DIR}/.session-token-history"
if [[ "${LIFETIME_TOKENS:-0}" -eq 0 && -f "$_TOKEN_HISTORY" ]]; then
    # Per-project sum: entries with matching project_hash (col 6) + old-format entries (NF < 6)
    _LIFETIME_TOK=$(awk -F'|' -v ph="$_PHASH" '(NF < 6) || ($6 == ph) {sum += $2} END {print sum+0}' "$_TOKEN_HISTORY" 2>/dev/null || echo "0")
    LIFETIME_TOKENS="${_LIFETIME_TOK:-0}"
fi
if [[ "${GLOBAL_LIFETIME_TOKENS:-0}" -eq 0 && -f "$_TOKEN_HISTORY" ]]; then
    # Global sum: all entries regardless of project (for cross-project context)
    _GLOBAL_LIFETIME_TOK=$(awk -F'|' '{sum += $2} END {print sum+0}' "$_TOKEN_HISTORY" 2>/dev/null || echo "0")
    GLOBAL_LIFETIME_TOKENS="${_GLOBAL_LIFETIME_TOK:-0}"
fi

write_statusline_cache "$PROJECT_ROOT"

# --- Inject token lifetime into session context ---
# @decision DEC-LIFETIME-TOKENS-004
# @title Inject token lifetime summary into session-init CONTEXT_PARTS
# @status accepted
# @rationale The statusline shows per-project token lifetime in the bottom bar,
# but the session context (system-reminder) has no token lifetime info. Injecting
# a "Token lifetime: ∑<project> this project | ∑<global> all projects" line gives
# the agent awareness of cumulative token spend across sessions. Only shown when
# the project sum > 0 to avoid noise on fresh projects. Uses K/M notation (same
# as statusline.sh format_tokens) via inline awk for portability — no external
# script dependency at session startup.
if (( LIFETIME_TOKENS > 0 || GLOBAL_LIFETIME_TOKENS > 0 )); then
    _fmt_tok() {
        local n="$1"
        if   (( n >= 1000000 )); then awk "BEGIN {printf \"%.1fM\", $n/1000000}"
        elif (( n >= 1000    )); then printf '%dk' "$(( n / 1000 ))"
        else                         printf '%d' "$n"
        fi
    }
    _TOK_CTX_LINE="Token lifetime:"
    if (( LIFETIME_TOKENS > 0 )); then
        _TOK_CTX_LINE="${_TOK_CTX_LINE} ∑$(_fmt_tok "$LIFETIME_TOKENS") this project"
    fi
    if (( GLOBAL_LIFETIME_TOKENS > LIFETIME_TOKENS )); then
        _TOK_CTX_LINE="${_TOK_CTX_LINE} | ∑$(_fmt_tok "$GLOBAL_LIFETIME_TOKENS") all projects"
    fi
    CONTEXT_PARTS+=("$_TOK_CTX_LINE")
fi

if [[ "$PLAN_EXISTS" == "true" ]]; then
    _PLAN_FILE="$PROJECT_ROOT/MASTER_PLAN.md"

    # Detect format: new (### Initiative:) vs old (## Phase N:)
    _HAS_INITIATIVES=$(grep -cE '^\#\#\#\s+Initiative:' "$_PLAN_FILE" 2>/dev/null || echo "0")

    if [[ "$_HAS_INITIATIVES" -gt 0 ]]; then
        # --- New living-document format: tiered injection ---

        # 1. Identity section (~10 lines)
        # @decision DEC-SIGPIPE-001
        # @title Move head -N limit into awk to prevent SIGPIPE with set -euo pipefail
        # @status accepted
        # @rationale `awk ... | head -N` causes SIGPIPE when the section is larger than N
        #   lines: head closes the pipe after N lines, awk gets SIGPIPE, and set -euo pipefail
        #   propagates exit 141 killing the hook. Fix: embed the line limit directly in awk
        #   using a counter (`if(++c<=N) print; else exit`). awk sees EOF normally, no SIGPIPE.
        #   Applied to all awk|head patterns on MASTER_PLAN.md (Pattern A).
        _IDENTITY=$(awk '/^## Identity/{f=1} f && /^## / && !/^## Identity/{exit} f{if(++c<=15) print; else exit}' \
            "$_PLAN_FILE" 2>/dev/null)
        [[ -n "$_IDENTITY" ]] && CONTEXT_PARTS+=("$_IDENTITY")

        # 2. Architecture section (~10 lines)
        _ARCH=$(awk '/^## Architecture/{f=1} f && /^## / && !/^## Architecture/{exit} f{if(++c<=15) print; else exit}' \
            "$_PLAN_FILE" 2>/dev/null)
        [[ -n "$_ARCH" ]] && CONTEXT_PARTS+=("$_ARCH")

        # 3. Active Initiatives: compact summary (REQ-P0-004 — bounded under 250 lines total)
        # Full initiative blocks can be 300+ lines for real plans. Extract a 5-8 line
        # summary per initiative: name, status, goal, phase counts. Agents read the
        # full plan via Read tool when they need work items, issue cross-references, etc.
        #
        # @decision DEC-PLAN-005
        # @title Compact per-initiative summary instead of full Active Initiatives block
        # @status accepted
        # @rationale E2E test showed real MASTER_PLAN.md with 2 active initiatives
        #   produced 796-line injection (731 lines from Active Initiatives alone) — 3x
        #   the 250-line target (REQ-P0-004). T13 caught this with realistic fixtures.
        #   Fix: extract name+status+goal+phase-counts (~5 lines per initiative) rather
        #   than dumping the entire block. Full detail is always available via Read tool.
        # Pattern A: limit embedded in awk to avoid SIGPIPE (DEC-SIGPIPE-001)
        _ACTIVE_HEADER=$(awk '/^## Active Initiatives/{found=1; print; next} found && /^## /{exit} found{if(++c<=3) print; else exit}' \
            "$_PLAN_FILE" 2>/dev/null)
        [[ -n "$_ACTIVE_HEADER" ]] && CONTEXT_PARTS+=("$_ACTIVE_HEADER")

        # Parse each ### Initiative: block for a compact summary
        _ACTIVE_SECTION=$(awk '/^## Active Initiatives/{f=1} f && /^## Completed Initiatives/{exit} f{print}' \
            "$_PLAN_FILE" 2>/dev/null)
        if [[ -n "$_ACTIVE_SECTION" ]]; then
            _INIT_SUMMARY=""
            _CUR_INIT=""
            _CUR_STATUS=""
            _CUR_GOAL=""
            _PLANNED_PHASES=0
            _INPROG_PHASES=0
            _DONE_PHASES=0
            _IN_PHASE=false   # true after a #### Phase N: header — next Status: is phase-level

            _flush_initiative() {
                if [[ -n "$_CUR_INIT" ]]; then
                    local _phase_line="Phases: ${_PLANNED_PHASES} planned, ${_INPROG_PHASES} in-progress, ${_DONE_PHASES} completed"
                    _INIT_SUMMARY+="### Initiative: ${_CUR_INIT}"$'\n'
                    [[ -n "$_CUR_STATUS" ]] && _INIT_SUMMARY+="**Status:** ${_CUR_STATUS}"$'\n'
                    [[ -n "$_CUR_GOAL" ]] && _INIT_SUMMARY+="**Goal:** ${_CUR_GOAL}"$'\n'
                    _INIT_SUMMARY+="${_phase_line}"$'\n'
                fi
            }

            while IFS= read -r _line; do
                if [[ "$_line" =~ ^'### Initiative: '(.*) ]]; then
                    # New initiative block — flush previous, reset state
                    _flush_initiative
                    _CUR_INIT="${BASH_REMATCH[1]}"
                    _CUR_STATUS=""
                    _CUR_GOAL=""
                    _PLANNED_PHASES=0
                    _INPROG_PHASES=0
                    _DONE_PHASES=0
                    _IN_PHASE=false
                elif [[ "$_line" =~ ^'#### Phase' ]]; then
                    # Phase header — next Status: belongs to this phase
                    _IN_PHASE=true
                elif [[ -n "$_CUR_INIT" ]]; then
                    # Pattern B: [[ =~ ]] replaces echo "$_line" | grep -qE to avoid SIGPIPE
                    # (DEC-SIGPIPE-001). Each grep spawns a subshell and pipe; in a tight
                    # read loop over thousands of lines, any broken pipe propagates exit 141.
                    # Pattern C: bash parameter expansion replaces echo "$_line" | sed for
                    # status/goal extraction — no subshell, no pipe, no SIGPIPE risk.
                    if [[ "$_IN_PHASE" == "true" && "$_line" =~ ^\*\*Status:\*\* ]]; then
                        # Phase-level status — count it
                        if [[ "$_line" =~ [[:space:]]planned([[:space:]]|$) ]]; then
                            _PLANNED_PHASES=$((_PLANNED_PHASES + 1))
                        elif [[ "$_line" =~ [[:space:]]in-progress([[:space:]]|$) ]]; then
                            _INPROG_PHASES=$((_INPROG_PHASES + 1))
                        elif [[ "$_line" =~ [[:space:]]completed([[:space:]]|$) ]]; then
                            _DONE_PHASES=$((_DONE_PHASES + 1))
                        fi
                        _IN_PHASE=false  # consumed
                    elif [[ "$_IN_PHASE" == "false" && "$_line" =~ ^\*\*Status:\*\* ]]; then
                        # Initiative-level status — Pattern C: parameter expansion strips prefix
                        _CUR_STATUS="${_line#\*\*Status:\*\* }"
                        _CUR_STATUS="${_CUR_STATUS#\*\*Status:\*\*}"
                    elif [[ "$_line" =~ ^\*\*Goal:\*\* ]]; then
                        # Pattern C: parameter expansion strips **Goal:** prefix
                        _CUR_GOAL="${_line#\*\*Goal:\*\* }"
                        _CUR_GOAL="${_CUR_GOAL#\*\*Goal:\*\*}"
                    fi
                fi
            done <<< "$_ACTIVE_SECTION"
            _flush_initiative

            [[ -n "$_INIT_SUMMARY" ]] && CONTEXT_PARTS+=("$_INIT_SUMMARY")
        fi

        # 4. Last 10 Decision Log entries (most recent decisions give context)
        # || true: grep returns 1 when no entries exist; pipefail would kill the script.
        _DEC_LOG_ENTRIES=$(awk '/^## Decision Log/{f=1} f && /^---/{exit} f && /^\|/{print}' \
            "$_PLAN_FILE" 2>/dev/null | grep -vE '^\|\s*Date\s*\|' | tail -10 || true)
        if [[ -n "$_DEC_LOG_ENTRIES" ]]; then
            CONTEXT_PARTS+=("Recent decisions (last 10):")
            CONTEXT_PARTS+=("$_DEC_LOG_ENTRIES")
        fi

        # 5. Completed Initiatives: one-liner table rows only (not full blocks)
        # Pattern A: limit embedded in awk (c<=60) to avoid SIGPIPE (DEC-SIGPIPE-001).
        # awk also filters header/separator rows inline, removing the grep|head pipeline.
        _COMPLETED_ROWS=$(awk '/^## Completed Initiatives/{f=1; next} f && /^\|/ && !/^\|\s*Initiative\s*\|/ && !/\|\s*-+\s*\|/ {if(++c<=60) print; else exit}' \
            "$_PLAN_FILE" 2>/dev/null || true)
        if [[ -n "$_COMPLETED_ROWS" ]]; then
            _COMPLETED_COUNT=$(echo "$_COMPLETED_ROWS" | wc -l | tr -d ' ')
            CONTEXT_PARTS+=("Completed initiatives (${_COMPLETED_COUNT}):")
            CONTEXT_PARTS+=("$_COMPLETED_ROWS")
        fi

        # Lifecycle status line
        if [[ "$PLAN_LIFECYCLE" == "dormant" ]]; then
            CONTEXT_PARTS+=("WARNING: MASTER_PLAN.md is dormant — all initiatives completed. Add a new initiative before writing code.")
        else
            _INIT_LINE="Plan: ${PLAN_ACTIVE_INITIATIVES} active initiative(s)"
            [[ "$PLAN_TOTAL_PHASES" -gt 0 ]] && _INIT_LINE="$_INIT_LINE | ${PLAN_COMPLETED_PHASES}/${PLAN_TOTAL_PHASES} phases done"
            [[ "$PLAN_AGE_DAYS" -gt 0 ]] && _INIT_LINE="$_INIT_LINE | age: ${PLAN_AGE_DAYS}d"
            CONTEXT_PARTS+=("$_INIT_LINE")

            if [[ "$PLAN_SOURCE_CHURN_PCT" -ge 10 ]]; then
                CONTEXT_PARTS+=("WARNING: Plan may be stale (${PLAN_SOURCE_CHURN_PCT}% source file churn since last update)")
            fi
        fi
    else
        # --- Old format: preamble + phase count (backward compatibility) ---
        # Pattern A: limit embedded in awk to avoid SIGPIPE (DEC-SIGPIPE-001)
        PREAMBLE=$(awk '/^---$|^## Original Intent/{exit} {if(++c<=30) print; else exit}' "$_PLAN_FILE")
        [[ -n "$PREAMBLE" ]] && CONTEXT_PARTS+=("$PREAMBLE")

        if [[ "$PLAN_LIFECYCLE" == "dormant" ]]; then
            CONTEXT_PARTS+=("WARNING: MASTER_PLAN.md is dormant (all $PLAN_TOTAL_PHASES phases done). Add a new initiative before writing code.")
        else
            PLAN_LINE="Plan:"
            [[ "$PLAN_TOTAL_PHASES" -gt 0 ]] && PLAN_LINE="$PLAN_LINE $PLAN_COMPLETED_PHASES/$PLAN_TOTAL_PHASES phases"
            [[ -n "$PLAN_PHASE" ]] && PLAN_LINE="$PLAN_LINE | active: $PLAN_PHASE"
            [[ "$PLAN_AGE_DAYS" -gt 0 ]] && PLAN_LINE="$PLAN_LINE | age: ${PLAN_AGE_DAYS}d"
            CONTEXT_PARTS+=("$PLAN_LINE")

            if [[ "$PLAN_SOURCE_CHURN_PCT" -ge 10 ]]; then
                CONTEXT_PARTS+=("WARNING: Plan may be stale (${PLAN_SOURCE_CHURN_PCT}% source file churn since last update)")
            fi
        fi
    fi
else
    CONTEXT_PARTS+=("Plan: not found (required before implementation)")
fi

# --- Dispatch summary injection (maintained in docs/DISPATCH.md) ---
# @decision DEC-DISPATCH-INJECT-001
# @title Inject dispatch summary from docs/DISPATCH.md into session context
# @status accepted
# @rationale The orchestrator needs dispatch rules every session but the full
#   docs/DISPATCH.md is ~300 lines. The DISPATCH-INJECT-START/END markers in
#   docs/DISPATCH.md delimit a compact summary (~20 lines) with the key routing
#   rules. Injecting it here ensures every session has orchestrator dispatch
#   rules without loading the full protocol doc. Placed after MASTER_PLAN.md
#   injection so plan context comes first (higher priority).
DISPATCH_FILE="$CLAUDE_DIR/docs/DISPATCH.md"
if [[ -f "$DISPATCH_FILE" ]]; then
  DISPATCH_SUMMARY=$(awk '/<!-- DISPATCH-INJECT-START -->/{found=1; next} /<!-- DISPATCH-INJECT-END -->/{found=0} found' "$DISPATCH_FILE")
  if [[ -n "$DISPATCH_SUMMARY" ]]; then
    CONTEXT_PARTS+=("$DISPATCH_SUMMARY")
  fi
fi

# --- Doc freshness status ---
# Advisory injection — stale docs surfaced alongside plan staleness.
# get_doc_freshness uses cached results (DEC-DOCFRESH-002) so startup cost is
# one cache-file read on warm runs, not a suite of git log calls.
get_doc_freshness "$PROJECT_ROOT"
if [[ "$DOC_STALE_COUNT" -gt 0 ]]; then
    CONTEXT_PARTS+=("$DOC_FRESHNESS_SUMMARY")
elif [[ -n "$DOC_MOD_ADVISORY" ]]; then
    CONTEXT_PARTS+=("Doc freshness: advisory — high modification churn in: $DOC_MOD_ADVISORY")
fi

# --- Research status ---
get_research_status "$PROJECT_ROOT"
if [[ "$RESEARCH_EXISTS" == "true" ]]; then
    CONTEXT_PARTS+=("Research: $RESEARCH_ENTRY_COUNT entries | recent: $RESEARCH_RECENT_TOPICS")
fi

# --- Preserved context from pre-compaction ---
# compact-preserve.sh writes .preserved-context before compaction.
# Re-inject it here so the post-compaction session has full context
# even if the additionalContext from PreCompact was lost in summarization.
#
# Resume directive logic: the preserved-context file may contain a
# "RESUME DIRECTIVE:" block (computed by build_resume_directive in context-lib.sh).
# This block is extracted and injected as the FIRST context element so it takes
# priority over all other context. The remainder is injected after.
_WAS_COMPACTION=false
PRESERVE_FILE="${CLAUDE_DIR}/.preserved-context"
if [[ -f "$PRESERVE_FILE" && -s "$PRESERVE_FILE" ]]; then
    _WAS_COMPACTION=true

    # Extract resume directive block (lines starting with "RESUME DIRECTIVE:" and
    # following indented lines that are part of the same block).
    RESUME_BLOCK=""
    _in_resume=false
    while IFS= read -r line; do
        # Skip file-level header comments
        [[ "$line" =~ ^#.* ]] && continue
        if [[ "$line" =~ ^RESUME\ DIRECTIVE: ]]; then
            _in_resume=true
            RESUME_BLOCK="${line}"
        elif [[ "$_in_resume" == "true" && "$line" =~ ^[[:space:]] ]]; then
            RESUME_BLOCK="${RESUME_BLOCK}
${line}"
        elif [[ "$_in_resume" == "true" ]]; then
            _in_resume=false
        fi
    done < "$PRESERVE_FILE"

    # Inject resume directive as first element (highest priority)
    if [[ -n "$RESUME_BLOCK" ]]; then
        # Prepend before all other CONTEXT_PARTS by building a new array
        PRIORITY_CONTEXT=("ACTION REQUIRED — session resumed after compaction. ${RESUME_BLOCK}")
        CONTEXT_PARTS=("${PRIORITY_CONTEXT[@]}" "${CONTEXT_PARTS[@]}")
    fi

    # --- Plan file anchor injection (B2) ---
    # @decision DEC-BUDGET-001
    # @title Inject plan file anchor from preserved context into post-compaction session
    # @status accepted
    # @rationale compact-preserve.sh writes "PLAN FILE: <path>" when a recently-modified
    #   plan exists. Re-injecting it here as a high-priority context part ensures the
    #   post-compaction session knows exactly where to read its implementation plan.
    _PLAN_ANCHOR_PATH=""
    while IFS= read -r _pa_line; do
        if [[ "$_pa_line" =~ ^PLAN\ FILE:\ (.*) ]]; then
            _PLAN_ANCHOR_PATH="${BASH_REMATCH[1]}"
            break
        fi
    done < "$PRESERVE_FILE"

    if [[ -n "$_PLAN_ANCHOR_PATH" ]]; then
        CONTEXT_PARTS+=("POST-COMPACTION: Your implementation plan is at $_PLAN_ANCHOR_PATH. Read it before proceeding — it contains your detailed approach, file paths, and reasoning.")
    fi

    # Inject remaining metadata (everything except header comments and resume block)
    _in_resume=false
    _saw_resume=false
    CONTEXT_PARTS+=("Preserved context from before compaction:")
    while IFS= read -r line; do
        [[ "$line" =~ ^#.* ]] && continue
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^RESUME\ DIRECTIVE: ]]; then
            _saw_resume=true
            _in_resume=true
            continue
        elif [[ "$_in_resume" == "true" && "$line" =~ ^[[:space:]] ]]; then
            continue  # skip indented resume block lines
        else
            _in_resume=false
        fi
        CONTEXT_PARTS+=("  $line")
    done < "$PRESERVE_FILE"

    # --- Compaction forensics logging (B3) ---
    # @decision DEC-BUDGET-003
    # @title Compaction forensics log for post-mortem analysis of context loss
    # @status accepted
    # @rationale Instead of deleting the preserve file, renaming it to .last
    #   lets us inspect what was preserved after the fact. The .compaction-log
    #   accumulates a structured record (one line per compaction event) that can
    #   be used to diagnose context loss patterns. Format: pipe-delimited for easy
    #   parsing with cut/awk.
    _PRESERVE_LAST="${PRESERVE_FILE}.last"
    mv "$PRESERVE_FILE" "$_PRESERVE_LAST"

    _COMPACTION_LOG="${CLAUDE_DIR}/.compaction-log"
    _CL_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)
    _CL_LINES=$(wc -l < "$_PRESERVE_LAST" | tr -d ' ')
    _CL_HAS_RESUME="no"
    [[ -n "$RESUME_BLOCK" ]] && _CL_HAS_RESUME="yes"
    _CL_HAS_PLAN="no"
    [[ -n "${_PLAN_ANCHOR_PATH:-}" ]] && _CL_HAS_PLAN="$_PLAN_ANCHOR_PATH"
    echo "${_CL_TIMESTAMP}|${_CL_LINES}|${_CL_HAS_RESUME}|${_CL_HAS_PLAN}" >> "$_COMPACTION_LOG"
fi

# --- Stale state directory cleanup ---
# state/{phash}/proof-status files are superseded by SQLite proof_state table
# (DEC-STATE-UNIFY-004). Safe to remove — no readers remain after Gate A migration.
_PHASH_CLEANUP=$(project_hash "${PROJECT_ROOT:-}" 2>/dev/null || echo "")
if [[ -n "$_PHASH_CLEANUP" ]]; then
    rm -f "${CLAUDE_DIR}/state/${_PHASH_CLEANUP}/proof-status" 2>/dev/null
fi

# --- Archive legacy state.json ---
# state.json is superseded by state.db (DEC-STATE-UNIFY-003). Archive once.
if [[ -f "${CLAUDE_DIR}/state/state.json" && ! -f "${CLAUDE_DIR}/state/state.json.archive" ]]; then
    mv "${CLAUDE_DIR}/state/state.json" "${CLAUDE_DIR}/state/state.json.archive" 2>/dev/null || true
fi

# --- Stale session files ---
STALE_FILE_COUNT=0
for pattern in "${CLAUDE_DIR}/.session-changes"* "${CLAUDE_DIR}/.session-decisions"*; do
    [[ -f "$pattern" ]] && STALE_FILE_COUNT=$((STALE_FILE_COUNT + 1))
done
[[ "$STALE_FILE_COUNT" -gt 0 ]] && CONTEXT_PARTS+=("Stale session files: $STALE_FILE_COUNT from previous session")

# --- Stale breadcrumb cleanup REMOVED ---
# The .active-worktree-path breadcrumb system was retired in Phase 2/3.
# No writers exist for .active-worktree-path* files. After one session cycle,
# all old breadcrumbs will have been cleaned by the TTL sweep in session-end.sh.
# W3-3b: Block removed as part of RSM Phase 3 breadcrumb retirement (#78).

# --- Trace count canary: warn if significant drop since last session ---
# check_trace_count_canary() compares current directory count against the
# value written at last session end. >30% drop triggers a warning.
# Runs wrapped in set +e: non-fatal, and find may return non-zero on permission errors.
set +e
_CANARY_WARNING=$(check_trace_count_canary 2>/dev/null || echo "")
set -e
if [[ -n "$_CANARY_WARNING" ]]; then
    CONTEXT_PARTS+=("$_CANARY_WARNING")
fi

# --- Trace protocol: surface incomplete and recent traces ---
if [[ -d "$TRACE_STORE" ]]; then
    # Clean up stale active markers (agent crashed without SubagentStop)
    for marker in "$TRACE_STORE"/.active-*; do
        [[ ! -f "$marker" ]] && continue
        local_trace_id=$(cat "$marker" 2>/dev/null || echo "")
        if [[ -n "$local_trace_id" ]]; then
            local_manifest="$TRACE_STORE/$local_trace_id/manifest.json"
            if [[ -f "$local_manifest" ]]; then
                # Check if marker is stale (>2 hours)
                marker_age=$(( $(date +%s) - $(_file_mtime "$marker") ))
                # @decision DEC-STALE-THRESHOLD-001
                # @title Raise stale marker threshold from 15min to 60min
                # @status accepted
                # @rationale 15-minute threshold caused false crash detection for
                #   auto-flow implementers that legitimately run 85+40+30 turns
                #   (implement+test+commit). 60 minutes accommodates the longest
                #   realistic agent runs while still catching genuine stale markers.
                #   Uses finalize_trace instead of raw jq so manifests get proper
                #   duration, outcome, and test_result fields.
                if [[ "$marker_age" -gt 3600 ]]; then
                    # Mark as crashed first, then finalize for proper duration/outcome fields
                    (jq '.status = "crashed" | .outcome = "crashed"' "$local_manifest" > "${local_manifest}.tmp" 2>/dev/null && mv "${local_manifest}.tmp" "$local_manifest") || true
                    _ft_project=$(jq -r '.project // empty' "$local_manifest" 2>/dev/null || echo "")
                    _ft_agent=$(jq -r '.agent_type // empty' "$local_manifest" 2>/dev/null || echo "")
                    finalize_trace "$local_trace_id" "$_ft_project" "$_ft_agent" 2>/dev/null || true
                    index_trace "$local_trace_id"
                    rm -f "$marker"
                    CONTEXT_PARTS+=("Crashed trace detected: $local_trace_id (stale ${marker_age}s). Read summary: ~/.claude/traces/$local_trace_id/summary.md")
                fi
            else
                rm -f "$marker"
            fi
        fi
    done

    # Clean orphaned .proof-status (crash recovery)
    # At session start, if no agents are active FOR THIS PROJECT (active markers just
    # cleaned above), any .proof-status for this project is stale — including "verified"
    # from a session that crashed before Guardian ran. A stale "verified" would bypass
    # the proof gate for unrelated future work.
    # @decision DEC-ISOLATION-008
    # @title session-init counts only this project's active markers for proof cleanup
    # @status accepted
    # @rationale The original check used `ls .active-*` globally — counting markers from
    #   ALL projects. If Project A had an active agent, Project B's stale proof-status
    #   would be preserved even though no agents were running for Project B. Fix: count
    #   only markers with the project hash suffix. Also clean the scoped proof file.
    # _PHASH computed at line 59 (top-level, before TRACE_STORE conditional)
    # @decision DEC-SESSION-INIT-PROOF-CLEAN-001
    # @title Count only current-session markers for proof cleanup guard
    # @status accepted
    # @rationale At session start, markers from other sessions are stale by definition.
    #   Counting them prevented proof-status cleanup, creating a deadlock where stale
    #   proof-status persisted across sessions indefinitely.
    _CURRENT_SID="${CLAUDE_SESSION_ID:-}"
    if [[ -n "$_CURRENT_SID" ]]; then
        # At session start, only current-session markers matter (all others are stale by definition)
        # Note: ls glob failure (no matches) returns exit 1; 2>/dev/null suppresses the error message,
        # wc -l receives empty stdin and outputs "0". Using || true avoids the "0\n0" double-output
        # that occurred when `|| echo "0"` was appended to a pipeline that already outputs "0".
        ACTIVE_MARKERS=$(ls "$TRACE_STORE"/.active-*-"${_CURRENT_SID}-${_PHASH}" 2>/dev/null | wc -l | tr -d ' \n' || true)
        ACTIVE_MARKERS="${ACTIVE_MARKERS:-0}"
    else
        ACTIVE_MARKERS=$(ls "$TRACE_STORE"/.active-*-"${_PHASH}" 2>/dev/null | wc -l | tr -d ' \n' || true)
        ACTIVE_MARKERS="${ACTIVE_MARKERS:-0}"
    fi
    # Check both new path (state/{phash}/proof-status) and legacy path for stale proof cleanup
    _NEW_PROOF="${CLAUDE_DIR}/state/${_PHASH}/proof-status"
    _OLD_PROOF="${CLAUDE_DIR}/.proof-status-${_PHASH}"
    PROOF_FILE=""
    if [[ -f "$_NEW_PROOF" ]]; then
        PROOF_FILE="$_NEW_PROOF"
    elif [[ -f "$_OLD_PROOF" ]]; then
        PROOF_FILE="$_OLD_PROOF"
    fi
    if [[ -n "$PROOF_FILE" ]]; then
        if [[ "$ACTIVE_MARKERS" -eq 0 ]]; then
            PROOF_VAL=$(cut -d'|' -f1 "$PROOF_FILE" 2>/dev/null || echo "")
            rm -f "$_NEW_PROOF" "$_OLD_PROOF"  # Clean both locations
            CONTEXT_PARTS+=("Cleaned stale proof-status ($PROOF_VAL) — no active agents for this project, likely from crashed session")
        fi
    fi
    # One-time migration: remove legacy unscoped .proof-status if it exists
    if [[ -f "${CLAUDE_DIR}/.proof-status" ]]; then
        rm -f "${CLAUDE_DIR}/.proof-status"
        CONTEXT_PARTS+=("Migrated: removed legacy .proof-status (replaced by scoped .proof-status-${_PHASH})")
    fi

    # @decision DEC-EPOCH-RESET-004
    # @title Clean malformed workflow_ids in proof_state table at session start
    # @status accepted
    # @rationale Manual testing / probing can write proof_state rows with malformed
    #   workflow_ids like "_main" (no 8-char hex prefix). These rows are unreachable
    #   by any hook (workflow_id() always returns a valid hash_name format) and
    #   accumulate as test debris. Cleaning them at session start prevents confusion
    #   in state diagnostics. Valid workflow_ids match: 8-char-hex-hash underscore name.
    #   The "_main" entry was written by source="probe" — not a real hook (#228 test debris).
    if declare -f _state_sql >/dev/null 2>&1; then
        _state_sql "DELETE FROM proof_state WHERE workflow_id NOT GLOB '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]_*';" 2>/dev/null || true
    fi

    # Surface last completed trace for current project
    if [[ -f "$TRACE_STORE/index.jsonl" ]]; then
        PROJECT_NAME=$(basename "$PROJECT_ROOT")
        LAST_TRACE=$(grep "\"project_name\":\"${PROJECT_NAME}\"" "$TRACE_STORE/index.jsonl" 2>/dev/null | tail -1 || echo "")
        if [[ -n "$LAST_TRACE" ]]; then
            LT_ID=$(echo "$LAST_TRACE" | jq -r '.trace_id // empty' 2>/dev/null)
            LT_OUTCOME=$(echo "$LAST_TRACE" | jq -r '.outcome // "unknown"' 2>/dev/null)
            LT_TYPE=$(echo "$LAST_TRACE" | jq -r '.agent_type // "unknown"' 2>/dev/null)
            if [[ -n "$LT_ID" ]]; then
                CONTEXT_PARTS+=("Last trace: ${LT_TYPE} ${LT_OUTCOME} — ~/.claude/traces/${LT_ID}/summary.md")
            fi
        fi
    fi

    # --- Development Log Digest (issue #110) ---
    # Build a compact digest of the last 5 traces for the current project.
    # Each line shows: date, agent type, outcome, duration, files changed, branch.
    # Omitted when fewer than 2 project traces exist (not enough history to be useful).
    #
    # @decision DEC-OBS-P2-110
    # @title Compact development log digest injected at session start
    # @status accepted
    # @rationale New sessions start with minimal context about recent development
    #   activity. Injecting a structured digest of the last 5 traces lets the agent
    #   quickly orient: what was recently done, what branch it was on, and whether
    #   prior work succeeded. Limited to 5 traces and 7 output lines to avoid context
    #   bloat. Requires at least 2 project traces to have meaningful "recent activity"
    #   (single-trace sessions have the "Last trace:" line above for coverage).
    #   Fix for issue #110.
    if [[ -f "$TRACE_STORE/index.jsonl" ]]; then
        _DEV_PROJECT_NAME=$(basename "$PROJECT_ROOT")
        # Collect last 5 project traces (most recent first via tail)
        _DEV_TRACES=$(grep "\"project_name\":\"${_DEV_PROJECT_NAME}\"" "$TRACE_STORE/index.jsonl" 2>/dev/null | tail -5 | tac 2>/dev/null || true)
        # grep -c exits 1 on no matches (outputs "0") — use || true to avoid "0\n0" double-output
        _DEV_TRACE_COUNT=$(echo "$_DEV_TRACES" | grep -c . 2>/dev/null || true)
        _DEV_TRACE_COUNT="${_DEV_TRACE_COUNT:-0}"

        if [[ "$_DEV_TRACE_COUNT" -ge 2 ]]; then
            _DEV_LOG_LINES=()
            while IFS= read -r trace_entry; do
                [[ -z "$trace_entry" ]] && continue
                _DL_DATE=$(echo "$trace_entry" | jq -r '.started_at // ""' 2>/dev/null | cut -c1-10)
                _DL_AGENT=$(echo "$trace_entry" | jq -r '.agent_type // "?"' 2>/dev/null)
                _DL_OUTCOME=$(echo "$trace_entry" | jq -r '.outcome // "?"' 2>/dev/null)
                _DL_DUR=$(echo "$trace_entry" | jq -r '.duration_seconds // ""' 2>/dev/null)
                _DL_FILES=$(echo "$trace_entry" | jq -r '.files_changed // ""' 2>/dev/null)
                _DL_BRANCH=$(echo "$trace_entry" | jq -r '.branch // ""' 2>/dev/null)

                # Format duration: show as Xm Ys if >= 60s, else just Xs
                _DL_DUR_FMT=""
                if [[ -n "$_DL_DUR" && "$_DL_DUR" =~ ^[0-9]+$ && "$_DL_DUR" -gt 0 ]]; then
                    if [[ "$_DL_DUR" -ge 60 ]]; then
                        _DL_DUR_FMT="$(( _DL_DUR / 60 ))m$(( _DL_DUR % 60 ))s"
                    else
                        _DL_DUR_FMT="${_DL_DUR}s"
                    fi
                fi

                # Build compact line
                _DL_LINE="${_DL_DATE} | ${_DL_AGENT} | ${_DL_OUTCOME}"
                [[ -n "$_DL_DUR_FMT" ]] && _DL_LINE="${_DL_LINE} | ${_DL_DUR_FMT}"
                [[ -n "$_DL_FILES" ]] && _DL_LINE="${_DL_LINE} | ${_DL_FILES} files"
                [[ -n "$_DL_BRANCH" && "$_DL_BRANCH" != "unknown" ]] && _DL_LINE="${_DL_LINE} | ${_DL_BRANCH}"
                _DEV_LOG_LINES+=("  ${_DL_LINE}")
            done <<< "$_DEV_TRACES"

            if [[ "${#_DEV_LOG_LINES[@]}" -ge 2 ]]; then
                CONTEXT_PARTS+=("Development Log (last ${#_DEV_LOG_LINES[@]} sessions for ${_DEV_PROJECT_NAME}):")
                for _dl in "${_DEV_LOG_LINES[@]}"; do
                    CONTEXT_PARTS+=("$_dl")
                done
            fi
        fi
    fi
fi

# --- Todo HUD (inline from already-computed counts — no extra gh calls) ---
# Replaces the former todo.sh hud call which re-queried the same GitHub API
# endpoints, adding ~24s of serial latency (DEC-STARTUP-PERF-001).
_TODO_TOTAL=$(( TODO_PROJECT_COUNT + TODO_GLOBAL_COUNT ))
if (( _TODO_TOTAL > 0 )); then
    if (( TODO_PROJECT_COUNT > 0 && TODO_GLOBAL_COUNT > 0 )); then
        CONTEXT_PARTS+=("Backlog: ${TODO_PROJECT_COUNT} project + ${TODO_GLOBAL_COUNT} global todos pending")
    elif (( TODO_PROJECT_COUNT > 0 )); then
        CONTEXT_PARTS+=("Backlog: ${TODO_PROJECT_COUNT} project todos pending")
    elif (( TODO_GLOBAL_COUNT > 0 )); then
        CONTEXT_PARTS+=("Backlog: ${TODO_GLOBAL_COUNT} global todos pending")
    fi
fi

# --- Observatory suggestions ---
OBS_STATE="$HOME/.claude/observatory/state.json"
if [[ -f "$OBS_STATE" ]]; then
    OBS_PENDING=$(jq -r 'select(.pending_suggestion != null) | "\(.pending_title) (priority: \(.pending_priority))"' "$OBS_STATE" 2>/dev/null)
    [[ -n "$OBS_PENDING" ]] && CONTEXT_PARTS+=("Observatory: improvement ready — $OBS_PENDING. Run /observatory to review.")
fi

# --- Pending agent findings ---
FINDINGS_FILE="${CLAUDE_DIR}/.agent-findings"
if [[ -f "$FINDINGS_FILE" && -s "$FINDINGS_FILE" ]]; then
    CONTEXT_PARTS+=("Unresolved agent findings from previous session:")
    while IFS= read -r line; do
        CONTEXT_PARTS+=("  $line")
    done < "$FINDINGS_FILE"
fi

# --- Reset prompt-count so first-prompt fallback re-fires after /clear ---
# The first-prompt path in prompt-submit.sh is the reliable HUD injection point.
# Without this reset, /clear leaves the old prompt-count file and the fallback
# never triggers again, so the HUD disappears.
# DEC-STATE-KV-002: delete SQLite KV entries first (primary), then remove flat files (fallback).
state_delete "prompt_count" 2>/dev/null || true
state_delete "session_start_epoch" 2>/dev/null || true
rm -f "${CLAUDE_DIR}/.prompt-count-"*
rm -f "${CLAUDE_DIR}/.session-start-epoch"
rm -f "${CLAUDE_DIR}/.subagent-tracker"

# @decision DEC-STATE-DOTFILE-001
# @title Remove .proof-epoch flat file — SQLite proof_state.epoch is sole authority
# @status accepted
# @rationale .proof-epoch was a legacy mtime-based sentinel for monotonic lattice
#   enforcement in write_proof_status(). Since W5-2, proof_state_set() uses the
#   SQLite proof_state.epoch column exclusively. No code path reads the flat file.
#   Removal confirmed by static analysis: zero readers across all hooks/scripts.
mkdir -p "${CLAUDE_DIR}/state/${_PHASH}" 2>/dev/null || true
# Prune orphaned session-scoped tracker files from crashed sessions.
# Each tracker is named .subagent-tracker-<SESSION_ID_or_PID>.
# If the PID portion is numeric and the process is dead, the file is stale.
for tracker_file in "${CLAUDE_DIR}/.subagent-tracker-"*; do
    [[ ! -f "$tracker_file" ]] && continue
    tracker_id="${tracker_file##*-}"
    # If tracker_id looks like a PID (all digits), check if process is alive
    if [[ "$tracker_id" =~ ^[0-9]+$ ]]; then
        if ! kill -0 "$tracker_id" 2>/dev/null; then
            rm -f "$tracker_file"
        fi
    else
        # CLAUDE_SESSION_ID format — skip if it matches the current session
        if [[ "$tracker_id" != "${CLAUDE_SESSION_ID:-}" ]]; then
            # Age check: if older than 2 hours, safe to prune
            tracker_age=$(( $(date +%s) - $(_file_mtime "$tracker_file") ))
            if [[ "$tracker_age" -gt 7200 ]]; then
                rm -f "$tracker_file"
            fi
        fi
    fi
done

# --- Clear stale test status from previous session ---
# test-status is now a hard gate for commits (guard.sh Checks 6/7).
# Stale passing results from a previous session must not satisfy the gate.
# test-runner.sh will regenerate it after the first Write/Edit in this session.
# Read: KV primary (DEC-STATE-KV-005), state/{phash}/test-status fallback, .test-status legacy.
# Delete: KV + both flat-file paths.
_NEW_TEST="${CLAUDE_DIR}/state/${_PHASH}/test-status"
_OLD_TEST="${CLAUDE_DIR}/.test-status"
TEST_STATUS=""
TS_RESULT=""
TS_FAILS=0
# KV primary read (DEC-STATE-KV-005)
if type state_read &>/dev/null; then
    _kv_ts=$(state_read "test_status" 2>/dev/null || echo "")
    if [[ -n "$_kv_ts" ]]; then
        TS_RESULT=$(printf '%s' "$_kv_ts" | cut -d'|' -f1)
        TS_FAILS=$(printf '%s' "$_kv_ts" | cut -d'|' -f2)
        TEST_STATUS="kv"
    fi
fi
# Flat-file fallback (legacy paths)
if [[ -z "$TEST_STATUS" ]]; then
    if [[ -f "$_NEW_TEST" ]]; then
        TEST_STATUS="$_NEW_TEST"
    elif [[ -f "$_OLD_TEST" ]]; then
        TEST_STATUS="$_OLD_TEST"
    fi
    if [[ -n "$TEST_STATUS" && -f "$TEST_STATUS" ]]; then
        TS_RESULT=$(cut -d'|' -f1 "$TEST_STATUS")
        TS_FAILS=$(cut -d'|' -f2 "$TEST_STATUS")
    fi
fi
if [[ -n "$TEST_STATUS" ]]; then
    if [[ "$TS_RESULT" == "fail" ]]; then
        CONTEXT_PARTS+=("WARNING: Last test run FAILED ($TS_FAILS failures). test-gate.sh will block source writes until tests pass.")
    fi
    # Delete KV + flat-file entries
    if type state_delete &>/dev/null; then
        state_delete "test_status" 2>/dev/null || true
    fi
    rm -f "$_NEW_TEST" "$_OLD_TEST"  # Clean both flat-file locations
fi

# --- Smoke test: validate library sourcing ---
# Verifies that source-lib.sh (and its dependencies: log.sh, core-lib.sh) can be sourced without error.
# Catches corruption early (e.g., partial writes during git merge) before
# all hooks fail silently. Runs in a subshell so failures don't kill this hook.
if ! (source "$(dirname "$0")/source-lib.sh") 2>/dev/null; then
    CONTEXT_PARTS+=("WARNING: Hook library smoke test FAILED. source-lib.sh or log.sh may be corrupted. Run: bash -n ~/.claude/hooks/source-lib.sh && bash -n ~/.claude/hooks/log.sh")
fi

# --- CI health check (two-tier: state-file → live query) ---
# @decision DEC-CI-004 (see ci-lib.sh for full rationale)
# Tier 1: Read watcher state file (fast, no network call)
# Tier 2: Fall back to gh run list query (network call, only when stale/missing)
CI_TIER2_NEEDED=true
if read_ci_status "$PROJECT_ROOT"; then
    CI_TIER2_NEEDED=false
    case "$CI_STATUS" in
        failure)
            CONTEXT_PARTS+=("[WARN] CI: FAILING — $(format_ci_summary)")
            # Persist to .agent-findings so other hooks pick it up
            _CI_FINDINGS_FILE="${CLAUDE_DIR}/.agent-findings"
            echo "CI FAILING: $(format_ci_summary)" >> "$_CI_FINDINGS_FILE" 2>/dev/null || true
            # DEC-STATE-KV-007: Emit audit event alongside flat-file delivery (best-effort).
            _CI_TEXT=$(printf '%s' "$(format_ci_summary)" | sed 's/"/\\"/g')
            state_emit "agent.finding" "{\"agent\":\"CI\",\"text\":\"CI FAILING: ${_CI_TEXT}\"}" 2>/dev/null || true
            ;;
        pending)
            # Stale pending (> 30min) → fall through to Tier 2
            if [[ "$CI_AGE" -gt 1800 ]]; then
                CI_TIER2_NEEDED=true
            else
                CONTEXT_PARTS+=("CI: IN PROGRESS — $(format_ci_summary)")
            fi
            ;;
        success)
            # Stale success (> 1hr) → fall through to Tier 2
            if [[ "$CI_AGE" -gt 3600 ]]; then
                CI_TIER2_NEEDED=true
            else
                CONTEXT_PARTS+=("CI: passed — $(format_ci_summary)")
            fi
            ;;
        error)
            # Log silently — error state is not actionable for the user
            log_info "SESSION-INIT" "CI watcher in error state; skipping CI context"
            ;;
        *)
            CI_TIER2_NEEDED=true
            ;;
    esac
fi

# Tier 2: Read from background gh query launched earlier (DEC-STARTUP-PERF-001)
if [[ "$CI_TIER2_NEEDED" == "true" ]] && [[ -n "${_PID_CI:-}" ]]; then
    wait "$_PID_CI" 2>/dev/null || true
    _GH_CI_RAW=$(cat "$_GH_TMPDIR/ci" 2>/dev/null || echo "")
    if [[ -n "$_GH_CI_RAW" ]]; then
        _GH_CONCLUSION="${_GH_CI_RAW%%|*}"
        _GH_TIMESTAMP="${_GH_CI_RAW##*|}"
        if [[ "$_GH_CONCLUSION" == "failure" ]]; then
            CONTEXT_PARTS+=("[WARN] CI failing on ${GIT_BRANCH:-main} — last run failed (${_GH_TIMESTAMP}). Dispatch tester to verify.")
        fi
    fi
fi

# --- Tool-name canary: warn if settings.json matchers may be stale ---
# Claude Code has renamed tools before (Task→Agent). If it renames again,
# hooks will silently stop matching. This check reads settings.json matchers
# and warns if neither "Task" nor "Agent" appears in PreToolUse matchers.
_SETTINGS="$HOME/.claude/settings.json"
if [[ -f "$_SETTINGS" ]]; then
    _PRE_MATCHER=$(jq -r '.hooks.PreToolUse[]? | select(.hooks[]?.command | test("task-track")) | .matcher // ""' "$_SETTINGS" 2>/dev/null)
    if [[ -n "$_PRE_MATCHER" ]] && ! echo "$_PRE_MATCHER" | grep -qE 'Agent|Task'; then
        CONTEXT_PARTS+=("WARNING: PreToolUse matcher '$_PRE_MATCHER' may not match current agent dispatch tool. All dispatch gates may be silently disabled.")
    fi
fi

# --- Preflight integrity checks ---
# Fast validation of libraries, state files, and hook registration.
# diagnose.sh --quick completes in <250ms. Failures inject warnings;
# a crash of preflight itself does NOT block the session.
DIAGNOSE_SCRIPT="$HOME/.claude/skills/diagnose/scripts/diagnose.sh"
if [[ -x "$DIAGNOSE_SCRIPT" ]]; then
    PREFLIGHT_OUTPUT=$("$DIAGNOSE_SCRIPT" --quick 2>/dev/null) || true
    if [[ -n "$PREFLIGHT_OUTPUT" ]]; then
        # Extract WARN and FAIL lines only — PASS lines are noise in session context
        PREFLIGHT_ISSUES=$(echo "$PREFLIGHT_OUTPUT" | grep -E '^\[(WARN|FAIL)\]' || true)
        if [[ -n "$PREFLIGHT_ISSUES" ]]; then
            CONTEXT_PARTS+=("Preflight checks:")
            while IFS= read -r line; do
                CONTEXT_PARTS+=("  $line")
            done <<< "$PREFLIGHT_ISSUES"
        fi
    fi
fi

# --- Initialize session event log ---
# After compaction, preserve the event log — the trajectory is still relevant
# context for the resumed session. Only reset for fresh sessions (/clear, startup).
SESSION_EVENT_FILE="${CLAUDE_DIR}/.session-events.jsonl"
if [[ "${_WAS_COMPACTION:-false}" != "true" ]]; then
    rm -f "$SESSION_EVENT_FILE"  # Fresh log each non-compaction session
fi
append_session_event "session_start" "{\"project\":\"$(basename "$PROJECT_ROOT")\",\"branch\":\"${GIT_BRANCH:-unknown}\"}" "$PROJECT_ROOT"

# --- Prior session context (cross-session learning) ---
# Only inject when 3+ sessions exist; get_prior_sessions returns empty otherwise.
PRIOR_SESSIONS=$(get_prior_sessions "$PROJECT_ROOT" 2>/dev/null || echo "")
if [[ -n "$PRIOR_SESSIONS" ]]; then
    while IFS= read -r line; do
        CONTEXT_PARTS+=("$line")
    done <<< "$PRIOR_SESSIONS"
fi

# --- Output as additionalContext ---
if [[ ${#CONTEXT_PARTS[@]} -gt 0 ]]; then
    CONTEXT=$(printf '%s\n' "${CONTEXT_PARTS[@]}")
    ESCAPED=$(echo "$CONTEXT" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": $ESCAPED
  }
}
EOF
fi

exit 0
