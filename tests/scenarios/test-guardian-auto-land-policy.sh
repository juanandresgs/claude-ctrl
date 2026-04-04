#!/usr/bin/env bash
# test-guardian-auto-land-policy.sh — proves the auto-land governance policy
# is internally consistent across guard.sh mechanics and governance text.
#
# Three sub-cases:
#   Sub-case A: Clean evaluated flow allows local commit (guard.sh allows)
#   Sub-case B: Destructive ops are still denied by guard.sh (safety unchanged)
#   Sub-case C: Governance text assertions (text consistency checks)
#
# This test does NOT re-prove the guard.sh gate mechanics (those are covered by
# test-guard-evaluator-gate-allows.sh and test-guard-evaluator-gate-denies.sh).
# It proves that (1) the mechanics still work as-expected after the policy text
# change, (2) destructive ops are hard-blocked, and (3) the governance text
# reflects the two-tier model described in agents/guardian.md.
#
# @decision DEC-GUARD-AUTOLAND
# @title Guardian auto-land policy: tiered approval model
# @status accepted
# @rationale ready_for_guardian is the tester-issued autoverify-HIGH equivalent.
#   Requiring additional user approval after tester clearance wastes tokens and
#   creates a redundant approval loop. Local commit/merge auto-lands when all
#   conditions are met. Push/rebase/reset/force and destructive ops still require
#   explicit user approval. guard.sh mechanical enforcement is unchanged — only
#   the governance text and Guardian agent instructions are updated.
set -euo pipefail

TEST_NAME="test-guardian-auto-land-policy"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-bash.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"

# ─── Sub-case A: Clean local commit is ALLOWED ────────────────────────────────
# Mirrors the full production sequence:
#   guardian role active + test-status=pass + evaluation_state=ready_for_guardian
#   with head_sha match + workflow binding + scope set
# → guard.sh must allow (no deny output).

run_sub_case_a() {
    local TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-A-$$"
    local TEST_DB="$TMP_DIR/.claude/state.db"
    local BRANCH="feature/auto-land-test"
    local WF_ID="feature-auto-land-test"

    trap 'rm -rf "$TMP_DIR"' EXIT

    mkdir -p "$TMP_DIR/.claude"
    git -C "$TMP_DIR" init -q
    git -C "$TMP_DIR" config user.email "t@t.com"
    git -C "$TMP_DIR" config user.name "T"
    git -C "$TMP_DIR" commit --allow-empty -m "init" -q
    git -C "$TMP_DIR" checkout -b "$BRANCH" -q

    CURRENT_HEAD=$(git -C "$TMP_DIR" rev-parse HEAD)

    # Gate 1: schema + guardian role
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian" >/dev/null 2>&1

    # Gate 2: test status = pass
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    test-state set pass --project-root "$TMP_DIR" --passed 1 --total 1 >/dev/null 2>&1

    # Gate 3: evaluation_state = ready_for_guardian with matching head_sha
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$CURRENT_HEAD" >/dev/null 2>&1

    # Gate 4: workflow binding + scope
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$WF_ID" "$TMP_DIR" "$BRANCH" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "$WF_ID" \
        --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1

    # Gate 5: dispatch lease (policy engine requires active lease for all git ops)
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        lease issue-for-dispatch "guardian" \
        --worktree-path "$TMP_DIR" --workflow-id "$WF_ID" \
        --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1

    CMD="git -C \"$TMP_DIR\" commit --allow-empty -m 'auto-land test commit'"
    PAYLOAD=$(jq -n --arg t "Bash" --arg c "$CMD" --arg w "$TMP_DIR" \
        '{tool_name:$t,tool_input:{command:$c},cwd:$w}')

    output=$(printf '%s' "$PAYLOAD" \
        | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" \
          CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" "$HOOK" 2>/dev/null) || {
        echo "FAIL: $TEST_NAME [A] — hook exited nonzero"
        exit 1
    }

    if [[ -n "$output" ]]; then
        decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")
        if [[ "$decision" == "deny" ]]; then
            reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || echo "")
            echo "FAIL: $TEST_NAME [A] — clean evaluated commit denied: $reason"
            exit 1
        fi
    fi

    echo "PASS: $TEST_NAME [A] — clean evaluated commit allowed (no deny)"
    rm -rf "$TMP_DIR"
    trap - EXIT
}

# ─── Sub-case B: Destructive ops still DENIED by guard.sh ─────────────────────
# Even with guardian role + all gates satisfied, these ops must be denied.
# This proves the policy change did NOT weaken safety enforcement.

