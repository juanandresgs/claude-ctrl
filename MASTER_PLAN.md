# MASTER_PLAN.md

Status: active
Created: 2026-03-23
Last updated: 2026-04-27 (Public ClauDEX release surface cleanup)

## Identity

This repository is the public release line for `claude-ctrl` v5.0 ClauDEX: a
Claude Code configuration, hook kernel, and typed policy runtime for turning
prompt doctrine into mechanically enforced workflow behavior.

## Architecture

ClauDEX is organized around one control-plane rule: prompts guide, hooks
adapt, and the runtime decides.

- `CLAUDE.md` and `agents/` define the operating doctrine and stage contracts.
- `settings.json` wires Claude Code events to hook adapters in `hooks/`.
- `hooks/` normalizes event payloads and calls the runtime instead of owning
  policy decisions directly.
- `runtime/` owns policy evaluation, SQLite state, dispatch, leases, reviewer
  readiness, work items, prompt packs, and validation commands through
  `bin/cc-policy`.
- `sidecars/codex-review/` owns the public Codex CLI critic path for
  implementer convergence review.
- `scripts/` contains live support entrypoints only: statusline rendering,
  backlog/todo plumbing, plan discipline checks, and shared keychain helpers.
- `evals/` is retained because `cc-policy eval` uses the scenarios and
  fixtures as behavioral evaluation inputs.

The public repository intentionally does not ship the private root-level
pytest/scenario harness. Public verification is through the runtime validation
commands documented in `README.md`.

## Original Intent

Preserve the original claude-ctrl thesis that model-context instructions are
not constraints, then update the mechanism for ClauDEX: shell hooks become
boundary adapters, a typed runtime owns operational truth, and stage work moves
through deterministic dispatch, critique, review, and landing gates.

## Principles

1. Prompts carry intent; hooks enforce boundaries; runtime state owns facts.
2. Keep one authority per operational fact.
3. Collapse stale or parallel authorities instead of documenting around them.
4. Make the correct path automatic and unsafe paths mechanically difficult.
5. Preserve public surfaces that are live, validated, or intentionally useful.
6. Remove private execution history and stale development scaffolding from the
   release line.
7. Keep the kernel simpler than the work it governs.

## Decision Log

- `2026-04-27 -- DEC-PUB-001` Publish ClauDEX as claude-ctrl v5.0, centered on
  typed runtime enforcement, stage dispatch, Guardian landing, Reviewer
  readiness, and Codex CLI implementer critique.
- `2026-04-27 -- DEC-PUB-002` Remove stale public root documentation and
  private development harness surfaces from the release line when they are not
  live runtime inputs or validated public artifacts.
- `2026-04-27 -- DEC-PUB-003` Keep `evals/` because the runtime evaluation CLI
  uses its scenarios and fixtures directly.
- `2026-04-27 -- DEC-PUB-004` Keep `scripts/` only for live runtime support
  files used by `settings.json`, hooks, policies, skills, or sidecars.

## Active Initiatives

### Public Release Hygiene

**Status:** in-progress

**Goal:** Keep the public repository aligned with the installed ClauDEX
mechanism and free of private worktree artifacts, stale docs, and deleted-path
references.

**Scope:** `README.md`, `CLAUDE.md`, `AGENTS.md`, `MASTER_PLAN.md`,
`settings.json`, `hooks/`, `runtime/`, `scripts/`, `sidecars/`, `skills/`,
`evals/`, `.codex/prompts/`, installers, and ignore rules.

**Exit:** Runtime validation commands pass, public docs point only at live
surfaces, stale root documentation, private harness trees, root temporary
folders, private release folders, and orphan scripts are absent from the
tracked release tree.

**Dependencies:** None.

## Completed Initiatives

### README Restoration

**Status:** completed

**Summary:** Restored the upstream-style public README, banner, design
philosophy, cybernetics statement, v5.0 ClauDEX narrative, diagrams, install
paths, and validation commands.

### Public Codex Critic Lane

**Status:** completed

**Summary:** Documented the implementer Codex CLI critic as the inner-loop
quality filter and kept the public implementation under
`sidecars/codex-review/` plus `hooks/implementer-critic.sh`.

## Parked Issues

- Decide whether `evals/` should remain a public benchmark fixture set long
  term or move to a separate validation repository once the public release line
  stabilizes.
- Decide whether a generated public architecture reference should replace the
  removed hand-written documentation tree. If restored, it should be generated
  from or validated against the runtime authorities.
