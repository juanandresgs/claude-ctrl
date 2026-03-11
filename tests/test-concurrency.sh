#!/usr/bin/env bash
# test-concurrency.sh — Concurrency and state management tests for Phase 1+2
#
# Validates all locking and CAS mechanisms introduced in W1-0 through W2-5:
#   - _lock_fd() platform-native locking primitive (core-lib.sh)
#   - write_proof_status() and state_update() use _lock_fd for serialization
#   - cas_proof_status() true atomic CAS — single lock across check-and-write
#   - write_proof_status() monotonic lattice (log.sh)
#   - is_protected_state_file() registry lookup (core-lib.sh)
#   - _PROTECTED_STATE_FILES registry (core-lib.sh)
#   - Gate 0 pre-write.sh registry-based denial
#   - Gate C.2 task-track.sh routes through write_proof_status()
#
# @decision DEC-CONCURRENCY-TEST-001
# @title Targeted concurrency test suite for Phase 1+2 locking and CAS mechanisms
# @status accepted
# @rationale The Phase 1/2 work items introduce concurrency primitives: _lock_fd
#   (W1-0), state_write_locked (W1-1, removed W2-4), cas_proof_status atomic rewrite
#   (W2-2), and Gate C.2 routing (W2-3). Unit-testing them in isolation provides
#   faster feedback than running the full e2e test suite. Tests source hook libs
#   directly (no mocks) and use isolated tmp directories to avoid cross-test
#   contamination. W2-4 removed state_write_locked() — T02-T04 were replaced with
#   _lock_fd wiring tests (T02, T03) and source-level verification (T04, T05).
#   CAS atomicity tests (T06, T07) validate W2-2's single-lock design.
#
# Usage: bash tests/test-concurrency.sh
# Scope: --scope concurrency in run-hooks.sh

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"

# Ensure tmp directory exists
mkdir -p "$PROJECT_ROOT/tmp"

# ---------------------------------------------------------------------------
# Test tracking
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "Running: $test_name"
}

pass_test() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  PASS"
}

fail_test() {
    local reason="$1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $reason"
}

# ---------------------------------------------------------------------------
# Setup: isolated temp dir, cleaned up on EXIT
# ---------------------------------------------------------------------------
TMPDIR_BASE="$PROJECT_ROOT/tmp/test-concurrency-$$"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------------------------------------------------------------------------
# Helper: make a clean isolated environment with git repo + .claude dir
# Returns path via stdout
# ---------------------------------------------------------------------------
make_temp_env() {
    local dir
    dir="$TMPDIR_BASE/env-$RANDOM"
    mkdir -p "$dir/.claude"
    git -C "$dir" init -q 2>/dev/null || true
    echo "$dir"
}

# ---------------------------------------------------------------------------
# Helper: compute project_hash — same as log.sh / core-lib.sh
# ---------------------------------------------------------------------------
compute_phash() {
    echo "$1" | shasum -a 256 | cut -c1-8 2>/dev/null || echo "00000000"
}

# ---------------------------------------------------------------------------
# Source hook libraries for unit-style testing
# ---------------------------------------------------------------------------
# Pre-set _HOOK_NAME to avoid unbound variable error in source-lib.sh EXIT trap
_HOOK_NAME="test-concurrency"
# Source log.sh first (provides write_proof_status, detect_project_root, etc.)
source "$HOOKS_DIR/log.sh" 2>/dev/null
# Source source-lib.sh (provides require_state, _lock_fd, core-lib.sh)
source "$HOOKS_DIR/source-lib.sh" 2>/dev/null
# Load state-lib.sh
require_state


# ===========================================================================
# T01: Sequential state_update() — no data loss across multiple writes
#
# Two sequential state_update() calls both succeed; state.json retains both keys.
# Validates DEC-STATE-002 flock-protected read-modify-write core invariant:
# each write must preserve prior keys (no overwrite of state.json structure).
#
# NOTE on parallelism: state_update uses _lock_fd for serialization. On macOS
# and Linux, _lock_fd is always available (lockf / flock). The core invariant
# tested here — that each state_update call preserves the full prior state —
# holds because each call does a full jq read-modify-write, not a merge.
# ===========================================================================
run_test "T01: state_update() — sequential writes both land, no data loss"

