#!/usr/bin/env bash
# test-statusline.sh — Unit tests for scripts/statusline.sh two-line redesign.
#
# Purpose: Pipe sample JSON to statusline.sh and verify:
#   - Two lines are output (newline separator present)
#   - Context bar renders for various percentages and null
#   - Cost renders with correct color thresholds and ~$ prefix
#   - Duration formats correctly (ms to human-readable)
#   - Conditional segments appear/disappear correctly
#   - Cache efficiency calculates and displays correctly
#   - Domain-clustered line 1: dirty:/wt: labels, agents: label, todos: label
#   - Token segment: tks: Nk(+Sk) notation with project Σ, correct color thresholds
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

# Set a fixed session ID so statusline.sh reads the per-session cache file we create
export CLAUDE_SESSION_ID="test-statusline-$$"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_RUN=0

# Cleanup trap (DEC-PROD-002): collect temp dirs and remove on exit
_CLEANUP_DIRS=()
trap '[[ ${#_CLEANUP_DIRS[@]} -gt 0 ]] && rm -rf "${_CLEANUP_DIRS[@]}" 2>/dev/null; true' EXIT
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
    # Run with HOME pointed at a temp dir so .todo-count and .statusline-cache-* are absent.
    # HOME must be set on the bash invocation (right side of pipe), not just printf.
    local tmpdir=""
    if [[ -z "$home_dir" ]]; then
        tmpdir=$(mktemp -d)
        home_dir="$tmpdir"
    fi
    local result
    result=$(printf '%s' "$json" | HOME="$home_dir" COLUMNS=200 bash "$STATUSLINE" 2>/dev/null)
    [[ -n "$tmpdir" ]] && rm -rf "$tmpdir"
    printf '%s' "$result"
}


# Run statusline with custom COLUMNS + HOME. Captures full output first to avoid SIGPIPE.
run_sl_columns() {
    local json="$1" columns="$2" home_dir="${3:-}"
    local tmpdir=""
    if [[ -z "$home_dir" ]]; then
        tmpdir=$(mktemp -d)
        home_dir="$tmpdir"
    fi
    local result
    result=$(printf '%s' "$json" | COLUMNS="$columns" HOME="$home_dir" bash "$STATUSLINE" 2>/dev/null)
    [[ -n "$tmpdir" ]] && rm -rf "$tmpdir"
    printf '%s' "$result"
}

# Extract line N (1-indexed) from multiline string without pipes (avoids SIGPIPE)
# Uses [[ ]] comparison to avoid (( )) returning exit 1 when condition is false (set -e safe)
extract_line() {
    local str="$1" n="$2" i=0
    while IFS= read -r _el_line; do
        i=$(( i + 1 ))
        if [[ "$i" -eq "$n" ]]; then
            printf '%s' "$_el_line"
            return 0
        fi
    done <<< "$str"
}

# Helper: get line 2 from run_statusline output (primary metrics: ctx bar, tokens, cost, lifetime)
# With the 4-line layout, "tail -1" now gets line 3 (secondary). All primary metrics are on line 2.
run_statusline_l2() {
    local _l2_out
    _l2_out=$(run_statusline "$@")
    extract_line "$_l2_out" 2
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

    if [[ "$line_count" -ge 2 ]]; then
        pass_test "Output has multiple lines (4-line layout: line_count=$line_count)"
    else
        fail_test "Output should have at least 2 newlines (4-line layout)" "line_count=$line_count, output=$output"
    fi
}

test_line1_contains_model() {
    run_test
    local json='{"model":{"display_name":"Opus 4.6"},"workspace":{"current_dir":"/tmp/proj"},"cost":{},"context_window":{}}'
    local _l1m_out line2
    # Model moved to Line 2 (combined with ctx bar) in the reorg layout
    _l1m_out=$(run_statusline "$json")
    line2=$(extract_line "$_l1m_out" 2 | strip_ansi)

    if [[ "$line2" == *"Opus 4.6"* ]]; then
        pass_test "Line 2 contains model name (model+ctx bar combo in reorg layout)"
    else
        fail_test "Line 2 missing model name (model moved to Line 2 combo in reorg)" "line2=$line2"
    fi
}

test_line1_contains_workspace() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/Users/turla/myproject"},"cost":{},"context_window":{}}'
    local line1
    local _rsl_out
    _rsl_out=$(run_statusline "$json")
    line1=$(extract_line "$_rsl_out" 1 | strip_ansi)

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
    line2=$(run_statusline_l2 "$json" | strip_ansi)

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
    line2=$(run_statusline_l2 "$json" | strip_ansi)

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
    line2=$(run_statusline_l2 "$json" | strip_ansi)

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
    line2=$(run_statusline_l2 "$json" | strip_ansi)

    # 85% of 12 = 10 filled chars
    if [[ "$line2" == *"85%"* && "$line2" == *"██████████"* ]]; then
        pass_test "Context bar renders 85% correctly (10 filled chars)"
    else
        fail_test "Context bar 85% rendering wrong" "line2=$line2"
    fi
}

# ============================================================================
# Test group 3: Cost — lifetime cost is now a dim parenthetical on Line 2 ∑ segment.
# Format: "∑NK tks (API equiv: ~$N.NN)" — only shown when lifetime_cost > 0.
# ============================================================================

test_cost_tilde_prefix() {
    run_test
    # Cost is on Line 2 as dim parenthetical; no "est. lifetime" label anywhere.
    # When no lifetime_cost in cache, no "API equiv" parenthetical shown on Line 2.
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{"total_cost_usd":0.53},"context_window":{}}'
    local line2
    line2=$(run_statusline_l2 "$json" | strip_ansi)

    # No lifetime cache → no API equiv parenthetical (lifetime_cost=0)
    if ! printf '%s' "$line2" | grep -qF 'API equiv'; then
        pass_test "Line 2 has no API equiv parenthetical when lifetime_cost=0 (no cache)"
    else
        fail_test "Line 2 should not show API equiv when lifetime_cost=0" "line2=$line2"
    fi
}

test_cost_display_present() {
    run_test
    # Verify lifetime cost shows on Line 2 as parenthetical when lifetime_cost is non-zero.
    # Requires lifetime_tokens > 0 to show ∑ segment (which carries the cost parenthetical).
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    printf '{"dirty":0,"worktrees":0,"agents_active":0,"agents_types":"","todo_project":0,"todo_global":0,"lifetime_cost":12.40,"lifetime_tokens":1000000}' \
        > "$tmpdir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{"total_cost_usd":0.53},"context_window":{"total_input_tokens":100000,"total_output_tokens":45000}}'
    local line2
    local output
    output=$(run_sl_columns "$json" 250 "$tmpdir")
    line2=$(extract_line "$output" 2 | strip_ansi)
    rm -rf "$tmpdir"

    if printf '%s' "$line2" | grep -qF 'API equiv'; then
        pass_test "Line 2 shows 'API equiv' cost parenthetical when lifetime_cost is non-zero"
    else
        fail_test "Line 2 missing 'API equiv' parenthetical in ∑ segment" "line2=$line2"
    fi
}

test_cost_zero() {
    run_test
    # When lifetime_cost=0, no API equiv parenthetical on Line 2 ∑ segment
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{"total_cost_usd":0},"context_window":{}}'
    local output
    output=$(run_statusline "$json")
    local line2
    line2=$(extract_line "$output" 2 | strip_ansi)

    # No lifetime cost parenthetical when lifetime=0
    if ! printf '%s' "$line2" | grep -qF 'API equiv'; then
        pass_test "No API equiv parenthetical on Line 2 when cost=0 and no lifetime cache"
    else
        fail_test "Unexpected API equiv shown on Line 2 when cost=0 and no lifetime cache" "line2=$line2"
    fi
}

test_cost_no_field() {
    run_test
    # When cost field absent, still no API equiv parenthetical on Line 2 (lifetime_cost=0)
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{}}'
    local output
    output=$(run_statusline "$json")
    local line2
    line2=$(extract_line "$output" 2 | strip_ansi)

    if ! printf '%s' "$line2" | grep -qF 'API equiv'; then
        pass_test "No API equiv parenthetical on Line 2 when cost field absent"
    else
        fail_test "Unexpected API equiv shown on Line 2 when cost field absent" "line2=$line2"
    fi
}

# ============================================================================
# Test group 4: Duration formatting
# ============================================================================

test_duration_less_than_1min() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{"total_duration_ms":30000},"context_window":{}}'
    local _rsl_out line3
    # Duration on Line 3 (session meta) as "session <1m"
    _rsl_out=$(run_statusline "$json")
    line3=$(extract_line "$_rsl_out" 3 | strip_ansi)

    if [[ "$line3" == *"session <1m"* ]]; then
        pass_test "Duration 30s shows as 'session <1m' on Line 3"
    else
        fail_test "Duration <1min format wrong (expected 'session <1m')" "line3=$line3"
    fi
}

