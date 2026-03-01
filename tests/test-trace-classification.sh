#!/usr/bin/env bash
# test-trace-classification.sh — Tests for agent-type-aware outcome classification in finalize_trace()
#
# Purpose: Verify that finalize_trace() uses agent-specific signals to determine
#   outcome, rather than relying solely on test_result which is "not-provided"
#   for non-implementer agents.
#
# Test cases:
#   T1: Guardian with HEAD change → success
#   T2: Guardian without HEAD change → partial
#   T3: Guardian with merge conflict in summary → failure
#   T4: Tester with AUTOVERIFY: CLEAN → success
#   T5: Tester with summary but no AUTOVERIFY → partial
#   T6: Planner with MASTER_PLAN.md modified → success
#   T7: Planner timeout (long duration, no summary) → timeout
#   T8: Planner with summary but no plan change → partial
#   T9: Generic fallback (unknown agent) → partial
#   T10: Implementer with test_result=pass → success (unchanged regression)
#   T11: Implementer with test_result=fail → failure (unchanged regression)
#
# @decision DEC-TRACE-CLASS-TEST-001
# @title Test agent-type-aware classification using direct finalize_trace() calls
# @status accepted
# @rationale finalize_trace() is a library function that can be sourced and called
#   directly. Tests create minimal trace fixtures (manifest + artifacts), call
#   finalize_trace(), and verify the resulting manifest.json outcome field.
#   git operations in guardian tests use temp repos with real HEAD commits so
#   SHA comparison works correctly. No mocking of internal functions needed.
#
# Usage: bash tests/test-trace-classification.sh
# Returns: 0 if all tests pass, 1 if any fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_LIB="${WORKTREE_ROOT}/hooks/log.sh"
CONTEXT_LIB="${WORKTREE_ROOT}/hooks/context-lib.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — expected $2, got $3"; FAIL=$((FAIL + 1)); }

# Suppress hook log output during tests (re-enabled at end for PASS/FAIL)
exec 2>/dev/null

# shellcheck source=/dev/null
source "$LOG_LIB"
# shellcheck source=/dev/null
source "$CONTEXT_LIB"

# Override TRACE_STORE and CLAUDE_DIR with temp dirs AFTER sourcing
TRACE_STORE=$(mktemp -d)
CLAUDE_DIR=$(mktemp -d)
export TRACE_STORE CLAUDE_DIR

cleanup_dirs=("$TRACE_STORE" "$CLAUDE_DIR")
trap 'rm -rf "${cleanup_dirs[@]}" 2>/dev/null || true' EXIT

# Re-enable stderr for test output
exec 2>&1

# ─────────────────────────────────────────────────────────────────
# Helper: create a minimal trace directory with manifest.json
# Returns trace_id
# ─────────────────────────────────────────────────────────────────
make_trace() {
    local label="$1"
    local project_root="$2"
    local agent_type="${3:-implementer}"
    local started_at="${4:-$(date -u -v -5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)}"
    local trace_id="${agent_type}-$(date +%Y%m%d)-$(date +%H%M%S)-${label}-$$"
    local trace_dir="${TRACE_STORE}/${trace_id}"
    mkdir -p "${trace_dir}/artifacts"
    cat > "${trace_dir}/manifest.json" << EOF
{
  "trace_id": "${trace_id}",
  "agent_type": "${agent_type}",
  "started_at": "${started_at}",
  "project": "${project_root}",
  "session_id": "test-session-${label}"
}
EOF
    echo "${trace_id}"
}

make_git_project() {
    local d
    d=$(mktemp -d)
    cleanup_dirs+=("$d")
    git -C "$d" init -q
    git -C "$d" config user.email "test@ci.local"
    git -C "$d" config user.name "CI Test"
    echo "initial" > "$d/file.txt"
    git -C "$d" add file.txt
    git -C "$d" commit -q -m "Initial commit"
    echo "$d"
}

