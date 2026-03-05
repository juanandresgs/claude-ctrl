# MASTER_PLAN: claude-config-pro

## Identity

**Type:** meta-infrastructure
**Languages:** Bash (85%), Markdown (10%), Python (3%), JSON (2%)
**Root:** /Users/turla/.claude
**Created:** 2026-03-01
**Last updated:** 2026-03-04 (production-reliability initiative added)

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
**Status:** planned
**Decision IDs:** DEC-RSM-FLOCK-001, DEC-RSM-LATTICE-001
**Requirements:** REQ-P0-001, REQ-P0-002, REQ-P0-003
**Issues:** #75, #37
**Definition of Done:**
- REQ-P0-001 partially satisfied: Write/Edit to .proof-status denied (content inspection in pre-write.sh)
- REQ-P0-002 satisfied: write_proof_status() uses flock, concurrent writes are safe
- REQ-P0-003 satisfied: monotonic lattice enforced in write_proof_status()

##### Planned Decisions
- DEC-RSM-FLOCK-001: flock()-based locking for write_proof_status() — sub-ms overhead, crash-safe — Addresses: REQ-P0-002
- DEC-RSM-LATTICE-001: Monotonic lattice enforcement — eliminates verified-to-pending regression — Addresses: REQ-P0-003

##### Work Items

