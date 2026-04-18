#!/usr/bin/env bash
# test-guardian-auto-land-e2e.sh — End-to-end proof of the auto-land
# governance policy implemented in the CONTROL PLANE (guard.sh, approvals table,
# classify_git_op, cc-policy approval CLI).
#
# Sub-cases:
#   A: Routine commit with ready_for_guardian -> allowed (Check 10, no approval token needed)
#   B: straightforward git push WITHOUT approval token -> allowed
#   C: straightforward git push does NOT consume unrelated approval tokens
#   D: git rebase WITHOUT approval token -> denied by Check 13
#   E: Classifier correctness (commit->routine_local, push->high_risk, etc.)
#   F: Destructive ops hard-denied by Checks 5-6 (reset --hard, push --force)
#
# @decision DEC-GUARD-013
# @title E2E proof: Guardian push auto-land, approval-gated recovery ops, and classifier in guard.sh
# @status accepted
# @rationale This test is the compound-interaction proof required by the
#   Evaluation Contract. It exercises the real production sequence across
#   schemas.py (APPROVALS_DDL), runtime/core/approvals.py (grant/consume),
#   runtime/cli.py (cc-policy approval grant/check/list), hooks/context-lib.sh
#   (classify_git_op), and pre-bash policy evaluation. Sub-case F confirms the
#   destructive-op denies still fire before any approval-token path, so no token
#   can override destructive-op denial.
set -euo pipefail

TEST_NAME="test-guardian-auto-land-e2e"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-bash.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"
CONTEXT_LIB="$REPO_ROOT/hooks/context-lib.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $TEST_NAME [$1] — $2"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $TEST_NAME [$1] — $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# ---------------------------------------------------------------------------
# Helper: build a clean temp git repo with all required guard.sh gates satisfied
# (guardian role, test-status=pass, evaluation_state=ready_for_guardian with
# matching HEAD SHA, workflow binding, scope set).
# Sets: TMP_DIR, TEST_DB, WF_ID, CURRENT_HEAD
# ---------------------------------------------------------------------------
_setup_passing_repo() {
    local branch="$1"
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

    # Schema + guardian role
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        marker set "agent-test" "guardian" --project-root "$TMP_DIR" >/dev/null 2>&1

    # Test status
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        test-state set pass --project-root "$TMP_DIR" --passed 1 --total 1 >/dev/null 2>&1

    # Evaluation state
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$CURRENT_HEAD" >/dev/null 2>&1

    # Workflow binding + scope
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$WF_ID" "$TMP_DIR" "$branch" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1
    python3 - "$TEST_DB" "$WF_ID" <<'PY' >/dev/null 2>&1
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

    # Dispatch lease: push remains high_risk for lease/capability matching even
    # though it is no longer approval-token gated. Rebase still relies on the
    # approval gate, so the lease must allow both routine_local and high_risk.
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        lease issue-for-dispatch "guardian" --workflow-id "$WF_ID" \
        --worktree-path "$TMP_DIR" --branch "$branch" \
        --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1
}

