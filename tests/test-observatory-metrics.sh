#!/usr/bin/env bash
# test-observatory-metrics.sh — Tests for Observatory v2 analyze.sh
#
# Purpose: Verify the new metrics-based analysis pipeline:
#   - analyze.sh produces metrics.json with correct schema and values
#   - metrics-history.jsonl gets appended with flattened rows
#   - Suggestions generated for compliance rates below threshold
#   - Root cause attribution (agent_fault / agent_crashed / no_trace_dir)
#
# @decision DEC-OBS-V2-TESTS-001
# @title Synthetic trace fixtures for metrics analysis testing
# @status accepted
# @rationale analyze.sh reads from CLAUDE_DIR/traces/index.jsonl and
#   per-trace compliance.json files. Tests create isolated temp directories
#   with synthetic fixtures to verify correctness without touching production
#   data. CLAUDE_DIR is overridden via env var (the standard isolation approach).
#   OBS_DIR is also overridden to keep observatory output in the temp dir.
#
# Usage: bash tests/test-observatory-metrics.sh
# Returns: 0 if all tests pass, 1 if any fail

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ANALYZE_SCRIPT="${WORKTREE_ROOT}/skills/observatory/scripts/analyze.sh"

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

# Create a minimal trace in the fake trace store
# Usage: make_trace <store_dir> <trace_id> [agent_type] [outcome] [branch] [started_at]
make_trace() {
    local store="$1"
    local trace_id="$2"
    local agent="${3:-implementer}"
    local outcome="${4:-success}"
    local branch="${5:-feature/test}"
    local started_at="${6:-2026-02-20T10:00:00Z}"
    local trace_dir="${store}/${trace_id}"
    mkdir -p "${trace_dir}/artifacts"
    cat > "${trace_dir}/manifest.json" <<EOF
{
  "trace_id": "${trace_id}",
  "agent_type": "${agent}",
  "branch": "${branch}",
  "started_at": "${started_at}",
  "outcome": "${outcome}",
  "test_result": "pass"
}
EOF
    echo "${trace_dir}"
}

# Add a line to index.jsonl for a trace
add_to_index() {
    local index_file="$1"
    local trace_id="$2"
    local agent="${3:-implementer}"
    local outcome="${4:-success}"
    local started_at="${5:-2026-02-20T10:00:00Z}"
    cat >> "$index_file" <<EOF
{"trace_id":"${trace_id}","agent_type":"${agent}","branch":"feature/test","started_at":"${started_at}","duration_seconds":120,"outcome":"${outcome}","test_result":"pass","files_changed":3}
EOF
}

# Write a compliance.json for a trace
write_compliance() {
    local trace_dir="$1"
    shift
    # remaining args: "artifact:source" pairs
    local compliance_json="${trace_dir}/artifacts/compliance.json"
    echo "{" > "$compliance_json"
    local first=true
    for pair in "$@"; do
        local artifact="${pair%%:*}"
        local source="${pair#*:}"
        [[ "$first" == "true" ]] && first=false || echo "," >> "$compliance_json"
        printf '  "%s": {"source": "%s", "written_at": "2026-02-20T10:01:00Z"}' \
            "$artifact" "$source" >> "$compliance_json"
    done
    echo "" >> "$compliance_json"
    echo "}" >> "$compliance_json"
}

echo "=== Observatory Metrics Tests (analyze.sh) ==="
echo ""

# ============================================================
# Test 1: Basic metrics.json schema validation
# ============================================================
echo "--- Test 1: metrics.json schema ---"
T1=$(make_tmpdir)
T1_TRACES="${T1}/traces"
T1_OBS="${T1}/observatory"
mkdir -p "$T1_TRACES" "$T1_OBS"
INDEX="${T1_TRACES}/index.jsonl"

# Create 3 implementer traces with compliance data
for i in 1 2 3; do
    td=$(make_trace "$T1_TRACES" "impl-${i}" "implementer" "success")
    add_to_index "$INDEX" "impl-${i}" "implementer" "success"
    # Write summary.md at trace root
    echo "summary" > "${td}/summary.md"
    write_compliance "$td" "summary.md:agent" "test-output.txt:auto" "diff.patch:agent" "files-changed.txt:agent"