T01_ENV=$(make_temp_env)
T01_CLAUDE="$T01_ENV/.claude"

export CLAUDE_DIR="$T01_CLAUDE"
export PROJECT_ROOT="$T01_ENV"
export CLAUDE_SESSION_ID="t01-session-$$"
export _HOOK_NAME="test-concurrency"

state_update ".concurrent.key_a" "value_a" "test-t01" 2>/dev/null || true
state_update ".concurrent.key_b" "value_b" "test-t01" 2>/dev/null || true

# With SQLite WAL backend, state is in state.db — verify via state_read()
# (state.json no longer created by state_update; storage backend is SQLite)
STATE_DB="$T01_CLAUDE/state/state.db"
if [[ -f "$STATE_DB" ]]; then
    KEY_A=$(state_read ".concurrent.key_a" 2>/dev/null || echo "")
    KEY_B=$(state_read ".concurrent.key_b" 2>/dev/null || echo "")
    if [[ "$KEY_A" == "value_a" && "$KEY_B" == "value_b" ]]; then
        pass_test
    else
        fail_test "Expected both keys in state.db; key_a='$KEY_A' key_b='$KEY_B'"
    fi
else
    fail_test "state.db not created at $STATE_DB"
fi

# Reset exported vars to avoid leaking into subsequent tests
# Note: _HOOK_NAME must NOT be unset — source-lib.sh's EXIT trap references it
# without a :- default, and with set -u active that would re-trigger the EXIT trap.
# Clear _WORKFLOW_ID and _STATE_SCHEMA_INITIALIZED caches — T01 calls state_update
# at top level which caches both. Without clearing, subsequent tests using a different
# CLAUDE_DIR will: (a) use T01's workflow_id for their state writes, and (b) skip DB
# schema initialization for the new DB (since the guard already fired for T01's DB).
unset CLAUDE_DIR PROJECT_ROOT CLAUDE_SESSION_ID 2>/dev/null || true
_WORKFLOW_ID=""
_STATE_SCHEMA_INITIALIZED=""


# ===========================================================================
# T02: _lock_fd — lock acquisition succeeds (lockf works on macOS)
#
# Validates that _lock_fd can acquire a lock on an uncontested file.
# This is the baseline platform-native locking test (DEC-LOCK-NATIVE-001).
# ===========================================================================
run_test "T02: _lock_fd — lock acquisition succeeds on uncontested file"

T02_LOCK=$(mktemp "$TMPDIR_BASE/t02-lockfile-XXXXXX")

if type _lock_fd &>/dev/null; then
    T02_RESULT=0
    (
        _lock_fd 5 9 || exit 1
        # Successfully acquired lock — write a sentinel
        echo "acquired" > "$T02_LOCK"
        exit 0
    ) 9>"$T02_LOCK" || T02_RESULT=$?

    if [[ "$T02_RESULT" -eq 0 ]]; then
        pass_test
    else
        fail_test "_lock_fd failed to acquire uncontested lock; exit=$T02_RESULT"
    fi
else
    echo "  NOTE: _lock_fd not available — skip (core-lib.sh not sourced)"
    pass_test
fi

rm -f "$T02_LOCK" 2>/dev/null || true


# ===========================================================================
# T03: _lock_fd — returns failure when lock is already held (timeout)
#
# _lock_fd is the platform-native locking primitive in core-lib.sh (DEC-LOCK-NATIVE-001).
# This test validates it directly: hold a lock via _lock_fd in a background subshell,
# then attempt to acquire the same lock with a 1s timeout — must fail.
# ===========================================================================
run_test "T03: _lock_fd — returns failure when lock is already held (1s timeout)"

T03_LOCK=$(mktemp "$TMPDIR_BASE/t03-lockfile-XXXXXX")

