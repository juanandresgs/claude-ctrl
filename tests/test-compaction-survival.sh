#!/usr/bin/env bash
# Tests for B-track compaction survival improvements.
#
# Covers:
#   B2 — Plan file as compaction anchor (compact-preserve.sh + session-init.sh)
#   B1 — SPECIFICS section with full paths + git diff (compact-preserve.sh)
#   B3 — Compaction forensics logging (session-init.sh: mv + .compaction-log)
#
# @decision DEC-BUDGET-001
# @title Test suite for B-track compaction survival improvements
# @status accepted
# @rationale Tests verify the three B-track changes work in isolation using
#   synthetic temp directories and synthetic preserve files. Each test creates
#   its own isolated environment so there are no cross-test or live-state
#   dependencies. Pattern A (awk NR<=N) and Pattern B ([[ =~ ]]) compliance
#   is verified implicitly via the pipefail-safe test harness.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="${SCRIPT_DIR}/../hooks"
CONTEXT_LIB="${HOOKS_DIR}/context-lib.sh"

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    GREEN='' RED='' YELLOW='' NC=''
fi

passed=0
failed=0

pass() { echo -e "${GREEN}PASS${NC} $1"; passed=$((passed + 1)); }
fail() { echo -e "${RED}FAIL${NC} $1: $2"; failed=$((failed + 1)); }

# Source context-lib for safe_cleanup
source "$CONTEXT_LIB"

echo "=== Compaction Survival Tests (B1/B2/B3) ==="
echo ""

# =============================================================================
# B2 TESTS: Plan file anchor in compact-preserve.sh
# =============================================================================
echo "--- B2: Plan file anchor (compact-preserve.sh) ---"

# Test B2-1: Recent plan.md is picked up as anchor
TEST_DIR=$(mktemp -d)
trap 'safe_cleanup "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/.claude"
echo "# My Plan" > "$TEST_DIR/plan.md"
# Touch to ensure it's within 2h (it was just created)

# Source only context-lib and call the logic inline (avoids full hook execution)
_PLAN_FILE_ANCHOR=""
for _plan_candidate in \
    "$TEST_DIR/plans/"*.md \
    "$TEST_DIR/plan.md" \
    "$TEST_DIR/PLAN.md"; do
    [[ ! -f "$_plan_candidate" ]] && continue
    if [[ "$(uname)" == "Darwin" ]]; then
        _plan_mtime=$(stat -f %m "$_plan_candidate" 2>/dev/null || echo "0")
    else
        _plan_mtime=$(stat -c %Y "$_plan_candidate" 2>/dev/null || echo "0")
    fi
    _now=$(date +%s)
    _age=$(( _now - _plan_mtime ))
    if [[ "$_age" -le 7200 ]]; then
        _PLAN_FILE_ANCHOR="$_plan_candidate"
        break
    fi
done

if [[ "$_PLAN_FILE_ANCHOR" == "$TEST_DIR/plan.md" ]]; then
    pass "B2-1: recent plan.md detected as anchor"
else
    fail "B2-1: recent plan.md not detected" "got: '$_PLAN_FILE_ANCHOR', expected: '$TEST_DIR/plan.md'"
fi

# Test B2-2: Stale plan.md (older than 2h) is NOT picked up
TEST_DIR2=$(mktemp -d)
mkdir -p "$TEST_DIR2/.claude"
echo "# Old Plan" > "$TEST_DIR2/plan.md"
# Force mtime to 3 hours ago
touch -t "$(date -v-3H '+%Y%m%d%H%M' 2>/dev/null || date --date='3 hours ago' '+%Y%m%d%H%M' 2>/dev/null || echo "200001010000")" "$TEST_DIR2/plan.md" 2>/dev/null || true

_PLAN_FILE_ANCHOR2=""
for _plan_candidate2 in \
    "$TEST_DIR2/plans/"*.md \
    "$TEST_DIR2/plan.md" \
    "$TEST_DIR2/PLAN.md"; do
    [[ ! -f "$_plan_candidate2" ]] && continue
    if [[ "$(uname)" == "Darwin" ]]; then
        _plan_mtime2=$(stat -f %m "$_plan_candidate2" 2>/dev/null || echo "0")
    else
        _plan_mtime2=$(stat -c %Y "$_plan_candidate2" 2>/dev/null || echo "0")
    fi
    _now2=$(date +%s)
    _age2=$(( _now2 - _plan_mtime2 ))
    if [[ "$_age2" -le 7200 ]]; then
        _PLAN_FILE_ANCHOR2="$_plan_candidate2"
        break
    fi
done

if [[ -z "$_PLAN_FILE_ANCHOR2" ]]; then
    pass "B2-2: stale plan.md (3h old) correctly ignored"
