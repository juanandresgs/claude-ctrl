# MASTER_PLAN.md

Status: active
Created: 2026-03-23
Last updated: 2026-03-24 (INIT-001 completed; INIT-002 execution detail added)

## Identity

This repository is the hard-fork successor to `claude-config-pro`. It is being
built from the patched `v2.0` kernel outward so the governance layer remains
smaller, more legible, and more mechanically trustworthy than the work it
governs.

## Architecture

- Canonical judgment lives in [CLAUDE.md](CLAUDE.md) and [agents/](agents).
- The active live authority is still the imported patched `v2.0` hook kernel in
  [hooks/](hooks) with [settings.json](settings.json).
- The canonical prompt layer is present, but several of its intended guarantees
  are not yet mechanically enforced in the bootstrap kernel.
- The current hard gaps are: missing write-side WHO enforcement, no real typed
  runtime ownership of shared state, and no revalidated subagent lifecycle
  contract against the installed Claude runtime.
- The current statusline is only a bootstrap HUD. The successor statusline will
  be rebuilt as a runtime-backed read model over the new state machine, not as a
  separate authority path.
- The target architecture is modular: thin hooks, typed runtime, read-only
  sidecars, and strict plan discipline.
- The future shared-state authority moves into [runtime/](runtime), reached
  through [hooks/lib/runtime-bridge.sh](hooks/lib/runtime-bridge.sh).
- No second live control path is allowed during migration. Replacements must cut
  over fully and delete the superseded mechanism.

## Original Intent

Bootstrap a new control-plane fork that preserves the stable determinism of
`v2.0`, carries forward the essential safety and proof fixes, selectively
rebuilds only the genuinely valuable ideas from later versions, and reaches a
full successor spec without dragging `claude-config-pro` complexity wholesale
into the new mainline.

## Principles

1. Start from the working kernel, not from the most complex branch.
2. Prompts shape judgment; hooks enforce local policy; runtime owns shared
   state.
3. Every claimed invariant must be backed by a gate, a state check, or a
   scenario test on the installed Claude runtime.
4. Port proven enforcement from history when it worked; simplify the
   implementation instead of deleting the control property.
5. Delete what you replace. Do not keep fallback authorities alive.
6. Preserve readable ownership boundaries between prompts, hooks, runtime, and
   sidecars.
7. The successor runtime must eliminate flat-file and breadcrumb coordination
   for workflow state; evidence files may exist, but they are never authority.
8. Docs must not claim protection that the running system cannot actually
   enforce.
9. Upstream is a donor, not the mainline.

## Decision Log

- `2026-03-23 — DEC-FORK-001` Bootstrap the successor from the patched `v2.0`
  kernel rather than from `claude-config-pro` `main`.
- `2026-03-23 — DEC-FORK-002` Preserve the canonical prompt rewrite already
  drafted in this repository and layer the kernel beneath it.
- `2026-03-23 — DEC-FORK-003` Initialize the hard fork as a standalone
  repository with its own history and treat upstream only as an import source.
- `2026-03-23 — DEC-FORK-004` Keep the patched `v2.0` bootstrap kernel as the
  sole live authority until each successor replacement hook is proven in
  scenarios and cuts over completely.
- `2026-03-23 — DEC-FORK-005` Port write-side dispatch enforcement from the
  later line into the successor core before broader runtime work; missing WHO
  enforcement on `Write|Edit` is the most important current control gap.
- `2026-03-23 — DEC-FORK-006` Treat the current Claude runtime contract as a
  compatibility surface that must be revalidated now; historical assumptions
  about `Task`, `Agent`, `SubagentStart`, and `SubagentStop` are not trusted
  until proven on the installed version.
- `2026-03-23 — DEC-FORK-007` The typed runtime becomes the sole authority for
  shared workflow state; flat files, breadcrumbs, and session-local marker files
  are not permitted as coordination mechanisms in the successor state machine.
- `2026-03-23 — DEC-FORK-008` No documentation may claim a control guarantee
  unless a scenario test proves it against the installed Claude version.
- `2026-03-23 — DEC-FORK-009` Reimplement the richer statusline HUD from the
  later line as a runtime-backed read model. Rendering belongs in
  `scripts/statusline.sh`; state derivation belongs in the successor runtime.
- `2026-03-23 — DEC-FORK-013` Trace artifacts remain evidence and recovery
  material only. No successor control decision may depend on a trace file,
  breadcrumb, or cache file being present.
- `2026-03-23 — DEC-FORK-010` Wave 1 Write|Edit WHO enforcement will be
  implemented by adding role checks to the existing `PreToolUse` (Write|Edit)
  hook chain rather than creating a new hook entrypoint, because the existing
  chain already fires on every Write|Edit call and adding a new file to that
  chain is lower-risk than restructuring the hook wiring in settings.json.
- `2026-03-23 — DEC-FORK-011` TKT-001 runtime payload capture will use
  instrumented wrapper scripts that log raw hook input JSON to a capture
  directory, not modifications to production hooks, so the capture is
  removable without merge risk.
- `2026-03-23 — DEC-FORK-012` The smoke suite (TKT-002) will be shell-based
  scenario tests in `tests/scenarios/` that invoke hook scripts with synthetic
  JSON payloads on stdin, validating output JSON for deny/allow/context
  decisions. This avoids requiring a live Claude runtime for CI.

## Active Initiatives

### INIT-002: Runtime MVP and Thin Hook Cutover

- **Status:** in-progress
- **Goal:** Replace bootstrap shared-state ownership with a real typed runtime
  and small hook entrypoints without reintroducing `claude-config-pro` style
  complexity.
