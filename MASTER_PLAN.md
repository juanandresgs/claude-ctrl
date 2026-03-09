# MASTER_PLAN: Claude Code Configuration System

<!--
@decision DEC-RECK-001 through DEC-RECK-007
@title Reckoning operationalization: restore institutional memory
@status accepted
@rationale Project reckoning (2026-03-07) found that a plan rewrite erased 73 decisions,
  12+ completed initiative summaries, and the Original Intent. User confirmed 9 decisions
  via /decide configurator to restore history, park orphaned initiatives, fix DEC-ID
  collision, and execute a strategic reset. This commit implements decisions 1-7.
-->

## Identity

**Type:** meta-infrastructure
**Languages:** Bash (85%), Markdown (10%), JSON/Python (5%)
**Root:** `/Users/turla/.claude`
**Created:** 2026-02-06
**Last updated:** 2026-03-09

The Claude Code configuration directory that shapes how Claude Code operates across all projects. It enforces development practices via hooks (deterministic shell scripts intercepting every tool call), four specialized agents (Planner, Implementer, Tester, Guardian), skills, and session instructions. Instructions guide; hooks enforce.

## Architecture

```
hooks/              — 26 hook scripts + 9 shared libraries; deterministic enforcement layer
agents/             — 5 agent prompt definitions (planner, implementer, tester, guardian, governor)
skills/             — 13 skill directories (deep-research, decide, reckoning, consume-content, etc.)
commands/           — Slash commands (/compact, /backlog); lightweight, no context fork
scripts/            — Utility scripts (statusline, worktree-roster, batch-fetch, etc.)
templates/          — MASTER_PLAN.md and initiative-block templates for Planner
docs/               — DISPATCH.md, development history; reference docs loaded on demand
observatory/        — Self-improving trace analysis flywheel
traces/             — Agent execution archive (index.jsonl + per-agent directories)
tests/              — Hook validation test suite
settings.json       — Hook registration (10 events, 24 hooks) + model config
CLAUDE.md           — Session instructions loaded every session (~149 lines, was ~255 pre-metanoia)
ARCHITECTURE.md     — Definitive technical reference (18 sections)
```

## Original Intent

> Build a configuration layer for Claude Code that enforces engineering discipline — git safety, documentation, proof-before-commit, worktree isolation — across all projects. The system should be self-governing: hooks enforce rules mechanically, agents handle specialized roles, and the observatory learns from traces to improve over time.

## Principles

These are the project's enduring design principles. They do not change between initiatives.

1. **Code is Truth** — Documentation derives from code; annotate at the point of implementation. When docs and code conflict, code is right.
2. **Main is Sacred** — Feature work happens in worktrees; main stays clean and deployable. Never work directly on main.
3. **Deterministic Enforcement** — Hooks enforce rules mechanically regardless of context pressure. Prompts inspire quality; hooks guarantee compliance.
4. **Ephemeral Agents, Persistent Knowledge** — Each agent is temporary; the plan, decisions, and code persist. Enable Future Implementers to succeed.
5. **Purpose Before Procedure** — Lead with WHY, then HOW. The model internalizes what it reads first. Purpose language at the top produces deep work; procedural language at the top produces compliance.

---

## Decision Log

