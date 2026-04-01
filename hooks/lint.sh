#!/usr/bin/env bash
# Auto-detect and run project linter on modified files.
# PostToolUse hook — matcher: Write|Edit
#
# Highest-impact hook: creates feedback loops where lint errors feed back
# into Claude via exit code 2, triggering automatic fixes.
#
# Detection: scans project root for linter config files, caches result
# per extension (.lint-cache-<ext>) so multi-language projects are handled
# correctly. Each extension has its own cache, breaker, and gap state.
#
# Enforcement-gap policy (TKT-024):
#   A source file with no linter profile ("none") is an ENFORCEMENT GAP —
#   not a neutral skip. Silent exit 0 is replaced by:
#     1. exit 2 + additionalContext to the model (immediate feedback)
#     2. Persisted entry in .claude/.enforcement-gaps (survives session)
#     3. GitHub Issue filed on first encounter via todo.sh (best-effort)
#   The write gate (pre-write.sh / check_enforcement_gap) escalates to
#   permissionDecision=deny when encounter_count > 1 for the same ext.
#
# @decision DEC-LINT-001
# @title Per-extension cache and enforcement-gap policy
# @status accepted
# @rationale The old single .lint-cache stored the first detected linter
#   across all extensions. Multi-language repos would use the wrong linter
#   after detecting any one. Per-ext caches (.lint-cache-py, .lint-cache-sh,
#   etc.) fix detection accuracy and allow targeted invalidation. The
#   gap-policy replaces the silent "none -> exit 0" path with a loud failure
#   that guarantees no source write goes unnoticed by enforcement.
#   Shell files (sh/bash/zsh) now map to shellcheck — no config file needed.
set -euo pipefail

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

# Derive extension for per-extension caching
FILE_EXT="${FILE_PATH##*.}"
[[ -z "$FILE_EXT" || "$FILE_EXT" == "$FILE_PATH" ]] && exit 0

# --- Detect project root ---
PROJECT_ROOT=$(detect_project_root)

# --- Per-extension state paths ---
CACHE_DIR="$PROJECT_ROOT/.claude"
mkdir -p "$CACHE_DIR"
CACHE_FILE="$CACHE_DIR/.lint-cache-${FILE_EXT}"
BREAKER_FILE="$CACHE_DIR/.lint-breaker-${FILE_EXT}"
GAPS_FILE="$CACHE_DIR/.enforcement-gaps"

# =============================================================================
# ENFORCEMENT GAP STATE MANAGEMENT
# Gap file format: type|ext|tool|first_epoch|encounter_count
# Keyed on type|ext (one line per unique gap).
# =============================================================================

# record_enforcement_gap <type> <ext> <tool>
# Upsert: creates on first encounter, increments count on subsequent ones.
record_enforcement_gap() {
    local gap_type="$1" ext="$2" tool="$3"
    local key="${gap_type}|${ext}"
    local epoch
    epoch=$(date +%s)

    touch "$GAPS_FILE"

    local existing
    existing=$(grep "^${key}|" "$GAPS_FILE" 2>/dev/null || true)

    if [[ -z "$existing" ]]; then
        # First encounter
        printf '%s|%s|%s|%s|1\n' "$gap_type" "$ext" "$tool" "$epoch" >> "$GAPS_FILE"
    else
        # Increment encounter count
        local first_epoch count
        first_epoch=$(printf '%s' "$existing" | cut -d'|' -f4)
        count=$(printf '%s' "$existing" | cut -d'|' -f5)
        count=$(( count + 1 ))
        # Rewrite file with updated count (atomic via tmp file)
        local tmp_file="${GAPS_FILE}.tmp.$$"
        grep -v "^${key}|" "$GAPS_FILE" > "$tmp_file" 2>/dev/null || true
        printf '%s|%s|%s|%s|%s\n' "$gap_type" "$ext" "$tool" "$first_epoch" "$count" >> "$tmp_file"
        mv "$tmp_file" "$GAPS_FILE"
    fi
}

# get_enforcement_gap_count <type> <ext>
# Returns the encounter count for a gap, or 0 if not found.
get_enforcement_gap_count() {
    local gap_type="$1" ext="$2"
    local key="${gap_type}|${ext}"

    [[ ! -f "$GAPS_FILE" ]] && echo "0" && return
    local line
    line=$(grep "^${key}|" "$GAPS_FILE" 2>/dev/null || true)
    if [[ -z "$line" ]]; then
        echo "0"
    else
        printf '%s' "$line" | cut -d'|' -f5
    fi
}

# clear_enforcement_gap <type> <ext>
# Removes a resolved gap (self-healing when tool is installed or profile added).
clear_enforcement_gap() {
    local gap_type="$1" ext="$2"
    local key="${gap_type}|${ext}"
    [[ ! -f "$GAPS_FILE" ]] && return
    local tmp_file="${GAPS_FILE}.tmp.$$"
    grep -v "^${key}|" "$GAPS_FILE" > "$tmp_file" 2>/dev/null || true
    mv "$tmp_file" "$GAPS_FILE"
}