- **Current truth:** [runtime/cli.py](runtime/cli.py),
  [scripts/planctl.py](scripts/planctl.py), and [hooks/lib/](hooks/lib) are
  scaffolds; the live kernel still owns proof, markers, worktree tracking, and
  related workflow state. The current statusline is also still a bootstrap cache
  reader rather than a runtime-backed projection.
- **Scope:** SQLite schema, `cc-policy` command implementation, runtime bridge,
  proof/marker/worktree/event domains, statusline projection,
  `pre-write.sh`, `pre-bash.sh`, `post-task.sh`, and hook-lib cutover.
- **Exit:** Shared workflow state flows through `cc-policy`; no hot-path hook
  entrypoint owns workflow state directly; successor hook entrypoints are
  readable, timed, and locally testable; statusline reads runtime-backed
  snapshots rather than separate cache authority; flat-file and breadcrumb
  coordination paths are removed.
- **Dependencies:** INIT-001
- **Implementation tickets:**
- `TKT-006` Implement the SQLite-backed runtime schema and real `cc-policy`
  commands for `proof_state`, `agent_markers`, `events`, and `worktrees`.
- `TKT-007` Replace bootstrap shared-state reads and writes with
  [hooks/lib/runtime-bridge.sh](hooks/lib/runtime-bridge.sh) calls and delete
  superseded flat-file and breadcrumb authorities after cutover.
- `TKT-008` Implement real
  [pre-write.sh](hooks/pre-write.sh) and [pre-bash.sh](hooks/pre-bash.sh) thin
  entrypoints over the hook libs in [hooks/lib/](hooks/lib).
- `TKT-009` Implement
  [post-task.sh](hooks/post-task.sh) dispatch emission and queue handling for
  `planner -> implementer -> tester -> guardian`.
- `TKT-011` Implement a runtime-backed statusline snapshot path and define the
  canonical fields exposed to `scripts/statusline.sh`.
- `TKT-012` Rebuild `scripts/statusline.sh` so the richer HUD derives its
  worktree, active-agent, initiative, proof, and workflow display from runtime
  snapshots with graceful fallback behavior.

#### Scaffold Assessment (2026-03-24)

Research findings from reading the current codebase:

- **`runtime/cli.py`** -- Argparse skeleton with all subcommand groups
  defined. Only `init`, `proof get`, and `proof set` have stub
  implementations (return hardcoded JSON). All other domains (`dispatch`,
  `marker`, `worktree`, `event`) return `{"status": "not_implemented"}`.
  The `statusline snapshot` subcommand is not yet wired.
- **`runtime/schemas.py`** -- One-line docstring. No schema definitions.
- **`runtime/core/config.py`** -- Has `default_db_path()` returning
  `~/.claude/state.db` with `CLAUDE_POLICY_DB` env override.
- **`runtime/core/db.py`** -- Has `connect()` with WAL pragma. No schema
  creation or migration logic.
- **`runtime/core/`** domain modules -- `proof.py`, `dispatch.py`,
  `markers.py`, `events.py`, `worktrees.py`, `policy.py` are all one-line
  docstring placeholders. No `statusline.py` exists yet.
- **`hooks/lib/core.sh`** -- Bootstrap loader that sources `log.sh`,
  `context-lib.sh`, and `runtime-bridge.sh`. Functional.
- **`hooks/lib/runtime-bridge.sh`** -- Single `cc_policy()` function that
  invokes `python3 "$runtime_root/cli.py" "$@"`. Functional but untested.
- **`hooks/lib/` policy files** -- `bash-policy.sh`, `write-policy.sh`,
  `dispatch-policy.sh`, `proof-policy.sh`, `worktree-policy.sh`,
  `plan-policy.sh`, `trace-lite.sh`, `diagnostics.sh` are all placeholder
  comments with no logic.
- **`hooks/context-lib.sh`** -- The current flat-file state hub. Contains
  all shared-state functions that TKT-007 must replace:
  `read_proof_status()` / `write_proof_status()` (`.proof-status-*` files),
  `current_active_agent_role()` (`.subagent-tracker`),
  `track_subagent_start()` / `track_subagent_stop()` (same tracker),
  `write_statusline_cache()` (`.statusline-cache` JSON),
  `get_subagent_status()`, `get_session_changes()` (`.session-changes-*`),
  `get_drift_data()` (`.plan-drift`), `append_audit()` (`.audit-log`).
- **`scripts/statusline.sh`** -- Reads `.statusline-cache` and
  `.todo-count` flat files. Pure ANSI renderer with segment logic.
- **`scripts/planctl.py`** -- Has `validate` (section-presence check) and
  `stamp` (mtime-based timestamp). No immutability or decision-log logic.
- **No `pre-write.sh`, `pre-bash.sh`, or `post-task.sh`** exist as hook
  entrypoints. The current wiring uses the per-guard hook files directly
  in `settings.json`.

#### Wave 2 Execution Detail

**Sequencing:** TKT-006 first (build the runtime core that everything
depends on), then TKT-007 (bridge shell callers to the new runtime and
delete flat-file authorities), then TKT-008 and TKT-009 in parallel (both
consume hook-libs that now call the runtime bridge; no shared file
boundaries), then TKT-011 (statusline snapshot depends on runtime being
live), then TKT-012 last (renderer can only be rebuilt after the snapshot
path exists).

**Critical path:** TKT-006 -> TKT-007 -> TKT-008 -> (done). Max width: 2
(TKT-008 and TKT-009 can run in parallel after TKT-007; TKT-011 can also
start after TKT-006 if TKT-007 is not blocking its specific domain).

**Parallelism note:** TKT-009 and TKT-011 both depend on TKT-006 for
runtime schema but do not depend on each other. TKT-008 depends on TKT-007
for the bridge functions it calls. TKT-012 depends on TKT-011 only.

