#!/usr/bin/env bash
# test-guard-no-lease-denied.sh — Proves that ALL git operations without a lease
# are denied after TKT-STAB-A3, including routine_local ops (commit/merge).
#
# Before TKT-STAB-A3:
#   - high_risk ops (push) without a lease → denied by Check 3
#   - routine_local ops (commit, merge) without a lease → allowed (Check 10 owned the gate)
#
# After TKT-STAB-A3:
#   - ALL git ops without a lease → denied by Check 3
#   - The "routine_local without a lease: allow" bypass is removed
#   - Meta-repo bypass is the sole exception (not tested here)
#
# Sub-cases:
#   A: git commit without a lease in non-meta-repo → denied, reason mentions "lease"
#   B: git merge without a lease in non-meta-repo → denied, reason mentions "lease"
#   C: git push without a lease in non-meta-repo → denied, reason mentions "lease"
#   D: git commit WITH a valid lease + ready_for_guardian → allowed (lease path unchanged)
#
# @decision DEC-GUARD-003
# @title WHO enforcement uses lease validate_op — no unleased git ops in enforced projects
# @status accepted (updated TKT-STAB-A3)
# @rationale All git ops require an active lease. The legacy routine_local bypass is removed.
#   This test covers the production sequence: orchestrator dispatches with a lease;
#   without that dispatch, guard.sh denies at Check 3.
set -euo pipefail

TEST_NAME="test-guard-no-lease-denied"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/guard.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $TEST_NAME [$1] — $2"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $TEST_NAME [$1] — $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_decision() {
    printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true
}

_reason() {
    printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true
}

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

# Set up a scratch non-meta-repo git repo with no active lease.
# Sets globals: TMP_DIR, TEST_DB, WF_ID, CURRENT_HEAD.
_setup_repo_no_lease() {
    local branch="$1" role="${2:-implementer}"
    WF_ID=$(printf '%s' "$branch" | tr '/: ' '---' | tr -cd '[:alnum:]._-')
    TMP_DIR="$REPO_ROOT/tmp/${TEST_NAME}-${WF_ID}-$$"
    TEST_DB="$TMP_DIR/.claude/state.db"

    mkdir -p "$TMP_DIR/.claude"
    git -C "$TMP_DIR" init -q
    git -C "$TMP_DIR" config user.email "t@t.com"
    git -C "$TMP_DIR" config user.name "T"
    git -C "$TMP_DIR" commit --allow-empty -m "init" -q
    git -C "$TMP_DIR" checkout -b "$branch" -q
    CURRENT_HEAD=$(git -C "$TMP_DIR" rev-parse HEAD)

    # Schema + role marker — no lease issued
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        marker set "agent-test" "$role" >/dev/null 2>&1

    # Test status = pass (ensures Check 10 won't be the first gate)
    echo "pass|0|$(date +%s)" > "$TMP_DIR/.claude/.test-status"

    # Workflow binding + scope (so Check 12 doesn't fire first)
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$WF_ID" "$TMP_DIR" "$branch" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1

    # NOTE: No lease is issued — this is the key condition under test
}

# ---------------------------------------------------------------------------
# Sub-case A: git commit without a lease → denied by Check 3
#
# Production sequence: implementer spawned without cc-policy lease issue-for-dispatch.
# Guard.sh Check 3 finds no active lease and denies before reaching Check 10.
# Before TKT-STAB-A3 this would have passed Check 3 (routine_local bypass).
# ---------------------------------------------------------------------------
run_sub_case_a() {
    local branch="feature/no-lease-commit-denied"
    _setup_repo_no_lease "$branch" "implementer"
    trap 'rm -rf "$TMP_DIR"' RETURN

    # Set evaluation_state=ready_for_guardian — the commit WOULD pass Check 10 if it
    # reached it, proving the denial is from Check 3 (no lease), not Check 10.
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$CURRENT_HEAD" >/dev/null 2>&1

    local cmd output decision reason
    cmd="git -C \"$TMP_DIR\" commit --allow-empty -m 'unleased commit'"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")
    reason=$(_reason "$output")

    if [[ "$decision" != "deny" ]]; then
        fail "A" "expected deny for commit without lease, got decision='$decision'"
        return
    fi
    if ! printf '%s' "$reason" | grep -qi "lease"; then
        fail "A" "deny reason should mention 'lease', got: $reason"
        return
    fi
    pass "A" "git commit without lease denied by Check 3 (reason mentions 'lease')"
}

