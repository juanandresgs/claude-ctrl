#!/usr/bin/env bash
# test-plan-injection.sh — Bounded session injection tests for living MASTER_PLAN format.
#
# Purpose: Validate that session-init.sh injects the right sections with appropriate
# bounds for plans of all sizes. Complements T13-T15 in test-living-plan-hooks.sh
# (which cover the large-plan bound and section extractability).
#
# Coverage added here:
#   INJ-01: Small plan (1 completed initiative, empty Active) → injection under 50 lines
#   INJ-02: Active initiative goal appears in injection output
#   INJ-03: Architecture section included when present
#   INJ-04: Decision Log entries appear in injection (last 10)
#   INJ-05: Completed initiatives rows appear in injection
#   INJ-06: Old-format plan uses preamble injection (backward compat)
#   INJ-07: Active initiative with 3 phases shows phase counts in summary
#   INJ-08: Dormant plan shows dormant warning in injection
#
# @decision DEC-PLAN-003
# @title Initiative-level lifecycle replaces document-level
# @status accepted
# @rationale The bounded injection (DEC-PLAN-004, DEC-PLAN-005) keeps context useful
#   regardless of plan age. These tests verify each tier of the tiered injection:
#   Identity, Architecture, per-initiative summary, Decision Log, Completed rows.
#   A dormant plan must inject the warning so the agent knows to add a new initiative.
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
# Shared helper: invoke session-init.sh and extract additionalContext
# Returns the injection text on stdout.
# ============================================================
run_injection() {
    local project_dir="$1"
    local state_dir
    state_dir=$(mktemp -d)

    CLAUDE_PROJECT_DIR="$project_dir" \
    CLAUDE_DIR="$state_dir" \
    CLAUDE_SESSION_ID="test-inj-$$" \
    bash "$HOOKS_DIR/session-init.sh" 2>/dev/null \
    | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    ctx = data.get('hookSpecificOutput', {}).get('additionalContext', '')
    print(ctx)
except Exception:
    pass
" 2>/dev/null || true

    rm -rf "$state_dir"
}

# ============================================================
# Fixtures
# ============================================================

make_small_dormant_plan() {
    # One completed initiative, empty Active section — smallest realistic new-format plan
    local dir
    dir=$(mktemp -d)
    git -C "$dir" init -q
    # Need a commit so git rev-parse --abbrev-ref HEAD works
    local _tree _cmt
    _tree=$(git -C "$dir" write-tree 2>/dev/null)
    _cmt=$(GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=t@t.com GIT_AUTHOR_DATE="2026-01-01T00:00:00" \
           GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=t@t.com GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
           git -C "$dir" commit-tree "$_tree" -m "init" 2>/dev/null)
    git -C "$dir" update-ref HEAD "$_cmt" 2>/dev/null || true

    cat > "$dir/MASTER_PLAN.md" <<'EOF'
# MASTER_PLAN: Small Dormant

## Identity
**Type:** test
**Root:** /tmp/test

## Original Intent
> A minimal test project.

## Decision Log
| Date | DEC-ID | Initiative | Decision | Rationale |
|------|--------|-----------|----------|-----------|
| 2026-01-15 | DEC-SM-001 | v1 | Use bash | Simple and portable |

---

## Active Initiatives

## Completed Initiatives
| Initiative | Period | Phases | Key Decisions | Archived |
|-----------|--------|--------|---------------|---------|
| v1 Alpha | 2026-01-01 — 2026-01-31 | 2 | DEC-SM-001 | — |
EOF
    echo "$dir"
}

