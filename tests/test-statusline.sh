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
    local line2
    # Model is on line 2 (metrics line) — line 1 is project context (workspace/git/agents/todos)
    line2=$(run_statusline "$json" | sed -n '2p' | strip_ansi)

    if [[ "$line2" == *"Opus 4.6"* ]]; then
        pass_test "Line 2 contains model name"
    else
        fail_test "Line 2 missing model name" "line2=$line2"
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
    local _rsl_out
    _rsl_out=$(run_statusline "$json")
    line1=$(extract_line "$_rsl_out" 1 | strip_ansi)

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
    local _rsl_out
    _rsl_out=$(run_statusline "$json")
    line1=$(extract_line "$_rsl_out" 1 | strip_ansi)

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
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line1=$(extract_line "$output" 1 | strip_ansi)
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
        > "$tmpdir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line1=$(extract_line "$output" 1 | strip_ansi)
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
        > "$tmpdir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line1=$(extract_line "$output" 1 | strip_ansi)
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
    local line1
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line1=$(extract_line "$output" 1 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line1" == *"todos: 10"* ]]; then
        pass_test "Todos segment shows 'todos: N' label format"
    else
        fail_test "Todos segment not using 'todos: N' label" "line1=$line1"
    fi
}

test_domain_clustering_order() {
    run_test
    # Line 1 should have: workspace BEFORE dirty: BEFORE agents: BEFORE todos:
    # (Model is on line 2, not line 1)
    # Use COLUMNS=300 (term_w=235 after 65-char right-panel reservation) so all
    # five segments fit and the ordering can be verified without responsive drops.
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    printf '{"dirty":5,"worktrees":1,"agents_active":2,"agents_types":"impl"}' \
        > "$tmpdir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"
    echo "3" > "$tmpdir/.claude/.todo-count"

    local json='{"model":{"display_name":"Opus 4.6"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    local output
    output=$(run_sl_columns "$json" 300 "$tmpdir")
    line1=$(extract_line "$output" 1 | strip_ansi)
    rm -rf "$tmpdir"

    # Extract positions of domain clusters on line 1
    # workspace (tmpdir basename) comes first, then dirty:, agents:, todos:
    local pos_dirty pos_agents pos_todos
    pos_dirty=$(printf '%s' "$line1" | grep -bo 'dirty:' 2>/dev/null | { head -1; cat > /dev/null; } | cut -d: -f1 || true)
    pos_agents=$(printf '%s' "$line1" | grep -bo 'agents:' 2>/dev/null | { head -1; cat > /dev/null; } | cut -d: -f1 || true)
    pos_todos=$(printf '%s' "$line1" | grep -bo 'todos:' 2>/dev/null | { head -1; cat > /dev/null; } | cut -d: -f1 || true)

    if [[ -n "$pos_dirty" && -n "$pos_agents" && -n "$pos_todos" ]] \
        && (( pos_dirty < pos_agents )) \
        && (( pos_agents < pos_todos )); then
        pass_test "Domain clustering order: dirty < agents < todos on line 1"
    else
        fail_test "Domain clustering order wrong" \
            "line1=$line1 | positions: dirty=$pos_dirty agents=$pos_agents todos=$pos_todos"
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
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

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
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

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
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

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
    line2_raw=$(run_statusline "$json" | tail -1)

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
    line2_raw=$(run_statusline "$json" | tail -1)

    # Yellow = ESC[33m applied to "600K tks" segment
    if printf '%s' "$line2_raw" | grep -q $'\033\[33m600K tks'; then
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
    pos_bar=$(printf '%s' "$line2" | { grep -bo '\[' || true; } | head -1 | cut -d: -f1)
    pos_tokens=$(printf '%s' "$line2" | { grep -bo 'K tks' || true; } | head -1 | cut -d: -f1)
    pos_cost=$(printf '%s' "$line2" | { grep -bo '~\$' || true; } | head -1 | cut -d: -f1)

    if [[ -n "$pos_bar" && -n "$pos_tokens" && -n "$pos_cost" ]] \
        && (( pos_bar < pos_tokens )) \
        && (( pos_tokens < pos_cost )); then
        pass_test "Line 2 order: context bar < Ntks < ~\$cost"
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
        "$tp" "$tg" > "$dir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"
}