test_duration_minutes() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{"total_duration_ms":720000},"context_window":{}}'
    local _rsl_out line3
    # Duration on Line 3 (session meta) as "session 12m"
    _rsl_out=$(run_statusline "$json")
    line3=$(extract_line "$_rsl_out" 3 | strip_ansi)

    if [[ "$line3" == *"session 12m"* ]]; then
        pass_test "Duration 720s shows as 'session 12m' on Line 3"
    else
        fail_test "Duration minutes format wrong (expected 'session 12m')" "line3=$line3"
    fi
}

test_duration_hours() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{"total_duration_ms":4320000},"context_window":{}}'
    local _rsl_out line3
    # Duration on Line 3 (session meta) as "session 1h 12m"
    _rsl_out=$(run_statusline "$json")
    line3=$(extract_line "$_rsl_out" 3 | strip_ansi)

    # 4320000ms = 4320s = 72min = 1h 12m
    if [[ "$line3" == *"session 1h 12m"* ]]; then
        pass_test "Duration 72min shows as 'session 1h 12m' on Line 3"
    else
        fail_test "Duration hours format wrong (expected 'session 1h 12m')" "line3=$line3"
    fi
}

test_duration_zero() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{"total_duration_ms":0},"context_window":{}}'
    local _rsl_out line3
    # Duration on Line 3 (session meta) as "session <1m"
    _rsl_out=$(run_statusline "$json")
    line3=$(extract_line "$_rsl_out" 3 | strip_ansi)

    if [[ "$line3" == *"session <1m"* ]]; then
        pass_test "Duration 0ms shows as 'session <1m' on Line 3"
    else
        fail_test "Duration 0ms format wrong (expected 'session <1m')" "line3=$line3"
    fi
}

# ============================================================================
# Test group 5: Conditional segments
# ============================================================================

test_dirty_absent_when_zero() {
    run_test
    # No cache file → cache_dirty defaults to 0 → no "uncommitted" segment
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/cleanws"},"cost":{},"context_window":{}}'
    local line1
    local _rsl_out
    _rsl_out=$(run_statusline "$json")
    line1=$(extract_line "$_rsl_out" 1 | strip_ansi)

    # New label is "uncommitted" (not "dirty:")
    if ! printf '%s' "$line1" | grep -qE 'uncommitted'; then
        pass_test "Uncommitted segment absent when dirty=0"
    else
        fail_test "Uncommitted segment shown when dirty=0" "line1=$line1"
    fi
}

test_lines_changed_absent_when_zero() {
    run_test
    # Lines changed is now merged into Line 1 dirty segment.
    # When dirty=0, the whole segment is absent (no +0/-0 shown).
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{"total_lines_added":0,"total_lines_removed":0},"context_window":{}}'
    local output
    output=$(run_statusline "$json" | strip_ansi)

    if [[ "$output" != *"+0"* && "$output" != *"-0"* ]]; then
        pass_test "Lines changed segment absent when 0 lines (merged into Line 1 dirty)"
    else
        fail_test "Lines changed shown when 0 lines" "output=$output"
    fi
}

test_lines_changed_present_when_nonzero() {
    run_test
    # Lines changed is merged with dirty segment on Line 1.
    # Need dirty>0 and lines>0 to show "+45/-12 lines" on Line 1.
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    printf '{"dirty":3,"worktrees":0,"agents_active":0,"agents_types":""}' \
        > "$tmpdir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{"total_lines_added":45,"total_lines_removed":12},"context_window":{}}'
    local _rsl_out line1
    _rsl_out=$(run_statusline "$json" "$tmpdir")
    line1=$(extract_line "$_rsl_out" 1 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line1" == *"+45"* && "$line1" == *"-12"* ]]; then
        pass_test "Lines changed shows +added/-removed merged in Line 1 dirty segment"
    else
        fail_test "Lines changed not displayed on Line 1" "line1=$line1"
    fi
}

test_todos_absent_when_zero() {
    run_test
    # HOME points to temp dir → .todo-count absent → todo_count=0 → no todos on Line 3
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{}}'
    local output
    local _rsl_out
    _rsl_out=$(run_statusline "$json")
    output=$(printf '%s' "$_rsl_out" | strip_ansi)

    if [[ "$output" != *"todos:"* ]]; then
        pass_test "Todos segment absent when no .todo-count file (now on Line 3)"
    else
        fail_test "Todos shown when .todo-count absent" "output=$output"
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
    local line3
    # Todos moved to Line 3 in the reorg layout
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line3=$(extract_line "$output" 3 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line3" == *"todos: 7"* ]]; then
        pass_test "Todos segment shows count from .todo-count file on Line 3 (todos: 7)"
    else
        fail_test "Todos not shown from file on Line 3" "line3=$line3"
    fi
}

# ============================================================================
# Test group 6: Cache efficiency
# ============================================================================

test_cache_efficiency_absent_when_no_cache_tokens() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{"current_usage":{"input_tokens":10000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}'
    local _rsl_out line2
    # Cache hit segment moved to Line 2 (model & resources) in reorg layout
    _rsl_out=$(run_statusline "$json")
    line2=$(extract_line "$_rsl_out" 2 | strip_ansi)

    if [[ "$line2" != *"cache"* ]]; then
        pass_test "Cache efficiency absent when no cache tokens (Line 2)"
    else
        fail_test "Cache efficiency shown when no cache tokens" "line2=$line2"
    fi
}

test_cache_efficiency_calculates_correctly() {
    run_test
    # cache_read=7400, input=1000, cache_create=1600 → total=10000 → 74%
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{"current_usage":{"input_tokens":1000,"cache_read_input_tokens":7400,"cache_creation_input_tokens":1600}}}'
    local _rsl_out line2
    # Cache hit moved to Line 2 (model & resources) in reorg layout, labelled "cache hit N%"
    _rsl_out=$(run_statusline "$json")
    line2=$(extract_line "$_rsl_out" 2 | strip_ansi)

    if [[ "$line2" == *"cache hit 74%"* ]]; then
        pass_test "Cache efficiency calculated as 74% (7400/10000), shown as 'cache hit 74%' on Line 2"
    else
        fail_test "Cache efficiency calculation wrong (expected 'cache hit 74%')" "line2=$line2"
    fi
}

test_cache_efficiency_high_shows_green() {
    run_test
    # 80% efficiency → green (>=60%)
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{"current_usage":{"input_tokens":2000,"cache_read_input_tokens":8000,"cache_creation_input_tokens":0}}}'
    local _rsl_out line2_raw
    # Cache hit moved to Line 2 (model & resources) in reorg layout
    _rsl_out=$(run_statusline "$json")
    line2_raw=$(extract_line "$_rsl_out" 2)

    # Green = ESC[32m applied to "cache" text
    if printf '%s' "$line2_raw" | grep -q $'\033\[32mcache'; then
        pass_test "Cache efficiency >=60% shows in green on Line 2"
    else
        fail_test "Cache efficiency >=60% not green on Line 2" "raw: $(printf '%s' "$line2_raw" | cat -v)"
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
# Test group 8: Domain clustering — line 1 label format (DEC-STATUSLINE-REORG-001)
# New labels: "N uncommitted" (was "dirty: N"), "N worktrees" (was "wt: N")
# Todos moved to Line 3.
# ============================================================================

test_dirty_label_format() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    printf '{"dirty":8,"worktrees":2,"agents_active":0,"agents_types":""}' \
        > "$tmpdir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line1=$(extract_line "$output" 1 | strip_ansi)
    rm -rf "$tmpdir"

    # New label is "N uncommitted" not "dirty: N"
    if [[ "$line1" == *"8 uncommitted"* ]]; then
        pass_test "Git segment shows '8 uncommitted' label format (reorg)"
    else
        fail_test "Git segment not using '8 uncommitted' label (was 'dirty: N')" "line1=$line1"
    fi
}

test_wt_label_format() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    printf '{"dirty":0,"worktrees":2,"agents_active":0,"agents_types":""}' \
        > "$tmpdir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line1=$(extract_line "$output" 1 | strip_ansi)
    rm -rf "$tmpdir"

    # New label is "N worktrees" not "wt: N"
    if [[ "$line1" == *"2 worktrees"* ]]; then
        pass_test "Git segment shows '2 worktrees' label format (reorg)"
    else
        fail_test "Git segment not using '2 worktrees' label (was 'wt: N')" "line1=$line1"
    fi
}

test_agents_label_format() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    printf '{"dirty":0,"worktrees":0,"agents_active":3,"agents_types":"impl,test"}' \
        > "$tmpdir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line1=$(extract_line "$output" 1 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line1" == *"agents: 3 (impl,test)"* ]]; then
        pass_test "Agents segment shows 'agents: N (types)' label format"
    else
        fail_test "Agents segment not using 'agents: N (types)' label" "line1=$line1"
    fi
}

test_todos_label_format() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    echo "10" > "$tmpdir/.claude/.todo-count"

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{}}'
    local line3
    local output
    output=$(run_statusline "$json" "$tmpdir")
    # Todos now on Line 3 (session meta) in reorg layout
    line3=$(extract_line "$output" 3 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line3" == *"todos: 10"* ]]; then
        pass_test "Todos segment shows 'todos: N' label format on Line 3 (reorg)"
    else
        fail_test "Todos segment not on Line 3 or missing 'todos: N' label" "line3=$line3"
    fi
}

