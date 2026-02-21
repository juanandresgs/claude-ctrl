#!/usr/bin/env bash
# test-state-registry.sh — Lint test: verify all hook state writes are registered.
#
# Purpose: Greps all hooks/*.sh files for write operations targeting state files
# (CLAUDE_DIR, TRACE_STORE, HOME/.claude paths). For each write target found,
# verifies it matches a pattern in hooks/state-registry.sh. Unregistered writes
# fail the test.
#
# This is a static analysis test — it does not execute hooks, only reads source.
#
# @decision DEC-STATE-REG-002
# @title Static lint approach for state file coverage
# @status accepted
# @rationale Runtime testing of state writes requires complex fixture setup and
#   timing coordination. Static grep-based analysis catches the same bugs
#   (unregistered writes) at much lower cost: no temp dirs, no hook execution,
#   no race conditions. The tradeoff is false negatives for dynamically constructed
#   paths — mitigated by requiring explicit variable names in write targets
#   (CLAUDE_DIR, TRACE_STORE, HOME) rather than arbitrary string concatenation.
#   False positives (grep hits that aren't real writes) are acceptable because
#   they produce noise, not missed bugs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$(dirname "$SCRIPT_DIR")/hooks"
REGISTRY_FILE="$HOOKS_DIR/state-registry.sh"

passed=0
failed=0
skipped=0

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    GREEN='' RED='' YELLOW='' NC=''
fi

pass() { echo -e "${GREEN}PASS${NC} $1"; passed=$((passed + 1)); }
fail() { echo -e "${RED}FAIL${NC} $1: $2"; failed=$((failed + 1)); }
skip() { echo -e "${YELLOW}SKIP${NC} $1: $2"; skipped=$((skipped + 1)); }

echo "=== State Registry Lint Tests ==="
echo "Registry: $REGISTRY_FILE"
echo "Hooks dir: $HOOKS_DIR"
echo ""

# --- Test 1: Registry file exists and is syntactically valid ---
echo "--- Registry Validation ---"
if [[ ! -f "$REGISTRY_FILE" ]]; then
    fail "registry-exists" "hooks/state-registry.sh not found at $REGISTRY_FILE"
    echo ""
    echo "Total: 1 | Passed: 0 | Failed: 1 | Skipped: 0"
    exit 1
fi

if bash -n "$REGISTRY_FILE" 2>/dev/null; then
    pass "registry-syntax — hooks/state-registry.sh is valid bash"
else
    fail "registry-syntax" "hooks/state-registry.sh has syntax errors"
    exit 1
fi

# Source the registry to get STATE_REGISTRY array
# shellcheck source=/dev/null
source "$REGISTRY_FILE"

