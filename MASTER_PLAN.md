# MASTER_PLAN: claude-config-pro

## Identity

**Type:** meta-infrastructure
**Languages:** Bash (85%), Markdown (10%), Python (3%), JSON (2%)
**Root:** /Users/turla/.claude
**Created:** 2026-03-01
**Last updated:** 2026-03-06 (Cross-Platform Reliability initiative added)

The Claude Code configuration directory. It shapes how Claude Code operates across all projects via hooks, agents, skills, and instructions. Managed as a git repository (juanandresgs/claude-config-pro). The hook system enforces governance (git safety, documentation, proof gates, worktree discipline) while the agent system dispatches specialized roles (planner, implementer, tester, guardian) for all project work.

## Architecture

    agents/        — Agent instruction files (planner, implementer, tester, guardian)
    hooks/         — Hook entry points (4) + domain libraries (6) — the governance engine
    hooks/*-lib.sh — Domain libraries: core, trace, plan, doc, session, source, git, ci
    scripts/       — Utility scripts (batch-fetch, ci-watch, worktree-roster, statusline)
    skills/        — Research and workflow skills (deep-research, observatory, decide, prd)
    commands/      — Lightweight slash commands (compact, backlog, todos)
    tests/         — Test suite (159 tests via run-hooks.sh + specialized test files)
    templates/     — Document templates for plans and initiatives
    observatory/   — Self-improving flywheel: trace analysis, signal surfacing

## Original Intent

> Build a configuration layer for Claude Code that enforces engineering discipline — git safety, documentation, proof-before-commit, worktree isolation — across all projects. The system should be self-governing: hooks enforce rules mechanically, agents handle specialized roles, and the observatory learns from traces to improve over time.

## Principles

1. **Mechanical Enforcement** — Rules are enforced by hooks, not by convention. If a behavior matters, a hook gates it.
2. **Main is Sacred** — Feature work happens in worktrees. Main only receives tested, reviewed, approved merges.
3. **Proof Before Commit** — Every implementation must be verified by the tester agent before Guardian can commit. The proof chain is: implement -> test -> verify -> commit.
4. **Ephemeral Agents, Persistent Plans** — Agents are disposable; MASTER_PLAN.md and traces persist. Every agent must leave enough context for the next one to succeed.
5. **Fail Loudly** — Silent failures are the enemy. Hooks deny rather than silently allow. Tests assert rather than skip. Traces classify rather than ignore.

---

## Decision Log

| Date | DEC-ID | Initiative | Decision | Rationale |
|------|--------|-----------|----------|-----------|
| 2026-03-01 | DEC-HOOKS-001 | metanoia-remediation | Fix shellcheck violations inline (not suppress) | Real fixes are safer than disable annotations; violations indicate real fragility |
| 2026-03-01 | DEC-TRACE-002 | metanoia-remediation | Agent-type-aware outcome classification via lookup table | Different agents have different success signals; lookup table is extensible |
| 2026-03-01 | DEC-TRACE-003 | metanoia-remediation | Write compliance.json at trace init, update at finalize | Prevents write-before-read race when agents crash early |
| 2026-03-01 | DEC-PLAN-004 | metanoia-remediation | Reduce planner.md by extracting templates | 641 lines / 31KB consumes excessive context; target ~400 lines / ~20KB |
| 2026-03-01 | DEC-STATE-005 | metanoia-remediation | Registry-based state file cleanup | Orphaned state files accumulate; registry + cleanup script prevents drift |
| 2026-03-01 | DEC-TEST-006 | metanoia-remediation | Validation harness follows existing run-hooks.sh pattern | Consistency with 131-test suite; no new framework needed |
| 2026-03-02 | DEC-AUDIT-001 | hook-consolidation | Map hook-to-library dependencies via static analysis | Static grep is faster and more reliable than runtime tracing for bash |
| 2026-03-02 | DEC-TIMING-001 | hook-consolidation | Parse .hook-timing.log with awk for timing reports | Tab-separated fields, awk is universal, no new dependencies |
| 2026-03-02 | DEC-DEDUP-001 | hook-consolidation | Tighten hooks to exact-minimum require set | Duplicate requires indicate code rot; exact-minimum aids auditing |
| 2026-03-01 | DEC-STATE-007 | state-mgmt-reliability | Replace inline proof resolution with resolve_proof_file() | Canonical resolver handles worktree breadcrumbs correctly; inline copies diverge |
| 2026-03-01 | DEC-STATE-008 | state-mgmt-reliability | Pervasive validate_state_file before cut | Prevents crashes on corrupt/empty/truncated state files |
| 2026-03-02 | DEC-STATE-001 | state-mgmt-reliability | Centralized state coordination via state-lib.sh | Single library for proof lifecycle avoids scattered inline logic |
| 2026-03-02 | DEC-STATE-GOV-001 | state-mgmt-reliability | State governance tests in run-hooks.sh | Integration tests validate hook-level proof behavior end-to-end |
| 2026-03-02 | DEC-STATE-LIFECYCLE-001 | state-mgmt-reliability | Lifecycle E2E tests cover full proof-status state machine | Validates transitions: needs-verification -> verified -> committed with worktree isolation |
| 2026-03-02 | DEC-STATE-CORRUPT-001 | state-mgmt-reliability | Corruption tests exercise validate_state_file edge cases | Ensures empty, truncated, malformed, binary proof files are caught before cut |
| 2026-03-02 | DEC-STATE-CONCURRENT-001 | state-mgmt-reliability | Concurrency tests for simultaneous proof writes | Validates atomicity of write_proof_status under contention |
| 2026-03-02 | DEC-STATE-CLEAN-E2E-001 | state-mgmt-reliability | E2E tests for clean-state.sh audit and cleanup | clean-state.sh is the only recovery path for accumulated stale state |
| 2026-03-02 | DEC-STATE-SESSION-BOUNDARY-001 | state-mgmt-reliability | Session boundary proof cleanup tests | session-init.sh cleanup prevents cross-session contamination |
| 2026-03-02 | DEC-STATE-AUDIT-001 | state-mgmt-reliability | clean-state.sh audit script for state file hygiene | Registry-based detection of orphaned, stale, and corrupt state files |
| 2026-03-02 | DEC-SL-LAYOUT-001 | statusline-ia | Keep 2-line layout with domain clustering | Width analysis shows all segments fit in 2 lines; 3 lines would be more visually intrusive |
| 2026-03-02 | DEC-SL-TOKENS-001 | statusline-ia | Display aggregate tokens as compact K notation | Raw token counts unreadable; K notation is universally understood and fits ~10 chars |
| 2026-03-02 | DEC-SL-TODOCACHE-001 | statusline-ia | Add todo_project and todo_global to .statusline-cache | Existing cache is the natural home; avoids file proliferation |
| 2026-03-02 | DEC-SL-COSTPERSIST-001 | statusline-ia | Append session cost to .session-cost-history | Cross-session data needs persistent file; proven pattern from .compaction-log |
| 2026-03-02 | DEC-COST-PERSIST-001 | statusline-ia | Capture session-end stdin for multi-field extraction | Session-end JSON is small; variable capture enables both reason and cost reads |
| 2026-03-02 | DEC-COST-PERSIST-002 | statusline-ia | Pipe-delimited history file for session cost | Append-only, awk-summable, human-readable; trimmed to 100 entries |
| 2026-03-02 | DEC-TODO-SPLIT-001 | statusline-ia | Compute project/global todo counts via gh issue list | Split lets users distinguish project-scoped vs global backlog |
| 2026-03-02 | DEC-LIFETIME-COST-001 | statusline-ia | Sum lifetime cost from history at session start | O(N) over ~100 lines; inexpensive for running lifetime spend |
| 2026-03-02 | DEC-CACHE-003 | statusline-ia | Add todo_project, todo_global, lifetime_cost to cache | Three new fields default to 0; cache always valid JSON |
| 2026-03-02 | DEC-TODO-SPLIT-002 | statusline-ia | -1 sentinel for absent cache fields (backward compat) | Old caches lack split fields; sentinel enables legacy fallback |
| 2026-03-02 | DEC-TODO-SPLIT-003 | statusline-ia | Split display format with p/g suffixes and legacy fallback | todos: 3p 7g when both; project-only or global-only when one is 0 |
| 2026-03-02 | DEC-LIFETIME-COST-002 | statusline-ia | Display lifetime cost as Sigma annotation next to session cost | Compact, contextual; dim rendering avoids visual noise |
| 2026-03-02 | DEC-RSM-REGISTRY-001 | robust-state-mgmt | Protected state file registry in core-lib.sh | Centralized, extensible, <1ms overhead; pre-write.sh Gate 0 checks registry |
| 2026-03-02 | DEC-RSM-FLOCK-001 | robust-state-mgmt | POSIX advisory locks via flock() for concurrent writes | Sub-ms overhead, auto-release on death, crash-safe subshell pattern |
| 2026-03-02 | DEC-RSM-LATTICE-001 | robust-state-mgmt | Monotonic lattice enforcement on proof-status | Proof-status is a semilattice; enforcing monotonicity eliminates regression bugs |
| 2026-03-02 | DEC-RSM-SQLITE-001 | robust-state-mgmt | SQLite WAL replaces state.json | Zero new deps on macOS; atomic CAS via BEGIN IMMEDIATE; eliminates jq race |
| 2026-03-02 | DEC-RSM-STATEDIR-001 | robust-state-mgmt | Unified state directory $CLAUDE_DIR/state/ | Eliminates breadcrumb heuristics; clean per-project/worktree/agent scoping |
| 2026-03-02 | DEC-RSM-SELFCHECK-001 | robust-state-mgmt | Triple self-validation at session startup | Version sentinels + generation file + bash -n catch different failure modes |
| 2026-03-02 | DEC-RSM-DAEMON-001 | robust-state-mgmt | Unix socket state daemon for multi-instance coordination | Graceful degradation; fencing tokens per Kleppmann; MCP bridge for web agents |
| 2026-03-02 | DEC-BL-TODO-001 | backlog-auto-capture | Restore todo.sh as standalone script matching hook call signatures | Hooks already reference scripts/todo.sh; matches statusline.sh pattern; zero overhead when not called |
| 2026-03-02 | DEC-BL-CAPTURE-001 | backlog-auto-capture | Fire-and-forget auto-capture in prompt-submit.sh | prompt-submit.sh must stay <100ms; background todo.sh create adds zero latency |
| 2026-03-02 | DEC-BL-SCAN-001 | backlog-auto-capture | Standalone scan-backlog.sh with /scan command | Script + command pattern for testability; reusable from gaps-report.sh and CI |
| 2026-03-02 | DEC-BL-GAPS-001 | backlog-auto-capture | gaps-report.sh aggregating .plan-drift, scan-backlog.sh, gh issues | Unified accountability view from multiple existing data sources |
| 2026-03-02 | DEC-BL-TRIGGER-001 | backlog-auto-capture | Immediate fire-and-forget auto-capture on deferral detection | Batching risks data loss on crash; immediate is reliable and simple |
| 2026-03-04 | DEC-PROD-001 | production-reliability | Auto-discover test files via glob in CI | Hardcoded list silently excludes 52 of 61 test files; glob ensures all run |
| 2026-03-04 | DEC-PROD-002 | production-reliability | Capture stderr to file instead of suppressing | 2>/dev/null hides real hook errors; capture preserves diagnostics |
| 2026-03-04 | DEC-PROD-003 | production-reliability | Inline rotation in session-init.sh for state files | session-init already runs at start; tail -n 1000 rotation is O(1) additional work |
| 2026-03-04 | DEC-PROD-004 | production-reliability | SESSION_ID-based TTL sentinel scoping | PID reuse causes false matches; SESSION_ID is unique per session |
| 2026-03-04 | DEC-PROD-005 | production-reliability | Non-blocking macOS CI matrix job | macOS is primary dev platform but CI is Ubuntu-only; continue-on-error initially |
| 2026-03-05 | DEC-RSM-BOOTSTRAP-001 | robust-state-mgmt | Bootstrap paradox: document self-hosting gate risk | When gate infrastructure itself is broken, the gate blocks the fix; manual override required (#105) |
| 2026-03-05 | DEC-MODE-TAXONOMY-001 | operational-mode-system | 4-tier mode taxonomy: Observe/Amend/Patch/Build | Maps to 4 distinct risk profiles; monotonic escalation lattice validated by deep research |
| 2026-03-05 | DEC-MODE-STATE-001 | operational-mode-system | .op-mode state file with monotonic write_op_mode() | Pipe-delimited format; registered in _PROTECTED_STATE_FILES; atomic_write() for crash safety |
| 2026-03-05 | DEC-MODE-CLASSIFY-001 | operational-mode-system | Deterministic classifier in prompt-submit.sh | prompt-submit.sh already has keyword detection; conservative fallback to Mode 4 on ambiguity |
| 2026-03-05 | DEC-MODE-CONTRACT-001 | operational-mode-system | Component contract matrix enforced at hook level | Each hook reads .op-mode and conditionally engages gates per contract matrix |
| 2026-03-05 | DEC-MODE-ESCALATE-001 | operational-mode-system | One-way escalation engine with trigger rules | Irreversible within session; is_source_file() authoritative; audit trail for every escalation |
| 2026-03-05 | DEC-MODE-SAFETY-001 | operational-mode-system | 9 cross-mode safety invariants, never mode-conditional | Layer 1 enforcement (guard.sh) fires unconditionally; agent exploitation of lightweight paths documented |
| 2026-03-05 | DEC-MODE-PERSIST-001 | operational-mode-system | Re-classify mode after compaction with Previous Mode hint | Fresh classification safer than stale state; monotonic lattice prevents downgrade |
| 2026-03-05 | DEC-MODE-BRANCH-001 | operational-mode-system | Mode 2 relaxes branch-guard for non-source files | Guardian approval is sufficient; no protected-non-source list needed |
| 2026-03-05 | DEC-MODE-PLAN-001 | operational-mode-system | Mode 3 plan-check skip via .op-mode hook-level read | Skips MASTER_PLAN.md required but enforces staleness if plan exists |
| 2026-03-06 | DEC-DISPATCH-001 | dispatch-enforcement | Restore compact routing table to CLAUDE.md | Full table was extracted (DEC-DISPATCH-EXTRACT-001); model no longer sees "must invoke implementer" every turn |
| 2026-03-06 | DEC-DISPATCH-002 | dispatch-enforcement | SESSION_ID-based orchestrator detection in session-init.sh | SessionStart fires only for orchestrator; subagents get SubagentStart with different CLAUDE_SESSION_ID |
| 2026-03-06 | DEC-DISPATCH-003 | dispatch-enforcement | Gate 1.5 in pre-write.sh blocks orchestrator source writes | Closes the enforcement gap: implementer dispatch was instruction-only while Guardian was mechanically enforced |
| 2026-03-06 | DEC-XPLAT-001 | xplatform-reliability | _file_mtime() in core-lib.sh with OS detection at load time | 25 inline stat calls use macOS-first order; Linux stat -f %m returns mount point not mtime; single function with Linux-first detection prevents recurrence |
| 2026-03-06 | DEC-XPLAT-002 | xplatform-reliability | _with_timeout() wrapper using Perl fallback | Stock macOS lacks timeout command; Perl alarm+exec available everywhere; zero new dependencies |
| 2026-03-06 | DEC-XPLAT-003 | xplatform-reliability | Fix stale test references inline | Section names reference context-lib.sh (moved to core-lib.sh/source-lib.sh); CYCLE COMPLETE fixture for removed CYCLE_MODE; real fixes not suppression |

---

## Active Initiatives

### Initiative: Statusline Information Architecture
**Status:** completed
**Started:** 2026-03-02
**Completed:** 2026-03-02
**Goal:** Redesign the statusline's segment layout for clarity: domain clustering, intuitive labels, aggregate token display, and project-scoped todo counts.

> The statusline was just rewritten as a two-line HUD, but segments lack labels and logical grouping. Raw numbers like `8 dirty WT:2` require mental decoding. Three data features are missing: aggregate token spend (context pressure beyond the percentage bar), project-vs-global todo split, and approximate cost labeling. This initiative adds all three while restructuring the layout into domain-clustered segments.

**Dominant Constraint:** simplicity — statusline must remain fast (single `jq` call for stdin, single `jq` call for cache, <50ms render)

#### Goals
- REQ-GOAL-001: Every statusline segment has a human-readable label that communicates its meaning without prior knowledge
- REQ-GOAL-002: Segments are visually clustered by domain (project/git, session economics, context/model)
- REQ-GOAL-003: Session token consumption is visible, giving users awareness of context window pressure beyond the percentage bar
- REQ-GOAL-004: Todo counts distinguish project-local from global, so users know which scope has pending work

#### Non-Goals
- REQ-NOGO-001: Real-time token tracking during a response — token counts update only when the statusline renders
- REQ-NOGO-002: Actual subscription cost calculation — we show list price with `~` prefix, not personalized billing
- REQ-NOGO-003: Interactive statusline (clickable segments, expand/collapse) — out of scope, text-only HUD
- REQ-NOGO-004: Historical cost graphs or trend visualization — `.session-cost-history` is storage, not visualization

#### Requirements

**Must-Have (P0)**

- REQ-P0-001: Domain-clustered layout — segments grouped by (1) project identity/git state, (2) session metrics/economics, (3) context/model info
  Acceptance: Given a rendered statusline, When a user reads left-to-right, Then related data appears adjacent with no interleaving of unrelated domains
- REQ-P0-002: Human-readable labels on all numeric segments
  Acceptance: Given the statusline output, When inspecting each segment, Then every numeric value has a preceding label (e.g., `dirty: 3` not `3 dirty`)
- REQ-P0-003: Cost prefixed with `~` to indicate approximate
  Acceptance: Given cost display, When rendered, Then cost shows as `~$X.XX` not `$X.XX`
- REQ-P0-004: Aggregate token count displayed in statusline from `total_input_tokens` + `total_output_tokens`
  Acceptance: Given stdin JSON with token fields, When statusline renders, Then a segment shows total tokens in human-readable K notation (e.g., `tokens: 145k`)
- REQ-P0-005: Project vs global todo split in display
  Acceptance: Given both project and global todo counts available, When statusline renders, Then display shows split (e.g., `todos: 3p 7g`) or project-only when in a project context with a fallback to global

**Nice-to-Have (P1)**

- REQ-P1-001: Project-lifetime cost persistence across sessions via `.session-cost-history`
  Criterion: session-end.sh appends session cost; session-init.sh sums history and writes to cache
- REQ-P1-002: Token direction breakdown (in/out) when terminal is wide enough
  Criterion: Wide terminals (>120 cols) show `tokens: 100k in / 45k out`; narrow show `tokens: 145k`

**Future Consideration (P2)**

- REQ-P2-001: 3-line layout option for very information-dense configurations
- REQ-P2-002: Cost alerting thresholds (color change at $1, $5, $10 lifetime)
- REQ-P2-003: Configurable segment visibility (user preferences for which segments appear)

#### Definition of Done

All P0 requirements satisfied. Statusline renders correctly at 80-column and 120-column widths. No new hooks added. Existing test suite passes. Performance: statusline renders in <50ms (no regression from current).

#### Architectural Decisions

- DEC-SL-LAYOUT-001: Keep 2-line layout with domain clustering
  Addresses: REQ-P0-001, REQ-P0-002.
  Rationale: Width analysis shows all new segments fit in 2 lines with labels. 3 lines would be more visually intrusive for minimal information gain. Line 1 = project/git/active-work, Line 2 = context/economics/code-metrics.

- DEC-SL-TOKENS-001: Display aggregate tokens as compact K notation (e.g., `145k`)
  Addresses: REQ-P0-004, REQ-NOGO-001.
  Rationale: Raw token counts (6+ digits) are unreadable. K notation is universally understood and fits in ~10 characters. Direction split deferred to P1 (width-dependent).

- DEC-SL-TODOCACHE-001: Add `todo_project` and `todo_global` fields to `.statusline-cache` JSON
  Addresses: REQ-P0-005.
  Rationale: `.statusline-cache` is already written by `write_statusline_cache()` at every hook cycle and read by statusline.sh. Adding fields to the existing JSON is simpler than creating a second cache file. The existing `.todo-count` file continues to serve session-init.sh's HUD injection (different consumer).

- DEC-SL-COSTPERSIST-001: Append session cost to `.session-cost-history` at session end; sum at session start into cache
  Addresses: REQ-P1-001.
  Rationale: Cost history must survive session boundaries. The statusline cache is session-scoped and rewritten each hook cycle. A persistent append-only file (like `.compaction-log`) is the proven pattern for cross-session data.

#### Proposed Layout

**Line 1: Project Identity + Git State + Active Work**
```
Opus claude-config-pro │ dirty: 8  wt: 2 │ agents: 3 (impl,test) │ todos: 3p 7g
```

**Line 2: Context Window + Session Economics + Code Metrics**
```
[████████░░░░] 67% │ tokens: 145k │ ~$0.53 │ 12m │ +45/-12 │ cache 69%
```

Domain clusters:
- **Cluster A (Line 1 left):** Model + workspace — "where am I"
- **Cluster B (Line 1 middle):** Git dirty + worktrees — "what state is the repo in"
- **Cluster C (Line 1 right):** Agents + todos — "what work is active"
- **Cluster D (Line 2 left):** Context bar + tokens — "how full is my context"
- **Cluster E (Line 2 middle):** Cost + duration — "what has this session cost"
- **Cluster F (Line 2 right):** Lines changed + cache — "what happened / efficiency"

#### Phase 1: Statusline Rendering Overhaul
**Status:** completed
**Completed:** 2026-03-02
**Decision IDs:** DEC-SL-LAYOUT-001, DEC-SL-TOKENS-001
**Requirements:** REQ-P0-001, REQ-P0-002, REQ-P0-003, REQ-P0-004
**Issues:** #71, #67, #68 (token display only)
**Definition of Done:**
- REQ-P0-001 satisfied: segments grouped by domain as specified in Proposed Layout
- REQ-P0-002 satisfied: every numeric segment has a label
- REQ-P0-003 satisfied: cost displays as `~$X.XX`
- REQ-P0-004 satisfied: token segment shows K notation from stdin fields

##### Decision Log
- DEC-SL-LAYOUT-001: 2-line domain-clustered layout — 3-line rejected as unnecessary given width analysis — Addresses: REQ-P0-001, REQ-P0-002 — **Implemented as planned**
- DEC-SL-TOKENS-001: Compact K notation for tokens — raw numbers unreadable, direction split deferred to P1 — Addresses: REQ-P0-004 — **Implemented as planned**

#### Phase 2: Data Pipeline — Todo Split + Cost Persistence
**Status:** completed
**Completed:** 2026-03-02
**Decision IDs:** DEC-SL-TODOCACHE-001, DEC-SL-COSTPERSIST-001, DEC-COST-PERSIST-001, DEC-COST-PERSIST-002, DEC-TODO-SPLIT-001, DEC-LIFETIME-COST-001, DEC-CACHE-003, DEC-TODO-SPLIT-002, DEC-TODO-SPLIT-003, DEC-LIFETIME-COST-002
**Requirements:** REQ-P0-005, REQ-P1-001
**Issues:** #72, #68 (cost persistence), #69

##### Decision Log
- DEC-SL-TODOCACHE-001: Todo split via statusline-cache JSON fields — avoids file proliferation — Addresses: REQ-P0-005 — **Implemented as planned**
- DEC-SL-COSTPERSIST-001: Cost persistence via `.session-cost-history` — proven cross-session pattern — Addresses: REQ-P1-001 — **Implemented as planned**
- DEC-COST-PERSIST-001: Capture session-end stdin to extract both reason and cost fields — Addresses: REQ-P1-001 — **New decision** (plan assumed stdin unavailable; it is available)
- DEC-COST-PERSIST-002: Append session cost to pipe-delimited history file — Addresses: REQ-P1-001 — **Implements DEC-SL-COSTPERSIST-001**
- DEC-TODO-SPLIT-001: Compute project/global counts via `gh issue list` before cache write — Addresses: REQ-P0-005 — **New decision**
- DEC-LIFETIME-COST-001: Sum lifetime cost from `.session-cost-history` at session start — Addresses: REQ-P1-001 — **New decision**
- DEC-CACHE-003: Add todo_project, todo_global, lifetime_cost fields to cache — Addresses: REQ-P0-005, REQ-P1-001 — **Implements DEC-SL-TODOCACHE-001**
- DEC-TODO-SPLIT-002: Read cache fields with -1 sentinel for backward compat — Addresses: REQ-P0-005 — **New decision**
- DEC-TODO-SPLIT-003: Split display format (`todos: 3p 7g`) with legacy fallback — Addresses: REQ-P0-005 — **New decision**
- DEC-LIFETIME-COST-002: Display lifetime cost as `(Σ~$N.NN)` annotation — Addresses: REQ-P1-001 — **Refinement** (plan suggested `(life: ~$12.40)`, Σ symbol more compact)

#### Statusline IA Worktree Strategy

Main is sacred. Each phase works in its own worktree:
- **Phase 1:** `~/.claude/.worktrees/statusline-rendering` on branch `feature/statusline-rendering`
- **Phase 2:** `~/.claude/.worktrees/statusline-data-pipeline` on branch `feature/statusline-data-pipeline`

#### Statusline IA References

- Issue #67: Labeling and visual clustering
- Issue #68: Aggregate token spend
- Issue #69: Todo granularity
- `scripts/statusline.sh` — current implementation (merged today)
- Stdin JSON fields: `context_window.total_input_tokens`, `context_window.total_output_tokens`
- `.statusline-cache` format: JSON written by `write_statusline_cache()` in session-lib.sh

### Initiative: Robust State Management
**Status:** active
**Started:** 2026-03-02
**Goal:** Build a three-tier state management system (global, project, config) that is reliable under concurrent use and extensible to multi-agent topologies including CI bots, Claude Web agents, and teams.

> The hook governance system manages state (.proof-status, .test-status, guardian markers, worktree breadcrumbs) using file-based writes scattered across 22 hook files with no coordination protocol. Five categories of failure have been documented: Write-tool loophole (#37), guardian marker races (#56), proof-path mismatches, state file corruption, and multiple writers with no mutual exclusion. The current system works for single-agent sequential use but cannot scale to concurrent agents, CI/CD bots, or multi-instance coordination. Deep research confirms SQLite WAL is available on macOS without installation, Unix socket daemons are the correct long-term coordination layer, and MCP state servers bridge to Claude Web agents.

**Dominant Constraint:** reliability — The state system must never cause false denies (blocking legitimate work) or false allows (permitting unauthorized state changes). Correctness over performance or simplicity. Graceful degradation: when coordination layer is unavailable, fall back to file-based (current system).

#### Goals
- REQ-GOAL-001: All governance state files protected from unauthorized writes regardless of tool (Bash, Write, Edit)
- REQ-GOAL-002: Concurrent state writes from multiple hooks/agents are safe (no corruption, no lost updates)
- REQ-GOAL-003: State file paths resolved through a single canonical mechanism, eliminating breadcrumb workarounds
- REQ-GOAL-004: Hook system self-state (library versions, syntax validity) tracked and validated at session startup
- REQ-GOAL-005: Architecture supports future multi-agent topologies (CI bots, web agents, teams) without protocol changes
- REQ-GOAL-006: Proof-status transitions enforced as a monotonic lattice (none < needs-verification < pending < verified < committed)

#### Non-Goals
- REQ-NOGO-001: Cross-machine state synchronization — each machine runs its own state service
- REQ-NOGO-002: Distributed consensus protocols (etcd, Raft) — Unix socket CAS is sufficient for local coordination
- REQ-NOGO-003: Setuid helpers or kernel modules — stay in userspace (flock, SQLite, Unix sockets)

#### Requirements

**Must-Have (P0)**

- REQ-P0-001: Write-tool loophole closed — Write/Edit to .proof-status and .test-status denied by pre-write.sh Gate 0
  Acceptance: Given an agent Write/Edit call targeting .proof-status, When pre-write.sh processes it, Then emit_deny fires with explanation; manual prompt-submit.sh and post-task.sh auto-verify paths remain functional
- REQ-P0-002: All proof-status writes use flock()-based locking with no corruption under concurrent access
  Acceptance: Given 5 parallel write_proof_status() calls, When executed simultaneously, Then final file contains exactly one valid state with no truncation or interleaving
- REQ-P0-003: Monotonic lattice enforcement on proof-status transitions
  Acceptance: Given proof-status = "verified", When write_proof_status("pending") is called, Then write is rejected (lower state cannot overwrite higher); Given proof-status = "pending", When write_proof_status("verified") is called, Then write succeeds (upward transition)
- REQ-P0-004: state.json replaced by SQLite WAL store with atomic CAS operations
  Acceptance: Given concurrent state_update() calls from multiple hooks, When executed, Then no lost updates, no corruption, and CAS semantics enforced via BEGIN IMMEDIATE
- REQ-P0-005: Hook system self-validation at session startup detects library skew, interrupted pulls, and syntax errors
  Acceptance: Given a domain library with a version mismatch, When session-init.sh runs, Then a warning is injected into CONTEXT_PARTS identifying the skewed library
- REQ-P0-006: Unified state directory convention ($CLAUDE_DIR/state/) with clean migration from scattered dotfiles
  Acceptance: Given an existing .proof-status-{phash} file, When the migration runs, Then state is readable from both old and new locations during transition; after migration, new location is authoritative
- REQ-P0-007: Protected state file registry — extensible path-to-writer policy for governance files
  Acceptance: Given the registry lists .proof-status, .test-status, .hook-timing.log, When a new state file is added, Then adding one entry to the registry protects it without touching gate logic

**Nice-to-Have (P1)**

- REQ-P1-001: Unix socket state daemon for multi-instance coordination
  Criterion: Daemon starts automatically, hooks use socket when available, fall back to file-based when unavailable
- REQ-P1-002: MCP state server for Claude Web agent and team coordination
  Criterion: FastMCP server exposes CAS, lease, subscribe operations to any MCP-connected Claude instance
- REQ-P1-003: CI/CD state bridge via ci-state-export.sh
  Criterion: Hook state readable as GitHub Actions step outputs; CI bots can query proof-status without file access

**Future Consideration (P2)**

- REQ-P2-001: Per-agent state namespaces for team-of-agents topologies
- REQ-P2-002: State replication across worktrees (event-sourced sync)
- REQ-P2-003: State visualization dashboard (TUI or web)

#### Definition of Done

All P0 requirements (001-007) satisfied. Write-tool loophole (#37) closed. Concurrent writes safe under flock(). SQLite WAL replaces state.json. Monotonic lattice enforced. Hook self-validation operational. State directory convention established with migration path. Existing 159-test suite passes with no regressions. New state management tests added for each phase.

#### Architectural Decisions

- DEC-RSM-REGISTRY-001: Protected state file registry array in core-lib.sh checked by pre-write.sh Gate 0
  Addresses: REQ-GOAL-001, REQ-P0-001, REQ-P0-007.
  Rationale: Centralized list of protected file patterns. Extensible (add patterns without touching gate logic), testable (registry is inspectable), <1ms string match overhead. Preferred over per-gate pattern matching (scattered, hard to audit) and file-attribute protection (not portable across macOS/Linux).

- DEC-RSM-FLOCK-001: POSIX advisory locks via flock() for concurrent write safety
  Addresses: REQ-GOAL-002, REQ-P0-002.
  Rationale: POSIX standard, available on macOS and Linux, sub-millisecond overhead, automatic release on process death. Preferred over mkdir-as-lock (no automatic release), lockfile/procmail (extra dependency), and no-locking (accepts races). Subshell-scoped pattern ensures crash safety.

- DEC-RSM-LATTICE-001: Monotonic lattice enforcement on proof-status writes
  Addresses: REQ-GOAL-006, REQ-P0-003.
  Rationale: Proof-status is already a semilattice (none < needs-verification < pending < verified < committed). Enforcing monotonicity at write time eliminates the verified-to-pending regression bug without external coordination. Combined with CAS, this is the correct concurrency primitive. Reset between work cycles via .proof-epoch counter.

- DEC-RSM-SQLITE-001: SQLite WAL as state store replacing state.json
  Addresses: REQ-P0-004, REQ-GOAL-002.
  Rationale: SQLite is pre-installed on macOS (zero new dependencies). WAL mode allows concurrent readers with one writer. BEGIN IMMEDIATE provides atomic CAS without external locking. Eliminates the jq read-modify-write race in state_update(). Per-project namespacing via project_hash key prefix.

- DEC-RSM-STATEDIR-001: Unified state directory $CLAUDE_DIR/state/ replacing scattered dotfiles
  Addresses: REQ-GOAL-003, REQ-P0-006.
  Rationale: Clean separation of state from config/cache. Eliminates breadcrumb-based worktree resolution (resolve_proof_file). Dual-write migration: new location primary, old location fallback during transition. Per-project, per-worktree, per-agent subdirectories support future namespacing.

- DEC-RSM-SELFCHECK-001: Triple self-validation at session startup (version sentinels + generation file + bash -n)
  Addresses: REQ-GOAL-004, REQ-P0-005.
  Rationale: Each catches a different failure mode: version sentinels detect library skew from partial loads, generation file (.hooks-gen) detects interrupted git pull, bash -n catches syntax errors from edits. Cost: ~175ms one-time at session start (7ms/file x ~25 files). Complementary, not redundant.

- DEC-RSM-DAEMON-001: Unix socket state daemon (Python asyncio, ~80 lines) for multi-instance coordination
  Addresses: REQ-GOAL-005, REQ-P1-001, REQ-P1-002.
  Rationale: JSON-over-AF_UNIX protocol provides CAS, leases with fencing tokens, and subscribe (SSE for hooks). Graceful degradation: all hooks fall back to file-based when socket unavailable. MCP bridge (~30-line FastMCP) extends to Claude Web agents. Per Kleppmann's analysis, fencing tokens prevent stale-lease hazards.

#### Phase 0: Immediate Fixes -- flock + Write-tool Closure
**Status:** completed
**Completed:** 2026-03-02
**Merge:** ca20027
**Decision IDs:** DEC-RSM-FLOCK-001, DEC-RSM-LATTICE-001
**Requirements:** REQ-P0-001, REQ-P0-002, REQ-P0-003
**Issues:** #75 (closed), #37 (closed)
**Outcome:** Gate 0 write protection in pre-write.sh, flock-based locking for write_proof_status(), monotonic lattice enforcement, guardian TTL extended to 600s with heartbeat, CAS wrapper in prompt-submit.sh.

##### Decision Log
- DEC-RSM-FLOCK-001: flock()-based locking — crash-safe subshell pattern — Addresses: REQ-P0-002 — **Implemented as planned**
- DEC-RSM-LATTICE-001: Monotonic lattice enforcement — ordinal map with epoch reset — Addresses: REQ-P0-003 — **Implemented as planned**

#### Phase 1: Coordination Protocol -- CAS + Protected Registry
**Status:** completed
**Completed:** 2026-03-03
**Merge:** cbcf7d4
**Decision IDs:** DEC-RSM-REGISTRY-001, DEC-RSM-FLOCK-001
**Requirements:** REQ-P0-002, REQ-P0-007
**Issues:** #76 (closed)
**Outcome:** Protected state file registry in core-lib.sh (`_PROTECTED_STATE_FILES` array + `is_protected_state_file()`), `state_write_locked()` CAS wrapper in state-lib.sh, proof-epoch counter for clean lattice resets, 15 concurrency tests (parallel writes, CAS contention, lock timeout, lattice enforcement, epoch reset).

##### Decision Log
- DEC-RSM-REGISTRY-001: Protected registry array — centralized, extensible, <1ms — Addresses: REQ-P0-007 — **Implemented as planned**
- DEC-RSM-FLOCK-001: state_write_locked() with CAS semantics — Addresses: REQ-P0-002 — **Implemented as planned**

#### Phase 2: State Management Consolidation -- Portable Locking, Atomic CAS, Lattice Routing
**Status:** completed
**Completed:** 2026-03-05
**Merge:** 61cf489
**Decision IDs:** DEC-RSM-SQLITE-001, DEC-RSM-BOOTSTRAP-001
**Requirements:** REQ-P0-004
**Issues:** #77 (closed)
**Outcome:** Portable locking via `_lock_fd()` replacing platform-specific flock, atomic `cas_proof_status()` rewrite with true CAS semantics (fixes sentinel-reads-lockfile bug), lattice routing through `_route_lattice()`, registry adoption across all state writers, 15 concurrency tests. Discovered bootstrap paradox (#105): self-hosting gate blocks merge of gate fix when `cas_proof_status()` on main is broken. **Scope adjusted:** SQLite migration deferred; Phase 2 focused on portable locking, CAS correctness, and lattice routing as prerequisites.

##### Decision Log
- DEC-RSM-SQLITE-001: Scope adjusted — portable locking and CAS correctness prioritized over SQLite migration — Addresses: REQ-P0-004 — **Partial: locking/CAS delivered, SQLite deferred to future phase**
- DEC-RSM-BOOTSTRAP-001: Bootstrap paradox documented — self-hosting gate changes require manual override when gate itself is broken — Filed as #105 — **New discovery**

#### Phase 3: Project-Tier State -- Unified state/ Directory
**Status:** planned
**Decision IDs:** DEC-RSM-STATEDIR-001
**Requirements:** REQ-P0-006
**Issues:** #78
**Definition of Done:**
- REQ-P0-006 satisfied: $CLAUDE_DIR/state/ is authoritative for all governance state
- Proof-status, test-status, guardian markers migrated to state directory
- Breadcrumb-based resolution in resolve_proof_file() retired
- Per-project, per-worktree scoping via directory structure

##### Planned Decisions
- DEC-RSM-STATEDIR-001: Unified state directory — clean separation, eliminates breadcrumbs — Addresses: REQ-P0-006

##### Work Items

**W3-0: Create state directory convention**
- Structure: `$CLAUDE_DIR/state/{project_hash}/proof-status`, `$CLAUDE_DIR/state/{project_hash}/test-status`, etc.
- Worktree-scoped: `$CLAUDE_DIR/state/{project_hash}/worktrees/{worktree_name}/proof-status`
- Agent-scoped: `$CLAUDE_DIR/state/{project_hash}/agents/{agent_type}/status`
- Create `state_dir()` helper in state-lib.sh: returns correct state directory for current context

**W3-1: Migrate proof-status to state directory**
- write_proof_status() writes to `$CLAUDE_DIR/state/{phash}/proof-status` (primary)
- Dual-write: also write old locations (.proof-status-{phash}, .proof-status) during transition
- resolve_proof_file() reads new location first, falls back to old
- Mark old breadcrumb resolution code as deprecated with removal target (Phase 3 completion)

**W3-2: Migrate test-status and guardian markers**
- .test-status → `$CLAUDE_DIR/state/{phash}/test-status`
- .active-guardian-* → `$CLAUDE_DIR/state/{phash}/guardian-lease`
- .active-autoverify-* → `$CLAUDE_DIR/state/{phash}/autoverify-lease`
- Update all readers/writers in task-track.sh, check-tester.sh, check-guardian.sh

**W3-3: Retire breadcrumb resolution**
- Remove .active-worktree-path breadcrumb creation from task-track.sh
- Simplify resolve_proof_file() to direct state directory lookup
- Remove backward compat code for old dotfile locations (after 1 release cycle)
- Update clean-state.sh to clean both old and new locations

**W3-4: Migration tests**
- Test: old-format proof-status readable during migration period
- Test: new-format proof-status takes priority over old
- Test: clean migration — after migrate, only new locations exist
- Test: worktree-scoped state isolation (two worktrees, independent proof-status)

##### Dispatch Plan
- Dispatch 1: W3-0, W3-1 (state directory + proof-status migration — foundation)
- Dispatch 2: W3-2, W3-3, W3-4 (remaining migrations + breadcrumb retirement + tests)

##### Critical Files
- `hooks/state-lib.sh` — state_dir() helper, directory convention
- `hooks/log.sh` — resolve_proof_file() migration, write_proof_status() new paths
- `hooks/task-track.sh` — guardian marker migration, breadcrumb removal
- `hooks/check-tester.sh` — proof-status read migration
- `scripts/clean-state.sh` — dual-location cleanup

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Phase 4: Global/Config Tier -- Self-Validation + Version Sentinels
**Status:** planned
**Decision IDs:** DEC-RSM-SELFCHECK-001
**Requirements:** REQ-P0-005
**Issues:** #79
**Definition of Done:**
- REQ-P0-005 satisfied: session-init.sh detects library skew, interrupted pulls, syntax errors
- Version sentinels in all 8 domain libraries
- .hooks-gen generation file maintained by post-merge git hook
- bash -n preflight validates all hooks + gate files at startup

##### Planned Decisions
- DEC-RSM-SELFCHECK-001: Triple self-validation — complementary detection of skew, interrupted pull, syntax errors — Addresses: REQ-P0-005

##### Work Items

**W4-0: Add version sentinels to all domain libraries**
- Each library gets `_LIB_VERSION=N` at the top (e.g., `_GIT_LIB_VERSION=1`)
- source-lib.sh `require_*()` records version on load
- `verify_library_consistency()` in source-lib.sh: check all loaded versions match expected generation

**W4-1: .hooks-gen generation file + post-merge git hook**
- Create `.git/hooks/post-merge`: writes timestamp to `hooks/.hooks-gen`
- session-init.sh reads .hooks-gen and compares to loaded library timestamps
- Mismatch → inject warning into CONTEXT_PARTS

**W4-2: bash -n preflight in session-init.sh**
- Validate syntax of all 4 entry points: `bash -n hooks/{pre-bash,pre-write,post-write,stop}.sh`
- Validate all gate files (future): `bash -n hooks/gates/*/*.sh`
- Cost: ~7ms/file x ~25 files = ~175ms one-time at session start
- Inject warnings for any failures

**W4-3: Config state validation tests**
- Test: version sentinel mismatch detected
- Test: .hooks-gen staleness detected
- Test: bash -n catches intentional syntax error
- Test: all current libraries pass version check (regression guard)

##### Dispatch Plan
- Dispatch 1: W4-0, W4-1, W4-2, W4-3 (all tightly coupled — self-validation suite)

##### Critical Files
- `hooks/source-lib.sh` — verify_library_consistency(), require_*() version recording
- `hooks/session-init.sh` — preflight validation, generation check
- `hooks/*-lib.sh` — all 8 domain libraries get version sentinels
- `.git/hooks/post-merge` — generation file writer

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Phase 5: Multi-Agent Topology -- State Service + MCP + CI/CD
**Status:** planned
**Decision IDs:** DEC-RSM-DAEMON-001
**Requirements:** REQ-P1-001, REQ-P1-002, REQ-P1-003
**Issues:** #80
**Definition of Done:**
- REQ-P1-001 satisfied: Unix socket state daemon operational with graceful degradation
- REQ-P1-002 satisfied: MCP state server exposes CAS/lease/subscribe to Claude instances
- REQ-P1-003 satisfied: ci-state-export.sh bridges hook state to GitHub Actions

##### Planned Decisions
- DEC-RSM-DAEMON-001: Unix socket state daemon with SQLite backend — graceful degradation, fencing tokens — Addresses: REQ-P1-001, REQ-P1-002

##### Work Items

**W5-0: Unix socket state daemon (Python asyncio)**
- Path: `scripts/state-daemon.py` (~80-100 lines)
- SQLite WAL backend (reuse state.db from Phase 2)
- Protocol: JSON over AF_UNIX socket at `~/.claude/state.sock`
- Operations: get, cas, lease/renew/release, subscribe (SSE for hooks)
- Auto-start: session-init.sh starts daemon if not running
- Auto-stop: daemon exits after 30min idle (no connected clients)

**W5-1: Graceful degradation in state-lib.sh**
- state_update/state_read/state_cas: try socket first, fall back to SQLite on connection error
- ~3 lines of additional code per function: `if _state_socket_available; then ... else ... fi`
- `_state_socket_available()`: check if `~/.claude/state.sock` exists and is connectable

**W5-2: Fencing tokens for lease safety**
- Per Kleppmann: every lease grants a monotonic token; every write includes the token
- State daemon rejects writes with stale tokens (older than current lease)
- Prevents: stale guardian marker allowing unauthorized commits after lease expiry

**W5-3: MCP state server (FastMCP)**
- Path: `scripts/state-mcp-server.py` (~30-50 lines)
- Wraps the Unix socket daemon with MCP protocol
- Tools: `state_get`, `state_cas`, `state_lease`, `state_subscribe`
- Registered in Claude Code MCP config for multi-instance access

**W5-4: ci-state-export.sh -- GitHub Actions bridge**
- Read proof-status, test-status from state directory
- Output as GitHub Actions `::set-output` format
- CI workflows can query hook state without direct file access
- Add to `.github/workflows/` as a step in CI pipeline

**W5-5: Multi-agent coordination design document**
- Architecture for team-of-agents with per-agent state namespaces
- Conflict resolution: last-writer-wins for advisory state, CAS for governance state
- Web agent integration via MCP state server
- NOT implementation — design document for future initiative

##### Dispatch Plan
- Dispatch 1: W5-0, W5-1 (daemon + graceful degradation — core infrastructure)
- Dispatch 2: W5-2, W5-3 (fencing tokens + MCP server — coordination layer)
- Dispatch 3: W5-4, W5-5 (CI bridge + design doc — integration)

##### Critical Files
- `scripts/state-daemon.py` — Unix socket state daemon (new file)
- `scripts/state-mcp-server.py` — MCP state server (new file)
- `hooks/state-lib.sh` — socket-first fallback logic
- `hooks/session-init.sh` — daemon auto-start
- `scripts/ci-state-export.sh` — GitHub Actions bridge (new file)

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Robust State Management Worktree Strategy

Main is sacred. Each phase works in its own worktree:
- **Phase 0:** `~/.claude/.worktrees/state-immediate-fixes` on branch `feature/state-immediate-fixes`
- **Phase 1:** `~/.claude/.worktrees/state-coordination` on branch `feature/state-coordination`
- **Phase 2:** `~/.claude/.worktrees/state-sqlite` on branch `feature/state-sqlite`
- **Phase 3:** `~/.claude/.worktrees/state-project-tier` on branch `feature/state-project-tier`
- **Phase 4:** `~/.claude/.worktrees/state-config-tier` on branch `feature/state-config-tier`
- **Phase 5:** `~/.claude/.worktrees/state-service` on branch `feature/state-service`

#### Robust State Management References

- Epic: #74 (Robust State Management)
- Closes: #37 (Write-tool loophole, Phase 0)
- Related: #60 (Metanoia Consolidation Debt epic), #56 (auto-verify race, fixed)
- Research: `tmp/state-management-research.md` (flock, SQLite WAL, Unix socket, MCP, CRDT)
- Research: `tmp/metanoia-remediation-plan.md` (gate extraction, security enforcement)
- Research: `tmp/metanoia-refactor-report.md` (incident history, benchmark data)
- Key patterns: Kleppmann fencing tokens, CRDT monotonic lattice, graceful degradation
- Current state files: `.proof-status-{phash}`, `.test-status`, `.active-guardian-*`, `.active-autoverify-*`, `.active-worktree-path`, `state.json`

### Initiative: Backlog Auto-Capture & Gaps Reporting
**Status:** completed
**Started:** 2026-03-02
**Completed:** 2026-03-02
**Goal:** Ensure nothing falls through the cracks by auto-capturing deferred work as GitHub Issues, scanning codebases for untracked markers, and producing unified accountability gaps reports.

> Claude Code sessions routinely defer work ("we'll do that later") and accumulate technical debt markers (TODOs, FIXMEs, HACKs) without systematic tracking. The existing deferral detection in prompt-submit.sh only suggests using /backlog — it doesn't create issues. The todo.sh script that hooks depend on is missing entirely, causing silent failures in session-init.sh and stop.sh. Meanwhile, @decision drift detection exists in stop.sh but has no counterpart for TODO/FIXME scanning, and there is no single view aggregating all accountability gaps. This initiative restores the missing foundation (todo.sh), upgrades deferral detection to auto-capture, adds codebase scanning for debt markers, and produces a unified gaps report.

**Dominant Constraint:** simplicity — hooks must remain fast (<100ms), scanning is on-demand only, auto-capture uses fire-and-forget to avoid latency impact

#### Goals
- REQ-GOAL-001: Every deferred-work conversation automatically becomes a tracked GitHub Issue with context (file, line, session)
- REQ-GOAL-002: All TODO/FIXME/HACK markers in code are discoverable via scanning, with GitHub Issues created or updated to match
- REQ-GOAL-003: A single gaps report aggregates all accountability gaps (open issues, untracked markers, decision drift, stale items) into an actionable view
- REQ-GOAL-004: The missing todo.sh backing script is restored, unblocking all hook integrations that depend on it

#### Non-Goals
- REQ-NOGO-001: Real-time TODO scanning on every hook run — too expensive; scanning is on-demand only
- REQ-NOGO-002: Auto-closing issues when TODOs are removed from code — requires git history diffing; separate initiative
- REQ-NOGO-003: Cross-project aggregation of gaps reports — each project gets its own report; global view is P2
- REQ-NOGO-004: IDE integration (VS Code extension for inline TODO tracking) — out of scope, CLI-only
- REQ-NOGO-005: Modifying existing @decision enforcement in stop.sh — that system works; we build alongside it

#### Requirements

**Must-Have (P0)**

- REQ-P0-001: Restore scripts/todo.sh with hud, count, claim, and create methods matching existing hook call signatures
  Acceptance: Given session-init.sh calls `todo.sh hud`, When todo.sh exists, Then it returns formatted backlog counts without error. Given stop.sh calls `todo.sh count --all`, When called, Then it returns `project|global|config|total` pipe-delimited counts.
- REQ-P0-002: Auto-capture of deferred-work language creates GitHub Issues automatically (not just advisory)
  Acceptance: Given a user says "we'll do that later" in a prompt, When prompt-submit.sh detects deferral language, Then a GitHub Issue is created via fire-and-forget todo.sh with label `claude-todo` and context, and the issue creation is confirmed in additionalContext.
- REQ-P0-003: On-demand codebase scanning for TODO/FIXME/HACK markers with issue correlation
  Acceptance: Given a developer invokes /scan, When scan-backlog.sh runs, Then it outputs a table of all markers with file:line, type, text, and linked issue (if any). Untracked markers are flagged.
- REQ-P0-004: Gaps report aggregating open issues, untracked markers, and decision drift
  Acceptance: Given a developer invokes /gaps, When gaps-report.sh runs, Then it outputs sections for open backlog issues, untracked code markers, decision drift (from .plan-drift), and a summary accountability score.

**Nice-to-Have (P1)**

- REQ-P1-001: Auto-capture includes file:line references when conversation context mentions specific files
  Criterion: Issue body includes file reference when the deferral was about a specific file being discussed.
- REQ-P1-002: Scanner deduplicates — if a TODO already has a matching issue, it links rather than creating a duplicate
  Criterion: Scanner searches existing issues by body content before creating new ones.
- REQ-P1-003: Gaps report includes staleness metrics (issues older than 14 days, TODOs older than last commit)
  Criterion: Report shows age of each item and flags stale ones.

**Future Consideration (P2)**

- REQ-P2-001: Cross-project gaps dashboard aggregating all projects
- REQ-P2-002: Git blame integration to attribute TODO age and author
- REQ-P2-003: Automated priority inference from marker context (HACK > FIXME > TODO)

#### Definition of Done

All P0 requirements (001-004) satisfied. todo.sh hud/count/claim/create work without error from hooks. Deferral detection in prompt-submit.sh auto-creates issues. /scan command produces accurate marker inventory. /gaps command produces unified accountability report. Existing 159-test suite passes with no regressions. New tests added for todo.sh, scan-backlog.sh, and gaps-report.sh.

#### Architectural Decisions

- DEC-BL-TODO-001: Restore todo.sh as standalone script in scripts/ matching existing hook call signatures
  Addresses: REQ-P0-001, REQ-GOAL-004.
  Rationale: Hooks already reference `scripts/todo.sh` with specific subcommands (hud, count, claim). Matches the established pattern where hooks call scripts (statusline.sh, worktree-roster.sh). A domain library in hooks/ would require require_backlog() and source overhead; a standalone script is called only when needed, zero overhead otherwise.

- DEC-BL-CAPTURE-001: Fire-and-forget auto-capture in prompt-submit.sh via todo.sh create
  Addresses: REQ-P0-002, REQ-GOAL-001.
  Rationale: prompt-submit.sh runs on every user prompt and must stay fast (<100ms). Inline gh issue create takes 500ms-2s (network). Fire-and-forget (`todo.sh create "..." &`) adds zero latency. The background process handles issue creation independently. If it fails, the advisory message still appears as fallback.

- DEC-BL-SCAN-001: Standalone scan-backlog.sh with /scan command wrapper
  Addresses: REQ-P0-003, REQ-GOAL-002.
  Rationale: Script + command pattern (same as statusline.sh, worktree-roster.sh) keeps scanning logic testable and reusable from gaps-report.sh and CI. A skill would fork context unnecessarily for what is fundamentally grep + issue-list correlation. Uses rg (ripgrep) for scanning, matching stop.sh's existing @decision scanning pattern.

- DEC-BL-GAPS-001: Standalone gaps-report.sh aggregating .plan-drift, scan-backlog.sh, and gh issues
  Addresses: REQ-P0-004, REQ-GOAL-003.
  Rationale: The gaps report must combine data from multiple sources: .plan-drift (written by stop.sh surface section), scan-backlog.sh output (TODO/FIXME scan), and gh issue list (open backlog). A standalone script can call scan-backlog.sh as a subprocess and read .plan-drift as a file, producing a unified markdown report. Command wrapper (/gaps) provides the user-facing interface.

- DEC-BL-TRIGGER-001: Immediate fire-and-forget auto-capture on deferral detection
  Addresses: REQ-P0-002.
  Rationale: Batching deferrals to session end risks losing them on crash. Immediate creation with fire-and-forget is reliable and simple. The /backlog command already handles manual creation with interview workflow for intentional items. Auto-capture handles the conversational deferrals that would otherwise be lost. Deduplication is P1.

#### Phase 1: Foundation -- todo.sh + Hook Integration
**Status:** completed
**Completed:** 2026-03-02
**Decision IDs:** DEC-BL-TODO-001, DEC-BL-CAPTURE-001, DEC-BL-TRIGGER-001
**Requirements:** REQ-P0-001, REQ-P0-002
**Issues:** #81
**Definition of Done:**
- REQ-P0-001 satisfied: todo.sh hud, count, claim, create all functional; session-init.sh and stop.sh integrations work
- REQ-P0-002 satisfied: prompt-submit.sh auto-creates issues on deferral detection via fire-and-forget

##### Planned Decisions
- DEC-BL-TODO-001: todo.sh as standalone script — matches existing hook call signatures — Addresses: REQ-P0-001
- DEC-BL-CAPTURE-001: Fire-and-forget auto-capture — zero latency impact on prompt-submit.sh — Addresses: REQ-P0-002
- DEC-BL-TRIGGER-001: Immediate capture — reliable, no session-crash risk — Addresses: REQ-P0-002

##### Work Items

**W1-0: Create scripts/todo.sh with hud, count, claim, create subcommands**
- `hud` subcommand: query `gh issue list --label claude-todo --state open` for both project and global repos, format as compact HUD lines for session-init injection
- `count --all` subcommand: return `project|global|config|total` pipe-delimited counts matching stop.sh expectations
- `claim N [--auto] [--global]` subcommand: assign issue to current session, add comment "Claimed by Claude Code session"
- `create "title" [--body "..."] [--context "..."]` subcommand: create issue with `gh issue create --label claude-todo`, return issue URL
- Handle missing `gh` gracefully (exit 0 with empty output, no errors)
- Respect scope: project repo when in git context, global repo (cc-todos) otherwise

**W1-1: Upgrade prompt-submit.sh deferral detection to auto-capture**
- Replace the advisory-only injection (line 239-241) with fire-and-forget issue creation
- Extract deferral text from prompt context (the sentence containing the trigger word)
- Call `scripts/todo.sh create "$DEFERRAL_TEXT" --context "session:$SESSION_ID" &`
- Keep the advisory injection as well (so the model knows an issue was created)
- Update the advisory message to say "Auto-captured as backlog issue" instead of "Suggest using /backlog"

**W1-2: Verify session-init.sh and stop.sh integrations work**
- session-init.sh line 102-110: todo.sh hud call should now succeed and inject HUD lines
- stop.sh line 564-573: todo.sh count --all should now succeed and show pending counts
- prompt-submit.sh line 223-236: todo.sh claim should now work for auto-claim on issue refs
- No code changes needed in these hooks — they already have the correct call signatures

**W1-3: Tests for todo.sh**
- Test: `todo.sh hud` returns formatted output (mock gh with fixture data)
- Test: `todo.sh count --all` returns pipe-delimited format
- Test: `todo.sh create "test title"` creates issue (mock gh)
- Test: `todo.sh` with missing gh exits gracefully
- Test: prompt-submit.sh deferral detection triggers todo.sh create (integration test)

##### Dispatch Plan
- Dispatch 1: W1-0, W1-1, W1-2, W1-3 (all tightly coupled — single script + hook modifications + tests)

##### Critical Files
- `scripts/todo.sh` — new file, the missing backing script for all backlog operations
- `hooks/prompt-submit.sh` — deferral detection upgrade (line 239-241)
- `hooks/session-init.sh` — verification only (no changes, existing todo.sh hud call)
- `hooks/stop.sh` — verification only (no changes, existing todo.sh count call)
- `tests/run-hooks.sh` — new test additions for todo.sh

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Phase 2: Codebase Scanner -- scan-backlog.sh + /scan
**Status:** completed
**Completed:** 2026-03-02
**Decision IDs:** DEC-BL-SCAN-001
**Requirements:** REQ-P0-003
**Issues:** #82
**Definition of Done:**
- REQ-P0-003 satisfied: /scan produces accurate marker inventory with file:line, type, text, and issue linkage

##### Planned Decisions
- DEC-BL-SCAN-001: Standalone scan-backlog.sh with rg-based scanning — testable, reusable — Addresses: REQ-P0-003

##### Work Items

**W2-0: Create scripts/scan-backlog.sh — rg-based marker scanner**
- Scan patterns: `TODO`, `FIXME`, `HACK`, `XXX`, `OPTIMIZE`, `TEMP`, `WORKAROUND`
- Use rg (ripgrep) with `--line-number --no-heading` for structured output
- Respect .gitignore (rg does this by default)
- Skip vendor/, node_modules/, .git/, archive/, _archive/ directories
- Output format: JSON array of `{file, line, type, text, issue_ref}` objects
- Also support `--format table` for human-readable markdown table output
- Exit codes: 0 = markers found, 1 = no markers, 2 = error

**W2-1: Issue correlation — match markers against existing issues**
- Query `gh issue list --label claude-todo --state open --json number,title,body --limit 200`
- For each found marker, search issue bodies for matching file:line reference
- If match found, set `issue_ref` to the issue number
- If no match, flag as "untracked"
- Correlation is best-effort (body search), not guaranteed (P1 dedup improves this)

**W2-2: Create commands/scan.md — /scan command**
- Parse $ARGUMENTS for options: `--json` (raw JSON output), `--create` (auto-create issues for untracked markers)
- Default: human-readable table showing all markers with tracking status
- With `--create`: call `todo.sh create` for each untracked marker with file:line in body
- Summary line: "Found N markers: M tracked, K untracked"

**W2-3: Tests for scan-backlog.sh**
- Test: scan finds TODO, FIXME, HACK markers in test fixtures
- Test: scan respects .gitignore exclusions
- Test: issue correlation matches markers to existing issues
- Test: JSON output format is valid
- Test: table output format is readable

##### Dispatch Plan
- Dispatch 1: W2-0, W2-1, W2-2, W2-3 (tightly coupled — scanner + correlation + command + tests)

##### Critical Files
- `scripts/scan-backlog.sh` — new file, the codebase marker scanner
- `commands/scan.md` — new file, /scan command wrapper
- `scripts/todo.sh` — used for issue queries and creation (Phase 1 dependency)
- `tests/run-hooks.sh` — new test additions for scan-backlog.sh

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Phase 3: Gaps Report -- gaps-report.sh + /gaps
**Status:** completed
**Completed:** 2026-03-02
**Decision IDs:** DEC-BL-GAPS-001
**Requirements:** REQ-P0-004
**Issues:** #83
**Definition of Done:**
- REQ-P0-004 satisfied: /gaps produces unified accountability report with open issues, untracked markers, decision drift, and summary score

##### Planned Decisions
- DEC-BL-GAPS-001: Standalone gaps-report.sh aggregating multiple data sources — unified accountability view — Addresses: REQ-P0-004

##### Work Items

**W3-0: Create scripts/gaps-report.sh — unified accountability aggregator**
- Section 1: Open Backlog Issues — `gh issue list --label claude-todo --state open` formatted as table
- Section 2: Untracked Code Markers — call `scan-backlog.sh --json`, filter to untracked only
- Section 3: Decision Drift — read `.plan-drift` file (written by stop.sh surface section), format unplanned/unimplemented counts
- Section 4: Staleness — issues older than 14 days (configurable via STALE_THRESHOLD_DAYS env var)
- Section 5: Summary Score — weighted score: open_issues * 1 + untracked_markers * 2 + drift_count * 3 + stale_count * 1 (lower is better)
- Output format: markdown sections with tables, human-readable
- Also support `--json` for machine-readable output

**W3-1: Create commands/gaps.md — /gaps command**
- No arguments: full gaps report
- `--json`: machine-readable output
- `--section <name>`: only show specific section (issues, markers, drift, staleness, score)
- Present results to user and suggest remediation actions for worst gaps

**W3-2: Integration with existing stop.sh surface data**
- Read `.plan-drift` for decision drift counts (already written by stop.sh lines 367-377)
- Read `.doc-drift` for documentation freshness data (already written by stop.sh lines 380-391)
- Read `.audit-log` for historical gap trends (already written by stop.sh lines 355-364)
- No modifications to stop.sh needed — just consume its output files

**W3-3: Tests for gaps-report.sh**
- Test: report includes all 5 sections with correct formatting
- Test: summary score calculation is correct
- Test: report handles missing .plan-drift gracefully (no surface data = skip drift section)
- Test: report handles missing scan-backlog.sh gracefully (degraded mode)
- Test: JSON output format is valid

##### Dispatch Plan
- Dispatch 1: W3-0, W3-1, W3-2, W3-3 (tightly coupled — report + command + integration + tests)

##### Critical Files
- `scripts/gaps-report.sh` — new file, the unified accountability aggregator
- `commands/gaps.md` — new file, /gaps command wrapper
- `scripts/scan-backlog.sh` — called as subprocess for marker scanning (Phase 2 dependency)
- `.plan-drift` — consumed for decision drift data (written by stop.sh)
- `.doc-drift` — consumed for documentation freshness data (written by stop.sh)
- `tests/run-hooks.sh` — new test additions for gaps-report.sh

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Backlog Auto-Capture Worktree Strategy

Main is sacred. Each phase works in its own worktree:
- **Phase 1:** `~/.claude/.worktrees/backlog-foundation` on branch `feature/backlog-foundation`
- **Phase 2:** `~/.claude/.worktrees/backlog-scanner` on branch `feature/backlog-scanner`
- **Phase 3:** `~/.claude/.worktrees/backlog-gaps` on branch `feature/backlog-gaps`

#### Backlog Auto-Capture References

- Issue #57: Auto-file backlog issues when agents encounter errors (related)
- Issue #38: Timeout wrappers for todo.sh hud and gh run list calls (related)
- `hooks/prompt-submit.sh` — deferral detection (line 239), auto-claim (line 223), todo.sh HUD (line 102)
- `hooks/stop.sh` — surface section (@decision audit, plan drift), session summary (todo counts)
- `hooks/session-init.sh` — todo.sh HUD injection at startup
- `commands/backlog.md` — existing /backlog command (manual creation)
- `.plan-drift` — decision drift state file written by stop.sh
- `.doc-drift` — documentation freshness state file written by stop.sh
- `.audit-log` — historical gap audit log written by stop.sh

### Initiative: Production Reliability Assessment & Remediation
**Status:** active
**Started:** 2026-03-04
**Goal:** Harden the test infrastructure, CI pipeline, and operational hygiene so that the 61-file test suite runs reliably in CI, state files don't accumulate unboundedly, and cross-platform compatibility is verified.

> An audit of the claude-config-pro repository revealed that CI only exercises 9 of 61 standalone test files (validate.yml has a hardcoded list), stderr is silently suppressed in the test harness (hiding real errors), ~39 test files lack cleanup traps, state files (.session-events.jsonl, .hook-timing.log) grow without bound, and orphaned markers accumulate across sessions. Meanwhile, CI runs Ubuntu-only with no macOS coverage despite macOS being the primary development platform. This initiative systematically remediates each finding across five phases.

**Dominant Constraint:** reliability — CI must catch real failures, test infrastructure must not hide errors, operational state must not degrade over time.

#### Goals
- REQ-GOAL-001: All 61 standalone test files run in CI via auto-discovery (not a hardcoded list)
- REQ-GOAL-002: Test infrastructure surfaces real errors instead of suppressing stderr
- REQ-GOAL-003: Operational state files have bounded growth with automatic rotation
- REQ-GOAL-004: CI validates on both Ubuntu and macOS
- REQ-GOAL-005: Documentation (README.md, ARCHITECTURE.md) reflects current repository state

#### Non-Goals
- REQ-NOGO-001: Rewriting the test framework — we fix specific defects, not redesign the harness
- REQ-NOGO-002: Deleting context-lib.sh — it is actively used as a backward-compat shim by run-hooks.sh
- REQ-NOGO-003: Removing duplicate project_hash() — intentionally documented in core-lib.sh for independent sourcing
- REQ-NOGO-004: Deleting "ghost" test stubs — all 61 test files have assertion markers; none are empty
- REQ-NOGO-005: Adding Windows CI — macOS + Ubuntu covers the real user base; Windows is P2 at best

#### Requirements

**Must-Have (P0)**

- REQ-P0-001: CI auto-discovers and runs all test-*.sh files instead of a hardcoded list
  Acceptance: Given a new test file `tests/test-foo.sh` is added, When CI runs, Then it is automatically included without editing validate.yml
- REQ-P0-002: test-helpers.sh run_hook() and run_hook_ec() capture stderr for diagnostic output instead of suppressing it
  Acceptance: Given a hook emits an error to stderr, When run_hook() executes it, Then stderr is captured and available for assertion or diagnostic display (not sent to /dev/null)
- REQ-P0-003: grep-based JSON parsing in test-pre-ask.sh and test-ci-feedback.sh replaced with jq
  Acceptance: Given JSON output from a hook, When the test validates a field, Then it uses jq (not grep) for extraction
- REQ-P0-004: ~39 test files missing cleanup traps have them added
  Acceptance: Given a test file creates temporary files or directories, When the test exits (success or failure), Then cleanup runs via trap
- REQ-P0-005: .session-events.jsonl rotation at 1000 lines
  Acceptance: Given .session-events.jsonl exceeds 1000 lines, When rotation runs, Then the file is truncated to the most recent 1000 lines
- REQ-P0-006: .hook-timing.log rotation
  Acceptance: Given .hook-timing.log exceeds a size threshold, When rotation runs, Then the file is trimmed to recent entries
- REQ-P0-007: Orphaned implementer markers and heartbeat processes cleaned up at session start
  Acceptance: Given stale markers from a crashed session exist, When session-init.sh runs, Then orphaned markers are removed and zombie heartbeat processes are killed
- REQ-P0-008: TTL sentinel scoping uses SESSION_ID instead of PID
  Acceptance: Given a guardian marker with SESSION_ID-based TTL, When the session ends, Then cleanup correctly identifies and removes markers from that session regardless of PID reuse

**Nice-to-Have (P1)**

- REQ-P1-001: macOS CI matrix job in validate.yml
  Criterion: CI runs on both ubuntu-latest and macos-latest; macOS failures are visible but non-blocking initially
- REQ-P1-002: CI timeout increased from default to explicit value preventing hung jobs
  Criterion: validate.yml specifies timeout-minutes for the test job
- REQ-P1-003: shellcheck extended to tests/ and scripts/ directories
  Criterion: CI runs shellcheck on hooks/, tests/, and scripts/ directories

**Future Consideration (P2)**

- REQ-P2-001: Windows CI support
- REQ-P2-002: Test coverage reporting (which hooks have test coverage, which don't)
- REQ-P2-003: Automated test file generation for new hooks

#### Definition of Done

All P0 requirements (001-008) satisfied. CI auto-discovers test files. stderr is captured not suppressed. grep-JSON replaced with jq. Cleanup traps present in all test files that create temp resources. State file rotation operational. Orphan cleanup in session-init.sh. Existing 159-test suite passes with no regressions. README.md and ARCHITECTURE.md updated.

#### Architectural Decisions

- DEC-PROD-001: Auto-discover test files via glob in CI instead of hardcoded list
  Addresses: REQ-GOAL-001, REQ-P0-001.
  Rationale: A hardcoded list silently excludes new test files. `for f in tests/test-*.sh` with a count assertion ensures all files run. The glob pattern is the same one developers use locally. The count assertion catches accidental file exclusions (e.g., gitignore patterns).

- DEC-PROD-002: Capture stderr to a file instead of suppressing with 2>/dev/null
  Addresses: REQ-GOAL-002, REQ-P0-002.
  Rationale: Suppressing stderr hides hook initialization errors, missing dependencies, and bash syntax errors. Redirecting to a temp file (`2>"$stderr_file"`) preserves diagnostic output while keeping stdout clean for JSON validation. Tests can optionally assert on stderr content.

- DEC-PROD-003: Inline rotation in session-init.sh for state files
  Addresses: REQ-GOAL-003, REQ-P0-005, REQ-P0-006.
  Rationale: session-init.sh already runs at session start and handles cleanup. Adding `tail -n 1000` rotation for .session-events.jsonl and .hook-timing.log is O(1) additional work. No daemon or cron needed. Rotation at session start means the files are bounded by 1000 lines + one session's worth of growth.

- DEC-PROD-004: SESSION_ID-based sentinel scoping for TTL markers
  Addresses: REQ-P0-007, REQ-P0-008.
  Rationale: PID-based TTLs break when PIDs are reused (common on macOS where PIDs wrap quickly). SESSION_ID is unique per session and available in the hook environment. Markers tagged with SESSION_ID can be cleaned up precisely at session end without false matches from PID reuse.

- DEC-PROD-005: Non-blocking macOS CI matrix job
  Addresses: REQ-P1-001.
  Rationale: macOS is the primary dev platform but CI has only run Ubuntu. Adding macOS as a matrix entry with `continue-on-error: true` initially surfaces compatibility issues without blocking merges. Once stable, remove the continue-on-error flag.

#### Phase 1: Test Infrastructure Reliability
**Status:** completed
**Completed:** 2026-03-04
**Merge:** b4c9586 (bundled with Phase 2)
**Decision IDs:** DEC-PROD-001, DEC-PROD-002, DEC-PROD-003
**Requirements:** REQ-P0-001, REQ-P0-002, REQ-P0-003, REQ-P0-004
**Outcome:** CI auto-discovers all test-*.sh files via glob, stderr captured to temp file in test-helpers.sh, jq replaces grep-based JSON parsing in test-pre-ask.sh and test-ci-feedback.sh, cleanup traps added to test files.

##### Decision Log
- DEC-PROD-001: Glob-based auto-discovery — Addresses: REQ-P0-001 — **Implemented as planned**
- DEC-PROD-002: stderr capture to temp file — Addresses: REQ-P0-002 — **Implemented as planned**

#### Phase 2: Operational Hygiene
**Status:** completed
**Completed:** 2026-03-04
**Merge:** b4c9586 (bundled with Phase 1)
**Decision IDs:** DEC-PROD-003, DEC-PROD-004
**Requirements:** REQ-P0-005, REQ-P0-006, REQ-P0-007, REQ-P0-008
**Outcome:** State file rotation (session-events.jsonl and hook-timing.log at 1000 lines) in session-init.sh, orphan marker cleanup at session start, TTL sentinels migrated from PID to SESSION_ID.

##### Decision Log
- DEC-PROD-003: Inline rotation in session-init.sh — Addresses: REQ-P0-005, REQ-P0-006 — **Implemented as planned**
- DEC-PROD-004: SESSION_ID-based sentinel scoping — Addresses: REQ-P0-007, REQ-P0-008 — **Implemented as planned**

#### Phase 3: Dead Code Cleanup (Verification Only)
**Status:** planned
**Decision IDs:** (none — verification phase)
**Requirements:** (verification only)
**Issues:** (to be created)
**Definition of Done:**
- Verified: no empty test stubs exist (all 61 test files have assertions)
- Verified: context-lib.sh is actively used (run-hooks.sh backward-compat shim)
- Verified: project_hash() duplication is intentional (documented in core-lib.sh)
- Any actual dead code found during verification is removed

##### Work Items

**W3-1: Verify no empty test stubs remain**
- Run: `for f in tests/test-*.sh; do grep -cE 'assert_|pass |fail |expect' "$f"; done`
- Confirm all files have at least one assertion marker
- If any empty stubs found, delete them (not expected based on audit)

**W3-2: Verify context-lib.sh usage and document**
- Confirm run-hooks.sh sources context-lib.sh
- Confirm no other path to removal exists
- Add a comment to context-lib.sh explaining its role if not already present

**W3-3: Verify project_hash() duplication is intentional**
- Confirm core-lib.sh documents the intentional duplication
- Confirm the two implementations are identical

##### Dispatch Plan
- Dispatch 1: W3-1, W3-2, W3-3 (verification only — quick, parallelizable)

##### Critical Files
- `tests/test-*.sh` — verification targets
- `hooks/context-lib.sh` — verify active usage
- `hooks/core-lib.sh` — verify project_hash() documentation

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Phase 4: Platform & CI Hardening
**Status:** completed
**Completed:** 2026-03-05
**Merge:** 03fe50e (bundled with Phase 5)
**Decision IDs:** DEC-PROD-005
**Requirements:** REQ-P1-001, REQ-P1-002, REQ-P1-003
**Outcome:** macOS added to CI matrix (continue-on-error), explicit timeout-minutes in validate.yml, shellcheck extended to tests/ and scripts/. Portable SHA-256 detection (e50930a) fixed cross-platform CI compatibility.

##### Decision Log
- DEC-PROD-005: Non-blocking macOS CI — Addresses: REQ-P1-001 — **Implemented as planned**

#### Phase 5: Documentation Freshness
**Status:** completed
**Completed:** 2026-03-05
**Merge:** 03fe50e (bundled with Phase 4)
**Decision IDs:** (none — documentation update)
**Requirements:** REQ-GOAL-005
**Outcome:** README.md and ARCHITECTURE.md updated to reflect current hook count, test count, directory structure, lazy-loading pattern, and state management architecture.

##### Decision Log
- Documentation updated to reflect current repository state — **Implemented as planned**

#### Production Reliability Worktree Strategy

Main is sacred. Each phase works in its own worktree:
- **Phase 1:** `~/.claude/.worktrees/prod-test-infra` on branch `feature/prod-test-infra`
- **Phase 2:** `~/.claude/.worktrees/prod-operational-hygiene` on branch `feature/prod-operational-hygiene`
- **Phase 3:** `~/.claude/.worktrees/prod-dead-code-verify` on branch `feature/prod-dead-code-verify`
- **Phase 4:** `~/.claude/.worktrees/prod-ci-hardening` on branch `feature/prod-ci-hardening`
- **Phase 5:** `~/.claude/.worktrees/prod-docs-freshness` on branch `feature/prod-docs-freshness`

Note: Phase 1 and Phase 2 can run in parallel (no dependencies). Phase 3 is a quick verification pass. Phase 4 depends on Phase 1 (CI changes build on auto-discovery). Phase 5 runs last (captures all changes).

#### Production Reliability References

- Audit source: Production reliability assessment (2026-03-04)
- `.github/workflows/validate.yml` — current CI configuration with hardcoded 9-file test list
- `tests/lib/test-helpers.sh` — test harness with stderr suppression (lines 87, 99)
- `tests/test-pre-ask.sh` — grep-based JSON parsing target
- `tests/test-ci-feedback.sh` — grep-based JSON parsing target
- `hooks/session-init.sh` — rotation and orphan cleanup target
- `hooks/task-track.sh` — TTL sentinel scoping target
- `.session-events.jsonl` — unbounded growth state file
- `.hook-timing.log` — unbounded growth state file

### Initiative: Operational Mode System
**Status:** active
**Started:** 2026-03-05
**Goal:** Introduce proportional governance by classifying work into 4 operational modes (Observe/Amend/Patch/Build) so that lightweight tasks skip heavyweight infrastructure while maintaining all safety invariants.

> The Claude Code deterministic harnessing framework enforces a single operational envelope (full Planner-Implementer-Tester-Guardian pipeline with worktrees) for ALL work. This creates 3-10x overhead for 60-70% of sessions that are NOT feature development -- research, config edits, backlog management, small fixes. The system already has ad-hoc exemptions (is_claude_meta_repo(), DISPATCH.md trivial-edit rules) proving one-size governance doesn't fit all work. This initiative replaces ad-hoc bypasses with a principled mode taxonomy enforced at the hook level, with monotonic escalation ensuring tasks can only become MORE governed, never less.

**Dominant Constraint:** reliability -- modes must never cause false allows (permitting unauthorized state changes or bypassing safety invariants). Conservative default to Mode 4 when classification is ambiguous.

#### Goals
- REQ-GOAL-001: Proportional governance -- overhead ratio < 0.5 for Mode 1-2 tasks vs current full-pipeline overhead
- REQ-GOAL-002: Transparent classification -- mode visible in statusline, transitions logged in audit trail
- REQ-GOAL-003: Safety confidence -- zero safety-invariant violations across all modes
- REQ-GOAL-004: Reduced token cost -- 40% reduction for non-feature sessions via skipped heavyweight components
- REQ-GOAL-005: Faster adoption -- first-session success rate improvement by removing friction for simple tasks

#### Non-Goals
- REQ-NOGO-001: User-selectable mode switching -- auto-classify only; user override is escape hatch not primary interface
- REQ-NOGO-002: Per-project mode configuration -- universal classification rules; project-specific overrides are P2
- REQ-NOGO-003: Reducing hook execution for Mode 4 (Build) -- unchanged heavyweight path; modes only lighten lower tiers
- REQ-NOGO-004: Automatic mode downgrade -- escalation only, never de-escalation within a session
- REQ-NOGO-005: Replacing the agent system -- modes augment dispatch routing, not replace Planner/Implementer/Tester/Guardian

#### Requirements

**Must-Have (P0)**

- REQ-P0-001: Mode taxonomy defined -- 4 discrete modes with clear boundaries, triggers, risk profiles, and escalation rules
  Acceptance: Given the mode taxonomy document, When a developer reads it, Then each mode has a one-line description, example triggers, risk profile, component contract, and boundary rules for escalation
- REQ-P0-002: Dispatch auto-selects mode -- classification heuristics in prompt-submit.sh with conservative fallback
  Acceptance: Given a user prompt "update the README", When prompt-submit.sh classifies it, Then .op-mode contains "2" (Amend); Given an ambiguous prompt, When classification fails, Then .op-mode defaults to "4" (Build)
- REQ-P0-003: Component contracts specified -- each mode defines which components engage (worktree, tester, guardian, hooks, approval gates)
  Acceptance: Given Mode 1 (Observe), When an agent runs, Then no worktree created, no tester dispatched, no guardian needed, branch-guard skipped; Given Mode 4 (Build), When an agent runs, Then full pipeline engaged (identical to current behavior)
- REQ-P0-004: Monotonic escalation -- mode can only increase during a session, never decrease
  Acceptance: Given .op-mode = 2 (Amend), When is_source_file() detects a source write, Then .op-mode escalates to 3 (Patch) or 4 (Build); Given .op-mode = 3, When write_op_mode(2) is called, Then the write is rejected
- REQ-P0-005: Cross-mode safety invariants -- 9 invariants that hold regardless of mode (nuclear deny, /tmp redirect, force-push protection, etc.)
  Acceptance: Given Mode 1 (Observe), When an agent attempts `rm -rf /`, Then guard.sh denies it (identical behavior to Mode 4)
- REQ-P0-006: Mode state persisted in .op-mode file -- registered in protected state file registry, atomic writes
  Acceptance: Given .op-mode is written, When pre-write.sh Gate 0 checks it, Then direct Write/Edit tool access is denied; Given concurrent write_op_mode() calls, Then atomic_write() prevents corruption

**Nice-to-Have (P1)**

- REQ-P1-001: Statusline mode display -- current mode shown as compact indicator (e.g., `M1:observe`)
  Criterion: statusline.sh reads .op-mode and renders mode indicator in Line 1
- REQ-P1-002: Mode-aware turn budgets -- lighter modes get smaller max_turns allocation
  Criterion: DISPATCH.md turn budget tables conditioned on mode; Mode 1 max_turns=15, Mode 2 max_turns=25
- REQ-P1-003: Mode-aware session summary -- stop.sh skips heavyweight surface logic in Mode 1-2
  Criterion: stop.sh reads .op-mode; Modes 1-2 skip @decision drift scan and plan-drift computation
- REQ-P1-004: Classification fast-path -- prompt-submit.sh short-circuits non-matching modes in <5ms
  Criterion: Mode 1/2 classification adds <5ms to prompt-submit.sh execution time

**Future Consideration (P2)**

- REQ-P2-001: Per-project mode overrides via .claude/modes.json
- REQ-P2-002: Mode analytics -- which modes are used most, escalation frequency, false classification rate
- REQ-P2-003: Mode-aware cost estimation -- predict session cost based on mode selection
- REQ-P2-004: LLM-assisted classification for ambiguous prompts (beyond keyword heuristics)

#### Definition of Done

All P0 requirements (001-006) satisfied. 4-tier mode taxonomy documented in docs/MODES.md. Classifier in prompt-submit.sh writes .op-mode. All 4 hooks (pre-write.sh, pre-bash.sh, prompt-submit.sh, stop.sh) read .op-mode and conditionally engage gates. Monotonic escalation enforced. 9 safety invariants verified as mode-independent. .op-mode registered in _PROTECTED_STATE_FILES. Existing test suite passes with no regressions. New mode-specific tests for classification, escalation, and hook integration.

#### Architectural Decisions

- DEC-MODE-TAXONOMY-001: 4-tier mode taxonomy (Observe/Amend/Patch/Build) with monotonic escalation
  Addresses: REQ-P0-001.
  Rationale: Maps to 4 distinct risk profiles. Mode 1 (Observe): read-only, no writes, no commits. Mode 2 (Amend): non-source writes (docs, config), guardian approval, no worktree. Mode 3 (Patch): source writes, testing required, optional worktree for <3 files. Mode 4 (Build): full pipeline (current behavior). Validated by deep research: monotonic escalation lattice is industry standard in safety-critical systems.

- DEC-MODE-STATE-001: .op-mode state file with monotonic write_op_mode() in state-lib.sh
  Addresses: REQ-P0-006.
  Rationale: Pipe-delimited format (mode|confidence|timestamp|reason) enables both hook reads and audit. Monotonic enforcement via ordinal comparison in write_op_mode(). Registered in _PROTECTED_STATE_FILES to close Write-tool loophole. atomic_write() for crash safety. Same proven pattern as .proof-status.

- DEC-MODE-CLASSIFY-001: Deterministic classifier in prompt-submit.sh with keyword heuristics
  Addresses: REQ-P0-002.
  Rationale: prompt-submit.sh already runs on every user prompt and has keyword detection (grep -qiE for deferral language). Adding mode classification here is zero-additional-hook-cost. Conservative fallback to Mode 4 on ambiguity prevents false allows. Classification signals: file types mentioned, action verbs (read/review vs edit/fix vs build/implement), scope indicators.

- DEC-MODE-CONTRACT-001: Component contract matrix enforced at hook level via .op-mode reads
  Addresses: REQ-P0-003.
  Rationale: Each hook reads .op-mode at entry and conditionally engages gates per the contract matrix. Mode 1: skip branch-guard, plan-check, test-gate, doc-gate. Mode 2: skip branch-guard for non-source, skip plan-check, skip test-gate. Mode 3: skip plan-check (unless plan exists), engage all others. Mode 4: unchanged. Assume-guarantee reasoning: each mode's skipped checks are valid ONLY because the mode's assumptions guarantee those checks are unnecessary.

- DEC-MODE-ESCALATE-001: One-way escalation engine with 10 trigger rules across 4 hooks
  Addresses: REQ-P0-004.
  Rationale: Escalation is irreversible within a session. Triggers: is_source_file() write -> escalate to Mode 3+, worktree creation -> escalate to Mode 4, git commit -> escalate to Mode 2+, multiple file edits -> escalate to Mode 3+. Anti-gaming: is_source_file() is authoritative (extension-based, not model judgment), classification failure defaults to Mode 4, audit trail for every escalation in .audit-log.

- DEC-MODE-SAFETY-001: 9 cross-mode safety invariants, never mode-conditional
  Addresses: REQ-P0-005.
  Rationale: Layer 1 enforcement (guard.sh) fires unconditionally across all modes. Invariants: (1) nuclear deny (rm -rf /, dd), (2) /tmp redirect, (3) force-push protection, (4) destructive git protection, (5) cd-into-worktree deny, (6) env modification deny, (7) hook bypass deny (--no-verify), (8) credential file protection, (9) sandbox enforcement. Deep research validates: agent exploitation of lightweight paths is documented; invariants must be mode-independent.

- DEC-MODE-PERSIST-001: Re-classify mode after compaction with Previous Mode hint
  Addresses: REQ-P0-002, REQ-P0-006.
  Rationale: Monotonic lattice prevents downgrade, but fresh classification after compaction is safer than carrying stale state. compact-preserve.sh includes "Previous Mode: N" hint that biases the classifier. If re-classification yields a lower mode, the lattice enforces the higher previous mode.

- DEC-MODE-BRANCH-001: Mode 2 relaxes branch-guard for all non-source files; Guardian is sufficient
  Addresses: REQ-P0-003.
  Rationale: Branch-guard's purpose is preventing accidental source writes, not gating all writes. Guardian approval sees the full diff. Adding a "protected non-source" list creates maintenance burden for marginal safety gain. settings.json is already protected by _PROTECTED_STATE_FILES registry if needed.

- DEC-MODE-PLAN-001: Mode 3 plan-check skip via .op-mode hook-level read
  Addresses: REQ-P0-003.
  Rationale: Plan-check reads .op-mode; if Mode 3, it skips "MASTER_PLAN.md required" deny but still enforces staleness advisory if plan exists. All mode state flows through .op-mode file, keeping the check mechanism consistent with other mode-aware gates.

#### Waves

##### Initiative Summary
- **Total items:** 15
- **Critical path:** 5 waves (W1 -> W2 -> W3 -> W4 -> W5)
- **Max width:** 4 (Wave 3)
- **Gates:** 2 review (W1, W5), 3 approve (W2, W3, W4)

##### Wave 1: Foundation (no dependencies)
**Issues:** #114
**Parallel dispatches:** 1 (tightly coupled)

**W1-1: Mode taxonomy document -- docs/MODES.md** -- Weight: M, Gate: review
- Create `docs/MODES.md` with 4-mode taxonomy: Mode 1 (Observe), Mode 2 (Amend), Mode 3 (Patch), Mode 4 (Build)
- Each mode: one-line description, example triggers, risk profile, component contract table, escalation triggers
- Component contract matrix: rows = modes, columns = worktree/tester/guardian/branch-guard/plan-check/test-gate/doc-gate
- Escalation boundary rules: what promotes each mode to the next
- **Integration:** Referenced by CLAUDE.md (add to Resources table), DISPATCH.md (mode-aware routing), and all hooks that read .op-mode

**W1-2: .op-mode state file infrastructure** -- Weight: M, Gate: review
- Add `write_op_mode()` to `hooks/state-lib.sh`: validates mode 1-4, enforces monotonic (ordinal comparison), atomic_write()
- Add `read_op_mode()` to `hooks/state-lib.sh`: returns current mode or default "4" if .op-mode missing
- Format: `mode|confidence|timestamp|reason` (e.g., `2|high|2026-03-05T19:00:00|prompt-classify:docs-only`)
- Register `.op-mode` in `_PROTECTED_STATE_FILES` array in `hooks/core-lib.sh`
- Add `require_mode` to `hooks/source-lib.sh` for lazy loading of mode functions
- **Integration:** `hooks/core-lib.sh` _PROTECTED_STATE_FILES array, `hooks/source-lib.sh` require_mode(), `hooks/state-lib.sh` new functions

**W1-3: Cross-mode safety invariants documentation** -- Weight: S, Gate: review
- Document the 9 safety invariants in `docs/MODES.md` with explicit "these NEVER change based on mode"
- Cross-reference each invariant to its enforcement point (guard.sh line numbers)
- Verify each invariant is already mode-independent in current code (should be -- guard.sh has no mode awareness today)
- **Integration:** `docs/MODES.md` safety invariants section

**W1-4: Foundation tests** -- Weight: M, Gate: review
- Test: write_op_mode() accepts modes 1-4, rejects 0, 5, "invalid"
- Test: write_op_mode() enforces monotonic (2 -> 3 ok, 3 -> 2 denied)
- Test: read_op_mode() returns 4 when .op-mode missing (conservative default)
- Test: .op-mode is in _PROTECTED_STATE_FILES registry
- Test: atomic_write() produces valid pipe-delimited format
- **Integration:** `tests/run-hooks.sh` or new `tests/test-op-mode.sh`

##### Dispatch Plan
- Dispatch 1: W1-1, W1-2, W1-3, W1-4 (tightly coupled -- taxonomy + state + invariants + tests)

##### Wave 2: Classification (depends on Wave 1)
**Issues:** #115
**Parallel dispatches:** 1 (tightly coupled)
**Blocked by:** Wave 1 (#114) -- needs write_op_mode/read_op_mode

**W2-1: Mode classifier in prompt-submit.sh** -- Weight: L, Gate: approve, Deps: W1-2
- Add classification function `classify_op_mode()` to prompt-submit.sh (or a new mode-lib.sh)
- Keyword heuristics for each mode:
  - Mode 1 signals: "read", "review", "explain", "show", "list", "what is", "how does", "research", "analyze"
  - Mode 2 signals: "update README", "edit config", "fix typo", "documentation", "settings", "CLAUDE.md"
  - Mode 3 signals: "fix bug", "small change", "patch", "quick fix", "one-liner", combined with file-type detection
  - Mode 4 signals: "implement", "build", "feature", "refactor", "new file", "initiative", "plan"
- Conservative: ambiguous -> Mode 4. Multi-signal conflict -> higher mode wins.
- Write result via write_op_mode() on first prompt of session
- Subsequent prompts: re-classify but lattice prevents downgrade
- **Integration:** `hooks/prompt-submit.sh` main flow, calls write_op_mode() from state-lib.sh

**W2-2: Compaction persistence** -- Weight: S, Gate: approve, Deps: W1-2
- Modify `commands/compact.md` (or context-preservation skill) to include "Previous Mode: N" in preserved context
- After compaction, prompt-submit.sh re-classifies with bias: if re-classification < previous mode, use previous
- **Integration:** `commands/compact.md` or `skills/context-preservation/`, `hooks/prompt-submit.sh`

**W2-3: Classification tests** -- Weight: M, Gate: approve, Deps: W2-1
- Test: "explain how hooks work" -> Mode 1
- Test: "update the README" -> Mode 2
- Test: "fix the typo in line 5 of statusline.sh" -> Mode 3 (source file detected)
- Test: "implement the new feature from issue #42" -> Mode 4
- Test: ambiguous prompt -> Mode 4 (conservative)
- Test: re-classification respects monotonic lattice
- Test: compaction preserves mode hint
- **Integration:** `tests/test-op-mode.sh` or `tests/test-mode-classify.sh`

##### Dispatch Plan
- Dispatch 1: W2-1, W2-2, W2-3 (classifier + persistence + tests)

##### Wave 3: Hook Integration (depends on Waves 1+2)
**Issues:** #116
**Parallel dispatches:** 2 (hook changes + dispatch gating can parallelize)
**Blocked by:** Wave 2 (#115) -- needs classifier writing .op-mode

**W3-1: pre-write.sh mode-aware gates** -- Weight: L, Gate: approve, Deps: W2-1
- Read .op-mode at entry (via read_op_mode())
- Mode 1 (Observe): deny ALL writes (not just source) with message "Mode 1 (Observe) does not allow writes. Escalate to Mode 2+ first."
- Mode 2 (Amend): skip branch-guard for non-source files (is_source_file() returns false), keep Gate 0 (protected state files), skip plan-check, skip test-gate
- Mode 3 (Patch): skip plan-check (unless plan exists and is stale), engage branch-guard, test-gate, doc-gate as normal
- Mode 4 (Build): unchanged (current behavior)
- **Integration:** `hooks/pre-write.sh` gates 1-5, read_op_mode() from state-lib.sh

**W3-2: pre-bash.sh mode-aware behavior** -- Weight: M, Gate: approve, Deps: W2-1
- Read .op-mode at entry
- Mode 1: if command has write intent (mkdir, touch, >, >>, tee, mv, cp), escalate to Mode 2 via write_op_mode() and inject advisory
- Mode 2: if command creates/modifies source files, escalate to Mode 3+
- Mode 3-4: unchanged
- **Integration:** `hooks/pre-bash.sh` main flow, write_op_mode() from state-lib.sh

**W3-3: Dispatch mode validation** -- Weight: M, Gate: approve, Deps: W2-1
- Add mode check to `docs/DISPATCH.md` routing rules
- Mode 1: only Planner agent allowed (no Implementer, no Tester, no Guardian)
- Mode 2: Guardian allowed (for commits), no Implementer (no source writes), no Tester (no source to test)
- Mode 3: all agents allowed, worktree optional for <3 source files
- Mode 4: all agents required, worktree mandatory
- Enforcement: task-track.sh validates mode before agent dispatch
- **Integration:** `docs/DISPATCH.md` routing table, `hooks/task-track.sh` dispatch validation

**W3-4: Hook integration tests** -- Weight: L, Gate: approve, Deps: W3-1, W3-2, W3-3
- Matrix tests: 4 modes x key operations (write source, write docs, bash command, agent dispatch)
- Mode 1 + write source -> denied
- Mode 1 + write docs -> denied
- Mode 2 + write source -> escalation to Mode 3+
- Mode 2 + write docs -> allowed, branch-guard skipped
- Mode 3 + write source -> allowed, branch-guard engaged
- Mode 4 + write source -> allowed (current behavior unchanged)
- Verify: all 9 safety invariants active in Mode 1 (guard.sh tests)
- **Integration:** `tests/test-op-mode-hooks.sh` (new test file)

##### Dispatch Plan
- Dispatch 1: W3-1, W3-2, W3-3 (hook modifications -- can be batched, 3 files)
- Dispatch 2: W3-4 (integration tests -- depends on all hook changes)

##### Wave 4: Escalation Engine (depends on Waves 1+2+3)
**Issues:** #117
**Parallel dispatches:** 1 (tightly coupled)
**Blocked by:** Wave 3 (#116) -- needs mode-aware hooks in place

**W4-1: Escalation triggers across hooks** -- Weight: L, Gate: approve, Deps: W3-1, W3-2
- Consolidate escalation logic into `escalate_mode()` function in state-lib.sh
- escalate_mode(target_mode, reason): validates target > current, writes .op-mode, logs to .audit-log
- Trigger rules (10 total):
  1. is_source_file() write in pre-write.sh -> Mode 3+
  2. Worktree creation (EnterWorktree tool) -> Mode 4
  3. Git commit command in pre-bash.sh -> Mode 2+
  4. Multiple source file edits (>2 files) -> Mode 4
  5. Agent dispatch (Implementer) -> Mode 4
  6. Agent dispatch (Tester) -> Mode 3+
  7. Agent dispatch (Guardian) -> Mode 2+
  8. Plan creation/amendment -> Mode 4
  9. Test execution -> Mode 3+
  10. Force push attempt -> Mode 4
- **Integration:** `hooks/state-lib.sh` escalate_mode(), `hooks/pre-write.sh`, `hooks/pre-bash.sh`, `hooks/prompt-submit.sh`, `hooks/task-track.sh`

**W4-2: Monotonic lattice enforcement + anti-gaming** -- Weight: M, Gate: approve, Deps: W4-1
- write_op_mode() rejects downward transitions (already in W1-2, but harden)
- Anti-gaming measures:
  - is_source_file() is authoritative (extension check, not model judgment)
  - No "suggest mode" interface for the model -- classification is hook-only
  - .op-mode in _PROTECTED_STATE_FILES -- model cannot directly write it
  - Audit every escalation with timestamp, trigger, previous mode, new mode
- **Integration:** `hooks/state-lib.sh` write_op_mode() hardening

**W4-3: Escalation audit logging** -- Weight: S, Gate: approve, Deps: W4-1
- Every escalation appends to `.audit-log`: `[timestamp] MODE_ESCALATION: mode_from -> mode_to | trigger: reason | file: path`
- Format compatible with existing .audit-log entries (stop.sh already writes to it)
- **Integration:** `.audit-log` (existing file), `hooks/state-lib.sh` escalate_mode()

**W4-4: Escalation path tests** -- Weight: M, Gate: approve, Deps: W4-1, W4-2
- Test: source write escalates Mode 1 -> Mode 3
- Test: worktree creation escalates Mode 2 -> Mode 4
- Test: git commit escalates Mode 1 -> Mode 2
- Test: downgrade attempt rejected (Mode 3 -> Mode 2)
- Test: anti-gaming -- Write tool to .op-mode denied by Gate 0
- Test: audit log entries present after escalation
- Test: multiple escalations in one session produce correct final mode
- **Integration:** `tests/test-op-mode-escalation.sh` (new test file)

##### Dispatch Plan
- Dispatch 1: W4-1, W4-2, W4-3, W4-4 (tightly coupled -- escalation engine + tests)

##### Wave 5: Polish (P1 items, depends on Wave 4)
**Issues:** #118
**Parallel dispatches:** 2
**Blocked by:** Wave 4 (#117) -- needs escalation engine

**W5-1: Statusline mode display** -- Weight: S, Gate: review, Deps: W4-1
- Add mode indicator to statusline Line 1: `M1:observe` / `M2:amend` / `M3:patch` / `M4:build`
- Read .op-mode via read_op_mode() in statusline.sh
- Position: after model name, before project name (leftmost indicator after model)
- Color: Mode 1 green (safe), Mode 2 yellow (caution), Mode 3 orange (elevated), Mode 4 red (full)
- **Integration:** `scripts/statusline.sh` render function, read_op_mode() from state-lib.sh

**W5-2: Mode-aware turn budgets** -- Weight: S, Gate: review, Deps: W4-1
- Update `docs/DISPATCH.md` with mode-conditioned turn budgets:
  - Mode 1: max_turns=15 (read-only, short sessions)
  - Mode 2: max_turns=25 (config/docs, moderate)
  - Mode 3: max_turns=50 (patch work, substantial)
  - Mode 4: max_turns=85 (unchanged, full feature)
- **Integration:** `docs/DISPATCH.md` turn budget table

**W5-3: Mode-aware stop.sh** -- Weight: M, Gate: review, Deps: W4-1
- Read .op-mode in stop.sh
- Mode 1-2: skip @decision drift scan (no source files modified), skip plan-drift computation
- Mode 3: run @decision scan only on modified files (not full codebase)
- Mode 4: unchanged (current behavior)
- **Integration:** `hooks/stop.sh` surface section

**W5-4: Classification fast-path optimization** -- Weight: S, Gate: review, Deps: W2-1
- Optimize classify_op_mode() to short-circuit for clear Mode 1/2 signals in <5ms
- Benchmark: measure prompt-submit.sh latency with and without classifier
- Target: <5ms additional latency for Mode 1/2 classification
- **Integration:** `hooks/prompt-submit.sh` classify_op_mode()

##### Dispatch Plan
- Dispatch 1: W5-1, W5-2 (statusline + dispatch docs -- independent, lightweight)
- Dispatch 2: W5-3, W5-4 (stop.sh + optimization -- independent but related to hooks)

##### Critical Files
- `docs/MODES.md` -- mode taxonomy, component contracts, safety invariants (new file)
- `hooks/state-lib.sh` -- write_op_mode(), read_op_mode(), escalate_mode()
- `hooks/core-lib.sh` -- _PROTECTED_STATE_FILES registry addition
- `hooks/source-lib.sh` -- require_mode() lazy loading
- `hooks/prompt-submit.sh` -- classify_op_mode() classifier
- `hooks/pre-write.sh` -- mode-aware gate conditionals
- `hooks/pre-bash.sh` -- mode-aware escalation triggers
- `hooks/task-track.sh` -- dispatch mode validation
- `hooks/stop.sh` -- mode-aware surface logic
- `scripts/statusline.sh` -- mode display indicator
- `docs/DISPATCH.md` -- mode-aware routing and turn budgets

##### Decision Log
<!-- Guardian appends here after wave completion -->

#### Operational Mode System Worktree Strategy

Main is sacred. Each wave works in its own worktree:
- **Wave 1:** `~/.claude/.worktrees/mode-foundation` on branch `feature/mode-foundation`
- **Wave 2:** `~/.claude/.worktrees/mode-classifier` on branch `feature/mode-classifier`
- **Wave 3:** `~/.claude/.worktrees/mode-hooks` on branch `feature/mode-hooks`
- **Wave 4:** `~/.claude/.worktrees/mode-escalation` on branch `feature/mode-escalation`
- **Wave 5:** `~/.claude/.worktrees/mode-polish` on branch `feature/mode-polish`

Note: Waves are strictly serial (W1 -> W2 -> W3 -> W4 -> W5). Within each wave, dispatch plan specifies parallelism.

#### Operational Mode System References

- Issue #109: Design operational mode system for safe non-dev actions and scaled component dispatch
- PRD: `prds/operational-mode-system.md` (620 lines, deep research validated)
- `hooks/pre-write.sh` -- current gate structure (6 gates: branch-guard, plan-check, test-gate, mock-gate, doc-gate, checkpoint)
- `hooks/pre-bash.sh` -- current command validation
- `hooks/prompt-submit.sh` -- current keyword detection (deferral language, mode classification target)
- `hooks/guard.sh` -- Layer 1 safety invariants (mode-independent)
- `hooks/core-lib.sh` -- is_source_file(), SOURCE_EXTENSIONS, _PROTECTED_STATE_FILES
- `hooks/state-lib.sh` -- write_proof_status(), atomic_write() (patterns for write_op_mode)
- `docs/DISPATCH.md` -- current dispatch routing rules
- Deep research validation: 103 citations across 3 providers (OpenAI, Perplexity, Gemini)

### Initiative: Dispatch Enforcement
**Status:** active
**Started:** 2026-03-06
**Goal:** Mechanically enforce that the orchestrator dispatches to subagents instead of writing source code directly, closing the enforcement gap that allowed the orchestrator to bypass the implementer dispatch.

> The orchestrator was observed doing implementation work directly instead of dispatching to the implementer agent. Root cause: (1) the dispatch routing table was extracted from CLAUDE.md to docs/DISPATCH.md, removing the "must invoke implementer" signal from every-turn context, and (2) no hook mechanically prevented orchestrator source writes. Guardian dispatch was the ONLY end-to-end enforced dispatch (pre-bash.sh blocks git commit/merge). This initiative restores the instruction signal and adds mechanical enforcement via SESSION_ID-based orchestrator detection.

**Dominant Constraint:** reliability — false positives (blocking legitimate subagent writes) are worse than false negatives (missing an orchestrator bypass)

#### Goals
- REQ-GOAL-001: Orchestrator never writes source code directly — must dispatch implementer
- REQ-GOAL-002: Dispatch routing table visible to orchestrator every turn
- REQ-GOAL-003: Mechanical hook prevents orchestrator source writes even if instructions ignored

#### Requirements

**Must-Have (P0)**
- REQ-P0-001: Dispatch routing table restored to CLAUDE.md with "Orchestrator May?" column
- REQ-P0-002: session-init.sh records orchestrator CLAUDE_SESSION_ID in .orchestrator-sid
- REQ-P0-003: pre-write.sh Gate 1.5 denies source writes when SESSION_ID matches .orchestrator-sid
- REQ-P0-004: .orchestrator-sid registered in _PROTECTED_STATE_FILES

#### Architectural Decisions
- DEC-DISPATCH-001: Compact routing table restored to CLAUDE.md (addresses REQ-GOAL-002)
- DEC-DISPATCH-002: SESSION_ID-based orchestrator detection (addresses REQ-GOAL-003)
- DEC-DISPATCH-003: Gate 1.5 ordering between branch-guard and plan-check (addresses REQ-P0-003)

#### Phases

##### Phase 1: Wave 1 — Instruction + Infrastructure
**Status:** in-progress
- W1-1: Restore dispatch routing table to CLAUDE.md
- W1-2: session-init.sh writes .orchestrator-sid + core-lib.sh registry + session-end.sh cleanup
- W1-3: pre-write.sh Gate 1.5 — orchestrator source write guard

##### Phase 2: Wave 2 — Tests
**Status:** planned
- W2-1: Tests for orchestrator guard (6 test cases)

#### Dispatch Enforcement Worktree Strategy

- **Wave 1:** `~/.claude/.worktrees/dispatch-enforcement` on branch `feature/dispatch-enforcement`

### Initiative: Cross-Platform Reliability
**Status:** active
**Started:** 2026-03-06
**Goal:** Make CI green on Ubuntu by fixing the `stat` and `timeout` portability bugs, cleaning stale test references, and establishing cross-platform compatibility patterns that prevent recurrence.

> CI fails on Ubuntu because 25 `stat -f %m` calls across 12 hook/script/test files use macOS-first argument order. On Linux, `stat -f %m` succeeds but returns the filesystem mount point (not mtime), causing silent data corruption in every staleness check. Secondary: 10 `timeout` command usages fail on stock macOS (requires coreutils). Tertiary: run-hooks.sh section names reference "context-lib.sh" for functions that moved to core-lib.sh/source-lib.sh, and test-proof-lifecycle.sh has a CYCLE COMPLETE fixture for removed CYCLE_MODE. This initiative fixes all portability issues and establishes canonical helpers to prevent recurrence.

**Dominant Constraint:** reliability — cross-platform correctness must be silent and automatic; no platform-specific branches in calling code

#### Goals
- REQ-GOAL-001: All file mtime checks work correctly on both macOS and Linux
- REQ-GOAL-002: All timeout-guarded operations work on both macOS (no coreutils) and Linux
- REQ-GOAL-003: Test suite passes on Ubuntu CI with zero platform-related failures
- REQ-GOAL-004: Canonical portability helpers prevent future platform-specific inline code

#### Non-Goals
- REQ-NOGO-001: Windows/WSL support — macOS + Linux covers the real user base; Windows is P2 at best
- REQ-NOGO-002: Rewriting the test framework — fix specific portability defects only
- REQ-NOGO-003: Changing stat output semantics beyond mtime — only mtime (epoch seconds) is needed

#### Requirements

**Must-Have (P0)**

- REQ-P0-001: `_file_mtime()` function in core-lib.sh replaces all 25 inline `stat -f %m` patterns
  Acceptance: Given a file on Linux, When `_file_mtime "$file"` is called, Then it returns epoch seconds (not mount point); Given a file on macOS, When called, Then it returns epoch seconds; Given a nonexistent file, When called, Then it returns "0"
- REQ-P0-002: `_with_timeout()` function in core-lib.sh provides portable timeout with Perl fallback
  Acceptance: Given a system without the `timeout` command (stock macOS), When `_with_timeout 5 command args` is called, Then it executes the command with a 5-second timeout using Perl alarm+exec; Given a system with `timeout`, When called, Then it uses the native `timeout` command
- REQ-P0-003: Stale test section names in run-hooks.sh updated to reflect current library locations
  Acceptance: Given run-hooks.sh section names, When inspected, Then they reference the correct current library (core-lib.sh or source-lib.sh), not the old context-lib.sh name
- REQ-P0-004: CYCLE COMPLETE fixture in test-proof-lifecycle.sh removed or replaced
  Acceptance: Given test-proof-lifecycle.sh, When run on Ubuntu CI, Then no assertion fails due to CYCLE_MODE references
- REQ-P0-005: test-ci-feedback.sh and test-clean-state.sh assertion failures resolved
  Acceptance: Given these test files, When run on Ubuntu CI, Then all assertions pass
- REQ-P0-006: SC2116 shellcheck warnings in test files resolved
  Acceptance: Given shellcheck runs on tests/, When SC2116 is checked, Then zero warnings

**Nice-to-Have (P1)**

- REQ-P1-001: Inline documentation in core-lib.sh explaining the portability pattern for future contributors

**Future Consideration (P2)**

- REQ-P2-001: Portability lint rule in CI that flags new `stat -f` or bare `timeout` usage

#### Definition of Done

All P0 requirements (001-006) satisfied. All 25 `stat -f %m` calls replaced with `_file_mtime()`. All 10 `timeout` usages replaced with `_with_timeout()`. Stale test references updated. Full test suite passes on Ubuntu CI. No regressions on macOS.

#### Architectural Decisions

- DEC-XPLAT-001: `_file_mtime()` in core-lib.sh with OS detection at load time
  Addresses: REQ-GOAL-001, REQ-GOAL-004, REQ-P0-001.
  Rationale: OS detection (`uname -s`) runs once when core-lib.sh is sourced, setting a module-level variable. `_file_mtime()` uses the cached OS to select `stat -c %Y` (Linux) or `stat -f %m` (macOS). Linux-first because `stat -c %Y` is the GNU/POSIX-standard flag. Single function replaces 25 inline patterns, preventing recurrence. Alternatives rejected: per-file inline fix (25 maintenance sites), Python-based mtime (adds dependency).

- DEC-XPLAT-002: `_with_timeout()` wrapper using Perl fallback when `timeout` command is missing
  Addresses: REQ-GOAL-002, REQ-GOAL-004, REQ-P0-002.
  Rationale: Stock macOS lacks the `timeout` command (GNU coreutils). Perl is available on all macOS and Linux systems. The wrapper checks for `timeout` in PATH first (faster, native on Linux), falls back to `perl -e 'alarm(shift); exec @ARGV' -- $seconds "$@"`. Zero new dependencies. Alternatives rejected: require brew install coreutils (install burden), background+sleep+kill (race-prone).

- DEC-XPLAT-003: Fix stale test references inline (not suppress)
  Addresses: REQ-P0-003, REQ-P0-004, REQ-P0-005.
  Rationale: run-hooks.sh section names still say "context-lib.sh" but the functions (is_source_file, is_skippable_path, get_git_state, build_resume_directive) moved to core-lib.sh and source-lib.sh during metanoia consolidation. test-proof-lifecycle.sh has a CYCLE COMPLETE fixture for CYCLE_MODE which was removed in de3dc48. Real fixes prevent CI confusion and are consistent with DEC-HOOKS-001 (fix shellcheck violations inline, not suppress).

#### Waves

##### Initiative Summary
- **Total items:** 3
- **Critical path:** 2 waves (W1 -> W2)
- **Max width:** 2 (Wave 1)
- **Gates:** 0 review, 1 approve (W2)

##### Wave 1 (no dependencies)
**Parallel dispatches:** 2

**W1-A: Portability functions and replacement (#119)** — Weight: M, Gate: none
- Add `_file_mtime()` to `hooks/core-lib.sh`:
  - Detect OS once at source time: `_CORE_OS=$(uname -s)`
  - Function body: `case "$_CORE_OS" in Linux) stat -c %Y "$1" 2>/dev/null || echo "0" ;; *) stat -f %m "$1" 2>/dev/null || echo "0" ;; esac`
  - Replace all 25 inline `stat -f %m` patterns across 12 files with `_file_mtime "$file"`
- Add `_with_timeout()` to `hooks/core-lib.sh`:
  - Check: `command -v timeout >/dev/null 2>&1`
  - If available: `timeout "$@"`
  - If not: `perl -e 'alarm(shift); exec @ARGV' -- "$@"`
  - Replace all 10 `timeout N` usages across 5 files with `_with_timeout N`
- Files to modify (12 for stat, 5 for timeout — some overlap):
  - hooks/core-lib.sh (add functions)
  - hooks/session-end.sh (5 stat)
  - hooks/session-init.sh (3 stat)
  - hooks/log.sh (3 stat)
  - hooks/trace-lib.sh (1 stat)
  - hooks/check-guardian.sh (1 stat)
  - hooks/task-track.sh (1 stat)
  - hooks/prompt-submit.sh (1 stat)
  - hooks/pre-bash.sh (2 timeout)
  - scripts/clean-state.sh (4 stat)
  - scripts/worktree-roster.sh (2 stat)
  - scripts/statusline.sh (1 stat)
  - tests/test-state-directory.sh (2 stat)
  - tests/test-self-validation.sh (1 stat)
  - tests/test-proof-lifecycle.sh (5 timeout)
  - tests/test-ci-feedback.sh (1 timeout)
  - tests/test-state-corruption.sh (2 timeout)
- **Integration:** core-lib.sh exports `_file_mtime()` and `_with_timeout()` — all files that source core-lib.sh (directly or via source-lib.sh require_core) get these functions automatically. Test files that don't source core-lib.sh need to source it or inline the function.

**W1-B: Fix stale test references (#120)** — Weight: S, Gate: none
- Update run-hooks.sh section names from "context-lib.sh: X" to the correct current library:
  - `is_source_file()` -> core-lib.sh (where it currently lives)
  - `is_skippable_path()` -> core-lib.sh
  - `get_git_state()` -> core-lib.sh
  - `build_resume_directive()` -> source-lib.sh (or wherever it currently lives)
  - Update section header strings, echo statements, and `should_run_section` calls (~10 references)
- Remove or update CYCLE COMPLETE fixture in test-proof-lifecycle.sh:564
  - CYCLE_MODE was removed in de3dc48 — the test fixture references a feature that no longer exists
  - Either remove the test that depends on it or update it to test current behavior
- Fix test-ci-feedback.sh assertion failures (platform-specific issues)
- Fix test-clean-state.sh assertion failures
- Fix SC2116 shellcheck warnings in test files (useless echo)
- Files to modify:
  - tests/run-hooks.sh (section name updates)
  - tests/test-proof-lifecycle.sh (CYCLE COMPLETE fixture)
  - tests/test-ci-feedback.sh (assertion fixes)
  - tests/test-clean-state.sh (assertion fixes)
  - test files with SC2116 warnings
- **Integration:** No new registrations needed — these are fixes to existing test infrastructure

##### Wave 2 (depends on Wave 1)
**Parallel dispatches:** 1
**Blocked by:** W1-A, W1-B

**W2: CI verification (#121)** — Weight: S, Gate: approve, Deps: W1-A, W1-B
- After W1-A and W1-B are merged to main, push and verify CI passes on both Ubuntu and macOS matrix jobs
- Confirm: all 159+ tests pass on Ubuntu (the primary CI target)
- Confirm: macOS CI job passes (or continues with expected non-blocking failures unrelated to this initiative)
- Confirm: shellcheck clean on hooks/, scripts/, tests/
- If any failures remain, fix them in this wave before declaring the initiative complete
- **Integration:** `.github/workflows/validate.yml` — no changes expected; this wave is verification only

##### Critical Files
- `hooks/core-lib.sh` — `_file_mtime()` and `_with_timeout()` additions (central to this initiative)
- `hooks/session-end.sh` — highest stat occurrence count (5 replacements)
- `hooks/session-init.sh` — 3 stat replacements in critical startup path
- `tests/run-hooks.sh` — stale section name references (10 updates)
- `tests/test-proof-lifecycle.sh` — CYCLE COMPLETE fixture + 5 timeout replacements

##### Decision Log
<!-- Guardian appends here after wave completion -->

#### Cross-Platform Reliability Worktree Strategy

Main is sacred. Each wave dispatches parallel worktrees:
- **Wave 1 W1-A:** `~/.claude/.worktrees/xplat-portability` on branch `feature/xplat-portability`
- **Wave 1 W1-B:** `~/.claude/.worktrees/xplat-test-fixes` on branch `feature/xplat-test-fixes`
- **Wave 2:** Verification on main after merge (no separate worktree)

#### Cross-Platform Reliability References

- Diagnostic trace: `traces/planner-20260306-135544-97dcc0` (full diagnostic analysis)
- CI workflow: `.github/workflows/validate.yml` (Ubuntu + macOS matrix)
- Prior art: DEC-PROD-005 (non-blocking macOS CI from Production Reliability initiative)
- Related: Portable SHA-256 detection (e50930a) — prior cross-platform fix pattern
- `hooks/core-lib.sh` — target for portability functions
- `man stat` — macOS: `-f %m` = mount point on Linux, `-c %Y` = mtime on Linux

---

## Completed Initiatives

| Initiative | Period | Phases | Key Decisions | Archived |
|-----------|--------|--------|---------------|----------|
| Production Remediation (Metanoia Suite) | 2026-02-28 to 2026-03-01 | 5 | DEC-HOOKS-001 thru DEC-TEST-006 | No |
| State Management Reliability | 2026-03-01 to 2026-03-02 | 5 | DEC-STATE-007, DEC-STATE-008 + 8 test decisions | No |
| Hook Consolidation Testing & Streamlining | 2026-03-02 | 4 | DEC-AUDIT-001, DEC-TIMING-001, DEC-DEDUP-001 | No |
| Statusline Information Architecture | 2026-03-02 | 2 | DEC-SL-LAYOUT-001, DEC-SL-TOKENS-001, DEC-SL-TODOCACHE-001, DEC-SL-COSTPERSIST-001 | No |

### Production Remediation (Metanoia Suite) — Summary

Fixed defects left by the metanoia hook consolidation (17 hooks -> 4 entry points + 6 domain libraries). Five phases over 3 days:

1. **CI Green** (919a2f0): Migrated 131 tests to consolidated hooks, 0 failures.
2. **Trace Reliability** (1372603): Shellcheck clean, agent-type-aware classification, compliance.json race fix, repair-traces.sh, 15 trace classification tests.
3. **Planner Reliability** (3796e35): planner.md slimmed 641->389 lines via template extraction, max_turns 40->65, silent dispatch fixes.
4. **State Cleanup** (22aff13): Worktree-roster cleans breadcrumbs on removal, resolve_proof_file falls back gracefully, clean-state.sh audit script.
5. **Validation Harness** (b36f3ad): 20 trace fixtures across 4 agent types x 5 outcomes, validation harness with 95% accuracy gate, regression detection via baseline diffing.

All P0 requirements satisfied. 6 architectural decisions recorded (DEC-HOOKS-001 through DEC-TEST-006). Issues closed: #39, #40, #41, #42.

### State Management Reliability — Summary

Unified all proof-status reads to canonical `resolve_proof_file()` and hardened `validate_state_file()` across the hook system. Five phases over 2 days:

1. **Phase 1 — Proof-Read Unification** (6158a09): task-track.sh, pre-bash.sh, post-write.sh migrated to resolve_proof_file(). #48
2. **Phase 2 — Hardening** (d8dfe39): subagent-start.sh, session-end.sh, stop.sh, prompt-submit.sh migrated; validate_state_file guards all cut sites. #49
3. **Phase 3 — Lifecycle E2E** (a5ad943): 12 lifecycle tests + 6 resolver consistency tests. #50
4. **Phase 4 — Corruption + Concurrency** (dc965d3): 8 corruption tests + 6 concurrency tests. #51
5. **Phase 5 — Clean-state + Session Boundary** (9e16837): 8 clean-state E2E tests + 6 session boundary tests. #52

All 6 P0 requirements satisfied. 28 new tests added (total suite: 159 tests, 0 failures, 3 pre-existing skips). 10 decisions recorded (DEC-STATE-007, DEC-STATE-008, DEC-STATE-001, DEC-STATE-GOV-001, DEC-STATE-LIFECYCLE-001, DEC-STATE-CORRUPT-001, DEC-STATE-CONCURRENT-001, DEC-STATE-CLEAN-E2E-001, DEC-STATE-SESSION-BOUNDARY-001, DEC-STATE-AUDIT-001). Issues closed: #48, #49, #50, #51, #52.

### Hook Consolidation Testing & Streamlining — Summary

Validated, audited, and streamlined the hook system after the lazy-loading performance refactor (`require_*()` in source-lib.sh). Four phases in 1 day:

1. **Phase 1 — Testing & Timing Validation** (#44): 159/159 tests pass, hook-timing-report.sh created with p50/p95/max per hook type, all 11 `--scope` values validated including edge cases.
2. **Phase 2 — Hook Dependency Audit & Deduplication** (#45): Static analysis audit mapped every hook to its minimum required libraries, duplicate `require_*()` calls removed from task-track.sh and other hooks.
3. **Phase 3 — Dead Code Removal & Hot Path** (#46): Dead code paths removed, pre-bash.sh early-exit and pre-write.sh worktree-skip verified optimal, context-lib.sh retained as test/diagnose shim, state registry lint added to test runner.
4. **Phase 4 — Documentation Update** (43b7c5c): HOOKS.md updated with require_*() table and --scope docs, README.md updated with domain library entries and utility scripts, ARCHITECTURE.md rewritten with lazy loading diagram and performance notes.

All 6 P0 requirements satisfied. 3 architectural decisions recorded (DEC-AUDIT-001, DEC-TIMING-001, DEC-DEDUP-001). Issues closed: #44, #45, #46, #47.

### Statusline Information Architecture — Summary

Redesigned the statusline HUD from raw unlabeled numbers to a domain-clustered, labeled two-line display with data enrichment. Two phases in 1 day:

1. **Phase 1 — Rendering Overhaul** (feature/statusline-rendering): Domain-clustered layout with labels on all segments (`dirty:`, `wt:`, `agents:`, `todos:`, `tokens:`), aggregate token display in K/M notation, `~$` cost prefix. +12 tests (39 total). Issues: #71, #67, #68.
2. **Phase 2 — Data Pipeline** (feature/statusline-data, 86c6f59): Todo split display (`todos: 3p 7g` with project/global counts via `gh issue list`), session cost persistence to `.session-cost-history` (pipe-delimited, 100-entry cap), lifetime cost annotation (`Σ~$N.NN`). +9 tests (48 total). Issues: #72, #68, #69.

All 5 P0 requirements satisfied (REQ-P0-001 through REQ-P0-005). P1 cost persistence (REQ-P1-001) also delivered. 4 architectural decisions recorded (DEC-SL-LAYOUT-001, DEC-SL-TOKENS-001, DEC-SL-TODOCACHE-001, DEC-SL-COSTPERSIST-001) plus 8 implementation decisions. Issues closed: #67, #68, #69, #71, #72.

---

## Parked Issues

| Issue | Description | Reason Parked |
|-------|-------------|---------------|
| #15 | ExitPlanMode spin loop fix | Blocked on upstream claude-code#26651 |
| #14 | PreToolUse updatedInput support | Blocked on upstream claude-code#26506 |
| #13 | Deterministic agent return size cap | Blocked on upstream claude-code#26681 |
| #37 | Close Write-tool loophole for .proof-status bypass | **Active** — Phase 0 of Robust State Management |
| #36 | Evaluate Opus for implementer agent | Not in remediation scope |
| #25 | Create unified model provider library | Not in remediation scope |