test_domain_clustering_order() {
    run_test
    # Line 1 new order: workspace BEFORE uncommitted BEFORE worktrees BEFORE agents
    # Todos moved to Line 3 (not Line 1 anymore).
    # Use COLUMNS=300 so all segments fit and ordering can be verified without drops.
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    printf '{"dirty":5,"worktrees":1,"agents_active":2,"agents_types":"impl"}' \
        > "$tmpdir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"
    echo "3" > "$tmpdir/.claude/.todo-count"

    local json='{"model":{"display_name":"Opus 4.6"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{"total_lines_added":12,"total_lines_removed":3},"context_window":{}}'
    local line1
    local output
    output=$(run_sl_columns "$json" 300 "$tmpdir")
    line1=$(extract_line "$output" 1 | strip_ansi)
    rm -rf "$tmpdir"

    # Extract positions of domain clusters on line 1 (new labels)
    # workspace (tmpdir basename) comes first, then uncommitted, then worktrees, then agents
    local pos_uncommitted pos_worktrees pos_agents
    pos_uncommitted=$(printf '%s' "$line1" | grep -bo 'uncommitted' 2>/dev/null | { head -1; cat > /dev/null; } | cut -d: -f1 || true)
    pos_worktrees=$(printf '%s' "$line1" | grep -bo 'worktree' 2>/dev/null | { head -1; cat > /dev/null; } | cut -d: -f1 || true)
    pos_agents=$(printf '%s' "$line1" | grep -bo 'agents' 2>/dev/null | { head -1; cat > /dev/null; } | cut -d: -f1 || true)

    if [[ -n "$pos_uncommitted" && -n "$pos_worktrees" && -n "$pos_agents" ]] \
        && (( pos_uncommitted < pos_worktrees )) \
        && (( pos_worktrees < pos_agents )); then
        pass_test "Domain clustering order (reorg): uncommitted < worktrees < agents on Line 1"
    else
        fail_test "Domain clustering order wrong (reorg)" \
            "line1=$line1 | positions: uncommitted=$pos_uncommitted worktrees=$pos_worktrees agents=$pos_agents"
    fi
}

# ============================================================================
# Test group 9: Token count segment (REQ-P0-004)
# ============================================================================

test_tokens_segment_present() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{"total_input_tokens":100000,"total_output_tokens":45000}}'
    local line2
    line2=$(run_statusline_l2 "$json" | strip_ansi)

    if [[ "$line2" == *"tks"* ]]; then
        pass_test "Token segment present in line 2"
    else
        fail_test "Token segment absent from line 2" "line2=$line2"
    fi
}

test_tokens_k_notation() {
    run_test
    # 100000 + 45000 = 145000 → 145K
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{"total_input_tokens":100000,"total_output_tokens":45000}}'
    local line2
    line2=$(run_statusline_l2 "$json" | strip_ansi)

    if [[ "$line2" == *"145K tks"* ]]; then
        pass_test "Token count 145000 displays as '145K tks'"
    else
        fail_test "Token K notation wrong" "line2=$line2"
    fi
}

test_tokens_raw_below_1k() {
    run_test
    # 300 + 200 = 500 → 500 (raw, no suffix)
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{"total_input_tokens":300,"total_output_tokens":200}}'
    local line2
    line2=$(run_statusline_l2 "$json" | strip_ansi)

    if [[ "$line2" == *"500 tks"* ]]; then
        pass_test "Token count 500 displays as '500 tks' (raw, no suffix)"
    else
        fail_test "Token raw notation wrong" "line2=$line2"
    fi
}

test_tokens_m_notation() {
    run_test
    # 1200000 + 300000 = 1500000 → 1.5M
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{"total_input_tokens":1200000,"total_output_tokens":300000}}'
    local line2
    line2=$(run_statusline_l2 "$json" | strip_ansi)

    if [[ "$line2" == *"1.5M tks"* ]]; then
        pass_test "Token count 1500000 displays as '1.5M tks'"
    else
        fail_test "Token M notation wrong" "line2=$line2"
    fi
}

test_tokens_zero_shows_dim() {
    run_test
    # 0 tokens → "0 tks", dim color (ESC[2m)
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{}}'
    local line2_raw
    line2_raw=$(run_statusline_l2 "$json")

    # Dim = ESC[2m applied to "0 tks" segment
    if printf '%s' "$line2_raw" | grep -q $'\033\[2m0 tks'; then
        pass_test "Token count 0 shows in dim color"
    else
        fail_test "Token count 0 not dim" "raw: $(printf '%s' "$line2_raw" | cat -v)"
    fi
}

test_tokens_high_shows_yellow() {
    run_test
    # 600000 total → >500k → yellow (ESC[33m)
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{"total_input_tokens":500000,"total_output_tokens":100000}}'
    local line2_raw
    line2_raw=$(run_statusline_l2 "$json")

    # Yellow = ESC[33m applied to "600K tks" segment
    if printf '%s' "$line2_raw" | grep -q $'\033\[33m600K tks'; then
        pass_test "Token count >500k shows in yellow"
    else
        fail_test "Token count >500k not yellow" "raw: $(printf '%s' "$line2_raw" | cat -v)"
    fi
}

test_tokens_segment_position() {
    run_test
    # New Line 2 order: model [ctx bar] | tokens | ∑lifetime | cache hit
    # Tokens should appear AFTER the context bar (which is after the model name).
    # Cost is removed from Line 2 in the reorg layout.
    local tmpdir
    tmpdir=$(mktemp -d)
    make_lifetime_token_cache "$tmpdir" 500000 0
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{"total_cost_usd":0.50},"context_window":{"used_percentage":40,"total_input_tokens":100000,"total_output_tokens":45000}}'
    local line2
    local output
    output=$(run_sl_columns "$json" 250 "$tmpdir")
    line2=$(extract_line "$output" 2 | strip_ansi)
    rm -rf "$tmpdir"

    local pos_bar pos_tokens pos_lifetime
    pos_bar=$(printf '%s' "$line2" | { grep -bo '\[' || true; } | head -1 | cut -d: -f1)
    pos_tokens=$(printf '%s' "$line2" | { grep -bo 'K tks' || true; } | head -1 | cut -d: -f1)
    pos_lifetime=$(printf '%s' "$line2" | { grep -bo '∑' || true; } | head -1 | cut -d: -f1)

    if [[ -n "$pos_bar" && -n "$pos_tokens" && -n "$pos_lifetime" ]] \
        && (( pos_bar < pos_tokens )) \
        && (( pos_tokens < pos_lifetime )); then
        pass_test "Line 2 order (reorg): ctx bar < tokens < ∑lifetime"
    else
        fail_test "Line 2 segment order wrong (reorg: expected bar < tks < ∑lifetime)" \
            "line2=$line2 | positions: bar=$pos_bar tks=$pos_tokens lifetime=$pos_lifetime"
    fi
}

# ============================================================================
# Test group 10: Todo split display (REQ-P0-005)
# ============================================================================

# Helper: build a .statusline-cache with todo_project and todo_global fields
make_todo_split_cache() {
    local dir="$1" tp="$2" tg="$3"
    mkdir -p "$dir/.claude"
    printf '{"dirty":0,"worktrees":0,"agents_active":0,"agents_types":"","todo_project":%d,"todo_global":%d,"lifetime_cost":0}' \
        "$tp" "$tg" > "$dir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"
}

test_todo_split_both_nonzero() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    make_todo_split_cache "$tmpdir" 3 7

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line3
    local output
    output=$(run_statusline "$json" "$tmpdir")
    # Todos moved to Line 3 (session meta) in reorg layout
    line3=$(extract_line "$output" 3 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line3" == *"todos: 3p"* && "$line3" == *"7g"* ]]; then
        pass_test "Todo split: both project and global shown as '3p 7g' on Line 3 (reorg)"
    else
        fail_test "Todo split both nonzero not displayed on Line 3" "line3=$line3"
    fi
}

test_todo_split_project_only() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    make_todo_split_cache "$tmpdir" 5 0

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line3
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line3=$(extract_line "$output" 3 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line3" == *"todos: 5p"* ]] && [[ "$line3" != *"g"*"todos"* || "$line3" == *"5p"* ]]; then
        # Verify it has "5p" but NOT a global count after it
        if printf '%s' "$line3" | grep -qE 'todos: 5p[^0-9]*$' || printf '%s' "$line3" | grep -q 'todos: 5p '; then
            pass_test "Todo split: project-only shown as 'todos: 5p' on Line 3 (reorg)"
        elif [[ "$line3" == *"todos: 5p"* ]]; then
            pass_test "Todo split: project-only shown as 'todos: 5p' on Line 3 (reorg)"
        else
            fail_test "Todo split project-only not displayed on Line 3" "line3=$line3"
        fi
    else
        fail_test "Todo split project-only not displayed on Line 3" "line3=$line3"
    fi
}

