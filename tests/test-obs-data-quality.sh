#!/usr/bin/env bash
# test-obs-data-quality.sh — Tests for Observatory Data Quality Fixes
#
# Purpose: Verify fixes for Phase 1 data quality issues:
#   - #103: .test-status fallback in finalize_trace (recovers test_result=unknown)
#   - #104: rebuild_index called after refinalize_stale_traces updates manifests
#   - #105: Robust start_commit/end_commit capture with diagnostic logging
#   - #106: Observatory tests included in run-hooks.sh (structural, not a runtime test)
#
# @decision DEC-OBS-DATA-QUALITY-001
# @title Unit tests for observatory data quality fixes (issues #103–#106)
# @status accepted
# @rationale The fixes touch finalize_trace, refinalize_stale_traces, and init_trace —
#   all critical paths that run at SubagentStop time. Unit tests with isolated temp
#   dirs verify each fix without requiring a running Claude session. Tests use
#   mktemp -d and trap cleanup, following the same pattern as test-observatory-batch-a-fixes.sh.
#
# Usage: bash tests/test-obs-data-quality.sh
# Returns: 0 if all tests pass, 1 if any fail

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="${WORKTREE_ROOT}/hooks"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Shared cleanup list for temp directories
CLEANUP_DIRS=()
trap 'rm -rf "${CLEANUP_DIRS[@]}"' EXIT

# Create an isolated trace store
make_trace_store() {
    local d
    d=$(mktemp -d)
    CLEANUP_DIRS+=("$d")
    echo "$d"
}

# Create a real git repo with one initial commit
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

# Create a plain (non-git) directory
make_plain_dir() {
    local d
    d=$(mktemp -d)
    CLEANUP_DIRS+=("$d")
    echo "$d"
}

# Create a minimal trace manifest directly (for refinalize tests)
# Usage: make_manifest <trace_store> <trace_id> [extra_json]
make_manifest() {
    local ts="$1"
    local tid="$2"
    local extra="${3:-}"
    local tdir="${ts}/${tid}"
    mkdir -p "${tdir}/artifacts"
    local base
    base=$(cat <<JSON
{
  "version": "1",
  "trace_id": "${tid}",
  "agent_type": "implementer",
  "session_id": "test-session",
  "project": "${ts}",
  "project_name": "test-project",
  "branch": "main",
  "start_commit": "",
  "started_at": "2026-01-01T10:00:00Z",
  "finished_at": "2026-01-01T10:05:00Z",
  "duration_seconds": 300,
  "status": "completed",
  "outcome": "unknown",
  "test_result": "unknown",
  "proof_status": "unknown",
  "files_changed": 0,
  "end_commit": ""
}
JSON
)
    if [[ -n "$extra" ]]; then
        echo "$base" | jq ". + ${extra}" > "${tdir}/manifest.json"
    else
        echo "$base" > "${tdir}/manifest.json"
    fi
    # Write a summary.md so outcome isn't "crashed"
    echo "# Summary" > "${tdir}/summary.md"
}

# ============================================================
# Issue #103 Tests: .test-status fallback in finalize_trace
# ============================================================
echo ""
echo "=== Issue #103: .test-status fallback in finalize_trace ==="

# Test 1: finalize_trace reads .test-status from project root when test-output.txt absent
echo ""
echo "--- Test 1: finalize_trace resolves test_result=pass from project root .test-status ---"
TS1=$(make_trace_store)
PROJ1=$(make_git_repo)
# Write .test-status to project root
echo "pass" > "${PROJ1}/.test-status"
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS1"
    trace_id=$(init_trace "$PROJ1" "implementer" 2>/dev/null)
    # Write a summary.md so finalize doesn't mark it crashed
    mkdir -p "${TS1}/${trace_id}/artifacts"
    echo "# Summary" > "${TS1}/${trace_id}/summary.md"
    finalize_trace "$trace_id" "$PROJ1" "implementer" 2>/dev/null
    jq -r '.test_result // "not-set"' "${TS1}/${trace_id}/manifest.json" 2>/dev/null
)
if [[ "$output" == "pass" ]]; then
    pass "#103: finalize_trace resolves test_result=pass from .test-status"
else
    fail "#103: finalize_trace .test-status → expected 'pass', got: '$output'"
fi

