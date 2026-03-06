#!/usr/bin/env bash
# clean-state.sh — Session-scoped state file audit and cleanup tool.
#
# Purpose: Enumerates all dot-files in ~/.claude/ that are session-scoped or
# project-scoped (proof-status, test-status, guardian-start-sha,
# last-tester-trace, agent-findings, etc.), identifies orphaned files
# (proof-status files for inactive projects), and provides --dry-run
# (default) and --clean modes.
#
# Usage:
#   clean-state.sh [--dry-run]  (default) — report what would be cleaned
#   clean-state.sh --clean      — actually remove orphaned files
#
# Categories of files managed:
#   proof-status-*      — project-scoped .proof-status-{phash} files
#   test-status         — .test-status (global, not scoped by project)
#   guardian-start-sha  — .guardian-start-sha-{phash}
#   last-tester-trace   — .last-tester-trace-{phash}
#   agent-findings      — .agent-findings (ages out after 3 days)
#   plan-drift          — .plan-drift (not orphanable, but tracked)
#   doc-drift           — .doc-drift (not orphanable, but tracked)
#   audit-log           — .audit-log (persistent, never removed)
#   cwd-recovery-needed — .cwd-recovery-needed (safe to clean when no active session)
#   worktree-roster     — .worktree-roster.tsv (not cleaned — informational only)
#
# A state file is "orphaned" if:
#   - It has a project hash suffix AND no git repo with that hash exists in common dirs
#   - It is older than the configured staleness threshold
#
# @decision DEC-STATE-AUDIT-001
# @title State file audit script with dry-run/clean modes
# @status accepted
# @rationale Session-scoped state files accumulate over time: proof-status files
#   for old projects and orphaned test-status from abandoned sessions. Without a
#   cleanup tool these files cause subtle cross-session contamination (stale
#   "verified" triggering dedup guards). Breadcrumb files (.active-worktree-path*)
#   were removed in DEC-PROOF-BREADCRUMB-001 — this script no longer tracks them.
#   A dedicated audit script with --dry-run default makes cleanup safe and visible.

set -euo pipefail

# _file_mtime FILE — cross-platform mtime (Linux-first; mirrors core-lib.sh)
# Defined locally because clean-state.sh is standalone (no source-lib.sh).
_file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
DRY_RUN=true

# Counters
FOUND_ORPHANED=0
FOUND_STALE=0
CLEANED=0
REPORTED=0

# Colors (only when stdout is a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    GREEN='\033[0;32m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' YELLOW='' GREEN='' CYAN='' BOLD='' NC=''
fi

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=true
            ;;
        --clean)
            DRY_RUN=false
            ;;
        --help|-h)
            cat <<EOF
Usage: clean-state.sh [--dry-run|--clean]

  --dry-run  (default) Report orphaned/stale state files without removing them.
  --clean    Actually remove identified orphaned and stale state files.

Files audited (in $CLAUDE_DIR/):
  .proof-status-{phash}            Project-scoped proof status
  .active-worktree-path-{phash}    Scoped breadcrumbs for worktrees
  .active-worktree-path            Legacy breadcrumb
  .test-status                     Global test result
  .guardian-start-sha-{phash}      Guardian commit baseline
  .last-tester-trace-{phash}       Last tester trace ID
  .agent-findings                  Agent issue log (ages out after 3 days)
  .cwd-recovery-needed             CWD recovery canary

Files NEVER removed (persistent cross-session state):
  .audit-log                       Persistent audit trail
  .plan-drift                      Decision drift data
  .doc-drift                       Documentation drift data
  .worktree-roster.tsv             Worktree registry
  .lint-breaker                    Lint circuit breaker
EOF
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg (use --dry-run or --clean)" >&2
            exit 1
            ;;
    esac
done

MODE="${DRY_RUN:+dry-run}"
MODE="${MODE:-clean}"

echo ""
echo "${BOLD}State File Audit — ${CLAUDE_DIR}${NC}"
echo "Mode: ${MODE}"
date '+%Y-%m-%d %H:%M:%S'
echo ""

# Helper: report a file
report_file() {
    local file="$1"
    local reason="$2"
    local category="$3"

    REPORTED=$((REPORTED + 1))
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  ${YELLOW}[would clean]${NC} $(basename "$file")"
        echo "    Category: $category"
        echo "    Reason:   $reason"
    else
        echo "  ${RED}[removed]${NC} $(basename "$file")"
        echo "    Category: $category"
        echo "    Reason:   $reason"
        rm -f "$file"
        CLEANED=$((CLEANED + 1))
    fi
    echo ""
}