done

CLAUDE_DIR="$T1" OBS_DIR="$T1_OBS" STATE_FILE="${T1_OBS}/state.json" \
    bash "$ANALYZE_SCRIPT" > /dev/null 2>&1

if [[ -f "${T1_OBS}/metrics.json" ]]; then
    pass "metrics.json created"
else
    fail "metrics.json not created"
fi

# Validate required top-level keys
for key in generated_at trace_count by_agent_type; do
    val=$(jq -r --arg k "$key" '.[$k] // "MISSING"' "${T1_OBS}/metrics.json" 2>/dev/null)
    if [[ "$val" != "MISSING" && "$val" != "null" ]]; then
        pass "metrics.json has key: $key"
    else
        fail "metrics.json missing key: $key"
    fi
done

# trace_count should be 3
tc=$(jq '.trace_count' "${T1_OBS}/metrics.json" 2>/dev/null)
if [[ "$tc" == "3" ]]; then
    pass "trace_count = 3"
else
    fail "trace_count expected 3, got $tc"
fi

# implementer should be in by_agent_type
has_impl=$(jq '.by_agent_type | has("implementer")' "${T1_OBS}/metrics.json" 2>/dev/null)
if [[ "$has_impl" == "true" ]]; then
    pass "by_agent_type has implementer"
else
    fail "by_agent_type missing implementer"
fi

echo ""

# ============================================================
# Test 2: Compliance rate computation
# ============================================================
echo "--- Test 2: compliance rate computation ---"
T2=$(make_tmpdir)
T2_TRACES="${T2}/traces"
T2_OBS="${T2}/observatory"
mkdir -p "$T2_TRACES" "$T2_OBS"
INDEX2="${T2_TRACES}/index.jsonl"

# 4 tester traces: 2 with summary.md (agent), 2 missing
for i in 1 2; do
    td=$(make_trace "$T2_TRACES" "tester-good-${i}" "tester" "success")
    add_to_index "$INDEX2" "tester-good-${i}" "tester" "success"
    echo "summary" > "${td}/summary.md"
    write_compliance "$td" "summary.md:agent" "test-output.txt:agent"
done
for i in 3 4; do
    td=$(make_trace "$T2_TRACES" "tester-bad-${i}" "tester" "partial")
    add_to_index "$INDEX2" "tester-bad-${i}" "tester" "partial"
    # summary.md exists but no compliance entry for test-output.txt
    echo "summary" > "${td}/summary.md"
    write_compliance "$td" "summary.md:agent"
    # test-output.txt not written — missing
done

CLAUDE_DIR="$T2" OBS_DIR="$T2_OBS" STATE_FILE="${T2_OBS}/state.json" \
    bash "$ANALYZE_SCRIPT" > /dev/null 2>&1

# summary.md rate: 4/4 = 100%
sum_rate=$(jq '.by_agent_type.tester.compliance."summary.md".rate' "${T2_OBS}/metrics.json" 2>/dev/null)
if [[ "$sum_rate" == "1" || "$sum_rate" == "1.0" ]]; then
    pass "tester summary.md compliance rate = 100%"
else
    fail "tester summary.md rate expected 1.0, got $sum_rate"
fi

# test-output.txt: 2 agent + 0 auto + 2 missing → rate = 0.5
tout_rate=$(jq '.by_agent_type.tester.compliance."test-output.txt".rate' "${T2_OBS}/metrics.json" 2>/dev/null)
# rate is (agent+auto)/(agent+auto+missing) = 2/4 = 0.5
if [[ "$tout_rate" == "0.5" ]]; then
    pass "tester test-output.txt compliance rate = 50%"
else
    fail "tester test-output.txt rate expected 0.5, got $tout_rate"
fi

# missing count should be 2
tout_missing=$(jq '.by_agent_type.tester.compliance."test-output.txt".missing' "${T2_OBS}/metrics.json" 2>/dev/null)
if [[ "$tout_missing" == "2" ]]; then
    pass "tester test-output.txt missing = 2"
