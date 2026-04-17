# ClauDEX Supervisor Handoff

This file defines the project-specific Codex supervisor kickoff for the
`claude-ctrl-hardFork` overnight bridge session.

## Purpose

The Codex supervisor is the decider for the live ClauDEX bridge loop.

- Claude Code is the bounded worker.
- Codex is the reviewer / dispatcher.
- The bridge remains active until there is no active run, the run is complete,
  or a real user decision boundary is reached.

The supervisor must not invent a new project or a second control plane. It
stays on the active ClauDEX cutover slice only.

## Open Soak Issues

- Soak Run 2026-04-14 (cutover bundle, worktree claudex-cutover-soak)
  1. Smoke keyword filter matched zero tests
     - Repro: `pytest -q tests/runtime/test_braid_v2.py -k 'smoke or quick or trace_export or seat_create'` → 0 passed, 5 deselected.
     - Impact: false green; smoke gate ineffective.
     - Suggested fix: drop the `-k` filter; run full file (5 tests, 0.22s) or validate filters with `--collect-only`.
     - Blocking? No.
  2. Watchdog pending-review / recovery artifacts missing
     - Repro: Soak run to `waiting_for_codex`; `.claude/claudex/pending-review.json` and relay-recovery artifacts not written; 5 watchdog tests fail.
     - Impact: Violates minimum bridge viability in this handoff; supervisor can miss state.
     - Current verification: `pytest -q tests/runtime/test_claudex_watchdog.py --maxfail=8` now passes locally (24 passed, 29.66s), so this is not currently reproduced in the soak worktree.
     - Suggested fix if it recurs: inspect `CLAUDEX_STATE_DIR`/lane mismatch first, then restore writing of `pending-review.json` and recovery state on waiting_for_codex/reconcile paths.
     - Blocking? No, unless reproduced again in the active lane.
  3. PID-reuse flake in watchdog dedupe test
     - Repro: watchdog test expects killed PID ≠ running PID; OS reused PID; assertion fails.
     - Impact: Flaky test only.
     - Suggested fix: change assertion to identity-based (e.g., start time) or tolerate PID reuse.
     - Blocking? No.
  4. dispatch-debug fixture absent in fresh worktree
     - Repro: `test_dispatch_debug_file_exists_and_has_subagent_start_events` fails because `tests/runtime/dispatch-debug.jsonl` not present in new worktree.
     - Impact: Test fails on clean clone unless seeded.
     - Current fix: seeded `tests/fixtures/dispatch-debug.seed.jsonl`; tests use live `runtime/dispatch-debug.jsonl` when present and deterministic seed truth otherwise.
     - Blocking? No.

### Soak Run 2026-04-14 (instruction 1776218048935-0001-0uqp4e)

- **Smoke keyword filter matches zero tests** (non-blocking, prompt fix)
  - Repro: `pytest -q tests/runtime/test_braid_v2.py -k 'smoke or quick or trace_export or seat_create'` → `5 deselected in 0.07s`.
  - Actual test names in `test_braid_v2.py`: `test_bundle_create_and_tree`, `test_adopt_tmux_worker_creates_runtime_rows`, `test_spawn_tmux_supervised_bundle_creates_child_bundle_threads_and_sessions`, `test_observe_tmux_seat_opens_and_clears_gates`, `test_controller_sweep_times_out_attempts_and_opens_findings`.
  - Impact: Supervisor's fast-smoke step no-ops silently and appears green. A future regression would pass this filter.
  - Suggested prompt fix: drop the `-k` filter for this file (only 5 tests, all fast) or use `-k 'bundle or adopt_tmux or spawn_tmux or observe_tmux or controller_sweep'`. Recommend the former (run all 5; whole file ran in 0.22s).
  - Blocking: no.