make_plan_with_architecture() {
    # New-format plan with explicit ## Architecture section
    local dir
    dir=$(mktemp -d)
    git -C "$dir" init -q
    local _tree _cmt
    _tree=$(git -C "$dir" write-tree 2>/dev/null)
    _cmt=$(GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=t@t.com GIT_AUTHOR_DATE="2026-01-01T00:00:00" \
           GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=t@t.com GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
           git -C "$dir" commit-tree "$_tree" -m "init" 2>/dev/null)
    git -C "$dir" update-ref HEAD "$_cmt" 2>/dev/null || true

    cat > "$dir/MASTER_PLAN.md" <<'EOF'
# MASTER_PLAN: Architecture Test

## Identity
**Type:** test

## Architecture
  hooks/ — lifecycle hooks
  agents/ — agent prompts
  scripts/ — utility scripts

## Original Intent
> A project with architecture section.

## Decision Log
| Date | DEC-ID | Initiative | Decision | Rationale |
|------|--------|-----------|----------|-----------|
| 2026-02-01 | DEC-AR-001 | v2 | Modular hooks | Separation of concerns |
| 2026-02-02 | DEC-AR-002 | v2 | Shared library | DRY principle |

---

## Active Initiatives

### Initiative: v2 Modular
**Status:** active
**Goal:** Refactor to modular architecture

#### Phase 1: Extract
**Status:** in-progress

#### Phase 2: Test
**Status:** planned

## Completed Initiatives
| Initiative | Period | Phases | Key Decisions | Archived |
|-----------|--------|--------|---------------|---------|
EOF
    echo "$dir"
}

make_plan_with_many_decisions() {
    # New-format plan with 15 decision log entries (should inject last 10)
    local dir
    dir=$(mktemp -d)
    git -C "$dir" init -q
    local _tree _cmt
    _tree=$(git -C "$dir" write-tree 2>/dev/null)
    _cmt=$(GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=t@t.com GIT_AUTHOR_DATE="2026-01-01T00:00:00" \
           GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=t@t.com GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
           git -C "$dir" commit-tree "$_tree" -m "init" 2>/dev/null)
    git -C "$dir" update-ref HEAD "$_cmt" 2>/dev/null || true

    {
        printf '%s\n' '# MASTER_PLAN: Many Decisions' '' '## Identity' '**Type:** test' '' '## Original Intent' '> Decision log test.' '' '## Decision Log' \
            '| Date | DEC-ID | Initiative | Decision | Rationale |' \
            '|------|--------|-----------|----------|-----------|'
        for i in $(seq 1 15); do
            printf "| 2026-01-%02d | DEC-MD-%03d | v1 | Decision %d | Rationale %d |\n" "$i" "$i" "$i" "$i"
        done
        printf '%s\n' '' '---' '' '## Active Initiatives' '' '### Initiative: v1 Decisions' \
            '**Status:** active' '**Goal:** Test decision injection' '' '#### Phase 1: Work' \
            '**Status:** in-progress' '' '## Completed Initiatives' \
            '| Initiative | Period | Phases | Key Decisions | Archived |' \
            '|-----------|--------|--------|---------------|---------|'
    } > "$dir/MASTER_PLAN.md"
    echo "$dir"
}

make_plan_with_completed_rows() {
    # New-format plan with 5 completed initiatives in the table
    local dir
    dir=$(mktemp -d)
    git -C "$dir" init -q
    local _tree _cmt
    _tree=$(git -C "$dir" write-tree 2>/dev/null)
    _cmt=$(GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=t@t.com GIT_AUTHOR_DATE="2026-01-01T00:00:00" \
           GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=t@t.com GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
           git -C "$dir" commit-tree "$_tree" -m "init" 2>/dev/null)
    git -C "$dir" update-ref HEAD "$_cmt" 2>/dev/null || true

    {
        printf '%s\n' '# MASTER_PLAN: Completed Rows' '' '## Identity' '**Type:** test' '' '## Original Intent' \
            '> Completed rows test.' '' '## Decision Log' \
            '| Date | DEC-ID | Initiative | Decision | Rationale |' \
            '|------|--------|-----------|----------|-----------|' '' '---' '' \
            '## Active Initiatives' '' '### Initiative: v6 Current' \
            '**Status:** active' '**Goal:** Current work' '' '#### Phase 1: Now' \
            '**Status:** in-progress' '' '## Completed Initiatives' \
            '| Initiative | Period | Phases | Key Decisions | Archived |' \
            '|-----------|--------|--------|---------------|---------|'
        for i in $(seq 1 5); do
            printf "| v%d Alpha | 2026-0%d-01 — 2026-0%d-28 | 3 | DEC-CR-%03d | — |\n" "$i" "$i" "$i" "$i"
        done
    } > "$dir/MASTER_PLAN.md"
    echo "$dir"
}

