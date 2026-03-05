#!/usr/bin/env bash
# test-subagent-tokens.sh — Tests for subagent token tracking feature.
#
# Tests:
#   T01 — sum_transcript_tokens() parses JSONL and sums correctly
#   T02 — sum_transcript_tokens() returns 1 for missing transcript
#   T03 — sum_transcript_tokens() returns 1 for unparseable content
#   T04 — track-agent-tokens.sh exits 0 silently when no transcript_path
#   T05 — track-agent-tokens.sh writes state file on valid transcript
#   T06 — track-agent-tokens.sh updates .statusline-cache subagent_tokens
#   T07 — track-agent-tokens.sh accumulates across multiple agents
#   T08 — statusline shows plain "tokens: Nk" when no subagent_tokens
#   T09 — statusline shows "tokens: Nk (ΣNk)" when subagent_tokens > 0
#   T10 — statusline grand total is session + subagent sum
#
# @decision DEC-TEST-SUBAGENT-TOKENS-001
# @title Subagent token tracking test suite
# @status accepted
# @rationale All components (sum_transcript_tokens, track-agent-tokens.sh,
# statusline.sh) are testable with synthetic JSONL inputs and temp cache files.
# No mocks needed — tests use real implementations with controlled fixtures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK_DIR="$WORKTREE_ROOT/hooks"
STATUSLINE="$WORKTREE_ROOT/scripts/statusline.sh"

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

pass_test() { TESTS_PASSED=$(( TESTS_PASSED + 1 )); echo -e "${GREEN}PASS${NC} $1"; }
fail_test() { TESTS_FAILED=$(( TESTS_FAILED + 1 )); echo -e "${RED}FAIL${NC} $1"; echo -e "  ${YELLOW}Details:${NC} $2"; }
run_test()  { TESTS_RUN=$(( TESTS_RUN + 1 )); }

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# ============================================================================
# Test group 1: sum_transcript_tokens() function
# ============================================================================

test_sum_transcript_tokens_basic() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    local transcript="$tmpdir/transcript.jsonl"

    # Write synthetic JSONL with message.usage fields (real Claude transcript format)
    cat > "$transcript" <<'JSONL'
{"type":"assistant","message":{"usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":200,"cache_creation_input_tokens":100}}}
{"type":"assistant","message":{"usage":{"input_tokens":800,"output_tokens":300,"cache_read_input_tokens":0,"cache_creation_input_tokens":50}}}
{"type":"user","message":{"content":"hello"}}
JSONL

    # Source session-lib.sh to get sum_transcript_tokens
    local result
    result=$(bash -c "
        source '$HOOK_DIR/source-lib.sh'
        require_session
        sum_transcript_tokens '$transcript'
    " 2>/dev/null)

    rm -rf "$tmpdir"

    # Verify: input=1800, output=800, cache_read=200, cache_create=150
    local input output cache_read cache_create
    input=$(echo "$result" | jq -r '.input' 2>/dev/null || echo -1)
    output=$(echo "$result" | jq -r '.output' 2>/dev/null || echo -1)
    cache_read=$(echo "$result" | jq -r '.cache_read' 2>/dev/null || echo -1)
    cache_create=$(echo "$result" | jq -r '.cache_create' 2>/dev/null || echo -1)

    if [[ "$input" == "1800" && "$output" == "800" && "$cache_read" == "200" && "$cache_create" == "150" ]]; then
        pass_test "T01: sum_transcript_tokens() correctly sums all usage fields"
    else
        fail_test "T01: sum_transcript_tokens() wrong sums" \
            "input=$input (want 1800) output=$output (want 800) cache_read=$cache_read (want 200) cache_create=$cache_create (want 150)"
    fi
}

test_sum_transcript_tokens_missing_file() {
    run_test
    local result=0
    bash -c "
        source '$HOOK_DIR/source-lib.sh'
        require_session
        sum_transcript_tokens '/nonexistent/path/transcript.jsonl'
    " 2>/dev/null || result=$?

    if [[ "$result" -ne 0 ]]; then
        pass_test "T02: sum_transcript_tokens() returns non-zero for missing transcript"
    else
        fail_test "T02: sum_transcript_tokens() should fail for missing transcript" "exit_code=$result"
    fi
}

