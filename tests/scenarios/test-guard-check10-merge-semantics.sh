#!/usr/bin/env bash
# test-guard-check10-merge-semantics.sh: proves guard.sh Check 10 uses the
# correct SHA reference for merge vs. commit operations.
#
# Problem fixed: Check 10 previously always compared head_sha against
# main's HEAD (git rev-parse HEAD in _EVAL_DIR). For a merge, main's HEAD
# is NOT what the evaluator cleared — the feature branch tip is. This caused
# spurious denials on every valid merge.
#
# Fix: when the command is a git merge and _MERGE_REF is set, resolve
# _COMPARE_HEAD from the merge-ref tip, not from HEAD.
#
# Sub-cases:
#   A: Merge with correct SHA — allowed
#   B: Merge with stale SHA  — denied (stale clearance)
#   C: Commit with correct SHA — allowed (regression: commit path unchanged)
#   D: Commit with stale SHA  — denied (regression: commit path unchanged)
#   E: Updated deny text — says "local landing" not "Guardian can commit or merge"
#
# Pattern follows test-guard-evaluator-gate-allows.sh exactly — same env
# vars, same runtime CLI calls, same payload format.
#
# @decision DEC-EVAL-004
# @title guard.sh Check 10 merge SHA comparison uses merge-ref tip, not main HEAD
# @status accepted
# @rationale The evaluator clears a feature branch, storing that branch's tip
#   SHA. On merge, main's HEAD is a different commit. Comparing stored SHA
#   against main HEAD produces a permanent false deny. The fix resolves the
#   SHA of the branch being merged (_MERGE_REF) and compares against that.
#   This test proves all four permutations (merge/commit × correct/stale) and
#   the updated deny-text wording.
set -euo pipefail

TEST_NAME="test-guard-check10-merge-semantics"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-bash.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

run_hook() {
    local payload="$1" project_dir="$2" db="$3"
    printf '%s' "$payload" \
        | CLAUDE_PROJECT_DIR="$project_dir" CLAUDE_POLICY_DB="$db" \
          CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" "$HOOK" 2>/dev/null || true
}

assert_allowed() {
    local sub_case="$1" output="$2"
    if [[ -n "$output" ]]; then
        local decision
        decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")
        if [[ "$decision" == "deny" ]]; then
            local reason
            reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || echo "")
            echo "FAIL: $TEST_NAME [$sub_case] — unexpected deny: $reason"
            exit 1
        fi
    fi
    echo "PASS: $TEST_NAME [$sub_case]"
}

assert_denied() {
    local sub_case="$1" output="$2" reason_pattern="${3:-}"
    local decision reason
    decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")
    reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || echo "")
    if [[ "$decision" != "deny" ]]; then
        echo "FAIL: $TEST_NAME [$sub_case] — expected deny, got '$decision'"
        echo "  output: $output"
        exit 1
    fi
    if [[ -n "$reason_pattern" ]] && ! printf '%s' "$reason" | grep -qi "$reason_pattern"; then
        echo "FAIL: $TEST_NAME [$sub_case] — deny reason does not match pattern '$reason_pattern'"
        echo "  reason: $reason"
        exit 1
    fi
    echo "PASS: $TEST_NAME [$sub_case]"
}

# ---------------------------------------------------------------------------
# Setup: create a scratch repo with main + feature branch
# ---------------------------------------------------------------------------
# Each sub-case gets a fresh TMP_DIR to avoid state bleed.