# Check if _lock_fd is available (it's exported from core-lib.sh)
if type _lock_fd &>/dev/null; then
    # Hold the lock in background for 3 seconds
    (
        _lock_fd 10 9
        sleep 3
    ) 9>"$T03_LOCK" &
    BG_LOCK_PID=$!

    # Give the background process time to acquire
    sleep 0.2

    # Attempt to acquire the same lock with 1s timeout — must fail
    T03_RESULT=0
    (
        _lock_fd 1 9 || exit 1
        exit 0
    ) 9>"$T03_LOCK" || T03_RESULT=$?

    # Clean up
    kill "$BG_LOCK_PID" 2>/dev/null || true
    wait "$BG_LOCK_PID" 2>/dev/null || true

    if [[ "$T03_RESULT" -ne 0 ]]; then
        pass_test
    else
        fail_test "_lock_fd should fail when lock is held; got exit=0 (lock not actually blocking)"
    fi
else
    echo "  NOTE: _lock_fd not available — skip (core-lib.sh not sourced)"
    pass_test
fi

rm -f "$T03_LOCK" 2>/dev/null || true


# ===========================================================================
# T04: write_proof_status() uses _lock_fd — source-level verification
#
# Verifies that write_proof_status() in log.sh uses _lock_fd (not bare flock or
# _portable_flock). This ensures the canonical write function uses the platform-
# native locking primitive that is available on both macOS and Linux.
# ===========================================================================
run_test "T04: write_proof_status() uses proof_state_set (SQLite, W5-2)"

# W5-2: write_proof_status no longer uses _lock_fd. It calls proof_state_set()
# which uses SQLite's BEGIN IMMEDIATE for atomicity. Verify the function delegates
# to proof_state_set (not raw flat-file writes).
LOG_SH="$HOOKS_DIR/log.sh"
if [[ -f "$LOG_SH" ]]; then
    if grep -A 30 '^write_proof_status()' "$LOG_SH" | grep -q 'proof_state_set'; then
        pass_test
    else
        fail_test "write_proof_status() does not call proof_state_set in $LOG_SH"
    fi
else
    fail_test "log.sh not found at $LOG_SH"
fi


# ===========================================================================
# T05: state_update() SQLite WAL concurrency — two concurrent writes both succeed
#
# SQLite WAL replaced flock serialization (DEC-SQLITE-001). state_update() no
# longer calls _lock_fd; SQLite's busy_timeout=5000ms handles contention
# transparently via WAL mode. This test verifies the WAL concurrency guarantee:
# two concurrent state_update() calls on different keys both succeed and
# state.db is created by the SQLite backend.
#
# Uses helper scripts (not subshells) to avoid set -euo pipefail inheritance
# that would cause background processes to exit before writing result files.
# ===========================================================================
run_test "T05: state_update() SQLite WAL — two concurrent writes both succeed"

T05_ENV=$(make_temp_env)
T05_CLAUDE="$T05_ENV/.claude"
T05_RESULT_A="$TMPDIR_BASE/t05-result-a"
T05_RESULT_B="$TMPDIR_BASE/t05-result-b"

# Helper script: sources libs in a clean (non-set-e) context, runs state_update
T05_HELPER="$TMPDIR_BASE/t05-helper.sh"
cat > "$T05_HELPER" <<T05_HELPER_EOF
#!/usr/bin/env bash
# T05 helper: run a single state_update and write exit code to result file
HOOKS_DIR="\$1"
CLAUDE_DIR="\$2"
PROJECT_ROOT="\$3"
CLAUDE_SESSION_ID="\$4"
KEY="\$5"
VALUE="\$6"
RESULT_FILE="\$7"
export CLAUDE_DIR PROJECT_ROOT CLAUDE_SESSION_ID
export _HOOK_NAME="test-concurrency"
source "\$HOOKS_DIR/log.sh" 2>/dev/null
source "\$HOOKS_DIR/source-lib.sh" 2>/dev/null
require_state 2>/dev/null
state_update "\$KEY" "\$VALUE" "test-t05" 2>/dev/null
echo \$? > "\$RESULT_FILE"
T05_HELPER_EOF
chmod +x "$T05_HELPER"

