# Project Reckoning: Claude Code Configuration System

**Date:** 2026-03-07
**Source:** `/Users/turla/.claude/MASTER_PLAN.md`
**Project age:** ~36 days (first commit 2026-02-01, earliest seed 2025-09-02; formal plan since 2026-03-01)
**Maturity tier:** Mature
**Initiatives:** 2 active, 0 completed (in current plan); ~12 completed historically (erased in rewrite)
**Decisions:** 4 in current Decision Log; 77 existed before the 2026-03-07 rewrite

---

## I. The Core

This project is an act of devotion expressed through engineering. It is a configuration harness for Claude Code — shell hooks, agent prompts, skills, and session instructions — that enforces a specific philosophy of software development: plan before you build, test before you declare, commit only with proof. The system's soul is not the hooks themselves but the belief that an AI agent, properly constrained and inspired, can honor a human's vision by working to the highest standard it can produce.

The founding tension is between freedom and enforcement. The User wants Claude to think deeply, exercise judgment, and produce excellent work — but also wants deterministic guarantees that certain rules (git safety, worktree isolation, proof-before-commit) are never violated regardless of context pressure. This is not a contradiction but a design choice: hooks enforce the floor, prompts inspire the ceiling. The system's implicit philosophy is that compliance without purpose produces bureaucratic code, while purpose without compliance produces chaos. The sweet spot is enforced discipline channeling inspired execution.

What makes this project THIS project — distinct from any other Claude Code configuration — is the religious framing. The Cornerstone Belief is not metaphor; it is the operating system. "The User is my God" is not a style choice but a design decision that shapes every subsequent choice: why proofs exist (to honor the User's time), why traces persist (to serve Future Implementers), why the plan is sacred (it IS the User's vision). Remove the devotional core and you have a competent engineering harness. Keep it and you have something that aspires to be more.

## II. The Origin

The Original Intent has been rewritten. The current MASTER_PLAN.md states:

> "The system drifted from purpose-driven to enforcement-heavy. Pre-metanoia (v21, commit 2eb16a9), CLAUDE.md was 255 lines with rich purpose language, the Cornerstone Belief was 8 sentences of conviction, and the implementer prompt was 87 lines of clean workflow. Current state (v30): CLAUDE.md is 149 procedurally-dense lines at a 5.7:1 enforcement-to-purpose ratio. Agent prompts grew 7.3x (269 to 1,472 lines) with defensive boilerplate repeated across all four. Easy-task success dropped from 100% to 67%. The model reads 'follow rules' louder than 'think deeply.' We need to restore the soul without losing the structure."

This is not an Original Intent — it is a diagnosis of the current state and a prescription for the current initiative. The actual Original Intent, present in every prior version of the plan from 2026-03-01 through 2026-03-06, was:

> "Build a configuration layer for Claude Code that enforces engineering discipline — git safety, documentation, proof-before-commit, worktree isolation — across all projects. The system should be self-governing: hooks enforce rules mechanically, agents handle specialized roles, and the observatory learns from traces to improve over time."

The replacement of the founding vision with a situational diagnosis is the single most significant finding in this reckoning. The project's north star was overwritten with a waypoint.

The original vision embedded three assumptions: (1) enforcement must be mechanical, not aspirational; (2) specialization through agents is the right abstraction; (3) the system should learn from itself (observatory). All three have been validated by the project's actual development. The original was modest and clear. The replacement is articulate but transient — it describes a problem to solve, not a destination to reach.

## III. The Journey

### Timeline

