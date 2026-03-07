# MASTER_PLAN: Claude Code Configuration System

## Identity

**Type:** meta-infrastructure
**Languages:** Bash (85%), Markdown (10%), JSON/Python (5%)
**Root:** `/Users/turla/.claude`
**Created:** 2026-03-07
**Last updated:** 2026-03-07

The Claude Code configuration directory that shapes how Claude Code operates across all projects. It enforces development practices via hooks (deterministic shell scripts intercepting every tool call), four specialized agents (Planner, Implementer, Tester, Guardian), skills, and session instructions. Instructions guide; hooks enforce.

## Architecture

```
hooks/              — 24 hook scripts + 9 shared libraries; deterministic enforcement layer
agents/             — 4 agent prompt definitions (planner, implementer, tester, guardian)
skills/             — 7 skill directories (deep-research, decide, consume-content, etc.)
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

> The system drifted from purpose-driven to enforcement-heavy. Pre-metanoia (v21, commit 2eb16a9), CLAUDE.md was 255 lines with rich purpose language, the Cornerstone Belief was 8 sentences of conviction, and the implementer prompt was 87 lines of clean workflow. Current state (v30): CLAUDE.md is 149 procedurally-dense lines at a 5.7:1 enforcement-to-purpose ratio. Agent prompts grew 7.3x (269 to 1,472 lines) with defensive boilerplate repeated across all four. Easy-task success dropped from 100% to 67%. The model reads "follow rules" louder than "think deeply." We need to restore the soul without losing the structure.

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
| 2026-03-07 | DEC-PROMPT-001 | prompt-restoration | Hybrid CLAUDE.md: pre-metanoia voice + current procedural references | Pre-metanoia purpose language is sacred; current procedural references are useful but must follow purpose, not lead |
| 2026-03-07 | DEC-PROMPT-002 | prompt-restoration | Shared protocols injected via subagent-start.sh, not just referenced | Deterministic injection at dispatch time means agents don't need to remember to read a file; the hook ensures they see shared protocols (CWD safety, trace, return message) |
| 2026-03-07 | DEC-PROMPT-003 | prompt-restoration | "What Matters" section added to CLAUDE.md with quality-of-thought expectations | The model lacks explicit guidance on what deep work looks like; codifying it in purpose position produces better reasoning |
| 2026-03-07 | DEC-AUDIT-001 | governance-audit | Governance signal map as markdown in docs/governance-signal-map.md | One-time research artifact to inform optimization decisions; markdown is sufficient |

---

## Active Initiatives

### Initiative: Prompt Purpose Restoration
**Status:** active
**Started:** 2026-03-07
**Goal:** Restore the purpose-to-enforcement ratio in prompts so the model produces deep, purposeful work instead of perfunctory compliance.

> The configuration harness drifted from a 1:1 purpose-to-enforcement ratio (v21, 255-line CLAUDE.md with rich conviction language) to a 5.7:1 enforcement-heavy state (v30, 149 procedurally-dense lines). Agent prompts grew 7.3x (269 to 1,472 lines) with defensive boilerplate repeated across all four agents. Easy-task success dropped from 100% to 67%. This initiative restores the soul: purpose-sandwich CLAUDE.md, shared defensive protocols injected at dispatch time, and slimmed agent prompts that lead with purpose.

**Dominant Constraint:** simplicity

#### Goals
- REQ-GOAL-001: Restore purpose-to-enforcement ratio in CLAUDE.md to approximately 1:1 (from 5.7:1)
- REQ-GOAL-002: Reduce agent prompt total line count by ~40% by extracting shared defensive boilerplate into injected shared protocols
- REQ-GOAL-003: Improve easy-task success rate back toward 100% without regressing medium-task success

#### Non-Goals
- REQ-NOGO-001: Reducing hook count — hooks enforce deterministically and that works well; the goal is reducing cognitive noise in prompts, not removing enforcement
- REQ-NOGO-002: Rewriting hook implementations — this is about what the model reads (prompts, injected context), not what hooks do internally
- REQ-NOGO-003: Adding new features or capabilities — this is restoration and optimization, not expansion

#### Requirements

**Must-Have (P0)**

- REQ-P0-001: CLAUDE.md restored to purpose-sandwich structure (identity/purpose lead, procedural docs referenced, quality standards close)
  Acceptance: Given the current 149-line CLAUDE.md, When restoration is complete, Then:
  - [ ] Purpose/values language is at least 40% of the document
  - [ ] Full pre-metanoia Cornerstone Belief (8 sentences) is restored
  - [ ] Dispatch table lives in DISPATCH.md (referenced, not inlined)
  - [ ] New "What Matters" section explicitly describes quality-of-thought expectations
  - [ ] Document follows purpose-sandwich: identity → purpose → quality expectations → references → procedures

- REQ-P0-002: Shared defensive boilerplate extracted and injected at dispatch time
  Acceptance: Given 4 agent prompts totaling 1,472 lines with repeated CWD safety, trace protocol, mandatory return message, and session-end checklist, When extraction is complete, Then:
  - [ ] `agents/shared-protocols.md` contains all shared defensive content
  - [ ] `subagent-start.sh` injects shared-protocols.md content into additionalContext for all non-lightweight agents
  - [ ] Each agent prompt retains its unique purpose/workflow content without the shared boilerplate
  - [ ] Total agent prompt line count reduced by 30-40%

- REQ-P0-003: "What Matters" section in CLAUDE.md
  Acceptance: Given the current CLAUDE.md lacks quality-of-thought guidance, When the section is added, Then it explicitly addresses:
  - [ ] Deep analysis over surface compliance
  - [ ] Understanding WHY, not just WHAT
  - [ ] Hard numbers and evidence over vague claims
  - [ ] Acting with judgment, not perfunctory rule-following
  - [ ] Making meaningful connections between requirements and implementation

**Nice-to-Have (P1)**

- REQ-P1-001: Agent prompts strengthened with purpose language — each prompt's opening sections emphasize the agent's unique value proposition, not just its procedures
- REQ-P1-004: Guardian merge presentation — after every merge, the Guardian leads with "What should you expect to see?" — putting the value of what was built front and center before git mechanics. The user should understand what changed for them before seeing commit hashes.

**Future Consideration (P2)**

- REQ-P2-001: A/B testing framework for prompt changes — compare quality metrics pre/post to validate improvements

#### Definition of Done

All P0 requirements pass their acceptance criteria. CLAUDE.md follows purpose-sandwich structure with restored Cornerstone Belief and "What Matters" section. Agent prompts are slimmed by 30-40% with shared content injected via subagent-start.sh. Easy-task qualitative output improves (assessed via validation session in W3-1). Satisfies: REQ-GOAL-001, REQ-GOAL-002, REQ-GOAL-003.

#### Architectural Decisions

- DEC-PROMPT-001: Hybrid approach for CLAUDE.md — use pre-metanoia voice/structure but keep current procedural references as pointers
  Addresses: REQ-P0-001.
  Rationale: Pre-metanoia Cornerstone Belief (8 sentences of conviction) and purpose language produced better output. Current procedural references (dispatch table pointer, hook list, resource table) are useful but should follow purpose, not lead. Starting from pre-metanoia voice and selectively adding back what hooks don't enforce.

- DEC-PROMPT-002: Shared protocols injected via subagent-start.sh at dispatch time
  Addresses: REQ-P0-002.
  Rationale: User adjustment — reference-based reading (agent remembers to read a file) is non-deterministic. Hook injection via subagent-start.sh is deterministic — agents see shared protocols without needing to remember. The hook already fires on every agent dispatch and injects additionalContext. New injection point: after trace init, before agent-type-specific context. Content: CWD safety rules, trace protocol, mandatory return message format, session-end checklist.

- DEC-PROMPT-003: "What Matters" section codifies quality-of-thought expectations
  Addresses: REQ-P0-003.
  Rationale: The model lacks explicit guidance on what deep work looks like. Current prompts tell the model WHAT to do (procedures) but not HOW to think (quality expectations). Placing this in purpose position (early in CLAUDE.md) produces better reasoning by setting the frame before procedures.

#### Waves

##### Initiative Summary
- **Total items:** 4
- **Critical path:** 3 waves (W1-1 → W2-1 → W3-1)
- **Max width:** 2 (Wave 1)
- **Gates:** 3 review, 1 approve

##### Wave 1 (no dependencies)
**Parallel dispatches:** 2

**W1-1: Create shared-protocols.md and wire injection in subagent-start.sh (#143)** — Weight: M, Gate: review
- Create `agents/shared-protocols.md` containing:
  - CWD safety rules (never bare `cd` into worktrees, subshell pattern, safe_cleanup)
  - Trace protocol (TRACE_DIR usage, artifacts list per agent type, summary.md requirements)
  - Mandatory return message format (structure, 1500 token limit, never end on bare tool call)
  - Session-end checklist (verify tests pass, annotations present, worktree clean, summary written)
- Extract these sections from all 4 agent prompts — identify the common content by comparing `implementer.md`, `guardian.md`, `tester.md`, `planner.md`
- Modify `hooks/subagent-start.sh`:
  - After line 54 (trace init block), before line 56 (CTX_LINE), add a new block
  - Read `agents/shared-protocols.md` content
  - For non-lightweight agents (skip Bash, Explore), inject content into CONTEXT_PARTS
  - Use `head -c 3000` or similar to cap injection size — the content should be ~2KB
- **Integration:** `hooks/subagent-start.sh` must source the shared-protocols content; `agents/shared-protocols.md` must be a new file in the agents/ directory

**W1-2: Restore CLAUDE.md purpose-sandwich structure (#144)** — Weight: M, Gate: review
- Restructure CLAUDE.md following DEC-PROMPT-001 (hybrid approach):
  - **Lead:** Full Identity section + restored Cornerstone Belief (all 8 sentences from pre-metanoia commit 2eb16a9)
  - **Purpose:** New "What Matters" section (DEC-PROMPT-003) — deep analysis, WHY not just WHAT, hard numbers, judgment over compliance, meaningful connections
  - **Quality:** Interaction Style, Output Intelligence, Sacred Practices — these stay but move after purpose
  - **References:** Resource table, Commands & Skills — compact reference section
  - **Procedures:** Dispatch Rules (compact — full table stays in DISPATCH.md), Notes
- The document should be approximately 200-250 lines (up from 149, but with purpose language comprising ~40%)
- Pre-metanoia source: `git show 2eb16a9:CLAUDE.md` for the Cornerstone Belief text and purpose language
- Do NOT modify hooks, agents, or settings.json in this item
- **Integration:** CLAUDE.md is loaded every session by Claude Code runtime — no explicit import needed. The dispatch table reference should point to `docs/DISPATCH.md`.

##### Wave 2
**Parallel dispatches:** 1
**Blocked by:** W1-1, W1-2

**W2-1: Slim all 4 agent prompts (#146)** — Weight: L, Gate: approve, Deps: W1-1, W1-2
- For each of `agents/planner.md`, `agents/implementer.md`, `agents/tester.md`, `agents/guardian.md`:
  1. Remove sections now covered by shared-protocols.md injection (CWD safety, trace protocol, mandatory return message, session-end checklist)
  2. Keep all unique purpose, workflow, and phase content
  3. Strengthen opening sections with purpose language — each agent should lead with its unique value, not procedures
  4. **Guardian-specific (REQ-P1-004):** Add a "Merge Presentation" section requiring the Guardian to lead post-merge output with "What should you expect to see from this work?" — value delivered, what changed for the user, what they can now do — before git mechanics (commit hash, branch, files). Purpose-first output.
  5. Target: 30-40% line count reduction across all 4 prompts (from 1,472 total to ~900-1,000)
- Specific removals per agent:
  - **implementer.md** (222 lines): Remove "CWD safety" block (~10 lines), "Trace Protocol" section (~15 lines), "Mandatory Return Message" (~15 lines), "Session End Protocol" (~5 lines). Target: ~175 lines
  - **guardian.md** (502 lines): Remove CWD safety in worktree cleanup (~8 lines), trace references (~5 lines), remove session context format that overlaps with shared protocol. Target: ~420 lines
  - **tester.md** (286 lines): Remove "Worktree path safety" block (~5 lines), trace protocol section (~10 lines). Target: ~265 lines
  - **planner.md** (462 lines): Remove trace protocol section (~10 lines), mandatory return message (~10 lines), session end protocol checklist items that overlap. Target: ~440 lines
- Verify no content is lost — every defensive rule must exist in EITHER the agent prompt OR shared-protocols.md (never neither, okay in both for truly agent-specific variants)
- **Integration:** Agent prompts are loaded by Claude Code runtime from agents/ directory. No explicit import changes needed — subagent-start.sh injection ensures shared content reaches agents.

##### Wave 3
**Parallel dispatches:** 1
**Blocked by:** W2-1

**W3-1: Validation session (#147)** — Weight: S, Gate: review, Deps: W2-1
- Run a test session with the restored prompts to qualitatively assess output
- Compare against pre-restoration output quality:
  - Does the implementer produce deeper analysis?
  - Does the orchestrator exercise more judgment (fewer unnecessary permission asks)?
  - Do agent returns include more meaningful summaries?
- Document findings in trace artifacts
- If quality regression is observed, identify which changes caused it and propose adjustments
- **Integration:** No code changes — this is a verification-only item

##### Critical Files
- `CLAUDE.md` — session instructions; the primary prompt surface that shapes all agent behavior
- `agents/shared-protocols.md` — NEW; shared defensive boilerplate injected at dispatch time
- `hooks/subagent-start.sh` — dispatch-time context injection; modified to inject shared protocols
- `agents/implementer.md` — largest delta (222→~175 lines)
- `agents/guardian.md` — most complex agent prompt (502 lines)

##### Decision Log
<!-- Guardian appends here after wave completion -->

#### Prompt Restoration Worktree Strategy

Main is sacred. Each wave dispatches parallel worktrees:
- **Wave 1:** `.worktrees/shared-protocols` on branch `feature/shared-protocols` (W1-1), `.worktrees/claude-md-restore` on branch `feature/claude-md-restore` (W1-2)
- **Wave 2:** `.worktrees/slim-agents` on branch `feature/slim-agents` (W2-1)
- **Wave 3:** `.worktrees/validation` on branch `feature/prompt-validation` (W3-1)

#### Prompt Restoration References

- Pre-metanoia CLAUDE.md: `git show 2eb16a9:CLAUDE.md`
- Pre-metanoia implementer: `git show 2eb16a9:agents/implementer.md`
- Current hook registrations: `settings.json` (10 events, 24 hooks)
- Subagent injection mechanism: `hooks/subagent-start.sh` lines 42-311
- DISPATCH.md: `docs/DISPATCH.md` — full dispatch protocol

---

### Initiative: Governance Signal Audit
**Status:** active
**Started:** 2026-03-07
**Goal:** Produce a comprehensive governance signal map documenting all hooks, their context injection, and overlap to enable informed optimization.

> The hook system grew from 8 to 24 registrations across 10 lifecycle events. Each hook may inject context (additionalContext, systemMessage), deny actions, or produce side effects. No single document maps the total signal volume a model receives per session or per action. Without this map, optimization is guesswork. This initiative produces the map, then proposes smarter signal routing.

**Dominant Constraint:** maintainability

#### Goals
- REQ-GOAL-004: Produce a structured governance signal map documenting all 24 hook registrations, their context injection volume, timing, and overlap
- REQ-GOAL-005: Identify duplicate enforcement (hooks enforcing what prompts already repeat) with specific reduction proposals

#### Non-Goals
- REQ-NOGO-004: Implementing any signal routing changes in this initiative — this is research and proposal only
- REQ-NOGO-005: Changing hook implementations — the audit documents what exists, it does not modify it

#### Requirements

**Must-Have (P0)**

- REQ-P0-004: Governance signal map produced
  Acceptance: Given 24 hook registrations across 10 events, When the audit is complete, Then:
  - [ ] Each hook is documented with: event, matcher, purpose (1 line), output type (deny/allow/advisory/context), injection content summary, estimated byte count, frequency (per-session/per-action/per-agent)
  - [ ] Total signal volume per lifecycle event is calculated
  - [ ] Overlap between hooks is identified (hooks that enforce the same constraint as a prompt)
  - [ ] Document is in `docs/governance-signal-map.md`

**Nice-to-Have (P1)**

- REQ-P1-002: Optimization proposals — specific recommendations for reducing signal noise while maintaining enforcement coverage

**Future Consideration (P2)**

- REQ-P2-002: Implement the optimization proposals in a follow-up initiative

#### Definition of Done

Signal map document exists in `docs/governance-signal-map.md` with all 24 hooks documented. Total signal volume calculated per event. Overlap with prompt content identified. Satisfies: REQ-GOAL-004, REQ-GOAL-005.

#### Architectural Decisions

- DEC-AUDIT-001: Governance signal map as markdown in docs/governance-signal-map.md
  Addresses: REQ-P0-004.
  Rationale: One-time research artifact to inform optimization decisions. Markdown is human-readable and sufficient for this purpose. JSON would add complexity without value.

#### Waves

##### Initiative Summary
- **Total items:** 2
- **Critical path:** 2 waves (W1-3 → W2-2)
- **Max width:** 1
- **Gates:** 1 review, 1 approve

##### Wave 1 (no dependencies)
**Parallel dispatches:** 1

**W1-3: Produce governance signal map (#145)** — Weight: L, Gate: review
- Audit all hooks registered in `settings.json`:
  - For each hook: read the source, identify what it outputs (deny/allow/advisory/context injection)
  - Measure: approximate byte count of injected context per invocation
  - Document: frequency (how often it fires — per-session, per-tool-call, per-agent-dispatch)
- Map total signal volume per lifecycle event:
  - SessionStart: what the model sees at session start (session-init.sh injection)
  - UserPromptSubmit: what fires on every user message (prompt-submit.sh)
  - PreToolUse: what fires before each tool call (pre-bash.sh, pre-write.sh, task-track.sh, pre-ask.sh)
  - PostToolUse: what fires after each tool call (post-write.sh, lint.sh, etc.)
  - SubagentStart: what agents see at dispatch (subagent-start.sh)
  - SubagentStop: what fires when agents return (check-*.sh hooks)
  - Stop: what fires at session end (stop.sh)
- Identify overlap: places where hooks enforce rules that prompts also state
- Write output to `docs/governance-signal-map.md`
- **Integration:** New file in docs/ directory. No code changes. Referenced by future optimization work.

##### Wave 2
**Parallel dispatches:** 1
**Blocked by:** W1-3

**W2-2: Propose optimization plan (#148)** — Weight: M, Gate: approve, Deps: W1-3
- Based on signal map findings, propose:
  - Which signals can be removed from prompts because hooks enforce them deterministically
  - Which hook injections can be made conditional (only fire when relevant, not on every invocation)
  - Which context injections can be compressed (shorter messages, same information)
  - Priority-ranked list of changes with estimated token savings per session
- Write proposals as an addendum to `docs/governance-signal-map.md` or a separate `docs/signal-optimization-proposals.md`
- Do NOT implement any changes — this is proposal only, to be approved before a follow-up initiative
- **Integration:** Markdown document in docs/. No code changes.

##### Critical Files
- `settings.json` — hook registrations (source of truth for what hooks exist)
- `hooks/session-init.sh` — largest context injection (SessionStart)
- `hooks/subagent-start.sh` — per-agent context injection (SubagentStart)
- `hooks/prompt-submit.sh` — fires on every user message
- `hooks/pre-bash.sh` — fires before every Bash command

##### Decision Log
<!-- Guardian appends here after wave completion -->

#### Governance Audit Worktree Strategy

Main is sacred. Each wave dispatches parallel worktrees:
- **Wave 1:** `.worktrees/signal-map` on branch `feature/signal-map` (W1-3)
- **Wave 2:** `.worktrees/signal-optimization` on branch `feature/signal-optimization` (W2-2)

#### Governance Audit References

- Hook registrations: `settings.json`
- Hook source code: `hooks/*.sh`
- Hook documentation: `hooks/HOOKS.md`
- Architecture reference: `ARCHITECTURE.md` sections 2-5 (hook engine, gate hooks, feedback hooks, session lifecycle)

---

## Completed Initiatives

| Initiative | Period | Phases | Key Decisions | Archived |
|-----------|--------|--------|---------------|----------|

---

## Parked Issues

Issues not belonging to any active initiative. Tracked for future consideration.

| Issue | Description | Reason Parked |
|-------|-------------|---------------|
