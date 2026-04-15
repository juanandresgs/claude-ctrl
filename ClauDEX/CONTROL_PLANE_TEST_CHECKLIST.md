# ClauDEX Control Plane Test Checklist

Status: active checklist
Scope: the main ClauDEX cutover runtime and the live supervisor/bridge control
path in this repository

This file tracks the highest-value testing work still needed for the main
ClauDEX control plane.

It is not the `braid-v2` release checklist. That lives in
[EXTERNALIZATION_CHECKLIST.md](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/ClauDEX/braid-v2/EXTERNALIZATION_CHECKLIST.md).

## Current Risk Read

- `runtime/core` policy, schema, and prompt-pack surfaces: low risk
- live supervisor/bridge helpers under `.codex/`, `scripts/claudex-*.sh`, and
  tmux ownership: medium to high risk
- tmux integration and long-lived recovery behavior: high risk

## Must-Have Before Calling The Main Loop Operationally Reliable

- [ ] Trust gate handling is mechanically covered.
  Add integration tests proving directory trust, tool trust, and equivalent
  permission prompts are cleared exactly once and do not re-loop forever.

- [ ] Supervisor restart de-duplication is mechanically covered.
  Add tests proving the supervisor recovery path does not keep restarting the
  same pane on repeated snapshots of the same degraded state.

- [ ] Single-owner helper lifecycle is covered.
  Add tests proving watchdog, progress monitor, and approver ownership collapse
  to one active control path and stale helpers cannot keep steering the same
  live pane.

- [ ] Progress monitor health classification is sharpened and tested.
  Add tests that distinguish:
  - trust / permission gate
  - dead pane
  - healthy review wait
  - real dispatch stall

- [ ] tmux-backed restart path is covered end to end.
  Add an integration test that starts a live supervisor pane, induces a stop,
  restarts through the supported recovery path, and proves the pending review
  remains attached to the same active run.

## Should-Have Before Treating The Bridge As Boring Infrastructure

- [ ] Queue, inflight, and pending-review coherence tests exist.
  Prove the bridge state and artifacts stay aligned across
  `queued -> inflight -> waiting_for_codex`.

- [ ] Dispatch recovery is directly tested.
  Prove the authoritative dispatch recovery path archives or revives a stalled
  run without duplicating helper daemons or stomping an active review.

- [ ] Status reporting understands tmux-owned helpers.
  Extend `claudex-bridge-status.sh` tests so a helper owned by a tmux pane is
  not falsely reported as stale just because pid-file probing is limited.

- [ ] Permission-limited process probing is covered.
  Add tests for the current macOS / sandbox shape where `pgrep` and `ps` are
  unreliable or unavailable, and verify the pid-file fallback path stays sane.

## Nice-To-Have Before Long Soak

- [ ] Failure-injection soak script exists for the main control path.
  Exercise trust prompts, dead panes, stale alerts, and queue stalls in one
  repeatable harness.

- [ ] Trace capture is emitted for helper decisions.
  Record when watchdog, approver, and progress monitor classified a state or
  took a recovery action so silent failure analysis is easier.

- [ ] Alert summaries are round-trippable.
  Add fixtures or snapshots for degraded-state reports so operator surfaces stop
  drifting from the runtime facts.

## Exit Signal

The main control-plane bridge can be treated as operationally reliable when:

- every Must-Have item above is complete
- at least one tmux-backed overnight soak finishes without restart storms
- trust / permission prompts resolve without manual babysitting
- repeated watchdog or monitor samples do not create repeated supervisor
  restarts for the same live condition