_teardown() {
    [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"
    TMP_DIR=""
}

# Run guard.sh with a command, return the output
_run_guard() {
    local cmd="$1"
    local project_dir="${2:-$TMP_DIR}"
    local db="${3:-$TEST_DB}"
    local payload
    payload=$(jq -n --arg t "Bash" --arg c "$cmd" --arg w "$project_dir" \
        '{tool_name:$t,tool_input:{command:$c},cwd:$w}')
    printf '%s' "$payload" \
        | CLAUDE_PROJECT_DIR="$project_dir" \
          CLAUDE_POLICY_DB="$db" \
          CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" \
          "$HOOK" 2>/dev/null || true
}

# Extract permissionDecision from guard.sh output
_decision() {
    printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true
}

# Extract permissionDecisionReason from guard.sh output
_reason() {
    printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true
}

# ─── Sub-case A: Routine commit with ready_for_guardian → allowed ─────────────
# Production sequence: guardian role + test-status=pass + evaluation_state=ready_for_guardian
# + binding + scope + no high-risk op → Check 10 passes, Check 13 sees routine_local, exits 0.
run_sub_case_a() {
    local branch="feature/e2e-commit-allow"
    _setup_passing_repo "$branch"
    trap '_teardown' RETURN

    local cmd="git -C \"$TMP_DIR\" commit --allow-empty -m 'auto-land test'"
    local output
    output=$(_run_guard "$cmd")
    local decision
    decision=$(_decision "$output")

    if [[ -z "$output" || "$decision" != "deny" ]]; then
        pass "A" "routine commit with ready_for_guardian allowed (no deny)"
    else
        fail "A" "routine commit was denied: $(_reason "$output")"
    fi
}

# ─── Sub-case B: git push WITHOUT approval token → allowed ────────────────────
# Production sequence: all gates pass, push is part of Guardian landing, and
# no approval token should be consulted.
run_sub_case_b() {
    local branch="feature/e2e-push-no-token"
    _setup_passing_repo "$branch"
    trap '_teardown' RETURN

    local cmd="git -C \"$TMP_DIR\" push origin $branch"
    local output
    output=$(_run_guard "$cmd")
    local decision
    decision=$(_decision "$output")

    if [[ -z "$output" || "$decision" != "deny" ]]; then
        pass "B" "straightforward push without approval token allowed"
    else
        fail "B" "push without approval token was denied: $(_reason "$output")"
    fi
}

# ─── Sub-case C: git push leaves unrelated approval token untouched ───────────
# Production sequence: grant a rebase approval token, run a straightforward
# push, verify the push is allowed, then verify the unrelated token was NOT
# consumed (push no longer consults approval tokens).
run_sub_case_c() {
    local branch="feature/e2e-push-with-token"
    _setup_passing_repo "$branch"
    trap '_teardown' RETURN

    # Grant an unrelated approval token
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        approval grant "$WF_ID" "rebase" >/dev/null 2>&1

    # Verify it's pending before guard runs
    local pending_before
    pending_before=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        approval list --workflow-id "$WF_ID" 2>/dev/null | jq -r '.count' 2>/dev/null || echo "0")
    if [[ "$pending_before" != "1" ]]; then
        fail "C" "expected 1 pending approval before guard run, got $pending_before"
        return
    fi

    local cmd="git -C \"$TMP_DIR\" push origin $branch"
    local output
    output=$(_run_guard "$cmd")
    local decision
    decision=$(_decision "$output")

    if [[ -z "$output" || "$decision" != "deny" ]]; then
        # Verify token was NOT consumed
        local pending_after
        pending_after=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            approval list --workflow-id "$WF_ID" 2>/dev/null | jq -r '.count' 2>/dev/null || echo "0")
        if [[ "$pending_after" == "1" ]]; then
            pass "C" "push allowed and unrelated approval token left untouched"
        else
            fail "C" "push allowed but unrelated approval token changed (pending_after=$pending_after)"
        fi
    else
        fail "C" "push with unrelated approval token was denied: $(_reason "$output")"
    fi
}

# ─── Sub-case D: git rebase WITHOUT approval token → denied by Check 13 ───────
run_sub_case_d() {
    local branch="feature/e2e-rebase-no-token"
    _setup_passing_repo "$branch"
    trap '_teardown' RETURN

    local cmd="git -C \"$TMP_DIR\" rebase main"
    local output
    output=$(_run_guard "$cmd")
    local decision
    decision=$(_decision "$output")

    if [[ "$decision" == "deny" ]]; then
        local reason
        reason=$(_reason "$output")
        if printf '%s' "$reason" | grep -qi "approval"; then
            pass "D" "rebase without token denied with approval message"
        else
            fail "D" "rebase denied but reason missing 'approval': $reason"
        fi
    else
        fail "D" "rebase without approval token was NOT denied (decision=$decision)"
    fi
}

