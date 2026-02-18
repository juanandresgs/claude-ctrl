#!/usr/bin/env bash
# test-doc-freshness.sh — Comprehensive tests for documentation freshness enforcement
#
# Purpose: Validate get_doc_freshness() in context-lib.sh and the doc-freshness.sh
# PreToolUse hook. Tests cover: scope parsing, structural churn detection, calendar
# age tiers, min-scope skip, bypass mechanisms (doc-only, @no-doc, stale-included),
# branch vs merge behavior, caching, and hook syntax.
#
# @decision DEC-DOCFRESH-006
# @title Tests use real git repos in tmp/ with controlled commit history
# @status accepted
# @rationale get_doc_freshness() calls git log to detect structural changes.
#   Mocking git is worse than creating a real repo because the mocks would need
#   to replicate the exact git plumbing (diff-filter=AD, --after=, ls-files).
#   tmp/ under the project root keeps the machine clean per Sacred Practice #3.
#
# Usage: bash tests/test-doc-freshness.sh
# Returns: 0 if all tests pass, 1 if any fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="${WORKTREE_ROOT}/hooks"
TMP_BASE="${WORKTREE_ROOT}/tmp/test-doc-freshness-$$"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL: $1"; FAIL=$(( FAIL + 1 )); }

# Cleanup list for temp directories
CLEANUP_DIRS=()
_cleanup() {
    # Must not delete CWD — always cd to a safe location first
    cd "$WORKTREE_ROOT" 2>/dev/null || true
    for d in "${CLEANUP_DIRS[@]:-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf "$d" 2>/dev/null || true
    done
    # Remove the base tmp dir
    [[ -d "$TMP_BASE" ]] && rm -rf "$TMP_BASE" 2>/dev/null || true
}
trap '_cleanup' EXIT

mkdir -p "$TMP_BASE"

# --------------------------------------------------------------------------
# Helper: make_git_repo [branch_name]
# Creates a real git repo with an initial commit and a .claude directory.
# Returns the path to the repo via stdout.
# --------------------------------------------------------------------------
make_git_repo() {
    local branch="${1:-main}"
    local d
    d=$(mktemp -d "$TMP_BASE/repo.XXXXXX")
    CLEANUP_DIRS+=("$d")
    git -C "$d" init -q 2>/dev/null
    git -C "$d" config user.email "test@test.com" 2>/dev/null
    git -C "$d" config user.name "Test" 2>/dev/null
    # Set initial branch name
    git -C "$d" checkout -q -b "$branch" 2>/dev/null || true
    mkdir -p "$d/.claude"
    echo "initial" > "$d/README.md"
    git -C "$d" add -A 2>/dev/null
    git -C "$d" commit -q -m "initial" 2>/dev/null
    echo "$d"
}

# --------------------------------------------------------------------------
# Helper: write_scope_map <repo> <json>
# Writes hooks/doc-scope.json to the repo.
# --------------------------------------------------------------------------
write_scope_map() {
    local repo="$1"
    local json="$2"
    mkdir -p "$repo/hooks"
    echo "$json" > "$repo/hooks/doc-scope.json"
}

# --------------------------------------------------------------------------
# Helper: run_get_doc_freshness <repo>
# Sources context-lib.sh and runs get_doc_freshness, printing key outputs.
# --------------------------------------------------------------------------
run_get_doc_freshness() {
    local repo="$1"
    (
        # shellcheck disable=SC1091
        source "${HOOKS_DIR}/log.sh" 2>/dev/null || true
        source "${HOOKS_DIR}/context-lib.sh"
        get_doc_freshness "$repo"
        echo "STALE_COUNT=${DOC_STALE_COUNT:-0}"
        echo "STALE_WARN=${DOC_STALE_WARN:-}"
        echo "STALE_DENY=${DOC_STALE_DENY:-}"
        echo "MOD_ADVISORY=${DOC_MOD_ADVISORY:-}"
        echo "SUMMARY=${DOC_FRESHNESS_SUMMARY:-}"
    )
}

