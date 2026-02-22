#!/usr/bin/env bash
# Stop hook: deterministic session summary with trajectory-aware narrative.
# Replaces AI agent Stop hook. Reads session tracking, produces concise summary.
# Bounded runtime (<2s). Reports via systemMessage.
#
# @decision DEC-SUMMARY-001
# @title Deterministic session summary with trajectory narrative
# @status accepted
# @rationale AI agent Stop hooks cause "stuck on Stop hooks 2/3" lockup due to
# non-deterministic inference time. Every metric here is a wc/grep/awk that
# completes instantly. v2 Phase 3 adds trajectory narrative: calls
# get_session_trajectory() and detect_approach_pivots() to surface edit->fail
# loops, most-failed assertions, and pivot counts in the summary. Trajectory
# calls are wrapped in set +e because grep pipelines exit 1 on no match.
set -euo pipefail

source "$(dirname "$0")/source-lib.sh"

HOOK_INPUT=$(read_input)

# Prevent re-firing loops
STOP_ACTIVE=$(get_field '.stop_hook_active')
STOP_ACTIVE="${STOP_ACTIVE:-false}"
if [[ "$STOP_ACTIVE" == "true" ]]; then
    exit 0
fi

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)

# Observatory v2: refinalize_stale_traces() was deleted (DEC-OBS-V2-002).
# Compliance data is now recorded at agent boundaries by check-*.sh hooks.
# No stale-trace re-finalization needed at session end.

# Backup trace manifests at session end (defense against data loss between sessions).
# ~2s for 500 manifests. Keeps last 3 compressed archives in TRACE_STORE.
# Wrapped in set +e: non-fatal if tar fails (e.g., no manifests yet).
set +e
backup_trace_manifests 2>/dev/null
set -e

# Find session tracking file via shared library (DEC-V3-005)
get_session_changes "$PROJECT_ROOT"
CHANGES="${SESSION_FILE:-}"

# No tracking file → no summary needed
if [[ -z "$CHANGES" || ! -f "$CHANGES" ]]; then
    exit 0
fi

# Count unique files changed (guard against empty file)
TOTAL_FILES=$(sort -u "$CHANGES" 2>/dev/null | wc -l | tr -d ' ') || TOTAL_FILES=0
[[ "$TOTAL_FILES" -eq 0 ]] && exit 0

# Count source vs non-source
# Use shared SOURCE_EXTENSIONS from context-lib.sh (DEC-V3-005)
SOURCE_EXTS="($SOURCE_EXTENSIONS)"
SOURCE_COUNT=$(sort -u "$CHANGES" 2>/dev/null | grep -cE "\\.${SOURCE_EXTS}$") || SOURCE_COUNT=0
CONFIG_COUNT=$(( TOTAL_FILES - SOURCE_COUNT ))

# Check for @decision annotations added this session
DECISIONS_ADDED=0
DECISION_PATTERN='@decision|# DECISION:|// DECISION\('
while IFS= read -r file; do
    [[ ! -f "$file" ]] && continue
    if grep -qE "$DECISION_PATTERN" "$file" 2>/dev/null; then
        ((DECISIONS_ADDED++)) || true
    fi
done < <(sort -u "$CHANGES" 2>/dev/null)

# Build summary (3-4 lines max)
SUMMARY="Session: $TOTAL_FILES file(s) changed"
if [[ "$SOURCE_COUNT" -gt 0 ]]; then
    SUMMARY+=" ($SOURCE_COUNT source, $CONFIG_COUNT config/other)"
fi
if [[ "$DECISIONS_ADDED" -gt 0 ]]; then
    SUMMARY+=". $DECISIONS_ADDED file(s) with @decision annotations."
fi

# Git + plan + test state via context-lib
get_git_state "$PROJECT_ROOT"
get_plan_status "$PROJECT_ROOT"

# Test status from test-runner.sh (format: "result|fail_count|timestamp")
# Staleness guard: treat .test-status older than 30 minutes as unknown.
# Without this, a days-old "pass" could mislead into suggesting "commit"
# when tests haven't been run this session.
#
# Wait loop: test-runner.sh runs async (PostToolUse). If a Write/Edit triggered
# it just before the model finished, .test-status may not exist yet. Wait briefly
# if test-runner is still running so we can capture the result rather than report
# "not run" while tests are actually in-flight.
TEST_RESULT="unknown"
TEST_FAILS=0
TEST_STATUS_FILE="${CLAUDE_DIR}/.test-status"

