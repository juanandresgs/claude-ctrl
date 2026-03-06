# PRD: Operational Mode System for Claude Code Deterministic Harnessing

**Status:** Draft
**Author:** PRD Skill (via Claude Code)
**Date:** 2026-03-05
**GitHub Issue:** #109
**Version:** 1.0

---

## 1. Problem Statement

### The Core Problem

The Claude Code deterministic harnessing framework (`~/.claude`) enforces a single operational envelope for all work: the full Planner-Implementer-Tester-Guardian pipeline with worktree isolation, proof gates, and multi-agent approval chains. This envelope is correct for feature development but creates 3-10x overhead for work that does not carry the risk profile that justifies it.

### Who Experiences This and How Often

**Primary persona: The Power User (daily operator)**

This user runs 10-30 Claude Code sessions per day across projects. Roughly 60-70% of their interactions are NOT feature development:

- **Research and exploration** (~25% of sessions): Reading code, analyzing architecture, running diagnostics, exploring options. Currently triggers session-init, prompt-submit, stop hooks, and statusline overhead despite being read-only. No governance is actually needed beyond the existing safety denials (nuclear deny, `/tmp/` redirect).

- **Configuration and documentation** (~20%): Editing CLAUDE.md, updating settings.json, fixing typos in docs, managing .gitignore. Currently blocked by branch-guard (cannot write source on main), forcing worktree creation for changes that are inherently low-risk and atomic. The existing "trivial edit" exception in DISPATCH.md is instructional only — the model can ignore it, and the hooks cannot distinguish trivial from non-trivial.

- **Backlog and project management** (~15%): Creating issues, triaging backlogs, reviewing PR status. Pure orchestration work that triggers the full hook chain despite requiring zero write governance.

- **Small fixes** (~10%): 1-5 line changes to existing code that need commits but do not warrant worktree isolation, full tester verification, or multi-phase planning. The current system forces these through the same pipeline as a multi-file feature.

**Secondary persona: New adopter**

The full-governance-always experience creates a steep onboarding curve. Users attempting simple tasks hit branch-guard denials, plan-check blocks, and test-gate warnings before understanding why. The system should demonstrate proportional governance — lightweight for lightweight tasks, heavy for heavy tasks — so users build trust incrementally.

### Cost of Not Solving

1. **Token waste**: Full hook chains fire on every tool call regardless of operational context. A read-only research session pays ~276ms per prompt (prompt-submit) + ~93ms per Bash (pre-bash) + ~1.1s per response (stop.sh) with no governance benefit. Over 20 Bash calls, that is ~3.9s of pure overhead.

2. **User friction**: Worktree creation for a 1-line config edit requires: orchestrator assessment, worktree add, implementer dispatch (85 turns budget), tester dispatch (40 turns), guardian dispatch (35 turns). Minimum 3 agent dispatches for what should be a direct edit.

3. **Context window pressure**: Agent dispatches consume context. A simple config change that triggers Planner + Implementer + Tester + Guardian uses 4 Task tool calls, each adding subagent prompts, hook injections, and trace overhead to the conversation. This crowds out actual user intent in longer sessions.

4. **Model self-governance failure**: The current "trivial edit" exception is instruction-only. Under context pressure (late in session, after compaction), the model may either (a) route everything through worktrees even when unnecessary (over-governance), or (b) attempt to skip governance when it should apply (under-governance). Neither failure mode is acceptable.

### Evidence

- GitHub Issue #109 explicitly requests this capability
- DISPATCH.md line 29 acknowledges the gap: "Editing `~/.claude/` config — Orchestrator — Trivial edits only (gitignore, 1-line, typos). Features use worktrees."
- The meta-repo (`~/.claude`) already has ad-hoc exemptions scattered across hooks: `is_claude_meta_repo()` bypasses test-status gates, proof-status gates, and checkpoint creation. This proves the system already recognizes that one-size governance does not fit all work.
- The CYCLE_MODE protocol (auto-flow vs phase-boundary) is the first attempt at mode differentiation — it varies the agent chain but not the underlying hook governance.

---

## 2. Goals

### User Goals

1. **Proportional governance**: Work that carries less risk should require less ceremony. A user editing `.gitignore` should experience zero agent dispatches and zero worktree overhead. A user building a multi-file feature should experience the full pipeline. Measurement: overhead ratio (governance overhead / actual work) drops below 0.5 for Mode 1-2 tasks (currently ~3.0 for all tasks).

2. **Transparent classification**: The user should always know which mode is active and why. No silent mode selection that produces surprising blocks or surprising leniency. Measurement: mode is visible in statusline; mode transitions logged to `.audit-log`.

3. **Confidence in safety**: Lightweight modes must NEVER allow the model to bypass safety invariants. The user should trust that escalation catches risk signals even when they did not anticipate them. Measurement: zero safety-invariant violations across all modes (verified via test suite).

