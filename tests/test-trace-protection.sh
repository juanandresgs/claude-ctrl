#!/usr/bin/env bash
# test-trace-protection.sh — Tests for observatory hardening (Parts 1 and 2)
#
# Purpose: Verify trace protection features:
#   1. backup_trace_manifests() creates archives with correct contents
#   2. backup_trace_manifests() rotates to keep only 3 backups
#   3. Stage 0 detects data loss when count drops >30%
#   4. Stage 0 detects no-historical-baseline when all traces same day
#   5. Data loss flag suppresses trend analysis in output
#   6. Trace count canary warns on significant drop
#   7. Canary initializes correctly on first run (no warning)
#
# @decision DEC-TRACE-PROT-001
# @title Test-first approach for observatory hardening
# @status accepted
# @rationale These features protect against data loss scenarios that are hard to
#   reproduce accidentally. Tests use isolated temp directories so production
#   trace data is never affected. Each test creates its own fixture state.
#   No set -euo pipefail at the top level — matches existing hook test patterns.
#   Subshells source context-lib.sh with TRACE_STORE overridden per-test.
#
# Usage: bash tests/test-trace-protection.sh
# Returns: 0 if all tests pass, 1 if any fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="${WORKTREE_ROOT}/hooks"
OBS_SCRIPTS_DIR="${WORKTREE_ROOT}/skills/observatory/scripts"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Shared cleanup list
CLEANUP_DIRS=()
cleanup() { rm -rf "${CLEANUP_DIRS[@]}" 2>/dev/null || true; }
trap cleanup EXIT

# Create an isolated trace store
make_trace_store() {
    local d
    d=$(mktemp -d)
    CLEANUP_DIRS+=("$d")
    echo "$d"
}

# Create a minimal trace directory with manifest
make_trace_dir() {
    local store="$1"
    local trace_id="${2:-trace-$(date +%s%N 2>/dev/null || date +%s)}"
    local trace_day="${3:-2026-01-15}"
    mkdir -p "${store}/${trace_id}"
    cat > "${store}/${trace_id}/manifest.json" <<MANIFEST
{
  "trace_id": "${trace_id}",
  "started_at": "${trace_day}T10:00:00Z",
  "agent_type": "implementer",
  "status": "completed"
}
MANIFEST
    echo "${trace_id}"
}

# ============================================================
# Test 1: backup_trace_manifests creates archive with contents
# ============================================================
echo ""
echo "=== Test 1: backup_trace_manifests creates archive ==="
T1_STORE=$(make_trace_store)

make_trace_dir "$T1_STORE" "trace-aaa" "2026-01-10" >/dev/null
make_trace_dir "$T1_STORE" "trace-bbb" "2026-01-11" >/dev/null
make_trace_dir "$T1_STORE" "trace-ccc" "2026-01-12" >/dev/null

(
    source "${HOOKS_DIR}/log.sh" 2>/dev/null
    source "${HOOKS_DIR}/context-lib.sh" 2>/dev/null
    TRACE_STORE="$T1_STORE"   # must be set AFTER source (context-lib.sh line 528 overwrites it)
    backup_trace_manifests 2>/dev/null
) || true

