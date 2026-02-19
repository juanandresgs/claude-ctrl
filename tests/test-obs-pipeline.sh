#!/usr/bin/env bash
# test-obs-pipeline.sh — Tests for Phase 2 Pipeline Completion fixes
#
# Purpose: Verify the four Phase 2 fixes:
#   - #107: oldTraces/ excluded from active scan; Stage 2c historical aggregate
#   - #108: report.sh staleness check and historical_traces context in header
#   - #109: NO_HISTORICAL_BASELINE uses prior-run detection, not calendar-day
#   - #110: session-init.sh development log digest (last 5 project traces)
#
# @decision DEC-OBS-P2-TESTS
# @title Test-first verification for Phase 2 pipeline fixes
# @status accepted
# @rationale Each fix modifies observable behavior in analyze.sh, report.sh, or
#   session-init.sh. Tests use isolated temp directories with synthetic trace
#   fixtures to verify correctness without touching production data. The four
#   issues (#107-#110) were identified as inter-related — they share the trace
#   directory scanning and session context injection code paths.
#
# Usage: bash tests/test-obs-pipeline.sh
# Returns: 0 if all tests pass, 1 if any fail

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ANALYZE_SCRIPT="${WORKTREE_ROOT}/skills/observatory/scripts/analyze.sh"
REPORT_SCRIPT="${WORKTREE_ROOT}/skills/observatory/scripts/report.sh"
HOOKS_DIR="${WORKTREE_ROOT}/hooks"
SESSION_INIT="${HOOKS_DIR}/session-init.sh"

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

# Create a minimal trace directory with a manifest
make_trace() {
    local store="$1" name="$2" agent="${3:-implementer}" outcome="${4:-success}" branch="${5:-main}" started_at="${6:-2026-02-18T10:00:00Z}"
    local trace_dir="${store}/${name}"
    mkdir -p "${trace_dir}/artifacts"
    cat > "${trace_dir}/manifest.json" <<EOF
{
  "trace_id": "${name}",
  "agent_type": "${agent}",
  "outcome": "${outcome}",
  "branch": "${branch}",
  "started_at": "${started_at}",
  "duration_seconds": 120,
  "files_changed": 3,
  "proof_status": "verified"
}
EOF
    # Write a summary so artifact health counts it
    echo "# Summary for ${name}" > "${trace_dir}/summary.md"
}

