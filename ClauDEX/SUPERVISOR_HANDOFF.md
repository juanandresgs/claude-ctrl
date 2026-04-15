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
   [`.claude/claudex/pending-review.json`](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/.claude/claudex/pending-review.json)
   when present, then prefer `get_response()` as the normal review source,
   verify files/tests, and decide the next bounded instruction.
5. If the bridge is `queued` or `inflight`, call `wait_for_codex_review()` to
   return to a true blocking state until review is needed.
6. If the bridge is active but `.claude/claudex/dispatch-stall.state.json`
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

**Next bounded action: guardian-equivalent checkpoint stewardship, not
a new cutover slice.** The local ClauDEX cutover bundle is
uncheckpointed on `fix/enforce-rca-13-git-shell-classifier` (248
working-tree entries). The supervisor should treat that checkpoint as
the next bounded action: create or reuse `feat/claudex-cutover`, stage
the coherent cutover bundle, rerun the focused verification gates,
commit, and push to the existing private upstream if no destructive git
action is required. See `ClauDEX/CURRENT_STATE.md` "Checkpoint
Readiness" section for git state, verification summary, and the 3
pre-existing unrelated test failures that are **not** Phase 8 blockers.

Do not auto-dispatch a new architecture slice until the checkpoint
slice is complete or a real git ambiguity has been handed to the user.

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