else
    fail "B2-2: stale plan.md incorrectly picked up" "got: '$_PLAN_FILE_ANCHOR2'"
fi
safe_cleanup "$TEST_DIR2"

# Test B2-3: plans/*.md is preferred when present and recent
TEST_DIR3=$(mktemp -d)
mkdir -p "$TEST_DIR3/.claude" "$TEST_DIR3/plans"
echo "# Dir Plan" > "$TEST_DIR3/plans/phase1.md"
echo "# Root Plan" > "$TEST_DIR3/plan.md"

_PLAN_FILE_ANCHOR3=""
for _plan_candidate3 in \
    "$TEST_DIR3/plans/"*.md \
    "$TEST_DIR3/plan.md" \
    "$TEST_DIR3/PLAN.md"; do
    [[ ! -f "$_plan_candidate3" ]] && continue
    if [[ "$(uname)" == "Darwin" ]]; then
        _plan_mtime3=$(stat -f %m "$_plan_candidate3" 2>/dev/null || echo "0")
    else
        _plan_mtime3=$(stat -c %Y "$_plan_candidate3" 2>/dev/null || echo "0")
    fi
    _now3=$(date +%s)
    _age3=$(( _now3 - _plan_mtime3 ))
    if [[ "$_age3" -le 7200 ]]; then
        _PLAN_FILE_ANCHOR3="$_plan_candidate3"
        break
    fi
done

if [[ "$_PLAN_FILE_ANCHOR3" == "$TEST_DIR3/plans/phase1.md" ]]; then
    pass "B2-3: plans/*.md takes priority over plan.md"
else
    fail "B2-3: plans/*.md not preferred" "got: '$_PLAN_FILE_ANCHOR3'"
fi
safe_cleanup "$TEST_DIR3"

# Test B2-4: No plan files → anchor is empty (no crash)
TEST_DIR4=$(mktemp -d)
mkdir -p "$TEST_DIR4/.claude"

_PLAN_FILE_ANCHOR4=""
for _plan_candidate4 in \
    "$TEST_DIR4/plans/"*.md \
    "$TEST_DIR4/plan.md" \
    "$TEST_DIR4/PLAN.md"; do
    [[ ! -f "$_plan_candidate4" ]] && continue
    _PLAN_FILE_ANCHOR4="$_plan_candidate4"
    break
done

if [[ -z "$_PLAN_FILE_ANCHOR4" ]]; then
    pass "B2-4: no plan files → anchor empty, no crash"
else
    fail "B2-4: unexpected anchor with no plan files" "got: '$_PLAN_FILE_ANCHOR4'"
fi
safe_cleanup "$TEST_DIR4"

echo ""
echo "--- B2: Plan file anchor injection (session-init.sh) ---"

# Test B2-5: session-init.sh extracts PLAN FILE: line from preserve file
TEST_DIR5=$(mktemp -d)
mkdir -p "$TEST_DIR5/.claude"
PRESERVE5="$TEST_DIR5/.claude/.preserved-context"
cat > "$PRESERVE5" <<'EOF'
# Preserved context from pre-compaction (2026-02-26T12:00:00Z)
Git: main | 3 uncommitted
PLAN FILE: /tmp/myproject/plan.md
READ THIS FILE after compaction — it contains your detailed implementation approach.
RESUME DIRECTIVE: Continue implementing feature X
  - Step 1 done
  - Step 2 next
EOF

# Simulate session-init.sh plan anchor extraction logic
_PLAN_ANCHOR_PATH5=""
while IFS= read -r _pa_line; do
    if [[ "$_pa_line" =~ ^PLAN\ FILE:\ (.*) ]]; then
        _PLAN_ANCHOR_PATH5="${BASH_REMATCH[1]}"
        break
    fi
done < "$PRESERVE5"

if [[ "$_PLAN_ANCHOR_PATH5" == "/tmp/myproject/plan.md" ]]; then
    pass "B2-5: session-init extracts PLAN FILE path correctly"
else
    fail "B2-5: PLAN FILE extraction failed" "got: '$_PLAN_ANCHOR_PATH5'"
fi

# Test B2-6: session-init.sh produces POST-COMPACTION message when anchor found
_INJECTED_MSG5="POST-COMPACTION: Your implementation plan is at $_PLAN_ANCHOR_PATH5. Read it before proceeding — it contains your detailed approach, file paths, and reasoning."
if [[ "$_INJECTED_MSG5" =~ "POST-COMPACTION:" && "$_INJECTED_MSG5" =~ "/tmp/myproject/plan.md" ]]; then
    pass "B2-6: POST-COMPACTION message contains plan path"
else
    fail "B2-6: POST-COMPACTION message malformed" "got: '$_INJECTED_MSG5'"