# Brief wait for async test-runner if it's still running
if [[ ! -f "$TEST_STATUS_FILE" ]] && pgrep -f "test-runner\\.sh" >/dev/null 2>&1; then
    for _i in 1 2 3; do
        sleep 1
        [[ -f "$TEST_STATUS_FILE" ]] && break
    done
    # If still no file but process finished, give one more beat
    if [[ ! -f "$TEST_STATUS_FILE" ]] && ! pgrep -f "test-runner\\.sh" >/dev/null 2>&1; then
        sleep 0.5
    fi
fi

if [[ -f "$TEST_STATUS_FILE" ]]; then
    FILE_MOD=$(stat -c '%Y' "$TEST_STATUS_FILE" 2>/dev/null || stat -f '%m' "$TEST_STATUS_FILE" 2>/dev/null || echo "0")
    NOW=$(date +%s)
    FILE_AGE=$(( NOW - FILE_MOD ))
    if [[ "$FILE_AGE" -le "$SESSION_STALENESS_THRESHOLD" ]]; then
        TEST_RESULT=$(cut -d'|' -f1 "$TEST_STATUS_FILE")
        TEST_FAILS=$(cut -d'|' -f2 "$TEST_STATUS_FILE")
    fi
fi

# Git line: branch + dirty/clean + test status
GIT_LINE="Git: branch=$GIT_BRANCH"
if [[ "$GIT_DIRTY_COUNT" -gt 0 ]]; then
    GIT_LINE+=", $GIT_DIRTY_COUNT uncommitted"
else
    GIT_LINE+=", clean"
fi
case "$TEST_RESULT" in
    pass)    GIT_LINE+=". Tests: passing." ;;
    fail)    GIT_LINE+=". Tests: FAILING ($TEST_FAILS failure(s))." ;;
    *)       GIT_LINE+=". Tests: not run this session." ;;
esac
SUMMARY+="\n$GIT_LINE"

# Proof-of-work status line (W7-1: #42 residual, #134)
PROOF_STATUS_FILE="${CLAUDE_DIR}/.proof-status"
if [[ -f "$PROOF_STATUS_FILE" ]]; then
    _PROOF_VAL=$(cut -d'|' -f1 "$PROOF_STATUS_FILE" 2>/dev/null || echo "")
    case "$_PROOF_VAL" in
        verified)          SUMMARY+="\nProof: verified." ;;
        pending)           SUMMARY+="\nProof: PENDING." ;;
        needs-verification) SUMMARY+="\nProof: PENDING." ;;
        *)                 SUMMARY+="\nProof: not started." ;;
    esac
else
    SUMMARY+="\nProof: not started."
fi

# Workflow phase detection → next-action guidance
IS_MAIN=false
[[ "$GIT_BRANCH" == "main" || "$GIT_BRANCH" == "master" ]] && IS_MAIN=true

NEXT_ACTION=""
if $IS_MAIN; then
    if [[ "$PLAN_EXISTS" != "true" ]]; then
        NEXT_ACTION="Create MASTER_PLAN.md before implementation."
    elif [[ "$GIT_WT_COUNT" -eq 0 ]]; then
        NEXT_ACTION="Use Guardian to create worktrees for implementation."
    else
        NEXT_ACTION="Continue implementation in active worktrees."
    fi
else
    # Feature branch
    if [[ "$TEST_RESULT" == "fail" ]]; then
        NEXT_ACTION="Fix failing tests ($TEST_FAILS failure(s)) before proceeding."
    elif [[ "$TEST_RESULT" != "pass" ]]; then
        NEXT_ACTION="Run tests to verify implementation before committing."
    elif [[ "$GIT_DIRTY_COUNT" -gt 0 ]]; then
        NEXT_ACTION="Review changes with user, then commit in this worktree when approved."
    else
        NEXT_ACTION="User should test the feature. When satisfied, use Guardian to merge to main."
    fi
fi

# Todo reminder removed (requires todo.sh — personal component)

SUMMARY+="\nNext: $NEXT_ACTION"

