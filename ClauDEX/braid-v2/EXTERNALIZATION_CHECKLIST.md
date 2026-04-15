# braid-v2 Externalization Checklist

Status: active checklist
Scope: what `braid-v2` must satisfy before it is presented as a reusable
package for other repositories or teams

This is the release/readiness checklist for `braid-v2` as an independent
supervision product.

It assumes the current design split holds:

- `braid-v2` owns runtime supervision truth
- the ClauDEX policy engine is one policy implementation, not the kernel itself

## Current Read

- kernel and SQLite model: real, but still narrow
- tmux adapter: real first adapter, not yet proven under deep soak
- controller keepalive: partial
- packaging boundary from ClauDEX repo law: not yet formalized

## Must-Have Before External Sharing

- [ ] Kernel coverage goes beyond the current narrow smoke suite.
  Add direct tests for:
  - bundle lifecycle validation
  - seat/session/thread invariants
  - dispatch state transitions
  - interaction gate lifecycle
  - finding and repair lifecycle
  - structured CLI error handling for invalid inputs

- [ ] Controller-driven keepalive is test-backed.
  Add coverage for:
  - stale dispatch timeout
  - bounded retry
  - archive on terminal bundle
  - no repeated restart storm on the same degraded state

- [ ] tmux adapter behavior is covered end to end.
  Add tests for:
  - adopt existing pane
  - spawn worker + supervisor pair
  - send and capture
  - detect and resolve trust/edit/permission prompts
  - handle pane respawn without losing session identity

- [ ] Recursive child bundle spawn is mechanically covered.
  Add tests for:
  - spawn_request recording
  - parent dispatcher approval path
  - child bundle creation
  - bundle tree visibility
  - parent supervision continuity while child bundle is active

- [ ] Policy surface is a real interface, not repo convention.
  Define and test the stable calls `braid-v2` expects from a policy authority so
  another repository can implement the same interface without importing ClauDEX
  internals by accident.

- [ ] One live soak completes without file-backed queue truth.
  `braid-v2` is not externally shareable until it completes an actual soak run
  with runtime-owned dispatch and supervision state as the authority.

- [ ] Run forensics are retained and exportable.
  Add coverage for:
  - append-only trajectory events
  - conversation pairing across worker, supervisor, dispatcher, and child
    bundles
  - retained snapshots at review, gate, timeout, repair, and archive
    boundaries
  - bundle archive export without tmux scraping
  - diagnostic queries suitable for evaluator tooling

## Should-Have Before Calling It A Package

- [ ] Reference seat topologies are documented and tested.
  At minimum:
  - `supervisor -> worker`
  - `supervisor + evaluator -> worker`
  - `dispatcher -> supervisor -> worker`, with guardian downstream only at
    authority boundaries

- [ ] At least one non-ClauDEX example exists.
  Ship one minimal example policy implementation or demo harness that proves
  `braid-v2` is not secretly tied to this repo's exact policy stack.

- [ ] Packaging boundaries are explicit.
  Split and document:
  - `braid-core`
  - `braid-adapter-tmux`
  - harness adapters
  - policy surface API
  - ClauDEX-specific policy pack

- [ ] Adapter failure semantics are stable.
  Document and test how adapters report:
  - delivery claim
  - timeout
  - gate open
  - gate resolve
  - session death

## Nice-To-Have Before Early Adoption

- [ ] A second harness adapter is live.
  Codex CLI or Gemini CLI should prove the kernel is truly multi-harness.

- [ ] Observer-only soak mode is proven.
  Read-only long-run monitoring should be able to open findings without becoming
  a hidden second supervisor.

## Exit Signal

`braid-v2` is ready to share as an independent package only when:

- every Must-Have item above is complete
- the policy surface can be implemented outside this repository
- one live soak finishes under runtime-owned authority
- tmux is just an adapter, not an implicit control authority