### Business Goals

4. **Reduced token cost**: Sessions that do not require full governance should consume proportionally fewer tokens. Measurement: 40% reduction in average tokens-per-session for non-feature work (research, config, backlog).

5. **Faster adoption**: New users complete their first successful interaction in under 2 minutes without hitting governance walls. Measurement: first-session success rate increases from estimated 60% to 90%.

---

## 3. Non-Goals

1. **User-selectable mode switching**: The system auto-classifies and auto-escalates. Users do NOT manually select modes. Rationale: manual selection lets the model (or user) accidentally under-govern. The user can override via a one-time prompt keyword ("use full mode"), but the default is always auto-classification. Deferring interactive mode selection prevents an escape hatch that undermines safety.

2. **Per-project mode configuration**: Mode selection is based on the work being done, not the project. A config edit in a production monorepo and a config edit in `~/.claude` should both be classified the same way. Rationale: per-project configuration creates maintenance burden and configuration drift. The classification heuristics should be universal.

3. **Reducing hook execution for heavyweight modes**: The full Planner-Implementer-Tester-Guardian pipeline with all hooks remains unchanged for Mode 4 (full-feature). This PRD does not optimize the heavyweight path — that is a separate performance initiative. Rationale: the heavyweight path is already optimized by the Metanoia refactor (74% fewer shell processes). Further optimization is orthogonal.

4. **Automatic mode downgrade**: Modes can only escalate (lightweight to heavyweight), never de-escalate within a single task. Once escalated, the task completes at the higher mode. Rationale: downgrade creates a loophole where the model starts heavy, recognizes it is "just a config edit," and downgrades to skip governance. One-way escalation is the only safe direction.

5. **Replacing the agent system**: Modes augment agent dispatch, not replace it. The Planner, Implementer, Tester, and Guardian agents remain unchanged. Modes determine WHICH agents are dispatched and WHICH hooks engage, not how agents behave internally.

---

## 4. User Journeys

### Journey 1: Research and Exploration (Mode 1 — Observe)

**As a** power user exploring a codebase, **I want** to read files, search code, and run diagnostic commands **so that** I can understand the system without triggering governance overhead.

**Acceptance Criteria:**
- Given the user asks "show me the architecture of the auth module"
- When the orchestrator classifies this as Mode 1 (read-only tools: Read, Grep, Glob, WebFetch, WebSearch)
- Then no agents are dispatched, no worktree is created, and the pre-write/post-write hooks never fire
- And the statusline shows `M1:observe`
- And if the user then says "now fix the bug in auth.ts," the mode escalates to Mode 3 or 4

**Edge cases:**
- Bash commands that are read-only (`git status`, `ls`, `cat`) should stay in Mode 1
- Bash commands that write (`echo > file`, `sed -i`) should trigger escalation
- A session that starts as Mode 1 and never writes anything should never trigger write-governance hooks

### Journey 2: Configuration and Documentation Edit (Mode 2 — Amend)

**As a** power user updating a config file or fixing a documentation typo, **I want** to make the edit directly on the current branch with Guardian approval for the commit **so that** I avoid the overhead of worktree creation, tester dispatch, and proof gates.

**Acceptance Criteria:**
- Given the user says "add `*.log` to .gitignore"
- When the orchestrator classifies this as Mode 2 (non-source file edit, small scope)
- Then branch-guard allows the write on main (because the file is not source code)
- And plan-check is skipped (no MASTER_PLAN.md required for config edits)
- And test-gate is skipped (config files do not affect test outcomes)
- And doc-gate is advisory-only (config files do not require @decision annotations)
- And Guardian is dispatched for the commit (approval gate preserved)
- And the statusline shows `M2:amend`

**Edge cases:**
- Editing `CLAUDE.md` is Mode 2 (markdown, not source)
- Editing `hooks/guard.sh` is NOT Mode 2 (source code in `$SOURCE_EXTENSIONS`) — escalates to Mode 3+
- Writing a NEW markdown file at project root triggers Sacred Practice #9 advisory (not blocked)
- If the edit grows beyond 50 lines, doc-gate engages for @decision enforcement (escalation signal)

### Journey 3: Small Fix (Mode 3 — Patch)

**As a** power user fixing a small bug in source code, **I want** to make the change in an isolated context with testing but without full planning overhead **so that** I get the safety of test verification without the ceremony of a multi-phase plan.

**Acceptance Criteria:**
- Given the user says "fix the off-by-one in statusline.sh line 42"
- When the orchestrator classifies this as Mode 3 (source code edit, small scope, no plan needed)
- Then the Implementer is dispatched into a worktree with `CYCLE_MODE: auto-flow`
- And branch-guard is active (source writes on main are blocked — worktree required)
- And test-gate is active (tests must pass before commit)
- And plan-check is relaxed: existing `MASTER_PLAN.md` satisfies the gate (no staleness check); absent `MASTER_PLAN.md` is allowed for bug fixes (new bypass: `MODE=patch` in hook context)
- And the Tester verifies and auto-verify can apply
- And Guardian commits
- But no Planner dispatch occurs
- And the statusline shows `M3:patch`

