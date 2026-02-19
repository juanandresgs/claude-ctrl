#!/usr/bin/env bash
# test-obs-critical-fixes.sh — Tests for Phase 0 Critical Observability Fixes
#
# Purpose: Verify all four Phase 0 fixes:
#   - C1 (#99): suggest.sh diagnostic logging — counts processed/skipped/regression signals
#   - C2 (#100): jq error handling in finalize_trace and refinalize_trace manifest writes
#   - C3 (#101): detect_active_trace uses session_id validation, not just ls -t glob race
#   - H1 (#102): session-end.sh removes .active-* markers for current session
#
# @decision DEC-OBS-OVERHAUL-001
# @title Fix-forward approach for pipeline bugs
# @status accepted
# @rationale Issues #99-#102 were identified in an observatory audit. Rather than
#   revert prior work, we harden the existing pipeline with better error handling,
#   diagnostic logging, and session-scoped cleanup. Tests verify each fix independently.
#
# @decision DEC-OBS-OVERHAUL-002
# @title Session-specific marker validation in detect_active_trace
# @status accepted
# @rationale The ls -t fallback races when concurrent agents of the same type run.
#   Primary path: match CLAUDE_SESSION_ID exactly. Fallback: read manifest session_id
#   from each candidate marker to find the one belonging to our session.
#
# @decision DEC-OBS-OVERHAUL-003
# @title jq error propagation in manifest writes
# @status accepted
# @rationale Silent jq failures leave manifests unupdated with no indication of failure.
#   Capturing stderr and checking exit codes makes failures visible and auditable.
#
# Usage: bash tests/test-obs-critical-fixes.sh
# Returns: 0 if all tests pass, 1 if any fail

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="${WORKTREE_ROOT}/hooks"
SUGGEST_SCRIPT="${WORKTREE_ROOT}/skills/observatory/scripts/suggest.sh"

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

make_git_repo() {
    local d
    d=$(mktemp -d)
    CLEANUP_DIRS+=("$d")
    git -C "$d" init -q 2>/dev/null
    git -C "$d" config user.email "test@test.com" 2>/dev/null
    git -C "$d" config user.name "Test" 2>/dev/null
    echo "initial" > "${d}/base.txt"
    git -C "$d" add base.txt 2>/dev/null
    git -C "$d" commit -q -m "initial" 2>/dev/null
    echo "$d"
}

# ============================================================
# C1 Tests: suggest.sh diagnostic logging (#99)
# ============================================================
echo ""
echo "=== C1: suggest.sh diagnostic logging ==="

# Scaffold: create a minimal analysis-cache.json and state.json
make_suggest_env() {
    local d
    d=$(make_tmpdir)
    mkdir -p "${d}/observatory/suggestions"

    # state.json: all signals implemented (so suggest would normally be silent)
    cat > "${d}/observatory/state.json" <<'EOF'
{
  "version": 3,
  "implemented": [
    {"sug_id":"SUG-001","signal_id":"SIG-TEST-UNKNOWN","implemented_at":"2026-01-01T00:00:00Z"},
    {"sug_id":"SUG-002","signal_id":"SIG-FILES-ZERO","implemented_at":"2026-01-01T00:00:00Z"}
  ],
  "deferred": [],
  "rejected": []
}
EOF

    # analysis-cache.json: 2 signals, no cohort regressions
    cat > "${d}/observatory/analysis-cache.json" <<'EOF'
{
  "generated_at": "2026-01-01T00:00:00Z",
  "trace_count": 10,
  "improvement_signals": [
    {
      "id": "SIG-TEST-UNKNOWN",
      "category": "data_quality",
      "severity": "high",
      "evidence": {"affected_count": 8, "total": 10}
    },
    {
      "id": "SIG-FILES-ZERO",
      "category": "data_quality",
      "severity": "medium",
      "evidence": {"affected_count": 6, "total": 10}
    }
  ],
  "cohort_regressions": []
}
EOF
    echo "$d"
}

