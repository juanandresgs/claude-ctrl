#!/usr/bin/env bash
# test-obs-data-quality.sh — Tests for Observatory Data Quality Fixes (v2)
#
# Purpose: Verify data quality behavior after Observatory v2 refactor:
#   - #103: finalize_trace reads test_result from compliance.json (not .test-status)
#           Without compliance.json → test_result="not-provided" (not "unknown")
#   - #105: Robust start_commit/end_commit capture with diagnostic logging
#   - #106: Observatory tests included in run-hooks.sh (structural, not a runtime test)
#
# NOTE: Issue #104 (refinalize_stale_traces) tests were removed. refinalize_stale_traces()
# and refinalize_trace() were deleted in Observatory v2 — replaced by compliance.json
# recording in check-*.sh hooks. (DEC-OBS-V2-002)
#
# @decision DEC-OBS-DATA-QUALITY-001
# @title Unit tests for observatory data quality behavior (issues #103, #105–#106)
# @status accepted
# @rationale The Observatory v2 refactor simplified finalize_trace to read from
#   compliance.json exclusively. These tests verify the new contract: (1) with
#   compliance.json present, finalize_trace reads test_result from it; (2) without
#   compliance.json, test_result="not-provided" (the explicit "no data" signal).
#   Tests #104 (refinalize_stale_traces) were deleted because that function no longer
#   exists in context-lib.sh. Tests use mktemp -d and trap cleanup, following the same
#   pattern as test-observatory-batch-a-fixes.sh.
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

# Write a compliance.json fixture to a trace directory.
# Usage: write_compliance_json <trace_dir> <test_result>
# Simulates what check-implementer.sh writes at agent boundary.
write_compliance_json() {
    local trace_dir="$1"
    local test_result="$2"
    cat > "${trace_dir}/compliance.json" <<JSON
{
  "agent_type": "implementer",
  "checked_at": "2026-02-21T03:00:00Z",
  "artifacts": {
    "summary.md": {"present": true, "source": "agent"},
    "test-output.txt": {"present": true, "source": "auto-capture"}
  },
  "test_result": "${test_result}",
  "test_result_source": ".test-status",
  "issues_count": 0
}
JSON
}

# ============================================================
# Issue #103 Tests: finalize_trace reads compliance.json
# ============================================================
echo ""
echo "=== Issue #103: finalize_trace reads test_result from compliance.json ==="

# Test 1: finalize_trace reads test_result=pass from compliance.json
echo ""
echo "--- Test 1: finalize_trace resolves test_result=pass from compliance.json ---"
TS1=$(make_trace_store)
PROJ1=$(make_git_repo)
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS1"
    trace_id=$(init_trace "$PROJ1" "implementer" 2>/dev/null)
    mkdir -p "${TS1}/${trace_id}/artifacts"
    echo "# Summary" > "${TS1}/${trace_id}/summary.md"
    # Write compliance.json simulating what check-implementer.sh writes
    write_compliance_json "${TS1}/${trace_id}" "pass"
    finalize_trace "$trace_id" "$PROJ1" "implementer" 2>/dev/null
    jq -r '.test_result // "not-set"' "${TS1}/${trace_id}/manifest.json" 2>/dev/null
)
if [[ "$output" == "pass" ]]; then
    pass "#103: finalize_trace resolves test_result=pass from compliance.json"
else
    fail "#103: finalize_trace compliance.json=pass → expected 'pass', got: '$output'"
fi

# Test 2: finalize_trace reads test_result=fail from compliance.json
echo ""
echo "--- Test 2: finalize_trace resolves test_result=fail from compliance.json ---"
TS2=$(make_trace_store)
PROJ2=$(make_git_repo)
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS2"
    trace_id=$(init_trace "$PROJ2" "implementer" 2>/dev/null)
    mkdir -p "${TS2}/${trace_id}/artifacts"
    echo "# Summary" > "${TS2}/${trace_id}/summary.md"
    write_compliance_json "${TS2}/${trace_id}" "fail"
    finalize_trace "$trace_id" "$PROJ2" "implementer" 2>/dev/null
    jq -r '.test_result // "not-set"' "${TS2}/${trace_id}/manifest.json" 2>/dev/null
)
if [[ "$output" == "fail" ]]; then
    pass "#103: finalize_trace resolves test_result=fail from compliance.json"
