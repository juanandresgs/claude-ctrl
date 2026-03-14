#!/usr/bin/env bash
# test-context-injection.sh — Validates section-aware shared protocol injection.
#
# Purpose: Verify that subagent-start.sh injects correct sections per agent type
# after the context injection optimization (shared-protocols.md lean rewrite +
# section-aware extraction in subagent-start.sh).
#
# Coverage:
#   CI-01: Section extraction — each named section is extractable and non-empty
#   CI-02: Governor skips CWD Safety
#   CI-03: Implementer/tester/guardian receive CWD Safety
#   CI-04: No HTML comments in injected output
#   CI-05: No @decision strings in injected output
#   CI-06: Implementer receives lockfile reminder
#   CI-07: Byte size check — injection smaller than old 2568-byte monolithic injection
#
# TAP-compatible: pass/fail/skip helpers, exits 1 on any failure.

set -euo pipefail

PASS=0
FAIL=0
SKIP=0

_CLEANUP_DIRS=()
trap '[[ ${#_CLEANUP_DIRS[@]} -gt 0 ]] && rm -rf "${_CLEANUP_DIRS[@]}" 2>/dev/null; true' EXIT

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)/hooks"
AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)/agents"
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED_PROTO="$AGENTS_DIR/shared-protocols.md"

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP: $1 — $2"; SKIP=$((SKIP+1)); }

# ============================================================
# Section extraction helper (mirrors what subagent-start.sh does)
# ============================================================
_extract_proto_section() {
    local section_name="$1"
    local file="${2:-$SHARED_PROTO}"
    awk -v header="## $section_name" '
        $0 == header { f=1; next }
        f && /^## / { exit }
        f { print }
    ' "$file"
}

# ============================================================
# Invoke subagent-start.sh with a given AGENT_TYPE and return additionalContext
# ============================================================
run_subagent_start() {
    local agent_type="$1"
    local project_dir="$2"
    local state_dir
    state_dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$state_dir")

    # Minimal git repo to satisfy require_git and require_plan checks
    git -C "$project_dir" init -q 2>/dev/null || true
    local _tree _cmt
    _tree=$(git -C "$project_dir" write-tree 2>/dev/null || echo "")
    if [[ -n "$_tree" ]]; then
        _cmt=$(GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=t@t.com \
               GIT_AUTHOR_DATE="2026-01-01T00:00:00" \
               GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=t@t.com \
               GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
               git -C "$project_dir" commit-tree "$_tree" -m "init" 2>/dev/null || echo "")
        [[ -n "$_cmt" ]] && git -C "$project_dir" update-ref HEAD "$_cmt" 2>/dev/null || true
    fi

    CLAUDE_PROJECT_DIR="$project_dir" \
    CLAUDE_DIR="$state_dir" \
    CLAUDE_SESSION_ID="test-ci-$$" \
    printf '{"agent_type":"%s","prompt":""}' "$agent_type" \
    | bash "$HOOKS_DIR/subagent-start.sh" 2>/dev/null \
    | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    ctx = data.get('hookSpecificOutput', {}).get('additionalContext', '')
    print(ctx)
except Exception:
    pass
" 2>/dev/null || true
}

# ============================================================
# Fixture: minimal git project
# ============================================================
make_project() {
    local dir
    dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$dir")
    git -C "$dir" init -q 2>/dev/null || true
    local _tree _cmt
    _tree=$(git -C "$dir" write-tree 2>/dev/null || echo "")
    if [[ -n "$_tree" ]]; then
        _cmt=$(GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=t@t.com \
               GIT_AUTHOR_DATE="2026-01-01T00:00:00" \
               GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=t@t.com \
               GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
               git -C "$dir" commit-tree "$_tree" -m "init" 2>/dev/null || echo "")
        [[ -n "$_cmt" ]] && git -C "$dir" update-ref HEAD "$_cmt" 2>/dev/null || true
    fi
    echo "$dir"
}

# ============================================================
# CI-01: Section extraction — each named section is non-empty
# ============================================================
echo "--- CI-01: Section extraction ---"

for section_name in "CWD Safety" "Trace Recovery" "Return Protocol" "Session End"; do
    sec=$(_extract_proto_section "$section_name")
    if [[ -n "$sec" ]]; then
        pass "CI-01[$section_name]: section extracted non-empty"
    else
        fail "CI-01[$section_name]: section is empty or not found" "Check ## $section_name header in shared-protocols.md"
    fi
done

# Verify old section headers no longer exist (confirming the rename from "CWD Safety Rules" etc.)
old_sec=$(_extract_proto_section "CWD Safety Rules")
if [[ -z "$old_sec" ]]; then
    pass "CI-01[no-old-headers]: old section headers removed"
else
    fail "CI-01[no-old-headers]: old header 'CWD Safety Rules' still present" "File not updated"
fi

# ============================================================
# CI-02: Governor is parked — subagent-start.sh has no governor case (DEC-PERF-006)
# ============================================================
echo "--- CI-02: Governor is parked (no governor) case in subagent-start.sh ---"

# Governor was parked in Issue #253 to save ~4,200 tokens/session.
# Verify subagent-start.sh has no governor) case (which would inject context
# and load governor.md into the Agent tool schema).
SUBAGENT_START="$HOOKS_DIR/subagent-start.sh"
if ! grep -q 'governor)' "$SUBAGENT_START" 2>/dev/null; then
    pass "CI-02: subagent-start.sh has no governor) case (governor parked)"
else
    fail "CI-02: subagent-start.sh still has governor) case" "Governor should be parked (DEC-PERF-006)"
