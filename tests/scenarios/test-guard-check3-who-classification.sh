#!/usr/bin/env bash
# v6 git WHO/custody classification scenario.
#
# Current doctrine:
# - every governed git mutation requires a dispatch lease;
# - Guardian owns landing git mutations;
# - implementers do not mutate git by default;
# - local commit/merge additionally requires ready v6_landing_readiness;
# - push/high-risk operations require explicit approval.
set -euo pipefail

TEST_NAME="test-guard-check3-who-classification"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-bash.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"
PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: <REDACTED> [$1] — $2"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $TEST_NAME [$1] — $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
_decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true; }
_reason() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true; }

_run_guard() {
    local cmd="$1" project_dir="$2" db="$3"
    local payload
    payload=$(jq -n --arg t Bash --arg c "$cmd" --arg w "$project_dir" '{tool_name:$t,tool_input:{command:$c},cwd:$w}')
    printf '%s' "$payload" \
        | CLAUDE_PROJECT_DIR="$project_dir" CLAUDE_POLICY_DB="$db" CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" "$HOOK" 2>/dev/null || true
}

_setup_repo() {
    local branch="$1" role="$2"
    WF_ID=$(printf '%s' "$branch" | tr '/: ' '---' | tr -cd '[:alnum:]._-')
    TMP_DIR="$REPO_ROOT/tmp/${TEST_NAME}-${WF_ID}-$$"
    TEST_DB="$TMP_DIR/.claude/state.db"
    mkdir -p "$TMP_DIR/.claude"
    git -C "$TMP_DIR" init -q -b main 2>/dev/null || { git -C "$TMP_DIR" init -q; git -C "$TMP_DIR" checkout -b main -q 2>/dev/null || true; }
    git -C "$TMP_DIR" config user.email t@t.com
    git -C "$TMP_DIR" config user.name T
    git -C "$TMP_DIR" commit --allow-empty -m init -q
    git -C "$TMP_DIR" checkout -b "$branch" -q
    CURRENT_HEAD=$(git -C "$TMP_DIR" rev-parse HEAD)
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" marker set agent-test "$role" --project-root "$TMP_DIR" >/dev/null
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" workflow bind "$WF_ID" "$TMP_DIR" "$branch" >/dev/null
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null
}

_seed_v6_ready_with_guardian_lease() {
    local role_for_lease="${1:-guardian}" metadata_extra="${2:-}"
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" test-state set pass --project-root "$TMP_DIR" --head-sha "$CURRENT_HEAD" --passed 1 --total 1 >/dev/null
    local reviewer_json reviewer_run payload result guardian_run lease_meta
    reviewer_json=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" stage run-create --workflow-id "$WF_ID" --stage-id reviewer --worktree-path "$TMP_DIR")
    reviewer_run=$(printf '%s' "$reviewer_json" | jq -r '.stage_run.id')
    payload=$(jq -nc --arg run "$reviewer_run" --arg sha "$CURRENT_HEAD" '{stage_run_id:$run,stage_id:"reviewer",verdict:"ready_for_guardian",summary:"reviewed",head_sha:$sha,findings:[]}')
    result=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" stage result-submit "$reviewer_run" --payload "$payload")
    guardian_run=$(printf '%s' "$result" | jq -r '.next_stage_run.id')
    if [[ -n "$metadata_extra" ]]; then
        lease_meta=$(jq -nc --arg run "$guardian_run" --argjson extra "$metadata_extra" '$extra + {stage_run_id:$run}')
    else
        lease_meta=$(jq -nc --arg run "$guardian_run" '{stage_run_id:$run}')
    fi
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" lease issue-for-dispatch "$role_for_lease" \
        --workflow-id "$WF_ID" --worktree-path "$TMP_DIR" --branch "${BRANCH:-}" \
        --allowed-ops '["routine_local","high_risk"]' --metadata "$lease_meta" >/dev/null
    if [[ "$role_for_lease" == "guardian" ]]; then
        CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" stage landing-ready "$guardian_run" >/dev/null
    fi
}

run_a_guardian_commit_allowed() {
    BRANCH="feature/check3-guardian-commit"; _setup_repo "$BRANCH" guardian; trap 'rm -rf "$TMP_DIR"' RETURN
    _seed_v6_ready_with_guardian_lease guardian
    output=$(_run_guard "git -C \"$TMP_DIR\" commit --allow-empty -m 'guardian commit'" "$TMP_DIR" "$TEST_DB")
    [[ -z "$output" || "$(_decision "$output")" != deny ]] && pass A "Guardian commit allowed with lease + v6_landing_readiness" || fail A "unexpected deny: $(_reason "$output")"
}

