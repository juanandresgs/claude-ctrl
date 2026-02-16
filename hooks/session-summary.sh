#!/usr/bin/env bash
set -euo pipefail

# Stop hook: deterministic session summary.
# Replaces AI agent Stop hook. Reads session tracking, produces concise summary.
# Bounded runtime (<2s). Reports via systemMessage.
#
# DECISION: Deterministic session summary. Rationale: AI agent Stop hooks cause
# "stuck on Stop hooks 2/3" lockup due to non-deterministic inference time.
# Every metric here is a wc/grep that completes instantly. Status: accepted.

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

HOOK_INPUT=$(read_input)

# Prevent re-firing loops
STOP_ACTIVE=$(echo "$HOOK_INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
if [[ "$STOP_ACTIVE" == "true" ]]; then
    exit 0
fi

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)

# Find session tracking file
SESSION_ID="${CLAUDE_SESSION_ID:-}"
CHANGES=""
if [[ -n "$SESSION_ID" && -f "${CLAUDE_DIR}/.session-changes-${SESSION_ID}" ]]; then
    CHANGES="${CLAUDE_DIR}/.session-changes-${SESSION_ID}"
elif [[ -f "${CLAUDE_DIR}/.session-changes" ]]; then
    CHANGES="${CLAUDE_DIR}/.session-changes"
fi

# No tracking file → no summary needed
if [[ -z "$CHANGES" || ! -f "$CHANGES" ]]; then
    exit 0
fi

# Count unique files changed (guard against empty file)
TOTAL_FILES=$(sort -u "$CHANGES" 2>/dev/null | wc -l | tr -d ' ') || TOTAL_FILES=0
[[ "$TOTAL_FILES" -eq 0 ]] && exit 0

# Count source vs non-source
SOURCE_EXTS='(ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh)'
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

# --- Pending todos reminder ---
TODO_SCRIPT="$HOME/.claude/scripts/todo.sh"
if [[ -x "$TODO_SCRIPT" ]] && command -v gh >/dev/null 2>&1; then
    TODO_COUNTS=$("$TODO_SCRIPT" count --all 2>/dev/null || echo "0|0|0|0")
    TODO_PROJECT=$(echo "$TODO_COUNTS" | cut -d'|' -f1)
    TODO_GLOBAL=$(echo "$TODO_COUNTS" | cut -d'|' -f2)
    TODO_CONFIG=$(echo "$TODO_COUNTS" | cut -d'|' -f3)
    TODO_TOTAL=$((TODO_PROJECT + TODO_GLOBAL + TODO_CONFIG))

    if [[ "$TODO_TOTAL" -gt 0 ]]; then
        SUMMARY+="\nTodos: ${TODO_PROJECT} project + ${TODO_GLOBAL} global + ${TODO_CONFIG} config pending."
    fi
fi

SUMMARY+="\nNext: $NEXT_ACTION"

# Output as systemMessage
ESCAPED=$(echo -e "$SUMMARY" | jq -Rs .)
cat <<EOF
{
  "systemMessage": $ESCAPED
}
EOF

exit 0
