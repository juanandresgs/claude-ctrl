#!/usr/bin/env bash
# test-plan-lifecycle.sh — Initiative-level lifecycle tests for living MASTER_PLAN format.
#
# Purpose: Validate get_plan_status() lifecycle transitions and plan-check.sh enforcement
# for edge cases NOT covered by test-living-plan-hooks.sh (T01-T08, T16-T17).
#
# Coverage gap filled:
#   - Empty Active Initiatives section → dormant
#   - Multiple active initiatives → PLAN_ACTIVE_INITIATIVES count
#   - Initiative with "planned" status → treated as not-active
#   - plan-check blocks when Active section is empty
#   - PLAN_TOTAL_INITIATIVES count includes all initiatives in Active section
#   - New initiative starts active; completing it transitions to dormant
#
# @decision DEC-PLAN-003
# @title Initiative-level lifecycle replaces document-level
# @status accepted
# @rationale PLAN_LIFECYCLE becomes none/active/dormant based on ### Initiative: headers
#   and their Status fields. Tests here validate edge cases beyond the basic T01-T08 suite
#   in test-living-plan-hooks.sh. Each test uses isolated temp dirs for clean isolation.
#
# TAP-compatible: uses pass/fail/skip helpers and exits 1 on any failure.

set -euo pipefail

PASS=0
FAIL=0
SKIP=0

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)/hooks"

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP: $1 — $2"; SKIP=$((SKIP+1)); }

# ============================================================
# Fixtures
# ============================================================

make_plan_empty_active_section() {
    # New format: Active Initiatives section exists but has no ### Initiative: blocks
    local dir
    dir=$(mktemp -d)
    git -C "$dir" init -q
    cat > "$dir/MASTER_PLAN.md" <<'EOF'
# MASTER_PLAN: Empty Active Test

## Identity
**Type:** test
**Root:** /tmp/test

## Original Intent
> Test project.

## Decision Log
| Date | DEC-ID | Initiative | Decision | Rationale |
|------|--------|-----------|----------|-----------|

---

## Active Initiatives

## Completed Initiatives
| Initiative | Period | Phases | Key Decisions | Archived |
|-----------|--------|--------|---------------|---------|
| v1 Alpha | 2026-01-01 — 2026-01-31 | 3 | DEC-TST-001 | — |
EOF
    echo "$dir"
}

make_plan_multiple_active() {
    # New format: 3 active initiatives in Active section
    local dir
    dir=$(mktemp -d)
    git -C "$dir" init -q
    cat > "$dir/MASTER_PLAN.md" <<'EOF'
# MASTER_PLAN: Multi-Active Test

## Identity
**Type:** test

## Original Intent
> Test project with multiple active initiatives.

## Decision Log
| Date | DEC-ID | Initiative | Decision | Rationale |
|------|--------|-----------|----------|-----------|

---

## Active Initiatives

### Initiative: v2 Alpha
**Status:** active
**Goal:** Build alpha

#### Phase 1: Core
**Status:** in-progress

### Initiative: v3 Beta
**Status:** active
**Goal:** Build beta

#### Phase 1: Setup
**Status:** planned

### Initiative: v4 Gamma
**Status:** active
**Goal:** Build gamma

#### Phase 1: Init
**Status:** planned

## Completed Initiatives
| Initiative | Period | Phases | Key Decisions | Archived |
|-----------|--------|--------|---------------|---------|
EOF
    echo "$dir"
}

make_plan_planned_status_only() {
    # New format: initiative has Status: planned (not active/completed)
    local dir
    dir=$(mktemp -d)
    git -C "$dir" init -q
    cat > "$dir/MASTER_PLAN.md" <<'EOF'
# MASTER_PLAN: Planned-Only Test

## Identity
**Type:** test

## Original Intent
> Test project.

## Decision Log
| Date | DEC-ID | Initiative | Decision | Rationale |
|------|--------|-----------|----------|-----------|

---

## Active Initiatives

### Initiative: v5 Future
**Status:** planned
**Goal:** Plan this initiative

#### Phase 1: Design
**Status:** planned

## Completed Initiatives
| Initiative | Period | Phases | Key Decisions | Archived |
|-----------|--------|--------|---------------|---------|
EOF
    echo "$dir"
}

make_plan_active_then_complete() {
    # New format: one initiative, starts active — we'll mutate it to completed to test transition
    local dir
    dir=$(mktemp -d)
    git -C "$dir" init -q
    cat > "$dir/MASTER_PLAN.md" <<'EOF'
# MASTER_PLAN: Transition Test

## Identity
**Type:** test

## Original Intent
> Test lifecycle transition.

## Decision Log
| Date | DEC-ID | Initiative | Decision | Rationale |
|------|--------|-----------|----------|-----------|

---

## Active Initiatives

### Initiative: v6 Transition
**Status:** active
**Goal:** Test transition

#### Phase 1: Work
**Status:** in-progress

## Completed Initiatives
| Initiative | Period | Phases | Key Decisions | Archived |
|-----------|--------|--------|---------------|---------|
EOF
    echo "$dir"
}

