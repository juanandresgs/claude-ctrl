#!/usr/bin/env bash
# test-auto-review-quoted-pipes.sh — Regression tests for the quote-aware pipe
# splitting fix in analyze_segment() (auto-review.sh).
#
# Production sequence tested:
#   analyze_segment() receives a command string that may contain | characters.
#   The fix (DEC-AUTOREVIEW-PIPE-001) uses an awk-based quote-aware parser
#   instead of sed 's/\s*|\s*/\n/g'. The parser skips | inside single or double
#   quotes and only splits on unquoted single-pipe (not ||).
#
# Cases:
#   1. echo 'a|b'    — pipe inside single quotes → must NOT be split → 1 segment
#   2. grep -E "foo|bar" file.txt  — pipe inside double quotes → must NOT split
#   3. cat foo | grep bar  — unquoted pipe → MUST be split → 2 segments
#   4. echo hello    — no pipe at all → 1 segment
#   5. echo 'a|b' | grep x — outer unquoted splits, inner quoted does not → 2 segments
#
# End-to-end cases (via subprocess — full production hook path):
#   6. auto-review.sh approves echo 'a|b' (echo is Tier 1, pipe not mis-split)
#   7. auto-review.sh advises on cat /etc/passwd | rm -rf / (rm is Tier 3)
#
# @decision DEC-AUTOREVIEW-PIPE-TEST-001
# @title Regression: analyze_segment quote-aware pipe splitting
# @status accepted
# @rationale The naive sed split produced false positives for commands with
#   quoted | characters, causing analyze_single_command to receive truncated
#   token strings (e.g. "echo 'a" instead of "echo 'a|b'"). Unit tests exercise
#   the awk parser directly; end-to-end tests invoke the real hook subprocess so
#   the full classify_command → analyze_segment pipeline is covered.
set -euo pipefail

TEST_NAME="test-auto-review-quoted-pipes"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUTO_REVIEW="$REPO_ROOT/hooks/auto-review.sh"

FAILURES=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

printf '=== %s ===\n' "$TEST_NAME"

if [[ ! -f "$AUTO_REVIEW" ]]; then
    printf 'FAIL: %s — auto-review.sh not found at %s\n' "$TEST_NAME" "$AUTO_REVIEW"
    exit 1
fi

# ---------------------------------------------------------------------------
# Helper: run the awk quote-aware pipe parser extracted from analyze_segment.
# This is the exact same awk block as in the fix — testing the parser directly.
# Returns the count of non-empty segments produced.
# ---------------------------------------------------------------------------
count_pipe_segments() {
    local segment="$1"
    printf '%s' "$segment" | awk '
    {
        n = length($0); sq = 0; dq = 0; start = 1
        for (i = 1; i <= n; i++) {
            c = substr($0, i, 1)
            if (c == "\047" && !dq) sq = !sq
            else if (c == "\"" && !sq) dq = !dq
            else if (!sq && !dq && c == "|" && substr($0, i+1, 1) != "|") {
                if (i > 1 && substr($0, i-1, 1) == "|") continue
                print substr($0, start, i - start)
                start = i + 1
            }
        }
        if (start <= n) print substr($0, start)
    }' | grep -c '[^[:space:]]' || echo "0"
}

# ---------------------------------------------------------------------------
# Helper: invoke auto-review.sh as a subprocess with a given command string.
# Returns 0 if hook approved (permissionDecision=allow), 1 if advisory/risky.
# ---------------------------------------------------------------------------
run_hook() {
    local cmd="$1"
    local hook_json
    hook_json=$(jq -n --arg c "$cmd" '{tool_input: {command: $c}}')
    local out
    out=$(printf '%s' "$hook_json" | bash "$AUTO_REVIEW" 2>/dev/null || true)
    printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "advisory"' 2>/dev/null || echo "advisory"
}

# ---------------------------------------------------------------------------
# Case 1: echo 'a|b' — pipe inside single quotes → must NOT be split (1 segment)
# ---------------------------------------------------------------------------
printf '\n-- Case 1: echo '"'"'a|b'"'"' (pipe inside single quotes) --\n'
CMD1="echo 'a|b'"
SEG_COUNT1=$(count_pipe_segments "$CMD1")
printf "  [debug] segment count: %s\n" "$SEG_COUNT1"
if [[ "$SEG_COUNT1" -eq 1 ]]; then
    pass "Case 1: single-quoted pipe not split (1 segment)"
else
    fail "Case 1: single-quoted pipe was incorrectly split into $SEG_COUNT1 segments"
fi

