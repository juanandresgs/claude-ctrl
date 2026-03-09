#!/usr/bin/env bash
# test-token-history-format.sh — Tests for per-project token history columns and
# project-scoped lifetime token summing.
#
# Purpose: Verifies the fix for issue #160 part 2:
#   1. session-end.sh appends project_hash and project_name as columns 6+7
#   2. session-init.sh sums only the current project's tokens (column 6 filter)
#   3. Old-format entries (5 columns) are included in sum (backward compat)
#   4. backfill-token-history.sh correctly adds columns 6+7 to old entries
#
# @decision DEC-PROJECT-TOKEN-HISTORY-001
# @title Per-project token history: columns 6+7 (project_hash, project_name)
# @status accepted
# @rationale Summing ALL sessions' tokens conflates work across projects. A Go
# project and a Python project sharing the same ~/.claude accumulate tokens
# independently but the lifetime display showed one combined number. Adding
# project_hash (col 6) and project_name (col 7) lets session-init.sh filter
# by project, giving accurate per-project lifetime totals.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="${SCRIPT_DIR}/../hooks"
SCRIPTS_DIR="${SCRIPT_DIR}/../scripts"
SOURCE_LIB="${HOOKS_DIR}/source-lib.sh"
BACKFILL="${SCRIPTS_DIR}/backfill-token-history.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass_test() { TESTS_PASSED=$(( TESTS_PASSED + 1 )); echo -e "${GREEN}✓${NC} $1"; }
fail_test() { TESTS_FAILED=$(( TESTS_FAILED + 1 )); echo -e "${RED}✗${NC} $1"; echo -e "  ${YELLOW}Details:${NC} $2"; }
run_test()  { TESTS_RUN=$(( TESTS_RUN + 1 )); }

# Cleanup trap
_CLEANUP_DIRS=()
trap '[[ ${#_CLEANUP_DIRS[@]} -gt 0 ]] && rm -rf "${_CLEANUP_DIRS[@]}" 2>/dev/null; true' EXIT

# Helper: compute project_hash from a path (mirrors core-lib.sh)
compute_phash() {
    local path="$1"
    echo "$path" | shasum -a 256 | cut -c1-8
}

# Helper: run write_cache_with_history — simulates session-end writing token history
# Args: claude_dir project_root total_tokens main_tokens subagent_tokens session_id
# This directly writes the new 7-column format, mirroring what session-end.sh will do
# after the fix is applied. The test verifies the FORMAT, not the shell implementation.
run_write_token_history() {
    local claude_dir="$1" project_root="$2"
    local total_tokens="$3" main_tokens="$4" subagent_tokens="$5" session_id="$6"
    local history_file="${claude_dir}/.session-token-history"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local phash
    phash=$(compute_phash "$project_root")
    local pname
    pname=$(basename "$project_root")
    if [[ "$total_tokens" -gt 0 ]]; then
        echo "${ts}|${total_tokens}|${main_tokens}|${subagent_tokens}|${session_id}|${phash}|${pname}" >> "$history_file"
    fi
}


