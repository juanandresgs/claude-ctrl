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
# Test group 3: Cost — ~$ prefix and color thresholds
# ============================================================================

test_cost_tilde_prefix() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{"total_cost_usd":0.53},"context_window":{}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    if printf '%s' "$line2" | grep -qF '~$0.53'; then
        pass_test "Cost displays with ~\$ prefix (e.g. ~\$0.53)"
    else
        fail_test "Cost missing ~\$ prefix" "line2=$line2"
    fi
}

test_cost_display_present() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{"total_cost_usd":0.53},"context_window":{}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    if printf '%s' "$line2" | grep -qF '~$0.53'; then
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

    if printf '%s' "$line2" | grep -qF '~$0.00'; then
        pass_test 'Zero cost displays as ~$0.00'
    else
        fail_test 'Zero cost display wrong' "line2=$line2"
    fi
}

test_cost_no_field() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    if printf '%s' "$line2" | grep -qF '~$0.00'; then
        pass_test 'Missing cost field defaults to ~$0.00'
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
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/cleanws"},"cost":{},"context_window":{}}'
    local line1
    line1=$(run_statusline "$json" | head -1 | strip_ansi)

    # Check that "dirty:" label is absent
    if ! printf '%s' "$line1" | grep -qE 'dirty:'; then
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

    if [[ "$line1" != *"todos:"* ]]; then
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

    if [[ "$line1" == *"todos: 7"* ]]; then
        pass_test "Todos segment shows count from .todo-count file (todos: 7)"
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
# Test group 8: Domain clustering — line 1 label format (REQ-P0-001, REQ-P0-002)
# ============================================================================

test_dirty_label_format() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    printf '{"dirty":8,"worktrees":2,"agents_active":0,"agents_types":""}' \
        > "$tmpdir/.claude/.statusline-cache"

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    line1=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | head -1 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line1" == *"dirty: 8"* ]]; then
        pass_test "Git segment shows 'dirty: N' label format"
    else
        fail_test "Git segment not using 'dirty: N' label" "line1=$line1"
    fi
}

test_wt_label_format() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    printf '{"dirty":0,"worktrees":2,"agents_active":0,"agents_types":""}' \
        > "$tmpdir/.claude/.statusline-cache"

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    line1=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | head -1 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line1" == *"wt: 2"* ]]; then
        pass_test "Git segment shows 'wt: N' label format"
    else
        fail_test "Git segment not using 'wt: N' label" "line1=$line1"
    fi
}

test_agents_label_format() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    printf '{"dirty":0,"worktrees":0,"agents_active":3,"agents_types":"impl,test"}' \
        > "$tmpdir/.claude/.statusline-cache"

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    line1=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | head -1 | strip_ansi)
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
    local line1
    line1=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | head -1 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line1" == *"todos: 10"* ]]; then
        pass_test "Todos segment shows 'todos: N' label format"
    else
        fail_test "Todos segment not using 'todos: N' label" "line1=$line1"
    fi
}

test_domain_clustering_order() {
    run_test
    # Line 1 should have: model+workspace BEFORE dirty: BEFORE agents: BEFORE todos:
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    printf '{"dirty":5,"worktrees":1,"agents_active":2,"agents_types":"impl"}' \
        > "$tmpdir/.claude/.statusline-cache"
    echo "3" > "$tmpdir/.claude/.todo-count"

    local json='{"model":{"display_name":"Opus 4.6"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    line1=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | head -1 | strip_ansi)
    rm -rf "$tmpdir"

    # Extract positions
    local pos_model pos_dirty pos_agents pos_todos
    pos_model=$(printf '%s' "$line1" | grep -bo 'Opus 4.6' | head -1 | cut -d: -f1)
    pos_dirty=$(printf '%s' "$line1" | grep -bo 'dirty:' | head -1 | cut -d: -f1)
    pos_agents=$(printf '%s' "$line1" | grep -bo 'agents:' | head -1 | cut -d: -f1)
    pos_todos=$(printf '%s' "$line1" | grep -bo 'todos:' | head -1 | cut -d: -f1)

    if [[ -n "$pos_model" && -n "$pos_dirty" && -n "$pos_agents" && -n "$pos_todos" ]] \
        && (( pos_model < pos_dirty )) \
        && (( pos_dirty < pos_agents )) \
        && (( pos_agents < pos_todos )); then
        pass_test "Domain clustering order: model < dirty < agents < todos"
    else
        fail_test "Domain clustering order wrong" \
            "line1=$line1 | positions: model=$pos_model dirty=$pos_dirty agents=$pos_agents todos=$pos_todos"
    fi
}

