#!/usr/bin/env bash
set -euo pipefail

# Pre-compaction context preservation.
# PreCompact hook
#
# Two outputs:
#   1. Persistent file: .claude/.preserved-context (survives compaction, read by session-init.sh)
#   2. additionalContext: injected into the system message before compaction
#
# The additionalContext includes a directive instructing Claude to generate
# a structured context summary (per context-preservation skill) as part of
# the compaction. This ensures session intent (not just project state) survives.

source "$(dirname "$0")/source-lib.sh"

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)
CONTEXT_PARTS=()

# --- Git state (via shared library) ---
get_git_state "$PROJECT_ROOT"

if [[ -n "$GIT_BRANCH" ]]; then
    GIT_LINE="Git: $GIT_BRANCH | $GIT_DIRTY_COUNT uncommitted"
    [[ "$GIT_WT_COUNT" -gt 0 ]] && GIT_LINE="$GIT_LINE | $GIT_WT_COUNT worktrees"
    CONTEXT_PARTS+=("$GIT_LINE")

    # Include worktree details (branch names help resume context)
    if [[ -n "$GIT_WORKTREES" ]]; then
        while IFS= read -r wt_line; do
            CONTEXT_PARTS+=("  worktree: $wt_line")
        done <<< "$GIT_WORKTREES"
    fi
fi