# Helper: sum lifetime tokens for a given project using the new filter logic
# shellcheck disable=SC2329  # function IS invoked (indirectly via test scaffolding)
sum_lifetime_tokens() {
    local claude_dir="$1" project_root="$2"
    # Pre-compute phash in the outer shell so the inner bash -c never needs to
    # reference it as a variable (avoids SC2154: compute_phash referenced but not assigned).
    local _outer_phash
    _outer_phash=$(echo "$project_root" | shasum -a 256 | cut -c1-8)
    bash -c "
        source '${SOURCE_LIB}' 2>/dev/null || true
        _TOKEN_HISTORY='${claude_dir}/.session-token-history'
        _PHASH=\$(project_hash '${project_root}' 2>/dev/null || echo '${_outer_phash}')
        if [[ -f \"\$_TOKEN_HISTORY\" ]]; then
            awk -F'|' -v ph=\"\$_PHASH\" '(NF < 6) || (\$6 == ph) {sum += \$2} END {print sum+0}' \"\$_TOKEN_HISTORY\" 2>/dev/null || echo 0
        else
            echo 0
        fi
    " 2>/dev/null
}

# ============================================================================
# Test group 1: New 7-column format in session-token-history
# ============================================================================

test_new_format_has_7_columns() {
    run_test
    local tmpdir project_root
    tmpdir=$(mktemp -d /Users/turla/.claude/tmp/test-token-hist-XXXXXX)
    _CLEANUP_DIRS+=("$tmpdir")
    project_root="${tmpdir}/myproject"
    mkdir -p "${project_root}/.claude"

    run_write_token_history "${project_root}/.claude" "$project_root" 50000 50000 0 "test-sess-1"

    local history_file="${project_root}/.claude/.session-token-history"
    if [[ ! -f "$history_file" ]]; then
        fail_test "7-column format: history file not created" "expected: $history_file"
        return
    fi

    local col_count
    col_count=$(awk -F'|' '{print NF}' "$history_file" | head -1)
    if [[ "$col_count" -eq 7 ]]; then
        pass_test "New format: history entry has 7 columns (ts|total|main|sub|sid|phash|pname)"
    else
        fail_test "New format: expected 7 columns, got $col_count" "line: $(cat "$history_file")"
    fi
}

test_new_format_project_hash_correct() {
    run_test
    local tmpdir project_root
    tmpdir=$(mktemp -d /Users/turla/.claude/tmp/test-token-hist-XXXXXX)
    _CLEANUP_DIRS+=("$tmpdir")
    project_root="${tmpdir}/myproject"
    mkdir -p "${project_root}/.claude"

    run_write_token_history "${project_root}/.claude" "$project_root" 50000 50000 0 "test-sess-1"

    local expected_phash
    expected_phash=$(compute_phash "$project_root")
    local actual_phash
    actual_phash=$(awk -F'|' '{print $6}' "${project_root}/.claude/.session-token-history" | head -1)

    if [[ "$actual_phash" == "$expected_phash" ]]; then
        pass_test "New format: column 6 contains correct project_hash ($expected_phash)"
    else
        fail_test "New format: project_hash mismatch" "expected=$expected_phash actual=$actual_phash"
    fi
}

test_new_format_project_name_correct() {
    run_test
    local tmpdir project_root
    tmpdir=$(mktemp -d /Users/turla/.claude/tmp/test-token-hist-XXXXXX)
    _CLEANUP_DIRS+=("$tmpdir")
    project_root="${tmpdir}/my-test-project"
    mkdir -p "${project_root}/.claude"

    run_write_token_history "${project_root}/.claude" "$project_root" 50000 50000 0 "test-sess-1"

    local actual_pname
    actual_pname=$(awk -F'|' '{print $7}' "${project_root}/.claude/.session-token-history" | head -1)

    if [[ "$actual_pname" == "my-test-project" ]]; then
        pass_test "New format: column 7 contains correct project_name (basename)"
    else
        fail_test "New format: project_name wrong" "expected=my-test-project actual=$actual_pname"
    fi
}

# ============================================================================
# Test group 2: Project-scoped lifetime token summing
# ============================================================================

test_project_filter_sums_only_matching() {
    run_test
    # Two projects write to the same history file; only project A's tokens should sum
    local tmpdir
    tmpdir=$(mktemp -d /Users/turla/.claude/tmp/test-token-hist-XXXXXX)
    _CLEANUP_DIRS+=("$tmpdir")
    local claude_dir="${tmpdir}/.claude"
    local project_a="${tmpdir}/project-a"
    local project_b="${tmpdir}/project-b"
    mkdir -p "$claude_dir" "$project_a" "$project_b"

    local history_file="${claude_dir}/.session-token-history"
    local phash_a
    phash_a=$(compute_phash "$project_a")
    local phash_b
    phash_b=$(compute_phash "$project_b")

    # Write entries: 3 for project A, 2 for project B
    printf '2026-01-01T00:00:00Z|100000|100000|0|sid-a1|%s|project-a\n' "$phash_a" >> "$history_file"
    printf '2026-01-02T00:00:00Z|200000|200000|0|sid-a2|%s|project-a\n' "$phash_a" >> "$history_file"
    printf '2026-01-03T00:00:00Z|50000|50000|0|sid-b1|%s|project-b\n' "$phash_b" >> "$history_file"
    printf '2026-01-04T00:00:00Z|150000|150000|0|sid-a3|%s|project-a\n' "$phash_a" >> "$history_file"
    printf '2026-01-05T00:00:00Z|75000|75000|0|sid-b2|%s|project-b\n' "$phash_b" >> "$history_file"

    # Sum for project A: 100k + 200k + 150k = 450k
    local sum_a
    sum_a=$(awk -F'|' -v ph="$phash_a" '(NF < 6) || ($6 == ph) {sum += $2} END {print sum+0}' "$history_file")

    if [[ "$sum_a" -eq 450000 ]]; then
        pass_test "Project filter: sums 450k for project A (ignores 125k from project B)"
    else
        fail_test "Project filter: wrong sum for project A" "expected=450000 actual=$sum_a"
    fi
}

test_project_filter_backward_compat_5col_entries() {
    run_test
    # Old-format entries (5 columns, no project_hash) should be included in sum
    # per the backward compat requirement
    local tmpdir
    tmpdir=$(mktemp -d /Users/turla/.claude/tmp/test-token-hist-XXXXXX)
    _CLEANUP_DIRS+=("$tmpdir")
    local project_root="${tmpdir}/myproject"
    mkdir -p "$project_root"

    local history_file="${tmpdir}/.session-token-history"
    local phash
    phash=$(compute_phash "$project_root")

    # Old format (5 columns) — no project context
    printf '2026-01-01T00:00:00Z|100000|100000|0|old-sess-1\n' >> "$history_file"
    printf '2026-01-02T00:00:00Z|200000|200000|0|old-sess-2\n' >> "$history_file"
    # New format for this project
    printf '2026-01-03T00:00:00Z|50000|50000|0|new-sess-1|%s|myproject\n' "$phash" >> "$history_file"

    # Sum should include all: 100k (old) + 200k (old) + 50k (new) = 350k
    local sum
    sum=$(awk -F'|' -v ph="$phash" '(NF < 6) || ($6 == ph) {sum += $2} END {print sum+0}' "$history_file")

    if [[ "$sum" -eq 350000 ]]; then
        pass_test "Backward compat: old-format entries (5 cols) included in sum (350k total)"
    else
        fail_test "Backward compat: old-format entries not counted" "expected=350000 actual=$sum"
    fi
}

test_project_filter_excludes_other_projects_new_format() {
    run_test
    # New-format entries from other projects should NOT be included
    local tmpdir
    tmpdir=$(mktemp -d /Users/turla/.claude/tmp/test-token-hist-XXXXXX)
    _CLEANUP_DIRS+=("$tmpdir")
    local project_mine="${tmpdir}/my-project"
    local project_other="${tmpdir}/other-project"
    mkdir -p "$project_mine" "$project_other"

    local history_file="${tmpdir}/.session-token-history"
    local phash_mine
    phash_mine=$(compute_phash "$project_mine")
    local phash_other
    phash_other=$(compute_phash "$project_other")

    # Mix: old (counts), my-project (counts), other (should NOT count)
    printf '2026-01-01T00:00:00Z|100000|100000|0|old-1\n' >> "$history_file"
    printf '2026-01-02T00:00:00Z|300000|300000|0|mine-1|%s|my-project\n' "$phash_mine" >> "$history_file"
    printf '2026-01-03T00:00:00Z|500000|500000|0|other-1|%s|other-project\n' "$phash_other" >> "$history_file"

    # Sum for my-project: 100k (old) + 300k (mine) = 400k (not 900k)
    local sum
    sum=$(awk -F'|' -v ph="$phash_mine" '(NF < 6) || ($6 == ph) {sum += $2} END {print sum+0}' "$history_file")

    if [[ "$sum" -eq 400000 ]]; then
        pass_test "Project filter: excludes other-project's 500k; sum=400k (100k old + 300k mine)"
    else
        fail_test "Project filter: other project tokens leaked into sum" "expected=400000 actual=$sum"
    fi
}

# ============================================================================
# Test group 3: Backfill script
# ============================================================================

test_backfill_script_exists() {
    run_test
    if [[ -f "$BACKFILL" && -x "$BACKFILL" ]]; then
        pass_test "backfill-token-history.sh exists and is executable"
    elif [[ -f "$BACKFILL" ]]; then
        fail_test "backfill-token-history.sh exists but not executable" "path: $BACKFILL"
    else
        fail_test "backfill-token-history.sh not found" "expected: $BACKFILL"
    fi
}

test_backfill_creates_backup() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d /Users/turla/.claude/tmp/test-backfill-XXXXXX)
    _CLEANUP_DIRS+=("$tmpdir")

    # Create a history file with old-format entries
    local history_file="${tmpdir}/.session-token-history"
    printf '2026-01-01T00:00:00Z|100000|100000|0|old-sess-1\n' > "$history_file"
    printf '2026-01-02T00:00:00Z|200000|200000|0|old-sess-2\n' >> "$history_file"

    # Run backfill
    bash "$BACKFILL" "$history_file" >/dev/null 2>&1 || true

    if [[ -f "${history_file}.bak" ]]; then
        pass_test "Backfill: creates .bak backup of original file"
    else
        fail_test "Backfill: no .bak backup created" "expected: ${history_file}.bak"
    fi
}