Append-only record of significant decisions across all initiatives. Each entry references
the initiative and decision ID. This log persists across initiative boundaries — it is the
project's institutional memory.

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
| 2026-03-06 | DEC-SQLITE-001 | sqlite-state-store | Global SQLite WAL database at $CLAUDE_DIR/state/state.db | WAL contention negligible for hook workloads; global simplifies cross-project queries and diagnostics |
| 2026-03-06 | DEC-SQLITE-002 | sqlite-state-store | workflow_id = {phash}_main / {phash}_{wt_basename} | Deterministic, stable across sessions; proof invalidation handles multi-instance safety |
| 2026-03-06 | DEC-SQLITE-003 | sqlite-state-store | Proof invalidation on write as multi-instance safety mechanism | Proof is about code state not instance identity; shared proof for shared worktree is correct |
| 2026-03-06 | DEC-SQLITE-004 | sqlite-state-store | PID-based liveness replaces TTL-based marker expiry | kill -0 is instantaneous and definitive; handles SIGKILL crashes that bypass cleanup hooks |
| 2026-03-06 | DEC-SQLITE-005 | sqlite-state-store | Automatic re-verification on proof invalidation (max 3 retries) | Keeps pipeline flowing without human intervention in multi-instance scenarios |
| 2026-03-06 | DEC-SQLITE-006 | sqlite-state-store | Dual-write/dual-read migration with 1-release soak period | Transparent migration; no data loss; flat files retained as fallback during transition |
| 2026-03-06 | DEC-SQLITE-007 | sqlite-state-store | One sqlite3 invocation per state operation | ~2-3ms per spawn well within budget; _state_sql() wrapper prepends WAL + busy_timeout pragmas |
| 2026-03-06 | DEC-SQLITE-008 | sqlite-state-store | History table replaces .audit-log and state.json history array | Structured history with SQL queries; capped at 500 entries per workflow via trigger |
| 2026-03-07 | DEC-PROMPT-001 | prompt-restoration | Hybrid CLAUDE.md: pre-metanoia voice + current procedural references | Pre-metanoia purpose language is sacred; current procedural references are useful but must follow purpose, not lead |
| 2026-03-07 | DEC-PROMPT-002 | prompt-restoration | Shared protocols injected via subagent-start.sh, not just referenced | Deterministic injection at dispatch time means agents don't need to remember to read a file; the hook ensures they see shared protocols (CWD safety, trace, return message) |
| 2026-03-07 | DEC-PROMPT-003 | prompt-restoration | "What Matters" section added to CLAUDE.md with quality-of-thought expectations | The model lacks explicit guidance on what deep work looks like; codifying it in purpose position produces better reasoning |
| 2026-03-07 | DEC-AUDIT-002 | governance-audit | Governance signal map as markdown in docs/governance-signal-map.md | One-time research artifact to inform optimization decisions; markdown is sufficient |
| 2026-03-09 | DEC-GOV-001 | governor-subagent | Use Opus for the governor agent | Governor's value is judgment quality; at ~2 dispatches/initiative, cost delta vs. Sonnet is negligible |
| 2026-03-09 | DEC-GOV-002 | governor-subagent | 4+4 dimension scoring rubric (initiative eval + meta-eval) | 4 initiative dimensions + 4 meta-evaluation dimensions; lean enough for ~15K tokens, structured for trend tracking |
| 2026-03-09 | DEC-GOV-003 | governor-subagent | Orchestrator instruction-based dispatch via DISPATCH.md | Follows existing auto-dispatch pattern; hook-based auto-dispatch is P2 upgrade path |
| 2026-03-09 | DEC-GOV-004 | governor-subagent | Bidirectional reckoning relationship — governor consumes AND provides | Governor reads recent reckoning verdict/trajectory; writes structured assessments for reckoning Phase 2 |
| 2026-03-09 | DEC-GOV-005 | governor-subagent | Read-only tools (Read, Grep, Glob) plus trace artifact writes | Enforces governor role — evaluates and reports, never acts; prevents scope creep |
| 2026-03-08 | DEC-LIFETIME-PERSIST-001 | statusline-ia | Read existing cache lifetime fields as fallback defaults in write_statusline_cache | write_statusline_cache() called from 7 hooks but only session-init.sh computes lifetime values; other callers were zeroing them out |
| 2026-03-08 | DEC-PROJECT-TOKEN-HISTORY-001 | statusline-ia | Add project_hash and project_name as columns 6+7 of .session-token-history | All sessions accumulated into one history; per-project columns enable project-scoped lifetime cost |
| 2026-03-08 | DEC-NO-TRIM-001 | statusline-ia | Remove 100-line trim from session history files | Each entry ~80 bytes; 10,000 entries (3 years) is under 1MB; trim caused data loss |
| 2026-03-09 | DEC-DUALBAR-001 | statusline-ia | Dual-color context bar: system overhead (dim) + conversation (severity-colored) | Single-color bar conflates system overhead with conversation usage; dual-color separates them |
| 2026-03-09 | DEC-DUALBAR-002 | statusline-ia | Baseline fingerprint: hash of config mtimes + model for invalidation | System overhead percentage needs recalculation when config changes; fingerprint detects drift |
| 2026-03-09 | DEC-DISPATCH-004 | dispatch-enforcement | Simple Task Fast Path for ≤2-file fixes | Orchestrator can handle trivial fixes (≤2 files, no new tests) directly without implementer dispatch; reduces overhead on easy tasks |
| 2026-03-09 | DEC-DISPATCH-005 | dispatch-enforcement | Interface Contracts and consumer-first pattern for multi-file features | Implementer defines interfaces in consumer code first, then implements providers; prevents integration surprises |
| 2026-03-09 | DEC-PROMPT-004 | prompt-restoration | Close initiative: 30-40% reduction target structurally unrealistic | shared-protocols supplements, doesn't replace; value delivered: Cornerstone Belief, What Matters, purpose-sandwich |
| 2026-03-09 | DEC-RECK-010 | reckoning-ops | Batch housekeeping: fix all 5 plan maintenance items | Breaks selectivity bias; one commit clears 5 persistent reckoning findings |
| 2026-03-09 | DEC-RECK-011 | reckoning-ops | Governance self-bypass: record and prevent | Simple Task Fast Path + Interface Contracts committed to main without worktrees; record and strengthen hooks |
| 2026-03-09 | DEC-RECK-012 | reckoning-ops | Structured issue triage session | 105 open issues; dedicate one session to close/park/refine |
| 2026-03-09 | DEC-RECK-013 | governance-audit | Close initiative — W1 delivered the value | Signal map + 7 proposals are the deliverable; W2 is busywork |
| 2026-03-09 | DEC-RECK-014 | reckoning-ops | Next strategic: Governance Efficiency | Directly addresses 60-310% overhead benchmark finding; 7 signal map proposals are starting point |
| 2026-03-09 | DEC-RECK-015 | reckoning-ops | Reckoning cadence: per-initiative boundaries | Natural checkpoint; enough time for findings to be acted on; typically every 1-2 weeks |
| 2026-03-09 | DEC-RECK-016 | reckoning-ops | Cap recursive evaluation at 3 layers, measure convergence | No new evaluative infrastructure until observatory+reckoning+governor prove value |
| 2026-03-09 | DEC-EFF-001 | governance-efficiency | Optimize-first, measure-after | Signal map proposals are thoroughly analyzed; measurement infrastructure would delay tangible improvement |
| 2026-03-09 | DEC-EFF-002 | governance-efficiency | Debug logging via .session-events.jsonl for demoted advisories | Preserves trace data for observatory/reckoning; model stops seeing noise but event log retains everything |
| 2026-03-09 | DEC-EFF-003 | governance-efficiency | File-mtime-based cache invalidation (DEC-PERF-004 pattern) | Existing stop.sh pattern proves the approach; no new cache mechanisms needed |
| 2026-03-09 | DEC-EFF-004 | governance-efficiency | Preserve all deny gates unconditionally | Deny gates are safety guarantees; advisory noise reduction yes, safety weakening never |
| 2026-03-09 | DEC-EFF-005 | governance-efficiency | Two-wave delivery: noise reduction then deduplication | Wave 1 low-risk advisory/caching; Wave 2 cross-hook changes need approve gate |

---

## Active Initiatives

### Initiative: Governor Subagent
**Status:** active
**Started:** 2026-03-09
**Goal:** Add a 5th agent — the governor — that serves as the system's mechanical feedback mechanism, evaluating initiatives against the project's core intent and trajectory at critical junctures, and meta-evaluating the health of the evaluative infrastructure itself.

> The system has a well-defined Act pipeline (Planner -> Implementer -> Tester -> Guardian) and a deterministic Enforce layer (24 hooks), but evaluation of whether work serves the project's trajectory is manual and periodic (/reckoning on demand, /observatory on traces). No agent fires automatically at initiative boundaries to check whether planned work honors the Original Intent, whether completed work actually served the trajectory, or whether the evaluative infrastructure (observatory, reckoning, traces, plan) is itself healthy. The governor closes this loop. Like a centrifugal governor on a steam engine, it does not DO the work — it measures whether the work is staying within bounds and feeds that signal back to the controller. It fires at exactly three moments: before multi-wave implementation begins, when an initiative completes, and as structured input to reckoning. It is meta-evaluative: it evaluates both the work AND the systems that evaluate the work — the SESAP concept applied recursively to the system's own governance infrastructure.