```
Wave 2a: TKT-006  (foundation -- runtime schema + cc-policy commands)
Wave 2b: TKT-007  (bridge cutover + flat-file deletion)
Wave 2c: TKT-008 || TKT-009 || TKT-011  (parallel -- thin hooks, dispatch, statusline snapshot)
Wave 2d: TKT-012  (statusline renderer rebuild)
```

##### TKT-006: SQLite Schema and cc-policy Commands

- **Weight:** L
- **Gate:** review (user sees `cc-policy` commands working with real data)
- **Deps:** none (INIT-001 must be complete; it is)
- **Implementer scope:**
  - Implement `runtime/schemas.py` with all table definitions as constants:
    - `proof_state` table: `workflow TEXT PK`, `state TEXT NOT NULL`,
      `actor TEXT`, `updated_at INTEGER NOT NULL`.
    - `agent_markers` table: `id INTEGER PK`, `workflow TEXT NOT NULL`,
      `role TEXT NOT NULL`, `session TEXT NOT NULL`, `trace TEXT`,
      `created_at INTEGER NOT NULL`, `cleared_at INTEGER`.
    - `events` table: `id INTEGER PK`, `type TEXT NOT NULL`,
      `workflow TEXT NOT NULL`, `actor TEXT`, `payload TEXT`,
      `created_at INTEGER NOT NULL`.
    - `worktrees` table: `path TEXT PK`, `workflow TEXT NOT NULL`,
      `branch TEXT NOT NULL`, `session TEXT NOT NULL`,
      `registered_at INTEGER NOT NULL`, `last_heartbeat INTEGER NOT NULL`.
    - `dispatch_cycles` table: `id INTEGER PK`,
      `workflow TEXT NOT NULL`, `session TEXT NOT NULL`,
      `phase TEXT NOT NULL DEFAULT 'implementing'`,
      `created_at INTEGER NOT NULL`, `updated_at INTEGER NOT NULL`.
    - `dispatch_queue` table: `id INTEGER PK`, `type TEXT NOT NULL`,
      `workflow TEXT NOT NULL`, `cycle_id INTEGER`,
      `payload TEXT`, `claimed_at INTEGER`, `acked_at INTEGER`,
      `created_at INTEGER NOT NULL`.
  - Implement `runtime/core/db.py` additions:
    - `ensure_schema(conn)` that creates all tables if not present.
    - All writes in explicit transactions.
  - Implement the domain modules with real logic:
    - `runtime/core/proof.py`: `get(conn, workflow)`, `set(conn, workflow,
      state, actor)`, `reset_stale(conn, max_age_seconds)`.
    - `runtime/core/markers.py`: `create(conn, workflow, role, session,
      trace)`, `query(conn, workflow, role)`,
      `clear_stale(conn, max_age_seconds)`.
    - `runtime/core/events.py`: `emit(conn, type, workflow, actor,
      payload)`, `query(conn, type, workflow, limit)`.
    - `runtime/core/worktrees.py`: `register(conn, workflow, path, branch,
      session)`, `heartbeat(conn, path, session)`,
      `list(conn, workflow)`, `sweep(conn, max_age_seconds)`.
    - `runtime/core/dispatch.py`: `create_cycle(conn, workflow, session)`,
      `advance(conn, cycle_id, phase)`,
      `enqueue(conn, type, workflow, cycle_id, payload)`,
      `claim(conn, type, workflow)`, `ack(conn, queue_id)`.
  - Wire all domain modules into `runtime/cli.py` so every `cc-policy`
    subcommand calls the real domain function with a real SQLite connection.
    All output is JSON to stdout. Exit 0 on success, 1 on error.
  - Add unit tests in `tests/runtime/`:
    - `test_proof.py`: get/set/reset-stale round-trip.
    - `test_markers.py`: create/query/clear-stale.
    - `test_events.py`: emit/query ordering and limit.
    - `test_worktrees.py`: register/heartbeat/list/sweep.
    - `test_dispatch.py`: create-cycle/advance/enqueue/claim/ack lifecycle.
    - `test_cli.py`: subprocess invocations of `cc-policy` validating JSON
      output for each domain.
  - Each test must use an in-memory or tmp/ SQLite database, not the user's
    real state.db.
- **Tester scope:**
  - Run `python3 -m pytest tests/runtime/` and paste output.
  - Run manual `cc-policy` CLI invocations for each domain and verify JSON
    output matches expected schema.
  - Verify `cc-policy init` creates the schema (inspect tables with
    `sqlite3 state.db .tables`).
  - Verify WAL mode is active.
  - Verify error cases: get nonexistent workflow returns sensible JSON,
    invalid state values are rejected.
- **Acceptance criteria:**
  - All 6 runtime domain modules have real implementations.
  - `runtime/schemas.py` defines all table schemas.
  - `cc-policy init` creates the database and all tables.
  - Every `cc-policy` subcommand in the stable CLI interface
    (implementation_plan.md) works with real SQLite operations.
  - All unit tests pass.
  - JSON output format is consistent: `{"status": "ok", ...}` on success,
    `{"status": "error", "message": "..."}` on failure.
- **File boundaries:**
  - Modifies: `runtime/cli.py`, `runtime/schemas.py`, `runtime/core/db.py`,
    `runtime/core/proof.py`, `runtime/core/dispatch.py`,
    `runtime/core/markers.py`, `runtime/core/events.py`,
    `runtime/core/worktrees.py`
  - Creates: `runtime/core/statusline.py` (stub with snapshot signature
    only -- full implementation in TKT-011),
    `tests/runtime/test_proof.py`, `tests/runtime/test_markers.py`,
    `tests/runtime/test_events.py`, `tests/runtime/test_worktrees.py`,
    `tests/runtime/test_dispatch.py`, `tests/runtime/test_cli.py`,
    `tests/runtime/__init__.py`, `tests/__init__.py`
  - Does NOT modify: any hook, `settings.json`, `hooks/context-lib.sh`,
    `scripts/`, `agents/`, `docs/`