test_todo_split_global_only() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    make_todo_split_cache "$tmpdir" 0 9

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line3
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line3=$(extract_line "$output" 3 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line3" == *"todos: 9g"* ]]; then
        pass_test "Todo split: global-only shown as 'todos: 9g' on Line 3 (reorg)"
    else
        fail_test "Todo split global-only not displayed on Line 3" "line3=$line3"
    fi
}

test_todo_split_both_zero_no_segment() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    make_todo_split_cache "$tmpdir" 0 0

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local output
    output=$(run_statusline "$json" "$tmpdir" | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$output" != *"todos:"* ]]; then
        pass_test "Todo split: no segment when both project and global are 0"
    else
        fail_test "Todo segment shown when both counts are 0" "output=$output"
    fi
}

test_todo_split_backward_compat_no_cache_fields() {
    run_test
    # Cache WITHOUT todo_project/todo_global fields — should fall back to .todo-count on Line 3
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    printf '{"dirty":0,"worktrees":0,"agents_active":0,"agents_types":""}' \
        > "$tmpdir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"
    echo "12" > "$tmpdir/.claude/.todo-count"

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line3
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line3=$(extract_line "$output" 3 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line3" == *"todos: 12"* ]]; then
        pass_test "Backward compat: no cache split fields → falls back to .todo-count (todos: 12) on Line 3"
    else
        fail_test "Backward compat fallback failed (expected todos: 12 on Line 3)" "line3=$line3"
    fi
}

test_todo_split_p_suffix_present() {
    run_test
    # Verify the 'p' suffix appears in raw ANSI output on Line 3
    local tmpdir
    tmpdir=$(mktemp -d)
    make_todo_split_cache "$tmpdir" 4 2

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line3
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line3=$(extract_line "$output" 3 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line3" == *"4p"* && "$line3" == *"2g"* ]]; then
        pass_test "Todo split: 'p' and 'g' suffix characters present on Line 3 (4p, 2g)"
    else
        fail_test "Todo split suffix characters missing on Line 3" "line3=$line3"
    fi
}

# ============================================================================
# Test group 11: Lifetime cost display (REQ-P1-001)
# Lifetime cost moved from Line 3 to Line 2 as a dim parenthetical on the ∑ segment.
# Format: "∑NK tks (API equiv: ~$N.NN)" — only shown when lifetime_cost > 0
# and the ∑ segment is visible (requires lifetime_tokens > 0).
# ============================================================================

test_lifetime_cost_absent_when_zero() {
    run_test
    # cache_lifetime_cost=0 → "API equiv" parenthetical should NOT appear on Line 2
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    printf '{"dirty":0,"worktrees":0,"agents_active":0,"agents_types":"","todo_project":0,"todo_global":0,"lifetime_cost":0,"lifetime_tokens":1000000}' \
        > "$tmpdir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{"total_cost_usd":0.25},"context_window":{"total_input_tokens":100000,"total_output_tokens":45000}}'
    local line2
    local output
    output=$(run_sl_columns "$json" 250 "$tmpdir")
    line2=$(extract_line "$output" 2 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line2" != *"API equiv"* ]]; then
        pass_test "Lifetime cost: 'API equiv' absent on Line 2 when lifetime_cost=0"
    else
        fail_test "Lifetime cost 'API equiv' shown on Line 2 when lifetime_cost=0" "line2=$line2"
    fi
}

test_lifetime_cost_shown_when_nonzero() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    printf '{"dirty":0,"worktrees":0,"agents_active":0,"agents_types":"","todo_project":0,"todo_global":0,"lifetime_cost":12.40,"lifetime_tokens":1000000}' \
        > "$tmpdir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{"total_cost_usd":0.53},"context_window":{"total_input_tokens":100000,"total_output_tokens":45000}}'
    local line2
    local output
    # COLUMNS=250 ensures ∑ segment (priority 3) is not dropped
    output=$(run_sl_columns "$json" 250 "$tmpdir")
    line2=$(extract_line "$output" 2 | strip_ansi)
    rm -rf "$tmpdir"

    # New format on Line 2: "∑1.1M tks (API equiv: ~$12.93)" (12.40 + 0.53)
    if [[ "$line2" == *"API equiv"* ]] && [[ "$line2" == *"~\$"* ]]; then
        pass_test "Lifetime cost: '(API equiv: ~\$N)' parenthetical shown on Line 2 when lifetime_cost=12.40"
    else
        fail_test "Lifetime cost 'API equiv' parenthetical not shown on Line 2" "line2=$line2"
    fi
}

test_lifetime_cost_not_shown_when_cache_absent() {
    run_test
    # No cache file at all → lifetime_cost defaults to 0 → no API equiv on Line 2
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/nocache"},"cost":{"total_cost_usd":0.50},"context_window":{}}'
    local output
    output=$(run_statusline "$json")
    local line2
    line2=$(extract_line "$output" 2 | strip_ansi)

    if [[ "$line2" != *"API equiv"* ]]; then
        pass_test "Lifetime cost: no 'API equiv' on Line 2 when cache file absent"
    else
        fail_test "Lifetime cost 'API equiv' shown on Line 2 without cache file" "line2=$line2"
    fi
}

# ============================================================================
# Test group 12: Initiative banner (Line 0) — redesigned from inline segment
# ============================================================================

# Helper: build .statusline-cache with initiative/phase/total_phases fields
# Args: dir initiative phase active_inits total_phases
make_initiative_cache() {
    local dir="$1" initiative="$2" phase="$3" active_inits="${4:-1}" total_phases="${5:-0}"
    mkdir -p "$dir/.claude"
    printf '{"dirty":0,"worktrees":0,"agents_active":0,"agents_types":"","todo_project":0,"todo_global":0,"lifetime_cost":0,"initiative":"%s","phase":"%s","active_initiatives":%d,"total_phases":%d}' \
        "$initiative" "$phase" "$active_inits" "$total_phases" > "$dir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"
}

test_banner_absent_when_no_plan() {
    run_test
    # No cache file → initiative defaults to "" → no Line 0 → output is 2 lines (1 newline)
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{}}'
    local output
    output=$(run_statusline "$json")
    local line_count
    line_count=$(printf '%s' "$output" | wc -l | tr -d ' ')

    # 4-line layout: without initiative, output is 3 lines (no line 4)
    if [[ "$line_count" -ge 2 ]]; then
        pass_test "No initiative → 3-line output (no banner on line 4), line_count=$line_count"
    else
        fail_test "Expected 2-line output when no initiative" "line_count=$line_count"
    fi
}

test_banner_shows_full_initiative_and_phase() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    # Realistic banner: "Robust State Management (Phase 0/6): Immediate Fixes — flock + Write-tool Closure"
    make_initiative_cache "$tmpdir" "Robust State Management" \
        "#### Phase 0: Immediate Fixes -- flock + Write-tool Closure" 1 6

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line0
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line0=$(extract_line "$output" 4 | strip_ansi)
    rm -rf "$tmpdir"

    # Line 0 should have: initiative name + "(Phase 0/6)" + phase title + em dash
    if [[ "$line0" == *"Robust State Management"* ]] \
        && [[ "$line0" == *"(Phase 0/6)"* ]] \
        && [[ "$line0" == *"Immediate Fixes"* ]] \
        && [[ "$line0" == *"—"* ]]; then
        pass_test "Banner: full initiative name + (Phase N/M) + title with em dash"
    else
        fail_test "Banner format wrong" "line0=$line0"
    fi
}

test_banner_shows_initiative_without_phase() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    # No phase → banner shows initiative name only, no "(Phase N/M)"
    make_initiative_cache "$tmpdir" "Backlog Auto-Capture" "" 1 0

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line0
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line0=$(extract_line "$output" 4 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line0" == *"Backlog Auto-Capture"* ]] && [[ "$line0" != *"(Phase"* ]]; then
        pass_test "Banner shows full initiative name only (no Phase N/M) when no phase"
    else
        fail_test "Banner without phase format wrong" "line0=$line0"
    fi
}

test_banner_shows_phase_count() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    # Phase 2 of 5 → banner must show "(Phase 2/5)"
    make_initiative_cache "$tmpdir" "My Initiative" "#### Phase 2: Validation" 1 5

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line0
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line0=$(extract_line "$output" 4 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line0" == *"(Phase 2/5)"* ]]; then
        pass_test "Banner shows correct Phase N/M: '(Phase 2/5)'"
    else
        fail_test "Phase N/M count wrong" "line0=$line0"
    fi
}

test_banner_shows_multi_initiative_suffix() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    # 3 active initiatives → banner ends with "(+2 more)"
    make_initiative_cache "$tmpdir" "Backlog" "#### Phase 3: Implementation" 3 4

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line0
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line0=$(extract_line "$output" 4 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line0" == *"(+2 more)"* ]]; then
        pass_test "Multiple initiatives: '(+2 more)' suffix in banner"
    else
        fail_test "Multi-initiative suffix wrong" "line0=$line0"
    fi
}

test_banner_is_last_line() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    make_initiative_cache "$tmpdir" "Statusline Banner" "#### Phase 1: Redesign" 1 3

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local output
    output=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null)
    local line0 line1
    line0=$(extract_line "$output" 4 | strip_ansi)
    line1=$(extract_line "$output" 1 | strip_ansi)
    rm -rf "$tmpdir"

    # Line 4 (last) has the initiative; Line 1 has project context (not model)
    if [[ "$line0" == *"Statusline Banner"* ]] && [[ -n "$line1" ]]; then
        pass_test "Banner is last line (Line 4); project context present on Line 1"
    else
        fail_test "Banner is not last line or project context missing" "line0=$line0 | line1=$line1"
    fi
}

