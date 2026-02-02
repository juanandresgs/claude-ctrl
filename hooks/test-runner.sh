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

HOOK_INPUT=$(read_input)
FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

# Exit silently if no file path or file doesn't exist
[[ -z "$FILE_PATH" ]] && exit 0
[[ ! -f "$FILE_PATH" ]] && exit 0

# Only run tests for source files
[[ ! "$FILE_PATH" =~ \.(ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php)$ ]] && exit 0

# Skip non-source directories
[[ "$FILE_PATH" =~ (node_modules|vendor|dist|build|\.next|__pycache__|\.git|\.claude) ]] && exit 0

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

TEST_OUTPUT=$(run_tests "$RUNNER" "$PROJECT_ROOT" "$FILE_PATH" 2>&1) || TEST_EXIT=$?
TEST_EXIT="${TEST_EXIT:-0}"

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
