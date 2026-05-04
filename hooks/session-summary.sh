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
seed_project_dir_from_hook_payload_cwd "$HOOK_INPUT"

# Prevent re-firing loops
STOP_ACTIVE=$(echo "$HOOK_INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
if [[ "$STOP_ACTIVE" == "true" ]]; then
    exit 0
fi

PROJECT_ROOT=$(detect_project_root)

# Find session tracking file
get_session_changes "$PROJECT_ROOT"
CHANGES_TEXT="${SESSION_CHANGES_TEXT:-}"

# No tracked changes → no summary needed
if [[ -z "$CHANGES_TEXT" ]]; then
    exit 0
fi

# Count unique files changed
TOTAL_FILES=$(printf '%s\n' "$CHANGES_TEXT" | sort -u | wc -l | tr -d ' ') || TOTAL_FILES=0
[[ "$TOTAL_FILES" -eq 0 ]] && exit 0

# Count source vs non-source
SOURCE_EXTS="($SOURCE_EXTENSIONS)"
SOURCE_COUNT=$(printf '%s\n' "$CHANGES_TEXT" | sort -u | grep -cE "\\.${SOURCE_EXTS}$") || SOURCE_COUNT=0
CONFIG_COUNT=$(( TOTAL_FILES - SOURCE_COUNT ))

# Check for @decision annotations added this session
DECISIONS_ADDED=0
DECISION_PATTERN='@decision|# DECISION:|// DECISION\('
while IFS= read -r file; do
    [[ ! -f "$file" ]] && continue
    if grep -qE "$DECISION_PATTERN" "$file" 2>/dev/null; then
        ((DECISIONS_ADDED++)) || true
    fi
done < <(printf '%s\n' "$CHANGES_TEXT" | sort -u)

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

# Test status from state.db. Wait briefly for async test-runner if a Write/Edit
# triggered it just before the model finished.
TEST_RESULT="unknown"
TEST_FAILS=0

# Brief wait for async test-runner if it's still running
if pgrep -f "test-runner\\.sh" >/dev/null 2>&1; then
    for _i in 1 2 3; do
        sleep 1
        ! pgrep -f "test-runner\\.sh" >/dev/null 2>&1 && break
    done
fi

TEST_STATE_JSON=$(rt_test_state_get "$PROJECT_ROOT" 2>/dev/null || echo '{"found":false}')
if [[ "$(printf '%s' "$TEST_STATE_JSON" | jq -r '.found // false' 2>/dev/null || echo "false")" == "true" ]]; then
    TEST_RESULT=$(printf '%s' "$TEST_STATE_JSON" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
    TEST_FAILS=$(printf '%s' "$TEST_STATE_JSON" | jq -r '.fail_count // 0' 2>/dev/null || echo "0")
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
        NEXT_ACTION="Dispatch Reviewer for evaluation. Guardian can commit when the Reviewer issues REVIEW_VERDICT=ready_for_guardian."
    else
        NEXT_ACTION="If the reviewer completion verdict is ready_for_guardian, use Guardian to merge or commit. Otherwise dispatch Reviewer first."
    fi
fi

# --- Pending todos reminder ---
TODO_SCRIPT="$HOME/.claude/scripts/todo.sh"
if [[ -x "$TODO_SCRIPT" ]] && command -v gh >/dev/null 2>&1; then
    TODO_COUNTS=$("$TODO_SCRIPT" count --all 2>/dev/null || echo "0|0|0")
    TODO_PROJECT=$(echo "$TODO_COUNTS" | cut -d'|' -f1)
    TODO_GLOBAL=$(echo "$TODO_COUNTS" | cut -d'|' -f2)
    TODO_TOTAL=$((TODO_PROJECT + TODO_GLOBAL))

    if [[ "$TODO_TOTAL" -gt 0 ]]; then
        SUMMARY+="\nTodos: ${TODO_PROJECT} project + ${TODO_GLOBAL} global pending."
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