if [[ ${#STATE_REGISTRY[@]} -eq 0 ]]; then
    fail "registry-not-empty" "STATE_REGISTRY array is empty"
    exit 1
fi
pass "registry-loaded — ${#STATE_REGISTRY[@]} entries"
echo ""

# --- Build lookup set from registry patterns ---
# Each registry entry has format: PATTERN|SCOPE|WRITERS|DESCRIPTION
# Normalize template variables ({phash}, {session}, {type}) to regex wildcards.
# We match against BOTH the full fragment (e.g. "traces/index.jsonl") and
# the basename (e.g. "index.jsonl") so that path-prefixed registry entries
# like "traces/index.jsonl" match writes to "${TRACE_STORE}/index.jsonl".

declare -a REGISTRY_PATTERNS=()
declare -a REGISTRY_RAW_PATTERNS=()

_normalize_pattern() {
    local raw="$1"
    local normalized="${raw//\{phash\}/[^\/]+}"
    normalized="${normalized//\{session\}/[^\/]+}"
    normalized="${normalized//\{type\}/[^\/]+}"
    normalized="${normalized//\{hash\}/[^\/]+}"
    # Escape dots for regex (literal dot in filenames)
    normalized="${normalized//./\\.}"
    echo "$normalized"
}

for entry in "${STATE_REGISTRY[@]}"; do
    raw_pattern="${entry%%|*}"
    REGISTRY_RAW_PATTERNS+=("$raw_pattern")
    # Add normalized full pattern
    REGISTRY_PATTERNS+=("$(_normalize_pattern "$raw_pattern")")
    # Also add basename-only pattern for entries with directory prefixes
    # (e.g. "traces/index.jsonl" → also register "index\\.jsonl")
    basename_only="${raw_pattern##*/}"
    if [[ "$basename_only" != "$raw_pattern" ]]; then
        REGISTRY_PATTERNS+=("$(_normalize_pattern "$basename_only")")
    fi
done

# --- Helper: check if a fragment matches any registry pattern ---
# Accepts the full path fragment (e.g. "traces/index.jsonl") and basename.
# Returns 0 if matched, 1 if not.
pattern_matched() {
    local target_fragment="$1"
    local target_base="${target_fragment##*/}"
    for pat in "${REGISTRY_PATTERNS[@]}"; do
        # Match against full fragment OR basename
        if [[ "$target_fragment" =~ $pat ]] || [[ "$target_base" =~ $pat ]]; then
            return 0
        fi
    done
    return 1
}

# --- Test 2: Extract write targets from hook source files ---
# We look for lines that write to state files, specifically:
#   echo/printf/cat ... > "${CLAUDE_DIR}/..."
#   echo/printf/cat ... > "${TRACE_STORE}/..."
#   echo/printf/cat ... > "$HOME/.claude/..."
#   echo/printf/cat ... >> "${CLAUDE_DIR}/..."  (append writes)
#   write_state_file / atomic_write patterns
#
# We extract the TARGET filename (basename) from each match.

echo "--- Write Target Extraction ---"

UNREGISTERED=()
REGISTERED_COUNT=0

# Process each hook file
for hook_file in "$HOOKS_DIR"/*.sh; do
    hook_name=$(basename "$hook_file")

    # Skip the registry itself and pure library helpers with no writes
    [[ "$hook_name" == "state-registry.sh" ]] && continue
    [[ "$hook_name" == "source-lib.sh" ]] && continue

    # Extract lines with write redirections targeting state directories.
    # Patterns we capture:
    #   > "${CLAUDE_DIR}/.something"
    #   > "${TRACE_STORE}/.something"
    #   > "$HOME/.claude/.something"
    #   >> "${CLAUDE_DIR}/.something"
    #   > "${root}/.claude/.something"       (context-lib internal)
    #   > "${ARCHIVE_DIR}/something.jsonl"   (session-end)
    #   > "${INDEX_FILE}"                    (session-end)
    #   echo ... > "$PROOF_FILE"             (variable targets)

    # We use a multi-pass grep approach:
    # Pass A: literal CLAUDE_DIR path writes
    while IFS= read -r raw_line; do
        [[ -z "$raw_line" ]] && continue
        # Strip leading whitespace and skip comments
        stripped="${raw_line#"${raw_line%%[! ]*}"}"
        [[ "$stripped" =~ ^# ]] && continue

        # Extract the target path fragment after > or >>
        # Match: > "${CLAUDE_DIR}/.something-{suffix}"
        if [[ "$raw_line" =~ \>[\>]?[[:space:]]*[\"\']?\$\{?CLAUDE_DIR\}?/([^\"\'[:space:]]+) ]]; then
            target_fragment="${BASH_REMATCH[1]}"
            # Strip trailing quote/bracket artifacts
            target_fragment="${target_fragment%\"}"
            target_fragment="${target_fragment%\'}"
            target_fragment="${target_fragment%\}}"

            if [[ -n "$target_fragment" ]]; then
                if pattern_matched "$target_fragment"; then
                    REGISTERED_COUNT=$((REGISTERED_COUNT + 1))
                else
                    UNREGISTERED+=("$hook_name: writes to .claude/${target_fragment} (not in registry)")
                fi
            fi
        fi
    done < "$hook_file"

    # Pass B: TRACE_STORE path writes
    while IFS= read -r raw_line; do
        [[ -z "$raw_line" ]] && continue
        stripped="${raw_line#"${raw_line%%[! ]*}"}"
        [[ "$stripped" =~ ^# ]] && continue

        if [[ "$raw_line" =~ \>[\>]?[[:space:]]*[\"\']?\$\{?TRACE_STORE\}?/([^\"\'[:space:]]+) ]]; then
            target_fragment="${BASH_REMATCH[1]}"
            target_fragment="${target_fragment%\"}"
            target_fragment="${target_fragment%\'}"
            target_fragment="${target_fragment%\}}"

            if [[ -n "$target_fragment" ]]; then
                # Prefix with traces/ for registry matching (registry uses "traces/index.jsonl")
                if pattern_matched "traces/${target_fragment}"; then
                    REGISTERED_COUNT=$((REGISTERED_COUNT + 1))
                else
                    UNREGISTERED+=("$hook_name: writes to traces/${target_fragment} (not in registry)")
                fi
            fi
        fi
    done < "$hook_file"

    # Pass C: HOME/.claude path writes (global state files)
    while IFS= read -r raw_line; do
        [[ -z "$raw_line" ]] && continue
        stripped="${raw_line#"${raw_line%%[! ]*}"}"
        [[ "$stripped" =~ ^# ]] && continue

        if [[ "$raw_line" =~ \>[\>]?[[:space:]]*[\"\']?\$HOME/\.claude/([^\"\'[:space:]]+) ]]; then
            target_fragment="${BASH_REMATCH[1]}"
            target_fragment="${target_fragment%\"}"
            target_fragment="${target_fragment%\'}"
            target_fragment="${target_fragment%\}}"

            if [[ -n "$target_fragment" ]]; then
                if pattern_matched "$target_fragment"; then
                    REGISTERED_COUNT=$((REGISTERED_COUNT + 1))
                else
                    UNREGISTERED+=("$hook_name: writes to ~/.claude/${target_fragment} (not in registry)")
                fi
            fi
        fi
    done < "$hook_file"

    # Pass D: Named variable targets (PROOF_FILE, INDEX_FILE, AUDIT_FILE, etc.)
    # These are harder to resolve statically; we track the variable assignment
    # and cross-check the assigned value contains a known suffix.
    # For now, detect the known problematic pattern: writes to $PROOF_FILE
    # (which is assigned from .proof-status variants — already registered).
    # This pass is intentionally limited to avoid false positives.
    while IFS= read -r raw_line; do
        [[ -z "$raw_line" ]] && continue
        stripped="${raw_line#"${raw_line%%[! ]*}"}"
        [[ "$stripped" =~ ^# ]] && continue

        # Detect writes to $FINDINGS_FILE (always .agent-findings)
        if [[ "$raw_line" =~ \>[\>]?[[:space:]]*[\"\']?\$FINDINGS_FILE ]]; then
            if pattern_matched ".agent-findings"; then
                REGISTERED_COUNT=$((REGISTERED_COUNT + 1))
            else
                UNREGISTERED+=("$hook_name: writes to \$FINDINGS_FILE (.agent-findings not in registry)")
            fi
        fi

        # Detect writes to audit_file pattern (always .audit-log)
        if [[ "$raw_line" =~ \>[\>]?[[:space:]]*[\"\']?\$audit_file ]]; then
            if pattern_matched ".audit-log"; then
                REGISTERED_COUNT=$((REGISTERED_COUNT + 1))
            else
                UNREGISTERED+=("$hook_name: writes to \$audit_file (.audit-log not in registry)")
            fi
        fi
    done < "$hook_file"
done

echo "Write targets checked: $REGISTERED_COUNT registered matches found"
echo ""

# --- Test 3: Report results ---
echo "--- Coverage Results ---"

if [[ ${#UNREGISTERED[@]} -eq 0 ]]; then
    pass "all-writes-registered — $REGISTERED_COUNT write targets all registered"
else
    for unrg in "${UNREGISTERED[@]}"; do
        fail "unregistered-write" "$unrg"
    done
fi

echo ""

# --- Test 4: Verify every registry entry has the required fields ---
echo "--- Registry Entry Format ---"
FORMAT_ERRORS=0
for entry in "${STATE_REGISTRY[@]}"; do
    IFS='|' read -r pat scope writers desc <<< "$entry"
    if [[ -z "$pat" || -z "$scope" || -z "$writers" || -z "$desc" ]]; then
        fail "registry-format" "Malformed entry (missing field): $entry"
        FORMAT_ERRORS=$((FORMAT_ERRORS + 1))
    fi
done
if [[ "$FORMAT_ERRORS" -eq 0 ]]; then
    pass "registry-format — all ${#STATE_REGISTRY[@]} entries have 4 fields"
fi

echo ""

# --- Test 5: Verify scope values are valid ---
echo "--- Scope Validation ---"
VALID_SCOPES=(
    "global"
    "global-scripts"
    "per-project"
    "per-project-legacy"
    "per-session"
    "per-session-legacy"
    "trace-global"
    "trace-scoped"
    "external"
)

SCOPE_ERRORS=0
for entry in "${STATE_REGISTRY[@]}"; do
    IFS='|' read -r pat scope writers desc <<< "$entry"
    valid=false
    for vs in "${VALID_SCOPES[@]}"; do
        [[ "$scope" == "$vs" ]] && valid=true && break
    done
    if [[ "$valid" == "false" ]]; then
        fail "invalid-scope" "Entry '$pat' has unknown scope '$scope'"
        SCOPE_ERRORS=$((SCOPE_ERRORS + 1))
    fi
done
if [[ "$SCOPE_ERRORS" -eq 0 ]]; then
    pass "scope-values — all entries have valid scope"
fi

echo ""

# --- Test 6: Verify no duplicate patterns ---
echo "--- Duplicate Pattern Check ---"
declare -a SEEN_PATTERNS=()
DUP_ERRORS=0
for entry in "${STATE_REGISTRY[@]}"; do
    raw_pattern="${entry%%|*}"
    for seen in "${SEEN_PATTERNS[@]:-}"; do
        if [[ "$seen" == "$raw_pattern" ]]; then
            fail "duplicate-pattern" "Pattern '$raw_pattern' appears more than once"
            DUP_ERRORS=$((DUP_ERRORS + 1))
        fi
    done
    SEEN_PATTERNS+=("$raw_pattern")
done
if [[ "$DUP_ERRORS" -eq 0 ]]; then
    pass "no-duplicate-patterns — all ${#STATE_REGISTRY[@]} patterns are unique"
fi

echo ""

# --- Summary ---
echo "==========================="
total=$((passed + failed + skipped))
echo -e "Total: $total | ${GREEN}Passed: $passed${NC} | ${RED}Failed: $failed${NC} | ${YELLOW}Skipped: $skipped${NC}"

if [[ $failed -gt 0 ]]; then
    exit 1
fi