run_b_guardian_commit_without_v6_readiness_denied() {
    BRANCH="feature/check3-no-readiness"; _setup_repo "$BRANCH" guardian; trap 'rm -rf "$TMP_DIR"' RETURN
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" test-state set pass --project-root "$TMP_DIR" --head-sha "$CURRENT_HEAD" --passed 1 --total 1 >/dev/null
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" lease issue-for-dispatch guardian --workflow-id "$WF_ID" --worktree-path "$TMP_DIR" --branch "$BRANCH" --allowed-ops '["routine_local","high_risk"]' >/dev/null
    output=$(_run_guard "git -C \"$TMP_DIR\" commit --allow-empty -m 'premature'" "$TMP_DIR" "$TEST_DB")
    [[ "$(_decision "$output")" == deny && "$(_reason "$output")" == *v6_landing_readiness* ]] && pass B "Guardian commit without v6 readiness denied" || fail B "expected v6_landing_readiness deny, got: $(_reason "$output")"
}

run_c_implementer_commit_denied_by_default() {
    BRANCH="feature/check3-impl-commit"; _setup_repo "$BRANCH" implementer; trap 'rm -rf "$TMP_DIR"' RETURN
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" lease issue-for-dispatch implementer --workflow-id "$WF_ID" --worktree-path "$TMP_DIR" --branch "$BRANCH" --allowed-ops '["routine_local"]' >/dev/null
    output=$(_run_guard "git -C \"$TMP_DIR\" commit --allow-empty -m 'impl commit'" "$TMP_DIR" "$TEST_DB")
    [[ "$(_decision "$output")" == deny && "$(_reason "$output")" == *implementer* ]] && pass C "Implementer commit denied by default" || fail C "expected implementer custody deny, got: $(_reason "$output")"
}

run_d_unleased_git_denied() {
    BRANCH="feature/check3-no-lease"; _setup_repo "$BRANCH" guardian; trap 'rm -rf "$TMP_DIR"' RETURN
    output=$(_run_guard "git -C \"$TMP_DIR\" commit --allow-empty -m 'no lease'" "$TMP_DIR" "$TEST_DB")
    [[ "$(_decision "$output")" == deny && "$(_reason "$output")" == *lease* ]] && pass D "Unleased git mutation denied" || fail D "expected lease deny, got: $(_reason "$output")"
}

run_e_push_requires_approval() {
    BRANCH="feature/check3-push"; _setup_repo "$BRANCH" guardian; trap 'rm -rf "$TMP_DIR"' RETURN
    _seed_v6_ready_with_guardian_lease guardian
    output=$(_run_guard "git -C \"$TMP_DIR\" push origin $BRANCH" "$TMP_DIR" "$TEST_DB")
    [[ "$(_decision "$output")" == deny && "$(_reason "$output")" == *approval* ]] && pass E "Guardian push denied without approval" || fail E "expected approval deny, got: $(_reason "$output")"
}

run_f_implementer_push_denied_even_with_lease() {
    BRANCH="feature/check3-impl-push"; _setup_repo "$BRANCH" implementer; trap 'rm -rf "$TMP_DIR"' RETURN
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" lease issue-for-dispatch implementer --workflow-id "$WF_ID" --worktree-path "$TMP_DIR" --branch "$BRANCH" --allowed-ops '["routine_local","high_risk"]' >/dev/null
    output=$(_run_guard "git -C \"$TMP_DIR\" push origin $BRANCH" "$TMP_DIR" "$TEST_DB")
    [[ "$(_decision "$output")" == deny && "$(_reason "$output")" == *implementer* ]] && pass F "Implementer push denied even with lease" || fail F "expected implementer push deny, got: $(_reason "$output")"
}

echo "=== $TEST_NAME: starting ==="
run_a_guardian_commit_allowed
run_b_guardian_commit_without_v6_readiness_denied
run_c_implementer_commit_denied_by_default
run_d_unleased_git_denied
run_e_push_requires_approval
run_f_implementer_push_denied_even_with_lease

if [[ $FAIL_COUNT -eq 0 ]]; then
    echo "PASS: <REDACTED> ($PASS_COUNT sub-cases)"
    exit 0
fi

echo "FAIL: $TEST_NAME — $FAIL_COUNT failures ($PASS_COUNT passed)"
exit 1