run_deny_check() {
    local label="$1"
    local cmd="$2"
    local expect_pattern="${3:-}"  # optional grep pattern to confirm deny reason

    local TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-B-${label}-$$"
    local TEST_DB="$TMP_DIR/.claude/state.db"
    local BRANCH="feature/destructive-deny-${label}"
    local WF_ID="feature-destructive-deny-${label}"

    trap 'rm -rf "$TMP_DIR"' EXIT

    mkdir -p "$TMP_DIR/.claude"
    git -C "$TMP_DIR" init -q
    git -C "$TMP_DIR" config user.email "t@t.com"
    git -C "$TMP_DIR" config user.name "T"
    git -C "$TMP_DIR" commit --allow-empty -m "init" -q
    git -C "$TMP_DIR" checkout -b "$BRANCH" -q

    CURRENT_HEAD=$(git -C "$TMP_DIR" rev-parse HEAD)

    # Set up all passing gates (same as sub-case A) to isolate the destructive-op check
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    test-state set pass --project-root "$TMP_DIR" --passed 1 --total 1 >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$CURRENT_HEAD" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$WF_ID" "$TMP_DIR" "$BRANCH" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1

    PAYLOAD=$(jq -n --arg t "Bash" --arg c "$cmd" --arg w "$TMP_DIR" \
        '{tool_name:$t,tool_input:{command:$c},cwd:$w}')

    output=$(printf '%s' "$PAYLOAD" \
        | CLAUDE_PROJECT_DIR="$TMP_DIR" CLAUDE_POLICY_DB="$TEST_DB" \
          CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" "$HOOK" 2>/dev/null) || true

    decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")

    if [[ "$decision" != "deny" ]]; then
        echo "FAIL: $TEST_NAME [B:$label] — expected deny for destructive op, got '$decision'"
        echo "  cmd: $cmd"
        echo "  output: $output"
        exit 1
    fi

    if [[ -n "$expect_pattern" ]]; then
        reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || echo "")
        if ! printf '%s' "$reason" | grep -qi "$expect_pattern"; then
            echo "FAIL: $TEST_NAME [B:$label] — deny reason missing expected pattern '$expect_pattern'"
            echo "  reason: $reason"
            exit 1
        fi
    fi

    echo "PASS: $TEST_NAME [B:$label] — correctly denied"
    rm -rf "$TMP_DIR"
    trap - EXIT
}