##### TKT-007: Runtime Bridge Cutover and Flat-File Deletion

- **Weight:** L
- **Gate:** approve (user must approve the flat-file removal)
- **Deps:** TKT-006 (runtime must exist and be tested)
- **Implementer scope:**
  - Implement `hooks/lib/runtime-bridge.sh` with shell wrapper functions
    that replace every flat-file state operation currently in
    `hooks/context-lib.sh`:
    - `rt_proof_get(workflow)` -- calls `cc-policy proof get --workflow`.
    - `rt_proof_set(workflow, state, actor)` -- calls `cc-policy proof set`.
    - `rt_proof_reset_stale()` -- calls `cc-policy proof reset-stale`.
    - `rt_marker_create(workflow, role, session, trace)` -- calls
      `cc-policy marker create`.
    - `rt_marker_query(workflow, role)` -- calls `cc-policy marker query`.
    - `rt_worktree_register(workflow, path, branch, session)` -- calls
      `cc-policy worktree register`.
    - `rt_worktree_heartbeat(path, session)` -- calls
      `cc-policy worktree heartbeat`.
    - `rt_worktree_list(workflow)` -- calls `cc-policy worktree list`.
    - `rt_event_emit(type, workflow, actor, payload)` -- calls
      `cc-policy event emit`.
    - Each wrapper must parse the JSON return and set shell variables for
      the caller (e.g., `RT_PROOF_STATE`, `RT_PROOF_ACTOR`).
    - Each wrapper must handle `cc-policy` failure gracefully: log the
      error and return a safe default rather than crashing the hook.
  - Replace callers in `hooks/context-lib.sh`:
    - `read_proof_status()` / `write_proof_status()` -> call
      `rt_proof_get` / `rt_proof_set`. Delete the `resolve_proof_file`,
      `read_proof_status_file`, `read_proof_timestamp_file`,
      `resolve_proof_file_for_command` functions.
    - `track_subagent_start()` / `track_subagent_stop()` -> call
      `rt_marker_create` / `rt_event_emit`. Delete the `.subagent-tracker`
      file-based functions.
    - `get_subagent_status()` -> call `rt_marker_query`. Delete the
      file-scanning implementation.
    - `write_statusline_cache()` -> delete entirely (replaced by TKT-011
      runtime snapshot). Callers will be updated to call
      `cc-policy statusline snapshot` instead.
    - `append_audit()` -> call `rt_event_emit` with type `audit`.
    - Keep `get_git_state()`, `get_plan_status()`, `is_source_file()`,
      `is_skippable_path()`, `canonical_session_id()`,
      `current_workflow_id()`, `file_mtime()`, `is_claude_meta_repo()`,
      `is_guardian_role()` -- these are pure local computations, not
      shared-state authorities.
    - `current_active_agent_role()` -> call `rt_marker_query` for active
      markers of the current workflow. Keep the `CLAUDE_AGENT_ROLE` env
      var fast-path.
  - Replace callers in consuming hooks:
    - `hooks/guard.sh` checks 8-10: replace `read_proof_status_file` /
      `resolve_proof_file_for_command` with `rt_proof_get`.
    - `hooks/session-init.sh`: replace `write_statusline_cache` call with
      `cc-policy statusline snapshot` (or a no-op if TKT-011 is not yet
      landed -- use a guard check). Replace `write_proof_status` with
      `rt_proof_set`.
    - `hooks/subagent-start.sh`: replace `track_subagent_start` with
      `rt_marker_create`.
  - Delete superseded flat-file authorities after cutover:
    - Remove code that creates/reads `.proof-status-*` files.
    - Remove code that creates/reads `.subagent-tracker` files.
    - Remove code that creates/reads `.statusline-cache` files.
    - Remove code that creates/reads `.audit-log` files.
    - Remove code that creates/reads `.agent-findings` files.
    - Keep `.session-changes-*` and `.plan-drift` reads as local-only
      analytics (they are not workflow authorities).
    - Keep `.test-status` reads -- this is a local gate, not a shared-state
      authority, and it is written by `hooks/test-runner.sh` which runs
      async. Migrating it to runtime is out of scope for INIT-002.
  - Add scenario tests in `tests/scenarios/`:
    - `test-runtime-bridge-proof.sh` -- set proof via bridge, get proof via
      bridge, verify round-trip.
    - `test-runtime-bridge-marker.sh` -- create marker via bridge, query
      via bridge.
    - `test-runtime-bridge-fallback.sh` -- kill cc-policy (invalid path),
      verify bridge functions return safe defaults.
    - `test-guard-runtime-proof.sh` -- run guard.sh commit check against
      runtime proof state instead of flat file.
- **Tester scope:**
  - Run all new and existing scenario tests.
  - Verify no hook reads `.proof-status-*`, `.subagent-tracker`,
    `.statusline-cache`, or `.audit-log` files.
  - Grep the hooks/ directory for any remaining flat-file state reads and
    confirm they are either local-only analytics or `.test-status`.
  - Verify `hooks/guard.sh` proof gate works against runtime state.
  - Verify `hooks/session-init.sh` initializes runtime state on session
    start.
  - Verify graceful degradation when `cc-policy` is unreachable.