# ---------------------------------------------------------------------------
# Sub-case B: git merge without a lease → denied by Check 3
#
# Plain merge was previously routine_local (bypassed Check 3).
# After TKT-STAB-A3, no lease = deny regardless of op class.
# ---------------------------------------------------------------------------
run_sub_case_b() {
    local branch="feature/no-lease-merge-denied"
    _setup_repo_no_lease "$branch" "implementer"
    trap 'rm -rf "$TMP_DIR"' RETURN

    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$CURRENT_HEAD" >/dev/null 2>&1

    local cmd output decision reason
    cmd="git -C \"$TMP_DIR\" merge feature/some-branch"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")
    reason=$(_reason "$output")

    if [[ "$decision" != "deny" ]]; then
        fail "B" "expected deny for merge without lease, got decision='$decision'"
        return
    fi
    if ! printf '%s' "$reason" | grep -qi "lease"; then
        fail "B" "deny reason should mention 'lease', got: $reason"
        return
    fi
    pass "B" "git merge without lease denied by Check 3 (reason mentions 'lease')"
}

# ---------------------------------------------------------------------------
# Sub-case C: git push without a lease → denied by Check 3
#
# Push was already denied before TKT-STAB-A3 (high_risk path). Confirming
# the new unified path still denies push for consistency.
# ---------------------------------------------------------------------------
run_sub_case_c() {
    local branch="feature/no-lease-push-denied"
    _setup_repo_no_lease "$branch" "implementer"
    trap 'rm -rf "$TMP_DIR"' RETURN

    local cmd output decision reason
    cmd="git -C \"$TMP_DIR\" push origin $branch"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")
    reason=$(_reason "$output")

    if [[ "$decision" != "deny" ]]; then
        fail "C" "expected deny for push without lease, got decision='$decision'"
        return
    fi
    if ! printf '%s' "$reason" | grep -qi "lease"; then
        fail "C" "deny reason should mention 'lease', got: $reason"
        return
    fi
    pass "C" "git push without lease denied by Check 3 (reason mentions 'lease')"
}

# ---------------------------------------------------------------------------
# Sub-case D: git commit WITH a valid lease + ready_for_guardian → allowed
#
# Compound-interaction test: covers the real production sequence end-to-end.
# 1. Orchestrator issues lease via cc-policy lease issue-for-dispatch.
# 2. Implementer runs git commit.
# 3. Check 3 finds lease → validate_op() returns allowed=true.
# 4. Check 10 finds ready_for_guardian + matching SHA → allowed.
# 5. Commit proceeds.
# ---------------------------------------------------------------------------
run_sub_case_d() {
    local branch="feature/with-lease-commit-allowed"
    _setup_repo_no_lease "$branch" "implementer"
    trap 'rm -rf "$TMP_DIR"' RETURN

    # Set evaluation_state=ready_for_guardian with matching HEAD SHA
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$CURRENT_HEAD" >/dev/null 2>&1

    # Issue an implementer lease with routine_local ops allowed
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        lease issue-for-dispatch "implementer" \
        --workflow-id "$WF_ID" \
        --worktree-path "$TMP_DIR" \
        --branch "$branch" \
        --allowed-ops '["routine_local"]' >/dev/null 2>&1

    local cmd output decision
    cmd="git -C \"$TMP_DIR\" commit --allow-empty -m 'leased commit'"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")

    if [[ -z "$output" || "$decision" != "deny" ]]; then
        pass "D" "git commit WITH lease + ready_for_guardian allowed (lease path unchanged)"
    else
        fail "D" "unexpected deny with valid lease: $(_reason "$output")"
    fi
}

# ---------------------------------------------------------------------------
# Run all sub-cases
# ---------------------------------------------------------------------------
echo "=== $TEST_NAME: starting ==="

run_sub_case_a
run_sub_case_b
run_sub_case_c
run_sub_case_d

echo ""
echo "=== $TEST_NAME: $PASS_COUNT passed, $FAIL_COUNT failed ==="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
