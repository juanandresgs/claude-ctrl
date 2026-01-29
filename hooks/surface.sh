#!/usr/bin/env bash
set -euo pipefail

# Session-end decision validation and audit.
# Stop hook — runs at session end.
#
# Performs the full /surface pipeline: extract → validate → report.
# No external documentation is generated (Code is Truth).
# Reports: files changed, @decision coverage, validation issues.
#
# This replaces both the old surface.sh Stop hook and the /surface command.

source "$(dirname "$0")/log.sh"

# Get project root (prefers CLAUDE_PROJECT_DIR)
PROJECT_ROOT=$(detect_project_root)

# Find session tracking file (try session-scoped first, fall back to legacy)
SESSION_ID="${CLAUDE_SESSION_ID:-}"
if [[ -n "$SESSION_ID" && -f "$PROJECT_ROOT/.claude/.session-decisions-${SESSION_ID}" ]]; then
    CHANGES="$PROJECT_ROOT/.claude/.session-decisions-${SESSION_ID}"
elif [[ -f "$PROJECT_ROOT/.claude/.session-decisions" ]]; then
    CHANGES="$PROJECT_ROOT/.claude/.session-decisions"
else
    # Also check glob for any session file
    CHANGES=$(ls "$PROJECT_ROOT/.claude/.session-decisions"* 2>/dev/null | head -1 || echo "")
fi

# Exit silently if no changes tracked
[[ -z "$CHANGES" || ! -f "$CHANGES" ]] && exit 0

# --- Count source file changes ---
SOURCE_EXTS='(ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh)'
SOURCE_COUNT=$(grep -cE "\\.${SOURCE_EXTS}$" "$CHANGES" 2>/dev/null || echo 0)

if [[ "$SOURCE_COUNT" -eq 0 ]]; then
    rm -f "$CHANGES"
    exit 0
fi

log_info "SURFACE" "$SOURCE_COUNT source files modified this session"

# --- Extract: find all @decision annotations in the project ---
# Determine source directories to scan
SCAN_DIRS=()
for dir in src lib app pkg cmd internal; do
    [[ -d "$PROJECT_ROOT/$dir" ]] && SCAN_DIRS+=("$PROJECT_ROOT/$dir")
done
# Fall back to project root if no standard dirs found
[[ ${#SCAN_DIRS[@]} -eq 0 ]] && SCAN_DIRS=("$PROJECT_ROOT")

DECISION_PATTERN='@decision|# DECISION:|// DECISION\('
TOTAL_DECISIONS=0
DECISIONS_IN_CHANGED=0
MISSING_DECISIONS=()
VALIDATION_ISSUES=()

# Count total decisions in codebase
for dir in "${SCAN_DIRS[@]}"; do
    count=$(grep -rlE "$DECISION_PATTERN" "$dir" \
        --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' \
        --include='*.py' --include='*.rs' --include='*.go' --include='*.java' \
        --include='*.c' --include='*.cpp' --include='*.h' --include='*.hpp' \
        --include='*.sh' --include='*.rb' --include='*.php' \
        2>/dev/null | wc -l | tr -d ' ')
    TOTAL_DECISIONS=$((TOTAL_DECISIONS + count))
done

# --- Validate: check changed files ---
while IFS= read -r file; do
    [[ ! -f "$file" ]] && continue
    # Only check source files
    [[ ! "$file" =~ \.(ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh)$ ]] && continue
    # Skip test/config/generated
    [[ "$file" =~ (\.test\.|\.spec\.|__tests__|\.config\.|\.generated\.|node_modules|vendor|dist|\.git) ]] && continue

    # Check if file has @decision
    if grep -qE "$DECISION_PATTERN" "$file" 2>/dev/null; then
        ((DECISIONS_IN_CHANGED++)) || true

        # Validate decision has rationale
        if ! grep -qE '@rationale|Rationale:' "$file" 2>/dev/null; then
            VALIDATION_ISSUES+=("$file: @decision missing rationale")
        fi
    else
        # Check if file is significant (50+ lines)
        line_count=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
        if [[ "$line_count" -ge 50 ]]; then
            MISSING_DECISIONS+=("$file ($line_count lines, no @decision)")
        fi
    fi
done < <(sort -u "$CHANGES")

# --- Report ---
log_info "SURFACE" "Scanned project: $TOTAL_DECISIONS @decision annotations found"
log_info "SURFACE" "$DECISIONS_IN_CHANGED decisions in files changed this session"

if [[ ${#MISSING_DECISIONS[@]} -gt 0 ]]; then
    log_info "SURFACE" "Missing annotations in significant files:"
    for missing in "${MISSING_DECISIONS[@]}"; do
        log_info "SURFACE" "  - $missing"
    done
fi

if [[ ${#VALIDATION_ISSUES[@]} -gt 0 ]]; then
    log_info "SURFACE" "Validation issues:"
    for issue in "${VALIDATION_ISSUES[@]}"; do
        log_info "SURFACE" "  - $issue"
    done
fi

# Summary
TOTAL_CHANGED=$(sort -u "$CHANGES" | grep -cE "\\.${SOURCE_EXTS}$" 2>/dev/null || echo 0)
MISSING_COUNT=${#MISSING_DECISIONS[@]}
ISSUE_COUNT=${#VALIDATION_ISSUES[@]}

if [[ "$MISSING_COUNT" -eq 0 && "$ISSUE_COUNT" -eq 0 ]]; then
    log_info "OUTCOME" "Documentation complete. $TOTAL_CHANGED source files changed, all properly annotated."
else
    log_info "OUTCOME" "$TOTAL_CHANGED source files changed. $MISSING_COUNT need @decision, $ISSUE_COUNT have validation issues."
fi

# Clean up session tracking
rm -f "$CHANGES"
exit 0