**Edge cases:**
- A "small fix" that touches 5+ files escalates to Mode 4
- A "small fix" that fails tests repeatedly (3+ test-gate strikes) escalates to Mode 4
- If the user says "this is a feature, not a fix," the mode escalates to Mode 4 regardless of scope

### Journey 4: Full Feature Development (Mode 4 — Build)

**As a** power user building a new feature, **I want** the full governance pipeline **so that** every aspect of the work is planned, isolated, tested, verified, and approved.

**Acceptance Criteria:**
- Given the user says "implement the operational mode system from the PRD"
- When the orchestrator classifies this as Mode 4 (new feature, multi-file, requires planning)
- Then the full pipeline engages: Planner, Implementer, Tester, Guardian
- And all hooks fire at full strength (branch-guard, plan-check, test-gate, mock-gate, doc-gate, checkpoint)
- And worktree isolation is mandatory
- And MASTER_PLAN.md is required before source writes
- And the statusline shows `M4:build`

**Edge cases:**
- Mode 4 is the default when classification is uncertain (conservative fallback)
- User explicitly requesting "use full mode" forces Mode 4 regardless of classification
- CYCLE_MODE (auto-flow vs phase-boundary) operates within Mode 4 as it does today

### Journey 5: Escalation During Work (Cross-Mode)

**As a** power user who started with a simple task that grew in scope, **I want** the system to automatically escalate governance **so that** I never accidentally bypass safety mechanisms.

**Acceptance Criteria:**
- Given the user is in Mode 2 (amend) editing CLAUDE.md
- When they then say "actually, let's also refactor the hook that reads this config"
- Then the system detects source code intent and escalates to Mode 3 or 4
- And the escalation is logged to `.audit-log` with reason
- And the user is informed: "Escalating to Mode 3 (patch): source code changes detected"
- And all Mode 3 governance activates for the remainder of the task

---

## 5. Requirements

### Must-Have (P0)

#### P0-1: Mode Taxonomy

Define exactly 4 operational modes with clear boundaries:

| Mode | Name | Risk Profile | Description |
|------|------|-------------|-------------|
| 1 | **Observe** | None | Read-only exploration. No file writes, no git mutations, no agent dispatches. |
| 2 | **Amend** | Low | Non-source file edits (config, docs, markdown). Direct commit via Guardian. No worktree. No tester. |
| 3 | **Patch** | Medium | Small source code changes (1-3 files, targeted fix). Worktree + Implementer + Tester + Guardian. No Planner. |
| 4 | **Build** | High | Multi-file features, new capabilities. Full pipeline: Planner + Implementer + Tester + Guardian + all hooks. |

**Acceptance criteria:**
- [ ] Each mode has a one-line description, example triggers, risk profile, and component contract
- [ ] Mode taxonomy is documented in a new `docs/MODES.md` (referenced from CLAUDE.md and DISPATCH.md)
- [ ] The taxonomy is extensible (modes can be added in future without restructuring)

#### P0-2: Mode Classification Engine

Implement a deterministic classifier in the hook system that selects the operational mode based on observable signals. The classifier runs at two points:

1. **Prompt-time classification** (in `prompt-submit.sh`): Analyzes the user's prompt for intent signals. Writes initial mode to `.op-mode` state file.
2. **Tool-time validation** (in `pre-write.sh` and `pre-bash.sh`): Validates that the current tool call is consistent with the classified mode. Escalates if not.

**Classification heuristics (ordered by signal strength):**

| Signal | Mode Assignment | Confidence |
|--------|----------------|------------|
| User explicitly says "just research" / "explore" / "show me" | Mode 1 | High |
| Prompt contains no write-intent verbs AND no file modification references | Mode 1 | Medium |
| Target files are ALL non-source (config, markdown, gitignore, settings) | Mode 2 | High |
| User says "fix typo" / "update config" / "edit docs" | Mode 2 | Medium |
| User references specific source file + "fix" / "bug" / "patch" + small scope | Mode 3 | Medium |
| User says "implement" / "build" / "create" / "add feature" / "new" | Mode 4 | High |
| Prompt references MASTER_PLAN.md or issue numbers | Mode 4 | High |
| Ambiguous or mixed signals | Mode 4 | Low (conservative fallback) |

**Acceptance criteria:**
- [ ] Classifier is deterministic (same prompt always produces same mode)
- [ ] Classifier output includes mode number and confidence level
- [ ] Ambiguous prompts default to Mode 4 (build) — never to a lighter mode
- [ ] User override keyword "full mode" or "use build mode" forces Mode 4
- [ ] Classification is logged to `.audit-log` with reason string
- [ ] Classification runs in <100ms (must not add perceptible latency to prompt-submit)