run_sub_case() {
    local sub_case="$1"
    local TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-${sub_case}-$$"
    local TEST_DB="$TMP_DIR/.claude/state.db"
    local BRANCH="feature/check10-test-${sub_case}"
    local WF_ID
    WF_ID=$(printf '%s' "$BRANCH" | tr '/: ' '---' | tr -cd '[:alnum:]._-')

    trap 'rm -rf "$TMP_DIR"' EXIT

    mkdir -p "$TMP_DIR/.claude"
    git -C "$TMP_DIR" init -q
    git -C "$TMP_DIR" config user.email "t@t.com"
    git -C "$TMP_DIR" config user.name "T"

    # Initial commit on main
    git -C "$TMP_DIR" commit --allow-empty -m "init" -q

    # Create feature branch with one commit
    git -C "$TMP_DIR" checkout -b "$BRANCH" -q
    git -C "$TMP_DIR" commit --allow-empty -m "feature work" -q
    FEATURE_SHA=$(git -C "$TMP_DIR" rev-parse HEAD)

    # Return to main for merge sub-cases
    git -C "$TMP_DIR" checkout main -q 2>/dev/null || git -C "$TMP_DIR" checkout -b main -q

    # Schema + guardian:land marker (Check 3)
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian:land" --project-root "$TMP_DIR" >/dev/null 2>&1

    # test-state = pass via runtime (policy engine reads SQLite)
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        test-state set pass --project-root "$TMP_DIR" --passed 1 --total 1 >/dev/null 2>&1

    # Lease (TKT-STAB-A3): Check 3 requires an active lease for all git ops.
    # --no-eval disables the lease's own eval check so Check 10 (not validate_op
    # inside Check 3) is the sole evaluation gating authority in all sub-cases.
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        lease issue-for-dispatch "guardian" \
        --workflow-id "$WF_ID" \
        --worktree-path "$TMP_DIR" \
        --branch "$BRANCH" \
        --allowed-ops '["routine_local","high_risk"]' \
        --no-eval >/dev/null 2>&1

    case "$sub_case" in
    # -----------------------------------------------------------------------
    # Sub-case A: Merge with correct SHA — must be allowed
    # Stored SHA = feature branch tip. Merge ref resolves to same SHA.
    #
    # Check 10 uses WF_ID (feature branch). Check 12 now follows the active
    # workflow binding for the worktree; binding a second "main" workflow to
    # the same worktree would deliberately replace the feature binding.
    # -----------------------------------------------------------------------
    A)
        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$FEATURE_SHA" >/dev/null 2>&1

        # Test state: pass (policy engine reads from runtime SQLite)
        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            test-state set pass --project-root "$TMP_DIR" --passed 1 --total 1 >/dev/null 2>&1

        # Dispatch lease: required for all git ops
        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            lease issue-for-dispatch "guardian" \
            --worktree-path "$TMP_DIR" \
            --workflow-id "$WF_ID" \
            --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1

        # Check 10 binding: feature branch workflow
        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            workflow bind "$WF_ID" "$TMP_DIR" "$BRANCH" >/dev/null 2>&1
        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1

        # Plain merge (no --no-ff) is routine_local — does not trigger Check 13
        CMD="git -C \"$TMP_DIR\" merge $BRANCH"
        PAYLOAD=$(jq -n --arg t "Bash" --arg c "$CMD" --arg w "$TMP_DIR" \
            '{tool_name:$t,tool_input:{command:$c},cwd:$w}')
        output=$(run_hook "$PAYLOAD" "$TMP_DIR" "$TEST_DB")
        assert_allowed "A: merge correct SHA" "$output"
        ;;

    # -----------------------------------------------------------------------
    # Sub-case B: Merge with stale SHA — must be denied
    # Stored SHA = old feature tip. After an extra commit, SHA is stale.
    # Both workflow bindings are set so Check 12 passes; only Check 10
    # should fire (stale SHA on the merge ref).
    # -----------------------------------------------------------------------
    B)
        # Store the SHA of the current feature tip
        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$FEATURE_SHA" >/dev/null 2>&1

        # Test state: pass (required to reach eval readiness check)
        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            test-state set pass --project-root "$TMP_DIR" --passed 1 --total 1 >/dev/null 2>&1

        # Dispatch lease: required for all git ops
        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            lease issue-for-dispatch "guardian" \
            --worktree-path "$TMP_DIR" \
            --workflow-id "$WF_ID" \
            --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1

        # Add another commit to the feature branch (makes stored SHA stale)
        git -C "$TMP_DIR" checkout "$BRANCH" -q
        git -C "$TMP_DIR" commit --allow-empty -m "extra commit after eval" -q
        # Back to main
        git -C "$TMP_DIR" checkout main -q 2>/dev/null || git -C "$TMP_DIR" checkout -b main -q

        # Feature branch binding (Check 10)
        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            workflow bind "$WF_ID" "$TMP_DIR" "$BRANCH" >/dev/null 2>&1
        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1

        # Plain merge (no --no-ff) is routine_local — Check 13 does not fire
        CMD="git -C \"$TMP_DIR\" merge $BRANCH"
        PAYLOAD=$(jq -n --arg t "Bash" --arg c "$CMD" --arg w "$TMP_DIR" \
            '{tool_name:$t,tool_input:{command:$c},cwd:$w}')
        output=$(run_hook "$PAYLOAD" "$TMP_DIR" "$TEST_DB")
        assert_denied "B: merge stale SHA" "$output" "head_sha"
        ;;

    # -----------------------------------------------------------------------
    # Sub-case C: Commit with correct SHA — allowed (regression)
    # Stored SHA = worktree HEAD. Commit path compares against HEAD as before.
    # -----------------------------------------------------------------------
    C)
        # For commit, stay on the feature branch (not main)
        git -C "$TMP_DIR" checkout "$BRANCH" -q
        CURRENT_HEAD=$(git -C "$TMP_DIR" rev-parse HEAD)

        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$CURRENT_HEAD" >/dev/null 2>&1
        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            test-state set pass --project-root "$TMP_DIR" --passed 1 --total 1 >/dev/null 2>&1
        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            lease issue-for-dispatch "guardian" \
            --worktree-path "$TMP_DIR" --workflow-id "$WF_ID" \
            --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1

        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            workflow bind "$WF_ID" "$TMP_DIR" "$BRANCH" >/dev/null 2>&1
        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1

        CMD="git -C \"$TMP_DIR\" commit --allow-empty -m 'test commit'"
        PAYLOAD=$(jq -n --arg t "Bash" --arg c "$CMD" --arg w "$TMP_DIR" \
            '{tool_name:$t,tool_input:{command:$c},cwd:$w}')
        output=$(run_hook "$PAYLOAD" "$TMP_DIR" "$TEST_DB")
        assert_allowed "C: commit correct SHA (regression)" "$output"
        ;;

    # -----------------------------------------------------------------------
    # Sub-case D: Commit with stale SHA — denied (regression)
    # Stored SHA = old HEAD. A new commit makes it stale before guard runs.
    # -----------------------------------------------------------------------
    D)
        git -C "$TMP_DIR" checkout "$BRANCH" -q
        OLD_HEAD=$(git -C "$TMP_DIR" rev-parse HEAD)

        # Store the old SHA
        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$OLD_HEAD" >/dev/null 2>&1
        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            test-state set pass --project-root "$TMP_DIR" --passed 1 --total 1 >/dev/null 2>&1
        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            lease issue-for-dispatch "guardian" \
            --worktree-path "$TMP_DIR" --workflow-id "$WF_ID" \
            --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1

        # Make a new commit so HEAD advances past the stored SHA
        git -C "$TMP_DIR" commit --allow-empty -m "new commit after eval" -q

        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            workflow bind "$WF_ID" "$TMP_DIR" "$BRANCH" >/dev/null 2>&1
        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1

        CMD="git -C \"$TMP_DIR\" commit --allow-empty -m 'another commit'"
        PAYLOAD=$(jq -n --arg t "Bash" --arg c "$CMD" --arg w "$TMP_DIR" \
            '{tool_name:$t,tool_input:{command:$c},cwd:$w}')
        output=$(run_hook "$PAYLOAD" "$TMP_DIR" "$TEST_DB")
        assert_denied "D: commit stale SHA (regression)" "$output" "head_sha"
        ;;

    # -----------------------------------------------------------------------
    # Sub-case E: Updated deny text — "local landing" not "Guardian can commit"
    # Set evaluation_state = needs_changes; verify deny text wording changed.
    # -----------------------------------------------------------------------
    E)
        git -C "$TMP_DIR" checkout "$BRANCH" -q

        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            evaluation set "$WF_ID" "needs_changes" >/dev/null 2>&1
        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            test-state set pass --project-root "$TMP_DIR" --passed 1 --total 1 >/dev/null 2>&1
        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            lease issue-for-dispatch "guardian" \
            --worktree-path "$TMP_DIR" --workflow-id "$WF_ID" \
            --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1

        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            workflow bind "$WF_ID" "$TMP_DIR" "$BRANCH" >/dev/null 2>&1
        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
            workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1

        CMD="git -C \"$TMP_DIR\" commit --allow-empty -m 'test'"
        PAYLOAD=$(jq -n --arg t "Bash" --arg c "$CMD" --arg w "$TMP_DIR" \
            '{tool_name:$t,tool_input:{command:$c},cwd:$w}')
        output=$(run_hook "$PAYLOAD" "$TMP_DIR" "$TEST_DB")

        reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || echo "")
        decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")

        if [[ "$decision" != "deny" ]]; then
            echo "FAIL: $TEST_NAME [E] — expected deny for needs_changes, got '$decision'"
            exit 1
        fi
        if ! printf '%s' "$reason" | grep -qi "local landing"; then
            echo "FAIL: $TEST_NAME [E] — deny reason should say 'local landing'"
            echo "  reason: $reason"
            exit 1
        fi
        if printf '%s' "$reason" | grep -qi "Guardian can commit or merge"; then
            echo "FAIL: $TEST_NAME [E] — deny reason still uses old wording 'Guardian can commit or merge'"
            echo "  reason: $reason"
            exit 1
        fi
        echo "PASS: $TEST_NAME [E: updated deny text]"
        ;;
    esac

    rm -rf "$TMP_DIR"
    trap - EXIT
}

# ---------------------------------------------------------------------------
# Run all sub-cases
# ---------------------------------------------------------------------------
run_sub_case A
run_sub_case B
run_sub_case C
run_sub_case D
run_sub_case E

echo "PASS: $TEST_NAME (all sub-cases)"
exit 0