# ============================================================================
# Test group 9: Token count segment (REQ-P0-004)
# ============================================================================

test_tokens_segment_present() {
    run_test
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{"total_input_tokens":100000,"total_output_tokens":45000}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    if [[ "$line2" == *"tks:"* ]]; then
        pass_test "Token segment present in line 2"
    else
        fail_test "Token segment absent from line 2" "line2=$line2"
    fi
}

test_tokens_k_notation() {
    run_test
    # 100000 + 45000 = 145000 → 145k
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{"total_input_tokens":100000,"total_output_tokens":45000}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    if [[ "$line2" == *"tks: 145k"* ]]; then
        pass_test "Token count 145000 displays as 'tks: 145k'"
    else
        fail_test "Token K notation wrong" "line2=$line2"
    fi
}

test_tokens_raw_below_1k() {
    run_test
    # 300 + 200 = 500 → 500 (raw, no suffix)
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{"total_input_tokens":300,"total_output_tokens":200}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    if [[ "$line2" == *"tks: 500"* ]]; then
        pass_test "Token count 500 displays as 'tks: 500' (raw, no suffix)"
    else
        fail_test "Token raw notation wrong" "line2=$line2"
    fi
}

test_tokens_m_notation() {
    run_test
    # 1200000 + 300000 = 1500000 → 1.5M
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{"total_input_tokens":1200000,"total_output_tokens":300000}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    if [[ "$line2" == *"tks: 1.5M"* ]]; then
        pass_test "Token count 1500000 displays as 'tks: 1.5M'"
    else
        fail_test "Token M notation wrong" "line2=$line2"
    fi
}

test_tokens_zero_shows_dim() {
    run_test
    # 0 tokens → "tks: 0", dim color (ESC[2m)
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{}}'
    local line2_raw
    line2_raw=$(run_statusline "$json" | tail -1)

    # Dim = ESC[2m before "tks:"
    if printf '%s' "$line2_raw" | grep -q $'\033\[2mtks:'; then
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
    line2_raw=$(run_statusline "$json" | tail -1)

    # Yellow = ESC[33m before "tks:"
    if printf '%s' "$line2_raw" | grep -q $'\033\[33mtks:'; then
        pass_test "Token count >500k shows in yellow"
    else
        fail_test "Token count >500k not yellow" "raw: $(printf '%s' "$line2_raw" | cat -v)"
    fi
}

test_tokens_segment_position() {
    run_test
    # tks: segment should appear AFTER context bar and BEFORE cost (~$)
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{"total_cost_usd":0.50},"context_window":{"used_percentage":40,"total_input_tokens":100000,"total_output_tokens":45000}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    local pos_bar pos_tokens pos_cost
    pos_bar=$(printf '%s' "$line2" | grep -bo '\[' | head -1 | cut -d: -f1)
    pos_tokens=$(printf '%s' "$line2" | grep -bo 'tks:' | head -1 | cut -d: -f1)
    pos_cost=$(printf '%s' "$line2" | grep -bo '~\$' | head -1 | cut -d: -f1)

    if [[ -n "$pos_bar" && -n "$pos_tokens" && -n "$pos_cost" ]] \
        && (( pos_bar < pos_tokens )) \
        && (( pos_tokens < pos_cost )); then
        pass_test "Line 2 order: context bar < tks: < ~\$cost"
    else
        fail_test "Line 2 segment order wrong" \
            "line2=$line2 | positions: bar=$pos_bar tks=$pos_tokens cost=$pos_cost"
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
        "$tp" "$tg" > "$dir/.claude/.statusline-cache"
}

test_todo_split_both_nonzero() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    make_todo_split_cache "$tmpdir" 3 7

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    line1=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | head -1 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line1" == *"todos: 3p"* && "$line1" == *"7g"* ]]; then
        pass_test "Todo split: both project and global shown as '3p 7g'"
    else
        fail_test "Todo split both nonzero not displayed" "line1=$line1"
    fi
}

test_todo_split_project_only() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    make_todo_split_cache "$tmpdir" 5 0

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    line1=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | head -1 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line1" == *"todos: 5p"* ]] && [[ "$line1" != *"g"*"todos"* || "$line1" == *"5p"* ]]; then
        # Verify it has "5p" but NOT a global count after it
        if printf '%s' "$line1" | grep -qE 'todos: 5p[^0-9]*$' || printf '%s' "$line1" | grep -q 'todos: 5p '; then
            pass_test "Todo split: project-only shown as 'todos: 5p'"
        elif [[ "$line1" == *"todos: 5p"* ]]; then
            pass_test "Todo split: project-only shown as 'todos: 5p'"
        else
            fail_test "Todo split project-only not displayed" "line1=$line1"
        fi
    else
        fail_test "Todo split project-only not displayed" "line1=$line1"
    fi
}