- **Acceptance criteria:**
  - `hooks/lib/runtime-bridge.sh` has real wrapper functions for every
    runtime domain.
  - All shared-state reads/writes in hooks go through the bridge.
  - Flat-file authorities (`.proof-status-*`, `.subagent-tracker`,
    `.statusline-cache`, `.audit-log`, `.agent-findings`) are no longer
    created or read by any hook.
  - All scenario tests pass (new and pre-existing).
  - `hooks/context-lib.sh` retains only local-computation functions.
  - No dual-authority paths exist: a function either uses the runtime or
    does not exist.
- **File boundaries:**
  - Modifies: `hooks/lib/runtime-bridge.sh`, `hooks/context-lib.sh`,
    `hooks/guard.sh`, `hooks/session-init.sh`, `hooks/subagent-start.sh`
  - Creates: `tests/scenarios/test-runtime-bridge-*.sh`,
    `tests/scenarios/test-guard-runtime-proof.sh`
  - Does NOT modify: `runtime/` (already implemented in TKT-006),
    `settings.json`, `agents/`, `docs/`

##### TKT-008: Thin Hook Entrypoints (pre-write.sh, pre-bash.sh)

- **Weight:** M
- **Gate:** approve (user must approve the settings.json rewiring)
- **Deps:** TKT-007 (bridge must be live so policy libs can call it)
- **Implementer scope:**
  - Implement `hooks/pre-write.sh` as a thin entrypoint that:
    1. Sources `hooks/lib/core.sh` (which chains to context-lib, bridge).
    2. Reads hook input JSON.
    3. Calls `hooks/lib/write-policy.sh` functions in order:
       - Branch protection (current `branch-guard.sh` logic).
       - WHO enforcement for source files (current `write-guard.sh` logic).
       - Governance markdown enforcement (current `plan-guard.sh` logic).
       - Plan existence gate (current `plan-check.sh` logic).
    4. Returns the first deny encountered, or exits 0.
    5. Target: under 60 lines for the entrypoint itself.
  - Implement `hooks/lib/write-policy.sh` with the decomposed functions:
    - `wp_branch_guard(file_path, project_root)` -- from branch-guard.sh.
    - `wp_who_guard(file_path, role)` -- from write-guard.sh.
    - `wp_governance_guard(file_path, role)` -- from plan-guard.sh.
    - `wp_plan_exists(project_root)` -- from plan-check.sh.
  - Implement `hooks/pre-bash.sh` as a thin entrypoint that:
    1. Sources `hooks/lib/core.sh`.
    2. Reads hook input JSON.
    3. Calls `hooks/lib/bash-policy.sh` functions in order:
       - /tmp safety check.
       - CWD/worktree safety check.
       - WHO enforcement for git operations.
       - Main-is-sacred check for commits.
       - Force push and destructive git checks.
       - Worktree removal safety.
       - Test status gate for commit/merge.
       - Proof gate for commit/merge.
    4. Returns the first deny encountered, or exits 0.
    5. Target: under 60 lines for the entrypoint itself.
  - Implement `hooks/lib/bash-policy.sh` with decomposed functions:
    - `bp_tmp_safety(command)` -- from guard.sh check 1.
    - `bp_cwd_safety(command)` -- from guard.sh check 2.
    - `bp_git_who(command, role)` -- from guard.sh check 3.
    - `bp_main_sacred(command, target_dir)` -- from guard.sh check 4.
    - `bp_force_push(command)` -- from guard.sh check 5.
    - `bp_destructive_git(command)` -- from guard.sh check 6.
    - `bp_worktree_remove(command, target_dir)` -- from guard.sh check 7.
    - `bp_test_gate(command, project_root)` -- from guard.sh checks 8-9.
    - `bp_proof_gate(command, project_root)` -- from guard.sh check 10.
  - Update `settings.json`:
    - Replace the PreToolUse Write|Edit array (currently 7 hooks:
      test-gate, mock-gate, branch-guard, write-guard, plan-guard,
      doc-gate, plan-check) with a single `pre-write.sh` entry.
    - Replace the PreToolUse Bash array (currently guard.sh, auto-review)
      with `pre-bash.sh` (auto-review moves to a PostToolUse or is called
      from within pre-bash if still needed).
  - Add scenario tests:
    - `test-pre-write-branch-deny.sh` -- source write on main via
      pre-write.sh, expects deny.
    - `test-pre-write-who-deny.sh` -- orchestrator source write via
      pre-write.sh, expects deny.
    - `test-pre-write-allow.sh` -- implementer source write on non-main
      via pre-write.sh, expects allow.
    - `test-pre-bash-git-who.sh` -- non-guardian git commit via
      pre-bash.sh, expects deny.
    - `test-pre-bash-tmp-deny.sh` -- /tmp write via pre-bash.sh, expects
      deny.
  - Retain the old hook files (branch-guard.sh, write-guard.sh, etc.)
    but mark them as superseded with a comment header. They will be
    deleted after the test suite confirms the new entrypoints are
    equivalent.
- **Tester scope:**
  - Run all new and existing scenario tests against the new entrypoints.
  - Verify `pre-write.sh` produces identical deny/allow decisions as the
    previous 7-hook chain for all existing test cases.
  - Verify `pre-bash.sh` produces identical deny/allow decisions as the
    previous guard.sh for all existing test cases.
  - Verify `settings.json` has exactly one hook per PreToolUse matcher.
  - Count lines in each entrypoint: must be under 60.
- **Acceptance criteria:**
  - `hooks/pre-write.sh` exists and handles all write-side policy.
  - `hooks/pre-bash.sh` exists and handles all bash-side policy.
  - `hooks/lib/write-policy.sh` has 4+ decomposed policy functions.
  - `hooks/lib/bash-policy.sh` has 9+ decomposed policy functions.
  - `settings.json` PreToolUse arrays are simplified.
  - All scenario tests pass (new and pre-existing).
  - Entrypoints are each under 60 lines.
