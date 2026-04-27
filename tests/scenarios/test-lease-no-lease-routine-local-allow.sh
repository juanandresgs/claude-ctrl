#!/usr/bin/env bash
# test-lease-no-lease-routine-local-allow.sh — No lease → ALL git ops denied.
# Post-INIT-PE, Check 3 denies every git op (commit, merge, push) when no
# active dispatch lease exists for the worktree. The old "no-lease +
# routine_local → allowed" path is removed.
#
# Sub-cases:
#   A: No lease + eval ready + commit → denied by Check 3 (no active lease)
#   B: No lease + eval NOT ready + commit → denied by Check 3 (no active lease)
#   C: No lease + eval ready + merge → denied by Check 3 (no active lease)
#
# @decision DEC-LEASE-002
# @title Check 3 uses lease validate_op, not marker role
# @status accepted
# @rationale Post-INIT-PE all git ops require an active dispatch lease.
#   Check 3 is the sole authority: no lease → deny regardless of op type or
#   evaluation_state. The no-lease routine_local allow path is removed.
set -euo pipefail

TEST_NAME="test-lease-no-lease-routine-local-allow"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-bash.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $TEST_NAME [$1] — $2"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $TEST_NAME [$1] — $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

_decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true; }
_reason()   { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true; }

_run_guard() {
    local cmd="$1" project_dir="$2" db="$3"
    local payload
    payload=$(jq -n --arg t "Bash" --arg c "$cmd" --arg w "$project_dir" \
        '{tool_name:$t,tool_input:{command:$c},cwd:$w}')
    printf '%s' "$payload" \
        | CLAUDE_PROJECT_DIR="$project_dir" \
          CLAUDE_POLICY_DB="$db" \
          CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" \
          "$HOOK" 2>/dev/null || true
}

_setup() {
    local branch="$1"
    WF_ID=$(printf '%s' "$branch" | tr '/: ' '---' | tr -cd '[:alnum:]._-')
    TMP_DIR="$REPO_ROOT/tmp/${TEST_NAME}-${WF_ID}-$$"
    TEST_DB="$TMP_DIR/.claude/state.db"

    mkdir -p "$TMP_DIR/.claude"
    (cd "$TMP_DIR" && git init -q && git config user.email "t@t.com" && git config user.name "T")
    (cd "$TMP_DIR" && git commit --allow-empty -m "init" -q)
    (cd "$TMP_DIR" && git checkout -b "$branch" -q)
    CURRENT_HEAD=$(git -C "$TMP_DIR" rev-parse HEAD)

    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian:land" --project-root "$TMP_DIR" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        test-state set pass --project-root "$TMP_DIR" --passed 1 --total 1 >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$CURRENT_HEAD" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$WF_ID" "$TMP_DIR" "$branch" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1
    # NO lease issued
}

# shellcheck disable=SC2329
_teardown() { [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"; TMP_DIR=""; }

# ---------------------------------------------------------------------------
# Sub-case A: No lease + eval ready + commit → denied by Check 3
# ---------------------------------------------------------------------------
run_sub_case_a() {
    local branch="feature/no-lease-commit-allow"
    _setup "$branch"
    trap '_teardown' RETURN

    local cmd output decision reason
    cmd="git -C \"$TMP_DIR\" commit --allow-empty -m 'no-lease routine commit'"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")
    reason=$(_reason "$output")

    if [[ "$decision" != "deny" ]]; then
        fail "A" "expected deny for no-lease commit, got decision='$decision'"
        return
    fi
    if ! printf '%s' "$reason" | grep -qiE "lease|No active"; then
        fail "A" "deny reason should mention 'lease', got: $reason"
        return
    fi
    pass "A" "no lease + eval ready + commit → denied (No active dispatch lease)"
}

# ---------------------------------------------------------------------------
# Sub-case B: No lease + eval NOT ready + commit → denied by Check 3
# Post-INIT-PE: Check 3 fires before Check 10. No lease → denied regardless
# of evaluation_state. The deny reason mentions "lease", not "evaluation_state".
# ---------------------------------------------------------------------------
run_sub_case_b() {
    local branch="feature/nolicense-commit-eval-deny"
    _setup "$branch"
    trap '_teardown' RETURN

    # Override eval to needs_changes (Check 10 would fire here, but Check 3 fires first)
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$WF_ID" "needs_changes" >/dev/null 2>&1

    local cmd output decision reason
    cmd="git -C \"$TMP_DIR\" commit --allow-empty -m 'premature commit'"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")
    reason=$(_reason "$output")

    if [[ "$decision" != "deny" ]]; then
        fail "B" "expected deny (Check 3: no lease), got decision='$decision'"
        return
    fi
    if ! printf '%s' "$reason" | grep -qiE "lease|No active"; then
        fail "B" "deny reason should mention 'lease', got: $reason"
        return
    fi
    pass "B" "no lease + needs_changes eval + commit → denied by Check 3 (lease, not evaluation_state)"
}

# ---------------------------------------------------------------------------
# Sub-case C: No lease + plain merge + eval ready → denied by Check 3
# Post-INIT-PE: merge is a git op; all git ops require an active lease.
# ---------------------------------------------------------------------------
run_sub_case_c() {
    local branch="feature/nolicense-merge-allow"
    _setup "$branch"
    trap '_teardown' RETURN

    # Create a second branch to merge from. Check 3 denies before merge-source
    # workflow/evaluation state is consulted.
    (cd "$TMP_DIR" && git checkout -b "feature/merge-source" -q && git commit --allow-empty -m "src" -q)
    (cd "$TMP_DIR" && git checkout "$branch" -q)

    local cmd output decision reason
    cmd="git -C \"$TMP_DIR\" merge feature/merge-source"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")
    reason=$(_reason "$output")

    if [[ "$decision" != "deny" ]]; then
        fail "C" "expected deny for no-lease merge, got decision='$decision'"
        return
    fi
    if ! printf '%s' "$reason" | grep -qiE "lease|No active"; then
        fail "C" "deny reason should mention 'lease', got: $reason"
        return
    fi
    pass "C" "no lease + eval ready + merge → denied (No active dispatch lease)"
}

echo "=== $TEST_NAME: starting ==="
run_sub_case_a
run_sub_case_b
run_sub_case_c
echo ""
echo "=== $TEST_NAME: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -gt 0 ]] && exit 1
exit 0
