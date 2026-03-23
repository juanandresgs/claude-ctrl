#!/usr/bin/env bash
set -euo pipefail

# Async background test runner after file changes.
# PostToolUse hook — matcher: Write|Edit — async: true
#
# Detects and runs the project test suite in the background.
# Results are delivered on the next conversation turn via systemMessage.
# Does not block Claude's flow (Sacred Practices 4 & 5: testing).
#
# Detection: scans project root for test framework config, runs appropriate suite.
# Skips non-source files and files in non-source directories.

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

HOOK_INPUT=$(read_input)
FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

# Exit silently if no file path or file doesn't exist
[[ -z "$FILE_PATH" ]] && exit 0
[[ ! -f "$FILE_PATH" ]] && exit 0

# Only run tests for source files (uses shared SOURCE_EXTENSIONS from context-lib.sh)
is_source_file "$FILE_PATH" || exit 0

# Skip non-source directories
is_skippable_path "$FILE_PATH" && exit 0
[[ "$FILE_PATH" =~ \.claude ]] && exit 0

PROJECT_ROOT=$(detect_project_root)

# --- Detect test runner ---
detect_test_runner() {
    local root="$1"
    local file="$2"
    local ext="${file##*.}"

    # Python
    if [[ "$ext" == "py" ]]; then
        if [[ -f "$root/pyproject.toml" ]] && grep -q '\[tool\.pytest\]' "$root/pyproject.toml" 2>/dev/null; then
            echo "pytest"
            return
        fi
        if [[ -f "$root/setup.cfg" ]] && grep -q '\[tool:pytest\]' "$root/setup.cfg" 2>/dev/null; then
            echo "pytest"
            return
        fi
        if [[ -d "$root/tests" || -d "$root/test" ]]; then
            echo "pytest"
            return
        fi
    fi

    # JavaScript/TypeScript
    if [[ "$ext" =~ ^(ts|tsx|js|jsx)$ ]]; then
        if [[ -f "$root/vitest.config.ts" || -f "$root/vitest.config.js" ]]; then
            echo "vitest"
            return
        fi
        if [[ -f "$root/jest.config.ts" || -f "$root/jest.config.js" || -f "$root/jest.config.cjs" ]]; then
            echo "jest"
            return
        fi
        if [[ -f "$root/package.json" ]] && grep -q '"test"' "$root/package.json" 2>/dev/null; then
            echo "npm-test"
            return
        fi
    fi

    # Rust
    if [[ "$ext" == "rs" && -f "$root/Cargo.toml" ]]; then
        echo "cargo-test"
        return
    fi

    # Go
    if [[ "$ext" == "go" && -f "$root/go.mod" ]]; then
        echo "go-test"
        return
    fi

    echo "none"
}

RUNNER=$(detect_test_runner "$PROJECT_ROOT" "$FILE_PATH")
[[ "$RUNNER" == "none" ]] && exit 0

# --- Cooldown: skip if last run was <10 seconds ago ---
LOCK_DIR="${PROJECT_ROOT}/.claude"
LAST_RUN_FILE="${LOCK_DIR}/.test-runner.last-run"
mkdir -p "$LOCK_DIR"

if [[ -f "$LAST_RUN_FILE" ]]; then
    LAST_RUN=$(cat "$LAST_RUN_FILE" 2>/dev/null || echo "0")
    NOW=$(date +%s)
    ELAPSED=$(( NOW - LAST_RUN ))
    if [[ "$ELAPSED" -lt 10 ]]; then
        exit 0
    fi
fi

# --- Lock file: ensure only one test process per project ---
LOCK_FILE="${LOCK_DIR}/.test-runner.lock"

# Kill previous test run if still active
if [[ -f "$LOCK_FILE" ]]; then
    OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
        # Kill child processes first (vitest workers, pytest workers, etc.)
        pkill -P "$OLD_PID" 2>/dev/null || true
        # Then kill the parent
        kill "$OLD_PID" 2>/dev/null || true
        wait "$OLD_PID" 2>/dev/null || true
    fi
    rm -f "$LOCK_FILE"