# Helper: report a file as stale (informational, not removed unless --clean)
report_stale_file() {
    local file="$1"
    local reason="$2"
    local category="$3"

    FOUND_STALE=$((FOUND_STALE + 1))
    echo "  ${CYAN}[stale]${NC} $(basename "$file")"
    echo "    Category: $category"
    echo "    Reason:   $reason"
    echo ""
}

# Check active git worktrees
get_active_worktree_paths() {
    git worktree list --porcelain 2>/dev/null | grep '^worktree ' | sed 's/^worktree //' || echo ""
}

ACTIVE_WORKTREES=$(get_active_worktree_paths)

# ─────────────────────────────────────────────────────────────────────────────
# 1. Proof-status files (.proof-status-{phash})
# ─────────────────────────────────────────────────────────────────────────────

echo "${BOLD}1. Proof-status files (.proof-status*)${NC}"
FOUND_PROOF=0

for proof_file in "$CLAUDE_DIR"/.proof-status*; do
    [[ -f "$proof_file" ]] || continue
    FOUND_PROOF=$((FOUND_PROOF + 1))

    status=$(cut -d'|' -f1 "$proof_file" 2>/dev/null || echo "unknown")
    timestamp=$(cut -d'|' -f2 "$proof_file" 2>/dev/null || echo "0")
    now=$(date +%s)
    age=$((now - ${timestamp:-0}))
    age_h=$((age / 3600))
    age_d=$((age / 86400))

    # Age-based staleness: proof-status files older than 7 days are likely stale
    if [[ "${timestamp:-0}" -gt 0 && "$age_d" -gt 7 ]]; then
        report_stale_file "$proof_file" "Status='$status', age=${age_d}d (>7 days — likely stale)" "proof-status"
    else
        age_str="${age_h}h"
        [[ "$age_d" -gt 0 ]] && age_str="${age_d}d"
        echo "  ${GREEN}[valid]${NC} $(basename "$proof_file"): status=$status, age=$age_str"
        echo ""
    fi
done

[[ "$FOUND_PROOF" -eq 0 ]] && echo "  No proof-status files found." && echo ""

# ─────────────────────────────────────────────────────────────────────────────
# 2. Test-status file (.test-status)
# ─────────────────────────────────────────────────────────────────────────────

echo "${BOLD}2. Test status (.test-status)${NC}"
TEST_STATUS_FILE="$CLAUDE_DIR/.test-status"
if [[ -f "$TEST_STATUS_FILE" ]]; then
    ts_status=$(cut -d'|' -f1 "$TEST_STATUS_FILE" 2>/dev/null || echo "unknown")
    ts_timestamp=$(cut -d'|' -f2 "$TEST_STATUS_FILE" 2>/dev/null || echo "0")
    ts_now=$(date +%s)
    ts_age=$((ts_now - ${ts_timestamp:-0}))
    ts_age_h=$((ts_age / 3600))
    # Test status older than 24h is likely stale (session-init should have cleared it)
    if [[ "${ts_timestamp:-0}" -gt 0 && "$ts_age" -gt 86400 ]]; then
        report_stale_file "$TEST_STATUS_FILE" "Status='$ts_status', age=${ts_age_h}h (>24h — session-init should have cleared this)" "test-status"
    else
        echo "  ${GREEN}[valid]${NC} .test-status: status=$ts_status, age=${ts_age_h}h"
        echo ""
    fi
else
    echo "  No .test-status file found."
    echo ""
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. Guardian start SHA files (.guardian-start-sha-{phash})
# ─────────────────────────────────────────────────────────────────────────────

echo "${BOLD}3. Guardian start SHA files (.guardian-start-sha*)${NC}"
FOUND_GUARDIAN=0

for sha_file in "$CLAUDE_DIR"/.guardian-start-sha*; do
    [[ -f "$sha_file" ]] || continue
    FOUND_GUARDIAN=$((FOUND_GUARDIAN + 1))
    sha_val=$(cat "$sha_file" 2>/dev/null | tr -d '[:space:]' | head -c 12)
    mtime=$(_file_mtime "$sha_file")
    now=$(date +%s)
    age_h=$(( (now - mtime) / 3600 ))
    age_d=$(( (now - mtime) / 86400 ))
    if [[ "$age_d" -gt 7 ]]; then
        report_stale_file "$sha_file" "SHA=${sha_val:-unknown}, age=${age_d}d (>7 days)" "guardian-sha"
    else
        echo "  ${GREEN}[valid]${NC} $(basename "$sha_file"): sha=${sha_val:-unknown}, age=${age_h}h"
        echo ""
    fi