else
    fail "#103: finalize_trace compliance.json=fail → expected 'fail', got: '$output'"
fi

# Test 3: compliance.json is the single source of truth — no .test-status fallback
echo ""
echo "--- Test 3: compliance.json is single source of truth (no .test-status fallback) ---"
TS3=$(make_trace_store)
PROJ3=$(make_git_repo)
# Write .test-status to project root — this should be IGNORED by finalize_trace
echo "fail" > "${PROJ3}/.test-status"
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS3"
    trace_id=$(init_trace "$PROJ3" "implementer" 2>/dev/null)
    mkdir -p "${TS3}/${trace_id}/artifacts"
    echo "# Summary" > "${TS3}/${trace_id}/summary.md"
    # compliance.json says pass; .test-status says fail — compliance.json wins
    write_compliance_json "${TS3}/${trace_id}" "pass"
    finalize_trace "$trace_id" "$PROJ3" "implementer" 2>/dev/null
    jq -r '.test_result // "not-set"' "${TS3}/${trace_id}/manifest.json" 2>/dev/null
)
if [[ "$output" == "pass" ]]; then
    pass "#103: compliance.json takes priority over .test-status (single source of truth)"
else
    fail "#103: compliance.json priority → expected 'pass', got: '$output'"
fi

# Test 4: No compliance.json → test_result="not-provided" (explicit no-data signal)
echo ""
echo "--- Test 4: No compliance.json → test_result=not-provided (explicit no-data signal) ---"
TS4=$(make_trace_store)
PROJ4=$(make_git_repo)
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS4"
    trace_id=$(init_trace "$PROJ4" "implementer" 2>/dev/null)
    mkdir -p "${TS4}/${trace_id}/artifacts"
    # test-output.txt present but no compliance.json — finalize_trace should NOT read it
    echo "All tests passed" > "${TS4}/${trace_id}/artifacts/test-output.txt"
    echo "# Summary" > "${TS4}/${trace_id}/summary.md"
    # deliberately NO compliance.json
    finalize_trace "$trace_id" "$PROJ4" "implementer" 2>/dev/null
    jq -r '.test_result // "not-set"' "${TS4}/${trace_id}/manifest.json" 2>/dev/null
)
if [[ "$output" == "not-provided" ]]; then
    pass "#103: no compliance.json → test_result=not-provided (correct explicit no-data signal)"
else
    fail "#103: no compliance.json → expected 'not-provided', got: '$output'"
fi

# ============================================================
# Issue #105 Tests: Robust start_commit/end_commit capture
# ============================================================
echo ""
echo "=== Issue #105: Robust start_commit/end_commit capture ==="

# Test 5: init_trace captures start_commit for git repos
echo ""
echo "--- Test 5: init_trace captures non-empty start_commit for git repos ---"
TS5=$(make_trace_store)
REPO5=$(make_git_repo)
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS5"
    trace_id=$(init_trace "$REPO5" "implementer" 2>/dev/null)
    jq -r '.start_commit // ""' "${TS5}/${trace_id}/manifest.json" 2>/dev/null
)
if [[ -n "$output" && "$output" != "null" && "$output" != "" ]]; then
    pass "#105: init_trace captures start_commit='${output:0:8}...' for git repo"
else
    fail "#105: init_trace failed to capture start_commit, got: '$output'"
fi

# Test 6: init_trace sets start_commit="" for non-git directories (no-git branch)
echo ""
echo "--- Test 6: init_trace does not capture start_commit for non-git dirs ---"
TS6=$(make_trace_store)
PROJ6=$(make_plain_dir)
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS6"
    trace_id=$(init_trace "$PROJ6" "implementer" 2>/dev/null)
    jq -r '.start_commit // "null"' "${TS6}/${trace_id}/manifest.json" 2>/dev/null
)
if [[ "$output" == "" || "$output" == "null" ]]; then
    pass "#105: init_trace leaves start_commit empty for non-git dir (correct behavior)"
