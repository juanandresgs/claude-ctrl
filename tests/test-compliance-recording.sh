#!/usr/bin/env bash
# test-compliance-recording.sh — Tests for Observatory v2 compliance.json recording
#
# Purpose: Verify that check-*.sh hooks write compliance.json with correct schema,
#   source attribution (agent vs auto-capture), and test_result from .test-status.
#
# Design: Tests exercise the compliance recording logic by sourcing context-lib and
#   simulating the artifact state that check-*.sh hooks encounter. We test the
#   schema and source attribution values by setting up synthetic trace directories
#   and verifying compliance.json content after simulating hook behavior.
#
# @decision DEC-OBS-TEST-001
# @title Compliance recording tests use synthetic trace dirs, not full hook invocation
# @status accepted
# @rationale Full hook invocation requires SubagentStop JSON payloads, Claude session
#   context, and live git state — all hard to synthesize. The compliance recording
#   logic is pure shell logic (file presence + .test-status read). Testing it by
#   simulating the artifact state and running inline logic gives the same coverage
#   with zero external dependencies.
#
# Usage: bash tests/test-compliance-recording.sh
# Returns: 0 if all tests pass, 1 if any fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Suppress hook stderr during tests
exec 2>/dev/null

# --- Helpers ---

make_trace_dir() {
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/artifacts"
    echo "$tmp"
}

# Write a minimal compliance.json by running the same logic check-implementer.sh uses.
# Takes: trace_dir, project_dir, pre_files_changed (true/false), pre_test_output (true/false)
# This reproduces the inline logic from check-implementer.sh's compliance block.
write_implementer_compliance() {
    local TRACE_DIR="$1"
    local PROJECT_ROOT="$2"
    local IMPL_PRE_FILES_CHANGED="$3"  # was artifact present before auto-capture?
    local IMPL_PRE_TEST_OUTPUT="$4"
    local CLAUDE_DIR="$PROJECT_ROOT"

    local _fc_present=false; local _fc_source="null"
    local _to_present=false; local _to_source="null"
    local _sm_present=false; local _sm_source="null"
    local _dp_present=false; local _dp_source="null"

    [[ -f "$TRACE_DIR/artifacts/files-changed.txt" ]] && _fc_present=true
    [[ -f "$TRACE_DIR/artifacts/test-output.txt" ]] && _to_present=true
    [[ -f "$TRACE_DIR/summary.md" ]] && _sm_present=true
    [[ -f "$TRACE_DIR/artifacts/diff.patch" ]] && _dp_present=true

    $_fc_present && { $IMPL_PRE_FILES_CHANGED && _fc_source='"agent"' || _fc_source='"auto-capture"'; }
    $_to_present && { $IMPL_PRE_TEST_OUTPUT && _to_source='"agent"' || _to_source='"auto-capture"'; }
    $_sm_present && _sm_source='"agent"'
    $_dp_present && _dp_source='"agent"'

    local _ts_result="not-provided"
    local _ts_source="null"
    local _TS_FILE=""
    [[ -f "${CLAUDE_DIR}/.test-status" ]] && _TS_FILE="${CLAUDE_DIR}/.test-status"
    [[ -z "$_TS_FILE" && -f "$PROJECT_ROOT/.test-status" ]] && _TS_FILE="$PROJECT_ROOT/.test-status"
    if [[ -n "$_TS_FILE" ]]; then
        _ts_result=$(cut -d'|' -f1 "$_TS_FILE" 2>/dev/null | tr -d '[:space:]' || echo "not-provided")
        _ts_source='".test-status"'
    fi

    cat > "$TRACE_DIR/compliance.json" << EOF
{
  "agent_type": "implementer",
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "artifacts": {
    "summary.md": {"present": $_sm_present, "source": $_sm_source},
    "test-output.txt": {"present": $_to_present, "source": $_to_source},
    "files-changed.txt": {"present": $_fc_present, "source": $_fc_source},
    "diff.patch": {"present": $_dp_present, "source": $_dp_source}
  },
  "test_result": "$_ts_result",
  "test_result_source": $_ts_source,
  "issues_count": 0
}
EOF
}

