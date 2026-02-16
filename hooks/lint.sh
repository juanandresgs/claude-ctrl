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
source "$(dirname "$0")/context-lib.sh"

HOOK_INPUT=$(read_input)
FILE_PATH=$(get_field '.tool_input.file_path')

# Exit silently if no file path or file doesn't exist
[[ -z "$FILE_PATH" ]] && exit 0
[[ ! -f "$FILE_PATH" ]] && exit 0

# Only lint source files (uses shared SOURCE_EXTENSIONS from context-lib.sh)
is_source_file "$FILE_PATH" || exit 0

# Skip non-source directories
is_skippable_path "$FILE_PATH" && exit 0

# --- Detect project root ---
PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)

# --- Linter detection with caching ---
# Cache in project .claude dir (not /tmp/ — Sacred Practice #3)
CACHE_DIR="$PROJECT_ROOT/.claude"
mkdir -p "$CACHE_DIR"
CACHE_FILE="$CACHE_DIR/.lint-cache"

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

# Check cache or detect (invalidate if config files are newer than cache)
CACHE_STALE=false
if [[ -f "$CACHE_FILE" ]]; then
    # Invalidate cache if any linter config file is newer than cache
    for cfg in "$PROJECT_ROOT/pyproject.toml" "$PROJECT_ROOT/setup.cfg" \
               "$PROJECT_ROOT/biome.json" "$PROJECT_ROOT/biome.jsonc" \
               "$PROJECT_ROOT/package.json" "$PROJECT_ROOT/Cargo.toml" \
               "$PROJECT_ROOT/.golangci.yml" "$PROJECT_ROOT/.golangci.yaml" \
               "$PROJECT_ROOT/go.mod" "$PROJECT_ROOT/Makefile"; do
        if [[ -f "$cfg" && "$cfg" -nt "$CACHE_FILE" ]]; then
            CACHE_STALE=true
            break
        fi
    done
    # Also invalidate .prettierrc* changes
    for cfg in "$PROJECT_ROOT"/.prettierrc*; do
        if [[ -f "$cfg" && "$cfg" -nt "$CACHE_FILE" ]]; then
            CACHE_STALE=true
            break
        fi
    done
fi

if [[ -f "$CACHE_FILE" && "$CACHE_STALE" == "false" ]]; then
    LINTER=$(cat "$CACHE_FILE")
else
    LINTER=$(detect_linter "$PROJECT_ROOT" "$FILE_PATH")
    echo "$LINTER" > "$CACHE_FILE"
fi

# No linter detected — exit silently
[[ "$LINTER" == "none" ]] && exit 0

# --- Circuit breaker: prevent runaway lint retry loops ---
BREAKER_FILE="${CLAUDE_DIR}/.lint-breaker"
if [[ -f "$BREAKER_FILE" ]]; then
    BREAKER_STATE=$(cut -d'|' -f1 "$BREAKER_FILE")
    BREAKER_COUNT=$(cut -d'|' -f2 "$BREAKER_FILE")
    BREAKER_TIME=$(cut -d'|' -f3 "$BREAKER_FILE")
    NOW=$(date +%s)
    ELAPSED=$(( NOW - BREAKER_TIME ))

    if [[ "$BREAKER_STATE" == "open" && "$ELAPSED" -lt 300 ]]; then
        # OPEN state: skip lint entirely
        cat <<BREAKER_EOF
{ "hookSpecificOutput": { "hookEventName": "PostToolUse",
    "additionalContext": "Lint circuit breaker OPEN ($BREAKER_COUNT consecutive failures). Skipping lint for $((300 - ELAPSED))s. Fix underlying lint issues to reset." } }
BREAKER_EOF
        exit 0
    elif [[ "$BREAKER_STATE" == "open" && "$ELAPSED" -ge 300 ]]; then
        # Timeout expired → HALF-OPEN (allow one attempt)
        echo "half-open|$BREAKER_COUNT|$BREAKER_TIME" > "$BREAKER_FILE"
    fi
fi

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
    # Update circuit breaker
    PREV_COUNT=0
    if [[ -f "$BREAKER_FILE" ]]; then
        PREV_COUNT=$(cut -d'|' -f2 "$BREAKER_FILE" 2>/dev/null || echo "0")
    fi
    NEW_COUNT=$(( PREV_COUNT + 1 ))
    if [[ "$NEW_COUNT" -ge 3 ]]; then
        echo "open|$NEW_COUNT|$(date +%s)" > "$BREAKER_FILE"
    else
        echo "closed|$NEW_COUNT|$(date +%s)" > "$BREAKER_FILE"
    fi

    # Lint failed — feed errors back to Claude via exit code 2
    echo "Lint errors ($LINTER) in $FILE_PATH:" >&2
    echo "$LINT_OUTPUT" >&2
    exit 2
fi

# Reset breaker on success
echo "closed|0|$(date +%s)" > "$BREAKER_FILE"

# Lint passed — silent success
exit 0