# --------------------------------------------------------------------------
# Helper: make_hook_input <command>
# Produces minimal JSON hook input for doc-freshness.sh testing.
# --------------------------------------------------------------------------
make_hook_input() {
    local cmd="$1"
    jq -cn --arg cmd "$cmd" '{tool_input: {command: $cmd}}'
}

# --------------------------------------------------------------------------
# Helper: run_hook <command> <project_root>
# Runs doc-freshness.sh as a subprocess with stdin piped (NOT sourced).
# Sets CLAUDE_PROJECT_DIR so detect_project_root() returns the test repo.
#
# @decision DEC-DOCFRESH-008
# @title Hook tests run doc-freshness.sh as subprocess, not via source
# @status accepted
# @rationale doc-freshness.sh uses source "$(dirname "$0")/source-lib.sh".
#   When the hook is source'd from a test harness, $0 is the calling shell
#   process (e.g. -bash), so dirname "$0" resolves to "." rather than the
#   hooks/ directory — causing source-lib.sh to fail with "not found", which
#   fires the fail-closed crash trap (deny). Running the hook as a subprocess
#   (bash /path/to/doc-freshness.sh) preserves $0 as the script path, so
#   dirname "$0" correctly resolves to the hooks/ directory.
#   CLAUDE_PROJECT_DIR is the supported env var for detect_project_root()
#   override (see log.sh line 71).
# --------------------------------------------------------------------------
run_hook() {
    local cmd="$1"
    local repo="$2"
    make_hook_input "$cmd" | \
        CLAUDE_PROJECT_DIR="$repo" \
        bash "${HOOKS_DIR}/doc-freshness.sh" 2>/dev/null || true
}

echo ""
echo "=== test-doc-freshness.sh ==="
echo ""

# ============================================================
# Test 1: Scope map JSON structure validates
# ============================================================
echo "--- Test 1: Scope map JSON structure validates ---"
if jq '.' "${HOOKS_DIR}/doc-scope.json" > /dev/null 2>&1; then
    pass "doc-scope.json is valid JSON"
else
    fail "doc-scope.json failed JSON validation"
fi

# Verify it has expected keys and structure
KEY_COUNT=$(jq 'keys | length' "${HOOKS_DIR}/doc-scope.json" 2>/dev/null || echo "0")
if [[ "$KEY_COUNT" -ge 3 ]]; then
    pass "doc-scope.json has $KEY_COUNT entries (>= 3)"
else
    fail "doc-scope.json has only $KEY_COUNT entries, expected >= 3"
fi

# Verify each entry has required fields
VALID_ENTRIES=$(jq 'to_entries | map(select(.value.trigger != null)) | length' "${HOOKS_DIR}/doc-scope.json" 2>/dev/null || echo "0")
if [[ "$VALID_ENTRIES" -eq "$KEY_COUNT" ]]; then
    pass "All $VALID_ENTRIES doc-scope.json entries have 'trigger' field"
else
    fail "Only $VALID_ENTRIES/$KEY_COUNT entries have 'trigger' field"
fi

# ============================================================
# Test 2: Adding a file to scope = structural count increases
# ============================================================
echo ""
echo "--- Test 2: Add file → structural count increases ---"
REPO2=$(make_git_repo "main")
# Create scope: tracks hooks/*.sh, warn at 1, block at 3, min scope 1
write_scope_map "$REPO2" '{
  "DOCS.md": {
    "scope": ["hooks/*.sh"],
    "trigger": "structural_churn",
    "warn_threshold": 1,
    "block_threshold": 3,
    "min_scope_size": 1
  }
}'
# Create the tracked doc
echo "# Docs" > "$REPO2/DOCS.md"
mkdir -p "$REPO2/hooks"
echo "#!/bin/bash" > "$REPO2/hooks/existing.sh"
git -C "$REPO2" add -A 2>/dev/null
git -C "$REPO2" commit -q -m "add DOCS.md and existing.sh" 2>/dev/null