bash "$T05_HELPER" "$HOOKS_DIR" "$T05_CLAUDE" "$T05_ENV" "t05-session-a-$$" ".concurrent.slot_a" "from_a" "$T05_RESULT_A" &
T05_PID_A=$!
bash "$T05_HELPER" "$HOOKS_DIR" "$T05_CLAUDE" "$T05_ENV" "t05-session-b-$$" ".concurrent.slot_b" "from_b" "$T05_RESULT_B" &
T05_PID_B=$!

wait "$T05_PID_A" 2>/dev/null || true
wait "$T05_PID_B" 2>/dev/null || true

T05_EXIT_A=$(cat "$T05_RESULT_A" 2>/dev/null || echo "missing")
T05_EXIT_B=$(cat "$T05_RESULT_B" 2>/dev/null || echo "missing")

# Verify state.db was created (SQLite backend active)
STATE_DB="$T05_CLAUDE/state/state.db"
if [[ "$T05_EXIT_A" == "0" && "$T05_EXIT_B" == "0" && -f "$STATE_DB" ]]; then
    pass_test
else
    fail_test "Expected both concurrent writes to succeed; exit_a=$T05_EXIT_A exit_b=$T05_EXIT_B state_db_exists=$([ -f "$STATE_DB" ] && echo yes || echo no)"
fi

unset CLAUDE_DIR PROJECT_ROOT CLAUDE_SESSION_ID 2>/dev/null || true


# ===========================================================================
# T06: proof_state_set() — SQLite atomic CAS: two concurrent writes both succeed
#      (last-write-wins within lattice — both advancing to "verified" are safe)
#
# W5-2 update: Old flock-based CAS tests removed. SQLite's BEGIN IMMEDIATE
# provides internal atomicity. Two concurrent proof_state_set("verified") calls
# are both valid (lattice allows pending→verified); SQLite serializes them.
# Post-condition: proof state = "verified" in SQLite.
# ===========================================================================
run_test "T06: proof_state_set() — SQLite CAS: concurrent verified writes both succeed"

T06_ENV=$(make_temp_env)
T06_CLAUDE="$T06_ENV/.claude"
mkdir -p "$TMPDIR_BASE/traces-t06"

# Helper script for concurrent SQLite proof_state_set
T06_HELPER="$TMPDIR_BASE/t06-helper.sh"
cat > "$T06_HELPER" <<T06_HELPER_EOF
#!/usr/bin/env bash
HOOKS_DIR="\$1"
CLAUDE_DIR="\$2"
PROJECT_ROOT="\$3"
CLAUDE_SESSION_ID="\$4"
RESULT_FILE="\$5"
export CLAUDE_DIR PROJECT_ROOT CLAUDE_SESSION_ID
source "\$HOOKS_DIR/core-lib.sh" 2>/dev/null
source "\$HOOKS_DIR/log.sh" 2>/dev/null
source "\$HOOKS_DIR/state-lib.sh" 2>/dev/null
proof_state_set "verified" "t06-concurrent" 2>/dev/null
echo \$? > "\$RESULT_FILE"
T06_HELPER_EOF
chmod +x "$T06_HELPER"

# Initialize to "pending" in SQLite
(
    export CLAUDE_DIR="$T06_CLAUDE"
    export PROJECT_ROOT="$T06_ENV"
    export CLAUDE_SESSION_ID="t06-setup-$$"
    source "$HOOKS_DIR/core-lib.sh" 2>/dev/null
    source "$HOOKS_DIR/log.sh" 2>/dev/null
    source "$HOOKS_DIR/state-lib.sh" 2>/dev/null
    proof_state_set "pending" "t06-setup" 2>/dev/null || true
) 2>/dev/null

RESULT_A_FILE="$TMPDIR_BASE/t06-result-a"
RESULT_B_FILE="$TMPDIR_BASE/t06-result-b"

