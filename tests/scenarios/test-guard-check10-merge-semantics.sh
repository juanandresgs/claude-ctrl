#!/usr/bin/env bash
# v6 landing-readiness SHA semantics for git commit/merge.
#
# Proves bash_eval_readiness compares:
#   - merge operations against the merge-ref tip;
#   - commit operations against worktree HEAD;
# and that stale v6_landing_readiness denies landing.
set -euo pipefail

TEST_NAME="test-guard-check10-merge-semantics"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-bash.sh"
RUNTIME_ROOT="$REPO_ROOT/runtime"

run_hook() {
    local payload="$1" project_dir="$2" db="$3"
    printf '%s' "$payload" \
        | CLAUDE_PROJECT_DIR="$project_dir" CLAUDE_POLICY_DB="$db" \
          CLAUDE_RUNTIME_ROOT="$RUNTIME_ROOT" "$HOOK" 2>/dev/null || true
}

assert_allowed() {
    local sub_case="$1" output="$2"
    if [[ -n "$output" ]]; then
        local decision reason
        decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")
        if [[ "$decision" == "deny" ]]; then
            reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || echo "")
            echo "FAIL: $TEST_NAME [$sub_case] — unexpected deny: $reason"
            exit 1
        fi
    fi
    echo "PASS: <REDACTED> [$sub_case]"
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
        echo "FAIL: $TEST_NAME [$sub_case] — deny reason does not match '$reason_pattern'"
        echo "  reason: $reason"
        exit 1
    fi
    echo "PASS: <REDACTED> [$sub_case]"
}

init_case_repo() {
    local tmp_dir="$1" branch="$2"
    mkdir -p "$tmp_dir/.claude"
    git -C "$tmp_dir" init -q -b main 2>/dev/null || {
        git -C "$tmp_dir" init -q
        git -C "$tmp_dir" checkout -b main -q 2>/dev/null || true
    }
    git -C "$tmp_dir" config user.email "t@t.com"
    git -C "$tmp_dir" config user.name "T"
    git -C "$tmp_dir" commit --allow-empty -m "init" -q
    git -C "$tmp_dir" checkout -b "$branch" -q
    git -C "$tmp_dir" commit --allow-empty -m "feature work" -q
}