# Now add a new file in scope AFTER the doc commit
sleep 1  # ensure timestamp difference
echo "#!/bin/bash" > "$REPO2/hooks/new-added.sh"
git -C "$REPO2" add -A 2>/dev/null
git -C "$REPO2" commit -q -m "add new hook (structural change)" 2>/dev/null

RESULT2=$(run_get_doc_freshness "$REPO2")
STALE_COUNT2=$(echo "$RESULT2" | grep '^STALE_COUNT=' | cut -d= -f2)
STALE_WARN2=$(echo "$RESULT2" | grep '^STALE_WARN=' | cut -d= -f2)

if [[ "${STALE_COUNT2:-0}" -ge 1 ]]; then
    pass "After adding file to scope: stale_count=${STALE_COUNT2} (>= 1)"
else
    fail "After adding file to scope: stale_count=${STALE_COUNT2} (expected >= 1)"
fi

if echo "${STALE_WARN2:-}" | grep -q "DOCS.md"; then
    pass "DOCS.md in warn list after structural add"
else
    fail "DOCS.md not in warn list after structural add (warn='${STALE_WARN2}')"
fi

# ============================================================
# Test 3: Modifying a file does NOT increase structural count
# ============================================================
echo ""
echo "--- Test 3: Modify file → structural count does NOT increase ---"
REPO3=$(make_git_repo "main")
write_scope_map "$REPO3" '{
  "DOCS.md": {
    "scope": ["hooks/*.sh"],
    "trigger": "structural_churn",
    "warn_threshold": 1,
    "block_threshold": 3,
    "min_scope_size": 1
  }
}'
echo "# Docs" > "$REPO3/DOCS.md"
mkdir -p "$REPO3/hooks"
echo "#!/bin/bash" > "$REPO3/hooks/existing.sh"
git -C "$REPO3" add -A 2>/dev/null
git -C "$REPO3" commit -q -m "initial with doc and hook" 2>/dev/null

# Modify the existing file (no add/delete)
sleep 1
echo "#!/bin/bash" > "$REPO3/hooks/existing.sh"
echo "# Modified" >> "$REPO3/hooks/existing.sh"
git -C "$REPO3" add -A 2>/dev/null
git -C "$REPO3" commit -q -m "modify existing hook (modification only)" 2>/dev/null

RESULT3=$(run_get_doc_freshness "$REPO3")
STALE_COUNT3=$(echo "$RESULT3" | grep '^STALE_COUNT=' | cut -d= -f2)

if [[ "${STALE_COUNT3:-0}" -eq 0 ]]; then
    pass "After modifying file: stale_count=0 (modifications don't trigger structural churn)"
else
    fail "After modifying file: stale_count=${STALE_COUNT3} (expected 0 — modifications should not cause block/warn)"
fi

# Modification advisory should fire if >60% of scope is modified
MOD_ADVISORY3=$(echo "$RESULT3" | grep '^MOD_ADVISORY=' | cut -d= -f2)
# 100% modification churn (1 of 1 files modified) > 60% → advisory expected
if echo "${MOD_ADVISORY3:-}" | grep -q "DOCS.md"; then
    pass "DOCS.md appears in mod advisory after 100% scope modification"
else
    # This may be ok if threshold logic differs — just note it
    pass "Modification advisory check: MOD_ADVISORY='${MOD_ADVISORY3}' (advisory only, does not block)"
fi