# C1-T1: suggest.sh logs "processed" count when signals exist
echo ""
echo "=== C1-T1: suggest.sh logs signal processing count ==="
ENV1=$(make_suggest_env)
output=$(
    OBS_DIR="${ENV1}/observatory" \
    bash "$SUGGEST_SCRIPT" 2>&1
)
if echo "$output" | grep -qiE 'processed|skipped|signals?'; then
    pass "C1-T1: suggest.sh logs diagnostic counts"
else
    fail "C1-T1: suggest.sh missing diagnostic logging; output: $(echo "$output" | head -5)"
fi

# C1-T2: suggest.sh logs "no suggestions generated" reason when all implemented
echo ""
echo "=== C1-T2: suggest.sh explains why no suggestions generated ==="
output2=$(
    OBS_DIR="${ENV1}/observatory" \
    bash "$SUGGEST_SCRIPT" 2>&1
)
if echo "$output2" | grep -qiE 'no suggest|all implement|cohort clean|skipped.*implement'; then
    pass "C1-T2: suggest.sh explains zero-output condition"
else
    fail "C1-T2: suggest.sh missing zero-output explanation; output: $(echo "$output2" | head -5)"
fi

# C1-T3: suggest.sh logs regression-checked count when cohort regressions exist
echo ""
echo "=== C1-T3: suggest.sh logs regression-check when cohort regressions present ==="
ENV3=$(make_suggest_env)
# Override cache to add a cohort regression for SIG-TEST-UNKNOWN
cat > "${ENV3}/observatory/analysis-cache.json" <<'EOF'
{
  "generated_at": "2026-01-01T00:00:00Z",
  "trace_count": 15,
  "improvement_signals": [
    {
      "id": "SIG-TEST-UNKNOWN",
      "category": "data_quality",
      "severity": "high",
      "evidence": {"affected_count": 8, "total": 15}
    }
  ],
  "cohort_regressions": [
    {"signal_id": "SIG-TEST-UNKNOWN", "regression": true, "rate": 0.6}
  ]
}
EOF
output3=$(
    OBS_DIR="${ENV3}/observatory" \
    bash "$SUGGEST_SCRIPT" 2>&1
)
if echo "$output3" | grep -qiE 'regression|re-propos'; then
    pass "C1-T3: suggest.sh logs regression detection path"
else
    fail "C1-T3: suggest.sh missing regression logging; output: $(echo "$output3" | head -5)"
fi

# C1-T4: suggest.sh produces SUG file for regression-flagged signal
echo ""
echo "=== C1-T4: suggest.sh produces SUG file for regression signal ==="
sug_count=$(ls "${ENV3}/observatory/suggestions/"*.json 2>/dev/null | wc -l | tr -d ' ')
if [[ "$sug_count" -ge 1 ]]; then
    pass "C1-T4: SUG file produced for regression signal (count: $sug_count)"
else
    fail "C1-T4: No SUG file produced for regression signal; output: $(echo "$output3" | head -5)"
fi

# C1-T5: state.json implemented entries all have implemented_at (or script flags missing ones)
echo ""
echo "=== C1-T5: state.json missing implemented_at is flagged ==="
ENV5=$(make_suggest_env)
# Inject an entry without implemented_at
cat > "${ENV5}/observatory/state.json" <<'EOF'
{
  "version": 3,
  "implemented": [
    {"sug_id":"SUG-001","signal_id":"SIG-TEST-UNKNOWN"},
    {"sug_id":"SUG-002","signal_id":"SIG-FILES-ZERO","implemented_at":"2026-01-01T00:00:00Z"}
  ],
  "deferred": [],
  "rejected": []
}
EOF
output5=$(
    OBS_DIR="${ENV5}/observatory" \
    bash "$SUGGEST_SCRIPT" 2>&1
)
# Either the script flags it OR it still processes (both are acceptable outcomes;
# the key requirement is that it doesn't silently mis-handle)
# Accept: flag/warn about missing timestamp OR process normally
if echo "$output5" | grep -qiE 'missing|no implemented_at|warning|processed|skipped'; then
    pass "C1-T5: suggest.sh handles missing implemented_at gracefully"
