#!/usr/bin/env bash
# Consolidated PostToolUse:Write|Edit hook — replaces 3 individual hooks.
# Runs track, plan-validate, and lint in a single process with ONE library source.
# test-runner.sh is kept separate (async, 60s timeout, different execution model).
# code-review.sh is pruned (see Phase 2 — low-signal MCP dependency).
#
# Replaces (in order of execution):
#   1. track.sh        — session change tracking + proof invalidation
#   2. plan-validate.sh — MASTER_PLAN.md structural validation
#   3. lint.sh         — auto-detect and run project linter
#
# @decision DEC-CONSOLIDATE-002
# @title Merge 3 PostToolUse:Write|Edit hooks into post-write.sh
# @status accepted
# @rationale Each PostToolUse hook independently re-sourced source-lib.sh →
#   log.sh → context-lib.sh, adding 60-160ms overhead per hook. For Write/Edit,
#   3 hooks ran sequentially — 180-480ms per write. Merging into a single process
#   with one library source reduces to ~60ms. All logic is preserved unchanged.
#   test-runner.sh is excluded because it is async (60s timeout) and must remain
#   a separate hook invocation to avoid blocking the synchronous hook chain.
#   code-review.sh is excluded per Phase 2 pruning (low-signal, unreliable MCP).

set -euo pipefail

source "$(dirname "$0")/source-lib.sh"

HOOK_INPUT=$(read_input)
FILE_PATH=$(get_field '.tool_input.file_path')

# Exit silently if no file path
[[ -z "$FILE_PATH" ]] && exit 0

# ============================================================
# Step 1: Track — session change tracking + proof invalidation
# Source: track.sh
# ============================================================

# Exit silently if parent directory doesn't exist
if [[ -e "$(dirname "$FILE_PATH")" ]]; then
    PROJECT_ROOT=$(detect_project_root)
    SESSION_ID="${CLAUDE_SESSION_ID:-$$}"
    TRACKING_DIR="$PROJECT_ROOT/.claude"
    TRACKING_FILE="$TRACKING_DIR/.session-changes-${SESSION_ID}"

    mkdir -p "$TRACKING_DIR"

    # Atomic append
    TMPFILE=$(mktemp "${TRACKING_DIR}/.track.XXXXXX")
    echo "$FILE_PATH" > "$TMPFILE"
    cat "$TMPFILE" >> "$TRACKING_FILE"
    rm -f "$TMPFILE"

    # Log write event to session event log (skip trace artifacts — meta-infrastructure noise)
    if [[ ! "$FILE_PATH" =~ /\.claude/traces/ ]]; then
        append_session_event "write" "{\"file\":\"$FILE_PATH\"}" "$PROJECT_ROOT"
    fi

    # Invalidate doc freshness cache when a .md file is written
    if [[ "$FILE_PATH" == *.md ]]; then
        _DOC_CACHE="${TRACKING_DIR}/.doc-freshness-cache"
        rm -f "$_DOC_CACHE"
    fi

    # Invalidate proof-status when non-test source files change
    # @decision DEC-PROOF-PATH-003
    # @title Use get_claude_dir() for proof-status path
    # @status accepted
    # @rationale For the meta-repo (PROJECT_ROOT = ~/.claude), TRACKING_DIR is
    #   "$PROJECT_ROOT/.claude" = "~/.claude/.claude" — double-nested. get_claude_dir()
    #   handles this correctly. Using it here ensures the proof-status path is consistent
    #   with where resolve_proof_file(), prompt-submit.sh, and check-tester.sh write it.
    _PROOF_PHASH=$(project_hash "$PROJECT_ROOT")
    _PROOF_SCOPED="$(get_claude_dir)/.proof-status-${_PROOF_PHASH}"
    _PROOF_LEGACY="$(get_claude_dir)/.proof-status"
    if [[ -f "$_PROOF_SCOPED" ]]; then
        PROOF_FILE="$_PROOF_SCOPED"
    elif [[ -f "$_PROOF_LEGACY" ]]; then
        PROOF_FILE="$_PROOF_LEGACY"
    else
        PROOF_FILE="$_PROOF_SCOPED"
    fi

    if [[ -f "$PROOF_FILE" ]]; then
        PROOF_STATUS=$(cut -d'|' -f1 "$PROOF_FILE")
        if [[ "$PROOF_STATUS" == "verified" ]]; then
            # @decision DEC-TRACK-GUARDIAN-001
            # @title Skip proof invalidation when Guardian agent is active
            # @status accepted
            # @rationale Guardian's commit/merge workflow can trigger Write/Edit events.
            #   Without this guard, track.sh fires on those writes and resets
            #   .proof-status from verified→pending mid-workflow, causing deadlock.
            _guardian_active=false
            for _gm in "${TRACE_STORE}/.active-guardian-"*; do
                [[ -f "$_gm" ]] && { _guardian_active=true; break; }
            done

            if [[ "$_guardian_active" == "false" ]]; then
                # @decision DEC-TRACK-001
                # @title Use relative path for proof invalidation exclusions in track.sh
                # @status accepted
                # @rationale Using absolute FILE_PATH caused all source files in the
                #   meta-repo (~/.claude) to be excluded because their paths contain
                #   ".claude". Relative path restricts exclusion to within the project.
                RELATIVE_PATH="${FILE_PATH#${PROJECT_ROOT}/}"
                if [[ "$FILE_PATH" =~ \.(ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh)$ ]] \
                   && [[ ! "$RELATIVE_PATH" =~ (\.test\.|\.spec\.|__tests__|\.config\.|node_modules|vendor|dist|\.git|\.claude) ]]; then
                    echo "pending|$(date +%s)" > "$PROOF_FILE"
                fi
            fi
        fi
    fi