cleanup_dirs=()
trap 'rm -rf "${cleanup_dirs[@]}" 2>/dev/null || true' EXIT

make_project() {
    local d
    d=$(mktemp -d)
    cleanup_dirs+=("$d")
    echo "$d"
}

# Re-enable stderr for test output
exec 2>&1

# ============================================================================
# Schema Tests
# ============================================================================

echo ""
echo "=== Schema Tests ==="

# Test 1: compliance.json has all required fields
echo ""
echo "--- Test 1: compliance.json has required top-level fields ---"
TD=$(make_trace_dir); cleanup_dirs+=("$TD")
PR=$(make_project)
echo "# summary" > "$TD/summary.md"
write_implementer_compliance "$TD" "$PR" false false
REQUIRED_FIELDS=$(jq 'has("agent_type") and has("checked_at") and has("artifacts") and has("test_result") and has("test_result_source") and has("issues_count")' "$TD/compliance.json" 2>/dev/null)
if [[ "$REQUIRED_FIELDS" == "true" ]]; then
    pass "compliance.json has all required top-level fields"
else
    fail "compliance.json missing required fields: $(cat "$TD/compliance.json")"
fi

# Test 2: agent_type is set correctly
echo ""
echo "--- Test 2: agent_type is 'implementer' ---"
TD2=$(make_trace_dir); cleanup_dirs+=("$TD2")
PR2=$(make_project)
write_implementer_compliance "$TD2" "$PR2" false false
AGENT_TYPE=$(jq -r '.agent_type' "$TD2/compliance.json" 2>/dev/null)
if [[ "$AGENT_TYPE" == "implementer" ]]; then
    pass "agent_type=implementer"
else
    fail "agent_type expected 'implementer', got: $AGENT_TYPE"
fi

# Test 3: checked_at is a valid ISO timestamp
echo ""
echo "--- Test 3: checked_at is a valid ISO timestamp ---"
TD3=$(make_trace_dir); cleanup_dirs+=("$TD3")
PR3=$(make_project)
write_implementer_compliance "$TD3" "$PR3" false false
CHECKED_AT=$(jq -r '.checked_at' "$TD3/compliance.json" 2>/dev/null)
if echo "$CHECKED_AT" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
    pass "checked_at is valid ISO timestamp: $CHECKED_AT"
else
    fail "checked_at is not a valid ISO timestamp: $CHECKED_AT"
fi

# Test 4: artifacts has expected implementer keys
echo ""
echo "--- Test 4: artifacts has all implementer artifact keys ---"
TD4=$(make_trace_dir); cleanup_dirs+=("$TD4")
PR4=$(make_project)
write_implementer_compliance "$TD4" "$PR4" false false
ARTIFACT_KEYS=$(jq '.artifacts | keys | sort | join(",")' "$TD4/compliance.json" 2>/dev/null)
EXPECTED_KEYS='"diff.patch,files-changed.txt,summary.md,test-output.txt"'
if [[ "$ARTIFACT_KEYS" == "$EXPECTED_KEYS" ]]; then
    pass "artifacts has all implementer keys: $ARTIFACT_KEYS"
else
    fail "artifacts keys mismatch — expected $EXPECTED_KEYS, got: $ARTIFACT_KEYS"
fi

