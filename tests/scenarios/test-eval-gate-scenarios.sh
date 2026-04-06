#!/usr/bin/env bash
# tests/scenarios/test-eval-gate-scenarios.sh
#
# Verify the 5 gate eval scenarios produce correct policy verdicts.
#
# Gate scenarios test the policy engine deterministically. Rather than going
# through run_deterministic() (which hardcodes actor_role=tester for the
# write-who scenarios), this test invokes the policy engine directly via
# cc-policy evaluate with the exact payloads each scenario describes.
#
# Scenarios tested:
#   1. write-who-deny       — tester writes src → deny
#   2. impl-source-allow    — implementer writes src → allow
#   3. guardian-no-lease-deny — guardian git commit, no lease → deny
#   4. eval-invalidation    — tester writes src, eval_state=ready → deny
#   5. scope-violation-deny — tester writes src in scoped project → deny
#
# All 5 produce the correct verdict via the policy engine CLI.
#
# Pattern: same as test-policy-engine-smoke.sh — JSON payload on stdin to
# python3 runtime/cli.py evaluate, inspect permissionDecision in output.
#
# Exit code: 0 = all checks passed, non-zero = failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI="$PROJECT_ROOT/runtime/cli.py"
FIXTURES_DIR="$PROJECT_ROOT/evals/fixtures"

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

# -----------------------------------------------------------------------
# Scenario 1: write-who-deny
# Tester role writes a source file → write_who denies.
# -----------------------------------------------------------------------
echo "--- Scenario 1: write-who-deny ---"

PAYLOAD=$(jq -n \
    --arg fp "$FIXTURES_DIR/clean-hello-world/src/hello.py" \
    '{
        event_type: "Write",
        tool_name: "Write",
        tool_input: {file_path: $fp, content: "# test\n"},
        cwd: "/tmp",
        actor_role: "tester",
        actor_id: "eval-test"
    }')

OUT=$(echo "$PAYLOAD" | python3 "$CLI" evaluate 2>&1)
check "write-who-deny: tester write → deny" "$OUT" '"action": "deny"'
check "write-who-deny: policy_name=write_who" "$OUT" '"policy_name": "write_who"'
check "write-who-deny: permissionDecision=deny" "$OUT" '"permissionDecision": "deny"'

# -----------------------------------------------------------------------
# Scenario 2: impl-source-allow
# Implementer role writes a source file → write_who returns no_opinion
# (passes through). Verified via policy explain trace.
#
# Note: other downstream policies (doc_gate etc.) may still deny on their
# own criteria. The gate scenario tests the write_who policy specifically:
# implementer role must NOT be denied by write_who. We verify this via the
# policy explain trace which shows write_who result = "no_opinion".
# -----------------------------------------------------------------------
echo "--- Scenario 2: impl-source-allow ---"

PAYLOAD=$(jq -n \
    --arg fp "$FIXTURES_DIR/basic-project/src/app.py" \
    '{
        event_type: "Write",
        tool_name: "Write",
        tool_input: {file_path: $fp, content: "test"},
        cwd: "/tmp",
        actor_role: "implementer",
        actor_id: "eval-test"
    }')

# Use policy explain to inspect the write_who trace result directly.
# write_who must return "no_opinion" for implementer (allowed through).
TRACE=$(echo "$PAYLOAD" | python3 "$CLI" policy explain 2>&1)
check "impl-source-allow: write_who result=no_opinion for implementer" "$TRACE" '"policy_name": "write_who", "result": "no_opinion"'
check "impl-source-allow: trace contains write_who entry" "$TRACE" 'write_who'

# -----------------------------------------------------------------------
# Scenario 3: guardian-no-lease-deny
# Guardian attempts git commit with no lease → bash_git_who denies.
# -----------------------------------------------------------------------
echo "--- Scenario 3: guardian-no-lease-deny ---"

PAYLOAD=$(jq -n \
    --arg cwd "$FIXTURES_DIR/guardian-no-lease" \
    '{
        event_type: "Bash",
        tool_name: "Bash",
        tool_input: {command: "git commit -m \"feat: landing\""},
        cwd: $cwd,
        actor_role: "guardian",
        actor_id: "eval-test"
    }')

OUT=$(echo "$PAYLOAD" | python3 "$CLI" evaluate 2>&1)
check "guardian-no-lease-deny: no-lease git commit → deny" "$OUT" '"action": "deny"'
check "guardian-no-lease-deny: policy_name=bash_git_who" "$OUT" '"policy_name": "bash_git_who"'
check "guardian-no-lease-deny: permissionDecision=deny" "$OUT" '"permissionDecision": "deny"'

# -----------------------------------------------------------------------
# Scenario 4: eval-invalidation
# Tester writes source file after eval_state=ready_for_guardian → still deny.
# (write_who checks role, not eval_state — role enforcement is unconditional)
# -----------------------------------------------------------------------
echo "--- Scenario 4: eval-invalidation ---"

PAYLOAD=$(jq -n \
    --arg fp "$FIXTURES_DIR/eval-ready/src/feature.py" \
    '{
        event_type: "Write",
        tool_name: "Write",
        tool_input: {file_path: $fp, content: "# tester write after clearance\n"},
        cwd: "/tmp",
        actor_role: "tester",
        actor_id: "eval-test"
    }')

OUT=$(echo "$PAYLOAD" | python3 "$CLI" evaluate 2>&1)
check "eval-invalidation: tester write after eval clearance → deny" "$OUT" '"action": "deny"'
check "eval-invalidation: policy_name=write_who" "$OUT" '"policy_name": "write_who"'
check "eval-invalidation: permissionDecision=deny" "$OUT" '"permissionDecision": "deny"'

# -----------------------------------------------------------------------
# Scenario 5: scope-violation-deny
# Tester writes to src/feature.py in scoped project → write_who denies
# (role check fires before scope check).
# -----------------------------------------------------------------------
echo "--- Scenario 5: scope-violation-deny ---"

PAYLOAD=$(jq -n \
    --arg fp "$FIXTURES_DIR/scoped-project/src/feature.py" \
    '{
        event_type: "Write",
        tool_name: "Write",
        tool_input: {file_path: $fp, content: "# tester scope violation\n"},
        cwd: "/tmp",
        actor_role: "tester",
        actor_id: "eval-test"
    }')

OUT=$(echo "$PAYLOAD" | python3 "$CLI" evaluate 2>&1)
check "scope-violation-deny: tester write in scoped project → deny" "$OUT" '"action": "deny"'
check "scope-violation-deny: policy_name=write_who" "$OUT" '"policy_name": "write_who"'
check "scope-violation-deny: permissionDecision=deny" "$OUT" '"permissionDecision": "deny"'

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
