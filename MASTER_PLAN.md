# MASTER_PLAN: claude-config-pro

## Identity

**Type:** meta-infrastructure
**Languages:** Bash (85%), Markdown (10%), Python (3%), JSON (2%)
**Root:** /Users/turla/.claude
**Created:** 2026-03-01
**Last updated:** 2026-03-02

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

---

## Active Initiatives

### Initiative: Statusline Information Architecture
**Status:** active
**Started:** 2026-03-02
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
**Status:** planned
**Decision IDs:** DEC-SL-LAYOUT-001, DEC-SL-TOKENS-001
**Requirements:** REQ-P0-001, REQ-P0-002, REQ-P0-003, REQ-P0-004
**Issues:** #71, #67, #68 (token display only)
**Definition of Done:**
- REQ-P0-001 satisfied: segments grouped by domain as specified in Proposed Layout
- REQ-P0-002 satisfied: every numeric segment has a label
- REQ-P0-003 satisfied: cost displays as `~$X.XX`
- REQ-P0-004 satisfied: token segment shows K notation from stdin fields

##### Planned Decisions
- DEC-SL-LAYOUT-001: 2-line domain-clustered layout — 3-line rejected as unnecessary given width analysis — Addresses: REQ-P0-001, REQ-P0-002
- DEC-SL-TOKENS-001: Compact K notation for tokens — raw numbers unreadable, direction split deferred to P1 — Addresses: REQ-P0-004

##### Work Items

**W1-0: Restructure line 1 with domain clustering and labels (#67)**
- Reorder segments: model+workspace, then git state (dirty+wt with labels), then agents (with label), then todos
- Add `dirty:` and `wt:` labels to git segment
- Add `agents:` label
- Add `todos:` label (placeholder for split — actual split in Phase 2)

**W1-1: Add token count segment to line 2 (#68)**
- Extract `total_input_tokens` + `total_output_tokens` from stdin JSON (add to the existing `jq` call)
- Create `format_tokens()` helper: converts raw count to K notation (e.g., 145234 -> `145k`, 1500000 -> `1.5M`)
- Insert token segment between context bar and cost: `tokens: 145k`
- Color: dim when <50k, default when 50k-500k, yellow when >500k

**W1-2: Prefix cost with `~` (#67 quick fix)**
- Change `$%.2f` format to `~$%.2f` in cost_display printf
- One-line change

**W1-3: Update label formatting for line 2 segments**
- Ensure duration, lines-changed, and cache segments have consistent label style
- Duration already reads well (`12m`); lines and cache may need minor label tweaks

##### Dispatch Plan
- Dispatch 1: W1-0, W1-1, W1-2, W1-3 (all in statusline.sh, ~1 file, tightly coupled)

##### Critical Files
- `scripts/statusline.sh` — primary file, all rendering changes happen here

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Phase 2: Data Pipeline — Todo Split + Cost Persistence
**Status:** planned
**Decision IDs:** DEC-SL-TODOCACHE-001, DEC-SL-COSTPERSIST-001
**Requirements:** REQ-P0-005, REQ-P1-001
**Issues:** #72, #68 (cost persistence), #69
**Definition of Done:**
- REQ-P0-005 satisfied: statusline shows project vs global todo counts from cache
- REQ-P1-001 satisfied: session cost persisted to `.session-cost-history`; lifetime cost readable at session start

##### Planned Decisions
- DEC-SL-TODOCACHE-001: Todo split via statusline-cache JSON fields — avoids file proliferation — Addresses: REQ-P0-005
- DEC-SL-COSTPERSIST-001: Cost persistence via `.session-cost-history` — proven cross-session pattern — Addresses: REQ-P1-001

##### Work Items

**W2-0: Compute project-specific todo count in session-init.sh (#69)**
- After the existing `todo.sh hud` call, run `todo.sh count --project` and `todo.sh count --global` (or parse HUD output)
- If project has no GitHub remote, project count = 0 and fall back to global only
- Write both counts to variables for cache consumption

**W2-1: Update write_statusline_cache() in session-lib.sh (#69)**
- Add `todo_project` and `todo_global` fields to the jq call
- Source values from session-init.sh variables or re-derive from `.todo-count` + project count
- Backward compatible: statusline.sh falls back to 0 if fields missing

**W2-2: Update statusline.sh to read todo split from cache (#69)**
- Replace single `todo_count` read with `todo_project` + `todo_global` from cache
- Display format: `todos: 3p 7g` when both > 0; `todos: 3p` when only project; `todos: 7g` when only global
- Fall back to existing `.todo-count` if cache fields missing (backward compat)

**W2-3: Persist session cost in session-end.sh (#68)**
- Read `cost.total_cost_usd` from the session's last known value (stdin JSON is not available at session-end; need alternative)
- Alternative: write cost to `.statusline-cache` during session (already done) and read it at session-end
- Append `timestamp|cost_usd` to `.session-cost-history`
- Trim to last 100 entries to prevent unbounded growth

**W2-4: Sum lifetime cost at session start (#68)**
- In session-init.sh, if `.session-cost-history` exists, sum the cost column
- Write `lifetime_cost` to `.statusline-cache` via `write_statusline_cache()`
- statusline.sh displays lifetime cost if available (e.g., `~$0.53 (life: ~$12.40)` or just the session cost if no history)

##### Dispatch Plan
- Dispatch 1: W2-0, W2-1, W2-2 (todo split pipeline — session-init -> cache -> statusline)
- Dispatch 2: W2-3, W2-4 (cost persistence pipeline — session-end -> history -> session-init -> cache)

##### Critical Files
- `hooks/session-init.sh` — computes project todo count and sums lifetime cost
- `hooks/session-lib.sh` — `write_statusline_cache()` gets new fields
- `hooks/session-end.sh` — persists session cost to history file
- `scripts/statusline.sh` — reads new cache fields for display

##### Decision Log
<!-- Guardian appends here after phase completion -->

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

---

## Completed Initiatives

| Initiative | Period | Phases | Key Decisions | Archived |
|-----------|--------|--------|---------------|----------|
| Production Remediation (Metanoia Suite) | 2026-02-28 to 2026-03-01 | 5 | DEC-HOOKS-001 thru DEC-TEST-006 | No |
| State Management Reliability | 2026-03-01 to 2026-03-02 | 5 | DEC-STATE-007, DEC-STATE-008 + 8 test decisions | No |
| Hook Consolidation Testing & Streamlining | 2026-03-02 | 4 | DEC-AUDIT-001, DEC-TIMING-001, DEC-DEDUP-001 | No |

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

---

## Parked Issues

| Issue | Description | Reason Parked |
|-------|-------------|---------------|
| #15 | ExitPlanMode spin loop fix | Blocked on upstream claude-code#26651 |
| #14 | PreToolUse updatedInput support | Blocked on upstream claude-code#26506 |
| #13 | Deterministic agent return size cap | Blocked on upstream claude-code#26681 |
| #37 | Close Write-tool loophole for .proof-status bypass | Not in remediation scope |
| #36 | Evaluate Opus for implementer agent | Not in remediation scope |
| #25 | Create unified model provider library | Not in remediation scope |