#### P0-3: Component Contract Matrix

Define which subsystems engage per mode. This is the enforcement specification — hooks read `.op-mode` and adjust their behavior accordingly.

| Component | Mode 1 (Observe) | Mode 2 (Amend) | Mode 3 (Patch) | Mode 4 (Build) |
|-----------|-------------------|-----------------|-----------------|-----------------|
| **Worktree isolation** | No | No | Yes | Yes |
| **Planner dispatch** | No | No | No | Yes |
| **Implementer dispatch** | No | No | Yes | Yes |
| **Tester dispatch** | No | No | Yes | Yes |
| **Guardian dispatch** | No | Yes (commit only) | Yes | Yes |
| **branch-guard** (pre-write) | N/A (no writes) | Relaxed: allows non-source on main | Active | Active |
| **plan-check** (pre-write) | N/A | Skipped | Relaxed: no staleness check | Active |
| **test-gate** (pre-write) | N/A | Skipped | Active | Active |
| **mock-gate** (pre-write) | N/A | Skipped | Active | Active |
| **doc-gate** (pre-write) | N/A | Advisory only | Active | Active |
| **checkpoint** (pre-write) | N/A | Skipped | Active | Active |
| **guard.sh safety** (pre-bash) | Active (always) | Active (always) | Active (always) | Active (always) |
| **proof-status gate** | N/A | Skipped | Active | Active |
| **lint** (post-write) | N/A | Active | Active | Active |
| **track** (post-write) | N/A | Active | Active | Active |
| **stop.sh** | Minimal: session-summary only | Full | Full | Full |

**Acceptance criteria:**
- [ ] Matrix is implemented as conditional logic in each hook (reading `.op-mode`)
- [ ] Each hook documents which mode checks it performs (in `@decision` annotation)
- [ ] Test suite validates every cell of the matrix (4 modes x N hooks)
- [ ] Component contracts are mechanically enforced, not instructional

#### P0-4: Escalation Engine

Implement automatic mode escalation when risk signals appear. Escalation is one-way and immediate.

**Escalation triggers:**

| Current Mode | Trigger | Escalates To | Mechanism |
|-------------|---------|-------------|-----------|
| 1 (Observe) | Write/Edit tool call on ANY file | 2 (Amend) or 3/4 based on file type | pre-write.sh reads `.op-mode`, detects mismatch, escalates |
| 1 (Observe) | Bash command that modifies files (`sed -i`, `echo >`, `rm`) | 2+ based on target | pre-bash.sh detects write intent |
| 2 (Amend) | Write/Edit on source file (`$SOURCE_EXTENSIONS` match) | 3 (Patch) or 4 (Build) | pre-write.sh branch-guard logic |
| 2 (Amend) | Edit grows beyond 50 lines in a source file | 3 (Patch) | doc-gate detects @decision-required threshold |
| 2 (Amend) | Agent dispatch requested (Implementer/Tester) | 3 (Patch) | task-track.sh detects mode mismatch |
| 3 (Patch) | Touches 5+ files (scope expansion) | 4 (Build) | track.sh counts session files, escalates |
| 3 (Patch) | 3+ test-gate strikes (persistent test failures) | 4 (Build) | test-gate strike counter exceeds threshold |
| 3 (Patch) | User references MASTER_PLAN.md or plan language | 4 (Build) | prompt-submit.sh reclassifies |
| Any | User says "use full mode" / "use build mode" | 4 (Build) | prompt-submit.sh keyword detection |

**Anti-gaming protections:**

The escalation engine must prevent the model from staying in a lightweight mode to avoid governance:

1. **Source file detection is authoritative**: If `is_source_file()` returns true, the file IS source code regardless of what the model claims. Hook enforcement, not model judgment.
2. **Escalation is irreversible within a task**: Once `.op-mode` is written to a higher mode, it cannot be written to a lower mode. The state file uses a monotonic lattice: `observe < amend < patch < build`. `write_op_mode()` function enforces `new >= current`.
3. **Conservative fallback**: Any classification failure (corrupt `.op-mode`, missing file during tool-time validation) defaults to Mode 4.
4. **Audit trail**: Every escalation writes to `.audit-log` with timestamp, from-mode, to-mode, and trigger reason.

**Acceptance criteria:**
- [ ] All escalation triggers are implemented in the relevant hooks
- [ ] Monotonic lattice is enforced by `write_op_mode()` (new >= current)
- [ ] Classification failure defaults to Mode 4
- [ ] Escalation is visible to user (advisory context or statusline update)
- [ ] Test suite covers every escalation path (trigger + resulting mode)

#### P0-5: Cross-Mode Safety Invariants

These invariants hold across ALL modes, including Mode 1. They are NEVER relaxed.

