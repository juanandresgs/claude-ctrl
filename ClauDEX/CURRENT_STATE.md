# ClauDEX Current State

Status (current, 2026-04-17): **PUSH DEBT PRESENT — UPSTREAM DIVERGED** — lane committed a **30-file** bundle as `d7db4ba` plus doc-reconciliation checkpoint `696254a` (3 files). Lane is 12 ahead / 35+ behind `origin/feat/claudex-cutover` (behind-count time-variant). Push requires merge integration first: 7 dirty tracked files block merge (must be checkpointed), then `git merge origin/feat/claudex-cutover`, then push. See "cc-policy-who-remediation Slice 1 State (2026-04-17)" and "Recommended next supervisor action" below.

Historical snapshot: as of 2026-04-14 closeout (Phase 8 Slice 12), the ClauDEX cutover bundle had landed and been pushed upstream with no remaining Phase-8 checkpoint debt. That snapshot is preserved in the "Checkpoint Readiness (Phase 8 Slice 12 closeout, 2026-04-14) — HISTORICAL SNAPSHOT" section below; it is not current lane truth.

Historical updated log:
- 2026-04-17: cc-policy-who-remediation Slice 1 — bridge-permission authority + subordinate WHO notes + authority-doc reconciliation + time-scoping + Invariant #15 Bash readiness invalidation (root + bridge parity) + supervisor Step 4 response-surface fallback + handoff-artifact invariant pins + Invariant #11 `@decision-ref` resolution pin + Invariant #5 `command_intent` sole-authority scanner pin + current-lane state-authority scanner pin + Invariant #13 symmetric retrieval-layer downstream pin + dated invariant-coverage-matrix artifact + coverage-matrix mechanical pin + CUTOVER_PLAN phase-closure time-scoping pin + DEC-EVAL-006 fingerprint-comparison fix (circular invalidation bypass + payload-identity baseline-key stability). Staged bundle grew 19 → 28 across turns, then committed as `d7db4ba` (30 files — fingerprint fix added 2 files to the composition). Push to `origin/feat/claudex-cutover` blocked by `bash_approval_gate` high-risk policy; push debt present.
- 2026-04-14: Phase 5 complete; Phase 6 slices 1-6 complete; Phase 7 slices 1-17 complete; Phase 8 slices 1-12 complete — Slice 10 = Tester Bundle 1 wiring decommission + 0047-fodn2m narrative/pin correction; Slice 11 = Tester Bundle 2 dead-code cleanup + invariant flip (0048-ywlb7d) + correction 0049-lojhjs/0050-hkoa80; Slice 12 = closeout / time-scoping correction; CUTOVER_PLAN planned-area set exhausted; Phase 8 exit criteria met; Final Acceptance Condition 12/12 satisfied against installed truth; accepted bundle landed on `feat/claudex-cutover` as commit `6b8cc5c` and pushed to `origin/feat/claudex-cutover`; follow-up auto-submit process-control fix landed as `d8fdf96` and pushed to the same upstream. That 2026-04-14 snapshot is historical — it does not describe the current lane.

This file is the execution handoff for the current ClauDEX buildout. It is the
place to answer:

- what has actually been built
- what is still local-only
- what the next bounded slice is
- how to restart cleanly without inheriting dead tmux state

## Git Placement

Canonical cutover custody branch (remote):

- `origin/feat/claudex-cutover` at HEAD `d8fdf96` — carries the accepted
  ClauDEX cutover bundle (`6b8cc5c`, "feat(claudex): cutover bundle -
  Phases 1-8 closeout") plus the follow-up auto-submit process-control
  fix (`d8fdf96`, "Fix ClauDEX auto-submit process growth").

Soak worktree branch (this lane) — current as of 2026-04-17:

- `claudesox-local` at HEAD `696254a` (doc-reconciliation checkpoint on
  top of `d7db4ba`), **12 commits ahead** of `origin/feat/claudex-cutover`
  (behind-count time-variant; 35 at last sample). Lane has **diverged**
  from upstream — non-fast-forward push rejected. Integration via
  `git merge origin/feat/claudex-cutover` is required before push can
  succeed. Merge is blocked by 7 dirty tracked files that overlap remote
  updates (must be checkpointed first — see "Recommended next supervisor
  action" below).

Soak worktree branch — historical snapshot (2026-04-14 closeout):

- Lane was on `claudesox-local` tracking `origin/feat/claudex-cutover`
  at HEAD `d8fdf96`. At that time the upstream checkpoint was landed
  and the soak lane carried a small uncommitted follow-up maintenance
  bundle (`ClauDEX/CURRENT_STATE.md`, `ClauDEX/SUPERVISOR_HANDOFF.md`,
  `scripts/claudex-codex-launch.sh`); those edits were state-record
  drift corrections and lane-local Codex supervisor launcher
  stabilization, not Phase-8 checkpoint debt. This snapshot is
  historical; it does not describe the current lane.

Originating branch:

- `fix/enforce-rca-13-git-shell-classifier` at `c7a3109` — the
  pre-checkpoint base from which `feat/claudex-cutover` was cut. Kept
  as historical reference only; no further commits are expected there.

Current ClauDEX reality:

- the ClauDEX cutover bundle **landed and was pushed** as commit
  `6b8cc5c` on `feat/claudex-cutover`; the follow-up process-control
  fix landed and was pushed as `d8fdf96` on the same branch
- `ClauDEX/DUAL_LANE_STABILITY_HANDOFF_2026-04-14.md` is intentionally
  excluded from the cutover bundle (lane/operator handoff)
- the braid-side portable bridge work was pushed separately upstream on:
  - repo: `/Users/turla/Code/braid`
  - branch: `feat/single-claude-mvp`
  - commit: `ccca086`

Implication (historical, as of 2026-04-14 closeout):

- architecture/design handoff was good at that snapshot
- implementation custody was immortalised on
  `origin/feat/claudex-cutover` through HEAD `d8fdf96`; **as of
  2026-04-14** no Phase-8 checkpoint debt remained
- the next clean action at that point was **not** a checkpoint commit —
  it was either cutover-plan continuation (new architecture slice,
  explicitly scoped) or narrow maintenance (soak hygiene, documentation
  drift, focused gate reverification)

Current implication (2026-04-17):

- Push debt is present in the lane; the 30-file bundle (`d7db4ba`) plus
  doc-reconciliation checkpoint (`696254a`) are committed locally but not
  pushed. Lane has diverged from upstream (12 ahead / 35+ behind,
  time-variant). The next clean action is a three-step integration:
  (1) checkpoint the 7 dirty merge-blocker files, (2) merge upstream,
  (3) push. No stash, reset, rebase, or force-push permitted.

## cc-policy-who-remediation Slice 1 State (2026-04-17)

- `runtime/core/bridge_permissions.py` added as concrete declarative authority
  (DEC-CLAUDEX-BRIDGE-PERMISSIONS-001); registered as entry #25 in
  `runtime/core/constitution_registry.py`; validated by
  `cc-policy bridge validate-settings` (exits 0).
- Five git-landing Bash denies removed from `ClauDEX/bridge/claude-settings.json`.
- Checkpoint committed locally as `d7db4ba` (30 files). Push to
  `origin/feat/claudex-cutover` is blocked by `bash_approval_gate`
  high-risk policy — **NOT** by runtime evaluation or lease gates.
- The committed bundle contains **30 files**:
  - two Bundle E subordinate-notes docs
    (`ClauDEX/CC_POLICY_WHO_REMEDIATION_SPEC.md`,
    `ClauDEX/CC_POLICY_WHO_REMEDIATION_EXECUTION_PROMPT.txt`)
  - seven bridge-permission-slice paths
    (`runtime/core/bridge_permissions.py`, `runtime/cli.py`,
    `runtime/core/constitution_registry.py`,
    `ClauDEX/bridge/claude-settings.json`,
    `tests/runtime/test_bridge_permissions.py`,
    `tests/runtime/test_bridge_validate_settings_cli.py`,
    `tests/runtime/test_constitution_registry.py`)
  - three authority-doc / time-scoping paths
    (`ClauDEX/CURRENT_STATE.md`, `ClauDEX/CUTOVER_PLAN.md`,
    `ClauDEX/SUPERVISOR_HANDOFF.md`)
  - nine Invariant #15 Bash readiness-invalidation paths
    (`hooks/post-bash.sh`, `hooks/pre-bash.sh`, `hooks/context-lib.sh`,
    `hooks/HOOKS.md`, `runtime/core/hook_manifest.py`, `settings.json`,
    `tests/runtime/policies/test_post_bash_eval_invalidation.py`,
    `tests/runtime/test_hook_manifest.py`,
    `tests/runtime/test_hook_validate_settings.py`)
    — includes DEC-EVAL-006 fingerprint-comparison fix (circular
    invalidation bypass) and payload-identity baseline-key stability
  - one supervisor Step 4 response-surface fallback edit
    (`.codex/prompts/claudex_supervisor.txt`) — documents the
    `get_response()` primary / `$CLAUDEX_STATE_DIR/pending-review.json`
    fallback / run_id-mismatch-ignore order for the bridge-broker-drift
    case
  - one handoff-artifact invariant extension
    (`tests/runtime/test_handoff_artifact_path_invariants.py`) — adds
    two new tests (`test_supervisor_step4_response_surface_fallback_is_pinned`,
    `test_supervisor_step4_primary_before_fallback_ordering`)
    pinning the Step 4 fallback order so it cannot silently regress
  - one Invariant #11 mechanical pin
    (`tests/runtime/test_decision_ref_resolution.py`,
    DEC-CLAUDEX-DECISION-REF-SCAN-001) — a filesystem-based scanner
    that asserts every `@decision-ref` / `Refs DEC-*` target in
    repo source has a matching `@decision DEC-X` declaration.
  - one Invariant #5 mechanical pin
    (`tests/runtime/policies/test_command_intent_single_authority.py`,
    DEC-CLAUDEX-COMMAND-INTENT-SOLE-AUTHORITY-001) — an AST-based
    scanner enforcing three rules over every `runtime/core/policies/*.py`
    module: Rule A (no `shlex` import), Rule B (no `.split(` on raw
    `tool_input["command"]` or variables bound to it), Rule C (any
    module that reads raw command text must consume the typed
    `command_intent` authority via import or `request.command_intent`
    attribute access). Rules A and B are absolute (not suppressible via
    `_KNOWN_EXEMPT_MODULES`); Rule C carries one documented exemption
    for `bash_tmp_safety.py` (literal-substring pattern detection only,
    no command-semantics parsing). Three scanner-self invariant tests
    mechanically pin the "Rules A/B never reference the allowlist"
    contract so a future regression cannot silently bypass the strict
    rules.
  - one current-lane state-authority scanner pin
    (`tests/runtime/test_current_lane_state_invariants.py`,
    DEC-CLAUDEX-CURRENT-LANE-STATE-INVARIANT-001) — a static scanner
    that pins the current-truth banners of `ClauDEX/CURRENT_STATE.md`
    and `ClauDEX/SUPERVISOR_HANDOFF.md` so they cannot silently fall
    behind the real staged-bundle count. Doc-specific active-region
    delimiters (line-anchored heading matches): `CURRENT_STATE.md` cuts
    at `## Checkpoint Readiness (Phase 8 Slice 12 closeout,
    2026-04-14)`; `SUPERVISOR_HANDOFF.md` cuts at `## Historical Phase
    State Snapshot` (NOT at `## Open Soak Issues`, which sits too high
    in the supervisor file and would hide current `## Current Restart
    Slice` guidance). Historical-context allowance is paragraph-scoped
    (between blank lines), not window-scoped. Includes regression pin
    that proves a stale bare count claim located between `## Open Soak
    Issues` and the historical snapshot delimiter IS detected.
  - one Invariant #13 symmetric retrieval-layer downstream pin
    (`tests/runtime/test_retrieval_layer_downstream_invariant.py`,
    DEC-CLAUDEX-RETRIEVAL-LAYER-DOWNSTREAM-INVARIANT-001) — an
    AST-based scanner that asserts the 25 canonical live-routing
    modules in `runtime/core/` plus every `runtime/core/policies/*.py`
    do NOT import `runtime.core.memory_retrieval` or
    `runtime.core.decision_digest_projection`. Closes the symmetric
    direction of CUTOVER_PLAN Invariant #13 — the existing
    `TestShadowOnlyDiscipline` in `test_memory_retrieval.py` covers
    "retrieval doesn't import live"; this new pin covers "live doesn't
    import retrieval as authority". `runtime/cli.py` is explicitly
    excluded from the scan set (acknowledged shadow-consumer of
    `decision_digest_projection` for read-only digest-render verbs).
  - one CUTOVER_PLAN phase-closure time-scoping pin
    (`tests/runtime/test_cutover_plan_phase_closure_invariants.py`,
    DEC-CLAUDEX-CUTOVER-PHASE-CLOSURE-INVARIANT-001) — an AST / regex
    scanner over `ClauDEX/CUTOVER_PLAN.md`'s `## Phase Plan` region
    asserting each `### Phase N — <title>` carries an explicit
    `Status: CLOSED <date>` annotation, allowed-vocabulary check,
    date-anchor check, and paragraph-scoped stale-future-tense guard.
    Paired with the `Status: CLOSED <date>` annotations added to
    Phases 0/1/2 (`pre-2026-04-13`), 2b (`2026-04-17`), 3-7
    (`2026-04-13`), 8 (`2026-04-14`) and the Execution-Model "Status
    note" preamble that reframes pre-cutover sequencing prose as
    historical. 14 tests; 4 synthetic fixtures (clean, missing-status,
    forbidden-marker, stale-future-tense).
  - one dated invariant-coverage-matrix artifact + one mechanical-pin
    companion (`ClauDEX/CUTOVER_INVARIANT_COVERAGE_2026-04-17.md` +
    `tests/runtime/test_cutover_invariant_coverage_matrix.py`,
    DEC-CLAUDEX-CUTOVER-INVARIANT-COVERAGE-MATRIX-001) — the dated
    matrix renders the current coverage status for CUTOVER_PLAN
    invariants #1-#16 (all 16 `covered`, each row citing at least one
    backing test file); the mechanical pin statically parses the
    artifact and asserts row-count (16), invariant-number coverage
    (set equals `{1..16}`), non-empty / non-placeholder backing-tests
    cells, and `covered` status discipline. Seven synthetic fixtures
    prove detection of every regression shape (missing row, empty
    backing, downgraded status, duplicate-row). Subordinate to
    CUTOVER_PLAN.md which remains architecture authority; the
    artifact is a derived projection, read-only in spirit.
  The bridge-parity additions for Invariant #15 (PostToolUse Bash wiring
  in `ClauDEX/bridge/claude-settings.json` + `REQUIRED_POSTTOOL_BASH_HOOKS`
  in `runtime/core/bridge_permissions.py` + `TestPostToolBashWiringPresent`
  in `tests/runtime/test_bridge_permissions.py`) are folded into those
  three existing staged paths, not new files.
- Lane: branch `claudesox-local` at HEAD `d7db4ba`, 11 commits ahead of
  `origin/feat/claudex-cutover` (behind-count time-variant).