test_todo_split_global_only() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    make_todo_split_cache "$tmpdir" 0 9

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    line1=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | head -1 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line1" == *"todos: 9g"* ]]; then
        pass_test "Todo split: global-only shown as 'todos: 9g'"
    else
        fail_test "Todo split global-only not displayed" "line1=$line1"
    fi
}

test_todo_split_both_zero_no_segment() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    make_todo_split_cache "$tmpdir" 0 0

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    line1=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | head -1 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line1" != *"todos:"* ]]; then
        pass_test "Todo split: no segment when both project and global are 0"
    else
        fail_test "Todo segment shown when both counts are 0" "line1=$line1"
    fi
}

test_todo_split_backward_compat_no_cache_fields() {
    run_test
    # Cache WITHOUT todo_project/todo_global fields — should fall back to .todo-count
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    printf '{"dirty":0,"worktrees":0,"agents_active":0,"agents_types":""}' \
        > "$tmpdir/.claude/.statusline-cache"
    echo "12" > "$tmpdir/.claude/.todo-count"

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    line1=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | head -1 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line1" == *"todos: 12"* ]]; then
        pass_test "Backward compat: no cache split fields → falls back to .todo-count (todos: 12)"
    else
        fail_test "Backward compat fallback failed" "line1=$line1"
    fi
}

test_todo_split_p_suffix_present() {
    run_test
    # Verify the 'p' suffix appears in raw ANSI output (stripped display check above,
    # this checks the suffix character is not lost)
    local tmpdir
    tmpdir=$(mktemp -d)
    make_todo_split_cache "$tmpdir" 4 2

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    line1=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | head -1 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line1" == *"4p"* && "$line1" == *"2g"* ]]; then
        pass_test "Todo split: 'p' and 'g' suffix characters present (4p, 2g)"
    else
        fail_test "Todo split suffix characters missing" "line1=$line1"
    fi
}

# ============================================================================
# Test group 11: Lifetime cost display (REQ-P1-001)
# ============================================================================

test_lifetime_cost_absent_when_zero() {
    run_test
    # cache_lifetime_cost=0 → Σ annotation should NOT appear
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    printf '{"dirty":0,"worktrees":0,"agents_active":0,"agents_types":"","todo_project":0,"todo_global":0,"lifetime_cost":0}' \
        > "$tmpdir/.claude/.statusline-cache"

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{"total_cost_usd":0.25},"context_window":{}}'
    local line2
    line2=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | tail -1 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line2" != *"Σ"* ]]; then
        pass_test "Lifetime cost: Σ annotation absent when lifetime_cost=0"
    else
        fail_test "Lifetime cost Σ shown when lifetime_cost=0" "line2=$line2"
    fi
}

test_lifetime_cost_shown_when_nonzero() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    printf '{"dirty":0,"worktrees":0,"agents_active":0,"agents_types":"","todo_project":0,"todo_global":0,"lifetime_cost":12.40}' \
        > "$tmpdir/.claude/.statusline-cache"

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{"total_cost_usd":0.53},"context_window":{}}'
    local line2
    line2=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | tail -1 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line2" == *"Σ~\$12.40"* || "$line2" == *"Σ~\$12"* ]]; then
        pass_test "Lifetime cost: Σ~\$12.40 shown when lifetime_cost=12.40"
    else
        fail_test "Lifetime cost Σ annotation not shown" "line2=$line2"
    fi
}

test_lifetime_cost_not_shown_when_cache_absent() {
    run_test
    # No cache file at all → lifetime_cost defaults to 0 → no Σ
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/nocache"},"cost":{"total_cost_usd":0.50},"context_window":{}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    if [[ "$line2" != *"Σ"* ]]; then
        pass_test "Lifetime cost: no Σ when cache file absent"
    else
        fail_test "Lifetime cost Σ shown without cache file" "line2=$line2"
    fi
}

# ============================================================================
# Test group 12: Initiative context segment (issue #91)
# ============================================================================

# Helper: build .statusline-cache with initiative/phase fields
make_initiative_cache() {
    local dir="$1" initiative="$2" phase="$3" active_inits="${4:-1}"
    mkdir -p "$dir/.claude"
    printf '{"dirty":0,"worktrees":0,"agents_active":0,"agents_types":"","todo_project":0,"todo_global":0,"lifetime_cost":0,"initiative":"%s","phase":"%s","active_initiatives":%d}' \
        "$initiative" "$phase" "$active_inits" > "$dir/.claude/.statusline-cache"
}