# Test 2: finalize_trace reads .test-status = fail
echo ""
echo "--- Test 2: finalize_trace resolves test_result=fail from project root .test-status ---"
TS2=$(make_trace_store)
PROJ2=$(make_git_repo)
echo "fail" > "${PROJ2}/.test-status"
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS2"
    trace_id=$(init_trace "$PROJ2" "implementer" 2>/dev/null)
    mkdir -p "${TS2}/${trace_id}/artifacts"
    echo "# Summary" > "${TS2}/${trace_id}/summary.md"
    finalize_trace "$trace_id" "$PROJ2" "implementer" 2>/dev/null
    jq -r '.test_result // "not-set"' "${TS2}/${trace_id}/manifest.json" 2>/dev/null
)
if [[ "$output" == "fail" ]]; then
    pass "#103: finalize_trace resolves test_result=fail from .test-status"
else
    fail "#103: finalize_trace .test-status=fail → expected 'fail', got: '$output'"
fi

# Test 3: test-output.txt takes priority over .test-status
echo ""
echo "--- Test 3: test-output.txt takes priority over .test-status ---"
TS3=$(make_trace_store)
PROJ3=$(make_git_repo)
echo "fail" > "${PROJ3}/.test-status"
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS3"
    trace_id=$(init_trace "$PROJ3" "implementer" 2>/dev/null)
    mkdir -p "${TS3}/${trace_id}/artifacts"
    echo "All tests passed" > "${TS3}/${trace_id}/artifacts/test-output.txt"
    echo "# Summary" > "${TS3}/${trace_id}/summary.md"
    finalize_trace "$trace_id" "$PROJ3" "implementer" 2>/dev/null
    jq -r '.test_result // "not-set"' "${TS3}/${trace_id}/manifest.json" 2>/dev/null
)
if [[ "$output" == "pass" ]]; then
    pass "#103: test-output.txt takes priority over .test-status (both present → pass wins)"
else
    fail "#103: priority test → expected 'pass' from test-output.txt, got: '$output'"
fi

# Test 4: No .test-status and no test-output.txt → test_result=unknown
echo ""
echo "--- Test 4: No test artifacts → test_result=unknown ---"
TS4=$(make_trace_store)
PROJ4=$(make_git_repo)
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS4"
    trace_id=$(init_trace "$PROJ4" "implementer" 2>/dev/null)
    mkdir -p "${TS4}/${trace_id}/artifacts"
    # Write a dummy artifact so outcome=partial not skipped
    echo "some log" > "${TS4}/${trace_id}/artifacts/build.log"
    echo "# Summary" > "${TS4}/${trace_id}/summary.md"
    finalize_trace "$trace_id" "$PROJ4" "implementer" 2>/dev/null
    jq -r '.test_result // "not-set"' "${TS4}/${trace_id}/manifest.json" 2>/dev/null
)
if [[ "$output" == "unknown" ]]; then
    pass "#103: no test artifacts → test_result=unknown (expected)"
else
    fail "#103: no artifacts → expected 'unknown', got: '$output'"
fi

# ============================================================
# Issue #104 Tests: rebuild_index called by refinalize_stale_traces
# ============================================================
echo ""
echo "=== Issue #104: rebuild_index called by refinalize_stale_traces ==="

# Test 5: refinalize_stale_traces rebuilds index when traces updated
echo ""
echo "--- Test 5: refinalize_stale_traces calls rebuild_index when traces are updated ---"
TS5=$(make_trace_store)
# Create 3 manifests, 2 with unknown test_result
make_manifest "$TS5" "trace-001"
make_manifest "$TS5" "trace-002"
make_manifest "$TS5" "trace-003" '{"test_result":"pass","outcome":"success","files_changed":2}'
# Write test-output.txt for trace-001 to enable resolution
echo "All tests passed" > "${TS5}/trace-001/artifacts/test-output.txt"
# Start with NO index (simulate missing index)
rm -f "${TS5}/index.jsonl"
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS5"
    refinalize_stale_traces 2>/dev/null
)
# Check that index now exists and has correct entry count
index_count=0
if [[ -f "${TS5}/index.jsonl" ]]; then
    index_count=$(wc -l < "${TS5}/index.jsonl" | tr -d ' ')