fi

# Track the test subprocess PID for targeted cleanup
TEST_PID=""

# Write our PID and clean up on exit (both lock file and test subprocess)
echo $$ > "$LOCK_FILE"
trap '{
    # Kill the test subprocess and its children if still running
    if [[ -n "$TEST_PID" ]] && kill -0 "$TEST_PID" 2>/dev/null; then
        pkill -P "$TEST_PID" 2>/dev/null || true
        kill "$TEST_PID" 2>/dev/null || true
    fi
    rm -f "$LOCK_FILE"
}' EXIT

# Debounce: let rapid writes settle before running tests.
# Since this hook is async, this doesn't block Claude.
# If another write fires during this sleep, the lock mechanism above
# will kill us before we start the actual test run.
sleep 2

# Re-check lock — if we were superseded during debounce, exit quietly
if [[ -f "$LOCK_FILE" ]]; then
    CURRENT_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [[ "$CURRENT_PID" != "$$" ]]; then
        exit 0
    fi
fi

# --- Run tests ---
run_tests() {
    local runner="$1"
    local root="$2"
    local file="$3"

    case "$runner" in
        pytest)
            if command -v pytest &>/dev/null; then
                cd "$root" && pytest --tb=short -q 2>&1 | tail -20
            fi
            ;;
        vitest)
            if [[ -f "$root/node_modules/.bin/vitest" ]]; then
                cd "$root" && npx vitest run --reporter=verbose 2>&1 | tail -30
            fi
            ;;
        jest)
            if [[ -f "$root/node_modules/.bin/jest" ]]; then
                cd "$root" && npx jest --bail 2>&1 | tail -30
            fi
            ;;
        npm-test)
            cd "$root" && npm test 2>&1 | tail -30
            ;;
        cargo-test)
            if command -v cargo &>/dev/null; then
                cd "$root" && cargo test 2>&1 | tail -30
            fi
            ;;
        go-test)
            if command -v go &>/dev/null; then
                cd "$root" && go test ./... 2>&1 | tail -30
            fi
            ;;
    esac
}

# Run tests in a subshell and capture PID for targeted cleanup
run_tests "$RUNNER" "$PROJECT_ROOT" "$FILE_PATH" > "${LOCK_DIR}/.test-runner.out" 2>&1 &
TEST_PID=$!
wait "$TEST_PID" 2>/dev/null || true
TEST_EXIT=$?
TEST_OUTPUT=$(cat "${LOCK_DIR}/.test-runner.out" 2>/dev/null || echo "")
rm -f "${LOCK_DIR}/.test-runner.out"

# Write cooldown timestamp
date +%s > "$LAST_RUN_FILE"

# --- Write test status for test-gate.sh and guard.sh ---
TEST_STATUS_FILE="${PROJECT_ROOT}/.claude/.test-status"
if [[ "$TEST_EXIT" -ne 0 ]]; then
    FAIL_COUNT=$(echo "$TEST_OUTPUT" | grep -cE '(FAIL|FAILED|ERROR|fail)' || echo "1")
    [[ "$FAIL_COUNT" -eq 0 ]] && FAIL_COUNT=1
    echo "fail|${FAIL_COUNT}|$(date +%s)" > "$TEST_STATUS_FILE"
    # Audit trail
    append_audit "$PROJECT_ROOT" "test_fail" "${RUNNER}: ${FAIL_COUNT} failures"
else
    echo "pass|0|$(date +%s)" > "$TEST_STATUS_FILE"
fi

# --- Report results ---
if [[ "$TEST_EXIT" -ne 0 ]]; then
    ESCAPED=$(echo "Test failures detected ($RUNNER):\n$TEST_OUTPUT" | jq -Rs .)
    cat <<EOF
{
  "systemMessage": $ESCAPED
}
EOF
else
    ESCAPED=$(echo "Tests passed ($RUNNER)" | jq -Rs .)
    cat <<EOF
{
  "systemMessage": $ESCAPED
}
EOF
fi

exit 0