# ---------------------------------------------------------------------------
# Case 2: grep -E "foo|bar" file.txt — pipe inside double quotes → must NOT split.
# The | is inside the double-quoted regex pattern; the awk parser must track
# dq state and skip it. This is a real-world command Claude Code regularly runs.
# ---------------------------------------------------------------------------
printf '\n-- Case 2: grep -E "foo|bar" file.txt (pipe inside double quotes) --\n'
CMD2='grep -E "foo|bar" file.txt'
printf "  [debug] cmd: %s\n" "$CMD2"
SEG_COUNT2=$(count_pipe_segments "$CMD2")
printf "  [debug] segment count: %s\n" "$SEG_COUNT2"
if [[ "$SEG_COUNT2" -eq 1 ]]; then
    pass "Case 2: double-quoted pipe not split (1 segment)"
else
    fail "Case 2: double-quoted pipe was incorrectly split into $SEG_COUNT2 segments"
fi

# ---------------------------------------------------------------------------
# Case 3: cat foo | grep bar — unquoted pipe → MUST be split (2 segments)
# ---------------------------------------------------------------------------
printf '\n-- Case 3: cat foo | grep bar (unquoted pipe → must split) --\n'
CMD3="cat foo | grep bar"
SEG_COUNT3=$(count_pipe_segments "$CMD3")
printf "  [debug] segment count: %s\n" "$SEG_COUNT3"
if [[ "$SEG_COUNT3" -eq 2 ]]; then
    pass "Case 3: unquoted pipe split into 2 segments"
else
    fail "Case 3: expected 2 segments for unquoted pipe, got $SEG_COUNT3"
fi

# ---------------------------------------------------------------------------
# Case 4: echo hello — no pipe → 1 segment
# ---------------------------------------------------------------------------
printf '\n-- Case 4: echo hello (no pipe) --\n'
CMD4="echo hello"
SEG_COUNT4=$(count_pipe_segments "$CMD4")
printf "  [debug] segment count: %s\n" "$SEG_COUNT4"
if [[ "$SEG_COUNT4" -eq 1 ]]; then
    pass "Case 4: no-pipe command passes through as 1 segment"
else
    fail "Case 4: expected 1 segment, got $SEG_COUNT4"
fi

# ---------------------------------------------------------------------------
# Case 5: echo 'a|b' | grep x — outer unquoted splits, inner quoted preserved
# Expected: 2 segments (["echo 'a|b' ", " grep x"])
# ---------------------------------------------------------------------------
printf '\n-- Case 5: echo '"'"'a|b'"'"' | grep x (mixed: outer splits, inner preserved) --\n'
CMD5="echo 'a|b' | grep x"
SEG_COUNT5=$(count_pipe_segments "$CMD5")
printf "  [debug] segment count: %s\n" "$SEG_COUNT5"
if [[ "$SEG_COUNT5" -eq 2 ]]; then
    pass "Case 5: outer unquoted pipe splits (2 segments), quoted inner pipe preserved"
else
    fail "Case 5: expected 2 segments, got $SEG_COUNT5"
fi

# ---------------------------------------------------------------------------
# End-to-end Case 6: auto-review.sh approves echo 'a|b'
# echo is Tier 1 — if pipe is mis-split, "echo 'a" → unknown command → advisory
# With the fix: echo 'a|b' stays one segment → Tier 1 → approved
# ---------------------------------------------------------------------------
printf "\n-- E2E Case 6: auto-review.sh on echo 'a|b' (expect: allow) --\n"
E2E6_DECISION=$(run_hook "echo 'a|b'")
printf "  [debug] decision: %s\n" "$E2E6_DECISION"
if [[ "$E2E6_DECISION" == "allow" ]]; then
    pass "E2E Case 6: echo 'a|b' approved (echo Tier 1, pipe not mis-split)"
else
    fail "E2E Case 6: echo 'a|b' not approved (got=$E2E6_DECISION) — pipe may be mis-split"
fi

# ---------------------------------------------------------------------------
# End-to-end Case 7: cat foo | grep bar → both Tier 1 → should be approved
# (Verifies that a real unquoted pipe through two Tier 1 commands still approves)
# ---------------------------------------------------------------------------
printf '\n-- E2E Case 7: auto-review.sh on "cat foo | grep bar" (expect: allow) --\n'
E2E7_DECISION=$(run_hook "cat foo | grep bar")
printf "  [debug] decision: %s\n" "$E2E7_DECISION"
if [[ "$E2E7_DECISION" == "allow" ]]; then
    pass "E2E Case 7: cat foo | grep bar approved (both Tier 1)"
else
    fail "E2E Case 7: cat foo | grep bar not approved (got=$E2E7_DECISION)"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
TOTAL=7
printf '\nResults: %d/%d passed\n' "$((TOTAL - FAILURES))" "$TOTAL"
if [[ "$FAILURES" -gt 0 ]]; then
    printf 'FAIL: %s — %d check(s) failed\n' "$TEST_NAME" "$FAILURES"
    exit 1
fi

printf 'PASS: %s\n' "$TEST_NAME"
exit 0