# ─── Sub-case E: Classifier correctness ───────────────────────────────────────
# Source context-lib.sh and call classify_git_op directly.
# commit -> routine_local
# merge (no --no-ff) -> routine_local
# push -> high_risk
# rebase -> high_risk
# reset -> high_risk
# merge --no-ff -> high_risk
# git log -> unclassified
run_sub_case_e() {
    # shellcheck source=/dev/null
    source "$CONTEXT_LIB" 2>/dev/null || {
        fail "E" "could not source context-lib.sh"
        return
    }

    local e_failures=0

    _check_classify() {
        local cmd="$1" expected="$2"
        local got
        got=$(classify_git_op "$cmd")
        if [[ "$got" == "$expected" ]]; then
            pass "E:classify($cmd)" "-> $got"
        else
            fail "E:classify($cmd)" "expected $expected, got $got"
            e_failures=$((e_failures + 1))
        fi
    }

    _check_classify "git commit -m 'msg'"           "routine_local"
    _check_classify "git -C /foo commit -m 'msg'"   "routine_local"
    _check_classify "git merge feature/foo"          "routine_local"
    _check_classify "git push origin main"           "high_risk"
    _check_classify "git -C /foo push origin HEAD"   "high_risk"
    _check_classify "git rebase main"                "high_risk"
    _check_classify "git rebase -i HEAD~3"           "high_risk"
    _check_classify "git reset HEAD~1"               "high_risk"
    _check_classify "git reset --soft HEAD~1"        "high_risk"
    _check_classify "git merge --no-ff feature/foo"  "high_risk"
    _check_classify "git log --oneline"              "unclassified"
    _check_classify "git status"                     "unclassified"
    _check_classify "git diff main...HEAD"           "unclassified"

    if [[ "$e_failures" -gt 0 ]]; then
        fail "E" "$e_failures classifier assertion(s) failed"
    fi
}

# ─── Sub-case F: Destructive ops hard-denied by Checks 5-6 ────────────────────
# Even with a guardian role + all passing gates + matching approval tokens, these ops
# must be denied by Checks 5-6 (which fire before Check 13).
_run_destructive_deny_check() {
    local subcaseid="$1"
    local git_args="$2"
    local pattern="$3"
    local subname="feature/e2e-destructive-${subcaseid}"

    _setup_passing_repo "$subname"

    # Grant approval tokens — must NOT override the hard deny from Checks 5-6
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        approval grant "$WF_ID" "destructive_cleanup" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        approval grant "$WF_ID" "reset" >/dev/null 2>&1

    local out dec reason subcmd
    subcmd="git -C \"$TMP_DIR\" $git_args"
    out=$(_run_guard "$subcmd")
    dec=$(_decision "$out")

    if [[ "$dec" == "deny" ]]; then
        reason=$(_reason "$out")
        if printf '%s' "$reason" | grep -qi "$pattern"; then
            pass "F:$subcaseid" "correctly hard-denied (reason matches '$pattern')"
        else
            fail "F:$subcaseid" "denied but reason missing '$pattern': $reason"
        fi
    else
        fail "F:$subcaseid" "destructive op NOT denied (decision=$dec)"
    fi

    _teardown
}

run_sub_case_f() {
    _run_destructive_deny_check "reset-hard"  "reset --hard HEAD~1"              "destructive"
    _run_destructive_deny_check "clean-f"     "clean -f"                         "permanently deletes"
    _run_destructive_deny_check "branch-D"    "branch -D some-branch"            "force-deletes"
    # push-force must also use the real TMP_DIR so Check 3 finds the lease and
    # passes through to Check 5's force-push safety check.
    local pf_branch="feature/e2e-destructive-push-force"
    _setup_passing_repo "$pf_branch"
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        approval grant "$WF_ID" "force_push" >/dev/null 2>&1
    local pf_cmd="git -C \"$TMP_DIR\" push origin $pf_branch --force"
    local pf_out pf_dec pf_reason
    pf_out=$(_run_guard "$pf_cmd")
    pf_dec=$(_decision "$pf_out")
    if [[ "$pf_dec" == "deny" ]]; then
        pf_reason=$(_reason "$pf_out")
        if printf '%s' "$pf_reason" | grep -qi "force-with-lease"; then
            pass "F:push-force" "correctly hard-denied (reason matches 'force-with-lease')"
        else
            fail "F:push-force" "denied but reason missing 'force-with-lease': $pf_reason"
        fi
    else
        fail "F:push-force" "destructive op NOT denied (decision=$pf_dec)"
    fi
    _teardown
}

# ─── Run all sub-cases ─────────────────────────────────────────────────────────
echo "=== $TEST_NAME: starting E2E proof ==="

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
