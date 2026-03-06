#!/usr/bin/env bash
# test-validation-harness.sh — Validation harness for trace classification fixtures
#
# Purpose: Run finalize_trace() against 11 known-good fixture trace directories
#   and verify each produces the expected outcome classification. Acts as a
#   regression guard for agent-type-aware classification logic in trace-lib.sh.
#
# Design:
#   1. Loads trace-baseline.json to get expected classification per fixture
#   2. For each fixture, copies it to a temp TRACE_STORE, sets up required
#      state files (git repos for guardian, MASTER_PLAN.md for planner, etc.)
#   3. Calls finalize_trace() and reads the resulting outcome field
#   4. Compares against expected; reports accuracy
#   5. Exits 1 if accuracy < 95% or any regressions detected
#
# Flags:
#   --update-baseline   Regenerate trace-baseline.json from current results
#
# @decision DEC-HARNESS-001
# @title Static fixture files + runtime state setup for classification harness
# @status accepted
# @rationale Three alternatives were considered:
#   (a) Fully static fixtures: all state pre-baked into JSON. Rejected because
#       guardian success requires a real git repo with two commits (start SHA !=
#       HEAD). You cannot fake git rev-parse HEAD with static files alone.
#   (b) Full dynamic (no fixtures): create everything at runtime. Rejected
#       because it duplicates test-trace-classification.sh and offers no
#       regression value — if we just re-run the same dynamic logic, we test
#       the logic but not its stability against static known inputs.
#   (c) Hybrid (chosen): fixture directories hold manifest.json, summary.md,
#       compliance.json (the "what happened" data). The harness sets up the
#       "environment" state files (git repos, SHA files, MASTER_PLAN.md) at
#       runtime. Fixtures are checked into git as regression anchors; runtime
#       setup is minimal and deterministic.
#
# @decision DEC-HARNESS-002
# @title Avoid bash 4+ associative arrays for macOS bash 3.2 compatibility
# @status accepted
# @rationale macOS ships bash 3.2 as the system shell. declare -A requires bash 4+.
#   We use parallel space-separated KEY=VALUE strings in a plain variable, iterated
#   with grep for lookups. This is portable and shellcheck-clean.
#
# Usage: bash tests/test-validation-harness.sh [--update-baseline]
# Returns: 0 if accuracy >= 95% and no regressions, 1 otherwise

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_TRACES_DIR="$SCRIPT_DIR/fixtures/traces"
BASELINE_FILE="$SCRIPT_DIR/fixtures/trace-baseline.json"

HOOKS_DIR="${WORKTREE_ROOT}/hooks"

UPDATE_BASELINE=false
if [[ "${1:-}" == "--update-baseline" ]]; then
    UPDATE_BASELINE=true
fi

PASS=0
FAIL=0
REGRESSION_COUNT=0

pass() { echo "PASS [$1]: expected=$2 got=$2"; PASS=$((PASS + 1)); }
fail() { echo "FAIL [$1]: expected=$2 got=$3"; FAIL=$((FAIL + 1)); }

# Suppress hook stderr during setup
exec 2>/dev/null

# shellcheck source=/dev/null
source "${HOOKS_DIR}/source-lib.sh"
require_trace

# Override TRACE_STORE with a temp dir AFTER sourcing
TRACE_STORE=$(mktemp -d)
export TRACE_STORE

# Temp dir for CLAUDE_DIR (guardian uses CLAUDE_DIR for .guardian-start-sha)
CLAUDE_DIR_TEMP=$(mktemp -d)
export CLAUDE_DIR="$CLAUDE_DIR_TEMP"

CLEANUP_DIRS="$TRACE_STORE $CLAUDE_DIR_TEMP"
# SC2064 note: intentional — CLEANUP_DIRS must expand at trap-set time to capture
# the current value. Variables added later via "CLEANUP_DIRS+=..." are picked up
# because the loop re-reads the variable at exit time via the unquoted $CLEANUP_DIRS.
# SC2154 false positive: shellcheck cannot infer loop variables inside trap strings.
# shellcheck disable=SC2064
trap "rm -rf \$CLEANUP_DIRS 2>/dev/null || true" EXIT

# Re-enable stderr for test output
exec 2>&1

