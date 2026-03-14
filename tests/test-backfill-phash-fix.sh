#!/usr/bin/env bash
# test-backfill-phash-fix.sh — Tests for the project_hash backfill bug fix
#
# Purpose: Verify that backfill-token-history.sh assigns the correct path-based
# project_hash to backfilled entries by learning from live-written 7-column entries.
#
# Problem being fixed (DEC-BACKFILL-PHASH-002):
#   Old backfill code hashed the project_name (e.g., ".claude") instead of
#   the project root path (e.g., "/Users/turla/.claude"), producing the wrong
#   hash. Live-written entries have the correct path-based hash. The fix pre-scans
#   the history file to learn the correct hash, then uses it for backfilled entries.
#
# Tests:
#   T1: Backfilled entries adopt the correct hash from a live entry in the same file
#   T2: Backfilled entries with no live counterpart fall back to _phash(project_name)
#   T3: Already-7-column entries are unchanged (idempotent)
#   T4: Mixed file (live + backfilled + 5-col) all end up with consistent hashes
#   T5: Multiple project names each get the correct hash for their project
#
# @decision DEC-BACKFILL-PHASH-TEST-001
# @title Test phash fix using mock history file with mix of live and backfilled entries
# @status accepted
# @rationale The bug manifests only when a file has both live 7-column entries
#   (correct hash) and 5-column entries needing backfill. Tests create controlled
#   history files and trace indices to exercise the pre-scan logic without requiring
#   real session state. Python3 is used to verify hashes since it matches the
#   shasum-based _phash() implementation.
#
# Usage: bash tests/test-backfill-phash-fix.sh
# Returns: 0 if all tests pass, 1 if any fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPTS_DIR="${WORKTREE_ROOT}/scripts"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — expected '$2', got '$3'"; FAIL=$((FAIL + 1)); }

# Compute the correct path-based project_hash using the same algorithm as core-lib.sh
# and backfill-token-history.sh's _phash():
#   echo "$path" | shasum -a 256 | cut -c1-8
# Note: echo adds a trailing newline — this is intentional and matches both
# core-lib.sh's project_hash() and backfill's _phash(). Do NOT use printf '%s'.
_expected_phash() {
    local path="$1"
    echo "$path" | shasum -a 256 | cut -c1-8
}

# ─────────────────────────────────────────────────────────────────
# T1: Backfilled 5-column entry adopts the correct hash from a live 7-column entry
#     for the same project_name in the same file
# ─────────────────────────────────────────────────────────────────
echo "--- T1: backfilled entry adopts correct hash from live entry ---"

T1_DIR=$(mktemp -d)
trap 'rm -rf "$T1_DIR" 2>/dev/null || true' EXIT

# Live 7-column entry written by session-end.sh using hash(PROJECT_ROOT)
# PROJECT_ROOT = "/Users/turla/.claude", project_name = ".claude"
CORRECT_PHASH=$(_expected_phash "/Users/turla/.claude")
WRONG_PHASH=$(_expected_phash ".claude")

T1_HISTORY="${T1_DIR}/.session-token-history"
# A live entry (sid != "unknown") has the CORRECT path-based hash
echo "2026-01-10T10:00:00Z|50000|40000|10000|live-session-abc123|${CORRECT_PHASH}|.claude" > "$T1_HISTORY"
# A 5-column entry that needs backfill
echo "2026-01-10T09:50:00Z|30000|25000|5000|unknown" >> "$T1_HISTORY"

# Trace index: one entry within 30min of the 5-col entry
T1_TRACE="${T1_DIR}/trace-index.jsonl"
echo '{"trace_id":"implementer-20260110-095500-abc","agent_type":"implementer","project_name":".claude","session_id":"impl-session-001","started_at":"2026-01-10T09:55:00Z"}' > "$T1_TRACE"

bash "${SCRIPTS_DIR}/backfill-token-history.sh" "$T1_HISTORY" "$T1_TRACE" > /dev/null 2>&1

# The backfilled entry should have the CORRECT hash, not the wrong name-based one
backfilled_hash=$(grep "09:50:00Z" "$T1_HISTORY" | cut -d'|' -f6)
if [[ "$backfilled_hash" == "$CORRECT_PHASH" ]]; then
    pass "T1: backfilled entry has correct path-based hash ($CORRECT_PHASH)"
elif [[ "$backfilled_hash" == "$WRONG_PHASH" ]]; then
    fail "T1" "$CORRECT_PHASH (path-based)" "$WRONG_PHASH (name-based — bug still present)"
else
    fail "T1" "$CORRECT_PHASH" "$backfilled_hash"
fi

# Verify correct hash NOT equal to wrong hash (sanity: they really differ)
if [[ "$CORRECT_PHASH" != "$WRONG_PHASH" ]]; then
    pass "T1b: sanity — path-based and name-based hashes differ ($CORRECT_PHASH vs $WRONG_PHASH)"
else
    fail "T1b" "different hashes" "hashes are identical (test is invalid for this path)"
