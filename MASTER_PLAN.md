# MASTER_PLAN.md

Status: active
Created: 2026-03-23
Last updated: 2026-05-12 (Implementer critic routing repair initiative)

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
- `2026-05-12 -- DEC-CRITIC-CONTEXT-001` Implementer critic context (workflow
  identity + lease identity at SubagentStop) is owned by a single runtime
  authority that resolves from the SubagentStop hook input, not by branch
  inference. The bash wrapper (`hooks/implementer-critic.sh`) and the Node
  sidecar (`sidecars/codex-review/scripts/implementer-critic-hook.mjs`) call
  the same `cc-policy` resolver; they must not derive workflow_id via
  `current_workflow_id()` or `detect_project_root()` when the hook payload
  carries the implementer's cwd or agent_id. The resolver prefers
  agent_id-anchored lease lookup, then hook-input-cwd-anchored lease lookup,
  then a clearly-marked unresolved state — never the orchestrator session
  branch. Rationale: SubagentStop fires in the orchestrator's context, so
  PROJECT_ROOT/CLAUDE_PROJECT_DIR resolve to the orchestrator and mis-tag the
  critic_reviews row to the orchestrator's workflow_id. Encoding the resolver
  in runtime keeps a single authority per CLAUDE.md "Architecture
  Preservation" and prevents the bash/Node wrappers from drifting apart.
- `2026-05-12 -- DEC-CRITIC-BLOCKED-002` When implementer critic is enabled
  and `dispatch_engine` returns PROCESS ERROR (no matching critic_reviews
  row, missing execution proof, or non-routable verdict), `hooks/post-task.sh`
  must surface a hard `BLOCKED:` marker inside
  `hookSpecificOutput.additionalContext` that the orchestrator already
  honors as a stop condition (per CLAUDE.md "Auto-Dispatch" rules). The
  orchestrator must not fall back to the implementer's self-reported
  `IMPL_RESULT:` trailer to dispatch reviewer; that is the parallel-authority
  bug that was hiding the broken critic loop. Rationale: encoding the stop in
  the hook output is mechanically enforced, while a CLAUDE.md prose
  instruction is brittle and depends on the orchestrator's reading
  discipline — CLAUDE.md "Architecture Preservation" requires the stricter
  encoding.
