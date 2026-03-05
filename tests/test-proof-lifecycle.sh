#!/usr/bin/env bash
# test-proof-lifecycle.sh — Tests for proof lifecycle fix (W1-W5)
#
# Tests:
#   T01: W1 — detect_project_root anchors from HOOK_INPUT .cwd
#   T02: W1 — phash consistency across different $PWD with same .cwd
#   T03: W2 — write_proof_status("verified") creates guardian marker
#   T04: W2 — write_proof_status("pending") does NOT create guardian marker
#   T05: W5 — state_update writes, state_read retrieves, history capped
#   T06: W3 — post-task.sh emits DISPATCH TESTER NOW (implementer + tests pass)
#   T07: W3 — post-task.sh emits advisory (implementer + tests fail)
#   T08: W4 — prompt-submit.sh emits DISPATCH GUARDIAN NOW on approval
#   T09: W5 — require_state loads state-lib.sh
#   T10: W5 — dual-write from write_proof_status to state.json
#   T11: Robustness — read_test_status handles non-numeric TEST_TIME
#
# @decision DEC-TEST-PROOF-001
# @title Test suite for proof lifecycle fix
# @status accepted
# @rationale Validates all 5 work items from the proof lifecycle plan plus
#   the robustness fix for read_test_status. Each test is isolated with its
#   own temp directory and cleanup.

set -euo pipefail
# Portable SHA-256 (macOS: shasum, Ubuntu: sha256sum)
if command -v shasum >/dev/null 2>&1; then
    _SHA256_CMD="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
    _SHA256_CMD="sha256sum"
else
    _SHA256_CMD="cat"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"

PASS_COUNT=0

# Cleanup trap (DEC-PROD-002): collect temp dirs and remove on exit
_CLEANUP_DIRS=()
trap '[[ ${#_CLEANUP_DIRS[@]} -gt 0 ]] && rm -rf "${_CLEANUP_DIRS[@]}" 2>/dev/null; true' EXIT
FAIL_COUNT=0
TOTAL_COUNT=0

pass_test() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS: ${CURRENT_TEST:-}"; }
fail_test() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: ${1:-${CURRENT_TEST:-}}"; }
run_test() { CURRENT_TEST="$1"; TOTAL_COUNT=$((TOTAL_COUNT + 1)); echo ""; echo "Running: $1"; }

make_temp_repo() {
    local d
    d=$(mktemp -d)
    git -C "$d" init --quiet 2>/dev/null
    mkdir -p "$d/.claude"
    echo "$d"
}

# ---------------------------------------------------------------------------
# T01: W1 — detect_project_root anchors from HOOK_INPUT .cwd
# ---------------------------------------------------------------------------
run_test "T01: W1 — detect_project_root anchors from HOOK_INPUT .cwd"

T01_REPO=$(make_temp_repo)
# Resolve symlinks (macOS: /var → /private/var) for consistent comparison
T01_REPO_RESOLVED=$(cd "$T01_REPO" && pwd -P)

T01_RESULT=$(
    unset CLAUDE_PROJECT_DIR
    source "$HOOKS_DIR/log.sh" 2>/dev/null
    # Set HOOK_INPUT AFTER sourcing log.sh (which resets HOOK_INPUT="")
    HOOK_INPUT="{\"cwd\":\"${T01_REPO}\"}"
    detect_project_root 2>/dev/null
)

if [[ "$T01_RESULT" == "$T01_REPO" || "$T01_RESULT" == "$T01_REPO_RESOLVED" ]]; then
    pass_test
else
    fail_test "expected '$T01_REPO'; got '$T01_RESULT'"
fi
rm -rf "$T01_REPO"

# ---------------------------------------------------------------------------
# T02: W1 — phash consistency with different $PWD but same .cwd
# ---------------------------------------------------------------------------
run_test "T02: W1 — phash consistency across different PWD with same .cwd"

T02_REPO=$(make_temp_repo)
T02_OTHER=$(mktemp -d)