fi

# ─────────────────────────────────────────────────────────────────
# T2: When no live entry exists for a project_name, fall back to _phash(name)
# ─────────────────────────────────────────────────────────────────
echo "--- T2: fallback to name-based hash when no live entry exists ---"

T2_DIR=$(mktemp -d)
trap 'rm -rf "$T2_DIR" 2>/dev/null || true' EXIT

T2_HISTORY="${T2_DIR}/.session-token-history"
# Only a 5-column entry (no live reference for this project)
echo "2026-01-10T09:50:00Z|30000|25000|5000|unknown" > "$T2_HISTORY"

T2_TRACE="${T2_DIR}/trace-index.jsonl"
echo '{"trace_id":"implementer-20260110-095500-xyz","agent_type":"implementer","project_name":"orphan-project","session_id":"impl-session-002","started_at":"2026-01-10T09:55:00Z"}' > "$T2_TRACE"

bash "${SCRIPTS_DIR}/backfill-token-history.sh" "$T2_HISTORY" "$T2_TRACE" > /dev/null 2>&1

# Without a live entry, backfill falls back to hash(project_name)
EXPECTED_FALLBACK=$(_expected_phash "orphan-project")
t2_hash=$(grep "09:50:00Z" "$T2_HISTORY" | cut -d'|' -f6)
if [[ "$t2_hash" == "$EXPECTED_FALLBACK" ]]; then
    pass "T2: fallback to name-based hash ($EXPECTED_FALLBACK) when no live entry"
else
    fail "T2" "$EXPECTED_FALLBACK (name fallback)" "$t2_hash"
fi

# ─────────────────────────────────────────────────────────────────
# T3: Already-7-column entries are left unchanged (idempotent)
# ─────────────────────────────────────────────────────────────────
echo "--- T3: 7-column entries unchanged after backfill ---"

T3_DIR=$(mktemp -d)
trap 'rm -rf "$T3_DIR" 2>/dev/null || true' EXIT

EXISTING_PHASH="deadbeef"  # some existing hash (won't be recomputed)
T3_HISTORY="${T3_DIR}/.session-token-history"
echo "2026-01-10T10:00:00Z|50000|40000|10000|live-session-abc|${EXISTING_PHASH}|.claude" > "$T3_HISTORY"

T3_TRACE="${T3_DIR}/trace-index.jsonl"
echo '{"trace_id":"implementer-20260110-100000-t3","agent_type":"implementer","project_name":".claude","session_id":"live-session-abc","started_at":"2026-01-10T10:00:00Z"}' > "$T3_TRACE"

bash "${SCRIPTS_DIR}/backfill-token-history.sh" "$T3_HISTORY" "$T3_TRACE" > /dev/null 2>&1

t3_hash=$(grep "10:00:00Z" "$T3_HISTORY" | cut -d'|' -f6)
if [[ "$t3_hash" == "$EXISTING_PHASH" ]]; then
    pass "T3: existing 7-col entry preserved unchanged ($EXISTING_PHASH)"
else
    fail "T3" "$EXISTING_PHASH" "$t3_hash"
fi

# ─────────────────────────────────────────────────────────────────
# T4: Mixed file — live, backfilled-old-wrong, and 5-col entries all consistent
# This is the production scenario: some 5-col entries, some already-backfilled
# entries with wrong hash, and some live entries with correct hash.
# After re-running backfill, the 5-col entries should get the correct hash.
# The already-backfilled-wrong entries are already 7-col so they're skipped.
# ─────────────────────────────────────────────────────────────────
echo "--- T4: mixed file — 5-col entries get correct hash from live entries ---"

T4_DIR=$(mktemp -d)
trap 'rm -rf "$T4_DIR" 2>/dev/null || true' EXIT

T4_CORRECT=$(_expected_phash "/Users/turla/.claude")
T4_WRONG=$(_expected_phash ".claude")

T4_HISTORY="${T4_DIR}/.session-token-history"
# Live entry: correct hash
echo "2026-01-15T14:00:00Z|80000|65000|15000|live-session-xyz|${T4_CORRECT}|.claude" > "$T4_HISTORY"
# Old backfilled entry: wrong hash (already 7-col, will be skipped)
echo "2026-01-14T10:00:00Z|50000|40000|10000|unknown|${T4_WRONG}|.claude" >> "$T4_HISTORY"
# New 5-col entry that needs backfill
echo "2026-01-16T09:00:00Z|35000|28000|7000|unknown" >> "$T4_HISTORY"

T4_TRACE="${T4_DIR}/trace-index.jsonl"
echo '{"trace_id":"implementer-20260116-090500-t4","agent_type":"implementer","project_name":".claude","session_id":"impl-session-t4","started_at":"2026-01-16T09:05:00Z"}' > "$T4_TRACE"

bash "${SCRIPTS_DIR}/backfill-token-history.sh" "$T4_HISTORY" "$T4_TRACE" > /dev/null 2>&1