- **Watchdog pending-review / recovery artifacts not written in 5 tests** (blocking quality, needs investigation)
  - Repro: `pytest -q tests/runtime/test_claudex_watchdog.py`, failures:
    - `test_watchdog_nudges_lodged_relay_prompt_before_dispatch_recovery` — `.claude/claudex/relay-prompt-recovery.state.json` missing.
    - `TestPendingReviewPersistence::test_waiting_for_codex_writes_pending_review_with_full_payload` — `pending-review.json` not written on `waiting_for_codex`.
    - `TestPendingReviewPersistence::test_completed_inflight_with_response_is_reconciled_to_review_handoff` — no pending-review artifact after reconcile.
    - `TestPendingReviewClearance::test_non_waiting_state_clears_pending_review_artifact` — setup tick failed to create the artifact.
    - `TestPendingReviewClearance::test_user_driving_is_handed_back_and_handoff_still_persists` — handoff artifact missing.
  - Impact: The very artifacts `SUPERVISOR_HANDOFF.md` lists under "Minimum bridge viability" (pending-review.json detection/regeneration) have regressed at the unit level. If the watchdog no longer writes these, the supervisor cannot rely on them either.
  - Current verification: a fresh local rerun in this worktree passed: `pytest -q tests/runtime/test_claudex_watchdog.py --maxfail=8` → **24 passed**, 29.66s.
  - Revised assessment: not currently reproduced in the soak worktree; if it recurs, first check whether the watchdog and tests are using different `CLAUDEX_STATE_DIR`/lane roots before changing writer logic.
  - Blocking: no while the targeted watchdog suite remains green; yes if reproduced in the active lane.

- **PID-reuse flake in watchdog dedupe test** (non-blocking, low-priority test-only fix)
  - Repro: `pytest -q tests/runtime/test_claudex_watchdog.py::test_watchdog_dedupes_auto_submit_when_pidfile_and_pgrep_disagree` intermittently fails: `assert 64078 not in {64078, 64085}` — macOS reused `proc_a.pid` for the replacement process.
  - Impact: Flaky CI / noisy soak runs. Not a runtime defect.
  - Suggested fix: after killing `proc_a`, loop spawning ephemeral throwaway processes until a fresh PID is obtained; or assert on a process-identity marker (argv/env fingerprint) rather than PID equality.
  - Blocking: no.

- **`test_dispatch_debug_file_exists_and_has_subagent_start_events` requires live dispatches** (non-blocking, test hygiene)
  - Repro: `pytest tests/runtime/test_subagent_start_payload_shape.py::TestContractCarrierGap::test_dispatch_debug_file_exists_and_has_subagent_start_events` fails in a fresh worktree because `runtime/dispatch-debug.jsonl` does not exist until at least one Agent dispatch has happened in that worktree.
  - Impact: Soak runs in throwaway worktrees fail this check even when the cutover is healthy; the failure is environmental, not functional.
  - Fix: seeded `tests/fixtures/dispatch-debug.seed.jsonl`; the test now prefers live `runtime/dispatch-debug.jsonl` and falls back to deterministic captured truth in fresh worktrees.
  - Blocking: no.


- **Auto-submit process pressure / orphan growth** (fixed, operationally blocking while active)
  - Repro: live soak had many orphaned `claudex-auto-submit.sh` processes spawned by active watchdogs after parent Claude sessions died.
  - Root cause: `claudex-auto-submit.sh` and `claudex-watchdog.sh` trapped `TERM`/`INT` with cleanup functions that returned instead of exiting, effectively swallowing SIGTERM; watchdog also spawned auto-submit without forwarding `CLAUDEX_STATE_DIR`, allowing lane/pid-file drift.
  - Fix: signal traps now clean up and exit with signal-like status; watchdog passes `CLAUDEX_STATE_DIR="$PID_DIR"` when spawning auto-submit; watchdog tests force isolated `CLAUDEX_STATE_DIR` so live lanes are not polluted by fake test artifacts.
  - Verification: `pytest -q tests/runtime/test_claudex_auto_submit.py tests/runtime/test_claudex_watchdog.py --maxfail=8` → **36 passed**, 14.80s; live bridge status shows one active auto-submit pid and one active watchdog pid for the soak lane.
  - Blocking: no after fix and orphan cleanup.

