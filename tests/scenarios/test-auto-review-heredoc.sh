#!/usr/bin/env bash
# tests/scenarios/test-auto-review-heredoc.sh — Verify auto-review.sh heredoc handling.
#
# Tests that commands containing heredocs (Gap 3 fix) do not crash auto-review.sh
# and that the hook exits 0 with valid JSON output in all cases.
#
# Production sequence exercised:
#   stdin JSON → auto-review.sh → read_input() → get_field() → is_safe()
#   → heredoc detected in Phase 1 → set_risk() → advise() → exit 0
#
# @decision DEC-AUTOREVIEW-HEREDOC-001
# @title Heredoc commands produce advisory output, not crashes
# @status accepted
# @rationale The tester requires compound-interaction tests that cross multiple
#   internal component boundaries. This test crosses: JSON parsing (get_field),
#   command decomposition (decompose_command), heredoc detection (is_safe Phase 1),
#   risk accumulation (set_risk), and response emission (advise).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS_DIR="$SCRIPT_DIR/hooks"
PASS=0
FAIL=0

# ── Helpers ───────────────────────────────────────────────────────────────────

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

assert_nonempty() {
    local val="$1" label="$2"
    if [[ -n "$val" ]]; then
        printf '  PASS: %s\n' "$label"
        ((PASS++)) || true
    else
        printf '  FAIL: %s (output was empty)\n' "$label"
        ((FAIL++)) || true
    fi
}

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

# ── Scenario 1: heredoc in git commit command substitution ────────────────────
# Real-world command: git commit -m "$(cat <<'EOF'\nfix: test\nEOF\n)"
# Before Gap 3 fix, analyze_substitutions crashed with exit 5 on the heredoc body.
# After fix: is_safe Phase 1 detects << and returns risky immediately → advise().

# shellcheck disable=SC2016  # $(...) is intentionally literal in the scenario description
printf 'Scenario 1: heredoc in git commit -m $(...) — no crash, advisory output\n'

# shellcheck disable=SC2016  # $(...) is intentionally literal — this IS the command string under test
HEREDOC_CMD='git commit -m "$(cat <<'"'"'EOF'"'"'\nfix: test\nEOF\n)"'
INPUT_JSON=$(jq -n \
    --arg cmd "$HEREDOC_CMD" \
    '{"tool_name":"Bash","tool_input":{"command":$cmd},"cwd":"/tmp"}')

OUTPUT=$(printf '%s' "$INPUT_JSON" | bash "$HOOKS_DIR/auto-review.sh" 2>/dev/null)
EXIT_CODE=$?

assert_exit_zero "$EXIT_CODE" 'no crash (exit 0)'
assert_nonempty "$OUTPUT" 'produced JSON output'
assert_json_field "$OUTPUT" '.hookSpecificOutput.hookEventName' 'PreToolUse' \
    'output has hookEventName field'
# Must be advisory (additionalContext), not a crash deny
assert_no_match "$OUTPUT" 'hook-safety-crash-deny' \
    'not a crash-deny (heredoc handled gracefully)'

# ── Scenario 2: simple safe command — auto-approve ────────────────────────────
# Baseline: git status should be auto-approved (not a crash, not advisory).

printf 'Scenario 2: simple safe command (git status) — auto-approve\n'

INPUT_JSON=$(jq -n '{"tool_name":"Bash","tool_input":{"command":"git status"},"cwd":"/tmp"}')
OUTPUT=$(printf '%s' "$INPUT_JSON" | bash "$HOOKS_DIR/auto-review.sh" 2>/dev/null)
EXIT_CODE=$?

assert_exit_zero "$EXIT_CODE" 'exit 0'
assert_json_field "$OUTPUT" '.hookSpecificOutput.permissionDecision' 'allow' \
    'git status auto-approved'
assert_no_match "$OUTPUT" 'hook-safety-crash-deny' \
    'no crash deny on safe command'

# ── Scenario 3: risky command — advisory output, exit 0 ──────────────────────
# git reset --hard is flagged risky by the --hard flag check. The hook must
# return advisory context and exit 0, never crash.

printf 'Scenario 3: risky command (git reset --hard) — advisory, exit 0\n'

INPUT_JSON=$(jq -n '{"tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~1"},"cwd":"/tmp"}')
OUTPUT=$(printf '%s' "$INPUT_JSON" | bash "$HOOKS_DIR/auto-review.sh" 2>/dev/null)
EXIT_CODE=$?

assert_exit_zero "$EXIT_CODE" 'exit 0 on risky command'
assert_nonempty "$OUTPUT" 'produced JSON output'
assert_no_match "$OUTPUT" 'hook-safety-crash-deny' \
    'risky command produces advisory, not crash deny'

# ── Scenario 4: empty command — silent pass-through ───────────────────────────
# When command is empty the hook should exit 0 with no output (no opinion).

printf 'Scenario 4: empty command — silent exit 0\n'

INPUT_JSON=$(jq -n '{"tool_name":"Bash","tool_input":{"command":""},"cwd":"/tmp"}')
OUTPUT=$(printf '%s' "$INPUT_JSON" | bash "$HOOKS_DIR/auto-review.sh" 2>/dev/null)
EXIT_CODE=$?