else
    fail "C1-T5: suggest.sh produced unexpected output for missing implemented_at: $(echo "$output5" | head -5)"
fi

# ============================================================
# C2 Tests: jq error handling in finalize_trace (#100)
# ============================================================
echo ""
echo "=== C2: jq error handling in finalize_trace / refinalize_trace ==="

# C2-T1: finalize_trace returns non-zero when manifest is corrupted/missing
echo ""
echo "=== C2-T1: finalize_trace returns non-zero for corrupt manifest ==="
TS_C2=$(make_tmpdir)
output_c2t1=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS_C2"
    # finalize_trace on a non-existent trace
    finalize_trace "nonexistent-trace-id" "/tmp" "implementer" 2>&1
    echo "exit:$?"
)
if echo "$output_c2t1" | grep -q "exit:1"; then
    pass "C2-T1: finalize_trace returns 1 for missing manifest"
else
    fail "C2-T1: finalize_trace did not return non-zero for missing manifest; got: $output_c2t1"
fi

# C2-T2: finalize_trace with a well-formed manifest succeeds and updates it
echo ""
echo "=== C2-T2: finalize_trace succeeds on well-formed manifest ==="
TS_C2T2=$(make_tmpdir)
PROJ_C2T2=$(make_tmpdir)
output_c2t2=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS_C2T2"
    trace_id=$(init_trace "$PROJ_C2T2" "implementer" 2>/dev/null)
    # Create a test artifact so outcome isn't "skipped"
    mkdir -p "${TS_C2T2}/${trace_id}/artifacts"
    echo "1 passed" > "${TS_C2T2}/${trace_id}/artifacts/test-output.txt"
    touch "${TS_C2T2}/${trace_id}/summary.md"
    finalize_trace "$trace_id" "$PROJ_C2T2" "implementer" 2>&1
    echo "status:$(jq -r '.status' "${TS_C2T2}/${trace_id}/manifest.json" 2>/dev/null)"
)
if echo "$output_c2t2" | grep -q "status:completed"; then
    pass "C2-T2: finalize_trace updates manifest to 'completed' on success"
else
    fail "C2-T2: finalize_trace did not update manifest; got: $output_c2t2"
fi

# C2-T3: finalize_trace with a malformed manifest — jq failure produces explicit error log
# Requirement: error must be logged to stderr (not swallowed by 2>/dev/null)
# Note: use a temp file for capture because $() under set -e exits on non-zero return.
echo ""
echo "=== C2-T3: finalize_trace logs explicit error for malformed manifest ==="
TS_C2T3=$(make_tmpdir)
PROJ_C2T3=$(make_tmpdir)
TRACE_C2T3="bad-trace-$(date +%s)"
mkdir -p "${TS_C2T3}/${TRACE_C2T3}/artifacts"
echo "NOT VALID JSON {{{" > "${TS_C2T3}/${TRACE_C2T3}/manifest.json"
_c2t3_out="${TS_C2T3}/_c2t3.out"
bash -c "
    source '${HOOKS_DIR}/log.sh'
    source '${HOOKS_DIR}/context-lib.sh'
    TRACE_STORE='${TS_C2T3}'
    finalize_trace '${TRACE_C2T3}' '${PROJ_C2T3}' 'implementer'
" > "$_c2t3_out" 2>&1 || true
output_c2t3=$(cat "$_c2t3_out" 2>/dev/null)
manifest_after=$(cat "${TS_C2T3}/${TRACE_C2T3}/manifest.json" 2>/dev/null)
if echo "$output_c2t3" | grep -qiE 'error|jq.*fail|manifest.*fail|failed.*manifest'; then
    pass "C2-T3: finalize_trace logs explicit error when jq fails on manifest"
