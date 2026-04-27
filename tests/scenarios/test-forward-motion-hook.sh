#!/usr/bin/env bash
# test-forward-motion-hook.sh — Stop-time forward-motion hint stays advisory.
#
# The hook may notice weak endings, but it must not block ordinary Stop. A
# previous blocking implementation trapped useful async status updates like:
# "I'll get a notification when it's done."

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/forward-motion.sh"
TMP_DIR="$REPO_ROOT/tmp/test-forward-motion-hook-$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
mkdir -p "$TMP_DIR"

PASS=0
FAIL=0

pass() {
    printf '  PASS: %s\n' "$1"
    PASS=$((PASS + 1))
}

fail() {
    printf '  FAIL: %s\n' "$1"
    FAIL=$((FAIL + 1))
}

run_hook() {
    local label="$1"
    local message="$2"
    local out_file="$TMP_DIR/$label.out"
    local err_file="$TMP_DIR/$label.err"
    local code_file="$TMP_DIR/$label.code"

    set +e
    jq -n --arg msg "$message" '{last_assistant_message: $msg}' \
        | "$HOOK" >"$out_file" 2>"$err_file"
    local code=$?
    set -e

    printf '%s\n' "$code" >"$code_file"
}

assert_exit_zero() {
    local label="$1"
    local code
    code="$(cat "$TMP_DIR/$label.code")"
    if [[ "$code" == "0" ]]; then
        pass "$label exits 0"
    else
        fail "$label exits 0 (got $code)"
    fi
}

assert_stderr_contains() {
    local label="$1"
    local expected="$2"
    if grep -qF "$expected" "$TMP_DIR/$label.err"; then
        pass "$label stderr contains $expected"
    else
        fail "$label stderr contains $expected"
    fi
}

assert_stderr_not_contains() {
    local label="$1"
    local unexpected="$2"
    if grep -qF "$unexpected" "$TMP_DIR/$label.err"; then
        fail "$label stderr should not contain $unexpected"
    else
        pass "$label stderr omits $unexpected"
    fi
}

echo "=== test-forward-motion-hook ==="

run_hook "background_status" "Re-dispatched the implementer in the background. I'll get a notification when it's done."
assert_exit_zero "background_status"
assert_stderr_not_contains "background_status" "Advisory:"
assert_stderr_not_contains "background_status" "Response lacks forward motion"

run_hook "bare_done" "Done."
assert_exit_zero "bare_done"
assert_stderr_contains "bare_done" "Advisory:"
assert_stderr_not_contains "bare_done" "Response lacks forward motion"

run_hook "question" "Tests are passing. Should I push the branch?"
assert_exit_zero "question"
assert_stderr_not_contains "question" "Advisory:"

run_hook "empty" ""
assert_exit_zero "empty"

printf '\nResult: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