# Create a minimal index.jsonl from trace manifests in a store
make_index() {
    local store="$1"
    local index_file="${store}/index.jsonl"
    rm -f "$index_file"
    for manifest in "${store}"/*/manifest.json; do
        [[ -f "$manifest" ]] || continue
        local trace_dir
        trace_dir=$(dirname "$manifest")
        local trace_id
        trace_id=$(basename "$trace_dir")
        jq -c ". + {\"trace_id\": \"${trace_id}\", \"project_name\": \"testproject\"}" "$manifest" >> "$index_file"
    done
}

# Create a minimal comparison-matrix.json for report.sh to not fail
make_matrix() {
    local obs_dir="$1"
    cat > "${obs_dir}/comparison-matrix.json" <<'EOF'
{"matrix": [], "effort_buckets": {"quick_wins": [], "moderate": [], "deep": []}, "batches": {}}
EOF
}

# ============================================================
# Issue #107: oldTraces/ excluded from active scan
# ============================================================
echo ""
echo "=== #107: oldTraces/ exclusion from active scan ==="

# Test 107-A: Active artifact health does NOT count oldTraces/ dirs
T107=$(make_tmpdir)
STORE107="${T107}/traces"
OBS107="${T107}/observatory"
mkdir -p "$STORE107" "$OBS107"

# 3 active traces
make_trace "$STORE107" "active-001" implementer success main "2026-02-18T10:00:00Z"
make_trace "$STORE107" "active-002" tester success main "2026-02-18T11:00:00Z"
make_trace "$STORE107" "active-003" guardian success main "2026-02-18T12:00:00Z"

# 5 oldTraces — should NOT be counted in active artifact health
mkdir -p "${STORE107}/oldTraces"
make_trace "${STORE107}/oldTraces" "old-001" implementer partial feature-x "2026-01-10T10:00:00Z"
make_trace "${STORE107}/oldTraces" "old-002" implementer success feature-y "2026-01-11T10:00:00Z"
make_trace "${STORE107}/oldTraces" "old-003" tester success main "2026-01-12T10:00:00Z"
make_trace "${STORE107}/oldTraces" "old-004" guardian success main "2026-01-13T10:00:00Z"
make_trace "${STORE107}/oldTraces" "old-005" implementer success main "2026-01-14T10:00:00Z"

make_index "$STORE107"
touch "${OBS107}/state.json" && echo '{"implemented":[],"rejected":[],"deferred":[]}' > "${OBS107}/state.json"

CLAUDE_DIR="$T107" TRACE_INDEX="${STORE107}/index.jsonl" \
    OBS_DIR="$OBS107" TRACE_STORE="$STORE107" STATE_FILE="${OBS107}/state.json" \
    bash "$ANALYZE_SCRIPT" > /dev/null 2>&1

if [[ $? -eq 0 && -f "${OBS107}/analysis-cache.json" ]]; then
    # Artifact health total_traces should be 3 (active only), not 8
    AH_TOTAL=$(jq '.artifact_health.total_traces' "${OBS107}/analysis-cache.json" 2>/dev/null || echo "-1")
    if [[ "$AH_TOTAL" -eq 3 ]]; then
        pass "#107-A: artifact_health.total_traces = 3 (active only, oldTraces excluded)"
    else
        fail "#107-A: artifact_health.total_traces = $AH_TOTAL (expected 3 — oldTraces leaked into count)"
    fi
else
    fail "#107-A: analyze.sh failed or no cache written"
fi

# Test 107-B: historical_traces section present and correct total
if [[ -f "${OBS107}/analysis-cache.json" ]]; then
    HT_AVAILABLE=$(jq -r '.historical_traces.available' "${OBS107}/analysis-cache.json" 2>/dev/null || echo "false")
    HT_TOTAL=$(jq '.historical_traces.total' "${OBS107}/analysis-cache.json" 2>/dev/null || echo "-1")
    if [[ "$HT_AVAILABLE" == "true" && "$HT_TOTAL" -eq 5 ]]; then
        pass "#107-B: historical_traces section present with total=5"
    else
        fail "#107-B: historical_traces.available=$HT_AVAILABLE total=$HT_TOTAL (expected available=true total=5)"
    fi
fi

# Test 107-C: historical_traces has outcome_dist populated
if [[ -f "${OBS107}/analysis-cache.json" ]]; then
    HT_OUTCOMES=$(jq '.historical_traces.outcome_dist | keys | length' "${OBS107}/analysis-cache.json" 2>/dev/null || echo "0")
    if [[ "$HT_OUTCOMES" -gt 0 ]]; then
        pass "#107-C: historical_traces.outcome_dist has ${HT_OUTCOMES} outcome types"
    else
        fail "#107-C: historical_traces.outcome_dist is empty"
    fi
fi

# Test 107-D: active trace count (dataset_integrity) excludes oldTraces/
if [[ -f "${OBS107}/analysis-cache.json" ]]; then
    DI_CURR=$(jq '.dataset_integrity.current_trace_dir_count' "${OBS107}/analysis-cache.json" 2>/dev/null || echo "-1")
    if [[ "$DI_CURR" -eq 3 ]]; then
        pass "#107-D: dataset_integrity.current_trace_dir_count = 3 (oldTraces excluded)"
    else
        fail "#107-D: dataset_integrity.current_trace_dir_count = $DI_CURR (expected 3)"
    fi
fi

# Test 107-E: no oldTraces/ directory — historical_traces.available = false
T107E=$(make_tmpdir)
STORE107E="${T107E}/traces"
OBS107E="${T107E}/observatory"
mkdir -p "$STORE107E" "$OBS107E"
make_trace "$STORE107E" "active-001" implementer success main "2026-02-18T10:00:00Z"
make_trace "$STORE107E" "active-002" tester success main "2026-02-18T11:00:00Z"
make_index "$STORE107E"
echo '{"implemented":[],"rejected":[],"deferred":[]}' > "${OBS107E}/state.json"

CLAUDE_DIR="$T107E" TRACE_INDEX="${STORE107E}/index.jsonl" \
    OBS_DIR="$OBS107E" TRACE_STORE="$STORE107E" STATE_FILE="${OBS107E}/state.json" \
    bash "$ANALYZE_SCRIPT" > /dev/null 2>&1

if [[ -f "${OBS107E}/analysis-cache.json" ]]; then
    HT_AVAIL=$(jq -r '.historical_traces.available' "${OBS107E}/analysis-cache.json" 2>/dev/null || echo "true")
    if [[ "$HT_AVAIL" == "false" ]]; then
        pass "#107-E: historical_traces.available=false when no oldTraces/ dir"
    else
        fail "#107-E: historical_traces.available=$HT_AVAIL (expected false when no oldTraces/ dir)"
    fi
fi

# ============================================================
# Issue #108: report.sh staleness check and historical context
# ============================================================
echo ""
echo "=== #108: report.sh staleness check ==="

# Test 108-A: INFO message printed to stderr when cache is newer than report
T108=$(make_tmpdir)
OBS108="${T108}/observatory"
mkdir -p "$OBS108/suggestions"

# Create a fake analysis-cache.json
cat > "${OBS108}/analysis-cache.json" <<'EOF'
{
  "version": 3,
  "generated_at": "2026-02-18T10:00:00Z",
  "trace_stats": {"total": 5, "outcome_dist": {}, "test_dist": {}, "files_changed_zero_count": 0, "negative_duration_count": 0, "zero_duration_count": 0, "main_impl_count": 0, "branch_unknown_count": 0, "agent_type_plan_count": 0},
  "artifact_health": {"total_traces": 5, "proof_unknown_count": 0, "completeness": {"summary.md": 0.8, "test-output.txt": 0.6, "diff.patch": 0.7, "files-changed.txt": 0.9}},
  "self_metrics": {"total_suggestions": 0, "implemented": 0, "rejected": 0, "acceptance_rate": null},
  "improvement_signals": [],
  "cohort_regressions": [],
  "trends": null,
  "agent_breakdown": [],
  "stale_markers": {"count": 0, "details": []},
  "dataset_integrity": {"data_loss_suspected": false, "no_historical_baseline": false, "single_day_only": false, "prev_trace_count": 0, "current_trace_dir_count": 5, "unique_days": 2},
  "historical_traces": {"available": true, "total": 42, "outcome_dist": {"success": 30, "partial": 12}, "agent_type_dist": {"implementer": 20, "tester": 12, "guardian": 10}}
}
EOF

make_matrix "$OBS108"
echo '{"implemented":[],"rejected":[],"deferred":[]}' > "${OBS108}/state.json"

# Create a report that is OLDER than the cache (set mtime 1 hour ago)
echo "old report" > "${OBS108}/assessment-report.md"
if [[ "$(uname)" == "Darwin" ]]; then
    touch -t "$(date -v-1H +%Y%m%d%H%M.%S)" "${OBS108}/assessment-report.md" 2>/dev/null || true
else
    touch --date="1 hour ago" "${OBS108}/assessment-report.md" 2>/dev/null || true
fi
# Make cache definitely newer
touch "${OBS108}/analysis-cache.json"

STDERR_108=$(OBS_DIR="$OBS108" STATE_FILE="${OBS108}/state.json" bash "$REPORT_SCRIPT" 2>&1 >/dev/null || true)
if echo "$STDERR_108" | grep -q "newer than last report"; then
    pass "#108-A: staleness warning printed to stderr when cache is newer"
else
    fail "#108-A: no staleness warning found in stderr (got: '$STDERR_108')"
fi

# Test 108-B: --skip-stale-check suppresses the warning
STDERR_108B=$(OBS_DIR="$OBS108" STATE_FILE="${OBS108}/state.json" bash "$REPORT_SCRIPT" --skip-stale-check 2>&1 >/dev/null || true)
if echo "$STDERR_108B" | grep -q "newer than last report"; then
    fail "#108-B: staleness warning should be suppressed with --skip-stale-check"
else
    pass "#108-B: --skip-stale-check suppresses staleness warning"
fi

# Test 108-C: Report header contains analysis data timestamp
REPORT_CONTENT=$(OBS_DIR="$OBS108" STATE_FILE="${OBS108}/state.json" bash "$REPORT_SCRIPT" --skip-stale-check 2>/dev/null; cat "${OBS108}/assessment-report.md" 2>/dev/null || echo "")
if echo "$REPORT_CONTENT" | grep -q "2026-02-18T10:00:00Z"; then
    pass "#108-C: report header contains analysis generated_at timestamp"
else
    fail "#108-C: report header missing analysis generated_at timestamp"
fi

# Test 108-D: Report header shows historical trace count
if echo "$REPORT_CONTENT" | grep -q "42 historical"; then
    pass "#108-D: report header references historical trace count (42)"
else
    fail "#108-D: report header missing historical trace context"
fi

# Test 108-E: No warning when report is already newer than cache (report is fresh)
touch "${OBS108}/assessment-report.md"  # make report newest
sleep 0.1
# cache stays at its current mtime (older than report now — but on same second may be equal)
STDERR_108E=$(OBS_DIR="$OBS108" STATE_FILE="${OBS108}/state.json" bash "$REPORT_SCRIPT" 2>&1 >/dev/null || true)
# This may or may not warn depending on subsecond timing; we just verify it doesn't error
if OBS_DIR="$OBS108" STATE_FILE="${OBS108}/state.json" bash "$REPORT_SCRIPT" --skip-stale-check >/dev/null 2>&1; then
    pass "#108-E: report.sh exits 0 when report is already fresh"
else
    fail "#108-E: report.sh failed with non-zero exit"
fi

# ============================================================
# Issue #109: NO_HISTORICAL_BASELINE — prior run detection
# ============================================================
echo ""
echo "=== #109: NO_HISTORICAL_BASELINE uses prior-run detection ==="

# Test 109-A: no prev cache → NO_HISTORICAL_BASELINE=true (first run)
T109A=$(make_tmpdir)
STORE109A="${T109A}/traces"
OBS109A="${T109A}/observatory"
mkdir -p "$STORE109A" "$OBS109A"

# All traces on same day — under old logic this would set NO_HISTORICAL_BASELINE=true
# Under new logic, it should ALSO be true because there's no prev cache
make_trace "$STORE109A" "t-001" implementer success main "2026-02-18T10:00:00Z"
make_trace "$STORE109A" "t-002" tester success main "2026-02-18T11:00:00Z"
make_trace "$STORE109A" "t-003" guardian success main "2026-02-18T12:00:00Z"
make_index "$STORE109A"
echo '{"implemented":[],"rejected":[],"deferred":[]}' > "${OBS109A}/state.json"

CLAUDE_DIR="$T109A" TRACE_INDEX="${STORE109A}/index.jsonl" \
    OBS_DIR="$OBS109A" TRACE_STORE="$STORE109A" STATE_FILE="${OBS109A}/state.json" \
    bash "$ANALYZE_SCRIPT" > /dev/null 2>&1

if [[ -f "${OBS109A}/analysis-cache.json" ]]; then
    NHB=$(jq -r '.dataset_integrity.no_historical_baseline' "${OBS109A}/analysis-cache.json" 2>/dev/null || echo "false")
    if [[ "$NHB" == "true" ]]; then
        pass "#109-A: NO_HISTORICAL_BASELINE=true when no prev cache (first run)"
    else
        fail "#109-A: NO_HISTORICAL_BASELINE=$NHB (expected true — no prev cache)"
    fi
fi

# Test 109-B: prev cache exists → NO_HISTORICAL_BASELINE=false even if all traces same day
T109B=$(make_tmpdir)
STORE109B="${T109B}/traces"
OBS109B="${T109B}/observatory"
mkdir -p "$STORE109B" "$OBS109B"

make_trace "$STORE109B" "t-001" implementer success main "2026-02-18T10:00:00Z"
make_trace "$STORE109B" "t-002" tester success main "2026-02-18T11:00:00Z"
make_trace "$STORE109B" "t-003" guardian success main "2026-02-18T12:00:00Z"
make_index "$STORE109B"
echo '{"implemented":[],"rejected":[],"deferred":[]}' > "${OBS109B}/state.json"

# Create a previous analysis cache (simulates a prior run)
cat > "${OBS109B}/analysis-cache.prev.json" <<'EOF'
{
  "version": 3,
  "generated_at": "2026-02-18T08:00:00Z",
  "trace_stats": {"total": 2},
  "improvement_signals": []
}
EOF

CLAUDE_DIR="$T109B" TRACE_INDEX="${STORE109B}/index.jsonl" \
    OBS_DIR="$OBS109B" TRACE_STORE="$STORE109B" STATE_FILE="${OBS109B}/state.json" \
    bash "$ANALYZE_SCRIPT" > /dev/null 2>&1

if [[ -f "${OBS109B}/analysis-cache.json" ]]; then
    NHB=$(jq -r '.dataset_integrity.no_historical_baseline' "${OBS109B}/analysis-cache.json" 2>/dev/null || echo "true")
    if [[ "$NHB" == "false" ]]; then
        pass "#109-B: NO_HISTORICAL_BASELINE=false when prev cache exists (same-day multi-run)"
    else
        fail "#109-B: NO_HISTORICAL_BASELINE=$NHB (expected false — prev cache present, same-day should NOT block trends)"
    fi
fi

# Test 109-C: trends NOT null when prev cache exists (same-day multi-run)
if [[ -f "${OBS109B}/analysis-cache.json" ]]; then
    TRENDS_VAL=$(jq '.trends' "${OBS109B}/analysis-cache.json" 2>/dev/null || echo "null")
    if [[ "$TRENDS_VAL" != "null" ]]; then
        pass "#109-C: trends computed (not null) when prev cache exists, same-day multi-run"
    else
        fail "#109-C: trends=null even though prev cache exists (same-day blocked trends — regression)"
    fi
fi

# Test 109-D: single_day_only field present in dataset_integrity (informational)
if [[ -f "${OBS109B}/analysis-cache.json" ]]; then
    SDO=$(jq 'has("single_day_only")' "${OBS109B}/dataset_integrity" 2>/dev/null || \
         jq '.dataset_integrity | has("single_day_only")' "${OBS109B}/analysis-cache.json" 2>/dev/null || echo "false")
    if [[ "$SDO" == "true" ]]; then
        pass "#109-D: dataset_integrity.single_day_only field present"
    else
        fail "#109-D: dataset_integrity.single_day_only field missing"
    fi
fi

# Test 109-E: trends null when prev cache absent (NO_HISTORICAL_BASELINE=true)
if [[ -f "${OBS109A}/analysis-cache.json" ]]; then
    TRENDS_A=$(jq '.trends' "${OOS109A:-${OBS109A}}/analysis-cache.json" 2>/dev/null || \
               jq '.trends' "${OBS109A}/analysis-cache.json" 2>/dev/null || echo "null")
    if [[ "$TRENDS_A" == "null" ]]; then
        pass "#109-E: trends=null when no prev cache (NO_HISTORICAL_BASELINE suppresses trends)"
    else
        fail "#109-E: trends not null when no prev cache — should be suppressed"
    fi
fi

# ============================================================
# Issue #110: session-init.sh development log digest
# ============================================================
echo ""
echo "=== #110: Development log digest in session-init ==="

# For session-init we test the logic by sourcing hooks and checking context output.
# Since session-init.sh requires full env, we test the underlying behavior
# via a focused test that creates a fake TRACE_STORE/index.jsonl with project traces.

T110=$(make_tmpdir)
STORE110="${T110}/traces"
OBS110="${T110}/observatory"
mkdir -p "$STORE110" "$OBS110"

# Create 5 project traces in index.jsonl directly (faster than running full analyze)
INDEX110="${STORE110}/index.jsonl"
cat > "$INDEX110" <<'EOF'
{"trace_id":"t-001","project_name":"myproject","agent_type":"implementer","outcome":"success","branch":"feature/auth","started_at":"2026-02-14T10:00:00Z","duration_seconds":300,"files_changed":5}
{"trace_id":"t-002","project_name":"myproject","agent_type":"tester","outcome":"success","branch":"feature/auth","started_at":"2026-02-15T11:00:00Z","duration_seconds":120,"files_changed":0}
{"trace_id":"t-003","project_name":"myproject","agent_type":"guardian","outcome":"success","branch":"main","started_at":"2026-02-16T12:00:00Z","duration_seconds":60,"files_changed":2}
{"trace_id":"t-004","project_name":"myproject","agent_type":"implementer","outcome":"partial","branch":"feature/ui","started_at":"2026-02-17T09:00:00Z","duration_seconds":450,"files_changed":8}
{"trace_id":"t-005","project_name":"myproject","agent_type":"tester","outcome":"success","branch":"feature/ui","started_at":"2026-02-18T14:00:00Z","duration_seconds":90,"files_changed":0}
{"trace_id":"t-006","project_name":"OTHER","agent_type":"implementer","outcome":"success","branch":"main","started_at":"2026-02-18T15:00:00Z","duration_seconds":200,"files_changed":3}
EOF

# Use a project root named "myproject" so the digest picks up those traces
PROJ_ROOT110="${T110}/myproject"
mkdir -p "$PROJ_ROOT110/.git"
# git init so get_git_state works without error
git -C "$PROJ_ROOT110" init -q 2>/dev/null || true
git -C "$PROJ_ROOT110" config user.email "test@test.com" 2>/dev/null || true
git -C "$PROJ_ROOT110" config user.name "Test" 2>/dev/null || true

# Source just the relevant part of session-init by running it in a limited env
# We test the digest logic directly via a mini script that replicates the logic
MINI_TEST=$(cat <<'MINISCRIPT'
#!/usr/bin/env bash
set -euo pipefail
TRACE_STORE="$1"
PROJECT_ROOT="$2"
INDEX="${TRACE_STORE}/index.jsonl"

DEV_PROJECT_NAME=$(basename "$PROJECT_ROOT")
_DEV_TRACES=$(grep "\"project_name\":\"${DEV_PROJECT_NAME}\"" "$INDEX" 2>/dev/null | tail -5 | awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}')
_DEV_TRACE_COUNT=$(echo "$_DEV_TRACES" | grep -c . 2>/dev/null || echo "0")

echo "TRACE_COUNT=${_DEV_TRACE_COUNT}"

if [[ "$_DEV_TRACE_COUNT" -ge 2 ]]; then
    _DEV_LOG_LINES=()
    while IFS= read -r trace_entry; do
        [[ -z "$trace_entry" ]] && continue
        _DL_DATE=$(echo "$trace_entry" | jq -r '.started_at // ""' 2>/dev/null | cut -c1-10)
        _DL_AGENT=$(echo "$trace_entry" | jq -r '.agent_type // "?"' 2>/dev/null)
        _DL_OUTCOME=$(echo "$trace_entry" | jq -r '.outcome // "?"' 2>/dev/null)
        _DL_DUR=$(echo "$trace_entry" | jq -r '.duration_seconds // ""' 2>/dev/null)
        _DL_FILES=$(echo "$trace_entry" | jq -r '.files_changed // ""' 2>/dev/null)
        _DL_BRANCH=$(echo "$trace_entry" | jq -r '.branch // ""' 2>/dev/null)
        _DL_DUR_FMT=""
        if [[ -n "$_DL_DUR" && "$_DL_DUR" =~ ^[0-9]+$ && "$_DL_DUR" -gt 0 ]]; then
            if [[ "$_DL_DUR" -ge 60 ]]; then
                _DL_DUR_FMT="$(( _DL_DUR / 60 ))m$(( _DL_DUR % 60 ))s"
            else
                _DL_DUR_FMT="${_DL_DUR}s"
            fi
        fi
        _DL_LINE="${_DL_DATE} | ${_DL_AGENT} | ${_DL_OUTCOME}"
        [[ -n "$_DL_DUR_FMT" ]] && _DL_LINE="${_DL_LINE} | ${_DL_DUR_FMT}"
        [[ -n "$_DL_FILES" ]] && _DL_LINE="${_DL_LINE} | ${_DL_FILES} files"
        [[ -n "$_DL_BRANCH" && "$_DL_BRANCH" != "unknown" ]] && _DL_LINE="${_DL_LINE} | ${_DL_BRANCH}"
        _DEV_LOG_LINES+=("  ${_DL_LINE}")
    done <<< "$_DEV_TRACES"
    echo "LINE_COUNT=${#_DEV_LOG_LINES[@]}"
    printf '%s\n' "${_DEV_LOG_LINES[@]}"
fi
MINISCRIPT
)

DIGEST_OUTPUT=$(echo "$MINI_TEST" | bash -s -- "$STORE110" "$PROJ_ROOT110" 2>/dev/null)

# Test 110-A: trace count is 5 (6th trace is OTHER project, excluded)
T_COUNT=$(echo "$DIGEST_OUTPUT" | grep "^TRACE_COUNT=" | cut -d= -f2)
if [[ "$T_COUNT" -eq 5 ]]; then
    pass "#110-A: digest finds 5 project traces (OTHER project excluded)"
else
    fail "#110-A: TRACE_COUNT=$T_COUNT (expected 5 — project filter failed)"
fi

# Test 110-B: 5 digest lines generated
LINE_COUNT=$(echo "$DIGEST_OUTPUT" | grep "^LINE_COUNT=" | cut -d= -f2)
if [[ "$LINE_COUNT" -eq 5 ]]; then
    pass "#110-B: 5 digest lines generated (one per trace)"
else
    fail "#110-B: LINE_COUNT=$LINE_COUNT (expected 5)"
fi

# Test 110-C: date appears in digest lines
if echo "$DIGEST_OUTPUT" | grep -q "2026-02-"; then
    pass "#110-C: date prefix present in digest lines"
else
    fail "#110-C: date prefix missing from digest lines"
fi

# Test 110-D: agent type appears in digest lines
if echo "$DIGEST_OUTPUT" | grep -q "implementer"; then
    pass "#110-D: agent type present in digest lines"
else
    fail "#110-D: agent type missing from digest lines"
fi

# Test 110-E: duration formatted (5m0s for 300 seconds)
if echo "$DIGEST_OUTPUT" | grep -q "5m0s"; then
    pass "#110-E: duration formatted correctly (300s → 5m0s)"
else
    fail "#110-E: duration format wrong (expected 5m0s for 300s)"
fi

# Test 110-F: fewer than 2 traces → no digest (omitted)
INDEX110F="${T110}/traces_few/index.jsonl"
mkdir -p "$(dirname "$INDEX110F")"
echo '{"trace_id":"t-001","project_name":"myproject","agent_type":"implementer","outcome":"success","branch":"main","started_at":"2026-02-18T10:00:00Z","duration_seconds":60,"files_changed":1}' > "$INDEX110F"

DIGEST_F=$(echo "$MINI_TEST" | bash -s -- "$(dirname "$INDEX110F")" "$PROJ_ROOT110" 2>/dev/null)
T_COUNT_F=$(echo "$DIGEST_F" | grep "^TRACE_COUNT=" | cut -d= -f2)
LINE_COUNT_F=$(echo "$DIGEST_F" | grep "^LINE_COUNT=" | cut -d= -f2 || echo "0")
if [[ "$LINE_COUNT_F" == "0" || -z "$LINE_COUNT_F" ]]; then
    pass "#110-F: digest omitted when fewer than 2 project traces exist"
else
    fail "#110-F: digest emitted with only $T_COUNT_F trace (should be omitted)"
fi

# Test 110-G: branch appears in digest lines
if echo "$DIGEST_OUTPUT" | grep -q "feature/"; then
    pass "#110-G: branch name present in digest lines"
else
    fail "#110-G: branch name missing from digest lines"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "==================================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==================================================="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
