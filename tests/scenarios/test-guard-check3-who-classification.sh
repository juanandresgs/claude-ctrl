#!/usr/bin/env bash
# test-guard-check3-who-classification.sh — Proves Check 3 uses the classifier
# to skip WHO enforcement for routine_local ops and still enforce for high-risk.
#
# The marker race fix: before this change, Check 3 blanket-denied ALL git
# commit/merge/push unless the active marker was "guardian". This forced
# concurrent agents to coordinate marker state before any commit — creating a
# race. The fix: commit/merge are routine_local (gated by Check 10), push is
# high_risk (gated by Check 3 + Check 13). Non-guardian roles can commit/merge
# once the evaluator clears the workflow.
#
# Sub-cases:
#   A: Routine commit by implementer role + ready_for_guardian → allowed
#   B: Routine commit by implementer role WITHOUT ready_for_guardian → denied by Check 10
#   C: Push by implementer role → denied by Check 3
#   D: Push by guardian role, no approval token → reaches Check 13 (denied with "approval")
#   E: Merge by implementer role + ready_for_guardian → allowed
#   F: Merge --no-ff by implementer role → denied by Check 3 (high_risk)
#
# @decision DEC-GUARD-003
# @title WHO enforcement uses classifier — routine local ops skip role check
# @status accepted
# @rationale evaluation_state=ready_for_guardian is sufficient authority for
#   routine local landing (DEC-APPROVAL-001). Requiring Guardian role for
#   commit/merge creates a marker race where concurrent sessions overwrite
#   the active marker, blocking legitimate auto-land. The classifier
#   (DEC-CLASSIFY-001) separates routine from high-risk. Check 10 gates
#   routine ops on evaluation_state. Check 13 gates high-risk ops on
#   approval tokens. WHO enforcement only adds value for push (remote ops).
set -euo pipefail

TEST_NAME="test-guard-check3-who-classification"
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
        marker set "agent-test" "$role" >/dev/null 2>&1

    # Test status = pass
    echo "pass|0|$(date +%s)" > "$TMP_DIR/.claude/.test-status"

    # Workflow binding + scope
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$WF_ID" "$TMP_DIR" "$branch" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Sub-case A: Routine commit by implementer role + ready_for_guardian → allowed
#
# Production sequence: implementer finishes work, evaluator clears the workflow,
# implementer runs git commit. Check 3 classifies "commit" as routine_local and
# skips WHO enforcement. Check 10 sees ready_for_guardian + matching SHA →
# passes. Commit proceeds without requiring guardian marker.
# ---------------------------------------------------------------------------
run_sub_case_a() {
    local branch="feature/check3-commit-implementer"
    _setup_repo "$branch" "implementer"
    trap 'rm -rf "$TMP_DIR"' RETURN

    # Set evaluation_state=ready_for_guardian with matching HEAD SHA
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$CURRENT_HEAD" >/dev/null 2>&1

    local cmd output decision
    cmd="git -C \"$TMP_DIR\" commit --allow-empty -m 'implementer commit'"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")

    if [[ -z "$output" || "$decision" != "deny" ]]; then
        pass "A" "routine commit by implementer with ready_for_guardian allowed"
    else
        fail "A" "unexpected deny: $(_reason "$output")"
    fi
}

# ---------------------------------------------------------------------------
# Sub-case B: Routine commit by implementer WITHOUT ready_for_guardian → denied by Check 10
#
# Check 3 skips WHO enforcement (routine_local). Check 10 fires because
# evaluation_state=needs_changes. Deny reason must mention "evaluation_state".
# ---------------------------------------------------------------------------
run_sub_case_b() {
    local branch="feature/check3-commit-needs-changes"
    _setup_repo "$branch" "implementer"
    trap 'rm -rf "$TMP_DIR"' RETURN

    # Explicitly set needs_changes — no ready_for_guardian
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$WF_ID" "needs_changes" >/dev/null 2>&1

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
    # Must NOT say "Guardian agent" — that would mean Check 3 fired instead of 10
    if printf '%s' "$reason" | grep -qi "Guardian agent"; then
        fail "B" "deny reason mentions 'Guardian agent' — Check 3 fired instead of Check 10: $reason"
        return
    fi
    pass "B" "commit without ready_for_guardian denied by Check 10 (not Check 3)"
}

