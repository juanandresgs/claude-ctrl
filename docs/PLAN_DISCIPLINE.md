# Plan Discipline

`MASTER_PLAN.md` is the human memory layer for the fork itself.

## It Must Contain

- Identity
- Architecture
- Original Intent
- Principles
- Decision Log
- Active Initiatives
- Completed Initiatives
- Parked Issues

## It Must Not Become

- A runtime database
- A scratchpad for transient thoughts
- A replacement for structured workflow state

## Current Enforcement

Two hooks enforce plan discipline today. Both are hard blocks (deny with
corrective message).

### `hooks/plan-check.sh` (PreToolUse Write|Edit)

Enforces Sacred Practice #6: "No Implementation Without Plan."

- **Plan existence gate:** Denies source file Write (20+ lines) when no
  `MASTER_PLAN.md` exists in the project root. Edit operations and small writes
  (under 20 lines) bypass this check.
- **Plan staleness check:** Composite signal from source file churn percentage
  (self-normalizing by project size) and decision drift count (from last surface
  audit). Two thresholds:
  - **Warn** at 15% source churn or 2+ drifted decisions.
  - **Deny** at 35% source churn or 5+ drifted decisions.
  - When no prior audit exists, falls back to raw commit count (warn at 40,
    deny at 100).
- **Scope:** Only fires for source files in git repos. Non-source files, test
  files, `.claude/` meta-infrastructure, and non-git directories are exempt.

### `hooks/plan-guard.sh` (PreToolUse Write|Edit)

Enforces governance markdown authority (DEC-FORK-014).

- **WHO:** Only the `planner` or `Plan` role may write governance markdown
  files: `MASTER_PLAN.md`, `CLAUDE.md`, `agents/*.md`, `docs/*.md`.
- **Override:** `CLAUDE_PLAN_MIGRATION=1` environment variable allows any role
  to write governance markdown for permanent-section migrations.
- **Exemption:** Files under `.claude/` are not considered governance markdown
  (meta-infrastructure is self-governed).
- **Deny behavior:** All other roles (implementer, tester, guardian, orchestrator
  with no role) receive a deny with a message directing them to dispatch a
  planner agent.

## Not Yet Enforced

The following plan discipline properties are described in CLAUDE.md and
`agents/planner.md` but are **not mechanically enforced** by any hook or tool:

- **Section immutability.** Permanent sections (Identity, Architecture, Original
  Intent, Principles, and existing Decision Log rows) are protected by prompt
  instructions to the planner agent. No hook prevents overwriting them.
  `planctl.py` validates section *presence* but not content stability.
- **Append-only decision log.** The Decision Log is expected to be append-only.
  No hook or tool prevents editing or deleting existing entries.
- **Initiative compression.** Completed initiatives should be compressed to
  summaries. This is a prompt convention, not enforced.
- **Timestamp stamping.** `planctl.py` has a `stamp` command but it is not wired
  into any hook. Plan timestamps are managed manually.
- **Automatic plan refresh triggers.** The staleness check in `plan-check.sh`
  warns or denies further source writes, but it does not automatically trigger a
  plan update. The agent must choose to update the plan.

## Enforcement Direction

`scripts/planctl.py` is currently a 67-line scaffold that validates section
presence and stamps a placeholder timestamp. It does not enforce section
immutability, append-only decision log semantics, or initiative compression.

TKT-010 (INIT-003 in MASTER_PLAN.md) defines the path to expand `planctl.py`
into real mechanical enforcement of these properties. Until that work lands, plan
discipline relies on prompt instructions to the planner agent and the two hooks
described above.