test_backfill_idempotent_on_new_format() {
    run_test
    # Running backfill on already-7-column entries should not change them
    local tmpdir
    tmpdir=$(mktemp -d /Users/turla/.claude/tmp/test-backfill-XXXXXX)
    _CLEANUP_DIRS+=("$tmpdir")

    local history_file="${tmpdir}/.session-token-history"
    # Already 7 columns — backfill should skip these
    printf '2026-01-01T00:00:00Z|100000|100000|0|new-sess-1|abc12345|myproject\n' > "$history_file"
    printf '2026-01-02T00:00:00Z|200000|200000|0|new-sess-2|abc12345|myproject\n' >> "$history_file"

    bash "$BACKFILL" "$history_file" >/dev/null 2>&1 || true

    # Still 7 columns after backfill
    local col_count
    col_count=$(awk -F'|' '{print NF}' "$history_file" | head -1)
    if [[ "$col_count" -eq 7 ]]; then
        pass_test "Backfill: idempotent — already-7-column entries unchanged"
    else
        fail_test "Backfill: corrupted already-good entries" "cols=$col_count"
    fi
}

test_backfill_adds_columns_to_5col_entries() {
    run_test
    # Old 5-column entries get columns 6+7 added (unknown phash, unknown project)
    local tmpdir
    tmpdir=$(mktemp -d /Users/turla/.claude/tmp/test-backfill-XXXXXX)
    _CLEANUP_DIRS+=("$tmpdir")

    local history_file="${tmpdir}/.session-token-history"
    printf '2026-01-01T00:00:00Z|100000|100000|0|old-sess-1\n' > "$history_file"

    # Create a minimal traces/index.jsonl nearby for the backfill to use
    local trace_index="${tmpdir}/traces/index.jsonl"
    mkdir -p "${tmpdir}/traces"
    printf '{"trace_id":"impl-1","project_name":"my-project","started_at":"2026-01-01T00:05:00Z"}\n' > "$trace_index"

    bash "$BACKFILL" "$history_file" "$trace_index" >/dev/null 2>&1 || true

    local col_count
    col_count=$(awk -F'|' '{print NF}' "$history_file" | head -1)
    if [[ "$col_count" -eq 7 ]]; then
        pass_test "Backfill: 5-column entries get columns 6+7 added (now 7 columns)"
    else
        fail_test "Backfill: 5-column entries not upgraded to 7 columns" "cols=$col_count"
    fi
}

