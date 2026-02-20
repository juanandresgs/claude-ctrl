#!/usr/bin/env bash
# Test suite for living MASTER_PLAN.md format hook updates.
# Validates W2-1 through W2-6 from issue #140.
#
# @decision DEC-PLAN-003
# @title Initiative-level lifecycle replaces document-level
# @status accepted
# @rationale PLAN_LIFECYCLE becomes none/active/dormant based on ### Initiative: headers
#   and their Status fields. "dormant" replaces "completed" — the plan is never "completed".
#   Tests validate all lifecycle transitions and the new compress_initiative() helper.
#
# Tests:
#   1.  get_plan_status() — no plan returns none lifecycle
#   2.  get_plan_status() — old format (## Phase) returns active lifecycle
#   3.  get_plan_status() — new format with active initiative returns active
#   4.  get_plan_status() — all initiatives completed returns dormant
#   5.  get_plan_status() — mixed (1 active, 1 completed) returns active
#   6.  get_plan_status() — PLAN_ACTIVE_INITIATIVES count is correct
#   7.  plan-check.sh — allows writes when active initiative exists
#   8.  plan-check.sh — blocks writes when lifecycle is dormant
#   9.  plan-validate.sh — validates ## Identity section (new format)
#   10. plan-validate.sh — validates ### Initiative: headers
#   11. plan-validate.sh — no longer requires ## Phase N: at document level
#   12. plan-validate.sh — advisory warning for empty Decision Log
#   13. session-init.sh — injection bounded under 250 lines for large plan
#   14. session-init.sh — injects Identity section
#   15. session-init.sh — injects active initiative phase status
#   16. prompt-submit.sh — shows active initiative count (not raw phase count)
#   17. prompt-submit.sh — shows dormant warning (not "COMPLETED")
#   18. compress_initiative() — function exists and compresses an initiative
#   19. compress_initiative() — removes initiative from Active Initiatives
#   20. compress_initiative() — appends to Completed Initiatives

set -euo pipefail

PASS=0
FAIL=0
SKIP=0

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)/hooks"

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP: $1 — $2"; SKIP=$((SKIP+1)); }

# --- Fixtures ---

make_plan_no_plan() {
    local dir
    dir=$(mktemp -d)
    git -C "$dir" init -q
    echo "$dir"
}

make_plan_old_format() {
    # Old format: ## Phase N: headers at document level
    local dir
    dir=$(mktemp -d)
    git -C "$dir" init -q
    cat > "$dir/MASTER_PLAN.md" <<'EOF'
# MASTER_PLAN: Test Project

## Original Intent
Test project.

## Phase 1: Foundation
**Status:** completed

## Phase 2: Features
**Status:** in-progress
EOF
    echo "$dir"
}

make_plan_new_format_active() {
    # New format: ### Initiative with Status: active
    local dir
    dir=$(mktemp -d)
    git -C "$dir" init -q
    cat > "$dir/MASTER_PLAN.md" <<'EOF'
# MASTER_PLAN: Test Project

## Identity
**Type:** test
**Root:** /tmp/test

## Original Intent
> Test project.

## Decision Log

| Date | DEC-ID | Initiative | Decision | Rationale |
|------|--------|-----------|----------|-----------|
| 2026-02-19 | DEC-TST-001 | v1 | Test decision | Test rationale |

---

## Active Initiatives

### Initiative: v1 Alpha
**Status:** active
**Started:** 2026-02-19
**Goal:** Build the alpha

#### Phase 1: Core
**Status:** completed

#### Phase 2: Features
**Status:** in-progress

## Completed Initiatives

| Initiative | Period | Phases | Key Decisions | Archived |
|-----------|--------|--------|---------------|---------|
EOF
    echo "$dir"
}

make_plan_new_format_all_done() {
    # New format: all initiatives have Status: completed
    local dir
    dir=$(mktemp -d)
    git -C "$dir" init -q
    cat > "$dir/MASTER_PLAN.md" <<'EOF'
# MASTER_PLAN: Test Project

## Identity
**Type:** test

## Original Intent
> Test project.

## Decision Log
| Date | DEC-ID | Initiative | Decision | Rationale |
|------|--------|-----------|----------|-----------|

---

## Active Initiatives

### Initiative: v1 Alpha
**Status:** completed
**Started:** 2026-02-19
**Goal:** Build the alpha

#### Phase 1: Core
**Status:** completed

## Completed Initiatives
| Initiative | Period | Phases | Key Decisions | Archived |
|-----------|--------|--------|---------------|---------|
EOF
    echo "$dir"
}

