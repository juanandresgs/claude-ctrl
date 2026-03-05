<!--
  Master Plan Template — Full living document structure for new projects.
  Used by the Planner agent (Workflow A — Create) when no MASTER_PLAN.md exists.
  See agents/planner.md Phase 4 for authoring guidance.
-->

# MASTER_PLAN: [Project Name]

## Identity

**Type:** [meta-infrastructure | web-app | CLI | library | API | ...]
**Languages:** [primary (X%), secondary (Y%), ...]
**Root:** [absolute path]
**Created:** [YYYY-MM-DD]
**Last updated:** [YYYY-MM-DD]

[2-3 sentence description of what this project is and what it does]

## Architecture

  dir1/    — [role, 1 line]
  dir2/    — [role, 1 line]
  dir3/    — [role, 1 line]
[Key directories and their roles — 1 line per directory, only meaningful dirs]

## Original Intent

> [Verbatim user request, as sacred text — quoted block]

## Principles

These are the project's enduring design principles. They do not change between initiatives.

1. **[Principle Name]** — [Description]
2. **[Principle Name]** — [Description]
[3-5 principles that will guide all future work]

---

## Decision Log

Append-only record of significant decisions across all initiatives. Each entry references
the initiative and decision ID. This log persists across initiative boundaries — it is the
project's institutional memory.

| Date | DEC-ID | Initiative | Decision | Rationale |
|------|--------|-----------|----------|-----------|
| [YYYY-MM-DD] | DEC-COMPONENT-001 | [initiative-slug] | [Decision title] | [Brief rationale] |

---

## Active Initiatives

### Initiative: [Initiative Name]
**Status:** active
**Started:** [YYYY-MM-DD]
**Goal:** [One-sentence goal]

> [2-4 sentence narrative: what problem this initiative solves and why now]

**Dominant Constraint:** [reliability | security | performance | maintainability | simplicity | balanced]

#### Goals
- REQ-GOAL-001: [Measurable outcome]
- REQ-GOAL-002: [Measurable outcome]

#### Non-Goals
- REQ-NOGO-001: [Exclusion] — [why excluded]
- REQ-NOGO-002: [Exclusion] — [why excluded]

#### Requirements

**Must-Have (P0)**

- REQ-P0-001: [Requirement]
  Acceptance: Given [context], When [action], Then [outcome]

**Nice-to-Have (P1)**

- REQ-P1-001: [Requirement]

**Future Consideration (P2)**

- REQ-P2-001: [Requirement — design to support later]

#### Definition of Done

[Overall initiative DoD — what does "done" mean for this initiative?]

#### Architectural Decisions

- DEC-COMPONENT-001: [Decision title]
  Addresses: REQ-P0-001.
  Rationale: [Why this approach was chosen over alternatives]

#### Waves

##### Initiative Summary
- **Total items:** [N]
- **Critical path:** [N] waves ([W-ID chain])
- **Max width:** [N] (Wave [N])
- **Gates:** [count] review, [count] approve

##### Wave 1 (no dependencies)
**Parallel dispatches:** [N]

**W1-1: [Task title] (#issue)** — Weight: [S/M/L/XL], Gate: [none/review/approve]
- [Specific implementation details]
- [File locations, line numbers if known]
- **Integration:** [Which existing file(s) must import/call this. Which registry must be updated.]

**W1-2: [Task title] (#issue)** — Weight: [S/M/L/XL], Gate: [none/review/approve]
- [Specific implementation details]
- **Integration:** [...]

##### Wave 2
**Parallel dispatches:** [N]
**Blocked by:** [W-IDs from prior waves]

**W2-1: [Task title] (#issue)** — Weight: [S/M/L/XL], Gate: [none/review/approve], Deps: [W-IDs]
- [Specific implementation details]
- **Integration:** [...]

##### Critical Files
- `path/to/key-file.ext` — [why this file is central to this initiative]

##### Decision Log
<!-- Guardian appends here after wave completion -->

#### [Initiative Name] Worktree Strategy

Main is sacred. Each wave dispatches parallel worktrees:
- **Wave N:** `{project_root}/.worktrees/[worktree-name]` on branch `[branch-name]`

#### [Initiative Name] References

[APIs, docs, local files relevant to this initiative]

---

## Completed Initiatives

| Initiative | Period | Phases | Key Decisions | Archived |
|-----------|--------|--------|---------------|----------|
[Empty at project start — Guardian/compress_initiative() appends when initiatives complete]

---

## Parked Issues

Issues not belonging to any active initiative. Tracked for future consideration.

| Issue | Description | Reason Parked |
|-------|-------------|---------------|
[Empty at project start]
