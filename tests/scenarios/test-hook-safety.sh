#!/usr/bin/env bash
# tests/scenarios/test-hook-safety.sh — Verify hook-safety.sh fail-closed wrapper.
#
# Tests the crash-deny behavior of run_fail_closed:
#   1. A hook function that returns non-zero before responding must emit deny JSON
#      and exit 0 (so Claude Code sees and respects the deny decision).
#   2. A hook function that emits a valid response and returns 0 must NOT trigger
#      the crash-deny path.
#
# Production sequence exercised:
#   hook script sources hook-safety.sh → calls run_fail_closed _hook_main
#   → _hook_main crashes (returns non-zero) → EXIT trap fires
#   → deny JSON emitted to stdout → exit 0
#
# @decision DEC-HOOK-004-FC-WRAPPER
# @title Compound test: hook-safety crash-deny behavior verified end-to-end
# @status accepted
# @rationale The tester requires at least one test exercising the real production
#   sequence (hook sources lib, installs trap, crashes, trap emits deny, exits 0).
#   Subprocess isolation (bash -c) mirrors how Claude Code invokes hooks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS_DIR="$SCRIPT_DIR/hooks"
PASS=0
FAIL=0

# ── Helpers ──────────────────────────────────────────────────────────────────

assert_json_field() {
    local json="$1" field="$2" expected="$3" label="$4"
    local actual
    actual=$(printf '%s' "$json" | jq -r "$field" 2>/dev/null || echo "__jq_error__")
    if [[ "$actual" == "$expected" ]]; then
        printf '  PASS: %s\n' "$label"
        ((PASS++)) || true
    else
        printf '  FAIL: %s (expected %q, got %q)\n' "$label" "$expected" "$actual"
        ((FAIL++)) || true
    fi
}

assert_exit_zero() {
    local code="$1" label="$2"
    if [[ "$code" -eq 0 ]]; then
        printf '  PASS: %s\n' "$label"
        ((PASS++)) || true
    else
        printf '  FAIL: %s (exit code %d, expected 0)\n' "$label" "$code"
        ((FAIL++)) || true
    fi
}

assert_no_match() {
    local haystack="$1" needle="$2" label="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        printf '  FAIL: %s (unexpectedly found %q in output)\n' "$label" "$needle"
        ((FAIL++)) || true
    else
        printf '  PASS: %s\n' "$label"
        ((PASS++)) || true
    fi
}

# ── Scenario 1: crash before response → deny + exit 0 ────────────────────────
# Production sequence: source hook-safety.sh, define _hook_main that returns 1
# (simulating a crash / unexpected non-zero before emitting a response),
# call run_fail_closed _hook_main. The EXIT trap must emit a deny JSON and exit 0.

printf 'Scenario 1: hook crashes before responding — expect deny + exit 0\n'

OUTPUT=$(bash -c "
    source '$HOOKS_DIR/lib/hook-safety.sh'
    # Stub observatory functions — hook-safety.sh guards these with type -t,
    # but stub them explicitly to keep output clean in isolated test subprocess.
    _obs_accum() { :; }
    rt_obs_metric_batch() { :; }
    _hook_main() { return 1; }
    run_fail_closed _hook_main
" 2>/dev/null)
EXIT_CODE=$?

assert_json_field "$OUTPUT" '.hookSpecificOutput.permissionDecision' 'deny' \
    'crash emits permissionDecision=deny'
assert_json_field "$OUTPUT" '.hookSpecificOutput.blockingHook' 'hook-safety-crash-deny' \
    'crash emits blockingHook=hook-safety-crash-deny'
assert_exit_zero "$EXIT_CODE" 'exit code is 0 after crash deny'

# ── Scenario 2: normal response → no crash deny ───────────────────────────────
# Production sequence: _hook_main emits a valid allow JSON and returns 0.
# run_fail_closed calls _mark_hook_responded(), so the EXIT trap is a no-op.
# Output must be the hook's own JSON, not the crash-deny payload.

printf 'Scenario 2: hook responds normally — no crash deny emitted\n'

OUTPUT=$(bash -c "
    source '$HOOKS_DIR/lib/hook-safety.sh'
    _obs_accum() { :; }
    rt_obs_metric_batch() { :; }
    _hook_main() {
        printf '{\"hookSpecificOutput\":{\"permissionDecision\":\"allow\"}}\n'
    }
    run_fail_closed _hook_main
" 2>/dev/null)
EXIT_CODE=$?

assert_no_match "$OUTPUT" 'hook-safety-crash-deny' \
    'normal response does not trigger crash deny'
assert_json_field "$OUTPUT" '.hookSpecificOutput.permissionDecision' 'allow' \
    'normal response preserves allow decision'
assert_exit_zero "$EXIT_CODE" 'exit code is 0 after normal response'

# ── Scenario 3: observatory stubs absent — must not crash ────────────────────
# When hook-safety.sh is sourced without context-lib.sh (as in auto-review.sh),
# _obs_accum and rt_obs_metric_batch are undefined. The type -t guards in the
# EXIT handler must prevent NameError-style failures and still emit the deny.

printf 'Scenario 3: observatory functions absent — crash deny still works\n'

OUTPUT=$(bash -c "
    source '$HOOKS_DIR/lib/hook-safety.sh'
    # Do NOT define _obs_accum or rt_obs_metric_batch — simulates auto-review.sh env
    _hook_main() { return 1; }
    run_fail_closed _hook_main
" 2>/dev/null)
EXIT_CODE=$?

assert_json_field "$OUTPUT" '.hookSpecificOutput.permissionDecision' 'deny' \
    'deny emitted even without observatory functions'
assert_exit_zero "$EXIT_CODE" 'exit 0 even without observatory functions'

# ── Scenario 4: set -e in caller — run_fail_closed set +e/-e toggle works ────
# The forbidden-shortcuts clause requires set -euo pipefail to remain in hooks.
# run_fail_closed uses set +e internally so a failing hook function does not
# trigger bash ERR before the EXIT trap can fire.

printf 'Scenario 4: set -euo pipefail in caller — toggle prevents premature exit\n'

OUTPUT=$(bash -c "
    set -euo pipefail
    source '$HOOKS_DIR/lib/hook-safety.sh'
    _obs_accum() { :; }
    rt_obs_metric_batch() { :; }
    _hook_main() {
        # This subcommand fails — with set -e and no wrapper, bash would exit
        # non-zero here before the EXIT trap can emit the deny JSON.
        false
    }
    run_fail_closed _hook_main
" 2>/dev/null)
EXIT_CODE=$?

assert_json_field "$OUTPUT" '.hookSpecificOutput.permissionDecision' 'deny' \
    'set -e caller: deny still emitted when hook fails'
assert_exit_zero "$EXIT_CODE" 'set -e caller: exit 0 after deny'

# ── Results ───────────────────────────────────────────────────────────────────

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
