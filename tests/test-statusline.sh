#!/usr/bin/env bash
# test-statusline.sh — Unit tests for scripts/statusline.sh two-line redesign.
#
# Purpose: Pipe sample JSON to statusline.sh and verify:
#   - Two lines are output (newline separator present)
#   - Context bar renders for various percentages and null
#   - Cost renders with correct color thresholds
#   - Duration formats correctly (ms to human-readable)
#   - Conditional segments appear/disappear correctly
#   - Cache efficiency calculates and displays correctly
#
# @decision DEC-TEST-STATUSLINE-001
# @title Statusline test suite validates two-line HUD correctness
# @status accepted
# @rationale The statusline is a pure function of stdin JSON + cache files.
# We can test it deterministically by controlling all inputs. No mocks needed —
# tests call the real script with controlled temp files for cache state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUSLINE="${SCRIPT_DIR}/../scripts/statusline.sh"

# Colors for output
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

# Helper: run statusline with given JSON, return raw output (ANSI stripped for comparisons)
# strip_ansi removes all ESC[ sequences
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

run_statusline() {
    local json="$1"
    local home_dir="${2:-}"
    # Run with HOME pointed at a temp dir so .todo-count and .statusline-cache are absent.
    # HOME must be set on the bash invocation (right side of pipe), not just printf.
    local tmpdir=""
    if [[ -z "$home_dir" ]]; then
        tmpdir=$(mktemp -d)
        home_dir="$tmpdir"
    fi
    local result
    result=$(printf '%s' "$json" | HOME="$home_dir" bash "$STATUSLINE" 2>/dev/null)
    [[ -n "$tmpdir" ]] && rm -rf "$tmpdir"
    printf '%s' "$result"
}

# ============================================================================
# Test group 1: Two-line structure
# ============================================================================

test_two_lines_output() {
    run_test
    local json='{"model":{"display_name":"Opus 4.6"},"workspace":{"current_dir":"/tmp/proj"},"cost":{"total_cost_usd":0.5,"total_duration_ms":60000},"context_window":{"used_percentage":40}}'
    local output
    output=$(run_statusline "$json")
    local line_count
    line_count=$(printf '%s' "$output" | wc -l | tr -d ' ')

    if [[ "$line_count" -eq 1 ]]; then
        pass_test "Output has two lines (newline separates them)"
    else
        fail_test "Output should have exactly 1 newline (2 lines)" "line_count=$line_count, output=$output"
    fi
}

test_line1_contains_model() {
    run_test
    local json='{"model":{"display_name":"Opus 4.6"},"workspace":{"current_dir":"/tmp/proj"},"cost":{},"context_window":{}}'
    local line1
    line1=$(run_statusline "$json" | head -1 | strip_ansi)

    if [[ "$line1" == *"Opus 4.6"* ]]; then
        pass_test "Line 1 contains model name"
    else
        fail_test "Line 1 missing model name" "line1=$line1"
    fi
}

test_line1_contains_workspace() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/Users/turla/myproject"},"cost":{},"context_window":{}}'
    local line1
    line1=$(run_statusline "$json" | head -1 | strip_ansi)

    if [[ "$line1" == *"myproject"* ]]; then
        pass_test "Line 1 contains workspace basename"
    else
        fail_test "Line 1 missing workspace name" "line1=$line1"
    fi
}

# ============================================================================
# Test group 2: Context bar
# ============================================================================

test_context_bar_null() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    if [[ "$line2" == *"░░░░░░░░░░░░"* && "$line2" == *"--"* ]]; then
        pass_test "Context bar shows all-empty with '--' when context_window absent"
    else
        fail_test "Context bar null rendering wrong" "line2=$line2"
    fi
}

test_context_bar_30pct() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{"used_percentage":30}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    # 30% of 12 = 3 filled chars
    if [[ "$line2" == *"30%"* && "$line2" == *"███"* ]]; then
        pass_test "Context bar renders 30% correctly (3 filled chars)"
    else
        fail_test "Context bar 30% rendering wrong" "line2=$line2"
    fi
}

test_context_bar_60pct() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{"used_percentage":60}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    # 60% of 12 = 7 filled chars
    if [[ "$line2" == *"60%"* && "$line2" == *"███████"* ]]; then
        pass_test "Context bar renders 60% correctly (7 filled chars)"
    else
        fail_test "Context bar 60% rendering wrong" "line2=$line2"
    fi
}

test_context_bar_85pct() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{"used_percentage":85}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    # 85% of 12 = 10 filled chars
    if [[ "$line2" == *"85%"* && "$line2" == *"██████████"* ]]; then
        pass_test "Context bar renders 85% correctly (10 filled chars)"
    else
        fail_test "Context bar 85% rendering wrong" "line2=$line2"
    fi
}