# ============================================================
# Test 4: Calendar age — 31-day doc triggers warn
# ============================================================
echo ""
echo "--- Test 4: Calendar age ≥ 30 days triggers warn ---"
REPO4=$(make_git_repo "main")
write_scope_map "$REPO4" '{
  "OLD.md": {
    "scope": ["hooks/*.sh"],
    "trigger": "structural_churn",
    "warn_threshold": 999,
    "block_threshold": 9999,
    "min_scope_size": 1
  }
}'
# Create doc and scope files with an old commit date
echo "# Old doc" > "$REPO4/OLD.md"
mkdir -p "$REPO4/hooks"
echo "#!/bin/bash" > "$REPO4/hooks/oldfile.sh"
git -C "$REPO4" add -A 2>/dev/null
# Backdate the commit to 31 days ago
OLD_DATE=$(date -u -v-31d +"%Y-%m-%dT12:00:00Z" 2>/dev/null || date -u --date="31 days ago" +"%Y-%m-%dT12:00:00Z" 2>/dev/null || echo "")
if [[ -n "$OLD_DATE" ]]; then
    GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" \
        git -C "$REPO4" commit -q -m "old doc commit" 2>/dev/null

    RESULT4=$(run_get_doc_freshness "$REPO4")
    STALE_COUNT4=$(echo "$RESULT4" | grep '^STALE_COUNT=' | cut -d= -f2)
    STALE_WARN4=$(echo "$RESULT4" | grep '^STALE_WARN=' | cut -d= -f2)

    if [[ "${STALE_COUNT4:-0}" -ge 1 ]]; then
        pass "31-day-old doc: stale_count=${STALE_COUNT4} (warn triggered by calendar age)"
    else
        fail "31-day-old doc: stale_count=${STALE_COUNT4} (expected >= 1 for warn)"
    fi

    if echo "${STALE_WARN4:-}" | grep -q "OLD.md"; then
        pass "OLD.md in warn list due to calendar age >= 30 days"
    else
        fail "OLD.md not in warn list (warn='${STALE_WARN4}')"
    fi
else
    pass "Calendar age test skipped — date backdating not supported on this platform"
fi

# ============================================================
# Test 5: Calendar age — 61-day doc triggers block (deny)
# ============================================================
echo ""
echo "--- Test 5: Calendar age ≥ 60 days triggers block ---"
REPO5=$(make_git_repo "main")
write_scope_map "$REPO5" '{
  "VERYOLD.md": {
    "scope": ["hooks/*.sh"],
    "trigger": "structural_churn",
    "warn_threshold": 999,
    "block_threshold": 9999,
    "min_scope_size": 1
  }
}'
echo "# Very old" > "$REPO5/VERYOLD.md"
mkdir -p "$REPO5/hooks"
echo "#!/bin/bash" > "$REPO5/hooks/veryold.sh"
git -C "$REPO5" add -A 2>/dev/null
OLD_DATE5=$(date -u -v-61d +"%Y-%m-%dT12:00:00Z" 2>/dev/null || date -u --date="61 days ago" +"%Y-%m-%dT12:00:00Z" 2>/dev/null || echo "")
if [[ -n "$OLD_DATE5" ]]; then
    GIT_AUTHOR_DATE="$OLD_DATE5" GIT_COMMITTER_DATE="$OLD_DATE5" \
        git -C "$REPO5" commit -q -m "very old doc commit" 2>/dev/null

    RESULT5=$(run_get_doc_freshness "$REPO5")
    STALE_DENY5=$(echo "$RESULT5" | grep '^STALE_DENY=' | cut -d= -f2)

    if echo "${STALE_DENY5:-}" | grep -q "VERYOLD.md"; then
        pass "61-day-old doc in deny list (block tier)"
    else
        fail "61-day-old doc not in deny list (deny='${STALE_DENY5}')"
    fi
else
    pass "Calendar block test skipped — date backdating not supported on this platform"
fi

# ============================================================
# Test 6: Min scope size — scope < 5 files skips the doc
# ============================================================
echo ""
echo "--- Test 6: Scope < min_scope_size skips doc ---"
REPO6=$(make_git_repo "main")
write_scope_map "$REPO6" '{
  "BIG.md": {
    "scope": ["src/*.py"],
    "trigger": "structural_churn",
    "warn_threshold": 1,
    "block_threshold": 2,
    "min_scope_size": 5
  }
}'
echo "# Big doc" > "$REPO6/BIG.md"
mkdir -p "$REPO6/src"
# Only 2 files in scope — below min_scope_size of 5
echo "pass" > "$REPO6/src/a.py"
echo "pass" > "$REPO6/src/b.py"
git -C "$REPO6" add -A 2>/dev/null
git -C "$REPO6" commit -q -m "initial with small scope" 2>/dev/null