**Dominant Constraint:** simplicity

#### Goals
- REQ-GOAL-006: Enable automatic trajectory evaluation at multi-wave initiative boundaries (before implementation, after completion)
- REQ-GOAL-007: Provide structured input to `/reckoning` pipeline and consume reckoning output (bidirectional) to ground assessments in the project's evolved trajectory state
- REQ-GOAL-008: Keep evaluation lean — under 50 tool calls and under 20K tokens per dispatch

#### Non-Goals
- REQ-NOGO-006: Replacing `/reckoning` — the governor evaluates per-initiative; reckoning evaluates the project; they are complementary, not redundant
- REQ-NOGO-007: Firing on every planner session — lightweight plans (Tier 1, single-wave) do not need evaluation; the governor only triggers for 2+ wave initiatives
- REQ-NOGO-008: Evaluating phase boundaries — that is the Guardian's domain; the governor operates at initiative level
- REQ-NOGO-009: Deep research, test execution, code analysis, or acting on findings — the governor reads and judges; it never writes to the project, runs commands, or invokes other agents

#### Requirements

**Must-Have (P0)**

- REQ-P0-005: Agent prompt definition at `agents/governor.md`
  Acceptance: Given the existing 4-agent system, When the governor prompt is created, Then:
  - [ ] Prompt leads with purpose (mechanical governor role, intent fidelity, meta-evaluation) not procedures
  - [ ] Defines exactly 3 trigger contexts: pre-implementation, post-completion, reckoning-input
  - [ ] Includes a scoring rubric with 4 initiative-evaluation dimensions (intent-alignment, priority-coherence, principle-adherence, scope-discipline) each scored 1-5
  - [ ] Includes 4 meta-evaluation dimensions (observatory-health, reckoning-health, trace-quality, plan-currency) each scored 1-5
  - [ ] Specifies output format: structured JSON (`evaluation.json`) + human-readable summary (`evaluation-summary.md`)
  - [ ] Specifies allowed tools: Read, Grep, Glob only (no Write, no Bash, no Agent)
  - [ ] Specifies full input set: MASTER_PLAN.md, most recent reckoning, traces, specific initiative being evaluated
  - [ ] Prompt is under 200 lines

- REQ-P0-006: Integration with dispatch system
  Acceptance: Given the dispatch infrastructure (DISPATCH.md, subagent-start.sh, task-track.sh), When the governor is wired in, Then:
  - [ ] DISPATCH.md routing table has a governor row with trigger conditions (after planner returns with 2+ waves, after initiative completion, before reckoning)
  - [ ] `subagent-start.sh` has a `governor` case injecting: MASTER_PLAN.md identity/principles/original-intent, active initiative being evaluated, most recent reckoning verdict and what-to-confront (if reckoning exists)
  - [ ] `task-track.sh` recognizes `governor` as a valid agent type (no proof-status gate — governor does not write code)
  - [ ] Governor is exempt from worktree gate (Gate C.1) — it evaluates, it does not implement

- REQ-P0-007: SubagentStop validation hook `hooks/check-governor.sh`
  Acceptance: Given the check-*.sh pattern for all existing agents, When the governor returns, Then:
  - [ ] Hook validates that the governor produced a scored assessment (not empty return)
  - [ ] Hook captures assessment to trace artifacts (`evaluation.json`, `evaluation-summary.md`)
  - [ ] Hook is registered in `settings.json` SubagentStop with matcher `governor`
  - [ ] Hook emits assessment verdict in additionalContext so orchestrator sees the result
  - [ ] Hook is under 80 lines (lean, like check-explore.sh, not heavy like check-tester.sh)

- REQ-P0-008: Governor output format and storage
  Acceptance: Given a governor dispatch, When the assessment is complete, Then:
  - [ ] Assessment written to `{TRACE_DIR}/artifacts/evaluation.json` with structure: `{ "dimensions": { "intent_alignment": {"score": N, "evidence": "..."}, ... }, "meta_dimensions": { "observatory_health": {"score": N, "evidence": "..."}, ... }, "verdict": "proceed|caution|block", "flags": [...], "narrative": "..." }`
  - [ ] Assessment also written as `{TRACE_DIR}/artifacts/evaluation-summary.md` (human-readable)
  - [ ] Assessment references specific DEC-IDs, REQ-IDs, and Principle numbers from MASTER_PLAN.md
  - [ ] Verdict logic: proceed (all initiative dimensions >= 3), caution (any 2, none 1), block (any 1)

**Nice-to-Have (P1)**

- REQ-P1-003: Reckoning integration — `/reckoning` reads the most recent governor assessments from traces when performing Phase 2 cross-reference, incorporating initiative-level and meta-evaluations into the Seven-Dimensional Analysis
- REQ-P1-005: Scoring rubric calibration test — a test that validates the governor's output JSON schema against a synthetic initiative block

**Future Consideration (P2)**

- REQ-P2-003: Auto-dispatch via hook — a PostToolUse:Task|Agent hook that detects planner completion with 2+ waves and auto-dispatches the governor
- REQ-P2-004: Historical trend tracking — store governor scores in a persistent file so reckoning can show intent-alignment trends over time

#### Definition of Done

All P0 requirements pass their acceptance criteria. `agents/governor.md` defines the 5th agent with purpose-led prompt, 4+4 dimension rubric, 3 trigger contexts, and read-only tool constraints. Dispatch infrastructure recognizes the governor type and injects appropriate context. `hooks/check-governor.sh` validates output and emits verdict. Governor can be dispatched against an existing initiative and produces valid `evaluation.json` + `evaluation-summary.md`. Satisfies: REQ-GOAL-006, REQ-GOAL-007, REQ-GOAL-008.

#### Architectural Decisions