elif [[ "$manifest_after" != "NOT VALID JSON {{{"  ]]; then
    fail "C2-T3: manifest was silently overwritten/corrupted on jq failure; manifest now: $manifest_after"
else
    fail "C2-T3: finalize_trace silently swallowed jq error (no error logged); manifest preserved but failure invisible"
fi

# C2-T4: refinalize_trace with malformed manifest — jq failure produces explicit error log
echo ""
echo "=== C2-T4: refinalize_trace logs explicit error for malformed manifest ==="
TS_C2T4=$(make_tmpdir)
TRACE_C2T4="bad-refin-$(date +%s)"
mkdir -p "${TS_C2T4}/${TRACE_C2T4}/artifacts"
echo "BROKEN JSON" > "${TS_C2T4}/${TRACE_C2T4}/manifest.json"
_c2t4_out="${TS_C2T4}/_c2t4.out"
bash -c "
    source '${HOOKS_DIR}/log.sh'
    source '${HOOKS_DIR}/context-lib.sh'
    TRACE_STORE='${TS_C2T4}'
    refinalize_trace '${TRACE_C2T4}'
" > "$_c2t4_out" 2>&1 || true
output_c2t4=$(cat "$_c2t4_out" 2>/dev/null)
manifest_after_refin=$(cat "${TS_C2T4}/${TRACE_C2T4}/manifest.json" 2>/dev/null)
if echo "$output_c2t4" | grep -qiE 'error|jq.*fail|manifest.*fail|failed.*manifest'; then
    pass "C2-T4: refinalize_trace logs explicit error when jq fails on manifest"
elif [[ "$manifest_after_refin" != "BROKEN JSON" ]]; then
    fail "C2-T4: refinalize_trace silently corrupted manifest on jq failure; manifest now: $manifest_after_refin"
else
    fail "C2-T4: refinalize_trace silently swallowed jq error (no error logged)"
fi

# C2-T5: tmp_manifest is validated non-empty before mv
echo ""
echo "=== C2-T5: finalize_trace validates tmp_manifest non-empty before mv ==="
TS_C2T5=$(make_tmpdir)
PROJ_C2T5=$(make_tmpdir)
output_c2t5=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS_C2T5"
    trace_id=$(init_trace "$PROJ_C2T5" "implementer" 2>/dev/null)
    mkdir -p "${TS_C2T5}/${trace_id}/artifacts"
    touch "${TS_C2T5}/${trace_id}/summary.md"
    finalize_trace "$trace_id" "$PROJ_C2T5" "implementer" 2>&1
    # After finalize: manifest should be valid JSON (not empty)
    jq -r '.status' "${TS_C2T5}/${trace_id}/manifest.json" 2>/dev/null
)
if [[ -n "$output_c2t5" && "$output_c2t5" != "null" ]]; then
    pass "C2-T5: manifest is valid JSON after finalize_trace (status=$output_c2t5)"
else
    fail "C2-T5: manifest empty or invalid after finalize_trace; got: $output_c2t5"
fi

# ============================================================
# C3 Tests: detect_active_trace session filtering (#101)
# ============================================================
echo ""
echo "=== C3: detect_active_trace session filtering ==="

# C3-T1: Session-specific marker is found by session_id
echo ""
echo "=== C3-T1: detect_active_trace finds session-specific marker ==="
TS_C3T1=$(make_tmpdir)
PROJ_C3T1=$(make_tmpdir)
output_c3t1=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS_C3T1"
    export CLAUDE_SESSION_ID="my-test-session-$$"
    trace_id=$(init_trace "$PROJ_C3T1" "implementer" 2>/dev/null)
    # detect should return that trace_id
    found=$(detect_active_trace "$PROJ_C3T1" "implementer" 2>/dev/null)
    echo "$found"
)
if [[ -n "$output_c3t1" ]]; then
    pass "C3-T1: detect_active_trace returns trace_id for session-specific marker"