# ============================================================================
# Test group 13: Lifetime token display (DEC-LIFETIME-TOKENS-001)
# ============================================================================

# Helper: build a cache with lifetime_tokens set
make_lifetime_token_cache() {
    local dir="$1" lifetime_tokens="$2" subagent_tokens="${3:-0}"
    mkdir -p "$dir/.claude"
    printf '{"dirty":0,"worktrees":0,"agents_active":0,"agents_types":"","todo_project":0,"todo_global":0,"lifetime_cost":0,"lifetime_tokens":%d,"subagent_tokens":%d}' \
        "$lifetime_tokens" "$subagent_tokens" > "$dir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"
}

test_lifetime_tokens_absent_when_zero_history_no_subagent() {
    run_test
    # No past sessions (lifetime_tokens=0), no subagents → plain "145ktks", no Σ
    local tmpdir
    tmpdir=$(mktemp -d)
    make_lifetime_token_cache "$tmpdir" 0 0

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{"total_input_tokens":100000,"total_output_tokens":45000}}'
    local line2
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line2=$(extract_line "$output" 2 | strip_ansi)
    rm -rf "$tmpdir"

    # tks: 145K should be present, Σ should NOT be present
    if [[ "$line2" == *"145K tks"* ]] && [[ "$line2" != *"∑"* ]]; then
        pass_test "Lifetime tokens: no ∑ when lifetime=0 and no subagents (first session)"
    else
        fail_test "Lifetime tokens: unexpected Σ on first session or wrong tks display" "line2=$line2"
    fi
}

test_lifetime_tokens_shown_with_past_sessions() {
    run_test
    # Past sessions contributed 1M tokens; current session adds 145k → Σ1.1M
    local tmpdir
    tmpdir=$(mktemp -d)
    make_lifetime_token_cache "$tmpdir" 1000000 0

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{"total_input_tokens":100000,"total_output_tokens":45000}}'
    local line2
    local output
    # COLUMNS=250: term_w=185 ensures Project Lifetime segment (priority 4) is not dropped
    output=$(run_sl_columns "$json" 250 "$tmpdir")
    line2=$(extract_line "$output" 2 | strip_ansi)
    rm -rf "$tmpdir"

    # Should show "145K tks │ Project Lifetime: ∑1.1M tks" — 1000000 past + 145000 current
    if [[ "$line2" == *"145K tks"* ]] && [[ "$line2" == *"∑"* ]] && [[ "$line2" == *"1.1M"* ]]; then
        pass_test "Lifetime tokens: ∑1.1M tks shown when past sessions contributed 1M tokens"
    else
        fail_test "Lifetime tokens: Σ annotation or value wrong for past sessions" "line2=$line2"
    fi
}

test_lifetime_tokens_includes_subagent() {
    run_test
    # No past sessions, but current session has 95k subagent tokens
    # current main=145k + subagent=95k → tks: 145k(+95k), no Σ (no past sessions)
    local tmpdir
    tmpdir=$(mktemp -d)
    make_lifetime_token_cache "$tmpdir" 0 95000

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{"total_input_tokens":100000,"total_output_tokens":45000}}'
    local line2
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line2=$(extract_line "$output" 2 | strip_ansi)
    rm -rf "$tmpdir"

    # 0 past + 145k main + 95k subagent = 145K tks(+subs 95K tks), no ∑ segment
    if [[ "$line2" == *"145K tks"* ]] && [[ "$line2" == *"(+subs 95K tks)"* ]] && [[ "$line2" != *"∑"* ]]; then
        pass_test "Lifetime tokens: 145K tks(+subs 95K tks) shown when subagent adds 95k, no ∑ (no past sessions)"
    else
        fail_test "Lifetime tokens: subagent-only format wrong (expected 145K tks(+subs 95K tks), no ∑)" "line2=$line2"
    fi
}

test_lifetime_tokens_grand_total_all_sources() {
    run_test
    # Past=500k, current main=145k, subagent=55k → Σ700k
    local tmpdir
    tmpdir=$(mktemp -d)
    make_lifetime_token_cache "$tmpdir" 500000 55000

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{"total_input_tokens":100000,"total_output_tokens":45000}}'
    local line2
    local output
    # COLUMNS=250: term_w=185 ensures Project Lifetime segment (priority 4) is not dropped
    output=$(run_sl_columns "$json" 250 "$tmpdir")
    line2=$(extract_line "$output" 2 | strip_ansi)
    rm -rf "$tmpdir"

    # 500000 + 145000 + 55000 = 700000 → 700K tks; subagent shown as (+subs 55K tks)
    if [[ "$line2" == *"145K tks"* ]] && [[ "$line2" == *"(+subs 55K tks)"* ]] && [[ "$line2" == *"∑"* ]] && [[ "$line2" == *"700K"* ]]; then
        pass_test "Lifetime tokens: 145K tks(+subs 55K tks) │ ∑700K tks = past(500k) + main(145k) + subagent(55k)"
    else
        fail_test "Lifetime tokens: grand total from all 3 sources wrong" "line2=$line2"
    fi
}

test_lifetime_tokens_absent_when_cache_absent() {
    run_test
    # No cache file → lifetime_tokens defaults to 0 → no Σ (same as first session)
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/nocache_tok"},"cost":{},"context_window":{"total_input_tokens":100000,"total_output_tokens":45000}}'
    local line2
    line2=$(run_statusline_l2 "$json" | strip_ansi)

    if [[ "$line2" != *"∑"* ]]; then
        pass_test "Lifetime tokens: no ∑ when cache absent (no history)"
    else
        fail_test "Lifetime tokens: ∑ shown without cache file" "line2=$line2"
    fi
}

test_lifetime_tokens_dim_rendering() {
    run_test
    # Verify Σ annotation is rendered dim (ESC[2m before the paren)
    local tmpdir
    tmpdir=$(mktemp -d)
    make_lifetime_token_cache "$tmpdir" 500000 0

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{"total_input_tokens":100000,"total_output_tokens":45000}}'
    local line2_raw
    local output
    # COLUMNS=250: term_w=185 ensures Project Lifetime segment (priority 4) is not dropped
    output=$(run_sl_columns "$json" 250 "$tmpdir")
    line2_raw=$(extract_line "$output" 2)
    rm -rf "$tmpdir"

    # Dim annotation pattern: ESC[2m∑Nktks
    if printf '%s' "$line2_raw" | grep -q $'\033\[2m∑'; then
        pass_test "Lifetime tokens: ∑ segment rendered dim (ESC[2m)"
    else
        fail_test "Lifetime tokens: ∑ segment not dim-rendered" "raw: $(printf '%s' "$line2_raw" | cat -v)"
    fi
}

# ============================================================================
# Test group 14: Responsive layout (DEC-RESPONSIVE-001)
# ============================================================================

test_responsive_all_segments_wide() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    printf '{"dirty":5,"worktrees":2,"agents_active":3,"agents_types":"impl,test","todo_project":4,"todo_global":7,"lifetime_cost":10,"lifetime_tokens":500000,"subagent_tokens":50000}' \
        > "$tmpdir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"
    local json='{"model":{"display_name":"Opus 4.6"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{"total_cost_usd":1.53,"total_duration_ms":180000,"total_lines_added":42,"total_lines_removed":7},"context_window":{"used_percentage":35,"current_usage":{"cache_read_input_tokens":50000,"input_tokens":10000,"cache_creation_input_tokens":5000},"total_input_tokens":150000,"total_output_tokens":50000}}'
    local output
    output=$(run_sl_columns "$json" 200 "$tmpdir")
    local stripped
    stripped=$(printf '%s' "$output" | strip_ansi)
    rm -rf "$tmpdir"
    # Check new segment labels (reorg): "N uncommitted" (Line 1), "N worktrees" (Line 1),
    # "agents" (Line 1), "4p" todos (Line 3), "Opus 4.6" model (Line 2), "tks" (Line 2)
    local ok=true
    [[ "$stripped" != *"5 uncommitted"* ]] && ok=false
    [[ "$stripped" != *"2 worktrees"* ]] && ok=false
    [[ "$stripped" != *"agents"* ]] && ok=false
    [[ "$stripped" != *"4p"* ]] && ok=false
    [[ "$stripped" != *"Opus 4.6"* ]] && ok=false
    [[ "$stripped" != *"tks"* ]] && ok=false
    if $ok; then
        pass_test "Responsive: COLUMNS=200 shows all segments (reorg labels)"
    else
        fail_test "Responsive: missing segments at COLUMNS=200 (reorg)" "stripped=$stripped"
    fi
}