# ─────────────────────────────────────────────────────────────────────────────
# Helper: copy a fixture dir into TRACE_STORE, substitute __PROJECT_ROOT__ and
# __START_SHA__ in manifest.json, return the trace_id (= fixture dir name)
# ─────────────────────────────────────────────────────────────────────────────
setup_fixture() {
    local fixture_name="$1"
    local project_root="$2"
    local start_sha="${3:-}"
    # Optional: override __STARTED_AT__ placeholder in manifest.json.
    # Use "recent" to substitute a timestamp 60 seconds ago (keeps duration < 600s).
    # Use "" or omit to keep the fixture's original __STARTED_AT__ value.
    local started_at_override="${4:-}"

    local src="$FIXTURES_TRACES_DIR/$fixture_name"
    local dst="$TRACE_STORE/$fixture_name"

    # Copy fixture into trace store
    cp -r "$src" "$dst"

    # Resolve started_at value
    local started_at_val
    if [[ "$started_at_override" == "recent" ]]; then
        # 60 seconds ago — keeps duration well under 600s threshold
        started_at_val=$(date -u -v -60S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u +%Y-%m-%dT%H:%M:%SZ)
    elif [[ -n "$started_at_override" ]]; then
        started_at_val="$started_at_override"
    else
        # Keep fixture's own __STARTED_AT__ value (or static date string — no placeholder)
        started_at_val="__STARTED_AT__"
    fi

    # Substitute placeholders in manifest.json
    local tmp_manifest="${dst}/manifest.json.tmp"
    sed \
        -e "s|__PROJECT_ROOT__|${project_root}|g" \
        -e "s|__START_SHA__|${start_sha}|g" \
        -e "s|__STARTED_AT__|${started_at_val}|g" \
        "${dst}/manifest.json" > "$tmp_manifest"
    mv "$tmp_manifest" "${dst}/manifest.json"

    echo "$fixture_name"
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: create a minimal git project with one commit, return project path
# ─────────────────────────────────────────────────────────────────────────────
make_git_project() {
    local d
    d=$(mktemp -d)
    CLEANUP_DIRS="$CLEANUP_DIRS $d"
    git -C "$d" init -q
    git -C "$d" config user.email "test@ci.local"
    git -C "$d" config user.name "CI Test Runner"
    echo "initial" > "$d/file.txt"
    git -C "$d" add file.txt
    git -C "$d" commit -q -m "Initial commit"
    echo "$d"
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: read outcome from finalized manifest
# ─────────────────────────────────────────────────────────────────────────────
get_outcome() {
    local trace_id="$1"
    jq -r '.outcome // "not-set"' "${TRACE_STORE}/${trace_id}/manifest.json" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Storage for actual results (newline-separated "name=value" pairs, bash 3 compat)
# ─────────────────────────────────────────────────────────────────────────────
ACTUAL_RESULTS_FILE=$(mktemp)
CLEANUP_DIRS="$CLEANUP_DIRS $ACTUAL_RESULTS_FILE"

record_result() {
    local fixture="$1"
    local outcome="$2"
    echo "${fixture}=${outcome}" >> "$ACTUAL_RESULTS_FILE"
}

lookup_result() {
    local fixture="$1"
    grep "^${fixture}=" "$ACTUAL_RESULTS_FILE" 2>/dev/null | cut -d= -f2- || echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Fixture: guardian-success
# State: make git project, advance HEAD, write start SHA to CLAUDE_DIR
# Expected: success (HEAD != start SHA)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- guardian-success ---"
{
    proj=$(make_git_project)
    start_sha=$(git -C "$proj" rev-parse HEAD)
    tid=$(setup_fixture "guardian-success" "$proj" "$start_sha")

    # Write start SHA so finalize_trace can compare it
    echo "$start_sha" > "${CLAUDE_DIR}/.guardian-start-sha"

    # Advance HEAD so current SHA differs from start SHA
    echo "more work" >> "$proj/file.txt"
    git -C "$proj" add file.txt
    git -C "$proj" commit -q -m "Guardian commit"

    finalize_trace "$tid" "$proj" "guardian" 2>/dev/null
    outcome=$(get_outcome "$tid")
    record_result "guardian-success" "$outcome"

    if [[ "$outcome" == "success" ]]; then
        pass "guardian-success" "success"
    else
        fail "guardian-success" "success" "$outcome"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Fixture: guardian-partial
# State: make git project, DO NOT advance HEAD, write start SHA = current SHA
# Expected: partial (no HEAD change, but summary.md > 50 chars)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- guardian-partial ---"
{
    proj=$(make_git_project)
    start_sha=$(git -C "$proj" rev-parse HEAD)
    tid=$(setup_fixture "guardian-partial" "$proj" "$start_sha")

    # Write start SHA — same as current HEAD, so no change detected
    echo "$start_sha" > "${CLAUDE_DIR}/.guardian-start-sha"

    # No new commit — HEAD stays the same
    finalize_trace "$tid" "$proj" "guardian" 2>/dev/null
    outcome=$(get_outcome "$tid")
    record_result "guardian-partial" "$outcome"

    if [[ "$outcome" == "partial" ]]; then
        pass "guardian-partial" "partial"
    else
        fail "guardian-partial" "partial" "$outcome"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Fixture: guardian-failure
# State: make git project, start SHA = current HEAD, no commit
# summary.md contains "merge conflict" keyword -> failure
# Expected: failure
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- guardian-failure ---"
{
    proj=$(make_git_project)
    start_sha=$(git -C "$proj" rev-parse HEAD)
    tid=$(setup_fixture "guardian-failure" "$proj" "$start_sha")

    echo "$start_sha" > "${CLAUDE_DIR}/.guardian-start-sha"

    finalize_trace "$tid" "$proj" "guardian" 2>/dev/null
    outcome=$(get_outcome "$tid")
    record_result "guardian-failure" "$outcome"

    if [[ "$outcome" == "failure" ]]; then
        pass "guardian-failure" "failure"
    else
        fail "guardian-failure" "failure" "$outcome"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Fixture: tester-success
# State: simple git project (no SHA needed for tester)
# summary.md contains "AUTOVERIFY: CLEAN" -> success
# Expected: success
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- tester-success ---"
{
    proj=$(make_git_project)
    tid=$(setup_fixture "tester-success" "$proj" "")

    finalize_trace "$tid" "$proj" "tester" 2>/dev/null
    outcome=$(get_outcome "$tid")
    record_result "tester-success" "$outcome"

    if [[ "$outcome" == "success" ]]; then
        pass "tester-success" "success"
    else
        fail "tester-success" "success" "$outcome"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Fixture: tester-partial
# State: simple git project
# summary.md exists but no AUTOVERIFY signal -> partial
# Expected: partial
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- tester-partial ---"
{
    proj=$(make_git_project)
    tid=$(setup_fixture "tester-partial" "$proj" "")

    finalize_trace "$tid" "$proj" "tester" 2>/dev/null
    outcome=$(get_outcome "$tid")
    record_result "tester-partial" "$outcome"

    if [[ "$outcome" == "partial" ]]; then
        pass "tester-partial" "partial"
    else
        fail "tester-partial" "partial" "$outcome"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Fixture: planner-success
# State: git project where MASTER_PLAN.md is touched AFTER trace started_at
#   The fixture started_at is 2026-03-01T20:00:00Z (fixed in the past).
#   We just touch MASTER_PLAN.md now — current mtime > fixture started_at.
# Expected: success
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- planner-success ---"
{
    proj=$(make_git_project)
    tid=$(setup_fixture "planner-success" "$proj" "")

    # Create MASTER_PLAN.md with current mtime (well after 2026-03-01T20:00:00Z)
    echo "# MASTER_PLAN.md" > "$proj/MASTER_PLAN.md"

    finalize_trace "$tid" "$proj" "planner" 2>/dev/null
    outcome=$(get_outcome "$tid")
    record_result "planner-success" "$outcome"

    if [[ "$outcome" == "success" ]]; then
        pass "planner-success" "success"
    else
        fail "planner-success" "success" "$outcome"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Fixture: planner-timeout
# State: git project, NO MASTER_PLAN.md modification
#   The fixture started_at is 2026-03-01T08:00:00Z (many hours ago from now).
#   duration > 600s is guaranteed. summary.md is tiny (< 50 chars).
# Expected: timeout
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- planner-timeout ---"
{
    proj=$(make_git_project)
    tid=$(setup_fixture "planner-timeout" "$proj" "")

    # Do NOT create MASTER_PLAN.md — plan was never written
    finalize_trace "$tid" "$proj" "planner" 2>/dev/null
    outcome=$(get_outcome "$tid")
    record_result "planner-timeout" "$outcome"

    if [[ "$outcome" == "timeout" ]]; then
        pass "planner-timeout" "timeout"
    else
        fail "planner-timeout" "timeout" "$outcome"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Fixture: implementer-success
# State: compliance.json has test_result=pass -> outcome=success
# Expected: success
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- implementer-success ---"
{
    proj=$(make_git_project)
    tid=$(setup_fixture "implementer-success" "$proj" "")

    finalize_trace "$tid" "$proj" "implementer" 2>/dev/null
    outcome=$(get_outcome "$tid")
    record_result "implementer-success" "$outcome"

    if [[ "$outcome" == "success" ]]; then
        pass "implementer-success" "success"
    else
        fail "implementer-success" "success" "$outcome"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Fixture: implementer-failure
# State: compliance.json has test_result=fail -> outcome=failure
# Expected: failure
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- implementer-failure ---"
{
    proj=$(make_git_project)
    tid=$(setup_fixture "implementer-failure" "$proj" "")

    finalize_trace "$tid" "$proj" "implementer" 2>/dev/null
    outcome=$(get_outcome "$tid")
    record_result "implementer-failure" "$outcome"

    if [[ "$outcome" == "failure" ]]; then
        pass "implementer-failure" "failure"
    else
        fail "implementer-failure" "failure" "$outcome"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Fixture: unknown-partial
# State: compliance.json has test_result=not-provided, artifacts/output.txt exists
#   Unknown agent falls into generic classification; not-provided + artifacts -> partial
#   "recent" started_at keeps duration < 600s so timeout branch is not triggered
# Expected: partial
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- unknown-partial ---"
{
    proj=$(make_git_project)
    tid=$(setup_fixture "unknown-partial" "$proj" "" "recent")

    finalize_trace "$tid" "$proj" "unknown" 2>/dev/null
    outcome=$(get_outcome "$tid")
    record_result "unknown-partial" "$outcome"

    if [[ "$outcome" == "partial" ]]; then
        pass "unknown-partial" "partial"
    else
        fail "unknown-partial" "partial" "$outcome"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Fixture: crashed-no-summary
# State: NO summary.md, has artifacts/partial-output.txt
#   finalize_trace detects missing summary.md -> status=crashed, outcome=crashed
# Expected: crashed
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- crashed-no-summary ---"
{
    proj=$(make_git_project)
    tid=$(setup_fixture "crashed-no-summary" "$proj" "")

    finalize_trace "$tid" "$proj" "implementer" 2>/dev/null
    outcome=$(get_outcome "$tid")
    record_result "crashed-no-summary" "$outcome"

    if [[ "$outcome" == "crashed" ]]; then
        pass "crashed-no-summary" "crashed"
    else
        fail "crashed-no-summary" "crashed" "$outcome"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Results and accuracy calculation
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "====================================="
TOTAL=$((PASS + FAIL))
echo "Results: $PASS/$TOTAL correct"
if [[ "$TOTAL" -gt 0 ]]; then
    ACCURACY=$(( PASS * 100 / TOTAL ))
else
    ACCURACY=0
fi
echo "Accuracy: ${ACCURACY}%"
echo "====================================="

# ─────────────────────────────────────────────────────────────────────────────
# Regression detection: compare actual results against baseline
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$UPDATE_BASELINE" == "false" && -f "$BASELINE_FILE" ]]; then
    echo ""
    echo "--- Regression Detection ---"
    REGRESSION_FOUND=false
    # Iterate over actual results file
    while IFS='=' read -r fixture_name actual; do
        [[ -z "$fixture_name" ]] && continue
        # Look up baseline expected value
        expected_from_baseline=$(jq -r --arg k "$fixture_name" '.classifications[$k] // ""' "$BASELINE_FILE" 2>/dev/null)
        if [[ -n "$expected_from_baseline" && "$actual" != "$expected_from_baseline" ]]; then
            echo "REGRESSION [$fixture_name]: baseline=$expected_from_baseline current=$actual"
            REGRESSION_COUNT=$((REGRESSION_COUNT + 1))
            REGRESSION_FOUND=true
        fi
    done < "$ACTUAL_RESULTS_FILE"
    if [[ "$REGRESSION_FOUND" == "false" ]]; then
        RESULT_COUNT=$(wc -l < "$ACTUAL_RESULTS_FILE" | tr -d ' ')
        echo "No regressions detected (all ${RESULT_COUNT} classifications match baseline)"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Baseline update mode: regenerate trace-baseline.json from current results
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$UPDATE_BASELINE" == "true" ]]; then
    echo ""
    echo "--- Updating baseline: $BASELINE_FILE ---"
    # Build classifications JSON using jq from ACTUAL_RESULTS_FILE
    classifications_json=$(
        while IFS='=' read -r k v; do
            [[ -z "$k" ]] && continue
            printf '%s\n' "$k=$v"
        done < "$ACTUAL_RESULTS_FILE" \
        | jq -Rn '[inputs | split("=") | {(.[0]): .[1]}] | add // {}'
    )

    jq -n \
        --arg generated_at "$(date -u +%Y-%m-%d)" \
        --argjson classifications "$classifications_json" \
        '{version: "1", generated_at: $generated_at, classifications: $classifications}' \
        > "$BASELINE_FILE"
    RESULT_COUNT=$(wc -l < "$ACTUAL_RESULTS_FILE" | tr -d ' ')
    echo "Baseline written to $BASELINE_FILE with ${RESULT_COUNT} entries"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Exit with failure if accuracy < 95% or regressions detected
# ─────────────────────────────────────────────────────────────────────────────
EXIT_CODE=0
if [[ "$ACCURACY" -lt 95 ]]; then
    echo "FAIL: accuracy ${ACCURACY}% is below 95% threshold"
    EXIT_CODE=1
fi
if [[ "$REGRESSION_COUNT" -gt 0 ]]; then
    echo "FAIL: $REGRESSION_COUNT regression(s) detected"
    EXIT_CODE=1
fi

exit "$EXIT_CODE"