# ============================================================================
# Test group 3: Cost color thresholds
# ============================================================================

test_cost_display_present() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{"total_cost_usd":0.53},"context_window":{}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    # Use $'...' quoting to get a literal dollar sign in the pattern
    if [[ "$line2" == *$'\x240.53'* ]] || printf '%s' "$line2" | grep -qF '$0.53'; then
        pass_test "Cost displays correctly formatted"
    else
        fail_test "Cost not shown or wrong format" "line2=$line2"
    fi
}

test_cost_zero() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{"total_cost_usd":0},"context_window":{}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    if printf '%s' "$line2" | grep -qF '$0.00'; then
        pass_test 'Zero cost displays as $0.00'
    else
        fail_test 'Zero cost display wrong' "line2=$line2"
    fi
}

test_cost_no_field() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    if printf '%s' "$line2" | grep -qF '$0.00'; then
        pass_test 'Missing cost field defaults to $0.00'
    else
        fail_test 'Missing cost field not defaulted' "line2=$line2"
    fi
}

# ============================================================================
# Test group 4: Duration formatting
# ============================================================================

test_duration_less_than_1min() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{"total_duration_ms":30000},"context_window":{}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    if [[ "$line2" == *"<1m"* ]]; then
        pass_test "Duration 30s shows as '<1m'"
    else
        fail_test "Duration <1min format wrong" "line2=$line2"
    fi
}

test_duration_minutes() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{"total_duration_ms":720000},"context_window":{}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    if [[ "$line2" == *"12m"* ]]; then
        pass_test "Duration 720s shows as '12m'"
    else
        fail_test "Duration minutes format wrong" "line2=$line2"
    fi
}

test_duration_hours() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{"total_duration_ms":4320000},"context_window":{}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    # 4320000ms = 4320s = 72min = 1h 12m
    if [[ "$line2" == *"1h 12m"* ]]; then
        pass_test "Duration 72min shows as '1h 12m'"
    else
        fail_test "Duration hours format wrong" "line2=$line2"
    fi
}

test_duration_zero() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{"total_duration_ms":0},"context_window":{}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    if [[ "$line2" == *"<1m"* ]]; then
        pass_test "Duration 0ms shows as '<1m'"
    else
        fail_test "Duration 0ms format wrong" "line2=$line2"
    fi
}

# ============================================================================
# Test group 5: Conditional segments
# ============================================================================

test_dirty_absent_when_zero() {
    run_test
    # No cache file → cache_dirty defaults to 0
    # Use workspace basename "cleanws" (avoids substring "dirty" in "nodirty")
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/cleanws"},"cost":{},"context_window":{}}'
    local line1
    line1=$(run_statusline "$json" | head -1 | strip_ansi)

    # Check that the word "dirty" (with a preceding digit, as in "5 dirty") is absent
    if ! printf '%s' "$line1" | grep -qE '[0-9]+ dirty'; then
        pass_test "Dirty segment absent when dirty=0"
    else
        fail_test "Dirty segment shown when dirty=0" "line1=$line1"
    fi
}

test_lines_changed_absent_when_zero() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{"total_lines_added":0,"total_lines_removed":0},"context_window":{}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    if [[ "$line2" != *"+0"* && "$line2" != *"-0"* ]]; then
        pass_test "Lines changed segment absent when 0 lines"
    else
        fail_test "Lines changed shown when 0 lines" "line2=$line2"
    fi
}

test_lines_changed_present_when_nonzero() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{"total_lines_added":45,"total_lines_removed":12},"context_window":{}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    if [[ "$line2" == *"+45"* && "$line2" == *"-12"* ]]; then
        pass_test "Lines changed shows +added/-removed"
    else
        fail_test "Lines changed not displayed" "line2=$line2"
    fi
}

test_todos_absent_when_zero() {
    run_test
    # HOME points to temp dir → .todo-count absent → todo_count=0
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{}}'
    local line1
    line1=$(run_statusline "$json" | head -1 | strip_ansi)

    if [[ "$line1" != *"todo"* ]]; then
        pass_test "Todos segment absent when no .todo-count file"
    else
        fail_test "Todos shown when .todo-count absent" "line1=$line1"
    fi
}