get_outcome() {
    local trace_id="$1"
    jq -r '.outcome // "not-set"' "${TRACE_STORE}/${trace_id}/manifest.json" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────
# T1: Guardian with HEAD change → success
# ─────────────────────────────────────────────────────────────────
{
    proj=$(make_git_project)
    tid=$(make_trace "t1-guardian-success" "$proj" "guardian")
    tdir="${TRACE_STORE}/${tid}"

    # Record start SHA, then make a new commit
    start_sha=$(git -C "$proj" rev-parse HEAD)
    echo "$start_sha" > "${CLAUDE_DIR}/.guardian-start-sha"

    echo "commit during test" >> "$proj/file.txt"
    git -C "$proj" add file.txt
    git -C "$proj" commit -q -m "Guardian commit"

    echo "# Guardian completed commit" > "${tdir}/summary.md"
    finalize_trace "$tid" "$proj" "guardian" 2>/dev/null

    outcome=$(get_outcome "$tid")
    if [[ "$outcome" == "success" ]]; then
        pass "T1: guardian HEAD change → success"
    else
        fail "T1: guardian HEAD change → success" "success" "$outcome"
    fi
}

# ─────────────────────────────────────────────────────────────────
# T2: Guardian without HEAD change → partial
# ─────────────────────────────────────────────────────────────────
{
    proj=$(make_git_project)
    tid=$(make_trace "t2-guardian-partial" "$proj" "guardian")
    tdir="${TRACE_STORE}/${tid}"

    # Record start SHA but don't make a new commit
    start_sha=$(git -C "$proj" rev-parse HEAD)
    echo "$start_sha" > "${CLAUDE_DIR}/.guardian-start-sha"

    # Summary must be >50 chars to trigger "partial" (not "skipped") when no HEAD change
    echo "# Guardian ran but made no commit — reviewed staged files and provided advisory" > "${tdir}/summary.md"
    finalize_trace "$tid" "$proj" "guardian" 2>/dev/null

    outcome=$(get_outcome "$tid")
    if [[ "$outcome" == "partial" ]]; then
        pass "T2: guardian no HEAD change → partial"
    else
        fail "T2: guardian no HEAD change → partial" "partial" "$outcome"
    fi
}

# ─────────────────────────────────────────────────────────────────
# T3: Guardian with merge conflict in summary → failure
# ─────────────────────────────────────────────────────────────────
{
    proj=$(make_git_project)
    tid=$(make_trace "t3-guardian-failure" "$proj" "guardian")
    tdir="${TRACE_STORE}/${tid}"

    # Record start SHA but don't advance HEAD
    start_sha=$(git -C "$proj" rev-parse HEAD)
    echo "$start_sha" > "${CLAUDE_DIR}/.guardian-start-sha"

    echo "# Guardian encountered MERGE CONFLICT — merge aborted" > "${tdir}/summary.md"
    finalize_trace "$tid" "$proj" "guardian" 2>/dev/null

    outcome=$(get_outcome "$tid")
    if [[ "$outcome" == "failure" ]]; then
        pass "T3: guardian merge conflict in summary → failure"
    else
        fail "T3: guardian merge conflict in summary → failure" "failure" "$outcome"
    fi
}

# ─────────────────────────────────────────────────────────────────
# T4: Tester with AUTOVERIFY: CLEAN → success
# ─────────────────────────────────────────────────────────────────
{
    proj=$(make_git_project)
    tid=$(make_trace "t4-tester-success" "$proj" "tester")
    tdir="${TRACE_STORE}/${tid}"

    cat > "${tdir}/summary.md" << 'EOF'
# Verification Complete

AUTOVERIFY: CLEAN

## Verification Assessment
Confidence: **High** — all features verified end-to-end.
EOF
    finalize_trace "$tid" "$proj" "tester" 2>/dev/null

    outcome=$(get_outcome "$tid")
    if [[ "$outcome" == "success" ]]; then
        pass "T4: tester AUTOVERIFY: CLEAN → success"
    else
        fail "T4: tester AUTOVERIFY: CLEAN → success" "success" "$outcome"
    fi
}

# ─────────────────────────────────────────────────────────────────
# T5: Tester with summary but no AUTOVERIFY → partial
# ─────────────────────────────────────────────────────────────────
{
    proj=$(make_git_project)
    tid=$(make_trace "t5-tester-partial" "$proj" "tester")
    tdir="${TRACE_STORE}/${tid}"

    cat > "${tdir}/summary.md" << 'EOF'
# Verification Results

Tested the feature manually. Some paths were verified.

## Verification Assessment
Confidence: **Medium** — not all edge cases tested.
EOF
    finalize_trace "$tid" "$proj" "tester" 2>/dev/null

    outcome=$(get_outcome "$tid")
    if [[ "$outcome" == "partial" ]]; then
        pass "T5: tester no AUTOVERIFY → partial"
    else
        fail "T5: tester no AUTOVERIFY → partial" "partial" "$outcome"
    fi
}

# ─────────────────────────────────────────────────────────────────
# T6: Planner with MASTER_PLAN.md modified → success
# ─────────────────────────────────────────────────────────────────
{
    proj=$(make_git_project)
    tid=$(make_trace "t6-planner-success" "$proj" "planner")
    tdir="${TRACE_STORE}/${tid}"

    # Write MASTER_PLAN.md AFTER the trace started_at
    echo "# MASTER_PLAN.md (created during test)" > "$proj/MASTER_PLAN.md"
    echo "# Planning complete" > "${tdir}/summary.md"
    finalize_trace "$tid" "$proj" "planner" 2>/dev/null

    outcome=$(get_outcome "$tid")
    if [[ "$outcome" == "success" ]]; then
        pass "T6: planner MASTER_PLAN.md modified → success"
    else
        fail "T6: planner MASTER_PLAN.md modified → success" "success" "$outcome"
    fi
}

# ─────────────────────────────────────────────────────────────────
# T7: Planner timeout (long duration, minimal summary) → timeout
# ─────────────────────────────────────────────────────────────────
{
    proj=$(make_git_project)
    # Use a started_at that is 700 seconds ago to trigger timeout
    old_start=$(date -u -v -700S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d '700 seconds ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u +%Y-%m-%dT%H:%M:%SZ)
    tid=$(make_trace "t7-planner-timeout" "$proj" "planner" "$old_start")
    tdir="${TRACE_STORE}/${tid}"

    # Write a minimal summary (less than 50 chars) to trigger timeout branch
    echo "Planning..." > "${tdir}/summary.md"
    # Do NOT create MASTER_PLAN.md — plan was never written
    finalize_trace "$tid" "$proj" "planner" 2>/dev/null

    outcome=$(get_outcome "$tid")
    if [[ "$outcome" == "timeout" ]]; then
        pass "T7: planner long duration + tiny summary → timeout"
    else
        fail "T7: planner long duration + tiny summary → timeout" "timeout" "$outcome"
    fi
}

# ─────────────────────────────────────────────────────────────────
# T8: Planner with summary but no plan change → partial
# ─────────────────────────────────────────────────────────────────
{
    proj=$(make_git_project)
    tid=$(make_trace "t8-planner-partial" "$proj" "planner")
    tdir="${TRACE_STORE}/${tid}"

    # Pre-create MASTER_PLAN.md with an old mtime (before trace started)
    echo "# Old plan" > "$proj/MASTER_PLAN.md"
    # Touch it to a time in the past (touch -t YYYYMMDDHHMM)
    touch -t "$(date +%Y%m%d%H%M -d '1 hour ago' 2>/dev/null || date -v -1H +%Y%m%d%H%M)" "$proj/MASTER_PLAN.md" 2>/dev/null || true

    # Write a substantial summary (>50 chars) to indicate planner ran
    cat > "${tdir}/summary.md" << 'EOF'
# Planning session summary

The planner reviewed the codebase and drafted an approach, but did not write MASTER_PLAN.md.
EOF
    finalize_trace "$tid" "$proj" "planner" 2>/dev/null

    outcome=$(get_outcome "$tid")
    if [[ "$outcome" == "partial" ]]; then
        pass "T8: planner summary present but no plan change → partial"
    else
        fail "T8: planner summary present but no plan change → partial" "partial" "$outcome"
    fi
}

# ─────────────────────────────────────────────────────────────────
# T9: Unknown agent type (generic fallback) with artifacts → partial
# ─────────────────────────────────────────────────────────────────
{
    proj=$(make_git_project)
    tid=$(make_trace "t9-unknown-partial" "$proj" "unknown")
    tdir="${TRACE_STORE}/${tid}"

    echo "# Some output" > "${tdir}/summary.md"
    # Write an artifact so artifacts/ is non-empty (empty artifacts/ → skipped, not partial)
    echo "some artifact content" > "${tdir}/artifacts/output.txt"
    # compliance.json with test_result=not-provided (typical for unknown agents)
    cat > "${tdir}/compliance.json" << 'CEOF'
{
  "agent_type": "unknown",
  "test_result": "not-provided",
  "issues_count": 0
}
CEOF
    finalize_trace "$tid" "$proj" "unknown" 2>/dev/null

    outcome=$(get_outcome "$tid")
    if [[ "$outcome" == "partial" ]]; then
        pass "T9: unknown agent with artifacts → partial (generic fallback)"
    else
        fail "T9: unknown agent with artifacts → partial (generic fallback)" "partial" "$outcome"
    fi
}

# ─────────────────────────────────────────────────────────────────
# T10: Implementer with test_result=pass → success (regression guard)
# ─────────────────────────────────────────────────────────────────
{
    proj=$(make_git_project)
    tid=$(make_trace "t10-impl-success" "$proj" "implementer")
    tdir="${TRACE_STORE}/${tid}"

    echo "# Implementer completed" > "${tdir}/summary.md"
    cat > "${tdir}/compliance.json" << 'CEOF'
{
  "agent_type": "implementer",
  "test_result": "pass",
  "artifacts": {"files-changed.txt": {"present": true, "source": "agent"}},
  "issues_count": 0
}
CEOF
    finalize_trace "$tid" "$proj" "implementer" 2>/dev/null

    outcome=$(get_outcome "$tid")
    if [[ "$outcome" == "success" ]]; then
        pass "T10: implementer test_result=pass → success (regression)"
    else
        fail "T10: implementer test_result=pass → success (regression)" "success" "$outcome"
    fi
}

# ─────────────────────────────────────────────────────────────────
# T11: Implementer with test_result=fail → failure (regression guard)
# ─────────────────────────────────────────────────────────────────
{
    proj=$(make_git_project)
    tid=$(make_trace "t11-impl-failure" "$proj" "implementer")
    tdir="${TRACE_STORE}/${tid}"

    echo "# Tests failed" > "${tdir}/summary.md"
    cat > "${tdir}/compliance.json" << 'CEOF'
{
  "agent_type": "implementer",
  "test_result": "fail",
  "artifacts": {},
  "issues_count": 1
}
CEOF
    finalize_trace "$tid" "$proj" "implementer" 2>/dev/null

    outcome=$(get_outcome "$tid")
    if [[ "$outcome" == "failure" ]]; then
        pass "T11: implementer test_result=fail → failure (regression)"
    else
        fail "T11: implementer test_result=fail → failure (regression)" "failure" "$outcome"
    fi
}

# ─────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Trace Classification Tests ==="
echo "PASS: $PASS / $((PASS + FAIL))"

if [[ $FAIL -gt 0 ]]; then
    echo "FAIL: $FAIL test(s) failed"
    exit 1
fi
exit 0
