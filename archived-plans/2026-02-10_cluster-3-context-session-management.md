# MASTER_PLAN: Cluster 3 — Context & Session Management

## Original Intent
The user wants to address Cluster 3 issues: P#27 (compaction sometimes fails to occur) and P#26 (context window info on status bar). Investigation revealed Claude Code doesn't expose token counts to hooks. The user approved a two-part approach: enrich the status bar with data hooks already compute, and add compaction heuristics based on prompt count and session duration.

## Context
Both issues stem from limited visibility into context state. We can't access token counts, but hooks already compute git state, plan status, and test results. A JSON cache file bridges hooks to the status bar. Compaction heuristics use prompt count and session duration as proxy signals for context pressure.

## Phase 1: Cache Infrastructure
**Status:** completed

Add `write_statusline_cache()` to `context-lib.sh`. Hooks that already call `get_git_state()` and `get_plan_status()` will write a JSON cache file (`.claude/.statusline-cache`) as a side effect.

**Files:**
- `hooks/context-lib.sh` — add `write_statusline_cache()` function
- `hooks/session-init.sh` — add cache write after existing `get_git_state` + `get_plan_status`
- `hooks/prompt-submit.sh` — add cache write in first-prompt block

**Cache format:** `{dirty, worktrees, plan, test, updated, agents_active, agents_types, agents_total}` (JSON, atomic write via tmp+mv)

### Decision Log
- DEC-CACHE-001: Single JSON cache file with atomic writes via tmp+mv. Chosen over multiple text files for atomicity and single jq call in reader.
- DEC-SUBAGENT-001: Subagent lifecycle tracking via line-based state file (.subagent-tracker). FIFO matching for start/stop events. Added as bonus scope beyond original plan.

## Phase 2: Status Bar Enrichment
**Status:** completed

Read cache in `statusline.sh`, add 5 new segments: git dirty (red), worktree count (cyan), plan phase (blue), test status (green/red), active subagents (yellow). Fallback: if cache missing, show defaults gracefully.

**Files:**
- `scripts/statusline.sh` — read `.statusline-cache`, add segments

**Target format:** `opus | project | 14:35:22 | 8 dirty | WT:2 | Phase 2/4 | pass | 2 agents (impl,plan) | 3 todos | v1.2.3`

### Decision Log
- DEC-CACHE-002: Status bar enrichment reads cached hook data. Piggyback on existing hooks rather than new dedicated cache hook. Five conditional segments shown only when relevant.

## Phase 3: Compaction Heuristics
**Status:** completed

Upgrade prompt counter from flag to incrementing integer. Track session start epoch. Suggest `/compact` at prompt 35/60 or at 45/90 min marks via `additionalContext`.

**Files:**
- `hooks/prompt-submit.sh` — increment counter, add epoch tracking, add threshold detection
- `hooks/session-init.sh` — clean up epoch file on session reset

### Decision Log
- DEC-COMPACT-001: Smart compaction suggestions based on prompt count (primary) and session duration (secondary). Exact threshold matches (35, 60 prompts; 45, 90 minutes) prevent repeat suggestions.
- DEC-COMPACT-002: Dual signal approach — prompt count is more reliable, session duration catches long sessions with fewer prompts.
- DEC-COMPACT-003: Narrow time windows (2-minute range) prevent spam across multiple prompts at the same threshold.

## Testing
- Add statusline cache tests to `tests/run-hooks.sh`
- Add prompt counter threshold tests
- Test fixtures for statusline stdin and cache data

## Worktree
- Branch: `cluster3-context-session`
- Single PR for all 3 phases

## Decision Log
- DEC-CACHE-001: Single JSON cache file over multiple text files (atomic writes, one jq call)
- DEC-CACHE-002: Piggyback on existing hooks rather than new dedicated cache hook
- DEC-COMPACT-001: Reuse existing prompt-count file with incrementing integer
- DEC-COMPACT-002: Dual signal — prompt count + session duration
- DEC-COMPACT-003: Exact threshold matches (35, 60) to avoid repeat suggestions