bash "$T06_HELPER" "$HOOKS_DIR" "$T06_CLAUDE" "$T06_ENV" "t06-a-$$" "$RESULT_A_FILE" 2>/dev/null &
PID_A=$!
bash "$T06_HELPER" "$HOOKS_DIR" "$T06_CLAUDE" "$T06_ENV" "t06-b-$$" "$RESULT_B_FILE" 2>/dev/null &
PID_B=$!

wait "$PID_A" 2>/dev/null || true
wait "$PID_B" 2>/dev/null || true

T06_DB="$T06_CLAUDE/state/state.db"
FINAL_STATUS_T06=""
if [[ -f "$T06_DB" ]]; then
    FINAL_STATUS_T06=$(sqlite3 "$T06_DB" \
        "SELECT status FROM proof_state LIMIT 1;" 2>/dev/null || echo "")
fi

if [[ "$FINAL_STATUS_T06" == "verified" ]]; then
    pass_test
else
    RESULT_A=$(cat "$RESULT_A_FILE" 2>/dev/null || echo "missing")
    RESULT_B=$(cat "$RESULT_B_FILE" 2>/dev/null || echo "missing")
    fail_test "Expected proof state=verified in SQLite; got: '${FINAL_STATUS_T06}' (A=${RESULT_A} B=${RESULT_B})"
fi

unset CLAUDE_DIR PROJECT_ROOT TRACE_STORE CLAUDE_SESSION_ID 2>/dev/null || true


# ===========================================================================
# T07: proof_state_set() — lattice rejects regression (verified → needs-verification)
#
# W5-2: SQLite is sole authority. proof_state_set() enforces the monotonic
# lattice via BEGIN IMMEDIATE. Setting "needs-verification" (ordinal 1) after
# "verified" (ordinal 3) must fail with non-zero exit. The state must remain
# "verified" in SQLite.
# ===========================================================================
run_test "T07: proof_state_set() — lattice rejects regression (verified->needs-verification)"

T07_ENV=$(make_temp_env)
T07_CLAUDE="$T07_ENV/.claude"
mkdir -p "$TMPDIR_BASE/traces-t07"

# Step 1: set state to "verified"
(
    export CLAUDE_DIR="$T07_CLAUDE"
    export PROJECT_ROOT="$T07_ENV"
    export TRACE_STORE="$TMPDIR_BASE/traces-t07"
    export CLAUDE_SESSION_ID="t07-session-$$"
    _STATE_SCHEMA_INITIALIZED=""  # New DB — clear schema init guard
    _WORKFLOW_ID=""               # New project — clear workflow_id cache
    proof_state_set "verified" "t07-setup" 2>/dev/null
) 2>/dev/null || true

# Step 2: attempt regression to "needs-verification" — must fail
T07_REGRESS_RESULT=0
(
    export CLAUDE_DIR="$T07_CLAUDE"
    export PROJECT_ROOT="$T07_ENV"
    export TRACE_STORE="$TMPDIR_BASE/traces-t07"
    export CLAUDE_SESSION_ID="t07-session-$$"
    proof_state_set "needs-verification" "t07-regress" 2>/dev/null
) 2>/dev/null || T07_REGRESS_RESULT=$?

# Step 3: confirm state is still "verified" in SQLite
T07_FINAL_STATE=$(
    export CLAUDE_DIR="$T07_CLAUDE"
    export PROJECT_ROOT="$T07_ENV"
    export TRACE_STORE="$TMPDIR_BASE/traces-t07"
    export CLAUDE_SESSION_ID="t07-session-$$"
    proof_state_get 2>/dev/null | cut -d'|' -f1 || echo "unknown"
)

if [[ "$T07_REGRESS_RESULT" -ne 0 ]] && [[ "$T07_FINAL_STATE" == "verified" ]]; then
    pass_test
else
    fail_test "Lattice regression should be rejected; exit=${T07_REGRESS_RESULT} final_state=${T07_FINAL_STATE}"
fi

unset CLAUDE_DIR PROJECT_ROOT TRACE_STORE CLAUDE_SESSION_ID 2>/dev/null || true