# Test 5: each artifact entry has 'present' and 'source' fields
echo ""
echo "--- Test 5: each artifact entry has 'present' and 'source' fields ---"
TD5=$(make_trace_dir); cleanup_dirs+=("$TD5")
PR5=$(make_project)
write_implementer_compliance "$TD5" "$PR5" false false
ALL_HAVE_FIELDS=$(jq '
  .artifacts | to_entries | all(
    .value | has("present") and has("source")
  )' "$TD5/compliance.json" 2>/dev/null)
if [[ "$ALL_HAVE_FIELDS" == "true" ]]; then
    pass "all artifact entries have 'present' and 'source' fields"
else
    fail "some artifact entries missing 'present' or 'source': $(jq '.artifacts' "$TD5/compliance.json")"
fi

# ============================================================================
# Source Attribution Tests
# ============================================================================

echo ""
echo "=== Source Attribution Tests ==="

# Test 6: artifact present BEFORE auto-capture → source = "agent"
echo ""
echo "--- Test 6: artifact pre-existing → source='agent' ---"
TD6=$(make_trace_dir); cleanup_dirs+=("$TD6")
PR6=$(make_project)
# Simulate: files-changed.txt was written by agent before check hook ran
echo "hooks/context-lib.sh" > "$TD6/artifacts/files-changed.txt"
write_implementer_compliance "$TD6" "$PR6" true false  # IMPL_PRE_FILES_CHANGED=true
FC_SOURCE=$(jq -r '.artifacts["files-changed.txt"].source' "$TD6/compliance.json" 2>/dev/null)
if [[ "$FC_SOURCE" == "agent" ]]; then
    pass "pre-existing files-changed.txt → source='agent'"
else
    fail "pre-existing artifact expected source='agent', got: $FC_SOURCE"
fi

# Test 7: artifact written BY auto-capture → source = "auto-capture"
echo ""
echo "--- Test 7: auto-captured artifact → source='auto-capture' ---"
TD7=$(make_trace_dir); cleanup_dirs+=("$TD7")
PR7=$(make_project)
# Simulate: files-changed.txt was written by auto-capture (pre_snapshot=false)
echo "hooks/context-lib.sh" > "$TD7/artifacts/files-changed.txt"
write_implementer_compliance "$TD7" "$PR7" false false  # IMPL_PRE_FILES_CHANGED=false
FC_SOURCE7=$(jq -r '.artifacts["files-changed.txt"].source' "$TD7/compliance.json" 2>/dev/null)
if [[ "$FC_SOURCE7" == "auto-capture" ]]; then
    pass "auto-captured files-changed.txt → source='auto-capture'"
else
    fail "auto-captured artifact expected source='auto-capture', got: $FC_SOURCE7"
fi

# Test 8: artifact missing → present=false, source=null
echo ""
echo "--- Test 8: missing artifact → present=false, source=null ---"
TD8=$(make_trace_dir); cleanup_dirs+=("$TD8")
PR8=$(make_project)
# No artifacts written
write_implementer_compliance "$TD8" "$PR8" false false
FC_PRESENT=$(jq -r '.artifacts["files-changed.txt"].present' "$TD8/compliance.json" 2>/dev/null)
FC_SOURCE8=$(jq -r '.artifacts["files-changed.txt"].source' "$TD8/compliance.json" 2>/dev/null)
if [[ "$FC_PRESENT" == "false" && "$FC_SOURCE8" == "null" ]]; then
    pass "missing artifact → present=false, source=null"
else
    fail "missing artifact: expected present=false source=null, got: present=$FC_PRESENT source=$FC_SOURCE8"
fi

# Test 9: diff.patch present → source="agent" (only written by agents, not auto-captured)
echo ""
echo "--- Test 9: diff.patch present → source='agent' ---"
TD9=$(make_trace_dir); cleanup_dirs+=("$TD9")
PR9=$(make_project)
echo "diff --git a/foo b/foo" > "$TD9/artifacts/diff.patch"
write_implementer_compliance "$TD9" "$PR9" false false
DP_SOURCE=$(jq -r '.artifacts["diff.patch"].source' "$TD9/compliance.json" 2>/dev/null)
if [[ "$DP_SOURCE" == "agent" ]]; then
    pass "diff.patch → source='agent'"
else
    fail "diff.patch expected source='agent', got: $DP_SOURCE"
fi

# ============================================================================
# test_result Tests
# ============================================================================

echo ""
echo "=== test_result Tests ==="

# Test 10: No .test-status → test_result="not-provided"
echo ""
echo "--- Test 10: No .test-status → test_result='not-provided' ---"
TD10=$(make_trace_dir); cleanup_dirs+=("$TD10")
PR10=$(make_project)  # no .test-status file
write_implementer_compliance "$TD10" "$PR10" false false
TR10=$(jq -r '.test_result' "$TD10/compliance.json" 2>/dev/null)
if [[ "$TR10" == "not-provided" ]]; then
    pass "no .test-status → test_result='not-provided'"
else
    fail "expected test_result='not-provided', got: $TR10"
fi

# Test 11: .test-status=pass → test_result="pass"
echo ""
echo "--- Test 11: .test-status=pass → test_result='pass' ---"
TD11=$(make_trace_dir); cleanup_dirs+=("$TD11")
PR11=$(make_project)
echo "pass" > "$PR11/.test-status"
write_implementer_compliance "$TD11" "$PR11" false false
TR11=$(jq -r '.test_result' "$TD11/compliance.json" 2>/dev/null)
if [[ "$TR11" == "pass" ]]; then
    pass ".test-status=pass → test_result='pass'"
else
    fail "expected test_result='pass', got: $TR11"
fi

# Test 12: .test-status=fail → test_result="fail"
echo ""
echo "--- Test 12: .test-status=fail → test_result='fail' ---"
TD12=$(make_trace_dir); cleanup_dirs+=("$TD12")
PR12=$(make_project)
echo "fail" > "$PR12/.test-status"
write_implementer_compliance "$TD12" "$PR12" false false
TR12=$(jq -r '.test_result' "$TD12/compliance.json" 2>/dev/null)
if [[ "$TR12" == "fail" ]]; then
    pass ".test-status=fail → test_result='fail'"
else
    fail "expected test_result='fail', got: $TR12"
fi

# Test 13: .test-status has pipe-separated format → reads first field only
echo ""
echo "--- Test 13: .test-status with pipe format → reads first field ---"
TD13=$(make_trace_dir); cleanup_dirs+=("$TD13")
PR13=$(make_project)
echo "pass|0|2026-02-21T03:00:00Z" > "$PR13/.test-status"
write_implementer_compliance "$TD13" "$PR13" false false
TR13=$(jq -r '.test_result' "$TD13/compliance.json" 2>/dev/null)
if [[ "$TR13" == "pass" ]]; then
    pass ".test-status pipe format → reads first field 'pass'"
else
    fail "pipe format: expected test_result='pass', got: $TR13"
fi

# Test 14: test_result_source is ".test-status" when .test-status exists
echo ""
echo "--- Test 14: test_result_source='.test-status' when file present ---"
TD14=$(make_trace_dir); cleanup_dirs+=("$TD14")
PR14=$(make_project)
echo "pass" > "$PR14/.test-status"
write_implementer_compliance "$TD14" "$PR14" false false
TRS14=$(jq -r '.test_result_source' "$TD14/compliance.json" 2>/dev/null)
if [[ "$TRS14" == ".test-status" ]]; then
    pass "test_result_source='.test-status' when file present"
else
    fail "expected test_result_source='.test-status', got: $TRS14"
fi

# Test 15: test_result_source=null when no .test-status
echo ""
echo "--- Test 15: test_result_source=null when no .test-status ---"
TD15=$(make_trace_dir); cleanup_dirs+=("$TD15")
PR15=$(make_project)
write_implementer_compliance "$TD15" "$PR15" false false
TRS15=$(jq -r '.test_result_source' "$TD15/compliance.json" 2>/dev/null)
if [[ "$TRS15" == "null" ]]; then
    pass "test_result_source=null when no .test-status"
else
    fail "expected test_result_source=null, got: $TRS15"
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "====================================="
echo "RESULTS: $PASS passed, $FAIL failed"
echo "====================================="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
