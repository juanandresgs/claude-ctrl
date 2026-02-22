#!/usr/bin/env bash
# State file registry — declares every state file hooks write.
#
# Purpose: Single source of truth for all persistent state files produced by
# the hooks system. Used by tests/test-state-registry.sh to lint hook source
# files and detect unregistered writes.
#
# Scope definitions:
#   global        — single shared file, not scoped by project or session
#   global-scripts — written by scripts/ (not hooks/), shared across projects
#   per-project   — one file per project (keyed by project hash or CLAUDE_DIR)
#   per-project-legacy — legacy unscoped variant kept for backward compat
#   per-session   — one file per session+project combination
#   per-session-legacy — legacy unscoped session-scoped variant
#   trace-global  — inside TRACE_STORE, shared across all projects
#   trace-scoped  — inside a specific trace directory
#
# Format: PATTERN|SCOPE|WRITER(S)|DESCRIPTION
#
# PATTERN uses {phash} for project hash, {session} for session ID, {type}
# for agent type. These are template placeholders, not regex.
#
# @decision DEC-STATE-REG-001
# @title Centralized state file registry as single source of truth
# @status accepted
# @rationale Without a registry, state files proliferate silently — new hooks
#   add writes without updating any central record, cross-project contamination
#   goes undetected, and cleanup logic becomes incomplete. A registry makes
#   every write explicit and lint-testable. The lint test (test-state-registry.sh)
#   greps hook source for write patterns and verifies each target appears here.
#   Unregistered writes fail CI. This pattern mirrors what linters do for
#   imports/exports in typed languages — explicit is better than implicit.

# shellcheck disable=SC2034  # Array used by sourcing scripts

STATE_REGISTRY=(
    # --- Proof-of-work gate ---
    ".proof-status-{phash}|per-project|task-track.sh,prompt-submit.sh,check-tester.sh|Proof-of-work gate status (scoped by project hash)"
    ".proof-status|per-project-legacy|prompt-submit.sh,check-tester.sh|Legacy unscoped proof status (backward compat dual-write)"

    # --- Worktree breadcrumbs ---
    ".active-worktree-path-{phash}|per-project|task-track.sh|Breadcrumb to active worktree path (scoped by project hash)"
    ".active-worktree-path|per-project-legacy|check-guardian.sh|Legacy unscoped worktree breadcrumb (read+delete only in check-guardian)"

    # --- Trace active markers ---
    ".active-{type}-{session}-{phash}|per-session|context-lib.sh|Scoped trace active marker (init_trace)"
    ".active-{type}-{session}|per-session-legacy|context-lib.sh|Legacy trace active marker (backward compat)"

    # --- Test status ---
    ".test-status|per-project|test-runner.sh|Test result status: pass|fail|count|epoch"

    # --- Doc / plan drift ---
    ".doc-drift|global|surface.sh|Documentation freshness drift cache (stale_count, bypass_count)"
    ".plan-drift|global|surface.sh|Plan drift detection cache (unplanned/unimplemented counts)"

    # --- Guardian commit detection ---
    ".guardian-start-sha|per-session|subagent-start.sh|HEAD SHA saved before guardian run for commit detection"

    # --- Trace index ---
    "traces/index.jsonl|trace-global|context-lib.sh|Global trace index (JSONL, one entry per finalized trace)"

    # --- Session-scoped files (cleaned at session end) ---
    ".session-events.jsonl|per-session|context-lib.sh,session-init.sh|Session event log (write/checkpoint/agent events)"
    ".session-changes-{session}|per-session|track.sh,checkpoint.sh|Files changed this session (for drift tracking)"
    ".subagent-tracker-{session}|per-session|context-lib.sh|Subagent lifecycle tracker (ACTIVE/DONE records)"
    ".prompt-count-{session}|per-session|prompt-submit.sh|Prompt counter for compaction heuristic"
    ".session-start-epoch|per-session|prompt-submit.sh|Session start epoch for duration tracking"

    # --- Gate strike counters (session-scoped) ---
    ".test-gate-strikes|per-session|test-gate.sh|Consecutive test-gate violation counter"
    ".mock-gate-strikes|per-session|mock-gate.sh|Consecutive mock-gate violation counter"
    ".test-gate-cold-warned|per-session|test-gate.sh|Cold-start warning flag for test gate"

    # --- Checkpoint counter ---
    ".checkpoint-counter|per-project|checkpoint.sh|Write counter for threshold-based checkpoint creation"

    # --- Statusline cache ---
    ".statusline-cache|per-project|context-lib.sh|Status bar data cache (git/plan/test/agent state)"

    # --- Agent findings ---
    ".agent-findings|per-project|check-guardian.sh,check-tester.sh|Unresolved agent findings for next-prompt injection"

    # --- Audit log ---
    ".audit-log|per-project|context-lib.sh|Persistent audit trail (epoch|event|detail)"

    # --- CWD recovery ---
    ".cwd-recovery-needed|global|check-guardian.sh|CWD recovery canary written after worktree deletion"

    # --- Update status (scripts/) ---
    ".update-status|global-scripts|scripts/update-check.sh|Background update check result (status|local|remote|count|ts|summary)"

    # --- Plan archive breadcrumb ---
    ".last-plan-archived|per-project|context-lib.sh|Breadcrumb after plan archive (archived=name, epoch=ts)"

    # --- Session index (per-project archive) ---
    "sessions/{phash}/index.jsonl|per-project|session-end.sh|Per-project session index for cross-session learning"
    "sessions/{phash}/{session}.jsonl|per-session|session-end.sh|Archived session event log"

    # --- Trace canary ---
    "traces/.trace-count-canary|trace-global|context-lib.sh|Trace count canary for drop detection between sessions"

    # --- Doc freshness cache (context-lib internal) ---
    ".doc-freshness-cache|per-project|context-lib.sh|Doc freshness computation cache (invalidated on .md writes)"

    # --- Plan churn cache (context-lib internal) ---
    ".plan-churn-cache|per-project|context-lib.sh|Plan churn percentage cache (git log -based)"

    # --- Test runner artifacts (session-scoped) ---
    ".test-runner.out|per-session|test-runner.sh|Async test runner stdout/stderr capture"
    ".test-runner-last-run|per-project|test-runner.sh|Epoch of last test run (for debounce)"
    ".test-runner-lock|per-session|test-runner.sh|Lock file preventing concurrent test runs"
)
