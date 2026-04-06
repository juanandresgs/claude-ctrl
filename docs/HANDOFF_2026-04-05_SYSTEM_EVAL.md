# Handoff — 2026-04-05 System Evaluation Convergence

This handoff is meant to travel with the current system evaluation and be given
directly to Claude Code.

It does two things:

1. preserves the useful conclusions from the current analysis
2. corrects the places where the analysis is too optimistic about single
   authority and runtime convergence

## North Star

Drive `claude-ctrl-hardFork` to one authority per operational fact:

- one canonical `project_root`
- one canonical `workflow_id`
- one canonical active agent identity
- one readiness authority
- one dispatch routing authority
- one lifecycle authority for spawn and stop

The Python runtime is already the right center of gravity. The remaining work is
to remove identity drift, not to add another layer beside it.

## Current Truth Claude Code Should Assume

These points should be treated as more authoritative than docs prose.

### True

- `pre-write.sh` and `pre-bash.sh` are live fail-closed adapters into the
  Python policy engine.
- completion-driven routing is the live dispatch path
- `evaluation_state` is the live readiness authority
- `dispatch_queue` is non-authoritative
- SQLite is the intended authority across runtime domains

### Not Yet True Enough

- `agent_markers` is not yet a clean single authority in practice
- `workflow_id` is not yet normalized across all write, eval, and binding paths
- `project_root` is not yet normalized across all target-aware bash paths
- `proof_state` still pollutes operator-facing status surfaces

## Corrections To The Paired Analysis

Claude Code should explicitly account for these corrections while executing.

1. Marker authority is still operationally broken.
   - `SubagentStart` registers markers for all agent types.
   - `SubagentStop` only deactivates `planner|Plan`, `implementer`, `tester`,
     and `guardian`.
   - fallback role resolution still uses the newest active marker globally.
   - result: active `Explore` and `general-purpose` markers can contaminate
     actor-role truth.

2. The most important live bug is path normalization, not the implementer
   completion gap.
   - `test_state` uses exact `project_root` string keys.
   - `pre-bash.sh` forwards raw `target_cwd`.
   - `cli.py evaluate` resolves git top-level paths, which can canonicalize
     `/tmp` to `/private/tmp` and `~/.claude` to the repo realpath.
   - result: valid runtime rows can become invisible to policy evaluation.

3. Workflow identity is still split.
   - lease-first identity is the intended rule
   - some paths still derive workflow IDs from branch names
   - live DB already shows duplicate conceptual workflows under different IDs

4. Cleanup is opportunistic, not absent.
   - stale leases and markers do get expired at session start
   - the real problem is not "no cleanup exists"
   - the real problem is that stale marker fallback is still globally scoped

5. Cross-repo target-aware bash handling already has regression coverage.
   - do not spend a wave rediscovering that
   - use the existing tests as the baseline and extend them only where the
     current path-normalization bug requires it

## Priority Order

Work in this order. Do not reorder unless a deeper local inspection proves a
dependency is backwards.

1. Canonicalize path identity
2. Fix marker lifecycle and active-agent scoping
3. Converge workflow identity on lease-first semantics everywhere
4. Remove `proof_state` from live operator surfaces
5. Finish structured completion contracts for implementer and planner
6. Delete dead compatibility surfaces

## Execution Packets

Each packet is written so Claude Code can treat it as a bounded wave.

### Packet 1 — Path Identity Convergence

**Goal**

Make `project_root` and `worktree_path` comparisons stable across symlinks and
filesystem aliases so runtime rows remain visible to policy evaluation.

**Why first**

This is a live enforcement bug. It causes false denies in current behavior.

**Primary evidence**

- `tests/scenarios/test-guard-db-scoping.sh` currently fails
- `/tmp` paths canonicalize to `/private/tmp`
- `~/.claude` canonicalizes to the repo realpath

**Likely files**

- `hooks/pre-bash.sh`
- `hooks/pre-write.sh`
- `hooks/context-lib.sh`
- `runtime/cli.py`
- `runtime/core/policy_utils.py`
- `runtime/core/policy_engine.py`
- `runtime/core/test_state.py`
- `runtime/core/workflows.py`
- any helper that persists or looks up `project_root` or `worktree_path`