T02_HASH1=$(
    unset CLAUDE_PROJECT_DIR
    cd "$T02_REPO"
    source "$HOOKS_DIR/log.sh" 2>/dev/null
    HOOK_INPUT="{\"cwd\":\"${T02_REPO}\"}"
    root=$(detect_project_root 2>/dev/null)
    project_hash "$root"
)

T02_HASH2=$(
    unset CLAUDE_PROJECT_DIR
    cd "$T02_OTHER"
    source "$HOOKS_DIR/log.sh" 2>/dev/null
    HOOK_INPUT="{\"cwd\":\"${T02_REPO}\"}"
    root=$(detect_project_root 2>/dev/null)
    project_hash "$root"
)

if [[ "$T02_HASH1" == "$T02_HASH2" && -n "$T02_HASH1" ]]; then
    pass_test
else
    fail_test "hashes differ: '$T02_HASH1' vs '$T02_HASH2'"
fi
rm -rf "$T02_REPO" "$T02_OTHER"

# ---------------------------------------------------------------------------
# T03: W2 — write_proof_status("verified") creates guardian marker
# ---------------------------------------------------------------------------
run_test "T03: W2 — write_proof_status('verified') creates guardian marker"

T03_REPO=$(make_temp_repo)
T03_TRACE=$(mktemp -d)

(
    export CLAUDE_PROJECT_DIR="$T03_REPO"
    export TRACE_STORE="$T03_TRACE"
    export CLAUDE_SESSION_ID="test3-$$"
    source "$HOOKS_DIR/log.sh" 2>/dev/null
    write_proof_status "verified" "$T03_REPO" 2>/dev/null
)

T03_MARKERS=$(ls "$T03_TRACE"/.active-guardian-* 2>/dev/null | wc -l | tr -d ' ')
if [[ "$T03_MARKERS" -ge 1 ]]; then
    pass_test
else
    fail_test "no .active-guardian-* marker found after write_proof_status('verified')"
fi
rm -rf "$T03_REPO" "$T03_TRACE"

# ---------------------------------------------------------------------------
# T04: W2 — write_proof_status("pending") does NOT create guardian marker
# ---------------------------------------------------------------------------
run_test "T04: W2 — write_proof_status('pending') does NOT create guardian marker"

T04_REPO=$(make_temp_repo)
T04_TRACE=$(mktemp -d)

(
    export CLAUDE_PROJECT_DIR="$T04_REPO"
    export TRACE_STORE="$T04_TRACE"
    export CLAUDE_SESSION_ID="test4-$$"
    source "$HOOKS_DIR/log.sh" 2>/dev/null
    write_proof_status "pending" "$T04_REPO" 2>/dev/null
)