- **File boundaries:**
  - Creates: `hooks/pre-write.sh`, `hooks/pre-bash.sh`
  - Modifies: `hooks/lib/write-policy.sh`, `hooks/lib/bash-policy.sh`,
    `settings.json`
  - Creates: `tests/scenarios/test-pre-write-*.sh`,
    `tests/scenarios/test-pre-bash-*.sh`
  - Does NOT modify: `runtime/`, `agents/`, `docs/`

##### TKT-009: post-task.sh Dispatch Emission

- **Weight:** M
- **Gate:** review (user sees dispatch queue entries after agent completion)
- **Deps:** TKT-006 (dispatch domain must exist in runtime)
- **Implementer scope:**
  - Implement `hooks/post-task.sh` as a PostToolUse or Stop/SubagentStop
    hook that:
    1. Sources `hooks/lib/core.sh`.
    2. Detects the completing agent role from hook input or
       `current_active_agent_role()`.
    3. Determines the next dispatch step based on the lifecycle:
       - Planner completes -> enqueue `plan_to_impl`.
       - Implementer completes -> enqueue `impl_to_test`.
       - Tester completes -> enqueue `test_to_guard`.
       - Guardian completes -> enqueue `guard_to_impl` (if cycle
         continues) or advance cycle to `completed`.
    4. Calls `cc-policy dispatch enqueue` with the appropriate type,
       workflow, and cycle.
    5. Calls `cc-policy event emit` to record the dispatch event.
    6. Target: under 80 lines.
  - Implement `hooks/lib/dispatch-policy.sh` with:
    - `dp_next_phase(current_role)` -- returns the next dispatch type.
    - `dp_should_continue(cycle_phase, guardian_result)` -- determines if
      the cycle loops back or completes.
  - Wire `post-task.sh` into `settings.json` SubagentStop hooks. It fires
    after the role-specific `check-*.sh` hooks.
  - Add scenario tests:
    - `test-dispatch-plan-to-impl.sh` -- simulate planner stop, verify
      `plan_to_impl` queue entry exists.
    - `test-dispatch-impl-to-test.sh` -- simulate implementer stop, verify
      `impl_to_test` queue entry exists.
    - `test-dispatch-cycle-complete.sh` -- simulate guardian stop with
      successful merge, verify cycle advances to completed.
- **Tester scope:**
  - Run all new scenario tests.
  - Verify `cc-policy dispatch claim` can retrieve enqueued items.
  - Verify event log records the dispatch transitions.
  - Verify no dispatch emission when agent type is Bash or Explore.
- **Acceptance criteria:**
  - `hooks/post-task.sh` exists and is wired in settings.json.
  - Dispatch queue is populated after each agent role completes.
  - `hooks/lib/dispatch-policy.sh` has phase-transition logic.
  - Event log records dispatch events.
  - All scenario tests pass.
- **File boundaries:**
  - Creates: `hooks/post-task.sh`
  - Modifies: `hooks/lib/dispatch-policy.sh`, `settings.json`
  - Creates: `tests/scenarios/test-dispatch-*.sh`
  - Does NOT modify: `runtime/`, existing hooks (except settings.json
    wiring), `agents/`, `docs/`

##### TKT-011: Runtime-Backed Statusline Snapshot

- **Weight:** M
- **Gate:** review (user sees snapshot JSON output)
- **Deps:** TKT-006 (runtime state must exist to project from)
- **Implementer scope:**
  - Implement `runtime/core/statusline.py` with:
    - `snapshot(conn, workflow, session, parent_pid)` -> returns a dict
      with all statusline fields derived from runtime state:
      - `proof_state`: from `proof.get()`.
      - `active_agents`: from `markers.query()` for active markers.
      - `agent_types`: comma-separated active agent types.
      - `worktree_count`: from `worktrees.list()`.
      - `dispatch_phase`: from latest `dispatch_cycles` row.
      - `recent_events`: count of events in last 60 seconds.
      - `initiative`: parsed from MASTER_PLAN.md active initiative name
        (passed as parameter, not parsed by runtime).
      - `plan_status`: passed as parameter from hook caller.
      - `dirty_count`, `branch`: passed as parameters from hook caller
        (local git state, not runtime state).
      - `timestamp`: current epoch.
    - The snapshot function must never fail -- return safe defaults for any
      missing data.
  - Wire `cc-policy statusline snapshot` in `runtime/cli.py`:
    - Accepts `--workflow`, `--session`, `--parent-pid`.
    - Reads optional `--plan-status`, `--dirty`, `--branch`,
      `--initiative` parameters (passed from the hook caller who has local
      git context).
    - Outputs the snapshot as JSON.
  - Add unit tests in `tests/runtime/test_statusline.py`:
    - Snapshot with all data present.
    - Snapshot with empty database (graceful defaults).
    - Snapshot with partial data (some domains populated, others not).
- **Tester scope:**
  - Run `cc-policy statusline snapshot` with a populated database and
    verify all expected fields are present.
  - Run with empty database and verify graceful degradation.
  - Verify output is valid JSON parseable by `jq`.
- **Acceptance criteria:**
  - `runtime/core/statusline.py` exists with `snapshot()` function.
  - `cc-policy statusline snapshot` produces valid JSON.
  - Graceful degradation when runtime state is empty or partial.
  - Unit tests pass.
- **File boundaries:**
  - Creates: `runtime/core/statusline.py`
  - Modifies: `runtime/cli.py` (wire statusline subcommand)
  - Creates: `tests/runtime/test_statusline.py`
  - Does NOT modify: `scripts/statusline.sh` (that is TKT-012),
    any hook, `settings.json`, `agents/`, `docs/`

