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

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

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
is_test_file() {
    local file="$1"
    [[ "$file" =~ \.test\. ]] && return 0
    [[ "$file" =~ \.spec\. ]] && return 0
    [[ "$file" =~ __tests__/ ]] && return 0
    [[ "$file" =~ _test\.go$ ]] && return 0
    [[ "$file" =~ _test\.py$ ]] && return 0
    [[ "$file" =~ /tests/ ]] && return 0
    [[ "$file" =~ /test/ ]] && return 0
    return 1
}

if is_test_file "$FILE_PATH"; then
    exit 0
fi

# --- Read test status ---
PROJECT_ROOT=$(detect_project_root)
TEST_STATUS_FILE="${PROJECT_ROOT}/.claude/.test-status"
STRIKES_FILE="${PROJECT_ROOT}/.claude/.test-gate-strikes"

# No test status yet → allow
[[ ! -f "$TEST_STATUS_FILE" ]] && exit 0

TEST_RESULT=$(cut -d'|' -f1 "$TEST_STATUS_FILE")
TEST_FAILS=$(cut -d'|' -f2 "$TEST_STATUS_FILE")
TEST_TIME=$(cut -d'|' -f3 "$TEST_STATUS_FILE")
NOW=$(date +%s)
AGE=$(( NOW - TEST_TIME ))

# Tests passing → allow + reset strikes
if [[ "$TEST_RESULT" == "pass" ]]; then
    rm -f "$STRIKES_FILE"
    exit 0
fi

# Stale test status (>10 min) → allow (tests may have been fixed externally)
if [[ "$AGE" -gt 600 ]]; then
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
echo "${NEW_STRIKES}|${NOW}" > "$STRIKES_FILE"

if [[ "$NEW_STRIKES" -ge 2 ]]; then
    # Strike 2+: DENY
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Tests are still failing ($TEST_FAILS failures, ${AGE}s ago). You've written source code ${NEW_STRIKES} times without fixing tests. Fix the failing tests before continuing. Test files are exempt from this gate."
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
    "additionalContext": "Tests are failing ($TEST_FAILS failures, ${AGE}s ago). Consider fixing tests before writing more source code. Next source write without fixing tests will be blocked."
  }
}
EOF
exit 0