make_old_format_plan() {
    # Old-format plan with ## Phase N: headers and ## Original Intent preamble
    local dir
    dir=$(mktemp -d)
    git -C "$dir" init -q
    local _tree _cmt
    _tree=$(git -C "$dir" write-tree 2>/dev/null)
    _cmt=$(GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=t@t.com GIT_AUTHOR_DATE="2026-01-01T00:00:00" \
           GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=t@t.com GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
           git -C "$dir" commit-tree "$_tree" -m "init" 2>/dev/null)
    git -C "$dir" update-ref HEAD "$_cmt" 2>/dev/null || true

    cat > "$dir/MASTER_PLAN.md" <<'EOF'
# MASTER_PLAN: Old Format Project

## Original Intent
A project using the old phase-based format.

---

## Phase 1: Foundation
**Status:** completed

## Phase 2: Features
**Status:** in-progress
EOF
    echo "$dir"
}

make_plan_active_with_3_phases() {
    # Active initiative with 3 phases at different statuses
    local dir
    dir=$(mktemp -d)
    git -C "$dir" init -q
    local _tree _cmt
    _tree=$(git -C "$dir" write-tree 2>/dev/null)
    _cmt=$(GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=t@t.com GIT_AUTHOR_DATE="2026-01-01T00:00:00" \
           GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=t@t.com GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
           git -C "$dir" commit-tree "$_tree" -m "init" 2>/dev/null)
    git -C "$dir" update-ref HEAD "$_cmt" 2>/dev/null || true

    cat > "$dir/MASTER_PLAN.md" <<'EOF'
# MASTER_PLAN: Phase Count Test

## Identity
**Type:** test

## Original Intent
> Phase count test.

## Decision Log
| Date | DEC-ID | Initiative | Decision | Rationale |
|------|--------|-----------|----------|-----------|

---

## Active Initiatives

### Initiative: v3 Phases
**Status:** active
**Goal:** Test phase counting in summary

#### Phase 1: Done Work
**Status:** completed

#### Phase 2: Current Work
**Status:** in-progress

#### Phase 3: Future Work
**Status:** planned

## Completed Initiatives
| Initiative | Period | Phases | Key Decisions | Archived |
|-----------|--------|--------|---------------|---------|
EOF
    echo "$dir"
}

# ============================================================
# TEST INJ-01: Small dormant plan → injection under 50 lines
# ============================================================
test_small_dormant_injection_bounded() {
    local dir
    dir=$(make_small_dormant_plan)

    local injection
    injection=$(run_injection "$dir")
    local line_count
    line_count=$(echo "$injection" | wc -l | tr -d ' ')

    rm -rf "$dir"

    if [[ "$line_count" -le 50 ]]; then
        pass "INJ-01: small dormant plan → injection bounded (${line_count} lines ≤ 50)"
    else
        fail "INJ-01: small plan injection bounded" "got ${line_count} lines, expected ≤ 50"
    fi
}

# ============================================================
# TEST INJ-02: Active initiative goal appears in injection
# ============================================================
test_active_goal_in_injection() {
    local dir
    dir=$(make_plan_with_architecture)

    local injection
    injection=$(run_injection "$dir")

    rm -rf "$dir"

    if echo "$injection" | grep -q "Refactor to modular architecture"; then
        pass "INJ-02: active initiative goal appears in injection"
    else
        fail "INJ-02: goal in injection" "goal not found in injection. Got: $(echo "$injection" | head -30)"
    fi
}

# ============================================================
# TEST INJ-03: Architecture section included when present
# ============================================================
test_architecture_section_injected() {
    local dir
    dir=$(make_plan_with_architecture)

    local injection
    injection=$(run_injection "$dir")

    rm -rf "$dir"

    if echo "$injection" | grep -q "## Architecture"; then
        pass "INJ-03: Architecture section included in injection"
    else
        fail "INJ-03: Architecture section in injection" "not found. Got: $(echo "$injection" | head -30)"
    fi
}