seed_v6_ready() {
    local db="$1" tmp_dir="$2" wf_id="$3" branch="$4" sha="$5"
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" workflow bind "$wf_id" "$tmp_dir" "$branch" >/dev/null
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" workflow scope-set "$wf_id" --allowed '["*"]' --forbidden '[]' >/dev/null
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" test-state set pass --project-root "$tmp_dir" --head-sha "$sha" --passed 1 --total 1 >/dev/null

    local reviewer_json reviewer_run payload result guardian_run lease_meta readiness
    reviewer_json=$(CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" stage run-create --workflow-id "$wf_id" --stage-id reviewer --worktree-path "$tmp_dir")
    reviewer_run=$(printf '%s' "$reviewer_json" | jq -r '.stage_run.id')
    payload=$(jq -nc --arg run "$reviewer_run" --arg sha "$sha" '{stage_run_id:$run,stage_id:"reviewer",verdict:"ready_for_guardian",summary:"reviewed",head_sha:$sha,findings:[]}')
    result=$(CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" stage result-submit "$reviewer_run" --payload "$payload")
    guardian_run=$(printf '%s' "$result" | jq -r '.next_stage_run.id')
    lease_meta=$(jq -nc --arg run "$guardian_run" '{stage_run_id:$run}')
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" lease issue-for-dispatch guardian \
        --workflow-id "$wf_id" --worktree-path "$tmp_dir" --branch "$branch" \
        --allowed-ops '["routine_local","high_risk"]' --metadata "$lease_meta" >/dev/null
    readiness=$(CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" stage landing-ready "$guardian_run")
    [[ $(printf '%s' "$readiness" | jq -r '.readiness.status') == ready ]]
}

run_sub_case() {
    local sub_case="$1"
    local tmp_dir="$REPO_ROOT/tmp/$TEST_NAME-${sub_case}-$$"
    local db="$tmp_dir/.claude/state.db"
    local branch="feature/check10-test-${sub_case}"
    local wf_id
    wf_id=$(printf '%s' "$branch" | tr '/: ' '---' | tr -cd '[:alnum:]._-')
    trap 'rm -rf "$tmp_dir"' RETURN

    init_case_repo "$tmp_dir" "$branch"
    local feature_sha
    feature_sha=$(git -C "$tmp_dir" rev-parse HEAD)
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null
    CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" marker set agent-test guardian --project-root "$tmp_dir" >/dev/null

    case "$sub_case" in
        A)
            git -C "$tmp_dir" checkout main -q
            seed_v6_ready "$db" "$tmp_dir" "$wf_id" "$branch" "$feature_sha"
            cmd="git -C \"$tmp_dir\" merge $branch"
            payload=$(jq -n --arg t Bash --arg c "$cmd" --arg w "$tmp_dir" '{tool_name:$t,tool_input:{command:$c},cwd:$w}')
            output=$(run_hook "$payload" "$tmp_dir" "$db")
            assert_allowed "A: merge correct SHA" "$output"
            ;;
        B)
            seed_v6_ready "$db" "$tmp_dir" "$wf_id" "$branch" "$feature_sha"
            git -C "$tmp_dir" checkout "$branch" -q
            git -C "$tmp_dir" commit --allow-empty -m "extra commit after review" -q
            git -C "$tmp_dir" checkout main -q
            cmd="git -C \"$tmp_dir\" merge $branch"
            payload=$(jq -n --arg t Bash --arg c "$cmd" --arg w "$tmp_dir" '{tool_name:$t,tool_input:{command:$c},cwd:$w}')
            output=$(run_hook "$payload" "$tmp_dir" "$db")
            assert_denied "B: merge stale SHA" "$output" "head_sha"
            ;;
        C)
            git -C "$tmp_dir" checkout "$branch" -q
            current_head=$(git -C "$tmp_dir" rev-parse HEAD)
            seed_v6_ready "$db" "$tmp_dir" "$wf_id" "$branch" "$current_head"
            cmd="git -C \"$tmp_dir\" commit --allow-empty -m 'test commit'"
            payload=$(jq -n --arg t Bash --arg c "$cmd" --arg w "$tmp_dir" '{tool_name:$t,tool_input:{command:$c},cwd:$w}')
            output=$(run_hook "$payload" "$tmp_dir" "$db")
            assert_allowed "C: commit correct SHA" "$output"
            ;;
        D)
            git -C "$tmp_dir" checkout "$branch" -q
            old_head=$(git -C "$tmp_dir" rev-parse HEAD)
            seed_v6_ready "$db" "$tmp_dir" "$wf_id" "$branch" "$old_head"
            git -C "$tmp_dir" commit --allow-empty -m "new commit after review" -q
            cmd="git -C \"$tmp_dir\" commit --allow-empty -m 'another commit'"
            payload=$(jq -n --arg t Bash --arg c "$cmd" --arg w "$tmp_dir" '{tool_name:$t,tool_input:{command:$c},cwd:$w}')
            output=$(run_hook "$payload" "$tmp_dir" "$db")
            assert_denied "D: commit stale SHA" "$output" "head_sha"
            ;;
        E)
            git -C "$tmp_dir" checkout "$branch" -q
            CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" workflow bind "$wf_id" "$tmp_dir" "$branch" >/dev/null
            CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" workflow scope-set "$wf_id" --allowed '["*"]' --forbidden '[]' >/dev/null
            CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" test-state set pass --project-root "$tmp_dir" --head-sha "$feature_sha" --passed 1 --total 1 >/dev/null
            CLAUDE_POLICY_DB="$db" python3 "$RUNTIME_ROOT/cli.py" lease issue-for-dispatch guardian \
                --workflow-id "$wf_id" --worktree-path "$tmp_dir" --branch "$branch" \
                --allowed-ops '["routine_local","high_risk"]' >/dev/null
            cmd="git -C \"$tmp_dir\" commit --allow-empty -m 'test'"
            payload=$(jq -n --arg t Bash --arg c "$cmd" --arg w "$tmp_dir" '{tool_name:$t,tool_input:{command:$c},cwd:$w}')
            output=$(run_hook "$payload" "$tmp_dir" "$db")
            assert_denied "E: missing v6 readiness" "$output" "v6_landing_readiness"
            ;;
    esac
    rm -rf "$tmp_dir"
    trap - RETURN
}

run_sub_case A
run_sub_case B
run_sub_case C
run_sub_case D
run_sub_case E

echo "PASS: <REDACTED> (all sub-cases)"