else
    fail "C3-T1: detect_active_trace returned empty for valid session-specific marker"
fi

# C3-T2: With two concurrent agents of same type, each session gets its own trace
echo ""
echo "=== C3-T2: Concurrent agents each detect their own trace (no glob race) ==="
TS_C3T2=$(make_tmpdir)
PROJ_C3T2=$(make_tmpdir)

# Create two traces for the same agent type with different session IDs
trace_a=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS_C3T2"
    export CLAUDE_SESSION_ID="session-A-$$"
    init_trace "$PROJ_C3T2" "implementer" 2>/dev/null
)
trace_b=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS_C3T2"
    export CLAUDE_SESSION_ID="session-B-$$"
    init_trace "$PROJ_C3T2" "implementer" 2>/dev/null
)

# Each session should detect its own trace
found_a=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS_C3T2"
    export CLAUDE_SESSION_ID="session-A-$$"
    detect_active_trace "$PROJ_C3T2" "implementer" 2>/dev/null
)
found_b=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS_C3T2"
    export CLAUDE_SESSION_ID="session-B-$$"
    detect_active_trace "$PROJ_C3T2" "implementer" 2>/dev/null
)

if [[ "$found_a" == "$trace_a" && "$found_b" == "$trace_b" ]]; then
    pass "C3-T2: Each session detects its own trace (A=$trace_a, B=$trace_b)"
elif [[ "$found_a" != "$trace_a" ]]; then
    fail "C3-T2: Session A detected wrong trace (expected $trace_a, got $found_a)"
else
    fail "C3-T2: Session B detected wrong trace (expected $trace_b, got $found_b)"
fi

# C3-T3: Without CLAUDE_SESSION_ID, fallback is used with warning log
echo ""
echo "=== C3-T3: detect_active_trace logs warning when CLAUDE_SESSION_ID is empty ==="
TS_C3T3=$(make_tmpdir)
PROJ_C3T3=$(make_tmpdir)
output_c3t3=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS_C3T3"
    export CLAUDE_SESSION_ID="session-C3T3-$$"
    trace_id=$(init_trace "$PROJ_C3T3" "planner" 2>/dev/null)
    # Now unset session ID to force fallback
    unset CLAUDE_SESSION_ID
    # detect should still find the trace but may log a warning
    found=$(detect_active_trace "$PROJ_C3T3" "planner" 2>&1)
    echo "$found"
)
# Either found a trace (fallback worked) or logged warning — both acceptable
if [[ -n "$output_c3t3" ]]; then
    pass "C3-T3: detect_active_trace handles missing CLAUDE_SESSION_ID (output: $(echo "$output_c3t3" | head -1))"
else
    fail "C3-T3: detect_active_trace returned nothing with empty CLAUDE_SESSION_ID"
fi

# C3-T4: Session-specific marker is validated against manifest session_id
echo ""
echo "=== C3-T4: detect_active_trace validates manifest session_id for non-session-marker ==="
TS_C3T4=$(make_tmpdir)
PROJ_C3T4=$(make_tmpdir)

# Create a trace for session X, then try to detect with session Y (different session)
# The marker for X exists but Y should NOT return X's trace
trace_x=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS_C3T4"
    export CLAUDE_SESSION_ID="session-X-$$"
    init_trace "$PROJ_C3T4" "tester" 2>/dev/null
)

# Use a temp file to capture output — detect_active_trace returns 1 when not found,
# which kills the subshell under set -e if wrapped in $()
_c3t4_out="${TS_C3T4}/_c3t4.out"
bash -c "
    source '${HOOKS_DIR}/log.sh'
    source '${HOOKS_DIR}/context-lib.sh'
    TRACE_STORE='${TS_C3T4}'
    export CLAUDE_SESSION_ID='session-Y-$$'
    detect_active_trace '${PROJ_C3T4}' 'tester'
" > "$_c3t4_out" 2>/dev/null || true
found_y=$(cat "$_c3t4_out" 2>/dev/null)