- `2026-05-12 -- DEC-WT-RETIRE-TEST-005` (closes issue #82)
  `test_retire_branch_d_fails_after_worktree_remove` must actually exercise
  the step-4 (git branch -d) failure path after a successful step-3 worktree
  remove (DEC-WT-RETIRE-003a rollback boundary), e.g. by pre-deleting the
  feature branch ref so step 4 errors with "branch not found" while step 3
  succeeds. The step-3 locked-worktree case it previously covered is lifted
  out into a separately named test (`test_retire_worktree_remove_fails_when_locked`)
  so coverage of both rollback boundaries is preserved.

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

### Implementer Critic Routing Repair

**Status:** in-progress

**Workflow:** `fix-implementer-critic-routing`
**Goal:** `g-fix-critic-routing`
**Closes:** GitHub issues `#81`, `#82`

**Problem statement.** The implementer critic loop is cosmetic. Three concrete
defects compound to make Codex critic verdicts unable to drive routing, while
appearing in the UI and persisting to the database:

- **R1 — wrong workflow_id.** `hooks/implementer-critic.sh` and
  `sidecars/codex-review/scripts/implementer-critic-hook.mjs` resolve their
  context via `detect_project_root` / `CLAUDE_PROJECT_DIR` /
  `current_workflow_id`. SubagentStop fires in the orchestrator's session
  context, so these resolve to the orchestrator (`/Users/turla/.claude`) and
  tag `critic_reviews.workflow_id` with the orchestrator's session branch
  (e.g. `codex-dispatch-runtime-authority`) instead of the implementer's
  actual workflow_id (e.g. `worktree-retire-authority`).
- **R2 — empty lease_id.** Same root cause: `lease current --worktree-path`
  is called with the orchestrator's path, returns nothing, and the wrappers
  submit `critic-review` rows with `lease_id=""`. The implementer's actual
  lease (already issued with a populated `agent_id`) is never consulted.
- **R3 — orchestrator ignores PROCESS ERROR.** Even when `dispatch_engine`
  correctly returns `next_role=None, error="PROCESS ERROR: implementer
  critic did not run."` because no critic_reviews row matches the workflow_id
  it's looking up, the orchestrator reads the implementer's self-reported
  `IMPL_RESULT: complete, READY_FOR_REVIEWER` trailer and dispatches reviewer
  manually. This is the parallel-authority pattern CLAUDE.md "Architecture
  Preservation" forbids.

Hard evidence in `state.db` `critic_reviews`: three rows for recent runs,
none matching the implementer's workflow_id, all with `lease_id=""`, all
TRY_AGAIN — including row id=3, whose verdict text correctly identified that
`test_retire_branch_d_fails_after_worktree_remove` does not exercise the
step-4 failure path it claims to. We shipped past it because the routing was
silently broken.

**Goal.** Close the implementer critic loop end-to-end so a TRY_AGAIN verdict
from Codex actually routes implementer→implementer (and a BLOCKED_BY_PLAN
verdict routes implementer→planner), with a regression test that proves it,
and fix the #82 test as part of the same bundle so the now-closed loop would
catch equivalent gaps going forward.

**Non-goals.**
- Reshaping the canonical routing table (DEC-COMPLETION-001 / DEC-ROUTING-002
  remain authoritative).
- Changing reviewer outer-loop readiness semantics.
- Reworking critic execution-proof validation rules.

**Architecture decisions.**
- DEC-CRITIC-CONTEXT-001 (this update): runtime-owned resolver, called from
  both wrappers; agent_id-first, hook-input-cwd-second lookup; never branch
  inference. (Architectural choice B + C from the planner brief; choice A — a
  parallel inline fix in each wrapper — was rejected because it preserves two
  drift-prone authorities.)
- DEC-CRITIC-BLOCKED-002 (this update): post-task.sh emits a hard `BLOCKED:`
  signal on PROCESS ERROR. (Architectural choice R3b; choice R3a — a prose
  fix in CLAUDE.md — was rejected because the existing CLAUDE.md "Auto-
  Dispatch" rules already honor BLOCKED, so the mechanical fix is cheaper
  than relying on orchestrator narration discipline.)
- DEC-WT-RETIRE-TEST-005 (this update): #82 test rewrite ships in this same
  bundle; the whole point is closing a loop that would otherwise let the same
  class of defect through.

**Scope (authoritative — runtime scope-sync written for
`wi-fix-critic-routing-implementation`):**

Allowed / required surfaces:
- `hooks/implementer-critic.sh` (R1, R2)
- `sidecars/codex-review/scripts/implementer-critic-hook.mjs` (R1, R2)
- `runtime/cli.py` and/or `runtime/core/critic_context.py` (new resolver)
- `runtime/core/dispatch_engine.py` (verify PROCESS ERROR shape; do not
  expand routing table)
- `runtime/core/critic_reviews.py` (touch only if `assess_latest` needs
  adjustment — default expectation is no change)
- `hooks/post-task.sh` (R3b BLOCKED encoding)
- `tests/runtime/test_critic_context.py` (new)
- `tests/runtime/test_critic_routing_end_to_end.py` (new)
- `tests/runtime/test_dispatch_engine_critic.py` (new)
- `tests/runtime/test_post_task_blocked_signal.py` (new)
- `tests/runtime/test_retire_worktree_cli.py` (rewrite of the named test,
  plus a new `test_retire_worktree_remove_fails_when_locked`)

Forbidden surfaces:
- `runtime/core/completions.py` (DEC-COMPLETION-001 routing table)
- `agents/planner.md`, `agents/implementer.md`, `agents/reviewer.md`,
  `agents/guardian.md` (no agent-prose routing fixes; this is a runtime/hook
  fix)
- `settings.json` (hook wiring is correct; this is a logic fix)
- Existing Decision Log entries above DEC-WT-RETIRE-004 (append-only)

**Evaluation Contract (mirrors the runtime work-item record):**

Required tests (real SQLite, real subprocess; no `unittest.mock.patch` on
subprocess in new tests, per Sacred Practice #5):
1. `tests/runtime/test_critic_context.py::test_critic_context_resolves_implementer_workflow_from_hook_input`
2. `tests/runtime/test_critic_context.py::test_critic_context_resolves_lease_id_by_agent_id`
3. `tests/runtime/test_critic_routing_end_to_end.py::test_critic_review_submitted_with_correct_workflow_id`
4. `tests/runtime/test_dispatch_engine_critic.py::test_dispatch_engine_routes_try_again_back_to_implementer`
5. `tests/runtime/test_dispatch_engine_critic.py::test_dispatch_engine_blocks_when_critic_missing`
6. `tests/runtime/test_post_task_blocked_signal.py::test_post_task_emits_blocked_signal_on_process_error`
7. `tests/runtime/test_retire_worktree_cli.py::test_retire_branch_d_fails_after_worktree_remove` (rewritten — step-4)
8. `tests/runtime/test_retire_worktree_cli.py::test_retire_worktree_remove_fails_when_locked` (new — preserves step-3 coverage)

Required real-path check: a live implementer dispatch against a scratch
workflow with `critic_enabled=true`, emitting known-bad code, must produce a
`critic_reviews` row tagged to the scratch workflow_id with non-empty
lease_id, and `dispatch_engine.process_agent_stop` must return
`next_role="implementer"`. Trace captured in PR description.

Required authority invariants:
- `critic_reviews.workflow_id` equals the implementer lease workflow_id, not
  the orchestrator session branch.
- `critic_reviews.lease_id` is non-empty whenever an implementer lease
  exists at SubagentStop.
- `dispatch_engine` returns `next_role=None` with PROCESS ERROR when
  `critic_enabled=true` and no matching critic_reviews row exists for the
  resolved workflow_id.
- `post-task.sh` `additionalContext` carries a `BLOCKED:` marker on PROCESS
  ERROR.

Forbidden shortcuts:
- No prose-only CLAUDE.md fix for R3 without the runtime BLOCKED signal.
- No `current_workflow_id()` fallback in the critic hook when hook-input cwd
  is present.
- No mocking of `subprocess.*` in the new critic-context or end-to-end tests.
- No filing the #82 rewrite as follow-up.
- No expansion of the `dispatch_engine` routing table.

Ready-for-guardian definition: all 8 required tests pass on a clean
checkout; live real-path trace in PR description proves the row matches and
lease_id is populated; reviewer subagent returns
`REVIEW_VERDICT=ready_for_guardian`; `cc-policy` reports no scope
violations; PR text references `#81` and `#82` for closure.

**Wave decomposition.**

Single bundle (per CLAUDE.md "Architecture Preservation" — authority change
ships with invariants, derived surfaces, and removal of the superseded path
in one change).

- **W-CCR-1** (`wi-fix-critic-routing-implementation`) — single
  implementation slice covering: (a) runtime resolver
  (`runtime/core/critic_context.py`) and `cc-policy critic context resolve`
  surface; (b) `hooks/implementer-critic.sh` and the Node sidecar switched to
  the resolver; (c) `hooks/post-task.sh` BLOCKED encoding for PROCESS ERROR;
  (d) tests #1–#6 above; (e) #82 test rewrite plus the new
  `test_retire_worktree_remove_fails_when_locked`. Weight: L. Gate:
  review→guardian(land). Deps: none. Landing policy: default grant from
  work-item record (`can_commit_branch`, `can_request_review`,
  `can_autoland`, `no_ff`); destructive/history-rewrite actions remain
  user-gated per the standard grant. Integration: critic_reviews table,
  leases table, dispatch_attempts table, workflow_bindings.

**Exit.** Active goal closes when the work item lands, the live real-path
trace is in the PR description, and both `#81` and `#82` are closed by the
merge. The Critic Telemetry And Visibility initiative remains in-progress —
this fix is a prerequisite, not a substitute, for visibility work.

**Dependencies.** None blocking. Public Codex Critic Lane and Critic
Telemetry And Visibility initiatives are upstream context; this fix is
inside their authority surface but does not change their contracts.

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