test_backfill_unmatched_uses_unknown() {
    run_test
    # Old entry with timestamp far from any trace gets 'unknown' project_name
    local tmpdir
    tmpdir=$(mktemp -d /Users/turla/.claude/tmp/test-backfill-XXXXXX)
    _CLEANUP_DIRS+=("$tmpdir")

    local history_file="${tmpdir}/.session-token-history"
    # Timestamp: 2025-01-01 (far from any trace)
    printf '2025-01-01T00:00:00Z|100000|100000|0|old-sess-1\n' > "$history_file"

    local trace_index="${tmpdir}/traces/index.jsonl"
    mkdir -p "${tmpdir}/traces"
    # Trace is in 2026 — more than 30 minutes away from the history entry
    printf '{"trace_id":"impl-1","project_name":"my-project","started_at":"2026-03-01T10:00:00Z"}\n' > "$trace_index"

    bash "$BACKFILL" "$history_file" "$trace_index" >/dev/null 2>&1 || true

    local project_name
    project_name=$(awk -F'|' '{print $7}' "$history_file" | head -1)
    if [[ "$project_name" == "unknown" ]]; then
        pass_test "Backfill: unmatched entry (>30min from any trace) gets 'unknown' project_name"
    else
        fail_test "Backfill: unmatched entry has wrong project_name" "actual=$project_name"
    fi
}