##### TKT-012: Statusline Renderer Rebuild

- **Weight:** M
- **Gate:** review (user sees the rendered statusline)
- **Deps:** TKT-011 (snapshot path must exist)
- **Implementer scope:**
  - Rewrite `scripts/statusline.sh` to:
    1. Read Claude stdin JSON (model, workspace, version) as before.
    2. Compute local-only fields: workspace name, timestamp.
    3. Call `cc-policy statusline snapshot` with `--workflow`,
       `--dirty`, `--branch`, `--initiative`, `--plan-status` parameters
       derived from the stdin JSON and a quick local git check.
    4. Parse the snapshot JSON with `jq` and render each segment.
    5. Fall back to safe defaults if `cc-policy` fails or returns
       incomplete data -- the statusline must never block the prompt.
  - Render segments (same visual structure as current, but sourced from
    runtime):
    - Model (dim), workspace (bold cyan), timestamp (yellow).
    - Dirty count (red, only if > 0) -- from snapshot or local fallback.
    - Worktree count (cyan, only if > 0) -- from snapshot.
    - Plan phase (blue or dim) -- from snapshot.
    - Proof state (green if verified, yellow if pending, dim if idle) --
      from snapshot.
    - Test status (green/red/dim) -- from local `.test-status` file
      (this is intentionally still local per TKT-007 scope).
    - Active agents (yellow, only if > 0) -- from snapshot.
    - Initiative name (blue, only if present) -- from snapshot.
    - Todos (magenta, only if > 0) -- from local `.todo-count`.
    - Version (green).
  - Delete the `.statusline-cache` reading logic entirely. The renderer
    must not read `.statusline-cache` after this change.
  - Add a fallback path: if `cc-policy` is not available or returns an
    error, render a minimal statusline (model, workspace, timestamp,
    version) without any runtime-derived segments.
  - Target: under 100 lines.
- **Tester scope:**
  - Run `scripts/statusline.sh` with synthetic stdin and a populated
    runtime database. Verify all segments render correctly.
  - Run with `cc-policy` unavailable (invalid path). Verify fallback
    renders without error.
  - Verify no references to `.statusline-cache` remain in the script.
  - Verify the script exits successfully and produces valid ANSI output
    in both cases.
- **Acceptance criteria:**
  - `scripts/statusline.sh` reads from `cc-policy statusline snapshot`.
  - No reference to `.statusline-cache` in the script.
  - Graceful fallback when runtime is unavailable.
  - New segments: proof state, initiative name.
  - All existing visual segments preserved.
  - Under 100 lines.
- **File boundaries:**
  - Modifies: `scripts/statusline.sh`
  - Does NOT modify: `runtime/` (reads via CLI), any hook,
    `settings.json`, `agents/`, `docs/`

#### Wave 2 State Authority Map

| State Domain | Current Authority (post-INIT-001) | Wave 2 Target | Ticket |
|---|---|---|---|
| Proof-of-work lifecycle | `.proof-status-*` via `context-lib.sh` | `proof_state` table via `cc-policy proof` | TKT-006, TKT-007 |
| Agent role tracking | `.subagent-tracker` via `context-lib.sh` | `agent_markers` table via `cc-policy marker` | TKT-006, TKT-007 |
| Audit events | `.audit-log` via `context-lib.sh` `append_audit()` | `events` table via `cc-policy event emit` | TKT-006, TKT-007 |
| Worktree registry | `git worktree list` (computed) | `worktrees` table via `cc-policy worktree` | TKT-006, TKT-007 |
| Dispatch queue | **NONE** (lifecycle is social/prompt-driven) | `dispatch_queue` + `dispatch_cycles` tables | TKT-006, TKT-009 |
| Statusline data | `.statusline-cache` via `context-lib.sh` | `cc-policy statusline snapshot` (runtime projection) | TKT-011, TKT-012 |
| Agent findings | `.agent-findings` file | `events` table (type=finding) | TKT-007 |
| Git WHO (commit/merge/push) | `hooks/guard.sh` via `context-lib.sh` | `hooks/pre-bash.sh` via `hooks/lib/bash-policy.sh` | TKT-008 |
| Write\|Edit WHO (source) | `hooks/write-guard.sh` via `context-lib.sh` | `hooks/pre-write.sh` via `hooks/lib/write-policy.sh` | TKT-008 |
| Governance markdown | `hooks/plan-guard.sh` via `context-lib.sh` | `hooks/pre-write.sh` via `hooks/lib/write-policy.sh` | TKT-008 |
| Main branch protection | `hooks/branch-guard.sh` | `hooks/pre-write.sh` via `hooks/lib/write-policy.sh` | TKT-008 |
| Plan existence gate | `hooks/plan-check.sh` | `hooks/pre-write.sh` via `hooks/lib/write-policy.sh` | TKT-008 |
| Test status | `.test-status` via `hooks/test-runner.sh` | No change (stays local; async writer) | -- |

#### Flat-File Deletion Schedule

Files deleted by TKT-007 after runtime cutover:

| File Pattern | Current Creator | Replaced By |
|---|---|---|
| `.proof-status-*` | `context-lib.sh` `write_proof_status()` | `cc-policy proof set` |
| `.subagent-tracker` | `context-lib.sh` `track_subagent_start()` | `cc-policy marker create` |
| `.statusline-cache` | `context-lib.sh` `write_statusline_cache()` | `cc-policy statusline snapshot` |
| `.audit-log` | `context-lib.sh` `append_audit()` | `cc-policy event emit` |
| `.agent-findings` | `session-init.sh` (read), various (write) | `cc-policy event emit` (type=finding) |