make_plan_mixed_counts() {
    # New format: 2 active + 1 completed in Active section, 3 total
    local dir
    dir=$(mktemp -d)
    git -C "$dir" init -q
    cat > "$dir/MASTER_PLAN.md" <<'EOF'
# MASTER_PLAN: Mixed Count Test

## Identity
**Type:** test

## Original Intent
> Test counting.

## Decision Log
| Date | DEC-ID | Initiative | Decision | Rationale |
|------|--------|-----------|----------|-----------|

---

## Active Initiatives

### Initiative: v7 First
**Status:** completed
**Goal:** Done

#### Phase 1: Core
**Status:** completed

### Initiative: v8 Second
**Status:** active
**Goal:** Working

#### Phase 1: Features
**Status:** in-progress

### Initiative: v9 Third
**Status:** active
**Goal:** Also working

#### Phase 1: Tests
**Status:** planned

## Completed Initiatives
| Initiative | Period | Phases | Key Decisions | Archived |
|-----------|--------|--------|---------------|---------|
EOF
    echo "$dir"
}

# ============================================================
# TEST PL-01: Empty Active Initiatives section → lifecycle=dormant
# ============================================================
test_empty_active_section_dormant() {
    local dir rc
    dir=$(make_plan_empty_active_section)

    (
        source "$HOOKS_DIR/source-lib.sh"
        get_plan_status "$dir"
        [[ "$PLAN_LIFECYCLE" == "dormant" ]] || { echo "lifecycle=$PLAN_LIFECYCLE"; exit 1; }
        [[ "$PLAN_ACTIVE_INITIATIVES" -eq 0 ]] || { echo "active=$PLAN_ACTIVE_INITIATIVES"; exit 1; }
    ) && rc=0 || rc=$?
    rm -rf "$dir"
    [[ $rc -eq 0 ]] && pass "PL-01: empty Active section → lifecycle=dormant, active_count=0" \
                     || fail "PL-01: empty Active section → dormant" "rc=$rc"
}

# ============================================================
# TEST PL-02: Three active initiatives → PLAN_ACTIVE_INITIATIVES=3
# ============================================================
test_multiple_active_initiatives_count() {
    local dir rc
    dir=$(make_plan_multiple_active)

    (
        source "$HOOKS_DIR/source-lib.sh"
        get_plan_status "$dir"
        [[ "$PLAN_LIFECYCLE" == "active" ]] || { echo "lifecycle=$PLAN_LIFECYCLE"; exit 1; }
        [[ "$PLAN_ACTIVE_INITIATIVES" -eq 3 ]] || { echo "active=$PLAN_ACTIVE_INITIATIVES"; exit 1; }
    ) && rc=0 || rc=$?
    rm -rf "$dir"
    [[ $rc -eq 0 ]] && pass "PL-02: 3 active initiatives → lifecycle=active, active_count=3" \
                     || fail "PL-02: multiple active initiatives count" "rc=$rc"
}

# ============================================================
# TEST PL-03: Initiative with Status: planned → not counted as active
# ============================================================
test_planned_status_not_active() {
    local dir rc
    dir=$(make_plan_planned_status_only)

    (
        source "$HOOKS_DIR/source-lib.sh"
        get_plan_status "$dir"
        # "planned" is neither "active" nor "completed" — counts as neither
        # The section has 1 initiative total; 0 active, 0 completed → dormant
        [[ "$PLAN_ACTIVE_INITIATIVES" -eq 0 ]] || { echo "active=$PLAN_ACTIVE_INITIATIVES"; exit 1; }
        [[ "$PLAN_LIFECYCLE" == "dormant" ]] || { echo "lifecycle=$PLAN_LIFECYCLE"; exit 1; }
    ) && rc=0 || rc=$?
    rm -rf "$dir"
    [[ $rc -eq 0 ]] && pass "PL-03: Status: planned initiative → not counted as active, lifecycle=dormant" \
                     || fail "PL-03: planned status not active" "rc=$rc"
}

# ============================================================
# TEST PL-04: PLAN_TOTAL_INITIATIVES counts all initiatives in Active section
# ============================================================
test_total_initiatives_count() {
    local dir rc
    dir=$(make_plan_mixed_counts)

    (
        source "$HOOKS_DIR/source-lib.sh"
        get_plan_status "$dir"
        # 3 total initiatives in Active section (1 completed + 2 active)
        [[ "$PLAN_TOTAL_INITIATIVES" -eq 3 ]] || { echo "total=$PLAN_TOTAL_INITIATIVES"; exit 1; }
        [[ "$PLAN_ACTIVE_INITIATIVES" -eq 2 ]] || { echo "active=$PLAN_ACTIVE_INITIATIVES"; exit 1; }
        [[ "$PLAN_LIFECYCLE" == "active" ]] || { echo "lifecycle=$PLAN_LIFECYCLE"; exit 1; }
    ) && rc=0 || rc=$?
    rm -rf "$dir"
    [[ $rc -eq 0 ]] && pass "PL-04: mixed Active section → total=3, active=2, lifecycle=active" \
                     || fail "PL-04: total initiatives count" "rc=$rc"
}