done

[[ "$FOUND_GUARDIAN" -eq 0 ]] && echo "  No guardian-start-sha files found." && echo ""

# ─────────────────────────────────────────────────────────────────────────────
# 4. Last tester trace files (.last-tester-trace-{phash})
# ─────────────────────────────────────────────────────────────────────────────

echo "${BOLD}4. Last tester trace files (.last-tester-trace*)${NC}"
FOUND_TESTER=0

for trace_file in "$CLAUDE_DIR"/.last-tester-trace*; do
    [[ -f "$trace_file" ]] || continue
    FOUND_TESTER=$((FOUND_TESTER + 1))
    trace_val=$(cat "$trace_file" 2>/dev/null | tr -d '[:space:]')
    mtime=$(_file_mtime "$trace_file")
    now=$(date +%s)
    age_d=$(( (now - mtime) / 86400 ))
    echo "  ${CYAN}[info]${NC} $(basename "$trace_file"): trace=${trace_val:-unknown}, age=${age_d}d"
    echo ""
done

[[ "$FOUND_TESTER" -eq 0 ]] && echo "  No last-tester-trace files found." && echo ""

# ─────────────────────────────────────────────────────────────────────────────
# 5. Agent findings file (.agent-findings)
# ─────────────────────────────────────────────────────────────────────────────

echo "${BOLD}5. Agent findings (.agent-findings)${NC}"
AGENT_FINDINGS="$CLAUDE_DIR/.agent-findings"
if [[ -f "$AGENT_FINDINGS" ]]; then
    mtime=$(_file_mtime "$AGENT_FINDINGS")
    now=$(date +%s)
    age=$((now - mtime))
    age_d=$((age / 86400))
    line_count=$(wc -l < "$AGENT_FINDINGS" 2>/dev/null | tr -d ' ')
    if [[ "$age_d" -gt 3 ]]; then
        report_stale_file "$AGENT_FINDINGS" "${line_count} line(s), age=${age_d}d (>3 days — session-end ages these out)" "agent-findings"
    else
        echo "  ${GREEN}[valid]${NC} .agent-findings: ${line_count} line(s), age=${age_d}d"
        echo ""
    fi
else
    echo "  No .agent-findings file found."
    echo ""
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. CWD recovery canary (.cwd-recovery-needed)
# ─────────────────────────────────────────────────────────────────────────────

echo "${BOLD}6. CWD recovery canary (.cwd-recovery-needed)${NC}"
CWD_CANARY="$CLAUDE_DIR/.cwd-recovery-needed"
if [[ -f "$CWD_CANARY" ]]; then
    canary_target=$(cat "$CWD_CANARY" 2>/dev/null | tr -d '[:space:]')
    mtime=$(_file_mtime "$CWD_CANARY")
    now=$(date +%s)
    age_h=$(( (now - mtime) / 3600 ))
    if [[ "$age_h" -gt 2 ]]; then
        report_file "$CWD_CANARY" "Stale recovery canary (target: ${canary_target:-empty}, age=${age_h}h > 2h)" "cwd-recovery"
        FOUND_ORPHANED=$((FOUND_ORPHANED + 1))
    else
        echo "  ${YELLOW}[active]${NC} .cwd-recovery-needed → ${canary_target:-empty}, age=${age_h}h"
        echo ""
    fi
else
    echo "  No .cwd-recovery-needed file found."
    echo ""
fi

# ─────────────────────────────────────────────────────────────────────────────
# 7. Summary
# ─────────────────────────────────────────────────────────────────────────────

echo "─────────────────────────────────────────────"
echo "${BOLD}Summary${NC}"
echo "  Orphaned (invalid targets or empty):  $FOUND_ORPHANED"
echo "  Stale (old but valid targets):        $FOUND_STALE"
if [[ "$DRY_RUN" == "true" ]]; then
    echo "  Would clean:                          $REPORTED"
    echo ""
    if [[ "$REPORTED" -gt 0 || "$FOUND_STALE" -gt 0 ]]; then
        echo "  Re-run with --clean to remove orphaned files."
    else
        echo "  ${GREEN}No orphaned files found. State is clean.${NC}"
    fi
else
    echo "  Cleaned:                              $CLEANED"
    echo ""
    if [[ "$CLEANED" -gt 0 ]]; then
        echo "  ${GREEN}Cleanup complete: $CLEANED file(s) removed.${NC}"
    else
        echo "  ${GREEN}Nothing to clean.${NC}"
    fi
fi
echo ""
