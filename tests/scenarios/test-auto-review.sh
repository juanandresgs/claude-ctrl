#!/usr/bin/env bash
# test-auto-review.sh — Test coverage for hooks/auto-review.sh
#
# Production sequence: Claude Code PreToolUse (Bash matcher) receives JSON on
# stdin with the command to run. auto-review.sh classifies the command through
# its three-tier engine and either auto-approves (safe) or injects advisory
# context (risky). This test suite exercises that classification logic at two
# levels:
#
#   1. Function-level: decompose_command and classify_command are sourced and
#      called directly, enabling tight assertions on segmentation and tier lookup.
#
#   2. End-to-end subprocess: the full hook is invoked with piped JSON, exactly
#      as the Claude Code harness does in production.
#
# @decision DEC-AUTOREVIEW-TEST-001
# @title Test suite for auto-review three-tier command classification engine
# @status accepted
# @rationale auto-review.sh is 842 lines of command classification logic with
#   zero prior test coverage. The function-level sourcing approach extracts only
#   the function definitions via sed before the top-level read_input/get_field
#   calls execute, avoiding side effects while allowing direct function invocation.
#   End-to-end subprocess tests validate the full stdin-to-stdout production path.
set -euo pipefail

TEST_NAME="test-auto-review"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/auto-review.sh"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"

# shellcheck disable=SC2329  # cleanup is invoked via trap EXIT
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR"

FAILURES=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

printf '=== %s ===\n' "$TEST_NAME"

# Verify the hook exists and is executable
if [[ ! -f "$HOOK" ]]; then
    printf 'FAIL: %s — hooks/auto-review.sh not found\n' "$TEST_NAME"
    exit 1
fi
chmod +x "$HOOK"

# ---------------------------------------------------------------------------
# Function-level isolation strategy
#
# auto-review.sh runs set -euo pipefail and calls read_input/get_field at the
# top level before any function definitions. To source individual functions
# without triggering the main flow, we extract only the function definitions
# via sed (everything from the first function definition through the end,
# excluding the main execution block at the bottom).
#
# We write the extracted functions to a temp file and source that, after first
# providing the log.sh stubs needed by the functions.
# ---------------------------------------------------------------------------

# Stub log.sh dependencies used by auto-review.sh functions
HOOK_INPUT='{"tool_input":{"command":""},"tool_name":"Bash"}'
RISK_REASON=""

# Create a sourcing stub: extract all function definitions + supporting
# declarations from auto-review.sh (stops before the main execution block)
FUNC_STUB="$TMP_DIR/auto_review_funcs.sh"

# Extract everything from first function through the end of function
# definitions, explicitly including the approve/advise/set_risk helpers.
# Strategy: sed from "approve() {" through the last closing brace before
# the "# ── Main" section. We use awk for robustness.
awk '
    /^approve\(\)|^advise\(\)|^set_risk\(\)|^is_safe\(\)|^decompose_command\(\)|^analyze_segment\(\)|^analyze_single_command\(\)|^analyze_substitutions\(\)|^classify_command\(\)|^analyze_tier2\(\)|^analyze_git\(\)|^analyze_npm\(\)|^analyze_pip\(\)|^analyze_docker\(\)|^analyze_cargo\(\)|^analyze_go\(\)|^analyze_curl\(\)|^analyze_sed\(\)|^analyze_chmod\(\)|^analyze_path_target\(\)|^analyze_brew\(\)|^analyze_gh\(\)/ { in_func=1 }
    in_func { print }
    /^# ── Main/ { in_func=0 }
' "$HOOK" > "$FUNC_STUB"

# Prepend required globals that the functions rely on
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf '# Stubs for top-level variables used by auto-review.sh functions\n'
    printf 'RISK_REASON=""\n'
    printf 'HOOK_INPUT=%s\n' "'${HOOK_INPUT}'"
    printf 'COMMAND=""\n'
    # Include the full function definitions
    printf '\n'
    cat "$FUNC_STUB"
} > "$TMP_DIR/funcs_with_header.sh"
mv "$TMP_DIR/funcs_with_header.sh" "$FUNC_STUB"

# shellcheck disable=SC1090
source "$FUNC_STUB"

# ===========================================================================
# Group 1 — decompose_command (5 tests)
# ===========================================================================
printf '\n-- Group 1: decompose_command --\n'