- DEC-GOV-001: Use Opus for the governor agent
  Addresses: REQ-GOAL-008.
  Rationale: The governor's entire value is judgment quality — scoring intent alignment, detecting scope drift, assessing principle adherence, meta-evaluating infrastructure health. At ~2 dispatches per initiative, the cost delta between Opus (~$0.15/dispatch) and Sonnet (~$0.02/dispatch) is negligible. Sonnet is appropriate for high-volume agents (implementer, tester); Opus is appropriate for low-volume judgment agents (planner, guardian, governor).

- DEC-GOV-002: 4+4 dimension scoring rubric with narrative and verdict
  Addresses: REQ-P0-005, REQ-P0-008.
  Rationale: 4 initiative-evaluation dimensions (intent-alignment, priority-coherence, principle-adherence, scope-discipline) assess the work. 4 meta-evaluation dimensions (observatory-health, reckoning-health, trace-quality, plan-currency) assess the evaluative infrastructure itself — the SESAP concept applied recursively. Each scored 1-5 with evidence. Verdict: proceed (all initiative dims >= 3), caution (any 2, none 1), block (any 1). 7-dimension overlap with reckoning rejected; 3-tier-only too coarse for trend tracking.

- DEC-GOV-003: Orchestrator instruction-based dispatch via DISPATCH.md rules
  Addresses: REQ-P0-006, REQ-NOGO-007.
  Rationale: The system already successfully uses instruction-based auto-dispatch for tester (after implementer) and guardian (on verification). Adding a rule "dispatch governor after planner returns with 2+ waves" follows the same proven pattern. Hook-based auto-dispatch (P2) is the upgrade path if instruction compliance proves unreliable. Simpler now, no hook changes needed for trigger logic.

- DEC-GOV-004: Bidirectional reckoning relationship — governor consumes AND provides
  Addresses: REQ-P1-003, REQ-P0-005.
  Rationale: The governor reads the most recent reckoning (verdict, trajectory, what-to-confront) to ground its assessment in the project's evolved trajectory state — not just static plan text. The governor writes structured assessment JSON to trace artifacts that reckoning reads in Phase 2. One-directional (provide-only) would miss the insight that a recent reckoning reveals about where the project actually is vs. where the plan says it is. Governor's full input set: MASTER_PLAN.md, most recent reckoning, traces, and the specific initiative being evaluated.

- DEC-GOV-005: Read-only tools (Read, Grep, Glob) plus trace artifact writes
  Addresses: REQ-NOGO-009, REQ-GOAL-008.
  Rationale: The governor is a judgment agent, not an implementation agent. Giving it Write or Bash would invite scope creep (governor starts "fixing" things it finds). Read-only plus trace artifact writes (via standard trace protocol) enforces the governor role — it evaluates and reports, never acts. This is a hard constraint, not a suggestion.

#### Waves

##### Initiative Summary
- **Total items:** 4
- **Critical path:** 3 waves (W1-1 -> W2-1 -> W3-1)
- **Max width:** 2 (Wave 1)
- **Gates:** 2 review, 1 approve, 1 none

##### Wave 1 (no dependencies)
**Parallel dispatches:** 2