**Required behavior**

- every persisted `project_root` / `worktree_path` uses one canonical form
- every lookup normalizes the same way before querying
- the normalization rule is shared, not duplicated ad hoc

**Do not do**

- do not patch only the failing scenario
- do not add a second fallback lookup path beside the canonical one

**Acceptance criteria**

- `bash tests/scenarios/test-guard-db-scoping.sh` passes
- a direct `git -C /tmp/... commit` path and a direct `git -C ~/.claude/...`
  style path both resolve the same runtime rows they wrote
- no domain module persists raw paths while another persists realpaths

### Packet 2 — Marker Authority Repair

**Goal**

Make active-agent identity scoped and mechanically correct.

**Why second**

Marker fallback currently pollutes actor-role truth and statusline truth.

**Primary evidence**

- active `Explore` / `general-purpose` markers accumulate in live state
- fallback actor-role inference uses the newest active marker globally

**Likely files**

- `settings.json`
- `hooks/subagent-start.sh`
- `hooks/check-planner.sh`
- `hooks/check-implementer.sh`
- `hooks/check-tester.sh`
- `hooks/check-guardian.sh`
- `runtime/core/markers.py`
- `runtime/core/policy_engine.py`
- `runtime/core/statusline.py`
- lifecycle code under `runtime/core/`

**Required behavior**

- all spawned agent types that create markers must have a matching stop path
  or explicit non-marker exemption
- fallback marker reads must be scoped by project and preferably workflow
- statusline active-agent truth must not be sourced from unrelated sessions

**Do not do**

- do not keep global newest-marker fallback as a silent convenience path
- do not add another flat-file lifecycle tracker

**Acceptance criteria**

- live marker list no longer accumulates active lightweight roles indefinitely
- actor-role inference in policy evaluation cannot be contaminated by another
  workflow's active marker
- statusline active-agent is believable in concurrent or interrupted sessions

### Packet 3 — Workflow Identity Convergence

**Goal**

Finish lease-first workflow identity so all runtime writes and reads use the
same `workflow_id`.

**Why third**

Even after path normalization, readiness and routing will still drift if some
paths use branch-derived workflow IDs while others use lease-derived IDs.

**Primary evidence**

- duplicate workflow rows already exist for the same conceptual work
- `track.sh` still invalidates eval state with branch-derived IDs
- many workflow bindings point to the main worktree under different IDs

**Likely files**

- `hooks/track.sh`
- `hooks/context-lib.sh`
- `hooks/subagent-start.sh`
- `hooks/check-tester.sh`
- `hooks/check-guardian.sh`
- `hooks/post-task.sh`
- `runtime/core/policy_engine.py`
- `runtime/core/workflows.py`
- `runtime/core/evaluation.py`
- `runtime/core/completions.py`

**Required behavior**

- if a lease exists, its `workflow_id` wins everywhere
- branch-derived workflow IDs are fallback only when no lease exists
- workflow binding, evaluation invalidation, completion submission, and routing
  all agree on the same ID

**Do not do**

- do not leave branch-derived invalidation as a tolerated exception
- do not add new translation layers between workflow ID formats

**Acceptance criteria**

- no new duplicate-form workflow rows are created by normal operation
- evaluation invalidation after source writes targets the same workflow that the
  tester and guardian paths use
- workflow binding and routing use the same identity in live runs

### Packet 4 — Readiness Surface Cleanup

**Goal**

Remove `proof_state` from operator-facing live surfaces so readiness has one
visible authority, not just one enforcement authority.

**Why fourth**

Enforcement already uses `evaluation_state`, but statusline and diagnostics can
still tell a conflicting story.

**Likely files**

- `runtime/core/statusline.py`
- `runtime/core/proof.py`
- `runtime/cli.py`
- `hooks/session-init.sh`
- `docs/DISPATCH.md`
- `hooks/HOOKS.md`

**Required behavior**

- `evaluation_state` is the readiness display
- `proof_state` is either fully retired from operator surfaces or clearly marked
  as legacy debug-only state

**Do not do**

- do not keep `proof_state` in the main statusline snapshot as a parallel signal

