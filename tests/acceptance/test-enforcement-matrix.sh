#!/usr/bin/env bash
# test-enforcement-matrix.sh — Comprehensive deny/allow matrix for every
# role x action combination in the kernel WHO enforcement surface.
#
# Matrix:
#   Role          | Source Write | Governance Write | Git Op  | Expected
#   --------------|--------------|-----------------|---------|--------
#   none (orch.)  |    DENY      |      DENY       |  DENY   |   pass
#   planner       |    DENY      |      ALLOW      |  DENY   |   pass
#   implementer   |    ALLOW     |      DENY       |  DENY   |   pass
#   tester        |    DENY      |      DENY       |  DENY   |   pass
#   guardian      |    DENY      |      DENY       |  ALLOW* |   pass
#
#   *Guardian git allow requires proof=verified + test-status=pass.
#
# @decision DEC-ACC-002
# @title Enforcement matrix covers every WHO x action cell independently
# @status accepted
# @rationale A regression in one role must not hide behind passing cells in
#   another. Each row uses its own isolated temp project so state never leaks.
#   Tests drive the real hook scripts (pre-write.sh, pre-bash.sh) with synthetic
#   JSON payloads — identical to the production execution path.
#
# Usage:  bash tests/acceptance/test-enforcement-matrix.sh
# Exit:   0 all pass, 1 any fail
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRE_WRITE="$REPO_ROOT/hooks/pre-write.sh"
GUARD="$REPO_ROOT/hooks/pre-bash.sh"
TMP_BASE="$REPO_ROOT/tmp/enforce-matrix-$$"

PASS=0
FAIL=0
FAILED_CASES=()