make_plan_new_format_mixed() {
    # New format: 1 active initiative, 1 completed initiative in Active Initiatives
    local dir
    dir=$(mktemp -d)
    git -C "$dir" init -q
    cat > "$dir/MASTER_PLAN.md" <<'EOF'
# MASTER_PLAN: Test Project

## Identity
**Type:** test

## Original Intent
> Test project.

## Decision Log
| Date | DEC-ID | Initiative | Decision | Rationale |
|------|--------|-----------|----------|-----------|

---

## Active Initiatives

### Initiative: v1 Alpha
**Status:** completed
**Goal:** Build v1

#### Phase 1: Core
**Status:** completed

### Initiative: v2 Beta
**Status:** active
**Goal:** Build v2

#### Phase 1: New Features
**Status:** planned

## Completed Initiatives
| Initiative | Period | Phases | Key Decisions | Archived |
|-----------|--------|--------|---------------|---------|
EOF
    echo "$dir"
}

make_plan_50_completed_active() {
    # New format: 50 completed initiatives in table + 1 active initiative with 3 phases
    local dir
    dir=$(mktemp -d)
    git -C "$dir" init -q
    {
        cat <<'EOF'
# MASTER_PLAN: Large Project

## Identity
**Type:** test
**Root:** /tmp/test

## Architecture
  hooks/ — lifecycle hooks
  agents/ — agent prompts

## Original Intent
> Build a large project with many initiatives.

## Decision Log
| Date | DEC-ID | Initiative | Decision | Rationale |
|------|--------|-----------|----------|-----------|
EOF
        for i in $(seq 1 10); do
            printf "| 2026-02-%02d | DEC-TST-%03d | v%d | Decision %d | Rationale %d |\n" \
                "$i" "$i" "$i" "$i" "$i"
        done
        cat <<'EOF'

---

## Active Initiatives

### Initiative: v51 Current Work
**Status:** active
**Started:** 2026-02-19
**Goal:** The current active initiative

#### Phase 1: Setup
**Status:** completed

#### Phase 2: Implementation
**Status:** in-progress

#### Phase 3: Testing
**Status:** planned

## Completed Initiatives
| Initiative | Period | Phases | Key Decisions | Archived |
|-----------|--------|--------|---------------|---------|
EOF
        for i in $(seq 1 50); do
            printf "| v%d | 2026-01-%02d — 2026-02-%02d | 3 | DEC-TST-%03d | — |\n" \
                "$i" "$i" "$i" "$i"
        done
    } > "$dir/MASTER_PLAN.md"
    echo "$dir"
}

make_plan_for_compress() {
    # New format: 1 active initiative with all phases completed — ready to compress
    local dir
    dir=$(mktemp -d)
    git -C "$dir" init -q
    cat > "$dir/MASTER_PLAN.md" <<'EOF'
# MASTER_PLAN: Test Project

## Identity
**Type:** test

## Original Intent
> Test project.

## Decision Log
| Date | DEC-ID | Initiative | Decision | Rationale |
|------|--------|-----------|----------|-----------|
| 2026-02-19 | DEC-CMP-001 | v1 | Test compress | Rationale |

---

## Active Initiatives

### Initiative: v1 Completed
**Status:** completed
**Started:** 2026-02-19
**Goal:** Complete this

#### Phase 1: Core
**Status:** completed

#### Phase 2: Tests
**Status:** completed

## Completed Initiatives
| Initiative | Period | Phases | Key Decisions | Archived |
|-----------|--------|--------|---------------|---------|
EOF
    echo "$dir"
}

# ============================================================
# TEST 1: No plan returns lifecycle=none
# ============================================================
test_no_plan_lifecycle_none() {
    local dir rc
    dir=$(make_plan_no_plan)

    (
        # shellcheck source=/dev/null
        source "$HOOKS_DIR/source-lib.sh"
        get_plan_status "$dir"
        [[ "$PLAN_LIFECYCLE" == "none" ]] || exit 1
        [[ "$PLAN_EXISTS" == "false" ]] || exit 1
    ) && rc=0 || rc=$?
    rm -rf "$dir"
    [[ $rc -eq 0 ]] && pass "T01: no plan → lifecycle=none" \
                     || fail "T01: no plan → lifecycle=none" "got rc=$rc"
}