**W0-0: Content inspection in pre-write.sh for .proof-status writes (closes #37)**
- Add Gate 0 at the top of pre-write.sh, before all existing gates
- Pattern match file_path against `*proof-status*` and `*.test-status*`
- emit_deny with explanation pointing to prompt-submit.sh and post-task.sh as authorized paths
- Extend to `.hook-timing.log` (append-only protection)
- 3 test fixtures: Write-to-proof-status deny, Edit-to-proof-status deny, Write-to-test-status deny

**W0-1: Wrap state_update() in flock to fix state.json concurrent jq race**
- In state-lib.sh, acquire flock on state.json.lock before jq read-modify-write
- Subshell-scoped: `(exec {lockfd}>"${file}.lock"; flock -w 5 $lockfd; ... )` pattern
- Timeout 5 seconds, log warning on timeout, continue without update (fail-open for audit layer)

**W0-2: Single flock around write_proof_status() 3-file write**
- In log.sh, wrap all 3 proof-status writes (worktree, project-scoped, legacy) in a single flock
- Lock file: `$CLAUDE_DIR/.proof-status.lock`
- Crash between writes currently leaves inconsistent state; single lock + atomic write per file fixes this

**W0-3: Extend guardian TTL 300s to 600s + add heartbeat renewal**
- In task-track.sh, change TTL constant from 300 to 600
- Add background heartbeat: `while kill -0 $PPID 2>/dev/null; do touch "$marker"; sleep 60; done &`
- Marker touch resets mtime, extending effective TTL while process is alive

**W0-4: Add monotonic lattice enforcement to write_proof_status()**
- Define ordinal map: none=0, needs-verification=1, pending=2, verified=3, committed=4
- Before write, read current state and compare ordinals
- Reject downward transitions (return 1 with log_info warning)
- Exception: epoch reset — if .proof-epoch differs, allow any transition (new work cycle)
- Add .proof-epoch counter file, incremented by session-init.sh at clean start

**W0-5: Add CAS wrapper to prompt-submit.sh**
- Replace direct write_proof_status("verified") with cas_proof_status("pending", "verified")
- cas_proof_status: acquire flock, read current, compare expected, write if match, fail if mismatch
- On mismatch: log warning, do not write (another path already changed state)

##### Dispatch Plan
- Dispatch 1: W0-0, W0-1, W0-2 (protection + locking — pre-write.sh, state-lib.sh, log.sh)
- Dispatch 2: W0-3, W0-4, W0-5 (TTL + lattice + CAS — task-track.sh, log.sh, prompt-submit.sh)

##### Critical Files
- `hooks/pre-write.sh` — Gate 0 for protected state files
- `hooks/state-lib.sh` — flock wrapper for state_update()
- `hooks/log.sh` — write_proof_status() flock + lattice enforcement
- `hooks/task-track.sh` — guardian TTL extension + heartbeat
- `hooks/prompt-submit.sh` — CAS wrapper for proof verification

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Phase 1: Coordination Protocol -- CAS + Protected Registry
**Status:** planned
**Decision IDs:** DEC-RSM-REGISTRY-001, DEC-RSM-FLOCK-001
**Requirements:** REQ-P0-002, REQ-P0-007
**Issues:** #76
**Definition of Done:**
- REQ-P0-007 satisfied: protected state file registry in core-lib.sh, extensible without gate changes
- REQ-P0-002 fully satisfied: state_write_locked() wrapper with CAS semantics in state-lib.sh
- Concurrency tests pass: parallel writes, lock contention, timeout handling

##### Planned Decisions
- DEC-RSM-REGISTRY-001: Protected state file registry array in core-lib.sh — centralized, extensible — Addresses: REQ-P0-007
- DEC-RSM-FLOCK-001: state_write_locked() wrapper — atomic CAS for all state file operations — Addresses: REQ-P0-002

##### Work Items

**W1-0: Protected state file registry in core-lib.sh**
- Define `_PROTECTED_STATE_FILES` array with glob patterns: `*proof-status*`, `*.test-status*`, `*.hook-timing.log`, `*state.json*`
- Add `is_protected_state_file()` function: iterate patterns, return 0 if match
- Pre-write.sh Gate 0 calls `is_protected_state_file "$FILE_PATH"` instead of inline pattern matching
- Registry is append-only: new state files get one line added to the array

**W1-1: state_write_locked() wrapper in state-lib.sh**
- Generic locked write: `state_write_locked FILE_PATH CONTENT [EXPECTED_CONTENT]`
- If EXPECTED_CONTENT provided: CAS semantics (read, compare, write-if-match)
- If not provided: unconditional locked write
- Uses subshell-scoped flock pattern from research
- Timeout: 5s, configurable via STATE_LOCK_TIMEOUT env var

**W1-2: .proof-epoch counter for clean lattice resets**
- In session-init.sh, when starting a new work cycle (no active proof flow), increment .proof-epoch
- write_proof_status() reads epoch before write; if epoch differs from file's recorded epoch, allow any transition
- Prevents stale lattice state from previous work cycles blocking new ones
- Epoch stored in proof-status file: `status|timestamp|epoch`

**W1-3: Concurrency test suite**
- 10 parallel write_proof_status() calls → assert final file is valid (not corrupt)
- CAS contention: 5 parallel cas_proof_status("pending", "verified") → assert exactly 1 succeeds
- Lock timeout: hold lock for 10s, attempt write with 1s timeout → assert timeout handled gracefully
- Lattice enforcement: attempt downward transition → assert rejection
- Epoch reset: change epoch, attempt downward transition → assert allowed

##### Dispatch Plan
- Dispatch 1: W1-0, W1-1, W1-2, W1-3 (tightly coupled — registry, CAS wrapper, epoch, tests)

##### Critical Files
- `hooks/core-lib.sh` — protected state file registry
- `hooks/state-lib.sh` — state_write_locked() CAS wrapper
- `hooks/session-init.sh` — proof-epoch management
- `hooks/log.sh` — write_proof_status() epoch-aware transitions
- `tests/run-hooks.sh` — concurrency test additions

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Phase 2: SQLite State Store -- Replace state.json
**Status:** planned
**Decision IDs:** DEC-RSM-SQLITE-001
**Requirements:** REQ-P0-004
**Issues:** #77
**Definition of Done:**
- REQ-P0-004 satisfied: state.json replaced by SQLite WAL at ~/.claude/state.db
- All state_update/state_read callers migrated to SQLite-backed functions
- Dual-write migration: SQLite primary, dotfiles as fallback
- CAS operations use BEGIN IMMEDIATE instead of flock + jq

##### Planned Decisions
- DEC-RSM-SQLITE-001: SQLite WAL as state store — zero new dependencies, atomic CAS, concurrent-safe — Addresses: REQ-P0-004

##### Work Items

**W2-0: SQLite state store initialization**
- Create `state_db_init()` in state-lib.sh: `sqlite3 "$STATE_DB" "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;"`
- Schema: `state(key TEXT PRIMARY KEY, value TEXT, updated_at INTEGER, source TEXT)`
- History table: `state_history(id INTEGER PRIMARY KEY, key TEXT, value TEXT, source TEXT, ts TEXT)` — capped at 100 per key
- Migration: if state.json exists, import all keys into SQLite on first init

**W2-1: Migrate state_update() to SQLite**
- Replace jq read-modify-write with `INSERT OR REPLACE INTO state`
- History append: `INSERT INTO state_history` with automatic cap
- Remove flock from state_update() (SQLite WAL handles concurrency)
- Fallback: if sqlite3 not available (should not happen on macOS), fall back to jq + flock

**W2-2: Migrate state_read() to SQLite**
- Replace jq query with `SELECT value FROM state WHERE key=?`
- Backward compat: if state.db missing, try state.json
- Performance: SQLite query should be <1ms (indexed key)

**W2-3: Add CAS operation to state-lib.sh via SQLite**
- `state_cas KEY EXPECTED NEW SOURCE`: BEGIN IMMEDIATE, SELECT, compare, UPDATE, COMMIT
- Return "ok" on success, "conflict:$current" on mismatch
- Used by prompt-submit.sh and any future CAS callers

**W2-4: Per-project namespacing in SQLite**
- Key format: `{project_hash}:{key_name}` (e.g., `a1b2c3d4:proof_status`)
- Global keys (no project context): `global:{key_name}`
- `state_update()` and `state_read()` auto-prefix based on `cache_project_context()`

##### Dispatch Plan
- Dispatch 1: W2-0, W2-1, W2-2 (core SQLite migration — init, write, read)
- Dispatch 2: W2-3, W2-4 (CAS + namespacing)

##### Critical Files
- `hooks/state-lib.sh` — complete rewrite: SQLite-backed state_update/state_read/state_cas
- `hooks/source-lib.sh` — require_state() may need adjustment for new deps
- `hooks/session-init.sh` — state.json to SQLite migration on first run
- `tests/run-hooks.sh` — SQLite-specific test additions

##### Decision Log
<!-- Guardian appends here after phase completion -->

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
**Status:** active
**Started:** 2026-03-02
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
**Status:** planned
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
**Status:** planned
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
**Status:** planned
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
**Status:** planned
**Decision IDs:** DEC-PROD-001, DEC-PROD-002, DEC-PROD-003
**Requirements:** REQ-P0-001, REQ-P0-002, REQ-P0-003, REQ-P0-004
**Issues:** (to be created)
**Definition of Done:**
- REQ-P0-001 satisfied: validate.yml uses glob-based auto-discovery for test-*.sh files
- REQ-P0-002 satisfied: run_hook() and run_hook_ec() capture stderr to temp file
- REQ-P0-003 satisfied: test-pre-ask.sh and test-ci-feedback.sh use jq instead of grep for JSON
- REQ-P0-004 satisfied: all test files creating temp resources have cleanup traps

##### Planned Decisions
- DEC-PROD-001: Glob-based test auto-discovery in CI — prevents silent exclusion of new tests — Addresses: REQ-P0-001
- DEC-PROD-002: stderr capture to temp file — surfaces real errors hidden by 2>/dev/null — Addresses: REQ-P0-002

##### Work Items

**W1-1: Replace hardcoded test list in validate.yml with glob auto-discovery**
- Replace the `for test in tests/test-post-task-fallback.sh ...` block with `for test in tests/test-*.sh`
- Add a count assertion: `test_count=$(ls tests/test-*.sh | wc -l); [ "$test_count" -ge 50 ]` as sanity check
- Ensure run-hooks.sh still runs separately (it has its own 159-test suite)
- File: `.github/workflows/validate.yml`

**W1-2: Fix grep-based JSON parsing in test-pre-ask.sh and test-ci-feedback.sh**
- In test-pre-ask.sh: replace grep-based JSON field extraction with jq queries
- In test-ci-feedback.sh: replace grep-based JSON field extraction with jq queries
- Pattern: `echo "$output" | grep 'field'` becomes `echo "$output" | jq -r '.field'`
- Verify tests still pass after replacement
- Files: `tests/test-pre-ask.sh`, `tests/test-ci-feedback.sh`

**W1-3: Fix stderr suppression in test-helpers.sh run_hook() and run_hook_ec()**
- Line 87: change `_stdout=$(echo "$input" | bash "$hook" 2>/dev/null)` to capture stderr to temp file
- Line 99: change `bash "$hook" <<< "$input" > "$_tmp" 2>/dev/null` to capture stderr to temp file
- Add `_stderr` variable available to callers for diagnostic output
- Ensure existing tests still pass (some may implicitly depend on stderr suppression)
- File: `tests/lib/test-helpers.sh`

**W1-4: Add cleanup traps to ~39 test files missing them**
- Identify all test files without `trap` on EXIT/ERR
- Add standard cleanup trap: `cleanup() { rm -rf "$TEST_DIR" 2>/dev/null; }; trap cleanup EXIT`
- Only add to files that create temporary directories or files
- Pattern from existing files with traps (e.g., test-auto-verify.sh)
- Files: ~39 files in `tests/test-*.sh`

##### Dispatch Plan
- Dispatch 1: W1-1, W1-2, W1-3 (CI + JSON + stderr — 3 files, tightly coupled infrastructure)
- Dispatch 2: W1-4 (bulk trap addition — ~39 files, mechanical but large)

##### Critical Files
- `.github/workflows/validate.yml` — CI test discovery
- `tests/lib/test-helpers.sh` — stderr capture (lines 87, 99)
- `tests/test-pre-ask.sh` — grep-to-jq migration
- `tests/test-ci-feedback.sh` — grep-to-jq migration
- `tests/test-*.sh` — ~39 files for cleanup trap addition

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Phase 2: Operational Hygiene
**Status:** planned
**Decision IDs:** DEC-PROD-003, DEC-PROD-004
**Requirements:** REQ-P0-005, REQ-P0-006, REQ-P0-007, REQ-P0-008
**Issues:** (to be created)
**Definition of Done:**
- REQ-P0-005 satisfied: .session-events.jsonl rotated at 1000 lines during session-init
- REQ-P0-006 satisfied: .hook-timing.log rotated during session-init
- REQ-P0-007 satisfied: orphaned markers cleaned at session start
- REQ-P0-008 satisfied: TTL sentinels use SESSION_ID not PID

##### Planned Decisions
- DEC-PROD-003: Inline rotation in session-init.sh — no daemon, no cron, bounded growth — Addresses: REQ-P0-005, REQ-P0-006
- DEC-PROD-004: SESSION_ID-based sentinel scoping — eliminates PID-reuse false matches — Addresses: REQ-P0-007, REQ-P0-008

##### Work Items

**W2-1: Add .session-events.jsonl rotation in session-init.sh**
- At session start, check line count: `wc -l < .session-events.jsonl`
- If > 1000, rotate: `tail -n 1000 .session-events.jsonl > .session-events.jsonl.tmp && mv .session-events.jsonl.tmp .session-events.jsonl`
- Log rotation event to the file itself
- File: `hooks/session-init.sh`

**W2-2: Add .hook-timing.log rotation in session-init.sh**
- Same pattern as W2-1: check line count, rotate if > 1000
- Preserve the most recent entries (tail, not head)
- File: `hooks/session-init.sh`

**W2-3: Orphan marker cleanup in session-init.sh**
- At session start, scan for `.active-guardian-*`, `.active-autoverify-*`, `.active-implementer-*` markers
- For each marker, check if the owning process (PID or SESSION_ID in marker) is still alive
- Remove markers for dead processes
- Kill zombie heartbeat processes (background `touch` loops from task-track.sh)
- File: `hooks/session-init.sh`

**W2-4: Migrate TTL sentinels from PID to SESSION_ID**
- In task-track.sh, write SESSION_ID into guardian/autoverify markers instead of PID
- In session-init.sh cleanup, match by SESSION_ID instead of `kill -0 $PID`
- Backward compat: handle old PID-based markers during transition (check both)
- Files: `hooks/task-track.sh`, `hooks/session-init.sh`

##### Dispatch Plan
- Dispatch 1: W2-1, W2-2, W2-3, W2-4 (all in session-init.sh + task-track.sh — tightly coupled)

##### Critical Files
- `hooks/session-init.sh` — rotation + orphan cleanup
- `hooks/task-track.sh` — TTL sentinel format change
- `.session-events.jsonl` — rotation target
- `.hook-timing.log` — rotation target

##### Decision Log
<!-- Guardian appends here after phase completion -->

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
**Status:** planned
**Decision IDs:** DEC-PROD-005
**Requirements:** REQ-P1-001, REQ-P1-002, REQ-P1-003
**Issues:** (to be created)
**Definition of Done:**
- REQ-P1-001 satisfied: macOS matrix job runs in CI (continue-on-error initially)
- REQ-P1-002 satisfied: explicit timeout-minutes in validate.yml
- REQ-P1-003 satisfied: shellcheck runs on tests/ and scripts/ in addition to hooks/

##### Planned Decisions
- DEC-PROD-005: Non-blocking macOS CI — surfaces platform issues without blocking merges — Addresses: REQ-P1-001

##### Work Items

**W4-1: Add macOS to CI matrix**
- Add `macos-latest` to the strategy matrix in validate.yml
- Set `continue-on-error: true` for macOS initially
- Ensure homebrew installs jq, shellcheck if needed on macOS runner
- File: `.github/workflows/validate.yml`

**W4-2: Add explicit timeout to CI jobs**
- Add `timeout-minutes: 15` to the test job
- Prevents hung jobs from consuming CI minutes
- File: `.github/workflows/validate.yml`

**W4-3: Extend shellcheck to tests/ and scripts/**
- Current CI runs shellcheck only on hooks/
- Add `tests/*.sh`, `tests/lib/*.sh`, `scripts/*.sh` to shellcheck targets
- Use `shellcheck -x` to follow source directives
- May need `.shellcheckrc` for test-specific exclusions (e.g., SC2034 unused variables in test fixtures)
- File: `.github/workflows/validate.yml`

##### Dispatch Plan
- Dispatch 1: W4-1, W4-2, W4-3 (all validate.yml changes — single file, parallel-safe)

##### Critical Files
- `.github/workflows/validate.yml` — all CI changes
- `.shellcheckrc` — may need test-specific exclusions (new file if needed)

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Phase 5: Documentation Freshness
**Status:** planned
**Decision IDs:** (none — documentation update)
**Requirements:** REQ-GOAL-005
**Issues:** (to be created)
**Definition of Done:**
- README.md reflects current hook count, test count, directory structure, and script inventory
- ARCHITECTURE.md reflects current system design, lazy-loading pattern, and state management architecture

##### Work Items

**W5-1: Update README.md**
- Update test count (currently says 159 — verify actual count)
- Update hook entry point count and domain library list
- Update scripts/ section with new scripts (statusline.sh, worktree-roster.sh, clean-state.sh, etc.)
- Update commands/ section with any new commands
- Verify all directory descriptions are current

**W5-2: Update ARCHITECTURE.md**
- Verify lazy-loading architecture description is current
- Update state management section with any new patterns
- Verify hook lifecycle diagram is accurate
- Update performance characteristics if changed

##### Dispatch Plan
- Dispatch 1: W5-1, W5-2 (documentation — independent files, parallel-safe)

##### Critical Files
- `README.md` — project overview and reference
- `ARCHITECTURE.md` — system design documentation

##### Decision Log
<!-- Guardian appends here after phase completion -->

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