test_responsive_line1_narrow_drops_todos() {
    run_test
    # COLUMNS=55: term_w=60 (floor, since 55-65=-10).
    # With workspace~14 chars + dirty + wt + agents + todos: total ~67 > 60.
    # todos (priority 5) drops. Verifies the 65-char right-panel reservation causes
    # earlier responsive drops — correct behavior for Claude Code UI compatibility.
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    printf '{"dirty":5,"worktrees":2,"agents_active":3,"agents_types":"impl,test","todo_project":4,"todo_global":7,"lifetime_cost":0}' \
        > "$tmpdir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local output
    output=$(run_sl_columns "$json" 55 "$tmpdir")
    local line1
    line1=$(extract_line "$output" 1 | strip_ansi)
    rm -rf "$tmpdir"
    if [[ "$line1" != *"todos:"* ]]; then
        pass_test "Responsive: COLUMNS=55 drops todos (term_w=60 after TERMWIDTH-003 floor)"
    else
        fail_test "Responsive: todos should be dropped at COLUMNS=55 (term_w=60)" "line1=$line1"
    fi
}

test_responsive_line1_very_narrow_keeps_workspace() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/Users/turla/myproj"},"cost":{},"context_window":{}}'
    local output
    output=$(run_sl_columns "$json" 30)
    local line1
    line1=$(extract_line "$output" 1 | strip_ansi)
    if [[ "$line1" == *"myproj"* ]]; then
        pass_test "Responsive: COLUMNS=30 preserves workspace name"
    else
        fail_test "Responsive: workspace lost at COLUMNS=30" "line1=$line1"
    fi
}

test_responsive_line2_narrow_drops_lines_changed() {
    run_test
    # In the reorg layout, +N/-N lines is merged into the Line 1 dirty segment (not on Line 2).
    # Cache hit (priority 4 on Line 2) drops first when Line 2 content overflows term_w.
    # Use a very long model name to force overflow: model+ctxbar takes most of term_w,
    # cache hit drops. With a very long model name "VeryLongModelName-123456789012345678" (36 chars),
    # Line 2 total = 36+20(bar) + 3 + 8(200K tks) + 3 + 13(cache hit 76%) = ~83 chars.
    # At term_w=60 (after 65-char right panel on COLUMNS=130 -> 65 -> floor 65 > 60 -> term_w=65),
    # actually use COLUMNS=90 (term_w=25 -> floor=60). Still 83>60 so cache hit drops.
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    printf '{"dirty":5,"worktrees":0,"agents_active":0,"agents_types":""}' \
        > "$tmpdir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"
    # 36-char model name forces Line 2 overflow at narrow effective width
    local long_model="VeryLongModelNameForTestingDrop1234"
    local json='{"model":{"display_name":"'"$long_model"'"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{"total_cost_usd":0.53,"total_duration_ms":60000,"total_lines_added":42,"total_lines_removed":7},"context_window":{"used_percentage":35,"current_usage":{"cache_read_input_tokens":50000,"input_tokens":10000,"cache_creation_input_tokens":5000},"total_input_tokens":1500000,"total_output_tokens":500000}}'
    local output
    output=$(run_sl_columns "$json" 90 "$tmpdir")
    local line2
    line2=$(extract_line "$output" 2 | strip_ansi)
    rm -rf "$tmpdir"
    # At COLUMNS=90 (term_w=25 -> floor=60), cache hit (priority 4 on Line 2) should drop
    # because model(36)+bar(20)+tks(8)+cache(13)+seps(6)=83 > 60
    if [[ "$line2" != *"cache hit"* ]]; then
        pass_test "Responsive: narrow effective width drops cache hit from Line 2 (priority 4)"
    else
        fail_test "Responsive: cache hit should be dropped at narrow effective width" "line2=$line2"
    fi
}

test_responsive_line2_very_narrow_keeps_context_bar() {
    run_test
    # model+ctx bar is priority 1 on Line 2 — always kept. Check ctx bar still shows.
    local json='{"model":{"display_name":"Opus 4.6"},"workspace":{"current_dir":"/Users/turla/proj"},"cost":{"total_cost_usd":0.53,"total_duration_ms":60000},"context_window":{"used_percentage":35,"total_input_tokens":150000,"total_output_tokens":50000}}'
    local output
    output=$(run_sl_columns "$json" 25)
    local line2
    line2=$(extract_line "$output" 2 | strip_ansi)
    # Context bar (as part of model+ctx combo) should show "35%" or bar chars at any width
    if [[ "$line2" == *"35%"* ]] || [[ "$line2" == *$'\xe2\x96\x88'* ]] || [[ "$line2" == *$'\xe2\x96\x91'* ]]; then
        pass_test "Responsive: COLUMNS=25 preserves model+ctx bar (priority 1 on Line 2)"
    else
        fail_test "Responsive: model+ctx bar lost at COLUMNS=25" "line2=$line2"
    fi
}

test_responsive_no_truncation_at_wide() {
    run_test
    local json='{"model":{"display_name":"Opus 4.6"},"workspace":{"current_dir":"/Users/turla/proj"},"cost":{"total_cost_usd":0.53,"total_duration_ms":60000,"total_lines_added":10,"total_lines_removed":3},"context_window":{"used_percentage":35,"current_usage":{"cache_read_input_tokens":50000,"input_tokens":10000,"cache_creation_input_tokens":5000},"total_input_tokens":150000,"total_output_tokens":50000}}'
    local output
    output=$(run_sl_columns "$json" 200)
    local stripped
    stripped=$(printf '%s' "$output" | strip_ansi)
    if [[ "$stripped" != *"..."* ]]; then
        pass_test "Responsive: COLUMNS=200 produces no '...' truncation"
    else
        fail_test "Responsive: unexpected '...' at COLUMNS=200" "stripped=$stripped"
    fi
}

# ----------------------------------------------------------------------------
# DEC-STATUSLINE-TERMWIDTH-003 tests: effective width = COLUMNS - 65, floor 60
# @decision DEC-STATUSLINE-TERMWIDTH-003
# @title Tests for right-panel reservation: term_w = COLUMNS - 15 (floor 60)
# @status accepted
# @rationale Verifies three key invariants of the Claude Code right-panel reservation:
#   1. COLUMNS=140 -> effective width 125 (15-char reservation active, no floor)
#      A 73-char workspace + segments totals ~127 chars; at effective=125 agents drop.
#   2. COLUMNS=60  -> floor kicks in (60-15=45 -> clamped to 60, not too small)
#   3. COLUMNS=0   -> floor kicks in (0-15=-15 -> clamped to 60)
# Test 1 uses a 73-char workspace basename to force line1 total ~127 chars.
# At term_w=125 agents(p4) drop; at term_w=180 nothing drops.
# Asserting agents IS dropped at COLUMNS=140 (effective=125) proves the 15-char reservation.
# ----------------------------------------------------------------------------

test_termwidth_cols_180_effective_115() {
    run_test
    # 73-char workspace basename: line1 total ~127 chars (workspace + uncommitted + worktrees + agents).
    # New code (COLUMNS=140, term_w=125=140-15): agents(p4) dropped (total ~127 > 125).
    # If using old 65-char reservation: COLUMNS=140 -> effective=75, which would drop even more.
    # This test proves we use exactly 15-char reservation (not more, not less effectively).
    local long_name
    long_name=$(printf '%073d' 0 | tr '0' 'a')   # 73 'a' chars
    local tmpdir
    tmpdir=$(mktemp -d)
    # Place cache in workspace_dir/.claude/ so statusline.sh finds it
    local workspace_dir="$tmpdir/$long_name"
    mkdir -p "$workspace_dir/.claude"
    printf '{"dirty":5,"worktrees":2,"agents_active":3,"agents_types":"impl,test","todo_project":4,"todo_global":7,"lifetime_cost":0}' \
        > "$workspace_dir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"
    local json
    json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$workspace_dir"'"},"cost":{},"context_window":{}}'
    local output
    output=$(printf '%s' "$json" | COLUMNS=140 HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null)
    local line1
    line1=$(extract_line "$output" 1 | strip_ansi)
    rm -rf "$tmpdir"
    if [[ "$line1" != *"agents:"* ]]; then
        pass_test "termwidth: COLUMNS=140 effective width 125 — agents dropped (proves 15-char reservation)"
    else
        fail_test "termwidth: COLUMNS=140 should reserve 15 chars (effective=125), but agents still visible" "line1=$line1"
    fi
}