# Test G1.1: Multi-line python3 -c "import...\nprint..." → single segment
# Regression: pre-fix, the newline reset awk quote tracking, producing two
# segments instead of one.
G1_1_CMD='python3 -c "import json
print(json.dumps({}))"'
G1_1_SEGS=$(decompose_command "$G1_1_CMD" | grep -c .)
if [[ "$G1_1_SEGS" -eq 1 ]]; then
    pass "G1.1: multi-line python3 -c → 1 segment (got $G1_1_SEGS)"
else
    fail "G1.1: multi-line python3 -c → 1 segment (got $G1_1_SEGS)"
fi

# Test G1.2: cmd1 && cmd2 → 2 segments
G1_2_CMD='echo hello && echo world'
G1_2_SEGS=$(decompose_command "$G1_2_CMD" | grep -c .)
if [[ "$G1_2_SEGS" -eq 2 ]]; then
    pass "G1.2: cmd1 && cmd2 → 2 segments (got $G1_2_SEGS)"
else
    fail "G1.2: cmd1 && cmd2 → 2 segments (got $G1_2_SEGS)"
fi

# Test G1.3: cmd1 || cmd2 → 2 segments
G1_3_CMD='ls /tmp || echo missing'
G1_3_SEGS=$(decompose_command "$G1_3_CMD" | grep -c .)
if [[ "$G1_3_SEGS" -eq 2 ]]; then
    pass "G1.3: cmd1 || cmd2 → 2 segments (got $G1_3_SEGS)"
else
    fail "G1.3: cmd1 || cmd2 → 2 segments (got $G1_3_SEGS)"
fi

# Test G1.4: cmd1 ; cmd2 → 2 segments
G1_4_CMD='cd /tmp ; ls'
G1_4_SEGS=$(decompose_command "$G1_4_CMD" | grep -c .)
if [[ "$G1_4_SEGS" -eq 2 ]]; then
    pass "G1.4: cmd1 ; cmd2 → 2 segments (got $G1_4_SEGS)"
else
    fail "G1.4: cmd1 ; cmd2 → 2 segments (got $G1_4_SEGS)"
fi

# Test G1.5: Semicolons inside quotes are preserved (not treated as delimiters)
# 'python3 -c "a=1; b=2" && echo done' → 2 segments (split on &&, not on ';')
G1_5_CMD='python3 -c "a=1; b=2" && echo done'
G1_5_SEGS=$(decompose_command "$G1_5_CMD" | grep -c .)
if [[ "$G1_5_SEGS" -eq 2 ]]; then
    pass "G1.5: semicolons inside quotes preserved → 2 segments (got $G1_5_SEGS)"
else
    fail "G1.5: semicolons inside quotes preserved → 2 segments (got $G1_5_SEGS)"
fi

# ===========================================================================
# Group 2 — classify_command (4 tests)
# ===========================================================================
printf '\n-- Group 2: classify_command --\n'

# Test G2.1: Tier 1 commands (safe, read-only)
G2_1_FAIL=0
for cmd in ls cat echo pwd; do
    tier=$(classify_command "$cmd")
    if [[ "$tier" != "1" ]]; then
        fail "G2.1: $cmd should be Tier 1 (got '$tier')"
        G2_1_FAIL=1
    fi
done
if [[ "$G2_1_FAIL" -eq 0 ]]; then
    pass "G2.1: ls, cat, echo, pwd → Tier 1"
fi

# Test G2.2: Tier 2 commands (behavior-dependent)
G2_2_FAIL=0
for cmd in git python3 npm docker; do
    tier=$(classify_command "$cmd")
    if [[ "$tier" != "2" ]]; then
        fail "G2.2: $cmd should be Tier 2 (got '$tier')"
        G2_2_FAIL=1
    fi
done
if [[ "$G2_2_FAIL" -eq 0 ]]; then
    pass "G2.2: git, python3, npm, docker → Tier 2"
fi

# Test G2.3: Tier 3 commands (always defer)
G2_3_FAIL=0
for cmd in rm sudo kill; do
    tier=$(classify_command "$cmd")
    if [[ "$tier" != "3" ]]; then
        fail "G2.3: $cmd should be Tier 3 (got '$tier')"
        G2_3_FAIL=1
    fi
done
if [[ "$G2_3_FAIL" -eq 0 ]]; then
    pass "G2.3: rm, sudo, kill → Tier 3"
fi

# Test G2.4: Unknown command → falls through to * → returns 0 (echo 0)
G2_4_TIER=$(classify_command "foobar_unknown_xyz")
if [[ "$G2_4_TIER" == "0" ]]; then
    pass "G2.4: foobar_unknown → Tier 0 (unknown, defer)"