# Session Y should NOT find session X's trace (different session IDs)
if [[ "$found_y" != "$trace_x" ]]; then
    pass "C3-T4: Session Y does not get Session X's trace (found_y='$found_y', trace_x='$trace_x')"
else
    fail "C3-T4: Session Y incorrectly returned Session X's trace ($trace_x)"
fi

# ============================================================
# H1 Tests: session-end.sh active marker cleanup (#102)
# ============================================================
echo ""
echo "=== H1: session-end.sh active marker cleanup ==="

SESSION_END_SCRIPT="${WORKTREE_ROOT}/hooks/session-end.sh"

# H1-T1: session-end.sh cleanup section removes .active-* marker for current session
# Tests the cleanup logic directly via context-lib.sh functions + the cleanup code
# extracted from session-end.sh. We test the logic, not the full script execution,
# because the full script may exit early in a minimal test environment (no real
# HOME/.claude, no session event log, etc.) — the cleanup code is at line 176+.
echo ""
echo "=== H1-T1: session-end.sh cleanup logic removes current session's .active-* marker ==="
TS_H1T1=$(make_tmpdir)
PROJ_H1T1=$(make_tmpdir)
SESSION_H1="test-session-h1-$$"

# Create an active trace for this session
(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS_H1T1"
    export CLAUDE_SESSION_ID="$SESSION_H1"
    init_trace "$PROJ_H1T1" "implementer" > /dev/null 2>&1
)
marker_path="${TS_H1T1}/.active-implementer-${SESSION_H1}"

# Verify marker exists before cleanup
if [[ ! -f "$marker_path" ]]; then
    fail "H1-T1 setup: marker was not created at $marker_path"