test_sum_transcript_tokens_no_usage() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    local transcript="$tmpdir/transcript.jsonl"

    # Transcript with no message.usage fields
    cat > "$transcript" <<'JSONL'
{"type":"user","message":{"content":"hello"}}
{"type":"assistant","message":{"content":"hi there"}}
JSONL

    local result
    result=$(bash -c "
        source '$HOOK_DIR/source-lib.sh'
        require_session
        sum_transcript_tokens '$transcript'
    " 2>/dev/null)

    rm -rf "$tmpdir"

    # Should return all zeros (valid JSON, just no usage)
    local input output
    input=$(echo "$result" | jq -r '.input' 2>/dev/null || echo -1)
    output=$(echo "$result" | jq -r '.output' 2>/dev/null || echo -1)

    if [[ "$input" == "0" && "$output" == "0" ]]; then
        pass_test "T03: sum_transcript_tokens() returns zeros for transcript with no usage fields"
    else
        fail_test "T03: sum_transcript_tokens() wrong output for no-usage transcript" \
            "input=$input output=$output (both want 0)"
    fi
}

# ============================================================================
# Test group 2: track-agent-tokens.sh hook behavior
# ============================================================================

test_hook_exits_silently_no_transcript() {
    run_test
    # SubagentStop payload without agent_transcript_path
    local payload='{"agent_type":"implementer","last_assistant_message":"done"}'
    local result=0

    bash -c "
        export CLAUDE_SESSION_ID='test-session-$$'
        printf '%s' '$payload' | bash '$HOOK_DIR/track-agent-tokens.sh'
    " 2>/dev/null || result=$?

    if [[ "$result" -eq 0 ]]; then
        pass_test "T04: track-agent-tokens.sh exits 0 silently when no transcript_path in payload"
    else
        fail_test "T04: track-agent-tokens.sh should exit 0 for missing transcript_path" "exit_code=$result"
    fi
}

test_hook_writes_state_file() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    local transcript="$tmpdir/transcript.jsonl"

    cat > "$transcript" <<'JSONL'
{"type":"assistant","message":{"usage":{"input_tokens":5000,"output_tokens":2000,"cache_read_input_tokens":1000,"cache_creation_input_tokens":500}}}
JSONL

    local session_id="test-tokens-$$"
    # State file goes to $tmpdir/.claude/ (get_claude_dir returns PROJECT_ROOT/.claude)
    mkdir -p "$tmpdir/.claude"
    local state_file="$tmpdir/.claude/.subagent-tokens-$session_id"
    local payload
    payload=$(printf '{"agent_type":"implementer","agent_transcript_path":"%s"}' "$transcript")

    bash -c "
        export CLAUDE_SESSION_ID='$session_id'
        export PROJECT_ROOT='$tmpdir'
        printf '%s' '$payload' | bash '$HOOK_DIR/track-agent-tokens.sh'
    " 2>/dev/null || true

    if [[ -f "$state_file" ]]; then
        local line
        line=$(head -1 "$state_file")
        # Format: epoch|agent_type|input|output|cache_read|cache_create|total
        local agent_type total
        agent_type=$(echo "$line" | cut -d'|' -f2)
        total=$(echo "$line" | cut -d'|' -f7)

        rm -rf "$tmpdir"

        if [[ "$agent_type" == "implementer" && "$total" == "8500" ]]; then
            pass_test "T05: track-agent-tokens.sh writes correct state file entry (total=8500)"
        else
            fail_test "T05: state file entry wrong" "agent_type=$agent_type (want implementer) total=$total (want 8500)"
        fi
    else
        rm -rf "$tmpdir"
        fail_test "T05: state file not created at $state_file" "file does not exist"
    fi
}