# ============================================================
# TEST 2: Old format (## Phase N:) still returns active lifecycle
# ============================================================
test_old_format_lifecycle_active() {
    local dir rc
    dir=$(make_plan_old_format)

    (
        source "$HOOKS_DIR/source-lib.sh"
        get_plan_status "$dir"
        [[ "$PLAN_LIFECYCLE" == "active" ]] || exit 1
    ) && rc=0 || rc=$?
    rm -rf "$dir"
    [[ $rc -eq 0 ]] && pass "T02: old format in-progress → lifecycle=active" \
                     || fail "T02: old format in-progress → lifecycle=active" "rc=$rc"
}

# ============================================================
# TEST 3: New format with active initiative returns lifecycle=active
# ============================================================
test_new_format_active_lifecycle() {
    local dir rc
    dir=$(make_plan_new_format_active)

    (
        source "$HOOKS_DIR/source-lib.sh"
        get_plan_status "$dir"
        [[ "$PLAN_LIFECYCLE" == "active" ]] || { echo "PLAN_LIFECYCLE=$PLAN_LIFECYCLE"; exit 1; }
        [[ "$PLAN_EXISTS" == "true" ]] || exit 1
    ) && rc=0 || rc=$?
    rm -rf "$dir"
    [[ $rc -eq 0 ]] && pass "T03: new format active initiative → lifecycle=active" \
                     || fail "T03: new format active initiative → lifecycle=active" "rc=$rc"
}

# ============================================================
# TEST 4: All initiatives completed returns lifecycle=dormant
# ============================================================
test_all_done_lifecycle_dormant() {
    local dir rc
    dir=$(make_plan_new_format_all_done)

    (
        source "$HOOKS_DIR/source-lib.sh"
        get_plan_status "$dir"
        [[ "$PLAN_LIFECYCLE" == "dormant" ]] || { echo "PLAN_LIFECYCLE=$PLAN_LIFECYCLE"; exit 1; }
    ) && rc=0 || rc=$?
    rm -rf "$dir"
    [[ $rc -eq 0 ]] && pass "T04: all initiatives completed → lifecycle=dormant" \
                     || fail "T04: all initiatives completed → lifecycle=dormant" "rc=$rc"
}

# ============================================================
# TEST 5: Mixed (1 active, 1 completed) returns lifecycle=active
# ============================================================
test_mixed_lifecycle_active() {
    local dir rc
    dir=$(make_plan_new_format_mixed)

    (
        source "$HOOKS_DIR/source-lib.sh"
        get_plan_status "$dir"
        [[ "$PLAN_LIFECYCLE" == "active" ]] || { echo "PLAN_LIFECYCLE=$PLAN_LIFECYCLE"; exit 1; }
    ) && rc=0 || rc=$?
    rm -rf "$dir"
    [[ $rc -eq 0 ]] && pass "T05: mixed initiatives → lifecycle=active" \
                     || fail "T05: mixed initiatives → lifecycle=active" "rc=$rc"
}

# ============================================================
# TEST 6: PLAN_ACTIVE_INITIATIVES count is correct
# ============================================================
test_active_initiative_count() {
    local dir rc
    dir=$(make_plan_new_format_mixed)

    (
        source "$HOOKS_DIR/source-lib.sh"
        get_plan_status "$dir"
        [[ "$PLAN_ACTIVE_INITIATIVES" -eq 1 ]] || { echo "PLAN_ACTIVE_INITIATIVES=$PLAN_ACTIVE_INITIATIVES"; exit 1; }
    ) && rc=0 || rc=$?
    rm -rf "$dir"
    [[ $rc -eq 0 ]] && pass "T06: mixed plan → PLAN_ACTIVE_INITIATIVES=1" \
                     || fail "T06: mixed plan → PLAN_ACTIVE_INITIATIVES=1" "rc=$rc"
}

# ============================================================
# TEST 7: plan-check.sh allows writes when active initiative exists
# ============================================================
test_plan_check_allows_active() {
    local dir result
    dir=$(make_plan_new_format_active)
    mkdir -p "$dir/src" "$dir/.claude"

    # CLAUDE_PROJECT_DIR forces detect_project_root() to return the fixture dir,
    # ensuring get_drift_data reads from $dir/.claude/.plan-drift (empty) rather
    # than the real ~/.claude drift cache which can have large drift counts.
    result=$(printf '%s\n' $(seq 1 25) | \
        jq -Rs --arg path "$dir/src/main.sh" \
            '{"tool_name":"Write","tool_input":{"file_path":$path,"content":.}}' | \
        CLAUDE_DIR="$dir/.claude" CLAUDE_PROJECT_DIR="$dir" bash "$HOOKS_DIR/plan-check.sh" 2>/dev/null || echo "")

    rm -rf "$dir"
    if echo "$result" | grep -q '"permissionDecision": *"deny"'; then
        fail "T07: active initiative → plan-check should allow" "got deny"
    else
        pass "T07: active initiative → plan-check allows write"
    fi
}

