#!/usr/bin/env bash
# Multi-language lint-on-write hook.
# PostToolUse hook — matcher: Write|Edit — async: false
#
# Runs the appropriate linter for the written/edited file immediately after
# it is saved, so the agent sees lint violations before moving on. When a
# linter is not installed, emits a one-time advisory via a breadcrumb file.
#
# Supported linters (out of the box):
#   .sh        — shellcheck  (brew install shellcheck)
#   .py        — ruff        (pip install ruff)
#   .go        — go vet
#   .rs        — cargo clippy (only when Cargo.toml exists)
#
# Exclusion lists match the CI workflow (.github/workflows/validate.yml) so
# local lint feedback is identical to what CI would report at push time.
#
# Cooldown: the same file is not re-linted within 3 seconds to avoid spam
# during rapid edits (e.g. multi-Edit sequences by the agent).
#
# @decision DEC-LINT-001
# @title lint.sh — synchronous PostToolUse lint-on-write hook
# @status accepted
# @rationale Lint violations discovered at CI time are expensive to fix:
#   the agent has already moved on, the commit is pending, and the mental
#   context is gone. Catching them immediately after Write/Edit closes the
#   feedback loop to seconds. Synchronous (async:false) so the agent sees
#   the systemMessage on the SAME turn, not the next one. Per-file linting
#   (not whole-project) keeps latency under 2 seconds. Exit code 2 is the
#   Claude Code convention for "soft advisory" — the operation is not blocked,
#   but the agent is informed.

set -euo pipefail

_HOOK_NAME="lint"
source "$(dirname "$0")/source-lib.sh"

HOOK_INPUT=$(read_input)
FILE_PATH=$(get_field '.tool_input.file_path // empty')

# Exit silently if no file path
[[ -z "${FILE_PATH:-}" ]] && exit 0

# Skip files in vendor / worktrees / archive / node_modules etc.
is_skippable_path "$FILE_PATH" && exit 0

# Derive extension
EXT="${FILE_PATH##*.}"

# Only handle known lint-able extensions
case "$EXT" in
    sh|bash|zsh|py|go|rs) : ;;  # handled below
    *)                  exit 0 ;;
esac

# Detect project root (for Cargo.toml check and breadcrumb dir)
PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)
BREADCRUMB_DIR="${CLAUDE_DIR}/.lint-advisories"
mkdir -p "$BREADCRUMB_DIR" 2>/dev/null || true

# --- Cooldown (3 seconds): avoid spam on rapid multi-edit sequences ---
_COOLDOWN_FILE="${CLAUDE_DIR}/.lint-cooldown-$(printf '%s' "$FILE_PATH" | tr '/' '_')"
if [[ -f "$_COOLDOWN_FILE" ]]; then
    _LAST_LINT=$(<"$_COOLDOWN_FILE")
    _NOW=$(date +%s)
    if (( _NOW - _LAST_LINT < 3 )); then
        exit 0
    fi
fi
printf '%s' "$(date +%s)" > "$_COOLDOWN_FILE"

# --- Emit one-time advisory when linter is not installed ---
# Uses a breadcrumb file per-linter to avoid repeating the message.
_advisory_once() {
    local linter="$1"
    local install_cmd="$2"
    local crumb="${BREADCRUMB_DIR}/${linter}-missing"
    [[ -f "$crumb" ]] && return 0
    touch "$crumb"
    local msg
    msg="Lint: ${linter} not installed. Run '${install_cmd}' for automatic ${EXT} linting."
    printf '{"additionalContext":"%s"}\n' "$msg"
}

# --- Emit lint findings ---
_emit_findings() {
    local linter="$1"
    local output="$2"
    local escaped
    escaped=$(printf '%s' "$output" | jq -Rs .)
    printf '{"additionalContext":%s}\n' "$escaped"
}

# --- Shellcheck exclusions matching CI (.github/workflows/validate.yml) ---
# Hooks use the short exclusion list; tests/scripts use the longer one.
_shellcheck_exclusions() {
    local file="$1"
    # Normalize path relative to project root for comparison
    local rel="${file#"$PROJECT_ROOT/"}"
    if [[ "$rel" == hooks/* ]]; then
        printf '%s' "SC2034,SC1091,SC2002,SC2012,SC2015,SC2126,SC2317,SC2329"
    else
        # tests/ and scripts/ — full exclusion list from CI
        printf '%s' "SC2034,SC1091,SC2155,SC2011,SC2016,SC2030,SC2031,SC2010,SC2005,SC1007,SC2153,SC2064,SC2329,SC2086,SC1090,SC2129,SC2320,SC2188,SC2015,SC2162,SC2045,SC2001,SC2088,SC2012,SC2105,SC2126,SC2295,SC2002,SC2317,SC2164"
    fi
}

# --- Run linter and emit results ---
LINT_OUTPUT=""
LINT_EXIT=0

case "$EXT" in

    sh|bash|zsh)
        if ! command -v shellcheck >/dev/null 2>&1; then
            _advisory_once "shellcheck" "brew install shellcheck"
            exit 0
        fi
        EXCL=$(_shellcheck_exclusions "$FILE_PATH")
        LINT_OUTPUT=$(shellcheck -e "$EXCL" "$FILE_PATH" 2>&1) || LINT_EXIT=$?
        ;;

    py)
        if ! command -v ruff >/dev/null 2>&1; then
            _advisory_once "ruff" "pip install ruff  OR  brew install ruff"
            exit 0
        fi
        LINT_OUTPUT=$(ruff check "$FILE_PATH" 2>&1) || LINT_EXIT=$?
        ;;

    go)
        if ! command -v go >/dev/null 2>&1; then
            _advisory_once "go" "brew install go"
            exit 0
        fi
        LINT_OUTPUT=$(go vet "$FILE_PATH" 2>&1) || LINT_EXIT=$?
        ;;

    rs)
        # Only lint if this is a Cargo workspace
        if [[ ! -f "${PROJECT_ROOT}/Cargo.toml" ]]; then
            exit 0
        fi
        if ! command -v cargo >/dev/null 2>&1; then
            _advisory_once "cargo" "curl https://sh.rustup.rs -sSf | sh"
            exit 0
        fi
        LINT_OUTPUT=$(cargo clippy -- -W clippy::all 2>&1) || LINT_EXIT=$?
        ;;
esac

# Exit silently when the linter passed
if [[ "$LINT_EXIT" -eq 0 ]] || [[ -z "$LINT_OUTPUT" ]]; then
    exit 0
fi

# Lint violations found — report as additionalContext
HEADER="Lint (${EXT}): ${FILE_PATH##*/} — violations detected:"
_emit_findings "$EXT" "${HEADER}
${LINT_OUTPUT}"

# Exit 2 = soft advisory feedback loop (agent is informed but not blocked)
exit 2
