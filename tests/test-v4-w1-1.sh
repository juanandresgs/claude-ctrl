#!/usr/bin/env bash
# test-v4-w1-1.sh — Tests for v4 Release W1-1 changes
#
# Validates:
#   1. Lint cooldown rework: single tmp/.lint-cooldowns file instead of per-file sentinels
#   2. Orchestrator SID flat-file removal: session-init no longer writes .orchestrator-sid
#   3. Gitignore additions: .lint-cooldown-* and other runtime files added
#
# @decision DEC-V4-LINT-001
# @title Lint cooldown consolidation test suite
# @status accepted
# @rationale Per-file lint cooldown sentinels created 200+ orphan files (one per
#   edited file, never cleaned up). The rework consolidates all cooldowns into a
#   single tmp/.lint-cooldowns file with path|timestamp lines. These tests verify:
#   - No per-file .lint-cooldown-* files are created
#   - A single tmp/.lint-cooldowns file is used instead
#   - Cooldown suppression works within 3 seconds
#   - Stale entries (>3s) are updated
#
#   Testing approach: CLAUDE_PROJECT_DIR overrides detect_project_root() so
#   CLAUDE_DIR resolves to an isolated temp dir. Stdin piped via temp file to
#   avoid process substitution issues in subshell contexts.
#
# @decision DEC-V4-ORCH-001
# @title Orchestrator SID flat-file removal test suite
# @status accepted
# @rationale SQLite is now the sole authority for orchestrator_sid. The flat-file
#   .orchestrator-sid was a migration fallback (DEC-STATE-UNIFY-004). These tests
#   verify the fallback writes/reads/deletes are fully removed.
#
# Usage: bash tests/test-v4-w1-1.sh
# Returns: 0 if all tests pass, 1 if any fail

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="${WORKTREE_ROOT}/hooks"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1 — ${2:-}"; FAIL=$((FAIL + 1)); }

# Shared cleanup list for temp directories and files
CLEANUP_DIRS=()
CLEANUP_FILES=()

cleanup() {
    rm -rf "${CLEANUP_DIRS[@]:-}" 2>/dev/null || true
    rm -f "${CLEANUP_FILES[@]:-}" 2>/dev/null || true
}
trap cleanup EXIT

# Helper: create an isolated temp environment
make_temp_env() {
    local d
    d=$(mktemp -d)
    CLEANUP_DIRS+=("$d")
    mkdir -p "$d/.claude"
    git -C "$d" init -q -b feature/test-branch 2>/dev/null
    git -C "$d" config user.email "test@test.com" 2>/dev/null
    git -C "$d" config user.name "Test" 2>/dev/null
    echo "$d"
}

# Helper: create a temp stdin file for hook input.
# Returns the temp file path. Added to CLEANUP_FILES automatically.
# Uses python3 to produce valid JSON with properly escaped content.
make_hook_input() {
    local file_path="$1"
    local content="${2:-#!/usr/bin/env bash\necho hello\n}"
    local t
    t=$(mktemp)
    CLEANUP_FILES+=("$t")
    python3 -c "
import json
data = {'tool_name': 'Write', 'tool_input': {'file_path': '$file_path', 'content': '$content'}}
print(json.dumps(data))
" > "$t"
    echo "$t"
}

# Helper: run lint.sh with an isolated CLAUDE_PROJECT_DIR.
# Args: env_dir file_path [content]
# Uses temp file for stdin to avoid process substitution issues.
run_lint() {
    local env_dir="$1"
    local file_path="$2"
    local content="${3:-#!/usr/bin/env bash\necho hello\n}"
    local input_file
    input_file=$(make_hook_input "$file_path" "$content")
    CLAUDE_PROJECT_DIR="$env_dir" \
    bash "$HOOKS_DIR/lint.sh" < "$input_file" >/dev/null 2>/dev/null || true
}

echo "=== v4 W1-1: Lint Cooldown Rework + Orchestrator SID Flat-File Removal ==="
echo ""