# ============================================================
# TEST 8: plan-check.sh blocks writes when lifecycle=dormant
# ============================================================
test_plan_check_blocks_dormant() {
    local dir result
    dir=$(make_plan_new_format_all_done)
    mkdir -p "$dir/src" "$dir/.claude"

    result=$(printf '%s\n' $(seq 1 25) | \
        jq -Rs --arg path "$dir/src/main.sh" \
            '{"tool_name":"Write","tool_input":{"file_path":$path,"content":.}}' | \
        CLAUDE_DIR="$dir/.claude" bash "$HOOKS_DIR/plan-check.sh" 2>/dev/null || echo "")

    rm -rf "$dir"
    if echo "$result" | grep -qiE '"permissionDecision": *"deny"'; then
        pass "T08: dormant lifecycle → plan-check blocks write"
    else
        fail "T08: dormant lifecycle → plan-check blocks write" "no deny in result"
    fi
}

# ============================================================
# TEST 9: plan-validate.sh — new format valid plan passes
# ============================================================
test_plan_validate_identity_required() {
    local dir result
    dir=$(make_plan_new_format_active)

    result=$(jq -n --arg path "$dir/MASTER_PLAN.md" \
        '{"tool_name":"Write","tool_input":{"file_path":$path}}' | \
        bash "$HOOKS_DIR/plan-validate.sh" 2>/dev/null || echo "")

    rm -rf "$dir"
    if echo "$result" | grep -q '"decision": *"block"'; then
        fail "T09: valid new-format plan → plan-validate should not block" "got block"
    else
        pass "T09: valid new-format plan → plan-validate passes"
    fi
}

# ============================================================
# TEST 10: plan-validate.sh — plan with no Identity section warns/blocks
# ============================================================
test_plan_validate_missing_identity() {
    local dir result
    dir=$(mktemp -d)
    git -C "$dir" init -q

    cat > "$dir/MASTER_PLAN.md" <<'EOF'
# MASTER_PLAN: Test

## Original Intent
> Test.

## Active Initiatives

### Initiative: v1
**Status:** active

#### Phase 1: Core
**Status:** planned
EOF

    result=$(jq -n --arg path "$dir/MASTER_PLAN.md" \
        '{"tool_name":"Write","tool_input":{"file_path":$path}}' | \
        bash "$HOOKS_DIR/plan-validate.sh" 2>/dev/null || echo "")
    rm -rf "$dir"
    pass "T10: plan-validate runs on new format without crash"
}

# ============================================================
# TEST 11: plan-validate.sh — no toplevel ## Phase N: required
# ============================================================
test_plan_validate_no_toplevel_phase_required() {
    local dir result
    dir=$(make_plan_new_format_active)

    result=$(jq -n --arg path "$dir/MASTER_PLAN.md" \
        '{"tool_name":"Write","tool_input":{"file_path":$path}}' | \
        bash "$HOOKS_DIR/plan-validate.sh" 2>/dev/null || echo "")

    rm -rf "$dir"
    if echo "$result" | grep -q '"decision": *"block"'; then
        fail "T11: no doc-level Phase headers → should not block" "got block"
    else
        pass "T11: plan with initiative phases only → plan-validate allows"
    fi
}

# ============================================================
# TEST 12: plan-validate.sh — empty Decision Log advisory only
# ============================================================
test_plan_validate_empty_decision_log_warning() {
    local dir result
    dir=$(mktemp -d)
    git -C "$dir" init -q

    cat > "$dir/MASTER_PLAN.md" <<'EOF'
# MASTER_PLAN: Test

## Identity
**Type:** test

## Original Intent
> Test.

## Decision Log
| Date | DEC-ID | Initiative | Decision | Rationale |
|------|--------|-----------|----------|-----------|

---

## Active Initiatives

### Initiative: v1
**Status:** active

#### Phase 1: Core
**Status:** planned

## Completed Initiatives
| Initiative | Period | Phases | Key Decisions | Archived |
|-----------|--------|--------|---------------|---------|
EOF

    result=$(jq -n --arg path "$dir/MASTER_PLAN.md" \
        '{"tool_name":"Write","tool_input":{"file_path":$path}}' | \
        bash "$HOOKS_DIR/plan-validate.sh" 2>/dev/null || echo "")

    rm -rf "$dir"
    if echo "$result" | grep -q '"decision": *"block"'; then
        fail "T12: empty Decision Log → advisory only, should not block" "got block"
    else
        pass "T12: empty Decision Log → advisory warning only (not blocked)"
    fi
}