**Acceptance criteria**

- statusline no longer reports contradictory proof/eval readiness
- docs stop describing prompt-driven proof verification as live behavior

### Packet 5 — Completion Contract Closure

**Goal**

Finish structured completion contracts so planner and implementer are no longer
heuristic or narrative-driven in stop handling.

**Why fifth**

This matters, but it is less urgent than path and identity correctness.

**Likely files**

- `agents/planner.md`
- `agents/implementer.md`
- `hooks/check-planner.sh`
- `hooks/check-implementer.sh`
- `runtime/core/completions.py`
- `runtime/core/dispatch_engine.py`

**Required behavior**

- implementer emits deterministic structured trailers
- planner emits deterministic structured trailers if planner routing remains
  role-significant
- stop logic does not rely on future-tense heuristics as the main signal

**Do not do**

- do not duplicate routing rules outside `completions.py`

**Acceptance criteria**

- implementer completion can be validated structurally
- planner completion can be validated structurally if planner remains a routed
  dispatch role
- interruption detection becomes advisory, not primary

### Packet 6 — Dead Surface Deletion

**Goal**

Delete compatibility and dead-weight surfaces once the runtime-first paths are
fully carrying the load.

**Likely files**

- `hooks/surface.sh`
- `hooks/write-guard.sh`
- `hooks/plan-guard.sh`
- `runtime/schemas.py`
- docs that still present dead surfaces as active
- zero-byte compatibility DB artifacts and flat-file remnants

**Primary targets**

- `.plan-drift` dead write
- `dispatch_queue` table and related manual-only CLI if genuinely no longer wanted
- stale `.subagent-tracker` references
- `.claude/runtime.db` placeholder if truly unused
- dead helper surfaces that preserve old authority stories

**Do not do**

- do not delete compatibility surfaces before the replacement path is proven
- do not keep dead code after a replacement is merged

**Acceptance criteria**

- hook/runtime/docs no longer imply legacy flat-file authorities are live
- schema no longer contains tables that the system itself declares
  non-authoritative unless they are intentionally retained for operator use

## Suggested Role Flow

Use the canonical role flow, but keep ownership narrow per packet.

1. `planner`
   - restate packet scope
   - map exact file boundaries
   - identify which authorities are being replaced in the same change

2. `implementer`
   - execute one packet only
   - delete the old authority in the same change where feasible
   - add tests before claiming completion

3. `tester`
   - verify the packet's explicit invariants
   - audit that no second authority survived beside the replacement

4. `guardian`
   - land only after the packet's acceptance criteria are evidenced

## Required Retest Set

Run these at minimum while executing this handoff:

- `python3 -m pytest tests/runtime/policies/test_bash_adapter_regressions.py -q`
- `bash tests/scenarios/test-guard-db-scoping.sh`
- `bash tests/scenarios/test-marker-lifecycle.sh`
- `bash tests/scenarios/test-lease-workflow-id-authority.sh`
- `bash tests/scenarios/test-routing-tester-completion.sh`
- `bash tests/scenarios/test-routing-guardian-completion.sh`

Before declaring the broader convergence complete, also rerun:

- `python3 -m pytest tests/runtime/test_policy_engine.py tests/runtime/test_dispatch_engine.py tests/runtime/test_dispatch.py tests/runtime/test_hook_bridge.py tests/runtime/test_evaluation.py tests/runtime/test_leases.py tests/runtime/test_markers.py tests/runtime/test_statusline_truth.py tests/runtime/test_cli.py tests/runtime/test_config_scoping.py tests/runtime/policies -q`

## Guidance For Claude Code

- start from code and live runtime state, not from stale docs
- treat identity normalization as architecture work, not as test-fixing
- when replacing an authority, remove or bypass the old one in the same change
- do not trust a green story from statusline alone while proof/eval surfaces are split
- do not spend time re-proving already-covered `target_cwd` regression cases
  except where path normalization changes them

## Bottom Line

The Python policy engine and completion-driven router are the right core.

The system is not blocked on inventing new architecture.

It is blocked on finishing convergence:

- canonical paths
- canonical workflow identity
- canonical active-agent identity
- canonical readiness display
- deletion of leftover authority shadows