fi

# Also verify no governor-specific string references remain
if ! grep -q '"governor"' "$SUBAGENT_START" 2>/dev/null; then
    pass "CI-02[strings]: subagent-start.sh has no \"governor\" string references"
else
    fail "CI-02[strings]: subagent-start.sh still has governor string references"
fi

# ============================================================
# CI-03: Other agents receive CWD Safety
# ============================================================
echo "--- CI-03: Other agents receive CWD Safety ---"

for agent_type in "implementer" "tester" "guardian" "planner"; do
    proj=$(make_project)
    agent_output=$(run_subagent_start "$agent_type" "$proj")
    if echo "$agent_output" | grep -q "CWD Safety"; then
        pass "CI-03[$agent_type]: CWD Safety present in output"
    else
        fail "CI-03[$agent_type]: CWD Safety missing from output" "Section should be injected for $agent_type"
    fi
done

# ============================================================
# CI-04: No HTML comments in output (sed stripping works)
# ============================================================
echo "--- CI-04: No HTML comments in output ---"

# Test the stripping logic directly on a temp file with an HTML comment injected
_TMP_PROTO=$(mktemp)
_CLEANUP_DIRS+=("$_TMP_PROTO")
# Write a test file that has a normal section plus an HTML comment
cat > "$_TMP_PROTO" <<'PROTO_EOF'
# Test Protocol

> Injected at spawn time.

## CWD Safety

Never use bare cd.

<!-- @decision DEC-TEST-001 this should be stripped -->

## Return Protocol

Return a text message.
PROTO_EOF

# Apply the same sed stripping used in subagent-start.sh
_stripped=$(sed '/^<!--/,/-->$/d' "$_TMP_PROTO")

if echo "$_stripped" | grep -q '<!--'; then
    fail "CI-04[sed-strip]: HTML comment opening still present after sed" "sed /^<!--/,/-->$/d not working"
elif echo "$_stripped" | grep -qF -- '-->'; then
    fail "CI-04[sed-strip]: HTML comment closing still present after sed" "sed /^<!--/,/-->$/d not working"
else
    pass "CI-04[sed-strip]: HTML comments stripped by sed"
fi

# Verify the section content is preserved
if echo "$_stripped" | grep -q "Never use bare cd"; then
    pass "CI-04[content-preserved]: Section content preserved after stripping"
else
    fail "CI-04[content-preserved]: Section content lost during stripping" "Check sed command"
fi

# ============================================================
# CI-05: No @decision strings in shared-protocols.md
# ============================================================
echo "--- CI-05: No @decision strings in shared-protocols.md ---"

# Check for actual @decision annotation blocks (^@decision ...) or HTML comment blocks
# containing @decision. The guard comment "> Do NOT add @decision annotations here" is
# intentional instructional text — it uses @decision as a noun, not as an annotation.
if grep -qE '^@decision\s|^# @decision\s' "$SHARED_PROTO"; then
    fail "CI-05: shared-protocols.md contains @decision annotation" "Remove @decision annotations — they waste agent tokens"
elif grep -q '<!--' "$SHARED_PROTO"; then
    fail "CI-05: shared-protocols.md contains HTML comment block (possible @decision)" "Remove HTML comment blocks — they waste agent tokens"
else
    pass "CI-05: shared-protocols.md has no @decision annotation blocks or HTML comments"
fi

# Also verify the "Applied to all agents" preamble is gone (token waste)
if grep -q "Applied to all agents" "$SHARED_PROTO"; then
    fail "CI-05[no-preamble]: Old preamble still in shared-protocols.md" "'Applied to all agents' line should be removed"
else
    pass "CI-05[no-preamble]: Old preamble removed from shared-protocols.md"
fi

# ============================================================
# CI-06: Implementer gets lockfile reminder
# ============================================================
echo "--- CI-06: Implementer gets lockfile reminder ---"

proj=$(make_project)
impl_output=$(run_subagent_start "implementer" "$proj")

if echo "$impl_output" | grep -q "claude-active"; then
    pass "CI-06: Implementer output contains lockfile reminder (.claude-active)"
else
    fail "CI-06: Implementer missing lockfile reminder" "Add: CONTEXT_PARTS+=(\"Before returning: verify no uncommitted changes in worktree, remove lockfile: rm -f .worktrees/<name>/.claude-active\")"
fi

# ============================================================
# CI-07: Byte size check — smaller than old 2568-byte monolithic injection
# ============================================================
echo "--- CI-07: Byte size check ---"

OLD_BYTES=2568  # measured from original shared-protocols.md before optimization

new_bytes=$(wc -c < "$SHARED_PROTO")
if [[ "$new_bytes" -lt "$OLD_BYTES" ]]; then
    pass "CI-07[file-size]: shared-protocols.md reduced ($new_bytes bytes < $OLD_BYTES old bytes)"
else
    fail "CI-07[file-size]: shared-protocols.md not smaller ($new_bytes bytes >= $OLD_BYTES old bytes)" \
         "New file should be leaner than original"
fi

# Verify CWD Safety section exists in shared-protocols.md (still injected for all active agents)
cwd_section=$(_extract_proto_section "CWD Safety")
cwd_bytes=${#cwd_section}
if [[ "$cwd_bytes" -gt 0 ]]; then
    pass "CI-07[cwd-section-exists]: CWD Safety section has $cwd_bytes bytes (injected for all agents)"
else
    fail "CI-07[cwd-section-exists]: CWD Safety section empty" "Section should have content"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
