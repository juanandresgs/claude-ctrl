#!/usr/bin/env bash
# test-guard-check3-who-classification.sh — Proves Check 3 lease enforcement
# gates all git ops (routine_local and high_risk) on an active dispatch lease.
#
# Updated TKT-STAB-A3: The legacy "routine_local without a lease → allow" bypass
# is removed. ALL git ops now require an active lease. Lease + eval state together
# are the two-factor gate for commit/merge. The classifier still separates op
# classes for allowed_ops matching inside validate_op().
#
# Sub-cases:
#   A: Routine commit by guardian:land + guardian lease + ready_for_guardian → allowed
#   B: Routine commit by guardian:land with lease but WITHOUT ready_for_guardian → denied by Check 10
#   C: Push by implementer role, no lease → denied by Check 3
#   D: Push by guardian:land role, lease, and ready_for_guardian → allowed (no approval token needed)
#   E: Merge by guardian:land + guardian lease + ready_for_guardian → allowed
#   F: Merge --no-ff by implementer role, no lease → denied by Check 3 (high_risk)
#
# @decision DEC-GUARD-003
# @title WHO enforcement uses lease validate_op — no unleased git ops in enforced projects
# @status accepted (updated TKT-STAB-A3)
# @rationale All git operations in the enforced project now require an active lease.
#   The legacy "routine_local without a lease → allow" path is removed.
#   Lease validate_op() is the sole Check 3 authority; Check 10 gates eval readiness.
#   Meta-repo bypass is the sole exception (not tested here).
set -euo pipefail

TEST_NAME="test-guard-check3-who-classification"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-bash.sh"
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

_seed_guardian_land_phase() {
    local db="$1" workflow_id="$2"
    python3 - "$db" "$workflow_id" <<'PY' >/dev/null 2>&1
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
try:
    conn.execute(
        "INSERT INTO completion_records "
        "(lease_id, workflow_id, role, verdict, valid, payload_json, missing_fields, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, CAST(strftime('%s','now') AS INTEGER))",
        ("seed-lease", sys.argv[2], "reviewer", "ready_for_guardian", 1, "{}", "[]"),
    )
    conn.commit()
finally:
    conn.close()
PY
}