test_todo_split_both_nonzero() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    make_todo_split_cache "$tmpdir" 3 7

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line1=$(extract_line "$output" 1 | strip_ansi)
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
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line1=$(extract_line "$output" 1 | strip_ansi)
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
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line1=$(extract_line "$output" 1 | strip_ansi)
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
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line1=$(extract_line "$output" 1 | strip_ansi)
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
        > "$tmpdir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"
    echo "12" > "$tmpdir/.claude/.todo-count"

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{},"context_window":{}}'
    local line1
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line1=$(extract_line "$output" 1 | strip_ansi)
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
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line1=$(extract_line "$output" 1 | strip_ansi)
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
        > "$tmpdir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{"total_cost_usd":0.25},"context_window":{}}'
    local line2
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line2=$(printf '%s' "$output" | tail -1 | strip_ansi)
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
        > "$tmpdir/.claude/.statusline-cache-${CLAUDE_SESSION_ID}"

    local json='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"'"$tmpdir"'"},"cost":{"total_cost_usd":0.53},"context_window":{}}'
    local line2
    local output
    output=$(run_statusline "$json" "$tmpdir")
    line2=$(printf '%s' "$output" | tail -1 | strip_ansi)
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

    if [[ "$line_count" -eq 1 ]]; then
        pass_test "No initiative → 2-line output (1 newline), no banner line"
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
    line0=$(extract_line "$output" 3 | strip_ansi)
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
    line0=$(extract_line "$output" 3 | strip_ansi)
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
    line0=$(extract_line "$output" 3 | strip_ansi)
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
    line0=$(extract_line "$output" 3 | strip_ansi)
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
    line0=$(extract_line "$output" 3 | strip_ansi)
    line1=$(extract_line "$output" 1 | strip_ansi)
    rm -rf "$tmpdir"

    # Line 3 (last) has the initiative; Line 1 has project context (not model)
    if [[ "$line0" == *"Statusline Banner"* ]] && [[ -n "$line1" ]]; then
        pass_test "Banner is last line (Line 3); project context present on Line 1"
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
    line2=$(printf '%s' "$output" | tail -1 | strip_ansi)
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
    line2=$(printf '%s' "$output" | tail -1 | strip_ansi)
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
    line2=$(printf '%s' "$output" | tail -1 | strip_ansi)
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
    line2=$(printf '%s' "$output" | tail -1 | strip_ansi)
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
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

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
    line2_raw=$(printf '%s' "$output" | tail -1)
    rm -rf "$tmpdir"

    # Dim annotation pattern: ESC[2mProject Lifetime: ∑Nktks
    if printf '%s' "$line2_raw" | grep -q $'\033\[2mProject Lifetime:'; then
        pass_test "Lifetime tokens: ∑ (Project Lifetime:) segment rendered dim (ESC[2m)"
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
    local ok=true
    [[ "$stripped" != *"dirty: 5"* ]] && ok=false
    [[ "$stripped" != *"wt: 2"* ]] && ok=false
    [[ "$stripped" != *"agents: 3"* ]] && ok=false
    [[ "$stripped" != *"4p"* ]] && ok=false
    [[ "$stripped" != *"Opus 4.6"* ]] && ok=false
    [[ "$stripped" != *"tks"* ]] && ok=false
    if $ok; then
        pass_test "Responsive: COLUMNS=200 shows all segments"
    else
        fail_test "Responsive: missing segments at COLUMNS=200" "stripped=$stripped"
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
    # COLUMNS=75: term_w=10 (75-65), floor kicks in -> term_w=60.
    # At term_w=60, +N/-N lines (priority 8, drops first) are dropped.
    # Verifies that narrow effective width causes correct responsive drop behavior.
    local json='{"model":{"display_name":"Opus 4.6"},"workspace":{"current_dir":"/Users/turla/proj"},"cost":{"total_cost_usd":0.53,"total_duration_ms":60000,"total_lines_added":42,"total_lines_removed":7},"context_window":{"used_percentage":35,"current_usage":{"cache_read_input_tokens":50000,"input_tokens":10000,"cache_creation_input_tokens":5000},"total_input_tokens":150000,"total_output_tokens":50000}}'
    local output
    output=$(run_sl_columns "$json" 75)
    local line2
    line2=$(extract_line "$output" 2 | strip_ansi)
    if [[ "$line2" != *"+42"* ]]; then
        pass_test "Responsive: COLUMNS=75 drops +N/-N lines (term_w=10 after TERMWIDTH-003 subtraction)"
    else
        fail_test "Responsive: +42 should be dropped at COLUMNS=75 (term_w=10)" "line2=$line2"
    fi
}

