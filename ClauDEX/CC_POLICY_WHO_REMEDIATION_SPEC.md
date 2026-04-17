# WHO / Checks-and-Balances — Subsystem Notes (Subordinate)

## Subordination Statement

This document is **supporting subsystem notes** for the current ClauDEX
cutover lane. It is **not** a plan, not a controlling authority, not a new
workflow, and not a second control plane.

- Architecture source of truth: `ClauDEX/CUTOVER_PLAN.md`.
- Active lane-state authorities: `ClauDEX/CURRENT_STATE.md` and
  `ClauDEX/SUPERVISOR_HANDOFF.md`.
- Live runtime and tests are the mechanical source of truth for authority,
  capabilities, stage identity, and WHO policy behavior.

If any wording below conflicts with those three files or with installed
runtime code, the three files and installed code win. This notes file must
be updated in the same change that updates the authority — never the other
way around.

Nothing in this file:

- opens a new active branch of work,
- introduces a new workflow id,
- appoints a new planning authority,
- or replaces any existing stage contract.

## Purpose (as subsystem notes)

Capture WHO / checks-and-balances framing so future bounded slices under the
existing cutover lane can address WHO gaps consistently. These notes
complement — they do not replace — the decomposition and sequencing work that
already lives in the three authority docs above.

## Operating Principle (restatement, informational)

For each materially different action class there is one owning stage, and
the next stage provides an independent check before progression. The
classification below restates live runtime intent; it is not a new mandate:

- planner owns planning, governance, continuation, and control configuration
- guardian(provision) owns worktree creation, lease issuance, and workflow binding
- implementer owns source edits inside an approved scope
- reviewer owns technical readiness and findings from a read-only viewpoint
  (operator-facing prose may say “evaluator” only where clearly labeled;
  runtime/tests/dispatch use `reviewer`)
- guardian(land) owns git landing
- orchestrator/supervisor owns coordination, dispatch, and review of stage
  outputs

The orchestrator does not perform source work, evaluation, worktree
provisioning, or git landing directly except for narrowly-scoped, explicit,
and audited emergency recovery paths.

## Observed WHO-Adjacent Topics (informational)

These are observations that may be useful inputs to future planner slices
under the existing cutover lane. They are not tasks, not ordered, and not a
backlog.

1. Bridge overlay denies for `git commit`/`push`/`merge`/`rebase`/`reset`
   previously prevented `cc-policy` from seeing the decision. Live runtime
   now carries `CAN_LAND_GIT` and landing-class coverage; if any residual
   bridge-level short-circuit is discovered, it should be treated as a
   deny-before-policy drift, not a feature.
2. Bridge overlay Bash surface breadth vs shell-mutation bypass risk.
3. Implementer git-authority classification alignment with guardian-only
   landing.
4. Stage-identity precision between `guardian:provision` and
   `guardian:land`.
5. Mandatory runtime-issued contract metadata for dispatch-significant
   launches.
6. Write/Edit hook wiring proof under the bridge launch surface.

Each of these is a topic a future planner may choose to incorporate. None is
a live slice by virtue of appearing here.

## Design References (informational)

The design references below are restatements of already-installed runtime
direction. They are included so future notes/slices can point at a shared
vocabulary without re-deriving it.

### A. Policy-first git landing

Git landing decisions are owned by `cc-policy`. Settings-level denies that
bypass policy evaluation are treated as drift and corrected at the bridge
surface, not preserved as parallel authority.

### B. Guardian-only landing

- implementer: source mutation only, no git landing
- reviewer: read-only
- guardian(provision): worktree/lease/binding only
- guardian(land): sole landing authority
- `CAN_LAND_GIT` is the capability-level gate; landing-class operations are
  denied for any stage that does not carry it.

### C. Stage identity precision

Policy evaluation and prompt-pack compilation resolve stage from dispatch
contract + runtime state, not only harness `agent_type`. Harness may surface
a single `guardian` agent type while runtime distinguishes `guardian:provision`
and `guardian:land`.

### D. Mandatory dispatch contracts

Planner / implementer / reviewer / guardian launches carry runtime-issued
contract metadata (workflow id, stage id, goal id, work item id, decision
scope, generation timestamp). `pre-agent.sh` is the enforcement point. Free-
form orchestration prompts are not authoritative.

### E. Closing shell-based mutation bypasses

`Write|Edit` WHO is not sufficient if shell mutation can bypass it. The
preferred direction is narrowing the bridge Bash surface toward original
hardFork; targeted bash mutation policy is a fallback where narrowing
cannot cover a given workflow.

## Illustrative Slice-Seed Topics (examples only; not an active plan)

The topics below are **example framings** a future planner working under the
existing cutover lane could choose to bound into slices. Ordering is
illustrative, not prescriptive, and inclusion here does not reserve a slot in
the cutover lane. Any actual slice must be admitted through the existing
planner/workflow gates.

- Bridge authority restoration (settings-level bypass removal vs runtime
  policy coverage)
- Mandatory contract-driven subagent dispatch enforcement
- Guardian-only landing authority verification in live policy behavior
- Stage-identity hardening for `guardian:provision` vs `guardian:land`
- Hook-wiring proof and statusline observability

Each “topic” is a candidate conversation, not a committed slice.

## Test References (informational)

Any slice that actually ships WHO changes carries its own tests under the
existing test authority (`tests/runtime/**` and `tests/**`). Representative
test families already live:

- lease + stage identity
- `bash_git_who` landing capability
- pre-agent contract enforcement
- bridge-settings / hook wiring invariants
- statusline snapshot coverage

This notes file does not add tests and does not impose new acceptance
criteria beyond what the existing authorities already require.

## Non-Authority Clause

This document does not define:

- session-level acceptance criteria
- supervisor operating rules
- workflow ids
- command sequences to be run as a new active branch

The existing `SUPERVISOR_HANDOFF.md` remains the operating authority for the
supervisor loop. The existing `CUTOVER_PLAN.md` remains the architecture
source of truth. Planning and sequencing continue to flow through the
already-active planner under the current cutover lane.

## Authority Reconciliation Rule

If this notes file drifts from installed code or from the three authority
docs, installed code and the authority docs are correct, and this notes file
must be updated in the same change that updates the authority — not the
other way around.