# shellcheck disable=SC2329  # invoked via trap below
cleanup() { rm -rf "$TMP_BASE"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Project factory: minimal git project on a feature branch with MASTER_PLAN.md
# ---------------------------------------------------------------------------
make_project() {
    local name="$1"
    local dir="$TMP_BASE/$name"
    mkdir -p "$dir/.claude" "$dir/src"
    git -C "$dir" init -q
    git -C "$dir" checkout -b feature/enforce-test -q 2>/dev/null || true
    git -C "$dir" commit --allow-empty -m "init" -q
    printf '# Plan\n## Status: in-progress\n' > "$dir/MASTER_PLAN.md"
    git -C "$dir" add MASTER_PLAN.md
    git -C "$dir" commit -m "add plan" -q
    printf '%s\n' "$dir"
}

set_role() {
    # TKT-018: role detection is runtime-only; .subagent-tracker removed.
    # Write marker into the project-scoped state.db so rt_marker_get_active_role()
    # finds it when hooks run with CLAUDE_PROJECT_DIR="$project_dir".
    local project_dir="$1" role="$2"
    if [[ -n "$role" ]]; then
        local db="$project_dir/.claude/state.db"
        CLAUDE_POLICY_DB="$db" python3 "$REPO_ROOT/runtime/cli.py" schema ensure >/dev/null 2>&1
        CLAUDE_POLICY_DB="$db" python3 "$REPO_ROOT/runtime/cli.py" marker set "agent-test" "$role" >/dev/null 2>&1
    fi
}

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------
assert_deny() {
    local label="$1" output="$2"
    local decision
    decision=$(printf '%s' "$output" \
        | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    if [[ "$decision" == "deny" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — expected deny, got "%s"\n' "$label" "$decision"
        [[ -n "$output" ]] && printf '       output: %s\n' "$output"
        FAIL=$(( FAIL + 1 )); FAILED_CASES+=("$label")
    fi
}

assert_allow() {
    local label="$1" output="$2"
    local decision
    decision=$(printf '%s' "$output" \
        | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    if [[ "$decision" == "deny" ]]; then
        local reason
        reason=$(printf '%s' "$output" \
            | jq -r '.hookSpecificOutput.permissionDecisionReason // "(none)"' 2>/dev/null)
        printf '  FAIL: %s — unexpected deny: %s\n' "$label" "$reason"
        FAIL=$(( FAIL + 1 )); FAILED_CASES+=("$label")
    else
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    fi
}

# ---------------------------------------------------------------------------
# Action runners
# ---------------------------------------------------------------------------
run_source_write() {
    local project_dir="$1"
    local payload
    payload=$(jq -n \
        --arg fp "$project_dir/src/app.py" \
        --arg content "# app.py — stub for testing the implementer source-write allow path.
x = 1" \
        '{tool_name:"Write",tool_input:{file_path:$fp,content:$content}}')
    printf '%s' "$payload" \
        | CLAUDE_PROJECT_DIR="$project_dir" "$PRE_WRITE" 2>/dev/null || true
}

run_governance_write() {
    local project_dir="$1"
    local payload
    payload=$(jq -n \
        --arg fp "$project_dir/MASTER_PLAN.md" \
        '{tool_name:"Write",tool_input:{file_path:$fp,content:"# Plan"}}')
    printf '%s' "$payload" \
        | CLAUDE_PROJECT_DIR="$project_dir" "$PRE_WRITE" 2>/dev/null || true
}

# Guardian git allow: pre-set proof + test gates, then run policy engine via pre-bash.sh.
# All other roles: gates absent so policy engine denies at WHO check.
run_git_op() {
    local project_dir="$1" role="$2"
    local workflow_id="feature-enforce-test"
    local db="$project_dir/.claude/state.db"

    if [[ "$role" == "guardian" ]]; then
        CLAUDE_POLICY_DB="$db" python3 "$REPO_ROOT/runtime/cli.py" \
            test-state set pass --total 1 --passed 1 --project-root "$project_dir" >/dev/null 2>&1
        # Proof via runtime (flat file removed; eval_readiness policy gates on evaluation_state)
        CLAUDE_POLICY_DB="$db" python3 "$REPO_ROOT/runtime/cli.py" proof set "$workflow_id" "verified" >/dev/null 2>&1
        # Workflow binding + scope required by Check 12
        CLAUDE_POLICY_DB="$db" python3 "$REPO_ROOT/runtime/cli.py" \
            workflow bind "$workflow_id" "$project_dir" "feature/enforce-test" >/dev/null 2>&1
        CLAUDE_POLICY_DB="$db" python3 "$REPO_ROOT/runtime/cli.py" \
            workflow scope-set "$workflow_id" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1
        # A3: all git ops now require an active lease. Set evaluation_state=ready_for_guardian
        # with the current HEAD SHA so Check 10 passes, then issue a guardian lease.
        local head_sha
        head_sha=$(git -C "$project_dir" rev-parse HEAD 2>/dev/null || echo "")
        if [[ -n "$head_sha" ]]; then
            CLAUDE_POLICY_DB="$db" python3 "$REPO_ROOT/runtime/cli.py" \
                evaluation set "$workflow_id" "ready_for_guardian" --head-sha "$head_sha" >/dev/null 2>&1
        fi
        CLAUDE_POLICY_DB="$db" python3 "$REPO_ROOT/runtime/cli.py" \
            lease issue-for-dispatch "guardian" \
            --worktree-path "$project_dir" \
            --workflow-id "$workflow_id" \
            --allowed-ops '["routine_local","high_risk"]' >/dev/null 2>&1
    fi

    # Use a commit command string; the bash_git_who policy enforces WHO on
    # commit/merge/push via lease validation.
    local payload
    payload=$(jq -n \
        --arg cmd "git commit --allow-empty -m test" \
        --arg cwd "$project_dir" \
        '{tool_name:"Bash",tool_input:{command:$cmd},cwd:$cwd}')
    printf '%s' "$payload" \
        | CLAUDE_PROJECT_DIR="$project_dir" \
          CLAUDE_POLICY_DB="$db" \
          CLAUDE_RUNTIME_ROOT="$REPO_ROOT/runtime" \
          "$GUARD" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Row 1: orchestrator (no role)
# ---------------------------------------------------------------------------
printf '\n=== Row 1: orchestrator (no role) ===\n'
proj=$(make_project "orch")

assert_deny  "orchestrator: source write denied"     "$(run_source_write     "$proj")"
assert_deny  "orchestrator: governance write denied" "$(run_governance_write "$proj")"
assert_deny  "orchestrator: git op denied"           "$(run_git_op           "$proj" "")"

# ---------------------------------------------------------------------------
# Row 2: planner
# ---------------------------------------------------------------------------
printf '\n=== Row 2: planner ===\n'
proj=$(make_project "planner")
set_role "$proj" "planner"

assert_deny  "planner: source write denied"      "$(run_source_write     "$proj")"
assert_allow "planner: governance write allowed" "$(run_governance_write "$proj")"
assert_deny  "planner: git op denied"            "$(run_git_op           "$proj" "planner")"

# ---------------------------------------------------------------------------
# Row 3: implementer
# ---------------------------------------------------------------------------
printf '\n=== Row 3: implementer ===\n'
proj=$(make_project "impl")
set_role "$proj" "implementer"

assert_allow "implementer: source write allowed"    "$(run_source_write     "$proj")"
assert_deny  "implementer: governance write denied" "$(run_governance_write "$proj")"
assert_deny  "implementer: git op denied"           "$(run_git_op           "$proj" "implementer")"

# ---------------------------------------------------------------------------
# Row 4: tester
# ---------------------------------------------------------------------------
printf '\n=== Row 4: tester ===\n'
proj=$(make_project "tester")
set_role "$proj" "tester"

assert_deny  "tester: source write denied"     "$(run_source_write     "$proj")"
assert_deny  "tester: governance write denied" "$(run_governance_write "$proj")"
assert_deny  "tester: git op denied"           "$(run_git_op           "$proj" "tester")"

# ---------------------------------------------------------------------------
# Row 5: guardian
# ---------------------------------------------------------------------------
printf '\n=== Row 5: guardian ===\n'
proj=$(make_project "guardian")
set_role "$proj" "guardian"

assert_deny  "guardian: source write denied"              "$(run_source_write     "$proj")"
assert_deny  "guardian: governance write denied"          "$(run_governance_write "$proj")"
assert_allow "guardian: git op allowed (gates satisfied)" "$(run_git_op           "$proj" "guardian")"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n=== test-enforcement-matrix: %d passed, %d failed ===\n' "$PASS" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
    printf 'Failed cases:\n'
    for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
    printf '\nFAIL: test-enforcement-matrix\n'
    exit 1
fi

printf 'PASS: test-enforcement-matrix\n'
exit 0