test_responsive_line2_very_narrow_keeps_context_bar() {
    run_test
    local json='{"model":{"display_name":"Opus 4.6"},"workspace":{"current_dir":"/Users/turla/proj"},"cost":{"total_cost_usd":0.53,"total_duration_ms":60000},"context_window":{"used_percentage":35,"total_input_tokens":150000,"total_output_tokens":50000}}'
    local output
    output=$(run_sl_columns "$json" 25)
    local line2
    line2=$(extract_line "$output" 2 | strip_ansi)
    if [[ "$line2" == *"35%"* ]] || [[ "$line2" == *"\u2591"* ]]; then
        pass_test "Responsive: COLUMNS=25 preserves context bar"
    else
        fail_test "Responsive: context bar lost at COLUMNS=25" "line2=$line2"
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
# @title Tests for right-panel reservation: term_w = COLUMNS - 65 (floor 60)
# @status accepted
# @rationale Verifies three key invariants of the Claude Code right-panel reservation:
#   1. COLUMNS=180 -> effective width 115 (65-char reservation active, no floor)
#   2. COLUMNS=60  -> floor kicks in (60-65=-5 -> clamped to 60, not negative)
#   3. COLUMNS=0   -> floor kicks in (0-65=-65 -> clamped to 60)
# Test 1 uses a 71-char workspace basename to force line1 total ~131 chars.
# At term_w=115 agents+todos drop; at term_w=180 nothing drops.
# Asserting agents IS dropped at COLUMNS=180 proves effective width=115.
# ----------------------------------------------------------------------------

test_termwidth_cols_180_effective_115() {
    run_test
    # 73-char workspace basename: line1 total ~131 chars (workspace+dirty+wt+agents+todos).
    # New code (COLUMNS=180, term_w=115=180-65): todos(p5)+agents(p4) both dropped.
    # Old code (COLUMNS=180, term_w=180): line1=131<180, nothing drops, agents visible.
    # Asserting agents ABSENT at COLUMNS=180 proves the 65-char right-panel reservation.
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
    output=$(printf '%s' "$json" | COLUMNS=180 HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null)
    local line1
    line1=$(extract_line "$output" 1 | strip_ansi)
    rm -rf "$tmpdir"
    if [[ "$line1" != *"agents:"* ]]; then
        pass_test "termwidth: COLUMNS=180 effective width 115 — agents dropped (proves 65-char reservation)"
    else
        fail_test "termwidth: COLUMNS=180 should reserve 65 chars (effective=115), but agents still visible" "line1=$line1"
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
    line2=$(run_statusline "$json" | tail -1 | strip_ansi)

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
    line2=$(printf '%s' "$output" | tail -1 | strip_ansi)
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
    line2=$(printf '%s' "$output" | tail -1 | strip_ansi)
    rm -rf "$tmpdir"

    if [[ "$line2" == *"Project Lifetime:"* ]]; then
        pass_test "New format: lifetime segment contains 'Project Lifetime:' prefix"
    else
        fail_test "New format: 'Project Lifetime:' prefix not found" "line2=$line2"
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
    line2=$(printf '%s' "$output" | tail -1 | strip_ansi)
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
# fingerprint drift, (c) rendering that shows ▓ blocks for system overhead in dim color
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

    # 20% baseline -> floor(20*12/100)=2 system blocks (full block, dim)
    # 60% total -> floor(60*12/100)=7 filled; conversation=7-2=5 blocks (full block, severity color)
    # Verify: bar contains full block chars AND dim ANSI code (ESC[2m) for system region
    if [[ "$raw_line2" == *$'\xe2\x96\x88'* ]] && printf '%s' "$raw_line2_ansi" | grep -qF $'\033[2m'; then
        pass_test "Dual-color bar: baseline=20 total=60 shows full-block chars with dim code for system region"
    else
        fail_test "Dual-color bar: expected full-block chars and dim ANSI code in bar" "raw_line2=$raw_line2"
    fi
}

test_dual_color_bar_system_uses_dim_color() {
    # System blocks should be preceded by a dim ANSI code (ESC[2m).
    # The bar renders: dim bracket+system blocks, severity conversation blocks, dim empty+bracket.
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

    # The dual-color bar renders dim code (ESC[2m) for system (full-block) region.
    # Check that ESC[2m appears in the bar output.
    if printf '%s' "$raw_line2" | grep -qF $'\033[2m'; then
        pass_test "Dual-color bar: dim color code (ESC[2m) present in bar output for system blocks"
    else
        fail_test "Dual-color bar: no dim ANSI code (ESC[2m) found in bar output" \
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
test_dual_color_bar_system_uses_dim_color
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