# ===========================================================================
# T08: Gate C.2 — task-track.sh calls proof_state_set() (not bare echo, not flat-file write)
#
# W5-2: task-track.sh was migrated from write_proof_status() to proof_state_set()
# directly, bypassing the flat-file wrapper. Validates the SQLite API is called
# at Gate C.2 and no direct dotfile I/O remains.
# ===========================================================================
run_test "T08: Gate C.2 — task-track.sh calls proof_state_set() directly (W5-2)"

TASK_TRACK="$HOOKS_DIR/task-track.sh"
if [[ -f "$TASK_TRACK" ]]; then
    # Must call proof_state_set at Gate C.2
    if grep -q 'proof_state_set' "$TASK_TRACK"; then
        # Must NOT bare-echo to proof-status flat files
        BARE_ECHO=$(grep -E 'echo.*proof-status|printf.*proof-status|>.*\.proof-status' "$TASK_TRACK" 2>/dev/null | grep -v '^\s*#' | grep -v 'PROOF_FILE=' | grep -v '\$PROOF_FILE' | head -1 || echo "")
        if [[ -z "$BARE_ECHO" ]]; then
            pass_test
        else
            fail_test "task-track.sh has bare write to proof-status: $BARE_ECHO"
        fi
    else
        fail_test "task-track.sh does not call proof_state_set()"
    fi
else
    fail_test "task-track.sh not found at $TASK_TRACK"
fi


# ===========================================================================
# T09: Lattice — forward transition allowed (none → needs-verification → verified)
#
# Validates proof_state_set() monotonic lattice allows forward progressions via
# SQLite. The canonical task-track → proof → guardian flow: needs-verification →
# pending → verified. All transitions must succeed.
# ===========================================================================
run_test "T09: Lattice — forward transition allowed (none -> needs-verification -> verified)"

T09_ENV=$(make_temp_env)
T09_CLAUDE="$T09_ENV/.claude"
mkdir -p "$TMPDIR_BASE/traces-t09"

LATTICE_FWD_RESULT=0
(
    export CLAUDE_DIR="$T09_CLAUDE"
    export PROJECT_ROOT="$T09_ENV"
    export TRACE_STORE="$TMPDIR_BASE/traces-t09"
    export CLAUDE_SESSION_ID="t09-session-$$"
    _STATE_SCHEMA_INITIALIZED=""  # New DB — clear schema init guard
    _WORKFLOW_ID=""               # New project — clear workflow_id cache
    proof_state_set "needs-verification" "t09" 2>/dev/null && \
    proof_state_set "pending" "t09" 2>/dev/null && \
    proof_state_set "verified" "t09" 2>/dev/null
) 2>/dev/null || LATTICE_FWD_RESULT=$?

T09_FINAL=$(
    export CLAUDE_DIR="$T09_CLAUDE"
    export PROJECT_ROOT="$T09_ENV"
    export TRACE_STORE="$TMPDIR_BASE/traces-t09"
    export CLAUDE_SESSION_ID="t09-session-$$"
    proof_state_get 2>/dev/null | cut -d'|' -f1 || echo ""
)
if [[ "$LATTICE_FWD_RESULT" -eq 0 ]] && [[ "$T09_FINAL" == "verified" ]]; then
    pass_test
else
    fail_test "Forward transition failed; exit=$LATTICE_FWD_RESULT final_state='$T09_FINAL'"
fi


# ===========================================================================
# T10: Lattice — regression rejected (verified → pending)
#
# After reaching 'verified', attempting to write 'pending' must fail (returns 1).
# W5-2: Uses proof_state_get() to verify state remains 'verified' in SQLite.
# ===========================================================================
run_test "T10: Lattice — regression rejected (verified -> pending fails)"

T10_ENV=$(make_temp_env)
T10_CLAUDE="$T10_ENV/.claude"
mkdir -p "$TMPDIR_BASE/traces-t10"

# First: establish verified status
(
    export CLAUDE_DIR="$T10_CLAUDE"
    export PROJECT_ROOT="$T10_ENV"
    export TRACE_STORE="$TMPDIR_BASE/traces-t10"
    export CLAUDE_SESSION_ID="t10-session-$$"
    _STATE_SCHEMA_INITIALIZED=""  # New DB — clear schema init guard
    _WORKFLOW_ID=""               # New project — clear workflow_id cache
    proof_state_set "verified" "t10-setup" 2>/dev/null
) 2>/dev/null || true