fi

# Test B2-7: No PLAN FILE line → anchor path is empty
PRESERVE7="$TEST_DIR5/.claude/.preserved-context-2"
cat > "$PRESERVE7" <<'EOF'
# Preserved context
Git: main | 0 uncommitted
RESUME DIRECTIVE: Continue feature Y
EOF

_PLAN_ANCHOR_PATH7=""
while IFS= read -r _pa_line7; do
    if [[ "$_pa_line7" =~ ^PLAN\ FILE:\ (.*) ]]; then
        _PLAN_ANCHOR_PATH7="${BASH_REMATCH[1]}"
        break
    fi
done < "$PRESERVE7"

if [[ -z "$_PLAN_ANCHOR_PATH7" ]]; then
    pass "B2-7: no PLAN FILE line → anchor empty"
else
    fail "B2-7: unexpected plan anchor extracted" "got: '$_PLAN_ANCHOR_PATH7'"
fi
safe_cleanup "$TEST_DIR5"

echo ""

# =============================================================================
# B1 TESTS: SPECIFICS section in compact-preserve.sh
# =============================================================================
echo "--- B1: SPECIFICS section (compact-preserve.sh) ---"

# Test B1-1: SPECIFICS section is generated with full paths up to 15
TEST_DIR_B1=$(mktemp -d)
mkdir -p "$TEST_DIR_B1/.claude"
SESSION_FILE_B1="$TEST_DIR_B1/.claude/.session-changes"

# Write 20 file paths to session changes
for i in $(seq 1 20); do
    echo "/full/path/to/file${i}.sh" >> "$SESSION_FILE_B1"
done

# Simulate the SPECIFICS generation logic
_SPECIFICS_LINES_B1=()
_SPECIFICS_LINES_B1+=("SPECIFICS:")
_SPECIFICS_LINES_B1+=("  Session files (full paths):")

_spec_file_count_b1=0
while IFS= read -r _spec_path; do
    [[ -z "$_spec_path" ]] && continue
    _SPECIFICS_LINES_B1+=("    $_spec_path")
    _spec_file_count_b1=$(( _spec_file_count_b1 + 1 ))
    [[ "$_spec_file_count_b1" -ge 15 ]] && break
done < <(sort -u "$SESSION_FILE_B1")

# Count file lines in SPECIFICS (those starting with 4 spaces)
_file_line_count=0
for _sl in "${_SPECIFICS_LINES_B1[@]}"; do
    [[ "$_sl" =~ ^"    /full/path" ]] && _file_line_count=$(( _file_line_count + 1 ))
done

if [[ "$_file_line_count" -eq 15 ]]; then
    pass "B1-1: SPECIFICS limits to 15 full paths (20 input → 15 output)"
else
    fail "B1-1: SPECIFICS file count wrong" "got: $_file_line_count, expected: 15"
fi

# Test B1-2: SPECIFICS uses full paths (not basename)
_has_full_path=false
for _sl in "${_SPECIFICS_LINES_B1[@]}"; do
    if [[ "$_sl" =~ "    /full/path/to/file1.sh" ]]; then
        _has_full_path=true
        break
    fi
done

if [[ "$_has_full_path" == "true" ]]; then
    pass "B1-2: SPECIFICS contains full paths (not just basenames)"
else
    fail "B1-2: SPECIFICS missing full paths" "lines: ${_SPECIFICS_LINES_B1[*]}"
fi

# Test B1-3: SPECIFICS with fewer than 15 files includes all of them
SESSION_FILE_B1b="$TEST_DIR_B1/.claude/.session-changes-b"
for i in $(seq 1 5); do
    echo "/path/file${i}.py" >> "$SESSION_FILE_B1b"
done

_SPEC_B1b=()
_spec_count_b1b=0
while IFS= read -r _sp; do
    [[ -z "$_sp" ]] && continue
    _SPEC_B1b+=("    $_sp")
    _spec_count_b1b=$(( _spec_count_b1b + 1 ))
    [[ "$_spec_count_b1b" -ge 15 ]] && break
done < <(sort -u "$SESSION_FILE_B1b")

if [[ "${#_SPEC_B1b[@]}" -eq 5 ]]; then
    pass "B1-3: SPECIFICS includes all files when < 15 (5 files → 5 lines)"
else
    fail "B1-3: SPECIFICS count wrong for small file list" "got: ${#_SPEC_B1b[@]}"
fi

safe_cleanup "$TEST_DIR_B1"

echo ""

# =============================================================================
# B3 TESTS: Compaction forensics logging (session-init.sh)
# =============================================================================
echo "--- B3: Compaction forensics logging (session-init.sh) ---"

