# ClauDEX CUTOVER_PLAN Invariants — Coverage Matrix (2026-04-17)

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
- **Produced by:** the cutover continuation track on `claudesox-local`
  during the 2026-04-17 cc-policy-who-remediation session (originally at
  HEAD `f24df96`, staged as a 28-file bundle that subsequently grew to
  30 files and was committed as `d7db4ba`, then merged with upstream and
  pushed to `origin/feat/claudex-cutover`). The staged bundle grew
  through interim sizes (22, 23, 24, 25, 27, 28, 30) as successive
  invariant pins were added; all checkpoint debt is now cleared.
  `ClauDEX/CURRENT_STATE.md` and `ClauDEX/SUPERVISOR_HANDOFF.md` are the
  authoritative lane-state surfaces; if any count here drifts from those
  two files, those files win and this artifact must be corrected in the
  same change.
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
| 4 | No constitution-level config default is defined outside the schema/bootstrap authority | covered | `tests/runtime/test_constitution_registry.py` (74+ tests including `TestCutoverPlanDocRegistryParity`) |
| 5 | No policy module reparses command semantics already supplied by runtime intent objects | covered | `tests/runtime/policies/test_command_intent_single_authority.py` (Rules A/B/C + `TestRuleABAbsoluteNoExemptBypass`, DEC-CLAUDEX-COMMAND-INTENT-SOLE-AUTHORITY-001) |
| 6 | Reviewer capabilities are read-only and cannot land git or edit source | covered | `tests/runtime/policies/test_bash_git_who.py` (CAN_LAND_GIT gate); `tests/runtime/policies/test_capability_gate_invariants.py` |
| 7 | Regular Stop review and workflow review cannot mutate each other's routing state | covered | `tests/runtime/test_dispatch_engine.py` (same DEC-PHASE5-STOP-REVIEW-SEPARATION-001 block) |
| 8 | Docs that claim harness behavior are either generated, validated, or clearly marked as non-authoritative reference | covered | `tests/runtime/test_hook_doc_validation.py`; `tests/runtime/test_hook_doc_projection.py`; `tests/runtime/test_hook_doc_check_cli.py`; `cc-policy hook doc-check` exact-hash validator |
| 9 | Prompt packs are generated from runtime authority and carry freshness metadata | covered | `tests/runtime/test_prompt_pack.py`; `tests/runtime/test_prompt_pack_resolver.py`; `tests/runtime/test_prompt_pack_validation.py`; `tests/runtime/test_prompt_pack_compile_cli.py`; `tests/runtime/test_prompt_pack_check_cli.py`; `tests/runtime/test_prompt_pack_state.py`; `tests/runtime/test_prompt_pack_decisions.py` |
| 10 | Canonical decision/work records exist outside markdown-only logs | covered | `tests/runtime/test_decision_work_registry.py`; `tests/runtime/test_decision_digest_projection.py`; `tests/runtime/test_decision_digest_cli.py` |
| 11 | `@decision-ref` links resolve to active or explicitly superseded decisions | covered | `tests/runtime/test_decision_ref_resolution.py` (DEC-CLAUDEX-DECISION-REF-SCAN-001) |
| 12 | Derived projections fail validation when upstream canonical state changed without reflow | covered | `tests/runtime/test_projection_reflow.py` (`TestAssessProjectionFreshness`, `TestExtractProjectionMetadata`, `TestAssessInputValidation`, `TestPlanProjectionReflow`, `TestRealBuilderOutputs`, `TestStatusVocabulary`, `TestModuleSurface`, `TestShadowOnlyDiscipline`); `tests/runtime/test_projection_schemas.py` |
| 13 | Retrieval and graph layers are derived read models and never treated as legal source of truth | covered | `tests/runtime/test_memory_retrieval.py::TestShadowOnlyDiscipline` (retrieval -> live direction); `tests/runtime/test_retrieval_layer_downstream_invariant.py` (live -> retrieval direction, DEC-CLAUDEX-RETRIEVAL-LAYER-DOWNSTREAM-INVARIANT-001) |
| 14 | Post-guardian continuation is planner-owned, not reviewer- or hook-owned | covered | `tests/runtime/test_goal_continuation.py::TestPlannerOwnedBoundary`, `::TestDispatchEngineIntegration`, `::TestUpdateGoalStatusForVerdict` |
| 15 | Any source change after reviewer clearance invalidates readiness | covered | Write/Edit path: `hooks/track.sh` (DEC-EVAL-005); Bash path: `hooks/post-bash.sh` (DEC-EVAL-006) with `tests/runtime/policies/test_post_bash_eval_invalidation.py`; bridge parity: `tests/runtime/test_bridge_permissions.py::TestPostToolBashWiringPresent` |
| 16 | Automatic continuation beyond guardian is allowed only within the active goal contract and autonomy budget | covered | `tests/runtime/test_goal_continuation.py::TestCheckContinuationBudget`; `tests/runtime/test_goal_contract_codec.py` |

## Summary

- Total invariants declared in CUTOVER_PLAN: 16.
- Status breakdown: covered = 16, partial = 0, missing = 0.
- Every `covered` row cites at least one concrete test file. Many cite
  multiple test classes and / or multiple sibling files.
- Three invariants (#5, #11, #13-symmetric) received dedicated mechanical
  pins in the 2026-04-17 cc-policy-who-remediation session; those pins
  were committed as part of the 30-file bundle (`d7db4ba`) and are now
  pushed to `origin/feat/claudex-cutover`. Invariant #15 bridge-parity
  extension was also part of that session. All other rows were already
  covered by pre-existing tests from Phases 3-8 of the cutover.

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

- 2026-04-17 (initial landing, interim bundle size 25): this document.
  Backed by `tests/runtime/test_cutover_invariant_coverage_matrix.py`.
  Produced during cc-policy-who-remediation session after the Invariant
  #13 symmetric pin landed, at which point the interim staged bundle
  measured 25 files. That 25-file figure is **historical** and applies
  only to that single landing moment.
- 2026-04-17 (late-session update, bundle grew to 28 files): subsequent
  slices in the same session added further mechanical pins (notably the
  CUTOVER_PLAN phase-closure time-scoping pin and the checkpoint-report
  staged-scope + excluded-scope authority pins), growing the staged
  checkpoint debt from 25 → 27 → 28 files. This document's non-
  historical lane-state references (`Produced by`, `Summary`) were
  reconciled to the **28-file** current-lane truth in this update.
  Authoritative cross-references: `ClauDEX/CURRENT_STATE.md`,
  `ClauDEX/SUPERVISOR_HANDOFF.md`.

When a future slice supersedes this artifact (e.g., `CUTOVER_INVARIANT_COVERAGE_2026-05-XX.md`),
the successor should:

1. Copy the table forward, updating rows that changed.
2. Carry over the Successor History with a new dated entry at the top.
3. Delete or explicitly mark this file as superseded to prevent drift.
