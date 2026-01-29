#!/usr/bin/env bash
set -euo pipefail

# Auto-detect and run project linter on modified files.
# PostToolUse hook — matcher: Write|Edit
#
# Highest-impact hook: creates feedback loops where lint errors feed back
# into Claude via exit code 2, triggering automatic fixes.
#
# Detection: scans project root for linter config files, caches result.
# Runs lint on the specific file only (fast, under 10 seconds).
# If no linter detected, exits 0 silently.

source "$(dirname "$0")/log.sh"

HOOK_INPUT=$(read_input)
FILE_PATH=$(get_field '.tool_input.file_path')

# Exit silently if no file path or file doesn't exist
[[ -z "$FILE_PATH" ]] && exit 0
[[ ! -f "$FILE_PATH" ]] && exit 0

# Only lint source files
[[ ! "$FILE_PATH" =~ \.(ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh)$ ]] && exit 0

# Skip non-source directories
[[ "$FILE_PATH" =~ (node_modules|vendor|dist|build|\.next|__pycache__|\.git) ]] && exit 0

# --- Detect project root ---
PROJECT_ROOT=$(detect_project_root)

# --- Linter detection with caching ---
CACHE_KEY=$(echo "$PROJECT_ROOT" | md5 2>/dev/null || echo "$PROJECT_ROOT" | md5sum 2>/dev/null | cut -d' ' -f1)
CACHE_FILE="/tmp/claude-lint-cache-${CACHE_KEY}"

detect_linter() {
    local root="$1"
    local file="$2"
    local ext="${file##*.}"

    # Python files
    if [[ "$ext" == "py" ]]; then
        if [[ -f "$root/pyproject.toml" ]] && grep -q '\[tool\.ruff\]' "$root/pyproject.toml" 2>/dev/null; then
            echo "ruff"
            return
        fi
        if [[ -f "$root/pyproject.toml" ]] && grep -q '\[tool\.black\]' "$root/pyproject.toml" 2>/dev/null; then
            echo "black"
            return
        fi
        if [[ -f "$root/setup.cfg" ]] && grep -q '\[flake8\]' "$root/setup.cfg" 2>/dev/null; then
            echo "flake8"
            return
        fi
    fi

    # JavaScript/TypeScript files
    if [[ "$ext" =~ ^(ts|tsx|js|jsx)$ ]]; then
        if [[ -f "$root/biome.json" || -f "$root/biome.jsonc" ]]; then
            echo "biome"
            return
        fi
        if [[ -f "$root/package.json" ]] && grep -q '"eslint"' "$root/package.json" 2>/dev/null; then
            echo "eslint"
            return
        fi
        # Check for prettier (standalone or as dependency)
        if ls "$root"/.prettierrc* 1>/dev/null 2>&1; then
            echo "prettier"
            return
        fi
        if [[ -f "$root/package.json" ]] && grep -q '"prettier"' "$root/package.json" 2>/dev/null; then
            echo "prettier"
            return
        fi
    fi

    # Rust files
    if [[ "$ext" == "rs" && -f "$root/Cargo.toml" ]]; then
        echo "clippy"
        return
    fi

    # Go files
    if [[ "$ext" == "go" ]]; then
        if [[ -f "$root/.golangci.yml" || -f "$root/.golangci.yaml" ]]; then
            echo "golangci-lint"
            return
        fi
        if [[ -f "$root/go.mod" ]]; then
            echo "govet"
            return
        fi
    fi

    # Makefile with lint target (fallback)
    if [[ -f "$root/Makefile" ]] && grep -q '^lint:' "$root/Makefile" 2>/dev/null; then
        echo "make-lint"
        return
    fi

    echo "none"
}

# Check cache or detect
if [[ -f "$CACHE_FILE" ]]; then
    LINTER=$(cat "$CACHE_FILE")
else
    LINTER=$(detect_linter "$PROJECT_ROOT" "$FILE_PATH")
    echo "$LINTER" > "$CACHE_FILE"
fi

# No linter detected — exit silently
[[ "$LINTER" == "none" ]] && exit 0

# --- Run linter ---
run_lint() {
    local linter="$1"
    local file="$2"
    local root="$3"

    case "$linter" in
        ruff)
            if command -v ruff &>/dev/null; then
                cd "$root" && ruff check --fix "$file" 2>&1 && ruff format "$file" 2>&1
            fi
            ;;
        black)
            if command -v black &>/dev/null; then
                cd "$root" && black "$file" 2>&1
            fi
            ;;
        flake8)
            if command -v flake8 &>/dev/null; then
                cd "$root" && flake8 "$file" 2>&1
            fi
            ;;
        biome)
            if command -v biome &>/dev/null; then
                cd "$root" && biome check --write "$file" 2>&1
            elif [[ -f "$root/node_modules/.bin/biome" ]]; then
                cd "$root" && npx biome check --write "$file" 2>&1
            fi
            ;;
        eslint)
            if [[ -f "$root/node_modules/.bin/eslint" ]]; then
                cd "$root" && npx eslint --fix "$file" 2>&1
            elif command -v eslint &>/dev/null; then
                cd "$root" && eslint --fix "$file" 2>&1
            fi
            ;;
        prettier)
            if [[ -f "$root/node_modules/.bin/prettier" ]]; then
                cd "$root" && npx prettier --write "$file" 2>&1
            elif command -v prettier &>/dev/null; then
                cd "$root" && prettier --write "$file" 2>&1
            fi
            ;;
        clippy)
            if command -v cargo &>/dev/null; then
                cd "$root" && cargo clippy -- -D warnings 2>&1
            fi
            ;;
        golangci-lint)
            if command -v golangci-lint &>/dev/null; then
                cd "$root" && golangci-lint run "$file" 2>&1
            fi
            ;;
        govet)
            if command -v go &>/dev/null; then
                cd "$root" && go vet "$file" 2>&1
            fi
            ;;
        make-lint)
            cd "$root" && make lint 2>&1
            ;;
    esac
}

# Run lint and capture result
LINT_OUTPUT=$(run_lint "$LINTER" "$FILE_PATH" "$PROJECT_ROOT" 2>&1) || LINT_EXIT=$?
LINT_EXIT="${LINT_EXIT:-0}"

if [[ "$LINT_EXIT" -ne 0 ]]; then
    # Lint failed — feed errors back to Claude via exit code 2
    echo "Lint errors ($LINTER) in $FILE_PATH:" >&2
    echo "$LINT_OUTPUT" >&2
    exit 2
fi

# Lint passed — silent success
exit 0
