# ClauDEX CUTOVER_PLAN Invariants — Coverage Matrix (2026-04-18)

> **SUPERSEDES:** `ClauDEX/CUTOVER_INVARIANT_COVERAGE_2026-04-17.md`
> Predecessor covered the original 16 invariants as of the 2026-04-17
> cc-policy-who-remediation session (committed `d7db4ba`). This successor
> refreshes eight rows with post-4/17 mechanical pins from the
> global-soak stabilization track (GS1-A through GS1-F-5, handoff sync).
> Date range: 2026-04-17 — 2026-04-18.

Scope: this document captures the mechanical-pin coverage status for every
invariant declared in `ClauDEX/CUTOVER_PLAN.md` § "Invariants That Must
Become Tests" (the 16 numbered invariants at approximately lines
1428–1456). It is dated; as the `runtime/core/` surface grows or shrinks
and new mechanical pins land, a successor doc supersedes this one (add a
dated entry under "Successor History" at the bottom).

This artifact is the **subordinate companion** to `ClauDEX/CUTOVER_PLAN.md`
— that file remains the architecture source of truth; this file is an
audit projection, read-only in spirit, and validated by the mechanical pin
`tests/runtime/test_cutover_invariant_coverage_matrix.py` (see rationale
below).

- **Architecture source of truth:** `ClauDEX/CUTOVER_PLAN.md` § Invariants
  That Must Become Tests.
- **Mechanical validator:** `tests/runtime/test_cutover_invariant_coverage_matrix.py`.
  The validator statically reads this file and asserts (a) all 16 invariant
  rows are present, (b) every row cites at least one non-empty test file
  reference. A regression (row removed, empty cell) fails the test with a
  structured diagnostic.
- **Produced by:** the global-soak stabilization track on `global-soak-main`
  during the 2026-04-18 session. Pre-landing HEAD `9762dc7` caps the GS1
  chain (GS1-A `d8e9096`, GS1-F-1 `68b88c8`, GS1-B-1 `ea5e4a0`,
  GS1-F-2 `0038efe`, GS1-F-3 `bf08423`, GS1-F-4 `1de81c0`,
  GS1-F-5 `2127fe9`, handoff sync `f42baec`). All GS1 checkpoint debt is
  now cleared. `ClauDEX/CURRENT_STATE.md` and `ClauDEX/SUPERVISOR_HANDOFF.md`
  are the authoritative lane-state surfaces; if any count here drifts from
  those two files, those files win and this artifact must be corrected in
  the same change.
- **Decision record:** `DEC-CLAUDEX-CUTOVER-INVARIANT-COVERAGE-MATRIX-001`.

## Coverage table

Each row names: the invariant number (matching CUTOVER_PLAN ordering),
the invariant prose (verbatim or minimally rendered), the coverage
status (`covered` / `partial` / `missing`), and the concrete backing test
file(s) and — where named — test class(es). Every `covered` row MUST
cite at least one non-empty test-reference cell.