**W1-1: Create `agents/governor.md` agent prompt (#182)** — Weight: M, Gate: review
- Create `agents/governor.md` with purpose-led structure:
  - **Opening:** Governor identity — mechanical governor metaphor, feedback mechanism for a self-modifying system, evaluates both work and the systems that evaluate work
  - **Section 1: Trigger Contexts** — Define the 3 dispatch contexts:
    1. **Pre-implementation:** Planner completed a 2+ wave initiative. Governor reads initiative block, MASTER_PLAN.md principles/intent, most recent reckoning. Assesses: does this work serve the original intent? Are priorities ordered by trajectory? Does scope stay within declared bounds?
    2. **Post-completion:** All phases of an initiative merged. Governor reads completed initiative summary, decision log entries, traces. Assesses: did the work honor the intent? Did scope drift occur? What did the meta-evaluation dimensions reveal?
    3. **Reckoning-input:** Dispatched by reckoning skill during Phase 2. Governor produces a focused assessment of active initiatives for reckoning to consume.
  - **Section 2: Initiative Evaluation Rubric** — 4 dimensions scored 1-5:
    - `intent_alignment`: Does this initiative serve the Original Intent and active Principles?
    - `priority_coherence`: Are priorities ordered by trajectory awareness, not just urgency?
    - `principle_adherence`: Does the work reference and honor stated Principles by number?
    - `scope_discipline`: Does the work stay within declared goals/non-goals?
  - **Section 3: Meta-Evaluation Rubric** — 4 dimensions scored 1-5:
    - `observatory_health`: Is the observatory being run? Are suggestions acted on? Is the trace-to-improvement pipeline functional?
    - `reckoning_health`: Are reckonings produced at appropriate cadence? Are findings acted on? Is the reckoning-to-action pipeline functional?
    - `trace_quality`: Are agents producing traces? Are summaries substantive? Is the archive growing healthily?
    - `plan_currency`: Is MASTER_PLAN.md up to date? Are completed initiatives compressed? Are decision log entries appended? Are parked issues reviewed?
  - **Section 4: Output Format** — Specifies `evaluation.json` schema and `evaluation-summary.md` format
  - **Section 5: Verdict Logic** — proceed (all initiative dims >= 3), caution (any 2, none 1), block (any 1)
  - **Section 6: Behavioral Constraints** — Read-only tools, no acting on findings, no invoking other agents/skills, under 50 tool calls, return message under 1500 tokens
- Target: under 200 lines
- **Integration:** `agents/governor.md` is loaded by Claude Code runtime from agents/ directory. Referenced in DISPATCH.md routing table and CLAUDE.md Resources table.

**W1-2: Create `hooks/check-governor.sh` SubagentStop hook (#183)** — Weight: S, Gate: none
- Create `hooks/check-governor.sh` following the check-explore.sh pattern (lean, ~60-80 lines):
  - Source `source-lib.sh`, require session + trace
  - Read agent response from stdin
  - Track subagent stop + tokens + session event
  - Validate assessment output:
    - Check `TRACE_DIR/artifacts/evaluation.json` exists and is valid JSON
    - Check `TRACE_DIR/artifacts/evaluation-summary.md` exists and is non-empty
    - Extract verdict from evaluation.json
  - Finalize trace
  - Emit verdict in additionalContext: "Governor assessment: verdict=[proceed|caution|block]. [1-line summary]. Full assessment: {TRACE_DIR}/artifacts/evaluation-summary.md"
  - Handle silent return: if no evaluation artifacts, inject trace summary (Layer A pattern from check-implementer.sh)
  - Exit 0 (governor results are advisory, never blocking)
- **Integration:** Register in `settings.json` under SubagentStop with matcher `governor`. File at `hooks/check-governor.sh`.

##### Wave 2
**Parallel dispatches:** 1
**Blocked by:** W1-1, W1-2

**W2-1: Wire governor into dispatch infrastructure (#184)** — Weight: M, Gate: approve, Deps: W1-1, W1-2
- **DISPATCH.md** updates:
  - Add routing table row: `| Plan/initiative evaluation | **Governor** | No — dispatched automatically after planner (2+ waves), after initiative completion, before reckoning |`
  - Add "Auto-dispatch to Governor" section after "Auto-dispatch to Tester": "After the planner returns with a 2+ wave initiative, dispatch the governor automatically with the initiative block. Do NOT ask 'should I evaluate?' — dispatch. Governor results are advisory: proceed = continue normally, caution = present concerns to user before implementing, block = present to user and wait for guidance. After initiative completion (all phases merged, before compress_initiative), dispatch governor for post-completion assessment."
  - Add governor to Pre-Dispatch Gates note: "Governor dispatch: no proof-status gate, no worktree gate. Governor is read-only."
- **subagent-start.sh** updates:
  - Add `governor` case in the agent-type-specific context block (after `planner|Plan` case, before `implementer` case):
    ```
    governor)
        CONTEXT_PARTS+=("Role: Governor — mechanical feedback mechanism. Evaluate the initiative against project intent, principles, and trajectory. Produce scored assessment (evaluation.json + evaluation-summary.md). Read-only: do NOT write to the project, run commands, or invoke other agents.")
        # Inject MASTER_PLAN.md identity, principles, original intent (compact)
        # Inject most recent reckoning verdict + what-to-confront (if exists)
        # Inject TRACE_DIR
    ```
  - Read most recent reckoning from `{PROJECT_ROOT}/reckonings/` (most recent by filename date), extract verdict and "What to Confront" section, inject as context (cap at 2000 bytes)
  - Inject MASTER_PLAN.md `## Original Intent` and `## Principles` sections (compact, ~500 bytes)
- **task-track.sh** updates:
  - Add `governor` to the recognized agent types (alongside implementer, planner, guardian, tester)
  - Skip proof-status gate for governor (same pattern as planner — governor does not write code)
  - Skip worktree gate (Gate C.1) for governor — it evaluates, it does not need a worktree
- **settings.json** updates:
  - Add SubagentStop entry: `{ "matcher": "governor", "hooks": [{ "type": "command", "command": "$HOME/.claude/hooks/check-governor.sh", "timeout": 5 }] }`
- **CLAUDE.md** updates:
  - Add governor to Resources table: `| agents/governor.md | Evaluating initiatives against project trajectory |`
- **Integration:** This is the wiring wave — it connects the governor prompt (W1-1) and hook (W1-2) to the dispatch infrastructure. All modified files are existing infrastructure files.

##### Wave 3
**Parallel dispatches:** 1
**Blocked by:** W2-1

**W3-1: Validation — dispatch governor against existing initiative (#185)** — Weight: S, Gate: review, Deps: W2-1
- Dispatch the governor against the "Prompt Purpose Restoration" initiative (active, multi-wave, well-documented)
- Verify output:
  - `evaluation.json` is valid JSON with correct schema (4 initiative dimensions + 4 meta dimensions + verdict + flags + narrative)
  - `evaluation-summary.md` is non-empty and human-readable
  - Verdict is one of: proceed, caution, block
  - Each dimension has a score 1-5 and evidence referencing specific DEC-IDs, REQ-IDs, or Principle numbers
  - Meta-evaluation dimensions produce meaningful assessments of observatory, reckoning, trace, and plan health
- Document findings in trace artifacts
- If output quality is insufficient, identify which prompt sections need adjustment and propose changes
- **Integration:** No code changes — this is a verification-only item

##### Critical Files
- `agents/governor.md` — NEW; the 5th agent prompt defining the governor's identity, rubric, and behavioral constraints
- `hooks/check-governor.sh` — NEW; SubagentStop validation for governor returns
- `docs/DISPATCH.md` — routing table and auto-dispatch rules; governor row and dispatch instructions added
- `hooks/subagent-start.sh` — governor case with reckoning/plan context injection
- `hooks/task-track.sh` — governor type recognition and gate exemptions

##### Decision Log
<!-- Guardian appends here after wave completion -->

#### Governor Subagent Worktree Strategy

Main is sacred. Each wave dispatches parallel worktrees:
- **Wave 1:** `.worktrees/governor-prompt` on branch `feature/governor-prompt` (W1-1), `.worktrees/governor-hook` on branch `feature/governor-hook` (W1-2)
- **Wave 2:** `.worktrees/governor-wiring` on branch `feature/governor-wiring` (W2-1)
- **Wave 3:** `.worktrees/governor-validation` on branch `feature/governor-validation` (W3-1)

#### Governor Subagent References

- Existing agent prompts: `agents/implementer.md` (168 lines), `agents/tester.md` (236 lines), `agents/guardian.md` (481 lines), `agents/planner.md` (435 lines)
- Shared protocols (injected at spawn): `agents/shared-protocols.md` (87 lines)
- Dispatch infrastructure: `docs/DISPATCH.md`, `hooks/subagent-start.sh`, `hooks/task-track.sh`
- SubagentStop hook pattern (lean): `hooks/check-explore.sh`
- SubagentStop hook pattern (full): `hooks/check-tester.sh`, `hooks/check-implementer.sh`
- Hook registration: `settings.json` SubagentStop section
- Reckoning skill: `skills/reckoning/SKILL.md` — governor consumes reckoning output and provides structured input
- Observatory: `observatory/` — governor meta-evaluates observatory health
- Issue: #169

---

### Initiative: Governance Efficiency
**Status:** active
**Started:** 2026-03-09
**Goal:** Reduce governance overhead (60-310% token excess on easy tasks) through targeted signal noise reduction, caching, and deduplication — without weakening any safety gates.

> Benchmark data (36 trials, 6 tasks, claude-ctrl-performance harness) revealed that v30 of the governance system spends 60-310% more tokens than v21 on easy tasks. The Governance Signal Audit (completed) produced `docs/governance-signal-map.md` with 7 concrete optimization proposals and a full redundancy analysis. This initiative implements those proposals: demoting low-value advisories to debug logs, caching redundant computations, and deduplicating cross-hook signal injection. Every optimization preserves all deny gates unconditionally. The system becomes leaner without becoming less safe.

**Dominant Constraint:** safety

#### Goals
- REQ-GOAL-009: Reduce per-prompt governance context injection from ~600 bytes to <400 bytes typical (33% reduction)
- REQ-GOAL-010: Eliminate advisory signals that proceed without blocking (pure noise removal)
- REQ-GOAL-011: Introduce caching for computationally redundant hook operations (keyword matching, trajectory narrative, plan churn)

#### Non-Goals
- REQ-NOGO-010: Removing or weakening any deny gates — safety enforcement is the entire point of governance
- REQ-NOGO-011: Building the Operational Mode System (#109, parked) — that's a 4-tier taxonomy; this is targeted optimization
- REQ-NOGO-012: Adding new infrastructure — this is about making existing infrastructure leaner
- REQ-NOGO-013: Building a local token measurement harness — external benchmarks exist (claude-ctrl-performance)

#### Requirements

**Must-Have (P0)**

- REQ-P0-009: Demote fast-mode bypass advisory in pre-write.sh to debug log (.session-events.jsonl)
  Acceptance: Given the fast-mode bypass advisory fires on every write in fast mode, When demoted, Then:
  - [ ] Advisory no longer injected into additionalContext
  - [ ] Event logged to .session-events.jsonl with {type: "advisory-demoted", gate: "fast-mode-bypass"}
  - [ ] Safety invariant documented: fast mode is a Claude Code feature, not model-controlled; no behavioral intent lost

- REQ-P0-010: Demote cold test-gate advisory in pre-write.sh to debug log
  Acceptance: Given the cold test-gate advisory fires on first write when no test data exists, When demoted, Then:
  - [ ] Advisory no longer injected into additionalContext
  - [ ] Event logged to .session-events.jsonl
  - [ ] Safety invariant documented: deny gate (strike 2+) still catches real test failures; cold-start advisory added no blocking value

- REQ-P0-011: Suppress bare doc-freshness advisory in pre-bash.sh (fire-once-per-session)
  Acceptance: Given doc-freshness advisory fires on every commit/merge, When modified to fire-once, Then:
  - [ ] Advisory fires on FIRST commit/merge attempt in a session, then suppressed for subsequent attempts
  - [ ] Deny gates for stale docs on merge-to-main remain fully active
  - [ ] Safety invariant documented: model sees the warning once (enough to act on it); deny gate is the real enforcement

- REQ-P0-012: Skip plan churn drift audit in pre-write.sh Gate 2 when churn <5%
  Acceptance: Given churn detection runs nested git/grep on every source write, When <5% churn, Then:
  - [ ] Churn computation cached with 300s TTL (follows DEC-PERF-004 pattern)
  - [ ] Churn ≥5% still triggers the full drift audit and advisory/deny
  - [ ] Safety invariant documented: <5% churn is genuinely trivial; the gate still fires when drift is meaningful

- REQ-P0-013: Cache keyword match results in prompt-submit.sh
  Acceptance: Given keyword detection (grep -qiE) runs on every user prompt, When cached, Then:
  - [ ] Results cached with invalidation on git state change or plan state change
  - [ ] Same signals produced, just served from cache on consecutive identical-context prompts
  - [ ] Safety invariant documented: technical optimization only; no signals lost, same behavioral intent

- REQ-P0-014: Cache trajectory narrative in stop.sh when no state changes between stops
  Acceptance: Given trajectory narrative regenerates every turn (~300-400ms), When cached, Then:
  - [ ] Cache keyed on git-state fingerprint (branch + HEAD + dirty count)
  - [ ] Stale cache invalidated on any git/plan mutation
  - [ ] Safety invariant documented: if nothing changed, same narrative is correct; model sees accurate state

- REQ-P0-015: Safety invariant requirement for all optimizations
  Acceptance: For EVERY optimization in this initiative, Then:
  - [ ] Implementer documents: (a) what behavior the signal encouraged, (b) what mechanism still preserves that behavior after optimization, (c) if no mechanism preserves it, the optimization is invalid and must be reverted
  - [ ] No deny gate is modified, weakened, or made conditional
  - [ ] Demoted advisories are redirected to .session-events.jsonl (DEC-EFF-002), not deleted

**Nice-to-Have (P1)**

- REQ-P1-006: Cross-hook git state deduplication — consolidate 5-hook git state injection into shared per-event-cycle cache
- REQ-P1-007: Cross-hook plan status deduplication — consolidate 5-hook plan status injection into shared cache
- REQ-P1-008: Evaluate prompt-vs-hook enforcement overlap — identify which prompt-stated rules can be removed from prompts because hooks enforce them deterministically (from signal map redundancy analysis, lines 696-704)

**Future Consideration (P2)**

- REQ-P2-005: Rerun external benchmarks (claude-ctrl-performance) to measure pre/post improvement quantitatively
- REQ-P2-006: Context-sensitive governance — scale overhead with task complexity (lighter for easy tasks, full for complex) — may inform future Operational Mode System reactivation

#### Definition of Done

All P0 requirements pass their acceptance criteria. Every optimization has a documented safety invariant proving no behavioral intent is lost. All deny gates remain untouched. Per-prompt context injection measurably reduced (target: ~600 → <400 bytes typical). Demoted advisories appear in .session-events.jsonl for forensic/analytical use. Satisfies: REQ-GOAL-009, REQ-GOAL-010, REQ-GOAL-011.

#### Architectural Decisions

- DEC-EFF-001: Optimize-first, measure-after
  Addresses: REQ-GOAL-009, REQ-GOAL-010, REQ-GOAL-011.
  Rationale: The signal map proposals are thoroughly analyzed with specific hooks, assessments, and implementation paths. They are low-risk (advisory demotions, caching). Building measurement infrastructure first would delay tangible improvement by an entire wave. Verification comes from rerunning external benchmarks post-implementation.

- DEC-EFF-002: Debug logging via .session-events.jsonl for demoted advisories
  Addresses: REQ-P0-009, REQ-P0-010, REQ-P0-015.
  Rationale: Demoted advisories are redirected to the event log, not deleted. The observatory and reckoning read event logs, not model context — their analytical inputs are unaffected. Trace data is preserved for forensic use.

- DEC-EFF-003: File-mtime-based cache invalidation (follows DEC-PERF-004 pattern)
  Addresses: REQ-P0-012, REQ-P0-013, REQ-P0-014.
  Rationale: The existing stop.sh caching pattern (DEC-PERF-004) uses mtime + TTL for cache invalidation. Extending this pattern to churn detection, keyword matching, and trajectory narrative avoids inventing new cache mechanisms.

- DEC-EFF-004: Preserve all deny gates unconditionally
  Addresses: REQ-NOGO-010.
  Rationale: Deny gates are the system's safety guarantees — they prevent destructive actions, enforce branch isolation, and gate the proof-of-work cycle. Advisory noise can be reduced; safety gates cannot be weakened. This is a hard constraint, not a trade-off.

- DEC-EFF-005: Two-wave delivery — noise reduction then deduplication
  Addresses: REQ-GOAL-009, REQ-P1-006, REQ-P1-007.
  Rationale: Wave 1 (P0 requirements) is low-risk advisory/caching work. Wave 2 (P1 requirements) modifies signal flow across multiple hooks — higher risk, needs the approve gate. Separating them allows Wave 1 to ship independently.

#### Waves

##### Initiative Summary
- **Total items:** 2
- **Critical path:** 2 waves (W1-1 → W2-1)
- **Max width:** 1
- **Gates:** 1 review, 1 approve

##### Wave 1 (no dependencies)
**Parallel dispatches:** 1

**W1-1: Implement signal map optimization proposals (#208)** — Weight: L, Gate: review
- Implement 6 P0 optimizations across 4 hooks:
  1. **pre-write.sh** (REQ-P0-009): Demote fast-mode bypass advisory — replace additionalContext injection with .session-events.jsonl log entry
  2. **pre-write.sh** (REQ-P0-010): Demote cold test-gate advisory — same pattern
  3. **pre-write.sh Gate 2** (REQ-P0-012): Add churn cache — compute churn %, write to `.churn-cache` with timestamp, skip full drift audit when <5% and cache age <300s
  4. **pre-bash.sh** (REQ-P0-011): Modify doc-freshness advisory to fire-once-per-session — use `.doc-freshness-fired-{SID}` sentinel file; deny gates remain unconditional
  5. **prompt-submit.sh** (REQ-P0-013): Cache keyword match results — store matches in `.keyword-cache-{SID}` keyed on git+plan state fingerprint; invalidate on state change
  6. **stop.sh** (REQ-P0-014): Cache trajectory narrative — keyed on git-state fingerprint (branch+HEAD+dirty); serve from cache when fingerprint unchanged
- For EACH optimization: document safety invariant inline as `@decision` annotation (REQ-P0-015)
- Run existing test suites to verify no regressions
- **Integration:** All changes are to existing hook files. No new files except cache sentinels (session-scoped, cleaned by session-end.sh). No settings.json changes.

##### Wave 2
**Parallel dispatches:** 1
**Blocked by:** W1-1

**W2-1: Cross-hook signal deduplication (#209)** — Weight: M, Gate: approve, Deps: W1-1
- Address signal map redundancy findings (lines 683-704):
  1. Git state (branch, dirty count, worktree count) injected by 5 hooks — create `_cached_git_state()` in git-lib.sh that writes to a per-event-cycle cache file; all hooks read from cache instead of re-computing
  2. Plan status (existence, active phase, initiative count) injected by 5 hooks — same `_cached_plan_state()` pattern in plan-lib.sh
  3. Evaluate prompt-vs-hook enforcement overlap — for each of the 6 overlaps identified in signal map (lines 696-704), determine if the prompt statement can be removed because the hook enforces it deterministically
- Verify: Run benchmark suite (external, claude-ctrl-performance) before and after to measure improvement
- **Integration:** Touches git-lib.sh, plan-lib.sh (new cache functions), session-init.sh, prompt-submit.sh, subagent-start.sh, compact-preserve.sh, stop.sh (cache reads replacing direct computation). Cache files cleaned by session-end.sh.

##### Critical Files
- `hooks/pre-write.sh` — Gates 2-4 advisory changes, churn cache
- `hooks/pre-bash.sh` — Doc-freshness fire-once modification
- `hooks/prompt-submit.sh` — Keyword match caching
- `hooks/stop.sh` — Trajectory narrative caching
- `hooks/git-lib.sh` — Shared git state cache (Wave 2)
- `hooks/plan-lib.sh` — Shared plan state cache (Wave 2)
- `docs/governance-signal-map.md` — Source of optimization proposals

##### Decision Log
<!-- Guardian appends here after wave completion -->

#### Governance Efficiency Worktree Strategy

Main is sacred. Each wave dispatches parallel worktrees:
- **Wave 1:** `.worktrees/eff-noise-reduction` on branch `feature/governance-efficiency-w1`
- **Wave 2:** `.worktrees/eff-deduplication` on branch `feature/governance-efficiency-w2`

#### Governance Efficiency References

- Signal map: `docs/governance-signal-map.md` (complete hook audit, context budget, redundancy analysis, 7 optimization proposals)
- Benchmark data: claude-ctrl-performance harness (external, 36 trials, 6 tasks)
- DEC-PERF-004 caching pattern: `hooks/stop.sh` lines 566-568 (TTL-based cache with mtime invalidation)
- Reckoning operationalization: DEC-RECK-014 (user chose governance efficiency as next strategic initiative)
- Safety invariant: DEC-EFF-004 (all deny gates preserved unconditionally)

---

## Completed Initiatives

| Initiative | Period | Phases | Key Decisions | Archived |
|-----------|--------|--------|---------------|----------|
| Production Remediation (Metanoia Suite) | 2026-02-28 to 2026-03-01 | 5 | DEC-HOOKS-001 thru DEC-TEST-006 | No |
| State Management Reliability | 2026-03-01 to 2026-03-02 | 5 | DEC-STATE-007, DEC-STATE-008 + 8 test decisions | No |
| Hook Consolidation Testing & Streamlining | 2026-03-02 | 4 | DEC-AUDIT-001, DEC-TIMING-001, DEC-DEDUP-001 | No |
| Statusline Information Architecture | 2026-03-02 | 2 | DEC-SL-LAYOUT-001, DEC-SL-TOKENS-001, DEC-SL-TODOCACHE-001, DEC-SL-COSTPERSIST-001 | No |
| Robust State Management | 2026-03-02 to 2026-03-05 | 2 (of 7 planned) | DEC-RSM-REGISTRY-001 through DEC-RSM-SELFCHECK-001 (6 decisions) | No |
| Prompt Purpose Restoration | 2026-03-07 to 2026-03-09 | 3 (W1-1, W1-2, W2-1) | DEC-PROMPT-001, DEC-PROMPT-002, DEC-PROMPT-003, DEC-PROMPT-004 | No |
| Governance Signal Audit | 2026-03-07 to 2026-03-09 | 1 (W1-3) | DEC-AUDIT-002, DEC-RECK-013 | No |

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

### Robust State Management — Summary

Hardened the state management infrastructure with protected file registry, POSIX advisory locks, and monotonic lattice enforcement. 2 of 7 planned phases delivered:

1. **Phase 1 — Registry + Locks** (feature/rsm-phase1): Protected state file registry in core-lib.sh, POSIX advisory locks via flock(), pre-write.sh Gate 0 registry check. #37
2. **Phase 2 — Lattice + Self-check** (feature/rsm-phase2): Monotonic lattice enforcement on proof-status transitions, triple self-validation at session startup. #38

Phases 3-5 (SQLite WAL, unified state directory, state daemon) superseded by the dedicated SQLite Unified State Store initiative (parked). 6 architectural decisions (DEC-RSM-REGISTRY-001 through DEC-RSM-SELFCHECK-001).

### Prompt Purpose Restoration — Summary

Restored purpose-to-enforcement ratio in CLAUDE.md and agent prompts after benchmark findings showed easy-task success dropped from 100% to 67%. Three waves:

1. **W1-1: Shared Protocols** (feature/shared-protocols): Created `agents/shared-protocols.md` (87 lines) with CWD safety, trace protocol, mandatory return message, session-end checklist. Wired injection in `hooks/subagent-start.sh` for all non-lightweight agents. #143
2. **W1-2: CLAUDE.md Restore** (feature/claude-md-restore): Rebuilt CLAUDE.md with purpose-sandwich structure — restored full Cornerstone Belief (8 sentences), added "What Matters" section, identity→purpose→quality→references→procedures flow. #144
3. **W2-1: Slim Agent Prompts** (#146): Targeted 30-40% reduction by removing shared boilerplate from 4 agent prompts. Actual reduction ~4.4% — shared-protocols injection supplements rather than replaces content (DEC-PROMPT-004). Purpose language strengthened in agent openings. Guardian merge presentation added (REQ-P1-004).

W3-1 (validation session) not executed — benchmark improvements validated through ongoing usage. 3 architectural decisions (DEC-PROMPT-001 through 003) plus closure decision (DEC-PROMPT-004). Issues closed: #143, #144, #146.

### Governance Signal Audit — Summary

Produced a comprehensive governance signal map documenting all 24 hook registrations, their context injection volume, timing, frequency, and overlap. One wave delivered:

1. **W1-3: Signal Map** (feature/signal-map): Created `docs/governance-signal-map.md` mapping all hooks by lifecycle event with byte counts, frequencies, and 7 optimization proposals. Total governance signal: ~15KB per session start, ~2KB per tool call. #145

W2-2 (formalize optimization proposals) deemed unnecessary (DEC-RECK-013) — the 7 proposals in the signal map are already actionable. 1 architectural decision (DEC-AUDIT-002) plus closure decision (DEC-RECK-013). Issue closed: #145.

---

## Parked Issues

Issues not belonging to any active initiative. Tracked for future consideration.

| Issue | Description | Reason Parked |
|-------|-------------|---------------|
| #15 | ExitPlanMode spin loop fix | Blocked on upstream claude-code#26651 |
| #14 | PreToolUse updatedInput support | Blocked on upstream claude-code#26506 |
| #13 | Deterministic agent return size cap | Blocked on upstream claude-code#26681 |
| #37 | Close Write-tool loophole for .proof-status bypass | **Active** — Phase 0 of Robust State Management |
| #36 | Evaluate Opus for implementer agent | Not in remediation scope |
| #25 | Create unified model provider library | Not in remediation scope |
| SQLite Unified State Store (#128-#134) | SQLite WAL state backend replacing flat-file state. Wave 1 (core API + tests) merged to main. Waves 2-4 pending: hook integration, migration, cleanup. 8 planning decisions (DEC-SQLITE-001 through 008). | Park until prompt restoration completes. Wave 1 code is stable and tested in main. Reactivate when ready to replace flat-file state system-wide. |
| Operational Mode System (#114-#118) | 4-tier mode taxonomy (Observe/Amend/Patch/Build) with escalation engine and hook integration. 9 planning decisions. Deep-research validated. | Ambitious for current project scale. Revisit when multi-user or multi-project usage patterns emerge. |
| Backlog Auto-Capture (cancelled) | Automatic issue creation from conversation keywords. 5 planning decisions. | Cancelled (DEC-RECK-006): manual /backlog command is sufficient. prompt-submit.sh already auto-detects deferred-work language. |