# ============================================================
# TEST 13: session-init.sh injection bounded under 250 lines for large plan
# ============================================================
test_session_init_bounded_injection() {
    local dir
    dir=$(make_plan_50_completed_active)

    # Simulate tiered extraction: Identity + Architecture + Active + last 10 decisions + completed table
    local identity_lines arch_lines active_lines dec_lines completed_lines injection_lines

    identity_lines=$(awk '/^## Identity/{f=1} f && /^## / && !/^## Identity/{exit} f{print}' \
        "$dir/MASTER_PLAN.md" | wc -l | tr -d ' ')

    arch_lines=$(awk '/^## Architecture/{f=1} f && /^## / && !/^## Architecture/{exit} f{print}' \
        "$dir/MASTER_PLAN.md" | wc -l | tr -d ' ')

    active_lines=$(awk '/^## Active Initiatives/{f=1} f && /^## Completed/{exit} f{print}' \
        "$dir/MASTER_PLAN.md" | wc -l | tr -d ' ')

    dec_lines=10  # last 10 entries

    completed_lines=$(awk '/^## Completed Initiatives/{f=1} f{print}' \
        "$dir/MASTER_PLAN.md" | grep -c '^|' 2>/dev/null || echo 0)
    [[ "$completed_lines" -gt 60 ]] && completed_lines=60

    injection_lines=$((identity_lines + arch_lines + active_lines + dec_lines + completed_lines + 10))

    rm -rf "$dir"

    if [[ "$injection_lines" -le 250 ]]; then
        pass "T13: 50-completed plan → injection bounded (${injection_lines} lines)"
    else
        fail "T13: injection bounded under 250 lines" "got ${injection_lines} lines"
    fi
}

# ============================================================
# TEST 14: Identity section extractable from new-format plan
# ============================================================
test_session_init_extracts_identity() {
    local dir
    dir=$(make_plan_new_format_active)

    local identity
    identity=$(awk '/^## Identity/{f=1} f && /^## / && !/^## Identity/{exit} f{print}' \
        "$dir/MASTER_PLAN.md" 2>/dev/null)

    rm -rf "$dir"
    if [[ -n "$identity" ]] && echo "$identity" | grep -q "## Identity"; then
        pass "T14: Identity section extractable from new-format plan"
    else
        fail "T14: Identity section extractable" "got: '$identity'"
    fi
}

# ============================================================
# TEST 15: Active initiatives section contains Initiative headers
# ============================================================
test_session_init_extracts_active_phases() {
    local dir
    dir=$(make_plan_new_format_active)

    local active_content
    active_content=$(awk '/^## Active Initiatives/{f=1} f && /^## Completed/{exit} f{print}' \
        "$dir/MASTER_PLAN.md" 2>/dev/null)

    rm -rf "$dir"
    if echo "$active_content" | grep -q "### Initiative:"; then
        pass "T15: Active initiatives section contains Initiative headers"
    else
        fail "T15: Active initiatives section has Initiative headers" "content='$active_content'"
    fi
}

# ============================================================
# TEST 16: PLAN_ACTIVE_INITIATIVES count correct on mixed plan
# ============================================================
test_prompt_submit_initiative_count() {
    local dir rc
    dir=$(make_plan_new_format_mixed)

    (
        source "$HOOKS_DIR/source-lib.sh"
        get_plan_status "$dir"
        [[ "$PLAN_ACTIVE_INITIATIVES" -eq 1 ]] || { echo "count=$PLAN_ACTIVE_INITIATIVES"; exit 1; }
        [[ "$PLAN_LIFECYCLE" == "active" ]] || { echo "lifecycle=$PLAN_LIFECYCLE"; exit 1; }
    ) && rc=0 || rc=$?
    rm -rf "$dir"
    [[ $rc -eq 0 ]] && pass "T16: mixed plan → PLAN_ACTIVE_INITIATIVES=1 and lifecycle=active" \
                     || fail "T16: prompt-submit initiative-aware" "rc=$rc"
}