- **State-record drift: handoff docs said "checkpoint pending" after checkpoint landed** (fixed, documentation-only)
  - Repro: a stale-state grep over `ClauDEX/CURRENT_STATE.md` and `ClauDEX/SUPERVISOR_HANDOFF.md` returned phrases asserting the bundle was still waiting for a checkpoint even though the checkpoint had already landed as `6b8cc5c` and the follow-up process-control fix landed as `d8fdf96`, both pushed to `origin/feat/claudex-cutover`.
  - Impact: supervisor and future implementers would dispatch another checkpoint-stewardship slice against a lane that has no checkpoint debt; directly contradicts installed truth.
  - Fix: `ClauDEX/CURRENT_STATE.md` Git Placement + Checkpoint Readiness sections rewritten to reflect `claudesox-local` tracking `origin/feat/claudex-cutover` at HEAD `d8fdf96` with `6b8cc5c` as the cutover-bundle commit; `ClauDEX/SUPERVISOR_HANDOFF.md` next-action text rewritten to say the checkpoint is complete and the next action is cutover-plan continuation or lane maintenance.
  - Blocking: no.


- **Codex supervisor model-upgrade prompt / MCP root drift** (fixed, lane maintenance)
  - Repro: launching `./scripts/claudex-codex-launch.sh` repeatedly showed the GPT-5.4 upgrade prompt; selecting "Use existing model" could crash the pane when the bridge MCP resolved Braid dependencies from `.b2r` instead of the active `/tmp/claudex-b2r-v2` root.
  - Impact: supervisor pane disappeared or stalled before it could call bridge tools; the worker could keep running but Codex supervision was not stable.
  - Fix: `scripts/claudex-codex-launch.sh` now writes lane-local config with `model = "gpt-5.3-codex"` and `model_reasoning_effort = "xhigh"`, writes the repo-global `.claude/claudex/braid-root` hint consumed by the MCP wrapper, and records the current Codex version as dismissed in lane-local `version.json`.
  - Verification: supervisor pane `%955` is running as `gpt-5.3-codex xhigh` and successfully calls `claude_bridge.get_status()` against active run `1776220007-97469-21be1f02`.
  - Blocking: no after relaunch; commit this follow-up bundle so restarts inherit the fix.

### Soak Run Test Counts

The first soak counts below are preserved for traceability; final local verification is the current gate.

- `tests/runtime/test_claudex_auto_submit.py tests/runtime/test_claudex_watchdog.py --maxfail=8`: **36 passed**, 14.80s.

- `tests/runtime/test_braid_v2.py` (full file, keyword filter matched nothing): **5 passed**, 0.22s first pass; **5 passed**, 0.33s final pass.
- `tests/runtime/test_claudex_watchdog.py --maxfail=8` fresh verification: **24 passed**, 29.66s first pass; **24 passed**, 28.27s final pass; **24 passed**, 26.55s under live lane env after isolation fix.
- `tests/runtime -k '(claudex or braid_v2 or dispatch)'` first-failure run: **33 passed, 1 failed** (watchdog PID dedupe) before `-x` stop, 3792 deselected, 20.44s.

### Suggested Prompt / Hook Improvements

- **Supervisor smoke prompt**: fixed in `.codex/prompts/claudex_supervisor.txt`; braid v2 smoke now runs `pytest -q tests/runtime/test_braid_v2.py` unfiltered.
- **Supervisor soak prompt**: fixed in `.codex/prompts/claudex_supervisor.txt`; any future `-k` smoke must be proven with `pytest --collect-only -q ... -k ...` before reporting green.
- **Hook/artifact contract**: keep `tests/runtime/test_claudex_watchdog.py` in the soak gate because `.claude/claudex/pending-review.json` and `.claude/claudex/relay-prompt-recovery.state.json` are canonical supervisor artifacts. If they fail again, treat state-dir/lane drift as the first suspect before adding a second artifact path.

### Follow-up verification 2026-04-14 (post-handoff edits)

- **Confirmed: watchdog failures are env-leak, not regression.** Running `pytest -q tests/runtime/test_claudex_watchdog.py --maxfail=8` with the supervisor's live env (`CLAUDEX_STATE_DIR=$PWD/.claude/claudex/b2r-v2-stable`, `BRAID_ROOT=/tmp/claudex-b2r-v2`) reproduced **8 failed, 1 passed in 9.76s** — the same 5 pending-review/recovery artifact failures plus the PID flake plus 2 `TestBridgeStatusSurface` cases. Unsetting both env vars and rerunning gave **24 passed in 36.75s**.
- **Net finding**: the watchdog test fixtures do not isolate from an externally-set `CLAUDEX_STATE_DIR`. When the soak shell exports the production lane, the fixtures write/read the production `.claude/claudex/pending-review.json` instead of the per-test tmpdir, and the assertions fail. This is test hygiene, not a watchdog writer regression.
- **Applied fix (test-only)**: `tests/runtime/test_claudex_watchdog.py` now explicitly passes the fixture `CLAUDEX_STATE_DIR` to watchdog/status/progress subprocesses, making the suite hermetic against supervisor env and removing false-positive lane pollution.
- **Combined clean-env verification**: `env -u CLAUDEX_STATE_DIR -u BRAID_ROOT pytest -q tests/runtime/test_braid_v2.py tests/runtime/test_claudex_watchdog.py tests/runtime/test_subagent_start_payload_shape.py` → **40 passed, 1 skipped in 35.35s**.
- No bounded Claude dispatch issued for this follow-up; the env isolation fix and auto-submit process fix are local worktree changes awaiting review/commit.