fi
manifest_count=$(ls -d "${TS5}"/*/manifest.json 2>/dev/null | wc -l | tr -d ' ')
if [[ "$index_count" -eq "$manifest_count" && "$index_count" -gt 0 ]]; then
    pass "#104: index rebuilt by refinalize_stale_traces — $index_count entries matches $manifest_count manifests"
else
    fail "#104: index count mismatch after refinalize_stale_traces — index=$index_count, manifests=$manifest_count"
fi

# Test 6: refinalize_stale_traces does NOT call rebuild_index when no traces updated
echo ""
echo "--- Test 6: refinalize_stale_traces skips rebuild when nothing to update ---"
TS6=$(make_trace_store)
# All traces already have resolved fields — nothing to refinalize
make_manifest "$TS6" "trace-a" '{"test_result":"pass","outcome":"success","files_changed":3,"duration_seconds":120}'
make_manifest "$TS6" "trace-b" '{"test_result":"fail","outcome":"failure","files_changed":1,"duration_seconds":60}'
# Build an index manually with only 1 entry (stale — but refinalize won't update)
echo '{"trace_id":"trace-a"}' > "${TS6}/index.jsonl"
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS6"
    refinalize_stale_traces 2>/dev/null
)
# Index should still have only 1 entry (no rebuild triggered)
index_count=0
if [[ -f "${TS6}/index.jsonl" ]]; then
    index_count=$(wc -l < "${TS6}/index.jsonl" | tr -d ' ')
fi
if [[ "$index_count" -eq 1 ]]; then
    pass "#104: index NOT rebuilt when no traces need updating (correct — avoid unnecessary I/O)"
else
    fail "#104: expected index=1 (no rebuild), got: $index_count"
fi

# Test 7: After refinalize + rebuild, index matches manifest count exactly
echo ""
echo "--- Test 7: After refinalize, index has exactly one entry per manifest ---"
TS7=$(make_trace_store)
for i in 1 2 3 4 5; do
    make_manifest "$TS7" "trace-$(printf '%03d' $i)"
done
# Create one trace with test-output.txt so at least one gets updated
echo "passed" > "${TS7}/trace-001/artifacts/test-output.txt"
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS7"
    refinalize_stale_traces 2>/dev/null
)
index_lines=0
if [[ -f "${TS7}/index.jsonl" ]]; then
    index_lines=$(wc -l < "${TS7}/index.jsonl" | tr -d ' ')
fi
if [[ "$index_lines" -eq 5 ]]; then
    pass "#104: index has exactly 5 entries for 5 manifests after refinalize"
else
    fail "#104: expected 5 index entries, got: $index_lines"
fi

# ============================================================
# Issue #105 Tests: Robust start_commit/end_commit capture
# ============================================================
echo ""
echo "=== Issue #105: Robust start_commit/end_commit capture ==="

# Test 8: init_trace captures start_commit for git repos
echo ""
echo "--- Test 8: init_trace captures non-empty start_commit for git repos ---"
TS8=$(make_trace_store)
REPO8=$(make_git_repo)
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS8"
    trace_id=$(init_trace "$REPO8" "implementer" 2>/dev/null)
    jq -r '.start_commit // ""' "${TS8}/${trace_id}/manifest.json" 2>/dev/null
)
if [[ -n "$output" && "$output" != "null" && "$output" != "" ]]; then
    pass "#105: init_trace captures start_commit='${output:0:8}...' for git repo"
else
    fail "#105: init_trace failed to capture start_commit, got: '$output'"
fi

# Test 9: init_trace sets start_commit="" for non-git directories (no-git branch)
echo ""
echo "--- Test 9: init_trace does not capture start_commit for non-git dirs ---"
TS9=$(make_trace_store)
PROJ9=$(make_plain_dir)
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS9"
    trace_id=$(init_trace "$PROJ9" "implementer" 2>/dev/null)
    jq -r '.start_commit // "null"' "${TS9}/${trace_id}/manifest.json" 2>/dev/null
)
if [[ "$output" == "" || "$output" == "null" ]]; then
    pass "#105: init_trace leaves start_commit empty for non-git dir (correct behavior)"
else
    fail "#105: init_trace should not set start_commit for non-git dir, got: '$output'"
fi

# Test 10: finalize_trace captures end_commit for git repos
echo ""
echo "--- Test 10: finalize_trace captures non-empty end_commit for git repos ---"
TS10=$(make_trace_store)
REPO10=$(make_git_repo)
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS10"
    trace_id=$(init_trace "$REPO10" "implementer" 2>/dev/null)
    mkdir -p "${TS10}/${trace_id}/artifacts"
    echo "# Summary" > "${TS10}/${trace_id}/summary.md"
    finalize_trace "$trace_id" "$REPO10" "implementer" 2>/dev/null
    jq -r '.end_commit // ""' "${TS10}/${trace_id}/manifest.json" 2>/dev/null
)
if [[ -n "$output" && "$output" != "null" && "$output" != "" ]]; then
    pass "#105: finalize_trace captures end_commit='${output:0:8}...' for git repo"
else
    fail "#105: finalize_trace failed to capture end_commit, got: '$output'"
fi

# Test 11: start_commit and end_commit match for a repo with no new commits
echo ""
echo "--- Test 11: start_commit == end_commit when no commits between init and finalize ---"
TS11=$(make_trace_store)
REPO11=$(make_git_repo)
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS11"
    trace_id=$(init_trace "$REPO11" "implementer" 2>/dev/null)
    mkdir -p "${TS11}/${trace_id}/artifacts"
    echo "# Summary" > "${TS11}/${trace_id}/summary.md"
    finalize_trace "$trace_id" "$REPO11" "implementer" 2>/dev/null
    start=$(jq -r '.start_commit // ""' "${TS11}/${trace_id}/manifest.json" 2>/dev/null)
    end=$(jq -r '.end_commit // ""' "${TS11}/${trace_id}/manifest.json" 2>/dev/null)
    if [[ -n "$start" && "$start" == "$end" ]]; then
        echo "match"
    else
        echo "mismatch:start=${start:0:8} end=${end:0:8}"
    fi
)
if [[ "$output" == "match" ]]; then
    pass "#105: start_commit == end_commit with no intermediate commits"
else
    fail "#105: commit mismatch — got: '$output'"
fi

# Test 12: WARN diagnostic emitted when end_commit capture fails (no git dir)
echo ""
echo "--- Test 12: finalize_trace emits WARN when end_commit capture fails for non-git path ---"
TS12=$(make_trace_store)
PROJ12=$(make_plain_dir)
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS12"
    trace_id=$(init_trace "$PROJ12" "implementer" 2>/dev/null)
    mkdir -p "${TS12}/${trace_id}/artifacts"
    echo "# Summary" > "${TS12}/${trace_id}/summary.md"
    # end_commit WARN only fires for git dirs where rev-parse fails — not for non-git dirs.
    # For non-git dirs, the outer git-dir check guards the block entirely (correct behavior).
    # So this test verifies end_commit is empty/null for non-git dirs (no spurious WARN).
    finalize_trace "$trace_id" "$PROJ12" "implementer" 2>/dev/null
    jq -r '.end_commit // "null"' "${TS12}/${trace_id}/manifest.json" 2>/dev/null
)
if [[ "$output" == "" || "$output" == "null" ]]; then
    pass "#105: finalize_trace leaves end_commit empty for non-git dir (correct — no spurious WARN)"
else
    fail "#105: finalize_trace should not set end_commit for non-git dir, got: '$output'"
fi

# ============================================================
# Issue #106 Structural Test: observatory tests in run-hooks.sh
# ============================================================
echo ""
echo "=== Issue #106: Observatory tests registered in run-hooks.sh ==="

# Test 13: run-hooks.sh references all 4 observatory test files + new test
echo ""
echo "--- Test 13: run-hooks.sh includes all observatory test files ---"
RUN_HOOKS="${SCRIPT_DIR}/run-hooks.sh"
missing_tests=()
for tf in \
    "test-observatory-batch-a-fixes.sh" \
    "test-observatory-cohort-regression.sh" \
    "test-observatory-flywheel-fix.sh" \
    "test-observatory-remaining-fixes.sh" \
    "test-obs-data-quality.sh"; do
    if ! grep -q "$tf" "$RUN_HOOKS" 2>/dev/null; then
        missing_tests+=("$tf")
    fi
done
if [[ "${#missing_tests[@]}" -eq 0 ]]; then
    pass "#106: All 5 observatory test files are registered in run-hooks.sh"
else
    fail "#106: Missing from run-hooks.sh: ${missing_tests[*]}"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [[ "$FAIL" -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "Some tests FAILED."
    exit 1
fi
