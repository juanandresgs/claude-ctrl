# GS1 Goal Decision Digest (2026-04-18)

This document is a **subordinate companion** to the runtime authority
`cc-policy decision digest` (projection source:
`runtime/core/decision_digest_projection.py`). It is a read-only derived
projection — not a parallel authority. It captures, in durable markdown
form, the post-guardian decision inventory for goal `gs1-global-soak-stabilization`
as of the closing of the GS1 work-item chain.

The DEC-id registry migration (DEC-CLAUDEX-DW-REGISTRY-001) remains
deferred. Until that slice runs, this artifact provides the projection in
markdown only; the runtime digest reports zero registered decisions for this
goal (empty `decision_ids`). Both are correct and consistent: the registry
has not yet been populated from in-commit `@decision` annotations.

**Produced by:** this implementer slice, at HEAD
`124fda8175e0fc64b0e26e6222f1acc49ae4fb44`, following the guardian-landing
chain: GS1-F-5 → handoff-lane-truth-refresh → coverage-matrix-successor.

---

## Authority Discipline

| Fact | Canonical Authority |
|------|---------------------|
| Goal record | `cc-policy workflow goal-get gs1-global-soak-stabilization` |
| Decision records | `runtime/core/decision_work_registry.py::decisions` (empty for this goal's DEC-ids pending registry migration) |
| Invariant #14 mechanical pin | `tests/runtime/test_goal_continuation.py::TestPlannerOwnedBoundary` |
| Decision digest freshness | `cc-policy decision digest` → `projection.content_hash` |

`cc-policy decision digest` current `content_hash` (captured at precondition
verification, generated_at 1776563472):

```
sha256:4a2712812e344357dc708fcc0d2f52a040a04486fbf16707f2d0dec0e7d53194
```

---

## Goal Record (Verbatim)

Captured via `cc-policy workflow goal-get gs1-global-soak-stabilization`:

```json
{
  "goal_id": "gs1-global-soak-stabilization",
  "desired_end_state": "Global-soak lane reports healthy bridge/broker state on active+waiting_for_codex runs; no false 'lagging' or 'pid file stale' signals in steady state; supervisor seat stays alive on claudex-global-soak.",
  "status": "active",
  "autonomy_budget": 8,
  "workflow_id": "global-soak-main",
  "created_at": 1776546313,
  "updated_at": 1776546313,
  "found": true
}
```

---

## Landed Work-Items Table

In chronological commit order (oldest first):

| work_item_id | status | head_sha | title |
|---|---|---|---|
| `gs1-a-snapshot-health-race` | landed | `d8e90965ed72f2beb7d781db6c5e27ef34d4b3ac` | GS1-A: Fix false 'lagging' snapshot health on healthy active+waiting_for_codex runs |
| `gs1-b-1-broker-pid-persist` | landed | `ea5e4a0` | GS1-B-1: Persist broker PID at bridge-up |
| `gs1-f-2-reliability` | landed | `0038efee69622408b914b7ab2afb9ddca7d3e6db` | GS1-F-2: SubagentStart marker seating reliability + DB routing |
| `gs1-f-3-unified-db-routing` | landed | `bf08423` | GS1-F-3: Unify carrier + DB routing across pre-agent/subagent-start |
| `gs1-f-4-compound-stage-marker-persistence` | landed | `1de81c0b09d0cc5d63a872e77756e51b9adc91c6` | GS1-F-4: compound-stage marker persistence |
| `gs1-f-5-capability-lock` | landed | `2127fe9242592ddf700371cce35c5e08f74f1b49` | GS1-F-5: compound-stage → can_land_git capability lock |
| `handoff-lane-truth-refresh` | landed | `9762dc7168b67c1d67f56f05b88e20b66384edce` | Handoff lane-truth tip-claim refresh |
| `coverage-matrix-successor` | landed | `124fda8175e0fc64b0e26e6222f1acc49ae4fb44` | CUTOVER invariant-coverage matrix successor dated artifact |

**Footnote:** `gs1-f-1-overnight-helpers` is **not a registered work-item**
in the runtime database. The overnight-helpers fix was landed as commit
`68b88c8` (fixes `hooks/subagent-start.sh` SubagentStart identity via
payload `agent_id`). It carries `DEC-CLAUDEX-SA-IDENTITY-001` and is cited
by SHA only. No `work_item_id` exists for it in `cc-policy workflow work-item-get`.

---

## DEC-id Inventory

Each entry below states whether the DEC-id was found in the referenced
commit message via `git log -1 --format=%B <sha>`. Entries not found in
commit messages are explicitly noted and dropped.

### DEC-CLAUDEX-SA-IDENTITY-001

- **Commit:** `68b88c8`
- **Work-item:** not registered (see footnote above)
- **Verification:** FOUND. Commit message contains `decision: DEC-CLAUDEX-SA-IDENTITY-001`.
- **Excerpt:**
  ```
  decision: DEC-CLAUDEX-SA-IDENTITY-001
  ```
- **Summary:** Payload `agent_id` is the sole authority for SubagentStart
  identity; shell PID (`agent-$$`) creates a dual-authority gap.

### DEC-GS1-B-BROKER-PID-PERSIST-001

- **Commit:** `ea5e4a0`
- **Work-item:** `gs1-b-1-broker-pid-persist`
- **Verification:** FOUND. Commit message contains `decision: DEC-GS1-B-BROKER-PID-PERSIST-001`.
- **Excerpt:**
  ```
  decision: DEC-GS1-B-BROKER-PID-PERSIST-001
  ```
- **Summary:** `bridge-up` is the sole canonical writer for `braidd.pid` at
  launch time; atomic `.tmp` + `mv` write gated on `BROKER_READY=1`.

### DEC-CLAUDEX-SA-MARKER-RELIABILITY-001

- **Commit:** `0038efe`
- **Work-item:** `gs1-f-2-reliability`
- **Verification:** FOUND. Commit message contains `decision: DEC-CLAUDEX-SA-MARKER-RELIABILITY-001`.
- **Excerpt:**
  ```
  decision: DEC-CLAUDEX-SA-MARKER-RELIABILITY-001 (extends
            DEC-CLAUDEX-SA-IDENTITY-001)
  ```
- **Summary:** `_local_cc_policy` 3-tier DB-routing fallback; seating errors
  captured as breadcrumb, never silently swallowed.

### DEC-CLAUDEX-SA-UNIFIED-DB-ROUTING-001

- **Commit:** `bf08423`
- **Work-item:** `gs1-f-3-unified-db-routing`
- **Verification:** FOUND. Commit message contains `decision: DEC-CLAUDEX-SA-UNIFIED-DB-ROUTING-001`.
- **Excerpt:**
  ```
  decision: DEC-CLAUDEX-SA-UNIFIED-DB-ROUTING-001 (extends
            DEC-CLAUDEX-SA-MARKER-RELIABILITY-001)
  ```
- **Summary:** `_resolve_policy_db()` in `hooks/lib/runtime-bridge.sh` is
  the single authoritative 3-tier resolver; no parallel resolvers remain.

### DEC-CONV-002-AMEND-001

- **Commit:** `1de81c0`
- **Work-item:** `gs1-f-4-compound-stage-marker-persistence`
- **Verification:** FOUND. Commit message contains `decision: DEC-CONV-002-AMEND-001`.
- **Excerpt:**
  ```
  decision: DEC-CONV-002-AMEND-001
  ```
- **Summary:** `ensure_schema()` cleanup whitelist derived from
  `stage_registry.ACTIVE_STAGES` union `{"guardian"}`; compound-stage
  markers (`guardian:land`, `guardian:provision`) survive cleanup.

### DEC-HANDOFF-INVARIANT-GS1-EXT-001

- **Commit:** `f42baec`
- **Work-item:** `handoff-lane-truth-refresh` (note: this commit predates the
  `handoff-lane-truth-refresh` work-item's head_sha `9762dc7`; `f42baec` is
  the intermediate handoff-sync doc commit, while `9762dc7` is the final
  lane-truth tip refresh)
- **Verification:** FOUND. Commit message contains `decision: DEC-HANDOFF-INVARIANT-GS1-EXT-001`.
- **Excerpt:**
  ```
  decision: DEC-HANDOFF-INVARIANT-GS1-EXT-001
  ```
- **Summary:** `test_handoff_artifact_path_invariants.py` regex extended to
  accept `GS1-<letter>[-<n>]` scheme alongside `A<N>[R|-followup]`.

### DEC-CLAUDEX-CUTOVER-INVARIANT-COVERAGE-MATRIX-001

- **Commit:** `124fda8`
- **Work-item:** `coverage-matrix-successor`
- **Verification:** NOT FOUND. `git log -1 --format=%B 124fda8` contains no
  `DEC-` reference or `decision:` line. The commit does reference GS1 commit
  SHAs and pin rows but does not declare a DEC-id in its message.
- **Disposition:** DROPPED from this inventory per forbidden-shortcuts rule
  ("Do NOT fabricate DEC-ids not present in commit messages").

### DEC-GS1-SNAPSHOT-HEALTH-RACE-001

- **Commit:** `d8e9096`
- **Work-item:** `gs1-a-snapshot-health-race`
- **Verification:** FOUND. Commit message contains `decision: DEC-GS1-SNAPSHOT-HEALTH-RACE-001`.
- **Excerpt:**
  ```
  decision: DEC-GS1-SNAPSHOT-HEALTH-RACE-001
  ```
- **Summary:** `SNAPSHOT_AGE_OK` is the single freshness authority for
  snapshot health; instruction-id race between periodic snapshots is
  expected on healthy runs and is not a health signal.

### Note on GS1-F-5 and handoff-lane-truth-refresh

- Commit `2127fe9` (GS1-F-5, `gs1-f-5-capability-lock`): no `decision:` line
  in commit message; test-only hardening slice — no new DEC-id declared.
- Commit `9762dc7` (`handoff-lane-truth-refresh`): no `decision:` line in
  commit message; docs-only tip refresh — no new DEC-id declared.

**Final DEC-id count: 7 confirmed** (one dropped: DEC-CLAUDEX-CUTOVER-INVARIANT-COVERAGE-MATRIX-001).

---

## Invariant #14 Lineage Check

**Verbatim quote from `ClauDEX/CUTOVER_PLAN.md` line 1493:**

> 14. Post-guardian continuation is planner-owned, not reviewer- or hook-owned.

**Mechanical pin:** `tests/runtime/test_goal_continuation.py::TestPlannerOwnedBoundary`

**Live execution proof:** This artifact is authored by the implementer stage
acting under a planner-approved supervisor specification, AFTER the
guardian-landing chain of `gs1-f-5 → handoff-lane-truth-refresh →
coverage-matrix-successor` closed. No reviewer stage and no hook authored
or authorized this artifact. The artifact's existence is a live execution
of Invariant #14.

The dispatch chain that produced this artifact:
1. Guardian landed `gs1-f-5-capability-lock` at `2127fe9`
2. Guardian landed `handoff-lane-truth-refresh` at `9762dc7`
3. Guardian landed `coverage-matrix-successor` at `124fda8`
4. Planner (supervisor) approved this continuation slice
5. Implementer (this agent) authored this artifact

---

## Known Gaps

1. **DEC-id registry migration deferred.** `DEC-CLAUDEX-DW-REGISTRY-001`
   remains open. Until that slice runs, `runtime/core/decision_work_registry.py::decisions`
   is empty for all GS1 DEC-ids. The runtime decision digest correctly
   reports zero registered decisions. This artifact is the durable
   markdown-only projection in the interim.

2. **No mechanical-pin test for this artifact.** Deferred to a follow-on
   slice. When authored, it would live at
   `tests/runtime/test_gs1_goal_digest_artifact.py`, mirroring the
   coverage-matrix pattern in `tests/runtime/test_cutover_invariant_coverage_matrix.py`.

3. **DEC-CLAUDEX-CUTOVER-INVARIANT-COVERAGE-MATRIX-001 not confirmed.**
   The commit message for `124fda8` does not contain this DEC-id. Either
   the annotation was not added to the commit or it was named differently.
   Dropped per forbidden-shortcuts rule. A follow-on slice can add the
   `decision:` line to the next coverage-matrix successor commit.

---

## Self-Decision Record

```
@decision DEC-GS1-GOAL-DIGEST-001
Title: GS1 goal decision digest is a planner-owned post-guardian projection
Status: proposed (markdown-only pending DEC-CLAUDEX-DW-REGISTRY-001 migration)
Rationale: Phase 6 authority requires planner-owned post-guardian continuation
for completed goals. The goal `gs1-global-soak-stabilization` has 8 landed
work-items carrying 7 confirmed DEC-ids as @decision annotations (one
DEC-id, DEC-CLAUDEX-CUTOVER-INVARIANT-COVERAGE-MATRIX-001, not found in
the referenced commit message and therefore dropped). Until the DEC registry
ingests markdown annotations, this artifact provides a durable post-guardian
projection that satisfies Invariant #14.
```

---

## Successor History

- 2026-04-18 (this doc, HEAD `124fda8175e0fc64b0e26e6222f1acc49ae4fb44`,
  landed as `<new_commit_sha_placeholder>`).