## Tonight's Priority Order

The bridge exists to support the cutover, not to become the night's main
project.

1. Keep Codex in charge of the live bridge session.
2. Do only the minimum bridge work required for reliable supervision.
3. As soon as the minimum supervision path is healthy, return to the ClauDEX
   cutover plan and continue the next unfinished cutover slice.

Minimum bridge viability means:

- the active run remains healthy
- the repo-local Codex `Stop` hook keeps the supervisor alive
- `wait_for_codex_review()` is sufficient to put Codex back into a blocking
  review state
- the progress monitor stays healthy
- stale or mismatched `pending-review.json` artifacts are detected and ignored
  or regenerated

Bridge transport is not the supervisor's main job once those conditions hold.
The watchdog owns relay nudges and automatic handback. Visible `__BRAID_RELAY__`
noise in Claude's pane is not, by itself, a reason to investigate transport.
When the progress monitor marks the current run as degraded, the watchdog may
invoke the repo-local supervisor restart path automatically; the monitor itself
remains read-only.
Longer term, this entire bridge stack is containment only. The target
architecture is the runtime-owned agent-session supervision fabric in
`ClauDEX/CUTOVER_PLAN.md`, where `tmux` and MCP are interchangeable transport
adapters rather than competing authorities.
If the active run is marked `dispatch_stalled`, that is not a supervisor wait
state. The watchdog owns the one authoritative recovery path through
`./scripts/claudex-dispatch-recover.sh`, and the repo-local Codex `Stop` hook
should allow the dedicated supervisor seat to stop normally instead of
re-arming into another idle loop.
The supervisor should monitor progress, review returned work, and steer the next
bounded cutover slice.

Once those conditions hold, bridge work is no longer the priority. The
supervisor must shift back to `ClauDEX/CUTOVER_PLAN.md`, especially:

- `## System Overview`
- `## Target Architecture`
- `## Execution Model`
- `## Phase Plan`

Do not continue bridge refinement unless a bridge defect is a direct blocker on
the active cutover slice.

Do not manually debug tmux pane state or pursue relay health checks just because
the bridge is queued or a relay sentinel echoed in the worker pane. Treat
transport diagnosis as an escalation-only path after the monitoring loop has
actually stopped advancing.

## Canonical Prompt Files

- Initial project-specific kickoff:
  - [`.codex/prompts/claudex_handoff.txt`](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.codex/prompts/claudex_handoff.txt)
- Steady-state loop reused by the Codex `Stop` hook:
  - [`.codex/prompts/claudex_supervisor.txt`](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.codex/prompts/claudex_supervisor.txt)

## Launch Command

From repo root:

```bash
./scripts/claudex-codex-launch.sh
```

That script launches Codex with the project-specific kickoff prompt. After the
first turn, the repo-local Codex `Stop` hook in
[`.codex/hooks/stop_supervisor.py`](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.codex/hooks/stop_supervisor.py)
keeps the same session alive by feeding the steady-state supervisor loop back
into Codex.

## Steady-State Behavior

The supervisor loop is:

1. Call `get_status()`.
2. If the bridge is inactive or the run is complete, stop.
3. If the bridge is `idle` with `queue_depth == 0`, no latest response, and no
   pending-review artifact, treat that as a fresh supervised run and dispatch
   the current restart slice from `## Current Restart Slice`.
4. If the bridge is `waiting_for_codex`, read
   `$CLAUDEX_STATE_DIR/pending-review.json`
   when present, then prefer `get_response()` as the normal review source,
   verify files/tests, and decide the next bounded instruction.