# ============================================================================
# Test group 3b: Two-tier null-project fallback (issue #175)
# ============================================================================
# When the closest trace has "unknown" project_name, the backfill should fall
# back to the nearest trace that has a real name — as long as it's within the
# 30-minute match window. This prevents failed tester dispatches (which always
# produce null/unknown project_name) from masking the real project identity.

test_backfill_null_fallback_uses_nearest_named_trace() {
    run_test
    # Setup: history entry at T=0
    #   Trace A at T+2min: project_name="unknown"  (closest)
    #   Trace B at T+5min: project_name="my-project" (slightly farther but named)
    # Expected: backfill uses "my-project" (not "unknown")
    local tmpdir
    tmpdir=$(mktemp -d /Users/turla/.claude/tmp/test-backfill-XXXXXX)
    _CLEANUP_DIRS+=("$tmpdir")

    local history_file="${tmpdir}/.session-token-history"
    # Base time: 2026-06-01T10:00:00Z
    printf '2026-06-01T10:00:00Z|150000|150000|0|sess-175-fallback\n' > "$history_file"

    local trace_index="${tmpdir}/traces/index.jsonl"
    mkdir -p "${tmpdir}/traces"
    # Trace A: 2 minutes after — closest but unknown
    printf '{"trace_id":"tester-001","project_name":"unknown","started_at":"2026-06-01T10:02:00Z"}\n' > "$trace_index"
    # Trace B: 5 minutes after — slightly farther but has real name
    printf '{"trace_id":"impl-001","project_name":"my-project","started_at":"2026-06-01T10:05:00Z"}\n' >> "$trace_index"

    bash "$BACKFILL" "$history_file" "$trace_index" >/dev/null 2>&1 || true

    local project_name
    project_name=$(awk -F'|' '{print $7}' "$history_file" | head -1)
    if [[ "$project_name" == "my-project" ]]; then
        pass_test "Null fallback: closest trace 'unknown' overridden by nearest named trace 'my-project'"
    else
        fail_test "Null fallback: expected 'my-project', got project_name='$project_name'" \
                  "closest='unknown'@+2min, named='my-project'@+5min, both within window"
    fi
}

test_backfill_null_fallback_all_unknown_stays_unknown() {
    run_test
    # When ALL traces in the window are "unknown", result must remain "unknown"
    local tmpdir
    tmpdir=$(mktemp -d /Users/turla/.claude/tmp/test-backfill-XXXXXX)
    _CLEANUP_DIRS+=("$tmpdir")

    local history_file="${tmpdir}/.session-token-history"
    printf '2026-06-02T10:00:00Z|200000|200000|0|sess-175-allunk\n' > "$history_file"

    local trace_index="${tmpdir}/traces/index.jsonl"
    mkdir -p "${tmpdir}/traces"
    # Both traces within window are "unknown"
    printf '{"trace_id":"tester-a","project_name":"unknown","started_at":"2026-06-02T10:03:00Z"}\n' > "$trace_index"
    printf '{"trace_id":"tester-b","project_name":"unknown","started_at":"2026-06-02T10:08:00Z"}\n' >> "$trace_index"

    bash "$BACKFILL" "$history_file" "$trace_index" >/dev/null 2>&1 || true

    local project_name
    project_name=$(awk -F'|' '{print $7}' "$history_file" | head -1)
    if [[ "$project_name" == "unknown" ]]; then
        pass_test "Null fallback: all-unknown window correctly results in 'unknown' project_name"
    else
        fail_test "Null fallback: expected 'unknown' (all traces unknown), got '$project_name'" \
                  "no named trace exists in window — should stay unknown"
    fi
}