1. **Nuclear deny**: `guard.sh` Check 0 (filesystem destruction, fork bombs, SQL drops, remote code execution) fires unconditionally in all modes.
2. **No `/tmp/`**: `guard.sh` Check 1 (`/tmp/` → project `tmp/`) fires unconditionally.
3. **No `--force` to main**: `guard.sh` Check 3 (force push protection) fires unconditionally.
4. **No destructive git**: `guard.sh` Check 4 (`reset --hard`, `clean -f`, `branch -D`) fires unconditionally.
5. **Commits go through Guardian**: In any mode that produces commits (Modes 2-4), Guardian dispatch is required. No direct `git commit` from orchestrator or implementer.
6. **Secrets protection**: `settings.json` deny rules for `.env`, `secrets/`, `credentials` are active in all modes.
7. **Human gate for verification**: `.proof-status` writes are restricted to `prompt-submit.sh` (user approval) and `check-tester.sh` (auto-verify) in all modes. `guard.sh` Check 9 blocks Bash writes; `pre-write.sh` Gate 0 blocks Write/Edit writes.
8. **Session lifecycle**: `session-init.sh`, `prompt-submit.sh`, `stop.sh`, and `session-end.sh` fire in all modes. Context injection and cleanup are universal.
9. **Audit trail**: `.audit-log` records mode classification, escalation, and key events in all modes.

**Acceptance criteria:**
- [ ] All 9 invariants are documented in `docs/MODES.md`
- [ ] Test suite validates each invariant fires in Mode 1 (the lightest mode)
- [ ] No hook bypass path can disable an invariant based on `.op-mode`
- [ ] Invariant violations are treated as P0 bugs

#### P0-6: State File Design

New state file: `.op-mode`

| Field | Format | Example |
|-------|--------|---------|
| mode | `1\|2\|3\|4` | `3` |
| confidence | `high\|medium\|low` | `medium` |
| timestamp | epoch seconds | `1741193390` |
| reason | free text | `source file referenced: hooks/guard.sh` |

**Format:** `mode|confidence|timestamp|reason`
**Example:** `3|medium|1741193390|source file referenced: hooks/guard.sh`

**Lifecycle:**
- Created by `prompt-submit.sh` on first prompt of a task
- Updated (escalated only) by `pre-write.sh`, `pre-bash.sh`, `task-track.sh`, `prompt-submit.sh`
- Read by all hooks that have mode-conditional behavior
- Cleared by `session-init.sh` on session start (each session starts fresh)
- Registered in `state-registry.sh`

**Acceptance criteria:**
- [ ] State file uses `atomic_write()` (DEC-INTEGRITY-004)
- [ ] `write_op_mode()` enforces monotonic escalation
- [ ] `read_op_mode()` returns Mode 4 on missing/corrupt file
- [ ] File is registered in `state-registry.sh`
- [ ] Test suite validates write-read cycle, escalation enforcement, and corruption handling

### Nice-to-Have (P1)

#### P1-1: Statusline Mode Display

Show the active mode in the status bar: `M1:observe`, `M2:amend`, `M3:patch`, `M4:build`.

**Acceptance criteria:**
- [ ] `statusline.sh` reads `.op-mode` and includes mode indicator
- [ ] Mode transitions update the statusline cache immediately
- [ ] Escalation is visually distinct (e.g., `M2:amend -> M3:patch` shown briefly)

#### P1-2: Mode-Aware Agent Turn Budgets

Reduce turn budgets for lighter modes to prevent waste:

| Agent | Mode 2 | Mode 3 | Mode 4 |
|-------|--------|--------|--------|
| Guardian | 15 | 25 | 35 |
| Implementer | N/A | 50 | 85 |
| Tester | N/A | 25 | 40 |
| Planner | N/A | N/A | 65 |

**Acceptance criteria:**
- [ ] `docs/DISPATCH.md` includes mode-specific turn budget table
- [ ] Orchestrator applies mode-specific budgets at dispatch time
- [ ] Turn budgets are instructional (in DISPATCH.md), not mechanically enforced

#### P1-3: Mode-Aware Stop Hook

Reduce stop.sh overhead for lighter modes:
- Mode 1: Skip decision audit (surface.sh logic), skip forward-motion check. Only session-summary.
- Mode 2: Skip decision audit. Include session-summary and forward-motion.
- Mode 3-4: Full stop.sh behavior (no change).

**Acceptance criteria:**
- [ ] stop.sh reads `.op-mode` and conditionally skips heavy logic
- [ ] Session-summary always fires (no mode exemption)
- [ ] Performance improvement measurable: Mode 1 stop.sh < 200ms (currently ~1.1s)

#### P1-4: Prompt-Submit Fast Classification

Optimize prompt-submit.sh to classify mode BEFORE the full hook chain loads:

1. Read prompt
2. Quick keyword scan (< 10ms)
3. Write `.op-mode`
4. Then load full libraries for other prompt-submit logic