else
    fail "G2.4: foobar_unknown → expected Tier 0, got '$G2_4_TIER'"
fi

# ===========================================================================
# Group 3 — is_safe end-to-end (7 tests)
# ===========================================================================
printf '\n-- Group 3: is_safe --\n'

# Test G3.1: Simple safe command
RISK_REASON=""
if is_safe "ls -la" 0; then
    pass "G3.1: 'ls -la' is safe"
else
    fail "G3.1: 'ls -la' should be safe (RISK_REASON=$RISK_REASON)"
fi

# Test G3.2: Simple risky command
RISK_REASON=""
if ! is_safe "rm -rf /" 0; then
    pass "G3.2: 'rm -rf /' is not safe"
else
    fail "G3.2: 'rm -rf /' should NOT be safe"
fi

# Test G3.3: Pipe safe — both parts safe
RISK_REASON=""
if is_safe "git log | head -5" 0; then
    pass "G3.3: 'git log | head -5' is safe"
else
    fail "G3.3: 'git log | head -5' should be safe (RISK_REASON=$RISK_REASON)"
fi

# Test G3.4: Pipe with risky segment — tee writing to system path
RISK_REASON=""
if ! is_safe "cat file | sudo tee /etc/hosts" 0; then
    pass "G3.4: 'cat file | sudo tee /etc/hosts' is not safe"
else
    fail "G3.4: 'cat file | sudo tee /etc/hosts' should NOT be safe"
fi

# Test G3.5: Heredoc detection → not safe (cannot statically analyze)
RISK_REASON=""
if ! is_safe "cat <<EOF
hello
EOF" 0; then
    pass "G3.5: heredoc (<<EOF) is not safe"
else
    fail "G3.5: heredoc (<<EOF) should NOT be safe (RISK_REASON=$RISK_REASON)"
fi

# Test G3.6: python3 -c with inline script → safe (Tier 2, script exec always allowed)
RISK_REASON=""
if is_safe 'python3 -c "import json"' 0; then
    pass "G3.6: 'python3 -c \"import json\"' is safe"
else
    fail "G3.6: 'python3 -c \"import json\"' should be safe (RISK_REASON=$RISK_REASON)"
fi

# Test G3.7: Multi-line python3 -c regression — collapsed newlines must not
# split the command into two segments where the second is "unknown"
RISK_REASON=""
MULTILINE_PY=$'python3 -c "\nimport sqlite3\n"'
if is_safe "$MULTILINE_PY" 0; then
    pass "G3.7: multi-line python3 -c is safe (regression: newline splitting)"
else
    fail "G3.7: multi-line python3 -c should be safe (RISK_REASON=$RISK_REASON)"
fi

# ---------------------------------------------------------------------------
# Subprocess helper — defined here because Groups 4 and 5 both use it.
# Run the auto-review hook with a given command string, return stdout.
# The hook is invoked exactly as Claude Code's PreToolUse harness does it:
# pipe JSON on stdin, read JSON on stdout.
# ---------------------------------------------------------------------------
run_hook() {
    local cmd="$1"
    local payload
    payload=$(jq -n \
        --arg command "$cmd" \
        '{"tool_input": {"command": $command}, "tool_name": "Bash"}')
    printf '%s' "$payload" | "$HOOK" 2>/dev/null || echo '{}'
}

# ===========================================================================
# Group 4 — analyze_tier2 for git (3 tests)
#
# These tests use the subprocess approach rather than direct function calls.
# analyze_git uses grep -qE '--force\b' patterns which rely on GNU grep's \b
# word boundary support. macOS BSD grep does not support \b as a word boundary
# in -E patterns, and when sourced with set -euo pipefail active the grep
# error would abort the test process. The subprocess invocation is also more
# faithful to the real production sequence: the hook runs as a subprocess in
# the harness, not sourced.
# ===========================================================================
printf '\n-- Group 4: analyze_tier2 for git (via subprocess) --\n'

