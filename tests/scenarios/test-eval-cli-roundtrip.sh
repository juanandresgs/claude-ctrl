#!/usr/bin/env bash
# tests/scenarios/test-eval-cli-roundtrip.sh
#
# End-to-end integration test for the cc-policy eval subcommand group.
# Exercises the full production sequence: list → run → report → report --json
#
# Sequence:
#   1. eval list         — verify it returns a JSON array of scenarios
#   2. eval run --category gate — run gate scenarios, capture run_id
#   3. eval report --run-id <id> — verify report is non-empty and multi-section
#   4. eval report --run-id <id> --json — verify valid JSON with expected keys
#   5. eval score --run-id <id> — verify re-score returns JSON with rescored count
#
# Pattern: same as test-policy-engine-smoke.sh and test-eval-gate-scenarios.sh
# The CLI is invoked as:
#   PYTHONPATH="$REPO_ROOT" python3 "$REPO_ROOT/runtime/cli.py" eval <subcommand>
#
# Exit code: 0 = all checks passed, non-zero = at least one failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI="$REPO_ROOT/runtime/cli.py"

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
# Step 1: eval list — must return JSON array with known scenario names
# -----------------------------------------------------------------------
echo "--- Step 1: eval list ---"

LIST_OUT=$(PYTHONPATH="$REPO_ROOT" python3 "$CLI" eval list 2>&1)
check "eval list: status=ok"           "$LIST_OUT" '"status": "ok"'
check "eval list: items array present" "$LIST_OUT" '"items"'
check "eval list: count > 0"           "$LIST_OUT" '"count"'
check "eval list: write-who-deny present" "$LIST_OUT" 'write-who-deny'
check "eval list: gate category present"  "$LIST_OUT" '"gate"'

# -----------------------------------------------------------------------
# Step 2: eval run --category gate — run gate scenarios, capture run_id
# -----------------------------------------------------------------------
echo "--- Step 2: eval run --category gate ---"

RUN_OUT=$(PYTHONPATH="$REPO_ROOT" python3 "$CLI" eval run --category gate 2>&1)
check "eval run: status=ok"              "$RUN_OUT" '"status": "ok"'
check "eval run: run_id present"         "$RUN_OUT" '"run_id"'
check "eval run: scenario_count present" "$RUN_OUT" '"scenario_count"'
check "eval run: pass_count present"     "$RUN_OUT" '"pass_count"'
check "eval run: mode=deterministic"     "$RUN_OUT" '"mode": "deterministic"'

# Extract run_id from JSON output using python3 (no jq dependency)
RUN_ID=$(echo "$RUN_OUT" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['run_id'])")
if [ -z "$RUN_ID" ]; then
    echo "FAIL: could not extract run_id from eval run output"
    ((FAIL++)) || true
else
    echo "PASS: run_id extracted: $RUN_ID"
    ((PASS++)) || true
fi

# -----------------------------------------------------------------------
# Step 3: eval report --run-id <id> — verify text report is non-empty
# -----------------------------------------------------------------------
echo "--- Step 3: eval report --run-id (text) ---"

REPORT_OUT=$(PYTHONPATH="$REPO_ROOT" python3 "$CLI" eval report --run-id "$RUN_ID" 2>&1)
check "eval report: contains EVAL RUN REPORT header" "$REPORT_OUT" 'EVAL RUN REPORT'
check "eval report: contains run_id"                 "$REPORT_OUT" "$RUN_ID"
check "eval report: contains Category Breakdown"     "$REPORT_OUT" 'Category Breakdown'
check "eval report: contains Scenario Details"       "$REPORT_OUT" 'Scenario Details'
check "eval report: contains gate category"          "$REPORT_OUT" 'gate'
check "eval report: contains PASS or FAIL verdict"   "$REPORT_OUT" 'PASS\|FAIL'

# Verify report is multi-line (at least 10 lines)
LINE_COUNT=$(echo "$REPORT_OUT" | wc -l | tr -d ' ')
if [ "$LINE_COUNT" -ge 10 ]; then
    echo "PASS: eval report has $LINE_COUNT lines (>= 10)"
    ((PASS++)) || true
else
    echo "FAIL: eval report has only $LINE_COUNT lines (expected >= 10)"
    ((FAIL++)) || true
fi

# -----------------------------------------------------------------------
# Step 4: eval report --json — verify valid JSON with expected keys
# -----------------------------------------------------------------------
echo "--- Step 4: eval report --run-id --json ---"

JSON_OUT=$(PYTHONPATH="$REPO_ROOT" python3 "$CLI" eval report --run-id "$RUN_ID" --json 2>&1)
check "eval report --json: status=ok"              "$JSON_OUT" '"status": "ok"'
check "eval report --json: run_id present"         "$JSON_OUT" '"run_id"'
check "eval report --json: mode present"           "$JSON_OUT" '"mode"'
check "eval report --json: scenario_count present" "$JSON_OUT" '"scenario_count"'
check "eval report --json: pass_count present"     "$JSON_OUT" '"pass_count"'
check "eval report --json: category_breakdown key" "$JSON_OUT" '"category_breakdown"'
check "eval report --json: scores key"             "$JSON_OUT" '"scores"'
check "eval report --json: gate in breakdown"      "$JSON_OUT" '"gate"'

# Verify it's parseable JSON
if echo "$JSON_OUT" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null; then
    echo "PASS: eval report --json output is valid JSON"
    ((PASS++)) || true
else
    echo "FAIL: eval report --json output is not valid JSON"
    ((FAIL++)) || true
fi

# -----------------------------------------------------------------------
# Step 5: eval score --run-id <id> — verify re-score returns JSON
# -----------------------------------------------------------------------
echo "--- Step 5: eval score --run-id ---"

SCORE_OUT=$(PYTHONPATH="$REPO_ROOT" python3 "$CLI" eval score --run-id "$RUN_ID" 2>&1)
check "eval score: status=ok"              "$SCORE_OUT" '"status": "ok"'
check "eval score: run_id present"         "$SCORE_OUT" '"run_id"'
check "eval score: rescored > 0"           "$SCORE_OUT" '"rescored"'
check "eval score: scenario_count present" "$SCORE_OUT" '"scenario_count"'

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
