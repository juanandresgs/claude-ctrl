# ClauDEX

Status: seeded on 2026-04-07

This folder is the canonical cutover workspace for restarting this repository
around the ClauDEX architecture model.

Purpose:
- give the restart one grounding document instead of another drifting addendum
- define the target authority model before more implementation work lands
- keep cutover planning separate from the historical donor docs in the repo root

Authority rules:
- [CUTOVER_PLAN.md](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/ClauDEX/CUTOVER_PLAN.md) is the authoritative restart and cutover plan
- [CURRENT_STATE.md](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/ClauDEX/CURRENT_STATE.md) is the authoritative execution handoff and clean-start record
- [OVERNIGHT_RUNBOOK.md](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/ClauDEX/OVERNIGHT_RUNBOOK.md) is the operator runbook for the supervised migration profile
- [CONTROL_PLANE_TEST_CHECKLIST.md](/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/ClauDEX/CONTROL_PLANE_TEST_CHECKLIST.md) is the active test debt / reliability checklist for the main ClauDEX control path
- root-level plans and docs remain useful donor material, but they are not the
  cutover authority unless explicitly ported into the ClauDEX plan
- implementation work that claims to be part of the restart must map to a phase
  or decision in the cutover plan

Operating intent:
- preserve architecture by constraint, not by convention
- make one authority per operational fact explicit in code
- treat hook wiring, docs, and config surfaces as derived outputs that must not
  silently drift from the runtime authority

Current git reality:
- the ClauDEX buildout is currently local working-tree state on top of
  `fix/enforce-rca-13-git-shell-classifier`
- the braid-side portable bridge work was pushed separately upstream
- the next clean git move for ClauDEX is to checkpoint this work onto a
  dedicated hardFork branch such as `feat/claudex-cutover`
