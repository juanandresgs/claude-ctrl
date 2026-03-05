#!/usr/bin/env bash
# Shared test helpers for hook test suite.
#
# Provides common setup, pass/fail/skip tracking, hook execution helpers,
# and JSON extraction utilities reused across all test files.
#
# @decision DEC-TEST-LIB-001
# @title Extract shared test infrastructure into tests/lib/test-helpers.sh
# @status accepted
# @rationale Each test file previously duplicated: color setup, pass/fail/skip
#   counters, run_hook() execution, and JSON field extraction. Extracting to a
#   shared library eliminates ~30 lines of boilerplate per test file and ensures
#   consistent behavior (e.g. run_hook captures stderr suppression the same way
#   everywhere). Source with: source "$(dirname "$0")/lib/test-helpers.sh".
#   @decision required per Sacred Practice #7: files >= 50 lines need annotation.

# Compute paths relative to this file so the library is location-independent.
# HELPERS_DIR = the lib/ directory
# TEST_ROOT   = the tests/ directory (parent of lib/)
# HOOKS_DIR   = the hooks/ directory (sibling of tests/)
HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(cd "$HELPERS_DIR/.." && pwd)"
HOOKS_DIR="$(cd "$TEST_ROOT/../hooks" && pwd)"

# ---------------------------------------------------------------------------
# Terminal colors — disabled when stdout is not a TTY (CI, pipes, etc.)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    GREEN='' RED='' YELLOW='' CYAN='' NC=''
fi

# ---------------------------------------------------------------------------
# Test counters — module-scoped, reset when the helper is sourced
# ---------------------------------------------------------------------------
_test_passed=0
_test_failed=0
_test_skipped=0

# ---------------------------------------------------------------------------
# Core pass/fail/skip reporters
# ---------------------------------------------------------------------------

# pass LABEL — increment passed counter and print green PASS line
pass() {
    echo -e "${GREEN}PASS${NC} $1"
    _test_passed=$((_test_passed + 1))
}

# fail LABEL REASON — increment failed counter and print red FAIL line
fail() {
    echo -e "${RED}FAIL${NC} $1: $2"
    _test_failed=$((_test_failed + 1))
}

# skip LABEL REASON — increment skipped counter and print yellow SKIP line
skip() {
    echo -e "${YELLOW}SKIP${NC} $1: $2"
    _test_skipped=$((_test_skipped + 1))
}

# summary — print totals and return exit 1 if any failures
summary() {
    local total=$((_test_passed + _test_failed + _test_skipped))
    echo ""
    echo "=== Results ==="
    echo -e "Total: $total | ${GREEN}Passed: $_test_passed${NC} | ${RED}Failed: $_test_failed${NC} | ${YELLOW}Skipped: $_test_skipped${NC}"
    [[ $_test_failed -gt 0 ]] && return 1 || return 0
}

# ---------------------------------------------------------------------------
# Hook execution helpers
# ---------------------------------------------------------------------------

# HOOK_STDERR — global variable set by run_hook() and run_hook_ec().
# Contains stderr from the last hook invocation. Useful for diagnosing
# assertion failures: inspect $HOOK_STDERR to see hook error messages.
# Example: [[ -z "$HOOK_STDERR" ]] || echo "Hook stderr: $HOOK_STDERR"
HOOK_STDERR=""

# run_hook HOOK_PATH INPUT_JSON
#   Feed INPUT_JSON on stdin to the hook script.
#   Prints hook stdout. Captures stderr into global $HOOK_STDERR (not
#   suppressed — available for diagnostics on assertion failure).
#   Always returns 0 (hooks exit 0 for deny — exit code is not meaningful here).
#
# @decision DEC-TEST-STDERR-001
# @title Capture hook stderr into HOOK_STDERR instead of suppressing it
# @status accepted
# @rationale run_hook() previously used 2>/dev/null, making debugging hook
#   failures opaque. Tests that fail now have access to $HOOK_STDERR to see
#   what the hook printed on stderr (e.g. bash errors, sourcing failures).
#   Existing tests are unaffected: they don't check HOOK_STDERR by default.
#   The capture uses a temp file to avoid subshell stderr-capture complications.
run_hook() {
    local hook="$1" input="$2"
    local _stdout _stderr_file _ec=0
    _stderr_file=$(mktemp)
    _stdout=$(echo "$input" | bash "$hook" 2>"$_stderr_file") || _ec=$?
    HOOK_STDERR=$(cat "$_stderr_file" 2>/dev/null || true)
    rm -f "$_stderr_file"
    echo "$_stdout"
    return 0
}

# run_hook_ec HOOK_PATH INPUT_JSON
#   Like run_hook but sets HOOK_STDOUT, HOOK_EXIT, and HOOK_STDERR globals.
#   Used when the exit code matters (e.g. PostToolUse exit code 2 tests).
run_hook_ec() {
    local hook="$1" input="$2"
    local _tmp _stderr_file _ec=0
    _tmp=$(mktemp)
    _stderr_file=$(mktemp)
    bash "$hook" <<< "$input" > "$_tmp" 2>"$_stderr_file" || _ec=$?
    HOOK_STDOUT=$(cat "$_tmp")
    HOOK_EXIT="$_ec"
    HOOK_STDERR=$(cat "$_stderr_file" 2>/dev/null || true)
    rm -f "$_tmp" "$_stderr_file"
}

# ---------------------------------------------------------------------------
# JSON extraction from hook output
# ---------------------------------------------------------------------------

# get_decision OUTPUT — extract .hookSpecificOutput.permissionDecision
get_decision() {
    echo "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null
}

# get_context OUTPUT — extract .hookSpecificOutput.additionalContext
get_context() {
    echo "$1" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}

# get_reason OUTPUT — extract .hookSpecificOutput.permissionDecisionReason
get_reason() {
    echo "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null
}

# count_json_objects OUTPUT — count top-level JSON objects in output.
# Consolidated hooks MUST emit exactly 1. Returns integer.
count_json_objects() {
    echo "$1" | python3 -c "
import sys, json
data = sys.stdin.read().strip()
if not data:
    print(0)
    sys.exit(0)
count = 0
decoder = json.JSONDecoder()
pos = 0
while pos < len(data):
    data_part = data[pos:].lstrip()
    if not data_part:
        break
    pos += len(data[pos:]) - len(data_part)
    try:
        _, end = decoder.raw_decode(data_part)
        count += 1
        pos += end
    except json.JSONDecodeError:
        break
print(count)
" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# Temp directory helpers
# ---------------------------------------------------------------------------

# make_temp — create a mktemp dir and print its path
# Caller is responsible for cleanup (use safe_cleanup from context-lib.sh
# when available, or plain rm -rf when not in a hook context).
make_temp() {
    mktemp -d "${TMPDIR:-/tmp}/hook-test-XXXXXX"
}

# make_git_repo [BRANCH] — create a temp git repo on the given branch (default: main)
# Prints the repo path. Caller must clean up.
make_git_repo() {
    local branch="${1:-main}"
    local repo
    repo=$(make_temp)
    git init "$repo" >/dev/null 2>&1
    (
        cd "$repo"
        git checkout -b "$branch" >/dev/null 2>&1 || true
        git commit -m "init" --allow-empty >/dev/null 2>&1
    )
    echo "$repo"
}
