# Dispatch Protocol

<!--
@decision DEC-DISPATCH-EXTRACT-001
@title Extract dispatch protocol from CLAUDE.md to docs/DISPATCH.md
@status accepted
@rationale The dispatch protocol section (~115 lines) loaded every session in CLAUDE.md
  but is only needed when agent dispatch is imminent. Extracting it to docs/DISPATCH.md
  reduces per-session token load while keeping the full protocol accessible on demand.
  CLAUDE.md retains a compact reference with the always-needed key rules.
-->

This file contains the full agent dispatch protocol for the Claude Code meta-infrastructure.
Referenced from `CLAUDE.md` — read when orchestrating agent dispatch or understanding routing rules.

> **Note:** Claude Code renamed the `Task` tool to `Agent` (circa v2.1.39).
> Hook matchers use `"Task|Agent"` for compatibility. This document uses
> "Agent dispatch" to refer to agent invocation via the Agent tool.

<!-- DISPATCH-INJECT-START -->
## Dispatch Summary

The orchestrator dispatches to specialized agents — it does NOT write source code directly.

| Task | Agent | Orchestrator May? |
|------|-------|--------------------|
| Planning, architecture | **Planner** | No Write/Edit for source |
| Implementation, tests | **Implementer** | No — worktree only |
| E2E verification | **Tester** | No — must invoke |
| Commits, merges, branches | **Guardian** | No git commit/merge/push |
| Initiative evaluation | **Governor** | Dispatch after planner (2+ waves) or initiative completion |
| Research, reading code | Orchestrator | Read/Grep/Glob only |

Key rules:
- Auto-dispatch tester after implementer returns (no asking)
- Auto-dispatch guardian when AUTO-VERIFIED appears
- Simple tasks (≤2 files, clear requirements) can skip planner
- Wave items dispatch in parallel (one implementer per worktree)
- Main is sacred — feature work in worktrees only
<!-- DISPATCH-INJECT-END -->

## Agent Dispatch Table

The orchestrator dispatches to specialized agents — it does NOT write source code directly.

| Task | Agent | Orchestrator May? |
|------|-------|--------------------|
| Planning, architecture | **Planner** | No Write/Edit for source |
| Implementation, tests | **Implementer** | No — must invoke implementer. Orchestrator controls the full cycle (implement → test → verify → commit). |
| E2E verification, demos | **Tester** | No — must invoke tester |
| Commits, merges, branches | **Guardian** | No git commit/merge/push/branch -d/-D |
| Plan/initiative evaluation | **Governor** | No — dispatch after planner (2+ waves), after initiative completion, before reckoning |
| Worktree creation (bootstrap) | Orchestrator | Yes — `git worktree add` before implementer dispatch |
| Research, reading code | Orchestrator / Explore | Read/Grep/Glob only |
| Post-guardian health check | Orchestrator | Invoke `/diagnose` when check-guardian.sh suggests it |
| Editing `~/.claude/` config | Orchestrator | Trivial edits only (gitignore, 1-line, typos). Features use worktrees. |

**Planner creates or amends the plan:** When MASTER_PLAN.md exists with `## Identity`, the Planner adds a new `### Initiative:` block rather than overwriting. When it does not exist, Planner creates the full living-document structure. Never dispatch Planner to replace an existing plan — dispatch to extend it.

Agents are interactive — they handle the full approval cycle (present → approve → execute → confirm). If an agent exits after asking approval, wait for user response, then resume with "The user approved. Proceed."

## Plan-to-Implementation Routing

Detection: `git ls-files --error-unmatch MASTER_PLAN.md` (exit 0 = tracked = amendment flow)

**Bootstrap** (MASTER_PLAN.md not yet tracked in git — sequential, never parallelize):
1. Dispatch **Planner** → creates MASTER_PLAN.md on main (Workflow A)
2. Dispatch **Guardian** → commits MASTER_PLAN.md to main (allowed because plan is untracked)
3. **Orchestrator** creates worktree: `git worktree add .worktrees/<phase> -b feature/<phase>`
4. Dispatch **Implementer** → works inside the worktree

**Amendment** (MASTER_PLAN.md already tracked in git):
1. **Orchestrator** creates worktree: `git worktree add .worktrees/<initiative> -b feature/<initiative>`
2. Dispatch **Planner** into the worktree → amends MASTER_PLAN.md there (Workflow B), creates issues
3. Dispatch **Implementer** into the same worktree → implements code
4. Dispatch **Tester** → verifies
5. Dispatch **Guardian** → merges worktree to main (plan amendment + code in a single approval)

The orchestrator owns worktree creation because it is infrastructure, not source code.
Gate C.1 in task-track.sh requires at least one non-main worktree before implementer dispatch.

### Simple Task Fast Path