fi

# ============================================================
# Step 2: Plan validate — structural validation of MASTER_PLAN.md
# Source: plan-validate.sh
# ============================================================

# Only validate MASTER_PLAN.md writes
if [[ "$FILE_PATH" =~ MASTER_PLAN\.md$ ]]; then
    # Resolve to absolute path if needed
    PLAN_FILE_PATH="$FILE_PATH"
    if [[ ! "$PLAN_FILE_PATH" = /* ]]; then
        _PV_PROJECT_ROOT=$(detect_project_root)
        PLAN_FILE_PATH="$_PV_PROJECT_ROOT/$PLAN_FILE_PATH"
    fi

    if [[ -f "$PLAN_FILE_PATH" ]]; then
        ISSUES=()
        WARNINGS=()

        HAS_INITIATIVES=$(grep -cE '^\#\#\#\s+Initiative:' "$PLAN_FILE_PATH" 2>/dev/null || echo "0")
        HAS_OLD_PHASES=$(grep -cE '^\#\#\s+Phase\s+[0-9]' "$PLAN_FILE_PATH" 2>/dev/null || echo "0")

        if ! grep -qiE '^\#.*intent|^\#.*vision|^\#.*user.*request|^\#.*original' "$PLAN_FILE_PATH" 2>/dev/null; then
            ISSUES+=("Missing original intent/vision section. MASTER_PLAN.md must preserve the user's original request.")
        fi

        PHASE_HEADERS=""

        if [[ "$HAS_INITIATIVES" -gt 0 ]]; then
            if ! grep -qE '^\#\#\s+Identity' "$PLAN_FILE_PATH" 2>/dev/null; then
                ISSUES+=("Missing '## Identity' section. New living-plan format requires Identity (type, root, dates).")
            fi
            if ! grep -qE '^\#\#\s+Active Initiatives' "$PLAN_FILE_PATH" 2>/dev/null; then
                ISSUES+=("Missing '## Active Initiatives' section. New format requires this section.")
            fi

            INITIATIVE_HEADERS=$(grep -nE '^\#\#\#\s+Initiative:' "$PLAN_FILE_PATH" 2>/dev/null || echo "")
            if [[ -n "$INITIATIVE_HEADERS" ]]; then
                while IFS= read -r init_line; do
                    INIT_LINE_NUM=$(echo "$init_line" | cut -d: -f1)
                    INIT_NAME=$(echo "$init_line" | sed 's/^[0-9]*:### Initiative: *//')
                    NEXT_LINE=$(grep -nE '^\#\#\#\s+Initiative:|^\#\#\s+' "$PLAN_FILE_PATH" 2>/dev/null | \
                        awk -F: -v curr="$INIT_LINE_NUM" '$1 > curr {print $1; exit}')
                    [[ -z "$NEXT_LINE" ]] && NEXT_LINE=$(wc -l < "$PLAN_FILE_PATH" | tr -d ' ')
                    INIT_CONTENT=$(sed -n "${INIT_LINE_NUM},${NEXT_LINE}p" "$PLAN_FILE_PATH" 2>/dev/null)

                    if ! echo "$INIT_CONTENT" | grep -qE '^\*\*Status:\*\*\s*(active|completed|planned)'; then
                        ISSUES+=("Initiative '$INIT_NAME': Missing or invalid **Status:** field. Must be: active, completed, or planned.")
                    fi

                    PHASE_HEADERS_IN_INIT=$(echo "$INIT_CONTENT" | grep -nE '^\#\#\#\#\s+Phase\s+[0-9]' || echo "")
                    if [[ -n "$PHASE_HEADERS_IN_INIT" ]]; then
                        while IFS= read -r phase_line; do
                            PHASE_NUM=$(echo "$phase_line" | grep -oE 'Phase\s+[0-9]+' | grep -oE '[0-9]+')
                            PHASE_LINE_NUM=$(echo "$phase_line" | cut -d: -f1)
                            PHASE_NEXT=$(echo "$INIT_CONTENT" | grep -nE '^\#\#\#\#\s+Phase\s+[0-9]' | \
                                awk -F: -v curr="$PHASE_LINE_NUM" '$1 > curr {print $1; exit}')
                            [[ -z "$PHASE_NEXT" ]] && PHASE_NEXT=$(echo "$INIT_CONTENT" | wc -l | tr -d ' ')
                            PHASE_CONTENT=$(echo "$INIT_CONTENT" | sed -n "${PHASE_LINE_NUM},${PHASE_NEXT}p" 2>/dev/null)
                            if ! echo "$PHASE_CONTENT" | grep -qE '\*\*Status:\*\*\s*(planned|in-progress|completed)'; then
                                ISSUES+=("Initiative '$INIT_NAME' Phase $PHASE_NUM: Missing or invalid Status field.")
                            fi
                        done <<< "$PHASE_HEADERS_IN_INIT"
                    fi
                done <<< "$INITIATIVE_HEADERS"
            fi

            DEC_LOG_SECTION=$(awk '/^## Decision Log/{f=1} f && /^---/{exit} f{print}' "$PLAN_FILE_PATH" 2>/dev/null || echo "")
            DEC_LOG_ENTRIES=$(echo "$DEC_LOG_SECTION" | grep -cE '^\|\s+[0-9]{4}' 2>/dev/null || echo "0")
            if [[ "$DEC_LOG_ENTRIES" -eq 0 ]]; then
                WARNINGS+=("Decision Log has no entries yet. Append decisions as work progresses.")
            fi

        elif [[ "$HAS_OLD_PHASES" -gt 0 ]]; then
            PHASE_HEADERS=$(grep -nE '^\#\#\s+Phase\s+[0-9]' "$PLAN_FILE_PATH" 2>/dev/null || echo "")

            while IFS= read -r phase_line; do
                PHASE_NUM=$(echo "$phase_line" | grep -oE 'Phase\s+[0-9]+' | grep -oE '[0-9]+')
                LINE_NUM=$(echo "$phase_line" | cut -d: -f1)
                NEXT_LINE=$(grep -nE '^\#\#\s+Phase\s+[0-9]' "$PLAN_FILE_PATH" 2>/dev/null | \
                    awk -F: -v curr="$LINE_NUM" '$1 > curr {print $1; exit}')
                [[ -z "$NEXT_LINE" ]] && NEXT_LINE=$(wc -l < "$PLAN_FILE_PATH" | tr -d ' ')
                PHASE_CONTENT=$(sed -n "${LINE_NUM},${NEXT_LINE}p" "$PLAN_FILE_PATH" 2>/dev/null)

                if ! echo "$PHASE_CONTENT" | grep -qE '\*\*Status:\*\*\s*(planned|in-progress|completed)'; then
                    ISSUES+=("Phase $PHASE_NUM: Missing or invalid Status field. Must be one of: planned, in-progress, completed")
                fi

                if echo "$PHASE_CONTENT" | grep -qE '\*\*Status:\*\*\s*completed'; then
                    if ! echo "$PHASE_CONTENT" | grep -qE '###\s+Decision\s+Log'; then
                        ISSUES+=("Phase $PHASE_NUM: Completed phase missing Decision Log section")
                    else
                        LOG_SECTION=$(echo "$PHASE_CONTENT" | sed -n '/### *Decision *Log/,/^###/p' | tail -n +2)
                        NON_COMMENT=$(echo "$LOG_SECTION" | grep -v '^\s*$' | grep -v '<!--' | grep -v -e '-->' || echo "")
                        if [[ -z "$NON_COMMENT" ]]; then
                            ISSUES+=("Phase $PHASE_NUM: Completed phase has empty Decision Log — Guardian must append decision entries")
                        fi
                    fi
                fi
            done <<< "$PHASE_HEADERS"
        fi

        # Validate Decision ID format
        DECISION_IDS=$(grep -oE 'DEC-[A-Z]+-[0-9]+' "$PLAN_FILE_PATH" 2>/dev/null | sort -u || echo "")
        if [[ -n "$DECISION_IDS" ]]; then
            while IFS= read -r dec_id; do
                if ! echo "$dec_id" | grep -qE '^DEC-[A-Z]{2,}-[0-9]{3}$'; then
                    ISSUES+=("Decision ID '$dec_id' doesn't follow DEC-COMPONENT-NNN format (e.g., DEC-AUTH-001)")
                fi
            done <<< "$DECISION_IDS"
        fi

        # Validate REQ-ID format
        REQ_IDS=$(grep -oE 'REQ-[A-Z0-9]+-[0-9]+' "$PLAN_FILE_PATH" 2>/dev/null | sort -u || echo "")
        if [[ -n "$REQ_IDS" ]]; then
            while IFS= read -r req_id; do
                if ! echo "$req_id" | grep -qE '^REQ-(GOAL|NOGO|UJ|P0|P1|P2|MET)-[0-9]{3}$'; then
                    ISSUES+=("Requirement ID '$req_id' doesn't follow REQ-{CATEGORY}-NNN format (CATEGORY: GOAL|NOGO|UJ|P0|P1|P2|MET)")
                fi
            done <<< "$REQ_IDS"
        fi

        # Advisory warnings
        if ! grep -qiE '^\#\#\s*(Goals|Goals\s*&\s*Non.Goals)' "$PLAN_FILE_PATH" 2>/dev/null; then
            WARNINGS+=("Missing Goals & Non-Goals section — consider adding structured requirements")
        fi
        if ! grep -qiE '^\#\#\#\s*Must.Have|^\#\#\s*Requirements' "$PLAN_FILE_PATH" 2>/dev/null; then
            WARNINGS+=("Missing Requirements section with P0/P1/P2 prioritization")
        elif ! grep -qE 'REQ-P0-[0-9]' "$PLAN_FILE_PATH" 2>/dev/null; then
            WARNINGS+=("Requirements section has no P0 (Must-Have) requirements")
        fi
        if ! grep -qiE '^\#\#\s*Success\s*Metrics' "$PLAN_FILE_PATH" 2>/dev/null; then
            WARNINGS+=("Missing Success Metrics section")
        fi

        # Advisory: completed phases should reference REQ-IDs
        if [[ -n "$PHASE_HEADERS" ]]; then
            while IFS= read -r phase_line; do
                PHASE_NUM=$(echo "$phase_line" | grep -oE 'Phase\s+[0-9]+' | grep -oE '[0-9]+')
                LINE_NUM=$(echo "$phase_line" | cut -d: -f1)
                NEXT_LINE=$(grep -nE '^\#\#\s+Phase\s+[0-9]' "$PLAN_FILE_PATH" 2>/dev/null | \
                    awk -F: -v curr="$LINE_NUM" '$1 > curr {print $1; exit}')
                [[ -z "$NEXT_LINE" ]] && NEXT_LINE=$(wc -l < "$PLAN_FILE_PATH" | tr -d ' ')
                PHASE_CONTENT=$(sed -n "${LINE_NUM},${NEXT_LINE}p" "$PLAN_FILE_PATH" 2>/dev/null)
                if echo "$PHASE_CONTENT" | grep -qE '\*\*Status:\*\*\s*completed'; then
                    if ! echo "$PHASE_CONTENT" | grep -qE 'REQ-[A-Z0-9]+-[0-9]+'; then
                        WARNINGS+=("Phase $PHASE_NUM: Completed phase does not reference any REQ-IDs")
                    fi
                fi
            done <<< "$PHASE_HEADERS"
        fi

        if [[ ${#WARNINGS[@]} -gt 0 ]]; then
            for warn in "${WARNINGS[@]}"; do
                log_info "PLAN-VALIDATE" "WARNING: $warn"
            done
        fi

        if [[ ${#ISSUES[@]} -gt 0 ]]; then
            FEEDBACK="MASTER_PLAN.md structural issues found:\n"
            for issue in "${ISSUES[@]}"; do
                FEEDBACK+="  - $issue\n"
            done
            FEEDBACK+="\nFix these issues to maintain plan integrity."

            log_info "PLAN-VALIDATE" "$(echo -e "$FEEDBACK")"

            ESCAPED=$(echo -e "$FEEDBACK" | jq -Rs .)
            cat <<EOF
{
  "decision": "block",
  "reason": $ESCAPED
}
EOF
            exit 2
        fi
    fi
fi

# ============================================================
# Step 3: Lint — auto-detect and run project linter
# Source: lint.sh
# ============================================================

# Only lint files that exist and are source files
if [[ -f "$FILE_PATH" ]] && is_source_file "$FILE_PATH" && ! is_skippable_path "$FILE_PATH"; then
    _LINT_PROJECT_ROOT=$(detect_project_root)
    _LINT_CLAUDE_DIR=$(get_claude_dir)
    CACHE_DIR="$_LINT_PROJECT_ROOT/.claude"
    mkdir -p "$CACHE_DIR"
    CACHE_FILE="$CACHE_DIR/.lint-cache"

    _detect_linter() {
        local root="$1"
        local file="$2"
        local ext="${file##*.}"

        if [[ "$ext" == "py" ]]; then
            if [[ -f "$root/pyproject.toml" ]] && grep -q '\[tool\.ruff\]' "$root/pyproject.toml" 2>/dev/null; then
                echo "ruff"; return
            fi
            if [[ -f "$root/pyproject.toml" ]] && grep -q '\[tool\.black\]' "$root/pyproject.toml" 2>/dev/null; then
                echo "black"; return
            fi
            if [[ -f "$root/setup.cfg" ]] && grep -q '\[flake8\]' "$root/setup.cfg" 2>/dev/null; then
                echo "flake8"; return
            fi
        fi

        if [[ "$ext" =~ ^(ts|tsx|js|jsx)$ ]]; then
            if [[ -f "$root/biome.json" || -f "$root/biome.jsonc" ]]; then
                echo "biome"; return
            fi
            if [[ -f "$root/package.json" ]] && grep -q '"eslint"' "$root/package.json" 2>/dev/null; then
                echo "eslint"; return
            fi
            if ls "$root"/.prettierrc* 1>/dev/null 2>&1; then
                echo "prettier"; return
            fi
            if [[ -f "$root/package.json" ]] && grep -q '"prettier"' "$root/package.json" 2>/dev/null; then
                echo "prettier"; return
            fi
        fi

        if [[ "$ext" == "rs" && -f "$root/Cargo.toml" ]]; then
            echo "clippy"; return
        fi

        if [[ "$ext" == "go" ]]; then
            if [[ -f "$root/.golangci.yml" || -f "$root/.golangci.yaml" ]]; then
                echo "golangci-lint"; return
            fi
            if [[ -f "$root/go.mod" ]]; then
                echo "govet"; return
            fi
        fi

        if [[ -f "$root/Makefile" ]] && grep -q '^lint:' "$root/Makefile" 2>/dev/null; then
            echo "make-lint"; return
        fi

        echo "none"
    }

    CACHE_STALE=false
    if [[ -f "$CACHE_FILE" ]]; then
        for cfg in "$_LINT_PROJECT_ROOT/pyproject.toml" "$_LINT_PROJECT_ROOT/setup.cfg" \
                   "$_LINT_PROJECT_ROOT/biome.json" "$_LINT_PROJECT_ROOT/biome.jsonc" \
                   "$_LINT_PROJECT_ROOT/package.json" "$_LINT_PROJECT_ROOT/Cargo.toml" \
                   "$_LINT_PROJECT_ROOT/.golangci.yml" "$_LINT_PROJECT_ROOT/.golangci.yaml" \
                   "$_LINT_PROJECT_ROOT/go.mod" "$_LINT_PROJECT_ROOT/Makefile"; do
            if [[ -f "$cfg" && "$cfg" -nt "$CACHE_FILE" ]]; then
                CACHE_STALE=true; break
            fi
        done
        for cfg in "$_LINT_PROJECT_ROOT"/.prettierrc*; do
            if [[ -f "$cfg" && "$cfg" -nt "$CACHE_FILE" ]]; then
                CACHE_STALE=true; break
            fi
        done
    fi

    if [[ -f "$CACHE_FILE" && "$CACHE_STALE" == "false" ]]; then
        LINTER=$(cat "$CACHE_FILE")
    else
        LINTER=$(_detect_linter "$_LINT_PROJECT_ROOT" "$FILE_PATH")
        echo "$LINTER" > "$CACHE_FILE"
    fi

    if [[ "$LINTER" != "none" ]]; then
        BREAKER_FILE="${_LINT_CLAUDE_DIR}/.lint-breaker"
        _LINT_SKIP=false

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
                _LINT_SKIP=true
            elif [[ "$BREAKER_STATE" == "open" && "$ELAPSED" -ge 300 ]]; then
                echo "half-open|$BREAKER_COUNT|$BREAKER_TIME" > "$BREAKER_FILE"
            fi
        fi

        if [[ "$_LINT_SKIP" == "false" ]]; then
            _run_lint() {
                local linter="$1"
                local file="$2"
                local root="$3"
                case "$linter" in
                    ruff)
                        if command -v ruff &>/dev/null; then
                            (cd "$root" && ruff check --fix "$file" 2>&1 && ruff format "$file" 2>&1)
                        fi ;;
                    black)
                        if command -v black &>/dev/null; then
                            (cd "$root" && black "$file" 2>&1)
                        fi ;;
                    flake8)
                        if command -v flake8 &>/dev/null; then
                            (cd "$root" && flake8 "$file" 2>&1)
                        fi ;;
                    biome)
                        if command -v biome &>/dev/null; then
                            (cd "$root" && biome check --write "$file" 2>&1)
                        elif [[ -f "$root/node_modules/.bin/biome" ]]; then
                            (cd "$root" && npx biome check --write "$file" 2>&1)
                        fi ;;
                    eslint)
                        if [[ -f "$root/node_modules/.bin/eslint" ]]; then
                            (cd "$root" && npx eslint --fix "$file" 2>&1)
                        elif command -v eslint &>/dev/null; then
                            (cd "$root" && eslint --fix "$file" 2>&1)
                        fi ;;
                    prettier)
                        if [[ -f "$root/node_modules/.bin/prettier" ]]; then
                            (cd "$root" && npx prettier --write "$file" 2>&1)
                        elif command -v prettier &>/dev/null; then
                            (cd "$root" && prettier --write "$file" 2>&1)
                        fi ;;
                    clippy)
                        if command -v cargo &>/dev/null; then
                            (cd "$root" && cargo clippy -- -D warnings 2>&1)
                        fi ;;
                    golangci-lint)
                        if command -v golangci-lint &>/dev/null; then
                            (cd "$root" && golangci-lint run "$file" 2>&1)
                        fi ;;
                    govet)
                        if command -v go &>/dev/null; then
                            (cd "$root" && go vet "$file" 2>&1)
                        fi ;;
                    make-lint)
                        (cd "$root" && make lint 2>&1) ;;
                esac
            }

            LINT_EXIT=0
            LINT_OUTPUT=$(_run_lint "$LINTER" "$FILE_PATH" "$_LINT_PROJECT_ROOT" 2>&1) || LINT_EXIT=$?

            if [[ "$LINT_EXIT" -ne 0 ]]; then
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

                echo "Lint errors ($LINTER) in $FILE_PATH:" >&2
                echo "$LINT_OUTPUT" >&2
                exit 2
            fi

            echo "closed|0|$(date +%s)" > "$BREAKER_FILE"
        fi
    fi
fi

exit 0