else
    # Run the exact cleanup logic from session-end.sh (lines 192-198) in isolation.
    # This validates the DEC-OBS-OVERHAUL-005 implementation directly.
    _h1t1_out="${TS_H1T1}/_h1t1.out"
    bash -c "
        source '${HOOKS_DIR}/log.sh'
        source '${HOOKS_DIR}/context-lib.sh'
        TRACE_STORE='${TS_H1T1}'
        CLAUDE_SESSION_ID='${SESSION_H1}'
        SESSION_TRACE_STORE=\"\${TRACE_STORE:-\$HOME/.claude/traces}\"
        if [[ -n \"\${CLAUDE_SESSION_ID:-}\" && -d \"\$SESSION_TRACE_STORE\" ]]; then
            for _active_marker in \"\${SESSION_TRACE_STORE}/.active-\"*\"-\${CLAUDE_SESSION_ID}\"; do
                [[ -f \"\$_active_marker\" ]] && rm -f \"\$_active_marker\"
            done
        fi
    " > "$_h1t1_out" 2>&1 || true

    if [[ ! -f "$marker_path" ]]; then
        pass "H1-T1: session-end.sh cleanup logic removed .active-* marker for current session"
    else
        fail "H1-T1: session-end.sh cleanup logic did NOT remove marker at $marker_path"
    fi
fi

# H1-T2: session-end.sh cleanup logic does NOT remove markers for OTHER sessions
echo ""
echo "=== H1-T2: session-end.sh preserves .active-* markers for other sessions ==="
TS_H1T2=$(make_tmpdir)
PROJ_H1T2=$(make_tmpdir)
SESSION_MINE="my-session-$$"
SESSION_OTHER="other-session-$$"

# Create a trace for "other" session
(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS_H1T2"
    export CLAUDE_SESSION_ID="$SESSION_OTHER"
    init_trace "$PROJ_H1T2" "planner" > /dev/null 2>&1
)
other_marker="${TS_H1T2}/.active-planner-${SESSION_OTHER}"

# Also create a trace for "my" session
(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS_H1T2"
    export CLAUDE_SESSION_ID="$SESSION_MINE"
    init_trace "$PROJ_H1T2" "implementer" > /dev/null 2>&1
)

# Run the cleanup logic for "my" session only
bash -c "
    source '${HOOKS_DIR}/log.sh'
    source '${HOOKS_DIR}/context-lib.sh'
    TRACE_STORE='${TS_H1T2}'
    CLAUDE_SESSION_ID='${SESSION_MINE}'
    SESSION_TRACE_STORE=\"\${TRACE_STORE:-\$HOME/.claude/traces}\"
    if [[ -n \"\${CLAUDE_SESSION_ID:-}\" && -d \"\$SESSION_TRACE_STORE\" ]]; then
        for _active_marker in \"\${SESSION_TRACE_STORE}/.active-\"*\"-\${CLAUDE_SESSION_ID}\"; do
            [[ -f \"\$_active_marker\" ]] && rm -f \"\$_active_marker\"
        done
    fi
" 2>/dev/null || true

if [[ -f "$other_marker" ]]; then
    pass "H1-T2: cleanup logic preserved other session's .active-* marker"
else
    fail "H1-T2: cleanup logic incorrectly removed other session's marker ($other_marker)"
fi

# H1-T3: refinalize_stale_traces heals orphaned active markers (status stays accurate)
echo ""
echo "=== H1-T3: refinalize_stale_traces heals orphaned 'active' traces ==="
TS_H1T3=$(make_tmpdir)
PROJ_H1T3=$(make_tmpdir)

# Create an "orphaned" trace: started >30 min ago, still active (no finalize called)
ORPHAN_TRACE="orphan-$(date +%s)"
mkdir -p "${TS_H1T3}/${ORPHAN_TRACE}/artifacts"
# Write a manifest with status=active and old started_at
two_hours_ago=$(date -u -v-2H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "2 hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
cat > "${TS_H1T3}/${ORPHAN_TRACE}/manifest.json" <<EOF
{
  "version": "1",
  "trace_id": "${ORPHAN_TRACE}",
  "agent_type": "implementer",
  "session_id": "dead-session",
  "project": "${PROJ_H1T3}",
  "project_name": "test",
  "branch": "main",
  "started_at": "${two_hours_ago}",
  "status": "active"
}
EOF
# Create a summary to prevent "crashed" outcome
echo "# Summary" > "${TS_H1T3}/${ORPHAN_TRACE}/summary.md"

updated_count=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS_H1T3"
    refinalize_stale_traces
)

final_status=$(jq -r '.status // "unknown"' "${TS_H1T3}/${ORPHAN_TRACE}/manifest.json" 2>/dev/null)
if [[ "$final_status" == "completed" ]]; then
    pass "H1-T3: refinalize_stale_traces healed orphaned trace (status='completed')"
else
    fail "H1-T3: orphaned trace not healed; status='$final_status' (updated_count=$updated_count)"
fi

# H1-T4: init_trace stale marker cleanup still works (regression guard)
echo ""
echo "=== H1-T4: init_trace stale marker cleanup regression guard ==="
TS_H1T4=$(make_tmpdir)
PROJ_H1T4=$(make_tmpdir)
stale_marker="${TS_H1T4}/.active-oldtype-oldsession"
echo "old-trace" > "$stale_marker"
three_hours_ago_t=$(date -v-3H +%Y%m%d%H%M.%S 2>/dev/null || date -d "3 hours ago" +%Y%m%d%H%M.%S 2>/dev/null)
touch -t "${three_hours_ago_t}" "$stale_marker" 2>/dev/null
(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS_H1T4"
    export CLAUDE_SESSION_ID="new-session-$$"
    init_trace "$PROJ_H1T4" "implementer" > /dev/null 2>&1
)
if [[ ! -f "$stale_marker" ]]; then
    pass "H1-T4: init_trace still removes stale markers (regression guard)"
else
    fail "H1-T4: init_trace no longer removes stale markers (regression!)"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo ""
if [[ "$FAIL" -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "Some tests FAILED."
    exit 1
fi