<!--
@decision DEC-DISPATCH-002
@title Simple Task Fast Path — skip planner for clearly-simple tasks
@status accepted
@rationale Benchmark data shows 60-310% token overhead on easy tasks from governance
  ceremony that doesn't scale with complexity. Allowing the orchestrator to skip planning
  for clearly-simple tasks reduces overhead while maintaining safety through worktrees,
  tests, and @decision annotations.
-->

Not every task needs full ceremony. The orchestrator MAY skip the planner and dispatch
the implementer directly when ALL of these hold:

- Task scope is ≤2 files (clear from the request)
- No architectural decisions needed (no new patterns, no API design)
- An active MASTER_PLAN.md already exists (amendment context available)
- The task is a bug fix, typo correction, or small enhancement to existing code

When using the fast path:
- The implementer still works in a worktree (Sacred Practice #2)
- The implementer still runs tests (Sacred Practice #4)
- The implementer still creates @decision annotations for non-obvious choices
- But NO planner dispatch, NO MASTER_PLAN.md amendment, NO issue creation

**Escalation signals** (abandon fast path, invoke planner):
- Task touches ≥3 files or creates new modules
- Task requires new interfaces or API design
- Task has ambiguous requirements or multiple valid approaches
- Implementation reveals unexpected complexity

## TEST_SCOPE Signal

The orchestrator can include `TEST_SCOPE: full|minimal|none` in the dispatch prompt:
- **full** (default): Test-first development — write failing tests, then implement
- **minimal**: Run existing tests for regressions, don't write new ones
- **none**: Skip tests entirely (config/docs/typo changes)

## Wave Dispatch (Parallel Implementers)

The planner's Phase 3 decomposes work into waves. Items within a wave are
independent and dispatch in parallel — each gets its own implementer in its
own worktree, with its own tester→guardian cycle.

**Dispatch pattern:**
1. Orchestrator creates one worktree per work item:
   `git worktree add .worktrees/<item-slug> -b feature/<item-slug>`
2. Dispatch one implementer per worktree
3. Each implementer returns after tests pass
4. Orchestrator dispatches tester + guardian per worktree (visible, sequential)
5. Use `run_in_background: true` for concurrent implementer dispatch

**Constraints:**
- Bootstrap remains sequential (plan must exist before implementation)
- Wave N cannot dispatch until Wave N-1 completes (dependency order)
- The "never dispatch a second implementer" in Task Interruption applies to
  UNPLANNED interruptions, not planned wave dispatch

**Auto-dispatch to Guardian:** When work is ready for commit, invoke Guardian directly with full context (files, issue numbers, push intent). Do NOT ask "should I commit?" before dispatching. Do NOT ask "want me to push?" after Guardian returns. Guardian owns the entire approval cycle — one user approval covers stage → commit → close → push.

**Decision Configurator Auto-Dispatch:** The Planner may invoke `/decide` during Phase 2 when 3+ architectural decisions have meaningful trade-offs. This is part of the Planner's workflow — the orchestrator doesn't separately dispatch `/decide`. If the Planner asks for guidance on a multi-option trade-off, suggest: "Consider `/decide plan` to let the user explore options interactively."

**Auto-dispatch to Tester:** After the implementer returns successfully (tests pass, no blocking issues), dispatch the tester automatically with the implementer's trace context. Do NOT ask "should I verify?" — just dispatch the tester.

**Auto-dispatch to Governor:** The governor operates in two modes — health pulse (fast, ~3-5K tokens) and full evaluation (~15-20K tokens). Dispatch rules:

- **Pre-implementation (planner returns 2+ waves):** Dispatch governor in **pulse mode** by default. If pulse returns "drifting" or "stale" with flags, escalate to full evaluation before dispatching implementer.
- **Post-completion (all phases merged):** Full evaluation (rare, high-leverage — always worth the cost).
- **Reckoning-input (Phase 2 of /reckoning):** Full evaluation.
- **Health pulse (orchestrator judgment):** Dispatch when session-init signals stale docs/plan, after change bursts or ad-hoc commits outside the plan, or periodically in meta-infrastructure projects (~/.claude). The orchestrator decides — no mechanical threshold.

Governor results are always advisory:
- **Pulse: healthy** = continue normally
- **Pulse: drifting/stale** = review flags, consider full evaluation before proceeding
- **Full: proceed** = continue to implementation normally
- **Full: caution** = present concerns to user before dispatching implementer
- **Full: block** = present to user and wait for guidance before proceeding

After initiative completion (all phases merged, before `compress_initiative()`), dispatch the governor for post-completion full evaluation.

**After tester returns:** Present the tester's full verification report to the user, including the Verification Assessment. Do NOT summarize it into a keyword demand. Engage in Q&A about the evidence. When the user expresses approval, prompt-submit.sh handles the gate transition automatically.

## Auto-Verify Fast Path

When post-task.sh detects `AUTOVERIFY: CLEAN` with High confidence, full coverage, and no caveats, it sets proof state to verified via `proof_state_set()` and emits `AUTO-VERIFIED` in a system-reminder.

When the orchestrator receives this system-reminder:
1. Dispatch Guardian with `AUTO-VERIFY-APPROVED` in the prompt — this tells
   Guardian to skip its approval presentation and execute the merge cycle directly.
2. Present the tester's verification report to the user in the same response
   (user sees evidence while commit is in flight).
3. Do NOT wait for user approval before dispatching — the auto-verify IS the approval.

If auto-verify doesn't trigger, the manual flow applies: present the tester's
report, engage in Q&A, user approval triggers prompt-submit.sh gate transition.

When post-task.sh emits `AUTOVERIFY EXPECTED` (tester met criteria but omitted signal), the orchestrator MAY dispatch Guardian with `INFER-VERIFY` in the prompt. Guardian performs its own inference check and proceeds with a softer approval if criteria are confirmed. This is a fallback, not a replacement for the primary auto-verify path.

## Manual Approval Fast Path

When prompt-submit.sh detects an approval keyword (approved, verified, lgtm, etc.)
and transitions proof state to verified (via `proof_state_set()`), it emits `DISPATCH GUARDIAN NOW with
AUTO-VERIFY-APPROVED`. This is functionally equivalent to the auto-verify path above:

1. The user has already approved — their approval keyword IS the approval.
2. Dispatch Guardian with `AUTO-VERIFY-APPROVED` in the prompt.
3. Guardian skips its Interactive Approval Protocol and executes directly.
4. Do NOT ask the user to approve again — that defeats the purpose of the gate.

## Pre-Dispatch Gates (Mechanically Enforced)

- Tester dispatch: requires implementer to have returned with tests passing
- Guardian dispatch: requires proof state = verified (SQLite proof_state table, read via `proof_state_get()`) when active (PreToolUse:Task|Agent gate in task-track.sh). Missing state = no gate (bootstrap path — implementer dispatch activates the gate via `proof_state_set("needs-verification")`)
- The user's approval (verified, approved, lgtm, looks good, ship it) triggers proof state = verified via `proof_state_set()` in prompt-submit.sh — no agent can write it directly
- INFER-VERIFY dispatches still require proof state to be at least pending (not missing).
- Governor dispatch: no proof-status gate, no worktree gate. Governor is read-only and advisory.

## Trace and Recovery Protocols

**Trace Protocol:** Agents write evidence to disk (TRACE_DIR/artifacts/) and return a cohesive summary of their work (aim for 200-500 tokens). Read TRACE_DIR/summary.md for full details on demand.

**Silent Return Recovery:** When an agent returns with no visible content, check-*.sh Layer A reads `$TRACE_DIR/summary.md` and injects its content directly into additionalContext (labeled "SILENT RETURN DETECTED"). Agents write summary.md incrementally after each phase, so the last-written version is always available. Act on the injected content — do NOT ask the user to investigate. If additionalContext says "no trace summary available", read the latest trace directly: `ls -t traces/<agent-type>-*/summary.md | head -1`.

**Session Acclimation:** MASTER_PLAN.md's `## Identity` and active initiative sections are
auto-injected at session start (bounded to ~200 lines regardless of plan age). This provides
project identity, architecture, and active work context. Development log digest (recent traces)
shows what agents did recently. Failed/crashed trace summaries are auto-injected — act on them
without prompting. When the task touches unfamiliar areas, read relevant files from the Resources table.

## Dispatch Sizing

**Implementer dispatch sizing:**
- Phases with 1–3 work items: dispatch all in one implementer call
- Phases with 4+ work items: split into multiple dispatches (group related items, max 3 per dispatch)
- If implementer returns PARTIAL (summary.md says work remains), re-dispatch for remaining items immediately without asking the user

## Task Interruption Protocol

When you receive a new task while agents from a previous dispatch are still running (system-reminder will show "ACTIVE AGENTS from previous dispatch"):

1. **Acknowledge** the active work — name the agent type and what it was doing
2. **Assess** both tasks — is the new task urgent? Is the old task near completion?
3. **Present options** via AskUserQuestion (never silently pivot):

| Option | When | What happens |
|--------|------|--------------|
| **Pivot** | Unrelated tasks (default) | Create `/backlog` issue with interrupted context (trace summary, branch, what remains), then proceed with new task. Non-optional — interrupted work MUST be captured. |
| **Queue** | Old task near completion | Finish old task first, then start new |
| **Parallel** | Old agent in final stage (tester/guardian) | Let old finish in background, start read-only exploration of new task. Never dispatch a second unplanned implementer. Planned wave dispatch is allowed (see Wave Dispatch). |
| **Merge** | Tasks overlap | Incorporate new requirements when current agent returns |

Two exceptions bypass AskUserQuestion:
- **Trivial tasks** (research, status checks, questions) that don't need agent dispatch — just answer and resume
- **Explicit cancellation** ("drop that", "forget it", "start fresh") — treat as Pivot, still MUST `/backlog` before proceeding