Files explicitly NOT deleted (local-only, not shared-state authorities):

| File Pattern | Reason Kept |
|---|---|
| `.test-status` | Async local gate written by `test-runner.sh`; not a shared-state authority |
| `.session-changes-*` | Local session analytics; not a workflow authority |
| `.plan-drift` | Local audit artifact; not a workflow authority |
| `.todo-count` | Local HUD cache; not a workflow authority |
| `.preserved-context` | One-time compaction recovery; not a workflow authority |

#### Wave 2 Known Risks

1. **cc-policy CLI startup latency.** Every bridge call spawns a Python
   process. If `cc-policy` takes >200ms to start, hook chains will feel
   slow. Mitigation: measure latency in TKT-006 tester scope. If too slow,
   TKT-006 must add a `--fast` mode or batch interface before TKT-007
   proceeds.
2. **Bridge fallback masks real failures.** If `cc-policy` crashes and the
   bridge returns safe defaults, the system silently degrades. Runtime
   errors must be logged even when the hook continues.
3. **settings.json rewiring in TKT-008 is a breaking change.** The current
   7-hook Write|Edit chain becomes a single `pre-write.sh`. If any hook in
   the old chain has behavior not captured in `write-policy.sh`, it will be
   silently lost. Mitigation: TKT-008 tester must run every existing
   scenario test against the new entrypoint and verify identical decisions.
4. **Dispatch queue (TKT-009) is additive, not replacing.** The current
   lifecycle is entirely prompt-driven with no queue. TKT-009 adds the
   queue but does not yet enforce it as the sole dispatch path. Enforcement
   moves to INIT-003 after the queue proves stable.
5. **SQLite in ~/.claude/state.db is per-user, not per-project.** Multiple
   projects share the same database. The `workflow` column in every table
   provides isolation, but a corrupt database affects all projects.
   Mitigation: WAL mode, explicit transactions, and runtime error handling
   must be solid in TKT-006.

### INIT-003: Plan Discipline and Successor Validation

- **Status:** planned
- **Goal:** Finish the successor kernel so its plan discipline, verification, and
  release claims are mechanically trustworthy.
- **Current truth:** [scripts/planctl.py](scripts/planctl.py) only validates
  section presence and stamps a placeholder timestamp; `MASTER_PLAN.md`
  discipline is still largely social rather than enforced.
- **Scope:** plan immutability, decision-log closure rules, trace-lite, scenario
  acceptance suite, statusline render/round-trip validation, shadow-mode
  sidecars, and readiness for daemon promotion.
- **Exit:** March 7-style plan replacement is mechanically blocked, the kernel
  acceptance suite passes twice consecutively, and sidecars remain read-only
  until the kernel is stable.
- **Dependencies:** INIT-001, INIT-002
- **Implementation tickets:**
- `TKT-010` Expand [scripts/planctl.py](scripts/planctl.py) into real section
  immutability, `Last updated`, append-only decision-log, and initiative
  compression enforcement.
- **Post-ticket continuation:** Add trace-lite manifests and summaries, complete
  the full acceptance suite in `tests/scenarios/`, including runtime-backed
  statusline render and round-trip checks; reintroduce search and observatory in
  shadow mode only; then promote `cc-policy` to daemon mode after CLI mode
  proves stable.

## Completed Initiatives

### INIT-001: Compatibility and Control Closure (completed 2026-03-24)

- **Goal:** Make the bootstrap truthful, safe, and aligned with the installed
  Claude runtime before deeper successor work.
- **Delivered:**
  - `TKT-001`: Runtime payload capture in `tests/scenarios/capture/` and
    `PAYLOAD_CONTRACT.md` documenting actual hook JSON schemas for all event
    types on the installed Claude runtime.
  - `TKT-002`: 17-test smoke suite (8 baseline + 5 write-guard + 4
    plan-guard) in `tests/scenarios/` with `test-runner.sh` harness. All
    tests pass against real hook scripts with synthetic JSON payloads.
  - `TKT-003`: `hooks/write-guard.sh` enforcing Write|Edit WHO --
    implementer-only source writes, orchestrator/planner/tester/guardian
    denied. Wired into `settings.json` PreToolUse Write|Edit chain.
  - `TKT-004`: `hooks/plan-guard.sh` enforcing governance markdown authority
    -- planner-only writes to MASTER_PLAN.md, CLAUDE.md, agents/*.md,
    docs/*.md. Migration override via `CLAUDE_PLAN_MIGRATION=1`.
  - `TKT-005`: `docs/DISPATCH.md`, `docs/ARCHITECTURE.md`,
    `docs/PLAN_DISCIPLINE.md` corrected to match actual enforcement surface.
    No doc claims protection that the hook chain cannot deliver.
- **Exit criteria met:** Orchestrator cannot write governed source or
  governance markdown directly. Agent lifecycle is scenario-tested. Dispatch
  docs match real behavior.

### Pre-INIT-001 (repository bootstrap)

- Standalone hard-fork repository bootstrapped from the patched `v2.0` kernel.
- Canonical prompt set drafted in `CLAUDE.md` and `agents/`.
- Successor implementation spec written in `implementation_plan.md`.
- Successor runtime, hook-lib, sidecar, and docs directories scaffolded so work
  can land against stable paths.

## Parked Issues

- Search and observatory sidecars remain parked from hot-path authority until
  the kernel acceptance suite is green twice consecutively.
- Daemon promotion and multi-client coordination stay parked until CLI mode is a
  proven stable interface.
- Upstream synchronization remains manual and selective; no merge/rebase flow
  from upstream is allowed into this mainline.
- Plugin ecosystems, auxiliary agent ecosystems, and non-core experiments remain
  out of scope until the kernel and runtime authority are stable.