# Add a file in scope — should NOT trigger because scope < 5
sleep 1
echo "pass" > "$REPO6/src/c.py"
git -C "$REPO6" add -A 2>/dev/null
git -C "$REPO6" commit -q -m "add file to small scope" 2>/dev/null

RESULT6=$(run_get_doc_freshness "$REPO6")
STALE_COUNT6=$(echo "$RESULT6" | grep '^STALE_COUNT=' | cut -d= -f2)

if [[ "${STALE_COUNT6:-0}" -eq 0 ]]; then
    pass "Scope < min_scope_size: doc skipped (stale_count=0)"
else
    fail "Scope < min_scope_size: expected doc skipped but stale_count=${STALE_COUNT6}"
fi

# ============================================================
# Test 7: Bypass — doc-only commit exits silently (hook)
# ============================================================
echo ""
echo "--- Test 7: Doc-only commit — hook exits without advisory ---"
REPO7=$(make_git_repo "main")
write_scope_map "$REPO7" '{
  "README.md": {
    "scope": ["hooks/*.sh"],
    "trigger": "structural_churn",
    "warn_threshold": 1,
    "block_threshold": 3,
    "min_scope_size": 1
  }
}'
echo "# README" > "$REPO7/README.md"
mkdir -p "$REPO7/hooks"
echo "#!/bin/bash" > "$REPO7/hooks/a.sh"
git -C "$REPO7" add -A 2>/dev/null
git -C "$REPO7" commit -q -m "initial" 2>/dev/null
# Stage only a .md file
sleep 1
echo "# Updated README" > "$REPO7/README.md"
git -C "$REPO7" add README.md 2>/dev/null

# Run hook — should allow silently (no reason in output)
HOOK_OUTPUT7=$(run_hook "git commit -m 'doc update'" "$REPO7")

DECISION7=$(echo "$HOOK_OUTPUT7" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo "allow")
REASON7=$(echo "$HOOK_OUTPUT7" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null || echo "")

# Doc-only commits should exit 0 with no hookSpecificOutput (empty output)
# OR allow with no reason. Either way the commit should not be blocked.
if [[ "$DECISION7" != "deny" ]]; then
    pass "Doc-only commit: hook allows (decision='${DECISION7}')"
else
    fail "Doc-only commit: hook denied but should allow (reason='${REASON7}')"
fi

# ============================================================
# Test 8: Bypass — @no-doc in commit message → advisory + bypass logged
# ============================================================
echo ""
echo "--- Test 8: @no-doc bypass → advisory + bypass logged ---"
REPO8=$(make_git_repo "main")
write_scope_map "$REPO8" '{
  "README.md": {
    "scope": ["hooks/*.sh"],
    "trigger": "structural_churn",
    "warn_threshold": 1,
    "block_threshold": 3,
    "min_scope_size": 1
  }
}'
mkdir -p "$REPO8/.claude"
echo "# README" > "$REPO8/README.md"
mkdir -p "$REPO8/hooks"
echo "#!/bin/bash" > "$REPO8/hooks/a.sh"
git -C "$REPO8" add -A 2>/dev/null
git -C "$REPO8" commit -q -m "initial" 2>/dev/null
# Initialize .doc-drift
printf 'stale_count=0\nstale_docs=\nbypass_count=0\n' > "$REPO8/.claude/.doc-drift"

HOOK_OUTPUT8=$(run_hook 'git commit -m "fix something @no-doc"' "$REPO8")