test_todos_present_from_file() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    # TODO_CACHE in statusline.sh is "$HOME/.claude/.todo-count"
    mkdir -p "$tmpdir/.claude"
    echo "7" > "$tmpdir/.claude/.todo-count"

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{}}'
    local line1
    # HOME must be set on the bash invocation (right side of pipe)
    line1=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | head -1 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line1" == *"7 todos"* ]]; then
        pass_test "Todos segment shows count from .todo-count file"
    else
        fail_test "Todos not shown from file" "line1=$line1"
    fi
}

# ============================================================================
# Test group 6: Cache efficiency
# ============================================================================

test_cache_efficiency_absent_when_no_cache_tokens() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{"current_usage":{"input_tokens":10000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    if [[ "$line2" != *"cache"* ]]; then
        pass_test "Cache efficiency absent when no cache tokens"
    else
        fail_test "Cache efficiency shown when no cache tokens" "line2=$line2"
    fi
}

test_cache_efficiency_calculates_correctly() {
    run_test
    # cache_read=7400, input=1000, cache_create=1600 → total=10000 → 74%
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{"current_usage":{"input_tokens":1000,"cache_read_input_tokens":7400,"cache_creation_input_tokens":1600}}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    if [[ "$line2" == *"cache 74%"* ]]; then
        pass_test "Cache efficiency calculated as 74% (7400/10000)"
    else
        fail_test "Cache efficiency calculation wrong" "line2=$line2"
    fi
}

test_cache_efficiency_high_shows_green() {
    run_test
    # 80% efficiency → green (>=60%)
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{"current_usage":{"input_tokens":2000,"cache_read_input_tokens":8000,"cache_creation_input_tokens":0}}}'
    local line2_raw
    line2_raw=$(run_statusline "$json" | tail -1)

    # Green = ESC[32m
    if printf '%s' "$line2_raw" | grep -q $'\033\[32mcache'; then
        pass_test "Cache efficiency >=60% shows in green"
    else
        fail_test "Cache efficiency >=60% not green" "raw: $(printf '%s' "$line2_raw" | cat -v)"
    fi
}

# ============================================================================
# Test group 7: Removed segments — verify no old content
# ============================================================================

test_no_plan_segment() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{}}'
    local output
    output=$(run_statusline "$json" | strip_ansi)

    if [[ "$output" != *"Phase"* && "$output" != *"no plan"* ]]; then
        pass_test "No plan/phase segment in output (removed)"
    else
        fail_test "Plan segment still present in output" "output=$output"
    fi
}

test_no_test_segment() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{}}'
    local output
    output=$(run_statusline "$json" | strip_ansi)

    if [[ "$output" != *"✓ tests"* && "$output" != *"✗ tests"* ]]; then
        pass_test "No test status segment in output (removed)"
    else
        fail_test "Test segment still present in output" "output=$output"
    fi
}

test_no_version_segment() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"version":"1.2.3","cost":{},"context_window":{}}'
    local output
    output=$(run_statusline "$json" | strip_ansi)

    if [[ "$output" != *"1.2.3"* ]]; then
        pass_test "No version segment in output (removed)"
    else
        fail_test "Version still present in output" "output=$output"
    fi
}

test_no_time_segment() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{}}'
    local output
    output=$(run_statusline "$json" | strip_ansi)

    # HH:MM:SS pattern should not appear
    if ! printf '%s' "$output" | grep -qE '[0-9]{2}:[0-9]{2}:[0-9]{2}'; then
        pass_test "No HH:MM:SS time segment in output (removed)"
    else
        fail_test "Time segment still present in output" "output=$output"
    fi
}

# ============================================================================
# Run all tests
# ============================================================================

echo "Running statusline test suite..."
echo ""

echo "--- Two-line structure ---"
test_two_lines_output
test_line1_contains_model
test_line1_contains_workspace

echo ""
echo "--- Context bar ---"
test_context_bar_null
test_context_bar_30pct
test_context_bar_60pct
test_context_bar_85pct

echo ""
echo "--- Cost ---"
test_cost_display_present
test_cost_zero
test_cost_no_field

echo ""
echo "--- Duration formatting ---"
test_duration_less_than_1min
test_duration_minutes
test_duration_hours
test_duration_zero

echo ""
echo "--- Conditional segments ---"
test_dirty_absent_when_zero
test_lines_changed_absent_when_zero
test_lines_changed_present_when_nonzero
test_todos_absent_when_zero
test_todos_present_from_file

echo ""
echo "--- Cache efficiency ---"
test_cache_efficiency_absent_when_no_cache_tokens
test_cache_efficiency_calculates_correctly
test_cache_efficiency_high_shows_green

echo ""
echo "--- Removed segments ---"
test_no_plan_segment
test_no_test_segment
test_no_version_segment
test_no_time_segment

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
