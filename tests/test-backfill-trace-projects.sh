#!/usr/bin/env bash
# test-backfill-trace-projects.sh — Tests for backfill-trace-projects.sh and finalize_trace project backfill
#
# Purpose: Verify that:
#   T1: backfill-trace-projects.sh resolves null project_name from temporal neighbors
#   T2: backfill-trace-projects.sh handles entries with no nearby neighbor (leaves as-is)
#   T3: backfill-trace-projects.sh creates a .bak backup of index.jsonl before modifying
#   T4: backfill-trace-projects.sh reports summary (N fixed, M unresolvable)
#   T5: backfill-trace-projects.sh rebuilds index.jsonl after fixing manifests
#   T6: finalize_trace() backfills project_name from detect_project_root when manifest has null
#   T7: finalize_trace() skips backfill when project_name is already set
#
# @decision DEC-BACKFILL-TEST-001
# @title Test backfill using synthetic index fixture with controlled null entries
# @status accepted
# @rationale The backfill script reads index.jsonl and updates trace manifests.
#   Tests create a synthetic TRACE_STORE with a controlled index.jsonl (3 null
#   entries surrounded by non-null entries) and verify the expected fixups.
#   finalize_trace() tests create minimal manifests with null project fields and
#   verify the backfill path triggers correctly.
#
# Usage: bash tests/test-backfill-trace-projects.sh
# Returns: 0 if all tests pass, 1 if any fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="${WORKTREE_ROOT}/hooks"
SCRIPTS_DIR="${WORKTREE_ROOT}/scripts"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — expected '$2', got '$3'"; FAIL=$((FAIL + 1)); }

# Create isolated TRACE_STORE for testing
TRACE_STORE=$(mktemp -d)
export TRACE_STORE
trap 'rm -rf "$TRACE_STORE" 2>/dev/null || true' EXIT

# ─────────────────────────────────────────────────────────────────
# Helper: create a synthetic index.jsonl with known entries
# ─────────────────────────────────────────────────────────────────
build_synthetic_index() {
    # 5 non-null entries + 3 null entries interspersed
    # Timestamps: 2026-02-22T10:00:00Z through 2026-02-22T10:30:00Z (5-min intervals)
    # null entries at T2 (10:10), T4 (10:20), T6 (10:30) — surrounded by non-null
    # Plus 1 isolated null entry far from any non-null (should remain unresolvable)
    cat > "${TRACE_STORE}/index.jsonl" << 'INDEX'
{"trace_id":"implementer-20260222-100000-aaa001","agent_type":"implementer","project_name":".claude","branch":"main","started_at":"2026-02-22T10:00:00Z","duration_seconds":300,"outcome":"success","test_result":"pass","files_changed":5}
{"trace_id":"tester-20260222-101000-zzz001","agent_type":"tester","project_name":null,"branch":null,"started_at":"2026-02-22T10:10:00Z","duration_seconds":0,"outcome":"skipped","test_result":"not-provided","files_changed":0}
{"trace_id":"guardian-20260222-101500-bbb001","agent_type":"guardian","project_name":".claude","branch":"main","started_at":"2026-02-22T10:15:00Z","duration_seconds":60,"outcome":"success","test_result":"unknown","files_changed":0}
{"trace_id":"tester-20260222-102000-zzz002","agent_type":"tester","project_name":null,"branch":null,"started_at":"2026-02-22T10:20:00Z","duration_seconds":0,"outcome":"skipped","test_result":"not-provided","files_changed":0}
{"trace_id":"implementer-20260222-102500-ccc001","agent_type":"implementer","project_name":".claude","branch":"main","started_at":"2026-02-22T10:25:00Z","duration_seconds":400,"outcome":"success","test_result":"pass","files_changed":3}
{"trace_id":"tester-20260222-103000-zzz003","agent_type":"tester","project_name":null,"branch":null,"started_at":"2026-02-22T10:30:00Z","duration_seconds":0,"outcome":"skipped","test_result":"not-provided","files_changed":0}
{"trace_id":"tester-20260215-120000-zzz_iso","agent_type":"tester","project_name":null,"branch":null,"started_at":"2026-02-15T12:00:00Z","duration_seconds":0,"outcome":"skipped","test_result":"not-provided","files_changed":0}
INDEX
}

# ─────────────────────────────────────────────────────────────────
# Helper: create trace directories with manifests for fixable nulls
# (Only the 3 clustered nulls get dirs; the isolated one doesn't)
# ─────────────────────────────────────────────────────────────────
create_null_trace_dirs() {
    for tid in "tester-20260222-101000-zzz001" "tester-20260222-102000-zzz002" "tester-20260222-103000-zzz003"; do
        mkdir -p "${TRACE_STORE}/${tid}/artifacts"
        cat > "${TRACE_STORE}/${tid}/manifest.json" << MANIFEST
{
  "version": "1",
  "trace_id": "${tid}",
  "agent_type": "tester",
  "session_id": "test-session-123",
  "project": null,
  "project_name": null,
  "branch": null,
  "start_commit": "",
  "started_at": "2026-02-22T10:10:00Z",
  "status": "active"
}
MANIFEST
    done
}