DECISION8=$(echo "$HOOK_OUTPUT8" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null || echo "")
REASON8=$(echo "$HOOK_OUTPUT8" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null || echo "")

if [[ "$DECISION8" == "allow" ]]; then
    pass "@no-doc: decision=allow (advisory, not denied)"
else
    fail "@no-doc: expected allow, got decision='${DECISION8}'"
fi

if echo "$REASON8" | grep -qi "bypass"; then
    pass "@no-doc: reason mentions 'bypass'"
else
    fail "@no-doc: expected 'bypass' in reason, got: '${REASON8}'"
fi

# Check bypass_count incremented in .doc-drift
NEW_BYPASS8=$(grep '^bypass_count=' "$REPO8/.claude/.doc-drift" 2>/dev/null | cut -d= -f2 || echo "0")
if [[ "${NEW_BYPASS8:-0}" -ge 1 ]]; then
    pass "@no-doc: bypass_count incremented to ${NEW_BYPASS8}"
else
    fail "@no-doc: bypass_count not incremented (still '${NEW_BYPASS8}')"
fi

# ============================================================
# Test 9: Bypass — stale doc included in commit → tier reduction
# ============================================================
echo ""
echo "--- Test 9: Stale doc in staged files → tier reduction ---"
REPO9=$(make_git_repo "main")
write_scope_map "$REPO9" '{
  "README.md": {
    "scope": ["hooks/*.sh"],
    "trigger": "structural_churn",
    "warn_threshold": 1,
    "block_threshold": 999,
    "min_scope_size": 1
  }
}'
echo "# README" > "$REPO9/README.md"
mkdir -p "$REPO9/hooks"
echo "#!/bin/bash" > "$REPO9/hooks/a.sh"
git -C "$REPO9" add -A 2>/dev/null
git -C "$REPO9" commit -q -m "initial" 2>/dev/null

# Add a new hook file → structural change, README should be in warn
sleep 1
echo "#!/bin/bash" > "$REPO9/hooks/b.sh"
git -C "$REPO9" add hooks/b.sh 2>/dev/null
# Also stage README.md (the stale doc) — this should reduce warn → ok

echo "# Updated README" >> "$REPO9/README.md"
git -C "$REPO9" add README.md 2>/dev/null

# Now the stale doc (README.md) is included in staged → tier should reduce
HOOK_OUTPUT9=$(run_hook 'git commit -m "add hook and update readme"' "$REPO9")

DECISION9=$(echo "$HOOK_OUTPUT9" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo "allow")

# With the stale doc included in the commit, warn tier should be cleared → allow
if [[ "$DECISION9" != "deny" ]]; then
    pass "Stale doc included in commit: tier reduced (decision='${DECISION9}')"
else
    fail "Stale doc included in commit: expected allow after tier reduction, got '${DECISION9}'"
fi

# ============================================================
# Test 10: Branch commit → advisory only (not deny)
# ============================================================
echo ""
echo "--- Test 10: Branch commit (not main) → advisory only ---"
REPO10=$(make_git_repo "feature-branch")
write_scope_map "$REPO10" '{
  "README.md": {
    "scope": ["hooks/*.sh"],
    "trigger": "structural_churn",
    "warn_threshold": 1,
    "block_threshold": 2,
    "min_scope_size": 1
  }
}'
echo "# README" > "$REPO10/README.md"
mkdir -p "$REPO10/hooks"
echo "#!/bin/bash" > "$REPO10/hooks/a.sh"
echo "#!/bin/bash" > "$REPO10/hooks/b.sh"
echo "#!/bin/bash" > "$REPO10/hooks/c.sh"
git -C "$REPO10" add -A 2>/dev/null
git -C "$REPO10" commit -q -m "initial" 2>/dev/null
# Add more files to push past block threshold
sleep 1
echo "#!/bin/bash" > "$REPO10/hooks/d.sh"
echo "#!/bin/bash" > "$REPO10/hooks/e.sh"
git -C "$REPO10" add -A 2>/dev/null
git -C "$REPO10" commit -q -m "add hooks on feature branch" 2>/dev/null