# Now attempt regression
REGRESSION_RESULT=0
(
    export CLAUDE_DIR="$T10_CLAUDE"
    export PROJECT_ROOT="$T10_ENV"
    export TRACE_STORE="$TMPDIR_BASE/traces-t10"
    export CLAUDE_SESSION_ID="t10-session-$$"
    proof_state_set "pending" "t10-regress" 2>/dev/null
) 2>/dev/null || REGRESSION_RESULT=$?

T10_STATUS=$(
    export CLAUDE_DIR="$T10_CLAUDE"
    export PROJECT_ROOT="$T10_ENV"
    export TRACE_STORE="$TMPDIR_BASE/traces-t10"
    export CLAUDE_SESSION_ID="t10-session-$$"
    proof_state_get 2>/dev/null | cut -d'|' -f1 || echo ""
)

if [[ "$REGRESSION_RESULT" -ne 0 ]] && [[ "$T10_STATUS" == "verified" ]]; then
    pass_test
else
    fail_test "Regression should be rejected; exit=$REGRESSION_RESULT status='$T10_STATUS'"
fi


# ===========================================================================
# T11: Lattice — proof_epoch_reset() allows regression (verified → none)
#
# W5-2: Epoch reset is now done via proof_epoch_reset() (SQLite), not by
# touching a .proof-epoch flat file. After proof_epoch_reset(), proof_state_set()
# with a lower ordinal must succeed.
# ===========================================================================
run_test "T11: Lattice — proof_epoch_reset() allows regression (verified -> none)"

T11_ENV=$(make_temp_env)
T11_CLAUDE="$T11_ENV/.claude"
mkdir -p "$TMPDIR_BASE/traces-t11"

# Step 1: write verified
(
    export CLAUDE_DIR="$T11_CLAUDE"
    export PROJECT_ROOT="$T11_ENV"
    export TRACE_STORE="$TMPDIR_BASE/traces-t11"
    export CLAUDE_SESSION_ID="t11-session-$$"
    _STATE_SCHEMA_INITIALIZED=""  # New DB — clear schema init guard
    _WORKFLOW_ID=""               # New project — clear workflow_id cache
    proof_state_set "verified" "t11-setup" 2>/dev/null
) 2>/dev/null || true

# Step 2: call proof_epoch_reset() — increments epoch in SQLite
(
    export CLAUDE_DIR="$T11_CLAUDE"
    export PROJECT_ROOT="$T11_ENV"
    export TRACE_STORE="$TMPDIR_BASE/traces-t11"
    export CLAUDE_SESSION_ID="t11-session-$$"
    proof_epoch_reset 2>/dev/null
) 2>/dev/null || true

# Step 3: attempt regression — should succeed due to epoch reset
EPOCH_RESET_RESULT=0
(
    export CLAUDE_DIR="$T11_CLAUDE"
    export PROJECT_ROOT="$T11_ENV"
    export TRACE_STORE="$TMPDIR_BASE/traces-t11"
    export CLAUDE_SESSION_ID="t11-session-$$"
    proof_state_set "none" "t11-regress" 2>/dev/null
) 2>/dev/null || EPOCH_RESET_RESULT=$?

T11_STATUS=$(
    export CLAUDE_DIR="$T11_CLAUDE"
    export PROJECT_ROOT="$T11_ENV"
    export TRACE_STORE="$TMPDIR_BASE/traces-t11"
    export CLAUDE_SESSION_ID="t11-session-$$"
    proof_state_get 2>/dev/null | cut -d'|' -f1 || echo "unknown"
)

if [[ "$EPOCH_RESET_RESULT" -eq 0 ]] && [[ "$T11_STATUS" == "none" ]]; then
    pass_test
else
    fail_test "Epoch reset should allow regression; exit=$EPOCH_RESET_RESULT status='$T11_STATUS'"
fi