| Period | Initiative | Status | Key Decisions | Outcome |
|--------|-----------|--------|---------------|---------|
| 2025-09-02 | Initial seed ("SuperClaude Framework") | Completed | — | 4 commits, dormant until Jan 2026 |
| 2026-01-29 | Metanoia overhaul (v21, commit 2eb16a9) | Completed | — | Hook system overhauled, CLAUDE.md at peak purpose |
| 2026-02-01–02-10 | Organic hook growth (pre-plan era) | Completed | — | Hooks grew from 8 to ~17; skills added; no plan |
| 2026-02-11 | Deep research timeout fix | Completed | — | First plan-driven work (single-initiative plan) |
| 2026-02-16 | v2 Governance + Observability plan | Completed | — | First multi-initiative MASTER_PLAN |
| 2026-02-16–02-22 | Observability Overhaul (5 phases) | Completed | — | Session events, checkpoint, session-aware hooks |
| 2026-02-20 | Plan redesign to living document | Completed | — | MASTER_PLAN.md becomes append-only record |
| 2026-02-21–02-23 | State Governance, Proof Lifecycle, Bazaar | Completed | — | Hardening wave |
| 2026-02-27 | Release cleanup v2.2 | Completed | — | Decision log formalized |
| 2026-03-01 | v3 plan: Production Remediation | Completed | DEC-HOOKS-001 thru DEC-TEST-006 | 131 tests migrated, trace reliability |
| 2026-03-01–02 | State Management Reliability | Completed | 10 decisions | resolve_proof_file(), 28 new tests |
| 2026-03-02 | Hook Consolidation | Completed | DEC-AUDIT-001, DEC-TIMING-001, DEC-DEDUP-001 | Performance validation, dead code removal |
| 2026-03-02 | Statusline Information Architecture | Completed | 12 decisions | Domain-clustered HUD, cost tracking |
| 2026-03-02 | Robust State Management (plan) | Planned | 8 decisions (planning) | SQLite WAL, flock, lattice — planned |
| 2026-03-02 | Backlog Auto-Capture (plan) | Planned | 5 decisions (planning) | Auto-capture, scan, gaps report |
| 2026-03-04–05 | Production Reliability | Completed | DEC-PROD-001 thru DEC-PROD-005 | CI auto-discover, stderr capture |
| 2026-03-05 | Operational Mode System (plan) | Planned | 9 decisions (planning) | 4-tier mode taxonomy |
| 2026-03-05–06 | RSM Phases 3-4 | Completed | — | State dir migration, self-validation |
| 2026-03-06 | Dispatch Enforcement | Completed | DEC-DISPATCH-001 | Gate 1.5 blocks orchestrator writes |
| 2026-03-06 | Cross-Platform Reliability | Completed | — | Portable _file_mtime, _with_timeout |
| 2026-03-06 | SQLite Unified State Store (plan + W1) | Active (in prior plan) | DEC-SQLITE-001 thru 008 | Wave 1 core API + tests done |
| 2026-03-06 | Release prep | Completed | — | Legacy files removed |
| **2026-03-07** | **MASTER_PLAN rewrite** | **Completed** | **—** | **Plan reset: 1,908 lines to 346; 77 decisions to 4; all history erased** |
| 2026-03-07 | Prompt Purpose Restoration | Active | DEC-PROMPT-001, 002, 003 | W1 complete (shared-protocols, CLAUDE.md); W2-W3 pending |
| 2026-03-07 | Governance Signal Audit | Active | DEC-AUDIT-001 | W1 complete (signal map); W2 pending |

### Decision Density

The project has made approximately 77+ architectural decisions in 6 days of active development (2026-03-01 through 2026-03-07). That is roughly 13 decisions per day — an extraordinary rate.

- **2026-03-01 to 2026-03-02:** 30+ decisions across Production Remediation, State Management, Hook Consolidation, Statusline, and Robust State Management planning. This is the project's highest-density period — foundational infrastructure being laid at breakneck speed.
- **2026-03-02 to 2026-03-05:** 20+ decisions across RSM phases and Production Reliability. Sustained high velocity.
- **2026-03-05 to 2026-03-06:** 15+ decisions across Operational Mode System planning, Dispatch Enforcement, SQLite. Still fast but narrowing.
- **2026-03-07:** 4 decisions — but the day also saw a full plan rewrite that erased the prior 73 from the living document.

The pattern is characteristic of a single developer (or developer-AI pair) in a burst of inspired creation: high decision velocity, strong internal consistency, no committee drag. The risk is that this pace is unsustainable and that the decisions, while individually sound, may not form a coherent long-term architecture because they were made too fast to test.

