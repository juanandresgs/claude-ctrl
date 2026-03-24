# Architecture

## Current Bootstrap

The hard fork currently runs on the patched `v2.0` kernel imported into
`hooks/` and registered by `settings.json`. This is intentional. Phase 1 of the
successor plan prioritizes a working, understandable control plane over early
architectural purity.

### Current Enforcement Surface

The live control plane is the hook chain registered in `settings.json`. Each
hook is a standalone shell script that reads JSON from stdin and emits a JSON
response to stdout. The hooks enforce policy; they do not own workflow state
beyond what they read from flat files at decision time.

**PreToolUse Write|Edit chain** (fires in order on every Write or Edit call):

1. `hooks/branch-guard.sh` -- Denies source file writes on `main`/`master`.
   Exempts non-source files, MASTER_PLAN.md, and `.claude/` meta-infrastructure.
2. `hooks/write-guard.sh` -- WHO enforcement: only the `implementer` role may
   write source files. All other roles (orchestrator, planner, tester, guardian)
   are denied. Non-source files pass through. Role detection uses
   `.subagent-tracker` via `context-lib.sh`.
3. `hooks/plan-guard.sh` -- Governance markdown authority: only the `planner`
   (or `Plan`) role may write MASTER_PLAN.md, CLAUDE.md, `agents/*.md`, or
   `docs/*.md`. Override: `CLAUDE_PLAN_MIGRATION=1` env var. `.claude/` exempt.
4. `hooks/doc-gate.sh` -- Documentation quality: source files must have a doc
   header; 50+ line files must have `@decision` annotation. Warns (does not
   block) on Edit to headerless files. Warns against new root-level markdown.
5. `hooks/plan-check.sh` -- Plan-first gate: denies source file Write (20+
   lines) when no MASTER_PLAN.md exists. Composite staleness check (source churn
   percentage + decision drift count) warns or denies when the plan is stale.
   Edit operations and small writes bypass.

**PreToolUse Bash chain** (fires on every Bash call):

1. `hooks/guard.sh` -- Multi-check gate:
   - WHO: only `guardian` role may `git commit/merge/push`.
   - WHERE: cannot commit on `main`/`master` (MASTER_PLAN.md-only commits
     exempt).
   - SAFETY: denies `git reset --hard`, `git clean -f`, `git branch -D`, raw
     `--force` push, force push to main/master, worktree CWD hazards, `/tmp/`
     writes.
   - GATES: requires `.test-status` = pass and proof-of-work = verified before
     commit or merge.

**SubagentStart** (fires on every agent spawn):

- `hooks/subagent-start.sh` -- Tracks active agent role in `.subagent-tracker`.
  Injects role-specific context. Does not deny.

**SessionStart** (fires on session start, /clear, /compact, resume):

- `hooks/session-init.sh` -- Injects git state, plan status, proof state.
  Clears stale session artifacts. Does not deny.

**UserPromptSubmit** (fires on every user prompt):

- `hooks/prompt-submit.sh` -- Records proof verification on "verified" reply.
  Injects contextual HUD. Auto-claims referenced issues. Does not deny.

### Scaffolds (Not Yet Active)

The following directories and files exist in the repository but are **scaffolds
only** -- they are not wired into the live hook chain and do not participate in
any enforcement or state management:

- `runtime/cli.py` -- Placeholder for the `cc-policy` CLI. Currently a 2.4k
  scaffold with no real state backend.
- `runtime/schemas.py`, `runtime/server.py` -- Stubs (44 bytes, 58 bytes).
- `runtime/core/` -- Empty or minimal scaffold directory.
- `hooks/lib/*.sh` -- Future decomposed hook policy libraries. `core.sh` loads
  `log.sh`, `context-lib.sh`, and `runtime-bridge.sh` but no hook entrypoint
  sources these yet. The individual policy files (`bash-policy.sh`,
  `write-policy.sh`, `dispatch-policy.sh`, etc.) are stubs.
- `hooks/lib/runtime-bridge.sh` -- 215-byte scaffold. Will bridge hooks to the
  typed runtime once `cc-policy` is real.
- `scripts/planctl.py` -- 67-line bootstrap helper that validates
  MASTER_PLAN.md section presence and stamps a placeholder timestamp. Does not
  enforce section immutability, append-only decision log, or initiative
  compression.
- `scripts/statusline.sh` -- Bootstrap cache reader. Will be rebuilt as a
  runtime-backed read model (INIT-002, TKT-011/TKT-012).

## Target Shape

The target architecture is:

1. Canonical prompts in `CLAUDE.md` and `agents/`
2. Thin hook entrypoints and small shell policy libs
3. Typed runtime for shared state and concurrency
4. Runtime-backed read models such as the statusline HUD
5. Read-only sidecars for observability and search

This target is defined in INIT-002 and INIT-003 of MASTER_PLAN.md. None of
these layers are active yet; the current system runs entirely on the bootstrap
hook kernel described above.

## Statusline Direction

The richer statusline HUD is part of the successor architecture, but it must be
implemented as a read model over canonical runtime state. `scripts/statusline.sh`
currently renders from a bootstrap cache; it must not become a second authority
for workflow state, nor may it rely on flat-file or breadcrumb coordination once
the runtime is live.

## Migration Boundary

Until the runtime is live, imported v2 hooks remain the active authority. New
modular files must not become a second live control path by accident.