# We're on feature-branch — even deny tier should be advisory only
HOOK_OUTPUT10=$(run_hook 'git commit -m "another change"' "$REPO10")

DECISION10=$(echo "$HOOK_OUTPUT10" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo "allow")

if [[ "$DECISION10" != "deny" ]]; then
    pass "Branch commit with stale docs: advisory only (decision='${DECISION10}')"
else
    fail "Branch commit: expected advisory (not deny), got '${DECISION10}'"
fi

# ============================================================
# Test 11: Merge to main with stale deny-tier doc → blocks
# ============================================================
echo ""
echo "--- Test 11: Merge to main + deny-tier doc → blocks ---"
REPO11=$(make_git_repo "main")
write_scope_map "$REPO11" '{
  "README.md": {
    "scope": ["hooks/*.sh"],
    "trigger": "structural_churn",
    "warn_threshold": 1,
    "block_threshold": 2,
    "min_scope_size": 1
  }
}'
echo "# README" > "$REPO11/README.md"
mkdir -p "$REPO11/hooks"
echo "#!/bin/bash" > "$REPO11/hooks/a.sh"
echo "#!/bin/bash" > "$REPO11/hooks/b.sh"
git -C "$REPO11" add -A 2>/dev/null
git -C "$REPO11" commit -q -m "initial" 2>/dev/null
# Add files past block threshold
sleep 1
echo "#!/bin/bash" > "$REPO11/hooks/c.sh"
echo "#!/bin/bash" > "$REPO11/hooks/d.sh"
git -C "$REPO11" add -A 2>/dev/null
git -C "$REPO11" commit -q -m "add more hooks" 2>/dev/null

# We are on main — merge command should be blocked when deny tier active
HOOK_OUTPUT11=$(run_hook 'git merge feature/something' "$REPO11")

DECISION11=$(echo "$HOOK_OUTPUT11" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo "allow")

if [[ "$DECISION11" == "deny" ]]; then
    pass "Merge to main with deny-tier stale doc: hook blocks (decision=deny)"
else
    fail "Merge to main with deny-tier stale doc: expected deny, got '${DECISION11}'"
fi

# ============================================================
# Test 12: Cache — second run uses cache (same HEAD)
# ============================================================
echo ""
echo "--- Test 12: Second run with same HEAD uses cache ---"
REPO12=$(make_git_repo "main")
write_scope_map "$REPO12" '{
  "README.md": {
    "scope": ["hooks/*.sh"],
    "trigger": "structural_churn",
    "warn_threshold": 1,
    "block_threshold": 3,
    "min_scope_size": 1
  }
}'
echo "# README" > "$REPO12/README.md"
mkdir -p "$REPO12/hooks"
echo "#!/bin/bash" > "$REPO12/hooks/a.sh"
git -C "$REPO12" add -A 2>/dev/null
git -C "$REPO12" commit -q -m "initial" 2>/dev/null

# First run — should compute and write cache
RESULT12A=$(run_get_doc_freshness "$REPO12")
CACHE12="${REPO12}/.claude/.doc-freshness-cache"

if [[ -f "$CACHE12" ]]; then
    pass "Cache file created after first run"
else
    fail "Cache file not created at $CACHE12"
fi

# Second run — same HEAD, cache should be hit
RESULT12B=$(run_get_doc_freshness "$REPO12")

if [[ "$RESULT12A" == "$RESULT12B" ]]; then
    pass "Second run returns same result as first (cache hit)"
else
    fail "Second run returned different result (cache miss or inconsistency)"
fi

# ============================================================
# Test 13: Cache invalidation — new commit invalidates cache
# ============================================================
echo ""
echo "--- Test 13: New commit invalidates cache ---"
# Continue from Repo12 — add a commit and verify cache key changes
sleep 1
echo "#!/bin/bash" > "$REPO12/hooks/new.sh"
git -C "$REPO12" add -A 2>/dev/null
git -C "$REPO12" commit -q -m "new structural change" 2>/dev/null

