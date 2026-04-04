#!/usr/bin/env bash
# test-lease-expired-deny.sh — Issue lease with expires_at in the past,
# run expire-stale, then validate-op → denied (no active lease remains).
#
# Sub-cases:
#   A: Issue lease with ttl=1 (expires in 1s), sleep 2, expire-stale,
#      then attempt commit → Check 3 denies (no active lease — ALL git ops require lease)
#   B: Issue lease with ttl=1, sleep 2, expire-stale,
#      then attempt push → Check 3 denies (high_risk, no-lease path)
#
# @decision DEC-LEASE-001
# @title Dispatch leases replace marker-based WHO enforcement for Check 3
# @status accepted
# @rationale Expired leases are cleaned up by expire-stale. After expiry,
#   validate_op finds no active lease. Post-INIT-PE, ALL git ops (including
#   routine_local) require an active lease. No-lease → denied by Check 3.
set -euo pipefail

TEST_NAME="test-lease-expired-deny"
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
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" marker set "agent-test" "guardian" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        test-state set pass --project-root "$TMP_DIR" --passed 1 --total 1 >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        evaluation set "$WF_ID" "ready_for_guardian" --head-sha "$CURRENT_HEAD" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow bind "$WF_ID" "$TMP_DIR" "$branch" >/dev/null 2>&1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        workflow scope-set "$WF_ID" --allowed '["*"]' --forbidden '[]' >/dev/null 2>&1
}

# shellcheck disable=SC2329
_teardown() { [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"; TMP_DIR=""; }

# ---------------------------------------------------------------------------
# Sub-case A: Expired lease + routine_local commit → denied (no active lease)
# Post-INIT-PE: ALL git ops require an active lease; no-lease path is gone.
# ---------------------------------------------------------------------------
run_sub_case_a() {
    local branch="feature/expired-lease-commit"
    _setup "$branch"
    trap '_teardown' RETURN

    # Issue lease with ttl=1 (expires in 1 second)
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        lease issue-for-dispatch "guardian" \
        --workflow-id "$WF_ID" \
        --worktree-path "$TMP_DIR" \
        --branch "$branch" \
        --allowed-ops '["routine_local","high_risk"]' \
        --ttl 1 >/dev/null 2>&1

    # Wait for TTL to elapse
    sleep 2

    # Expire stale leases
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" lease expire-stale >/dev/null 2>&1

    local cmd output decision reason
    cmd="git -C \"$TMP_DIR\" commit --allow-empty -m 'after expired lease'"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")
    reason=$(_reason "$output")

    if [[ "$decision" != "deny" ]]; then
        fail "A" "expected deny for commit with expired lease, got decision='$decision'"
        return
    fi
    if ! printf '%s' "$reason" | grep -qiE "lease|No active"; then
        fail "A" "deny reason should mention 'lease', got: $reason"
        return
    fi
    pass "A" "expired lease + routine_local commit → denied (No active dispatch lease)"
}

# ---------------------------------------------------------------------------
# Sub-case B: Expired lease + push → denied (no-lease + high_risk path)
# ---------------------------------------------------------------------------
run_sub_case_b() {
    local branch="feature/expired-lease-push"
    _setup "$branch"
    trap '_teardown' RETURN

    # Issue lease with ttl=1
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
        lease issue-for-dispatch "guardian" \
        --workflow-id "$WF_ID" \
        --worktree-path "$TMP_DIR" \
        --branch "$branch" \
        --allowed-ops '["routine_local","high_risk"]' \
        --ttl 1 >/dev/null 2>&1

    # Wait for TTL to elapse
    sleep 2

    # Expire stale leases
    CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" lease expire-stale >/dev/null 2>&1

    local cmd output decision reason
    cmd="git -C \"$TMP_DIR\" push origin $branch"
    output=$(_run_guard "$cmd" "$TMP_DIR" "$TEST_DB")
    decision=$(_decision "$output")
    reason=$(_reason "$output")

    if [[ "$decision" != "deny" ]]; then
        fail "B" "expected deny for push with expired lease, got decision='$decision'"
        return
    fi
    if ! printf '%s' "$reason" | grep -qiE "lease|No active"; then
        fail "B" "deny reason should mention 'lease', got: $reason"
        return
    fi
    pass "B" "expired lease + push denied (no active lease for high_risk)"
}

echo "=== $TEST_NAME: starting ==="
run_sub_case_a
run_sub_case_b
echo ""
echo "=== $TEST_NAME: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -gt 0 ]] && exit 1
exit 0
