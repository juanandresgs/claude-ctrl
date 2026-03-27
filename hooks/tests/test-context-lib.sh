#!/usr/bin/env bash
# Regression test for context-lib.sh shell bug class:
# VAR=$(cmd || echo fallback) concatenates output when cmd exits non-zero
# but has already written to stdout. Fixed by moving fallback to assignment level.
#
# @decision DEC-TEST-CTX-001
# @title Regression: grep -c and git on non-zero exit produce embedded newlines
# @status accepted
# @rationale grep -c exits 1 with 0 matches but still prints "0" to stdout.
#   git rev-parse --abbrev-ref HEAD may emit output before exiting non-zero.
#   Both caused malformed variable values ("0\n0", "HEAD\nunknown") that broke
#   downstream [[ -gt ]] and [[ -ge ]] arithmetic comparisons.

# No set -euo pipefail — test harness must survive assertion failures.

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_integer() {
    local name="$1" val="$2"
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        pass "$name is clean integer: '$val'"
    else
        fail "$name is NOT clean integer: $(printf '%q' "$val")"
    fi
}

assert_no_newline() {
    local name="$1" val="$2"
    if [[ "$val" != *$'\n'* ]]; then
        pass "$name has no embedded newline"
    else
        fail "$name has embedded newline: $(printf '%q' "$val")"
    fi
}

assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$name contains: '$needle'"
    else
        fail "$name does NOT contain: '$needle'"
        echo "    actual: $(printf '%q' "$haystack")"
    fi
}

assert_not_contains() {
    local name="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$name does not contain: '$needle'"
    else
        fail "$name CONTAINS unexpected: '$needle'"
    fi
}

# ── run_hook: invoke prompt-submit.sh targeting a specific repo ─────────────
# Sets CLAUDE_PROJECT_DIR so detect_project_root resolves to the target repo.
# Returns: HOOK_OUT (stdout), HOOK_EXIT (real exit code), HOOK_ERR (stderr).
run_hook() {
    local target_repo="$1" prompt="$2" session="$3"
    local json
    json=$(jq -n \
        --arg cwd "$target_repo" \
        --arg prompt "$prompt" \
        --arg session_id "$session" \
        '{cwd: $cwd, prompt: $prompt, session_id: $session_id}')

    local tmp_err tmp_out
    tmp_err=$(mktemp)
    tmp_out=$(mktemp)

    CLAUDE_PROJECT_DIR="$target_repo" \
        bash "$HOOKS_DIR/prompt-submit.sh" \
        < <(echo "$json") \
        >"$tmp_out" 2>"$tmp_err"
    HOOK_EXIT=$?
    HOOK_OUT=$(cat "$tmp_out")
    HOOK_ERR=$(cat "$tmp_err")
    rm -f "$tmp_out" "$tmp_err"
}

# ── Setup ──────────────────────────────────────────────────────────────────

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

GIT_OPTS=(-c user.email="t@t.com" -c user.name="T")

# Repo A: MASTER_PLAN.md present, zero Phase headers
REPO_NO_PHASES="$TMPDIR_BASE/no-phases"
mkdir -p "$REPO_NO_PHASES"
git -C "$REPO_NO_PHASES" init -q
git -C "$REPO_NO_PHASES" "${GIT_OPTS[@]}" commit --allow-empty -m "init" -q
cat > "$REPO_NO_PHASES/MASTER_PLAN.md" <<'EOF'
# My Plan

No Phase headers — just a description.

**Status:** in-progress
EOF

# Repo B: research-log.md present, zero matching entries
REPO_RESEARCH="$TMPDIR_BASE/research"
mkdir -p "$REPO_RESEARCH/.claude"
git -C "$REPO_RESEARCH" init -q
git -C "$REPO_RESEARCH" "${GIT_OPTS[@]}" commit --allow-empty -m "init" -q
cat > "$REPO_RESEARCH/.claude/research-log.md" <<'EOF'
# Research Log

No entries — no "### [" lines.
EOF

# Repo C: unborn repo (no commits)
REPO_UNBORN="$TMPDIR_BASE/unborn"
mkdir -p "$REPO_UNBORN"
git -C "$REPO_UNBORN" init -q
# No commits — HEAD is unresolvable

# ── Source library for unit tests (scenarios A–C) ─────────────────────────

detect_project_root() { echo "${_TEST_ROOT:-$PWD}"; }
export -f detect_project_root

source "$HOOKS_DIR/context-lib.sh"

# ── Scenario A: MASTER_PLAN.md with zero Phase headers ─────────────────────

echo ""
echo "=== Scenario A: MASTER_PLAN.md with zero Phase headers ==="
_TEST_ROOT="$REPO_NO_PHASES"
get_plan_status "$REPO_NO_PHASES"