# file_enforcement_gap_backlog <type> <ext> <tool>
# Files a GitHub Issue on first encounter (count==1). Best-effort: never
# blocks lint execution if gh CLI or todo.sh is unavailable.
# Dedup: checks both local gap count AND existing open issues by title prefix
# to prevent duplicate issues across fresh projects / worktrees / test runs.
file_enforcement_gap_backlog() {
    local gap_type="$1" ext="$2" tool="$3"

    # Only file on first encounter (local gap count)
    local count
    count=$(get_enforcement_gap_count "$gap_type" "$ext")
    [[ "$count" -ne 1 ]] && return 0

    local todo_sh="$HOME/.claude/scripts/todo.sh"
    [[ -x "$todo_sh" ]] || return 0
    command -v gh >/dev/null 2>&1 || return 0

    local title="Enforcement gap: no linter for .${ext} files (${gap_type}: ${tool})"

    # Title-based dedup: search for existing open issue with same title.
    # This prevents duplicates across fresh worktrees / projects / test isolation.
    local existing
    existing=$(gh issue list --label claude-todo --state open --search "$title" \
        --json number --jq '.[0].number' 2>/dev/null) || existing=""
    [[ -n "$existing" ]] && return 0

    # Synchronous (not fire-and-forget) so dedup check is reliable
    "$todo_sh" add --global --priority=high \
        "${title} -- silent non-enforcement on source writes" \
        2>/dev/null || true
}

# emit_gap_context <type> <ext> <tool> <count>
# Writes the additionalContext JSON block to stdout so the model sees the gap.
emit_gap_context() {
    local gap_type="$1" ext="$2" tool="$3" count="$4"
    local msg

    if [[ "$gap_type" == "unsupported" ]]; then
        msg="ENFORCEMENT GAP (unsupported): No linter profile is configured for .${ext} files. Source writes to .${ext} files are not being linted. Add a linter config (e.g., shellcheck for .sh, a java linter for .java) to restore enforcement. Gap recorded in .claude/.enforcement-gaps (encounter #${count})."
    else
        msg="ENFORCEMENT GAP (missing_dep): Linter '${tool}' is detected for .${ext} files but is not installed. Install '${tool}' to restore lint enforcement for .${ext} files. Gap recorded in .claude/.enforcement-gaps (encounter #${count})."
    fi

    local escaped_msg
    escaped_msg=$(printf '%s' "$msg" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": $escaped_msg
  }
}
EOF
}

# =============================================================================
# LINTER DETECTION
# =============================================================================

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

    # Shell files — always map to shellcheck (no project config required)
    if [[ "$ext" =~ ^(sh|bash|zsh)$ ]]; then
        echo "shellcheck"
        return
    fi

    # Makefile with lint target (fallback for any extension)
    if [[ -f "$root/Makefile" ]] && grep -q '^lint:' "$root/Makefile" 2>/dev/null; then
        echo "make-lint"
        return
    fi

    echo "none"
}

# check_linter_available <linter>
# Centralised dependency check. Returns 0 if the binary is reachable, 1 if not.
# Called BEFORE run_lint so missing-dep gaps fire before any lint attempt.
check_linter_available() {
    local linter="$1"
    case "$linter" in
        ruff)          command -v ruff &>/dev/null ;;
        black)         command -v black &>/dev/null ;;
        flake8)        command -v flake8 &>/dev/null ;;
        biome)         command -v biome &>/dev/null || [[ -f "$PROJECT_ROOT/node_modules/.bin/biome" ]] ;;
        eslint)        [[ -f "$PROJECT_ROOT/node_modules/.bin/eslint" ]] || command -v eslint &>/dev/null ;;
        prettier)      [[ -f "$PROJECT_ROOT/node_modules/.bin/prettier" ]] || command -v prettier &>/dev/null ;;
        clippy)        command -v cargo &>/dev/null ;;
        golangci-lint) command -v golangci-lint &>/dev/null ;;
        govet)         command -v go &>/dev/null ;;
        shellcheck)    command -v shellcheck &>/dev/null ;;
        make-lint)     command -v make &>/dev/null ;;
        none)          return 1 ;;
        *)             return 1 ;;
    esac
}

# =============================================================================
# CACHE HANDLING (per-extension)
# Invalidated when any linter config file is newer than the cache file.
# =============================================================================

CACHE_STALE=false
if [[ -f "$CACHE_FILE" ]]; then
    for cfg in "$PROJECT_ROOT/pyproject.toml" "$PROJECT_ROOT/setup.cfg" \
               "$PROJECT_ROOT/biome.json" "$PROJECT_ROOT/biome.jsonc" \
               "$PROJECT_ROOT/package.json" "$PROJECT_ROOT/Cargo.toml" \
               "$PROJECT_ROOT/.golangci.yml" "$PROJECT_ROOT/.golangci.yaml" \
               "$PROJECT_ROOT/go.mod" "$PROJECT_ROOT/Makefile" \
               "$PROJECT_ROOT/.shellcheckrc"; do
        if [[ -f "$cfg" && "$cfg" -nt "$CACHE_FILE" ]]; then
            CACHE_STALE=true
            break
        fi
    done
    if [[ "$CACHE_STALE" == "false" ]]; then
        for cfg in "$PROJECT_ROOT"/.prettierrc*; do
            if [[ -f "$cfg" && "$cfg" -nt "$CACHE_FILE" ]]; then
                CACHE_STALE=true
                break
            fi
        done
    fi