T04_MARKERS=$(find "$T04_TRACE" -maxdepth 1 -name '.active-guardian-*' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$T04_MARKERS" -eq 0 ]]; then
    pass_test
else
    fail_test "guardian marker found after write_proof_status('pending') — should not exist"
fi
rm -rf "$T04_REPO" "$T04_TRACE"

# ---------------------------------------------------------------------------
# T05: W5 — state_update writes, state_read retrieves, history capped
# ---------------------------------------------------------------------------
run_test "T05: W5 — state.json CRUD and history cap"

T05_DIR=$(mktemp -d)
mkdir -p "$T05_DIR"

(
    export CLAUDE_DIR="$T05_DIR"
    source "$HOOKS_DIR/log.sh" 2>/dev/null
    source "$HOOKS_DIR/state-lib.sh" 2>/dev/null

    # Write a value
    state_update ".proof.status" "verified" "test" 2>/dev/null

    # Read it back
    val=$(state_read ".proof.status" 2>/dev/null || echo "")
    if [[ "$val" == "verified" ]]; then
        echo "PASS_READ"
    else
        echo "FAIL_READ: got '$val'"
    fi

    # Write 25 entries to test history cap
    for i in $(seq 1 25); do
        state_update ".test.key" "val$i" "test" 2>/dev/null
    done

    history_count=$(jq '.history | length' "$T05_DIR/state.json" 2>/dev/null || echo "0")
    if [[ "$history_count" -le 20 ]]; then
        echo "PASS_CAP"
    else
        echo "FAIL_CAP: history has $history_count entries"
    fi
) > "$T05_DIR/output.txt" 2>/dev/null

T05_OUT=$(cat "$T05_DIR/output.txt")
if echo "$T05_OUT" | grep -q "PASS_READ" && echo "$T05_OUT" | grep -q "PASS_CAP"; then
    pass_test
else
    fail_test "state.json CRUD: $(cat "$T05_DIR/output.txt")"
fi
rm -rf "$T05_DIR"

# ---------------------------------------------------------------------------
# T06: W3 — post-task.sh emits DISPATCH TESTER NOW (implementer + tests pass)
# ---------------------------------------------------------------------------
run_test "T06: W3 — post-task.sh emits DISPATCH TESTER NOW when implementer + tests pass"

T06_REPO=$(make_temp_repo)
T06_TRACE_STORE=$(mktemp -d)

# Write a passing test-status (format: result|fails|timestamp)
echo "pass|0|$(date +%s)" > "$T06_REPO/.claude/.test-status"

T06_INPUT="{\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"implementer\",\"prompt\":\"implement feature X\"},\"cwd\":\"${T06_REPO}\"}"

T06_OUT=$(
    export CLAUDE_PROJECT_DIR="$T06_REPO"
    export TRACE_STORE="$T06_TRACE_STORE"
    export CLAUDE_SESSION_ID="test6-$$"
    printf '%s' "$T06_INPUT" | bash "${HOOKS_DIR}/post-task.sh" 2>/dev/null || true
)

if echo "$T06_OUT" | grep -q "DISPATCH TESTER NOW"; then
    pass_test
else
    fail_test "expected 'DISPATCH TESTER NOW'; got: $(echo "$T06_OUT" | head -2)"
fi
rm -rf "$T06_REPO" "$T06_TRACE_STORE"

# ---------------------------------------------------------------------------
# T07: W3 — post-task.sh emits advisory when implementer + tests fail
# ---------------------------------------------------------------------------
run_test "T07: W3 — post-task.sh emits advisory when implementer + tests fail"

T07_REPO=$(make_temp_repo)
T07_TRACE_STORE=$(mktemp -d)

echo "fail|3|$(date +%s)" > "$T07_REPO/.claude/.test-status"

T07_INPUT="{\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"implementer\",\"prompt\":\"implement Y\"},\"cwd\":\"${T07_REPO}\"}"

T07_OUT=$(
    export CLAUDE_PROJECT_DIR="$T07_REPO"
    export TRACE_STORE="$T07_TRACE_STORE"
    export CLAUDE_SESSION_ID="test7-$$"
    printf '%s' "$T07_INPUT" | bash "${HOOKS_DIR}/post-task.sh" 2>/dev/null || true
)

if echo "$T07_OUT" | grep -q "additionalContext" && ! echo "$T07_OUT" | grep -q "DISPATCH TESTER NOW"; then
    pass_test
else
    fail_test "expected advisory without DISPATCH TESTER NOW; got: $(echo "$T07_OUT" | head -2)"
fi
rm -rf "$T07_REPO" "$T07_TRACE_STORE"

# ---------------------------------------------------------------------------
# T08: W4 — prompt-submit.sh emits DISPATCH GUARDIAN NOW on approval
# ---------------------------------------------------------------------------
run_test "T08: W4 — prompt-submit.sh emits DISPATCH GUARDIAN NOW on approval"

T08_REPO=$(make_temp_repo)
T08_PHASH=$(echo "$T08_REPO" | $_SHA256_CMD | cut -c1-8)

# Create pending proof-status
echo "pending|$(date +%s)" > "$T08_REPO/.claude/.proof-status-${T08_PHASH}"
echo "pending|$(date +%s)" > "$T08_REPO/.claude/.proof-status"

T08_INPUT="{\"prompt\":\"approved\",\"cwd\":\"${T08_REPO}\"}"

T08_OUT=$(
    export CLAUDE_PROJECT_DIR="$T08_REPO"
    export CLAUDE_SESSION_ID="test8-$$"
    printf '%s' "$T08_INPUT" | bash "${HOOKS_DIR}/prompt-submit.sh" 2>/dev/null || true
)

if echo "$T08_OUT" | grep -q "DISPATCH GUARDIAN NOW"; then
    pass_test
else
    fail_test "expected 'DISPATCH GUARDIAN NOW'; got: $(echo "$T08_OUT" | head -3)"
fi
rm -rf "$T08_REPO"

# ---------------------------------------------------------------------------
# T09: W5 — require_state loads state-lib.sh
# ---------------------------------------------------------------------------
run_test "T09: W5 — require_state loads state-lib.sh"

T09_RESULT=$(
    source "$HOOKS_DIR/source-lib.sh" 2>/dev/null
    require_state 2>/dev/null
    type state_update &>/dev/null && echo "LOADED" || echo "NOT_LOADED"
)

if [[ "$T09_RESULT" == "LOADED" ]]; then
    pass_test
else
    fail_test "state_update not available after require_state"
fi

# ---------------------------------------------------------------------------
# T10: W5 — dual-write from write_proof_status to state.json
# ---------------------------------------------------------------------------
run_test "T10: W5 — write_proof_status dual-writes to state.json"

T10_REPO=$(make_temp_repo)
T10_TRACE=$(mktemp -d)

(
    export CLAUDE_PROJECT_DIR="$T10_REPO"
    export CLAUDE_DIR="$T10_REPO/.claude"
    export TRACE_STORE="$T10_TRACE"
    export CLAUDE_SESSION_ID="test10-$$"
    source "$HOOKS_DIR/log.sh" 2>/dev/null
    source "$HOOKS_DIR/state-lib.sh" 2>/dev/null
    write_proof_status "verified" "$T10_REPO" 2>/dev/null
)

T10_STATE="$T10_REPO/.claude/state.json"
if [[ -f "$T10_STATE" ]]; then
    T10_VAL=$(jq -r '.proof.status // empty' "$T10_STATE" 2>/dev/null)
    if [[ "$T10_VAL" == "verified" ]]; then
        pass_test
    else
        fail_test "state.json proof.status='$T10_VAL', expected 'verified'"
    fi
else
    fail_test "state.json not created by write_proof_status"
fi
rm -rf "$T10_REPO" "$T10_TRACE"

# ---------------------------------------------------------------------------
# T11: Robustness — read_test_status handles non-numeric TEST_TIME
# ---------------------------------------------------------------------------
run_test "T11: Robustness — read_test_status handles non-numeric TEST_TIME"

T11_REPO=$(mktemp -d)
mkdir -p "$T11_REPO/.claude"
echo "pass|info|not-a-number" > "$T11_REPO/.claude/.test-status"

T11_RESULT=$(
    source "$HOOKS_DIR/source-lib.sh" 2>/dev/null
    if read_test_status "$T11_REPO" 2>/dev/null; then
        echo "OK:${TEST_RESULT}:${TEST_AGE}"
    else
        echo "FAIL"
    fi
)

if [[ "$T11_RESULT" == "OK:pass:"* ]]; then
    pass_test
else
    fail_test "read_test_status crashed or returned wrong result: '$T11_RESULT'"
fi
rm -rf "$T11_REPO"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================"
echo "Proof Lifecycle Tests: $PASS_COUNT passed, $FAIL_COUNT failed"
echo "============================================"

[[ "$FAIL_COUNT" -eq 0 ]] && exit 0 || exit 1