5. If the bridge is `queued` or `inflight`, call `wait_for_codex_review()` to
   return to a true blocking state until review is needed.
6. If the bridge is active but `$CLAUDEX_STATE_DIR/dispatch-stall.state.json`
   matches the active run, do not keep re-arming. Treat that as a transport
   failure already handed off to the watchdog recovery path.
7. Only stop for genuine user input, a genuine git/policy ambiguity, or an
   inactive / completed run.

The steady-state supervisor loop should not call `get_conversation()` or
`get_worker_observer()` unless the simpler path has already failed twice in a
row. Those tools are escalation-only for inconsistent bridge state, not part of
the normal review/steer cycle.

## Checkpoint Stewardship

Routine checkpoint work is not, by itself, a terminal approval boundary.
When a bounded slice is accepted and the next best-practice action is to
checkpoint coherent repo state, the supervisor should treat that as a
guardian-equivalent slice and keep the lane moving.

Default checkpoint behavior:

- create or reuse a dedicated feature branch when the current branch is not the
  intended custody branch for the accepted bundle
- stage only the coherent cutover bundle for that slice
- rerun the focused verification needed to justify the checkpoint
- create a descriptive checkpoint commit
- push to the existing private upstream when the push is straightforward and
  non-destructive

Escalate to the user only when one of these is true:

- the checkpoint would require a force-push, history rewrite, or destructive
  cleanup
- no appropriate remote / upstream target exists yet
- the working tree mixes unrelated changes that cannot be safely separated from
  the accepted bundle
- secrets, credentials, or policy-sensitive artifacts may be included
- the intended branch / repo placement is genuinely ambiguous

If the guardian subagent is unavailable, the Codex supervisor owns this
checkpoint-stewardship slice directly. It should return an exact artifact:
branch used, commit SHA, push target, included scope, excluded scope, and test
evidence. Do not stop merely because branch creation, staging, commit, or push
would normally be "git work"; stop only when the git decision itself is
ambiguous or destructive.

## Completed Slices (most recent session)

These slices are done and test-backed. Do not re-dispatch them.

1. **SubagentStart payload shape pins** (`tests/runtime/test_subagent_start_payload_shape.py`)
   — live capture confirms six contract fields are absent from real SubagentStart
   payloads; sidecar-file carrier rejected; SQLite registry recommended.

2. **Single-authority request validator** — `validate_subagent_start_prompt_pack_request`
   moved to `runtime/core/prompt_pack_validation.py`. `prompt_pack.py` calls it
   via function-local import. All import-discipline guard tests updated and passing.

3. **SubagentStart hook-adapter reduction** (`hooks/subagent-start.sh`) — runtime-first
   path verified and tightened. 31 tests in `tests/runtime/test_subagent_start_hook.py`
   cover all 5 routing invariants. Hook is a thin transport adapter only.

4. **SubagentStart contract carrier transport** (DEC-CLAUDEX-SA-CARRIER-001) —
   `pending_agent_requests` SQLite table + Python helpers + `pre-agent.sh` write
   + `subagent-start.sh` consume. 57 tests.

5. **Carrier producer** (DEC-CLAUDEX-AGENT-PROMPT-001) — `runtime/core/agent_prompt.py`
   + `cc-policy dispatch agent-prompt` CLI. Returns `prompt_prefix` with
   `CLAUDEX_CONTRACT_BLOCK:` at column 0 on line 1. 43 tests.
   **Live-verified 2026-04-09**: `dispatch-debug.jsonl` entry 39/39 confirms
   production reachability. Phase 2b gate cleared.

6. **Phase 2b schema seed** (DEC-CLAUDEX-SUPERVISION-DOMAIN-001) —
   `agent_sessions`, `seats`, `supervision_threads`, `dispatch_attempts` tables
   added to `runtime/schemas.py` as the sole runtime authority. Status/role
   constants added. 42 tests in `tests/runtime/test_supervision_schema.py`.

7. **Phase 2b domain authority** — `runtime/core/dispatch_attempts.py` — full
   state machine: `issue / claim / acknowledge / fail / cancel / timeout / retry
   / expire_stale`. Invalid transitions raise `ValueError`. 52 tests.

