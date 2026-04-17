# Phase 8 Slice 1 — Installed-Truth Legacy Deletion Inventory

**Status:** inventory only — **no deletions performed in this slice**.
**Produced:** 2026-04-13. **Corrected:** 2026-04-13 (see "Correction notice" below).

## Correction Notice (2026-04-13) — HISTORICAL (pre-Slice-10/11)

> **Time-scoping note (Slice 12 closeout, 2026-04-14):** the three
> points below record installed truth at Slice 1 inventory time. The
> tester-related present-tense wording ("is wired", "calls", "is still
> the validator", "is NOT a safe Phase 8 target") was correct then and
> is now historical — Slice 10 decommissioned the wiring and Slice 11
> retired the dead runtime code. Category A is **closed as
> completed**; see the Phase 8 closeout material later in this file.

The first revision of this inventory contained three installed-truth errors
flagged in Codex review (instruction `1776127576872-0034-cb6tuc`). They are
corrected below; the affected sections are rewritten, not patched.

1. **[At Slice 1 time] Category A was NOT a safe Phase 8 target while
   `check-tester.sh` was wired.** `settings.json:296-319` wired a
   `SubagentStop` matcher on role `tester` to
   `$HOME/.claude/hooks/check-tester.sh`, and that hook at
   `hooks/check-tester.sh:144` called `rt_completion_submit
   "$_CT_LEASE_ID" "$_CT_WF_ID" "tester" "$_CT_PAYLOAD"`.
   `ROLE_SCHEMAS["tester"]` (`runtime/core/completions.py:70-74`) was
   the validator for that payload. Removing the schema in Phase 8
   before unwiring the hook would have broken a live-wired path on
   the next tester SubagentStop. Category A was reclassified as a
   **Phase 8 follow-on removal bundle target** — see category section
   below.
   **(Slice 12 closeout, 2026-04-14):** Category A is now **CLOSED AS
   COMPLETED.** Slice 10 decommissioned the wiring, Slice 11 retired
   the dead runtime code and flipped invariants, and the Slice 11
   correction bundle cleaned the scenario/acceptance/test surface. The
   original "not safe" framing above is preserved as historical
   correction context.
2. **`runtime/core/proof.py` is NOT orphaned.** A correct grep
   (`from runtime.core.proof|from \.proof|import runtime\.core\.proof`) shows
   **5 importers**: `runtime/cli.py:52` (live CLI), plus
   `tests/runtime/test_statusline.py:52`, `test_statusline_truth.py:192,222`,
   `test_sidecars.py:44`, and `test_proof.py:26`. The earlier claim used a
   narrower grep that missed `import runtime.core.proof as proof_mod`.
   `proof.py` is not deletable without a CLI change.
3. **`hooks/log.sh` is NOT orphaned.** It is a shared logging library sourced
   by at least 14 hooks (`notify.sh`, `plan-validate.sh`, `pre-bash.sh`,
   `pre-write.sh`, `prompt-submit.sh`, `compact-preserve.sh`, `lint.sh`,
   `auto-review.sh`, `track.sh`, `check-tester.sh`, `post-task.sh`,
   `session-end.sh`, `plan-guard.sh`, `subagent-start.sh`). It is not wired
   directly in `settings.json` because it is a library, not a hook. Do not
   delete.

With these corrections, the revised recommended first deletion target for
Phase 8 Slice 2 is **`hooks/auto-review.sh` + its three scenario tests**.
See the updated "Recommended First Deletion Slice" section.
**Author context:** Phase 7 closed with `CUTOVER_PLAN.md` planned-area count
at zero (Slice 17 promoted `runtime/core/memory_retrieval.py` to concrete).
Phase 8 opens on installed truth: the goal of this artifact is to pin down
concrete, evidence-backed deletion candidates so subsequent Phase 8 slices can
each remove exactly one class of superseded authority as a bounded bundle.

## Scope & Non-Goals

**In scope**
- Survey of installed truth: hook wiring (`settings.json`), runtime/core
  modules, routing surfaces, constitution registry, prompt/projection/reflow,
  donor docs.
- Explicit listing of candidates grouped by operational fact, with file
  paths, line ranges, and the concrete authority that supersedes each one.
- A proposed first deletion slice (Phase 8 Slice 2) with exact files,
  functions, and existing pinning tests.

**Out of scope for this slice**
- No file deletions, no hook rewiring, no settings.json edits.
- No bridge/watchdog edits (`ClauDEX/bridge/**`, `scripts/claudex-*`,
  `.codex/**`).
- No new control-plane modules or new runtime authority.
- No changes to live behaviour. If a Phase 8 test is added at all, it must
  only pin an already-true invariant.

## Inspected Surfaces

> **Time-scoping note (Slice 12 closeout, 2026-04-14):** this table
> records installed truth as observed **at Slice 1 inventory time
> (2026-04-13, before Slice 10/11)**. All tester-era rows below were
> correct then and are now historical — Slice 10 decommissioned the
> wiring and Slice 11 retired the dead runtime code. See the Slice 10 /
> Slice 10 correction / Slice 11 / Slice 11 correction sections for
> current truth. Do not treat present-tense wording in this table as
> current installed state.

| Surface | Path | Notes (Slice 1 inventory time; pre-Slice-10/11) |
|---|---|---|
| Hook wiring | `settings.json` | `auto-review.sh` not wired (grep → no matches). `log.sh` not wired as a hook (it is sourced as a library by 14 other hooks). **[Pre-Slice-10] Tester matcher at lines 296-319 was LIVE**, invoking `check-tester.sh` on every tester SubagentStop. **(Removed in Slice 10.)** |
| Hook scripts | `hooks/*.sh` | 30+ scripts. `auto-review.sh` (36 KB) not wired anywhere in JSON, only referenced by its own scenario tests + one comment in `hooks/lib/hook-safety.sh:59`. `log.sh` is a shared logging library — actively sourced. `block-worktree-create.sh` anchors exactly one active `WorktreeCreate` manifest entry after Phase 8 Slice 3 (the former `PreToolUse:EnterWorktree` entry was removed; no deprecated entries remain). |
| Tester hook | `hooks/check-tester.sh` | **[Pre-Slice-10] LIVE producer** of `tester` completion payloads. `hooks/check-tester.sh:144` called `rt_completion_submit "$_CT_LEASE_ID" "$_CT_WF_ID" "tester" "$_CT_PAYLOAD"`. Payload shape `{EVAL_VERDICT, EVAL_TESTS_PASS, EVAL_NEXT_ROLE, EVAL_HEAD_SHA}` was validated by `ROLE_SCHEMAS["tester"]`. **(Hook file deleted in Slice 10; schema removed in Slice 11.)** |
| Hook docs | `hooks/HOOKS.md` | Installed truth: `hook doc-check` reports `status=ok`, `exact_match=true` against `hook_manifest`. The earlier "drift from wired reality" narrative was wrong — HOOKS.md is a derived projection and is already regenerated from the manifest. Category D was actually the deprecated-block-worktree manifest-status ambiguity, resolved in Phase 8 Slice 3. |
| Routing | `runtime/core/dispatch_engine.py` | **[Pre-Slice-11]** Live tester branch lines 318-324, orphan comment 410-411. **(Branch and `_known_types` entry removed in Slice 11.)** |
| Completion shape | `runtime/core/completions.py` | **[Pre-Slice-11]** `ROLE_SCHEMAS["tester"]` lines 70-74 — compat-only; tester no longer routes. **(Schema entry removed in Slice 11.)** |
| Shadow observer | `runtime/core/dispatch_shadow.py` | **[Pre-Slice-11]** Tester→reviewer collapse mappings at lines 80-82, 129-133, 177-181, 189-191. **(All removed in Slice 11; `compute_shadow_decision("tester", ...)` now returns `REASON_UNKNOWN_LIVE_ROLE`.)** |
| Constitution | `runtime/core/constitution_registry.py` | 24 concrete entries, planned set `()` post-Slice-17. |
| Proof state | `runtime/core/evaluation.py`, `runtime/core/proof.py` | `evaluation.py:8` states "proof_state retains zero enforcement effect". `proof.py` imported by `runtime/cli.py:52` (live) plus 4 tests. Not orphaned — deletion requires CLI surgery. |
| Dispatch (compat) | `runtime/core/dispatch.py` | `dispatch_queue` surface no longer in hot path. |
| Stage registry | `runtime/core/stage_registry.py` | Docstring confirms reviewer introduction / tester removal was the reason this module exists. |
| Donor docs | `docs/ARCHITECTURE.md`, `docs/DISPATCH.md`, `docs/PLAN_DISCIPLINE.md`, `implementation_plan.md`, `MASTER_PLAN.md` | Post-Slice-4: `docs/AGENT_HANDOFFS.md` and `docs/HANDOFF_2026-03-31.md` were deleted (zero live inbound references). Post-Slice-5: `docs/PHASE0_HOOK_AUTHORITY_RECOMMENDATIONS.md` was deleted after preservation audit confirmed all three recommendations + the 11-item HOOKS.md delta are canonically held in `MASTER_PLAN.md` INIT-PHASE0 (DEC-PHASE0-001/002/003, P0-H table at L10512). Post-Slice-6: `docs/HANDOFF_2026-04-05_SYSTEM_EVAL.md` was deleted after preservation audit confirmed North Star + 6 packets + retest set are preserved in INIT-CONV (L2631-3043, all 7 W-CONV waves); the `MASTER_PLAN.md:2645` handoff link was replaced with a concise historical note in the same bundle. `ARCHITECTURE.md`, `DISPATCH.md`, `PLAN_DISCIPLINE.md` remain live specs. |

## Deletion Categories

### Category A — Tester-Era Routing Compat — **COMPLETED (Slice 10 + Slice 11 + Slice 11 correction, 2026-04-13)**

**Status (closeout, Phase 8 Slice 12):** Category A is closed as
completed. The wiring was decommissioned in Slice 10 (Bundle 1), the
dead runtime code + invariant flip landed in Slice 11 (Bundle 2), and
the Slice 11 correction bundle
(`1776135766401-0049-lojhjs` / `1776137878959-0050-hkoa80`) cleaned
up scenario/acceptance/test-surface residue and added the CLI-help,
executable-surface, and `PAYLOAD_CONTRACT.md` pins. See the
"Slice 10", "Slice 10 correction", "Slice 11", and "Slice 11 correction"
sections below for evidence.

**Status correction (Phase 8 Slice 9, 2026-04-13):** Earlier inventory
revisions labelled these targets "Phase 9." `ClauDEX/CUTOVER_PLAN.md:1411-1421`
Phase 8 scope explicitly includes "remove tester-era routing authority"
— there is no Phase 9 in the cutover plan. Tester removal was **in-scope
for Phase 8** and landed as the Slice 10 + Slice 11 bundle (completed
2026-04-13). References to "Phase 9" throughout this document are
historical local follow-on-bucket shorthand, not an official cutover
phase.

**[Slice 1-era analysis, preserved as historical audit context —
superseded by Slice 10 + Slice 11; see closeout status above.]**

At Slice 1 inventory time these paths were NOT pure compat.
`hooks/check-tester.sh` was still wired in `settings.json:286-319` as
the `SubagentStop` handler for role `tester`, and at line 144 it
called `rt_completion_submit "$_CT_LEASE_ID" "$_CT_WF_ID" "tester"
"$_CT_PAYLOAD"`. Any tester SubagentStop fired that hook, which
validated against `ROLE_SCHEMAS["tester"]`. Removing the schema or
the dispatch branch while the hook was wired would have corrupted
the still-reachable payload validation. The Slice 9 plan (below)
therefore scoped this removal as a coordinated Bundle 1 + Bundle 2
execution, which landed in Slices 10 + 11 + the Slice 11 correction.

**[Slice 1-era]** `determine_next_role("tester", ...)` returning
`None` described only the routing decision *after* schema validation
succeeded; at that time it did not prove the schema itself was
unused. After Slice 11 the schema entry itself is gone.

**Follow-on-bundle targets** (original Slice 1 enumeration, **all
removed by Slices 10 + 11 + correction — table below is historical
record of pre-execution dependency analysis**):

| Target | Removal dependency (pre-Slice-10/11 analysis) | Status |
|---|---|---|
| `runtime/core/completions.py:70-74` — `ROLE_SCHEMAS["tester"]` | At Slice 1 time, validated the payload produced by `check-tester.sh:144`; could only be removed after `check-tester.sh` was unwired. | **Removed in Slice 11.** |
| `runtime/core/dispatch_engine.py:318-324` — `elif normalised == "tester":` branch | At Slice 1 time, invoked on every tester SubagentStop via `post-task.sh` → `cli.py`; could only be removed after tester hook was unwired. | **Removed in Slice 11.** |
| `runtime/core/dispatch_engine.py:410-411` — comment line documenting `tester needs_changes` transition | Removed with the dispatch branch. | **Removed in Slice 11.** |
| `runtime/core/dispatch_shadow.py:80-82` — `"tester"` in `KNOWN_LIVE_ROLES` | At Slice 1 time, shadow observer still received tester stop payloads via the live path. | **Removed in Slice 11.** |
| `runtime/core/dispatch_shadow.py:129-133` — tester→reviewer mapper branch | At Slice 1 time, still reachable. | **Removed in Slice 11.** |
| `runtime/core/dispatch_shadow.py:177-181` — tester→reviewer destination branch | At Slice 1 time, still reachable. | **Removed in Slice 11.** |
| `runtime/core/dispatch_shadow.py:189-191` — `tester / ready_for_guardian → GUARDIAN_LAND` | At Slice 1 time, still reachable. | **Removed in Slice 11.** |

**Prerequisite bundle** (must land together before any of the above
targets are deleted — see Slice 9 "Bundle split" for the concrete
file list):
- Unwire `settings.json:286-319` tester matcher.
- Decommission `hooks/check-tester.sh`.
- Remove tester entries from `runtime/core/hook_manifest.py` (lines
  409-423, both `SubagentStop:tester` rows).
- Remove `hooks/subagent-start.sh:60` tester-role allowlist entry and
  `:277-292` tester context-inject branch.
- Retire `agents/tester.md`.

**Slice 1 installed-truth correction (Slice 9):** The Slice 1 prerequisite
list cited `hooks/pre-agent.sh:277-292` as containing a tester dispatch
block. `hooks/pre-agent.sh` is only 109 lines and contains zero `tester`
references; the tester context-inject block lives in
`hooks/subagent-start.sh:60,277-292`, not `pre-agent.sh`. The prerequisite
list above is the corrected truth.

### Category B — Orphaned Hooks

| Target | Status | Evidence |
|---|---|---|
| `hooks/auto-review.sh` (~36 KB, 842 lines) | **DELETED in Phase 8 Slice 2** | Historical evidence: `grep -l auto-review.sh **/*.json` → no files found. Decommissioned by commit `c7a3109` per DEC-PHASE0-003 (`MASTER_PLAN.md:10354`, "It's already not running"). The three scenario tests were subject-under-test and the one `hooks/lib/hook-safety.sh:59` comment was stripped in the same bundle. |
| `hooks/log.sh` (~3.8 KB) | **NOT ORPHANED — DO NOT DELETE** | Previous inventory was wrong. `log.sh` is a shared logging library sourced by 14 hooks: `notify.sh`, `plan-validate.sh`, `pre-bash.sh`, `pre-write.sh`, `prompt-submit.sh`, `compact-preserve.sh`, `lint.sh`, `auto-review.sh`, `track.sh`, `check-tester.sh`, `post-task.sh`, `session-end.sh`, `plan-guard.sh`, `subagent-start.sh`. Not wired in `settings.json` because it is a library, not a hook entry point. |

`auto-review.sh` was the cleanest Phase 8 target: unwired, only referenced
by its own tests plus one comment, with written authority in
`MASTER_PLAN.md` DEC-PHASE0-003 (line 10354) to decommission. Executed in
Phase 8 Slice 2.

### Category C — Retained Legacy Storage / Compat Surfaces (Phase 8 Slice 8 audit; bundle 1 retired 2026-04-17; bundle 2 retired 2026-04-17)

Phase 8 Slice 8 (2026-04-13) closed the importer/read/write audit that
Slice 1 flagged as "pending." Category C was closed as "retained, deferred"
for Phase 8. Post-Phase-8 **Category C bundle 1** (2026-04-17) retired the
`proof_state` surface under `DEC-CATEGORY-C-PROOF-RETIRE-001`.
Post-Phase-8 **Category C bundle 2** (2026-04-17) retires the
`dispatch_queue` / `dispatch_cycles` surfaces and the legacy
`dispatch enqueue/next/start/complete/cycle-*` CLI actions under
`DEC-CATEGORY-C-DISPATCH-RETIRE-001`. **Category C is now fully closed.**
The per-file evidence table below records the current disposition of each
target; the Slice 8 narrative that follows is preserved as the historical
audit snapshot.

| Target | Disposition | Notes |
|---|---|---|
| `runtime/core/proof.py` + `proof_state` table | **Retired post-Phase-8 under Category C bundle 1 (DEC-CATEGORY-C-PROOF-RETIRE-001, 2026-04-17).** | Module deleted; `PROOF_STATE_DDL` and its `ALL_DDL` entry removed from `runtime/schemas.py`; `proof get/set/list` CLI retired from `runtime/cli.py` (import + subparser + `_handle_proof` + domain-dispatch branch); `SELECT … FROM proof_state` + `self.proof_states` + `proof_count` report key + `stale_proofs` health branch removed from `sidecars/observatory/observe.py`; retained-storage comments in `runtime/core/statusline.py` / `runtime/core/evaluation.py` / `hooks/check-guardian.sh` / `hooks/session-init.sh` rewritten to retirement pointers; `tests/runtime/test_proof.py` deleted; surgical edits applied to `tests/runtime/test_statusline.py` / `tests/runtime/test_statusline_truth.py` / `tests/runtime/test_sidecars.py` (removed `proof_mod` imports, proof fixture inserts, and proof-specific assertions; rewrote compound tests to exercise eval-state surfaces only); new invariant pins in `tests/runtime/test_phase8_category_c_proof_retired.py`; extended pins in `tests/runtime/test_phase8_deletions.py`. Non-destructive posture: the DDL is gone so new DBs never create the table; existing DBs retain the inert row data until a forensic operator drops it manually (no runtime `DROP TABLE` issued). |
| `runtime/core/dispatch.py` — `dispatch_queue` + `dispatch_cycles` surfaces | **Retired post-Phase-8 under Category C bundle 2 (DEC-CATEGORY-C-DISPATCH-RETIRE-001, 2026-04-17).** | Module `runtime/core/dispatch.py` deleted. `DISPATCH_QUEUE_DDL`, `DISPATCH_CYCLES_DDL`, their `ALL_DDL` entries, `DISPATCH_QUEUE_STATUSES`, and `DISPATCH_CYCLE_STATUSES` removed from `runtime/schemas.py`. Six legacy actions retired from `runtime/cli.py` (`enqueue`, `next`, `start`, `complete`, `cycle-start`, `cycle-current`); the `dispatch` CLI domain itself stays live for `process-stop`, `agent-start`, `agent-stop`, `agent-prompt`, `attempt-issue`, `attempt-claim`, `attempt-expire-stale` (owned by `dispatch_engine` / `dispatch_attempts`). `SELECT … FROM dispatch_queue` + `dispatch_backlog` health branch removed from `sidecars/observatory/observe.py`; `self.dispatch` kept as an always-empty list so the `pending_dispatches` report key stays present with value `0` (schema stability). `SELECT … FROM dispatch_cycles` removed from `runtime/core/statusline.py`; the `dispatch_cycle_id` and `dispatch_initiative` snapshot keys remain with `None` defaults (schema stability). `tests/runtime/test_dispatch.py` deleted; surgical edits applied to `tests/runtime/test_statusline.py` and `tests/runtime/test_sidecars.py`; new invariant pins in `tests/runtime/test_phase8_category_c_dispatch_retired.py`; extended pins in `tests/runtime/test_phase8_deletions.py`. Non-destructive posture: no runtime `DROP TABLE`; existing DBs retain inert row data. Unrelated dispatch-family modules (`dispatch_engine.py`, `dispatch_shadow.py`, `dispatch_attempts.py`, `dispatch_hook.py`) are unaffected — they never imported `runtime.core.dispatch`. |

**Future retirement bundle scope:** none remaining. Category C is
**fully closed** with both bundles retired.

### Category D — Hook Wiring Status Drift (RESOLVED in Phase 8 Slice 3)

Earlier revisions claimed `hooks/HOOKS.md` itself was drifting from the
manifest. Installed truth (`hook doc-check --exact_match=true`) showed that
claim was wrong — HOOKS.md was already being regenerated from the manifest.

The real remaining issue was the `hooks/block-worktree-create.sh` wiring
status: the manifest flagged both `WorktreeCreate` and
`PreToolUse:EnterWorktree` entries as `STATUS_DEPRECATED` with rationale
"CUTOVER_PLAN H8: speculative", producing `validate-settings:
ok_with_deprecated`. That is an ambiguous state — either the hook is live
and should be `ACTIVE`, or it is obsolete and should be removed.

**Phase 8 Slice 3 outcome (2026-04-13): split resolution per MASTER_PLAN
DEC-PHASE0-001 / DEC-PHASE0-002:**

| Entry | Outcome | Rationale |
|---|---|---|
| `WorktreeCreate` → `hooks/block-worktree-create.sh` | **Un-deprecated (→ ACTIVE)** | Verified-live per DEC-PHASE0-001 (documented Claude Code event); anchors the fail-closed worktree-safety adapter per DEC-GUARD-WT-009. |
| `PreToolUse:EnterWorktree` → `hooks/block-worktree-create.sh` | **Removed from settings.json + manifest** | Per DEC-PHASE0-002: `EnterWorktree` is not in the documented event list and the JSONL capture shows zero events matching it. |

Post-slice state: `validate-settings` returns `status=ok` (not
`ok_with_deprecated`) with `deprecated_still_wired=[]`.

### Category E — Donor Docs to Consolidate

| Path | Disposition |
|---|---|
| `docs/PHASE0_HOOK_AUTHORITY_RECOMMENDATIONS.md` | **Deleted in Phase 8 Slice 5.** Preservation audit confirmed all three recommendations and the 11-item HOOKS.md delta are canonically preserved in `MASTER_PLAN.md` INIT-PHASE0 (DEC-PHASE0-001/002/003 and the delta table at L10512-10530). The donor doc already self-declared as non-normative (line 6). |
| `docs/AGENT_HANDOFFS.md` | **Deleted in Phase 8 Slice 4.** Audit showed zero live inbound references (only self-references at lines 68, 80 in its own body + historical session-forensics logs). |
| `docs/HANDOFF_2026-03-31.md` | **Deleted in Phase 8 Slice 4.** Audit showed zero live inbound references anywhere outside frozen `ClauDEX/session-forensics/` archives. |
| `docs/HANDOFF_2026-04-05_SYSTEM_EVAL.md` | **Deleted in Phase 8 Slice 6.** Preservation audit confirmed the North Star, 6 execution packets, and required retest set are canonically preserved in `MASTER_PLAN.md` INIT-CONV (L2631-3043) across W-CONV-1 through W-CONV-7. INIT-CONV is marked `complete (all 6 waves landed, 2026-04-05/06)`. The `MASTER_PLAN.md:2645` **Handoff:** link was replaced with a historical note in the same bundle. |
| `implementation_plan.md` | **Retained — not a Phase 8 deletion target.** Reclassified in Phase 8 Slice 7 as constitution-level per installed truth: (a) `AGENTS.md:34` names it the successor implementation spec ("Treat `implementation_plan.md` as the successor implementation spec"); (b) `runtime/core/constitution_registry.py:227-229` registers it as a concrete constitution entry; (c) `tests/runtime/test_constitution_registry.py:73,139` asserts that registry entry; (d) `ClauDEX/CUTOVER_PLAN.md:1465` lists it under "Constitution-Level Files". The "overlaps with MASTER_PLAN.md — merge or retire" framing from Slice 1 was the wrong classification. |
| `docs/ARCHITECTURE.md`, `docs/DISPATCH.md`, `docs/PLAN_DISCIPLINE.md` | **Keep.** Live specs referenced by CLAUDE.md-style discipline. Not deletion candidates. |

## Recommended First Deletion Slice (Phase 8 Slice 2) — COMPLETED 2026-04-13

**Status:** **DONE.** Landed under Phase 8 Slice 2 on 2026-04-13. See
`ClauDEX/CURRENT_STATE.md` "Phase 8 Slice 2" section for evidence. All 4
deletions applied, `hooks/lib/hook-safety.sh:58-59` comment stripped,
`tests/runtime/test_phase8_deletions.py` pins green (7 passed), constitution
remains healthy (concrete_count=24, planned_count=0).

The original recommendation (below) is preserved for audit:

**Target:** `hooks/auto-review.sh` + its three scenario tests.

**Rationale**
- Genuinely unwired: `grep -l auto-review.sh **/*.json` returns zero files.
  No `settings.json` entry and no runtime `bash`/`exec` caller.
- Written authority to decommission: `MASTER_PLAN.md` DEC-PHASE0-003 (line
  10354) and P0-C explicitly say delete the hook and its three scenario
  tests. Commit `c7a3109` already removed the hook from live wiring.
- Bounded, mechanically-verifiable bundle — exactly 4 files deleted, one
  comment in `hook-safety.sh` stripped, plus `hooks/HOOKS.md` sweep and a
  handful of MASTER_PLAN breadcrumbs that describe historical work.
- Zero live behaviour change: nothing invokes the hook today.

**Files to touch in Slice 2**

Deletions (4 files):
- `hooks/auto-review.sh`
- `tests/scenarios/test-auto-review.sh`
- `tests/scenarios/test-auto-review-heredoc.sh`
- `tests/scenarios/test-auto-review-quoted-pipes.sh`

Edits (strip references):
- `hooks/lib/hook-safety.sh:59` — comment mentions `auto-review.sh`; trim.
- `hooks/HOOKS.md` — remove any remaining `auto-review` section/cross-links
  (if still present after earlier cleanups).
- `MASTER_PLAN.md` — mark the `INIT-TESTGAP` section as completed/retired
  (the section's whole premise is protecting `auto-review.sh`); leave the
  historical decision log intact.

Invariants to pin after deletion (Slice 2 bundle):
- `test ! -f hooks/auto-review.sh`
- `test ! -f tests/scenarios/test-auto-review.sh && test ! -f tests/scenarios/test-auto-review-heredoc.sh && test ! -f tests/scenarios/test-auto-review-quoted-pipes.sh`
- `grep -n "auto-review" hooks/HOOKS.md` returns zero hits.

Docs to update in the same bundle:
- `ClauDEX/CUTOVER_PLAN.md` (record Phase 8 Slice 2 completion).
- `ClauDEX/CURRENT_STATE.md` (append slice summary).

## Phase 8 Slice 4 — Handoff-Doc Deletion Audit — COMPLETED 2026-04-13

**Status:** **DONE.** Landed under Phase 8 Slice 4 on 2026-04-13.

**Scope:** Category E handoff artifacts only. Deleted files proven
unreferenced by live authority via inbound-link audit. `ARCHITECTURE.md`,
`DISPATCH.md`, `PLAN_DISCIPLINE.md`, `implementation_plan.md`, and
`MASTER_PLAN.md` were intentionally not touched in Slice 4.
`docs/PHASE0_HOOK_AUTHORITY_RECOMMENDATIONS.md` was also left for Slice 4
and subsequently deleted in Phase 8 Slice 5.

**Audit (`rg` against the three candidate names, excluding frozen
`ClauDEX/session-forensics/` archives):**

- `docs/AGENT_HANDOFFS.md` → only self-references at its own lines 68 and
  80 + inventory/CURRENT_STATE tracking rows. No inbound live reference
  from any runtime, hook, test, config, or top-level authority doc.
  **Safe to delete.**
- `docs/HANDOFF_2026-03-31.md` → zero inbound references from any live
  surface. Only hits in `ClauDEX/session-forensics/` (historical session
  captures, not live authority). **Safe to delete.**
- `docs/HANDOFF_2026-04-05_SYSTEM_EVAL.md` → one live inbound reference at
  `MASTER_PLAN.md:2645` (INIT-CONV handoff citation). **Retained at
  Slice 4**; subsequently retired in Phase 8 Slice 6 after preservation
  audit (see Slice 6 section below).

**Deletions (2 files):**
- `docs/AGENT_HANDOFFS.md`
- `docs/HANDOFF_2026-03-31.md`

**Test pins added to `tests/runtime/test_phase8_deletions.py`:**
- `test_phase8_slice4_handoff_is_deleted` (2 parametrized cases — the two
  deleted handoff basenames).
- `test_phase8_slice4_surface_has_no_deleted_handoff_reference` (9
  parametrized cases covering `settings.json`, `MASTER_PLAN.md`,
  `CLAUDE.md`, `AGENTS.md`, `implementation_plan.md`,
  `docs/ARCHITECTURE.md`, `docs/DISPATCH.md`, `docs/PLAN_DISCIPLINE.md`,
  `hooks/HOOKS.md`). Historical `ClauDEX/session-forensics/` archives are
  intentionally excluded because they are frozen session captures.

Existing Slice 2 auto-review pins are retained and still green.

## Phase 8 Slice 5 — PHASE0 Donor-Doc Retirement — COMPLETED 2026-04-13

**Status:** **DONE.** Landed under Phase 8 Slice 5 on 2026-04-13.

**Scope:** Retire `docs/PHASE0_HOOK_AUTHORITY_RECOMMENDATIONS.md` after
proving its three recommendations and 11-item HOOKS.md delta are
canonically preserved in `MASTER_PLAN.md` INIT-PHASE0.

**Preservation audit (donor content → MASTER_PLAN location):**

| Donor doc section | MASTER_PLAN.md preservation |
|---|---|
| Intro: "MASTER_PLAN.md INIT-PHASE0 is canonical" (line 6) | Self-declared non-normative |
| Rec 1 — auto-review decommission + 4-point rationale | DEC-PHASE0-003 (L10354) + P0-C work item |
| Rec 2a — WorktreeCreate KEEP | DEC-PHASE0-001 (L10310) |
| Rec 2b — EnterWorktree REMOVE | DEC-PHASE0-002 (L10331) |
| Rec 3 — HOOKS.md reduce-scope + rejected branches | P0-H narrative (L10421) |
| 11-item HOOKS.md ↔ official docs delta | Full table (L10512-10530), identical rows |
| Memory cross-refs (drift, verify-docs, schema, guardian) | Home MEMORY.md index entries still exist |
| Commit SHA c7a3109 + dispatch-debug.jsonl references | git log + live repo files still authoritative |

**Audit PASSED.** All substantive content preserved; donor doc self-
identified as non-normative convenience copy.

**Deletion:** `docs/PHASE0_HOOK_AUTHORITY_RECOMMENDATIONS.md`.

**Test pins added to `tests/runtime/test_phase8_deletions.py`:**
- `test_phase8_slice5_phase0_doc_is_deleted` (1 case — the deleted donor
  doc stays absent).
- `test_phase8_slice5_surface_has_no_phase0_doc_reference` (9
  parametrized cases covering the same live-authority surface set as
  Slice 4: `settings.json`, `MASTER_PLAN.md`, `CLAUDE.md`, `AGENTS.md`,
  `implementation_plan.md`, `docs/ARCHITECTURE.md`, `docs/DISPATCH.md`,
  `docs/PLAN_DISCIPLINE.md`, `hooks/HOOKS.md`). Phase 8 tracking docs
  under `ClauDEX/` are intentionally excluded so historical-context
  citations of the deleted doc name remain permitted there. The donor
  doc was never referenced from `MASTER_PLAN.md` or `implementation_plan.md`
  in the first place (pre-audit showed 0 matches in those files).

**Live-surface reference updates in same bundle:**
- `ClauDEX/CUTOVER_PLAN.md:1497` — removed the donor-surface line.
- `ClauDEX/PHASE8_DELETION_INVENTORY.md` — Category B evidence,
  Slice-2 rationale, Category E table, Slice-4 "not touched" clause,
  and Inspected Surfaces donor-docs row all updated to cite
  `MASTER_PLAN.md` DEC-PHASE0-003 instead of the deleted doc.
- `tests/runtime/test_phase8_deletions.py:15` — Slice-2 docstring
  citation updated to `MASTER_PLAN.md` DEC-PHASE0-003.

**Not touched:** `MASTER_PLAN.md` (no changes required — all content
already preserved); `implementation_plan.md`; `docs/HANDOFF_2026-04-05_SYSTEM_EVAL.md`
(left for Slice 6 and deleted there); live specs (`docs/ARCHITECTURE.md`,
`docs/DISPATCH.md`, `docs/PLAN_DISCIPLINE.md`); runtime, hooks, settings,
manifest, prompt-pack, bridge code.

## Phase 8 Slice 6 — INIT-CONV Handoff-Doc Retirement — COMPLETED 2026-04-13

**Status:** **DONE.** Landed under Phase 8 Slice 6 on 2026-04-13.

**Scope:** Retire `docs/HANDOFF_2026-04-05_SYSTEM_EVAL.md` after proving
its content is canonically preserved in `MASTER_PLAN.md` INIT-CONV.

**Preservation audit (handoff section → MASTER_PLAN location):**

| Handoff section | MASTER_PLAN.md preservation |
|---|---|
| North Star (6 canonical authorities) | INIT-CONV L2646-2649 — identical bullets |
| Current Truth (True + Not-Yet-True) | Problem/Evidence L2635-2644 + per-wave narratives |
| Corrections (5 items) | Covered in W-CONV-1/2/3 problem/evidence |
| Priority Order (6 steps) | Dependency graph L2660-2674 (same ordering) |
| Packet 1 — Path Identity | W-CONV-1 @ L2697 (complete, DEC-CONV-001) |
| Packet 2 — Marker Authority | W-CONV-2 @ L2765 |
| Packet 3 — Workflow Identity | W-CONV-3 @ L2819 |
| Packet 4 — Readiness Surface | W-CONV-4 @ L2904 |
| Packet 5 — Completion Contract | W-CONV-5 @ L2940 |
| Packet 6 — Dead Surface Deletion | W-CONV-6 @ L2998 |
| (bonus) Orch Trusts Completion | W-CONV-7 @ L3043 |
| Suggested Role Flow | Canonical flow in CLAUDE.md dispatch rules |
| Required Retest Set | L2682-2689 — identical command list |
| Full convergence retest | L2693-2694 — identical |
| Guidance For Claude Code | Sacred Practices + What Matters in CLAUDE.md |
| Bottom Line | Problem/North Star already state this |

**Audit PASSED.** INIT-CONV L2633 marks the whole initiative
`complete (all 6 waves landed, 2026-04-05/06)`, confirming the handoff's
purpose was fulfilled.

**Deletion:** `docs/HANDOFF_2026-04-05_SYSTEM_EVAL.md`.

**MASTER_PLAN.md edit (minimal, docs-only):**
- L2645 `**Handoff:** docs/HANDOFF_2026-04-05_SYSTEM_EVAL.md` replaced
  with `**Handoff:** source handoff retired in Phase 8 Slice 6
  (2026-04-13); conclusions, corrections, and the 6-packet priority
  order are preserved in this INIT-CONV section and W-CONV-1 through
  W-CONV-7 below.`

**Test pins added to `tests/runtime/test_phase8_deletions.py`:**
- `test_phase8_slice6_handoff_is_deleted` (1 case — the retired handoff
  stays absent).
- `test_phase8_slice6_surface_has_no_handoff_reference` (9 parametrized
  cases covering the same live-authority surface set as Slice 4/5:
  `settings.json`, `MASTER_PLAN.md`, `CLAUDE.md`, `AGENTS.md`,
  `implementation_plan.md`, `docs/ARCHITECTURE.md`, `docs/DISPATCH.md`,
  `docs/PLAN_DISCIPLINE.md`, `hooks/HOOKS.md`). `ClauDEX/` tracking docs
  excluded so historical-context citations remain permitted. The pin on
  `MASTER_PLAN.md` guards against the dead link re-appearing.

**Slice 4 pin cleanup:** The Slice 4 docstring wording that described
this handoff as "intentionally kept" was updated to reflect Slice 6's
subsequent deletion.

**Not touched:** `implementation_plan.md`; live specs
(`docs/ARCHITECTURE.md`, `docs/DISPATCH.md`, `docs/PLAN_DISCIPLINE.md`);
runtime, hooks, settings, manifest, prompt-pack, bridge code.

**Do not attempt these as first targets**
- **Category A (tester routing compat):** live-wired via
  `settings.json:286-319` → `check-tester.sh:144` → `ROLE_SCHEMAS["tester"]`.
  Scope for a Phase 8 follow-on removal bundle (CUTOVER_PLAN.md:1418
  explicitly lists tester-era routing removal as Phase 8 scope). Plan
  captured in Slice 9 below.
- **`runtime/core/proof.py`:** imported by `runtime/cli.py:52`; not a
  single-file deletion. Could be handled in a later Phase 8 slice only after
  a CLI import audit and statusline-test rework.
- **`hooks/log.sh`:** sourced by 14 live hooks; it is a logging library, not
  a hook entry point. Leave as-is.

## Already-True Invariants (Candidate Pins, Slice 1-Eligible)

Only pin if the pin is mechanically derivable today; do NOT add assertions
that would require live behaviour change. Candidates:

1. `"tester" not in completions.ROLE_SCHEMAS` — **false today** (live
   producer); pin after the Phase 8 follow-on tester-hook decommission
   (Slice 9 plan).
2. `dispatch_engine.determine_next_role("tester", ...)` returns `None` —
   **true today**, but the branch is live. Candidate pin for the
   Phase 8 follow-on removal bundle, not the current inventory slice.
3. No hook entry in `settings.json` points to a missing file — **true
   today**. Strongest candidate for any Slice 1 pin; deferred per
   instruction ("pins optional").
4. `hooks/auto-review.sh` is not referenced in any `.json` under the repo
   root — **true today**. Will become "file does not exist" after Slice 2.

Per the instruction ("Add narrow mechanical tests only if you find an
obvious already-true invariant"), no tests are added in this slice. The
candidates above are recorded so the next slice can land them alongside the
deletions they protect.

## Phase 8 Slice 7 — Category E Closure / Reclassification — COMPLETED 2026-04-13

**Status:** **DONE.** Landed under Phase 8 Slice 7 on 2026-04-13.

**Scope:** Docs-only classification cleanup. No file deletions, no runtime
or hook changes. Closes Category E by pinning the correct classification
of `implementation_plan.md` and removing stale "next Phase 8 candidate"
language that still pointed at it.

**Premise correction:** Slice 1's Category E table entry for
`implementation_plan.md` read "Overlaps with `MASTER_PLAN.md`. Merge or
retire." That framing was wrong on installed truth. The installed
authorities treat it as a constitution-level successor implementation
spec, not a donor doc awaiting merge:

| Installed-truth surface | Evidence |
|---|---|
| `AGENTS.md:34` | "Treat `implementation_plan.md` as the successor implementation spec." |
| `runtime/core/constitution_registry.py:227-229` | `name="implementation_plan.md"`, `path="implementation_plan.md"` — concrete (not planned) registry entry. |
| `tests/runtime/test_constitution_registry.py:73,139` | Two assertions list `implementation_plan.md` as part of the concrete constitution surface set. |
| `ClauDEX/CUTOVER_PLAN.md:1465` | Listed under "Constitution-Level Files" ("require explicit architecture-scoped plan coverage, decision annotation where relevant, and invariant test updates"). |

**Outcome:**
- Category E table in this inventory reclassifies `implementation_plan.md`
  as **Retained — not a Phase 8 deletion target** with the four citations
  above.
- `ClauDEX/CURRENT_STATE.md` "Next Phase 8 candidate" wordings (end of
  Slice 5 and Slice 6 sections) that pointed at the `implementation_plan.md`
  ↔ `MASTER_PLAN.md` overlap are removed. Header bumped to reflect
  Slice 7 completion.
- Category E is now closed: all Slice-4/5/6 deletions stand, and the only
  remaining Category E file is correctly classified as retained
  constitution material.

**Not touched:**
- `implementation_plan.md` itself (preserved as-is — constitution-level
  per four independent installed-truth surfaces).
- `MASTER_PLAN.md` (no handoff link or Category E wording to repair).
- `ClauDEX/CUTOVER_PLAN.md` lines 1465 and 1495: line 1465 correctly
  classifies `implementation_plan.md` as constitution-level and must not
  be weakened; line 1495 lists it under "Donor Surfaces and Historical
  Inputs" with the softer framing "may be harvested, but the restart is
  grounded here" — this does not directly imply Phase 8 merge/retire,
  so per Codex instruction it is left as-is.
- Runtime, hooks, settings, manifest, prompt-pack, bridge code.
- `tests/runtime/test_phase8_deletions.py` (no new pins — Slice 7 is
  reclassification, not deletion; there is nothing new absent to pin).

## Phase 8 Slice 8 — Category C Installed-Truth Audit — COMPLETED 2026-04-13

**Status:** **DONE.** Landed under Phase 8 Slice 8 on 2026-04-13.

**Scope:** Audit only. Importer/read/write evidence for Category C
surfaces (`runtime/core/proof.py` + `proof_state`, `runtime/core/dispatch.py`
+ `dispatch_queue` + `dispatch_cycles`), starting from installed truth.
No runtime, hook, settings, manifest, prompt-pack, or bridge code
touched. No schema or test changes. Docs-only reclassification of the
Category C row in this inventory + `ClauDEX/CURRENT_STATE.md`.

**Importer audit (non-tracking surfaces only):**

| Symbol | Live importer / reader / writer | File:line |
|---|---|---|
| `runtime.core.proof as proof_mod` | CLI live import | `runtime/cli.py:52` |
| `proof_mod.get` / `set_status` / `list_all` | CLI command handler | `runtime/cli.py:161,168,172` (`proof get/set/list`) |
| `proof_state` | Schema DDL (`CREATE TABLE IF NOT EXISTS`) | `runtime/schemas.py:24` |
| `proof_state` | Observatory SELECT (read-only sidecar) | `sidecars/observatory/observe.py:117-118` |
| `proof_state` | Retained-storage comments (zero enforcement effect) | `runtime/core/statusline.py:9,33,126`, `runtime/core/evaluation.py:8,17` |
| `proof_state` | Hook comments marking it superseded (no writes) | `hooks/check-guardian.sh:232`, `hooks/session-init.sh:114`, `hooks/subagent-start.sh:279` |
| `runtime.core.dispatch as dispatch_mod` | CLI live import | `runtime/cli.py:35` |
| `dispatch_mod.enqueue` / `next_pending` / `start` / `complete` / `start_cycle` / `current_cycle` | CLI command handler | `runtime/cli.py:1541-1572` (`dispatch enqueue/next/start/complete/cycle-start/cycle-current`) |
| `dispatch_queue` | Schema DDL | `runtime/schemas.py:64` |
| `dispatch_cycles` | Schema DDL | `runtime/schemas.py:76` |
| `dispatch_queue` | Removed from hot routing path (DEC-WS6-001) | `runtime/core/statusline.py:38-47` (narrative, not a read) |
| `dispatch_cycles` | **Still read** for `dispatch_cycle_id` | `runtime/core/statusline.py:243` |
| `dispatch_queue` | Observatory SELECT pending rows | `sidecars/observatory/observe.py:131` |

Tests that observe Category C surfaces (retained as storage/compat
fixtures, not rewired in this slice): `tests/runtime/test_proof.py`,
`tests/runtime/test_statusline.py`, `tests/runtime/test_statusline_truth.py`,
`tests/runtime/test_sidecars.py`, `tests/runtime/test_dispatch.py`.

Excluded from audit per instruction: `ClauDEX/session-forensics/`, JSONL
logs, and tracking docs (they only mention the symbols in historical
narrative).

**Findings:**

1. Neither `proof.py` nor `dispatch.py` is orphaned. Both have live CLI
   command surfaces in `runtime/cli.py`.
2. Both modules' underlying tables are defined in the canonical schema
   and created on every DB init.
3. `proof_state` is intentionally retained **storage**: writers and
   readers exist, but downstream enforcement/display code (`statusline.py`,
   `evaluation.py`) explicitly treats it as zero-effect. The CLI
   `proof get/set/list` surface keeps it user-addressable.
4. `dispatch_queue` is intentionally retained **legacy-compat storage**:
   DEC-WS6-001 pulled it out of the routing hot-path but kept the CLI
   manual-orchestration surface. `post-task.sh` stopped enqueuing.
5. `dispatch_cycles` is **more live** than `dispatch_queue` — it is
   still read by `statusline.py:243` for `dispatch_cycle_id`. It is
   not a deletion candidate even in isolation from the queue.
6. None of these surfaces is mechanically isolated enough to be deleted
   in a bounded Phase 8 slice. Each would require a coordinated bundle:
   CLI command retirement + schema migration + observatory read removal
   + statusline/evaluation/sidecar test rewrites.

**Classification outcome:** Category C is **retained / deferred** — not
merely "pending a CLI import audit." The audit is now complete and the
classification is final for Phase 8. Future retirement (post-Phase-8
cleanup bundle) must land as coordinated bundles as described in the
Category C table "Future retirement bundle scope" above.

**Verification run in this slice:**
- `python3 runtime/cli.py constitution validate` →
  `{"concrete_count": 24, "planned_count": 0, "healthy": true,
  "status": "ok"}`.

No runtime, hook, settings, manifest, prompt-pack, or bridge code
modified. No schema or test changes. Docs-only.

## Phase 8 Slice 9 — Tester-Era Removal Scope Manifest (plan only) — COMPLETED 2026-04-13

**Status:** **DONE** as plan only. **No runtime, hook, settings, test,
or agent code changed in this slice.** Docs-only plan captured here +
`ClauDEX/CURRENT_STATE.md` Slice 9 section.

**Why Phase 8, not Phase 9:** `ClauDEX/CUTOVER_PLAN.md:1418` Phase 8 scope
explicitly says "remove tester-era routing authority." There is no
Phase 9 in the cutover plan. The removal lands as a Phase 8 follow-on
bundle (slice number TBD — this Slice 9 is the plan; the execution
slice(s) will follow).

### 1. Current live tester path (installed truth)

Evidence gathered via:
```
rg -n --glob '!ClauDEX/session-forensics/**' --glob '!**/*.jsonl' \
    --glob '!**/*.log' -w 'tester'
```

Chain, producer → consumer, with exact file:line:

| Step | File:line | Role |
|---|---|---|
| 1 | `settings.json:287` | `SubagentStop` matcher `"tester"` wires two hooks. |
| 2a | `settings.json:290-293` | `$HOME/.claude/hooks/notify.sh` (notification adapter). |
| 2b | `settings.json:295-298` | `$HOME/.claude/hooks/check-tester.sh` (eval-verdict writer). |
| 2c | `settings.json:299-318` | `$HOME/.claude/hooks/post-task.sh` (thin post-task adapter). |
| 3 | `hooks/check-tester.sh:144` | `rt_completion_submit … "tester" …` — tester completion producer. |
| 4 | `runtime/core/completions.py:70-74` | `ROLE_SCHEMAS["tester"] = {"required": ["EVAL_VERDICT","EVAL_TESTS_PASS","EVAL_NEXT_ROLE","EVAL_HEAD_SHA"], ...}` — validates payload from step 3. |
| 5 | `runtime/cli.py:1574-` | `dispatch process-stop` reads `{"agent_type":"tester", ...}` JSON from stdin (help string at `:1575`). |
| 6 | `runtime/core/dispatch_engine.py:318-324` | `elif normalised == "tester":` branch — releases lease, `next_role=None`. |
| 7 | `runtime/core/dispatch_engine.py:169` | `_known_types = {"planner","implementer","tester","guardian","reviewer"}`. |
| 8 | `runtime/core/dispatch_shadow.py:81,129-132,177-180,189-191` | Shadow observer tester→reviewer collapse + `tester / ready_for_guardian → GUARDIAN_LAND` mappings. |
| 9 | `runtime/core/hook_manifest.py:409-423` | Two `SubagentStop/tester` entries (`check-tester.sh`, `post-task.sh`) both `STATUS_ACTIVE`. |
| 10 | `hooks/HOOKS.md:73-76` | Derived doc surface listing the two tester matchers (regenerated from manifest). |
| 11 | `hooks/subagent-start.sh:60` | `tester` in role allowlist. |
| 12 | `hooks/subagent-start.sh:277-292` | Tester-role branch injecting evaluation context + EVAL_* trailer instructions. |
| 13 | `agents/tester.md` | Tester agent prompt (role definition). |
| 14 | Scenario tests | `tests/scenarios/test-routing-tester-completion.sh`, `test-check-tester-valid-trailer.sh`, `test-check-tester-invalid-trailer.sh`, `test-completion-tester.sh`, `test-agent-spawn.sh` (spawns tester among other roles). |

### 2. Full file-change scope (to fully remove tester as live/compat authority)

**A. Wiring / orchestration (producers):**
- `settings.json` — remove the `"matcher": "tester"` block (`:286-319`).
- `runtime/core/hook_manifest.py:409-423` — remove both
  `SubagentStop:tester` entries; update KNOWN_HOOK_EVENTS / docstring if
  needed.
- `hooks/check-tester.sh` — delete.
- `hooks/HOOKS.md` — regenerate via
  `runtime.core.hook_doc_projection.render_hook_doc()` (no hand-edit).
- `hooks/subagent-start.sh:60` — remove `tester` from role allowlist.
- `hooks/subagent-start.sh:244,277-292` — remove tester context-inject
  branch (update the `:244` comment reference).

**B. Runtime (validators + routing + observer):**
- `runtime/core/completions.py:70-74` — delete `ROLE_SCHEMAS["tester"]`;
  update the header docstring `:4,13,26,208` to reflect that tester is
  no longer a validated role.
- `runtime/core/dispatch_engine.py:318-324` — delete `elif normalised
  == "tester":` branch.
- `runtime/core/dispatch_engine.py:169` — remove `"tester"` from
  `_known_types`.
- `runtime/core/dispatch_engine.py:133,155,272-273,338,411,427,665,875`
  — strip tester-specific comments or replace with reviewer
  equivalents.
- `runtime/core/dispatch_shadow.py:81,129-132,177-180,189-191` — remove
  tester→reviewer collapse mappings and `"tester"` from
  `KNOWN_LIVE_ROLES`; update module docstring `:29-30,52,97,104`.
- `runtime/core/leases.py:60` — remove the `"tester"` row from the role
  capability table.
- `runtime/schemas.py:1019` — remove `"tester"` from the cleanup
  allowlist (`role NOT IN (…)`); update adjacent comment `:1008`.

**C. Agent prompt / role definition:**
- `agents/tester.md` — delete (or mark retired; prefer delete for
  authority singularity per W-CONV-6 dead-surface-deletion discipline).
- `agents/implementer.md`, `agents/guardian.md`, `agents/reviewer.md`
  — strip any tester-chain references; the canonical chain is now
  `planner → guardian(provision) → implementer → reviewer →
  guardian(merge)`.

**D. Docs (flow narratives referencing tester):**
- `CLAUDE.md`, `MASTER_PLAN.md`, `implementation_plan.md` —
  constitution-level; edit only exact stale lines that describe tester
  as the live eval role, not historical decision logs. Prefer minimal
  edits.
- `docs/DISPATCH.md`, `docs/ARCHITECTURE.md`, `docs/PLAN_DISCIPLINE.md`,
  `docs/SYSTEM_MENTAL_MODEL.md`, `docs/PROMPTS.md` — update live-flow
  descriptions; leave historical rationale.
- `hooks/HOOKS.md` — regenerated (see A).
- `hooks/block-worktree-create.sh:24`, `hooks/context-lib.sh:436`,
  `hooks/post-task.sh:12`, `hooks/prompt-submit.sh:28,33`,
  `hooks/write-guard.sh:6,26,75`, `hooks/check-guardian.sh:127,233`,
  `hooks/check-implementer.sh:289`, `hooks/check-reviewer.sh:16,18,27`,
  `hooks/track.sh:48,61,68,72` — comment-only sweep; replace
  tester-flow references with reviewer.
- `scripts/statusline.sh`, `scripts/eval_judgment.py` — tester-aware
  code paths (check whether they key off role name; if yes, rename to
  reviewer; if only display text, update).
- `skills/signal-trace/SKILL.md`, `ClauDEX/SUPERVISOR_HANDOFF.md` —
  update flow narratives.

**E. Eval harness (semantic decision required during execution slice):**
- `runtime/core/eval_runner.py:34,38,281,318,322,352,491` — scenario
  `actor_role` defaults to `"tester"`. This is an eval-fixture actor
  name, not a live role. **Decision:** rename default to `"reviewer"`
  (matches new canonical flow) and accept the fixture churn, OR retain
  `"tester"` as the canonical eval actor name. Recommend: rename to
  `"reviewer"` for consistency; schedule the rename in the same bundle
  as the scenario fixture updates below to avoid two churns.
- `runtime/core/eval_scorer.py:36-37,50,469` — parses `agents/tester.md`
  trailer format. If `agents/tester.md` is deleted, either retain the
  scorer format contract (it is self-describing) with a docstring
  pointing at `agents/reviewer.md` as the canonical producer, or fold
  the format spec directly into the scorer module docstring.
- `runtime/core/quick_eval.py:4,9,39,156` — "requires full tester"
  decision wording; rename to "requires full reviewer evaluation" for
  semantic consistency.
- `runtime/core/evaluation.py:11,114` — comment references; update.
- `evals/fixtures/*/EVAL_CONTRACT.md`, `evals/fixtures/*/fixture.yaml`
  — scenarios reference `actor_role: "tester"`. Batch-rename in the
  same bundle as `eval_runner.py`.

**F. CLI help strings (runtime/cli.py):**
- `runtime/cli.py:3636,3694,3784,3928,4021,4210` — help strings list
  `tester` among valid roles. Update to remove `tester` / add `reviewer`
  consistently.

**G. Tests (see §4 for which ones flip vs. delete).**

### 3. Bundle split — recommended: two bundles, not one

**Recommendation: two coordinated bundles.** A single bundle is
physically possible but simultaneously touches wiring, schemas,
runtime, shadow observer, CLI help, prompt packs, ~20 test files, and
the full eval fixture suite — too broad to land cleanly as one bundle
without high rework risk. The two-bundle split below keeps the
intermediate state durable: after Bundle 1 there are zero live
producers; remaining tester code is unreachable dead code awaiting
Bundle 2's deletion. This does **not** create a parallel authority —
dead code without a reachable caller is not authority.

**Bundle 1 — Wiring decommission (removes all live producers):**
- Files to change:
  - `settings.json` (remove tester matcher block).
  - `runtime/core/hook_manifest.py` (remove both tester entries).
  - `hooks/check-tester.sh` (delete).
  - `hooks/HOOKS.md` (regenerate).
  - `hooks/subagent-start.sh` (remove tester role allowlist + branch).
  - `agents/tester.md` (delete).
  - `tests/runtime/test_hook_manifest.py` (flip entry-count pins −2;
    forbid `SubagentStop:tester`).
  - `tests/runtime/test_subagent_start_hook.py` (flip tester-branch
    pin to "tester role rejected / not known").
  - `tests/runtime/test_hook_validate_settings.py` (no tester matcher
    permitted).
  - Scenario tests:
    - `tests/scenarios/test-check-tester-valid-trailer.sh` — delete.
    - `tests/scenarios/test-check-tester-invalid-trailer.sh` — delete.
    - `tests/scenarios/test-completion-tester.sh` — delete.
    - `tests/scenarios/test-agent-spawn.sh` — update to spawn
      reviewer (not tester) alongside other roles, or strip tester
      from the role iteration list if that's the invariant under test.
  - `tests/runtime/test_phase8_deletions.py` — add new `SLICE_*_DELETED_FILES`
    tuple for the deleted tester assets + no-inbound-reference pins
    across live-authority surfaces (same 9-surface set as Slices 4-6).
- Post-bundle state: no live producer writes `"tester"` completion
  records; `ROLE_SCHEMAS["tester"]`, the dispatch_engine `elif
  normalised == "tester":` branch, and shadow tester mappings become
  dead code.
- Acceptance: `rg -n --glob '!ClauDEX/session-forensics/**' --glob
  '!**/*.jsonl' -w tester settings.json runtime/core/hook_manifest.py
  hooks/` → 0 matches for wiring / manifest / live hook code.

**Bundle 2 — Dead-code cleanup + invariant flip:**
- Files to change:
  - `runtime/core/completions.py` (drop `ROLE_SCHEMAS["tester"]` +
    docstring edits).
  - `runtime/core/dispatch_engine.py` (drop tester branch +
    `_known_types` entry + comments).
  - `runtime/core/dispatch_shadow.py` (drop all tester mappings).
  - `runtime/core/leases.py:60` (drop tester capability row).
  - `runtime/schemas.py` (drop tester from cleanup allowlist).
  - Eval harness rename bundle (§2E): `runtime/core/eval_runner.py`,
    `runtime/core/eval_scorer.py`, `runtime/core/quick_eval.py`,
    `runtime/core/evaluation.py`, `evals/fixtures/*/EVAL_CONTRACT.md`,
    `evals/fixtures/*/fixture.yaml`.
  - `runtime/cli.py` help strings.
  - `runtime/core/markers.py`, `runtime/core/lifecycle.py`,
    `runtime/core/traces.py`, `runtime/core/policy_engine.py`,
    `runtime/core/stage_registry.py` — comment-only sweeps.
  - Runtime tests: `test_completions.py`, `test_dispatch_engine.py`,
    `test_dispatch_shadow.py`, `test_shadow_parity.py`, `test_leases.py`,
    `test_stage_registry.py`, `test_eval_runner.py`, `test_eval_scorer.py`,
    `test_eval_metrics.py`, `test_eval_report.py`, `test_quick_eval.py`,
    `test_evaluation.py`, `test_markers.py`, `test_lifecycle.py`,
    `test_traces.py`, `test_policy_engine.py`,
    `policies/test_write_who.py`, `policies/test_write_plan_guard.py`,
    `policies/test_capability_gate_invariants.py`,
    `policies/test_bash_worktree_creation.py` — flip tester-compat
    assertions to "tester is not a known role."
  - Acceptance tests: `tests/acceptance/test-runtime-consistency.sh`,
    `test-full-lifecycle.sh`, `test-enforcement-matrix.sh`,
    `tests/scenarios/test-routing-tester-completion.sh` (delete),
    `tests/scenarios/test-statusline-snapshot.sh`,
    `test-statusline-render.sh`, `test-marker-lifecycle.sh`,
    `test-gwt-1-routing.sh`, `test-auto-dispatch-signal.sh`,
    `test-post-task.sh`, `test-stop-assessment.sh`,
    `test-eval-gate-scenarios.sh`, etc. — update to the canonical
    planner→guardian→implementer→reviewer→guardian chain.
  - `tests/runtime/test_phase8_deletions.py` — add invariant pins
    asserting `"tester" not in ROLE_SCHEMAS`, `"tester" not in
    dispatch_engine._known_types`, `"tester" not in
    dispatch_shadow.KNOWN_LIVE_ROLES`.
  - `docs/*` and `CLAUDE.md`, `MASTER_PLAN.md`, `implementation_plan.md`
    — flow-narrative updates only where lines are currently false about
    live behaviour.
- Post-bundle state: tester is eliminated from runtime authority,
  invariant tests prove it, no dead code remains.

### 4. Invariant tests that flip

From "tester compat is accepted/neutralized" to "tester is not a
known/routed role" — these assertions must be **rewritten**, not just
deleted:

| Test | Current behaviour pinned | Post-bundle behaviour to pin |
|---|---|---|
| `tests/runtime/test_completions.py` | `ROLE_SCHEMAS["tester"]` present; tester validation enforced. | `"tester" not in ROLE_SCHEMAS`; submitting tester payload returns unknown-role error. |
| `tests/runtime/test_dispatch_engine.py` | `process_agent_stop("tester", …)` releases lease + returns `next_role=None`. | `process_agent_stop("tester", …)` raises / returns unknown-role error (pick one and pin). |
| `tests/runtime/test_dispatch_shadow.py` | tester→reviewer collapse + `tester/ready_for_guardian → GUARDIAN_LAND` present in `KNOWN_LIVE_ROLES`. | Neither mapping present; `"tester" not in KNOWN_LIVE_ROLES`. |
| `tests/runtime/test_shadow_parity.py` | Tester stop events produce the collapse. | No such events accepted; parity harness treats tester as unknown. |
| `tests/runtime/test_hook_manifest.py` | 32 active entries, 2 of them `SubagentStop:tester`. | 30 active entries, zero tester matchers. |
| `tests/runtime/test_subagent_start_hook.py` | Tester branch injects eval context. | Tester role not in allowlist; hook errors or ignores. |
| `tests/runtime/test_leases.py` | Tester has a capability row with empty `allowed_ops`. | Tester absent from role capability table. |
| `tests/runtime/test_stage_registry.py` | Tester referenced in migration narrative. | Registry has no tester stage. |
| `tests/runtime/policies/test_write_who.py`, `test_write_plan_guard.py`, `test_capability_gate_invariants.py` | Tester is explicitly denied write-source. | Tester not in role enumeration; denial test either flips to reviewer or is deleted. |
| `tests/runtime/test_eval_runner.py` | `actor_role="tester"` default. | Default changed to `"reviewer"` or asserted explicitly per scenario. |

### 5. Docs and prompts to update or delete

- **Delete:** `agents/tester.md`, `hooks/check-tester.sh`,
  `tests/scenarios/test-check-tester-valid-trailer.sh`,
  `test-check-tester-invalid-trailer.sh`, `test-completion-tester.sh`,
  `test-routing-tester-completion.sh`.
- **Regenerate:** `hooks/HOOKS.md` (from manifest via
  `runtime.core.hook_doc_projection.render_hook_doc()`).
- **Update (flow-narrative edits):** `CLAUDE.md`, `MASTER_PLAN.md`,
  `implementation_plan.md`, `docs/DISPATCH.md`, `docs/ARCHITECTURE.md`,
  `docs/PLAN_DISCIPLINE.md`, `docs/SYSTEM_MENTAL_MODEL.md`,
  `docs/PROMPTS.md`, `agents/implementer.md`, `agents/guardian.md`,
  `agents/reviewer.md`, `skills/signal-trace/SKILL.md`,
  `ClauDEX/SUPERVISOR_HANDOFF.md`, `scripts/statusline.sh`,
  `scripts/eval_judgment.py`. Edit only lines that currently describe
  tester as the live eval role; leave historical decision logs intact.
- **Comment-only sweeps:** hook comment references listed in §2D,
  plus `runtime/core/*` comment lines listed in §2B/E/F.

### 6. Exact verification set for the execution bundle(s)

Bundle 1 (wiring decommission):
- `python3 runtime/cli.py hook validate-settings` → `status=ok`, no
  tester matchers.
- `python3 runtime/cli.py hook doc-check` → `exact_match=true` after
  HOOKS.md regeneration.
- `python3 runtime/cli.py hook manifest-summary` → `active_count=30`
  (from current 32), `SubagentStop:tester` entries absent.
- `python3 runtime/cli.py constitution validate` → `healthy: true`.
- `rg -n --glob '!ClauDEX/session-forensics/**' --glob '!**/*.jsonl' -w
  tester settings.json hooks/HOOKS.md hooks/check-tester.sh
  hooks/subagent-start.sh runtime/core/hook_manifest.py agents/` →
  0 matches on tester matchers / producer writes (comment sweeps in
  other hooks remain until Bundle 2).
- `python3 -m pytest tests/runtime/test_hook_manifest.py
  tests/runtime/test_subagent_start_hook.py
  tests/runtime/test_hook_validate_settings.py
  tests/runtime/test_phase8_deletions.py -v` → all green; new
  tester-deletion pins added and passing.
- `bash tests/scenarios/test-agent-spawn.sh` → green after update.

Bundle 2 (dead-code cleanup + invariant flip):
- `python3 runtime/cli.py constitution validate` → `healthy: true`.
- `python3 -m pytest tests/runtime/ -v` → all green; new invariant
  pins (§4) all passing.
- `bash tests/acceptance/run-acceptance.sh` → all scenarios green
  under the planner→guardian→implementer→reviewer→guardian chain.
- New Phase 8 deletion pins asserting `"tester" not in
  ROLE_SCHEMAS`, `"tester" not in dispatch_engine._known_types`,
  `"tester" not in dispatch_shadow.KNOWN_LIVE_ROLES`.

**Pre-execution plan claim corrected (Slice 12, 2026-04-13):** An
earlier Slice 9 draft listed an `rg -w tester runtime/ hooks/ agents/
tests/ scripts/ docs/` → `zero matches` expectation. That draft
expectation turned out to be wrong: once Bundle 2 landed, historical
retirement-note comments in dead-code files (e.g.
`runtime/core/{completions,dispatch_engine,dispatch_shadow,leases,
evaluation,eval_runner,eval_scorer,stage_registry}.py`,
`runtime/schemas.py`, and 5 hook comments) and the Phase 8
deletion-pin suite itself legitimately reference the bare string
`tester` — the former as Future-Implementer annotations, the latter
as "must-not-appear-in-live-authority" assertions. See the
"Slice 11 correction" section below for the post-execution
focused-rg classification that replaces this pre-execution
"zero matches" claim.

### 7. Not touched by Slice 9 (plan-only)

- `settings.json`, `runtime/core/*`, `hooks/*`, `agents/*`, `tests/*`,
  `scripts/*`, `docs/*` — no code or docs edits beyond this inventory
  + `ClauDEX/CURRENT_STATE.md`.
- bridge code, prompt packs, schema files.
- Category C/E rows remain as closed by Slices 5-8.
- `MASTER_PLAN.md` and `implementation_plan.md`.

Slice 9 is planning-only. The two execution bundles above are the
next Phase 8 follow-on slices; their slice numbers will be assigned
when the execution begins.

## Phase 8 Follow-On Dependencies

Scope originally labelled "Phase 9" in Slices 1-8 is now correctly
recorded as Phase 8 follow-on work per `ClauDEX/CUTOVER_PLAN.md:1418`.
See Slice 9 below for the full scope manifest and bundle split.

- `hooks/check-tester.sh` + `settings.json:286-319` tester matcher +
  `hooks/subagent-start.sh:60,277-292` + `agents/tester.md` — require
  orchestrator-level coordination.
- Any change to the Agent-tool dispatch contract.

## Change Summary

| File | Change |
|---|---|
| `ClauDEX/PHASE8_DELETION_INVENTORY.md` | **New** — this document. |
| `ClauDEX/CURRENT_STATE.md` | Append Phase 8 Slice 1 summary pointing here. |

No source code modified. No tests modified. No deletions performed.

---

## Slice 10 — Tester Bundle 1: wiring decommission (2026-04-13)

**Status:** executed.

**Scope:** remove every live producer path that can create or dispatch a
`tester` SubagentStop/completion. Runtime dead code (`ROLE_SCHEMAS["tester"]`,
`dispatch_engine` tester branch, `dispatch_shadow` tester mappings, leases /
schemas / eval harness surfaces) is intentionally left for Bundle 2.

### Files deleted

- `hooks/check-tester.sh` — tester SubagentStop adapter. No replacement; the
  reviewer path uses `hooks/check-reviewer.sh` and REVIEW_* trailers.
- `agents/tester.md` — tester role prompt. Superseded by `agents/reviewer.md`.
- `tests/scenarios/test-check-tester-valid-trailer.sh`
- `tests/scenarios/test-check-tester-invalid-trailer.sh`
- `tests/scenarios/test-completion-tester.sh`
- `tests/scenarios/test-routing-tester-completion.sh`

### Live wiring removed

- `settings.json` — removed the `SubagentStop` matcher block for `tester`
  (was `L286-310`). SubagentStop role matchers now: `planner|Plan`,
  `implementer`, `guardian`, `reviewer`.
- `runtime/core/hook_manifest.py` — removed both tester entries
  (`check-tester.sh`, `post-task.sh` under matcher `tester`). Manifest
  count 32 → 30.
- `hooks/subagent-start.sh`:
  - Dispatch-role allowlist (`_IS_DISPATCH_ROLE` case at L60): removed
    `tester`. Active list: `planner|Plan|implementer|guardian|reviewer`.
  - Deleted the `tester)` branch that injected EVAL_* trailer guidance.
  - Updated stale comments/wording:
    - File-top role list: removed "Tester".
    - Implementer branch WS1 comment: `check-tester` → `check-reviewer`.
    - Implementer HANDOFF line: "hand off to Tester" → "hand off to
      Reviewer".
    - Guardian authority line: "(set by Tester via EVAL_VERDICT trailer)"
      → "(set by Reviewer via REVIEW_VERDICT trailer)".
- `hooks/HOOKS.md` — regenerated from `render_hook_doc()`; generator
  hash matches. Two tester rows under SubagentStop are gone.

### Derived-doc updates

- `CLAUDE.md`:
  - Integration Surface Context: "implementer or tester" →
    "implementer or reviewer".
  - ClauDEX Contract Injection role lists: tester removed from
    `(planner, implementer, guardian, reviewer)` / stage-id list.
  - Auto-Dispatch example: `AUTO_DISPATCH: tester` → `AUTO_DISPATCH: reviewer`;
    "(or tester's)" → "(or reviewer's)".
  - Resources table: removed `agents/tester.md` row.
- `docs/PROMPTS.md`: Source of Truth list replaces `agents/tester.md`
  with `agents/reviewer.md`.
- `agents/guardian.md`: DEC-GUARD-AUTOLAND rationale uses "reviewer"
  instead of "tester".
- `agents/implementer.md`: "The tester will audit ..." → "The reviewer
  will audit ...".
- `agents/reviewer.md`: frontmatter description and opening paragraph
  no longer claim tester precedes reviewer; dispatched-directly-after-
  implementer wording.
- `agents/shared-protocols.md`: left untouched this slice (Evaluator
  Trailer section documents the EVAL_* contract that dead runtime code
  still references; Bundle 2 removes it alongside `ROLE_SCHEMAS["tester"]`).

### Test updates

- `tests/runtime/test_hook_manifest.py`:
  - `test_manifest_is_exactly_32_entries_against_todays_settings` →
    `test_manifest_is_exactly_30_entries_against_todays_settings`,
    asserts `len(hm.HOOK_MANIFEST) == 30`.
  - `test_active_plus_deprecated_counts_match` asserts `active == 30`.
  - `test_entries_for_adapter_exact_match_only`: `post-task.sh` count
    5 → 4.
  - New: `test_no_subagent_stop_tester_entry` pins that no manifest
    entry has `(event="SubagentStop", matcher="tester")`.
- `tests/runtime/test_hook_validate_settings.py`:
  - `test_real_settings_parses_to_32_entries` renamed to `_to_30_`,
    asserts 30.
  - `test_counts_reflect_entry_sets` asserts 30 / 30.
  - `test_empty_settings_is_drift_due_to_missing_in_settings`
    `missing_in_settings == 30`.
- `tests/scenarios/test-agent-spawn.sh`:
  - `NAMED_ROLES` list: `tester` → `reviewer` (reviewer is the live
    evaluator role).
  - Header rationale updated.
- `tests/runtime/test_phase8_deletions.py`:
  - New decision annotation: `DEC-PHASE8-SLICE10-001`.
  - 6 delete-file pins (check-tester.sh, agents/tester.md, 4 scenario
    tests).
  - 2 no-reference-surface pins (`settings.json`, `hooks/HOOKS.md`)
    forbidding the `check-tester.sh` adapter basename.
  - 1 JSON-shape pin asserting `settings.json` has no SubagentStop
    matcher equal to `"tester"`.
  - Deliberately narrow: does NOT forbid the bare string `tester`
    anywhere — Bundle 2 will tighten this once dead runtime code is
    removed.

### Verification evidence

- `python3 runtime/cli.py hook validate-settings` →
  `{"status": "ok", "healthy": true, "settings_repo_entry_count": 30,
  "manifest_wired_entry_count": 30, "deprecated_still_wired": [],
  "invalid_adapter_files": []}`.
- `python3 runtime/cli.py hook doc-check` →
  `{"status": "ok", "healthy": true, "exact_match": true,
  "expected_content_hash": "sha256:11a24375...851b1e9e",
  "candidate_content_hash": "sha256:11a24375...851b1e9e"}`.
- `python3 runtime/cli.py constitution validate` →
  `{"concrete_count": 24, "planned_count": 0, "healthy": true,
  "status": "ok"}`.
- `pytest tests/runtime/test_hook_manifest.py
   tests/runtime/test_hook_validate_settings.py
   tests/runtime/test_subagent_start_hook.py
   tests/runtime/test_phase8_deletions.py` → 179 passed.
- `bash tests/scenarios/test-agent-spawn.sh` → `PASS: test-agent-spawn`
  (five named roles including `reviewer` emit `additionalContext`,
  lightweight roles exit 0).

### Out of scope (deferred to Bundle 2)

- `runtime/core/completions.py` — `ROLE_SCHEMAS["tester"]`
- `runtime/core/dispatch_engine.py` — tester completion branch
- `runtime/core/dispatch_shadow.py` — tester role mappings
- `runtime/core/leases.py` — tester lease issuance (if present)
- `runtime/schemas.py` — tester-related schema paths
- `runtime/core/eval_runner.py` — tester harness surfaces
- `agents/shared-protocols.md` — Evaluator Trailer section
- CLI help strings referencing tester
- `MASTER_PLAN.md` / `implementation_plan.md` narrative references

After Bundle 1 there are zero live tester producers. Any remaining tester
runtime code is unreachable dead code, not a parallel authority.

---

## Slice 10 correction (Bundle 1 follow-up, 2026-04-13)

Codex review of the initial Slice 10 landing (0046-m7p36e) found that the
wiring removal was clean but narrative surfaces still named the deleted
`check-tester.sh` adapter in comments and live docs. Correction 0047-fodn2m
re-pointed those comments and docs at the active SubagentStop evaluator
adapter (`check-reviewer.sh` in the live chain) and expanded the Slice 10
invariant pins so the same basename/path cannot silently reappear.

### Comment re-points in live hook sources

- `hooks/prompt-submit.sh` — DEC-EVAL-004 rationale now names the reviewer
  completion/evaluation_state pipeline instead of the deleted adapter
- `hooks/track.sh` — DEC-WS1-TRACK-001 rationale generalised from
  "matching the pattern in check-guardian.sh and check-tester.sh" to
  "matching the pattern in check-guardian.sh and other SubagentStop
  adapters"; also replaced "new tester pass" with "new reviewer pass"
- `hooks/check-reviewer.sh` — header and DEC-CHECK-REVIEWER-001
  rationale replaced the historical `check-tester.sh` comparison with a
  generic description and a Phase 8 Slice 10 retirement note
- `hooks/check-guardian.sh` — Check 6 header and the evaluation-state
  error message re-pointed from "set by check-tester.sh" /
  "Tester issues EVAL_VERDICT=ready_for_guardian" to the generic
  SubagentStop evaluator adapter wording
- `hooks/check-implementer.sh` — DEC-IMPL-CONTRACT-002 rationale
  re-pointed from "same trailer pattern as check-tester.sh" to
  "trailer-matching pattern used by the other SubagentStop adapters"
- `hooks/post-task.sh` — DEC-DISPATCH-001 canonical flow updated from
  "planner→implementer→tester→guardian" to
  "planner→guardian(provision)→implementer→reviewer→guardian(merge)"
- `hooks/write-guard.sh` — denied-role enumerations (header, comment,
  DENY branch) updated from `(empty, planner, Plan, tester, guardian)`
  to `(empty, planner, Plan, reviewer, guardian)`; reviewer is read-only
  by contract (`agents/reviewer.md`) and is the currently active
  non-implementer role in the live chain
- `hooks/context-lib.sh` — DEC-WF-003 rationale updated "Later roles
  (tester, guardian)" → "Later roles (reviewer, guardian)"

### Documentation re-points

- `docs/DISPATCH.md` — UserPromptSubmit readiness note re-pointed at the
  live SubagentStop evaluator adapter; Phase 8 Slice 10 retirement of
  the legacy tester evaluator producer recorded
- `docs/SYSTEM_MENTAL_MODEL.md` — SubagentStop hook list, dispatch
  diagram node, and "evaluator output governs landing" narrative all
  re-pointed at `check-reviewer.sh` (the legacy tester evaluator adapter
  retirement is recorded generically; the deleted basename is not
  restated to keep the file clear of the pinned basename)
- `tests/scenarios/capture/PAYLOAD_CONTRACT.md` — SubagentStop hook
  list updated to name `check-reviewer.sh` in place of the deleted
  adapter

### Test-pin adjustments

- `tests/runtime/test_phase8_deletions.py` — DEC-PHASE8-SLICE10-001
  rationale corrected from "four deleted files" to "six deleted files"
  (matches the actual deletion list: 1 hook + 1 prompt + 4 scenario
  tests). Expanded `SLICE10_NO_ADAPTER_REFERENCE_SURFACES` from
  `(settings.json, hooks/HOOKS.md)` to also include the nine cleaned
  live hooks and the three cleaned live docs. Added a sibling pin
  `test_phase8_slice10_surface_has_no_tester_prompt_reference` that
  forbids the `agents/tester.md` relative path on the same surface set.
  Both pins remain deliberately narrow — they do not forbid the bare
  role string `tester`, which is still legitimately mentioned in
  Bundle 2 dead-code surfaces until Bundle 2 lands.

### Out of scope (still deferred to Bundle 2)

The following files still contain `check-tester.sh` or `agents/tester.md`
references and were intentionally left untouched by this correction
because they fall in the eval-harness / dead-runtime-code territory
Bundle 2 owns:

- `runtime/core/evaluation.py` — evaluator constant table
- `runtime/core/eval_scorer.py` — scorer docstring references
- `tests/scenarios/test-prompt-submit-no-verified.sh`
- `tests/scenarios/test-lease-workflow-id-authority.sh`
- `tests/scenarios/test-marker-lifecycle.sh`
- `tests/runtime/test_evaluation.py`, `test_hook_manifest.py`,
  `test_lifecycle.py`, `test_statusline_truth.py`, `test_bugs.py`,
  `test_eval_scorer.py`, `test_hook_validate_settings.py`,
  `test_hook_bridge.py`, `tests/runtime/policies/test_write_plan_guard.py`
- `MASTER_PLAN.md`, `implementation_plan.md` narrative references

These surfaces are explicitly outside the expanded Slice 10 pin set.
Bundle 2 will remove them when it retires the dead runtime code and can
tighten the pins to forbid the raw role string `tester`.

### Verification evidence (post-correction)

- `pytest tests/runtime/test_phase8_deletions.py` → 71 passed (adds
  13 new pins beyond the pre-correction 58: the 13 surfaces × 2 checks
  minus the 2 pre-existing `settings.json` / `hooks/HOOKS.md` checks
  covered by the existing adapter-basename test, plus the new prompt
  path pin on all 13 surfaces).
- `python3 runtime/cli.py hook validate-settings` →
  `{"status": "ok", "healthy": true, "settings_repo_entry_count": 30,
  "manifest_wired_entry_count": 30}`.
- `python3 runtime/cli.py hook doc-check` →
  `{"status": "ok", "exact_match": true,
  "expected_content_hash": "sha256:11a24375...851b1e9e"}` (unchanged
  from pre-correction — no manifest surface was touched).
- `python3 runtime/cli.py constitution validate` →
  `{"concrete_count": 24, "healthy": true, "status": "ok"}`.
- `rg` over live hooks/docs/settings/manifest/HOOKS/CLAUDE/agents/tests
  (excluding the Bundle 2 scope files listed above) finds zero
  `check-tester.sh` hits outside that scope.

## Slice 11 — Tester Bundle 2: dead-code cleanup + invariant flip (2026-04-13)

**Status:** **DONE.** Landed 2026-04-13 per Codex instruction
1776132844181-0048-ywlb7d. Bundle 2 retires the legacy `tester` role from
the runtime entirely: it is no longer a known, validated, or routed
role, and the invariant-pin suite mechanically forbids its reintroduction.

### Scope delivered

Runtime dead-code removal (tester no longer referenced by live logic;
retained only in historical comments for Future Implementers):

- `runtime/core/completions.py` — `ROLE_SCHEMAS` no longer contains
  `"tester"`. `determine_next_role()` returns `None` for any
  `role == "tester"`. Schema validation rejects tester stop payloads.
- `runtime/core/dispatch_engine.py` — `_known_types` no longer contains
  `"tester"`; `process_agent_stop(agent_type="tester", ...)` exits
  silently (no completion submitted, no shadow event emitted).
- `runtime/core/dispatch_shadow.py` — `KNOWN_LIVE_ROLES` no longer
  contains `"tester"`. `compute_shadow_decision(live_role="tester", ...)`
  returns `reason=REASON_UNKNOWN_LIVE_ROLE`, `agreed=False`, all shadow
  fields `None`. The legacy `tester → reviewer` collapse and
  `tester(ready_for_guardian) → guardian:land` mapping are removed.
- `runtime/core/leases.py` — `ROLE_DEFAULTS` no longer contains
  `"tester"`; tester lease requests fall into the unknown-role default
  (`["routine_local"]`).
- `runtime/schemas.py` — `ensure_schema()` retained-role set is
  `{planner, implementer, reviewer, guardian}`; stale `tester` markers
  are deactivated on every `ensure_schema()` invocation
  (DEC-CONV-002 whitelist).
- `runtime/core/stage_registry.py`, `runtime/core/eval_runner.py`,
  `runtime/core/eval_scorer.py` — historical docstring notes only.

Invariant-pin test coverage (prevents reintroduction):

- `tests/runtime/test_phase8_deletions.py` DEC-PHASE8-SLICE11-001 —
  7 new pins:
  1. `test_phase8_slice11_tester_absent_from_role_schemas`
  2. `test_phase8_slice11_tester_absent_from_dispatch_engine_known_types`
     (behavioural: silent exit, zero shadow emission)
  3. `test_phase8_slice11_tester_absent_from_dispatch_shadow_known_live_roles`
     (+ `compute_shadow_decision` reason assertion)
  4. `test_phase8_slice11_tester_absent_from_leases_role_defaults`
  5. `test_phase8_slice11_tester_not_in_ensure_schema_retained_role_set`
     (inserts ghost tester marker, asserts `ensure_schema` deactivation)
  6. `test_phase8_slice11_determine_next_role_returns_none_for_tester`
     (all verdicts)
  7. `test_phase8_slice11_agents_tester_md_stays_deleted`

Test suite flips (tester → reviewer, or tester → unknown-role behaviour):

- `tests/runtime/test_completions.py` — tester schema assertions flipped
- `tests/runtime/test_dispatch_engine.py` — tester stop flow → silent exit
- `tests/runtime/test_dispatch_shadow.py` — tester inputs → unknown-live-role
- `tests/runtime/test_shadow_parity.py` — tester parity assertions removed
- `tests/runtime/test_leases.py` — tester ROLE_DEFAULTS assertions removed
- `tests/runtime/test_stage_registry.py`, `test_eval_runner.py` — tester refs
- `tests/runtime/test_lifecycle.py`, `test_hook_bridge.py`,
  `test_statusline.py`, `test_quick_eval.py` — tester → reviewer swap
- `tests/runtime/policies/test_hook_scenarios.py` —
  `write-guard-tester-deny` scenario removed

Docs updated (live authority docs only; historical retirement notes
retained intentionally for Future Implementers):

- `docs/DISPATCH.md` — canonical role flow updated to
  `planner → guardian(provision) → implementer → reviewer → guardian(merge)`;
  Slice 11 retirement note added.
- `docs/SYSTEM_MENTAL_MODEL.md` — dispatch graph updated to
  `next role: reviewer`; `Reviewer` section uses `REVIEW_*` trailers;
  operator cheat sheet references Reviewer; Slice 11 note added.
- `docs/ARCHITECTURE.md` — `check-{planner,implementer,reviewer,guardian}.sh`
  adapter list; Slice 10/11 retirement note added.
- `docs/PLAN_DISCIPLINE.md` — plan-guard deny roles updated to
  `(implementer, reviewer, guardian, orchestrator)`.

### Verification evidence (2026-04-13)

- `cc-policy constitution validate` →
  `{"concrete_count": 24, "healthy": true, "status": "ok"}`.
- `cc-policy hook validate-settings` →
  `{"status": "ok", "healthy": true, "settings_repo_entry_count": 30,
  "manifest_wired_entry_count": 30, "missing_in_manifest": [],
  "missing_in_settings": [], "deprecated_still_wired": []}`.
- `cc-policy hook doc-check` →
  `{"status": "ok", "exact_match": true,
  "expected_content_hash": "sha256:11a24375...851b1e9e"}` (unchanged).
- `pytest tests/runtime/test_completions.py test_dispatch_engine.py
  test_dispatch_shadow.py test_shadow_parity.py test_leases.py
  test_stage_registry.py test_eval_runner.py test_phase8_deletions.py`
  → **502 passed in 18.64s**.
- `pytest tests/runtime/policies/ test_lifecycle.py test_hook_bridge.py
  test_statusline.py test_quick_eval.py` → **541 passed in 75.86s**.
- `rg '\btester\b' runtime/ hooks/ agents/ settings.json` — remaining
  hits are comment-only retirement notes in
  `runtime/core/{completions,dispatch_engine,dispatch_shadow,leases,
  stage_registry,eval_runner,eval_scorer,evaluation}.py`,
  `runtime/schemas.py`, and 5 hook comments. `agents/` and
  `settings.json` contain zero hits.

### After Slice 11

Tester is no longer a dispatch-significant runtime role. Unknown-role
silent-exit in `dispatch_engine`, zero shadow emission, and
`ensure_schema()` marker deactivation are now load-bearing invariants
pinned in `test_phase8_deletions.py`. Reintroducing `tester` to any of
`ROLE_SCHEMAS`, `_known_types`, `KNOWN_LIVE_ROLES`, `ROLE_DEFAULTS`, or
the `ensure_schema` retained-role set will fail those pins.

## Slice 11 correction (Bundle 2 follow-up, 2026-04-13)

**Status:** **DONE.** Landed under Codex correction instructions
`1776135766401-0049-lojhjs` and continuation `1776137878959-0050-hkoa80`.
Codex review of the initial Slice 11 landing (0048-ywlb7d) accepted the
runtime/invariant core but flagged two correction classes that landed in
this bundle.

### Scope delivered

**1. Scenario / acceptance / test-surface reframes.** Slice 11
removed tester from the live authority surfaces but left `tester`
role actors, markers, leases, enqueues, trace roles, evaluator
fixtures, and observability fixture roles scattered across the
scenario/runtime test surface. Several of these scenarios now fail
under `ensure_schema()` retained-role cleanup (e.g. a stored
`tester` marker becomes `null` after the post-Slice-11 whitelist
sweep). Reframed files:

- `tests/scenarios/test-prompt-submit-no-verified.sh`,
  `tests/scenarios/test-marker-lifecycle.sh`,
  `tests/scenarios/test-eval-not-consumed-on-deny.sh`,
  `tests/scenarios/test-guardian-auto-land-policy.sh`,
  `tests/scenarios/test-statusline-snapshot.sh`,
  `tests/scenarios/test-statusline-render.sh`,
  `tests/scenarios/test-lease-concurrent.sh`,
  `tests/scenarios/test-stop-assessment.sh`,
  `tests/scenarios/test-eval-gate-scenarios.sh`,
  `tests/scenarios/test-obs-pipeline.sh`,
  `tests/scenarios/test-obs-emission.sh`,
  `tests/scenarios/test-trace-lite.sh`.
- Runtime test fixtures: `test_evaluation.py`, `test_lifecycle.py`,
  `test_bugs.py`, `test_eval_scorer.py`, `test_policy_engine.py`,
  `test_dispatch.py`, `test_traces.py`, `test_eval_report.py`,
  `test_eval_metrics.py`, `test_observatory_analysis.py`,
  `test_observatory.py`, `test_statusline.py`, `test_sidecars.py`,
  `test_stab_a4.py`, `test_prompt_pack_state.py`.
- `implementation_plan.md:57` file-tree entry
  `check-tester.sh` → `check-reviewer.sh`.

All reframes keep the same test intent — the fixtures used a role
name because the tests are role-agnostic; switching to `reviewer`
(a live role) preserves the behavioural assertion while satisfying
the whitelist cleanup and authority invariants.

**2. Narrative pins on operator-visible surfaces.** Three new pins
were added to `tests/runtime/test_phase8_deletions.py` covering
surfaces that are not runtime authorities but are operator-visible:

- `test_phase8_slice11_cli_help_does_not_advertise_tester` — CLI
  help text (`python3 -m runtime.cli --help`, `runtime.cli dispatch
  --help`, `runtime.cli marker --help`, `runtime.cli lease --help`)
  does not advertise `tester` as a live role.
- `test_phase8_slice11_executable_test_has_no_live_tester_surface`
  — each executable scenario test under `tests/scenarios/` is
  scanned for live surface references to the deleted adapter
  (`check-tester.sh`) outside retirement-context comments.
- `test_phase8_slice11_capture_payload_contract_has_no_live_tester_role`
  — `tests/scenarios/capture/PAYLOAD_CONTRACT.md` does not list
  `tester` as a live SubagentStop role.

### Post-execution focused-rg classification

(Replaces the pre-execution "zero matches" expectation in the
Slice 9 plan §6.)

Remaining `tester` hits after the correction, grouped by whether
they are legitimate or stale:

- **Legitimate — retirement invariants:** comment-only historical
  retirement notes in `runtime/core/{completions,dispatch_engine,
  dispatch_shadow,leases,evaluation,eval_runner,eval_scorer,
  stage_registry}.py`, `runtime/schemas.py`, and 5 hook
  comments. These are Future-Implementer annotations that explain
  why the dead branches were removed.
- **Legitimate — pin contract:** Phase 8 deletion pin suite
  (`tests/runtime/test_phase8_deletions.py`) references the literal
  string `tester` to assert its absence from live authority
  surfaces. Required by the pin contract.
- **Cleaned:** all reframed scenario/acceptance fixtures and
  runtime tests listed above; no live surface embeds the deleted
  adapter basename `check-tester.sh`.
- **Out-of-scope historical:** `MASTER_PLAN.md` and `ClauDEX/**`
  (including this document and session forensics) retain
  historical decision-log references to tester. These are
  deliberately preserved as audit trail and are not in the
  Phase 8 deletion scope.

### Verification evidence (post-correction)

- `pytest tests/runtime/test_phase8_deletions.py` → **169 passed**
  (full Slice 10 + Slice 11 + Slice 11-correction pin suite).
- `pytest tests/runtime/` → **4124 passed, 3 pre-existing
  unrelated failures** (`test_claudex_stop_supervisor.py::
  test_stop_hook_allows_stop_for_consumed_pending_review`,
  `test_claudex_watchdog.py::TestWatchdogSelfExecOnScriptDrift`,
  `test_subagent_start_payload_shape.py::
  TestPreToolAgentPayloadShape`). Acknowledged by Codex as
  out-of-scope for Slice 11.
- `cc-policy constitution validate` → `concrete_count=24,
  healthy=true, status=ok`.
- `cc-policy hook validate-settings` → `status=ok, healthy=true,
  settings_repo_entry_count=30, manifest_wired_entry_count=30,
  deprecated_still_wired=[], invalid_adapter_files=[]`.
- `cc-policy hook doc-check` → `exact_match=true,
  expected_content_hash=sha256:11a24375...851b1e9e` (unchanged —
  no manifest surface touched by this correction).

### After the correction

Category A is closed as completed. The Phase 8 CUTOVER_PLAN.md
exit criterion "remove tester-era routing authority" is discharged
in full, including the CLI-help / executable-scenario / capture-
payload-contract operator surfaces that sit one layer outside the
core authority map.