# Test G4.1: git status → safe (allow)
G4_1_OUT=$(run_hook "git status")
G4_1_DECISION=$(printf '%s' "$G4_1_OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)
if [[ "$G4_1_DECISION" == "allow" ]]; then
    pass "G4.1: 'git status' → allow (safe)"
else
    fail "G4.1: 'git status' → expected allow, got '$G4_1_DECISION' (full: $G4_1_OUT)"
fi

# Test G4.2: git push --force — dangerous flag detection
#
# Bug #262 fix: auto-review.sh previously used grep -qE '--force\b' which failed
# silently on macOS BSD grep (\b unsupported in -E mode), causing --force to be
# misclassified as safe. Fixed by replacing \b with plain '--force' — no real git
# flag starts with --force and continues with word chars, so the trailing boundary
# was unnecessary. This test now asserts risky on all platforms.
G4_2_OUT=$(run_hook "git push --force")
G4_2_CTX=$(printf '%s' "$G4_2_OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
if [[ "$G4_2_CTX" == *"auto-review risk:"* ]]; then
    pass "G4.2: 'git push --force' → advisory context (risky, POSIX-portable detection)"
else
    G4_2_DECISION=$(printf '%s' "$G4_2_OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)
    fail "G4.2: 'git push --force' → expected advisory context, got decision='$G4_2_DECISION' ctx='$G4_2_CTX'"
fi

# Test G4.3: git reset --hard → not safe (advisory context)
G4_3_OUT=$(run_hook "git reset --hard HEAD~1")
G4_3_CTX=$(printf '%s' "$G4_3_OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
if [[ "$G4_3_CTX" == *"auto-review risk:"* ]]; then
    pass "G4.3: 'git reset --hard' → advisory context (risky)"
else
    fail "G4.3: 'git reset --hard' → expected advisory context, got '$G4_3_CTX' (full: $G4_3_OUT)"
fi

# ===========================================================================
# Group 5 — Hook end-to-end via subprocess (4 tests)
# ===========================================================================
printf '\n-- Group 5: hook end-to-end (subprocess) --\n'

# Test G5.1: Safe command → permissionDecision == "allow"
G5_1_OUT=$(run_hook "ls -la")
G5_1_DECISION=$(printf '%s' "$G5_1_OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)
if [[ "$G5_1_DECISION" == "allow" ]]; then
    pass "G5.1: safe command 'ls -la' → permissionDecision=allow"
else
    fail "G5.1: safe command 'ls -la' → expected allow, got '$G5_1_DECISION' (full: $G5_1_OUT)"
fi

# Test G5.2: Risky command → additionalContext present (advisory, not allow)
G5_2_OUT=$(run_hook "rm -rf /tmp/test")
G5_2_CTX=$(printf '%s' "$G5_2_OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
if [[ "$G5_2_CTX" == *"auto-review risk:"* ]]; then
    pass "G5.2: risky command 'rm -rf /tmp/test' → additionalContext with risk reason"
else
    fail "G5.2: risky command 'rm -rf /tmp/test' → expected additionalContext, got '$G5_2_CTX' (full: $G5_2_OUT)"
fi

# Test G5.3: Compound safe command → allow
G5_3_OUT=$(run_hook "git log --oneline && echo done")
G5_3_DECISION=$(printf '%s' "$G5_3_OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)
if [[ "$G5_3_DECISION" == "allow" ]]; then
    pass "G5.3: compound safe command 'git log && echo done' → allow"
else
    fail "G5.3: compound safe command → expected allow, got '$G5_3_DECISION' (full: $G5_3_OUT)"
fi

# Test G5.4: Compound with risky segment → advisory context
G5_4_OUT=$(run_hook "cat /tmp/file && rm -rf /tmp/file")
G5_4_CTX=$(printf '%s' "$G5_4_OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
if [[ "$G5_4_CTX" == *"auto-review risk:"* ]]; then
    pass "G5.4: compound with risky segment 'cat && rm -rf' → advisory context"
else
    fail "G5.4: compound with risky segment → expected advisory context, got '$G5_4_CTX' (full: $G5_4_OUT)"
fi

# ===========================================================================
# Group 6 — check-guardian.sh grep pattern for git -C form (Bug #141)
#
# These tests directly verify that the grep patterns on lines 178 and 190 of
# check-guardian.sh match both 'git commit' and 'git -C /path commit' forms.
# We grep inline (not via subprocess hook) to test the pattern directly.
# ===========================================================================
printf '\n-- Group 6: check-guardian git -C pattern (Bug #141) --\n'

# shellcheck disable=SC2034  # GUARDIAN_HOOK reserved for future direct-invoke tests
GUARDIAN_HOOK="$REPO_ROOT/hooks/check-guardian.sh"

# Test G6.1: plain 'git commit' form — matches original pattern
G6_1_TEXT="The agent ran git commit -m 'fix'"
if printf '%s' "$G6_1_TEXT" | grep -qiE 'merged|committed|git\s+(\S+\s+)*merge|git\s+(\S+\s+)*commit'; then
    pass "G6.1: 'git commit' form matched by check-guardian pattern"
else
    fail "G6.1: 'git commit' form should match check-guardian pattern"
fi

# Test G6.2: 'git -C /path commit' form — previously missed, now caught
G6_2_TEXT="The agent ran git -C /repo/path commit -m 'fix'"
if printf '%s' "$G6_2_TEXT" | grep -qiE 'merged|committed|git\s+(\S+\s+)*merge|git\s+(\S+\s+)*commit'; then
    pass "G6.2: 'git -C /path commit' form matched by check-guardian pattern (Bug #141)"
else
    fail "G6.2: 'git -C /path commit' form should match check-guardian pattern (Bug #141)"
fi

# Test G6.3: 'git -C /path push' form — matched by Check 6 pattern
G6_3_TEXT="Pushed: git -C /repo/worktree push origin feature/foo"
if printf '%s' "$G6_3_TEXT" | grep -qiE 'merged|committed|pushed|git\s+(\S+\s+)*merge|git\s+(\S+\s+)*commit|git\s+(\S+\s+)*push'; then
    pass "G6.3: 'git -C /path push' form matched by check-guardian Check 6 pattern"
else
    fail "G6.3: 'git -C /path push' form should match check-guardian Check 6 pattern"
fi

# Test G6.4: safe text with no git ops — must NOT match
G6_4_TEXT="The agent ran ls and echo hello"
if ! printf '%s' "$G6_4_TEXT" | grep -qiE 'merged|committed|pushed|git\s+(\S+\s+)*merge|git\s+(\S+\s+)*commit|git\s+(\S+\s+)*push'; then
    pass "G6.4: non-git-op text does not match check-guardian pattern (no false positive)"
else
    fail "G6.4: non-git-op text should NOT match check-guardian pattern"
fi


# ===========================================================================
# Group 7 — classify_git_op (Fix #175: BSD grep \b patterns)
#
# classify_git_op lives in hooks/context-lib.sh. It previously used \b
# word-boundary assertions that silently failed on macOS BSD grep, causing
# all git ops to fall through to "unclassified". Fix #175 replaced \b with
# explicit POSIX ERE anchors: (^|\s)git(\s.*\s|\s)(subcommand)(\s|$).
#
# These tests source only classify_git_op (extracted via awk, no runtime deps)
# and verify the classification result on macOS BSD grep.
# ===========================================================================
printf '\n-- Group 7: classify_git_op BSD-grep compatibility (Fix #175) --\n'

CONTEXT_LIB="$REPO_ROOT/hooks/context-lib.sh"
CTX_STUB="$TMP_DIR/ctx_funcs.sh"

# Extract just classify_git_op from context-lib.sh — stops at closing brace
awk '
    /^classify_git_op\(\)/ { in_func=1 }
    in_func { print }
    in_func && /^\}$/ { in_func=0 }
' "$CONTEXT_LIB" > "$CTX_STUB"

# Prepend minimal header (no runtime deps needed — classify_git_op is pure)
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    cat "$CTX_STUB"
} > "$TMP_DIR/ctx_with_header.sh"
mv "$TMP_DIR/ctx_with_header.sh" "$CTX_STUB"

# shellcheck disable=SC1090
source "$CTX_STUB"

# Test G7.1: plain 'git commit -m test' → routine_local
G7_1_RESULT=$(classify_git_op "git commit -m test")
if [[ "$G7_1_RESULT" == "routine_local" ]]; then
    pass "G7.1: 'git commit -m test' → routine_local (got '$G7_1_RESULT')"
else
    fail "G7.1: 'git commit -m test' → expected routine_local, got '$G7_1_RESULT'"
fi

# Test G7.2: 'git -C /path commit -m test' → routine_local (handles -C form)
G7_2_RESULT=$(classify_git_op "git -C /repo/path commit -m test")
if [[ "$G7_2_RESULT" == "routine_local" ]]; then
    pass "G7.2: 'git -C /path commit -m test' → routine_local (got '$G7_2_RESULT')"
else
    fail "G7.2: 'git -C /path commit -m test' → expected routine_local, got '$G7_2_RESULT'"
fi

# Test G7.3: 'git push origin main' → high_risk
G7_3_RESULT=$(classify_git_op "git push origin main")
if [[ "$G7_3_RESULT" == "high_risk" ]]; then
    pass "G7.3: 'git push origin main' → high_risk (got '$G7_3_RESULT')"
else
    fail "G7.3: 'git push origin main' → expected high_risk, got '$G7_3_RESULT'"
fi

# Test G7.4: 'git merge --abort' → admin_recovery
G7_4_RESULT=$(classify_git_op "git merge --abort")
if [[ "$G7_4_RESULT" == "high_risk" || "$G7_4_RESULT" == "admin_recovery" ]]; then
    if [[ "$G7_4_RESULT" == "admin_recovery" ]]; then
        pass "G7.4: 'git merge --abort' → admin_recovery (got '$G7_4_RESULT')"
    else
        fail "G7.4: 'git merge --abort' → expected admin_recovery, got '$G7_4_RESULT'"
    fi
else
    fail "G7.4: 'git merge --abort' → expected admin_recovery, got '$G7_4_RESULT'"
fi

# Test G7.5: 'git reset --merge' → admin_recovery
G7_5_RESULT=$(classify_git_op "git reset --merge")
if [[ "$G7_5_RESULT" == "admin_recovery" ]]; then
    pass "G7.5: 'git reset --merge' → admin_recovery (got '$G7_5_RESULT')"
else
    fail "G7.5: 'git reset --merge' → expected admin_recovery, got '$G7_5_RESULT'"
fi

# Test G7.6: 'git rebase origin/main' → high_risk
G7_6_RESULT=$(classify_git_op "git rebase origin/main")
if [[ "$G7_6_RESULT" == "high_risk" ]]; then
    pass "G7.6: 'git rebase origin/main' → high_risk (got '$G7_6_RESULT')"
else
    fail "G7.6: 'git rebase origin/main' → expected high_risk, got '$G7_6_RESULT'"
fi

# Test G7.7: 'git reset --hard HEAD~1' → high_risk (reset, not admin_recovery)
G7_7_RESULT=$(classify_git_op "git reset --hard HEAD~1")
if [[ "$G7_7_RESULT" == "high_risk" ]]; then
    pass "G7.7: 'git reset --hard HEAD~1' → high_risk (got '$G7_7_RESULT')"
else
    fail "G7.7: 'git reset --hard HEAD~1' → expected high_risk, got '$G7_7_RESULT'"
fi

# Test G7.8: 'ls -la' → unclassified (no git op)
G7_8_RESULT=$(classify_git_op "ls -la")
if [[ "$G7_8_RESULT" == "unclassified" ]]; then
    pass "G7.8: 'ls -la' → unclassified (got '$G7_8_RESULT')"
else
    fail "G7.8: 'ls -la' → expected unclassified, got '$G7_8_RESULT'"
fi

# Test G7.9: 'git log --oneline' → unclassified (read-only git op)
G7_9_RESULT=$(classify_git_op "git log --oneline")
if [[ "$G7_9_RESULT" == "unclassified" ]]; then
    pass "G7.9: 'git log --oneline' → unclassified (got '$G7_9_RESULT')"
else
    fail "G7.9: 'git log --oneline' → expected unclassified, got '$G7_9_RESULT'"
fi

# Test G7.10: 'git merge --no-ff feature/foo' → high_risk (non-ff merge)
G7_10_RESULT=$(classify_git_op "git merge --no-ff feature/foo")
if [[ "$G7_10_RESULT" == "high_risk" ]]; then
    pass "G7.10: 'git merge --no-ff feature/foo' → high_risk (got '$G7_10_RESULT')"
else
    fail "G7.10: 'git merge --no-ff feature/foo' → expected high_risk, got '$G7_10_RESULT'"
fi

# Test G7.11: compound interaction — 'git -C /repo rebase' → high_risk (-C form)
G7_11_RESULT=$(classify_git_op "git -C /repo rebase origin/main")
if [[ "$G7_11_RESULT" == "high_risk" ]]; then
    pass "G7.11: 'git -C /repo rebase' → high_risk (got '$G7_11_RESULT')"
else
    fail "G7.11: 'git -C /repo rebase' → expected high_risk, got '$G7_11_RESULT'"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
printf '\n'
if [[ "$FAILURES" -gt 0 ]]; then
    printf 'FAIL: %s — %d check(s) failed\n' "$TEST_NAME" "$FAILURES"
    exit 1
fi

printf 'PASS: %s\n' "$TEST_NAME"
exit 0