fi

if [[ -f "$CACHE_FILE" && "$CACHE_STALE" == "false" ]]; then
    LINTER=$(cat "$CACHE_FILE")
else
    LINTER=$(detect_linter "$PROJECT_ROOT" "$FILE_PATH")
    echo "$LINTER" > "$CACHE_FILE"
fi

# =============================================================================
# ENFORCEMENT GAP EVALUATION (replaces silent "none -> exit 0")
# =============================================================================

if [[ "$LINTER" == "none" ]]; then
    # Policy gap: an in-scope source extension with no linter profile.
    append_audit "$PROJECT_ROOT" "enforcement_gap" "unsupported|${FILE_EXT}|none|$FILE_PATH"
    record_enforcement_gap "unsupported" "$FILE_EXT" "none"
    file_enforcement_gap_backlog "unsupported" "$FILE_EXT" "none"
    GAP_COUNT=$(get_enforcement_gap_count "unsupported" "$FILE_EXT")
    emit_gap_context "unsupported" "$FILE_EXT" "none" "$GAP_COUNT"
    exit 2
fi

if ! check_linter_available "$LINTER"; then
    # Degraded state: profile detected but binary missing.
    append_audit "$PROJECT_ROOT" "enforcement_gap" "missing_dep|${FILE_EXT}|${LINTER}|$FILE_PATH"
    record_enforcement_gap "missing_dep" "$FILE_EXT" "$LINTER"
    file_enforcement_gap_backlog "missing_dep" "$FILE_EXT" "$LINTER"
    GAP_COUNT=$(get_enforcement_gap_count "missing_dep" "$FILE_EXT")
    emit_gap_context "missing_dep" "$FILE_EXT" "$LINTER" "$GAP_COUNT"
    exit 2
fi

# Linter available and no gap: self-heal any stale gap entries for this ext.
if [[ -f "$GAPS_FILE" ]]; then
    grep -q "^unsupported|${FILE_EXT}|" "$GAPS_FILE" 2>/dev/null \
        && clear_enforcement_gap "unsupported" "$FILE_EXT" || true
    grep -q "^missing_dep|${FILE_EXT}|" "$GAPS_FILE" 2>/dev/null \
        && clear_enforcement_gap "missing_dep" "$FILE_EXT" || true
fi

# =============================================================================
# CIRCUIT BREAKER (per-extension, 5-minute cooling-off window)
# =============================================================================

if [[ -f "$BREAKER_FILE" ]]; then
    BREAKER_STATE=$(cut -d'|' -f1 "$BREAKER_FILE")
    BREAKER_COUNT=$(cut -d'|' -f2 "$BREAKER_FILE")
    BREAKER_TIME=$(cut -d'|' -f3 "$BREAKER_FILE")
    NOW=$(date +%s)
    ELAPSED=$(( NOW - BREAKER_TIME ))

    if [[ "$BREAKER_STATE" == "open" && "$ELAPSED" -lt 300 ]]; then
        cat <<BREAKER_EOF
{ "hookSpecificOutput": { "hookEventName": "PostToolUse",
    "additionalContext": "Lint circuit breaker OPEN ($BREAKER_COUNT consecutive failures). Skipping lint for $((300 - ELAPSED))s. Fix underlying lint issues to reset." } }
BREAKER_EOF
        exit 0
    elif [[ "$BREAKER_STATE" == "open" && "$ELAPSED" -ge 300 ]]; then
        echo "half-open|$BREAKER_COUNT|$BREAKER_TIME" > "$BREAKER_FILE"
    fi
fi

# =============================================================================
# LINTER EXECUTION
# Note: existing linter cases are intentionally preserved unchanged for
# backward compatibility. Only shellcheck is new.
# =============================================================================

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
        shellcheck)
            if command -v shellcheck &>/dev/null; then
                local sc_exit=0
                shellcheck -x "$file" 2>&1 || sc_exit=$?
                # Advisory: shfmt diff (does not affect exit code)
                if command -v shfmt &>/dev/null; then
                    shfmt -d "$file" 2>&1 || true
                fi
                # Propagate shellcheck's exit code out of the if block
                return "$sc_exit"
            fi
            ;;
        make-lint)
            cd "$root" && make lint 2>&1
            ;;
    esac
}

# Run lint and capture result
LINT_EXIT=0
LINT_OUTPUT=$(run_lint "$LINTER" "$FILE_PATH" "$PROJECT_ROOT" 2>&1) || LINT_EXIT=$?

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
