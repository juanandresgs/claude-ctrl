#!/usr/bin/env bash
# Escalating test-failure gate for source code writes.
# PreToolUse hook — matcher: Write|Edit
#
# DECISION: Escalating test gate enforcement. Rationale: Async test-runner
# results arrived too late to prevent compounding errors. This hook reads
# .test-status (written by test-runner.sh) and blocks source writes after
# 2+ consecutive attempts while tests are failing. Test files are always
# exempt so fixes can proceed. Status: accepted.
#
# Reads:  .claude/.test-status    (format: "result|fail_count|timestamp")
# Writes: .claude/.test-gate-strikes (format: "strike_count|last_strike_epoch")
#
# Logic:
#   - No .test-status → ALLOW (no test data yet)
#   - .test-status says "pass" → ALLOW + reset strikes
#   - .test-status older than 10 min → ALLOW (stale)
#   - .test-status says "fail" + fresh:
#       Strike 1 → ALLOW with advisory warning
#       Strike 2+ → DENY
#   - Test files always ALLOW, never increment strikes
#   - Non-source files always ALLOW
set -euo pipefail

source "$(dirname "$0")/source-lib.sh"

HOOK_INPUT=$(read_input)
FILE_PATH=$(get_field '.tool_input.file_path')

# Exit silently if no file path
[[ -z "$FILE_PATH" ]] && exit 0

# Non-source files always pass
is_source_file "$FILE_PATH" || exit 0

# Skip .claude config directory
[[ "$FILE_PATH" =~ \.claude/ ]] && exit 0

# Skip non-source directories (vendor, node_modules, etc.)
is_skippable_path "$FILE_PATH" && exit 0

# --- Test file exemption: always allow, never increment strikes ---
is_test_file "$FILE_PATH" && exit 0

# --- Read test status ---
PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)
TEST_STATUS_FILE="${CLAUDE_DIR}/.test-status"
STRIKES_FILE="${CLAUDE_DIR}/.test-gate-strikes"

# No test status yet → allow (with cold-start advisory if test framework detected)
if [[ ! -f "$TEST_STATUS_FILE" ]]; then
    HAS_TESTS=false
    [[ -f "$PROJECT_ROOT/pyproject.toml" ]] && HAS_TESTS=true
    [[ -f "$PROJECT_ROOT/vitest.config.ts" || -f "$PROJECT_ROOT/vitest.config.js" ]] && HAS_TESTS=true
    [[ -f "$PROJECT_ROOT/jest.config.ts" || -f "$PROJECT_ROOT/jest.config.js" ]] && HAS_TESTS=true
    [[ -f "$PROJECT_ROOT/Cargo.toml" ]] && HAS_TESTS=true
    [[ -f "$PROJECT_ROOT/go.mod" ]] && HAS_TESTS=true
    if [[ "$HAS_TESTS" == "true" ]]; then
        COLD_FLAG="${CLAUDE_DIR}/.test-gate-cold-warned"
        if [[ ! -f "$COLD_FLAG" ]]; then
            mkdir -p "${PROJECT_ROOT}/.claude"
            touch "$COLD_FLAG"
            cat <<EOF
{ "hookSpecificOutput": { "hookEventName": "PreToolUse", "additionalContext": "No test results yet but test framework detected. Tests will run automatically after this write." } }
EOF
            exit 0
        fi
    fi
    exit 0
fi

read_test_status "$PROJECT_ROOT"

# Tests passing → allow + reset strikes
if [[ "$TEST_RESULT" == "pass" ]]; then
    rm -f "$STRIKES_FILE"
    exit 0
fi

# Stale test status (>10 min) → allow (tests may have been fixed externally)
if [[ "$TEST_AGE" -gt "$TEST_STALENESS_THRESHOLD" ]]; then
    exit 0
fi

# --- Tests are failing and status is fresh ---
# Read current strike count
CURRENT_STRIKES=0
if [[ -f "$STRIKES_FILE" ]]; then
    CURRENT_STRIKES=$(cut -d'|' -f1 "$STRIKES_FILE" 2>/dev/null || echo "0")
fi

# Increment strikes
NEW_STRIKES=$(( CURRENT_STRIKES + 1 ))
mkdir -p "${PROJECT_ROOT}/.claude"
NOW=$(date +%s)
echo "${NEW_STRIKES}|${NOW}" > "$STRIKES_FILE"

if [[ "$NEW_STRIKES" -ge 2 ]]; then
    # Strike 2+: DENY with trajectory-aware guidance
    # Read the session event log to provide specific actionable context.
    DENY_REASON="Tests are still failing ($TEST_FAILS failures, ${TEST_AGE}s ago). You've written source code ${NEW_STRIKES} times without fixing tests."

    # Augment with trajectory data if the session event log exists
    EVENTS_FILE="${CLAUDE_DIR}/.session-events.jsonl"
    if [[ -f "$EVENTS_FILE" ]]; then
        detect_approach_pivots "$PROJECT_ROOT"

        if [[ "$PIVOT_COUNT" -gt 0 && -n "$PIVOT_FILES" ]]; then
            # Find the most-edited pivoting file (first one in space-separated list)
            TOP_FILE=$(echo "$PIVOT_FILES" | awk '{print $1}')
            TOP_BASENAME=$(basename "$TOP_FILE")

            # Count total writes for this file in the session
            FILE_WRITES=$(grep '"event":"write"' "$EVENTS_FILE" 2>/dev/null \
                | jq -r --arg f "$TOP_FILE" 'select(.file == $f) | .file' 2>/dev/null \
                | wc -l | tr -d ' ')

            DENY_REASON="$DENY_REASON You've modified \`${TOP_BASENAME}\` ${FILE_WRITES} time(s) this session without resolving test failures."

            # Add assertion-level hint if available
            if [[ -n "$PIVOT_ASSERTIONS" ]]; then
                TOP_ASSERTION=$(echo "$PIVOT_ASSERTIONS" | tr ',' '\n' | grep -v '^$' | head -1)
                if [[ -n "$TOP_ASSERTION" ]]; then
                    DENY_REASON="$DENY_REASON The assertion \`${TOP_ASSERTION}\` has been failing repeatedly. Consider reading the failing test to understand what it expects, or try a different approach."
                fi
            else
                DENY_REASON="$DENY_REASON Consider stepping back to re-read the failing test or trying a different file."
            fi
        else
            # No pivot pattern detected but we have an event log — give generic trajectory hint
            MOST_EDITED=$(grep '"event":"write"' "$EVENTS_FILE" 2>/dev/null \
                | jq -r '.file // empty' 2>/dev/null \
                | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
            if [[ -n "$MOST_EDITED" ]]; then
                MOST_EDITED_BASE=$(basename "$MOST_EDITED")
                DENY_REASON="$DENY_REASON Most-edited file this session: \`${MOST_EDITED_BASE}\`. Consider reading the failing tests before writing more source code."
            else
                DENY_REASON="$DENY_REASON Fix the failing tests before continuing. Test files are exempt from this gate."
            fi
        fi
    else
        DENY_REASON="$DENY_REASON Fix the failing tests before continuing. Test files are exempt from this gate."
    fi

    ESCAPED_REASON=$(echo "$DENY_REASON" | jq -Rs '.[0:-1]')
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": $ESCAPED_REASON
  }
}
EOF
    exit 0
fi

# Strike 1: ALLOW with advisory warning
cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "Tests are failing ($TEST_FAILS failures, ${TEST_AGE}s ago). Consider fixing tests before writing more source code. Next source write without fixing tests will be blocked."
  }
}
EOF
exit 0