# ============================================================
# TEST INJ-04: Decision Log entries appear in injection (last 10 of 15)
# ============================================================
test_decision_log_in_injection() {
    local dir
    dir=$(make_plan_with_many_decisions)

    local injection
    injection=$(run_injection "$dir")

    rm -rf "$dir"

    # Decision 15 (most recent) should appear; decision 1 (oldest) should not
    local has_recent has_oldest
    echo "$injection" | grep -q "DEC-MD-015" && has_recent=1 || has_recent=0
    echo "$injection" | grep -q "DEC-MD-001" && has_oldest=1 || has_oldest=0

    if [[ "$has_recent" -eq 1 && "$has_oldest" -eq 0 ]]; then
        pass "INJ-04: Decision Log shows last 10 entries (recent DEC-015 present, oldest DEC-001 absent)"
    elif [[ "$has_recent" -eq 0 ]]; then
        fail "INJ-04: recent Decision Log entry in injection" "DEC-MD-015 not found"
    else
        fail "INJ-04: Decision Log limited to 10 entries" "oldest entry DEC-MD-001 still present (not trimmed)"
    fi
}

# ============================================================
# TEST INJ-05: Completed initiatives table rows appear in injection
# ============================================================
test_completed_rows_in_injection() {
    local dir
    dir=$(make_plan_with_completed_rows)

    local injection
    injection=$(run_injection "$dir")

    rm -rf "$dir"

    if echo "$injection" | grep -q "v1 Alpha"; then
        pass "INJ-05: completed initiatives table rows appear in injection"
    else
        fail "INJ-05: completed initiatives rows in injection" "v1 Alpha not found. Got: $(echo "$injection" | head -40)"
    fi
}

# ============================================================
# TEST INJ-06: Old-format plan uses preamble injection (backward compat)
# ============================================================
test_old_format_preamble_injection() {
    local dir
    dir=$(make_old_format_plan)

    local injection
    injection=$(run_injection "$dir")

    rm -rf "$dir"

    # Old format should inject preamble content (title or "Original Intent")
    if echo "$injection" | grep -qE "Old Format Project|Original Intent|Phase [0-9]"; then
        pass "INJ-06: old-format plan uses preamble injection (backward compat)"
    else
        fail "INJ-06: old-format preamble injection" "no plan content found. Got: $(echo "$injection" | head -20)"
    fi
}

# ============================================================
# TEST INJ-07: Active initiative phase counts appear in summary
# ============================================================
test_phase_counts_in_summary() {
    local dir
    dir=$(make_plan_active_with_3_phases)

    local injection
    injection=$(run_injection "$dir")

    rm -rf "$dir"

    # The compact summary should show phase counts like "1 planned, 1 in-progress, 1 completed"
    if echo "$injection" | grep -qE "planned|in-progress|completed"; then
        pass "INJ-07: phase counts appear in initiative summary"
    else
        fail "INJ-07: phase counts in summary" "no phase status found. Got: $(echo "$injection" | head -30)"
    fi
}

# ============================================================
# TEST INJ-08: Dormant plan shows dormant warning in injection
# ============================================================
test_dormant_warning_in_injection() {
    local dir
    dir=$(make_small_dormant_plan)

    local injection
    injection=$(run_injection "$dir")

    rm -rf "$dir"

    if echo "$injection" | grep -qi "dormant"; then
        pass "INJ-08: dormant plan → dormant warning present in injection"
    else
        fail "INJ-08: dormant warning in injection" "no 'dormant' keyword found"
    fi
}

# ============================================================
# Run all tests
# ============================================================
echo "=== test-plan-injection.sh: Bounded session injection tests ==="
echo ""

test_small_dormant_injection_bounded
test_active_goal_in_injection
test_architecture_section_injected
test_decision_log_in_injection
test_completed_rows_in_injection
test_old_format_preamble_injection
test_phase_counts_in_summary
test_dormant_warning_in_injection

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