# --- Trajectory narrative (from session event log) ---
# Call get_session_trajectory and detect_approach_pivots to build a
# human-readable retrospective of what happened this session.
EVENTS_FILE="${CLAUDE_DIR}/.session-events.jsonl"
if [[ -f "$EVENTS_FILE" ]]; then
    # These functions use grep pipelines that exit 1 on no match; guard with set +e
    set +e
    get_session_trajectory "$PROJECT_ROOT"
    detect_approach_pivots "$PROJECT_ROOT"
    set -e

    TRAJ_LINE=""

    if [[ "${TRAJ_TOOL_CALLS:-0}" -gt 0 ]]; then
        TRAJ_LINE="Trajectory: ${TRAJ_TOOL_CALLS} write(s) across ${TRAJ_FILES_MODIFIED} file(s)."
    fi

    if [[ "${TRAJ_TEST_FAILURES:-0}" -gt 0 ]]; then
        TRAJ_LINE="$TRAJ_LINE ${TRAJ_TEST_FAILURES} test failure(s)."
        # Surface the most-failed assertion if available
        TOP_ASSERTION=$(grep '"event":"test_run"' "$EVENTS_FILE" 2>/dev/null \
            | grep '"result":"fail"' \
            | jq -r '.assertion // empty' 2>/dev/null \
            | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
        if [[ -n "$TOP_ASSERTION" && "$TOP_ASSERTION" != "null" && "$TOP_ASSERTION" != "unknown" ]]; then
            TRAJ_LINE="$TRAJ_LINE Most-failed: \`${TOP_ASSERTION}\`."
        fi
    fi

    if [[ "${PIVOT_COUNT:-0}" -gt 0 ]]; then
        TRAJ_LINE="$TRAJ_LINE ${PIVOT_COUNT} approach pivot(s) detected (edit->fail loop)."
        if [[ -n "${PIVOT_FILES:-}" ]]; then
            PIVOT_BASE=$(echo "$PIVOT_FILES" | tr ' ' '\n' | xargs -I{} basename {} 2>/dev/null | paste -sd ', ' - || echo "$PIVOT_FILES")
            TRAJ_LINE="$TRAJ_LINE Looping files: ${PIVOT_BASE}."
        fi
    fi

    if [[ "${TRAJ_GATE_BLOCKS:-0}" -gt 0 ]]; then
        TRAJ_LINE="$TRAJ_LINE ${TRAJ_GATE_BLOCKS} gate block(s)."
    fi

    if [[ -n "${TRAJ_AGENTS:-}" ]]; then
        TRAJ_LINE="$TRAJ_LINE Agents: ${TRAJ_AGENTS}."
    fi

    if [[ -n "$TRAJ_LINE" ]]; then
        SUMMARY+="\n$TRAJ_LINE"
    fi

    # Write structured retrospective to sessions dir if it exists
    SESSIONS_DIR="$HOME/.claude/sessions"
    if [[ -d "$SESSIONS_DIR" ]]; then
        PROJECT_HASH=$(echo "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-8 || echo "unknown")
        SESSION_DIR="$SESSIONS_DIR/$PROJECT_HASH"
        mkdir -p "$SESSION_DIR"

        SESSION_LABEL="${CLAUDE_SESSION_ID:-$(date +%Y%m%d-%H%M%S)}"
        RETRO_FILE="$SESSION_DIR/${SESSION_LABEL}-summary.md"

        cat > "$RETRO_FILE" <<RETRO
# Session Retrospective

**Date:** $(date -u +%Y-%m-%dT%H:%M:%SZ)
**Project:** $PROJECT_ROOT
**Branch:** $GIT_BRANCH

## Changes
- Files changed: $TOTAL_FILES ($SOURCE_COUNT source, $CONFIG_COUNT config/other)
- Decisions annotated: $DECISIONS_ADDED

## Test Status
- Result: $TEST_RESULT
- Failures: $TEST_FAILS

## Trajectory
- Writes: ${TRAJ_TOOL_CALLS:-0} across ${TRAJ_FILES_MODIFIED:-0} file(s)
- Test failures: ${TRAJ_TEST_FAILURES:-0}
- Gate blocks: ${TRAJ_GATE_BLOCKS:-0}
- Approach pivots: ${PIVOT_COUNT:-0}
- Pivot files: ${PIVOT_FILES:-none}
- Pivot assertions: ${PIVOT_ASSERTIONS:-none}
- Agents used: ${TRAJ_AGENTS:-none}
- Duration: ${TRAJ_ELAPSED_MIN:-0}m

## Next
$NEXT_ACTION
RETRO
    fi
fi

# Output as systemMessage
ESCAPED=$(echo -e "$SUMMARY" | jq -Rs .)
cat <<EOF
{
  "systemMessage": $ESCAPED
}
EOF

exit 0
