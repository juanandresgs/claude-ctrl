#!/usr/bin/env bash
# Thin entrypoint consolidating all Write|Edit policy checks.
# PreToolUse hook — matcher: Write|Edit
#
# @decision DEC-HOOK-003
# @title Consolidated Write|Edit entrypoint
# @status accepted
# @rationale settings.json currently chains 5 hooks sequentially for Write|Edit
#   (branch-guard, write-guard, plan-guard, plan-check, plus doc-gate/test-gate/
#   mock-gate). This entrypoint runs the same policy checks in a single process
#   via write-policy.sh delegation, reducing fork overhead and making the chain
#   readable in one place. Existing hooks are the source of truth; this file is
#   a coordinator only. settings.json rewiring happens after the test suite
#   confirms equivalence.
#
# Policy check order (first deny wins):
#   1. branch-guard          — block source writes on main/master
#   2. write-guard           — WHO: only implementer may write source files
#   3. plan-guard            — WHO: only planner may write governance markdown
#   4. plan-check            — plan existence + staleness gate for source writes
#   5. plan-immutability     — permanent sections may not be rewritten (TKT-010)
#   6. decision-log          — decision log entries are append-only (TKT-010)
set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$HOOKS_DIR/log.sh"
source "$HOOKS_DIR/lib/write-policy.sh"

HOOK_INPUT=$(read_input)
FILE_PATH=$(get_field '.tool_input.file_path')
[[ -z "$FILE_PATH" ]] && exit 0

CHECKS=(check_branch_guard check_write_who check_enforcement_gap check_plan_guard check_plan_exists check_plan_immutability_hook check_decision_log_hook)
CONTEXT_PARTS=()

for check_fn in "${CHECKS[@]}"; do
    output=$("$check_fn" "$HOOK_INPUT")

    if [[ -n "$output" ]]; then
        # First deny wins — annotate with blockingHook so agents can diagnose
        # which of the 6 checks fired. Fix #466: without this field agents see
        # a generic denial and cannot determine which hook blocked them.
        if echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
            output=$(echo "$output" | jq --arg hook "$check_fn" '.hookSpecificOutput.blockingHook = $hook')
            echo "$output"
            exit 0
        fi
        # Collect any additionalContext from passing checks
        ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
        [[ -n "$ctx" ]] && CONTEXT_PARTS+=("$ctx")
    fi
done

# If checks produced context but no deny, emit it so Claude sees the advisory
if [[ ${#CONTEXT_PARTS[@]} -gt 0 ]]; then
    COMBINED=$(printf '%s\n' "${CONTEXT_PARTS[@]}")
    ESCAPED=$(echo "$COMBINED" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": $ESCAPED
  }
}
EOF
fi

exit 0