test_hook_updates_statusline_cache() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    local transcript="$tmpdir/transcript.jsonl"

    cat > "$transcript" <<'JSONL'
{"type":"assistant","message":{"usage":{"input_tokens":10000,"output_tokens":3000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
JSONL

    local session_id="test-cache-$$"
    # Pre-create a minimal statusline-cache (in PROJECT_ROOT/.claude/)
    mkdir -p "$tmpdir/.claude"
    printf '{"dirty":0,"worktrees":1,"updated":0,"agents_active":0,"lifetime_cost":0}\n' \
        > "$tmpdir/.claude/.statusline-cache"

    local payload
    payload=$(printf '{"agent_type":"tester","agent_transcript_path":"%s"}' "$transcript")

    bash -c "
        export CLAUDE_SESSION_ID='$session_id'
        export PROJECT_ROOT='$tmpdir'
        printf '%s' '$payload' | bash '$HOOK_DIR/track-agent-tokens.sh'
    " 2>/dev/null || true

    local cache_file="$tmpdir/.claude/.statusline-cache"
    local subagent_tokens=0
    if [[ -f "$cache_file" ]]; then
        subagent_tokens=$(jq -r '.subagent_tokens // 0' "$cache_file" 2>/dev/null || echo 0)
    fi

    rm -rf "$tmpdir"

    if [[ "$subagent_tokens" -eq 13000 ]]; then
        pass_test "T06: track-agent-tokens.sh updates .statusline-cache with subagent_tokens=13000"
    else
        fail_test "T06: .statusline-cache subagent_tokens wrong" \
            "subagent_tokens=$subagent_tokens (want 13000)"
    fi
}

test_hook_accumulates_across_agents() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)

    # First agent transcript
    local transcript1="$tmpdir/transcript1.jsonl"
    printf '{"type":"assistant","message":{"usage":{"input_tokens":5000,"output_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' \
        > "$transcript1"

    # Second agent transcript
    local transcript2="$tmpdir/transcript2.jsonl"
    printf '{"type":"assistant","message":{"usage":{"input_tokens":3000,"output_tokens":500,"cache_read_input_tokens":200,"cache_creation_input_tokens":0}}}\n' \
        > "$transcript2"

    local session_id="test-accum-$$"
    mkdir -p "$tmpdir/.claude"

    # Run hook twice (simulating two agents completing), using PROJECT_ROOT to control claude dir
    bash -c "
        export CLAUDE_SESSION_ID='$session_id'
        export PROJECT_ROOT='$tmpdir'
        printf '{\"agent_type\":\"implementer\",\"agent_transcript_path\":\"$transcript1\"}' | bash '$HOOK_DIR/track-agent-tokens.sh'
    " 2>/dev/null || true

    bash -c "
        export CLAUDE_SESSION_ID='$session_id'
        export PROJECT_ROOT='$tmpdir'
        printf '{\"agent_type\":\"tester\",\"agent_transcript_path\":\"$transcript2\"}' | bash '$HOOK_DIR/track-agent-tokens.sh'
    " 2>/dev/null || true

    local state_file="$tmpdir/.claude/.subagent-tokens-$session_id"
    local cache_file="$tmpdir/.claude/.statusline-cache"

    local state_line_count=0
    [[ -f "$state_file" ]] && state_line_count=$(wc -l < "$state_file" | tr -d ' ')

    local cumulative=0
    [[ -f "$cache_file" ]] && cumulative=$(jq -r '.subagent_tokens // 0' "$cache_file" 2>/dev/null || echo 0)

    rm -rf "$tmpdir"

    # First agent: 5000+1000=6000, Second: 3000+500+200=3700, total=9700
    if [[ "$state_line_count" -eq 2 && "$cumulative" -eq 9700 ]]; then
        pass_test "T07: track-agent-tokens.sh accumulates correctly across 2 agents (total=9700)"
    else
        fail_test "T07: accumulation wrong" \
            "state_lines=$state_line_count (want 2) cumulative=$cumulative (want 9700)"
    fi
}

# ============================================================================
# Test group 3: statusline.sh display
# ============================================================================

# run_statusline_with_cache <cache_content> <total_input_tokens> <total_output_tokens>
# Creates a tmpdir, writes the cache, builds JSON with current_dir=tmpdir,
# runs statusline, returns output. The workspace current_dir MUST match the
# tmpdir so statusline resolves CACHE_FILE=$tmpdir/.claude/.statusline-cache.
run_statusline_with_cache() {
    local cache_content="$1"
    local total_input="${2:-0}"
    local total_output="${3:-0}"
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    printf '%s\n' "$cache_content" > "$tmpdir/.claude/.statusline-cache"

    # workspace current_dir = tmpdir so CACHE_FILE resolves to tmpdir/.claude/.statusline-cache
    # Build JSON using jq with numeric args to avoid quoting issues
    local json
    json=$(jq -n \
        --arg dir "$tmpdir" \
        --argjson tin "$total_input" \
        --argjson tout "$total_output" \
        '{"model":{"display_name":"Claude"},"workspace":{"current_dir":$dir},"cost":{"total_cost_usd":0.1,"total_duration_ms":1000},"context_window":{"used_percentage":20,"total_input_tokens":$tin,"total_output_tokens":$tout}}')

    local result
    result=$(printf '%s' "$json" | HOME="$tmpdir" bash "$STATUSLINE" 2>/dev/null || true)
    rm -rf "$tmpdir"
    printf '%s' "$result"
}

test_statusline_plain_tokens_no_subagent() {
    run_test
    # statusline reads total_tokens from: total_input_tokens + total_output_tokens
    # Use 8000+2000=10000 total tokens for "tks: 10k" display (label is "tks:", not "tokens:")
    local cache='{"dirty":0,"worktrees":0,"updated":0,"agents_active":0,"subagent_tokens":0,"lifetime_cost":0}'

    local line2
    line2=$(run_statusline_with_cache "$cache" 8000 2000 | tail -1 | strip_ansi)

    # Should show "tks: 10k" without (+Sk) annotation
    if [[ "$line2" == *"tks: 10k"* && "$line2" != *"(+"* ]]; then
        pass_test "T08: statusline shows plain 'tks: Nk' when subagent_tokens=0"
    else
        fail_test "T08: statusline token display wrong for zero subagent_tokens" \
            "line2=$line2"
    fi
}