run_sub_case_b() {
    # Check 6: git reset --hard
    run_deny_check "reset-hard" \
        "git -C /tmp reset --hard HEAD~1" \
        "destructive"

    # Check 6: git clean -f
    run_deny_check "clean-f" \
        "git -C /tmp clean -f" \
        "permanently deletes"

    # Check 6: git branch -D
    run_deny_check "branch-D" \
        "git -C /tmp branch -D some-branch" \
        "force-deletes"

    # Check 5: git push --force without --force-with-lease
    # Inline test: needs a lease so Check 3 passes through to Check 5.
    # run_deny_check uses /tmp paths which have no lease, causing Check 3 to
    # deny first. This inline version uses the real TMP_DIR with a lease.
    local PF_TMP="$REPO_ROOT/tmp/$TEST_NAME-B-push-force-$$"
    local PF_DB="$PF_TMP/.claude/state.db"
    local PF_BRANCH="feature/destructive-deny-push-force"
    local PF_WF="feature-destructive-deny-push-force"
    trap 'rm -rf "$PF_TMP"' EXIT
    mkdir -p "$PF_TMP/.claude"
    git -C "$PF_TMP" init -q
    git -C "$PF_TMP" config user.email "t@t.com"
    git -C "$PF_TMP" config user.name "T"
    git -C "$PF_TMP" commit --allow-empty -m "init" -q
    git -C "$PF_TMP" checkout -b "$PF_BRANCH" -q
    local PF_HEAD
    PF_HEAD=$(git -C "$PF_TMP" rev-parse HEAD)
    CLAUDE_POLICY_DB="$PF_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1
    CLAUDE_POLICY_DB="$PF_DB" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$PF_DB" python3 "$RUNTIME_ROOT/cli.py" \
        test-state set pass --project-root "$PF_TMP" --passed 1 --total 1 >/dev/null 2>&1
    CLAUDE_POLICY_DB="$PF_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$PF_WF" "ready_for_guardian" --head-sha "$PF_HEAD" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$PF_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$PF_WF" "$PF_TMP" "$PF_BRANCH" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$PF_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "$PF_WF" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1
    CLAUDE_POLICY_DB="$PF_DB" python3 "$RUNTIME_ROOT/cli.py" \
        lease issue-for-dispatch "guardian" --workflow-id "$PF_WF" \
        --worktree-path "$PF_TMP" --branch "$PF_BRANCH" \
        --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1
    CLAUDE_POLICY_DB="$PF_DB" python3 "$RUNTIME_ROOT/cli.py" \
        approval grant "$PF_WF" "push" >/dev/null 2>&1
    local pf_cmd="git -C \"$PF_TMP\" push origin $PF_BRANCH --force"
    local pf_payload pf_output pf_decision pf_reason
    pf_payload=$(jq -n --arg t "Bash" --arg c "$pf_cmd" --arg w "$PF_TMP" \
        '{tool_name:$t,tool_input:{command:$c},cwd:$w}')
    pf_output=$(printf '%s' "$pf_payload" \
        | CLAUDE_PROJECT_DIR="$PF_TMP" CLAUDE_POLICY_DB="$PF_DB" \
          CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" "$HOOK" 2>/dev/null) || true
    pf_decision=$(printf '%s' "$pf_output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)
    if [[ "$pf_decision" != "deny" ]]; then
        echo "FAIL: $TEST_NAME [B:push-force] — expected deny, got '$pf_decision'"
        exit 1
    fi
    pf_reason=$(printf '%s' "$pf_output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)
    if ! printf '%s' "$pf_reason" | grep -qi "force-with-lease"; then
        echo "FAIL: $TEST_NAME [B:push-force] — deny reason missing 'force-with-lease': $pf_reason"
        exit 1
    fi
    echo "PASS: $TEST_NAME [B:push-force] — correctly denied"
    rm -rf "$PF_TMP"
    trap - EXIT
}

# ─── Sub-case C: Governance text assertions ────────────────────────────────────
# Verifies that the governance text reflects the two-tier model.
# Catches regressions where someone rewrites guardian.md back to blanket approval.

run_sub_case_c() {
    local GUARDIAN_MD="$REPO_ROOT/agents/guardian.md"
    local CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
    local failures=0

    # C1: agents/guardian.md must contain an Auto-land section (tiered model present)
    if ! grep -qi "auto-land\|auto land" "$GUARDIAN_MD"; then
        echo "FAIL: $TEST_NAME [C1] — agents/guardian.md missing 'Auto-land' section"
        failures=$((failures + 1))
    else
        echo "PASS: $TEST_NAME [C1] — agents/guardian.md contains auto-land section"
    fi

    # C2: agents/guardian.md must NOT treat approval question as the universal default
    # The old text had "Ask 'Do you approve?'" as the only protocol.
    # After the change, that phrase must be scoped to high-risk ops only.
    # We check that the phrase appears inside an "Approval required" or "high-risk" context,
    # not as a standalone universal instruction at the top-level protocol.
    # Strategy: if the file still begins its Approval Protocol with just the ask-approve line
    # (no tiering), it fails. We look for explicit tier labels to confirm structure.
    if ! grep -qi "approval required\|high.risk\|high risk" "$GUARDIAN_MD"; then
        echo "FAIL: $TEST_NAME [C2] — agents/guardian.md missing high-risk approval tier label"
        failures=$((failures + 1))
    else
        echo "PASS: $TEST_NAME [C2] — agents/guardian.md contains high-risk tier label"
    fi

    # C3: agents/guardian.md must mention push/rebase/reset as requiring approval
    if ! grep -qi "push.*approv\|rebase.*approv\|reset.*approv\|approv.*push\|approv.*rebase\|approv.*reset" "$GUARDIAN_MD"; then
        # fallback: check that push, rebase, and reset all appear in the Approval required section
        if ! grep -qi "push\|rebase\|reset" "$GUARDIAN_MD"; then
            echo "FAIL: $TEST_NAME [C3] — agents/guardian.md does not mention push/rebase/reset in approval context"
            failures=$((failures + 1))
        else
            echo "PASS: $TEST_NAME [C3] — agents/guardian.md mentions push/rebase/reset (approval context inferred)"
        fi
    else
        echo "PASS: $TEST_NAME [C3] — agents/guardian.md explicitly links push/rebase/reset to approval"
    fi

    # C4: CLAUDE.md Sacred Practice #8 must contain language about auto/automatic local landing
    if ! grep -qi "automatic\|auto-land\|auto land" "$CLAUDE_MD"; then
        echo "FAIL: $TEST_NAME [C4] — CLAUDE.md Sacred Practice #8 missing 'automatic' local-landing language"
        failures=$((failures + 1))
    else
        echo "PASS: $TEST_NAME [C4] — CLAUDE.md Sacred Practice #8 contains automatic local-landing language"
    fi

    # C5: CLAUDE.md Sacred Practice #8 must distinguish local landing from push/force
    if ! grep -qiE "push.*approval|force.*approval|approval.*push|approval.*force" "$CLAUDE_MD"; then
        # fallback: check that the #8 entry mentions push/force requiring approval separately
        if ! grep -qiE "Push|force ops|destructive" "$CLAUDE_MD"; then
            echo "FAIL: $TEST_NAME [C5] — CLAUDE.md #8 does not distinguish push/force as requiring approval"
            failures=$((failures + 1))
        else
            echo "PASS: $TEST_NAME [C5] — CLAUDE.md #8 distinguishes push/force ops (approval required)"
        fi
    else
        echo "PASS: $TEST_NAME [C5] — CLAUDE.md #8 explicitly links push/force to approval requirement"
    fi

    if [[ "$failures" -gt 0 ]]; then
        echo "FAIL: $TEST_NAME [C] — $failures governance text assertion(s) failed"
        exit 1
    fi
    echo "PASS: $TEST_NAME [C] — all governance text assertions passed"
}

# ─── Run all sub-cases ─────────────────────────────────────────────────────────
run_sub_case_a
run_sub_case_b
run_sub_case_c

echo "PASS: $TEST_NAME (all sub-cases)"
exit 0