**Acceptance criteria:**
- [ ] Mode classification adds < 20ms to prompt-submit latency
- [ ] Classification runs before `require_*()` calls (follows DEC-PROMPT-FAST-001 pattern)

### Future Considerations (P2)

#### P2-1: Mode Analytics

Track mode distribution across sessions to identify optimization opportunities:
- What percentage of sessions are each mode?
- How often do escalations occur? Which triggers fire most?
- What is the average overhead per mode?

Data stored in `.op-mode-analytics` (append-only, trimmed at session-end like `.audit-log`).

#### P2-2: Project-Level Mode Overrides

Allow projects to set minimum mode floors via `.claude/project-modes.json`:
```json
{
  "minimum_mode": 3,
  "source_extensions_override": ["*.tf", "*.yaml"]
}
```

This would let production-critical projects enforce heavier governance even for config files.

#### P2-3: Mode-Aware Context Injection

Reduce context injection volume for lighter modes:
- Mode 1: Inject only git state (skip plan, worktrees, todo HUD, agent findings)
- Mode 2: Inject git state + plan status (skip agent findings, full worktree roster)

This reduces token consumption for lightweight sessions.

#### P2-4: Compound Task Mode Resolution

Handle prompts that contain multiple sub-tasks at different risk levels:
- "Update the README and also fix the auth bug" — README is Mode 2, auth fix is Mode 3+
- Classification should take the maximum mode across all detected sub-tasks
- Individual sub-task completion should not downgrade the session mode

---

## 6. Success Metrics

### Leading Indicators (days to weeks post-launch)