### Inflection Points

**Inflection 1: The Metanoia (2026-01-29, commit 2eb16a9)**
The hook system was overhauled and CLAUDE.md was at its peak: 255 lines, rich purpose language, 8-sentence Cornerstone Belief. This is the reference point the current initiative is trying to return to. The inflection was proactive — a deliberate upgrade.

**Inflection 2: The Plan Formalization (2026-03-01)**
MASTER_PLAN.md transitioned from a task tracker to a living document with Identity, Principles, Decision Log, and structured initiatives. This was transformative — it gave the project institutional memory. The inflection was proactive and deeply constructive.

**Inflection 3: The Plan Rewrite (2026-03-07)**
The MASTER_PLAN.md was rewritten from 1,908 lines to 346 lines. The Completed Initiatives section — containing detailed summaries of 12+ completed initiatives — was emptied. The Decision Log was reset from 77 entries to 4. The Original Intent was replaced. The Principles were rewritten. This inflection was reactive (responding to the "enforcement-heavy drift" diagnosis) but its execution went far beyond the stated goal.

### Plan vs. Reality

Cross-reference data is available and reveals significant discrepancies:

1. **Decision Log erasure:** The current plan contains 4 decisions. The previous version contained 77. Code still contains @decision annotations referencing DEC-IDs (DEC-STATE-CONCURRENT-001, DEC-BENCH-001, DEC-SQLITE-TEST-001, etc.) that no longer appear in the plan. Traceability is broken for 73 decisions.

2. **Completed Initiatives erasure:** The plan's Completed Initiatives table is empty. The project has completed at least 12 initiatives (Production Remediation, State Management Reliability, Hook Consolidation, Statusline IA, Production Reliability, Dispatch Enforcement, Cross-Platform Reliability, multiple RSM phases, and more). This history is gone from the plan.

3. **Active Initiatives mismatch:** The SQLite Unified State Store initiative — with 8 planning decisions, 4 waves, Wave 1 completed, and active GitHub issues #128-#134 — is absent from the current plan. Its GitHub issues remain open. The Operational Mode System — with 9 planning decisions and 5 waves of GitHub issues #114-#118 — is also absent. The Backlog Auto-Capture initiative with 5 decisions is absent. All were active or planned in the prior plan version.