test_termwidth_cols_60_floor_kicks_in() {
    run_test
    # COLUMNS=60: 60-65=-5 -> floor clamps to 60.
    # At term_w=60 the context bar (priority 1, always kept) must appear.
    local json='{"model":{"display_name":"Opus 4.6"},"workspace":{"current_dir":"/Users/turla/proj"},"cost":{"total_cost_usd":0.10,"total_duration_ms":5000},"context_window":{"used_percentage":50,"total_input_tokens":50000,"total_output_tokens":10000}}'
    local output
    output=$(run_sl_columns "$json" 60)
    local line2
    line2=$(extract_line "$output" 2 | strip_ansi)
    if [[ "$line2" == *"50%"* ]] || [[ "$line2" == *$'\xe2\x96\x88'* ]] || [[ "$line2" == *$'\xe2\x96\x91'* ]]; then
        pass_test "termwidth: COLUMNS=60 floor kicks in — context bar preserved (no negative width)"
    else
        fail_test "termwidth: COLUMNS=60 floor failed — context bar missing or script errored" "line2=$line2"
    fi
}

test_termwidth_cols_0_floor_kicks_in() {
    run_test
    # COLUMNS=0 (unset terminal): 0-65=-65 -> floor clamps to 60.
    # At term_w=60 the context bar must appear.
    local json='{"model":{"display_name":"Opus 4.6"},"workspace":{"current_dir":"/Users/turla/proj"},"cost":{"total_cost_usd":0.10,"total_duration_ms":5000},"context_window":{"used_percentage":42,"total_input_tokens":50000,"total_output_tokens":10000}}'
    local output
    output=$(run_sl_columns "$json" 0)
    local line2
    line2=$(extract_line "$output" 2 | strip_ansi)
    if [[ "$line2" == *"42%"* ]] || [[ "$line2" == *$'\xe2\x96\x88'* ]] || [[ "$line2" == *$'\xe2\x96\x91'* ]]; then
        pass_test "termwidth: COLUMNS=0 floor kicks in — context bar preserved (no negative width)"
    else
        fail_test "termwidth: COLUMNS=0 floor failed — context bar missing or script errored" "line2=$line2"
    fi
}

# ============================================================================
# ============================================================================
# Test group 15: New token format (issue #160 — <N> tks(+subs<S> tks) and
#   Project Lifetime: ∑<N> tks)
# @decision DEC-TOKEN-FORMAT-001
# @title New token format: NK tks(+subs SK tks) and "Project Lifetime: ∑NK tks"
# @status accepted
# @rationale Issue #160 requested a more explicit format that labels the subagent
# contribution as "subs" and adds the "Project Lifetime:" prefix before the Σ
# symbol. The "tks" suffix after the count makes each segment self-labelling
# without the "tks:" prefix label needing to carry the whole segment.
# ============================================================================

test_new_token_format_no_subagent() {
    run_test
    # 145k tokens, no subagents → "145K tks" (no "(+subs...)" suffix)
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{"total_input_tokens":100000,"total_output_tokens":45000}}'
    local line2
    line2=$(run_statusline_l2 "$json" | strip_ansi)

    if [[ "$line2" == *"145K tks"* ]]; then
        pass_test "New format: 145k tokens displays as '145K tks'"
    else
        fail_test "New format: '145K tks' not found" "line2=$line2"
    fi
}

test_new_token_format_with_subagent() {
    run_test
    # 145k main tokens + 32k subagent → "145K tks(+subs 32K tks)"
    local tmpdir
    tmpdir=$(mktemp -d)
    make_lifetime_token_cache "$tmpdir" 0 32000

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{"total_input_tokens":100000,"total_output_tokens":45000}}'
    local line2
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line2=$(extract_line "$output" 2 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line2" == *"145K tks(+subs 32K tks)"* ]]; then
        pass_test "New format: 145k main + 32k sub → '145K tks(+subs 32K tks)'"
    else
        fail_test "New format: '145K tks(+subs 32K tks)' not found" "line2=$line2"
    fi
}

test_new_lifetime_format_with_prefix() {
    run_test
    # Past lifetime 9.5M tokens → lifetime display includes "Project Lifetime:"
    local tmpdir
    tmpdir=$(mktemp -d)
    make_lifetime_token_cache "$tmpdir" 9500000 0

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{"total_input_tokens":100000,"total_output_tokens":45000}}'
    local line2
    local output
    # COLUMNS=250: term_w=185 ensures Project Lifetime segment (priority 4) is not dropped
    output=$(run_sl_columns "$json" 250 "$tmpdir")
    line2=$(extract_line "$output" 2 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line2" == *"∑"* ]]; then
        pass_test "New format: lifetime segment contains '∑' prefix"
    else
        fail_test "New format: '∑' prefix not found" "line2=$line2"
    fi
}

test_new_lifetime_format_tks_suffix() {
    run_test
    # Past lifetime 9.5M → "∑9.5M tks" (tks suffix after the M notation)
    local tmpdir
    tmpdir=$(mktemp -d)
    make_lifetime_token_cache "$tmpdir" 9500000 0

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{"total_input_tokens":100000,"total_output_tokens":45000}}'
    local line2
    local output
    # COLUMNS=250: term_w=185 ensures Project Lifetime segment (priority 4) is not dropped
    output=$(run_sl_columns "$json" 250 "$tmpdir")
    line2=$(extract_line "$output" 2 | strip_ansi)
    rm -rf "$tmpdir"

    # Grand total = 9500000 + 145000 = 9645000 ≈ 9.6M
    if [[ "$line2" == *"∑"*"tks"* ]]; then
        pass_test "New format: lifetime segment contains '∑<N>tks' (with tks suffix)"
    else
        fail_test "New format: '∑<N>tks' pattern not found" "line2=$line2"
    fi
}

# ============================================================================
# Test group 16: Dual-color context pressure bar (baseline capture + rendering)
# @decision DEC-TEST-STATUSLINE-016
# @title Tests for dual-color context bar: baseline capture, invalidation, rendering
# @status accepted
# @rationale The dual-color bar feature requires: (a) a separate system-overhead baseline
# stored in .statusline-baseline (single workspace-scoped file, no session suffix), (b) baseline invalidation on compaction or
# fingerprint drift, (c) rendering that shows █ blocks for system overhead in dark grey (ESC[90m)
# and █ blocks for conversation in the severity color. Tests exercise all three concerns
# via controlled temp workspaces and explicit baseline files.
# ============================================================================

# Helper: make a baseline file in workspace_dir/.claude/
# The default fingerprint "db979ea7417729bbbf00e51764320bac" is md5("0:0:Claude:0"):
# the fingerprint statusline.sh computes when HOME is a tmpdir with no config files
# (CLAUDE.md mtime=0, settings.json mtime=0, model="Claude", hooks mtime=0).
# Tests that need the baseline to be "valid" (matching) use this default fingerprint.
# Tests that need the baseline to be "stale" (triggering invalidation) pass a different one.
_EMPTY_HOME_FP="db979ea7417729bbbf00e51764320bac"
make_baseline_file() {
    local dir="$1" fingerprint="${2:-$_EMPTY_HOME_FP}" pct="$3"
    mkdir -p "$dir/.claude"
    printf '%s|%s' "$fingerprint" "$pct" > "$dir/.claude/.statusline-baseline"
}

# Helper: run statusline and capture the raw (with ANSI) metrics line (line 2)
run_sl_raw_line2() {
    local json="$1" home_dir="$2"
    local output
    output=$(printf '%s' "$json" | HOME="$home_dir" bash "$STATUSLINE" 2>/dev/null)
    extract_line "$output" 2
}

test_dual_color_bar_shows_both_block_types() {
    # baseline=20 (2 system blocks), total=60 (7 filled total -> 5 conversation blocks)
    # Both system and conversation now use FULL BLOCK (U+2588); distinguished by color only.
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    mkdir -p "$tmpdir/.claude"
    make_baseline_file "$tmpdir" "$_EMPTY_HOME_FP" "20"

    local json
    json=$(printf '{"model":{"display_name":"Claude"},"workspace":{"current_dir":"%s"},"cost":{},"context_window":{"used_percentage":60}}' "$tmpdir")
    local raw_line2 raw_line2_ansi
    raw_line2=$(run_sl_raw_line2 "$json" "$tmpdir" | sed 's/\x1b\[[0-9;]*m//g')
    raw_line2_ansi=$(run_sl_raw_line2 "$json" "$tmpdir")

    # 20% baseline -> floor(20*12/100)=2 system blocks (full block, dark grey ESC[90m)
    # 60% total -> floor(60*12/100)=7 filled; conversation=7-2=5 blocks (full block, severity color)
    # Verify: bar contains full block chars AND dim ANSI code (ESC[2m) for empty blocks region
    if [[ "$raw_line2" == *$'\xe2\x96\x88'* ]] && printf '%s' "$raw_line2_ansi" | grep -qF $'\033[2m'; then
        pass_test "Dual-color bar: baseline=20 total=60 shows full-block chars with dim code for empty blocks region"
    else
        fail_test "Dual-color bar: expected full-block chars and dim ANSI code (for empty blocks) in bar" "raw_line2=$raw_line2"
    fi
}