| # | Invariant | Status | Backing tests |
|---|---|---|---|
| 1 | No stage transitions are defined outside the stage registry | covered | `tests/runtime/test_stage_registry.py::TestTargetGraphTable`, `::TestInnerLoop`, `::TestOuterLoop`; consumed as sole authority by `tests/runtime/test_dispatch_engine.py` |
| 2 | No workflow-routing dependency remains on Stop-review events | covered | `tests/runtime/test_dispatch_engine.py` (`DEC-PHASE5-STOP-REVIEW-SEPARATION-001` cases around line 837+) |
| 3 | No repo-owned hook path in `settings.json` points to a missing file | covered | `tests/runtime/test_hook_manifest.py`; `tests/runtime/test_hook_validate_settings.py`; `cc-policy hook validate-settings` CLI with `invalid_adapter_files` report |
| 4 | No constitution-level config default is defined outside the schema/bootstrap authority | covered | `tests/runtime/test_constitution_registry.py` (74+ tests including `TestCutoverPlanDocRegistryParity`); post-4/17: `runtime/schemas.py` `_MARKER_ACTIVE_ROLES` derivation from `runtime.core.stage_registry.ACTIVE_STAGES` (commit `1de81c0`, DEC-CONV-002-AMEND-001) ensures compound-stage whitelist never drifts from declared stages |
| 5 | No policy module reparses command semantics already supplied by runtime intent objects | covered | `tests/runtime/policies/test_command_intent_single_authority.py` (Rules A/B/C + `TestRuleABAbsoluteNoExemptBypass`, DEC-CLAUDEX-COMMAND-INTENT-SOLE-AUTHORITY-001) |
| 6 | Reviewer capabilities are read-only and cannot land git or edit source | covered | `tests/runtime/policies/test_bash_git_who.py` (CAN_LAND_GIT gate); `tests/runtime/policies/test_capability_gate_invariants.py`; post-4/17: `tests/runtime/test_marker_compound_stage_persistence.py::test_guardian_land_marker_grants_can_land_git_capability` (commit `2127fe9`) locks compound-stage guardian:land → CAN_LAND_GIT capability invariant, proving the converse: only the guardian role (not reviewer) acquires landing authority |
| 7 | Regular Stop review and workflow review cannot mutate each other's routing state | covered | `tests/runtime/test_dispatch_engine.py` (same DEC-PHASE5-STOP-REVIEW-SEPARATION-001 block) |
| 8 | Docs that claim harness behavior are either generated, validated, or clearly marked as non-authoritative reference | covered | `tests/runtime/test_hook_doc_validation.py`; `tests/runtime/test_hook_doc_projection.py`; `tests/runtime/test_hook_doc_check_cli.py`; `cc-policy hook doc-check` exact-hash validator |
| 9 | Prompt packs are generated from runtime authority and carry freshness metadata | covered | `tests/runtime/test_prompt_pack.py`; `tests/runtime/test_prompt_pack_resolver.py`; `tests/runtime/test_prompt_pack_validation.py`; `tests/runtime/test_prompt_pack_compile_cli.py`; `tests/runtime/test_prompt_pack_check_cli.py`; `tests/runtime/test_prompt_pack_state.py`; `tests/runtime/test_prompt_pack_decisions.py` |
| 10 | Canonical decision/work records exist outside markdown-only logs | covered | `tests/runtime/test_decision_work_registry.py`; `tests/runtime/test_decision_digest_projection.py`; `tests/runtime/test_decision_digest_cli.py` |
| 11 | `@decision-ref` links resolve to active or explicitly superseded decisions | covered | `tests/runtime/test_decision_ref_resolution.py` (DEC-CLAUDEX-DECISION-REF-SCAN-001) |
| 12 | Derived projections fail validation when upstream canonical state changed without reflow | covered | `tests/runtime/test_projection_reflow.py` (`TestAssessProjectionFreshness`, `TestExtractProjectionMetadata`, `TestAssessInputValidation`, `TestPlanProjectionReflow`, `TestRealBuilderOutputs`, `TestStatusVocabulary`, `TestModuleSurface`, `TestShadowOnlyDiscipline`); `tests/runtime/test_projection_schemas.py` |
| 13 | Retrieval and graph layers are derived read models and never treated as legal source of truth | covered | `tests/runtime/test_memory_retrieval.py::TestShadowOnlyDiscipline` (retrieval -> live direction); `tests/runtime/test_retrieval_layer_downstream_invariant.py` (live -> retrieval direction, DEC-CLAUDEX-RETRIEVAL-LAYER-DOWNSTREAM-INVARIANT-001) |
| 14 | Post-guardian continuation is planner-owned, not reviewer- or hook-owned | covered | `tests/runtime/test_goal_continuation.py::TestPlannerOwnedBoundary`, `::TestDispatchEngineIntegration`, `::TestUpdateGoalStatusForVerdict` |
| 15 | Any source change after reviewer clearance invalidates readiness | covered | Write/Edit path: `hooks/track.sh` (DEC-EVAL-005); Bash path: `hooks/post-bash.sh` (DEC-EVAL-006) with `tests/runtime/policies/test_post_bash_eval_invalidation.py`; bridge parity: `tests/runtime/test_bridge_permissions.py::TestPostToolBashWiringPresent`; post-4/17: `hooks/lib/runtime-bridge.sh::_resolve_policy_db()` unified 3-tier resolver (commit `bf08423`, DEC-CLAUDEX-SA-UNIFIED-DB-ROUTING-001) ensures DB-path is consistent across all hook sites; `tests/hooks/test_runtime_bridge_resolver.py` (10 unit tests, commit `bf08423`); `tests/runtime/test_pre_agent_carrier.py::TestPreAgentCarrierDBRoutingNoEnv`, `::TestPreAgentToSubagentStartRoundTrip` |
| 16 | Automatic continuation beyond guardian is allowed only within the active goal contract and autonomy budget | covered | `tests/runtime/test_goal_continuation.py::TestCheckContinuationBudget`; `tests/runtime/test_goal_contract_codec.py`; post-4/17: `tests/runtime/test_marker_compound_stage_persistence.py` (6 subprocess-driven integration tests, commit `1de81c0`) prove compound-stage guardian markers survive `ensure_schema` cleanup so guardian auto-continuation operates on a correctly-seated marker — a precondition for the autonomy-budget gate to be consulted at all; `tests/runtime/test_handoff_artifact_path_invariants.py` GS1 regex extension (commit `f42baec`, DEC-HANDOFF-INVARIANT-GS1-EXT-001) preserves lane-truth monotonicity across GS1 work items |

## Summary

- Total invariants declared in CUTOVER_PLAN: 16.
- Status breakdown: covered = 16, partial = 0, missing = 0.
- Every `covered` row cites at least one concrete test file. Many cite
  multiple test classes and / or multiple sibling files.
