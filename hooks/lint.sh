#!/usr/bin/env bash
# Auto-detect and run project linter on modified files.
# PostToolUse hook — matcher: Write|Edit
#
# Highest-impact hook: creates feedback loops where lint errors feed back
# into Claude via exit code 2, triggering automatic fixes.
#
# Detection: scans project root for linter config files, caches result per
# extension in state.db so multi-language projects are handled correctly.
# Durable enforcement-gap state is also stored in state.db.
#
# Enforcement-gap policy (TKT-024):
#   A source file with no linter profile ("none") is an ENFORCEMENT GAP —
#   not a neutral skip. Silent exit 0 is replaced by:
#     1. exit 2 + additionalContext to the model (immediate feedback)
#     2. Persisted entry in state.db enforcement_gaps (survives session)
#     3. GitHub Issue filed via canonical bug pipeline (rt_bug_file, best-effort)
#   The write gate (pre-write.sh / check_enforcement_gap) escalates to
#   permissionDecision=deny when encounter_count > 1 for the same ext.
#
# @decision DEC-LINT-001
# @title DB-backed per-extension cache and enforcement-gap policy
# @status accepted
# @rationale Per-extension detection prevents multi-language repos from using
#   the wrong linter. Cache and circuit-breaker state belong in state.db rather
#   than project-local flatfiles. The gap-policy replaces the silent "none -> exit 0" path
#   with a loud failure that guarantees no source write goes unnoticed by
#   enforcement. Durable gap state lives in state.db.
#   Shell files (sh/bash/zsh) now map to shellcheck — no config file needed.
set -euo pipefail

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

HOOK_INPUT=$(read_input)
seed_project_dir_from_hook_payload_cwd "$HOOK_INPUT"
FILE_PATH=$(get_field '.tool_input.file_path')

# Exit silently if no file path or file doesn't exist
[[ -z "$FILE_PATH" ]] && exit 0
[[ ! -f "$FILE_PATH" ]] && exit 0

# Only lint source files (uses shared SOURCE_EXTENSIONS from context-lib.sh)
is_source_file "$FILE_PATH" || exit 0

# Skip non-source directories
is_skippable_path "$FILE_PATH" && exit 0
is_scratchlane_path "$FILE_PATH" && exit 0

# Derive extension for per-extension caching
FILE_EXT="${FILE_PATH##*.}"
[[ -z "$FILE_EXT" || "$FILE_EXT" == "$FILE_PATH" ]] && exit 0

# --- Detect project root ---
PROJECT_ROOT=$(detect_project_root)

# =============================================================================
# ENFORCEMENT GAP STATE MANAGEMENT
# =============================================================================

# record_enforcement_gap <type> <ext> <tool>
# Upsert: creates on first encounter, increments count on subsequent ones.
record_enforcement_gap() {
    local gap_type="$1" ext="$2" tool="$3"
    cc_policy enforcement-gap record \
        --project-root "$PROJECT_ROOT" \
        --gap-type "$gap_type" \
        --ext "$ext" \
        --tool "$tool" >/dev/null 2>&1 || true
}

# get_enforcement_gap_count <type> <ext>
# Returns the encounter count for a gap, or 0 if not found.
get_enforcement_gap_count() {
    local gap_type="$1" ext="$2"
    cc_policy enforcement-gap count \
        --project-root "$PROJECT_ROOT" \
        --gap-type "$gap_type" \
        --ext "$ext" 2>/dev/null \
        | jq -r '.count // 0' 2>/dev/null || echo "0"
}

# clear_enforcement_gap <type> <ext>
# Removes a resolved gap (self-healing when tool is installed or profile added).
clear_enforcement_gap() {
    local gap_type="$1" ext="$2"
    cc_policy enforcement-gap clear \
        --project-root "$PROJECT_ROOT" \
        --gap-type "$gap_type" \
        --ext "$ext" >/dev/null 2>&1 || true
}

# file_enforcement_gap_backlog <type> <ext> <tool>
# Routes enforcement-gap bugs through the canonical bug-filing pipeline via
# rt_bug_file() (hooks/lib/runtime-bridge.sh). Dedup is handled by fingerprint
# matching in SQLite — more reliable across worktrees and fresh environments
# than the prior local-gap-count + gh issue search approach.
#
# Migration (DEC-BUGS-003): replaced direct todo.sh add with rt_bug_file()
# so filings gain: fingerprint dedup, SQLite persistence, and audit events.
# The count==1 gate is removed — the pipeline's fingerprint check is authoritative.
# Best-effort: rt_bug_file emits fallback JSON on runtime unavailability.
file_enforcement_gap_backlog() {
    local gap_type="$1" ext="$2" tool="$3"
    local title="Enforcement gap: no linter for .${ext} files (${gap_type}: ${tool})"
    local body="Enforcement gap discovered. Extension: .${ext}, Type: ${gap_type}, Tool: ${tool}"
    local evidence="lint.sh detected no linter for .${ext} files"
    rt_bug_file "enforcement_gap" "$title" "$body" "global" "hooks/lint.sh" "" "$evidence" \
        >/dev/null 2>&1 || true
}

