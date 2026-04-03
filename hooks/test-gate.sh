#!/usr/bin/env bash
# Escalating test-failure gate for source code writes.
# PreToolUse hook — matcher: Write|Edit
#
# DECISION: Escalating test gate enforcement. Rationale: Async test-runner
# results arrived too late to prevent compounding errors. This hook reads
# test_state from the SQLite runtime (via rt_test_state_get) and blocks source
# writes after 2+ consecutive attempts while tests are failing. Test files are
# always exempt so fixes can proceed. Status: accepted.
#
# Reads:  runtime SQLite test_state table (via rt_test_state_get)
# Writes: .claude/.test-gate-strikes (format: "strike_count|last_strike_epoch")
#
# @decision DEC-WS3-GATE-001
# Title: test-gate.sh reads SQLite runtime, not .test-status flat file
# Status: accepted
# Rationale: .test-status was written by test-runner.sh as a flat-file bridge.
#   WS3 migrated test state to SQLite via rt_test_state_get. This hook was the
#   last live enforcement reader of the flat file. Converging to rt_test_state_get
#   ensures a single authority for test state across all hooks.
#
# @decision DEC-GUARD-SKIP-001
# Title: .claude/ skip uses project-rooted path, not substring match
# Status: accepted
# Rationale: substring match on .claude/ exempts ANY file with that segment
#   in its absolute path, including project source files when the repo lives
#   under ~/.claude. Project-rooted check ensures only the project's own
#   .claude config tree is skipped.
#
# Logic:
#   - No test state in runtime yet → ALLOW (no test data yet)
#   - runtime test_state says "pass" → ALLOW + reset strikes
#   - runtime test_state older than 10 min → ALLOW (stale)
#   - runtime test_state says "fail" + fresh:
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

# --- Read test status from runtime ---
PROJECT_ROOT=$(detect_project_root)
STRIKES_FILE="${PROJECT_ROOT}/.claude/.test-gate-strikes"

# Skip the project's own .claude config directory (meta-infrastructure).
# Use project-rooted check, not substring match, to avoid exempting source
# files in repos that live under a path containing ".claude/" (DEC-GUARD-SKIP-001).
if [[ -n "$PROJECT_ROOT" && "$FILE_PATH" == "$PROJECT_ROOT/.claude/"* ]]; then
    exit 0
fi

_TS_JSON=$(rt_test_state_get "$PROJECT_ROOT") || _TS_JSON=""
_TS_STATUS=$(printf '%s' "${_TS_JSON:-}" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
_TS_FOUND=$(printf '%s' "${_TS_JSON:-}" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")
_TS_FAIL_COUNT=$(printf '%s' "${_TS_JSON:-}" | jq -r '.fail_count // 0' 2>/dev/null || echo "0")
_TS_UPDATED=$(printf '%s' "${_TS_JSON:-}" | jq -r '.updated_at // 0' 2>/dev/null || echo "0")
NOW=$(date +%s)

# No test state yet → allow (with cold-start advisory if test framework detected)
if [[ "$_TS_FOUND" != "yes" ]]; then
    HAS_TESTS=false
    [[ -f "$PROJECT_ROOT/pyproject.toml" ]] && HAS_TESTS=true
    [[ -f "$PROJECT_ROOT/vitest.config.ts" || -f "$PROJECT_ROOT/vitest.config.js" ]] && HAS_TESTS=true
    [[ -f "$PROJECT_ROOT/jest.config.ts" || -f "$PROJECT_ROOT/jest.config.js" ]] && HAS_TESTS=true
    [[ -f "$PROJECT_ROOT/Cargo.toml" ]] && HAS_TESTS=true
    [[ -f "$PROJECT_ROOT/go.mod" ]] && HAS_TESTS=true
    if [[ "$HAS_TESTS" == "true" ]]; then
        COLD_FLAG="${PROJECT_ROOT}/.claude/.test-gate-cold-warned"
        if [[ ! -f "$COLD_FLAG" ]]; then
            mkdir -p "${PROJECT_ROOT}/.claude"
            touch "$COLD_FLAG"
            cat <<COLDEOF
{ "hookSpecificOutput": { "hookEventName": "PreToolUse", "additionalContext": "No test results yet but test framework detected. Tests will run automatically after this write." } }
COLDEOF
            exit 0
        fi
    fi
    exit 0
fi

# Tests passing → allow + reset strikes
if [[ "$_TS_STATUS" == "pass" || "$_TS_STATUS" == "pass_complete" ]]; then
    rm -f "$STRIKES_FILE"
    exit 0
fi

# Calculate age from updated_at
AGE=0
if [[ "$_TS_UPDATED" -gt 0 ]]; then
    AGE=$(( NOW - _TS_UPDATED ))
fi

# Stale test status (>10 min) → allow
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
    "permissionDecisionReason": "Tests are still failing ($_TS_FAIL_COUNT failures, ${AGE}s ago). You've written source code ${NEW_STRIKES} times without fixing tests. Fix the failing tests before continuing. Test files are exempt from this gate."
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
    "additionalContext": "Tests are failing ($_TS_FAIL_COUNT failures, ${AGE}s ago). Consider fixing tests before writing more source code. Next source write without fixing tests will be blocked."
  }
}
EOF
exit 0