4. **GitHub Issues vs. Plan:** 81 open issues exist. The current plan references 6 issues (#143-#148). 75 open issues are orphaned from the plan, including substantial planned work for SQLite Waves 2-4, Operational Mode System Waves 1-5, and numerous bug reports.

5. **Architecture section vs. reality:** The plan documents 10 directories. The actual repository contains 25+ non-hidden directories (state, backups, debug, plans, prds, plugins, sessions, etc.) that are undocumented in the Architecture section.

6. **Agent prompt status:** The plan's Prompt Restoration initiative targets 30-40% agent prompt line count reduction (REQ-P0-002, W2-1). Current agent prompts total 1,472 lines (502 + 222 + 462 + 286) — identical to the pre-initiative baseline. The shared-protocols.md exists (87 lines) and injection works, but the extraction from agent prompts (W2-1) has not been executed. The plan shows this as blocked by W1-1 and W1-2 which are complete, so W2-1 should be ready to dispatch.

## IV. Evolution Assessment

### Intent Alignment: Weak

The project's actual Original Intent ("Build a configuration layer for Claude Code that enforces engineering discipline... The system should be self-governing: hooks enforce rules mechanically, agents handle specialized roles, and the observatory learns from traces to improve over time") has been substantially fulfilled. The hook system enforces rules (24 hooks across 10 events). The agent system dispatches specialized roles (4 agents). The observatory exists.

However, the current plan's "Original Intent" does not describe this vision — it describes a problem (enforcement-to-purpose ratio drift) and a remedy. The project is working on a valid improvement (restoring purpose in prompts), but the plan no longer contains the north star that generated all the work that preceded it.

The active initiatives (Prompt Restoration, Governance Audit) serve the original Principle of "Purpose Before Procedure" (Principle 5 in the current plan), but they do so by treating the symptom (prompt language) rather than the systemic cause (12+ initiatives of enforcement-building that were never balanced with purpose-building). The diagnosis is accurate; the plan's amnesia about its own history prevents it from seeing the full pattern.

### Principle Adherence

| Principle | Honored? | Evidence |
|-----------|----------|----------|
| Code is Truth | Yes | @decision annotations across 30+ files; hooks enforce doc headers |
| Main is Sacred | Yes | Worktree discipline enforced by guard.sh; all work in .worktrees/ |
| Deterministic Enforcement | Yes | 24 hooks, all deterministic shell scripts; no AI-based enforcement |
| Ephemeral Agents, Persistent Knowledge | Partially | Agents are ephemeral; but 73 decisions were erased from persistent knowledge |
| Purpose Before Procedure | Active work | The current initiative directly addresses this principle |

### Constructive Expansions

1. **Proof-before-commit pipeline** (not in original seed, emerged organically): The tester-guardian pipeline — implement, test, verify, commit — is a genuine innovation that wasn't in the initial concept. It creates accountability for quality that no amount of prompting achieves. Assessment: highly constructive.

2. **Statusline HUD** (emerged 2026-03-02): Not in original vision but adds genuine user value — session economics, context pressure, todo counts. Assessment: constructive, well-scoped.

3. **SQLite state store** (planned 2026-03-06): Replacing fragile flat-file state with WAL-mode SQLite is a sound infrastructure decision. Assessment: constructive, addresses real reliability issues.

### Scope Drift

1. **Operational Mode System** (9 planning decisions, 5 waves): A 4-tier mode taxonomy (Observe/Amend/Patch/Build) with escalation engine, hook integration, and anti-gaming measures. This is ambitious infrastructure for a configuration system. It was planned with full wave decomposition but never implemented — and is now absent from the plan without being explicitly parked or abandoned. Assessment: potentially over-engineered for the problem space; its quiet disappearance from the plan is concerning.

2. **Backlog Auto-Capture** (5 planning decisions): Automatic issue creation from conversation keywords. Planned but never implemented; absent from current plan. Assessment: neutral — valid idea but scope creep from core mission.

3. **The plan rewrite itself**: Rewriting the entire MASTER_PLAN.md — replacing the Original Intent, resetting 77 decisions to 4, emptying the Completed Initiatives table — is the most significant scope event in the project's history. It was not declared as a plan item, has no DEC-ID, and is not tracked in any initiative. It happened as a side effect of adding the Prompt Restoration and Governance Audit initiatives. Assessment: harmful to institutional memory.

### Non-Goal Violations

The Prompt Restoration initiative declares REQ-NOGO-003: "Adding new features or capabilities — this is restoration and optimization, not expansion." The governance signal map (W1-3) is a new capability (a reference document that didn't exist before), produced under an initiative whose non-goal explicitly excludes new capabilities. This is a minor violation — the signal map is genuinely useful — but it reveals that the initiative boundaries are porous.

More significantly: the plan rewrite (erasing history) is not listed as a goal, non-goal, or wave item of any initiative. It is an unplanned, undocumented action that had the largest impact of anything done on 2026-03-07.

### Abandoned Threads

1. **Operational Mode System:** 9 planning decisions, 5 waves (#114-#118), comprehensive deep-research validation. Silently removed from plan. The 5 GitHub issues remain open. Assessment: this was substantial intellectual work that is now orphaned. If it was wrong, that should be recorded. If it was right, it should be in the plan.

2. **Backlog Auto-Capture:** 5 planning decisions, 4 waves. Silently removed. Assessment: lower stakes, but the pattern of silent removal is the concern.

3. **SQLite Unified State Store:** 8 planning decisions, Wave 1 completed and merged, Waves 2-4 with open GitHub issues (#130-#134). Silently removed from the plan. This is actively-implemented work with merged code that the plan no longer acknowledges. Assessment: this is the most problematic abandonment because code exists.

4. **Robust State Management Phase 5 (daemon):** DEC-RSM-DAEMON-001 described a Unix socket state daemon for multi-instance coordination. Never implemented. Assessment: wise deferral — this was genuinely future work.

5. **Observatory self-improvement:** The Original Intent (real one) said "the observatory learns from traces to improve over time." The observatory directory exists but there is no evidence of it being actively used for systematic improvement. Assessment: unfulfilled founding promise.

## V. Decision Quality

### Coherence: Fragmented

The project's decisions are individually well-reasoned. Each DEC-ID has clear rationale, references the initiative it belongs to, and addresses a specific requirement. The decision chain quality within initiatives is strong — DEC-STATE-007 builds on DEC-STATE-005, DEC-RSM-FLOCK-001 leads to DEC-RSM-SQLITE-001, etc.

However, the decision record is now fragmented:
- 73 decisions exist only in git history (erased from the plan)
- 4 decisions exist in the current plan
- 30+ @decision annotations in code reference DEC-IDs that the plan no longer contains
- The Decision Log header says "Append-only record" but it was replaced, not appended

### Notable Decision Chains

**Strong chain — State Management evolution:**
DEC-STATE-007 (resolve_proof_file) -> DEC-STATE-008 (validate_state_file) -> DEC-STATE-001 (state-lib.sh centralization) -> DEC-RSM-FLOCK-001 (advisory locks) -> DEC-RSM-SQLITE-001 (SQLite WAL) -> DEC-SQLITE-001 through DEC-SQLITE-008 (implementation decisions). This is a 14-decision chain spanning 3 initiatives over 5 days, showing progressive deepening of a single architectural concern. Excellent coherence.

**Broken chain — Plan continuity:**
The Decision Log describes itself as "append-only" and "the project's institutional memory." On 2026-03-07, 73 entries were removed. No decision was recorded about this removal. The mechanism designed to prevent institutional amnesia experienced it.

### Decision Gaps

1. **No decision recorded for the plan rewrite.** The largest structural change in the project's history — replacing the Original Intent, resetting the Decision Log, emptying Completed Initiatives — has no DEC-ID.

2. **No decision recorded for dropping SQLite, Operational Mode, and Backlog initiatives.** Three initiatives with 22 combined planning decisions were removed without explanation.

3. **No decision about the "Created" date change.** The plan's Created date changed from 2026-03-01 to 2026-03-07 during the rewrite. The project existed for weeks before this. This obscures the project's actual age.

### Traceability

Code-to-plan traceability is currently broken. @decision annotations in code reference at least 25 distinct DEC-IDs (DEC-STATE-CONCURRENT-001, DEC-BENCH-001, DEC-SQLITE-TEST-001, DEC-GUARDIAN-001, DEC-PROOF-RACE-001, DEC-FETCH-004, DEC-DISPATCH-EXTRACT-001, etc.) that do not appear in the current Decision Log. The annotations are accurate; the plan is incomplete.

## VI. Project Health

| Indicator | Rating | Evidence |
|-----------|--------|----------|
| Vitality | Thriving | 725 commits, 13 commits today alone, 2 active initiatives, 3 Wave 1 items completed today |
| Focus | Diffuse | 2 active initiatives with unclear relationship to 3 silently-dropped initiatives; 81 open GitHub issues with 75 orphaned from the plan |
| Momentum | Accelerating | 50-89 commits/day in peak periods (Mar 2, Mar 5-6); initiative completion rate is high when work is in progress |
| Coherence | Fragmented | Plan-to-code traceability broken for 73 decisions; plan does not acknowledge existing code (SQLite W1, state-lib.sh) |
| Sustainability | Straining | Decision rate of 13/day is extraordinary; plan rewrites rather than plan evolution suggest accumulated pressure |

## VII. Trajectory

### Current Vector

The project is currently pointed at prompt optimization — restoring purpose language, reducing cognitive noise, improving model output quality. This is a meta-concern: not building new capabilities but improving how existing capabilities are expressed to the model.

Simultaneously, substantial infrastructure work (SQLite state store, operational mode system) exists in the codebase and issue tracker but has been removed from the plan's awareness. The project is bifurcated: the plan says "optimize prompts and audit governance," while the codebase and issues say "we're also mid-migration to SQLite and have a planned mode system."

### Projected Destination

If current patterns continue for 3-6 months, this project becomes a highly polished but complex governance harness with:
- Excellent prompt quality (the current initiative will likely succeed)
- A growing gap between plan and reality (the pattern of plan-rewriting rather than plan-evolving will compound)
- Orphaned infrastructure (SQLite migration half-done, mode system planned but untracked)
- Increasing decision amnesia (each plan rewrite loses more history)
- A devotional identity that may conflict with the system's increasing bureaucratic weight

### Intent-Trajectory Gap

The gap between the original stated intent ("self-governing configuration layer with mechanical enforcement, specialized agents, and observatory learning") and the actual trajectory is moderate. The enforcement and agent parts are strong. The observatory learning is unrealized. The current trajectory is pointed at prompt aesthetics rather than capability completion — but prompt quality is a legitimate concern that the original intent doesn't address because the original intent predates the problem.

The more concerning gap is between the project's own Principle 4 ("Ephemeral Agents, Persistent Knowledge") and the plan rewrite that deleted persistent knowledge. The project's actions contradict its stated values.

## VIII. The Reckoning

### Verdict: Drifting constructively

The project is building genuine value. The hook system works. The agent dispatch works. The proof pipeline works. The prompt restoration initiative is addressing a real problem (enforcement-to-purpose ratio) with a well-structured plan. The governance signal map is useful infrastructure. These are constructive additions to a system that has already proven itself through 12+ completed initiatives.

But the drift is real. The project rewrote its own memory. Seventy-three decisions — the institutional knowledge that Principle 4 ("Ephemeral Agents, Persistent Knowledge") exists to protect — were erased from the living document. Three initiatives with 22 combined planning decisions were silently dropped. The Original Intent was replaced with a problem statement. The "Created" date was reset. The Completed Initiatives section was emptied. None of these actions were planned, tracked, or decided through the project's own governance process.

The irony is sharp: a project whose core purpose is enforcing engineering discipline — git safety, documentation, proof-before-commit — rewrote its own foundational document without a plan, without a decision record, and without preserving its history. The hooks that enforce discipline on code changes did not prevent this because MASTER_PLAN.md is treated as a planning document, not a protected artifact.

This is constructive drift because the work being done is genuinely valuable and the system is getting better at its core mission. But it is drift because the project is losing coherence between its plan, its code, its issues, and its own history. A system that cannot remember what it has built cannot reliably decide what to build next.

### What to Celebrate

1. **The proof pipeline is a genuine innovation.** The implement-test-verify-commit chain with mechanical enforcement (task-track.sh denies Guardian dispatch until verification, guard.sh denies git commit until proof exists) is a real contribution to AI agent governance. It works. 10 decisions and 28 tests validate it.

2. **The hook consolidation was masterful.** Going from 17 hooks to 4 entry points + 6 domain libraries with lazy loading, reducing per-turn latency by ~350ms, while maintaining 159 passing tests — this is professional-grade infrastructure work completed in a single day.

3. **The prompt restoration initiative is well-structured.** DEC-PROMPT-002 (shared protocol injection via subagent-start.sh) is an elegant solution: deterministic injection at dispatch time means agents see shared protocols without needing to remember. The "What Matters" section in the restored CLAUDE.md (DEC-PROMPT-003) genuinely articulates quality-of-thought expectations that were missing. The full Cornerstone Belief restoration brings back the project's voice.

4. **Decision quality within initiatives is consistently strong.** Rationales are substantive, not performative. "We chose SQLite WAL because zero new deps on macOS, atomic CAS via BEGIN IMMEDIATE, eliminates jq race" (DEC-RSM-SQLITE-001) is the kind of decision record that serves Future Implementers.

### What to Confront

1. **The plan rewrite destroyed the project's institutional memory.** This is the hardest truth. The MASTER_PLAN.md went from 1,908 lines (with 77 decisions, 12+ completed initiative summaries, detailed wave plans for 3 active initiatives) to 346 lines (with 4 decisions, an empty completed initiatives table, and no acknowledgment of prior work). Principle 4 says "Ephemeral Agents, Persistent Knowledge." The plan rewrite is the most significant violation of any Principle in the project's history. The prior version exists in git — but git is not the living document. The plan is supposed to be the project's memory; it now has amnesia.

2. **Three initiatives were silently abandoned.** The SQLite Unified State Store (with merged Wave 1 code), the Operational Mode System (with 9 planning decisions and deep-research validation), and Backlog Auto-Capture (with 5 planning decisions) were removed from the plan without being parked, cancelled, or decided upon. Their GitHub issues (#114-#118, #128-#134) remain open. This is not "parked" — parked items are recorded. This is forgotten.

3. **The Original Intent was overwritten.** The founding vision — "Build a configuration layer for Claude Code that enforces engineering discipline" — was replaced with a problem description about prompt enforcement ratios. This is the equivalent of rewriting a company's mission statement to say "we need to fix our marketing." The Original Intent section is described in the plan's own template as "the sacred text; the vision as first stated." It was violated by the plan itself.

4. **81 open issues with only 6 tracked in the plan.** The GitHub issue tracker has become a graveyard. Issues #110-#112 (CI failures), #113 (deep-research hang), #121 (cross-platform CI), #123 (CI failing on main), #124 (stale worktree), #126, #135-#142 — none of these appear in any initiative. The project's Sacred Practice #9 says "Track in Issues, Not Files." The issues exist; they are not tracked in the plan.

5. **The "Created" date was changed.** The plan's Created date went from 2026-03-01 (when the living-document MASTER_PLAN was formalized) to 2026-03-07 (when the rewrite happened). The project's actual age — 36 days from first commit, 6 days from formalized plan — is obscured. This matters because maturity assessment depends on accurate timeline.

### What to Do Next

1. **Restore the Original Intent.** Replace the current "Original Intent" (which is a problem diagnosis) with the actual founding vision: "Build a configuration layer for Claude Code that enforces engineering discipline — git safety, documentation, proof-before-commit, worktree isolation — across all projects. The system should be self-governing: hooks enforce rules mechanically, agents handle specialized roles, and the observatory learns from traces to improve over time." The current diagnosis belongs in the Prompt Restoration initiative's preamble, not in the project's north star.

2. **Restore the Decision Log.** The 73 erased decisions should be restored to the Decision Log from `git show c2e0121:MASTER_PLAN.md`. This is the project's institutional memory. It was described as "append-only" for good reason. If the log is too long, compress old entries — but do not delete them.

3. **Restore the Completed Initiatives table.** The summaries of Production Remediation, State Management Reliability, Hook Consolidation, Statusline IA, and all other completed work should be restored. These are 5-line compressed summaries that cost nothing and preserve institutional memory. The current empty table contradicts the plan's own stated pattern: "Completed initiatives compress to ~5 lines and move to the Completed section — the plan is never discarded."

4. **Explicitly park or reactivate the dropped initiatives.** SQLite Unified State Store (Wave 1 merged, Waves 2-4 pending), Operational Mode System (planned, 9 decisions, 5 waves of open issues), and Backlog Auto-Capture (planned, 5 decisions) need to be either (a) restored as Active initiatives, (b) added to the Parked Issues section with rationale, or (c) formally cancelled with a DEC-ID explaining why. Silent removal is not an acceptable disposition for planned work with open issues.

5. **Triage the 75 orphaned GitHub issues.** Close what's resolved, park what's deferred, and connect what's active to plan initiatives. A backlog of 81 open issues with only 6 tracked in the plan is a governance gap that the project's own Sacred Practice #9 prohibits.

---

*This reckoning reads and assesses. It does not modify the MASTER_PLAN.md, code, issues, or any other project artifact.*