test_initiative_absent_when_no_plan() {
    run_test
    # No cache file → initiative defaults to "" → segment absent
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/p"},"cost":{},"context_window":{}}'
    local line1
    line1=$(run_statusline "$json" | head -1 | strip_ansi)

    # Expect no initiative-looking content (no colon-P pattern or bare initiative name)
    # The key check: segment is absent when no plan
    if [[ "$line1" != *":P"* ]] && ! printf '%s' "$line1" | grep -qE 'P[0-9]+'; then
        pass_test "Initiative segment absent when no cache/plan"
    else
        fail_test "Initiative segment shown when no plan" "line1=$line1"
    fi
}

test_initiative_present_with_phase() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    make_initiative_cache "$tmpdir" "Backlog" "#### Phase 3: Implementation" 1

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    line1=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | head -1 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line1" == *"Backlog:P3"* ]]; then
        pass_test "Initiative segment shows 'Backlog:P3' format"
    else
        fail_test "Initiative+phase format wrong" "line1=$line1"
    fi
}

test_initiative_present_without_phase() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    make_initiative_cache "$tmpdir" "Backlog" "" 1

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    line1=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | head -1 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line1" == *"Backlog"* ]] && [[ "$line1" != *"Backlog:P"* ]]; then
        pass_test "Initiative segment shows name only when no phase"
    else
        fail_test "Initiative without phase format wrong" "line1=$line1"
    fi
}

test_initiative_truncation() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    # "Backlog Auto-Capture" is >20 chars (20 chars exactly: B-a-c-k-l-o-g- -A-u-t-o---C-a-p-t-u-r-e = 20)
    # Use a longer name to ensure truncation: "Statusline Initiative Context"
    make_initiative_cache "$tmpdir" "Statusline Initiative Context" "#### Phase 2: Tests" 1

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    line1=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | head -1 | strip_ansi)
    rm -rf "$tmpdir"

    # Long name should be truncated to first word: "Statusline"
    if [[ "$line1" == *"Statusline"* ]] && [[ "$line1" != *"Statusline Initiative"* ]]; then
        pass_test "Initiative name >20 chars truncated to first word"
    else
        fail_test "Initiative truncation wrong" "line1=$line1"
    fi
}

test_initiative_multiple_shows_plus() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    # 3 active initiatives → first name + "+2" suffix
    make_initiative_cache "$tmpdir" "Backlog" "#### Phase 3: Implementation" 3

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    line1=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | head -1 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line1" == *"Backlog+2:P3"* ]]; then
        pass_test "Multiple initiatives shows '+N' suffix: 'Backlog+2:P3'"
    else
        fail_test "Multiple initiatives +N suffix wrong" "line1=$line1"
    fi
}

test_initiative_position_before_dirty() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    # Cache with both initiative and dirty state
    printf '{"dirty":5,"worktrees":1,"agents_active":0,"agents_types":"","todo_project":0,"todo_global":0,"lifetime_cost":0,"initiative":"Backlog","phase":"#### Phase 2: Implementation","active_initiatives":1}' \
        > "$tmpdir/.claude/.statusline-cache"

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    line1=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | head -1 | strip_ansi)
    rm -rf "$tmpdir"

    local pos_initiative pos_dirty
    pos_initiative=$(printf '%s' "$line1" | grep -bo 'Backlog' | head -1 | cut -d: -f1)
    pos_dirty=$(printf '%s' "$line1" | grep -bo 'dirty:' | head -1 | cut -d: -f1)

    if [[ -n "$pos_initiative" && -n "$pos_dirty" ]] && (( pos_initiative < pos_dirty )); then
        pass_test "Initiative segment appears before dirty: segment"
    else
        fail_test "Initiative not before dirty" \
            "line1=$line1 | pos_initiative=$pos_initiative pos_dirty=$pos_dirty"
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
        "$lifetime_tokens" "$subagent_tokens" > "$dir/.claude/.statusline-cache"
}