- Focused test evidence (refreshed 2026-04-17 for full 30-file bundle):
  **309 passed in 8.18s** across the 11-file combined focused suite
  (pre-Invariant-#5 snapshot); plus
  `pytest -q tests/runtime/policies/test_command_intent_single_authority.py`
  → **14 passed in 0.05s** adding the new Invariant #5 scanner pin coverage:
  `pytest -q tests/runtime/test_bridge_permissions.py
  tests/runtime/test_bridge_validate_settings_cli.py
  tests/runtime/test_constitution_registry.py
  tests/runtime/policies/test_post_bash_eval_invalidation.py
  tests/runtime/test_hook_manifest.py
  tests/runtime/test_hook_validate_settings.py
  tests/runtime/test_hook_doc_validation.py
  tests/runtime/test_hook_doc_projection.py
  tests/runtime/test_hook_doc_check_cli.py
  tests/runtime/test_handoff_artifact_path_invariants.py
  tests/runtime/test_decision_ref_resolution.py`.
  Validator CLIs (re-run 2026-04-17):
  - `python3 runtime/cli.py bridge validate-settings` → exit 0, `{"status":"ok"}`
  - `python3 runtime/cli.py hook validate-settings` → exit 0, `{"status":"ok","healthy":true,"settings_repo_entry_count":31,"manifest_wired_entry_count":31,"missing_in_manifest":[],"missing_in_settings":[]}`
  - `python3 runtime/cli.py hook doc-check` → exit 0, `{"status":"ok","healthy":true,"exact_match":true,"expected_line_count":102,"candidate_line_count":102}` (content hash `sha256:7019769b9f7d8d4fd90cfab786f4aa4512f624ccb9cf8f7f70510040f66dbed7`).
  Codex independent verification seats accepted the combined scope across
  the six sub-slices: `1776406189098-0001-lqjleq`,
  `1776406882715-0003-7t7ugq`, `1776407137196-0001-3ql6ig`,
  `1776408220252-0004-2n7gcm`, `1776408476029-0005-jdg8g4`,
  `1776409725071-0001-7hvquf`, `1776411084446-0003-xs5p0d`
  (Invariant #11), `1776413402515-0001-zsj5f3` (supervisor Step 4
  fallback + handoff-invariant pins), and `1776413883321-0003-e8mgaw`
  (Invariant #11 integration). Earlier seat numbers preserved for audit.

### Recommended next supervisor action (current lane truth, 2026-04-17 late-session)

**This is the active recommended next action for the current lane.** The
similarly-titled subsection further down under "Checkpoint Readiness (Phase
8 Slice 12 closeout, 2026-04-14) — HISTORICAL SNAPSHOT" is a historical
artifact from the 2026-04-14 Phase-8 closeout and does NOT describe the
current lane.

The recommended action is a strict three-step sequence:

1. **Checkpoint the 7 dirty merge-blocker files.** These dirty tracked files
   overlap with files `origin/feat/claudex-cutover` would update on merge
   and must be committed first (routine non-destructive checkpoint, not a
   user decision boundary):
   `.codex/prompts/claudex_handoff.txt`,
   `.codex/prompts/claudex_supervisor.txt`, `CLAUDE.md`,
   `ClauDEX/CURRENT_STATE.md`, `ClauDEX/SUPERVISOR_HANDOFF.md`,
   `scripts/claudex-codex-model-guard.sh`,
   `scripts/claudex-supervisor-restart.sh`.
   The remaining 5 dirty tracked files do NOT overlap remote updates and
   can stay uncommitted.

2. **Merge upstream.** `git fetch origin feat/claudex-cutover` then
   `git merge origin/feat/claudex-cutover --no-edit`. Expect conflicts
   in up to 11 overlap files; resolve, test, commit merge.

3. **Push.** `cc-policy approval grant claudesox-local push` then
   `git push origin claudesox-local:feat/claudex-cutover`. Do NOT start
   a new implementation slice before the push lands.

2. **Then, bounded probe implementation slice for the
   `waiting_for_codex` response-surface drift** (post-checkpoint
   continuation contract is recorded in the Codex response for
   instruction `1776434532306-0002-c0n153`). The drift is classified as
   `broker_or_cache_surface_mismatch`, sub-class
   `degraded_dead_pid_stale_socket`, with HIGH confidence (env-divergence
   ruled out; `braid status` directly names the class; `ps -p <braidd
   pid>` confirms the pidfile is stale and the broker daemon is not
   running, while the Unix socket file persists on disk). Implementation
   delta is bounded to adding read-only CLIs
   (`cc-policy bridge probe-response-drift --run-id <id>`,
   `cc-policy bridge broker-health`) that surface the broker-health
   subobject and classify the drift class. No authority change to
   `runtime/core/bridge_permissions.py`, `.codex/prompts/claudex_supervisor.txt`
   Step 4, or `runtime.core.transport_contract`.

State-gating nuance captured in the diagnostic:
`$CLAUDEX_STATE_DIR/pending-review.json` is written when the run enters
`waiting_for_codex` and may be **absent** during `inflight`. Any probe or
consumer that reads this file must treat absence during `inflight` as a
non-error state, not as drift. This nuance is recorded in the
SUPERVISOR_HANDOFF.md bridge response-broker drift entry's late-session
verification note.

The existing `.codex/prompts/claudex_supervisor.txt` Step 4 fallback
rule remains the current mitigation and continues to apply end-to-end;
the narrower root-cause classification does not supersede it.

**Bridge probe CLIs landed this session (Option A, no new paths)** —
instruction `1776435335627-0008-n74wwg`. The two probe commands planned
for the post-checkpoint continuation slice were implemented within the
already-staged file set and are live on this lane now:

- `python3 -m runtime.cli bridge broker-health` — observed exit 0 with
  `status="degraded_dead_pid_stale_socket"`, `braidd_pid=89934`,
  `pid_alive=false`, `socket_exists=true`,
  `recovery_hint="braid down && braid up"`.
- `python3 -m runtime.cli bridge probe-response-drift --run-id
  1776367239-90135-af6087b8` — observed exit 0 with
  `status="broker_cache_miss_stale_socket"` and coherent
  `broker_health`, `pending_review`, `cursor`, and `env` sub-objects.

The probes are pure read-only (no filesystem writes, no subprocess
spawn, no runtime-DB writes) and fail-closed (missing artifacts produce
a classified JSON status, not a traceback). Test coverage:
`pytest -q tests/runtime/test_bridge_permissions.py
tests/runtime/test_bridge_validate_settings_cli.py` → 73 passed, 0
failed.

**Integration throttle — updated.** The three-step sequence at the
top of this subsection now applies: (1) checkpoint 7 dirty merge-blocker
files, (2) merge upstream, (3) push. The probe CLIs' availability in
the lane does NOT change the integration order, does NOT permit
unthrottled retry, and does NOT supersede the `Checkpoint-retry throttle
rule` recorded in `ClauDEX/SUPERVISOR_HANDOFF.md` § Checkpoint
Stewardship.

## Checkpoint Readiness (Phase 8 Slice 12 closeout, 2026-04-14) — HISTORICAL SNAPSHOT

**This section is a historical snapshot as of 2026-04-14 closeout.** It describes the lane state at Phase-8 slice-12 acceptance. It does NOT describe the current lane (2026-04-17) — see the "Status (current, 2026-04-17)" header at the top of this file for current truth. The "No checkpoint debt remains" claim below applies to the 2026-04-14 Phase-8 state only, not to the 2026-04-17 lane which carries a **28-file** harness-blocked staged bundle.

**Status (historical, 2026-04-14):** **CHECKPOINT LANDED.** Phase 8 is closed as accepted
(Slice 12 closeout and time-scoping correction accepted per Codex
instructions `1776138763332-0051-lxgl2p` and `1776139292226-0052-b15d20`).
The Final Acceptance Condition at `CUTOVER_PLAN.md:1532` is satisfied
12/12 against installed truth. The accepted ClauDEX cutover bundle
landed on `feat/claudex-cutover` as commit `6b8cc5c`
("feat(claudex): cutover bundle - Phases 1-8 closeout") and was pushed
to `origin/feat/claudex-cutover`. A follow-up auto-submit
process-control fix landed on the same branch as `d8fdf96` ("Fix
ClauDEX auto-submit process growth") and was also pushed. As of the
2026-04-14 Phase-8 closeout snapshot, no Phase-8 checkpoint debt
remained; the lane was `claudesox-local` tracking
`origin/feat/claudex-cutover` at HEAD `d8fdf96`. (Current 2026-04-17
lane state is different — see the top-of-file "Status (current,
2026-04-17)" banner.)

### Git state at handoff (installed truth)

- Current worktree branch: `claudesox-local` tracking
  `origin/feat/claudex-cutover` at HEAD `d8fdf96` (via
  `git status --short --branch`).
- Canonical cutover commits on `origin/feat/claudex-cutover`:
  `6b8cc5c` (Phases 1-8 bundle) and `d8fdf96` (auto-submit
  process-control fix on top of the bundle).
- Pre-checkpoint base: `c7a3109` on
  `origin/fix/enforce-rca-13-git-shell-classifier` — kept as
  historical reference only.
- Working-tree residual: a coherent follow-up maintenance bundle touching
  `ClauDEX/CURRENT_STATE.md`, `ClauDEX/SUPERVISOR_HANDOFF.md`, and
  `scripts/claudex-codex-launch.sh`. The doc edits align state records
  with landed checkpoint truth; the launcher edit pins the lane-local
  Codex supervisor to `gpt-5.3-codex` with `xhigh` reasoning, writes the
  braid-root hint consumed by the MCP wrapper, and records the current
  Codex upgrade prompt as dismissed. One untracked path
  `ClauDEX/DUAL_LANE_STABILITY_HANDOFF_2026-04-14.md` remains excluded
  from the cutover branch (lane/operator handoff).
- Excluded-artifact invariant (for the already-landed bundle — `.jsonl`,
  `.trace`, `.claude/`, `.b2r*`, `tmp/`, `.worktrees/`, `.env`,
  `secret`/`credential`, and any `runtime/` path outside
  `runtime/core/`, `runtime/cli.py`, `runtime/schemas.py`): held at
  bundle creation time; `runtime/core/prompt_pack_state.py` and peers
  are canonical authority, not runtime state.
- Scope classification: Phase 8 work is fully exhausted. There is no
  Phase 9 in `ClauDEX/CUTOVER_PLAN.md`. The current bounded action is to
  finish and checkpoint the follow-up maintenance bundle above, then
  resume either cutover-plan continuation (new architecture slice,
  explicitly scoped) or steady-state lane maintenance — **not** another
  Phase 8 checkpoint commit.

Historical staged-file summary (from the pre-landing checkpoint slice;
preserved for traceability — the bundle is now committed as
`6b8cc5c`):

| Area | Paths in bundle |
|---|---|
| `ClauDEX/` | 36 |
| `runtime/` | 53 |
| `tests/` | 113 |
| `hooks/` | 20 |
| `docs/` | 8 |
| `agents/` | 4 |
| `scripts/` | 16 |
| `.codex/` | 6 |
| `plugins/` | 1 |
| root / other | 6 |

(Sum: 263 at landing.)

Notable deletions (all intentional per Slices 2/4/5/6/10):
`agents/tester.md`, `docs/AGENT_HANDOFFS.md`,
`docs/HANDOFF_2026-03-31.md`, `docs/HANDOFF_2026-04-05_SYSTEM_EVAL.md`,
`hooks/auto-review.sh`, `hooks/check-tester.sh`, and 4 tester/auto-review
scenario tests (`test-check-tester-valid-trailer.sh`,
`test-check-tester-invalid-trailer.sh`, `test-completion-tester.sh`,
`test-routing-tester-completion.sh`, `test-auto-review.sh`,
`test-auto-review-heredoc.sh`, `test-auto-review-quoted-pipes.sh`).

Notable additions include the ClauDEX framework itself
(`ClauDEX/*.md`, `ClauDEX/bridge/**`), the Codex supervisor bundle
(`.codex/`), the claudex-* scripts, and the new runtime authorities
(`runtime/core/stage_registry.py`, `dispatch_shadow.py`,
`authority_registry.py`, `contracts.py`, `shadow_parity.py` plus the
many untracked Phase 2-7 modules).

### Verification gates at handoff

- `cc-policy constitution validate` →
  `concrete_count=24, planned_count=0, healthy=true, status=ok`.
- `cc-policy hook validate-settings` →
  `status=ok, healthy=true, settings_repo_entry_count=30,
  manifest_wired_entry_count=30, deprecated_still_wired=[],
  invalid_adapter_files=[]`.
- `cc-policy hook doc-check` →
  `status=ok, exact_match=true,
  expected_content_hash=sha256:11a24375...851b1e9e`.
- `pytest tests/runtime/test_phase8_deletions.py` → **169 passed**
  (per Slice 11 correction and Slice 12 re-runs).
- `pytest tests/runtime/` → **4124 passed** at handoff, with **3
  pre-existing unrelated failures** (`test_claudex_stop_supervisor.py::
  test_stop_hook_allows_stop_for_consumed_pending_review`,
  `test_claudex_watchdog.py::TestWatchdogSelfExecOnScriptDrift`,
  `test_subagent_start_payload_shape.py::
  TestPreToolAgentPayloadShape`). These predated the tester retirement
  chain and were acknowledged by Codex as out-of-scope for Slices
  10/11/11-correction; they were **not Phase 8 blockers**.

  **Update (2026-04-14, closeout-hardening slice):** all three
  pre-existing failures are now resolved without changing the authority
  model.
  - `test_stop_hook_allows_stop_for_consumed_pending_review` → passing.
    Fix: `.codex/hooks/stop_supervisor.py` now honors
    `codex-review-cursor.json`; when the cursor's `instruction_id` +
    `completed_at` match the active `pending-review.json`, the
    supervisor allows a normal stop instead of rearming. All 9 tests in
    `test_claudex_stop_supervisor.py` pass.
  - `TestWatchdogSelfExecOnScriptDrift` → passing.  Fix: pure
    test-infra: `tests/runtime/test_claudex_watchdog.py` now copies
    `scripts/claudex-common.sh` alongside the writable watchdog copy
    used by the self-exec test so the sourced lib resolves under
    `set -e`.  No watchdog behavior change.  All 24 tests in
    `test_claudex_watchdog.py` pass in a clean env.
  - `TestPreToolAgentPayloadShape::test_subagent_type_matches_subsequent_subagent_start_agent_type`
    → passing.  Fix: the previous strict "next-SubagentStart" pairing
    produced false mismatches on sessions with multiple interleaved
    agents.  The test now pins the actual write-key invariant the
    carrier depends on — "for every non-empty PreToolUse.subagent_type
    X in a session, there exists a SubagentStart.agent_type == X in the
    same session" — and explicitly excludes the documented
    empty-subagent_type no-carrier case.  All 12 tests in
    `test_subagent_start_payload_shape.py` pass.

  Runtime-suite note: the dirty-env case where `CLAUDEX_STATE_DIR` /
  `BRAID_ROOT` leak from a live supervised bridge into pytest produces
  additional watchdog failures because `PID_DIR` redirects to the real
  lane state dir.  Run the full `tests/runtime/` suite with
  `env -u CLAUDEX_STATE_DIR -u BRAID_ROOT pytest ...` for faithful
  counts.

### Recommended next supervisor action (cutover-plan continuation or maintenance)

Checkpoint stewardship is **complete**: the cutover bundle landed as
`6b8cc5c` and the process-control fix landed as `d8fdf96`, both on
`origin/feat/claudex-cutover`. Do not re-dispatch a checkpoint slice
against this lane.

The next bounded action is one of:

- **Cutover-plan continuation.** Re-read `ClauDEX/CUTOVER_PLAN.md`
  (the runtime-owned agent-session supervision fabric is the next
  architecture track beyond the bridge stack) and open a fresh,
  explicitly scoped slice only when ready. The canonical chain —
  planner → guardian (provision) → implementer → reviewer → guardian
  (merge) — still applies.
- **Narrow maintenance.** Documentation drift fixes, soak-test hygiene,
  focused gate reverification (e.g. the auto-submit / watchdog pair in
  a clean env), or other bounded items that do not open architecture
  work. State-authority documents (`ClauDEX/CURRENT_STATE.md`,
  `ClauDEX/SUPERVISOR_HANDOFF.md`) must stay aligned with installed
  truth as subsequent commits land.

Escalate to the user only under the standard checkpoint-stewardship
conditions (force/history rewrite, ambiguous push target, mixed
working tree, sensitive artifacts, or genuine architectural ambiguity).

## Materially Implemented

Phase 1 is materially present:

- stage/shadow/contracts:
  - `runtime/core/stage_registry.py`
  - `runtime/core/dispatch_shadow.py`
  - `runtime/core/shadow_parity.py`
  - `runtime/core/contracts.py`
- authority / schema / constitution:
  - `runtime/core/authority_registry.py`
  - `runtime/core/constitution_registry.py`
  - `runtime/core/decision_work_registry.py`
  - `runtime/core/projection_schemas.py`
  - `runtime/core/goal_contract_codec.py`
  - `runtime/core/work_item_contract_codec.py`
  - `runtime/core/workflow_contract_capture.py`

Phase 2 is well underway:

- prompt-pack and workflow-contract path:
  - `runtime/core/prompt_pack.py`
  - `runtime/core/prompt_pack_resolver.py`
  - `runtime/core/prompt_pack_state.py`
  - `runtime/core/prompt_pack_validation.py` ← single authority for SubagentStart
    request contract validator (`validate_subagent_start_prompt_pack_request`)
  - `runtime/core/prompt_pack_decisions.py`
- hook-adapter reduction and hook-doc surfaces:
  - `runtime/core/hook_manifest.py`
  - `runtime/core/hook_doc_projection.py`
  - `runtime/core/hook_doc_validation.py`
- SubagentStart runtime-first adapter path (mechanically test-backed):
  - `hooks/subagent-start.sh` — thin transport adapter: contract-present payloads
    route to `cc-policy prompt-pack subagent-start`; contract-absent payloads
    take the legacy shell-built path; errors are surfaced without fallback
  - `tests/runtime/test_subagent_start_hook.py` — 31 tests covering all 5
    routing invariants (happy path, legacy path, compile error, partial contract,
    validation violations)

Operator / bridge scaffolding exists:

- `.codex/`
- `ClauDEX/bridge/`
- `scripts/claudex-*.sh`
- `hooks/claudex-*.sh`

## Verified Test Surface

Verified locally in this repo (full runtime suite most recent run):

- `tests/runtime/` — 2991 passed, 1 xpassed

This covers:

- stage registry, shadow dispatch / parity
- authority / constitution / decision-work registries
- projection schemas, goal/work-item/workflow contracts
- prompt-pack family (compiler, resolver, state, decisions, validation)
- hook-manifest / hook-doc validation family
- SubagentStart hook routing (47 tests: 5 routing invariants + 5 carrier path + 17 reviewer dispatch-entry + severity pins)
- SubagentStart payload shape pins (12 tests from captured production events)
- pending_agent_requests table + CLI (23 tests)
- pre-agent.sh carrier write leg (17 tests, including 5 end-to-end hook chain tests)
- agent_prompt producer helper + `cc-policy dispatch agent-prompt` CLI (43 tests)

Key live-capture pin (from `tests/runtime/test_subagent_start_payload_shape.py`):
Real SubagentStart payloads from `runtime/dispatch-debug.jsonl` carry exactly:
`session_id, transcript_path, cwd, agent_id, agent_type, hook_event_name`.
The six contract fields (`workflow_id`, `stage_id`, `goal_id`, `work_item_id`,
`decision_scope`, `generated_at`) are absent from all 40 captured events.

**Carrier transport status:** IMPLEMENTED and fully test-backed (57 tests across
three test files).

**Producer status:** IMPLEMENTED and fully test-backed (43 tests). The
`cc-policy dispatch agent-prompt --workflow-id W --stage-id S` CLI resolves the
six contract fields from runtime state (active goal and in_progress work item)
and returns a `prompt_prefix` that starts with the `CLAUDEX_CONTRACT_BLOCK:`
line at column 0 — directly parseable by `pre-agent.sh`'s grep.

**Operator wiring status: IMPLEMENTED** — `CLAUDE.md` "Dispatch Rules" §
"ClauDEX Contract Injection" now contains the canonical rule instructing the
orchestrator to call `cc-policy dispatch agent-prompt --workflow-id <W>
--stage-id <S>` before every Agent tool dispatch and to prepend the returned
`prompt_prefix` verbatim (preserving `CLAUDEX_CONTRACT_BLOCK:` at column 0).

**Live verification: CONFIRMED (2026-04-09).** A real Agent dispatch in this
session produced a `dispatch-debug.jsonl` entry (entry 39 of 39) whose
`tool_input.prompt` starts with `CLAUDEX_CONTRACT_BLOCK:` on line 1.
Production reachability is proven. Phase 2b gate cleared.

## Current Bridge Reality

The bridge work is not the architecture goal. It only exists to keep Codex in
the driver seat for the cutover.

What is true now:

- `hooks/claudex-submit-inject.sh` was patched to normalize repeated
  sentinel-only prompts before they hit braid
- that fix was manually proven against a live braid run: it emitted the correct
  `additionalContext` and moved queue -> `inflight.json`
- `scripts/claudex-watchdog.sh` was patched to reduce helper drift and stale
  duplicate process multiplication
- repo-local `.codex/config.toml` was updated so bridge tools are trusted and
  auto-approved for the local Codex supervisor seat

What is still not trustworthy:

- fresh operator sessions have still shown cases where the bridge remains
  `idle` and no initial instruction is actually seeded
- therefore a fresh supervised run should not assume the operator bootstrap is
  already reliable enough to seed work unattended

## Architectural Direction (2026-04-09)

The current braid/tmux supervisor stack is a containment path, not the target
ClauDEX architecture.

Chosen direction:

- supervision becomes a runtime-owned domain with canonical records for
  `agent_sessions`, `seats`, `supervision_threads`, and `dispatch_attempts`
- `tmux` remains useful as the universal execution/attachment surface for
  arbitrary CLI agents, but only as a transport adapter
- MCP or provider-native control surfaces are preferred adapters when an agent
  exposes them, but they plug into the same runtime-owned supervision model
- queue files, sentinel prompts, pane text, pid files, and bridge logs are
  diagnostics or transitional transport only, never authority

Implication:

- do not spend the cutover polishing the current bridge into a permanent
  product
- the next architecture track after the current carrier slice is the
  agent-agnostic supervision fabric described in `ClauDEX/CUTOVER_PLAN.md`
- any future bridge work should be judged by whether it collapses into that
  runtime-owned transport interface instead of adding another transport-specific
  control path

## Completed Slices (this session)

These slices are done and test-backed:

1. **SubagentStart payload shape pins** — `tests/runtime/test_subagent_start_payload_shape.py`
   captures the live harness payload shape and pins the gap: contract fields absent.

2. **Single-authority request validator** — `validate_subagent_start_prompt_pack_request`
   moved to `runtime/core/prompt_pack_validation.py` as the sole public authority.
   `prompt_pack.py` calls it via function-local import (breaks module-level load cycle).
   Guard tests narrowed to allow function-local imports while blocking module-level
   reverse imports.

3. **SubagentStart hook-adapter reduction** — `hooks/subagent-start.sh` runtime-first
   path verified and tightened. 31 tests in `tests/runtime/test_subagent_start_hook.py`
   cover all 5 routing invariants.

4. **SubagentStart contract carrier transport** (DEC-CLAUDEX-SA-CARRIER-001) —
   transport layer complete (57 tests). Producer gap identified.

5. **Carrier producer** (DEC-CLAUDEX-AGENT-PROMPT-001) — `runtime/core/agent_prompt.py`
   + `cc-policy dispatch agent-prompt` CLI. Resolves workflow_id, stage_id, goal_id,
   work_item_id, decision_scope, generated_at from runtime state and returns a
   `prompt_prefix` with `CLAUDEX_CONTRACT_BLOCK:` on line 1. 43 tests in
   `tests/runtime/test_agent_prompt.py`. Full suite: 2991 passed, 1 xpassed.
   Remaining gap: operator wiring (instructing orchestrator to call the CLI and
   prepend the prefix) — no further code required.
   `runtime/schemas.py` + `runtime/core/pending_agent_requests.py` provide the
   `pending_agent_requests` SQLite table and helpers. `hooks/pre-agent.sh`
   extracts `CLAUDEX_CONTRACT_BLOCK` from `tool_input.prompt` and writes the
   carrier row. `hooks/subagent-start.sh` atomically consumes the row before the
   `_HAS_CONTRACT` check, merging the six contract fields into HOOK_INPUT.
   57 tests across three files prove the full carrier chain end-to-end including
   the pre-agent.sh write leg and the two-hook handoff.
   **Remaining gap (transport only):** no repo-owned code yet embeds
   `CLAUDEX_CONTRACT_BLOCK` in live Agent tool prompts. Fixed by slice 5.

5. **Carrier producer** (DEC-CLAUDEX-AGENT-PROMPT-001) — `cc-policy dispatch
   agent-prompt` CLI + `runtime/core/agent_prompt.py` helper. Resolves the six
   contract fields from runtime state and returns a `prompt_prefix` with
   `CLAUDEX_CONTRACT_BLOCK:` on line 1. 43 tests in
   `tests/runtime/test_agent_prompt.py`. Full suite: 2991 passed, 1 xpassed.

## Phase 2b — Supervision Domain Schema (Completed 2026-04-09)

Schema authority seeded. DEC-CLAUDEX-SUPERVISION-DOMAIN-001 accepted.

Four tables added to `runtime/schemas.py` as the sole runtime authority for
the supervision fabric (all via `ensure_schema`):

| Table | Purpose |
|---|---|
| `agent_sessions` | One live agent instance bound to a workflow and transport |
| `seats` | Named role within a session: worker, supervisor, reviewer, observer |
| `supervision_threads` | Explicit seat→seat supervision relationship |
| `dispatch_attempts` | Single issued instruction with delivery claim, ack, retry, timeout |

Status/role constants also added:
`AGENT_SESSION_STATUSES`, `SEAT_STATUSES`, `SEAT_ROLES`,
`SUPERVISION_THREAD_STATUSES`, `SUPERVISION_THREAD_TYPES`,
`DISPATCH_ATTEMPT_STATUSES`

Invariant coverage: `tests/runtime/test_supervision_schema.py` — 42 tests:
table existence, core columns + defaults, FK-reference columns, status
constants, INSERT/SELECT round-trips, idempotency, index existence.

Full suite: 3033 passed, 1 xpassed, 1 pre-existing live-corpus pin failure
(unrelated to this slice — caused by the Phase 2a live verification dispatch).

**Boundaries held:** No tmux/MCP/watchdog wiring. No adapter contracts,
claim/ack helpers, or recovery loops. Schema-only bundle.

**Next slice completed (2026-04-09):** `dispatch_attempts` domain helper
`runtime/core/dispatch_attempts.py` — full state-machine authority (52 tests).
See Phase 2b domain surface below.

**Transport-adapter contract (completed 2026-04-09):** `runtime/core/transport_contract.py`
(Protocol + registry) + `runtime/core/claude_code_adapter.py` (first adapter). 28 tests.
See Phase 2b adapter surface below.

**Hook wiring slice: COMPLETED 2026-04-09** — `dispatch_hook.py` bridges
harness events to `dispatch_attempts` state. See Phase 2b Hook Wiring section.

**Live integration verification: PASSED 2026-04-09.**
Agent dispatch with `subagent_type="Explore"` + CLAUDEX_CONTRACT_BLOCK prefix
produced `dispatch_attempts` row at `delivered` in `.claude/state.db`.
Full evidence: `attempt_id=85afda17…`, `seat_id=2ac4ff0e…:Explore`, `role=worker`,
`workflow_id=claudex-phase2b-verify`, `delivery_claimed_at` set, `acknowledged_at=NULL`.
Carrier row consumed atomically; zero residual rows in `pending_agent_requests`.

**Operator requirement from live capture (added to `CLAUDE.md` § ClauDEX Contract Injection):**
`subagent_type` must be set explicitly on every Agent tool call in the ClauDEX
delivery path. When omitted, `tool_input.subagent_type` is empty in PreToolUse
and the entire delivery-tracking path is silently skipped.

**`expire_stale()` watchdog integration: COMPLETED 2026-04-09**
`cc-policy dispatch attempt-expire-stale` CLI command added. `expire_stale_dispatch_attempts()`
function wired into `watchdog_tick()` (runs every tick, best-effort). Authority
stays in Python; watchdog shell just invokes the CLI. 8 new tests (3 CLI in
`test_dispatch_hook.py`, 5 watchdog integration in `test_claudex_watchdog.py`).
Full Phase 2b suite: 152 passed.

**`tmux` transport adapter: COMPLETED 2026-04-09** — `runtime/core/tmux_adapter.py`
(`TmuxAdapter` + auto-registration). Second adapter behind the same `TransportAdapter`
protocol. 31 tests in `tests/runtime/test_tmux_adapter.py`. Full Phase 2b suite: 183 passed.
See Phase 2b Tmux Adapter section below.

**Phase 2b complete.** See Phase 3 section below for current state.

## Phase 2b — Supervision Domain Authority Surface (Completed 2026-04-09)

`runtime/core/dispatch_attempts.py` — sole authority for `dispatch_attempts` state.

Public API:

| Function | Transition / Effect |
|---|---|
| `issue(conn, seat_id, instruction, *, workflow_id, timeout_at)` | Creates `pending` attempt; returns dict with `attempt_id` |
| `claim(conn, attempt_id)` | `pending` → `delivered`; sets `delivery_claimed_at` |
| `acknowledge(conn, attempt_id)` | `delivered` → `acknowledged` (terminal); sets `acknowledged_at` |
| `fail(conn, attempt_id)` | `delivered` → `failed` |
| `cancel(conn, attempt_id)` | `pending` → `cancelled` (terminal) |
| `timeout(conn, attempt_id)` | `pending\|delivered` → `timed_out` |
| `retry(conn, attempt_id)` | `timed_out\|failed` → `pending`; increments `retry_count`, clears `delivery_claimed_at` |
| `get(conn, attempt_id)` | Fetch one attempt by ID |
| `list_for_seat(conn, seat_id, *, status)` | List attempts for a seat, optionally filtered |
| `expire_stale(conn)` | Sweep `pending`/`delivered` past `timeout_at` → `timed_out`; returns count |

Invalid transitions raise `ValueError`. State machine table encoded in
`_VALID_TRANSITIONS` — no ad-hoc status checks scattered in callers.

No adapter code wired. `dispatch.py` (legacy `dispatch_queue`/`dispatch_cycles`)
is orthogonal — DEC-WS6-001 marks that domain non-authoritative for routing.

## Phase 2b — Transport-Adapter Contract (Completed 2026-04-09)

`runtime/core/transport_contract.py` — `TransportAdapter` Protocol + registry.

`runtime/core/claude_code_adapter.py` — `ClaudeCodeAdapter` (first adapter, auto-registered).

**Why `claude_code` first:** Harness events (PreToolUse:Agent, SubagentStart, SubagentStop)
are deterministic delivery oracles with no pane-scraping or sentinel involvement. The
`tmux` adapter is deferred because its delivery confirmation requires sentinel-echo or
pane-read steps that are transport-diagnostic, not runtime-authoritative.

| Adapter method | Harness event | Transition |
|---|---|---|
| `dispatch(conn, seat_id, instruction)` | PreToolUse:Agent | → `pending` |
| `on_delivery_claimed(conn, attempt_id)` | SubagentStart | `pending` → `delivered` |
| `on_acknowledged(conn, attempt_id)` | (no automatic trigger; explicit caller only) | `delivered` → `acknowledged` |
| `on_failed(conn, attempt_id)` | transport-layer failure only | `delivered` → `failed` |
| `on_timeout(conn, attempt_id)` | watchdog sweep | `pending\|delivered` → `timed_out` |

**Domain boundary:** `SubagentStop` is work completion, owned by `completions.py`.
It must never be mapped to `on_acknowledged()`. The delivery domain ends at
`delivered`; `on_acknowledged()` has no automatic harness trigger for `claude_code`.

Registry: `get_adapter("claude_code")` → `ClaudeCodeAdapter` instance.

**Hook wiring: COMPLETED 2026-04-09** — see Phase 2b Hook Wiring section below.

## Phase 2b — Tmux Transport Adapter (Completed 2026-04-09)

`runtime/core/tmux_adapter.py` — `TmuxAdapter` (second adapter, auto-registered as `"tmux"`).

DEC-CLAUDEX-TRANSPORT-TMUX-001 accepted.

Design: pure domain translator — never reads or writes tmux pane state. The external
observer (watchdog/sentinel reader) owns pane interaction; this adapter owns the mapping
from caller-supplied delivery evidence to `dispatch_attempts` state transitions.

| Adapter method | Trigger | Transition |
|---|---|---|
| `dispatch(conn, seat_id, instruction)` | Orchestrator writes instruction to pane | → `pending` |
| `on_delivery_claimed(conn, attempt_id)` | Caller confirms sentinel echo in pane capture | `pending` → `delivered` |
| `on_acknowledged(conn, attempt_id)` | Pane emits explicit receipt sentinel (`__RECEIPT_ACK__`) | `delivered` → `acknowledged` |
| `on_failed(conn, attempt_id)` | Pane process exits before delivery claim | `delivered` → `failed` |
| `on_timeout(conn, attempt_id)` | Sentinel not confirmed within `timeout_at` window | `pending\|delivered` → `timed_out` |

Key distinctions from `claude_code`:
- `on_delivery_claimed()` is **NOT automatic** — requires external sentinel observation
- `on_acknowledged()` has genuine utility (receipt sentinel before work begins)
- Pane IDs, sentinel strings, pane capture output are transport evidence, NOT stored in `dispatch_attempts`

Registry: `get_adapter("tmux")` → `TmuxAdapter` instance. Both `"tmux"` and `"claude_code"`
coexist in the sorted registry after their modules are imported.

Invariant coverage: `tests/runtime/test_tmux_adapter.py` — 31 tests:
- Protocol/registry (6 tests), dispatch() (6 tests), state transitions (12 tests),
  full-path scenarios (4 tests), invalid-transition guards (3 tests), semantic pins (4 tests)

## Phase 2b — Hook Wiring (Completed 2026-04-09)

`runtime/core/dispatch_hook.py` — DEC-CLAUDEX-HOOK-WIRING-001.

Two functions bridge harness events to `dispatch_attempts` state:

| Function | Called by | Hook event |
|---|---|---|
| `record_agent_dispatch(conn, session_id, agent_type, instruction, *, workflow_id, timeout_at)` | `pre-agent.sh` | PreToolUse:Agent |
| `record_subagent_delivery(conn, session_id, agent_type)` | `subagent-start.sh` | SubagentStart |

`ensure_session_and_seat(conn, session_id, agent_type)` — idempotent upsert of
`agent_sessions` + `seats` rows so hooks never need pre-provisioning.
`seat_id` is derived as `"{session_id}:{agent_type}"` (stable, deterministic).

CLI surface added to existing `dispatch` subparser:
- `cc-policy dispatch attempt-issue --session-id S --agent-type T --instruction I [--workflow-id W]`
- `cc-policy dispatch attempt-claim --session-id S --agent-type T`

Both are best-effort: errors suppressed with `|| true`; never block dispatch.

Hook modifications:
- `hooks/pre-agent.sh` — after writing the carrier row, calls `attempt-issue`
  with `CLAUDE_POLICY_DB=$_CARRIER_DB` and `$_BLOCK_LINE` as instruction.
- `hooks/subagent-start.sh` — after consuming the carrier row, calls
  `attempt-claim` via `_local_cc_policy`.

Invariant coverage: `tests/runtime/test_dispatch_hook.py` — 23 tests:
unit tests for all three public functions + 3 CLI integration tests.

## Phase 3 — Capability-Gated Policy Model (Completed 2026-04-13)

Seven slices landed:

**Slice 1: Capability contract authority** — `runtime/core/authority_registry.py`
extended with `StageCapabilityContract` (frozen dataclass), `resolve_contract(stage)`,
and `all_contracts()`. Contracts bundle granted/denied capability sets and a read_only
flag into a projectable record. `as_prompt_projection()` returns JSON-serializable,
deterministic dicts for prompt-pack compilation. 32 new tests in
`tests/runtime/test_authority_registry.py` (90 total).

**Slice 2: Docstring authority correction** — `authority_registry.py` module docstring
updated to distinguish live-for-policy-engine (capabilities_for() used by
`policy_engine.build_context()` and `enforcement_config`) from shadow-only-for-routing
(dispatch_engine, completions still isolated). Test class renamed
`TestShadowOnlyDiscipline` → `TestImportDiscipline` with updated comments.

**Slice 3: Prompt-pack stage contract wiring** — `prompt_pack_resolver.py::render_stage_contract_layer()`
now resolves capabilities via `ar.resolve_contract(stage)` instead of recomputing
`ar.capabilities_for()` + `ar.CAPABILITIES - caps`. Uses `contract.granted`,
`contract.denied`, `contract.read_only`, and `contract.stage_id` (for verdict lookup).
Reviewer gets explicit "Read-only: yes" line. Live-role aliases (e.g. "Plan", "guardian")
canonicalize through the contract. 17 new tests in `tests/runtime/test_prompt_pack_resolver.py`
(170 total).

**Slice 4: Reviewer git read-only gate** — `bash_git_who.py` now denies classified
git operations (commit, merge, push) when `READ_ONLY_REVIEW` is present in
`request.context.capabilities`, checked after meta-repo bypass but before lease
`allowed_ops` evaluation. A permissive lease cannot override the capability denial.
`leases.ROLE_DEFAULTS` includes reviewer with empty `allowed_ops` and
`requires_eval=False`. 8 new tests in `tests/runtime/policies/test_bash_git_who.py`
(23 total); 1 new test in `tests/runtime/test_leases.py`.

**Slice 5: Runtime CLI capability-contract projection** — `cc-policy context
capability-contract --stage <stage>` returns the `StageCapabilityContract.as_prompt_projection()`
payload as JSON. Live-role aliases (e.g. "Plan", "guardian") canonicalize through
`resolve_contract()`. Unknown and sink stages fail closed with nonzero exit. 8 tests
in `tests/runtime/test_hook_bridge.py::TestContextCapabilityContract`.

**Slice 6: Capability-gate invariant coverage** — `tests/runtime/policies/test_capability_gate_invariants.py`
adds 25 AST-based tests pinning that all five migrated policy files (`write_who`,
`write_plan_guard`, `bash_worktree_creation`, `bash_git_who`, `enforcement_config`)
authorize via capability constants and `context.capabilities`, not raw role-name
string comparisons. Cross-cutting tests verify no `is_<role>` helpers are defined or
imported. Protected policy tests (86 total across 5 files) confirmed no regressions.

**Slice 7: Phase 3 exit-criteria audit** — `ready_to_mark_phase3_complete: true`.
All four CUTOVER_PLAN Phase 3 exit criteria verified:

1. Reviewer read-only rules enforceable mechanically — `READ_ONLY_REVIEW` gates in
   `bash_git_who`, capability denial in `write_who`/`write_plan_guard`/`bash_worktree_creation`,
   empty `ROLE_DEFAULTS` for reviewer.
2. Policy modules no longer depend on scattered role folklore — zero `actor_role ==`
   comparisons in `runtime/core/policies/`; AST invariant tests prevent regression.
3. Stage contracts projectable into prompt packs deterministically —
   `StageCapabilityContract.as_prompt_projection()` → sorted JSON; `render_stage_contract_layer()`
   uses `resolve_contract()` as sole source; `cc-policy context capability-contract` CLI.
4. Planner and guardian have distinct continuation authorities — `STAGE_CAPABILITIES`
   declares disjoint capability sets; `TestContractDistinctness` (4 tests) + `TestRoleBoundaries`
   (5 tests) pin distinctness.

Existing migrated policy gates (all capability-based, invariant-tested):
- `write_who.py` → `CAN_WRITE_SOURCE`
- `write_plan_guard.py` → `CAN_WRITE_GOVERNANCE`
- `bash_worktree_creation.py` → `CAN_PROVISION_WORKTREE`
- `bash_git_who.py` → `READ_ONLY_REVIEW`
- `enforcement_config.py` → `CAN_SET_CONTROL_CONFIG`

**Phase 3 complete.**

### Phase 4 — Workflow Reviewer Introduction (COMPLETE 2026-04-13)

10 slices landed:

1. **Reviewer completion schema** — REVIEW_VERDICT/REVIEW_HEAD_SHA/REVIEW_FINDINGS_JSON required fields, verdict vocabulary from stage_registry.REVIEWER_VERDICTS (DEC-COMPLETION-REVIEWER-001).
2. **REVIEW_FINDINGS_JSON structural validation** — JSON shape, `findings` list of objects, per-finding required fields (severity/title/detail), canonical severity from schemas.FINDING_SEVERITIES, optional field type guards (line >= 1, reviewer_round >= 0, bool rejected).
3. **Findings persistence from completions** — `reviewer_findings.ingest_completion_findings()` bridge helper; `completions.submit()` persists atomically for valid reviewer completions. Invalid completions do not persist findings.
4. **Prompt-pack scoped-findings fix** — effective_work_item_id derived from resolved contract.
5. **Reviewer routing in determine_next_role** — derived from stage_registry.next_stage() via _STAGE_TO_ROLE. reviewer verdicts route to guardian/implementer/planner. Legacy routes unchanged.
6. **Reviewer dispatch wiring** — dispatch_engine + dispatch_shadow handle reviewer via _route_from_completion. Shadow parity on all three verdicts.
7. **Reviewer SubagentStop harness support** — check-reviewer.sh, settings.json group, hook_manifest entries.
8. **Reviewer dispatch-entry guidance** — subagent-start.sh recognizes reviewer, agents/reviewer.md, CLAUDE.md updated, severity vocabulary pinned to FINDING_SEVERITIES.
9. **Convergence test fixture fix** — test_reviewer_convergence.py findings_json default corrected from bare list `"[]"` to `'{"findings": []}'` matching runtime validator expectations. 38 convergence tests now passing.
10. **Phase 4 exit-criteria audit** — all five CUTOVER_PLAN criteria verified with mechanical evidence (see below).

**Exit-criteria verification:**

1. **Runtime can represent reviewer completions and findings natively** — PASS.
   - `completions.py` ROLE_SCHEMAS["reviewer"]: 3 required fields, REVIEWER_VERDICTS vocabulary.
   - `_validate_findings_json()`: JSON shape, per-finding required fields, severity vocabulary from FINDING_SEVERITIES, optional field type guards.
   - `reviewer_findings.py`: full domain API (insert, ingest, upsert, get, list, resolve/waive/reopen, status transitions).
   - `schemas.py`: reviewer_findings table with indexes, FINDING_SEVERITIES/FINDING_STATUSES constants.
   - `completions.submit()`: persists findings atomically for valid reviewer completions.
   - Evidence: 51 tests in test_completions.py, 77 in test_reviewer_findings.py (128 total).

2. **Reviewer is read-only by policy** — PASS.
   - `authority_registry.py`: reviewer granted {READ_ONLY_REVIEW, CAN_EMIT_DISPATCH_TRANSITION}, denied all write/land/provision/config capabilities. Contract read_only=True.
   - `bash_git_who.py`: READ_ONLY_REVIEW gate denies commit/merge/push before lease validation.
   - `write_who.py`: CAN_WRITE_SOURCE check denies source writes.
   - `write_plan_guard.py`: CAN_WRITE_GOVERNANCE check denies governance writes.
   - `bash_worktree_creation.py`: CAN_PROVISION_WORKTREE check denies worktree creation.
   - `leases.py` ROLE_DEFAULTS: reviewer has empty allowed_ops, requires_eval=False.
   - Evidence: 8 tests in test_authority_registry.py (TestReviewerReadOnly + TestReviewerContractReadOnly), 8 in test_bash_git_who.py (Phase 3 READ_ONLY_REVIEW section), AST invariants in test_capability_gate_invariants.py, 1 in test_leases.py.

3. **New workflow lane can run in shadow or staged mode without split authority claims** — PASS.
   - `dispatch_shadow.py`: reviewer in KNOWN_LIVE_ROLES, identity-mapped in map_live_to_shadow_stage(), reviewer destination + ready_for_guardian→GUARDIAN_LAND in translate_live_next_role().
   - `dispatch_engine.py`: reviewer in _known_types, uses _route_from_completion (same as tester), worktree_path on needs_changes.
   - `completions.py`: reviewer routing derived from stage_registry.next_stage() via _STAGE_TO_ROLE. (Phase 5 slice 1 cut implementer→tester to implementer→reviewer.)
   - Reviewer is purely additive — no existing authority replaced or overridden.
   - Evidence: 8 shadow tests, 11 dispatch tests.

4. **Reviewer outputs validated against interaction schemas** — PASS.
   - ROLE_SCHEMAS enforces 3 required fields + verdict vocabulary.
   - _validate_findings_json() enforces JSON structure, per-finding fields, severity vocabulary, optional field types.
   - submit() calls validate_payload(); invalid completions set valid=0.
   - dispatch_engine: _route_from_completion returns PROCESS ERROR for invalid completions; no auto-dispatch.
   - check-reviewer.sh: submits via rt_completion_submit, checks valid field, reports contract errors.
   - No freeform prose acceptance path exists.
   - Evidence: 30+ validation tests in test_completions.py, test_reviewer_invalid_completion_returns_error in test_dispatch_engine.py.

5. **Convergence state is explicit and invalidates correctly on post-review source changes** — PASS.
   - `reviewer_convergence.py` (DEC-CLAUDEX-REVIEWER-CONVERGENCE-001): assess() computes readiness on demand with 6 deterministic reason codes. ReviewerReadiness frozen dataclass with typed fields.
   - Stale head detection: when completion's REVIEW_HEAD_SHA != current_head_sha, returns ready_for_guardian=False with reason=REASON_STALE_HEAD.
   - Open blocking finding detection: when open findings with severity=blocking exist, returns ready_for_guardian=False with reason=REASON_OPEN_BLOCKING.
   - Priority ordering: invalid_completion > verdict_not_ready > stale_head > open_blocking_findings.
   - Module is read-only by design — composes existing authorities (completions, reviewer_findings, stage_registry) without importing routing, evaluation, hooks, or policies.
   - Evidence: 38 tests in test_reviewer_convergence.py covering all 6 reason codes, priority ordering, work_item scoping, deterministic latest selection, and isolation invariants.

**Phase 4 complete.**

### Phase 5 — Loop Activation and Tester Removal (COMPLETE 2026-04-13)

**Slice 1: Cut live implementer→tester to implementer→reviewer (DEC-PHASE5-ROUTING-001)**

Source changes:
- `completions.py`: implementer routes to reviewer (all 3 verdicts). Tester entries removed from `_routing` dict. `determine_next_role("tester", ...)` returns None.
- `dispatch_engine.py`: implementer branch sets `next_role="reviewer"`, populates worktree_path for reviewer. `evaluation.set_status(conn, wf, "pending")` removed (tester-readiness coupling). Tester branch neutralized: releases lease only, no routing.
- `dispatch_shadow.py`: docstring updated to mark tester→reviewer collapse as legacy. No functional changes — shadow already correctly maps implementer→IMPLEMENTER and reviewer→REVIEWER.

Test changes:
- `test_completions.py`: tester routing → None, implementer routing → reviewer. Lifecycle test updated.
- `test_dispatch_engine.py`: all implementer assertions → reviewer. Tester tests neutralized (no routing, no auto-dispatch). Full cycle test uses reviewer instead of tester. Phase 4 regression test updated.
- `test_dispatch_shadow.py`: implementer→tester collapse test → implementer→reviewer direct parity. Tester integration tests updated for neutralized live routing. Shadow crash/error/JSON tests switched from tester to reviewer.

Evidence: 210 tests pass (completions + dispatch_engine + dispatch_shadow), 53 hook tests pass. 263 total, 0 failures.

**Slice 2: Remove stop-review influence from workflow dispatch (DEC-PHASE5-STOP-REVIEW-SEPARATION-001)**

Source changes:
- `dispatch_engine.py`: `_check_codex_gate` deleted entirely — no runtime consumer remains. `codex_blocked`/`codex_reason` removed from result dict. `CODEX BLOCK` suggestion append removed. Decision annotation added.
- `cli.py`: `codex_blocked`/`codex_reason` removed from JSON serialization.

Test changes:
- `test_dispatch_engine.py`: 7 old W-AD-3 gate tests replaced with 6 separation invariant tests proving: (a) BLOCK cannot set auto_dispatch=False, (b) next_role unchanged by events, (c) codex_blocked/codex_reason absent from result, (d) CODEX BLOCK absent from suggestion.

Doc changes:
- `CLAUDE.md`: "Stop the chain" list no longer includes Codex stop-review BLOCK. Note documents gate as non-authoritative.
- `docs/DISPATCH.md`: Gate description updated — user-facing review lane only, non-authoritative for dispatch.
- `hooks/HOOKS.md`: post-task.sh description updated for Phase 5 routing + stop-review separation.
- `settings.json`: stop-review-gate-hook.mjs retained for user-facing review; documented as non-authoritative.

Evidence: 263 targeted tests pass (same suite as slice 1), 0 failures.

**Slice 3: stage_registry as single implementer/reviewer routing authority**

Source changes:
- `completions.py`: removed 3 literal implementer entries from `_routing` dict. `determine_next_role()` delegates both implementer and reviewer to `stage_registry.next_stage()` via `_STAGE_TO_ROLE`. Guardian literal routing untouched (Phase 6 scope).
- `stage_registry.py`: decision status updated from "proposed (shadow-mode)" to "accepted (live for implementer/reviewer routing)". Stale claims removed: "not imported by completions", "does not replace determine_next_role yet", "shadow-mode" labels. Module docstring reflects partial-delegation truth.

Test changes:
- `test_completions.py`: added `test_implementer_routing_matches_stage_registry` (behavioral parity, matching existing reviewer test). Added `test_no_literal_routing_for_registry_delegated_roles` (AST structural invariant — fails if any dict literal in `determine_next_role()` contains tuple keys for implementer/reviewer/tester).

Evidence: 253 pytest + 12 scenario = 265 targeted tests, 0 failures.

**Phase 5 exit audit (2026-04-13):**

All four CUTOVER_PLAN exit criteria verified with mechanical evidence:

1. **Workflow routing no longer depends on tester** — `determine_next_role("tester", ...)` returns None for all verdicts. No tester entries in `_routing` dict. AST invariant test forbids literal tester tuple keys. 2 tests pin this.
2. **Regular Stop review cannot affect workflow routing** — `_check_codex_gate` deleted. No `codex_blocked`/`codex_reason` in dispatch_engine result. 6 separation invariant tests + 12 scenario checks prove BLOCK events cannot set auto_dispatch=False.
3. **Reviewer is the sole technical readiness authority before guardian** — only `determine_next_role("reviewer", "ready_for_guardian")` returns `"guardian"`. No other (role, verdict) pair reaches guardian through routing. Verified by exhaustive check across planner/implementer/tester.
4. **The implementer/reviewer loop is canonical and test-backed** — `implementer→reviewer` and `reviewer(needs_changes)→implementer` both derive from `stage_registry.next_stage()`. Behavioral parity tests + AST structural invariant + stage_registry tests pin the loop. 265 targeted tests, 0 failures.

Next cutover phase: **Phase 6 — Goal Continuation Activation.**

## Current Restart Slice

**Phase 6 — Goal Continuation Activation: IN PROGRESS.**

**Slice 1 complete: Planner completion contract seed.**

Source changes:
- `completions.py`: planner added to `ROLE_SCHEMAS` with `PLAN_VERDICT` + `PLAN_SUMMARY` required fields. Verdict vocabulary sourced from `stage_registry.PLANNER_VERDICTS` (identity reference). Module docstring updated to v4 scope.

Test changes:
- `test_completions.py`: 8 new planner validation tests. Stale "planner is role_not_enforced" test updated.

Evidence: 144 completions/stage_registry tests + 63 dispatch_engine tests = 207 total, 0 failures.

**Slice 2 complete: Planner routing helper delegation.**

Source changes:
- `completions.py`: planner added to stage-registry delegated roles in `determine_next_role()`. `next_work_item` → guardian, `goal_complete`/`needs_user_decision`/`blocked_external` → None (sinks). Docstrings updated.

Test changes:
- `test_completions.py`: 6 new planner routing tests (4 verdicts + unknown + stage_registry parity). AST structural invariant updated to forbid literal planner tuple keys.

**Slice 3 complete: Planner hook structured completion submission.**

Source changes:
- `hooks/check-planner.sh`: parses PLAN_VERDICT and PLAN_SUMMARY trailers from planner response. Submits structured completion record via `rt_completion_submit` with role=planner. Advisory only (exit 0). `completions.py` remains schema authority.
- `hooks/HOOKS.md`: check-planner.sh entry updated for PLAN_* trailer parsing and completion submission.

Test changes:
- `tests/runtime/test_hook_bridge.py`: 6 new structural tests in `TestCheckPlannerHookStructure`: settings wiring, PLAN_VERDICT parsing, PLAN_SUMMARY parsing, rt_completion_submit call with role planner, advisory exit 0, no non-zero exits.
- `tests/runtime/test_completions.py`: AST invariant error message updated to include planner.

**Slice 4 complete: Live planner-stop dispatch consumption.**

Source changes:
- `dispatch_engine.py`: planner block replaced — `_route_from_completion()` consumes structured completion record, routes via `determine_next_role("planner", PLAN_VERDICT)` → `stage_registry`. Unconditional planner→guardian(provision) removed. Planner terminal verdicts (goal_complete, needs_user_decision, blocked_external) emit explicit suggestion signals (GOAL_COMPLETE, USER_DECISION_REQUIRED, BLOCKED_EXTERNAL). `_emit_shadow_stage_decision()` updated: planner added to verdict-reading roles.
- `completions.py`: module docstring updated ("Planner, implementer, and reviewer routing are derived..."). Stale "live path not yet consumed" note removed from `determine_next_role()`.
- `dispatch_shadow.py`: planner case uses actual verdict (not hardcoded "next_work_item"). Module docstring updated.

Test changes:
- `test_dispatch_engine.py`: all planner tests rewritten to require lease + completion (mirrors guardian/reviewer contract). 16 new planner tests: 4 verdict routing, 3 error paths (no lease, no completion, invalid), lease release, 3 suggestion signals, production sequence. Stop-review separation tests migrated from planner to implementer (clean auto-dispatch case).
- `test_dispatch_shadow.py`: planner shadow tests updated with lease + completion setup. New `test_planner_preserves_actual_verdict` for all 4 verdicts.

Evidence: 237 tests (completions + dispatch_engine + dispatch_shadow), 0 failures.

**Slice 5 complete: Live post-guardian planner continuation.**

Source changes:
- `completions.py`: guardian literal routing table removed. `determine_next_role()` now delegates all active routing roles (planner, implementer, reviewer, guardian) to `stage_registry.next_stage()` via `_STAGE_TO_ROLE`. Guardian compound-stage resolution uses overlap-safe logic: collects all matching stages and accepts the result only when they translate to the same live role; fails closed on conflict.
- `dispatch_engine.py`: guardian terminal suggestion handler reduced to safety-net for unknown verdicts. Stale cycle-complete comments for guardian committed/merged updated.
- `stage_registry.py`: decision status updated to "live for all active routing roles". Stale "disjoint verdict sets" claim corrected — guardian provision/land share `denied`/`skipped` labels intentionally; overlaps are outcome-equivalent. Stale Phase-6-scope comments removed.
- `dispatch_shadow.py`: module docstring updated to document all planned divergences as closed. `_diagnose()` legacy divergence classifiers annotated as pre-Slice-5 backward compatibility only.

Live routing changes:
- `guardian committed` → `planner` (was `None`)
- `guardian merged` → `planner` (was `None`)
- `guardian skipped` → `planner` (was `implementer`)
- `guardian denied` → `implementer` (unchanged)
- `guardian provisioned` → `implementer` (unchanged)

Test changes:
- `test_completions.py`: guardian committed/merged tests assert `"planner"` instead of `None`. New tests: `test_guardian_skipped_routes_to_planner`, `test_guardian_provisioned_routes_to_implementer`, `test_guardian_overlapping_verdicts_are_outcome_equivalent` (proves overlap-safe resolver). AST invariant extended to include guardian in forbidden roles; failure message updated.
- `test_dispatch_engine.py`: 5 tests updated — guardian committed/merged now route to planner with `auto_dispatch=True`. Full-cycle production sequence updated.
- `test_dispatch_shadow.py`: formerly-divergent guardian committed/merged/skipped tests now assert `agreed=True, reason=PARITY`. Zero-routing-effect test updated.
- `test_shadow_parity.py`: E2E reason sequence now `[PARITY, PARITY, PARITY, PARITY]`. CLI integration test expects 4 parity events.

Evidence: 348 tests (completions + dispatch_engine + dispatch_shadow + shadow_parity + stage_registry + lifecycle), 0 failures. 1808 passed in full runtime suite, 1 pre-existing settings-count failure unrelated.

**Slice 6 complete: Autonomy budget and user-boundary enforcement.**

Source changes:
- New `runtime/core/goal_continuation.py`: sole budget-enforcement authority. `check_continuation_budget()` gates planner `next_work_item` auto-dispatch on active goal contract + positive autonomy budget. Consumes one budget unit atomically per continuation. `update_goal_status_for_verdict()` transitions goal status for terminal planner verdicts using canonical vocabulary (`complete`, `awaiting_user`, `blocked_external`).
- `dispatch_engine.py`: planner block wired with budget check after routing, before auto_dispatch. When budget exhausted, goal not active, or no goal contract exists, suppresses auto_dispatch (clears next_role, sets `budget_exhausted=True`, surfaces `BUDGET_EXHAUSTED` or `NO_ACTIVE_GOAL` signal). Budget check fails closed: exceptions also suppress auto-dispatch and surface `BUDGET_CHECK_FAILED` error. Terminal verdict goal-status updates are best-effort (try/except with pass).

Design decisions:
- Workflow-to-goal resolution: `workflow_id` used directly as `goal_id` for `goal_contracts` table lookup. Simplest deterministic rule; workflows without a goal contract row are denied (fail closed — no active goal contract to authorize automatic continuation).
- `dispatch_engine` imports `goal_continuation` inside the planner block, so the dispatch-engine import-discipline/shadow-only AST tests remain scoped; `goal_continuation` itself owns the direct `decision_work_registry` dependency.
- Authority is singular: budget/status source is `goal_contracts` table via `decision_work_registry`. Hooks, suggestion text, and prompt prose do not duplicate budget semantics.

Test changes:
- New `tests/runtime/test_goal_continuation.py`: 26 tests across 4 test classes:
  - `TestCheckContinuationBudget` (8): allows+decrements, decrement-to-zero, exhausted blocks, no-goal blocks (fail closed), non-active blocks, awaiting_user blocks, blocked_external blocks, sequential decrements.
  - `TestUpdateGoalStatusForVerdict` (6): goal_complete→complete, needs_user_decision→awaiting_user, blocked_external→blocked_external, next_work_item no-op, no-goal no-op, unknown no-op.
  - `TestPlannerOwnedBoundary` (3): reviewer verdicts rejected, guardian verdicts rejected, budget not consumed on denial.
  - `TestDispatchEngineIntegration` (9): budget allows auto_dispatch, exhausted blocks auto_dispatch, no-goal blocks (fail closed), goal_complete/needs_user_decision/blocked_external update status, non-active blocks, multi-cycle budget consumption, budget-check-exception fails closed.
- Existing planner→guardian tests in `test_dispatch_engine.py`, `test_dispatch_shadow.py`, and `test_shadow_parity.py` updated to insert active goal contracts before planner flows (required by fail-closed no-goal enforcement).

Evidence: 473 tests (completions + dispatch_engine + dispatch_shadow + shadow_parity + goal_continuation + decision_work_registry + stage_registry), 0 failures.

Phase 6 remaining scope: none identified. All 6 slices complete. Phase 6 status: complete.

## Phase 7 — Derived surface generation/enforcement

**Slice 1 complete: Hook-doc projection is current and enforced.**

Source changes:
- `hooks/HOOKS.md`: replaced 483-line hand-written prose with 106-line derived projection generated by `runtime.core.hook_doc_projection.render_hook_doc()`. The file is now a derived surface of `HOOK_MANIFEST`, not hand-edited content. Header includes generator version and regeneration instructions.

Test changes:
- `tests/runtime/test_hook_doc_check_cli.py`: flipped `TestRealRepoCurrentState` from asserting drift (exit 1, `status=violation`) to asserting current (exit 0, `status=ok`, `healthy=True`, `exact_match=True`). Updated decision docstring accordingly.
- `tests/runtime/test_hook_validate_settings.py`: updated 3 entry-count pins from 31 to 33 to match current manifest size (pre-existing count drift, not caused by this slice).

CLI verification:
- `python3 runtime/cli.py hook doc-check` → exit 0, `status=ok`, `healthy=true`, `exact_match=true`, hash `sha256:8323cb...5ead5`.
- `python3 runtime/cli.py hook validate-settings` → exit 0, `status=ok_with_deprecated`, `healthy=true`, 33 repo entries, 33 manifest entries, 2 deprecated entries flagged.

Evidence: 156 tests (hook_doc_check_cli + hook_doc_validation + hook_doc_projection + hook_validate_settings + hook_manifest), 0 failures.

**Slice 2 complete: Prompt-pack compile/check round-trip metadata.**

Source changes:
- `runtime/cli.py`: `prompt-pack compile` payload now includes a `validation_inputs` object alongside the existing `inputs` echo. Contains `workflow_id`, `stage_id`, `layers` (the resolved layer mapping used to render `rendered_body`), `generated_at`, and `manifest_version`. Writing `rendered_body` and `validation_inputs` to files and invoking `cc-policy prompt-pack check` produces exit 0 with `healthy=True` — closing the derived-surface freshness gap where a compiled artifact could not be revalidated from compile output alone.

Design decisions:
- `validation_inputs` is separate from `inputs` (the caller/operator echo). `inputs` carries goal_id, work_item_id, decision_scope, etc. — the request context. `validation_inputs` carries the exact resolved data the check CLI needs — the revalidation contract. No overloading.
- The CLI packages already-resolved layers from `resolve_prompt_pack_layers()` into `validation_inputs`; it does not implement a second compiler.

Test changes:
- `tests/runtime/test_prompt_pack_compile_cli.py`: added `TestValidationInputs` class with 8 tests: stable key set, id matching, layer keys match `CANONICAL_LAYER_ORDER`, generated_at roundtrip, manifest_version default/override, happy-path roundtrip check (compile→write→check exits 0 with `healthy=True`, `exact_match=True`), mutated body fails check with drift.

Evidence: 228 tests (prompt_pack_compile_cli + prompt_pack_check_cli + prompt_pack_validation), 0 failures. Hook doc-check remained green (exit 0, `status=ok`).

### Phase 7 Slice 3 — Promote realized stage/capability authorities into constitution registry

Scope: `runtime/core/constitution_registry.py`, `tests/runtime/test_constitution_registry.py`, `ClauDEX/CUTOVER_PLAN.md`

Source changes:
- `runtime/core/constitution_registry.py`: Added 2 concrete entries (`runtime/core/stage_registry.py`, `runtime/core/authority_registry.py`) to `_CONCRETE`. Removed `stage_registry_capability_authority_modules` from `_PLANNED`. Updated docstring and comments. Registry stays pure/declarative — no imports of either module.
- `ClauDEX/CUTOVER_PLAN.md`: §"Constitution-Level Files" list updated — `prompt_pack.py`, `stage_registry.py`, `authority_registry.py` now appear as concrete entries with promotion annotations; "future stage registry / capability authority modules" and "future prompt-pack compiler modules" bullets removed.

Design decisions:
- Bundled change: registry, CUTOVER_PLAN, and tests updated together per Architecture Preservation §"Architecture changes must ship as bundles."
- The two concrete entries carry concise rationales referencing Phase 7 Slice 3 promotion, matching the pattern set by prompt_pack.py's Phase 2 promotion.
- A breadcrumb comment in `_PLANNED` records the promotion (same pattern as prompt_pack_compiler_modules).

Test changes:
- `tests/runtime/test_constitution_registry.py`: `CUTOVER_PLAN_CONCRETE_FILES` frozenset expanded from 12 → 14. Count assertion updated (12 → 14). Declaration-order tuple and layout assertions updated. Removed negative assertion for `stage_registry.py`. Added 3 new tests: `test_stage_registry_capability_authority_slug_is_gone_from_planned`, `test_stage_registry_module_is_concrete`, `test_authority_registry_module_is_concrete`.

Evidence: 52 constitution-registry tests passed, 131 stage/authority registry tests passed, hook doc-check green (exact_match=True).

### Phase 7 Slice 4 — Promote realized decision/work registry authority into constitution registry

Scope: `runtime/core/constitution_registry.py`, `tests/runtime/test_constitution_registry.py`, `ClauDEX/CUTOVER_PLAN.md`

Source changes:
- `runtime/core/constitution_registry.py`: Added concrete entry for `runtime/core/decision_work_registry.py` to `_CONCRETE`. Removed `decision_work_registry_modules` from `_PLANNED`. Updated docstring to list all four promotions (prompt_pack Phase 2, stage_registry+authority_registry Phase 7 S3, decision_work_registry Phase 7 S4). Registry remains pure/declarative — no imports of `decision_work_registry`.
- `ClauDEX/CUTOVER_PLAN.md`: §"Constitution-Level Files" updated — `decision_work_registry.py` now appears as a concrete entry with promotion annotation; "future decision/work registry modules" bullet removed.

Design decisions:
- Same bundled-change pattern as Slices 2–3: registry, CUTOVER_PLAN, and tests updated together.
- Concise rationale references DecisionRecord/GoalRecord/WorkItemRecord schemas and Phase 6 goal-continuation budget/status authority.
- Breadcrumb comment in `_PLANNED` records the promotion (same pattern as prior promotions).

Test changes:
- `tests/runtime/test_constitution_registry.py`: `CUTOVER_PLAN_CONCRETE_FILES` frozenset expanded 14 → 15. Count assertion 14 → 15. Declaration-order tuple and layout assertions updated. Planned-area lookup test switched to `projection_reflow_engine_modules`. Added 2 new tests: `test_decision_work_registry_slug_is_gone_from_planned`, `test_decision_work_registry_module_is_concrete`.

Evidence: 172 tests (test_constitution_registry + test_decision_work_registry), 0 failures. Hook doc-check green (status=ok, healthy=true, exact_match=true).

### Phase 7 Slice 5 — Promote realized projection validation authorities into constitution registry

Scope: `runtime/core/constitution_registry.py`, `tests/runtime/test_constitution_registry.py`, `ClauDEX/CUTOVER_PLAN.md`

Source changes:
- `runtime/core/constitution_registry.py`: Added 4 concrete entries (`projection_schemas.py`, `hook_doc_projection.py`, `hook_doc_validation.py`, `prompt_pack_validation.py`) to `_CONCRETE`. Replaced `projection_reflow_engine_modules` planned entry with narrower `projection_reflow_orchestrator_module` (only the not-yet-realized reflow orchestration layer remains planned). Updated docstring with Phase 7 Slice 5 promotions.
- `ClauDEX/CUTOVER_PLAN.md`: §"Constitution-Level Files" updated — 4 projection validators now concrete with Phase 7 Slice 5 annotations; "future projection/reflow engine modules" narrowed to "future projection reflow orchestration module".

Design decisions:
- The broad `projection_reflow_engine_modules` planned slug was split rather than simply removed: 4 realized validators promoted to concrete, 1 narrower `projection_reflow_orchestrator_module` remains planned for the not-yet-implemented reflow daemon/scheduler.
- Same bundled-change pattern as Slices 3–4.

Test changes:
- `tests/runtime/test_constitution_registry.py`: `CUTOVER_PLAN_CONCRETE_FILES` frozenset expanded 15 → 19. Count assertion 15 → 19. Declaration-order tuple and layout assertions updated. Planned-area lookup test switched to `projection_reflow_orchestrator_module`. Added 5 new tests: `test_projection_reflow_engine_slug_is_gone_from_planned`, `test_projection_schemas_module_is_concrete`, `test_hook_doc_projection_module_is_concrete`, `test_hook_doc_validation_module_is_concrete`, `test_prompt_pack_validation_module_is_concrete`.

Evidence: 304 tests (test_constitution_registry + test_projection_schemas + test_hook_doc_projection + test_hook_doc_validation + test_prompt_pack_validation), 0 failures. Hook doc-check green (status=ok, healthy=true, exact_match=true).

### Phase 7 Slice 6 — Enforce constitution-level write scope through the registry

Scope: `runtime/core/policies/write_plan_guard.py`, `tests/runtime/policies/test_write_plan_guard.py`, `runtime/core/constitution_registry.py` (docstring only), `tests/runtime/test_constitution_registry.py` (wording only)

Source changes:
- `runtime/core/policies/write_plan_guard.py`: Extended to deny writes to concrete constitution-level files from actors lacking `CAN_WRITE_GOVERNANCE`. Uses `constitution_registry.is_constitution_level` and `normalize_repo_path` — no hardcoded file list. Handles absolute paths under `project_root` by converting to repo-relative before consulting the registry. Relative paths also work. Governance-markdown check fires first; constitution-level check fires second for non-markdown constitution files. `CLAUDE_PLAN_MIGRATION=1` bypass and `.claude/` meta-infra skip preserved. Added `_to_repo_relative()` helper.
- `runtime/core/constitution_registry.py`: Docstring updated — "Live consumers" section added documenting `write_plan_guard` as a consumer; "What this module does NOT do" bullets adjusted to reflect that scope gating now exists in the policy layer.

Design decisions:
- The registry remains pure/declarative with no imports of live policy modules. The dependency direction is one-way: policy imports registry.
- Constitution-level deny reason is distinct from governance-markdown deny reason so agents can distinguish which gate fired.

Test changes:
- `tests/runtime/policies/test_write_plan_guard.py`: Added 8 constitution-level enforcement tests: implementer denied for `runtime/cli.py`, implementer denied for `runtime/core/stage_registry.py`, planner allowed, Plan alias allowed, `CLAUDE_PLAN_MIGRATION=1` bypass, unrelated source files unaffected, registry-driven (not hardcoded) assertion, relative-path handling.
- `tests/runtime/test_constitution_registry.py`: Renamed `test_live_modules_do_not_import_constitution_registry` → `test_core_routing_modules_do_not_import_constitution_registry` with updated docstring clarifying that individual policy files may import the registry as read-only consumers.

Evidence: 85 tests (test_write_plan_guard + test_constitution_registry), 0 failures. Broader write policy bundle: 51 tests (test_write_who + test_write_plan_guard + test_write_enforcement_gap), 0 failures.

### Phase 7 Slice 7 — Expose constitution registry through read-only CLI validation surface

Scope: `runtime/cli.py`, `tests/runtime/test_constitution_cli.py` (new)

Source changes:
- `runtime/cli.py`: Added `_handle_constitution()` handler with two actions:
  - `constitution list`: emits JSON with `concrete_count`, `planned_count`, `concrete_paths`, `planned_areas`, `concrete_entries`, `planned_entries`. Always exits 0.
  - `constitution validate`: checks all concrete paths exist on disk via `--repo-root`. Emits JSON with `healthy`, `missing_concrete_paths`, counts. Exits 0 when healthy, 1 when any concrete path is missing.
  - Both commands are read-only — no mutation. Uses `constitution_registry` as sole authority; no hardcoded file list in the CLI.
- Added subparser registration (`constitution` domain with `list` and `validate` subcommands) and dispatch routing.

Design decisions:
- Follows the same pattern as `hook doc-check` and `prompt-pack check`: thin CLI wrapper around a domain module, JSON output, non-zero on drift/failure.
- `validate` accepts `--repo-root` for testing against arbitrary directories without affecting the real repo.

Test changes:
- `tests/runtime/test_constitution_cli.py` (new): 14 tests across 3 classes: list output shape (7 tests), validate healthy in current repo (4 tests), validate unhealthy with empty/partial repo-root (3 tests). Tests use `constitution_registry` as authority — no hardcoded path list.

Evidence: 73 tests (test_constitution_registry + test_constitution_cli), 0 failures. CLI evidence: `constitution validate` → exit 0, `status=ok`, `healthy=true`, `concrete_count=19`, `planned_count=2`, `missing_concrete_paths=[]`. `constitution list` → exit 0, `status=ok`, `concrete_count=19`, `planned_count=2`, 19 concrete entries with name/path/rationale, 2 planned entries present.

### Phase 7 Slice 8 — Promote realized hook manifest authority into constitution registry

Scope: `runtime/core/constitution_registry.py`, `ClauDEX/CUTOVER_PLAN.md`, `tests/runtime/test_constitution_registry.py`

Source changes:
- `runtime/core/constitution_registry.py`: Added `runtime/core/hook_manifest.py` as a concrete entry in `_CONCRETE`. Rationale names it the runtime-owned hook manifest authority that backs settings.json hook-wiring validation and the hooks/HOOKS.md projection — its derived consumers (`hook_doc_projection`, `hook_doc_validation`) and derived surfaces (`settings.json`, `hooks/HOOKS.md`) were already constitution-level, so promoting the source closes the one-authority model. Updated module docstring with Phase 7 Slice 8 promotion bullet. Concrete count: 19 → 20.
- `ClauDEX/CUTOVER_PLAN.md`: §"Constitution-Level Files" list extended with `runtime/core/hook_manifest.py` (Phase 7 Slice 8 annotation).

Design decisions:
- No planned slug to narrow or remove — the hook manifest was already realized; its absence from the concrete list was a one-authority gap rather than a planned-slug expansion. Promotion is purely additive on the concrete side.
- Registry remains pure: no live-module import of `hook_manifest`. The promotion is a declarative path/rationale addition; live enforcement continues to flow through `is_constitution_level()` at policy time.

Test changes:
- `tests/runtime/test_constitution_registry.py`:
  - `CUTOVER_PLAN_CONCRETE_FILES` frozenset extended with `runtime/core/hook_manifest.py` (with `# Phase 7 Slice 8 hook manifest authority:` marker comment).
  - `test_concrete_count_is_nineteen` → `test_concrete_count_is_twenty` with assertion `== 20`.
  - Ordered tuple in `test_all_concrete_paths_helper_returns_declaration_order` appended with `runtime/core/hook_manifest.py`; layout pin grown `first_nineteen` → `first_twenty` with slice `[20:]`.
  - Added `test_hook_manifest_module_is_concrete` (lookup + `is_constitution_level` positive assertion).
  - Added `test_no_broad_hook_manifest_planned_slug` (negative assertion that no planned slug contains `hook_manifest`, preventing dual-surface regressions).

Evidence:
- `python3 -m pytest tests/runtime/test_constitution_registry.py tests/runtime/test_hook_manifest.py tests/runtime/test_hook_validate_settings.py tests/runtime/test_hook_doc_projection.py tests/runtime/test_hook_doc_validation.py -q` → 200 passed, 0 failures.
- `python3 runtime/cli.py constitution validate` → exit 0, `status=ok`, `healthy=true`, `concrete_count=20`, `planned_count=2`, `missing_concrete_paths=[]`.
- `python3 runtime/cli.py hook validate-settings` → exit 0, `status=ok`, `healthy=true`, 33 settings/manifest entries matched, 0 missing either side, 2 deprecated-still-wired entries unchanged (pre-existing CUTOVER_PLAN H8 speculative worktree wiring).
- `python3 runtime/cli.py hook doc-check` → exit 0, `status=ok`, `healthy=true`, `exact_match=true` (hooks/HOOKS.md projection still matches manifest).

### Phase 7 Slice 9 — Hook-doc projection stale-condition names its source authority

Scope: `runtime/core/hook_doc_projection.py`, `tests/runtime/test_hook_doc_projection.py`

Source changes:
- `runtime/core/hook_doc_projection.py`: Extended `build_hook_doc_projection()`'s `StaleCondition.watched_files` tuple from `("settings.json", "hooks/HOOKS.md")` to `("runtime/core/hook_manifest.py", "settings.json", "hooks/HOOKS.md")`. Ordering is deterministic — source authority first, then derived surfaces. Added inline comment explaining the Phase 7 Slice 9 rationale: after Slice 8 promoted hook_manifest.py to concrete constitution-level, the projection's stale metadata named its derived outputs but omitted the actual source input whose changes stale the projection.
- No change to `render_hook_doc()` output, `content_hash`, manifest wiring, settings, or constitution registry.

Design decisions:
- Metadata-only edit: the rendered hooks/HOOKS.md body is unchanged (`hook doc-check` reports the same `content_hash` `sha256:8323cb9a...`, `exact_match=true`).
- No new imports: kept the existing import discipline (only `hook_manifest` + `projection_schemas`); the watched path is a string literal, not sourced from `constitution_registry`. The AST shadow-discipline invariant (hook_doc_projection imports only authority + schema) stays satisfied.
- Deterministic ordering (authority → derived) is pinned in tests so future edits cannot silently reshuffle the tuple.

Test changes:
- `tests/runtime/test_hook_doc_projection.py`:
  - Extended `test_stale_condition_watches_constitution_level_files` with `"runtime/core/hook_manifest.py" in watched`.
  - Added `test_stale_condition_watches_hook_manifest_source_authority` (focused positive assertion with rationale docstring).
  - Added `test_stale_condition_watched_files_are_deterministic` pinning the exact tuple and order `(hook_manifest.py, settings.json, hooks/HOOKS.md)`.

Evidence:
- `python3 -m pytest tests/runtime/test_hook_doc_projection.py tests/runtime/test_hook_doc_validation.py tests/runtime/test_hook_doc_check_cli.py -q` → 81 passed, 0 failures.
- `python3 runtime/cli.py hook doc-check` → exit 0, `status=ok`, `healthy=true`, `exact_match=true`, `content_hash=sha256:8323cb9a800f19fbb30fc970701ff9e627efe09897f9251cfbca71adfaf5ead5` (unchanged — confirms metadata-only edit).
- `python3 runtime/cli.py constitution validate` → exit 0, `status=ok`, `healthy=true`, `concrete_count=20`, `planned_count=2`, `missing_concrete_paths=[]`.

### Phase 7 Slice 10 — Promote realized prompt-pack resolver authority into constitution registry

Scope: `runtime/core/constitution_registry.py`, `ClauDEX/CUTOVER_PLAN.md`, `tests/runtime/test_constitution_registry.py`

Source changes:
- `runtime/core/constitution_registry.py`: Added `runtime/core/prompt_pack_resolver.py` as a concrete entry in `_CONCRETE`. Rationale names it the canonical prompt-pack layer composition authority that composes the six canonical layers, renders the constitution layer from `constitution_registry.CONCRETE_PATHS`, renders stage contracts from `stage_registry`, and backs the `prompt-pack compile` CLI path — so derived compiled guidance cannot change without the write-scope gate and constitution CLI seeing the source. Updated module docstring promotions list with Phase 7 Slice 10. Concrete count: 20 → 21.
- `ClauDEX/CUTOVER_PLAN.md`: §"Constitution-Level Files" list extended with `runtime/core/prompt_pack_resolver.py` (Phase 7 Slice 10 annotation).

Design decisions:
- Purely additive on the concrete side — like Slice 8's hook_manifest promotion, no planned slug covered the resolver/layer-composition layer, so this closes a one-authority gap rather than narrowing a planned area. No `_PLANNED` edit required.
- Registry stays pure/declarative: no import of `prompt_pack_resolver`. The promotion is path/rationale metadata; live enforcement continues to flow through `is_constitution_level()` at policy time.
- `runtime/core/prompt_pack.py` (bootstrap compiler) and `runtime/core/prompt_pack_validation.py` (drift validator) were already concrete — promoting the resolver completes the prompt-pack authority triangle (compiler + composer + validator).

Test changes:
- `tests/runtime/test_constitution_registry.py`:
  - `CUTOVER_PLAN_CONCRETE_FILES` frozenset extended with `runtime/core/prompt_pack_resolver.py` (with `# Phase 7 Slice 10 prompt-pack resolver authority:` marker comment).
  - `test_concrete_count_is_twenty` → `test_concrete_count_is_twenty_one` with assertion `== 21`.
  - Ordered tuple in `test_all_concrete_paths_helper_returns_declaration_order` appended with `runtime/core/prompt_pack_resolver.py`; layout pin grown `first_twenty` → `first_twenty_one` with slice `[21:]`.
  - Added `test_prompt_pack_resolver_module_is_concrete` (lookup + `is_constitution_level` positive assertion).
  - Added `test_no_broad_prompt_pack_resolver_planned_slug` (negative assertion excluding both `prompt_pack_resolver` and `layer_composition` slug substrings to guard against dual-surface regressions).

Evidence:
- `python3 -m pytest tests/runtime/test_constitution_registry.py tests/runtime/test_prompt_pack_resolver.py tests/runtime/test_prompt_pack.py tests/runtime/test_prompt_pack_compile_cli.py -q` → 451 passed, 0 failures.
- `python3 runtime/cli.py constitution validate` → exit 0, `status=ok`, `healthy=true`, `concrete_count=21`, `planned_count=2`, `missing_concrete_paths=[]`.

Next-audit candidates (reported only, not promoted in this slice):
- `runtime/core/prompt_pack_state.py` — prompt-pack state surface.
- `runtime/core/prompt_pack_decisions.py` — decision-scoping surface for prompt-pack compiles.
- `runtime/core/workflow_contract_capture.py` — contract capture integration point.
Each of these may warrant constitution-level promotion if they are realized source authorities backing the compiled prompt-pack path; they should be audited individually in future bounded slices before any promotion decision.

### Phase 7 Slice 11 — Compiled prompt-pack freshness watches the full constitution set

Scope: `runtime/core/prompt_pack.py`, `runtime/core/prompt_pack_resolver.py`, `tests/runtime/test_prompt_pack.py`, `tests/runtime/test_prompt_pack_resolver.py`, `tests/runtime/test_prompt_pack_compile_cli.py`

Problem:
- The resolver's `render_constitution_layer()` already derives the constitution layer from every concrete entry in `constitution_registry.CONCRETE_PATHS`, but `build_prompt_pack()` was still hardcoding `StaleCondition.watched_files` to `(CLAUDE.md, AGENTS.md)`. After Slice 10, compiled packs could include a constitution layer derived from 21 concrete files while the freshness metadata named only 2 — stale metadata that cannot trigger reflow when upstream authorities change.

Source changes:
- `runtime/core/prompt_pack_resolver.py`: Added `constitution_watched_files()` helper that forwards to `constitution_registry.all_concrete_paths()`. Returns the full concrete path tuple in deterministic registry order (CUTOVER_PLAN baseline → Phase promotions in landing order). The helper does not duplicate the path list; the registry remains the sole authority. Added to `__all__`.
- `runtime/core/prompt_pack.py`:
  - `build_prompt_pack()` gained an optional keyword-only `watched_files: Tuple[str, ...] | None = None`. When `None`, falls back to the minimal `(CLAUDE.md, AGENTS.md)` pair for direct pure-builder callers. When provided, replaces the fallback — no mutation of module state, no merging. Docstring updated with Phase 7 Slice 11 rationale.
  - Both full compile paths now pass `_ppr.constitution_watched_files()` into `build_prompt_pack()`:
    - `compile_prompt_pack_for_stage()` (Mode-A/B compile capstone)
    - `build_subagent_start_prompt_pack_response()` (SubagentStart delivery)
  - Used the existing function-local `_ppr` import pattern; no new module-level imports — the shadow-discipline invariant is preserved (prompt_pack.py still imports only `projection_schemas` at module level).

Design decisions:
- Single-authority bridge: the helper sits in `prompt_pack_resolver.py` (which is itself constitution-level as of Slice 10) rather than in `prompt_pack.py` so the resolver remains the sole owner of how the constitution set flows into compiled guidance. Keeps the dependency direction clean: compiler → resolver → registry.
- Opt-in override, not default change: the direct-builder default stays `(CLAUDE.md, AGENTS.md)`. The full set is scoped to the compile path. This avoids forcing every unit test and synthetic caller to know about the 21-element authority set; only the real compile path — which actually derives the constitution layer from every path — emits the full list.
- No rendered-body change, no hash change: `watched_files` is metadata only. The prompt-pack body is unchanged byte-for-byte.

Test changes:
- `tests/runtime/test_prompt_pack.py`:
  - Replaced the substring-membership test with `test_stale_condition_watched_files_direct_builder_default` pinning the exact `(CLAUDE.md, AGENTS.md)` tuple for direct callers.
  - Added `test_stale_condition_watched_files_override_is_honored` proving the kwarg replaces the fallback.
  - Added `test_compile_path_watched_files_match_constitution_registry` in `TestCompilePromptPackForStage` asserting `pack.metadata.stale_condition.watched_files == cr.all_concrete_paths()` and spot-checking the Slice 8/Slice 10 promotions. No duplicated file list.
- `tests/runtime/test_prompt_pack_resolver.py`:
  - Added `TestConstitutionWatchedFiles` (5 tests): helper returns `cr.all_concrete_paths()`, returns a tuple, is deterministic, reflects registry mutation via monkeypatch, and covers Phase 7 promotions.
- `tests/runtime/test_prompt_pack_compile_cli.py`:
  - Added `from runtime.core import constitution_registry as cr`.
  - Trimmed the existing `test_metadata_stale_condition_lists_watched_authorities` to only assert authority-level concerns (removed the stale `"CLAUDE.md" in watched_files` membership check that would have continued to pass while masking the real contract).
  - Added `test_metadata_stale_condition_watched_files_is_full_constitution_set` asserting the CLI JSON's `watched_files` equals `cr.all_concrete_paths()` in order — no hardcoded list.
  - Added `test_metadata_stale_condition_watched_files_includes_phase7_promotions` spot-checking `prompt_pack_resolver.py` and `hook_manifest.py` reach the CLI surface.

Evidence:
- `python3 -m pytest tests/runtime/test_prompt_pack.py tests/runtime/test_prompt_pack_resolver.py tests/runtime/test_prompt_pack_compile_cli.py tests/runtime/test_prompt_pack_validation.py -q` → 521 passed, 0 failures.
- `python3 runtime/cli.py constitution validate` → exit 0, `status=ok`, `healthy=true`, `concrete_count=21`, `planned_count=2`, `missing_concrete_paths=[]`.

### Phase 7 Slice 12 — `prompt-pack check` validates compiled metadata when provided

Scope: `runtime/core/prompt_pack_validation.py`, `runtime/cli.py`, `tests/runtime/test_prompt_pack_validation.py`, `tests/runtime/test_prompt_pack_check_cli.py`, `tests/runtime/test_prompt_pack_compile_cli.py`

Problem:
- After Slice 11, compiled `metadata.stale_condition.watched_files` is meaningful (full concrete constitution set). But the existing `prompt-pack check` validator (body-only) cannot detect drift in the metadata envelope. A candidate pack whose body matches the compiler output but whose metadata has been tampered with, silently stripped, or left stale relative to a newer constitution set would pass validation silently. CUTOVER_PLAN §Invariant 12 requires derived projections to fail validation when upstream state changed without reflow — metadata is part of that projection.

Source changes:
- `runtime/core/prompt_pack_validation.py`:
  - Added **public** single-authority serialiser `serialise_prompt_pack_metadata(metadata)` returning the JSON-shaped metadata dict the compile CLI emits. Exported in `__all__`. Both `runtime/cli.py` (compile action) and `validate_prompt_pack_metadata` route through this helper — the on-wire metadata shape has exactly one owner and cannot drift between producer and validator. A private alias `_serialise_metadata_to_compile_shape = serialise_prompt_pack_metadata` is retained for intra-module readability only.
  - Added pure helper `_first_metadata_mismatch(expected, candidate, path="")` walking two JSON values in parallel and emitting `{"path": str, "expected": Any, "candidate": Any}` at the first divergence. Uses dotted paths for dict keys and `[i]` for list indices.
  - Added `validate_prompt_pack_metadata(candidate_metadata, *, workflow_id, stage_id, layers, generated_at, watched_files, manifest_version=MANIFEST_VERSION)` — pure drift checker. Rebuilds the expected metadata by calling `build_prompt_pack(..., watched_files=tuple(watched_files))` (the same compiler authority that produced the artifact) and serialising through `serialise_prompt_pack_metadata`. Returns a stable report dict with `status / healthy / exact_match / expected_metadata / candidate_metadata / first_mismatch / workflow_id / stage_id`. No I/O, no live-module imports; missing/wrong-type candidate fields surface as drift (never exceptions). Malformed compiler inputs (workflow_id / stage_id / layers) still raise `ValueError` from `build_prompt_pack` — caller bugs, not drift.
  - Added `serialise_prompt_pack_metadata` and `validate_prompt_pack_metadata` to `__all__`.
  - Added DEC-CLAUDEX-PROMPT-PACK-METADATA-VALIDATION-001.
- `runtime/cli.py`:
  - Compile action: `payload["metadata"]` is now constructed by calling `prompt_pack_validation_mod.serialise_prompt_pack_metadata(pack.metadata)` instead of inline field construction. JSON shape and ordering are preserved exactly — the inline builder was moved into the public helper verbatim. Added DEC-CLAUDEX-PROMPT-PACK-METADATA-SERIALISER-SINGLE-AUTHORITY-001.
  - Compile action: extended `validation_inputs` with `"watched_files": list(pack.metadata.stale_condition.watched_files)` so the compile→check round-trip no longer requires the caller to reconstruct the full concrete constitution set.
  - `pp_check` argparse: added `--metadata-path` option (opt-in). Updated `--inputs-path` help to note `watched_files` is required when `--metadata-path` is present.
  - Check handler: when `--metadata-path` is given, reads the metadata file, validates it is a JSON object, reads and validates `inputs.watched_files` as a list of non-empty strings (error if missing/malformed — no silent fallback), calls `validate_prompt_pack_metadata`, adds `metadata_report` + `metadata_path` to the payload, and exits 0 only when both `report["healthy"]` and `metadata_report["healthy"]` are true; otherwise exits 1 with `status=violation`. Body-only behavior (no `--metadata-path`) is byte-identical to the prior contract — `metadata_report` / `metadata_path` keys are never present.
  - Added DEC-CLAUDEX-PROMPT-PACK-CHECK-CLI-METADATA-001.

Design decisions:
- Pure, symmetric validator. `validate_prompt_pack_metadata` is fully symmetric with `validate_prompt_pack` (body drift): both are pure, both rebuild the expected artifact via `build_prompt_pack`, both return a stable status-plus-first-mismatch report. The validator does NOT reach into `constitution_registry` or `prompt_pack_resolver` — the CLI is the sole layer that resolves `watched_files`, which the validator receives as an opaque tuple. This preserves the shadow-only discipline and keeps the rebuild-via-compiler model intact.
- Opt-in gate, not default change. `--metadata-path` is explicit operator opt-in. Body-only callers and existing tests are unaffected; no test file edits were needed in the pre-Slice-12 check-CLI contract except the new `TestMetadataPathOptInGate` class.
- Missing `watched_files` errors loudly. When `--metadata-path` is active, absent or malformed `inputs.watched_files` returns a CLI error rather than silently falling back to the direct-builder `(CLAUDE.md, AGENTS.md)` pair. Silent fallback would produce a spurious "metadata drift" report that looked like the artifact was wrong when really the revalidation inputs were underspecified.
- Shared serialiser prevents CLI/validator drift. `serialise_prompt_pack_metadata` (public, exported in `__all__`) is the single place JSON field names / ordering for the metadata envelope are defined. The CLI compile path calls it directly to build `payload["metadata"]` and the validator calls it to shape `expected_metadata` — a future slice that changes the metadata envelope cannot silently desync producer and validator.

Test changes:
- `tests/runtime/test_prompt_pack_validation.py`: added 4 new classes / 18 tests pinning the pure helper:
  - `TestMetadataValidatorHealthy` (4): matching metadata is healthy; identity echo; JSON-serialisable; `expected_metadata` contains the provided `watched_files`.
  - `TestMetadataValidatorTampered` (5): tampered watched_files list / indexed entry / generator_version / generated_at / cross-drift (validator watched_files vs candidate watched_files) all surface drift with the correct dotted path.
  - `TestMetadataValidatorMalformedShape` (7): empty mapping / missing stale_condition / extra top-level key / wrong container type for watched_files / wrong type for provenance / None candidate all classify as drift (never exceptions); malformed compiler layers still raises ValueError.
  - `TestMetadataValidatorExportAndDiscipline` (2): function is exported; two calls with identical inputs produce byte-identical reports.
- `tests/runtime/test_prompt_pack_check_cli.py`: added `TestMetadataPathOptInGate` (11 tests):
  - body-only behavior unchanged without `--metadata-path` (no `metadata_report` / `metadata_path` keys);
  - healthy case with `--metadata-path` exits 0 and both reports healthy;
  - tampered metadata with clean body fails (status=violation, body healthy, metadata drift);
  - body drift with clean metadata still fails;
  - missing / non-list / non-string / empty-string `inputs.watched_files` all error with message mentioning `watched_files`;
  - missing metadata file / malformed JSON / non-object JSON all error with descriptive prefix.
- `tests/runtime/test_prompt_pack_compile_cli.py`: added `from runtime.core import prompt_pack_validation as ppv`; updated `test_validation_inputs_present_and_has_stable_keys` expected key set to include `watched_files`; added 4 new tests in `TestValidationInputs`:
  - `watched_files` equals `cr.all_concrete_paths()`;
  - `validation_inputs.watched_files == metadata.stale_condition.watched_files`;
  - `test_compile_metadata_equals_public_serialiser` — rebuilds a pack from `out["validation_inputs"]` and asserts `out["metadata"] == ppv.serialise_prompt_pack_metadata(rebuilt.metadata)` — fails if the CLI regresses to inline metadata construction and then drifts;
  - compile → write body+inputs+metadata → `prompt-pack check --metadata-path` exits 0 with both reports healthy.
- `tests/runtime/test_prompt_pack_validation.py`: extended `TestMetadataValidatorExportAndDiscipline` with `test_serialiser_is_public_and_exported` (public name in `__all__`) and `test_serialiser_matches_private_alias` (private `_serialise_metadata_to_compile_shape` forwards to the public helper — never a second implementation).

Evidence:
- `python3 -m pytest tests/runtime/test_prompt_pack_validation.py tests/runtime/test_prompt_pack_check_cli.py tests/runtime/test_prompt_pack_compile_cli.py -q` → 262 passed, 0 failures, 30.34s.
- `python3 runtime/cli.py constitution validate` → exit 0, `status=ok`, `healthy=true`, `concrete_count=21`, `planned_count=2`, `missing_concrete_paths=[]`.

### Phase 7 Slice 13 — Pure decision-digest projection builder

Scope: `runtime/core/decision_digest_projection.py` (NEW), `tests/runtime/test_decision_digest_projection.py` (NEW), `runtime/core/constitution_registry.py`, `ClauDEX/CUTOVER_PLAN.md`, `tests/runtime/test_constitution_registry.py`, `ClauDEX/CURRENT_STATE.md`.

Problem:
- CUTOVER_PLAN Phase 7 exit criteria require that `MASTER_PLAN.md` and decision digests be renderable or validatable from the canonical registry, and that stale decision/plan projections fail landing. `runtime/core/projection_schemas.DecisionDigest` already pins the typed projection shape and `runtime/core/decision_work_registry.DecisionRecord` is the concrete canonical decision authority (Phase 7 Slice 4), but no generator bridges the two. Hand-maintained digest markdown cannot be validated against an authority until a pure, deterministic builder exists.

Source changes:
- `runtime/core/decision_digest_projection.py` (NEW, pure, shadow-only):
  - `render_decision_digest(decisions, *, cutoff_epoch) -> str` — renders the decision-digest body as deterministic markdown. Output shape: H1 title + preamble naming `runtime.core.decision_work_registry` as authority + generator version line + `Cutoff: epoch=<int>` line + either `_No decisions within cutoff window._` placeholder or one bullet per decision formatted as `` - `<decision_id>` v<version> [<status>] — <title>`` with a `  - _<rationale>_` sub-bullet. Newline-terminated.
  - `build_decision_digest_projection(decisions, *, generated_at, cutoff_epoch, manifest_version=MANIFEST_VERSION) -> DecisionDigest` — builds the full `DecisionDigest` projection. Uses the SAME rendered markdown body for `content_hash` and derives `decision_ids` from the same filtered+sorted sequence, so the three fields cannot drift from the rendered content.
  - Constants: `DECISION_DIGEST_GENERATOR_VERSION="1.0.0"`, `MANIFEST_VERSION="1.0.0"`, `DECISIONS_SOURCE_KIND="decision_records"`, `DECISION_REGISTRY_SOURCE_FILE="runtime/core/decision_work_registry.py"`.
  - Private helpers: `_hash_content` (sha256 + `"sha256:"` prefix), `_validate_decisions_input` (rejects non-sequence, non-DecisionRecord, duplicate decision_id), `_validate_cutoff` (rejects bool, non-int, negative), `_filter_and_sort` (descending `updated_at`, `decision_id` asc tiebreaker, `updated_at >= cutoff_epoch` lower bound), `_build_provenance` (one `SourceRef` per included decision with `source_version=f"{rec.version}:{rec.status}"` so supersession drift is detectable even when `version` does not move).
  - `StaleCondition(watched_authorities=("decision_records",), watched_files=("runtime/core/decision_work_registry.py",))` — reflow trigger on the authority name and the registry shape source file.
  - `__all__` exports the public API.
  - Added DEC-CLAUDEX-DECISION-DIGEST-PROJECTION-001.
  - Zero live-module imports: depends ONLY on `runtime.core.decision_work_registry` (for `DecisionRecord`) and `runtime.core.projection_schemas` (for typed output shapes). Pinned by AST-walk discipline test.
- `runtime/core/constitution_registry.py`: added `ConstitutionEntry(name="runtime/core/decision_digest_projection.py", kind=KIND_CONCRETE, path="runtime/core/decision_digest_projection.py", rationale=...)` at the end of `_CONCRETE`. Updated module docstring "Promoted entries" list with Phase 7 Slice 13 entry.
- `ClauDEX/CUTOVER_PLAN.md`: appended `- `runtime/core/decision_digest_projection.py` (added as concrete in Phase 7 Slice 13)` to the Constitution-Level Files list.

Design decisions:
- Pure / deterministic / caller-supplied inputs. The builder never reads decisions from SQLite and never opens the decision-work registry's read helpers at module scope — callers thread records through explicitly. `generated_at` is required and is the only timestamp the builder uses, so two calls with the same `(decisions, generated_at, cutoff_epoch, manifest_version)` produce byte-identical projections.
- Cutoff is an inclusive lower bound. Decisions with `updated_at < cutoff_epoch` are silently dropped from body, `decision_ids`, and `provenance` — never partially represented. Rationale: the schema docstring's "within a time window" language matches a filter-not-error contract, and a deterministic placeholder for the empty case (`_No decisions within cutoff window._`) is more useful than an exception for an empty window.
- Render order is declarative, not caller-controlled. Sort: descending `updated_at` (most-recent first), ties broken by `decision_id` ascending. This keeps the rendered body byte-deterministic independent of how the caller iterates decisions.
- `source_version` encodes status. `SourceRef.source_version=f"{version}:{status}"` so a decision whose status flipped (e.g. to `superseded`) since the digest was rendered is legitimately detectable as stale even if `version` never moved.
- Pure module, not a CLI. This slice deliberately adds no CLI commands, writes no files, touches no `MASTER_PLAN.md`, and does not change registry / prompt-pack / hook / settings behavior. At the time Slice 13 landed, no CLI surface reached this builder; the read-only CLI adapters that pull decisions from the canonical store and thread them through this builder/validator landed in Slice 14 (`cc-policy decision digest`) and Slice 15 (`cc-policy decision digest-check`), and they are the only CLI adapters that reach this module — no further adapter path is planned.

Test changes:
- `tests/runtime/test_decision_digest_projection.py` (NEW, 48 tests across 8 classes):
  - `TestRenderDecisionDigest` (11): empty-window deterministic output; single/multiple decisions rendered; descending `updated_at` ordering; `decision_id` tiebreaker; cutoff filter; rationale and title echo; byte-determinism across calls; generator version line stability; input list is never mutated.
  - `TestBuildDecisionDigestProjection` (8): returns `DecisionDigest`; `decision_ids` matches render order; `content_hash` equals sha256 of the rendered body; `cutoff_epoch` echoed; `generated_at` echoed; empty-window projection is still well-formed; two builds with identical inputs are byte-identical.
  - `TestProvenance` (5): one `SourceRef` per included decision; `source_kind="decision_records"`; `source_id=decision_id`; `source_version="<version>:<status>"` encodes both; out-of-window decisions never appear in provenance.
  - `TestStaleCondition` (6): `watched_authorities=("decision_records",)` exactly; `watched_files=("runtime/core/decision_work_registry.py",)` exactly; rationale non-empty; schema invariants held.
  - `TestInputValidation` (7): non-sequence decisions raises ValueError; non-DecisionRecord entry raises; duplicate `decision_id` raises; bool/non-int/negative `cutoff_epoch` raises.
  - `TestMetadataEnvelope` (2): `generator_version=="1.0.0"`; `source_versions == (("decision_records", manifest_version),)` with caller-supplied `manifest_version` override respected.
  - `TestShadowOnlyDiscipline` (6): AST-walk pins the module's permitted imports set to `{decision_work_registry, projection_schemas}` plus stdlib; no dispatch_engine / completions / policy_engine / hooks / settings / cli / leases / workflows imports; no filesystem-writing imports (os.open / pathlib.Path for I/O, subprocess, etc.).
  - `TestModuleSurface` (3): `__all__` is exactly the expected public names; `DECISION_REGISTRY_SOURCE_FILE` string exists and equals `"runtime/core/decision_work_registry.py"`; `DECISIONS_SOURCE_KIND == "decision_records"`.
- `tests/runtime/test_constitution_registry.py`:
  - `CUTOVER_PLAN_CONCRETE_FILES` frozenset extended with `"runtime/core/decision_digest_projection.py"`.
  - `test_concrete_count_is_twenty_one` renamed to `test_concrete_count_is_twenty_two` and asserts `== 22`.
  - `test_all_concrete_paths_helper_returns_declaration_order` tuple extended with the new path at the tail.
  - `test_registry_is_tuple` slice boundaries updated (`[:21]` → `[:22]`, `[21:]` → `[22:]`).
  - Added focused `test_decision_digest_projection_module_is_concrete` (entry lookup + kind + path + `is_constitution_level` hit) and `test_no_broad_decision_digest_projection_planned_slug` (no planned slug contains `"decision_digest"`).

Evidence:
- `python3 -m pytest tests/runtime/test_decision_digest_projection.py tests/runtime/test_projection_schemas.py tests/runtime/test_decision_work_registry.py tests/runtime/test_constitution_registry.py -q` → 290 passed, 0 failures, 0.70s.
- `python3 runtime/cli.py constitution validate` → exit 0, `status=ok`, `healthy=true`, `concrete_count=22`, `planned_count=2`, `missing_concrete_paths=[]`.

### Phase 7 Slice 14 — Read-only decision-digest CLI projection surface

Scope: `runtime/cli.py`, `tests/runtime/test_decision_digest_cli.py` (NEW), `tests/runtime/test_decision_digest_projection.py`, `tests/runtime/test_decision_work_registry.py`, `ClauDEX/CURRENT_STATE.md`.

Problem:
- Slice 13 landed the pure `runtime.core.decision_digest_projection` builder, but no operator/CI surface rendered a digest from the canonical runtime registry. CUTOVER_PLAN Phase 7 calls for decision digests to be rendered or validated from the canonical registry. The bounded next step is read-only CLI exposure — no digest-file writing, no `MASTER_PLAN.md` edits, no decision/work-item mutation.

Source changes:
- `runtime/cli.py`:
  - Added `_handle_decision(args)` implementing `cc-policy decision digest` with `--cutoff-epoch` (default `0`), `--generated-at` (default current time), and optional `--status` / `--scope` filters. Argparse delivers raw strings; the handler converts and validates, returning JSON errors via `_err()` for non-int or negative values.
  - Opens a runtime DB connection via a **read-only SQLite URI** (`file:<db_path>?mode=ro`, `uri=True`) resolved through `default_db_path()`. Does NOT call `_get_conn()` — that helper calls `db.connect()` (which creates parent directories and sets WAL journal mode) plus `ensure_schema()` (which creates tables on first touch), both of which would violate the read-only contract and crash with `sqlite3.OperationalError: unable to open database file` when the caller cannot write the DB path. `sqlite3.Error` from either the open or the `SELECT` is caught and returned via `_err()` as a `decision digest: …` JSON error. Sets `row_factory=sqlite3.Row` for the `list_decisions` consumer; reads decisions via `dwr.list_decisions(conn, status=..., scope=...)`; closes the connection before calling the pure builder. Pushes the `DecisionRecord` sequence through `ddp.render_decision_digest()` and `ddp.build_decision_digest_projection()` unchanged.
  - Payload shape: `status`, `healthy`, `rendered_body`, `projection` (`decision_ids` / `cutoff_epoch` / `content_hash`), `metadata` (generator_version, generated_at, stale_condition with watched_authorities/watched_files, source_versions as `[[kind, ver], …]`, provenance as list of SourceRef dicts), `decision_count`, `decision_ids`, `cutoff_epoch`, `filters`, `repo_root`.
  - Imports `runtime.core.decision_digest_projection` and `runtime.core.decision_work_registry` **at function scope** inside `_handle_decision`, never at module scope. This preserves the shadow-only module-load graph for both authorities — the CLI module import does not drag them in.
  - Wired `decision` subparser with `digest` action into `build_parser()`; dispatched via `args.domain == "decision"` in `main()`.
  - Added DEC-CLAUDEX-DECISION-DIGEST-CLI-001.

Design decisions:
- Function-scope imports are load-bearing. The AST discipline tests in `test_decision_digest_projection.py` and `test_decision_work_registry.py` had previously pinned "CLI must not import this module at all". Slice 14 relaxes those pins to the sharper invariant: CLI must not import these modules **at module scope**, but function-scope use inside a single read-only handler is permitted. This keeps the module-load graph clean while allowing the CLI to bridge caller → authority → pure builder.
- The CLI is a thin adapter. All projection logic — cutoff filtering, render order, content hashing, provenance, stale-condition — lives in the pure builder. The CLI only handles argparse binding, DB connection management, and JSON shaping. `test_decision_digest_cli.py::TestBuilderEquivalence` pins that CLI `rendered_body` and `projection.content_hash` are byte-identical to what the pure builder produces for the same `(decisions, cutoff_epoch, generated_at)` inputs.
- Filter pass-through, not CLI-side reimplementation. `--status` and `--scope` flow directly into `list_decisions` keyword arguments; the CLI does no additional filtering on its own. This keeps filter semantics owned by the registry, not split across two layers.
- Errors via `_err()` JSON, not argparse stderr. `--cutoff-epoch` / `--generated-at` accept raw strings and are validated manually so malformed inputs produce a consistent `{"status":"error","message":"decision digest: ..."}` payload on stderr with non-zero exit — matching every other `cc-policy` domain error path.
- Read-only guarantee is enforced at the connection layer, not just policy. The handler opens the DB with `mode=ro` — a missing DB file cannot be created, an unwritable parent directory cannot be written, and the schema cannot be bootstrapped. This is mechanically stronger than "the handler promises not to call `INSERT`". Pinned by `TestReadOnly`: row count and row contents unchanged across the CLI invocation; a non-existent DB path returns a JSON error without creating the file or parent directory; a schemaless DB file returns a JSON error without creating tables; a seeded DB has no `-wal` sidecar created by the CLI invocation.

Test changes:
- `tests/runtime/test_decision_digest_cli.py` (NEW, 28 tests across 8 classes):
  - `TestHappyPath` (7): exit 0 / `status=ok`; payload has all required top-level keys; all three seeded decisions appear; `cutoff_epoch` and `generated_at` echoed; metadata watches `decision_records` authority + `runtime/core/decision_work_registry.py` file; `filters` echoed as `{"status":null,"scope":null}` when absent.
  - `TestBuilderEquivalence` (3): `rendered_body` equals `ddp.render_decision_digest(decisions, cutoff_epoch=…)`; `projection.content_hash` and `projection.decision_ids` equal pure-builder output; two subprocess invocations with identical inputs produce byte-identical payloads.
  - `TestFilters` (4): `--status accepted` narrows to DEC-A/DEC-C; `--scope kernel` narrows to DEC-A/DEC-B; combined narrows to DEC-A; non-matching filters produce a healthy empty payload with the `_No decisions within cutoff window._` placeholder.
  - `TestCutoffFiltering` (3): cutoff between values drops older decisions; cutoff above all drops everything; cutoff equal to an `updated_at` is inclusive (boundary decision kept).
  - `TestEmptyResult` (1): empty DB returns healthy payload with placeholder body.
  - `TestReadOnly` (5): `COUNT(*)` unchanged across CLI call; decision ids and `updated_at` unchanged; a missing DB path returns a JSON error and does NOT create the file or its parent directory; a schemaless DB file returns a JSON error and does NOT cause tables to be created; a seeded DB has no `-wal` sidecar after the CLI invocation (journal mode is untouched).
  - `TestInputValidation` (4): non-int `--cutoff-epoch` errors with "--cutoff-epoch" in message; negative `--cutoff-epoch` errors with "non-negative"; non-int `--generated-at` errors with "--generated-at"; negative `--generated-at` errors with "non-negative".
  - `TestCliImportDiscipline` (4): `runtime/cli.py` does NOT import `decision_digest_projection` or `decision_work_registry` at module scope; DOES import both at function scope (sanity — Slice 14 was the first slice to wire them this way, and Slice 15's `digest-check` adapter reuses the same function-scope import inside `_handle_decision`). Uses an AST helper that distinguishes module-level from function-level imports.
- `tests/runtime/test_decision_digest_projection.py`:
  - `test_cli_does_not_import_decision_digest_projection` → `test_cli_does_not_import_decision_digest_projection_at_module_level`. Now walks `tree.body` (module top level only) rather than `ast.walk()` so function-scope imports inside `_handle_decision` are permitted. The invariant that module-level CLI import is forbidden remains pinned.
- `tests/runtime/test_decision_work_registry.py`:
  - `test_cli_does_not_import_decision_work_registry` → `test_cli_does_not_import_decision_work_registry_at_module_level`. Same module-level-only walk pattern. At the time this Slice 14 entry was first written, the comment named Phase 7 Slice 14 as the slice that introduced the function-scope CLI use; the Slice 15 doc-drift correction (see subsection below) expanded the comment to also cover Slice 15's `digest-check` adapter so the rationale reflects both function-scope CLI adapters without contradicting the module-scope-forbidden invariant.
  - Live-routing-import bans (`dispatch_engine`, `completions`, `policy_engine` do not import the registry) remain fully intact.

Slice 14 correction #1 (read-only DB connection):
- Review of the initial Slice 14 bundle caught that `_handle_decision` used `_get_conn()`, which calls `db.connect()` (creates parent dirs, sets WAL) and `ensure_schema()` (creates tables). In a read-only sandbox, `python3 runtime/cli.py decision digest --cutoff-epoch 0 --generated-at 1` crashed with `sqlite3.OperationalError: unable to open database file` instead of returning a JSON error. Correction scope: the DB open in `_handle_decision` only. Pure-builder behavior, payload shape, parser wiring, CLI import discipline, constitution registry, CUTOVER_PLAN, prompt-pack, hooks, and settings are all unchanged.
- Source: `runtime/cli.py` now opens the DB via `sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)` with `default_db_path()` for path resolution; `sqlite3.Error` from both the URI open and `list_decisions` is caught and returned through `_err()`. No `ensure_schema`, no WAL pragma, no `connect()` helper, no directory creation. Docstring updated with the read-only connection rationale.
- Tests: `test_decision_digest_cli.py` strengthened `TestReadOnly` from 2 → 5 tests (see above). The new assertions go beyond row-count by pinning that missing DB paths and schemaless DB files produce JSON errors rather than bootstrapping state, and that the CLI does not leave a `-wal` sidecar behind.

Slice 14 correction #2 (immutable-mode fallback + `db_read_mode` payload field):
- Follow-up review caught that `mode=ro` alone is insufficient in some read-only sandboxes (e.g. the Codex supervisor sandbox). `mode=ro` opens, but subsequent queries can fail because SQLite still tries to create / touch the `-wal` / `-shm` sidecar files. The well-documented fallback is `mode=ro&immutable=1`: it promises SQLite the file will not change under us, so SQLite reads the DB without touching journal / WAL sidecars at all. Correction scope: the DB read block in `_handle_decision` only. Pure-builder behavior, payload keys (beyond the new `db_read_mode` field), parser wiring, CLI import discipline, constitution registry, CUTOVER_PLAN, prompt-pack, hooks, and settings remain unchanged.
- Source: `runtime/cli.py` now wraps the open+query in a nested `_try_read(uri)` helper. It first attempts `file:{db_path}?mode=ro`; on `sqlite3.Error`, it retries once with `file:{db_path}?mode=ro&immutable=1`. A `db_read_mode` local tracks which path served the request (`"ro"` or `"ro_immutable"`). If both paths fail, the CLI returns a consolidated JSON error through `_err()` that names both attempts. Successful payload now carries `"db_read_mode": db_read_mode` so operators can see which path was used (observability for sandbox diagnosis).
- Tests: `test_decision_digest_cli.py` — `test_payload_has_all_required_top_level_keys` now pins `db_read_mode` as a required top-level key (10 → 11 required keys). Added `test_db_read_mode_is_valid_value` (focused field-presence test): asserts `payload["db_read_mode"] in {"ro", "ro_immutable"}`. `TestHappyPath` grew from 7 → 8 tests; total CLI test file grew from 31 → 32 tests. The instruction allowed skipping a simulated WAL/SHM-failure test on brittleness grounds; we opted for the field-presence test and direct-command sandbox evidence below.

Evidence:
- `python3 -m pytest tests/runtime/test_decision_digest_cli.py tests/runtime/test_decision_digest_projection.py tests/runtime/test_decision_work_registry.py -q` → 198 passed, 0 failures, 7.81s.
- `python3 runtime/cli.py constitution validate` → exit 0, `status=ok`, `healthy=true`, `concrete_count=22`, `planned_count=2`, `missing_concrete_paths=[]`.
- `python3 runtime/cli.py decision digest --cutoff-epoch 0 --generated-at 1` → exit 0, `status=ok`, `healthy=true`, `decision_count=0`, `db_read_mode=ro_immutable`, `rendered_body` ends with `_No decisions within cutoff window._`. Verified in Codex's read-only sandbox after the immutable fallback change: the primary `mode=ro` open failed (SQLite tried to touch `-wal`/`-shm` sidecars that the sandbox disallows), so the `mode=ro&immutable=1` retry served the request and the CLI returned the deterministic empty-window payload without crashing. On the host (writable) side the primary `mode=ro` path serves the same payload with `db_read_mode=ro`; both paths are confirmed reachable by `test_db_read_mode_is_valid_value`, which accepts either value.
- Repro of Codex's sandbox failure mode (both paths fail cleanly): `CLAUDE_POLICY_DB=/tmp/does-not-exist-slice14-v2.db python3 runtime/cli.py decision digest --cutoff-epoch 0 --generated-at 1` → exit 1 with `{"status":"error","message":"decision digest: failed to read DB at /tmp/does-not-exist-slice14-v2.db read-only; mode=ro: unable to open database file; mode=ro+immutable=1: unable to open database file"}` on stderr; no file or parent dir created.

### Phase 7 Slice 15 — Read-only decision-digest body drift validation

Slice scope: add the pure drift-validator and the CLI surface that bridges the canonical decision store to it. Analogous to how `runtime/core/hook_doc_validation.py` + `cc-policy hook doc-check` pair with the hook-doc projection. No digest files are written; no decisions/work items are mutated; no constitution registry entries, CUTOVER_PLAN, prompt-pack behavior, hook wiring, settings, generated hook docs, bridge/watchdog files, or Phase 8 deletion are touched.

Design decisions:
- Validator lives in the same module as the builder (`runtime/core/decision_digest_projection.py`) rather than a new file. Both surfaces share `render_decision_digest`, the hash helper, and `_filter_and_sort`; splitting them into two files would duplicate the renderer dependency without an offsetting isolation benefit. Module-load discipline is preserved: AST tests already pin the imports, and the CLI-side function-scope import rule covers validator use the same way it covers builder use.
- Tolerant trailing-newline rule copied verbatim from `hook_doc_validation.py`: count contiguous trailing `\n` on expected and candidate, pad candidate up to the expected count, never remove content. Extra trailing newlines on the candidate are real drift. Tests pin the strip-all-trailing → healthy case and the append-extra-newlines → drift case.
- Report shape mirrors the hook-doc validator (`status`, `healthy`, `expected_content_hash`, `candidate_content_hash`, `exact_match`, `expected_line_count`, `candidate_line_count`, `first_mismatch`, `generator_version`) plus two decision-specific fields (`decision_ids`, `cutoff_epoch`). `VALIDATION_STATUS_OK`/`VALIDATION_STATUS_DRIFT` module-level constants mirror the hook-doc vocabulary so downstream CI / invariant checks can key off a single string per outcome.
- `expected_content_hash` is computed by re-running `render_decision_digest` and hashing the bytes. A test (`test_expected_hash_matches_projection_content_hash`) pins that this hash equals `DecisionDigest.content_hash` emitted by `build_decision_digest_projection` for the same inputs, so the validator and the builder cannot silently drift on which body is "expected".
- CLI: the `digest-check` action reuses the same read-only DB open path as `digest` (`mode=ro` primary, `mode=ro&immutable=1` fallback, `db_read_mode` in payload). Shared logic was hoisted to a single `_read_decisions_ro(subcommand=...)` helper inside `_handle_decision` so both subcommands have one authority for how the CLI touches the DB — dual read paths would make Phase 7's read-only guarantees non-singular. Function-scope imports of `decision_digest_projection` / `decision_work_registry` remain the discipline (AST tests unchanged).
- Exit codes / payload: healthy → `_ok()` (exit 0, `status=ok`). Drift → stdout JSON with `status=violation` and full report + adapter fields, exit code 1. Malformed inputs (missing candidate path, directory candidate, non-int cutoff, DB read failure) → `_err()` on stderr with `status=error` and a `decision digest-check:` prefix.

Source changes:
- `runtime/core/decision_digest_projection.py`: added `VALIDATION_STATUS_OK` / `VALIDATION_STATUS_DRIFT` constants, `_trailing_newline_count`, `_normalise_trailing_newline`, `_first_mismatch`, and `validate_decision_digest(candidate, decisions, *, cutoff_epoch)` returning the stable report dict. Updated `__all__` to export the new public surface. The imports at module scope remain `hashlib` + `typing` + `decision_work_registry.DecisionRecord` + `projection_schemas` only; no new live-module dependency.
- `runtime/cli.py`: refactored `_handle_decision` to gate on the action name once and hoist function-scope imports + a shared `_read_decisions_ro` helper above both branches. Added the `digest-check` action body (candidate file read, DB read-only open via the shared helper, `validate_decision_digest` call, payload shaping, exit-code mapping). Argparse subparser `decision digest-check` added with `--candidate-path` (required), `--cutoff-epoch` (default `"0"`), `--status`, `--scope`. Docstring for `_handle_decision` extended with the `digest-check` action description.

Test changes:
- `tests/runtime/test_decision_digest_projection.py`: added `TestValidateDecisionDigest` class with 18 tests across happy round trip, expected-hash-matches-projection pin, trailing-newline tolerance (strip one / strip all → healthy; append extra → drift), tampered title drift with `first_mismatch` shape, missing-bullet reports `candidate=None`, extra-content-line reports an extra on the candidate side, empty candidate vs empty-window projection drift, empty-window round trip healthy, report key shape, line-count types/non-negativity, decision-ids render order echo, cutoff echo, generator-version echo, and ValueError propagation for non-str candidate / duplicate decisions / negative cutoff. `TestModuleSurface` expanded to pin the new `__all__` entries and the `VALIDATION_STATUS_*` constants. File now 66 tests (was 48).
- `tests/runtime/test_decision_digest_cli.py`: added `_digest_check_args` helper and a `TestDigestCheck` class with 13 tests across healthy round trip (exit 0, `report.healthy=true`, `exact_match=true`, `first_mismatch=null`), required payload keys (9 keys including `db_read_mode`), `db_read_mode ∈ {"ro","ro_immutable"}`, absolute `candidate_path` echo, trailing-newline tolerance (strip → healthy), tampered title → exit 1 with `status=violation`, filter binding (candidate rendered unfiltered against `--status=accepted` → drift; candidate rendered with `--scope=kernel` against same filter → healthy; `--cutoff-epoch=2500` healthy), and error paths (missing candidate, directory candidate, non-int cutoff, missing DB with no file created). File now 45 tests (was 32).

Evidence:
- `python3 -m pytest tests/runtime/test_decision_digest_projection.py tests/runtime/test_decision_digest_cli.py tests/runtime/test_decision_work_registry.py -q` → 229 passed, 0 failures, 11.97s.
- `python3 runtime/cli.py constitution validate` → exit 0, `status=ok`, `healthy=true`, `concrete_count=22`, `planned_count=2`, `missing_concrete_paths=[]` (unchanged — Slice 15 does not touch the constitution registry).
- Healthy direct-command round trip: render the expected body via `cc-policy decision digest`, write `rendered_body` to a tmp candidate, then call `python3 runtime/cli.py decision digest-check --candidate-path <tmp>/cand.md --cutoff-epoch 0` → exit 0, `status=ok`, `report.status=ok`, `report.healthy=true`, `report.exact_match=true`, `report.expected_content_hash==report.candidate_content_hash==sha256:4a2712812e344357dc708fcc0d2f52a040a04486fbf16707f2d0dec0e7d53194`, `db_read_mode=ro`.
- Drift direct-command: append `garbage\n` to the same candidate and rerun → exit 1, `status=violation`, `report.status=drift`, `report.first_mismatch.line=9` (the "garbage" line past the expected tail), `db_read_mode=ro`. The JSON payload goes to stdout so CI can key drift off exit 1 without re-parsing.

Slice 15 doc-drift correction (docstring alignment for Slices 14/15):
- Motivation: after Slices 14 and 15 landed the read-only CLI surfaces (`cc-policy decision digest` and `decision digest-check`), two in-tree module docstrings still described the pre-Slice-14 world. This is the same class of architecture-preservation drift the CLAUDE.md constitution calls out: "one authority per operational fact" and "docs are claims, not proof" — leaving the stale wording in place would encourage future agents to build a second CLI path "because the current one is a future slice". Correction is narrowly scoped to docstrings and one test comment; no runtime behavior, tests, CUTOVER_PLAN, MASTER_PLAN, constitution registry, or bridge files are touched.
- `runtime/core/decision_digest_projection.py` module docstring: replaced the "later slices can either validate … or replace markdown digest folklore" sentence and the "future slice wires a CLI surface" sentence with the accurate landed state — the module is a pure builder + validator whose CLI adapters (`decision digest` Slice 14, `decision digest-check` Slice 15) live in `runtime/cli.py _handle_decision` and reach this module via function-scope imports. The scope-discipline block and "does NOT do" block were tightened to name the validator and to say "the read-only DB query and filter pass-through live in the CLI adapter" rather than "wiring to the canonical store is a future CLI slice". The authority boundary is preserved verbatim: this module still has no filesystem I/O, no DB access, no subprocess, no CLI wiring, no live routing imports, no hook imports.
- `runtime/core/decision_work_registry.py` module docstring: replaced the "CLI exposure (no `cc-policy decision ...` commands yet)" and "not imported by … `cli.py`" wording with the accurate invariant: no live routing / policy / hook imports (unchanged), and `runtime/cli.py` may reach this registry only through the function-scope import inside `_handle_decision` for the read-only `decision digest` / `decision digest-check` adapters (`mode=ro` / `mode=ro&immutable=1`, no schema bootstrap, no writes). The "deferred" section's projection-family bullet was tightened to reflect that the decision-digest projection generator now exists (Slice 13). The no-events/no-evaluation/no-leases/no-settings/no-hooks discipline line is preserved unchanged.
- `tests/runtime/test_decision_work_registry.py`: the comment above `test_cli_does_not_import_decision_work_registry_at_module_level` was expanded from "Phase 7 Slice 14 introduced … cc-policy decision digest" to also name Slice 15's `digest-check` adapter so the rationale stays in sync. No assertion logic changed — the test still walks `tree.body` and forbids module-scope import, which is exactly the invariant the updated docstring names.
- No other test needed to be adjusted: no existing AST/doc discipline test keyed off the stale "future slice" / "no CLI exposure" wording. Searches across `tests/` for those phrases returned no matches in the affected modules.

Review evidence (direct Codex smoke after Slice 15 acceptance):
- Codex ran `python3 runtime/cli.py constitution validate` in its read-only sandbox → exit 0, `healthy=true`, `concrete_count=22`.
- Codex ran `python3 runtime/cli.py decision digest-check --candidate-path ClauDEX/CURRENT_STATE.md --cutoff-epoch 0` → exit 1 with structured `status=violation`, `report.status=drift`, `report.first_mismatch.line=1`, and `db_read_mode=ro_immutable` — as expected (CURRENT_STATE.md is not a canonical decision digest, so line 1 drifts immediately), and the immutable fallback path served the read as designed for the Codex sandbox. This is the independent reviewer smoke that validated the Slice 15 CLI surface end-to-end against a real on-disk file in a genuinely read-only environment.

Post-correction evidence:
- `python3 -m pytest tests/runtime/test_decision_digest_projection.py tests/runtime/test_decision_digest_cli.py tests/runtime/test_decision_work_registry.py -q` → 229 passed, 0 failures, 10.05s (unchanged from Slice 15 acceptance).
- `python3 runtime/cli.py constitution validate` → exit 0, `status=ok`, `healthy=true`, `concrete_count=22`, `planned_count=2`, `missing_concrete_paths=[]` (unchanged at Slice 15 time; bumped to `concrete_count=23`, `planned_count=1` in Slice 16).

### Phase 7 Slice 16 — Pure projection reflow staleness planner

Slice scope: deliver the first minimal reflow enforcement primitive as a pure runtime authority, and promote the planned slug `projection_reflow_orchestrator_module` to a concrete constitution-level module in the same bundle. No daemon, no scheduler, no file writes, no CLI, no guardian/CI wiring, no prompt-pack behavioral change, no hook wiring, no settings touches, no bridge/watchdog files.

Design decisions:
- Pure-function authority. The module exposes `assess_projection_freshness(projection_id, projection_or_metadata, *, changed_authorities, changed_files) -> ProjectionAssessment` and `plan_projection_reflow(projections, *, changed_authorities, changed_files) -> ReflowPlan`. No filesystem I/O, no DB, no subprocess, no CLI adapter, no hook import. The planner answers a purely logical question from in-memory inputs — a future slice may wrap this in a scheduler or CI gate; those are explicitly out of scope here.
- Staleness rule (pinned by tests): a projection is `"stale"` iff either `metadata.stale_condition.watched_authorities ∩ changed_authorities` or `metadata.stale_condition.watched_files ∩ changed_files` is non-empty. Otherwise `"fresh"`. Projections with empty watch lists (the explicit opt-out allowed by `StaleCondition`) are always `"fresh"` even when large change sets are supplied — matching the "some projections may explicitly opt out of staleness tracking" contract from `projection_schemas.StaleCondition`.
- Single metadata resolution helper. `extract_projection_metadata(obj)` accepts either a bare `ProjectionMetadata` or any object carrying a `.metadata` attribute typed as `ProjectionMetadata` (which every concrete `projection_schemas` dataclass — `PromptPack`, `RenderedMasterPlan`, `DecisionDigest`, `HookDocProjection`, `GraphExport`, `SearchIndexMetadata` — satisfies). Raises `ValueError` on any other shape so callers fail loudly rather than silently producing an "always fresh" verdict. One helper resolves once for the whole module — no per-call-site ad-hoc attribute probing.
- Deterministic output. Watched-authority and changed-authority sets are normalised to sorted tuples of unique strings before comparison, so the ordering of the caller's iterables does not change the output bytes. Tests verify that `assess_projection_freshness(..., changed_authorities=("stage_transitions","role_capabilities"), ...)` and `changed_authorities=["role_capabilities","stage_transitions"]` produce byte-equal assessments. Batch planner sorts its `assessments` tuple by `projection_id`, so the plan has a deterministic wire shape regardless of input-iterable order.
- Frozen, JSON-serialisable result shapes. `ProjectionAssessment` and `ReflowPlan` are both `@dataclass(frozen=True)`. Each carries an `.as_dict()` helper that converts tuples to lists and `source_versions` 2-tuples to 2-element lists so tests can pin `json.dumps(... .as_dict())` round-trip equivalence. `ReflowPlan.__post_init__` enforces `total == len(assessments)` and `fresh_count + stale_count == total` so a malformed plan cannot be constructed by a future caller; tests pin both invariants with direct `pytest.raises(ValueError)` construction.
- Single authority, no parallel planned area. Because the concrete module now owns the "projection reflow" operational fact, the planned slug `projection_reflow_orchestrator_module` is removed from `_PLANNED` in the same bundle (per CLAUDE.md Architecture Preservation: "No parallel authorities as a transition aid"). A regression test pins `cr.lookup("projection_reflow_orchestrator_module") is None` so it cannot resurface, plus a bulk scan that forbids any planned slug containing `"projection_reflow"` or `"reflow_orchestrator"`.
- Matched entries surface *why* stale. Every assessment reports `matched_authorities` and `matched_files` as sorted intersections, so a consumer (a future reflow scheduler, a Guardian gate, a CI check) knows exactly which watched entry triggered the verdict without re-running the match. Tests pin that matched lists are sorted and that duplicates in the change set do not duplicate matches.
- No CLI adapter this slice. Future slices may expose the planner via `cc-policy projection reflow-plan` (or similar) using the same function-scope-import discipline the decision-digest adapters use. A dedicated `test_cli_does_not_import_projection_reflow` pins that `runtime/cli.py` does not reach this module anywhere in its AST, so "no CLI adapter this slice" is a mechanical invariant, not a docstring claim.

Source changes:
- `runtime/core/projection_reflow.py` (new, 320 LOC): module docstring with decision annotation + scope discipline + staleness rule + "does NOT do" block; status constants (`REFLOW_STATUS_FRESH`, `REFLOW_STATUS_STALE`, `REFLOW_STATUSES`); frozen dataclasses `ProjectionAssessment` and `ReflowPlan` with `.as_dict()` serialisers and `ReflowPlan.__post_init__` count invariants; helpers `extract_projection_metadata`, `_normalise_change_set`, `_extract_schema_type`; public API `assess_projection_freshness` and `plan_projection_reflow`. Imports are stdlib-only plus `runtime.core.projection_schemas` for `ProjectionMetadata` / `StaleCondition` type contracts — nothing else from `runtime.core` is reached.
- `runtime/core/constitution_registry.py`: promoted `projection_reflow_orchestrator_module` planned slug to a concrete `ConstitutionEntry` for `runtime/core/projection_reflow.py` with a rationale that names the Slice 16 promotion and the "no daemon, no scheduler, no CLI" boundary. Removed the planned entry in the same edit (replaced with a comment naming the Slice 16 promotion so a future agent cannot re-add it). Updated module docstring "Previously planned areas" list to include the new promotion line.

Test changes:
- `tests/runtime/test_projection_reflow.py` (new, 53 tests): `TestStatusVocabulary` (3 — status constants, `REFLOW_STATUSES` ordering, set equality); `TestExtractProjectionMetadata` (7 — bare-metadata passthrough, unwraps for `HookDocProjection`/`PromptPack`/`DecisionDigest`, rejects random object, rejects object with wrong-type `.metadata`, rejects `None`); `TestAssessProjectionFreshness` (15 — authority match, file match, no overlap, empty watch lists always fresh, both-kind match, partial subset match, watched/matched sort, schema_type read from concrete, schema_type None for bare metadata, metadata fields echoed, deterministic output regardless of input order, duplicate entries do not duplicate matches, empty change set fresh, frozen dataclass immutability, `as_dict` JSON-serialisable round trip); `TestAssessInputValidation` (6 — non-string / empty id, missing metadata, non-string / empty-string / `None` change-set entries); `TestPlanProjectionReflow` (13 — batch assessment, sorted by projection_id, deterministic regardless of input order, changed sets echoed sorted, duplicate id raises, non-tuple entry raises, empty plan zero counts, accepts concrete projection dataclasses, `ReflowPlan` count invariants rejected on malformed construction, `as_dict` JSON round trip, change-set validation propagates, non-string id in entry); `TestModuleSurface` (3 — `__all__` equality, assessment is frozen dataclass, plan is frozen dataclass); `TestShadowOnlyDiscipline` (5 — forbidden-token substring scan over AST-imported names, permitted `runtime.core` prefix is only `projection_schemas`, core routing modules do not import reflow, `runtime/cli.py` does not import reflow, no subprocess/sqlite3/pathlib/shutil imports).
- `tests/runtime/test_constitution_registry.py`: bumped concrete count test 22 → 23 (renamed `test_concrete_count_is_twenty_two` → `test_concrete_count_is_twenty_three`, comment updated with "+ 1 Phase 7 S16 (projection_reflow)"); added `runtime/core/projection_reflow.py` to `CUTOVER_PLAN_CONCRETE_FILES` set and to `test_all_concrete_paths_helper_returns_declaration_order` tuple (last entry, preserving declaration order); updated `test_registry_is_tuple` to slice at index 23 for the concrete/planned partition check; updated `test_lookup_finds_planned_area_by_slug` to use `memory_retrieval_compiler_modules` (still-planned) since `projection_reflow_orchestrator_module` is no longer planned. Added three new focused tests: `test_projection_reflow_module_is_concrete` (lookup + `is_constitution_level`), `test_projection_reflow_orchestrator_slug_is_gone_from_planned` (old slug returns `None` and is not in `PLANNED_AREA_NAMES`), `test_no_broad_projection_reflow_planned_slug` (no planned slug may contain `"projection_reflow"` or `"reflow_orchestrator"`). Pins the "no parallel planned authority after concrete exists" invariant.

CUTOVER_PLAN changes:
- Added `runtime/core/projection_reflow.py` (promoted from planned area in Phase 7 Slice 16) to the "Constitution-Level Files" list. Removed the "- the future projection reflow orchestration module" bullet in the same edit so the list has no parallel-authority line for the same area. The memory/retrieval compiler planned area bullet remains.

Evidence:
- `python3 -m pytest tests/runtime/test_projection_reflow.py -q` → 53 passed, 0 failures, 0.16s (all new tests green on first run).
- `python3 -m pytest tests/runtime/test_projection_reflow.py tests/runtime/test_constitution_registry.py tests/runtime/test_projection_schemas.py -q` → 180 passed, 0 failures, 0.33s (reflow + constitution set-equality + schema invariants all intact).
- `python3 runtime/cli.py constitution validate` → exit 0, stdout `{"concrete_count": 23, "planned_count": 1, "missing_concrete_paths": [], "planned_areas": ["memory_retrieval_compiler_modules"], "healthy": true, ...}`, `status=ok`. Confirms the promotion landed (23 concrete, down to 1 planned), the registered `runtime/core/projection_reflow.py` resolves on disk (`missing_concrete_paths=[]`), and the only remaining planned area is `memory_retrieval_compiler_modules` — the reflow planner is no longer advertised as future work.
- Full `tests/runtime` suite: 3849 passed, 5 pre-existing failures in unrelated files (`test_claudex_stop_supervisor.py`, `test_statusline.py`, `test_subagent_start_payload_shape.py` — all about live session correlation / statusline / stop supervisor state, none touching projection reflow, constitution registry, projection schemas, or any Slice 16 surface). 1 xpassed. These 5 failures are baseline noise carried over from prior slices and are unaffected by Slice 16.

Slice 16 correction (bare-string change-set rejection + real-builder integration coverage):
- Motivation: Codex direct smoke flagged a silent false-fresh: passing `changed_files="CLAUDE.md"` (a bare `str`) to `assess_projection_freshness` returned `status='fresh'` even when `CLAUDE.md` was in `watched_files`. Because `str` is iterable over characters, `_normalise_change_set` was decomposing the value into `("C","L","A",...)`, none of which matched any watched file, and reporting a healthy verdict. The contract is "iterable collection of non-empty strings", not "character-iterable"; silently coercing a bare string to a singleton would equally mask caller bugs, so the right fix is loud rejection. This is the same class of "fail loudly rather than guess" rule the CLAUDE.md constitution calls out.
- `runtime/core/projection_reflow.py`: `_normalise_change_set` now rejects a top-level `str`, `bytes`, `bytearray`, or `memoryview` with a `ValueError` whose message names the exact hazard ("A bare string is iterable over characters…") and points at the correct remedy ("wrap in a tuple/list, e.g. `('CLAUDE.md',)`"). The check runs before `iter(items)` so every other validation path is unchanged. Module docstring of `_normalise_change_set` updated to name the new rejection rule. No public-API surface change beyond the strictened input contract; existing callers passing tuples/lists/sets continue to work unchanged.
- `tests/runtime/test_projection_reflow.py`: `TestAssessInputValidation` gained five new tests — `test_bare_string_changed_files_is_rejected`, `test_bare_string_changed_authorities_is_rejected`, `test_bare_bytes_changed_files_is_rejected`, `test_bare_bytearray_changed_authorities_is_rejected`, and `test_bare_string_plan_propagates_same_validation` (covers both `changed_files` and `changed_authorities` on the batch planner). Each directly exercises the Codex-reported repro path. No existing test needed to change.
- `tests/runtime/test_projection_reflow.py`: added a dedicated `TestRealBuilderOutputs` class (9 tests) that passes actual outputs from `runtime.core.hook_doc_projection.build_hook_doc_projection`, `runtime.core.prompt_pack.build_prompt_pack`, and `runtime.core.decision_digest_projection.build_decision_digest_projection` into the planner. Covers: round-trip fresh when change set is empty for each builder, stale on watched-file match (`hooks/HOOKS.md` for the hook doc, `CLAUDE.md` for the prompt pack), stale on watched-authority match (`hook_wiring` for the hook doc, `decision_records` for the decision digest), and a batch plan over all three real projections that lights up one axis per projection (`3 stale, 0 fresh`) plus a no-overlap batch (`0 stale, 3 fresh`). The builder imports live in test methods only; `projection_reflow.py` remains unaware of those modules (pinned by the pre-existing `test_projection_reflow_does_not_import_live_modules` shadow-only test, which lists `hook_doc_projection`, `decision_digest_projection`, `prompt_pack`, and `prompt_pack_resolver` among its forbidden-token substrings).
- No CUTOVER_PLAN, no constitution registry, no CLI, no daemon/scheduler change — this correction is source + tests + state only, exactly as scoped by Codex.

Correction evidence:
- Direct Codex repro after the fix: `python3 -c "from runtime.core import projection_reflow as pr; from runtime.core.projection_schemas import ProjectionMetadata, StaleCondition; md=ProjectionMetadata(generator_version='1', generated_at=0, stale_condition=StaleCondition(rationale='r', watched_files=('CLAUDE.md',))); print(pr.assess_projection_freshness('p', md, changed_authorities=(), changed_files='CLAUDE.md').as_dict())"` → exit 1 with `ValueError: changed_files must be an iterable collection of non-empty strings, not a bare str. A bare string is iterable over characters, which would silently decompose e.g. 'CLAUDE.md' into ('C','L','A',...) and produce a false 'fresh' verdict. Wrap the value in a tuple/list (e.g. ('CLAUDE.md',)) or pass an empty collection.` The silent false-fresh path is closed.
- `python3 -m pytest tests/runtime/test_projection_reflow.py -q` → 67 passed, 0 failures, 0.20s (was 53; +5 bare-string/bytes rejection, +9 real-builder integration). Both new test groups pin invariants that the pre-correction code would have failed.
- `python3 -m pytest tests/runtime/test_projection_reflow.py tests/runtime/test_constitution_registry.py tests/runtime/test_projection_schemas.py -q` → 194 passed, 0 failures, ~0.4s (was 180; +14 new reflow tests; constitution + schema invariants unchanged).

### Phase 7 Slice 17 — Pure memory/retrieval projection compiler

Scope (from Codex instruction 0031-p2ow48): deliver the final remaining planned area `memory_retrieval_compiler_modules` as a pure shadow-kernel authority that compiles deterministic `SearchIndexMetadata` and `GraphExport` projections from caller-supplied canonical memory sources and graph edges. Non-goals: no search engine / vector DB / daemon / scheduler / CLI / disk scan; no second memory authority alongside this one; callers must supply records explicitly. Promote the slug to concrete in the same bundle and exhaust the CUTOVER_PLAN planned-area set.

Design:
- `runtime/core/memory_retrieval.py` is the sole runtime authority that turns caller-supplied records into typed projection records. Public contract (pinned by tests): constants `MEMORY_RETRIEVAL_GENERATOR_VERSION="1.0.0"`, `MANIFEST_VERSION="1.0.0"`, `MEMORY_SOURCE_KIND="memory_sources"`, `GRAPH_EDGE_KIND="graph_edges"`; frozen dataclasses `MemorySource(source_id, source_kind, source_version, path, title, body, tags=())` and `GraphEdge(source_id, target_id, relation, evidence_version)`; pure renderers `render_search_index_manifest` / `render_graph_export_manifest`; pure compilers `build_search_index_metadata(sources, *, index_name, generated_at, watched_authorities=(), watched_files=(), manifest_version) -> SearchIndexMetadata` and `build_graph_export(sources, edges, *, generated_at, watched_authorities=(), watched_files=(), manifest_version) -> GraphExport`. No filesystem I/O, no DB, no subprocess, no CLI surface, no hook adapter, no live-module imports at module scope — AST-inspection test pins that only `runtime.core.projection_schemas` reaches the module from the `runtime.core` namespace.
- Determinism: both compilers sort inputs internally (sources by `source_id`; edges by `(source_id, target_id, relation, evidence_version)`) and render manifests via `json.dumps(..., sort_keys=True, ensure_ascii=False)`. `content_hash = "sha256:" + sha256(manifest.utf8).hexdigest()`. Caller iteration order never leaks into hashes; tests pin that reversed inputs produce byte-identical `SearchIndexMetadata` / `GraphExport` records (content_hash + provenance + counts all equal).
- Validation discipline: duplicate `source_id` values and duplicate directed-edge triples raise `ValueError` — silent dedupe would hide caller bugs. Unknown edge endpoints (source or target not in corpus) raise. Self-loop edges raise. `watched_authorities` / `watched_files` are normalised via `_normalise_watched`, which mirrors the Slice 16 correction: a top-level bare `str` / `bytes` / `bytearray` / `memoryview` is rejected with `ValueError` naming the exact hazard, rather than silently decomposing `"CLAUDE.md"` into character tuples. Non-string / empty entries are rejected; the result is sorted and deduplicated.
- Reflow integration: the `SearchIndexMetadata.metadata.stale_condition` and `GraphExport.metadata.stale_condition` carry caller-supplied watched sets verbatim, so the projections round-trip through `runtime.core.projection_reflow.plan_projection_reflow` as ordinary projections (pinned by `TestReflowIntegration`: watched-authority change lights up the search index, watched-file change lights up the graph export, batch plan over both is fresh with no overlap and stale when both watched authorities match).
- `generated_at` belongs to metadata but is intentionally NOT part of the hashed manifest; the hash tracks logical corpus identity, not emission time (pinned by `test_generated_at_does_not_flip_hash`).

Source changes:
- `runtime/core/memory_retrieval.py` — new file; full compiler authority described above. Imports only `hashlib`, `json`, `dataclasses`, `typing`, and `runtime.core.projection_schemas`. No parallel memory authority: the module builds the already-declared `SearchIndexMetadata` / `GraphExport` shapes in `projection_schemas`, never re-defines them.
- `runtime/core/constitution_registry.py` — added the concrete entry `runtime/core/memory_retrieval.py` with a Slice 17 rationale that names the CUTOVER_PLAN §Canonical Memory with Derived Retrieval authority area and records the "no second memory authority" invariant. Removed the `memory_retrieval_compiler_modules` planned entry; the `_PLANNED` tuple is now empty. Updated the module docstring to note the empty-planned-set milestone and promoted the full history of planned-slug promotions into inline comments so no future slice can accidentally re-add a superseded slug. Added the Slice 17 promotion to the docstring's list of previously-planned areas. This is "no parallel authorities as a transition aid" applied literally: the concrete and planned representations of memory/retrieval cannot coexist.
- `ClauDEX/CUTOVER_PLAN.md` — §Constitution-Level Files: replaced the `- the future memory and retrieval compiler modules` bullet with `- runtime/core/memory_retrieval.py (promoted from planned area in Phase 7 Slice 17)`. The constitution-level list now has zero "future" bullets; every listed entry resolves to a concrete file on disk.

Test changes:
- `tests/runtime/test_memory_retrieval.py` — new file; 94 tests across nine sections:
  - `TestMemorySourceValidation` (11 tests): empty required-string fields raise, non-string fields raise, empty `body` is allowed, `tags` must be a tuple, tag entries must be non-empty strings, duplicate tags raise, `MemorySource` is a frozen dataclass.
  - `TestGraphEdgeValidation` (11 tests): empty / non-string fields raise, self-loop raises, `GraphEdge` is a frozen dataclass.
  - `TestSearchIndexMetadata` (16 tests): `document_count`, `index_name`, schema-type identity, `sha256:<hex>` prefix + length, determinism across input reorder, provenance ordering + `source_kind`, `source_versions` declares `memory_sources`, `stale_condition` carries rationale + sorted-deduped watched sets, hash flips on body/source_version/tags/title/path/index_name changes, hash unchanged when only `generated_at` changes, empty corpus deterministic.
  - `TestSearchIndexInputValidation` (12 tests): `sources` must be list/tuple, entries must be `MemorySource`, duplicate `source_id` raises, empty / non-string `index_name` raises, `bool` / negative `generated_at` raises, bare `str` `watched_authorities` raises with "bare" in the message, bare `bytes` `watched_files` raises, non-string watched entry raises, empty watched entry raises, empty `manifest_version` raises.
  - `TestGraphExport` (18 tests): `node_count` / `edge_count` / schema-type identity / hash prefix, determinism across source + edge reorder, provenance layout (sources then edges; source refs sorted by id, edge refs use composite `src->tgt:rel` ids), `source_versions` declares both kinds, unknown source / target endpoint raises, duplicate `(source_id, target_id, relation)` triple raises, different `relation` between the same pair is legal, `evidence_version` / `relation` change flips hash, empty edges is valid, empty corpus + empty edges deterministic, `sources` / `edges` must be list/tuple, edge entry must be `GraphEdge`, bare-str `watched_authorities` raises, duplicate source id raises.
  - `TestManifestRenderers` (3 tests): direct JSON shape pins — `document_count`, sorted document ids, sorted edge keys, generator version constant echoed; determinism across reversed inputs.
  - `TestReflowIntegration` (6 tests): `assess_projection_freshness` returns FRESH for both projections when no change overlaps; STALE on watched-authority match (search index) and watched-file match (graph export); `plan_projection_reflow` over both at once is `0 stale / 2 fresh` with no overlap and `2 stale / 0 fresh` when both watched authorities are changed. Confirms memory/retrieval projections are first-class citizens of the reflow planner.
  - `TestModuleSurface` (3 tests): `__all__` set equality, non-empty `MEMORY_RETRIEVAL_GENERATOR_VERSION`, `MEMORY_SOURCE_KIND` and `GRAPH_EDGE_KIND` are distinct.
  - `TestShadowOnlyDiscipline` (5 tests): AST inspection forbids live routing / policy / hook / settings / enforcement / stage_registry / authority_registry / constitution_registry / projection_reflow substrings; only `runtime.core.projection_schemas` is a legal `runtime.core` dependency; no `subprocess` / `sqlite3` / `os.path` / `pathlib` / `shutil` at module scope; core routing modules (`dispatch_engine`, `completions`, `policy_engine`) must not import `memory_retrieval`; `runtime/cli.py` must not import `memory_retrieval` (Slice 17 ships no CLI adapter).
- `tests/runtime/test_constitution_registry.py`: bumped `CUTOVER_PLAN_CONCRETE_FILES` with `runtime/core/memory_retrieval.py`; renamed `test_concrete_count_is_twenty_three` → `test_concrete_count_is_twenty_four` and flipped the expected count to 24; added `runtime/core/memory_retrieval.py` to the declaration-order tuple; `test_registry_is_tuple` now pins the first 24 entries as concrete and the remaining as planned; added `test_planned_area_set_is_empty_after_slice_17` pinning `planned_areas() == ()` and `PLANNED_AREA_NAMES == frozenset()`; replaced `test_lookup_finds_planned_area_by_slug` with `test_lookup_returns_none_for_any_previously_planned_slug` (planned tuple is now empty — the test verifies every previously-planned slug, including `memory_retrieval_compiler_modules`, returns `None`); added `test_memory_retrieval_module_is_concrete`, `test_memory_retrieval_compiler_slug_is_gone_from_planned`, and `test_no_broad_memory_retrieval_planned_slug` in the shape of the Slice 16 promotion tests.

Evidence:
- `python3 -m pytest tests/runtime/test_memory_retrieval.py -q` → 94 passed, 0 failures, 0.26s. Every contract listed above has at least one pinning test.
- `python3 -m pytest tests/runtime/test_constitution_registry.py tests/runtime/test_memory_retrieval.py tests/runtime/test_projection_reflow.py -q` → 233 passed, 0 failures, 0.48s. Confirms the promotion does not regress the Slice 16 reflow tests or the existing constitution invariants (no concrete-path overlap with CUTOVER_PLAN baseline, every concrete path exists on disk, normalize_repo_path edge cases, is_constitution_level overmatch suppression, shadow-only imports).
- `python3 runtime/cli.py constitution validate` → exit 0, stdout `{"concrete_count": 24, "planned_count": 0, "missing_concrete_paths": [], "planned_areas": [], "healthy": true, ...}`, `status=ok`. Confirms the final promotion landed: 24 concrete entries (up from 23), 0 planned areas (down from 1), `runtime/core/memory_retrieval.py` resolves on disk, CUTOVER_PLAN planned-area set exhausted.
- Full `tests/runtime` suite: 3961 passed, 5 pre-existing failures in unrelated files (`test_claudex_stop_supervisor.py::test_stop_hook_allows_stop_for_consumed_pending_review`, `test_statusline.py` snapshot tests, `test_subagent_start_payload_shape.py::test_subagent_type_matches_subsequent_subagent_start_agent_type` — all about live supervisor / statusline / subagent correlation state, none touching memory_retrieval, projection_reflow, constitution_registry, projection_schemas, or any Slice 17 surface). 1 xfailed. These 5 failures are baseline noise carried over from prior slices and are unaffected by Slice 17.

Slice 17 correction (tag canonicalisation — caller order must not flip hashes):
- Motivation: Codex direct smoke flagged a data-model bug. `MemorySource.tags` already rejected duplicates and the docstring claimed this prevented "two callers producing different hashes for identical logical content", but tag *order* still affected the search-index content hash. Repro before the fix: two `MemorySource` records identical except for `tags=('a','b')` vs `tags=('b','a')` produced different `SearchIndexMetadata.content_hash` values. Tags are a label *set*, not a sequence; caller iteration order must not leak into downstream projections any more than source-list order does.
- `runtime/core/memory_retrieval.py`: `MemorySource.__post_init__` now canonicalises `tags` to ascending sorted order after the existing validation + duplicate-rejection pass. Since the dataclass is frozen, the mutation uses the established `object.__setattr__` escape hatch (only invoked when the supplied tuple is not already sorted, so the common already-canonical path allocates no new tuple). Field-level docstring updated to spell out the "unordered label set, canonicalised to sorted order" contract and cross-reference the duplicate-rejection rule. No other behaviour change: non-tuple / non-string / empty / duplicate entries still raise `ValueError`, and every other field validator is untouched.
- `tests/runtime/test_memory_retrieval.py`: `TestMemorySourceValidation` gained five new tests — `test_tags_are_canonicalised_to_sorted_order` (two-element reversed input stores sorted), `test_tags_three_way_canonicalisation` (three-element reversed input stores sorted), `test_already_sorted_tags_pass_through_unchanged` (pre-sorted input is a no-op), `test_tag_order_does_not_change_search_index_content_hash` (Codex repro: `('alpha','beta')` vs `('beta','alpha')` must produce byte-identical `SearchIndexMetadata.content_hash`), and `test_tag_order_does_not_change_graph_export_content_hash` (same invariant flows through the graph export, since graph nodes carry the same source manifest entries). No existing test needed to change — the pre-existing `test_tags_change_flips_hash` still exercises "add a tag where there was none", which is a genuine label-set change.
- No constitution/CUTOVER change: the data-model correction is source + tests + state only, exactly as scoped by Codex.

Correction evidence:
- Direct Codex repro after the fix: `python3 -c "from runtime.core import memory_retrieval as mr; a=mr.MemorySource(source_id='x',source_kind='doc',source_version='v1',path='p',title='t',body='b',tags=('a','b')); b=mr.MemorySource(source_id='x',source_kind='doc',source_version='v1',path='p',title='t',body='b',tags=('b','a')); print('a.tags:', a.tags); print('b.tags:', b.tags); print('h_a:', mr.build_search_index_metadata((a,),index_name='idx',generated_at=0).content_hash); print('h_b:', mr.build_search_index_metadata((b,),index_name='idx',generated_at=0).content_hash)"` → `a.tags=('a','b')`, `b.tags=('a','b')`, `h_a=h_b=sha256:3b3df84f295f9791704057e49ebba4cf263d144ce43e08ef2d03c3d5e7fc520b`. Tag order no longer leaks into the projection hash.
- `python3 -m pytest tests/runtime/test_memory_retrieval.py -q` → 99 passed, 0 failures, 0.23s (was 94; +5 canonicalisation tests). Every new invariant has a pinning test; the pre-existing search-index determinism / hash-change tests continue to pass.

Single-authority integrity (post-Slice-17):
- `runtime/core/memory_retrieval.py` is the only `runtime/core` module that builds `SearchIndexMetadata` or `GraphExport` projections. AST shadow-only test plus the existing `test_core_routing_modules_do_not_import_memory_retrieval` test ensure the compiler has no routing-layer consumers.
- CUTOVER_PLAN §Constitution-Level Files has no "future" bullets; every listed entry resolves to a concrete file on disk. `planned_count=0` is a first-time milestone for the cutover.
- `PLANNED_AREA_NAMES == frozenset()` makes the "no parallel authorities as a transition aid" invariant mechanically checkable: if a later slice tries to re-add a planned slug alongside a concrete promotion, `test_planned_area_set_is_empty_after_slice_17` will fail.

### Historical evidence (Phase 2b live-capture gate)

The following carrier/producer pipeline was verified during Phase 2b and
remains intact through Phase 5:

- Carrier transport (pre-agent.sh write + subagent-start.sh consume): 57 tests
- Producer (`cc-policy dispatch agent-prompt` CLI + `runtime/core/agent_prompt.py`): 43 tests
- Operator wiring (`CLAUDE.md` § "ClauDEX Contract Injection")

**Live capture (2026-04-09):** `runtime/dispatch-debug.jsonl` entry 39/39
confirms production reachability — `tool_input.prompt` starts with
`CLAUDEX_CONTRACT_BLOCK:` at column 0 on line 1.

## Clean Restart Procedure

1. Archive any active dead bridge run:

```bash
cd /Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork
./scripts/claudex-bridge-down.sh --archive
```

2. Start a fresh supervised session:

```bash
cd /Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork
./scripts/claudex-overnight-start.sh --session overnight-prod3 --no-attach
```

3. Verify:

```bash
./scripts/claudex-bridge-status.sh
tmux capture-pane -pt overnight-prod3:1.1 | tail -120
tmux capture-pane -pt overnight-prod3:1.2 | tail -120
```

4. If the bridge remains `idle` with:

- `queue_depth_fs = 0`
- no latest response
- no pending-review artifact

then do **not** wait for a handoff that does not exist. Seed the Current
Restart Slice explicitly through the supervisor path.

## Clean Work Boundaries

Treat these as repo clutter, not work product:

- `runtime/cc_state.db`
- `runtime/dispatch-debug.jsonl`
- `runtime/prebash-trace.log`
- `traces/`
- `stats-cache.json`
- `watch_*`

Treat these as dead operator state unless intentionally reused:

- archived braid runs
- old `overnight*` tmux sessions
- stale progress-monitor / approver pid files

### Phase 8 Slice 1 — Installed-truth legacy deletion inventory

Scope: bounded, evidence-backed inventory of superseded / legacy authorities
so subsequent Phase 8 slices have explicit deletion targets. **No code,
tests, or hooks deleted in this slice.** No bridge/watchdog edits. No new
control plane.

Artifact: `ClauDEX/PHASE8_DELETION_INVENTORY.md`.

Inspected surfaces:
- `settings.json` hook wiring (no `auto-review.sh` reference; `log.sh`
  correctly absent because it is a library, not a hook entry point).
- `hooks/*.sh` (30+ scripts; `auto-review.sh` (36 KB) was the genuine
  orphan — unwired and targeted for deletion. `log.sh` (3.8 KB) is a
  shared logging library sourced by 14 live hooks, NOT orphaned.
  `block-worktree-create.sh` was manifest-flagged deprecated — resolved
  in Phase 8 Slice 3: WorktreeCreate entry un-deprecated as ACTIVE,
  PreToolUse:EnterWorktree entry removed).
- `hooks/HOOKS.md` is an exact-match derived projection of
  `hook_manifest` (`hook doc-check` → `status=ok`, `exact_match=true`
  post-Slice-3). The earlier "drifts from wired truth" phrasing was
  wrong; the real issue was the deprecated-block-worktree manifest
  status, resolved in Phase 8 Slice 3.
- `runtime/core/dispatch_engine.py`, `runtime/core/completions.py`,
  `runtime/core/dispatch_shadow.py` (tester-compat residue).
- `runtime/core/constitution_registry.py` (24 concrete, planned set empty
  post-Slice-17).
- `runtime/core/proof.py` + `runtime/core/evaluation.py` (proof_state
  superseded per `evaluation.py:8`, but `proof.py` is imported by
  `runtime/cli.py:52` and 4 tests — **not orphaned, not a first deletion
  target**).
- `runtime/core/dispatch.py` (`dispatch_queue` LEGACY-COMPAT).
- `runtime/core/stage_registry.py` (docstring confirms reviewer/tester
  migration motivation).
- Donor docs (post-Slice-6): `docs/ARCHITECTURE.md`, `docs/DISPATCH.md`,
  `docs/PLAN_DISCIPLINE.md`, `implementation_plan.md`, `MASTER_PLAN.md`.
  `docs/AGENT_HANDOFFS.md` and `docs/HANDOFF_2026-03-31.md` were deleted
  in Phase 8 Slice 4. `docs/PHASE0_HOOK_AUTHORITY_RECOMMENDATIONS.md` was
  deleted in Phase 8 Slice 5 after preservation audit confirmed
  `MASTER_PLAN.md` INIT-PHASE0 holds all three recommendations + the
  11-item HOOKS.md delta. `docs/HANDOFF_2026-04-05_SYSTEM_EVAL.md` was
  deleted in Phase 8 Slice 6 after preservation audit confirmed
  `MASTER_PLAN.md` INIT-CONV (L2631-3043) holds the North Star, 6
  packets, and retest set; the `MASTER_PLAN.md:2645` **Handoff:** link
  was replaced with a historical note in the same bundle.

Tests run: none added or modified in this slice (instruction permits
already-true invariant pins; deferring to the deletion slice that actually
removes the compat so the pin lands next to the removal).

Recommended first deletion target (Phase 8 Slice 2): **`hooks/auto-review.sh`
+ its three scenario tests** (`tests/scenarios/test-auto-review.sh`,
`test-auto-review-heredoc.sh`, `test-auto-review-quoted-pipes.sh`). The hook
is unwired (`grep -l auto-review.sh **/*.json` → no files), decommissioned
by written authority in `MASTER_PLAN.md` DEC-PHASE0-003 (line 10354), and
the only live references are those scenario tests plus one comment in
`hooks/lib/hook-safety.sh:59`.

#### Slice 1 correction (2026-04-13) — HISTORICAL (pre-Slice-10/11)

> **Time-scoping note (Slice 12 closeout, 2026-04-14):** the numbered
> points below record installed truth **at Slice 1 inventory time**.
> Present-tense statements about tester wiring ("is wired", "still
> validates", "is NOT a safe Phase 8 target") were correct then and
> are now historical — the wiring was decommissioned in Slice 10, the
> dead runtime code was removed in Slice 11, and the Slice 11
> correction bundle cleaned the scenario/test surface. Category A is
> **closed as completed** — see the Phase 8 Closeout Status section
> below for current truth.

First revision of the inventory carried three installed-truth errors flagged
in Codex review (`1776127576872-0034-cb6tuc`). Corrected in place:

1. **[At Slice 1 time] Category A (tester routing compat) was NOT a
   safe Phase 8 target.** `settings.json:296-319` wired `SubagentStop`
   matcher `tester` to `check-tester.sh`, whose line 144 called
   `rt_completion_submit ... "tester" "$_CT_PAYLOAD"`.
   `ROLE_SCHEMAS["tester"]` validated that payload. Reclassified as a
   Phase 8 follow-on removal bundle target (must land together with
   `check-tester.sh` unwiring + `settings.json` matcher removal +
   `subagent-start.sh` tester branch removal + `agents/tester.md`
   retirement). (Slice 9 corrected an earlier "Phase 9" label and a
   `pre-agent.sh` path error — see Slice 9 section below.)
   **(Status today: all listed removals landed in Slices 10 + 11 +
   correction; Category A closed.)**
2. **`runtime/core/proof.py` is NOT orphaned.** Correct grep shows
   `runtime/cli.py:52` imports it plus 4 tests (`test_statusline.py`,
   `test_statusline_truth.py`, `test_sidecars.py`, `test_proof.py`). Earlier
   grep was too narrow. Not a first-target.
3. **`hooks/log.sh` is NOT orphaned.** Shared logging library sourced by 14
   hooks (`notify.sh`, `plan-validate.sh`, `pre-bash.sh`, `pre-write.sh`,
   `prompt-submit.sh`, `compact-preserve.sh`, `lint.sh`, `auto-review.sh`,
   `track.sh`, `check-tester.sh`, `post-task.sh`, `session-end.sh`,
   `plan-guard.sh`, `subagent-start.sh`). Keep.

The revised recommendation (`auto-review.sh` + 3 scenario tests) replaces
the withdrawn Category A recommendation. See
`ClauDEX/PHASE8_DELETION_INVENTORY.md` "Correction Notice" and revised
"Recommended First Deletion Slice" sections for the full evidence.

### Phase 8 Slice 2 — auto-review.sh decommission

Scope: delete the orphaned `auto-review.sh` bundle identified in Phase 8
Slice 1's corrected recommendation. No live behaviour change — the hook was
not wired in `settings.json` and had no non-test callers.

**Deletions (4 files):**
- `hooks/auto-review.sh`
- `tests/scenarios/test-auto-review.sh`
- `tests/scenarios/test-auto-review-heredoc.sh`
- `tests/scenarios/test-auto-review-quoted-pipes.sh`

**Edits:**
- `hooks/lib/hook-safety.sh:58-59` — stripped the `auto-review.sh`-specific
  example from the `_obs_accum` guard comment. The comment now reads as a
  general statement about callers that don't source `context-lib.sh`.

**Tests added:**
- `tests/runtime/test_phase8_deletions.py` — 7 parametrised pins:
  4 file-absence pins + 3 no-reference pins over `settings.json`,
  `hooks/HOOKS.md`, `hooks/lib/hook-safety.sh`. Narrow by design — not a
  generic deletion framework.

**Not touched (per instruction):**
- `settings.json` (read-only; no `auto-review` reference to remove).
- `hooks/log.sh` (live shared library, sourced by 14 hooks).
- Tester routing/hook surfaces (Phase 8 follow-on removal bundle;
  plan captured in Slice 9).
- Bridge/watchdog files.
- `MASTER_PLAN.md` historical references.

**Evidence:**
- `test -e hooks/auto-review.sh` → all 4 target files report "gone".
- `grep -c auto-review` on `settings.json`, `hooks/HOOKS.md`,
  `hooks/lib/hook-safety.sh` → 0 hits each.
- `python3 -m runtime.cli constitution validate` →
  `{"concrete_count": 24, "planned_count": 0, "healthy": true,
  "status": "ok"}`.
- `python3 -m pytest tests/runtime/test_phase8_deletions.py -v` →
  **7 passed in 0.03s**.

Category status as of 2026-04-13: Category B (`auto-review.sh`) closed in
Slice 2. Category D (block-worktree manifest status) resolved in Slice 3.
Category E closed across Slices 4-7 (Slice 4 deleted two unreferenced
handoffs, Slice 5 retired the PHASE0 donor doc, Slice 6 retired the
INIT-CONV handoff after MASTER_PLAN preservation audit, Slice 7 reclassified
`implementation_plan.md` as retained constitution-level per four
independent installed-truth surfaces). Category A (tester-era routing authority) scope manifest produced in
Slice 9; execution lands as a Phase 8 follow-on bundle (CUTOVER_PLAN.md
§Phase 8 explicitly scopes tester-era removal — there is no Phase 9 in
the cutover plan). Category C (`proof.py`, `dispatch.py`) audit closed
in Slice 8:
classified as retained/deferred legacy storage + CLI compat surfaces;
not a Phase 8 deletion target. See Slice 8 section below for importer
evidence and future retirement bundle scope (post-Phase-8 cleanup).

### Phase 8 Slice 3 — block-worktree-create.sh wiring-status resolution

Scope: collapse the `ok_with_deprecated` ambiguity into one clear authority
state per MASTER_PLAN DEC-PHASE0-001 and DEC-PHASE0-002. The earlier
"HOOKS.md drift" narrative was wrong — `hook doc-check` already reported
`exact_match=true`. The real ambiguity was in `runtime/core/hook_manifest.py`
which flagged both block-worktree entries as deprecated.

**Outcome — split resolution:**
- `WorktreeCreate` → `hooks/block-worktree-create.sh`: **un-deprecated to
  ACTIVE.** DEC-PHASE0-001 verified `WorktreeCreate` as a documented
  Claude Code event; DEC-GUARD-WT-009 makes this the fail-closed safety
  adapter forcing all worktree creation through Guardian.
- `PreToolUse:EnterWorktree` → `hooks/block-worktree-create.sh`:
  **removed** from both `settings.json` and `runtime/core/hook_manifest.py`.
  DEC-PHASE0-002: `EnterWorktree` is not a documented Claude Code
  event/matcher (0 events in JSONL capture), so the wiring was
  unreachable.

**Changed files:**
- `runtime/core/hook_manifest.py` — WorktreeCreate entry: `STATUS_DEPRECATED`
  → `STATUS_ACTIVE` with new DEC-GUARD-WT-009/DEC-PHASE0-001 rationale;
  PreToolUse:EnterWorktree entry removed; module + KNOWN_HOOK_EVENTS
  docstrings updated to drop "speculative" language.
- `settings.json` — `PreToolUse:EnterWorktree` block (10 lines) removed.
  `WorktreeCreate` block unchanged.
- `hooks/HOOKS.md` — regenerated from the updated manifest via
  `runtime.core.hook_doc_projection.render_hook_doc()`. `[DEPRECATED]`
  markers gone; EnterWorktree section gone; WorktreeCreate section now
  shows it as active.
- `tests/runtime/test_hook_manifest.py` — entry-count pins 33→32,
  deprecated-count 2→0, active-count 31→32; `TestDeprecationPolicy`
  replaced by `TestActiveOnlyPolicy` (pins single active block-worktree
  entry, forbids EnterWorktree reappearance); adapter_paths expectations
  updated.
- `tests/runtime/test_hook_validate_settings.py` — real-settings tests
  expect `VALIDATION_STATUS_OK` instead of `OK_WITH_DEPRECATED`;
  deprecated-surfacing test now uses a monkey-patched synthetic
  deprecated entry so the surfacing contract is still pinned without
  depending on live wiring.

**Evidence:**
- `python3 runtime/cli.py hook doc-check` → exit 0, `status=ok`,
  `exact_match=true`, `expected_line_count=candidate_line_count=104`.
- `python3 runtime/cli.py hook validate-settings` → exit 0, `status=ok`
  (not `ok_with_deprecated`), `deprecated_still_wired=[]`,
  `settings_repo_entry_count=manifest_wired_entry_count=32`.
- `python3 runtime/cli.py constitution validate` → healthy,
  `concrete_count=24`, `planned_count=0`.
- `python3 -m pytest tests/runtime/test_hook_manifest.py
  tests/runtime/test_hook_validate_settings.py
  tests/runtime/test_hook_doc_check_cli.py
  tests/runtime/test_phase8_deletions.py` → **102 passed**.

**Not touched:** tester routing/hook surfaces; `auto-review.sh`
deletion pins; bridge/watchdog files; memory/reflow modules; donor docs.
`hooks/block-worktree-create.sh` itself (the shell file) is unchanged —
its own `@decision DEC-GUARD-WT-009 Status: accepted` already named it
the active authority.

### Phase 8 Slice 4 — Category E handoff-doc deletion audit

Scope: narrow Category E audit of three session-scoped handoff docs.
Delete only those with zero live inbound references; preserve any doc
still cited by live authority.

**Audit (`rg` against the three candidate names, excluding frozen
`ClauDEX/session-forensics/` archives):**

- `docs/AGENT_HANDOFFS.md` → only self-references at its own lines 68 and
  80 + inventory/CURRENT_STATE tracking rows. No inbound live reference
  from any runtime, hook, test, config, or top-level authority doc.
- `docs/HANDOFF_2026-03-31.md` → zero inbound references from any live
  surface outside frozen `ClauDEX/session-forensics/` archives.
- `docs/HANDOFF_2026-04-05_SYSTEM_EVAL.md` → cited at `MASTER_PLAN.md:2645`
  as the historical handoff record for the INIT-CONV initiative.
  **Retained at Slice 4**; subsequently retired in Phase 8 Slice 6 after
  preservation audit (see Slice 6 section below).

**Deletions (2 files):**
- `docs/AGENT_HANDOFFS.md`
- `docs/HANDOFF_2026-03-31.md`

**Test pins added to `tests/runtime/test_phase8_deletions.py`
(DEC-PHASE8-SLICE4-001):**
- `test_phase8_slice4_handoff_is_deleted` — 2 parametrized cases
  asserting the two deleted handoff files stay absent.
- `test_phase8_slice4_surface_has_no_deleted_handoff_reference` — 9
  parametrized cases asserting no live inbound reference to the deleted
  handoff basenames from `settings.json`, `MASTER_PLAN.md`, `CLAUDE.md`,
  `AGENTS.md`, `implementation_plan.md`, `docs/ARCHITECTURE.md`,
  `docs/DISPATCH.md`, `docs/PLAN_DISCIPLINE.md`, `hooks/HOOKS.md`.
  `ClauDEX/session-forensics/` is intentionally excluded as a frozen
  historical archive, not live authority.

Existing 7 Slice-2 auto-review pins are retained and still green.

**Evidence:**
- `rg -l -e 'AGENT_HANDOFFS' -e 'HANDOFF_2026-03-31' settings.json
  MASTER_PLAN.md CLAUDE.md AGENTS.md implementation_plan.md
  docs/ARCHITECTURE.md docs/DISPATCH.md docs/PLAN_DISCIPLINE.md
  hooks/HOOKS.md` → 0 matches (no output).
- `python3 -m pytest tests/runtime/test_phase8_deletions.py -v` →
  **18 passed** (7 Slice-2 + 11 Slice-4).
- `python3 runtime/cli.py constitution validate` →
  `{"concrete_count": 24, "planned_count": 0, "healthy": true,
  "status": "ok"}`.

**Not touched:** `docs/HANDOFF_2026-04-05_SYSTEM_EVAL.md` (retained
because `MASTER_PLAN.md:2645` still cites it);
`docs/PHASE0_HOOK_AUTHORITY_RECOMMENDATIONS.md` (left for Slice 5 and
deleted there); `implementation_plan.md`; live specs
(`docs/ARCHITECTURE.md`, `docs/DISPATCH.md`, `docs/PLAN_DISCIPLINE.md`);
`MASTER_PLAN.md`; any runtime, hook, settings, manifest, prompt-pack,
or bridge code.

### Phase 8 Slice 5 — PHASE0 donor-doc retirement

Scope: retire `docs/PHASE0_HOOK_AUTHORITY_RECOMMENDATIONS.md` only after
preservation audit proves its decisions + 11-item HOOKS.md delta are
already canonically held in `MASTER_PLAN.md` INIT-PHASE0.

**Preservation audit (donor section → MASTER_PLAN location):**

| Donor section | MASTER_PLAN.md preservation |
|---|---|
| Intro: "MASTER_PLAN.md INIT-PHASE0 is canonical" | Donor doc self-declared non-normative |
| Rec 1 (auto-review decommission, 4-point rationale) | DEC-PHASE0-003 @ L10354 + P0-C work item |
| Rec 2a (WorktreeCreate KEEP) | DEC-PHASE0-001 @ L10310 |
| Rec 2b (EnterWorktree REMOVE) | DEC-PHASE0-002 @ L10331 |
| Rec 3 (HOOKS.md reduce-scope + rejected branches) | P0-H narrative @ L10421 |
| 11-item HOOKS.md ↔ official-docs delta | Full table @ L10512-10530, identical rows |
| Memory cross-refs | Home MEMORY.md index entries still exist |
| c7a3109 + dispatch-debug.jsonl cross-refs | git log + live repo files still authoritative |

**Audit PASSED.** Donor doc was a convenience copy of canonical INIT-PHASE0.

**Deletion:** `docs/PHASE0_HOOK_AUTHORITY_RECOMMENDATIONS.md`.

**Test pins added to `tests/runtime/test_phase8_deletions.py`
(DEC-PHASE8-SLICE5-001):**
- `test_phase8_slice5_phase0_doc_is_deleted` — asserts the donor doc
  stays absent.
- `test_phase8_slice5_surface_has_no_phase0_doc_reference` — 9
  parametrized cases asserting no live-authority surface names
  `PHASE0_HOOK_AUTHORITY_RECOMMENDATIONS.md` (`settings.json`,
  `MASTER_PLAN.md`, `CLAUDE.md`, `AGENTS.md`, `implementation_plan.md`,
  `docs/ARCHITECTURE.md`, `docs/DISPATCH.md`, `docs/PLAN_DISCIPLINE.md`,
  `hooks/HOOKS.md`). Phase 8 tracking docs under `ClauDEX/` are
  intentionally excluded so historical-context citations remain
  permitted there.

**Live-surface reference updates in same bundle:**
- `ClauDEX/CUTOVER_PLAN.md:1497` — donor-surface line removed.
- `ClauDEX/PHASE8_DELETION_INVENTORY.md` — Category B evidence,
  Slice-2 rationale, Category E table, Slice-4 not-touched clause,
  and Inspected Surfaces donor-docs row all updated to cite
  `MASTER_PLAN.md` DEC-PHASE0-003 instead of the deleted doc.
- `tests/runtime/test_phase8_deletions.py:15` — Slice-2 docstring
  citation updated to `MASTER_PLAN.md` DEC-PHASE0-003.

**Evidence:**
- `rg -l PHASE0_HOOK_AUTHORITY_RECOMMENDATIONS settings.json
  MASTER_PLAN.md CLAUDE.md AGENTS.md implementation_plan.md
  docs/ARCHITECTURE.md docs/DISPATCH.md docs/PLAN_DISCIPLINE.md
  hooks/HOOKS.md` → 0 matches.
- `python3 -m pytest tests/runtime/test_phase8_deletions.py -v` →
  **28 passed** (7 Slice-2 + 11 Slice-4 + 10 Slice-5).
- `python3 runtime/cli.py constitution validate` →
  `{"concrete_count": 24, "planned_count": 0, "healthy": true,
  "status": "ok"}`.

**Not touched:** `MASTER_PLAN.md` (no changes required — all content
already preserved); `implementation_plan.md`; live specs; runtime,
hooks, settings, manifest, prompt-pack, bridge code.

### Phase 8 Slice 6 — INIT-CONV handoff-doc retirement

Scope: retire `docs/HANDOFF_2026-04-05_SYSTEM_EVAL.md` only after
preservation audit proves its North Star, 6 execution packets, and
retest set are already canonically held in `MASTER_PLAN.md` INIT-CONV.

**Preservation audit (handoff section → MASTER_PLAN location):**

| Handoff section | MASTER_PLAN.md preservation |
|---|---|
| North Star (6 canonical authorities) | INIT-CONV L2646-2649 (identical bullets) |
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
| Required Retest Set (6 commands) | L2682-2689 (identical) |
| Full convergence retest | L2693-2694 (identical) |
| Guidance For Claude Code | Sacred Practices + What Matters in CLAUDE.md |
| Bottom Line | Problem/North Star already state this |

**Audit PASSED.** INIT-CONV L2633 marks the initiative `complete (all 6
waves landed, 2026-04-05/06)`.

**Deletion:** `docs/HANDOFF_2026-04-05_SYSTEM_EVAL.md`.

**MASTER_PLAN.md edit (minimal, docs-only):**
- L2645 `**Handoff:** docs/HANDOFF_2026-04-05_SYSTEM_EVAL.md` →
  `**Handoff:** source handoff retired in Phase 8 Slice 6 (2026-04-13);
  conclusions, corrections, and the 6-packet priority order are
  preserved in this INIT-CONV section and W-CONV-1 through W-CONV-7
  below.`

**Test pins added to `tests/runtime/test_phase8_deletions.py`
(DEC-PHASE8-SLICE6-001):**
- `test_phase8_slice6_handoff_is_deleted` — asserts the retired handoff
  stays absent.
- `test_phase8_slice6_surface_has_no_handoff_reference` — 9 parametrized
  cases over the same live-authority surface set as Slice 4/5
  (`settings.json`, `MASTER_PLAN.md`, `CLAUDE.md`, `AGENTS.md`,
  `implementation_plan.md`, `docs/ARCHITECTURE.md`, `docs/DISPATCH.md`,
  `docs/PLAN_DISCIPLINE.md`, `hooks/HOOKS.md`). The `MASTER_PLAN.md` pin
  guards against the dead link reappearing. `ClauDEX/` tracking docs
  excluded so historical-context citations remain permitted.

**Slice 4 docstring cleanup:** `test_phase8_deletions.py` module
docstring updated — the "intentionally kept" wording for this handoff
was replaced with a note that Slice 6 retired it after preservation
audit.

**Evidence:**
- `rg -l HANDOFF_2026-04-05_SYSTEM_EVAL settings.json MASTER_PLAN.md
  CLAUDE.md AGENTS.md implementation_plan.md docs/ARCHITECTURE.md
  docs/DISPATCH.md docs/PLAN_DISCIPLINE.md hooks/HOOKS.md` → 0 matches.
- `python3 -m pytest tests/runtime/test_phase8_deletions.py -v` →
  **38 passed** (7 Slice-2 + 11 Slice-4 + 10 Slice-5 + 10 Slice-6).
- `python3 runtime/cli.py constitution validate` →
  `{"concrete_count": 24, "planned_count": 0, "healthy": true,
  "status": "ok"}`.

**Not touched:** `implementation_plan.md`; live specs; runtime, hooks,
settings, manifest, prompt-pack, bridge code.

### Phase 8 Slice 7 — Category E closure / reclassification

Scope: docs-only classification cleanup. No file deletions, no runtime or
hook changes. Closes Category E by pinning the correct classification of
`implementation_plan.md` and removing stale "next Phase 8 candidate"
language that still pointed at it.

**Premise correction.** Slice 1's Category E table entry for
`implementation_plan.md` read "Overlaps with `MASTER_PLAN.md`. Merge or
retire." That framing was wrong on installed truth. The installed
authorities treat it as a constitution-level successor implementation
spec, not a donor doc awaiting merge:

| Installed-truth surface | Evidence |
|---|---|
| `AGENTS.md:34` | "Treat `implementation_plan.md` as the successor implementation spec." |
| `runtime/core/constitution_registry.py:227-229` | `name="implementation_plan.md"`, `path="implementation_plan.md"` — concrete (not planned) registry entry. |
| `tests/runtime/test_constitution_registry.py:73,139` | Two assertions list `implementation_plan.md` in the concrete constitution surface set. |
| `ClauDEX/CUTOVER_PLAN.md:1465` | Listed under "Constitution-Level Files" with the rule that changes require explicit architecture-scoped plan coverage, decision annotation, and invariant test updates. |

**Outcome:**
- `ClauDEX/PHASE8_DELETION_INVENTORY.md` Category E row for
  `implementation_plan.md` reclassified to **Retained — not a Phase 8
  deletion target**, citing the four installed-truth surfaces above.
- A "Phase 8 Slice 7 — Category E Closure / Reclassification" section
  appended to the inventory recording the closure.
- Stale "Next Phase 8 candidate" wording that pointed at the
  `implementation_plan.md` ↔ `MASTER_PLAN.md` overlap is removed. The
  earlier Slice 2 "next candidate" paragraph is rewritten as a Category
  status summary (B/D/E closed, A deferred to a Phase 8 follow-on
  removal bundle, C deferred on CLI audit).
- Header bumped to reflect Slice 7 completion.

**Not touched:**
- `implementation_plan.md` itself — preserved as-is per four independent
  installed-truth surfaces.
- `MASTER_PLAN.md` — no handoff link or Category E wording to repair.
- `ClauDEX/CUTOVER_PLAN.md` — line 1465 correctly classifies
  `implementation_plan.md` as constitution-level and must not be
  weakened; line 1495 lists it under "Donor Surfaces and Historical
  Inputs" with the softer framing "may be harvested, but the restart is
  grounded here" — this does not directly imply Phase 8 merge/retire,
  so per Codex instruction it is left alone.
- Runtime, hooks, settings, manifest, prompt-pack, bridge code.
- `tests/runtime/test_phase8_deletions.py` — no new pins. Slice 7 is
  reclassification, not deletion; there is nothing new absent to pin.

**Evidence:**
- `rg "Merge or retire" ClauDEX/PHASE8_DELETION_INVENTORY.md` → 0
  matches (the old Category E row wording is gone).
- `rg "Next Phase 8 candidate" ClauDEX/CURRENT_STATE.md` → 0 matches
  (both stale blocks removed/rewritten).
- `python3 runtime/cli.py constitution validate` →
  `{"concrete_count": 24, "planned_count": 0, "healthy": true,
  "status": "ok"}`.

### Phase 8 Slice 8 — Category C installed-truth audit (no deletion)

Scope: docs-only audit of the two Category C surfaces Slice 1 had flagged
as "deferred pending CLI import audit": `runtime/core/proof.py` +
`proof_state` table, and `runtime/core/dispatch.py` + `dispatch_queue` /
`dispatch_cycles` tables. Importer/read/write evidence gathered from
installed truth, excluding `ClauDEX/session-forensics/`, JSONL logs, and
tracking docs. No runtime, hook, settings, manifest, prompt-pack, bridge,
schema, or test code changed.

**Key installed-truth findings:**

`proof.py` / `proof_state` — retained:
- `runtime/cli.py:52` imports `proof_mod`; `runtime/cli.py:157-179`
  exposes `proof get/set/list` as live user-invokable CLI commands.
- `runtime/schemas.py:24` defines `proof_state` in the canonical schema.
- `sidecars/observatory/observe.py:117-118` selects `proof_state` rows
  in the observatory read-only pass.
- `runtime/core/statusline.py:33,126` and `runtime/core/evaluation.py:8,17`
  explicitly say the storage is retained with zero enforcement/display
  effect (intentional legacy storage — not a bug to clean up in Phase 8).
- Hook comments at `hooks/check-guardian.sh:232`, `hooks/session-init.sh:114`,
  `hooks/subagent-start.sh:279` already mark `proof_state` as superseded
  by `evaluation_state` but perform no writes.

`dispatch.py` / `dispatch_queue` + `dispatch_cycles` — retained:
- `runtime/cli.py:35` imports `dispatch_mod`; `runtime/cli.py:1537-1572`
  exposes `dispatch enqueue/next/start/complete/cycle-start/cycle-current`
  as live manual-orchestration CLI commands.
- `runtime/schemas.py:64,76` defines both tables in the canonical schema.
- DEC-WS6-001 (`runtime/core/statusline.py:38-47`) pulled `dispatch_queue`
  out of the routing hot-path but kept the legacy-compat surface.
  `post-task.sh` no longer enqueues.
- **`dispatch_cycles` is more live than `dispatch_queue`** —
  `runtime/core/statusline.py:243` still reads `dispatch_cycles` for
  `dispatch_cycle_id` (initiative-level tracking, intentionally retained
  per DEC-WS6-001).
- `sidecars/observatory/observe.py:131` still selects pending
  `dispatch_queue` rows in the observatory pass.

**Classification outcome:** both surfaces are **retained — not Phase 8
deletion targets.** Neither is mechanically isolated enough for a
bounded Phase 8 slice. Retirement would require a coordinated future
retirement bundle (post-Phase-8 cleanup): CLI command retirement +
schema migration + observatory read
removal + statusline/evaluation/sidecar test rewrites (for
`proof_state`), or the above plus a completion-records-based replacement
for `statusline.py:243`'s `dispatch_cycle_id` lookup (for the dispatch
tables).

**Doc updates in this bundle:**
- `ClauDEX/PHASE8_DELETION_INVENTORY.md` — Category C table rewritten to
  list specific blockers instead of "needs importer survey"; Category C
  header changed from "Duplicate / Orphaned Runtime Authorities" to
  "Retained Legacy Storage / Compat Surfaces (Phase 8 Slice 8 audit)";
  future retirement bundle scope (post-Phase-8 cleanup) added; new
  "Phase 8 Slice 8 —
  Category C Installed-Truth Audit" section appended with the full
  importer evidence matrix.
- `ClauDEX/CURRENT_STATE.md` — header bumped to slices 1-8; Slice-2
  category-status summary updated so Category C no longer reads
  "deferred pending CLI import audit"; this Slice 8 section appended.

**Not touched:**
- Runtime modules (`proof.py`, `dispatch.py`, `statusline.py`,
  `evaluation.py`, `schemas.py`, `cli.py`).
- Hooks, settings, manifest, prompt-pack, bridge.
- Tests (`test_proof.py`, `test_dispatch.py`, `test_statusline.py`,
  `test_statusline_truth.py`, `test_sidecars.py`). They continue to
  observe the retained storage/compat surfaces; Slice 8 is audit-only.
- `MASTER_PLAN.md` and `implementation_plan.md`.
- Category A (tester) surfaces — Phase 8 follow-on removal bundle
  scope.

**Evidence:**
- Importer/read/write matrix captured verbatim in
  `ClauDEX/PHASE8_DELETION_INVENTORY.md` "Phase 8 Slice 8" section
  (non-tracking surfaces only, per audit rule).
- `python3 runtime/cli.py constitution validate` →
  `{"concrete_count": 24, "planned_count": 0, "healthy": true,
  "status": "ok"}`.

### Phase 8 Slice 9 — tester-era removal scope manifest (plan only)

Scope: docs-only. No runtime/hook/settings/test/agent code changed.
Produces the scope manifest and bundle plan for Category A
(tester-era routing authority) removal — the last outstanding Phase 8
category per `ClauDEX/CUTOVER_PLAN.md:1418` ("remove tester-era
routing authority").

**Wording correction.** Earlier Slices (1-8) labelled tester removal
"Phase 9." `ClauDEX/CUTOVER_PLAN.md` has no Phase 9 — Phase 8 is the
final cutover phase and its scope explicitly includes tester removal.
Slice 9 renames these references to "Phase 8 follow-on removal bundle"
and updates all "Phase 9" wording in `PHASE8_DELETION_INVENTORY.md` to
match. References retained as local follow-on-bucket shorthand only.

**Installed-truth tester path (evidence):**

Audit command:
```
rg -n --glob '!ClauDEX/session-forensics/**' --glob '!**/*.jsonl' \
    --glob '!**/*.log' -w 'tester'
```

Live chain, producer → consumer:
1. `settings.json:287` — `SubagentStop` matcher `"tester"` wiring
   `notify.sh`, `check-tester.sh`, `post-task.sh`.
2. `hooks/check-tester.sh:144` — `rt_completion_submit(..., "tester", ...)`.
3. `runtime/core/completions.py:70-74` — `ROLE_SCHEMAS["tester"]`
   validates the payload.
4. `runtime/cli.py:1574-` — `dispatch process-stop` `{"agent_type":"tester"}`.
5. `runtime/core/dispatch_engine.py:318-324` — tester branch releases
   lease, returns `next_role=None`.
6. `runtime/core/dispatch_engine.py:169` — `_known_types` includes
   `"tester"`.
7. `runtime/core/dispatch_shadow.py:81,129-132,177-180,189-191` —
   tester→reviewer collapse + `tester/ready_for_guardian → GUARDIAN_LAND`.
8. `runtime/core/hook_manifest.py:409-423` — two `SubagentStop:tester`
   entries, both `STATUS_ACTIVE`.
9. `hooks/HOOKS.md:73-76` — derived doc surface.
10. `hooks/subagent-start.sh:60,277-292` — tester role allowlist +
    context-inject branch.
11. `agents/tester.md` — tester agent prompt.
12. Scenario tests: `test-routing-tester-completion.sh`,
    `test-check-tester-valid-trailer.sh`,
    `test-check-tester-invalid-trailer.sh`,
    `test-completion-tester.sh`, `test-agent-spawn.sh`.

**Installed-truth correction (Slice 1 bug caught in Slice 9):** Slice 1
cited `hooks/pre-agent.sh:277-292` as a tester dispatch block.
`hooks/pre-agent.sh` is only 109 lines and has zero tester references.
The tester context-inject branch lives in `hooks/subagent-start.sh`.
Prerequisite lists corrected across `PHASE8_DELETION_INVENTORY.md`.

**Bundle split recommendation: two bundles.**

- **Bundle 1 — Wiring decommission.** Removes all live producers:
  `settings.json` tester matcher block, `hook_manifest.py` tester
  entries, `check-tester.sh`, `subagent-start.sh` tester branch,
  `agents/tester.md`, plus the 4 tester-specific scenario tests and
  their hook-manifest/validate-settings/subagent-start pins. Post-
  bundle: no live producer writes `"tester"` completion records;
  `ROLE_SCHEMAS["tester"]` + `dispatch_engine` tester branch +
  shadow mappings become dead code (unreachable, not a parallel
  authority).
- **Bundle 2 — Dead-code cleanup + invariant flip.** Deletes
  `ROLE_SCHEMAS["tester"]`, the dispatch_engine tester branch + its
  `_known_types` entry, all shadow tester mappings, the leases role
  row, the schema cleanup allowlist entry, the eval-harness `actor_role`
  default rename, CLI help-string cleanup, and comment sweeps across
  runtime + hooks. Flips invariant tests from "tester compat accepted/
  neutralized" → "tester is not a known/routed role."

A single bundle is physically possible but touches ~20 test files,
settings, manifest, 6+ runtime modules, and the full eval fixture suite
— too broad to land cleanly without rework risk. The two-bundle split
keeps the intermediate state safe: Bundle 1 has zero live producers;
Bundle 2 removes unreachable dead code. This is not a parallel
authority since dead code without reachable callers is not authority.

**Invariant tests that flip** (full list in Slice 9 inventory section
§4): `test_completions.py`, `test_dispatch_engine.py`,
`test_dispatch_shadow.py`, `test_shadow_parity.py`,
`test_hook_manifest.py` (active-count pin 32→30),
`test_subagent_start_hook.py`, `test_leases.py`, `test_stage_registry.py`,
`policies/test_write_who.py`, `policies/test_write_plan_guard.py`,
`policies/test_capability_gate_invariants.py`, `test_eval_runner.py`.

**Docs and prompts changed** (full list in §5 of the Slice 9 inventory
section):
- **Delete:** `agents/tester.md`, `hooks/check-tester.sh`,
  4 tester-specific scenario tests.
- **Regenerate:** `hooks/HOOKS.md` (from manifest projection).
- **Flow-narrative updates:** `CLAUDE.md`, `MASTER_PLAN.md`,
  `implementation_plan.md`, `docs/DISPATCH.md`, `docs/ARCHITECTURE.md`,
  `docs/PLAN_DISCIPLINE.md`, `docs/SYSTEM_MENTAL_MODEL.md`,
  `docs/PROMPTS.md`, `agents/implementer.md`, `agents/guardian.md`,
  `agents/reviewer.md`, `skills/signal-trace/SKILL.md`,
  `ClauDEX/SUPERVISOR_HANDOFF.md`, `scripts/statusline.sh`,
  `scripts/eval_judgment.py`. Constitution-level edits are minimal —
  only lines currently stating tester as the live eval role.
- **Comment sweeps:** ~10 hook files + runtime comment lines in
  `dispatch_engine.py`, `markers.py`, `lifecycle.py`, `traces.py`,
  `policy_engine.py`, `stage_registry.py`, `evaluation.py`,
  `quick_eval.py`, `eval_scorer.py`.

**Eval-harness semantic decision noted:** `runtime/core/eval_runner.py`
uses `actor_role="tester"` as the scenario default. Recommendation
(deferred to execution slice): rename to `"reviewer"` for consistency,
batched with eval fixture rename to avoid two churns.

**Verification set for execution bundles** (captured verbatim in the
Slice 9 inventory section §6):
- Bundle 1: `hook validate-settings` → `status=ok` with no tester
  matchers; `hook doc-check` → `exact_match=true` post-regen;
  `hook manifest-summary active_count=30`; wiring-side `rg` → 0 tester
  matches; scoped runtime-tests pass.
- Bundle 2: `constitution validate` → healthy; full `pytest
  tests/runtime/` green with new invariant pins; full `rg` across
  runtime/hooks/agents/tests/scripts/docs → 0 tester matches outside
  historical decision logs; new `test_phase8_deletions.py` pins for
  `ROLE_SCHEMAS`/`_known_types`/`KNOWN_LIVE_ROLES`.

**Not touched in Slice 9:**
- `settings.json`, `runtime/core/*`, `hooks/*`, `agents/*`,
  `tests/*`, `scripts/*`, `docs/*`, prompt packs, bridge, schemas.
- Category C/E closures (Slices 5-8) stand as is.
- `MASTER_PLAN.md` and `implementation_plan.md`.

Slice 9 is plan-only. Execution bundles are the next Phase 8 follow-on
slices; slice numbers assigned when execution begins.

**Evidence in this slice:**
- Audit command captured above; results cross-referenced to
  `PHASE8_DELETION_INVENTORY.md` Slice 9 section.
- `python3 runtime/cli.py constitution validate` →
  `{"concrete_count": 24, "planned_count": 0, "healthy": true,
  "status": "ok"}`.
- `rg "Phase 9"` across `ClauDEX/PHASE8_DELETION_INVENTORY.md` and
  `ClauDEX/CURRENT_STATE.md` now returns only lines that explicitly
  record the "Phase 9 → Phase 8 follow-on" wording correction; no
  lingering active "Phase 9" classification remains.

## Phase 8 Slice 10 — Tester Bundle 1 wiring decommission (2026-04-13)

**Status:** executed; first code-edit slice in Phase 8.

**Scope (executed):** every live producer path that could create or
dispatch a `tester` SubagentStop/completion has been removed.
Dead runtime code (`ROLE_SCHEMAS["tester"]`, `dispatch_engine` tester
branch, `dispatch_shadow` tester mappings, leases/schemas/eval harness)
is deferred to Bundle 2.

**What moved:**

- Deleted: `hooks/check-tester.sh`, `agents/tester.md`, four
  tester-specific scenario tests.
- `settings.json` SubagentStop tester matcher block removed — live
  matchers: `planner|Plan`, `implementer`, `guardian`, `reviewer`.
- `runtime/core/hook_manifest.py` — two tester entries removed;
  manifest count 32 → 30.
- `hooks/subagent-start.sh` — tester removed from dispatch-role
  allowlist; tester CONTEXT_PARTS branch deleted; stale references
  to Tester in implementer/guardian wording re-pointed at Reviewer.
- `hooks/HOOKS.md` regenerated (generator hash matches).
- Live-authority doc surfaces cleaned: `CLAUDE.md`, `docs/PROMPTS.md`,
  `agents/implementer.md`, `agents/guardian.md`, `agents/reviewer.md`.
- Tests updated: hook-manifest + validate-settings counts (30, 30),
  agent-spawn scenario uses reviewer, phase8 deletions pins added
  (Slice 10 = 9 new assertions).

**Verification:**

- `hook validate-settings` → `status=ok, entries=30/30`.
- `hook doc-check` → `exact_match=true`.
- `constitution validate` → `healthy=true, concrete_count=24`.
- `pytest test_hook_manifest test_hook_validate_settings
  test_subagent_start_hook test_phase8_deletions` → 179 passed.
- `bash test-agent-spawn.sh` → PASS.

**What's left for Bundle 2:**

- Runtime dead-code cleanup: `ROLE_SCHEMAS["tester"]`,
  `dispatch_engine` branch, `dispatch_shadow` mappings, leases, schemas,
  `eval_runner` tester paths, `agents/shared-protocols.md` Evaluator
  Trailer section, CLI help text, narrative references in
  `MASTER_PLAN.md` / `implementation_plan.md`.
- Invariant flip: once dead code is gone, the narrow "no tester
  matcher / no check-tester.sh" pins in Slice 10 can be tightened to a
  repo-wide "no raw `tester` role string" invariant.

After Bundle 1 there are zero live tester producers. Bundle 2 removes
unreachable dead code; there is no parallel authority.

### Slice 10 correction (0047-fodn2m, 2026-04-13)

Codex review of the initial Slice 10 landing flagged two follow-ups:

1. Stale `check-tester.sh` references still lived in live hook comments
   and live docs (10+ sites). The correction re-pointed them all at the
   active SubagentStop evaluator adapter — `check-reviewer.sh` in the
   current chain — and removed the deleted basename from every live
   surface. Touched: `hooks/prompt-submit.sh`, `hooks/track.sh`,
   `hooks/check-reviewer.sh`, `hooks/check-guardian.sh`,
   `hooks/check-implementer.sh`, `hooks/post-task.sh`,
   `hooks/write-guard.sh`, `hooks/context-lib.sh`, `docs/DISPATCH.md`,
   `docs/SYSTEM_MENTAL_MODEL.md`,
   `tests/scenarios/capture/PAYLOAD_CONTRACT.md`.
2. Typo in the DEC-PHASE8-SLICE10-001 rationale in
   `tests/runtime/test_phase8_deletions.py` ("four deleted files" while
   listing six). Fixed.

The Slice 10 invariant pins were expanded in the same edit: the
no-`check-tester.sh` pin now covers the nine cleaned hooks and three
cleaned docs as well as `settings.json` + `hooks/HOOKS.md`. A sibling
`no-agents/tester.md` pin was added on the same surface set. Both pins
remain narrow — they do not forbid the bare role string `tester`, which
is still a Bundle 2 scope item because dead runtime code (ROLE_SCHEMAS,
dispatch_engine/shadow, leases/schemas/eval harness, the tester
sections of MASTER_PLAN.md / implementation_plan.md, and the
tester-aware test suites) still legitimately references it.

Post-correction verification: `pytest tests/runtime/test_phase8_deletions.py`
→ 71 passed; `hook validate-settings` healthy (30/30);
`hook doc-check` exact_match (hash unchanged — no manifest surface
touched); `constitution validate` healthy (24 concrete entries).

## Phase 8 Slice 11 — Tester Bundle 2 dead-code + invariant flip (2026-04-13)

Landed per Codex instruction 1776132844181-0048-ywlb7d. Slice 11 is the
second and final bundle of the tester retirement: after Slice 10
decommissioned every live producer, Slice 11 removes the dead runtime
code, flips the invariant pins, and mechanically forbids reintroduction.

After this slice, `tester` is no longer a known, validated, or routed
runtime role. The canonical live chain is
`planner → guardian(provision) → implementer → reviewer → guardian(merge)`.

Runtime changes (authority surfaces):
- `runtime/core/completions.py` — `ROLE_SCHEMAS` minus `tester`;
  `determine_next_role("tester", ...) → None` for all verdicts.
- `runtime/core/dispatch_engine.py` — `_known_types` minus `tester`;
  `process_agent_stop(agent_type="tester")` exits silently with zero
  shadow emission.
- `runtime/core/dispatch_shadow.py` — `KNOWN_LIVE_ROLES` minus
  `tester`; `compute_shadow_decision(live_role="tester")` →
  `reason=REASON_UNKNOWN_LIVE_ROLE`, `agreed=False`, shadow fields all
  `None`. Legacy `tester → reviewer` collapse and
  `tester(ready_for_guardian) → guardian:land` mapping both removed.
- `runtime/core/leases.py` — `ROLE_DEFAULTS` minus `tester`.
- `runtime/schemas.py` — `ensure_schema()` retained-role set is
  `{planner, implementer, reviewer, guardian}`; stale tester markers
  are deactivated on every `ensure_schema()` invocation
  (DEC-CONV-002 whitelist).

Invariant pins (DEC-PHASE8-SLICE11-001):
- `tests/runtime/test_phase8_deletions.py` — 7 new pins cover
  `ROLE_SCHEMAS`, `_known_types` (behavioural), `KNOWN_LIVE_ROLES`
  (+ `compute_shadow_decision`), `ROLE_DEFAULTS`, `ensure_schema`
  retained-role set (ghost-marker deactivation), `determine_next_role`
  (all verdicts), and `agents/tester.md` stays deleted.

Test-suite flips:
- `test_completions.py`, `test_dispatch_engine.py`,
  `test_dispatch_shadow.py`, `test_shadow_parity.py`, `test_leases.py`,
  `test_stage_registry.py`, `test_eval_runner.py` —
  tester assertions flipped to unknown-role/silent-exit.
- `test_lifecycle.py`, `test_hook_bridge.py`, `test_statusline.py`,
  `test_quick_eval.py` — tester → reviewer swap. `test_hook_bridge.py`
  tester-marker case flipped to assert `ensure_schema` deactivation.
- `tests/runtime/policies/test_hook_scenarios.py` —
  `write-guard-tester-deny` scenario removed.

Doc updates (live authority; historical retirement notes retained):
- `docs/DISPATCH.md` — canonical role flow now
  `planner → guardian(provision) → implementer → reviewer →
  guardian(merge)`; Slice 11 retirement note added.
- `docs/SYSTEM_MENTAL_MODEL.md` — dispatch graph references
  `next role: reviewer`; Reviewer section uses `REVIEW_*` trailers.
- `docs/ARCHITECTURE.md` — adapter list updated to
  `check-{planner,implementer,reviewer,guardian}.sh`.
- `docs/PLAN_DISCIPLINE.md` — plan-guard deny roles updated.

Verification (2026-04-13):
- `cc-policy constitution validate` →
  `{"concrete_count": 24, "healthy": true, "status": "ok"}`.
- `cc-policy hook validate-settings` →
  `{"status": "ok", "healthy": true, "settings_repo_entry_count": 30,
  "manifest_wired_entry_count": 30}`.
- `cc-policy hook doc-check` →
  `{"status": "ok", "exact_match": true,
  "expected_content_hash": "sha256:11a24375...851b1e9e"}` (unchanged).
- Targeted pytest (core modules + phase8 pins): **502 passed in 18.64s**.
- Targeted pytest (policies + lifecycle + adjacent): **541 passed in
  75.86s**.
- `rg '\btester\b'` over `agents/` and `settings.json` → zero hits.
  Remaining hits in `runtime/` and `hooks/` are comment-only historical
  retirement notes for Future Implementers.

After Slice 11, the unknown-role silent-exit, zero shadow emission,
and `ensure_schema` marker deactivation are load-bearing invariants —
reintroducing `tester` to any authority surface fails the pin suite.

### Slice 11 correction (Bundle 2 follow-up, 2026-04-13)

Landed per Codex correction instructions `1776135766401-0049-lojhjs`
and continuation `1776137878959-0050-hkoa80`. Codex review of the
initial Slice 11 landing (0048-ywlb7d) accepted the runtime/invariant
core but flagged two correction classes:

1. **Scenario / acceptance / test-surface reframes** — several
   scenario tests and adjacent runtime tests still carried
   `tester` role actors, markers, leases, lease-role, dispatch
   enqueue, trace role, evaluator fixtures, scorer docstrings,
   statusline marker data, and observability fixture roles. Several
   of these would now fail under `ensure_schema()` whitelist
   cleanup (e.g. `test-statusline-snapshot.sh` where a stored
   `tester` marker became null after the retained-role cleanup).
2. **Narrative pins on non-runtime surfaces** — a CLI-help pin
   (`test_phase8_slice11_cli_help_does_not_advertise_tester`), an
   executable-surface pin
   (`test_phase8_slice11_executable_test_has_no_live_tester_surface`),
   and a capture-payload-contract pin
   (`test_phase8_slice11_capture_payload_contract_has_no_live_tester_role`)
   were added to enforce that the live operator-visible surfaces
   (CLI help text, executable scenario scripts, `PAYLOAD_CONTRACT.md`)
   do not advertise `tester` as a live role.

Files reframed (scenario / acceptance re-points):
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

Focused-rg classification of remaining `tester` hits after the
correction lands:
- Dead-code retirement invariants in `runtime/core/{completions,
  dispatch_engine,dispatch_shadow,leases,evaluation,eval_runner,
  eval_scorer,stage_registry}.py` and `runtime/schemas.py` —
  comment-only historical retirement notes. **Legitimate.**
- Phase 8 deletion pin suite (`test_phase8_deletions.py`) — uses
  the literal string `tester` to assert its absence from live
  authority surfaces. **Required by the pin contract.**
- Reframed scenario/acceptance fixtures — all converted to
  `reviewer` or role-agnostic wording; retirement-context comments
  do not embed the deleted adapter basename `check-tester.sh`.
  **Cleaned.**
- `MASTER_PLAN.md` / `ClauDEX/**` historical decision logs —
  out of live-enforcement scope; intentionally preserved.

Verification (post-correction):
- `pytest tests/runtime/test_phase8_deletions.py` → **169 passed**
  (covers the full Slice 10 + Slice 11 pin suite + CLI-help pin +
  executable-surface pin + capture-doc pin).
- `pytest tests/runtime/` → **4124 passed** (3 pre-existing
  unrelated failures: `test_claudex_stop_supervisor.py::
  test_stop_hook_allows_stop_for_consumed_pending_review`,
  `test_claudex_watchdog.py::TestWatchdogSelfExecOnScriptDrift`,
  `test_subagent_start_payload_shape.py::TestPreToolAgentPayloadShape`
  — acknowledged by Codex as out-of-scope for Slice 11).
- `cc-policy constitution validate` → `healthy: true` (24 concrete).
- `cc-policy hook validate-settings` → `status=ok` (30/30 wired,
  no deprecated).
- `cc-policy hook doc-check` → `exact_match=true`, hash
  `sha256:11a24375...851b1e9e` (unchanged — no manifest surface
  touched by this correction).

## Phase 8 Closeout Status (2026-04-13)

With Slices 1-11 landed and the Slice 11 correction accepted, Phase 8
is materially complete under the exit criteria defined in
`ClauDEX/CUTOVER_PLAN.md:1423-1426`.

### Exit-criterion evidence table

| Exit criterion (CUTOVER_PLAN.md:1425-1426) | Installed-truth evidence |
|---|---|
| only one live authority remains for each operational fact in the authority map | Hook manifest: `cc-policy hook validate-settings` → `status=ok`, `settings_repo_entry_count=30`, `manifest_wired_entry_count=30`, `deprecated_still_wired=[]`, `invalid_adapter_files=[]`. Hook doc: `cc-policy hook doc-check` → `exact_match=true` (manifest-derived). Stage / completion / dispatch authorities: `_STAGE_TO_ROLE` in `completions.py` + `dispatch_engine._known_types` + `dispatch_shadow.KNOWN_LIVE_ROLES` + `leases.ROLE_DEFAULTS` + `ensure_schema` retained-role set are **all** the singular set `{planner, implementer, reviewer, guardian}`. Constitution registry: `cc-policy constitution validate` → `concrete_count=24`, `planned_count=0`, `healthy=true`. |
| no compatibility path is mistaken for an active control path | Tester retirement complete: `hooks/check-tester.sh` deleted, `agents/tester.md` deleted, `SubagentStop:tester` matcher removed from `settings.json` + `hook_manifest.py`; all 169 Phase 8 deletion pins green including the CLI-help, executable-surface, and `PAYLOAD_CONTRACT.md` surface pins. Category A closed as completed (§below). Category C retained-and-classified: `proof_state` and `dispatch_queue`/`dispatch_cycles` remain, but their retained status is installed-truth-verified with explicit `DEC-WS6-001` / evaluation.py comments marking them storage-only and non-authoritative; they are not mistaken for active control paths. Category B/D/E all closed by Slices 2/3/4/5/6/7/8. |

### Category disposition summary

| Category | Disposition | Closed in |
|---|---|---|
| A — Tester-era routing authority | **Completed.** Wiring decommissioned in Slice 10; dead runtime code + invariant flip in Slice 11; narrative / scenario / test surface corrected in the Slice 11 correction bundle. | Slice 10 + Slice 11 + Slice 11 correction |
| B — Orphaned hooks (`auto-review.sh`) | **Completed.** | Slice 2 |
| C — Retained legacy storage / compat (`proof_state`, `dispatch_queue`/`dispatch_cycles`) | **Retained — not a Phase 8 deletion target.** Audited, classified, and deferred; future retirement bundle scoped in inventory but explicitly not Phase 8 work. | Slice 8 (audit) |
| D — Hook wiring-status drift (`block-worktree-create.sh`) | **Resolved.** `WorktreeCreate` un-deprecated → ACTIVE; `PreToolUse:EnterWorktree` removed. | Slice 3 |
| E — Donor docs consolidation | **Completed** (deletions) + **Reclassified** for `implementation_plan.md` (retained as constitution-level). | Slices 4 / 5 / 6 / 7 |

### Outstanding Phase 8 candidates

None. All inventoried categories are either closed as completed
(A / B / D / E) or closed as audited-and-retained (C). The
`CUTOVER_PLAN.md` Phase 8 scope bullets are all discharged:

- "remove tester-era routing authority" — done (Slices 10 + 11 +
  correction).
- "remove obsolete hook docs and wiring" — done (Slices 2 + 3 +
  manifest-doc regeneration).
- "remove compatibility mirrors that outlived migration usefulness"
  — done where safe; Category C surfaces audited and retained
  because their retirement is out-of-scope (CLI surface change +
  schema migration + sidecar rewrites).
- "collapse remaining duplicate control surfaces" — done; the
  authority-map survey in `ClauDEX/PHASE8_DELETION_INVENTORY.md`
  lists no remaining duplicates.

### Blockers

None for Phase 8 closeout itself. The 3 pre-existing pytest
failures noted in the Slice 11 correction verification
(`test_claudex_stop_supervisor`, `test_claudex_watchdog`,
`test_subagent_start_payload_shape`) are independent of the tester
retirement chain and predate Slices 10/11 — they are tracked
separately.

## Do Not Lose

The important thing is not the current tmux layout. The important thing is the
local ClauDEX buildout:

- docs in `ClauDEX/`
- repo-local supervisor config in `.codex/`
- runtime work in `runtime/core/`
- tests in `tests/runtime/`

That is the actual cutover asset and should be checkpointed first when moving
to a clean branch.