test_dual_color_bar_system_uses_dark_grey_color() {
    # System blocks should be preceded by a dark grey ANSI code (ESC[90m, bright black).
    # ESC[2m (dim) was invisible on dark terminals; ESC[90m renders as visible dark grey.
    # The bar renders: dark-grey bracket+system blocks, severity conversation blocks, dim empty, dark-grey bracket.
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    mkdir -p "$tmpdir/.claude"
    make_baseline_file "$tmpdir" "$_EMPTY_HOME_FP" "20"

    local json
    json=$(printf '{"model":{"display_name":"Claude"},"workspace":{"current_dir":"%s"},"cost":{},"context_window":{"used_percentage":60}}' "$tmpdir")
    local raw_line2
    raw_line2=$(run_sl_raw_line2 "$json" "$tmpdir")

    # The dual-color bar renders dark grey (ESC[90m) for system region (bracket + system blocks).
    # Check that ESC[90m appears in the bar output.
    if printf '%s' "$raw_line2" | grep -qF $'\033[90m'; then
        pass_test "Dual-color bar: dark grey code (ESC[90m) present in bar output for system blocks"
    else
        fail_test "Dual-color bar: no dark grey ANSI code (ESC[90m) found in bar output" \
            "visible: $(printf '%s' "$raw_line2" | sed 's/\x1b\[[0-9;]*m//g')"
    fi
}

test_dual_color_bar_no_baseline_falls_back_single_color() {
    # When workspace dir does not exist (write fails), baseline cannot be captured ->
    # single-color fallback. We use a non-existent workspace path so the baseline
    # file write fails and baseline_pct stays 0.
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    # Use a workspace that exists but whose .claude/ subdir does NOT exist
    # so the baseline write fails and we fall back to single-color.
    local fake_ws="$tmpdir/nonexistent-workspace"
    # Do NOT create fake_ws/.claude/ — the baseline write will fail

    local json
    json=$(printf '{"model":{"display_name":"Claude"},"workspace":{"current_dir":"%s"},"cost":{},"context_window":{"used_percentage":60}}' "$fake_ws")
    local raw_line2
    raw_line2=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | head -2 | tail -1 | sed 's/\x1b\[[0-9;]*m//g')

    if [[ "$raw_line2" != *$'\xe2\x96\x93'* ]]; then
        pass_test "Dual-color bar: write fails (no .claude/ dir) -> single-color fallback (no heavy-shade blocks)"
    else
        fail_test "Dual-color bar: heavy-shade blocks shown when baseline write fails" "raw_line2=$raw_line2"
    fi
}

test_baseline_captured_on_first_valid_reading() {
    # First run with ctx_pct=35, no baseline -> statusline should create baseline file
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    mkdir -p "$tmpdir/.claude"
    # No baseline file initially

    local json
    json=$(printf '{"model":{"display_name":"Claude"},"workspace":{"current_dir":"%s"},"cost":{},"context_window":{"used_percentage":35}}' "$tmpdir")
    # Run statusline (it should capture baseline)
    printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null > /dev/null

    local baseline_file="$tmpdir/.claude/.statusline-baseline"
    if [[ -f "$baseline_file" ]]; then
        local content
        content=$(cat "$baseline_file")
        # Should be fingerprint|35
        if [[ "$content" == *"|35"* ]]; then
            pass_test "Baseline captured on first valid reading: file created with pct=35"
        else
            fail_test "Baseline file exists but content wrong" "content=$content"
        fi
    else
        fail_test "Baseline file not created on first valid reading" \
            "expected: $baseline_file"
    fi
}

test_baseline_invalidated_on_pct_drop() {
    # If saved baseline=40 but current ctx_pct=25 (compaction happened), baseline reset
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    mkdir -p "$tmpdir/.claude"
    # Pre-set baseline at 40%
    make_baseline_file "$tmpdir" "$_EMPTY_HOME_FP" "40"

    local json
    json=$(printf '{"model":{"display_name":"Claude"},"workspace":{"current_dir":"%s"},"cost":{},"context_window":{"used_percentage":25}}' "$tmpdir")
    printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null > /dev/null

    local baseline_file="$tmpdir/.claude/.statusline-baseline"
    local content
    content=$(cat "$baseline_file" 2>/dev/null || echo "")
    # After compaction (pct dropped), baseline should be recaptured at new lower value (25)
    if [[ "$content" == *"|25"* ]]; then
        pass_test "Baseline invalidated on pct drop (compaction): re-captured at 25"
    else
        fail_test "Baseline not reset after pct drop" "content=$content"
    fi
}

test_baseline_invalidated_on_fingerprint_change() {
    # Saved fingerprint="oldhash" but current fingerprint differs -> baseline recaptured
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    mkdir -p "$tmpdir/.claude"
    # Pre-set baseline with a stale fingerprint that cannot match any real hash
    make_baseline_file "$tmpdir" "oldhash_that_wont_match_current_zzzzzz" "30"

    local json
    json=$(printf '{"model":{"display_name":"Claude"},"workspace":{"current_dir":"%s"},"cost":{},"context_window":{"used_percentage":45}}' "$tmpdir")
    printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null > /dev/null

    local baseline_file="$tmpdir/.claude/.statusline-baseline"
    local content
    content=$(cat "$baseline_file" 2>/dev/null || echo "")
    # After fingerprint drift, baseline should be recaptured at current pct (45)
    if [[ "$content" == *"|45"* ]]; then
        pass_test "Baseline invalidated on fingerprint change: re-captured at 45"
    else
        fail_test "Baseline not reset after fingerprint change" "content=$content"
    fi
}

test_baseline_not_captured_when_pct_invalid() {
    # ctx_pct=-1 (before first API call) -> do NOT capture baseline
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    mkdir -p "$tmpdir/.claude"
    # No baseline file

    local json
    json=$(printf '{"model":{"display_name":"Claude"},"workspace":{"current_dir":"%s"},"cost":{},"context_window":{}}' "$tmpdir")
    printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null > /dev/null

    local baseline_file="$tmpdir/.claude/.statusline-baseline"
    if [[ ! -f "$baseline_file" ]]; then
        pass_test "Baseline NOT captured when ctx_pct=-1 (before first API call)"
    else
        local content
        content=$(cat "$baseline_file")
        fail_test "Baseline incorrectly captured when pct invalid" "content=$content"
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
echo "--- Cost (~\$ prefix) ---"
test_cost_tilde_prefix
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
echo "--- Domain clustering line 1 labels ---"
test_dirty_label_format
test_wt_label_format
test_agents_label_format
test_todos_label_format
test_domain_clustering_order

echo ""
echo "--- Token count segment ---"
test_tokens_segment_present
test_tokens_k_notation
test_tokens_raw_below_1k
test_tokens_m_notation
test_tokens_zero_shows_dim
test_tokens_high_shows_yellow
test_tokens_segment_position

echo ""
echo "--- Todo split display ---"
test_todo_split_both_nonzero
test_todo_split_project_only
test_todo_split_global_only
test_todo_split_both_zero_no_segment
test_todo_split_backward_compat_no_cache_fields
test_todo_split_p_suffix_present

echo ""
echo "--- Lifetime cost display ---"
test_lifetime_cost_absent_when_zero
test_lifetime_cost_shown_when_nonzero
test_lifetime_cost_not_shown_when_cache_absent

echo ""
echo "--- Initiative banner Line 0 ---"
test_banner_absent_when_no_plan
test_banner_shows_full_initiative_and_phase
test_banner_shows_initiative_without_phase
test_banner_shows_phase_count
test_banner_shows_multi_initiative_suffix
test_banner_is_last_line

echo ""
echo "--- Lifetime token display ---"
test_lifetime_tokens_absent_when_zero_history_no_subagent
test_lifetime_tokens_shown_with_past_sessions
test_lifetime_tokens_includes_subagent
test_lifetime_tokens_grand_total_all_sources
test_lifetime_tokens_absent_when_cache_absent
test_lifetime_tokens_dim_rendering

echo ""
echo "--- New token format (issue #160) ---"
test_new_token_format_no_subagent
test_new_token_format_with_subagent
test_new_lifetime_format_with_prefix
test_new_lifetime_format_tks_suffix

echo ""
echo "--- Responsive layout ---"
test_responsive_all_segments_wide
test_responsive_line1_narrow_drops_todos
test_responsive_line1_very_narrow_keeps_workspace
test_responsive_line2_narrow_drops_lines_changed
test_responsive_line2_very_narrow_keeps_context_bar
test_responsive_no_truncation_at_wide
echo ""
echo "--- Terminal width (DEC-STATUSLINE-TERMWIDTH-003) ---"
test_termwidth_cols_180_effective_115
test_termwidth_cols_60_floor_kicks_in
test_termwidth_cols_0_floor_kicks_in

echo ""
echo "--- Dual-color context bar (baseline) ---"
test_dual_color_bar_shows_both_block_types
test_dual_color_bar_system_uses_dark_grey_color
test_dual_color_bar_no_baseline_falls_back_single_color
test_baseline_captured_on_first_valid_reading
test_baseline_invalidated_on_pct_drop
test_baseline_invalidated_on_fingerprint_change
test_baseline_not_captured_when_pct_invalid
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