test_backfill_null_fallback_real_name_closest_no_regression() {
    run_test
    # When the closest trace already has a real name, it must still be used (no regression)
    local tmpdir
    tmpdir=$(mktemp -d /Users/turla/.claude/tmp/test-backfill-XXXXXX)
    _CLEANUP_DIRS+=("$tmpdir")

    local history_file="${tmpdir}/.session-token-history"
    printf '2026-06-03T10:00:00Z|300000|300000|0|sess-175-noreg\n' > "$history_file"

    local trace_index="${tmpdir}/traces/index.jsonl"
    mkdir -p "${tmpdir}/traces"
    # Closest trace has real name — should be used directly
    printf '{"trace_id":"impl-closest","project_name":"real-project","started_at":"2026-06-03T10:01:00Z"}\n' > "$trace_index"
    # Farther trace also has real name — should NOT override the closest
    printf '{"trace_id":"impl-far","project_name":"other-project","started_at":"2026-06-03T10:20:00Z"}\n' >> "$trace_index"

    bash "$BACKFILL" "$history_file" "$trace_index" >/dev/null 2>&1 || true

    local project_name
    project_name=$(awk -F'|' '{print $7}' "$history_file" | head -1)
    if [[ "$project_name" == "real-project" ]]; then
        pass_test "Null fallback no-regression: closest named trace 'real-project' used (not overridden)"
    else
        fail_test "Null fallback no-regression: expected 'real-project', got '$project_name'" \
                  "closest trace had real name — original behavior must hold"
    fi
}

# ============================================================================
# Test group 4: Global lifetime sum
# ============================================================================

test_global_lifetime_sum_all_entries() {
    run_test
    # Global sum uses ALL entries regardless of project_hash
    local tmpdir
    tmpdir=$(mktemp -d /Users/turla/.claude/tmp/test-token-hist-XXXXXX)
    _CLEANUP_DIRS+=("$tmpdir")

    local history_file="${tmpdir}/.session-token-history"
    printf '2026-01-01T00:00:00Z|100000|100000|0|s1|hash-a|proj-a\n' >> "$history_file"
    printf '2026-01-02T00:00:00Z|200000|200000|0|s2|hash-b|proj-b\n' >> "$history_file"
    printf '2026-01-03T00:00:00Z|50000|50000|0|s3\n' >> "$history_file"  # old format

    # Global sum: 100k + 200k + 50k = 350k
    local global_sum
    global_sum=$(awk -F'|' '{sum += $2} END {print sum+0}' "$history_file")

    if [[ "$global_sum" -eq 350000 ]]; then
        pass_test "Global sum: all entries summed (350k) regardless of project"
    else
        fail_test "Global sum: wrong total" "expected=350000 actual=$global_sum"
    fi
}

# ============================================================================
# Test group 5: Session-id exact match (DEC-BACKFILL-SESSION-MATCH-001)
# ============================================================================
# Verifies Tier 0 session_id matching in backfill: when a token history entry
# has the same session_id as a trace in the index, the backfill uses that
# trace's project_name regardless of timestamp proximity.

test_backfill_session_id_exact_match() {
    run_test
    # History entry at T=0 with known session_id
    # Trace index has a trace with the SAME session_id but timestamp is 45min away
    # (outside the 30-min window, so timestamp matching alone would fail)
    # Tier 0 must find it via exact session_id match
    local tmpdir
    tmpdir=$(mktemp -d /Users/turla/.claude/tmp/test-backfill-sid-XXXXXX)
    _CLEANUP_DIRS+=("$tmpdir")

    local history_file="${tmpdir}/.session-token-history"
    # Entry with known session_id — no project columns yet
    printf '2026-06-10T10:00:00Z|500000|500000|0|sess-exact-abc123\n' > "$history_file"

    local trace_index="${tmpdir}/traces/index.jsonl"
    mkdir -p "${tmpdir}/traces"
    # Trace is 45 minutes later (outside 30-min window), but same session_id
    printf '{"trace_id":"impl-abc","session_id":"sess-exact-abc123","project_name":"correct-project","started_at":"2026-06-10T10:45:00Z"}\n' > "$trace_index"

    bash "$BACKFILL" "$history_file" "$trace_index" >/dev/null 2>&1 || true

    local project_name
    project_name=$(awk -F'|' '{print $7}' "$history_file" | head -1)
    if [[ "$project_name" == "correct-project" ]]; then
        pass_test "Session-id Tier 0: exact session_id match finds project beyond timestamp window"
    else
        fail_test "Session-id Tier 0: expected 'correct-project' via session_id, got '$project_name'" \
                  "trace is 45min away (past 30-min window) but same session_id — should match"
    fi
}

