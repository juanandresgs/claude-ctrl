#!/usr/bin/env bash
# test-workflow-bind-roundtrip.sh: verifies cc-policy workflow bind + get roundtrip.
#
# Production sequence: orchestrator dispatches implementer → subagent-start.sh
# calls rt_workflow_bind → cc-policy workflow bind writes to SQLite → later
# hooks and roles call cc-policy workflow get to look up the binding.
#
# @decision DEC-SMOKE-WF-001
# @title Workflow bind/get roundtrip verifies all required fields survive persistence
# @status accepted
# @rationale The bind→get roundtrip is the atomic unit of the workflow binding
#   mechanism. If any field is lost (ticket, initiative, branch, worktree_path)
#   downstream consumers get stale identity data. This test confirms the full
#   persistence cycle for all optional and required fields.
set -euo pipefail

TEST_NAME="test-workflow-bind-roundtrip"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME_ROOT="$REPO_ROOT/runtime"
TMP_DIR="$REPO_ROOT/tmp/$TEST_NAME-$$"
TEST_DB="$TMP_DIR/.claude/state.db"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/.claude"

# Provision schema
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" schema ensure >/dev/null 2>&1

# Bind workflow with all optional fields
CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" \
    workflow bind "test-wf" "/tmp/test-wt" "feature/test" \
    --ticket TKT-TEST --initiative INIT-TEST >/dev/null 2>&1
expected_wt_path=$(python3 -c 'import os; print(os.path.realpath("/tmp/test-wt"))')

# Get the binding and verify all fields
result=$(CLAUDE_POLICY_DB="$TEST_DB" python3 "$RUNTIME_ROOT/cli.py" workflow get "test-wf" 2>&1)

# Verify each field
wf_id=$(printf '%s' "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('workflow_id',''))")
wt_path=$(printf '%s' "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('worktree_path',''))")
branch=$(printf '%s' "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('branch',''))")
ticket=$(printf '%s' "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ticket',''))")
initiative=$(printf '%s' "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('initiative',''))")
found=$(printf '%s' "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('found',''))")

fail=0

[[ "$found" == "True" ]] || { echo "FAIL: $TEST_NAME — found=$found expected True"; fail=1; }
[[ "$wf_id" == "test-wf" ]] || { echo "FAIL: $TEST_NAME — workflow_id='$wf_id' expected 'test-wf'"; fail=1; }
[[ "$wt_path" == "$expected_wt_path" ]] || { echo "FAIL: $TEST_NAME — worktree_path='$wt_path' expected '$expected_wt_path'"; fail=1; }
[[ "$branch" == "feature/test" ]] || { echo "FAIL: $TEST_NAME — branch='$branch' expected 'feature/test'"; fail=1; }
[[ "$ticket" == "TKT-TEST" ]] || { echo "FAIL: $TEST_NAME — ticket='$ticket' expected 'TKT-TEST'"; fail=1; }
[[ "$initiative" == "INIT-TEST" ]] || { echo "FAIL: $TEST_NAME — initiative='$initiative' expected 'INIT-TEST'"; fail=1; }

[[ "$fail" -eq 0 ]] || exit 1

echo "PASS: $TEST_NAME"
exit 0