else
    fail "tester test-output.txt missing expected 2, got $tout_missing"
fi

echo ""

# ============================================================
# Test 3: metrics-history.jsonl appended
# ============================================================
echo "--- Test 3: metrics-history.jsonl appended ---"
T3=$(make_tmpdir)
T3_TRACES="${T3}/traces"
T3_OBS="${T3}/observatory"
mkdir -p "$T3_TRACES" "$T3_OBS"
INDEX3="${T3_TRACES}/index.jsonl"

td=$(make_trace "$T3_TRACES" "impl-hist-1" "implementer" "success")
add_to_index "$INDEX3" "impl-hist-1" "implementer" "success"
echo "summary" > "${td}/summary.md"
write_compliance "$td" "summary.md:agent" "test-output.txt:agent"

# Run analyze twice
CLAUDE_DIR="$T3" OBS_DIR="$T3_OBS" STATE_FILE="${T3_OBS}/state.json" \
    bash "$ANALYZE_SCRIPT" > /dev/null 2>&1
CLAUDE_DIR="$T3" OBS_DIR="$T3_OBS" STATE_FILE="${T3_OBS}/state.json" \
    bash "$ANALYZE_SCRIPT" > /dev/null 2>&1

if [[ -f "${T3_OBS}/metrics-history.jsonl" ]]; then
    pass "metrics-history.jsonl created"
else
    fail "metrics-history.jsonl not created"
fi

# Each run appends rows (one per agent+artifact combo). With 2 runs, at least 2 lines.
line_count=$(wc -l < "${T3_OBS}/metrics-history.jsonl" | tr -d ' ')
if [[ "$line_count" -ge 2 ]]; then
    pass "metrics-history.jsonl has $line_count lines (2+ expected for 2 runs)"
else
    fail "metrics-history.jsonl has $line_count lines, expected >= 2"
fi

# Validate history row schema
row=$(head -1 "${T3_OBS}/metrics-history.jsonl")
for key in ts agent_type artifact rate; do
    val=$(echo "$row" | jq -r --arg k "$key" '.[$k] // "MISSING"' 2>/dev/null)
    if [[ "$val" != "MISSING" && "$val" != "null" ]]; then
        pass "history row has key: $key"
    else
        fail "history row missing key: $key (row: $row)"
    fi
done

echo ""

# ============================================================
# Test 4: Suggestion generation for low compliance rates
# ============================================================
echo "--- Test 4: suggestion generation (rate < 60%) ---"
T4=$(make_tmpdir)
T4_TRACES="${T4}/traces"
T4_OBS="${T4}/observatory"
mkdir -p "$T4_TRACES" "$T4_OBS"
INDEX4="${T4_TRACES}/index.jsonl"

# Create 5 implementer traces where only 2 have test-output.txt (40% = below 60% threshold)
for i in 1 2; do
    td=$(make_trace "$T4_TRACES" "impl-good-${i}" "implementer" "success")
    add_to_index "$INDEX4" "impl-good-${i}" "implementer" "success"
    echo "summary" > "${td}/summary.md"
    write_compliance "$td" "summary.md:agent" "test-output.txt:agent" "diff.patch:agent" "files-changed.txt:agent"
done
for i in 3 4 5; do
    td=$(make_trace "$T4_TRACES" "impl-bad-${i}" "implementer" "partial")
    add_to_index "$INDEX4" "impl-bad-${i}" "implementer" "partial"
    echo "summary" > "${td}/summary.md"
    # Only summary.md written — test-output.txt, diff.patch, files-changed.txt missing
    write_compliance "$td" "summary.md:agent"
done

CLAUDE_DIR="$T4" OBS_DIR="$T4_OBS" STATE_FILE="${T4_OBS}/state.json" \
    bash "$ANALYZE_SCRIPT" > /dev/null 2>&1

# state.json should have suggestions
if [[ -f "${T4_OBS}/state.json" ]]; then
    pass "state.json created"
else
    fail "state.json not created"
fi

sug_count=$(jq '.suggestions | length' "${T4_OBS}/state.json" 2>/dev/null || echo "0")
if [[ "$sug_count" -gt 0 ]]; then
    pass "state.json has $sug_count suggestion(s) for low compliance"