8. **Phase 2b transport-adapter contract** (DEC-CLAUDEX-TRANSPORT-CONTRACT-001) —
   `runtime/core/transport_contract.py` (`TransportAdapter` Protocol + registry)
   + `runtime/core/claude_code_adapter.py` (first adapter, auto-registered).
   Domain boundary: `SubagentStop` is work completion owned by `completions.py`;
   `on_acknowledged()` has no automatic harness trigger for `claude_code`.
   31 tests in `tests/runtime/test_transport_contract.py`.

10. **Phase 2b tmux transport adapter** (DEC-CLAUDEX-TRANSPORT-TMUX-001) —
   `runtime/core/tmux_adapter.py`: `TmuxAdapter` class + auto-registration as `"tmux"`.
   Pure domain translator: caller (watchdog/observer) owns pane interaction and sentinel
   detection; adapter maps caller-supplied evidence to `dispatch_attempts` state.
   `on_delivery_claimed()` requires external sentinel confirmation (not automatic).
   `on_acknowledged()` has genuine utility for tmux receipt sentinel.
   Pane IDs and sentinel strings are NOT stored in `dispatch_attempts`.
   Both `"tmux"` and `"claude_code"` coexist in registry. 31 tests.

9. **Phase 2b hook wiring** (DEC-CLAUDEX-HOOK-WIRING-001) —
   `runtime/core/dispatch_hook.py`: `record_agent_dispatch` (PreToolUse:Agent →
   pending), `record_subagent_delivery` (SubagentStart → delivered).
   `cc-policy dispatch attempt-issue` + `attempt-claim` CLI commands.
   `hooks/pre-agent.sh` + `hooks/subagent-start.sh` wired.
   Two authority corrections applied in this slice:
   - **seats.role** always `'worker'` (SEAT_ROLES vocabulary); harness
     `agent_type` is transport identity encoded in `seat_id` only.
   - **attempt-claim gated on carrier match**: `subagent-start.sh` only calls
     `attempt-claim` when `_CARRIER_JSON` is non-empty — no carrier proof, no
     delivery claim.
   24 tests in `tests/runtime/test_dispatch_hook.py`.

11. **Phase 3 capability contract authority** (DEC-CLAUDEX-CAPABILITY-CONTRACT-001) —
    `StageCapabilityContract` frozen dataclass + `resolve_contract()` + `all_contracts()`
    added to `runtime/core/authority_registry.py`. Contracts bundle granted/denied sets
    and read_only flag. `as_prompt_projection()` returns deterministic JSON for prompt-pack
    compilation. Module docstring updated to distinguish live-for-policy-engine vs.
    shadow-only-for-routing. 90 tests in `tests/runtime/test_authority_registry.py`
    (32 new).

12. **Phase 3 prompt-pack stage contract wiring** —
    `prompt_pack_resolver.py::render_stage_contract_layer()` rewired to use
    `resolve_contract()` as sole capability source. Uses `contract.stage_id` for
    all downstream lookups (capabilities, denied, read_only, verdicts). Reviewer
    gets "Read-only: yes". Live-role aliases canonicalize through the contract.
    170 tests in `tests/runtime/test_prompt_pack_resolver.py` (17 new).

13. **Phase 3 reviewer git read-only gate** — `bash_git_who.py` denies classified
    git operations (commit, merge, push) when `READ_ONLY_REVIEW` capability is
    present, checked after meta-repo bypass but before lease `allowed_ops`. A
    permissive lease cannot override the capability denial.
    `leases.ROLE_DEFAULTS` includes reviewer with empty `allowed_ops`.
    23 tests in `tests/runtime/policies/test_bash_git_who.py` (8 new);
    1 new test in `tests/runtime/test_leases.py`.

14. **Phase 3 runtime CLI capability-contract projection** —
    `cc-policy context capability-contract --stage <stage>` returns
    `StageCapabilityContract.as_prompt_projection()` as JSON. Aliases canonicalize
    via `resolve_contract()`. Unknown/sink stages fail closed (nonzero exit).
    8 tests in `tests/runtime/test_hook_bridge.py::TestContextCapabilityContract`.

15. **Phase 3 capability-gate invariant coverage** —
    `tests/runtime/policies/test_capability_gate_invariants.py`: 25 AST-based tests
    pinning all five migrated policies authorize via capability constants, not
    role-name strings. Protected policy tests: 86 passed across 5 files.