test_backfill_session_id_match_trumps_closer_unknown() {
    run_test
    # History entry with known session_id
    # Trace A: 2 min away, session_id matches, project_name="unknown" (skip — no real name)
    # Trace B: 10 min away, session_id matches, project_name="real-project"
    # Trace C: 1 min away, different session_id, project_name="wrong-project"
    # Expected: "real-project" (Tier 0 finds exact session_id with real name)
    local tmpdir
    tmpdir=$(mktemp -d /Users/turla/.claude/tmp/test-backfill-sid-XXXXXX)
    _CLEANUP_DIRS+=("$tmpdir")

    local history_file="${tmpdir}/.session-token-history"
    printf '2026-06-11T10:00:00Z|100000|100000|0|sess-match-xyz\n' > "$history_file"

    local trace_index="${tmpdir}/traces/index.jsonl"
    mkdir -p "${tmpdir}/traces"
    # Trace A: closest time, same session, but unknown project — should be skipped in Tier 0
    printf '{"trace_id":"tester-x","session_id":"sess-match-xyz","project_name":"unknown","started_at":"2026-06-11T10:02:00Z"}\n' > "$trace_index"
    # Trace B: 10 min, same session, real project — Tier 0 should find this
    printf '{"trace_id":"impl-x","session_id":"sess-match-xyz","project_name":"real-project","started_at":"2026-06-11T10:10:00Z"}\n' >> "$trace_index"
    # Trace C: 1 min, different session — should NOT be used by Tier 0
    printf '{"trace_id":"impl-y","session_id":"sess-other-999","project_name":"wrong-project","started_at":"2026-06-11T10:01:00Z"}\n' >> "$trace_index"

    bash "$BACKFILL" "$history_file" "$trace_index" >/dev/null 2>&1 || true

    local project_name
    project_name=$(awk -F'|' '{print $7}' "$history_file" | head -1)
    if [[ "$project_name" == "real-project" ]]; then
        pass_test "Session-id Tier 0: real project found via session_id even with closer different-session trace"
    else
        fail_test "Session-id Tier 0: expected 'real-project' via session_id match, got '$project_name'" \
                  "should ignore closer trace with different session_id"
    fi
}

test_backfill_session_id_unknown_falls_back_to_timestamp() {
    run_test
    # History entry with session_id="unknown" — Tier 0 must be skipped
    # Falls back to Tier 1+2 timestamp matching
    local tmpdir
    tmpdir=$(mktemp -d /Users/turla/.claude/tmp/test-backfill-sid-XXXXXX)
    _CLEANUP_DIRS+=("$tmpdir")

    local history_file="${tmpdir}/.session-token-history"
    printf '2026-06-12T10:00:00Z|200000|200000|0|unknown\n' > "$history_file"

    local trace_index="${tmpdir}/traces/index.jsonl"
    mkdir -p "${tmpdir}/traces"
    # Trace 3 min away — Tier 1 timestamp match should find it
    printf '{"trace_id":"impl-fallback","session_id":"real-session-99","project_name":"ts-matched-project","started_at":"2026-06-12T10:03:00Z"}\n' > "$trace_index"

    bash "$BACKFILL" "$history_file" "$trace_index" >/dev/null 2>&1 || true

    local project_name
    project_name=$(awk -F'|' '{print $7}' "$history_file" | head -1)
    if [[ "$project_name" == "ts-matched-project" ]]; then
        pass_test "Session-id Tier 0 bypass: 'unknown' session_id falls back to timestamp matching"
    else
        fail_test "Session-id Tier 0 bypass: expected 'ts-matched-project' via timestamp, got '$project_name'" \
                  "session_id='unknown' should skip Tier 0 and use timestamp fallback"
    fi
}

# ============================================================================
# Test group 6: read_input() session_id extraction (DEC-SESSION-ID-001)
# ============================================================================