- Eight rows (#4, #6, #15, #16, and the GS1-reinforced invariants below)
  received updated or additional mechanical pins in the 2026-04-18
  global-soak stabilization session:
  - **GS1-A** (`d8e9096`): `tests/runtime/test_claudex_watchdog.py` pins
    `SNAPSHOT_AGE_OK` as sole freshness authority; stops false 'lagging'
    signals on active+waiting_for_codex runs.
  - **GS1-F-1** (`68b88c8`): `tests/hooks/test_subagent_start_identity.py`
    (7 tests) pins payload `agent_id` as sole SubagentStart identity
    authority (DEC-CLAUDEX-SA-IDENTITY-001).
  - **GS1-B-1** (`ea5e4a0`): `tests/runtime/test_claudex_bridge_up_broker_pid.py`
    pins broker PID atomic write at bridge-up (DEC-GS1-B-BROKER-PID-PERSIST-001).
  - **GS1-F-2** (`0038efe`): `tests/hooks/test_subagent_start_identity.py::TestMarkerSeatingReliability`
    (3 tests) pins 3-tier DB routing fallback when `CLAUDE_PROJECT_DIR`
    absent (DEC-CLAUDEX-SA-MARKER-RELIABILITY-001).
  - **GS1-F-3** (`bf08423`): `hooks/lib/runtime-bridge.sh::_resolve_policy_db()`
    unified resolver; `tests/hooks/test_runtime_bridge_resolver.py` (10 tests),
    extended `tests/runtime/test_pre_agent_carrier.py` (DEC-CLAUDEX-SA-UNIFIED-DB-ROUTING-001).
  - **GS1-F-4** (`1de81c0`): `runtime/schemas.py` derives `_MARKER_ACTIVE_ROLES`
    from `ACTIVE_STAGES ∪ {"guardian"}`; `tests/runtime/test_marker_compound_stage_persistence.py`
    (6 subprocess integration tests) prove compound-stage markers survive
    `ensure_schema` cleanup (DEC-CONV-002-AMEND-001).
  - **GS1-F-5** (`2127fe9`): `tests/runtime/test_marker_compound_stage_persistence.py::test_guardian_land_marker_grants_can_land_git_capability`
    locks guardian:land → CAN_LAND_GIT capability chain.
  - **Handoff sync** (`f42baec`): `tests/runtime/test_handoff_artifact_path_invariants.py`
    GS1 regex extension accepts `GS1-<letter>[-<n>]` scheme alongside
    existing `A<N>` series (DEC-HANDOFF-INVARIANT-GS1-EXT-001).

## Why this document exists

The cutover's own acceptance bar (CUTOVER_PLAN.md:1430) states:

> The cutover is not complete without mechanical checks.

This coverage matrix is the deliberate mechanical check that the invariant
list itself does not silently drift over time. Without this artifact (plus
its mechanical pin test), a future author could (a) introduce a new
invariant row in CUTOVER_PLAN without backing it with a test, (b) remove
an invariant from CUTOVER_PLAN without noticing the test surface is now
out of sync, or (c) silently drop a test file that this matrix cites and
let the prose cite become a broken promise. The mechanical pin
`tests/runtime/test_cutover_invariant_coverage_matrix.py` catches each of
these three failure modes.

## Authority discipline

This doc is a **derived projection**, not a parallel authority. It does
not re-declare any invariant, does not override any CUTOVER_PLAN prose,
does not introduce new enforcement logic, and does not gate any policy
decision. Its only runtime consumer is the mechanical pin test above,
which reads it as a static fixture to verify structural completeness.

If any cell in the table above is or becomes wrong (wrong test path,
missing invariant, stale status), the mechanical pin test fails with a
structured `file:line`-style diagnostic naming the offending row.
Correction must either update this doc (primary authority for *this
projection's* cell contents) or update the mechanical pin if the matrix
itself is being reorganized.

## Successor history

- 2026-04-17 (initial landing, bundle `d7db4ba`): `ClauDEX/CUTOVER_INVARIANT_COVERAGE_2026-04-17.md`.
  Backed by `tests/runtime/test_cutover_invariant_coverage_matrix.py`.
  Produced during cc-policy-who-remediation session. All 16 invariants covered
  as of the 30-file bundle committed to `origin/feat/claudex-cutover`.
- 2026-04-18 (GS1 stabilization track, HEAD `9762dc7`): this document.
  Refreshes rows #4, #6, #15, #16 with post-4/17 GS1 mechanical pins
  (GS1-A through GS1-F-5 + handoff sync). Supersedes the 2026-04-17 artifact.

When a future slice supersedes this artifact (e.g., `CUTOVER_INVARIANT_COVERAGE_2026-MM-DD.md`),
the successor should:

1. Copy the table forward, updating rows that changed.
2. Carry over the Successor History with a new dated entry at the top.
3. Mark this file as superseded to prevent drift.