16. **Phase 3 exit-criteria audit** — `ready_to_mark_phase3_complete: true`.
    All four CUTOVER_PLAN exit criteria verified with mechanical evidence.

## Current State (as of 2026-04-14)

**Phases 3, 4, 5, 6, 7, and 8 are all COMPLETE.** The ClauDEX cutover
has reached the Phase 8 closeout boundary:

- **Phase 3 — Capability-Gated Policy Model:** COMPLETE (2026-04-13),
  7 slices.
- **Phase 4 — Workflow Reviewer Introduction:** COMPLETE (2026-04-13),
  10 slices.
- **Phase 5 — Loop Activation and Tester Removal:** COMPLETE (2026-04-13),
  3 slices — `determine_next_role("tester", ...)` returns None;
  reviewer is sole technical readiness authority.
- **Phase 6 — Goal Continuation Activation:** COMPLETE (2026-04-13),
  6 slices.
- **Phase 7 — Constitution / Authority Hardening:** COMPLETE (2026-04-13),
  17 slices; `CUTOVER_PLAN` planned-area set exhausted.
- **Phase 8 — Legacy Deletion and Final Cutover:** COMPLETE
  (2026-04-14), 12 slices — Slice 10 decommissioned the tester
  wiring, Slice 11 retired the dead runtime code and flipped
  invariants, Slice 11 correction cleaned scenario/test surface, and
  Slice 12 closed the audit / state-record correction + time-scoping
  pass. Both Phase 8 CUTOVER_PLAN exit criteria are met with
  installed-truth evidence — see `ClauDEX/CURRENT_STATE.md`
  "Phase 8 Closeout Status" section.

**Checkpoint stewardship is complete.** The ClauDEX cutover bundle
landed as commit `6b8cc5c` (`feat(claudex): cutover bundle - Phases 1-8
closeout`) and the subsequent auto-submit process-control fix landed as
`d8fdf96` (`Fix ClauDEX auto-submit process growth`). Both commits are
pushed to `origin/feat/claudex-cutover`; this soak worktree is on
`claudesox-local` tracking the same upstream at HEAD `d8fdf96`. No
checkpoint debt remains.

**Next bounded action: checkpoint the follow-up maintenance bundle,
then resume cutover-plan continuation or lane maintenance.** With
Phases 1-8 closed and upstream, the only current local work is the
state-record correction plus the lane-local Codex supervisor launcher
fix (`ClauDEX/CURRENT_STATE.md`, `ClauDEX/SUPERVISOR_HANDOFF.md`,
`scripts/claudex-codex-launch.sh`). Once that bundle is reviewed,
tested, committed, and pushed, the supervisor should either (a) resume
the `ClauDEX/CUTOVER_PLAN.md` architecture track — the runtime-owned
agent-session supervision fabric — when ready to open a new slice, or
(b) stay in steady-state review/steer mode and handle narrow
maintenance items without opening fresh architecture work. See
`ClauDEX/CURRENT_STATE.md` "Checkpoint Readiness" section for the
installed-truth git state and focused gate evidence.

Do not auto-dispatch a new architecture slice unless the cutover plan
has been re-read and a clearly bounded slice is ready.

For current detail, see `ClauDEX/CURRENT_STATE.md`.

## Relevant Grounding

- Architecture / target design:
  - [ClauDEX/CUTOVER_PLAN.md](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/ClauDEX/CUTOVER_PLAN.md)
- Current execution / restart state:
  - [ClauDEX/CURRENT_STATE.md](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/ClauDEX/CURRENT_STATE.md)
- Operator / runtime setup:
  - [ClauDEX/OVERNIGHT_RUNBOOK.md](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/ClauDEX/OVERNIGHT_RUNBOOK.md)
- Repo-local Codex config:
  - [`.codex/config.toml`](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.codex/config.toml)
- Repo-local Codex hooks:
  - [`.codex/hooks.json`](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.codex/hooks.json)

## Invariant

The supervisor loop must keep Codex in charge of the live bridge session.

- No pulse-file operator.
- No secondary autonomous decider.
- No user prompt required merely because Codex reached a turn boundary.
- The `Stop` hook and `wait_for_codex_review()` exist specifically so Codex
  returns to a blocking review state instead of falling out of the loop.
