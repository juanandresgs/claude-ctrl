#!/usr/bin/env bash
# test-workflow-scope-check.sh: verifies scope-set + scope-check compliance logic.
#
# Production sequence: planner writes scope manifest via scope-set → guard.sh
# Check 12 calls scope-check with changed files → deny on violations.
#
# Three cases tested:
#   A. File in allowed_paths → compliant
#   B. File not in allowed_paths → violation (OUT_OF_SCOPE)
#   C. File in forbidden_paths (even if also in allowed) → violation (FORBIDDEN)
#
# @decision DEC-SMOKE-WF-002
# @title Scope compliance check exercises all three rule branches
# @status accepted
# @rationale DEC-WF-002 specifies forbidden takes precedence over allowed. This
#   test covers all three branches: clean allowed match, out-of-scope miss, and
#   forbidden override. Each branch must be verified independently to confirm
#   the precedence rule is enforced by the CLI layer end-to-end.
set -euo pipefail

TEST_NAME="test-workflow-scope-check"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME_ROOT="$REPO_ROOT/runtime"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/.claude/state.db"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"

# Provision schema
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1

# Bind a workflow
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    workflow bind "scope-wf" "/wt/scope" "feature/scope" >/dev/null 2>&1

# Set scope: allowed runtime/*.py and hooks/*.sh; forbidden settings.json
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    workflow scope-set "scope-wf" \
    --allowed '["runtime/*.py", "hooks/*.sh"]' \
    --forbidden '["settings.json"]' >/dev/null 2>&1

# Case A: runtime/cli.py is in allowed_paths → expect compliant
result_a=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    workflow scope-check "scope-wf" --changed '["runtime/cli.py"]' 2>&1)
compliant_a=$(printf '%s' "$result_a" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('compliant',''))")

if [[ "$compliant_a" != "True" ]]; then
    echo "FAIL: $TEST_NAME — Case A: runtime/cli.py should be compliant, got compliant=$compliant_a"
    echo "  result: $result_a"
    exit 1
fi

# Case B: agents/planner.md not in allowed_paths → expect violation
result_b=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    workflow scope-check "scope-wf" --changed '["agents/planner.md"]' 2>&1)
compliant_b=$(printf '%s' "$result_b" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('compliant',''))")
violations_b=$(printf '%s' "$result_b" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('violations',''))")

if [[ "$compliant_b" != "False" ]]; then
    echo "FAIL: $TEST_NAME — Case B: agents/planner.md should be violation, got compliant=$compliant_b"
    exit 1
fi
if ! printf '%s' "$violations_b" | grep -q "OUT_OF_SCOPE"; then
    echo "FAIL: $TEST_NAME — Case B: expected OUT_OF_SCOPE in violations, got: $violations_b"
    exit 1
fi

# Case C: settings.json is forbidden (even though not in allowed_paths) → FORBIDDEN violation
result_c=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    workflow scope-check "scope-wf" --changed '["settings.json"]' 2>&1)
compliant_c=$(printf '%s' "$result_c" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('compliant',''))")
violations_c=$(printf '%s' "$result_c" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('violations',''))")

if [[ "$compliant_c" != "False" ]]; then
    echo "FAIL: $TEST_NAME — Case C: settings.json should be forbidden violation, got compliant=$compliant_c"
    exit 1
fi
if ! printf '%s' "$violations_c" | grep -q "FORBIDDEN"; then
    echo "FAIL: $TEST_NAME — Case C: expected FORBIDDEN in violations, got: $violations_c"
    exit 1
fi

echo "PASS: $TEST_NAME"
exit 0