else
    fail "#105: init_trace should not set start_commit for non-git dir, got: '$output'"
fi

# Test 7: finalize_trace captures end_commit for git repos
echo ""
echo "--- Test 7: finalize_trace captures non-empty end_commit for git repos ---"
TS7=$(make_trace_store)
REPO7=$(make_git_repo)
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS7"
    trace_id=$(init_trace "$REPO7" "implementer" 2>/dev/null)
    mkdir -p "${TS7}/${trace_id}/artifacts"
    echo "# Summary" > "${TS7}/${trace_id}/summary.md"
    finalize_trace "$trace_id" "$REPO7" "implementer" 2>/dev/null
    jq -r '.end_commit // ""' "${TS7}/${trace_id}/manifest.json" 2>/dev/null
)
if [[ -n "$output" && "$output" != "null" && "$output" != "" ]]; then
    pass "#105: finalize_trace captures end_commit='${output:0:8}...' for git repo"
else
    fail "#105: finalize_trace failed to capture end_commit, got: '$output'"
fi

# Test 8: start_commit and end_commit match for a repo with no new commits
echo ""
echo "--- Test 8: start_commit == end_commit when no commits between init and finalize ---"
TS8=$(make_trace_store)
REPO8=$(make_git_repo)
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS8"
    trace_id=$(init_trace "$REPO8" "implementer" 2>/dev/null)
    mkdir -p "${TS8}/${trace_id}/artifacts"
    echo "# Summary" > "${TS8}/${trace_id}/summary.md"
    finalize_trace "$trace_id" "$REPO8" "implementer" 2>/dev/null
    start=$(jq -r '.start_commit // ""' "${TS8}/${trace_id}/manifest.json" 2>/dev/null)
    end=$(jq -r '.end_commit // ""' "${TS8}/${trace_id}/manifest.json" 2>/dev/null)
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

# Test 9: WARN diagnostic emitted when end_commit capture fails (no git dir)
echo ""
echo "--- Test 9: finalize_trace leaves end_commit empty for non-git dirs ---"
TS9=$(make_trace_store)
PROJ9=$(make_plain_dir)
output=$(
    source "${HOOKS_DIR}/log.sh"
    source "${HOOKS_DIR}/context-lib.sh"
    TRACE_STORE="$TS9"
    trace_id=$(init_trace "$PROJ9" "implementer" 2>/dev/null)
    mkdir -p "${TS9}/${trace_id}/artifacts"
    echo "# Summary" > "${TS9}/${trace_id}/summary.md"
    # end_commit WARN only fires for git dirs where rev-parse fails — not for non-git dirs.
    # For non-git dirs, the outer git-dir check guards the block entirely (correct behavior).
    # So this test verifies end_commit is empty/null for non-git dirs (no spurious WARN).
    finalize_trace "$trace_id" "$PROJ9" "implementer" 2>/dev/null
    jq -r '.end_commit // "null"' "${TS9}/${trace_id}/manifest.json" 2>/dev/null
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

# Test 10: run-hooks.sh references all observatory test files
echo ""
echo "--- Test 10: run-hooks.sh includes all observatory test files ---"
RUN_HOOKS="${SCRIPT_DIR}/run-hooks.sh"
missing_tests=()
for tf in \
    "test-observatory-metrics.sh" \
    "test-observatory-convergence.sh" \
    "test-obs-data-quality.sh" \
    "test-obs-pipeline.sh"; do
    if ! grep -q "$tf" "$RUN_HOOKS" 2>/dev/null; then
        missing_tests+=("$tf")
    fi
done
if [[ "${#missing_tests[@]}" -eq 0 ]]; then
    pass "#106: All observatory test files are registered in run-hooks.sh"
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