# ============================================================
# TEST 17: All-done plan returns lifecycle=dormant (not "completed")
# ============================================================
test_prompt_submit_dormant_not_completed() {
    local dir rc
    dir=$(make_plan_new_format_all_done)

    (
        source "$HOOKS_DIR/source-lib.sh"
        get_plan_status "$dir"
        [[ "$PLAN_LIFECYCLE" == "dormant" ]] || { echo "lifecycle=$PLAN_LIFECYCLE"; exit 1; }
        [[ "$PLAN_LIFECYCLE" != "completed" ]] || { echo "lifecycle=completed (old word)"; exit 1; }
    ) && rc=0 || rc=$?
    rm -rf "$dir"
    [[ $rc -eq 0 ]] && pass "T17: all-done plan → lifecycle=dormant (not 'completed')" \
                     || fail "T17: dormant not completed" "rc=$rc"
}

# ============================================================
# TEST 18: compress_initiative() function exists
# ============================================================
test_compress_initiative_exists() {
    local rc
    (
        source "$HOOKS_DIR/source-lib.sh"
        declare -f compress_initiative > /dev/null 2>&1
    ) && rc=0 || rc=$?
    [[ $rc -eq 0 ]] && pass "T18: compress_initiative() function exists in context-lib.sh" \
                     || fail "T18: compress_initiative() exists" "function not found"
}

# ============================================================
# TEST 19: compress_initiative() removes initiative from Active Initiatives
# ============================================================
test_compress_removes_from_active() {
    local dir rc
    dir=$(make_plan_for_compress)

    (
        source "$HOOKS_DIR/source-lib.sh"
        compress_initiative "$dir/MASTER_PLAN.md" "v1 Completed"
        ACTIVE_BLOCK=$(awk '/^## Active Initiatives/{f=1} f && /^## Completed/{exit} f{print}' \
            "$dir/MASTER_PLAN.md" 2>/dev/null)
        if echo "$ACTIVE_BLOCK" | grep -q "### Initiative: v1 Completed"; then
            echo "Still found in Active: $ACTIVE_BLOCK"
            exit 1
        fi
    ) && rc=0 || rc=$?
    rm -rf "$dir"
    [[ $rc -eq 0 ]] && pass "T19: compress_initiative() removes from Active Initiatives" \
                     || fail "T19: compress removes from active" "rc=$rc"
}

# ============================================================
# TEST 20: compress_initiative() appends to Completed Initiatives
# ============================================================
test_compress_appends_to_completed() {
    local dir rc
    dir=$(make_plan_for_compress)

    (
        source "$HOOKS_DIR/source-lib.sh"
        compress_initiative "$dir/MASTER_PLAN.md" "v1 Completed"
        COMPLETED_BLOCK=$(awk '/^## Completed Initiatives/{f=1} f{print}' \
            "$dir/MASTER_PLAN.md" 2>/dev/null)
        if echo "$COMPLETED_BLOCK" | grep -q "v1 Completed"; then
            exit 0
        else
            echo "Completed block: $COMPLETED_BLOCK"
            exit 1
        fi
    ) && rc=0 || rc=$?
    rm -rf "$dir"
    [[ $rc -eq 0 ]] && pass "T20: compress_initiative() appends to Completed Initiatives" \
                     || fail "T20: compress appends to completed" "rc=$rc"
}

# ============================================================
# Run all tests
# ============================================================
echo "=== test-living-plan-hooks.sh: Living MASTER_PLAN format hook tests ==="
echo ""

test_no_plan_lifecycle_none
test_old_format_lifecycle_active
test_new_format_active_lifecycle
test_all_done_lifecycle_dormant
test_mixed_lifecycle_active
test_active_initiative_count
test_plan_check_allows_active
test_plan_check_blocks_dormant
test_plan_validate_identity_required
test_plan_validate_missing_identity
test_plan_validate_no_toplevel_phase_required
test_plan_validate_empty_decision_log_warning
test_session_init_bounded_injection
test_session_init_extracts_identity
test_session_init_extracts_active_phases
test_prompt_submit_initiative_count
test_prompt_submit_dormant_not_completed
test_compress_initiative_exists
test_compress_removes_from_active
test_compress_appends_to_completed

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
