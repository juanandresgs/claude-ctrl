#!/usr/bin/env bash
# tests/scenarios/test-policy-engine-smoke.sh
#
# Scenario: PE-W1 smoke tests for the policy engine CLI surface.
#
# Verifies:
#   1. cc-policy evaluate returns valid JSON with expected structure
#   2. cc-policy policy list returns empty array (no policies in W1)
#   3. cc-policy policy explain returns valid trace structure
#
# Exit code: 0 = all checks passed, non-zero = failure
# All output goes to stdout so pytest-subprocess or manual inspection can read it.
#
# @decision DEC-PE-007
# Title: Scenario smoke test validates CLI contract for policy engine endpoints
# Status: accepted
# Rationale: The CLI surface (evaluate, policy list, policy explain) is the
#   integration boundary hooks use. Testing it via the same shell invocation
#   that hooks will use (python3 runtime/cli.py evaluate) validates the full
#   path: argparse wiring → handler → engine → JSON output. Unit tests cover
#   internal semantics; this test covers the external contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI="$PROJECT_ROOT/runtime/cli.py"

PASS=0
FAIL=0

check() {
    local desc="$1"
    local result="$2"
    local expect="$3"
    if echo "$result" | grep -q "$expect"; then
        echo "PASS: $desc"
        ((PASS++)) || true
    else
        echo "FAIL: $desc"
        echo "  Expected to find: $expect"
        echo "  Got: $result"
        ((FAIL++)) || true
    fi
}

TRIVIAL_PAYLOAD='{"event_type":"PreToolUse","tool_name":"Write","tool_input":{},"cwd":"/tmp","actor_role":"","actor_id":""}'

# -----------------------------------------------------------------------
# Test 1: cc-policy evaluate — trivial payload → allow
# -----------------------------------------------------------------------
EVAL_OUT=$(echo "$TRIVIAL_PAYLOAD" | python3 "$CLI" evaluate 2>&1)
check "evaluate returns status ok"               "$EVAL_OUT" '"status": "ok"'
check "evaluate returns action"                  "$EVAL_OUT" '"action":'
check "evaluate returns reason"                  "$EVAL_OUT" '"reason":'
check "evaluate returns policy_name"             "$EVAL_OUT" '"policy_name":'
check "evaluate returns hookSpecificOutput"      "$EVAL_OUT" '"hookSpecificOutput":'
check "evaluate trivial payload → allow"         "$EVAL_OUT" '"action": "allow"'
check "evaluate hook output has permissionDecision" "$EVAL_OUT" '"permissionDecision"'

# -----------------------------------------------------------------------
# Test 2: cc-policy policy list — empty in W1
# -----------------------------------------------------------------------
LIST_OUT=$(python3 "$CLI" policy list 2>&1)
check "policy list returns status ok"            "$LIST_OUT" '"status": "ok"'
check "policy list returns policies key"         "$LIST_OUT" '"policies":'
check "policy list returns count key"            "$LIST_OUT" '"count":'
check "policy list count is 22 post-W5"          "$LIST_OUT" '"count": 22'

# -----------------------------------------------------------------------
# Test 3: cc-policy policy explain — trace structure
# -----------------------------------------------------------------------
EXPLAIN_OUT=$(echo "$TRIVIAL_PAYLOAD" | python3 "$CLI" policy explain 2>&1)
check "policy explain returns status ok"         "$EXPLAIN_OUT" '"status": "ok"'
check "policy explain returns trace key"         "$EXPLAIN_OUT" '"trace":'
check "policy explain returns count key"         "$EXPLAIN_OUT" '"count":'
check "policy explain count is 22 post-W5"       "$EXPLAIN_OUT" '"count": 22'

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