# Build a scratch git repo with all guards satisfied for commit by an
# implementer role. Sets globals: TMP_DIR, TEST_DB, WF_ID, CURRENT_HEAD.
_setup_repo() {
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

    # Schema + role marker (NOT guardian unless specified)
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        marker set "agent-test" "$role" --project-root "$TMP_DIR" >/dev/null 2>&1

    # Test status = pass (SQLite authority — Check 8/9 read via rt_test_state_get, not flat file)
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        test-state set "pass" --project-root "$TMP_DIR" >/dev/null 2>&1

    # Workflow binding + scope
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$WF_ID" "$TMP_DIR" "$branch" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Sub-case A: Routine commit by guardian:land + active guardian lease + ready_for_guardian → allowed
#
# Production sequence: reviewer clears the workflow, guardian:land holds the
# landing seat, and a guardian lease authorises the commit. Check 3 finds the
# active lease, the landing-authority gate recognises guardian:land, and
# Check 10 sees ready_for_guardian + matching SHA.
# ---------------------------------------------------------------------------
run_sub_case_a() {
    local branch="feature/check3-commit-implementer"
    _setup_repo "$branch" "guardian"
    trap 'rm -rf "$TMP_DIR"' RETURN
    _seed_guardian_land_phase "$TEST_DB" "$WF_ID"

    # Set evaluation_state=ready_for_guardian with matching HEAD SHA
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$CURRENT_HEAD" >/dev/null 2>&1

    # Issue guardian lease (landing seat).
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        lease issue-for-dispatch "guardian" \
        --workflow-id "$WF_ID" \
        --worktree-path "$TMP_DIR" \
        --branch "$branch" \
        --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1

    local cmd output decision
    cmd="git -C \"$TMP_DIR\" commit --allow-empty -m 'guardian commit'"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")

    if [[ -z "$output" || "$decision" != "deny" ]]; then
        pass "A" "routine commit by guardian:land with lease + ready_for_guardian allowed"
    else
        fail "A" "unexpected deny: $(_reason "$output")"
    fi
}

# ---------------------------------------------------------------------------
# Sub-case B: Routine commit by guardian:land WITH lease but WITHOUT ready_for_guardian → denied by Check 10
#
# TKT-STAB-A3: Check 3 now requires a lease for all git ops. A lease is issued here
# so Check 3 passes (validate_op allows routine_local). Check 10 then fires because
# evaluation_state=needs_changes. Deny reason must mention "evaluation_state".
# This proves the lease gate and the eval gate are separate: having a lease is not
# sufficient — eval readiness is still required by Check 10.
# ---------------------------------------------------------------------------
run_sub_case_b() {
    local branch="feature/check3-commit-needs-changes"
    _setup_repo "$branch" "guardian"
    trap 'rm -rf "$TMP_DIR"' RETURN
    _seed_guardian_land_phase "$TEST_DB" "$WF_ID"

    # Explicitly set needs_changes — no ready_for_guardian
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$WF_ID" "needs_changes" >/dev/null 2>&1

    # Issue a lease so Check 3 passes — Check 10 becomes the active gate
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        lease issue-for-dispatch "guardian" \
        --workflow-id "$WF_ID" \
        --worktree-path "$TMP_DIR" \
        --branch "$branch" \
        --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1

    local cmd output decision reason
    cmd="git -C \"$TMP_DIR\" commit --allow-empty -m 'premature commit'"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")
    reason=$(_reason "$output")

    if [[ "$decision" != "deny" ]]; then
        fail "B" "expected deny (Check 10), got decision='$decision'"
        return
    fi
    if ! printf '%s' "$reason" | grep -qi "evaluation_state"; then
        fail "B" "deny reason should mention 'evaluation_state', got: $reason"
        return
    fi
    # Must NOT say "Guardian agent" — that would mean old Check 3 role-check fired
    if printf '%s' "$reason" | grep -qi "Guardian agent"; then
        fail "B" "deny reason mentions 'Guardian agent' — old Check 3 role-check fired: $reason"
        return
    fi
    pass "B" "guardian:land commit with lease but without ready_for_guardian denied by Check 10"
}

# ---------------------------------------------------------------------------
# Sub-case C: Push by implementer role, no lease → denied by Check 3
#
# Push is high_risk. Check 3 (lease-based, DEC-LEASE-002) finds no active
# lease for the worktree. No-lease + high_risk → deny with "No active lease".
# ---------------------------------------------------------------------------
run_sub_case_c() {
    local branch="feature/check3-push-implementer"
    _setup_repo "$branch" "implementer"
    trap 'rm -rf "$TMP_DIR"' RETURN

    local cmd output decision reason
    cmd="git -C \"$TMP_DIR\" push origin $branch"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")
    reason=$(_reason "$output")

    if [[ "$decision" != "deny" ]]; then
        fail "C" "expected deny for push by implementer (no lease), got decision='$decision'"
        return
    fi
    if ! printf '%s' "$reason" | grep -qiE "lease|No active"; then
        fail "C" "deny reason should mention 'lease' or 'No active', got: $reason"
        return
    fi
    pass "C" "push by implementer denied by Check 3 (no lease for high-risk op)"
}

# ---------------------------------------------------------------------------
# Sub-case D: Push by guardian role, lease issued and ready_for_guardian → allowed
#
# Push remains high_risk for lease/capability matching, but is no longer
# approval-token gated. With a guardian lease and ready_for_guardian, the hook
# must allow the push through.
# ---------------------------------------------------------------------------
run_sub_case_d() {
    local branch="feature/check3-push-guardian-no-token"
    _setup_repo "$branch" "guardian"
    trap 'rm -rf "$TMP_DIR"' RETURN
    _seed_guardian_land_phase "$TEST_DB" "$WF_ID"

    # Set ready_for_guardian so Check 10 doesn't fire first
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$CURRENT_HEAD" >/dev/null 2>&1

    # Issue a guardian lease with high_risk so Check 3 and Check 10 can pass.
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        lease issue-for-dispatch "guardian" \
        --workflow-id "$WF_ID" \
        --worktree-path "$TMP_DIR" \
        --branch "$branch" \
        --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1

    local cmd output decision reason
    cmd="git -C \"$TMP_DIR\" push origin $branch"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")
    reason=$(_reason "$output")

    if [[ -z "$output" || "$decision" != "deny" ]]; then
        pass "D" "push by guardian:land with high_risk lease + ready_for_guardian allowed"
    else
        fail "D" "unexpected deny for guardian push: $reason"
    fi
}

# ---------------------------------------------------------------------------
# Sub-case E: Merge by guardian:land + active guardian lease + ready_for_guardian → allowed
#
# Plain merge (no --no-ff) is routine_local, but landing authority still belongs
# to guardian:land. This uses separate main+feature branch setup to mirror a
# real merge scenario.
# ---------------------------------------------------------------------------
run_sub_case_e() {
    local base_branch="feature/check3-merge-implementer"
    WF_ID=$(printf '%s' "$base_branch" | tr '/: ' '---' | tr -cd '[:alnum:]._-')
    TMP_DIR="$REPO_ROOT/tmp/${TEST_NAME}-${WF_ID}-$$"
    TEST_DB="$TMP_DIR/.claude/state.db"

    trap 'rm -rf "$TMP_DIR"' RETURN

    mkdir -p "$TMP_DIR/.claude"
    git -C "$TMP_DIR" init -q
    git -C "$TMP_DIR" config user.email "t@t.com"
    git -C "$TMP_DIR" config user.name "T"

    # Initial commit on default branch (main)
    git -C "$TMP_DIR" commit --allow-empty -m "init" -q

    # Create feature branch with a commit
    git -C "$TMP_DIR" checkout -b "$base_branch" -q
    git -C "$TMP_DIR" commit --allow-empty -m "feature work" -q
    local FEATURE_SHA
    FEATURE_SHA=$(git -C "$TMP_DIR" rev-parse HEAD)

    # Return to main for the merge
    git -C "$TMP_DIR" checkout main -q 2>/dev/null || git -C "$TMP_DIR" checkout -b main -q

    # Schema + guardian landing role
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        marker set "agent-test" "guardian" --project-root "$TMP_DIR" >/dev/null 2>&1

    # Test status = pass (SQLite authority — Check 8 reads via rt_test_state_get, not flat file)
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        test-state set "pass" --project-root "$TMP_DIR" >/dev/null 2>&1

    # Evaluation_state: feature branch workflow cleared with feature SHA
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$FEATURE_SHA" >/dev/null 2>&1

    # Check 10 binding: feature branch workflow
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$WF_ID" "$TMP_DIR" "$base_branch" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1
    _seed_guardian_land_phase "$TEST_DB" "$WF_ID"

    # Issue guardian lease (landing seat).
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        lease issue-for-dispatch "guardian" \
        --workflow-id "$WF_ID" \
        --worktree-path "$TMP_DIR" \
        --branch "$base_branch" \
        --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1

    local cmd output decision
    cmd="git -C \"$TMP_DIR\" merge $base_branch"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")

    if [[ -z "$output" || "$decision" != "deny" ]]; then
        pass "E" "plain merge by guardian:land with lease + ready_for_guardian allowed"
    else
        fail "E" "unexpected deny: $(_reason "$output")"
    fi
}

# ---------------------------------------------------------------------------
# Sub-case F: Merge --no-ff by implementer role, no lease → denied by Check 3
#
# merge --no-ff is classified as high_risk. Check 3 (lease-based, DEC-LEASE-002)
# finds no active lease for the worktree. No-lease + high_risk → deny with
# "No active lease". The old "Guardian" role check is gone.
# ---------------------------------------------------------------------------
run_sub_case_f() {
    local branch="feature/check3-merge-no-ff"
    _setup_repo "$branch" "implementer"
    trap 'rm -rf "$TMP_DIR"' RETURN

    local cmd output decision reason
    cmd="git -C \"$TMP_DIR\" merge --no-ff feature/test"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")
    reason=$(_reason "$output")

    if [[ "$decision" != "deny" ]]; then
        fail "F" "expected deny for merge --no-ff (no lease), got decision='$decision'"
        return
    fi
    if ! printf '%s' "$reason" | grep -qiE "lease|No active"; then
        fail "F" "deny reason should mention 'lease' or 'No active', got: $reason"
        return
    fi
    pass "F" "merge --no-ff denied by Check 3 (no lease for high-risk op)"
}

# ---------------------------------------------------------------------------
# Run all sub-cases
# ---------------------------------------------------------------------------
echo "=== $TEST_NAME: starting ==="

run_sub_case_a
run_sub_case_b
run_sub_case_c
run_sub_case_d
run_sub_case_e
run_sub_case_f

echo ""
echo "=== $TEST_NAME: $PASS_COUNT passed, $FAIL_COUNT failed ==="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