# ===========================================================================
# T12: is_protected_state_file() — matches .proof-status, .test-status, .proof-epoch
#
# Validates the _PROTECTED_STATE_FILES registry for all documented protected files.
# ===========================================================================
run_test "T12: is_protected_state_file() — matches all protected file patterns"

T12_ERRORS=()

PROTECTED_PATHS=(
    "/some/path/.proof-status"
    "/some/path/.proof-status-abc12345"
    "/some/path/.test-status"
    "/some/path/.proof-epoch"
    "/some/path/.state.lock"
    "/some/path/.proof-status.lock"
)

for path in "${PROTECTED_PATHS[@]}"; do
    if is_protected_state_file "$path"; then
        : # expected to match
    else
        T12_ERRORS+=("$path should match but does not")
    fi
done

if [[ ${#T12_ERRORS[@]} -eq 0 ]]; then
    pass_test
else
    fail_test "Protected file misses: ${T12_ERRORS[*]}"
fi


# ===========================================================================
# T13: is_protected_state_file() — non-match for README.md and state.json
#
# These files must NOT be protected — they are regular writable files.
# ===========================================================================
run_test "T13: is_protected_state_file() — does not match non-protected files"

T13_ERRORS=()

NON_PROTECTED_PATHS=(
    "/some/path/README.md"
    "/some/path/state.json"
    "/some/path/hooks/pre-write.sh"
    "/some/path/main.py"
)

for path in "${NON_PROTECTED_PATHS[@]}"; do
    if is_protected_state_file "$path"; then
        T13_ERRORS+=("$path should NOT match but does")
    fi
done

if [[ ${#T13_ERRORS[@]} -eq 0 ]]; then
    pass_test
else
    fail_test "False positives: ${T13_ERRORS[*]}"
fi


# ===========================================================================
# T14: Gate 0 — Write to .proof-status denied by registry (existing fixture)
#
# Runs pre-write.sh with the write-proof-status-deny.json fixture and verifies
# the hook returns a deny decision. Validates Gate 0 using registry.
# ===========================================================================
run_test "T14: Gate 0 — Write to .proof-status denied by registry (existing fixture)"

FIXTURE_DIR="$TEST_DIR/fixtures"
PRE_WRITE="$HOOKS_DIR/pre-write.sh"
FIXTURE="$FIXTURE_DIR/write-proof-status-deny.json"

if [[ ! -f "$FIXTURE" ]]; then
    fail_test "Fixture not found: $FIXTURE"
else
    OUTPUT=$(bash "$PRE_WRITE" < "$FIXTURE" 2>/dev/null) || true
    DECISION=$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")
    if [[ "$DECISION" == "deny" ]]; then
        pass_test
    else
        fail_test "Expected 'deny' from Gate 0; got: '${DECISION:-no output}'"
    fi
fi


# ===========================================================================
# T15: Gate 0 — Write to .proof-epoch denied via registry (new fixture)
#
# Runs pre-write.sh with the write-proof-epoch-deny.json fixture and verifies
# the hook returns a deny decision. Validates new .proof-epoch is in registry.
# ===========================================================================
run_test "T15: Gate 0 — Write to .proof-epoch denied via registry (new fixture)"

EPOCH_FIXTURE="$FIXTURE_DIR/write-proof-epoch-deny.json"

if [[ ! -f "$EPOCH_FIXTURE" ]]; then
    fail_test "Fixture not found: $EPOCH_FIXTURE"
else
    EPOCH_OUTPUT=$(bash "$PRE_WRITE" < "$EPOCH_FIXTURE" 2>/dev/null) || true
    EPOCH_DECISION=$(echo "$EPOCH_OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")
    if [[ "$EPOCH_DECISION" == "deny" ]]; then
        pass_test
    else
        fail_test "Expected 'deny' from Gate 0 for .proof-epoch; got: '${EPOCH_DECISION:-no output}'"
    fi
fi


# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "==========================="
echo "Concurrency Tests: $TESTS_RUN run | $TESTS_PASSED passed | $TESTS_FAILED failed"
echo "==========================="

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