# ---------------------------------------------------------------------------
# Sub-case C: Push by implementer role → denied by Check 3
#
# Push is high_risk. Check 3 sees high_risk and enforces Guardian role.
# Deny reason must mention "Guardian" and "push".
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
        fail "C" "expected deny for push by implementer, got decision='$decision'"
        return
    fi
    if ! printf '%s' "$reason" | grep -qi "Guardian"; then
        fail "C" "deny reason should mention 'Guardian', got: $reason"
        return
    fi
    if ! printf '%s' "$reason" | grep -qi "push"; then
        fail "C" "deny reason should mention 'push', got: $reason"
        return
    fi
    pass "C" "push by implementer denied by Check 3 with Guardian+push message"
}

# ---------------------------------------------------------------------------
# Sub-case D: Push by guardian role, no approval token → reaches Check 13
#
# Check 3 passes (guardian role + high_risk is allowed). Check 13 fires because
# no approval token exists. Deny reason must mention "approval" — NOT "Guardian
# agent may run" (which would mean Check 3 fired, not Check 13).
# ---------------------------------------------------------------------------
run_sub_case_d() {
    local branch="feature/check3-push-guardian-no-token"
    _setup_repo "$branch" "guardian"
    trap 'rm -rf "$TMP_DIR"' RETURN

    # Set ready_for_guardian so Check 10 doesn't fire first
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$CURRENT_HEAD" >/dev/null 2>&1

    local cmd output decision reason
    cmd="git -C \"$TMP_DIR\" push origin $branch"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")
    reason=$(_reason "$output")

    if [[ "$decision" != "deny" ]]; then
        fail "D" "expected deny for push without approval token, got decision='$decision'"
        return
    fi
    if ! printf '%s' "$reason" | grep -qi "approval"; then
        fail "D" "deny reason should mention 'approval' (Check 13), got: $reason"
        return
    fi
    # Confirm it's Check 13 that fired, not Check 3
    if printf '%s' "$reason" | grep -qi "Only the Guardian agent may run"; then
        fail "D" "deny mentions 'Only the Guardian agent may run' — Check 3 fired instead of Check 13: $reason"
        return
    fi
    pass "D" "push by guardian without token denied by Check 13 (not Check 3)"
}

# ---------------------------------------------------------------------------
# Sub-case E: Merge by implementer role + ready_for_guardian → allowed
#
# Plain merge (no --no-ff) is routine_local. Check 3 skips WHO enforcement.
# Check 10 passes with ready_for_guardian + matching merge-ref SHA.
# Uses separate main+feature branch setup to mirror a real merge scenario.
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

    # Schema + implementer role
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        marker set "agent-test" "implementer" >/dev/null 2>&1

    # Test status = pass
    echo "pass|0|$(date +%s)" > "$TMP_DIR/.claude/.test-status"

    # Evaluation_state: feature branch workflow cleared with feature SHA
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$FEATURE_SHA" >/dev/null 2>&1

    # Check 10 binding: feature branch workflow
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$WF_ID" "$TMP_DIR" "$base_branch" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1

    # Check 12 binding: "main" workflow (current branch when merge runs)
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "main" "$TMP_DIR" "main" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "main" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1

    local cmd output decision
    cmd="git -C \"$TMP_DIR\" merge $base_branch"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")

    if [[ -z "$output" || "$decision" != "deny" ]]; then
        pass "E" "plain merge by implementer with ready_for_guardian allowed"
    else
        fail "E" "unexpected deny: $(_reason "$output")"
    fi
}

# ---------------------------------------------------------------------------
# Sub-case F: Merge --no-ff by implementer role → denied by Check 3 (high_risk)
#
# merge --no-ff is classified as high_risk. Check 3 enforces Guardian role.
# Deny reason must mention "Guardian".
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
        fail "F" "expected deny for merge --no-ff by implementer, got decision='$decision'"
        return
    fi
    if ! printf '%s' "$reason" | grep -qi "Guardian"; then
        fail "F" "deny reason should mention 'Guardian', got: $reason"
        return
    fi
    pass "F" "merge --no-ff by implementer denied by Check 3 (high_risk)"
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