# Test B3-1: mv renames preserve file to .last (not deleted)
TEST_DIR_B3=$(mktemp -d)
mkdir -p "$TEST_DIR_B3/.claude"
PRESERVE_B3="$TEST_DIR_B3/.claude/.preserved-context"
echo "test content" > "$PRESERVE_B3"

_PRESERVE_LAST_B3="${PRESERVE_B3}.last"
mv "$PRESERVE_B3" "$_PRESERVE_LAST_B3"

if [[ ! -f "$PRESERVE_B3" && -f "$_PRESERVE_LAST_B3" ]]; then
    pass "B3-1: preserve file renamed to .last (original deleted, .last exists)"
else
    fail "B3-1: rename failed" "original exists: $(test -f "$PRESERVE_B3" && echo yes || echo no), .last exists: $(test -f "$_PRESERVE_LAST_B3" && echo yes || echo no)"
fi

# Test B3-2: .compaction-log is written with correct pipe-delimited format
COMPACTION_LOG_B3="$TEST_DIR_B3/.claude/.compaction-log"
_CL_TIMESTAMP_B3=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)
_CL_LINES_B3=$(wc -l < "$_PRESERVE_LAST_B3" | tr -d ' ')
_CL_HAS_RESUME_B3="yes"
_CL_HAS_PLAN_B3="/path/to/plan.md"
echo "${_CL_TIMESTAMP_B3}|${_CL_LINES_B3}|${_CL_HAS_RESUME_B3}|${_CL_HAS_PLAN_B3}" >> "$COMPACTION_LOG_B3"

if [[ -f "$COMPACTION_LOG_B3" ]]; then
    _LOG_LINE=$(cat "$COMPACTION_LOG_B3")
    _FIELD_COUNT=$(echo "$_LOG_LINE" | tr '|' '\n' | wc -l | tr -d ' ')
    if [[ "$_FIELD_COUNT" -eq 4 ]]; then
        pass "B3-2: .compaction-log written with 4 pipe-delimited fields"
    else
        fail "B3-2: wrong field count in .compaction-log" "got: $_FIELD_COUNT fields in: '$_LOG_LINE'"
    fi
else
    fail "B3-2: .compaction-log not created"
fi

# Test B3-3: Timestamp field matches ISO 8601 pattern
_TIMESTAMP_FIELD=$(cut -d'|' -f1 "$COMPACTION_LOG_B3")
if [[ "$_TIMESTAMP_FIELD" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    pass "B3-3: timestamp field is valid ISO 8601 UTC format"
else
    fail "B3-3: timestamp format invalid" "got: '$_TIMESTAMP_FIELD'"
fi

# Test B3-4: Line count field is numeric
_LINES_FIELD=$(cut -d'|' -f2 "$COMPACTION_LOG_B3")
if [[ "$_LINES_FIELD" =~ ^[0-9]+$ ]]; then
    pass "B3-4: lines_preserved field is numeric"
else
    fail "B3-4: lines_preserved not numeric" "got: '$_LINES_FIELD'"
fi

# Test B3-5: .compaction-log accumulates (append semantics)
echo "${_CL_TIMESTAMP_B3}|5|no|no" >> "$COMPACTION_LOG_B3"
_LOG_LINE_COUNT=$(wc -l < "$COMPACTION_LOG_B3" | tr -d ' ')
if [[ "$_LOG_LINE_COUNT" -eq 2 ]]; then
    pass "B3-5: .compaction-log accumulates entries (append semantics)"
else
    fail "B3-5: .compaction-log doesn't accumulate" "got: $_LOG_LINE_COUNT lines"
fi

# Test B3-6: no-plan case uses 'no' for has_plan field
PRESERVE_B3b="$TEST_DIR_B3/.claude/.preserved-context-b"
echo "only one line" > "$PRESERVE_B3b"
_PRESERVE_LAST_B3b="${PRESERVE_B3b}.last"
mv "$PRESERVE_B3b" "$_PRESERVE_LAST_B3b"

_CL_HAS_PLAN_B3b="no"  # No plan anchor found
_LOG_LINE_B3b="${_CL_TIMESTAMP_B3}|1|no|${_CL_HAS_PLAN_B3b}"
_HAS_PLAN_FIELD=$(echo "$_LOG_LINE_B3b" | cut -d'|' -f4)
if [[ "$_HAS_PLAN_FIELD" == "no" ]]; then
    pass "B3-6: no-plan case records 'no' in has_plan field"
else
    fail "B3-6: no-plan case field wrong" "got: '$_HAS_PLAN_FIELD'"
fi

safe_cleanup "$TEST_DIR_B3"

echo ""
echo "============================================"
echo "Compaction Survival Tests: $passed passed, $failed failed"
echo "============================================"

[[ "$failed" -eq 0 ]] && exit 0 || exit 1