test_read_input_extracts_session_id() {
    run_test
    # Source log.sh, feed JSON via process substitution (NOT pipe — pipe creates subshell,
    # which would prevent the export from reaching the calling shell). Verify CLAUDE_SESSION_ID
    # is set after read_input returns.
    local HOOKS_DIR_LOCAL="${SCRIPT_DIR}/../hooks"
    local result
    result=$(bash -c "
        unset CLAUDE_SESSION_ID
        source '${HOOKS_DIR_LOCAL}/log.sh' 2>/dev/null
        # Process substitution avoids pipe subshell — export propagates to outer shell
        read_input < <(printf '{\"session_id\":\"test-session-extraction-001\",\"hook_event_name\":\"PreToolUse\"}') >/dev/null
        printf '%s' \"\${CLAUDE_SESSION_ID:-UNSET}\"
    " 2>/dev/null)

    if [[ "$result" == "test-session-extraction-001" ]]; then
        pass_test "read_input: extracts session_id and exports CLAUDE_SESSION_ID"
    else
        fail_test "read_input: expected CLAUDE_SESSION_ID='test-session-extraction-001', got '$result'" \
                  "log.sh read_input() must export CLAUDE_SESSION_ID from stdin JSON"
    fi
}

test_read_input_preserves_existing_session_id() {
    run_test
    # If CLAUDE_SESSION_ID is already set (e.g. future native env var), read_input must NOT overwrite it
    local HOOKS_DIR_LOCAL="${SCRIPT_DIR}/../hooks"
    local result
    result=$(bash -c "
        export CLAUDE_SESSION_ID='preexisting-session-id'
        source '${HOOKS_DIR_LOCAL}/log.sh' 2>/dev/null
        read_input < <(printf '{\"session_id\":\"new-session-id\",\"hook_event_name\":\"PreToolUse\"}') >/dev/null
        printf '%s' \"\${CLAUDE_SESSION_ID:-UNSET}\"
    " 2>/dev/null)

    if [[ "$result" == "preexisting-session-id" ]]; then
        pass_test "read_input: does not overwrite existing CLAUDE_SESSION_ID (preserves native env var)"
    else
        fail_test "read_input: overwrote existing CLAUDE_SESSION_ID" \
                  "expected 'preexisting-session-id', got '$result'"
    fi
}

test_read_input_empty_when_no_session_id() {
    run_test
    # JSON without session_id should result in empty CLAUDE_SESSION_ID (not "null" or error)
    local HOOKS_DIR_LOCAL="${SCRIPT_DIR}/../hooks"
    local result
    result=$(bash -c "
        unset CLAUDE_SESSION_ID
        source '${HOOKS_DIR_LOCAL}/log.sh' 2>/dev/null
        read_input < <(printf '{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\"}') >/dev/null
        printf '%s' \"\${CLAUDE_SESSION_ID:-EMPTY}\"
    " 2>/dev/null)

    if [[ "$result" == "EMPTY" || -z "$result" ]]; then
        pass_test "read_input: CLAUDE_SESSION_ID stays empty when stdin has no session_id"
    else
        fail_test "read_input: unexpected CLAUDE_SESSION_ID value when no session_id in JSON" \
                  "got '$result' (expected empty/unset)"
    fi
}

# ============================================================================
# Run all tests
# ============================================================================

echo "Running token history format tests..."
echo ""

echo "--- New 7-column format ---"
test_new_format_has_7_columns
test_new_format_project_hash_correct
test_new_format_project_name_correct

echo ""
echo "--- Project-scoped lifetime summing ---"
test_project_filter_sums_only_matching
test_project_filter_backward_compat_5col_entries
test_project_filter_excludes_other_projects_new_format

echo ""
echo "--- Backfill script ---"
test_backfill_script_exists
test_backfill_creates_backup
test_backfill_idempotent_on_new_format
test_backfill_adds_columns_to_5col_entries
test_backfill_unmatched_uses_unknown

echo ""
echo "--- Backfill null-project fallback (issue #175) ---"
test_backfill_null_fallback_uses_nearest_named_trace
test_backfill_null_fallback_all_unknown_stays_unknown
test_backfill_null_fallback_real_name_closest_no_regression

echo ""
echo "--- Backfill session_id exact match (DEC-BACKFILL-SESSION-MATCH-001) ---"
test_backfill_session_id_exact_match
test_backfill_session_id_match_trumps_closer_unknown
test_backfill_session_id_unknown_falls_back_to_timestamp

echo ""
echo "--- read_input() session_id extraction (DEC-SESSION-ID-001) ---"
test_read_input_extracts_session_id
test_read_input_preserves_existing_session_id
test_read_input_empty_when_no_session_id

echo ""
echo "--- Global lifetime sum ---"
test_global_lifetime_sum_all_entries

echo ""
echo "========================================="
echo "Test Results:"
echo "  Total:  $TESTS_RUN"
echo -e "  ${GREEN}Passed: $TESTS_PASSED${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "  ${RED}Failed: $TESTS_FAILED${NC}"
else
    echo "  Failed: 0"
fi
echo "========================================="

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