# ============================================================
# SECTION 1: Lint Cooldown Rework (DEC-V4-LINT-001)
# ============================================================

echo "=== Section 1: Lint Cooldown Rework ==="
echo ""

# Test 1.1: lint.sh does NOT create per-file .lint-cooldown-* sentinel files
# After the rework, no .lint-cooldown-<sanitized_path> files should be created.
echo "=== Test 1.1: lint.sh creates no per-file .lint-cooldown-* sentinel files ==="

T1_ENV=$(make_temp_env)
T1_CLAUDE="$T1_ENV/.claude"
mkdir -p "$T1_ENV/hooks"
printf '#!/usr/bin/env bash\necho hello\n' > "$T1_ENV/hooks/hook1.sh"

run_lint "$T1_ENV" "$T1_ENV/hooks/hook1.sh"

T1_SENTINEL_COUNT=$(find "$T1_CLAUDE" -maxdepth 1 -name '.lint-cooldown-*' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$T1_SENTINEL_COUNT" -eq 0 ]]; then
    pass "Test 1.1: lint.sh creates no per-file .lint-cooldown-* sentinel files"
else
    fail "Test 1.1: lint.sh creates no per-file .lint-cooldown-* sentinel files" \
         "found $T1_SENTINEL_COUNT sentinel file(s): $(find "$T1_CLAUDE" -maxdepth 1 -name '.lint-cooldown-*' | head -3)"
fi

echo ""

# Test 1.2: lint.sh creates/updates tmp/.lint-cooldowns consolidated file
echo "=== Test 1.2: lint.sh writes cooldown to tmp/.lint-cooldowns ==="

T2_ENV=$(make_temp_env)
T2_CLAUDE="$T2_ENV/.claude"
mkdir -p "$T2_ENV/hooks"
printf '#!/usr/bin/env bash\necho world\n' > "$T2_ENV/hooks/hook2.sh"

run_lint "$T2_ENV" "$T2_ENV/hooks/hook2.sh"

T2_COOLDOWN_FILE="$T2_CLAUDE/tmp/.lint-cooldowns"
if [[ -f "$T2_COOLDOWN_FILE" ]]; then
    pass "Test 1.2a: tmp/.lint-cooldowns file is created in CLAUDE_DIR"
    # Verify it contains the path
    if grep -qF "$T2_ENV/hooks/hook2.sh" "$T2_COOLDOWN_FILE" 2>/dev/null; then
        pass "Test 1.2b: tmp/.lint-cooldowns contains the linted file path"
    else
        fail "Test 1.2b: tmp/.lint-cooldowns contains the linted file path" \
             "file content: $(cat "$T2_COOLDOWN_FILE" 2>/dev/null | head -5)"
    fi
    # Verify format is path|timestamp (second field is a digit string)
    T2_LINE=$(grep -F "$T2_ENV/hooks/hook2.sh" "$T2_COOLDOWN_FILE" 2>/dev/null | head -1)
    T2_TS=$(echo "$T2_LINE" | cut -d'|' -f2)
    if [[ "$T2_TS" =~ ^[0-9]+$ ]]; then
        pass "Test 1.2c: cooldown entry format is path|timestamp"
    else
        fail "Test 1.2c: cooldown entry format is path|timestamp" \
             "got line: '$T2_LINE' (ts='$T2_TS')"
    fi
else
    fail "Test 1.2a: tmp/.lint-cooldowns file is created in CLAUDE_DIR" \
         "file not found at $T2_COOLDOWN_FILE (files in .claude: $(ls "$T2_CLAUDE"/ 2>/dev/null | head -5))"
    fail "Test 1.2b: tmp/.lint-cooldowns contains the linted file path" \
         "cooldown file not created"
    fail "Test 1.2c: cooldown entry format is path|timestamp" \
         "cooldown file not created"
fi

echo ""

# Test 1.3: Cooldown suppresses lint when a fresh entry exists for the file
echo "=== Test 1.3: Cooldown suppresses re-lint within 3 seconds ==="

T3_ENV=$(make_temp_env)
T3_CLAUDE="$T3_ENV/.claude"
T3_TARGET="$T3_ENV/hooks/hook3.sh"
mkdir -p "$T3_ENV/hooks"
printf '#!/usr/bin/env bash\necho hello\n' > "$T3_TARGET"

# Pre-seed the cooldown file with a very recent timestamp
mkdir -p "$T3_CLAUDE/tmp"
printf '%s|%s\n' "$T3_TARGET" "$(date +%s)" > "$T3_CLAUDE/tmp/.lint-cooldowns"

T3_INPUT=$(make_hook_input "$T3_TARGET")
# Capture output — should be empty (skipped by cooldown)
T3_OUTPUT=$(
    CLAUDE_PROJECT_DIR="$T3_ENV" \
    bash "$HOOKS_DIR/lint.sh" < "$T3_INPUT" 2>/dev/null
) || true

if [[ -z "$T3_OUTPUT" ]]; then
    pass "Test 1.3: cooldown suppresses lint output within 3 seconds (empty output, exit 0)"
else
    fail "Test 1.3: cooldown suppresses lint output within 3 seconds" \
         "got non-empty output: $(echo "$T3_OUTPUT" | head -2)"
fi

echo ""

# Test 1.4: Stale cooldown entry (>3s old) allows re-lint and updates timestamp
echo "=== Test 1.4: Stale cooldown entry (>3s old) is updated after lint runs ==="

T4_ENV=$(make_temp_env)
T4_CLAUDE="$T4_ENV/.claude"
T4_TARGET="$T4_ENV/hooks/hook4.sh"
mkdir -p "$T4_ENV/hooks"
printf '#!/usr/bin/env bash\necho hello\n' > "$T4_TARGET"

# Pre-seed cooldown with a 10-second-old timestamp (stale)
mkdir -p "$T4_CLAUDE/tmp"
T4_STALE_TS=$(( $(date +%s) - 10 ))
printf '%s|%s\n' "$T4_TARGET" "$T4_STALE_TS" > "$T4_CLAUDE/tmp/.lint-cooldowns"

run_lint "$T4_ENV" "$T4_TARGET"

# After re-lint on stale entry, timestamp should be fresher than stale ts
if [[ -f "$T4_CLAUDE/tmp/.lint-cooldowns" ]]; then
    T4_NEW_TS=$(grep -F "$T4_TARGET" "$T4_CLAUDE/tmp/.lint-cooldowns" 2>/dev/null | cut -d'|' -f2 | head -1 || echo "0")
    if [[ "$T4_NEW_TS" =~ ^[0-9]+$ ]] && (( T4_NEW_TS > T4_STALE_TS )); then
        pass "Test 1.4: stale cooldown entry is updated with fresh timestamp after re-lint"
    else
        fail "Test 1.4: stale cooldown entry is updated with fresh timestamp" \
             "stale_ts=$T4_STALE_TS, new_ts='$T4_NEW_TS'"
    fi
else
    fail "Test 1.4: stale cooldown entry is updated" \
         "cooldown file not found at $T4_CLAUDE/tmp/.lint-cooldowns"
fi

echo ""

# Test 1.5: lint.sh source code audit — old pattern removed, new pattern present
echo "=== Test 1.5: lint.sh source code uses new tmp/.lint-cooldowns pattern ==="

# 1.5a: No old .lint-cooldown-<sanitized_path> creation in lint.sh source
if grep -q 'lint-cooldown-\$\|CLAUDE_DIR}\/\.lint-cooldown-\$(printf\|lint-cooldown-"$(printf' "$HOOKS_DIR/lint.sh" 2>/dev/null; then
    fail "Test 1.5a: lint.sh source has no per-file .lint-cooldown-* creation" \
         "found old per-file pattern in lint.sh"
elif grep -qE '_COOLDOWN_FILE=.*lint-cooldown-' "$HOOKS_DIR/lint.sh" 2>/dev/null; then
    fail "Test 1.5a: lint.sh source has no per-file .lint-cooldown-* sentinel creation" \
         "Found: $(grep '_COOLDOWN_FILE=.*lint-cooldown-' "$HOOKS_DIR/lint.sh" | head -2)"
else
    pass "Test 1.5a: lint.sh source has no per-file .lint-cooldown-* sentinel creation"
fi

# 1.5b: New tmp/.lint-cooldowns path is referenced
if grep -q 'tmp/\.lint-cooldowns\|tmp/\$' "$HOOKS_DIR/lint.sh" 2>/dev/null && \
   grep -q 'lint-cooldowns' "$HOOKS_DIR/lint.sh" 2>/dev/null; then
    pass "Test 1.5b: lint.sh references new consolidated tmp/.lint-cooldowns path"
else
    fail "Test 1.5b: lint.sh references new consolidated tmp/.lint-cooldowns path" \
         "pattern 'tmp/.lint-cooldowns' not found in lint.sh"
fi

echo ""

# Test 1.6: session-init.sh no longer has rm .lint-cooldown-* cleanup
# (The stale-cooldown cleanup was needed for per-file sentinels; now obsolete)
echo "=== Test 1.6: session-init.sh has no obsolete rm .lint-cooldown-* cleanup ==="

if grep -q 'rm -f.*lint-cooldown-.*\*\|rm.*lint-cooldown-' "$HOOKS_DIR/session-init.sh" 2>/dev/null; then
    fail "Test 1.6: session-init.sh has no obsolete rm .lint-cooldown-* cleanup" \
         "Found: $(grep 'rm.*lint-cooldown' "$HOOKS_DIR/session-init.sh" | head -2)"
else
    pass "Test 1.6: session-init.sh has no obsolete rm .lint-cooldown-* cleanup"
fi

echo ""

# Test 1.7: state-dotfile-bypass allowlist still covers the lint cooldown pattern
# The allowlist must permit references to .lint-cooldown (for the gitignore) but
# the new path (tmp/.lint-cooldowns) also needs to be in the allowlist.
echo "=== Test 1.7: _check_state_dotfile_bypass allowlist covers tmp/.lint-cooldowns ==="

# Check allowlist in lint.sh itself
if grep -q '\.lint-cooldown\|tmp/\.lint-cooldowns' "$HOOKS_DIR/lint.sh" 2>/dev/null; then
    # Verify the allowlist line covers the new pattern
    if grep -q '"*\.lint-cooldown\|lint-cooldowns' "$HOOKS_DIR/lint.sh" 2>/dev/null; then
        pass "Test 1.7: _check_state_dotfile_bypass allowlist covers lint cooldown patterns"
    else
        fail "Test 1.7: _check_state_dotfile_bypass allowlist covers lint cooldown patterns" \
             "allowlist may not include tmp/.lint-cooldowns pattern"
    fi
else
    fail "Test 1.7: lint cooldown pattern referenced in lint.sh" \
         "no lint-cooldown reference found in lint.sh"
fi

echo ""

# ============================================================
# SECTION 2: Orchestrator SID Flat-File Removal (DEC-V4-ORCH-001)
# ============================================================

echo "=== Section 2: Orchestrator SID Flat-File Removal ==="
echo ""

# Test 2.1: session-init.sh does NOT write .orchestrator-sid flat-file at runtime
echo "=== Test 2.1: session-init.sh does not write .orchestrator-sid flat-file at runtime ==="

T6_ENV=$(make_temp_env)
T6_CLAUDE="$T6_ENV/.claude"
T6_SESSION_ID="test-v4-orch-session-456"

T6_SINIT_INPUT=$(mktemp)
CLEANUP_FILES+=("$T6_SINIT_INPUT")
echo '{"session_event":"startup"}' > "$T6_SINIT_INPUT"

CLAUDE_PROJECT_DIR="$T6_ENV" \
CLAUDE_SESSION_ID="$T6_SESSION_ID" \
TRACE_STORE="$T6_CLAUDE/traces" \
bash "$HOOKS_DIR/session-init.sh" < "$T6_SINIT_INPUT" >/dev/null 2>/dev/null || true

T6_SID_FILE="$T6_CLAUDE/.orchestrator-sid"
if [[ ! -f "$T6_SID_FILE" ]]; then
    pass "Test 2.1: session-init.sh does NOT write .orchestrator-sid flat-file"
else
    fail "Test 2.1: session-init.sh does NOT write .orchestrator-sid flat-file" \
         ".orchestrator-sid found at $T6_SID_FILE (content: $(cat "$T6_SID_FILE" 2>/dev/null))"
fi

echo ""

# Test 2.2: session-init.sh still writes orchestrator_sid to SQLite (primary path)
echo "=== Test 2.2: session-init.sh still writes orchestrator_sid to SQLite ==="

T6_SQLITE_VAL=$(
    bash -c '
        export CLAUDE_PROJECT_DIR="'"$T6_ENV"'"
        source "'"$HOOKS_DIR"'/source-lib.sh"
        require_state
        state_read "orchestrator_sid" 2>/dev/null || echo ""
    ' 2>/dev/null || echo ""
)

if [[ "$T6_SQLITE_VAL" == "$T6_SESSION_ID" ]]; then
    pass "Test 2.2: session-init.sh writes orchestrator_sid to SQLite (primary path preserved)"
else
    fail "Test 2.2: session-init.sh writes orchestrator_sid to SQLite" \
         "expected '$T6_SESSION_ID', got '$T6_SQLITE_VAL'"
fi

echo ""

# Test 2.3: Gate 1.5 still denies via SQLite-only path (no flat-file needed)
echo "=== Test 2.3: Gate 1.5 denies via SQLite-only path (no flat-file fallback) ==="

T7_ENV=$(make_temp_env)
T7_CLAUDE="$T7_ENV/.claude"
T7_ORCH_SID="v4-sqlite-only-orch-sid"

# Seed SQLite only
bash -c '
    export CLAUDE_PROJECT_DIR="'"$T7_ENV"'"
    export CLAUDE_SESSION_ID="'"$T7_ORCH_SID"'"
    source "'"$HOOKS_DIR"'/source-lib.sh"
    require_state
    state_update "orchestrator_sid" "'"$T7_ORCH_SID"'" "test-seed"
' 2>/dev/null || true

# Ensure NO flat-file exists
rm -f "$T7_CLAUDE/.orchestrator-sid" 2>/dev/null || true

T7_TARGET="$T7_ENV/.worktrees/feature-test/src/feature.sh"
T7_INPUT=$(mktemp)
CLEANUP_FILES+=("$T7_INPUT")
# Use python3 to produce valid JSON with properly escaped content (no literal newlines)
python3 -c "
import json, sys
data = {'tool_name': 'Write', 'tool_input': {'file_path': '$T7_TARGET', 'content': '# source\necho hi\n'}}
print(json.dumps(data))
" > "$T7_INPUT"

T7_OUTPUT=$(
    CLAUDE_PROJECT_DIR="$T7_ENV" \
    CLAUDE_SESSION_ID="$T7_ORCH_SID" \
    bash "$HOOKS_DIR/pre-write.sh" < "$T7_INPUT" 2>/dev/null
) || true

if echo "$T7_OUTPUT" | grep -q '"permissionDecision".*"deny"' && \
   echo "$T7_OUTPUT" | grep -q 'orchestrator context\|dispatch an implementer'; then
    pass "Test 2.3: Gate 1.5 denies via SQLite-only path (no flat-file fallback needed)"
else
    fail "Test 2.3: Gate 1.5 denies via SQLite-only path" \
         "expected orchestrator deny, got: $(echo "$T7_OUTPUT" | head -3)"
fi

echo ""

# Test 2.4: Source audit — session-end.sh has no rm .orchestrator-sid
echo "=== Test 2.4: session-end.sh source has no rm .orchestrator-sid command ==="

if grep -q 'rm -f.*\.orchestrator-sid\|rm.*orchestrator-sid' "$HOOKS_DIR/session-end.sh" 2>/dev/null; then
    fail "Test 2.4: session-end.sh source has no rm .orchestrator-sid" \
         "Found: $(grep 'rm.*orchestrator-sid' "$HOOKS_DIR/session-end.sh" | head -2)"
else
    pass "Test 2.4: session-end.sh source has no rm .orchestrator-sid (flat-file cleanup removed)"
fi

echo ""

# Test 2.5: Source audit — pre-write.sh has no .orchestrator-sid flat-file read (non-comment)
echo "=== Test 2.5: pre-write.sh source has no .orchestrator-sid flat-file reference ==="

T25_VIOLATIONS=$(grep '\.orchestrator-sid' "$HOOKS_DIR/pre-write.sh" 2>/dev/null \
    | grep -v '^[[:space:]]*#' || true)

if [[ -z "$T25_VIOLATIONS" ]]; then
    pass "Test 2.5: pre-write.sh source has no .orchestrator-sid flat-file read (flat-file fallback removed)"
else
    fail "Test 2.5: pre-write.sh source has no .orchestrator-sid flat-file reference" \
         "Found non-comment references: $(echo "$T25_VIOLATIONS" | head -3)"
fi

echo ""

# Test 2.6: Source audit — session-init.sh has no .orchestrator-sid flat-file write
echo "=== Test 2.6: session-init.sh source has no .orchestrator-sid flat-file write ==="

# Find non-comment lines with .orchestrator-sid
T26_VIOLATIONS=$(grep '\.orchestrator-sid' "$HOOKS_DIR/session-init.sh" 2>/dev/null \
    | grep -v '^[[:space:]]*#' || true)

if [[ -z "$T26_VIOLATIONS" ]]; then
    pass "Test 2.6: session-init.sh source has no .orchestrator-sid flat-file write"
else
    fail "Test 2.6: session-init.sh source has no .orchestrator-sid flat-file write" \
         "Found non-comment references: $(echo "$T26_VIOLATIONS" | head -3)"
fi

echo ""

# ============================================================
# SECTION 3: Gitignore Additions (DEC-V4-GITIGNORE-001)
# ============================================================

echo "=== Section 3: Gitignore Additions ==="
echo ""

GITIGNORE_FILE="$WORKTREE_ROOT/.gitignore"

check_gitignore() {
    local pattern="$1"
    local label="$2"
    if [[ ! -f "$GITIGNORE_FILE" ]]; then
        fail "$label" ".gitignore file not found at $GITIGNORE_FILE"
        return
    fi
    if grep -qF "$pattern" "$GITIGNORE_FILE" 2>/dev/null; then
        pass "$label"
    else
        fail "$label" "'$pattern' not found in .gitignore"
    fi
}

echo "=== Test 3.1-3.11: Gitignore runtime state entries ==="

check_gitignore ".hooks-gen"                       "Test 3.1:  .hooks-gen in .gitignore"
check_gitignore ".statusline-baseline"             "Test 3.2:  .statusline-baseline in .gitignore"
check_gitignore ".session-events.jsonl"            "Test 3.3:  .session-events.jsonl in .gitignore"
check_gitignore ".db-safety-stats"                 "Test 3.4:  .db-safety-stats in .gitignore"
check_gitignore ".mcp-rate-state"                  "Test 3.5:  .mcp-rate-state in .gitignore"
check_gitignore ".mcp-credential-advisory-emitted" "Test 3.6:  .mcp-credential-advisory-emitted in .gitignore"
check_gitignore ".orchestrator-sid"                "Test 3.7:  .orchestrator-sid in .gitignore"
check_gitignore ".git-state-cache"                 "Test 3.8:  .git-state-cache in .gitignore"
check_gitignore ".plan-state-cache"                "Test 3.9:  .plan-state-cache in .gitignore"
check_gitignore ".statusline-cache"                "Test 3.10: .statusline-cache in .gitignore"
check_gitignore ".lint-cooldown-*"                 "Test 3.11: .lint-cooldown-* in .gitignore"

echo ""

# ============================================================
# RESULTS
# ============================================================

echo "=== Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) tests ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