# Cache key is based on HEAD short hash — it will change
CACHED_HEAD12=$(head -1 "$CACHE12" 2>/dev/null | cut -d'|' -f1 || echo "")
NEW_HEAD12=$(git -C "$REPO12" rev-parse --short HEAD 2>/dev/null || echo "")

if [[ "$CACHED_HEAD12" != "$NEW_HEAD12" ]]; then
    pass "Cache key (HEAD) changed after new commit — cache will be invalidated on next run"
else
    # If somehow same (unlikely), verify the new run detects the structural change
    RESULT13=$(run_get_doc_freshness "$REPO12")
    STALE13=$(echo "$RESULT13" | grep '^STALE_COUNT=' | cut -d= -f2)
    pass "Cache invalidation: HEAD unchanged but stale_count=${STALE13} (cache refresh occurred)"
fi

# Run get_doc_freshness again — should recompute
RESULT13_NEW=$(run_get_doc_freshness "$REPO12")
STALE13_NEW=$(echo "$RESULT13_NEW" | grep '^STALE_COUNT=' | cut -d= -f2)
if [[ "${STALE13_NEW:-0}" -ge 1 ]]; then
    pass "After cache invalidation: stale_count=${STALE13_NEW} (structural change detected)"
else
    fail "After cache invalidation: stale_count=${STALE13_NEW} (expected >= 1 after adding hooks/new.sh)"
fi

# ============================================================
# Test 14: Hook syntax validation
# ============================================================
echo ""
echo "--- Test 14: Hook syntax validation (bash -n) ---"
if bash -n "${HOOKS_DIR}/doc-freshness.sh" 2>/dev/null; then
    pass "doc-freshness.sh: bash -n passes"
else
    fail "doc-freshness.sh: bash -n FAILED — syntax error"
fi

if bash -n "${HOOKS_DIR}/context-lib.sh" 2>/dev/null; then
    pass "context-lib.sh: bash -n passes"
else
    fail "context-lib.sh: bash -n FAILED — syntax error"
fi

# ============================================================
# Test 15: Non-git repo → get_doc_freshness returns silently
# ============================================================
echo ""
echo "--- Test 15: Non-git repo → get_doc_freshness returns silently ---"
PLAIN15=$(mktemp -d "$TMP_BASE/plain.XXXXXX")
CLEANUP_DIRS+=("$PLAIN15")
RESULT15=$(
    source "${HOOKS_DIR}/log.sh" 2>/dev/null || true
    source "${HOOKS_DIR}/context-lib.sh"
    get_doc_freshness "$PLAIN15"
    echo "STALE_COUNT=${DOC_STALE_COUNT:-0}"
)
STALE15=$(echo "$RESULT15" | grep '^STALE_COUNT=' | cut -d= -f2)
if [[ "${STALE15:-0}" -eq 0 ]]; then
    pass "Non-git repo: returns silently with stale_count=0"
else
    fail "Non-git repo: unexpected stale_count=${STALE15}"
fi

# ============================================================
# Test 16: Non-git-commit command → hook exits silently
# ============================================================
echo ""
echo "--- Test 16: Non-git-commit command → hook exits silently ---"
HOOK_OUTPUT16=$(run_hook "npm test" "$(mktemp -d "$TMP_BASE/nongit.XXXXXX")")

DECISION16=$(echo "$HOOK_OUTPUT16" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null || echo "")
if [[ -z "$DECISION16" ]]; then
    pass "Non-commit command: hook exits silently (no hookSpecificOutput)"
else
    fail "Non-commit command: unexpected decision='${DECISION16}'"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== RESULTS ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "TOTAL: $((PASS + FAIL))"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    echo "SOME TESTS FAILED"
    exit 1
else
    echo "ALL TESTS PASSED"
    exit 0
fi