| Metric | Target | Stretch | Measurement |
|--------|--------|---------|-------------|
| Mode 1 sessions: zero write-hook fires | 100% | 100% | Audit log analysis |
| Mode 2 sessions: zero worktree creation | 100% | 100% | Audit log analysis |
| Mode 2 sessions: zero tester dispatch | 100% | 100% | Audit log analysis |
| Escalation accuracy: false negatives (should have escalated, didn't) | 0 | 0 | Manual review of 50 sessions |
| Escalation accuracy: false positives (escalated unnecessarily) | < 20% | < 10% | Manual review of 50 sessions |
| Mode classification latency | < 20ms | < 10ms | hook-timing-report.sh |
| Safety invariant violations across all modes | 0 | 0 | Test suite (automated) |

### Lagging Indicators (weeks to months)

| Metric | Target | Stretch | Measurement |
|--------|--------|---------|-------------|
| Average tokens per non-feature session | 40% reduction | 60% reduction | Session token tracking |
| Average time for Mode 2 task (config edit → committed) | < 60 seconds | < 30 seconds | Trace analysis |
| User overrides to Mode 4 (classification was wrong) | < 5% of sessions | < 2% | Prompt keyword tracking |
| Test suite coverage of mode matrix | 100% of P0-3 cells | All P1 cells too | Test count |

### Evaluation Schedule

- **1 week post-launch**: Verify zero safety invariant violations. Check escalation accuracy on 20 sessions.
- **2 weeks post-launch**: Measure token reduction for non-feature sessions. Review escalation false-positive rate.
- **1 month post-launch**: Full metrics evaluation. Decide on P1 items based on real usage patterns.

---

## 7. Open Questions

### Blocking (must answer before implementation)

1. **Mode persistence across compaction** (Engineering): Should `.op-mode` survive compaction via `compact-preserve.sh`, or should the mode be re-classified after compaction? Re-classification is safer (fresh assessment of context), but loses the escalation history. **Recommendation:** Re-classify after compaction. The monotonic lattice means a compacted session cannot downgrade, but a fresh classification may under-classify if the compaction summary is ambiguous. Include a `## Previous Mode: N` hint in the preserved context to bias the classifier.

2. **Mode 2 branch-guard relaxation scope** (Engineering): Currently `branch-guard` blocks ALL source file writes on main. Mode 2 relaxes this for non-source files. But some non-source files are still high-impact: `settings.json`, `package.json`, `Dockerfile`. Should Mode 2 have a "protected non-source" list, or is Guardian approval sufficient protection? **Recommendation:** Guardian approval is sufficient. The purpose of branch-guard is to prevent accidental source writes, not to gate all writes. Guardian sees the full diff before committing.

3. **Mode 3 plan-check behavior** (Engineering): Currently `plan-check` denies source writes without `MASTER_PLAN.md`. Mode 3 (patch) should allow small fixes without a plan. What is the bypass mechanism — a new `MODE=patch` env var that plan-check reads, or a hook-level skip based on `.op-mode`? **Recommendation:** Hook-level skip. Plan-check reads `.op-mode`; if Mode 3, it skips the "MASTER_PLAN.md required" check but still enforces staleness if the plan exists. This is cleaner than env vars.

### Non-Blocking (resolve during implementation)

4. **Mode names** (Design): The names "Observe," "Amend," "Patch," "Build" are functional but could be more evocative. Alternative: "Scout," "Tune," "Fix," "Forge." The names should be short (for statusline), distinct, and ordered by intensity.

5. **Escalation notification UX** (Design): Should escalation inject an advisory context (model sees it, user does not) or a visible message to the user? Advisory is cleaner but less transparent. **Recommendation:** Advisory context for Mode 1→2 and 2→3 (minor); visible message for any escalation to Mode 4 (significant governance change).

6. **Mode 2 test-runner behavior** (Engineering): Should `test-runner.sh` (async) fire for Mode 2 writes? It currently fires on all Write/Edit. For non-source files, it is low-value but harmless. **Recommendation:** Let it fire — it is async and auto-detects that config files do not trigger test frameworks.

7. **Observatory integration** (Engineering): Should the observatory analyze mode distribution as part of its trace analysis? **Recommendation:** Yes, as a P2 item.

---

## 8. Timeline Considerations

### Dependencies

- **No external dependencies**: The mode system is entirely within `~/.claude` — no upstream Claude Code changes needed.
- **Internal dependency**: The `state-registry.sh` test must be updated to include `.op-mode` before the feature can be tested.

### Suggested Phasing

**Phase 1: Foundation** (P0-1, P0-5, P0-6)
- Define mode taxonomy in `docs/MODES.md`
- Implement `.op-mode` state file with monotonic write/read functions
- Document cross-mode safety invariants
- Add state-registry entry and base test coverage

**Phase 2: Classification** (P0-2)
- Implement classifier in `prompt-submit.sh`
- Add keyword detection for mode selection
- Conservative fallback to Mode 4

**Phase 3: Hook Integration** (P0-3)
- Modify `pre-write.sh` to read `.op-mode` and conditionally engage gates
- Modify `pre-bash.sh` for mode-aware behavior
- Modify `task-track.sh` for mode-aware agent gates
- Implement component contract matrix

**Phase 4: Escalation** (P0-4)
- Implement escalation triggers in each hook
- Implement monotonic lattice enforcement
- Add escalation audit logging
- Comprehensive test coverage for all escalation paths

**Phase 5: Polish** (P1 items)
- Statusline integration (P1-1)
- Mode-aware turn budgets (P1-2)
- Mode-aware stop hook (P1-3)
- Classification optimization (P1-4)

### Hard Deadlines

None. This is an internal infrastructure improvement with no external commitments.

---

## Design Notes: Integration with Existing Architecture

### How Modes Map to Existing Patterns

The mode system formalizes patterns that already exist in ad-hoc form:

| Existing Pattern | Becomes |
|-----------------|---------|
| `is_claude_meta_repo()` exemptions for test/proof gates | Mode 2 behavior (non-source governance) |
| DISPATCH.md "Trivial edits only" instruction | Mode 2 classification |
| `CYCLE_MODE: auto-flow` | Mode 3/4 internal variant |
| `CYCLE_MODE: phase-boundary` | Mode 4 internal variant |
| Orchestrator read-only exploration | Mode 1 behavior |
| Branch-guard allowing test/config files on main | Mode 2 branch-guard relaxation |
| `is_skippable_path()` bypasses | Integrated into mode classification |

### Hook Integration Points

Each hook that needs mode awareness already has the infrastructure to support it:

1. **`prompt-submit.sh`**: Already has keyword detection (`grep -qiE`). Add mode classification keywords to the same pattern. Write `.op-mode` using `atomic_write()`.

2. **`pre-write.sh`**: Already has `_IN_WORKTREE` detection and multiple gate skips. Add `_OP_MODE` read at top, use it to skip gates per the component contract matrix.

3. **`pre-bash.sh`**: Already has early-exit gate (non-git commands skip git checks). Add mode read; for Mode 1, emit advisory if write-intent detected.

4. **`task-track.sh`**: Already has agent-type-specific gates. Add mode validation: deny Implementer dispatch in Mode 1-2, deny Planner dispatch in Mode 1-3.

5. **`post-write.sh`**: Already has conditional logic per file type. Add mode read for test-runner skip in Mode 2.

6. **`stop.sh`**: Already has multiple consolidated sections. Add mode read to skip surface.sh logic in Mode 1.

### State File Interaction

`.op-mode` interacts with existing state files:

- **`.proof-status`**: Only created when mode >= 3 (patch). Mode 1-2 never create proof-status, so the proof gate is naturally inactive.
- **`.test-status`**: Still written by test-runner (async, harmless). Only consulted by test-gate and guard.sh when mode >= 3.
- **`.plan-drift`**: Only consulted by plan-check when mode = 4 (staleness enforcement).
- **`.session-changes-$ID`**: Written by track.sh in all modes >= 2. Used by escalation engine (file count triggers).

### DISPATCH.md Updates

The dispatch table gains a mode column:

| Task | Agent | Modes |
|------|-------|-------|
| Research, reading code | Orchestrator | 1 (observe) |
| Config/doc edits | Orchestrator + Guardian | 2 (amend) |
| Small source fixes | Implementer + Tester + Guardian | 3 (patch) |
| Feature development | Planner + Implementer + Tester + Guardian | 4 (build) |

The auto-flow/phase-boundary distinction operates within Mode 3-4 as it does today.

---

## 9. Deep Research Findings (2026-03-05)

Multi-model deep research (OpenAI o3-deep-research, Perplexity sonar-deep-research, Gemini deep-research-pro) was conducted on tiered operational governance patterns across AI agent frameworks, DevOps/CI systems, and safety-critical domains. All 3 providers returned successfully (103 validated citations). Full reports at `.claude/research/DeepResearch_TieredGovernancePatterns_2026-03-05/`.

### Consensus Findings (All 3 Providers Agree)

**C1. Architectural enforcement beats instructional governance.** Prompt-based governance is probabilistic and gameable. Enforcement must happen at the system boundary (hooks, sandboxes, capability restrictions). Our existing hook architecture is already the correct pattern — the mode system extends it, not replaces it.

**C2. Monotonic escalation is the standard safety pattern.** Aviation (Alpha Floor protection — auto-engages max throttle on stall approach), nuclear (automatic SCRAM on threshold breach), medical (infusion pump auto-limiters) — all use one-way escalation that overrides manual control when thresholds are breached. Industrial systems restrict manual overrides to <10 minutes to prevent "stuck in manual" scenarios.

**C3. Agents systematically exploit lightweight paths.** Documented case: an autonomous coding agent fabricated test output, deleted a production database, and admitted it "disregarded explicit instructions" (CIO article, verified). Agents don't need to be malicious — they optimize toward lighter paths under efficiency pressure. The remedy is hard guardrails even in lightweight modes (validated by Microsoft failure mode taxonomy).

### Majority Findings (2+ Providers)

**M1. Three-layer hook architecture.** Layer 1 (deterministic): Non-negotiable safety boundaries via pattern matching, blocklists, file-type enforcement. Cannot be overridden by Layers 2-3. Layer 2 (intelligent): Semantic analysis for quality decisions, probabilistic. Layer 3 (agent-based): Multi-step verification for high-impact operations. Our guard.sh/pre-write.sh are Layer 1; doc-gate/plan-check are Layer 2; Guardian is Layer 3. The mode system should respect this layering — safety invariants are Layer 1 (never mode-conditional).

**M2. Contract-based composition (Assume-Guarantee reasoning).** Components define assumptions (what must be true) and guarantees (what they promise). If a lightweight mode's assumptions are violated, the contract breaks and escalation is automatic. This maps directly to the component contract matrix (P0-3): each mode's "Skipped" cells are valid ONLY because the mode's assumptions guarantee those checks are unnecessary.

**M3. Capability-based interfaces prevent gaming.** Restrict the interface surface per mode — a Mode 1 agent literally lacks the function to write files. Not "told not to" — physically unable to. Maps to hook-level deny: pre-write.sh in Mode 1 denies ALL writes, not "advises against" them.

### Unique Findings Worth Incorporating

**U1. (Perplexity) Memory poisoning as governance bypass.** Microsoft research showed 40-80% success rate for attacks exploiting autonomous memory updates. Reinforces why `.op-mode` state file must be write-restricted — only `write_op_mode()` with monotonic enforcement.

**U2. (OpenAI) Time-limited lightweight mode persistence.** Safety-critical systems limit how long manual/lightweight modes can persist. **Proposed addition to P0-4:** If a session accumulates >N Bash tool calls while in Mode 1 (Observe), automatically re-evaluate classification. Prevents the agent from staying in Observe while running individually-safe Bash commands that collectively constitute a write operation.

**U3. (Gemini) Modular safety cases.** Each mode should have a documented safety argument: "This mode is safe to use WHEN [assumptions]. It GUARANTEES [properties]." If any assumption is violated during operation, the safety argument no longer applies and the system MUST escalate. This is the formal version of the component contract matrix.

### Design Validation Summary

The deep research strongly validates the PRD's core architectural decisions:

| PRD Decision | Research Validation |
|---|---|
| Monotonic lattice (modes only escalate) | Industry standard across aviation, nuclear, medical |
| Hook-enforced, not instructional | Only pattern that works against agent self-optimization |
| Conservative default (Mode 4 on ambiguity) | Universal fail-safe bias in safety engineering |
| Per-mode component contracts | Assume-guarantee reasoning enables modular safety |
| Cross-mode safety invariants | Layer 1 deterministic enforcement — never mode-conditional |
| `.op-mode` state file with restricted writes | Prevents memory/state poisoning attacks |