# The 5-col entry (09:00:00Z) should get the CORRECT hash
t4_new_hash=$(grep "2026-01-16T09:00:00Z" "$T4_HISTORY" | cut -d'|' -f6)
if [[ "$t4_new_hash" == "$T4_CORRECT" ]]; then
    pass "T4: new 5-col entry got correct path-based hash ($T4_CORRECT)"
elif [[ "$t4_new_hash" == "$T4_WRONG" ]]; then
    fail "T4" "$T4_CORRECT (path-based)" "$T4_WRONG (name-based — bug still present)"
else
    fail "T4" "$T4_CORRECT" "$t4_new_hash"
fi

# The old already-backfilled wrong-hash entry should remain unchanged (skipped)
t4_old_hash=$(grep "2026-01-14T10:00:00Z" "$T4_HISTORY" | cut -d'|' -f6)
if [[ "$t4_old_hash" == "$T4_WRONG" ]]; then
    pass "T4b: old already-backfilled entry preserved (skipped, hash=$T4_WRONG)"
else
    fail "T4b" "$T4_WRONG (unchanged)" "$t4_old_hash"
fi

# ─────────────────────────────────────────────────────────────────
# T5: Multiple projects — each project gets its own correct hash
# ─────────────────────────────────────────────────────────────────
echo "--- T5: multiple projects each get the correct hash ---"

T5_DIR=$(mktemp -d)
trap 'rm -rf "$T5_DIR" 2>/dev/null || true' EXIT

PROJ_A_CORRECT=$(_expected_phash "/Users/turla/projects/project-alpha")
PROJ_B_CORRECT=$(_expected_phash "/Users/turla/work/project-beta")

T5_HISTORY="${T5_DIR}/.session-token-history"
# Live entries for two different projects
echo "2026-02-01T10:00:00Z|40000|32000|8000|live-alpha-001|${PROJ_A_CORRECT}|project-alpha" > "$T5_HISTORY"
echo "2026-02-01T11:00:00Z|60000|48000|12000|live-beta-001|${PROJ_B_CORRECT}|project-beta" >> "$T5_HISTORY"
# 5-col entries that need backfill for each project
echo "2026-02-01T09:45:00Z|25000|20000|5000|unknown" >> "$T5_HISTORY"
echo "2026-02-01T10:45:00Z|35000|28000|7000|unknown" >> "$T5_HISTORY"

T5_TRACE="${T5_DIR}/trace-index.jsonl"
echo '{"trace_id":"implementer-20260201-095000-a","agent_type":"implementer","project_name":"project-alpha","session_id":"impl-alpha-001","started_at":"2026-02-01T09:50:00Z"}' > "$T5_TRACE"
echo '{"trace_id":"implementer-20260201-105000-b","agent_type":"implementer","project_name":"project-beta","session_id":"impl-beta-001","started_at":"2026-02-01T10:50:00Z"}' >> "$T5_TRACE"

bash "${SCRIPTS_DIR}/backfill-token-history.sh" "$T5_HISTORY" "$T5_TRACE" > /dev/null 2>&1

# project-alpha entry (09:45) should get PROJ_A_CORRECT hash
t5_alpha_hash=$(grep "2026-02-01T09:45:00Z" "$T5_HISTORY" | cut -d'|' -f6)
t5_alpha_name=$(grep "2026-02-01T09:45:00Z" "$T5_HISTORY" | cut -d'|' -f7)
if [[ "$t5_alpha_hash" == "$PROJ_A_CORRECT" && "$t5_alpha_name" == "project-alpha" ]]; then
    pass "T5a: project-alpha entry has correct hash ($PROJ_A_CORRECT) and name"
elif [[ "$t5_alpha_hash" == "$PROJ_A_CORRECT" ]]; then
    pass "T5a: project-alpha entry has correct hash ($PROJ_A_CORRECT), name=$t5_alpha_name"
else
    fail "T5a" "$PROJ_A_CORRECT for project-alpha" "$t5_alpha_hash for $t5_alpha_name"
fi

# project-beta entry (10:45) should get PROJ_B_CORRECT hash
t5_beta_hash=$(grep "2026-02-01T10:45:00Z" "$T5_HISTORY" | cut -d'|' -f6)
t5_beta_name=$(grep "2026-02-01T10:45:00Z" "$T5_HISTORY" | cut -d'|' -f7)
if [[ "$t5_beta_hash" == "$PROJ_B_CORRECT" && "$t5_beta_name" == "project-beta" ]]; then
    pass "T5b: project-beta entry has correct hash ($PROJ_B_CORRECT) and name"
elif [[ "$t5_beta_hash" == "$PROJ_B_CORRECT" ]]; then
    pass "T5b: project-beta entry has correct hash ($PROJ_B_CORRECT), name=$t5_beta_name"
else
    fail "T5b" "$PROJ_B_CORRECT for project-beta" "$t5_beta_hash for $t5_beta_name"
fi

# ─────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