test_statusline_sigma_display_with_subagent() {
    run_test
    # 80k+20k=100k session tokens + 50k subagent
    # Subagent tokens show as (+Sk) suffix: "tks: 100k(+50k)"
    local cache='{"dirty":0,"worktrees":0,"updated":0,"agents_active":0,"subagent_tokens":50000,"lifetime_cost":0}'

    local line2
    line2=$(run_statusline_with_cache "$cache" 80000 20000 | tail -1 | strip_ansi)

    # Should show (+50k) subagent annotation inline with tks:
    if [[ "$line2" == *"tks: 100k(+50k)"* ]]; then
        pass_test "T09: statusline shows (+Sk) inline annotation when subagent_tokens > 0"
    else
        fail_test "T09: statusline missing (+Sk) annotation" "line2=$line2"
    fi
}

test_statusline_grand_total_correct() {
    run_test
    # 160k+40k=200k session tokens + 145k subagent + 200k lifetime past sessions = Σ545k
    # Σ segment only shows when past-session lifetime_tokens > 0
    local cache='{"dirty":0,"worktrees":0,"updated":0,"agents_active":0,"subagent_tokens":145000,"lifetime_cost":0,"lifetime_tokens":200000}'

    local line2
    line2=$(run_statusline_with_cache "$cache" 160000 40000 | tail -1 | strip_ansi)

    # 200k session + 145k subagent + 200k lifetime = 545k grand total
    if [[ "$line2" == *"Σ545k"* ]]; then
        pass_test "T10: statusline grand total correct (200k + 145k + 200k = Σ545k)"
    else
        fail_test "T10: statusline grand total wrong" "line2=$line2 (expected Σ545k)"
    fi
}

# ============================================================================
# T11: Cold start full-schema cache creation
# ============================================================================

test_cold_start_full_schema_cache() {
    run_test
    local tmpdir
    tmpdir=$(mktemp -d)
    local transcript="$tmpdir/transcript.jsonl"

    cat > "$transcript" <<'JSONL'
{"type":"assistant","message":{"usage":{"input_tokens":2000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
JSONL

    local session_id="test-schema-$$"
    mkdir -p "$tmpdir/.claude"
    # NO existing .statusline-cache — cold start

    local payload
    payload=$(printf '{"agent_type":"planner","agent_transcript_path":"%s"}' "$transcript")

    bash -c "
        export CLAUDE_SESSION_ID='$session_id'
        export PROJECT_ROOT='$tmpdir'
        printf '%s' '$payload' | bash '$HOOK_DIR/track-agent-tokens.sh'
    " 2>/dev/null || true

    local cache_file="$tmpdir/.claude/.statusline-cache"
    local ok=true
    if [[ ! -f "$cache_file" ]]; then
        rm -rf "$tmpdir"
        fail_test "T11: cold start cache not created" "file does not exist"
        return
    fi

    # Verify all 14 fields are present
    local fields=("dirty" "worktrees" "agents_active" "agents_types"
                  "todo_project" "todo_global" "lifetime_cost" "lifetime_tokens"
                  "subagent_tokens" "initiative" "phase"
                  "active_initiatives" "total_phases" "updated")
    local missing=""
    for f in "${fields[@]}"; do
        if ! jq -e "has(\"$f\")" "$cache_file" >/dev/null 2>&1; then
            missing+=" $f"
            ok=false
        fi
    done

    local st
    st=$(jq -r '.subagent_tokens // 0' "$cache_file" 2>/dev/null)

    rm -rf "$tmpdir"

    if $ok && [[ "$st" -eq 2500 ]]; then
        pass_test "T11: cold start creates full-schema cache (all 14 fields, subagent_tokens=2500)"
    else
        fail_test "T11: cold start cache schema incomplete" "missing=[$missing] subagent_tokens=$st (want 2500)"
    fi
}

# ============================================================================
# Run all tests
# ============================================================================

echo "=== Subagent Token Tracking Tests ==="
echo ""

test_sum_transcript_tokens_basic
test_sum_transcript_tokens_missing_file
test_sum_transcript_tokens_no_usage

echo ""
test_hook_exits_silently_no_transcript
test_hook_writes_state_file
test_hook_updates_statusline_cache
test_hook_accumulates_across_agents

echo ""
test_statusline_plain_tokens_no_subagent
test_statusline_sigma_display_with_subagent
test_statusline_grand_total_correct

echo ""
test_cold_start_full_schema_cache

echo ""
echo "=== Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed ==="

[[ "$TESTS_FAILED" -eq 0 ]]