# --- MASTER_PLAN.md preamble: preserve for post-compaction context ---
# Living-document format: extract ## Identity + ## Architecture sections (bounded, ~25 lines).
# Legacy format: extract pre-`---` or pre-`## Original Intent` preamble.
if [[ -f "$PROJECT_ROOT/MASTER_PLAN.md" ]]; then
    HAS_INITIATIVES=$(grep -cE '^\#\#\#\s+Initiative:' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null || echo "0")
    if [[ "$HAS_INITIATIVES" -gt 0 ]]; then
        # Living-document format: bounded extraction of permanent sections
        IDENTITY_SECTION=$(awk '/^## Identity/{f=1; next} f && /^## /{exit} f{print}' \
            "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null | head -12)
        ARCH_SECTION=$(awk '/^## Architecture/{f=1; next} f && /^## /{exit} f{print}' \
            "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null | head -10)
        PREAMBLE=""
        [[ -n "$IDENTITY_SECTION" ]] && PREAMBLE="## Identity
${IDENTITY_SECTION}"
        [[ -n "$ARCH_SECTION" ]] && PREAMBLE="${PREAMBLE}
## Architecture
${ARCH_SECTION}"

        # Extract active initiative names for post-compaction resume context
        ACTIVE_INIT_NAMES=$(awk '
            /^## Active Initiatives/{in_active=1; next}
            in_active && /^## /{in_active=0; next}
            in_active && /^\#\#\# Initiative:/ { name=substr($0, index($0,":")+2) }
            in_active && /^\*\*Status:\*\* active/ { print name }
        ' "$PROJECT_ROOT/MASTER_PLAN.md" 2>/dev/null | head -5 | paste -sd', ' - || echo "")
        if [[ -n "$ACTIVE_INIT_NAMES" ]]; then
            PREAMBLE="${PREAMBLE}
Active initiatives: ${ACTIVE_INIT_NAMES}"
        fi
    else
        # Legacy format: extract pre-`---` or pre-`## Original Intent` preamble
        PREAMBLE=$(awk '/^---$|^## Original Intent/{exit} {print}' "$PROJECT_ROOT/MASTER_PLAN.md" | head -30)
    fi
    if [[ -n "$PREAMBLE" ]]; then
        CONTEXT_PARTS+=("$PREAMBLE")
    fi
fi

# --- MASTER_PLAN.md (via shared library) ---
get_plan_status "$PROJECT_ROOT"

if [[ "$PLAN_EXISTS" == "true" ]]; then
    PLAN_LINE="Plan: $PLAN_COMPLETED_PHASES/$PLAN_TOTAL_PHASES phases done"
    [[ -n "$PLAN_PHASE" ]] && PLAN_LINE="$PLAN_LINE | active: $PLAN_PHASE"
    CONTEXT_PARTS+=("$PLAN_LINE")
fi

# --- Plan file anchor (B2) ---
# @decision DEC-BUDGET-001
# @title Plan file as compaction anchor for post-compaction context continuity
# @status accepted
# @rationale After compaction, Claude loses its detailed implementation approach.
#   Storing the plan file path and a 20-line preview in the preserved context
#   file gives the post-compaction session an actionable anchor: it knows exactly
#   where to read to resume work. Modification-time gating (2h) ensures we only
#   anchor to plans that were actively in use this session, not stale plans from
#   prior work. Uses `_` prefix convention per namespace pollution rules.
_PLAN_FILE_ANCHOR=""
for _plan_candidate in \
    "$PROJECT_ROOT/plans/"*.md \
    "$PROJECT_ROOT/plan.md" \
    "$PROJECT_ROOT/PLAN.md"; do
    # glob may not match anything — skip if not a real file
    [[ ! -f "$_plan_candidate" ]] && continue
    # Check modification time: within last 2 hours (7200 seconds)
    if [[ "$(uname)" == "Darwin" ]]; then
        _plan_mtime=$(stat -f %m "$_plan_candidate" 2>/dev/null || echo "0")
    else
        _plan_mtime=$(stat -c %Y "$_plan_candidate" 2>/dev/null || echo "0")
    fi
    _now=$(date +%s)
    _age=$(( _now - _plan_mtime ))
    if [[ "$_age" -le 7200 ]]; then
        _PLAN_FILE_ANCHOR="$_plan_candidate"
        break
    fi
done

if [[ -n "$_PLAN_FILE_ANCHOR" ]]; then
    CONTEXT_PARTS+=("PLAN FILE: $_PLAN_FILE_ANCHOR")
    CONTEXT_PARTS+=("READ THIS FILE after compaction — it contains your detailed implementation approach.")
    # Preview: first 20 lines, each prefixed with two spaces (Pattern B: [[ =~ ]] not grep)
    _plan_preview_lines=()
    _plan_line_num=0
    while IFS= read -r _plan_line && [[ "$_plan_line_num" -lt 20 ]]; do
        _plan_preview_lines+=("  $_plan_line")
        _plan_line_num=$(( _plan_line_num + 1 ))
    done < "$_PLAN_FILE_ANCHOR"
    for _preview_line in "${_plan_preview_lines[@]}"; do
        CONTEXT_PARTS+=("$_preview_line")
    done
fi

# --- Session file changes ---
get_session_changes "$PROJECT_ROOT"

if [[ -n "$SESSION_FILE" && -f "$SESSION_FILE" ]]; then
    FILE_COUNT=$(sort -u "$SESSION_FILE" | wc -l | tr -d ' ')
    FILE_LIST=$(sort -u "$SESSION_FILE" | head -5 | xargs -I{} basename {} | paste -sd', ' -)
    REMAINING=$((FILE_COUNT - 5))
    if [[ "$REMAINING" -gt 0 ]]; then
        CONTEXT_PARTS+=("Modified this session: $FILE_LIST (+$REMAINING more)")
    else
        CONTEXT_PARTS+=("Modified this session: $FILE_LIST")
    fi

    # Full paths for context (written to file, not displayed)
    FULL_PATHS=$(sort -u "$SESSION_FILE" | head -10)

    # --- Key @decisions made this session ---
    DECISIONS_FOUND=()
    while IFS= read -r file; do
        [[ ! -f "$file" ]] && continue
        decision_line=$(grep -oE '@decision\s+[A-Z]+-[A-Z0-9-]+' "$file" 2>/dev/null | head -1 || echo "")
        if [[ -n "$decision_line" ]]; then
            DECISIONS_FOUND+=("$decision_line ($(basename "$file"))")
        fi
    done < <(sort -u "$SESSION_FILE")

    if [[ ${#DECISIONS_FOUND[@]} -gt 0 ]]; then
        DECISIONS_LINE=$(printf '%s, ' "${DECISIONS_FOUND[@]:0:5}")
        CONTEXT_PARTS+=("Decisions: ${DECISIONS_LINE%, }")
    fi

    # --- SPECIFICS: concrete breadcrumbs for post-compaction context (B1) ---
    # @decision DEC-BUDGET-002
    # @title SPECIFICS section in compact-preserve.sh for concrete breadcrumbs
    # @status accepted
    # @rationale Basename-only file lists lose the path context needed to reopen
    #   files after compaction. Full paths (up to 15) plus git diff --stat for
    #   non-main branches provide the concrete breadcrumbs a post-compaction
    #   session needs. Scoped inside the SESSION_FILE block since specifics are
    #   only meaningful when session changes exist. Pattern A (awk NR<=N) avoids
    #   SIGPIPE from head in pipelines; `_` prefix avoids namespace pollution.
    _SPECIFICS_LINES=()
    _SPECIFICS_LINES+=("SPECIFICS:")
    _SPECIFICS_LINES+=("  Session files (full paths):")

    # Full paths, up to 15 (Pattern A: awk NR<=15 not pipe to head)
    _spec_file_count=0
    while IFS= read -r _spec_path; do
        [[ -z "$_spec_path" ]] && continue
        _SPECIFICS_LINES+=("    $_spec_path")
        _spec_file_count=$(( _spec_file_count + 1 ))
        [[ "$_spec_file_count" -ge 15 ]] && break
    done < <(sort -u "$SESSION_FILE")

    # Recent git changes (non-main branch only)
    _GIT_DIFF_LINES=""
    if [[ -n "${GIT_BRANCH:-}" && "$GIT_BRANCH" != "main" && "$GIT_BRANCH" != "master" ]]; then
        _GIT_DIFF_LINES=$(git -C "$PROJECT_ROOT" diff --stat HEAD 2>/dev/null | awk 'NR<=5{print}' || true)
    fi
    if [[ -n "$_GIT_DIFF_LINES" ]]; then
        _SPECIFICS_LINES+=("  Recent git changes:")
        while IFS= read -r _diff_line; do
            [[ -z "$_diff_line" ]] && continue
            _SPECIFICS_LINES+=("    $_diff_line")
        done <<< "$_GIT_DIFF_LINES"
    fi

    for _spec_line in "${_SPECIFICS_LINES[@]}"; do
        CONTEXT_PARTS+=("$_spec_line")
    done
fi

# --- Test status ---
TEST_STATUS="${CLAUDE_DIR}/.test-status"
if [[ -f "$TEST_STATUS" ]]; then
    TS_RESULT=$(cut -d'|' -f1 "$TEST_STATUS")
    TS_FAILS=$(cut -d'|' -f2 "$TEST_STATUS")
    CONTEXT_PARTS+=("Test status: ${TS_RESULT} (${TS_FAILS} failures)")
fi

# --- Agent findings (unresolved issues from subagents) ---
FINDINGS_FILE="${CLAUDE_DIR}/.agent-findings"
if [[ -f "$FINDINGS_FILE" && -s "$FINDINGS_FILE" ]]; then
    CONTEXT_PARTS+=("Unresolved agent findings:")
    while IFS= read -r line; do
        CONTEXT_PARTS+=("  $line")
    done < "$FINDINGS_FILE"
fi

# --- Active traces ---
if [[ -d "$TRACE_STORE" ]]; then
    for marker in "$TRACE_STORE"/.active-*; do
        [[ ! -f "$marker" ]] && continue
        active_trace_id=$(cat "$marker" 2>/dev/null || echo "")
        if [[ -n "$active_trace_id" ]]; then
            CONTEXT_PARTS+=("Active trace: $active_trace_id (agent still running). TRACE_DIR=~/.claude/traces/$active_trace_id")
        fi
    done
fi

# --- Audit trail (last 5) ---
AUDIT_LOG="${CLAUDE_DIR}/.audit-log"
if [[ -f "$AUDIT_LOG" && -s "$AUDIT_LOG" ]]; then
    CONTEXT_PARTS+=("Recent audit (last 5):")
    while IFS= read -r line; do
        CONTEXT_PARTS+=("  $line")
    done < <(tail -5 "$AUDIT_LOG")
fi

# --- Session trajectory ---
TRAJ_SUMMARY=$(get_session_summary_context "$PROJECT_ROOT")
if [[ -n "$TRAJ_SUMMARY" ]]; then
    CONTEXT_PARTS+=("$TRAJ_SUMMARY")
fi

# --- Resume directive ---
build_resume_directive "$PROJECT_ROOT"
if [[ -n "$RESUME_DIRECTIVE" ]]; then
    CONTEXT_PARTS+=("")
    CONTEXT_PARTS+=("$RESUME_DIRECTIVE")
fi

# --- Write persistent file ---
# This file survives compaction and is read by session-init.sh on the
# SessionStart(compact) event. Belt-and-suspenders: even if the
# additionalContext is lost during compaction, session-init.sh can
# re-inject this data.
PRESERVE_FILE="${CLAUDE_DIR}/.preserved-context"
if [[ ${#CONTEXT_PARTS[@]} -gt 0 ]]; then
    mkdir -p "$PROJECT_ROOT/.claude"
    {
        echo "# Preserved context from pre-compaction ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
        printf '%s\n' "${CONTEXT_PARTS[@]}"
        # Include full file paths for re-navigation
        if [[ -n "${FULL_PATHS:-}" ]]; then
            echo ""
            echo "# Full paths of session-modified files:"
            echo "$FULL_PATHS"
        fi
    } > "$PRESERVE_FILE"
fi

# --- Output additionalContext ---
# Includes both the project state AND a directive for Claude to generate
# a structured context summary during compaction.
if [[ ${#CONTEXT_PARTS[@]} -gt 0 ]]; then
    DIRECTIVE="POST-COMPACTION: The RESUME DIRECTIVE below was computed from session state. Preserve it verbatim in the summary — it tells the next session what to do."

    CONTEXT=$(printf '%s\n' "${CONTEXT_PARTS[@]}")
    FULL_OUTPUT="${DIRECTIVE}

--- Project State ---
${CONTEXT}"
    ESCAPED=$(echo "$FULL_OUTPUT" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreCompact",
    "additionalContext": $ESCAPED
  }
}
EOF
fi

exit 0