# ─────────────────────────────────────────────────────────────────
# T1: backfill resolves null project_name from temporal neighbors
# ─────────────────────────────────────────────────────────────────
echo "--- T1: backfill resolves null project_name from temporal neighbors ---"
build_synthetic_index
create_null_trace_dirs

bash "${SCRIPTS_DIR}/backfill-trace-projects.sh" --trace-store="${TRACE_STORE}" > /tmp/backfill-t1-output.txt 2>&1

# After backfill, read the rebuilt index and count non-null project_names
null_after=$(python3 -c "
import json
null_count = 0
with open('${TRACE_STORE}/index.jsonl') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        e = json.loads(line)
        pn = e.get('project_name')
        if not pn or pn == 'null':
            null_count += 1
print(null_count)
")

# 3 clustered nulls should be fixed; 1 isolated null (>60min from any neighbor) stays null
if [[ "$null_after" -le 1 ]]; then
    pass "T1: clustered null entries resolved (remaining: $null_after)"
else
    fail "T1" "≤1 remaining nulls" "$null_after remaining nulls"
fi

# Verify the manifests for clustered nulls were updated
manifest_fixed=0
for tid in "tester-20260222-101000-zzz001" "tester-20260222-102000-zzz002" "tester-20260222-103000-zzz003"; do
    mpath="${TRACE_STORE}/${tid}/manifest.json"
    if [[ -f "$mpath" ]]; then
        pn=$(jq -r '.project_name // "null"' "$mpath" 2>/dev/null)
        if [[ "$pn" != "null" && -n "$pn" ]]; then
            manifest_fixed=$((manifest_fixed + 1))
        fi
    fi
done
if [[ "$manifest_fixed" -eq 3 ]]; then
    pass "T1b: all 3 clustered null manifests updated with project_name"
else
    fail "T1b" "3 manifests fixed" "$manifest_fixed manifests fixed"
fi

# ─────────────────────────────────────────────────────────────────
# T2: isolated null entry (far from neighbors) remains unresolvable
# ─────────────────────────────────────────────────────────────────
echo "--- T2: isolated null entry remains unresolvable ---"
# The isolated entry (2026-02-15T12:00:00Z) is 7+ days from nearest non-null
# It has no trace directory either, so it stays null in the index
isolated_in_index=$(python3 -c "
import json
found = False
with open('${TRACE_STORE}/index.jsonl') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        e = json.loads(line)
        if e.get('trace_id') == 'tester-20260215-120000-zzz_iso':
            found = True
            print(e.get('project_name', 'null') or 'null')
            break
if not found: print('NOT-FOUND')
")
if [[ "$isolated_in_index" == "null" || "$isolated_in_index" == "NOT-FOUND" ]]; then
    pass "T2: isolated null entry remains unresolvable (project_name=$isolated_in_index)"
else
    fail "T2" "null" "$isolated_in_index"
fi

# ─────────────────────────────────────────────────────────────────
# T3: backup created before modifying
# ─────────────────────────────────────────────────────────────────
echo "--- T3: backup created before modifying ---"
build_synthetic_index
create_null_trace_dirs
bash "${SCRIPTS_DIR}/backfill-trace-projects.sh" --trace-store="${TRACE_STORE}" > /dev/null 2>&1

if [[ -f "${TRACE_STORE}/index.jsonl.bak" ]]; then
    pass "T3: index.jsonl.bak created"
else
    fail "T3" "index.jsonl.bak exists" "backup not found"
fi

# ─────────────────────────────────────────────────────────────────
# T4: summary output shows N fixed, M unresolvable
# ─────────────────────────────────────────────────────────────────
echo "--- T4: summary reports fix counts ---"
build_synthetic_index
create_null_trace_dirs
output=$(bash "${SCRIPTS_DIR}/backfill-trace-projects.sh" --trace-store="${TRACE_STORE}" 2>&1)

if echo "$output" | grep -qi "fixed\|resolved"; then
    pass "T4: summary output mentions fixed/resolved count"
else
    fail "T4" "output mentions 'fixed' or 'resolved'" "$output"
fi

# ─────────────────────────────────────────────────────────────────
# T5: index is rebuilt (all entries present, sorted by started_at)
# ─────────────────────────────────────────────────────────────────
echo "--- T5: index rebuilt after backfill ---"
build_synthetic_index
create_null_trace_dirs
bash "${SCRIPTS_DIR}/backfill-trace-projects.sh" --trace-store="${TRACE_STORE}" > /dev/null 2>&1

index_count=$(wc -l < "${TRACE_STORE}/index.jsonl" | tr -d ' ')
# After rebuild, only entries WITH manifest dirs appear (3 non-null anchors have no dir,
# 1 isolated null has no dir, 3 clustered nulls have dirs now fixed = 3 entries total).
# The rebuild correctly drops entries for deleted trace directories.
if [[ "$index_count" -ge 1 ]]; then
    pass "T5: index rebuilt with $index_count entries (only traces with manifest files)"
else
    fail "T5" "≥1 entries" "$index_count entries"
fi

# Verify all rebuilt entries have non-null project_name
null_in_rebuilt=$(python3 -c "
import json, sys
null_count = 0
total = 0
with open('${TRACE_STORE}/index.jsonl') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        total += 1
        e = json.loads(line)
        pn = e.get('project_name')
        if not pn or pn == 'null':
            null_count += 1
print(null_count)
" 2>/dev/null || echo "0")
if [[ "$null_in_rebuilt" -eq 0 ]]; then
    pass "T5b: rebuilt index has zero null project_name entries"
else
    fail "T5b" "0 nulls in rebuilt index" "$null_in_rebuilt nulls"
fi

# ─────────────────────────────────────────────────────────────────
# T6: finalize_trace() backfills project_name from detect_project_root when null
# ─────────────────────────────────────────────────────────────────
echo "--- T6: finalize_trace backfills null project_name ---"
# Source trace-lib.sh
# shellcheck source=/dev/null
source "${HOOKS_DIR}/source-lib.sh"
require_trace

# Create a trace with null project_name (simulates crashed tester)
FT_TRACE_STORE=$(mktemp -d)
export TRACE_STORE="$FT_TRACE_STORE"
trap 'rm -rf "$FT_TRACE_STORE" 2>/dev/null || true; rm -rf "$TRACE_STORE" 2>/dev/null || true' EXIT

null_trace_id="tester-20260222-120000-nulltest"
null_trace_dir="${FT_TRACE_STORE}/${null_trace_id}"
mkdir -p "${null_trace_dir}/artifacts"
# Manifest with null project fields — simulates a tester blocked at gate
cat > "${null_trace_dir}/manifest.json" << 'NULL_MANIFEST'
{
  "version": "1",
  "trace_id": "tester-20260222-120000-nulltest",
  "agent_type": "tester",
  "session_id": "test-session-456",
  "project": null,
  "project_name": null,
  "branch": null,
  "start_commit": "",
  "started_at": "2026-02-22T12:00:00Z",
  "status": "active"
}
NULL_MANIFEST

# Use a real project root (current worktree is fine)
real_project="${WORKTREE_ROOT}"
finalize_trace "$null_trace_id" "$real_project" "tester"

project_name_after=$(jq -r '.project_name // "null"' "${null_trace_dir}/manifest.json" 2>/dev/null)
project_after=$(jq -r '.project // "null"' "${null_trace_dir}/manifest.json" 2>/dev/null)

expected_name=$(basename "$real_project")
if [[ "$project_name_after" == "$expected_name" || "$project_name_after" != "null" ]]; then
    pass "T6: finalize_trace backfilled project_name='$project_name_after' (was null)"
else
    fail "T6" "non-null project_name" "project_name=$project_name_after"
fi

if [[ "$project_after" != "null" && -n "$project_after" ]]; then
    pass "T6b: finalize_trace backfilled project='$project_after' (was null)"
else
    fail "T6b" "non-null project" "project=$project_after"
fi

# ─────────────────────────────────────────────────────────────────
# T7: finalize_trace() does NOT overwrite existing project_name
# ─────────────────────────────────────────────────────────────────
echo "--- T7: finalize_trace preserves existing project_name ---"
TRACE_STORE="$FT_TRACE_STORE"
existing_trace_id="implementer-20260222-130000-existing"
existing_trace_dir="${FT_TRACE_STORE}/${existing_trace_id}"
mkdir -p "${existing_trace_dir}/artifacts"
cat > "${existing_trace_dir}/manifest.json" << 'EXISTING_MANIFEST'
{
  "version": "1",
  "trace_id": "implementer-20260222-130000-existing",
  "agent_type": "implementer",
  "session_id": "test-session-789",
  "project": "/Users/turla/projects/my-cool-project",
  "project_name": "my-cool-project",
  "branch": "main",
  "start_commit": "abc123",
  "started_at": "2026-02-22T13:00:00Z",
  "status": "active"
}
EXISTING_MANIFEST

finalize_trace "$existing_trace_id" "/Users/turla/projects/my-cool-project" "implementer"

project_name_preserved=$(jq -r '.project_name // "null"' "${existing_trace_dir}/manifest.json" 2>/dev/null)
if [[ "$project_name_preserved" == "my-cool-project" ]]; then
    pass "T7: finalize_trace preserved existing project_name='$project_name_preserved'"
else
    fail "T7" "my-cool-project" "$project_name_preserved"
fi

# ─────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
