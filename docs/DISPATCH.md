# Dispatch

The canonical role flow is:

1. `planner`
2. `implementer`
3. `tester`
4. `guardian`

## Rules

- The orchestrator does not write source code directly.
- Implementer builds and hands off.
- Tester verifies and owns evidence.
- Guardian is the only role allowed to commit, merge, or push.

## Current Enforcement Surface

The following dispatch rules are mechanically enforced by the hook chain
registered in `settings.json`. These are hard blocks (deny with corrective
message), not advisory warnings.

### PreToolUse Write|Edit chain (fires on every Write or Edit call)

| Order | Hook | What it enforces |
|-------|------|-----------------|
| 1 | `hooks/branch-guard.sh` | Source files cannot be written on `main` or `master`. Non-source files, MASTER_PLAN.md, and `.claude/` are exempt. |
| 2 | `hooks/write-guard.sh` | Only the `implementer` role may write source files. Orchestrator (empty role), planner, tester, and guardian are denied. Non-source files are not governed. |
| 3 | `hooks/plan-guard.sh` | Only the `planner` (or `Plan`) role may write governance markdown (MASTER_PLAN.md, CLAUDE.md, `agents/*.md`, `docs/*.md`). `CLAUDE_PLAN_MIGRATION=1` env var overrides for permanent-section migrations. `.claude/` is exempt. |
| 4 | `hooks/doc-gate.sh` | Source files must have a documentation header. Files 50+ lines must contain a `@decision` annotation. Warns against creating new root-level markdown files (Sacred Practice #9). |
| 5 | `hooks/plan-check.sh` | Source files (Write of 20+ lines) cannot be written without MASTER_PLAN.md in the project root. Composite staleness check (source churn % + decision drift) can warn or deny when the plan is stale. Edit operations and small writes are exempt. |

### PreToolUse Bash chain (fires on every Bash call)

| Hook | What it enforces |
|------|-----------------|
| `hooks/guard.sh` | **WHO:** Only the `guardian` role may run `git commit`, `git merge`, or `git push`. **WHERE:** Cannot commit on `main`/`master` (except MASTER_PLAN.md-only commits). **SAFETY:** Denies `git reset --hard`, `git clean -f`, `git branch -D`, raw `--force` push (requires `--force-with-lease`), force push to main/master, worktree CWD hazards, `/tmp/` writes. **GATES:** Requires runtime `test_state` = pass and `evaluation_state` = `ready_for_guardian` (lease-first workflow_id resolution) before commit or merge. |

### SubagentStart (fires on every agent spawn)

| Hook | What it enforces |
|------|-----------------|
| `hooks/subagent-start.sh` | Tracks active agent role in `.subagent-tracker`. Injects role-specific context (branch state, plan status, research status, test status, proof state). Does not deny — context injection only. |

### SessionStart (fires on session start, /clear, /compact, resume)

| Hook | What it enforces |
|------|-----------------|
| `hooks/session-init.sh` | Injects git state, plan status, research status, proof state, stale session files, todo HUD. Clears stale session artifacts. Does not deny — context injection only. |

### UserPromptSubmit (fires on every user prompt)

| Hook | What it enforces |
|------|-----------------|
| `hooks/prompt-submit.sh` | Records proof verification when user replies "verified". Injects contextual HUD (git state, plan status, agent findings, compaction suggestions). Auto-claims referenced issues. Does not deny — context injection and state recording only. |

## Not Yet Enforced

The following dispatch properties exist as prompt guidance in CLAUDE.md and
`agents/*.md` but are **not mechanically enforced by any hook or gate**:

- **Automatic role sequencing.** The planner-to-implementer-to-tester-to-guardian
  flow is a convention the orchestrator follows from prompt instructions. No hook
  blocks dispatching out of order.
- **Orchestrator direct dispatch denial.** The orchestrator can still dispatch
  any agent type at any time. No hook prevents skipping the planner or tester.
- **Typed runtime dispatch queue.** `dispatch_queue` exists (INIT-002/TKT-009)
  but is non-authoritative (DEC-WS6-001). Routing uses completion records via
  `determine_next_role()`. The queue is retained for manual orchestration only.
- **Plan section immutability.** MASTER_PLAN.md permanent sections (Identity,
  Architecture, Principles, Decision Log rows) are protected by prompt
  instructions only. `planctl.py` validates section presence but does not enforce
  immutability or append-only decision log semantics.
- **Orchestrator source-write prevention at dispatch level.** The orchestrator
  cannot write source files (enforced by `write-guard.sh`), but this is
  role-based write denial, not dispatch-level prevention. The orchestrator could
  still attempt to write and receive a deny rather than being prevented from
  trying.