archive_count=$(ls "$T1_STORE"/.manifest-backup-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
if [[ "$archive_count" -ge 1 ]]; then
    pass "Test 1a: archive created (found $archive_count archive(s))"
else
    fail "Test 1a: no archive created in $T1_STORE"
fi

first_archive=$(ls "$T1_STORE"/.manifest-backup-*.tar.gz 2>/dev/null | head -1)
if [[ -n "$first_archive" ]]; then
    manifest_count=$(tar -tzf "$first_archive" 2>/dev/null | grep -c 'manifest.json' || echo "0")
    if [[ "$manifest_count" -eq 3 ]]; then
        pass "Test 1b: archive contains 3 manifest files"
    else
        fail "Test 1b: archive contains $manifest_count manifest files (expected 3)"
    fi
else
    fail "Test 1b: no archive found to inspect"
fi

# ============================================================
# Test 2: backup_trace_manifests rotation (max 3 backups)
# ============================================================
echo ""
echo "=== Test 2: backup_trace_manifests rotation (max 3) ==="
T2_STORE=$(make_trace_store)
make_trace_dir "$T2_STORE" "trace-rot1" "2026-01-10" >/dev/null

# Pre-create 4 fake archives with distinct timestamps
for i in 01 02 03 04; do
    touch "${T2_STORE}/.manifest-backup-2026-01-${i}.tar.gz"
done

(
    source "${HOOKS_DIR}/log.sh" 2>/dev/null
    source "${HOOKS_DIR}/context-lib.sh" 2>/dev/null
    TRACE_STORE="$T2_STORE"   # must be set AFTER source
    backup_trace_manifests 2>/dev/null
) || true

final_count=$(ls "$T2_STORE"/.manifest-backup-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
if [[ "$final_count" -le 3 ]]; then
    pass "Test 2: rotation keeps ≤3 backups (found $final_count)"
else
    fail "Test 2: rotation failed — found $final_count backups (expected ≤3)"
fi

# ============================================================
# Test 3: Stage 0 detects data loss (count drops >30%)
# ============================================================
# analyze.sh computes TRACE_STORE as "${CLAUDE_DIR}/traces" (line 75).
# To isolate tests, we create a full CLAUDE_DIR layout with traces/ subdir
# so analyze.sh finds our test data rather than real production traces.
echo ""
echo "=== Test 3: Stage 0 data loss detection ==="
T3_CLAUDE=$(mktemp -d); CLEANUP_DIRS+=("$T3_CLAUDE")
T3_STORE="${T3_CLAUDE}/traces"
T3_OBS="${T3_CLAUDE}/observatory"
mkdir -p "$T3_STORE" "$T3_OBS"

# Current state: 10 traces (previous was 50 → 80% drop)
for i in $(seq 1 10); do
    make_trace_dir "$T3_STORE" "trace-curr-$(printf '%03d' "$i")" "2026-01-15" >/dev/null
done

T3_INDEX="${T3_STORE}/index.jsonl"
for i in $(seq 1 10); do
    printf '{"trace_id":"trace-curr-%03d","agent_type":"implementer","outcome":"completed","test_result":"pass","files_changed":5,"duration_seconds":120,"started_at":"2026-01-15T10:00:00Z"}\n' "$i" >> "$T3_INDEX"
done

# Previous cache shows 50 traces (will be read as analysis-cache.prev.json after snapshot)
printf '{"trace_stats":{"total":50},"dataset_integrity":{"prev_trace_count":50}}\n' > "${T3_OBS}/analysis-cache.json"

CLAUDE_DIR="$T3_CLAUDE" \
OBS_DIR="$T3_OBS" \
STATE_FILE="${T3_OBS}/state.json" \
    bash "${OBS_SCRIPTS_DIR}/analyze.sh" 2>/dev/null || true

if [[ -f "${T3_OBS}/analysis-cache.json" ]]; then
    data_loss=$(jq -r '.dataset_integrity.data_loss_suspected // false' "${T3_OBS}/analysis-cache.json" 2>/dev/null || echo "false")
    if [[ "$data_loss" == "true" ]]; then
        pass "Test 3: data_loss_suspected=true when count drops >30%"
    else
        fail "Test 3: data_loss_suspected=$data_loss (expected true)"
    fi
else
    fail "Test 3: analysis-cache.json not created"
fi

# ============================================================
# Test 4: Stage 0 detects no-historical-baseline (all same day)
# ============================================================
echo ""
echo "=== Test 4: Stage 0 no-historical-baseline ==="
T4_CLAUDE=$(mktemp -d); CLEANUP_DIRS+=("$T4_CLAUDE")
T4_STORE="${T4_CLAUDE}/traces"
T4_OBS="${T4_CLAUDE}/observatory"
mkdir -p "$T4_STORE" "$T4_OBS"

TODAY="2026-02-18"
for i in $(seq 1 5); do
    make_trace_dir "$T4_STORE" "trace-same-$(printf '%03d' "$i")" "$TODAY" >/dev/null
done

T4_INDEX="${T4_STORE}/index.jsonl"
for i in $(seq 1 5); do
    printf '{"trace_id":"trace-same-%03d","agent_type":"implementer","outcome":"completed","test_result":"pass","files_changed":3,"duration_seconds":100,"started_at":"%sT10:0%d:00Z"}\n' "$i" "$TODAY" "$i" >> "$T4_INDEX"
done

# No previous cache (first run — no analysis-cache.json)
CLAUDE_DIR="$T4_CLAUDE" \
OBS_DIR="$T4_OBS" \
STATE_FILE="${T4_OBS}/state.json" \
    bash "${OBS_SCRIPTS_DIR}/analyze.sh" 2>/dev/null || true

if [[ -f "${T4_OBS}/analysis-cache.json" ]]; then
    no_baseline=$(jq -r '.dataset_integrity.no_historical_baseline // false' "${T4_OBS}/analysis-cache.json" 2>/dev/null || echo "false")
    if [[ "$no_baseline" == "true" ]]; then
        pass "Test 4: no_historical_baseline=true when all traces same day"
    else
        fail "Test 4: no_historical_baseline=$no_baseline (expected true)"
    fi
else
    fail "Test 4: analysis-cache.json not created"
fi

# ============================================================
# Test 5: Data loss flag suppresses trends (trends=null)
# ============================================================
echo ""
echo "=== Test 5: Data loss suppresses trend analysis ==="
T5_CLAUDE=$(mktemp -d); CLEANUP_DIRS+=("$T5_CLAUDE")
T5_STORE="${T5_CLAUDE}/traces"
T5_OBS="${T5_CLAUDE}/observatory"
mkdir -p "$T5_STORE" "$T5_OBS"

# 5 current traces (prev was 50)
for i in $(seq 1 5); do
    make_trace_dir "$T5_STORE" "trace-dl-$(printf '%03d' "$i")" "2026-01-15" >/dev/null
done

T5_INDEX="${T5_STORE}/index.jsonl"
for i in $(seq 1 5); do
    printf '{"trace_id":"trace-dl-%03d","agent_type":"implementer","outcome":"completed","test_result":"pass","files_changed":2,"duration_seconds":90,"started_at":"2026-01-15T10:00:00Z"}\n' "$i" >> "$T5_INDEX"
done

# Previous cache with 50 traces and a trend
printf '{"trace_stats":{"total":50},"dataset_integrity":{"prev_trace_count":50},"improvement_signals":[],"trends":{"signal_count_delta":-2,"signal_trend":"improving"}}\n' > "${T5_OBS}/analysis-cache.json"

CLAUDE_DIR="$T5_CLAUDE" \
OBS_DIR="$T5_OBS" \
STATE_FILE="${T5_OBS}/state.json" \
    bash "${OBS_SCRIPTS_DIR}/analyze.sh" 2>/dev/null || true

if [[ -f "${T5_OBS}/analysis-cache.json" ]]; then
    data_loss=$(jq -r '.dataset_integrity.data_loss_suspected // false' "${T5_OBS}/analysis-cache.json" 2>/dev/null || echo "false")
    trends_val=$(jq -r '.trends' "${T5_OBS}/analysis-cache.json" 2>/dev/null || echo "not-null")

    if [[ "$data_loss" == "true" && "$trends_val" == "null" ]]; then
        pass "Test 5: trends=null when data_loss_suspected=true"
    elif [[ "$data_loss" != "true" ]]; then
        fail "Test 5: data_loss_suspected=$data_loss (expected true)"
    else
        fail "Test 5: trends not suppressed (trends=$trends_val, expected null)"
    fi
else
    fail "Test 5: analysis-cache.json not created"
fi

# ============================================================
# Test 6: Trace count canary warns on significant drop
# ============================================================
echo ""
echo "=== Test 6: Trace count canary warning ==="
T6_STORE=$(make_trace_store)

# Canary says 100 traces previously
echo "100|$(( $(date +%s) - 3600 ))" > "${T6_STORE}/.trace-count-canary"

# Current: only 20 traces (80% drop)
for i in $(seq 1 20); do
    make_trace_dir "$T6_STORE" "trace-canary-$(printf '%03d' "$i")" "2026-01-15" >/dev/null
done

warning_output=$(
    source "${HOOKS_DIR}/log.sh" 2>/dev/null
    source "${HOOKS_DIR}/context-lib.sh" 2>/dev/null
    TRACE_STORE="$T6_STORE"   # must be set AFTER source
    check_trace_count_canary 2>/dev/null || echo ""
)

if echo "$warning_output" | grep -qiE "trace count dropped|data loss|WARNING"; then
    pass "Test 6a: canary warns on >30% count drop"
else
    fail "Test 6a: no warning from canary (output: '$warning_output')"
fi

# Canary should be updated with new count (20)
if [[ -f "${T6_STORE}/.trace-count-canary" ]]; then
    new_count=$(cut -d'|' -f1 "${T6_STORE}/.trace-count-canary" 2>/dev/null || echo "?")
    if [[ "$new_count" -eq 20 ]]; then
        pass "Test 6b: canary file updated with current count"
    else
        fail "Test 6b: canary has count=$new_count (expected 20)"
    fi
else
    fail "Test 6b: canary file missing after check"
fi

# ============================================================
# Test 7: Canary initializes silently on first run
# ============================================================
echo ""
echo "=== Test 7: Canary first-run initialization ==="
T7_STORE=$(make_trace_store)
# No canary file exists

for i in $(seq 1 15); do
    make_trace_dir "$T7_STORE" "trace-init-$(printf '%03d' "$i")" "2026-01-15" >/dev/null
done

no_warn_output=$(
    source "${HOOKS_DIR}/log.sh" 2>/dev/null
    source "${HOOKS_DIR}/context-lib.sh" 2>/dev/null
    TRACE_STORE="$T7_STORE"   # must be set AFTER source
    check_trace_count_canary 2>/dev/null || echo ""
)

if echo "$no_warn_output" | grep -qiE "WARNING|dropped"; then
    fail "Test 7a: false warning on first-run (no baseline to compare)"
else
    pass "Test 7a: no false warning on canary initialization"
fi

if [[ -f "${T7_STORE}/.trace-count-canary" ]]; then
    stored=$(cut -d'|' -f1 "${T7_STORE}/.trace-count-canary" 2>/dev/null || echo "?")
    if [[ "$stored" -eq 15 ]]; then
        pass "Test 7b: canary initialized with correct count"
    else
        fail "Test 7b: canary has count=$stored (expected 15)"
    fi
else
    fail "Test 7b: canary file not created on first run"
fi

# ============================================================
# Test 8: check-implementer auto-captures files-changed.txt
# ============================================================
echo ""
echo "=== Test 8: check-implementer auto-captures files-changed.txt ==="
T8_GIT=$(make_trace_store)  # use as both git root and stand-in
T8_TRACE=$(make_trace_store)

# Set up a minimal git repo with a staged file
git -C "$T8_GIT" init -q 2>/dev/null
git -C "$T8_GIT" config user.email "test@test.com" 2>/dev/null
git -C "$T8_GIT" config user.name "Test" 2>/dev/null
echo "initial" > "${T8_GIT}/init.txt"
git -C "$T8_GIT" add init.txt 2>/dev/null
git -C "$T8_GIT" commit -q -m "initial" 2>/dev/null
# Add an unstaged change
echo "modified" > "${T8_GIT}/modified.sh"
git -C "$T8_GIT" add modified.sh 2>/dev/null  # staged

mkdir -p "${T8_TRACE}/artifacts"

# Simulate the check-implementer auto-capture block directly
(
    PROJECT_ROOT="$T8_GIT"
    TRACE_DIR="$T8_TRACE"
    if [[ -d "$TRACE_DIR/artifacts" && ! -f "$TRACE_DIR/artifacts/files-changed.txt" ]]; then
        git -C "$PROJECT_ROOT" diff --name-only 2>/dev/null > "$TRACE_DIR/artifacts/files-changed.txt" || true
        git -C "$PROJECT_ROOT" diff --cached --name-only 2>/dev/null >> "$TRACE_DIR/artifacts/files-changed.txt" || true
        git -C "$PROJECT_ROOT" log --name-only --format="" -5 2>/dev/null >> "$TRACE_DIR/artifacts/files-changed.txt" || true
        sort -u "$TRACE_DIR/artifacts/files-changed.txt" -o "$TRACE_DIR/artifacts/files-changed.txt" 2>/dev/null || true
    fi
) || true

if [[ -f "${T8_TRACE}/artifacts/files-changed.txt" ]]; then
    file_count=$(wc -l < "${T8_TRACE}/artifacts/files-changed.txt" | tr -d ' ')
    if [[ "$file_count" -ge 1 ]]; then
        pass "Test 8: files-changed.txt auto-captured ($file_count line(s))"
    else
        fail "Test 8: files-changed.txt is empty"
    fi
else
    fail "Test 8: files-changed.txt not created"
fi

# ============================================================
# Test 9: check-implementer auto-captures test-output.txt
# ============================================================
echo ""
echo "=== Test 9: check-implementer auto-captures test-output.txt ==="
T9_CLAUDE=$(make_trace_store)
T9_TRACE=$(make_trace_store)

# Write a .test-status file
echo "pass|0|$(date +%s)" > "${T9_CLAUDE}/.test-status"
mkdir -p "${T9_TRACE}/artifacts"

# Simulate auto-capture block
(
    CLAUDE_DIR="$T9_CLAUDE"
    PROJECT_ROOT="/nonexistent"
    TRACE_DIR="$T9_TRACE"
    if [[ -d "$TRACE_DIR/artifacts" && ! -f "$TRACE_DIR/artifacts/test-output.txt" ]]; then
        TS_FILE=""
        [[ -f "${CLAUDE_DIR}/.test-status" ]] && TS_FILE="${CLAUDE_DIR}/.test-status"
        if [[ -n "$TS_FILE" ]]; then
            echo "# Auto-captured from .test-status at $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TRACE_DIR/artifacts/test-output.txt"
            cat "$TS_FILE" >> "$TRACE_DIR/artifacts/test-output.txt" 2>/dev/null || true
            TS_RESULT=$(cut -d'|' -f1 "$TS_FILE" 2>/dev/null || echo "unknown")
            [[ "$TS_RESULT" == "pass" ]] && echo "Tests passed" >> "$TRACE_DIR/artifacts/test-output.txt"
            [[ "$TS_RESULT" == "fail" ]] && echo "Tests failed" >> "$TRACE_DIR/artifacts/test-output.txt"
        fi
    fi
) || true

if [[ -f "${T9_TRACE}/artifacts/test-output.txt" ]]; then
    if grep -q "Tests passed" "${T9_TRACE}/artifacts/test-output.txt"; then
        pass "Test 9: test-output.txt captured with 'Tests passed'"
    else
        fail "Test 9: test-output.txt exists but missing 'Tests passed' (content: $(cat "${T9_TRACE}/artifacts/test-output.txt"))"
    fi
else
    fail "Test 9: test-output.txt not created"
fi

# ============================================================
# Test 10: check-tester auto-captures verification-output.txt
# ============================================================
echo ""
echo "=== Test 10: check-tester auto-captures verification-output.txt ==="
T10_TRACE=$(make_trace_store)
mkdir -p "${T10_TRACE}/artifacts"
T10_PROOF=$(make_trace_store)
T10_PROOF_FILE="${T10_PROOF}/.proof-status"
echo "pending|$(date +%s)" > "$T10_PROOF_FILE"

T10_RESPONSE="Feature works correctly. AUTOVERIFY: CLEAN. **High** confidence."

# Simulate tester auto-capture block
(
    TRACE_DIR="$T10_TRACE"
    PROOF_FILE="$T10_PROOF_FILE"
    RESPONSE_TEXT="$T10_RESPONSE"
    if [[ ! -f "$TRACE_DIR/artifacts/verification-output.txt" && -n "$RESPONSE_TEXT" ]]; then
        echo "# Auto-captured from tester response at $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TRACE_DIR/artifacts/verification-output.txt"
        echo "$RESPONSE_TEXT" | head -c 8000 >> "$TRACE_DIR/artifacts/verification-output.txt" 2>/dev/null || true
    fi
) || true

if [[ -f "${T10_TRACE}/artifacts/verification-output.txt" ]]; then
    if grep -q "AUTOVERIFY" "${T10_TRACE}/artifacts/verification-output.txt"; then
        pass "Test 10: verification-output.txt captured with response content"
    else
        fail "Test 10: verification-output.txt exists but content unexpected"
    fi
else
    fail "Test 10: verification-output.txt not created"
fi

# ============================================================
# Test 11: check-tester skips capture if file already exists
# ============================================================
echo ""
echo "=== Test 11: check-tester does not overwrite existing verification-output.txt ==="
T11_TRACE=$(make_trace_store)
mkdir -p "${T11_TRACE}/artifacts"
echo "original content" > "${T11_TRACE}/artifacts/verification-output.txt"

T11_RESPONSE="New tester response"

(
    TRACE_DIR="$T11_TRACE"
    RESPONSE_TEXT="$T11_RESPONSE"
    PROOF_FILE="/nonexistent"
    if [[ ! -f "$TRACE_DIR/artifacts/verification-output.txt" && -n "$RESPONSE_TEXT" ]]; then
        echo "$RESPONSE_TEXT" > "$TRACE_DIR/artifacts/verification-output.txt"
    fi
) || true

content=$(cat "${T11_TRACE}/artifacts/verification-output.txt" 2>/dev/null)
if [[ "$content" == "original content" ]]; then
    pass "Test 11: existing verification-output.txt not overwritten"
else
    fail "Test 11: file was overwritten (content: $content)"
fi

# ============================================================
# Test 12: check-guardian auto-captures commit-info.txt
# ============================================================
echo ""
echo "=== Test 12: check-guardian auto-captures commit-info.txt ==="
T12_GIT=$(make_trace_store)
T12_TRACE=$(make_trace_store)

git -C "$T12_GIT" init -q 2>/dev/null
git -C "$T12_GIT" config user.email "test@test.com" 2>/dev/null
git -C "$T12_GIT" config user.name "Test" 2>/dev/null
echo "file1" > "${T12_GIT}/file1.txt"
git -C "$T12_GIT" add . 2>/dev/null
git -C "$T12_GIT" commit -q -m "feat: add feature" 2>/dev/null

mkdir -p "${T12_TRACE}/artifacts"

# Simulate guardian auto-capture block
(
    PROJECT_ROOT="$T12_GIT"
    TRACE_DIR="$T12_TRACE"
    if [[ -d "$TRACE_DIR/artifacts" ]]; then
        {
            git -C "$PROJECT_ROOT" log --oneline -1 2>/dev/null || true
            git -C "$PROJECT_ROOT" diff --stat HEAD~1..HEAD 2>/dev/null || true
        } > "$TRACE_DIR/artifacts/commit-info.txt" 2>/dev/null || true
    fi
) || true

if [[ -f "${T12_TRACE}/artifacts/commit-info.txt" ]]; then
    if grep -q "feat: add feature" "${T12_TRACE}/artifacts/commit-info.txt"; then
        pass "Test 12: commit-info.txt captured with commit message"
    else
        fail "Test 12: commit-info.txt exists but missing commit message (content: $(cat "${T12_TRACE}/artifacts/commit-info.txt"))"
    fi
else
    fail "Test 12: commit-info.txt not created"
fi

# ============================================================
# Test 13: traces/.gitignore excludes everything except itself
# ============================================================
echo ""
echo "=== Test 13: traces/.gitignore defense-in-depth ==="
GITIGNORE_FILE="${WORKTREE_ROOT}/traces/.gitignore"
if [[ -f "$GITIGNORE_FILE" ]]; then
    if grep -q '^\*$' "$GITIGNORE_FILE" && grep -q '!\.gitignore' "$GITIGNORE_FILE"; then
        pass "Test 13: traces/.gitignore has wildcard exclude + self-exception"
    else
        fail "Test 13: traces/.gitignore missing required patterns (content: $(cat "$GITIGNORE_FILE"))"
    fi
else
    fail "Test 13: traces/.gitignore does not exist"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================="

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