assert_exit_zero "$EXIT_CODE" 'exit 0 on empty command'
assert_no_match "$OUTPUT" 'hook-safety-crash-deny' \
    'no crash deny on empty command'

# ── Scenario 5: here-string <<< must NOT trigger heredoc detection ────────────
# grep foo <<< "bar" passes a single string via here-string — not a heredoc body.
# RCA-4: the pattern (^|[^<])<<- excludes <<< because the third < prevents match.
# Expected: auto-approve (not advisory, not crash-deny).

printf 'Scenario 5: here-string <<< should NOT trigger heredoc detection\n'

INPUT_JSON=$(jq -n '{"tool_name":"Bash","tool_input":{"command":"grep foo <<< \"bar\""},"cwd":"/tmp"}')
OUTPUT=$(printf '%s' "$INPUT_JSON" | bash "$HOOKS_DIR/auto-review.sh" 2>/dev/null)
EXIT_CODE=$?

assert_exit_zero "$EXIT_CODE" 'exit 0 on here-string command'
assert_json_field "$OUTPUT" '.hookSpecificOutput.permissionDecision' 'allow' \
    'here-string <<< auto-approved (not flagged as heredoc)'
assert_no_match "$OUTPUT" 'Heredoc detected' \
    'here-string does not produce heredoc advisory'

# ── Scenario 6: << inside a double-quoted string — conservative false positive ─
# echo "<<test>>" contains << inside double quotes — not a real shell heredoc.
# However the regex cannot distinguish quoted << from a heredoc delimiter:
# "<<t" matches (^|[^<])<<...[A-Za-z_] because " is not < and t is [A-Za-z_].
# RCA-4 excludes <<< and arithmetic <<, but NOT quoted <<.
# The false positive is intentional — being conservative is safer than missing
# a real heredoc body. Expected: heredoc advisory (risky), exit 0, no crash.

printf 'Scenario 6: quoted << (echo "<<test>>") — conservative false positive, advisory exit 0\n'

INPUT_JSON=$(jq -n '{"tool_name":"Bash","tool_input":{"command":"echo \"<<test>>\""},"cwd":"/tmp"}')
OUTPUT=$(printf '%s' "$INPUT_JSON" | bash "$HOOKS_DIR/auto-review.sh" 2>/dev/null)
EXIT_CODE=$?

assert_exit_zero "$EXIT_CODE" 'exit 0 on quoted << command (no crash)'
assert_nonempty "$OUTPUT" 'produced JSON output for quoted << command'
assert_no_match "$OUTPUT" 'hook-safety-crash-deny' \
    'quoted << produces advisory, not crash deny'

# ── Scenario 7: arithmetic << must NOT trigger heredoc detection ──────────────
# bash -c 'echo $((1<<3))' — the << inside $((...)) is a left-shift operator.
# RCA-4: the pattern excludes arithmetic << because the << is preceded by a digit,
# not a word-boundary, and the (^|[^<]) anchor only excludes another <.
# The delimiter after << would need to start with a letter/underscore/quote;
# "3))" does not match [A-Za-z_], so no heredoc match.
# Expected: auto-approve (may still be advisory for bash -c, but not for heredoc).

printf 'Scenario 7: arithmetic << (1<<3) should NOT trigger heredoc detection\n'

INPUT_JSON=$(jq -n '{"tool_name":"Bash","tool_input":{"command":"bash -c '\''echo $((1<<3))'\''"},"cwd":"/tmp"}')
OUTPUT=$(printf '%s' "$INPUT_JSON" | bash "$HOOKS_DIR/auto-review.sh" 2>/dev/null)
EXIT_CODE=$?

assert_exit_zero "$EXIT_CODE" 'exit 0 on arithmetic << command'
assert_no_match "$OUTPUT" 'Heredoc detected' \
    'arithmetic << does not produce heredoc advisory'

# ── Scenario 8: tab-strip heredoc <<-EOF SHOULD trigger heredoc detection ─────
# cat <<-EOF\n\ttext\n\tEOF is a valid tab-stripping heredoc form.
# RCA-4: the pattern includes <<- as an optional - after <<, so this must match.
# Expected: advisory output (risky), exit 0.

printf 'Scenario 8: tab-strip heredoc (<<-EOF) SHOULD trigger heredoc detection\n'

INPUT_JSON=$(jq -n '{"tool_name":"Bash","tool_input":{"command":"cat <<-EOF\n\tsome text\n\tEOF"},"cwd":"/tmp"}')
OUTPUT=$(printf '%s' "$INPUT_JSON" | bash "$HOOKS_DIR/auto-review.sh" 2>/dev/null)
EXIT_CODE=$?

assert_exit_zero "$EXIT_CODE" 'exit 0 on tab-strip heredoc (no crash)'
assert_nonempty "$OUTPUT" 'produced JSON output for tab-strip heredoc'
assert_no_match "$OUTPUT" 'hook-safety-crash-deny' \
    'tab-strip heredoc produces advisory, not crash deny'
# Must be advisory (heredoc detected), not auto-approved
assert_no_match "$OUTPUT" '"permissionDecision":"allow"' \
    'tab-strip heredoc is NOT auto-approved'

# ── Results ───────────────────────────────────────────────────────────────────

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