else
    fail "state.json has no suggestions despite low compliance rates"
fi

# Suggestion should have required fields
first_sug=$(jq ''.suggestions[0]'' "${T4_OBS}/state.json" 2>/dev/null || echo "{}")
for field in id metric metric_value_at_suggestion title convergence_check status suggested_at; do
    val=$(echo "$first_sug" | jq -r --arg f "$field" '.[$f] // "MISSING"' 2>/dev/null)
    if [[ "$val" != "MISSING" && "$val" != "null" ]]; then
        pass "suggestion has field: $field = $val"
    else
        fail "suggestion missing field: $field"
    fi
done

# Status should be "proposed"
status=$(echo "$first_sug" | jq -r '.status' 2>/dev/null)
if [[ "$status" == "proposed" ]]; then
    pass "suggestion status = proposed"
else
    fail "suggestion status expected proposed, got $status"
fi

echo ""

# ============================================================
# Test 5: Root cause attribution
# ============================================================
echo "--- Test 5: root cause attribution ---"
T5=$(make_tmpdir)
T5_TRACES="${T5}/traces"
T5_OBS="${T5}/observatory"
mkdir -p "$T5_TRACES" "$T5_OBS"
INDEX5="${T5_TRACES}/index.jsonl"

# tier1: artifacts dir exists, summary.md exists → agent_fault
td_agent=$(make_trace "$T5_TRACES" "impl-agentfault" "implementer" "success")
add_to_index "$INDEX5" "impl-agentfault" "implementer" "success"
echo "summary" > "${td_agent}/summary.md"
write_compliance "$td_agent" "summary.md:agent"
# test-output.txt NOT written (agent_fault)

# tier2: artifacts dir exists, no summary.md → agent_crashed
td_crash=$(make_trace "$T5_TRACES" "impl-crashed" "implementer" "partial")
add_to_index "$INDEX5" "impl-crashed" "implementer" "partial"
# summary.md NOT written (crashed)

# tier3: no artifacts dir at all → no_trace_dir
td_notrace="${T5_TRACES}/impl-notrace"
mkdir -p "$td_notrace"
# No artifacts dir, no summary.md
cat > "${td_notrace}/manifest.json" <<'EOF'
{"trace_id":"impl-notrace","agent_type":"implementer","outcome":"crashed"}
EOF
add_to_index "$INDEX5" "impl-notrace" "implementer" "crashed"
# Remove the artifacts dir that make_trace created (it wasn't called here — already correct)

CLAUDE_DIR="$T5" OBS_DIR="$T5_OBS" STATE_FILE="${T5_OBS}/state.json" \
    bash "$ANALYZE_SCRIPT" > /dev/null 2>&1

# Root causes should appear in compliance data
root_causes=$(jq '
  .by_agent_type.implementer.compliance["test-output.txt"].root_causes // {}
' "${T5_OBS}/metrics.json" 2>/dev/null || echo "{}")

# We expect: agent_fault (1) + agent_crashed (1) + no_trace_dir (1)
agent_fault_count=$(echo "$root_causes" | jq '.agent_fault // 0' 2>/dev/null || echo "0")
agent_crashed_count=$(echo "$root_causes" | jq '.agent_crashed // 0' 2>/dev/null || echo "0")
no_trace_count=$(echo "$root_causes" | jq '.no_trace_dir // 0' 2>/dev/null || echo "0")

if [[ "$agent_fault_count" -ge 1 ]]; then
    pass "root cause: agent_fault detected ($agent_fault_count)"
else
    fail "root cause: agent_fault not detected (got: $root_causes)"
fi

if [[ "$agent_crashed_count" -ge 1 ]]; then
    pass "root cause: agent_crashed detected ($agent_crashed_count)"
else
    fail "root cause: agent_crashed not detected (got: $root_causes)"
fi

if [[ "$no_trace_count" -ge 1 ]]; then
    pass "root cause: no_trace_dir detected ($no_trace_count)"
else
    fail "root cause: no_trace_dir not detected (got: $root_causes)"
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
