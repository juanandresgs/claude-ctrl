# MASTER_PLAN.md

Status: active
Created: 2026-03-23
Last updated: 2026-05-06 (Codex critic visibility digest)

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
- `2026-05-03 -- DEC-CRITIC-RUNS-001` Add critic run telemetry as the
  first-class visibility lane around `critic_reviews`: final verdicts remain
  routing authority, while lifecycle progress, fallback state, traces, and
  metrics feed the statusline, conversation digest, and self-improvement evals.
- `2026-05-06 -- DEC-CRITIC-VISIBILITY-002` Carry critic findings and
  user-visible digests through the final dispatch output, and render the latest
  active or current implementer-anchored critic progress/summary in the
  statusline so Codex CLI critique is not hidden behind prompt-discipline-only
  narration or falsely revived from stale global rows.
- `2026-05-03 -- DEC-GUARDIAN-ADMISSION-001` Add Guardian Admission as the
  non-canonical Guardian mode and pre-workflow custody authority for the fork
  between project onboarding/provisioning and task-local scratchlane work.
  Scratchlane permits remain owned by `runtime/core/scratchlanes.py`;
  admission may apply them only through that authority.
- `2026-05-10 -- DEC-WT-RETIRE-001` `_retire_worktree` is the sole atomic
  cleanup authority for feature worktrees, symmetric counterpart to
  `_provision_worktree`. Guardian calls `cc-policy worktree retire` after a
  successful landing. No agent-side prose path, `safe_cleanup` script, or
  manual `git worktree remove` / `git branch -d` sequence substitutes for this
  function. The runtime function owns the full sequence atomically.
- `2026-05-10 -- DEC-WT-RETIRE-002` Retire Guardian lease is anchored at
  `project_root`, never the feature worktree path. The lease must outlive
  the worktree disappearing mid-operation. The project_root anchor survives
  the entire retire sequence and is released in `finally`, preventing
  stranded leases.
- `2026-05-10 -- DEC-WT-RETIRE-003` (superseded by DEC-WT-RETIRE-003a) ---
  original planner-approved ordering placed `git branch -d` before
  `git worktree remove`. Superseded because git refuses `branch -d` on a
  branch that is checked out in a live worktree. See DEC-WT-RETIRE-003a.
- `2026-05-10 -- DEC-WT-RETIRE-003a` Step ordering inverted from
  DEC-WT-RETIRE-003: `git worktree remove` runs before `git branch -d`
  because git refuses `branch -d` on a branch that is currently checked out in
  any worktree. The fail-before-mutation invariant for unmerged branches is
  preserved via an explicit `git merge-base --is-ancestor` pre-flight check
  (step 2) that runs before either git mutation. Atomicity and rollback
  semantics are preserved by the Guardian PROJECT_ROOT lease (DEC-WT-RETIRE-002)
  plus the pre-flight gate that blocks both git ops when the branch is unmerged.
  Rollback boundary under the new ordering: if `git worktree remove` (step 3)
  fails, branch is untouched and registry is untouched - caller retries from
  step 3. If `git branch -d` (step 4) fails after successful worktree remove,
  the registry is NOT soft-deleted; the next retry observes
  (worktree-gone, branch-still-exists, registry-still-active) and converges
  from a `branch -d` retry. The lease-anchor invariant (DEC-WT-RETIRE-002)
  is unchanged.
- `2026-05-10 -- DEC-WT-RETIRE-004` Retire explicitly revokes leases by
  `worktree_path` filter and does NOT call `revoke_missing_worktrees()`.
  That janitor function is for leak recovery; using it as primary cleanup
  would conflate intentional cleanup with accidental path loss, create a race
  window, and make revocation dependent on filesystem state rather than
  explicit lease IDs.

## Active Initiatives

### Public Release Hygiene

**Status:** in-progress

**Goal:** Keep the public repository aligned with the installed ClauDEX
mechanism and free of private worktree artifacts, stale docs, and deleted-path
references.

**Scope:** `README.md`, `CLAUDE.md`, `AGENTS.md`, `MASTER_PLAN.md`,
`settings.json`, `hooks/`, `runtime/`, `scripts/`, `sidecars/`, `skills/`,
`evals/`, `.codex/prompts/`, the installer, and ignore rules.

**Exit:** Runtime validation commands pass, public docs point only at live
surfaces, stale root documentation, private harness trees, root temporary
folders, private release folders, and orphan scripts are absent from the
tracked release tree.

**Dependencies:** None.

### Critic Telemetry And Visibility

**Status:** in-progress

**Goal:** Make Codex critic work visible and measurable without turning traces
into enforcement authority.

**Scope:** `runtime/core/critic_runs.py`, `runtime/core/critic_reviews.py`,
`runtime/core/dispatch_engine.py`, `critic_runs` schema, `cc-policy critic-run`,
implementer critic hook telemetry, statusline projection, trace manifest
entries, and success metrics for loopback, fallback, duration, and escalation
behavior.

**Exit:** Critic runs persist start/progress/final/fallback lifecycle state,
statusline shows compact live status, the Claude thread receives a concise
critic digest, traces can reconstruct critic activity, and focused tests cover
runtime metrics, hook telemetry, and HUD rendering.

**Dependencies:** Public Codex Critic Lane.

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

### State DB Consolidation

**Status:** completed

**Summary:** Moved durable hook/control-plane memory into `state.db`: session
prompt/change tracking, linter enforcement gaps, linter profile cache, lint
circuit breakers, compaction handoff context, escalating write-policy strike
counters, Bash mutation baselines, and critic review details. Runtime hooks no
longer create durable `.claude/.session-*`, `.prompt-count-*`,
`.enforcement-gaps`, `.lint-cache-*`, `.lint-breaker-*`, `.preserved-context`,
`.test-gate-strikes`, `.mock-gate-strikes`, `tmp/.bash-source-baseline-*`, or
critic review artifact files.

### Guardian Admission

**Status:** completed

**Summary:** Added the `cc-policy admission` classifier/apply domain,
Guardian admission mode in `agents/guardian.md`, SubagentStop audit handling,
write/Bash admission gates, scratchlane auto-application path, and
deterministic eval coverage for project onboarding vs scratchlane custody.

## Parked Issues

- Decide whether `evals/` should remain a public benchmark fixture set long
  term or move to a separate validation repository once the public release line
  stabilizes.
- Decide whether a generated public architecture reference should replace the
  removed hand-written documentation tree. If restored, it should be generated
  from or validated against the runtime authorities.
