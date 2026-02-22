#!/usr/bin/env bash
# test-observatory-convergence.sh — Tests for Observatory v2 converge.sh
#
# Purpose: Verify convergence analysis pipeline:
#   - Trend detection: improving / flat / degrading classification
#   - Slope computation over a sliding window
#   - Ineffective fix detection (no improvement after 2 runs)
#   - state.json updated when convergence is detected
#
# @decision DEC-OBS-V2-TESTS-002
# @title Synthetic metrics-history.jsonl for convergence testing
# @status accepted
# @rationale converge.sh reads metrics-history.jsonl and state.json. Tests
#   create synthetic history data with known slopes to verify that the
#   improving/flat/degrading classification and ineffective-fix detection
#   work correctly. OBS_DIR is overridden via env to isolate test output
#   from production data.
#
# Usage: bash tests/test-observatory-convergence.sh
# Returns: 0 if all tests pass, 1 if any fail

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONVERGE_SCRIPT="${WORKTREE_ROOT}/skills/observatory/scripts/converge.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

CLEANUP_DIRS=()
cleanup_all() {
    local d
    for d in "${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap cleanup_all EXIT

make_tmpdir() {
    local d
    d=$(mktemp -d)
    CLEANUP_DIRS+=("$d")
    echo "$d"
}

# Write a metrics-history.jsonl with controlled data points
# Usage: write_history <file> <agent_type> <artifact> <rates...>
# Creates one row per rate, with sequential timestamps
write_history() {
    local file="$1"
    local agent_type="$2"
    local artifact="$3"
    shift 3
    local i=0
    for rate in "$@"; do
        local ts
        ts=$(printf "2026-02-2%dT10:00:00Z" $i 2>/dev/null || echo "2026-02-20T10:0${i}:00Z")
        # Simple sequential timestamps: day offset
        ts="2026-02-$(printf '%02d' $((20 + i)))T10:00:00Z"
        jq -cn \
            --arg ts "$ts" \
            --arg agent "$agent_type" \
            --arg artifact "$artifact" \
            --argjson rate "$rate" \
            '{ts: $ts, agent_type: $agent, artifact: $artifact, rate: $rate, count: 5}' \
            >> "$file"
        i=$((i + 1))
    done
}

echo "=== Observatory Convergence Tests (converge.sh) ==="
echo ""

# ============================================================
# Test 1: Improving trend detection
# ============================================================
echo "--- Test 1: improving trend (rates going up) ---"
T1=$(make_tmpdir)
T1_OBS="${T1}/observatory"
mkdir -p "$T1_OBS"
HISTORY1="${T1_OBS}/metrics-history.jsonl"

# Rates increasing: 0.20 → 0.30 → 0.45 → 0.55 → 0.70
# Slope = (0.70 - 0.20) / 5 = 0.10 > 0.05 → improving
write_history "$HISTORY1" "implementer" "test-output.txt" 0.20 0.30 0.45 0.55 0.70

CONV=$(OBS_DIR="$T1_OBS" bash "$CONVERGE_SCRIPT" 2>/dev/null)
trend=$(echo "$CONV" | jq -r '.convergence[0].trend' 2>/dev/null || echo "error")
current=$(echo "$CONV" | jq -r '.convergence[0].current_rate' 2>/dev/null || echo "error")

if [[ "$trend" == "improving" ]]; then
    pass "improving trend detected (rates 20→70%)"
else
    fail "improving trend not detected, got: $trend"
fi

# jq may emit 0.7 or 0.70 depending on version — compare numerically
current_ok=$(echo "$current" | jq -r 'tonumber | . == 0.7' 2>/dev/null || echo "false")
if [[ "$current_ok" == "true" ]]; then
    pass "current_rate = 0.70"
else
    fail "current_rate expected 0.70, got $current"
fi

# Arrow in output
data_points=$(echo "$CONV" | jq '.convergence[0].data_points' 2>/dev/null || echo "0")
if [[ "$data_points" -ge 5 ]]; then
    pass "data_points = $data_points"
else
    fail "data_points expected 5, got $data_points"
fi

echo ""

# ============================================================
# Test 2: Degrading trend detection
# ============================================================
echo "--- Test 2: degrading trend (rates going down) ---"
T2=$(make_tmpdir)
T2_OBS="${T2}/observatory"
mkdir -p "$T2_OBS"
HISTORY2="${T2_OBS}/metrics-history.jsonl"

# Rates decreasing: 0.80 → 0.70 → 0.55 → 0.40 → 0.30
# Slope = (0.30 - 0.80) / 5 = -0.10 < -0.05 → degrading
write_history "$HISTORY2" "tester" "summary.md" 0.80 0.70 0.55 0.40 0.30

CONV2=$(OBS_DIR="$T2_OBS" bash "$CONVERGE_SCRIPT" 2>/dev/null)
trend2=$(echo "$CONV2" | jq -r '.convergence[0].trend' 2>/dev/null || echo "error")

if [[ "$trend2" == "degrading" ]]; then
    pass "degrading trend detected (rates 80→30%)"
else
    fail "degrading trend not detected, got: $trend2"
fi

echo ""

# ============================================================
# Test 3: Flat trend detection
# ============================================================
echo "--- Test 3: flat trend (rates stable) ---"
T3=$(make_tmpdir)
T3_OBS="${T3}/observatory"
mkdir -p "$T3_OBS"
HISTORY3="${T3_OBS}/metrics-history.jsonl"

# Rates flat: 0.50 → 0.51 → 0.49 → 0.50 → 0.51
# Slope ≈ (0.51 - 0.50) / 5 = 0.002 → flat (< 0.05 threshold)
write_history "$HISTORY3" "guardian" "diff.patch" 0.50 0.51 0.49 0.50 0.51

CONV3=$(OBS_DIR="$T3_OBS" bash "$CONVERGE_SCRIPT" 2>/dev/null)
trend3=$(echo "$CONV3" | jq -r '.convergence[0].trend' 2>/dev/null || echo "error")

if [[ "$trend3" == "flat" ]]; then
    pass "flat trend detected (rates ~50%)"
else
    fail "flat trend not detected, got: $trend3"
fi

echo ""

# ============================================================
# Test 4: Insufficient data (< 2 points)
# ============================================================
echo "--- Test 4: insufficient data (1 point) ---"
T4=$(make_tmpdir)
T4_OBS="${T4}/observatory"
mkdir -p "$T4_OBS"
HISTORY4="${T4_OBS}/metrics-history.jsonl"

write_history "$HISTORY4" "planner" "summary.md" 0.75

CONV4=$(OBS_DIR="$T4_OBS" bash "$CONVERGE_SCRIPT" 2>/dev/null)
trend4=$(echo "$CONV4" | jq -r '.convergence[0].trend' 2>/dev/null || echo "error")

if [[ "$trend4" == "insufficient_data" ]]; then
    pass "insufficient_data detected for 1-point history"
else
    fail "expected insufficient_data, got: $trend4"
fi

echo ""

# ============================================================
# Test 5: Empty history returns valid empty output
# ============================================================
echo "--- Test 5: empty history returns valid JSON ---"
T5=$(make_tmpdir)
T5_OBS="${T5}/observatory"
mkdir -p "$T5_OBS"
# No history file

CONV5=$(OBS_DIR="$T5_OBS" bash "$CONVERGE_SCRIPT" 2>/dev/null)
if echo "$CONV5" | jq -e '.convergence' > /dev/null 2>&1; then
    pass "empty history returns valid JSON with convergence key"
else
    fail "empty history output is not valid JSON or missing convergence key"
fi

conv_arr=$(echo "$CONV5" | jq '.convergence | length' 2>/dev/null || echo "-1")
if [[ "$conv_arr" == "0" ]]; then
    pass "convergence array is empty when no history"
else
    fail "convergence array expected empty, got length $conv_arr"
fi

echo ""

# ============================================================
# Test 6: Ineffective fix detection
# ============================================================
echo "--- Test 6: ineffective fix detection ---"
T6=$(make_tmpdir)
T6_OBS="${T6}/observatory"
mkdir -p "$T6_OBS"
HISTORY6="${T6_OBS}/metrics-history.jsonl"
STATE6="${T6_OBS}/state.json"

# Create history: low rates before impl, still low after impl
# impl date: 2026-02-22T10:00:00Z
# Pre-impl runs: 2026-02-20, 2026-02-21 (rate ~0.30)
# Post-impl runs: 2026-02-23, 2026-02-24 (rate ~0.35 — not improved by 0.10)
jq -cn '{ts:"2026-02-20T10:00:00Z",agent_type:"implementer",artifact:"test-output.txt",rate:0.30,count:5}' >> "$HISTORY6"
jq -cn '{ts:"2026-02-21T10:00:00Z",agent_type:"implementer",artifact:"test-output.txt",rate:0.32,count:5}' >> "$HISTORY6"
jq -cn '{ts:"2026-02-23T10:00:00Z",agent_type:"implementer",artifact:"test-output.txt",rate:0.33,count:5}' >> "$HISTORY6"
jq -cn '{ts:"2026-02-24T10:00:00Z",agent_type:"implementer",artifact:"test-output.txt",rate:0.35,count:5}' >> "$HISTORY6"

# Create state.json with an implemented suggestion for this metric
cat > "$STATE6" <<'EOF'
{
  "version": 4,
  "last_analysis_at": "2026-02-21T10:00:00Z",
  "suggestions": [
    {
      "id": "SUG-001",
      "metric": "compliance.implementer.test-output.txt.rate",
      "metric_value_at_suggestion": 0.30,
      "title": "Improve implementer test-output.txt compliance",
      "convergence_check": "implementer.test-output.txt.compliance.rate > 0.60",
      "status": "implemented",
      "suggested_at": "2026-02-19T10:00:00Z",
      "implemented_at": "2026-02-22T10:00:00Z",
      "converged_at": null
    }
  ]
}
EOF

CONV6=$(OBS_DIR="$T6_OBS" STATE_FILE="$STATE6" bash "$CONVERGE_SCRIPT" 2>/dev/null)

ineff=$(echo "$CONV6" | jq '.ineffective_fixes | length' 2>/dev/null || echo "0")
if [[ "$ineff" -gt 0 ]]; then
    pass "ineffective fix detected (no improvement after 2 post-impl runs)"
else
    fail "ineffective fix not detected (expected 1, got $ineff)"
fi

# Verify the fix details
ineff_id=$(echo "$CONV6" | jq -r '.ineffective_fixes[0].id // "none"' 2>/dev/null)
if [[ "$ineff_id" == "SUG-001" ]]; then
    pass "ineffective fix ID = SUG-001"
else
    fail "ineffective fix ID expected SUG-001, got $ineff_id"
fi

ineff_verdict=$(echo "$CONV6" | jq -r '.ineffective_fixes[0].verdict // "none"' 2>/dev/null)
if [[ "$ineff_verdict" == "ineffective" ]]; then
    pass "ineffective fix verdict = ineffective"
else
    fail "ineffective fix verdict expected 'ineffective', got $ineff_verdict"
fi

# State.json should be updated with status = "ineffective"
updated_status=$(jq -r '.suggestions[0].status' "$STATE6" 2>/dev/null || echo "unknown")
if [[ "$updated_status" == "ineffective" ]]; then
    pass "state.json updated: SUG-001 status = ineffective"
else
    fail "state.json not updated: status expected 'ineffective', got $updated_status"
fi

echo ""

# ============================================================
# Test 7: Window parameter limits history
# ============================================================
echo "--- Test 7: window parameter limits history ---"
T7=$(make_tmpdir)
T7_OBS="${T7}/observatory"
mkdir -p "$T7_OBS"
HISTORY7="${T7_OBS}/metrics-history.jsonl"

# Write 10 data points (0.10 through 1.00, improving)
for i in 1 2 3 4 5 6 7 8 9 10; do
    rate="0.$(printf '%02d' $((i * 10)))"
    [[ "$i" -eq 10 ]] && rate="1.0"
    ts="2026-02-$(printf '%02d' $((10 + i)))T10:00:00Z"
    jq -cn --arg ts "$ts" --arg rate "$rate" \
        '{ts:$ts,agent_type:"guardian",artifact:"summary.md",rate:($rate|tonumber),count:3}' \
        >> "$HISTORY7"
done

# With window=3, should only use last 3 points: 0.80, 0.90, 1.00
CONV7=$(OBS_DIR="$T7_OBS" bash "$CONVERGE_SCRIPT" --window 3 2>/dev/null)
dp=$(echo "$CONV7" | jq '.convergence[0].data_points' 2>/dev/null || echo "0")
if [[ "$dp" -eq 3 ]]; then
    pass "window=3 limits data_points to 3"
else
    fail "window=3: expected 3 data_points, got $dp"
fi

echo ""

# ============================================================
# Summary
# ============================================================
TOTAL=$((PASS + FAIL))
echo "==========================="
echo "Results: $PASS/$TOTAL passed"
[[ "$FAIL" -gt 0 ]] && echo "FAILURES: $FAIL" && exit 1
echo "ALL PASSED"
exit 0