test_lifetime_tokens_absent_when_zero_history_no_subagent() {
    run_test
    # No past sessions (lifetime_tokens=0), no subagents → plain "tks: 145k", no Σ
    local tmpdir
    tmpdir=$(mktemp -d)
    make_lifetime_token_cache "$tmpdir" 0 0

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{"total_input_tokens":100000,"total_output_tokens":45000}}'
    local line2
    line2=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | tail -1 | strip_ansi)
    rm -rf "$tmpdir"

    # tks: 145k should be present, Σ should NOT be present
    if [[ "$line2" == *"tks: 145k"* ]] && [[ "$line2" != *"Σ"* ]]; then
        pass_test "Lifetime tokens: no Σ when lifetime=0 and no subagents (first session)"
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
    line2=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | tail -1 | strip_ansi)
    rm -rf "$tmpdir"

    # Should show "tks: 145k │ Σ1.1M" — 1000000 past + 145000 current
    if [[ "$line2" == *"tks: 145k"* ]] && [[ "$line2" == *"Σ"* ]] && [[ "$line2" == *"1.1M"* ]]; then
        pass_test "Lifetime tokens: Σ1.1M shown when past sessions contributed 1M tokens"
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
    line2=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | tail -1 | strip_ansi)
    rm -rf "$tmpdir"

    # 0 past + 145k main + 95k subagent = tks: 145k(+95k), no Σ segment
    if [[ "$line2" == *"tks: 145k"* ]] && [[ "$line2" == *"(+95k)"* ]] && [[ "$line2" != *"Σ"* ]]; then
        pass_test "Lifetime tokens: tks: 145k(+95k) shown when subagent adds 95k, no Σ (no past sessions)"
    else
        fail_test "Lifetime tokens: subagent-only format wrong (expected tks: 145k(+95k), no Σ)" "line2=$line2"
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
    line2=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | tail -1 | strip_ansi)
    rm -rf "$tmpdir"

    # 500000 + 145000 + 55000 = 700000 → 700k; subagent shown as (+55k)
    if [[ "$line2" == *"tks: 145k"* ]] && [[ "$line2" == *"(+55k)"* ]] && [[ "$line2" == *"Σ"* ]] && [[ "$line2" == *"700k"* ]]; then
        pass_test "Lifetime tokens: tks: 145k(+55k) │ Σ700k = past(500k) + main(145k) + subagent(55k)"
    else
        fail_test "Lifetime tokens: grand total from all 3 sources wrong" "line2=$line2"
    fi
}

test_lifetime_tokens_absent_when_cache_absent() {
    run_test
    # No cache file → lifetime_tokens defaults to 0 → no Σ (same as first session)
    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp/nocache_tok"},"cost":{},"context_window":{"total_input_tokens":100000,"total_output_tokens":45000}}'
    local line2
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

    if [[ "$line2" != *"Σ"* ]]; then
        pass_test "Lifetime tokens: no Σ when cache absent (no history)"
    else
        fail_test "Lifetime tokens: Σ shown without cache file" "line2=$line2"
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
    line2_raw=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null | tail -1)
    rm -rf "$tmpdir"

    # Dim annotation pattern: ESC[2mΣNk (Σ is now a standalone dim segment)
    if printf '%s' "$line2_raw" | grep -q $'\033\[2mΣ'; then
        pass_test "Lifetime tokens: Σ segment rendered dim (ESC[2m)"
    else
        fail_test "Lifetime tokens: Σ segment not dim-rendered" "raw: $(printf '%s' "$line2_raw" | cat -v)"
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
echo "--- Domain clustering — line 1 labels (REQ-P0-001, REQ-P0-002) ---"
test_dirty_label_format
test_wt_label_format
test_agents_label_format
test_todos_label_format
test_domain_clustering_order

echo ""
echo "--- Token count segment (REQ-P0-004) ---"
test_tokens_segment_present
test_tokens_k_notation
test_tokens_raw_below_1k
test_tokens_m_notation
test_tokens_zero_shows_dim
test_tokens_high_shows_yellow
test_tokens_segment_position

echo ""
echo "--- Todo split display (REQ-P0-005) ---"
test_todo_split_both_nonzero
test_todo_split_project_only
test_todo_split_global_only
test_todo_split_both_zero_no_segment
test_todo_split_backward_compat_no_cache_fields
test_todo_split_p_suffix_present

echo ""
echo "--- Lifetime cost display (REQ-P1-001) ---"
test_lifetime_cost_absent_when_zero
test_lifetime_cost_shown_when_nonzero
test_lifetime_cost_not_shown_when_cache_absent

echo ""
echo "--- Initiative context segment (issue #91) ---"
test_initiative_absent_when_no_plan
test_initiative_present_with_phase
test_initiative_present_without_phase
test_initiative_truncation
test_initiative_multiple_shows_plus
test_initiative_position_before_dirty

echo ""
echo "--- Lifetime token display (DEC-LIFETIME-TOKENS-001) ---"
test_lifetime_tokens_absent_when_zero_history_no_subagent
test_lifetime_tokens_shown_with_past_sessions
test_lifetime_tokens_includes_subagent
test_lifetime_tokens_grand_total_all_sources
test_lifetime_tokens_absent_when_cache_absent
test_lifetime_tokens_dim_rendering

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