# ============================================================
# TEST PL-05: Lifecycle transition — active → dormant when initiative completed
# ============================================================
test_lifecycle_transition_active_to_dormant() {
    local dir rc
    dir=$(make_plan_active_then_complete)

    # First: verify it starts active
    (
        source "$HOOKS_DIR/source-lib.sh"
        get_plan_status "$dir"
        [[ "$PLAN_LIFECYCLE" == "active" ]] || { echo "before=$PLAN_LIFECYCLE"; exit 1; }
    ) && rc=0 || rc=$?

    if [[ $rc -ne 0 ]]; then
        rm -rf "$dir"
        fail "PL-05: lifecycle transition — initial state not active" "rc=$rc"
        return
    fi

    # Mutate the plan: mark the initiative as completed
    sed -i.bak 's/\*\*Status:\*\* active/\*\*Status:\*\* completed/' "$dir/MASTER_PLAN.md"
    rm -f "$dir/MASTER_PLAN.md.bak"

    # Now verify it becomes dormant
    (
        source "$HOOKS_DIR/source-lib.sh"
        get_plan_status "$dir"
        [[ "$PLAN_LIFECYCLE" == "dormant" ]] || { echo "after=$PLAN_LIFECYCLE"; exit 1; }
    ) && rc=0 || rc=$?
    rm -rf "$dir"
    [[ $rc -eq 0 ]] && pass "PL-05: lifecycle transitions active → dormant when initiative completed" \
                     || fail "PL-05: lifecycle transition active→dormant" "rc=$rc"
}

# ============================================================
# TEST PL-06: plan-check.sh blocks writes when Active section is empty
# ============================================================
test_plan_check_blocks_empty_active_section() {
    local dir result
    dir=$(make_plan_empty_active_section)
    mkdir -p "$dir/src" "$dir/.claude"

    # Feed plan-check a Write tool event for a source file (>20 lines to bypass fast-mode)
    result=$(printf '%s\n' $(seq 1 25) | \
        jq -Rs --arg path "$dir/src/main.sh" \
            '{"tool_name":"Write","tool_input":{"file_path":$path,"content":.}}' | \
        CLAUDE_DIR="$dir/.claude" CLAUDE_PROJECT_DIR="$dir" bash "$HOOKS_DIR/plan-check.sh" 2>/dev/null || echo "")

    rm -rf "$dir"
    if echo "$result" | grep -qiE '"permissionDecision": *"deny"'; then
        pass "PL-06: empty Active section → plan-check blocks source writes"
    else
        fail "PL-06: plan-check blocks empty Active section" "no deny in result: $result"
    fi
}

# ============================================================
# TEST PL-07: plan-check.sh allows writes with multiple active initiatives
# ============================================================
test_plan_check_allows_multiple_active() {
    local dir result
    dir=$(make_plan_multiple_active)
    mkdir -p "$dir/src" "$dir/.claude"

    result=$(printf '%s\n' $(seq 1 25) | \
        jq -Rs --arg path "$dir/src/main.sh" \
            '{"tool_name":"Write","tool_input":{"file_path":$path,"content":.}}' | \
        CLAUDE_DIR="$dir/.claude" CLAUDE_PROJECT_DIR="$dir" bash "$HOOKS_DIR/plan-check.sh" 2>/dev/null || echo "")

    rm -rf "$dir"
    if echo "$result" | grep -q '"permissionDecision": *"deny"'; then
        fail "PL-07: multiple active initiatives → plan-check should allow" "got deny"
    else
        pass "PL-07: multiple active initiatives → plan-check allows source writes"
    fi
}

# ============================================================
# TEST PL-08: PLAN_EXISTS=true when new-format plan present
# ============================================================
test_plan_exists_true_new_format() {
    local dir rc
    dir=$(make_plan_multiple_active)

    (
        source "$HOOKS_DIR/source-lib.sh"
        get_plan_status "$dir"
        [[ "$PLAN_EXISTS" == "true" ]] || { echo "PLAN_EXISTS=$PLAN_EXISTS"; exit 1; }
    ) && rc=0 || rc=$?
    rm -rf "$dir"
    [[ $rc -eq 0 ]] && pass "PL-08: new-format plan present → PLAN_EXISTS=true" \
                     || fail "PL-08: PLAN_EXISTS=true for new format" "rc=$rc"
}

# ============================================================
# Run all tests
# ============================================================
echo "=== test-plan-lifecycle.sh: Initiative-level lifecycle edge case tests ==="
echo ""

test_empty_active_section_dormant
test_multiple_active_initiatives_count
test_planned_status_not_active
test_total_initiatives_count
test_lifecycle_transition_active_to_dormant
test_plan_check_blocks_empty_active_section
test_plan_check_allows_multiple_active
test_plan_exists_true_new_format

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