# emit_gap_context <type> <ext> <tool> <count>
# Writes the additionalContext JSON block to stdout so the model sees the gap.
emit_gap_context() {
    local gap_type="$1" ext="$2" tool="$3" count="$4"
    local msg

    if [[ "$gap_type" == "unsupported" ]]; then
        msg="ENFORCEMENT GAP (unsupported): No linter profile is configured for .${ext} files. Source writes to .${ext} files are not being linted. Add a linter config (e.g., shellcheck for .sh, a java linter for .java) to restore enforcement. Gap recorded in state.db (encounter #${count})."
    else
        msg="ENFORCEMENT GAP (missing_dep): Linter '${tool}' is detected for .${ext} files but is not installed. Install '${tool}' to restore lint enforcement for .${ext} files. Gap recorded in state.db (encounter #${count})."
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

    # JavaScript/TypeScript/frontend files
    if [[ "$ext" =~ ^(ts|tsx|js|jsx|mjs|cjs|mts|cts|astro|vue|svelte|css|scss|sass|less|html|htm)$ ]]; then
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

lint_config_mtime() {
    local root="$1"
    local max_mtime=0
    local cfg mtime

    for cfg in "$root/pyproject.toml" "$root/setup.cfg" \
               "$root/biome.json" "$root/biome.jsonc" \
               "$root/package.json" "$root/Cargo.toml" \
               "$root/.golangci.yml" "$root/.golangci.yaml" \
               "$root/go.mod" "$root/Makefile" \
               "$root/.shellcheckrc" "$root"/.prettierrc*; do
        [[ -f "$cfg" ]] || continue
        mtime=$(file_mtime "$cfg")
        [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
        [[ "$mtime" -gt "$max_mtime" ]] && max_mtime="$mtime"
    done

    printf '%s\n' "$max_mtime"
}

# =============================================================================
# CACHE HANDLING (per-extension)
# Invalidated when the current config mtime exceeds the stored DB signature.
# =============================================================================

CONFIG_MTIME=$(lint_config_mtime "$PROJECT_ROOT")
CACHE_JSON=$(cc_policy lint-state cache-get \
    --project-root "$PROJECT_ROOT" \
    --ext "$FILE_EXT" \
    --config-mtime "$CONFIG_MTIME" 2>/dev/null || echo '{"found":false}')
CACHE_FOUND=$(printf '%s' "$CACHE_JSON" | jq -r 'if .found then "yes" else "no" end' 2>/dev/null || echo "no")

if [[ "$CACHE_FOUND" == "yes" ]]; then
    LINTER=$(printf '%s' "$CACHE_JSON" | jq -r '.linter // "none"' 2>/dev/null || echo "none")
else
    LINTER=$(detect_linter "$PROJECT_ROOT" "$FILE_PATH")
    cc_policy lint-state cache-set \
        --project-root "$PROJECT_ROOT" \
        --ext "$FILE_EXT" \
        --linter "$LINTER" \
        --config-mtime "$CONFIG_MTIME" >/dev/null 2>&1 || true
fi

# =============================================================================
# ENFORCEMENT GAP EVALUATION (replaces silent "none -> exit 0")
#
# PE-W5 scope note (Blocker PE-W5-B2):
#   This hook is operational — it runs the linter, records enforcement gaps
#   in state.db, and exits 2 to feed errors back to Claude.
#   It does NOT issue permissionDecision=deny. The hard DENY for persistent
#   gaps (encounter_count > 1) lives in the policy engine:
#     runtime/core/policies/write_enforcement_gap.py (DEC-PE-W2-003)
#   That policy is evaluated by pre-write.sh on every source Write/Edit.
#   Do not add deny logic here — the policy engine is the single authority.
# =============================================================================

if [[ "$LINTER" == "none" ]]; then
    # Operational: record the gap, file a bug, emit advisory context to the model.
    # Do NOT exit 2 here — the enforcement DENY lives in the policy engine:
    #   runtime/core/policies/write_enforcement_gap.py (DEC-PE-W2-003)
    # That policy issues permissionDecision=deny on the NEXT Write/Edit when
    # encounter_count > 1.  lint.sh is the gap detector; the policy engine is
    # the enforcer.  Two-authority pattern eliminated per PE-W5 adapter migration.
    #
    # @decision DEC-LINT-002
    # @title Enforcement-gap deny moved to policy engine (PE-W2)
    # @status accepted
    # @rationale lint.sh previously issued exit 2 on every gap detection, acting
    #   as both detector and enforcer.  write_enforcement_gap.py (PE-W2) is now
    #   the single enforcement authority.  lint.sh records state and emits
    #   advisory feedback only; it no longer makes enforcement decisions.
    append_audit "$PROJECT_ROOT" "enforcement_gap" "unsupported|${FILE_EXT}|none|$FILE_PATH"
    record_enforcement_gap "unsupported" "$FILE_EXT" "none"
    file_enforcement_gap_backlog "unsupported" "$FILE_EXT" "none"
    GAP_COUNT=$(get_enforcement_gap_count "unsupported" "$FILE_EXT")
    emit_gap_context "unsupported" "$FILE_EXT" "none" "$GAP_COUNT"
    exit 0
fi

if ! check_linter_available "$LINTER"; then
    # Degraded state: profile detected but binary missing.
    # Same adapter pattern: record gap, emit advisory, do NOT deny here.
    # The policy engine denies on next Write/Edit when count > 1.
    append_audit "$PROJECT_ROOT" "enforcement_gap" "missing_dep|${FILE_EXT}|${LINTER}|$FILE_PATH"
    record_enforcement_gap "missing_dep" "$FILE_EXT" "$LINTER"
    file_enforcement_gap_backlog "missing_dep" "$FILE_EXT" "$LINTER"
    GAP_COUNT=$(get_enforcement_gap_count "missing_dep" "$FILE_EXT")
    emit_gap_context "missing_dep" "$FILE_EXT" "$LINTER" "$GAP_COUNT"
    exit 0
fi

# Linter available and no gap: self-heal any stale gap entries for this ext.
clear_enforcement_gap "unsupported" "$FILE_EXT" || true
clear_enforcement_gap "missing_dep" "$FILE_EXT" || true

# =============================================================================
# CIRCUIT BREAKER (per-extension, 5-minute cooling-off window, DB-backed)
# =============================================================================

BREAKER_JSON=$(cc_policy lint-state breaker-get \
    --project-root "$PROJECT_ROOT" \
    --ext "$FILE_EXT" 2>/dev/null || echo '{"found":false,"state":"closed","failure_count":0,"updated_at":0}')
BREAKER_STATE=$(printf '%s' "$BREAKER_JSON" | jq -r '.state // "closed"' 2>/dev/null || echo "closed")
BREAKER_COUNT=$(printf '%s' "$BREAKER_JSON" | jq -r '.failure_count // 0' 2>/dev/null || echo "0")
BREAKER_TIME=$(printf '%s' "$BREAKER_JSON" | jq -r '.updated_at // 0' 2>/dev/null || echo "0")
[[ "$BREAKER_COUNT" =~ ^[0-9]+$ ]] || BREAKER_COUNT=0
[[ "$BREAKER_TIME" =~ ^[0-9]+$ ]] || BREAKER_TIME=0
NOW=$(date +%s)
ELAPSED=$(( NOW - BREAKER_TIME ))

if [[ "$BREAKER_STATE" == "open" && "$ELAPSED" -lt 300 ]]; then
    cat <<BREAKER_EOF
{ "hookSpecificOutput": { "hookEventName": "PostToolUse",
    "additionalContext": "Lint circuit breaker OPEN ($BREAKER_COUNT consecutive failures). Skipping lint for $((300 - ELAPSED))s. Fix underlying lint issues to reset." } }
BREAKER_EOF
    exit 0
elif [[ "$BREAKER_STATE" == "open" && "$ELAPSED" -ge 300 ]]; then
    cc_policy lint-state breaker-set \
        --project-root "$PROJECT_ROOT" \
        --ext "$FILE_EXT" \
        --state "half-open" \
        --failure-count "$BREAKER_COUNT" \
        --updated-at "$BREAKER_TIME" >/dev/null 2>&1 || true
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
    PREV_COUNT="$BREAKER_COUNT"
    [[ "$PREV_COUNT" =~ ^[0-9]+$ ]] || PREV_COUNT=0
    NEW_COUNT=$(( PREV_COUNT + 1 ))
    if [[ "$NEW_COUNT" -ge 3 ]]; then
        cc_policy lint-state breaker-set \
            --project-root "$PROJECT_ROOT" \
            --ext "$FILE_EXT" \
            --state "open" \
            --failure-count "$NEW_COUNT" >/dev/null 2>&1 || true
    else
        cc_policy lint-state breaker-set \
            --project-root "$PROJECT_ROOT" \
            --ext "$FILE_EXT" \
            --state "closed" \
            --failure-count "$NEW_COUNT" >/dev/null 2>&1 || true
    fi

    # Lint failed — feed errors back to Claude via exit code 2
    echo "Lint errors ($LINTER) in $FILE_PATH:" >&2
    echo "$LINT_OUTPUT" >&2
    exit 2
fi

# Reset breaker on success
cc_policy lint-state breaker-reset \
    --project-root "$PROJECT_ROOT" \
    --ext "$FILE_EXT" >/dev/null 2>&1 || true

# Lint passed — silent success
exit 0
