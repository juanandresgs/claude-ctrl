#!/usr/bin/env bash
# lint-test-patterns.sh — Scan scenario and acceptance test files for stale
# patterns that survived past policy-engine migrations.
#
# Only executable lines are checked (lines not starting with #).
# Exits 0 if the suite is clean, 1 if any warnings are emitted.
#
# Usage:  bash tests/lint-test-patterns.sh [dir ...]
#         Default dirs: tests/scenarios/ tests/acceptance/
#
# @decision DEC-LINT-001
# @title lint-test-patterns.sh is the canonical stale-pattern gate
# @status accepted
# @rationale INIT-PE deleted the shell policy layer; the acceptance and
#   scenario suites still contained references to the deleted files and
#   legacy dispatch/test-status patterns. A lint gate applied at commit time
#   prevents re-accumulation of these stale references. Patterns are checked
#   only on non-comment lines so intentional documentation inside test files
#   (describing what used to exist) does not trigger false positives.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default scan directories; caller may override by passing paths as arguments
if [[ $# -gt 0 ]]; then
    SCAN_DIRS=("$@")
else
    SCAN_DIRS=(
        "$REPO_ROOT/tests/scenarios"
        "$REPO_ROOT/tests/acceptance"
    )
fi

WARNINGS=0

# emit_warning <file> <lineno> <description>
emit_warning() {
    local file="$1"
    local lineno="$2"
    local desc="$3"
    echo "WARNING: ${file}:${lineno} — ${desc}"
    WARNINGS=$(( WARNINGS + 1 ))
}

# check_file <path>
# Reads each line; skips comment lines (trimmed first char is '#').
# Applies all stale-pattern checks to every executable line.
check_file() {
    local file="$1"
    local lineno=0

    while IFS= read -r raw_line; do
        lineno=$(( lineno + 1 ))
        # Strip leading whitespace to detect comment lines
        local trimmed="${raw_line#"${raw_line%%[! ]*}"}"
        # Skip blank lines and comment lines
        [[ -z "$trimmed" || "${trimmed:0:1}" == "#" ]] && continue

        # Pattern 1: Deleted hook references
        if [[ "$raw_line" == *"hooks/guard.sh"* ]]; then
            emit_warning "$file" "$lineno" "stale ref: hooks/guard.sh (deleted in INIT-PE)"
        fi
        if [[ "$raw_line" == *"hooks/lib/write-policy.sh"* ]]; then
            emit_warning "$file" "$lineno" "stale ref: hooks/lib/write-policy.sh (deleted in INIT-PE)"
        fi
        if [[ "$raw_line" == *"hooks/lib/bash-policy.sh"* ]]; then
            emit_warning "$file" "$lineno" "stale ref: hooks/lib/bash-policy.sh (deleted in INIT-PE)"
        fi
        if [[ "$raw_line" == *"hooks/lib/plan-policy.sh"* ]]; then
            emit_warning "$file" "$lineno" "stale ref: hooks/lib/plan-policy.sh (deleted in INIT-PE)"
        fi
        if [[ "$raw_line" == *"hooks/lib/dispatch-helpers.sh"* ]]; then
            emit_warning "$file" "$lineno" "stale ref: hooks/lib/dispatch-helpers.sh (deleted in INIT-PE)"
        fi

        # Pattern 2: Flat-file test-status writes
        if [[ "$raw_line" =~ echo.*\.test-status ]]; then
            emit_warning "$file" "$lineno" "stale flat-file write: echo > .test-status (replaced by SQLite)"
        fi

        # Pattern 3: Stale dispatch_queue enqueue or dispatch_status implementer
        if [[ "$raw_line" == *"dispatch enqueue"* ]]; then
            emit_warning "$file" "$lineno" "stale dispatch: 'dispatch enqueue' (queue replaced by completion records, DEC-WS6-001)"
        fi
        if [[ "$raw_line" =~ dispatch_status.*implementer ]]; then
            emit_warning "$file" "$lineno" "stale dispatch: dispatch_status implementer pattern (removed in INIT-PE)"
        fi

        # Pattern 4: W1-era policy count assertion
        if [[ "$raw_line" == *'"count": 0'* ]]; then
            emit_warning "$file" "$lineno" "suspect W1-era policy assertion: \"count\": 0 near policy check"
        fi

        # Pattern 5 (removed): doc header detection had too many false positives.
        # The doc_gate policy enforces headers at runtime — no need to lint for
        # missing headers in test fixtures statically.

    done < "$file"
}

# Collect all .sh files from all scan directories
# Skip the lint patterns test itself (it contains synthetic bad fixtures in heredocs)
SELF_BASENAME="test-lint-patterns.sh"
FILES_CHECKED=0
for dir in "${SCAN_DIRS[@]}"; do
    if [[ ! -d "$dir" ]]; then
        echo "WARNING: scan directory not found: $dir" >&2
        continue
    fi
    while IFS= read -r -d '' f; do
        [[ "$(basename "$f")" == "$SELF_BASENAME" ]] && continue
        check_file "$f"
        FILES_CHECKED=$(( FILES_CHECKED + 1 ))
    done < <(find "$dir" -maxdepth 1 -name "*.sh" -print0 2>/dev/null)
done

if [[ $WARNINGS -eq 0 ]]; then
    echo "OK: lint-test-patterns clean ($FILES_CHECKED files checked, 0 warnings)"
    exit 0
else
    echo "FAIL: lint-test-patterns found $WARNINGS warning(s) across $FILES_CHECKED files"
    exit 1
fi