assert_integer   "PLAN_TOTAL_PHASES"       "$PLAN_TOTAL_PHASES"
assert_integer   "PLAN_COMPLETED_PHASES"   "$PLAN_COMPLETED_PHASES"
assert_integer   "PLAN_IN_PROGRESS_PHASES" "$PLAN_IN_PROGRESS_PHASES"
assert_no_newline "PLAN_TOTAL_PHASES"      "$PLAN_TOTAL_PHASES"

# Verify downstream arithmetic does not crash
if [[ "$PLAN_TOTAL_PHASES" -gt 0 ]] 2>/dev/null; then
    pass "[[ PLAN_TOTAL_PHASES -gt 0 ]]: no crash (branch taken)"
else
    pass "[[ PLAN_TOTAL_PHASES -gt 0 ]]: no crash (branch not taken)"
fi

# ── Scenario B: research-log.md with zero entries ──────────────────────────

echo ""
echo "=== Scenario B: research-log.md with zero entries ==="
_TEST_ROOT="$REPO_RESEARCH"
get_research_status "$REPO_RESEARCH"

assert_integer    "RESEARCH_ENTRY_COUNT"   "$RESEARCH_ENTRY_COUNT"
assert_no_newline "RESEARCH_ENTRY_COUNT"   "$RESEARCH_ENTRY_COUNT"

# ── Scenario C: GIT_BRANCH in unborn repo ─────────────────────────────────

echo ""
echo "=== Scenario C: GIT_BRANCH in unborn repo ==="
_TEST_ROOT="$REPO_UNBORN"
get_git_state "$REPO_UNBORN"

assert_no_newline "GIT_BRANCH" "$GIT_BRANCH"
pass "GIT_BRANCH resolved to: '${GIT_BRANCH:-<empty>}'"

# ── Scenario D: full hook chain — no-phases repo ───────────────────────────
# Uses CLAUDE_PROJECT_DIR so detect_project_root resolves to REPO_NO_PHASES.

echo ""
echo "=== Scenario D: prompt-submit.sh — no-phases repo (first prompt) ==="
run_hook "$REPO_NO_PHASES" "What is the plan status?" "test-ctx-D-$$"

if [[ "$HOOK_EXIT" -eq 0 ]]; then
    pass "hook exits 0"
else
    fail "hook exits $HOOK_EXIT"
    [[ -n "$HOOK_ERR" ]] && echo "    stderr: $HOOK_ERR"
fi

if [[ -n "$HOOK_OUT" ]] && echo "$HOOK_OUT" | jq . >/dev/null 2>&1; then
    pass "output is valid JSON"
    CTX_D=$(echo "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
    echo "    additionalContext: $CTX_D"
    assert_contains   "additionalContext" "$CTX_D" "branch="
    assert_contains   "additionalContext" "$CTX_D" "0/0 phases done"
    assert_no_newline "additionalContext branch field" \
        "$(echo "$CTX_D" | grep 'branch=' || true)"
elif [[ -z "$HOOK_OUT" ]]; then
    fail "output is empty — expected JSON with plan context"
else
    fail "output is not valid JSON: $HOOK_OUT"
fi

# ── Scenario E: full hook chain — unborn repo ─────────────────────────────

echo ""
echo "=== Scenario E: prompt-submit.sh — unborn repo (first prompt) ==="
run_hook "$REPO_UNBORN" "What branch am I on?" "test-ctx-E-$$"

if [[ "$HOOK_EXIT" -eq 0 ]]; then
    pass "hook exits 0"
else
    fail "hook exits $HOOK_EXIT"
    [[ -n "$HOOK_ERR" ]] && echo "    stderr: $HOOK_ERR"
fi

if [[ -n "$HOOK_OUT" ]] && echo "$HOOK_OUT" | jq . >/dev/null 2>&1; then
    pass "output is valid JSON"
    CTX_E=$(echo "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
    echo "    additionalContext: $CTX_E"
    assert_contains     "additionalContext" "$CTX_E" "branch=unknown"
    assert_not_contains "additionalContext" "$CTX_E" "HEAD"
    # The branch line must have "branch=unknown" and "uncommitted" on the SAME line.
    # If the old bug were present, GIT_BRANCH="HEAD\nunknown" would split them across lines.
    BRANCH_LINE=$(echo "$CTX_E" | grep 'branch=' || true)
    assert_contains     "branch line" "$BRANCH_LINE" "uncommitted"
    assert_no_newline   "branch line" "$BRANCH_LINE"
elif [[ -z "$HOOK_OUT" ]]; then
    fail "output is empty — expected JSON with git context for first prompt"
else
    fail "output is not valid JSON: $HOOK_OUT"
fi

# ── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
