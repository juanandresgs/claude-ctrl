# ClauDEX Supervisor Handoff

## Current Lane Truth (2026-04-17)

- Branch `claudesox-local` at HEAD `747fb3a` (post-merge docs/config hardening tip), pushed to `origin/feat/claudex-cutover`. Lane is **0 ahead / 0 behind** — fully integrated.
- **Push debt cleared.** The 30-file cc-policy-who-remediation bundle (committed as `d7db4ba`), doc-reconciliation checkpoint (`696254a`), pre-merge supervisor infrastructure checkpoint (`49e71d5`, 12 files), and two merge commits (`959c3b2` integrating 41 upstream commits with 5 conflicts resolved, `995341e` integrating 1 additional upstream commit clean) are all pushed to `origin/feat/claudex-cutover`. Post-merge docs/config hardening tail also pushed: `ba1f9df` (post-merge docs coherence reconciliation), `09780f9` (stale Phase 2b active-slice claim qualified as historical), `49dd7fd` (stale checkpoint-debt claims qualified in invariant coverage matrix), `747fb3a` (bridge model authority moved from launcher to settings profile).
- **No checkpoint debt, no merge blockers, no push debt.** The lane is in steady-state maintenance mode.
- Historical: the pre-merge integration prep (7 merge-blocker files, non-destructive constraint, stash-pop contamination incident) is resolved. Those details are preserved in the Open Soak Issues section for audit.

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

## 2026-04-17 §2a closure snapshot

Post-Integration-Wave-1, the §2a supervision fabric has been closed on
`feat/claudex-cutover` by a continuous FF-only chain `018f2fa →
f37b8ab`. Custody HEAD immediately before the docs-only Category C
scoping packet was `f37b8ab`. No new phase was opened; every commit
is a post-Phase-8 continuation under the closed Phase 2b scope.

Installed truth the supervisor should rely on:

- **§2a model symmetry** — all four primitives have runtime-owned
  domain modules with state-machine enforcement, query surface, and
  CLI:
  - `runtime/core/agent_sessions.py` (`cc-policy agent-session
    {get, mark-completed, mark-dead, mark-orphaned, list-active}`),
    `a3653ad`, `DEC-AGENT-SESSION-DOMAIN-001`.
  - `runtime/core/seats.py` (`cc-policy seat {get, release,
    mark-dead, list-for-session, list-active}`), `e982d50`,
    `DEC-SEAT-DOMAIN-001`.
  - `runtime/core/supervision_threads.py` (`cc-policy supervision
    {attach, detach, abandon, abandon-for-seat, abandon-for-session,
    get, list-*}` — 11 actions), `f1e4fc6 → 5432e10`,
    `DEC-SUPERVISION-THREADS-DOMAIN-001`.
  - `runtime/core/dispatch_attempts.py` (unchanged; Bundle 2 full
    state machine + timeout sweep).

- **§2a Rule 1 mechanically enforced** —
  `tests/runtime/test_authority_table_writers.py` (`571c155`,
  `DEC-AUTHORITY-WRITERS-001`) fails the suite if any file outside
  the five-element allowlist (`runtime/core/agent_sessions.py`,
  `seats.py`, `supervision_threads.py`, `dispatch_attempts.py`,
  `runtime/schemas.py`) issues INSERT/UPDATE/DELETE against the
  four §2a tables. Green on baseline.

- **SubagentStop adapter wiring** — the four check hooks
  (`hooks/check-{implementer,reviewer,guardian,planner}.sh`) call
  `cc-policy dispatch seat-release` best-effort immediately after
  `lifecycle on-stop`. Source pin (`3967f6d`) + execution-level
  behavioral pin (`d733ee3`) in `tests/runtime/test_dispatch_hook.py`.

- **Dead-loop recovery is runtime-owned** — the watchdog tick
  (`scripts/claudex-watchdog.sh`) now calls `cc-policy dispatch
  sweep-dead` immediately after `attempt-expire-stale`. The sweeper
  (`runtime/core/dead_recovery.py`, `f3e88dd`,
  `DEC-DEAD-RECOVERY-001`) marks seats with past-grace terminal
  attempts dead, cascade-closes their supervision_threads, and
  transitions every-seat-terminal sessions to completed or dead.
  Pure delegation — no authority-writer allowlist extension.
  Default grace `DEFAULT_GRACE_SECONDS = 900` (module constant,
  overridable via `--grace-seconds`).  **Eligibility is keyed off
  the seat's most recent dispatch_attempt only** (deterministic
  `ORDER BY updated_at DESC, attempt_id DESC LIMIT 1`) per the
  `f37b8ab` selector re-correction, which **supersedes the
  `c400245` `created_at` ordering**.  The `c400245` fix closed the
  mixed-history over-sweep (old `timed_out` followed by a newer
  `cancelled` / `acknowledged` must not sweep); the `f37b8ab`
  re-correction additionally closes a retry under-sweep —
  `dispatch_attempts.retry()` reuses the same row, bumping
  `updated_at` / `status` / `retry_count` but leaving
  `created_at` fixed, so the `created_at` key under-swept when a
  retried attempt finished *after* a later-issued terminal
  attempt.  Under the current `updated_at` ordering both
  regressions hold: cancelled and retried cases both resolve to
  the correct seat-latest delivery-activity row.

- **Unchanged authority-surface invariants** — `cc-policy
  constitution validate` healthy=true concrete_count=24;
  `cc-policy hook validate-settings` healthy=true entry_count=30;
  `cc-policy hook doc-check` exact_match=true. All three numbers
  have held from `018f2fa` through `f3e88dd`; any drift in a future
  slice should be treated as a blocker.

Bridge transport (`scripts/claudex-*.sh` non-watchdog,
`hooks/claudex-*.sh`) remains containment; the single watchdog
one-liner is the only adapter change in this closure chain.

## Next bounded cutover slice

**Category C retirement scoping packet (planning-only,
2026-04-17).** Both Category C code surfaces are already retired
(`proof_state` at `f72e656`, `dispatch_queue`/`dispatch_cycles` at
`369cca6`, both under non-destructive posture). The remaining
deferred piece is the **inert rows** on pre-retirement databases
where neither retirement bundle issued `DROP TABLE`. An
execution-ready scoping packet has been produced at
`ClauDEX/CATEGORY_C_SCOPING_PACKET_2026-04-17.md` describing two
ordered sub-slices (proof_state first, dispatch_queue /
dispatch_cycles second), each guarded by explicit operator
approval per Sacred Practice #8, with required invariant gates
(`test_phase8_category_c_*`, `test_authority_table_writers`,
`constitution validate concrete_count=25`, `hook validate-settings
entry_count=31`, `hook doc-check exact_match=true`) and
escalation boundaries (destructive `DROP TABLE`, cross-database
impact, forensic data-loss risk). The packet is **planning-only**
— no `runtime/` / `hooks/` / `settings.json` / `schema` / bridge
/ watchdog edits are made by its landing, and no execution slice
may proceed without a separate authorizing instruction. This does
NOT reopen Phase 8 and does NOT create Phase 9. Grounded in
`CUTOVER_PLAN.md` (no Phase 9 defined) and annotated with reserved
decision `DEC-CATEGORY-C-FORENSIC-001` (status: planning).

## Open Soak Issues

### Checkpoint-report excluded-scope narration drift (2026-04-17) — RESOLVED (guardrail added)

- **Subject:** `guardian:land` checkpoint-retry report emitted for Codex instruction `1776423808293-0006-4eqliy` listed an `Excluded scope` cell enumerating ~25 modified / untracked paths (e.g., `M .codex/hooks/stop_supervisor.py`, `M scripts/claudex-*.sh`, `?? ClauDEX/CC_POLICY_SUPERVISION_RECOVERY_PLAN.md`, `M CLAUDE.md`, `M hooks/pre-agent.sh`, etc.) that were NOT present in live `git status --short` at report time.
- **Repro:** compare the emitted report's `Excluded scope` enumeration to `git status --short` at HEAD `f24df96`. Live state shows a single non-staged entry: `?? .claudex/`. Drift source: the session-start `gitStatus` block embedded in the environment prompt, narrated forward across slices as if it were live state.
- **Evidence:** Codex review instruction `1776423868647-0007-ugxr84` flagged the contradiction. Supervisor verification at the same HEAD confirmed only `?? .claudex/` outside the staged bundle.
- **Impact:** the report was materially truthful about the harness-block outcome (staged count, blocker text) but the excluded-scope cell was stale fiction. Future automation trusting such a report could believe the repo has substantial unstaged work it does not actually have, or conclude deferred items remain unsafely outside the bundle when they no longer exist in the worktree. This is a reporting-authority defect — excluded-scope narration drift — symmetric to the earlier included-scope drift.
- **Fix (applied this slice):** added `CHECKPOINT REPORT EXCLUDED-SCOPE AUTHORITY RULE` to `ClauDEX/CC_POLICY_WHO_REMEDIATION_EXECUTION_PROMPT.txt` requiring (1) excluded scope derived from live `git status --short`, (2) explicit staged-vs-unstaged/untracked distinction via first-column indicator, (3) explicit "none outside lane-local artifacts" wording when only `?? .claudex/` remains, and (4) prohibition of narration from session-start `gitStatus` snapshots or recalled lists. Mechanical pin: `tests/runtime/test_handoff_artifact_path_invariants.py::TestCheckpointReportExcludedScopeAuthority`.
- **Blocking?** No. The real staged index and runtime gates were unaffected. Resolved by the guardrail prose + mechanical pin this slice.
- **Verification state:** 4-token pin (`CHECKPOINT REPORT EXCLUDED-SCOPE AUTHORITY RULE`, `git status --short`, `distinguish staged entries`, `none outside lane-local artifacts`, `session-start status snapshot`) asserts the execution prompt surface carries the rule; pin-citation test asserts the rule names the mechanical class path; staged/unstaged distinction test asserts the rule body references both `??` and unstaged/untracked vocabulary.

### Checkpoint-report staged-scope narration drift (2026-04-17) — RESOLVED (guardrail added)

- **Subject:** `git commit` / `guardian:land` subagent report emitted by Codex instruction `1776422371697-0001-b39h0v` listed `Included scope` paths that were NOT in the live staged index.
- **Repro context:** the guardian subagent reported an "Included (28 paths)" list containing entries like `.codex/hooks/stop_supervisor.py`, `.codex/prompts/claudex_handoff.txt`, `CLAUDE.md`, `ClauDEX/OVERNIGHT_RUNBOOK.md`, `hooks/pre-agent.sh`, `hooks/subagent-start.sh`, `runtime/core/agent_prompt.py`, `runtime/core/authority_registry.py`, `runtime/core/decision_work_registry.py`, `runtime/core/eval_runner.py`, `runtime/core/policies/__init__.py`, `runtime/core/policies/agent_contract_required.py`, `runtime/core/workflows.py`, `runtime/schemas.py`, `scripts/claudex-sync-claude-agents.sh`, `tests/runtime/test_agent_contract_required_policy.py`, `tests/test_bridge_settings_bash_envelope.py`, `tests/test_bridge_settings_no_git_landing_denies.py`, `tests/test_claude_agents_projection.py`. None of those paths is in `git diff --cached --name-only` at HEAD `f24df96...`; the authoritative staged set is a different 28-path list (see the matching `## Current Restart Slice` composition and `cc-policy-who-remediation Slice 1 (2026-04-17)` staged-debt bullet above in this file). The orchestrator's wrap-up response detected the mismatch and over-reported the authoritative list alongside the subagent's hallucination; Codex review `1776422792879-0002-ibhq3l` independently confirmed the real staged count is 28 but did not itself enumerate the subagent's hallucinated entries.
- **Impact:** the report was materially truthful about the harness-block outcome (staged count, commit SHA, blocker text) but the scope-narration cells were unreliable. A future automation or operator who trusts such a report verbatim could mis-audit what's in-bundle or misbelieve a file has already been checkpointed. This is a reporting-authority defect — scope narration drift — even though the real git index was byte-identical to pre-dispatch.
- **Suggested fix (applied this slice):** the guardian-dispatch prompt authoring (in the execution-prompt surface and the supervisor handoff discipline) must require checkpoint reports to derive `Included scope` exclusively from `git diff --cached --name-only` at the time of the attempt. Reports must cite the exact `git diff --cached --name-only | wc -l` count and MUST NOT narrate paths from memory or from a prior turn's dispatch-context list. Any non-staged path in the `Included scope` section is treated as invalid. This discipline is pinned by a new mechanical invariant extension in `tests/runtime/test_handoff_artifact_path_invariants.py` (`TestCheckpointReportScopeAuthority`).
- **Blocking?** No. The real staged index and runtime gates were unaffected; only the narrative prose was unreliable. Resolved by adding the guardrail prose and the mechanical pin this slice.
- **Verification state:** mechanical pin asserts the execution prompt surface (`ClauDEX/CC_POLICY_WHO_REMEDIATION_EXECUTION_PROMPT.txt`) contains the explicit `git diff --cached --name-only` authority clause and count-requirement clause.

### Invariant #5 scanner defect — Rule A/B bypassed via `_KNOWN_EXEMPT_MODULES` (2026-04-17) — RESOLVED

- **Subject:** `tests/runtime/policies/test_command_intent_single_authority.py` (the Invariant #5 mechanical pin added this session).
- **Symptom:** the first landing of the scanner included `if path.name in _KNOWN_EXEMPT_MODULES: continue` at the top of both Rule A (no-shlex-import) and Rule B (no-split-on-raw-command) scan loops. This silently allowed any module in the allowlist (currently `bash_tmp_safety.py`, exempted only for Rule C literal-substring-pattern use) to also bypass the two absolute rules, contradicting the scanner's own module-docstring contract (*"Rules A and B are absolute ... apply to every policy module regardless of this list"*).
- **Evidence:** Codex review instruction `1776417637417-0001-oqn1bp` flagged the contradiction at the exact lineno positions (~310-311, ~328-329 in the first-landing form). Static verification confirmed: exempt modules could have imported `shlex` or tokenized raw command strings without failing Rule A/B.
- **Impact:** the scanner's Rule A and Rule B were effectively "strict only on non-exempt modules", not "absolute" as claimed. A future author adding a module to the allowlist for Rule C reasons would accidentally also grant that module a free pass on tokenization and `shlex` import, reopening the parallel-parser-drift defect class this pin exists to close.
- **Fix (applied 2026-04-17):** Rule A and Rule B scan loops now iterate every policy module unconditionally — the `if path.name in _KNOWN_EXEMPT_MODULES: continue` guard was removed from both. Comment block added to each rule explicitly stating "Rule {A,B} is absolute per the module-docstring contract. Rule C may keep the current exemption behavior" so a future re-introduction will be caught at review. A new `TestRuleABAbsoluteNoExemptBypass` class adds three mechanical self-tests: (a) `test_rule_a_does_not_reference_known_exempt_modules` — AST-scans the test file's own source and asserts `_KNOWN_EXEMPT_MODULES` is NOT referenced inside the Rule A test-function body; (b) `test_rule_b_does_not_reference_known_exempt_modules` — same invariant for Rule B; (c) `test_rule_c_does_reference_known_exempt_modules` — counterpart that asserts Rule C's test-function body DOES reference the allowlist (so the allowlist doesn't silently become dead code). A future regression that re-adds the `continue`-on-exempt pattern to Rule A or Rule B will fail these invariants.
- **Blocking?** No — resolved in the same slice. The scanner now correctly enforces Rules A and B absolutely.
- **Verification state:** 14 tests pass in `tests/runtime/policies/test_command_intent_single_authority.py` (3 live-repo rule scans + 4 positive-fixture-detection tests + 1 negative-fixture-clean-passes test + 3 module-surface/allowlist-discipline tests + 3 new scanner-self-invariant tests). `tests/runtime/policies/test_bash_git_who.py` (55 tests) and `tests/runtime/test_policy_engine.py` (subset) remain green — zero policy-module regression.

### Invariant #11 mechanical pin verified + moved into staged checkpoint scope (2026-04-17)

- **Subject:** `tests/runtime/test_decision_ref_resolution.py` — the filesystem-based scanner pinning CUTOVER_PLAN Invariant #11 (`@decision-ref` / `Refs DEC-*` cross-references must resolve to an `@decision DEC-X` declaration somewhere in repo source). Landed from a prior implementer slice (Codex acceptance `1776411084446-0003-xs5p0d`), originally held as untracked (`??`) and excluded from the 19-file checkpoint bundle.
- **Verification (lane):** `pytest -q tests/runtime/test_decision_ref_resolution.py` → **5 passed in 0.26s**. The live-repo scan across `runtime/`, `hooks/`, `tests/`, `agents/`, and top-level `ClauDEX/*.md` (excluding `ClauDEX/braid-v2/**`, `.git`, `.claudex`, `tmp`, `__pycache__`, `.worktrees`, `dist`, `build`, `.venv`, `venv`, `node_modules`, `.pyc`) finds zero unresolved `@decision-ref` / `Refs DEC-*` targets.
- **Contract fit:** The file opens with `@decision DEC-CLAUDEX-DECISION-REF-SCAN-001` (shadow-only, filesystem-based, stdlib-only — mirrors `hook_manifest` / `bridge_permissions` shadow-only discipline), explicitly cross-references `CUTOVER_PLAN.md` Invariant #11 as the authority the pin serves, and keeps `_KNOWN_DRIFT_IDS` empty by default with a documented rule requiring a dated follow-on-slice comment for any future addition. No parallel authority is introduced; the scanner is read-only and does not compete with `runtime/core/decision_work_registry.py` (the SQLite-backed decision store).
- **Action taken this slice:** staged the file so it is no longer excluded debt. The checkpoint bundle at the time of this Invariant-#11-integration slice became 22 paths (prior 21 + this file); the bundle subsequently grew to 23 with the addition of the Invariant #5 `command_intent` sole-authority scanner pin.
- **Blocking?** No. The test passes on the live repo. If a future slice introduces a new `@decision-ref DEC-X` target without a matching `@decision DEC-X` declaration, this invariant will fail and surface the drift with structured `file:line` diagnostics.
- **Verification state:** Green on lane at 2026-04-17 with HEAD `f24df96`; passes are deterministic (scan is pure-Python stdlib, sorted-walk, fixed regex).

### Bridge response-broker drift in `waiting_for_codex` (2026-04-17)

- **Symptom:** while the lane was in `waiting_for_codex`, the lane-local `pending-review.json` reported `response_available=true` with a valid `response_path`, while the Codex bridge supervisor's `get_response()` call against the same run returned `count: 0`. The two response surfaces disagreed even though they were nominally reading the same run.
- **Evidence context (from Codex supervisor):**
  - Run id: `1776367239-90135-af6087b8`
  - Triggering orchestrator instruction: `1776412474745-0001-8t25qs` (the stash-pop recovery slice)
  - Broker health: reported as "degraded" at the Codex supervisor seat
  - Artifact: `$CLAUDEX_STATE_DIR/pending-review.json` had a non-empty `response_path` pointing at an existing on-disk response while `get_response()` returned the empty result
- **Impact:** The supervisor loop cannot rely on `get_response()` as the authoritative signal when it disagrees with the lane-local `pending-review.json`. If the supervisor had defaulted to `get_response().count == 0 → treat as no response`, it would have missed a real response that was already written to disk, delaying review and extending the live-gate window. Conversely, trusting `pending-review.json` alone bypasses the bridge broker's dedupe/ack semantics. Neither fallback is safe in isolation.
- **Blocking?** Not blocking the current staged checkpoint (commit and push are governed by a separate harness gate). Blocking in the sense that the normal `get_response()`-first supervisor discipline cannot be trusted end-to-end while the broker is degraded; the supervisor must fall back to reading `pending-review.json` directly when `get_response()` disagrees with it.
- **Suggested next action:**
  - Short-term: the supervisor should treat `pending-review.json` as the tiebreaker when `get_response()` returns 0 but `pending-review.json` carries a valid `response_path` on disk. Add a comment in `.codex/prompts/claudex_supervisor.txt` (or equivalent) noting this fallback order; do NOT remove `get_response()` as the primary path.
  - Medium-term: investigate whether the bridge broker's response-cache invalidation missed the write, or whether the lane and supervisor are pointing at different bridge roots (cf. the 2026-04-14 env-leak class: `BRAID_ROOT` / `CLAUDEX_STATE_DIR` mismatch between supervisor seat and lane could produce the same symptom without broker bug). Capture the runtime values of `BRAID_ROOT` and `CLAUDEX_STATE_DIR` on both seats next time the drift recurs.
  - Long-term: the Phase-2b supervision fabric (`runtime.core.transport_contract` + `dispatch_attempts`) is the intended authoritative surface for delivery claim / ack. Work already done in that lane (see "Current Restart Slice" below) is forward progress; until the live bridge runs through that fabric, the `get_response()` / `pending-review.json` dual surface is the known drift point.
- **Verification state:** Not currently reproducing in this lane's own shell (the lane is write-side, not supervisor-side). Symptom was observed from the Codex supervisor read-only seat. Re-verification requires either (a) the supervisor pane to redo the `get_response()` / `pending-review.json` comparison, or (b) the lane to simulate the state by walking `pending-review.json` and the bridge broker cache together. Neither has been done this turn because this slice is checkpoint stewardship only.
- **Fresh verification 2026-04-17 (supervisor seat):** re-observed the same drift on run `1776367239-90135-af6087b8`. `get_status()` reported `state=waiting_for_codex`, `latest_response.instruction_id=1776413091424-0003-lb2em4`; lane-local `$CLAUDEX_STATE_DIR/pending-review.json` had `response_available=true` with a valid on-disk `response_path`; the Codex supervisor's `get_response()` call against the same run returned `count: 0`. This confirms the drift is not a one-off and that the supervisor loop needs an explicit fallback-order rule rather than treating `get_response()` as sole truth.
- **Mitigation landed (2026-04-17):** `.codex/prompts/claudex_supervisor.txt` Step 4 now documents the explicit response-surface fallback order — primary `get_response()`, fallback to lane-local `pending-review.json` when `count: 0` AND `run_id` matches the active run AND `response_path` is readable, ignore/regenerate when `run_id` mismatches. The fallback order is mechanically pinned by `tests/runtime/test_handoff_artifact_path_invariants.py::test_supervisor_step4_response_surface_fallback_is_pinned` and `::test_supervisor_step4_primary_before_fallback_ordering` (5 passed in 0.02s). The Step 4 fallback rule remains the current mitigation and continues to apply — it is not superseded by the narrower root-cause classification below. Broker-health investigation (cache-invalidation miss vs `BRAID_ROOT`/`CLAUDEX_STATE_DIR` env divergence) was narrowed this session (see below).
- **Fresh verification 2026-04-17 late-session (lane seat, instruction `1776434660074-0003-h9s2vh`) — root cause narrowed to `broker_or_cache_surface_mismatch`:**
  - **Env-divergence ruled out.** Lane-side `BRAID_ROOT=/tmp/claudex-b2r-v2` and `CLAUDEX_STATE_DIR=/Users/turla/Code/ConfigRefactor/claude-ctrl-hardFork/worktrees/claudex-cutover-soak/.claude/claudex` match the supervisor-seat baseline byte-for-byte. `$CLAUDEX_STATE_DIR/braid-root` sentinel file reads `/tmp/claudex-b2r-v2` (agrees with env). Both seats resolve the same active run id `1776367239-90135-af6087b8`.
  - **Live broker signal (lane seat):** `$BRAID_ROOT/braid status` reports `Broker: degraded (socket exists but pid 89934 is dead)`. `cat $BRAID_ROOT/runs/braidd.pid` → `89934`; `ps -p 89934` returns empty → the pidfile is stale and the broker daemon is not running. Unix socket file `$BRAID_ROOT/runs/braidd.sock` remains on-disk. This is the mechanical explanation for the supervisor's observed `get_response() = count:0` while on-disk response files and `pending-review.json` carry real content: clients dialing the stale socket get no server response, while filesystem writers (which bypass the broker) continue producing real response artifacts.
  - **State-gating nuance for `pending-review.json`:** at the moment of this lane-seat verification the run was `state="inflight"` and `$CLAUDEX_STATE_DIR/pending-review.json` was **absent** (confirmed via `find $CLAUDEX_STATE_DIR $BRAID_ROOT -name pending-review.json -type f` → no matches). Supervisor-seat verification at the same HEAD moments later (when the run transitioned to `state="waiting_for_codex"`) confirmed the file exists at the lane-local path with matching `run_id` / `instruction_id` and readable `response_path`. Conclusion: `pending-review.json` is **not persistently present** — it is written when the run enters `waiting_for_codex` and may be absent during `inflight`. Any probe or consumer that reads `pending-review.json` must handle absence during `inflight` as a non-error state, not as drift.
  - **Classification:** `broker_or_cache_surface_mismatch`, concrete sub-class `degraded_dead_pid_stale_socket`. Confidence: **HIGH** (env ruled out; `braid status` directly names the class; `ps` confirms dead pid).
  - **Next action recorded in planning contract:** `1776434532306-0002-c0n153` response contains the bounded-probe planning contract (`cc-policy bridge probe-response-drift` + `cc-policy bridge broker-health` read-only CLIs). That probe slice will execute **after** the committed bundle pushes to remote; it will not widen scope before pushing.
- **Implementation landed (2026-04-17 same-session, instruction `1776435335627-0008-n74wwg`):** the two probe CLIs planned above shipped in Option A form (already-staged files only, no new paths; staged count remained 28). Source in `runtime/core/bridge_permissions.py` (new public functions `probe_broker_health`, `probe_response_surface_drift` + frozen dataclasses `BrokerHealthSnapshot`, `ResponseSurfaceDiagnostic`). CLI wiring in `runtime/cli.py` under the `bridge` subparser. Tests in `tests/runtime/test_bridge_permissions.py` (13 new tests covering the six required classes) + `tests/runtime/test_bridge_validate_settings_cli.py` (5 new end-to-end CLI tests). `pytest -q tests/runtime/test_bridge_permissions.py tests/runtime/test_bridge_validate_settings_cli.py` → 73 passed, 0 failed. Broader smoke including `test_constitution_registry`, `test_current_lane_state_invariants`, `test_handoff_artifact_path_invariants` → 185 passed, 0 failed.
- **Live classification values observed on this lane (2026-04-17, HEAD `f24df96`):**
  - `python3 -m runtime.cli bridge broker-health` → exit 0, `status="degraded_dead_pid_stale_socket"`, `braidd_pid=89934`, `pid_alive=false`, `socket_exists=true`, `recovery_hint="braid down && braid up"`. This confirms via runtime CLI the same dead-pid / stale-socket finding previously surfaced only by the external `braid status` tool.
  - `python3 -m runtime.cli bridge probe-response-drift --run-id 1776367239-90135-af6087b8` → exit 0, `status="broker_cache_miss_stale_socket"`, with coherent `broker_health`, `pending_review`, `cursor`, and `env` sub-objects.
- **Impact of implementation:** root-cause diagnosis of the response-surface drift is now a runtime-CLI output rather than a manual forensic walk (inspecting `$BRAID_ROOT/runs/braidd.pid`, `ps -p <pid>`, `$CLAUDEX_STATE_DIR/pending-review.json`, `$BRAID_ROOT/runs/.../status.json` by hand). Supervisors, operators, and runbooks can now call the two CLIs directly and branch on the classified `status` field. The Step 4 fallback rule remains the current mitigation; these probes are diagnostic, not mitigation.

### Accidental `git stash pop` contaminated the lane (2026-04-17) — RESOLVED

- **Symptom:** a `git stash pop` invoked by the orchestrator during an attempted debug of a pre-existing test failure reapplied a pre-existing orphan stash `stash@{0}: WIP on claudesox-local: 9b24af9` against the then-19-file staged checkpoint bundle. The pop produced merge conflict markers in 16 files, left 17 files in `UU` (unmerged) state (including two files from the staged bundle — `ClauDEX/CURRENT_STATE.md` and `ClauDEX/SUPERVISOR_HANDOFF.md`), and expanded the staged set from 19 to 68 paths by silently promoting orphan stash content into the index. The policy engine then failed to import (`SyntaxError` in `runtime/schemas.py` from conflict markers), blocking all Bash tool invocations via `pre-bash.sh` fail-safe.
- **Evidence / Repro:**
  - Pre-incident status: `## claudesox-local...origin/feat/claudex-cutover [ahead 10]` with exactly 19 staged entries + `?? .claudex/` + `?? tests/runtime/test_decision_ref_resolution.py`.
  - Triggering sequence (recorded in session trace): the orchestrator ran `git stash push -- tests/runtime/test_decision_ref_resolution.py` (failed — path didn't match because the file was untracked), then `git stash pop` (succeeded — popped the orphan stash, producing the conflict).
  - Post-incident status: 68 staged entries, 17 `UU` entries, 16 files with conflict markers.
  - Orphan stash remained preserved on `stash@{0}` because the pop did not drop it (conflicts block auto-drop).
- **Impact:**
  - Policy engine briefly unable to import, blocking all runtime Bash operations via `pre-bash.sh` fail-safe until the blocking `runtime/schemas.py`, `runtime/core/authority_registry.py`, and `runtime/core/policies/bash_git_who.py` conflict markers were cleared via direct Edit-tool writes.
  - 19-file staged bundle was preserved at the git-object-store level (stage-2 blobs intact) but required manual resolution to exit the unmerged state.
  - Orphan stash content that overlapped our 19-bundle files (`runtime/cli.py`, `runtime/core/constitution_registry.py`, etc.) did NOT contaminate those bundle entries — they remained as cleanly-staged `M` because the stash had no content for them OR the content merged trivially.
- **Blocking?** No — resolved within the same turn per Codex recovery instruction `1776412474745-0001-8t25qs`. Recovery used `git checkout --ours` on bundle UU docs + `git add`, `git restore --source=HEAD --staged --worktree` on 49 non-bundle paths, and direct Edit-tool writes on 3 `runtime/core/*.py` files whose conflict markers had broken Python parsing before policy-engine-dependent Bash tools could run. Post-recovery lane matches the expected 19-file staged bundle exactly.
- **Suggested next action:**
  - NEVER run `git stash push` or `git stash pop` during an active checkpoint slice without first confirming the stash list is empty of pre-existing orphans (`git stash list | wc -l` should be the value you expect; this lane had 5 pre-existing stashes, so any `pop` was unsafe).
  - Orchestrator discipline: stash operations are on the destructive list for a reason — prefer `git diff --stat` / content-hash checks over `git stash` for "is this test failure pre-existing" investigation.
  - Consider adding a `bash_approval_gate` or `bash_git_who` sub-rule that denies `git stash` invocations during `in_progress` workflow states unless an explicit approval is granted.
- **Verification state (post-recovery):**
  - `git ls-files -u` → empty (no UU).
  - `git diff --cached --name-only | wc -l` → 19.
  - `git diff --cached --name-only` matches the expected 19-file bundle (per "## Current Restart Slice" enumeration below) exactly.
  - `git status --short --branch` → `## claudesox-local...origin/feat/claudex-cutover [ahead 10]` + the 19 staged entries + `?? .claudex/` + `?? tests/runtime/test_decision_ref_resolution.py`. No `UU` entries.
  - `CURRENT_STATE.md` cached blob hash `4a297f67...` matches the pre-pop stage-2 blob hash captured during forensic snapshot; `SUPERVISOR_HANDOFF.md` cached hash `ea03d9e6...` likewise.
  - `orphan stash stash@{0}` remains preserved on the stash list for operator inspection — can be dropped manually once the operator has confirmed there is no content worth recovering.

### cc-policy-who-remediation Slice 1 (2026-04-17)

- `runtime/core/bridge_permissions.py` added as concrete declarative authority
  (DEC-CLAUDEX-BRIDGE-PERMISSIONS-001); registered as entry #25 in
  `runtime/core/constitution_registry.py`; validated by
  `cc-policy bridge validate-settings` (exits 0).
- Five git-landing Bash denies removed from `ClauDEX/bridge/claude-settings.json`.
- **Checkpoint committed locally as `d7db4ba` (30 files).** Push blocked by
  `bash_approval_gate` high-risk policy, NOT runtime evaluation or lease gates.
- Committed bundle composition (**30 files**):
  Bundle E subordinate notes (`CC_POLICY_WHO_REMEDIATION_SPEC.md`,
  `CC_POLICY_WHO_REMEDIATION_EXECUTION_PROMPT.txt`); bridge-permission-slice
  (`runtime/core/bridge_permissions.py`, `runtime/cli.py`,
  `runtime/core/constitution_registry.py`,
  `ClauDEX/bridge/claude-settings.json`,
  `tests/runtime/test_bridge_permissions.py`,
  `tests/runtime/test_bridge_validate_settings_cli.py`,
  `tests/runtime/test_constitution_registry.py`); authority-doc /
  time-scoping (`ClauDEX/CURRENT_STATE.md`, `ClauDEX/CUTOVER_PLAN.md`,
  `ClauDEX/SUPERVISOR_HANDOFF.md`); Invariant #15 Bash readiness
  invalidation (`hooks/post-bash.sh`, `hooks/HOOKS.md`,
  `runtime/core/hook_manifest.py`, `settings.json`,
  `tests/runtime/policies/test_post_bash_eval_invalidation.py`,
  `tests/runtime/test_hook_manifest.py`,
  `tests/runtime/test_hook_validate_settings.py`); supervisor Step 4
  response-surface fallback (`.codex/prompts/claudex_supervisor.txt`);
  handoff-artifact invariant extension with Step 4 fallback pins
  (`tests/runtime/test_handoff_artifact_path_invariants.py`);
  Invariant #11 `@decision-ref` resolution pin
  (`tests/runtime/test_decision_ref_resolution.py`,
  DEC-CLAUDEX-DECISION-REF-SCAN-001); Invariant #5 `command_intent`
  sole-authority scanner pin
  (`tests/runtime/policies/test_command_intent_single_authority.py`,
  DEC-CLAUDEX-COMMAND-INTENT-SOLE-AUTHORITY-001); current-lane
  state-authority scanner pin
  (`tests/runtime/test_current_lane_state_invariants.py`,
  DEC-CLAUDEX-CURRENT-LANE-STATE-INVARIANT-001); Invariant #13
  symmetric retrieval-layer downstream pin
  (`tests/runtime/test_retrieval_layer_downstream_invariant.py`,
  DEC-CLAUDEX-RETRIEVAL-LAYER-DOWNSTREAM-INVARIANT-001); and dated
  invariant-coverage-matrix artifact + mechanical pin
  (`ClauDEX/CUTOVER_INVARIANT_COVERAGE_2026-04-17.md` +
  `tests/runtime/test_cutover_invariant_coverage_matrix.py`,
  DEC-CLAUDEX-CUTOVER-INVARIANT-COVERAGE-MATRIX-001). The bridge-parity extensions for
  Invariant #15 (PostToolUse Bash wiring and `REQUIRED_POSTTOOL_BASH_HOOKS`
  + drift tests) are folded into the three already-listed bridge paths — no
  new files for that sub-slice.
- Lane: `claudesox-local` at HEAD `d7db4ba`, 11 commits ahead of
  `origin/feat/claudex-cutover` (behind-count time-variant).
- Focused test evidence (refreshed 2026-04-17 for full 30-file bundle):
  **309 passed in 8.18s** across the 11-file combined focused suite
  (adds `tests/runtime/test_handoff_artifact_path_invariants.py` and
  `tests/runtime/test_decision_ref_resolution.py` to the prior 9-file
  set), plus **14 passed in 0.05s** on
  `tests/runtime/policies/test_command_intent_single_authority.py` for
  the Invariant #5 scanner pin. `python3 runtime/cli.py bridge validate-settings` → status ok;
  `python3 runtime/cli.py hook validate-settings` → status ok, healthy
  true, 31/31 manifest/settings parity; `python3 runtime/cli.py hook
  doc-check` → status ok, healthy true, exact_match true, 102/102
  line count (content hash
  `sha256:7019769b9f7d8d4fd90cfab786f4aa4512f624ccb9cf8f7f70510040f66dbed7`).
  Codex independent verification seats accepted the combined scope
  across six sub-slices: `1776406189098-0001-lqjleq`,
  `1776406882715-0003-7t7ugq`, `1776407137196-0001-3ql6ig`,
  `1776408220252-0004-2n7gcm`, `1776408476029-0005-jdg8g4`,
  `1776409725071-0001-7hvquf`, `1776411084446-0003-xs5p0d`
  (Invariant #11), `1776413402515-0001-zsj5f3` (Step 4 fallback +
  handoff invariant pins), and `1776413883321-0003-e8mgaw`
  (Invariant #11 integration).
- Blocking? No — checkpoint debt is preserved; next step is harness permission
  resolution or guardian-path commit.

- Soak Run 2026-04-14 (cutover bundle, worktree claudex-cutover-soak)
  1. Smoke keyword filter matched zero tests
     - Repro: `pytest -q tests/runtime/test_braid_v2.py -k 'smoke or quick or trace_export or seat_create'` → 0 passed, 5 deselected.
     - Impact: false green; smoke gate ineffective.
     - Suggested fix: drop the `-k` filter; run full file (5 tests, 0.22s) or validate filters with `--collect-only`.
     - Blocking? No.
  2. Watchdog pending-review / recovery artifacts missing
     - Repro: Soak run to `waiting_for_codex`; `.claude/claudex/pending-review.json` and relay-recovery artifacts not written; 5 watchdog tests fail.
     - Impact: Violates minimum bridge viability in this handoff; supervisor can miss state.
     - Current verification: `pytest -q tests/runtime/test_claudex_watchdog.py --maxfail=8` now passes locally (24 passed, 29.66s), so this is not currently reproduced in the soak worktree.
     - Suggested fix if it recurs: inspect `CLAUDEX_STATE_DIR`/lane mismatch first, then restore writing of `pending-review.json` and recovery state on waiting_for_codex/reconcile paths.
     - Blocking? No, unless reproduced again in the active lane.
  3. PID-reuse flake in watchdog dedupe test
     - Repro: watchdog test expects killed PID ≠ running PID; OS reused PID; assertion fails.
     - Impact: Flaky test only.
     - Suggested fix: change assertion to identity-based (e.g., start time) or tolerate PID reuse.
     - Blocking? No.
  4. dispatch-debug fixture absent in fresh worktree
     - Repro: `test_dispatch_debug_file_exists_and_has_subagent_start_events` fails because `tests/runtime/dispatch-debug.jsonl` not present in new worktree.
     - Impact: Test fails on clean clone unless seeded.
     - Current fix: seeded `tests/fixtures/dispatch-debug.seed.jsonl`; tests use live `runtime/dispatch-debug.jsonl` when present and deterministic seed truth otherwise.
     - Blocking? No.

### Soak Run 2026-04-14 (instruction 1776218048935-0001-0uqp4e)

- **Smoke keyword filter matches zero tests** (non-blocking, prompt fix)
  - Repro: `pytest -q tests/runtime/test_braid_v2.py -k 'smoke or quick or trace_export or seat_create'` → `5 deselected in 0.07s`.
  - Actual test names in `test_braid_v2.py`: `test_bundle_create_and_tree`, `test_adopt_tmux_worker_creates_runtime_rows`, `test_spawn_tmux_supervised_bundle_creates_child_bundle_threads_and_sessions`, `test_observe_tmux_seat_opens_and_clears_gates`, `test_controller_sweep_times_out_attempts_and_opens_findings`.
  - Impact: Supervisor's fast-smoke step no-ops silently and appears green. A future regression would pass this filter.
  - Suggested prompt fix: drop the `-k` filter for this file (only 5 tests, all fast) or use `-k 'bundle or adopt_tmux or spawn_tmux or observe_tmux or controller_sweep'`. Recommend the former (run all 5; whole file ran in 0.22s).
  - Blocking: no.

- **Watchdog pending-review / recovery artifacts not written in 5 tests** (blocking quality, needs investigation)
  - Repro: `pytest -q tests/runtime/test_claudex_watchdog.py`, failures:
    - `test_watchdog_nudges_lodged_relay_prompt_before_dispatch_recovery` — `.claude/claudex/relay-prompt-recovery.state.json` missing.
    - `TestPendingReviewPersistence::test_waiting_for_codex_writes_pending_review_with_full_payload` — `pending-review.json` not written on `waiting_for_codex`.
    - `TestPendingReviewPersistence::test_completed_inflight_with_response_is_reconciled_to_review_handoff` — no pending-review artifact after reconcile.
    - `TestPendingReviewClearance::test_non_waiting_state_clears_pending_review_artifact` — setup tick failed to create the artifact.
    - `TestPendingReviewClearance::test_user_driving_is_handed_back_and_handoff_still_persists` — handoff artifact missing.
  - Impact: The very artifacts `SUPERVISOR_HANDOFF.md` lists under "Minimum bridge viability" (pending-review.json detection/regeneration) have regressed at the unit level. If the watchdog no longer writes these, the supervisor cannot rely on them either.
  - Current verification: a fresh local rerun in this worktree passed: `pytest -q tests/runtime/test_claudex_watchdog.py --maxfail=8` → **24 passed**, 29.66s.
  - Revised assessment: not currently reproduced in the soak worktree; if it recurs, first check whether the watchdog and tests are using different `CLAUDEX_STATE_DIR`/lane roots before changing writer logic.
  - Blocking: no while the targeted watchdog suite remains green; yes if reproduced in the active lane.

- **PID-reuse flake in watchdog dedupe test** (non-blocking, low-priority test-only fix)
  - Repro: `pytest -q tests/runtime/test_claudex_watchdog.py::test_watchdog_dedupes_auto_submit_when_pidfile_and_pgrep_disagree` intermittently fails: `assert 64078 not in {64078, 64085}` — macOS reused `proc_a.pid` for the replacement process.
  - Impact: Flaky CI / noisy soak runs. Not a runtime defect.
  - Suggested fix: after killing `proc_a`, loop spawning ephemeral throwaway processes until a fresh PID is obtained; or assert on a process-identity marker (argv/env fingerprint) rather than PID equality.
  - Blocking: no.

- **`test_dispatch_debug_file_exists_and_has_subagent_start_events` requires live dispatches** (non-blocking, test hygiene)
  - Repro: `pytest tests/runtime/test_subagent_start_payload_shape.py::TestContractCarrierGap::test_dispatch_debug_file_exists_and_has_subagent_start_events` fails in a fresh worktree because `runtime/dispatch-debug.jsonl` does not exist until at least one Agent dispatch has happened in that worktree.
  - Impact: Soak runs in throwaway worktrees fail this check even when the cutover is healthy; the failure is environmental, not functional.
  - Fix: seeded `tests/fixtures/dispatch-debug.seed.jsonl`; the test now prefers live `runtime/dispatch-debug.jsonl` and falls back to deterministic captured truth in fresh worktrees.
  - Blocking: no.


- **Auto-submit process pressure / orphan growth** (fixed, operationally blocking while active)
  - Repro: live soak had many orphaned `claudex-auto-submit.sh` processes spawned by active watchdogs after parent Claude sessions died.
  - Root cause: `claudex-auto-submit.sh` and `claudex-watchdog.sh` trapped `TERM`/`INT` with cleanup functions that returned instead of exiting, effectively swallowing SIGTERM; watchdog also spawned auto-submit without forwarding `CLAUDEX_STATE_DIR`, allowing lane/pid-file drift.
  - Fix: signal traps now clean up and exit with signal-like status; watchdog passes `CLAUDEX_STATE_DIR="$PID_DIR"` when spawning auto-submit; watchdog tests force isolated `CLAUDEX_STATE_DIR` so live lanes are not polluted by fake test artifacts.
  - Verification: `pytest -q tests/runtime/test_claudex_auto_submit.py tests/runtime/test_claudex_watchdog.py --maxfail=8` → **36 passed**, 14.80s; live bridge status shows one active auto-submit pid and one active watchdog pid for the soak lane.
  - Blocking: no after fix and orphan cleanup.

- **State-record drift: handoff docs said "checkpoint pending" after checkpoint landed** (observed and fixed at 2026-04-14 closeout; documentation-only; HISTORICAL context only — this entry describes the 2026-04-14 Phase-8 closeout state, NOT the current 2026-04-17 lane state; see the top-of-file "Current Lane Truth (2026-04-17)" banner for current state)
  - Repro (2026-04-14): a stale-state grep over `ClauDEX/CURRENT_STATE.md` and `ClauDEX/SUPERVISOR_HANDOFF.md` returned phrases asserting the bundle was still waiting for a checkpoint even though the Phase-8 checkpoint had already landed as `6b8cc5c` and the follow-up process-control fix landed as `d8fdf96`, both pushed to `origin/feat/claudex-cutover`.
  - Impact (2026-04-14): supervisor and future implementers would dispatch another checkpoint-stewardship slice against a lane that at that snapshot had no checkpoint debt; directly contradicted installed truth as of 2026-04-14.
  - Fix (applied 2026-04-14): `ClauDEX/CURRENT_STATE.md` Git Placement + Checkpoint Readiness sections rewritten to reflect `claudesox-local` tracking `origin/feat/claudex-cutover` at HEAD `d8fdf96` with `6b8cc5c` as the cutover-bundle commit; `ClauDEX/SUPERVISOR_HANDOFF.md` next-action text at the time was rewritten to say (as of 2026-04-14) that the Phase-8 checkpoint had landed and the next action was cutover-plan continuation or lane maintenance. **That 2026-04-14 next-action framing is superseded as of 2026-04-17: the current lane carries 28-file staged checkpoint debt (harness-blocked), so the current next action is landing the staged bundle once the harness permission layer permits.**
  - Blocking: no (historical entry; resolved at 2026-04-14).


- **Codex supervisor model-upgrade prompt / MCP root drift** (fixed, lane maintenance)
  - Repro: launching `./scripts/claudex-codex-launch.sh` repeatedly showed the GPT-5.4 upgrade prompt; selecting "Use existing model" could crash the pane when the bridge MCP resolved Braid dependencies from `.b2r` instead of the active `/tmp/claudex-b2r-v2` root.
  - Impact: supervisor pane disappeared or stalled before it could call bridge tools; the worker could keep running but Codex supervision was not stable.
  - Fix: `scripts/claudex-codex-launch.sh` now writes lane-local config with `model = "gpt-5.3-codex"` and `model_reasoning_effort = "xhigh"`, writes the repo-global `.claude/claudex/braid-root` hint consumed by the MCP wrapper, and records the current Codex version as dismissed in lane-local `version.json`.
  - Verification: supervisor pane `%955` is running as `gpt-5.3-codex xhigh` and successfully calls `claude_bridge.get_status()` against active run `1776220007-97469-21be1f02`.
  - Blocking: no after relaunch; commit this follow-up bundle so restarts inherit the fix.

### Soak Run Test Counts

The first soak counts below are preserved for traceability; final local verification is the current gate.

- `tests/runtime/test_claudex_auto_submit.py tests/runtime/test_claudex_watchdog.py --maxfail=8`: **36 passed**, 14.80s.

- `tests/runtime/test_braid_v2.py` (full file, keyword filter matched nothing): **5 passed**, 0.22s first pass; **5 passed**, 0.33s final pass.
- `tests/runtime/test_claudex_watchdog.py --maxfail=8` fresh verification: **24 passed**, 29.66s first pass; **24 passed**, 28.27s final pass; **24 passed**, 26.55s under live lane env after isolation fix.
- `tests/runtime -k '(claudex or braid_v2 or dispatch)'` first-failure run: **33 passed, 1 failed** (watchdog PID dedupe) before `-x` stop, 3792 deselected, 20.44s.

### Suggested Prompt / Hook Improvements

- **Supervisor smoke prompt**: fixed in `.codex/prompts/claudex_supervisor.txt`; braid v2 smoke now runs `pytest -q tests/runtime/test_braid_v2.py` unfiltered.
- **Supervisor soak prompt**: fixed in `.codex/prompts/claudex_supervisor.txt`; any future `-k` smoke must be proven with `pytest --collect-only -q ... -k ...` before reporting green.
- **Hook/artifact contract**: keep `tests/runtime/test_claudex_watchdog.py` in the soak gate because `.claude/claudex/pending-review.json` and `.claude/claudex/relay-prompt-recovery.state.json` are canonical supervisor artifacts. If they fail again, treat state-dir/lane drift as the first suspect before adding a second artifact path.

### Follow-up verification 2026-04-14 (post-handoff edits)

- **Confirmed: watchdog failures are env-leak, not regression.** Running `pytest -q tests/runtime/test_claudex_watchdog.py --maxfail=8` with the supervisor's live env (`CLAUDEX_STATE_DIR=$PWD/.claude/claudex/b2r-v2-stable`, `BRAID_ROOT=/tmp/claudex-b2r-v2`) reproduced **8 failed, 1 passed in 9.76s** — the same 5 pending-review/recovery artifact failures plus the PID flake plus 2 `TestBridgeStatusSurface` cases. Unsetting both env vars and rerunning gave **24 passed in 36.75s**.
- **Net finding**: the watchdog test fixtures do not isolate from an externally-set `CLAUDEX_STATE_DIR`. When the soak shell exports the production lane, the fixtures write/read the production `.claude/claudex/pending-review.json` instead of the per-test tmpdir, and the assertions fail. This is test hygiene, not a watchdog writer regression.
- **Applied fix (test-only)**: `tests/runtime/test_claudex_watchdog.py` now explicitly passes the fixture `CLAUDEX_STATE_DIR` to watchdog/status/progress subprocesses, making the suite hermetic against supervisor env and removing false-positive lane pollution.
- **Combined clean-env verification**: `env -u CLAUDEX_STATE_DIR -u BRAID_ROOT pytest -q tests/runtime/test_braid_v2.py tests/runtime/test_claudex_watchdog.py tests/runtime/test_subagent_start_payload_shape.py` → **40 passed, 1 skipped in 35.35s**.
- No bounded Claude dispatch issued for this follow-up; the env isolation fix and auto-submit process fix are local worktree changes awaiting review/commit.

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
   `$CLAUDEX_STATE_DIR/pending-review.json`
   when present, then prefer `get_response()` as the normal review source,
   verify files/tests, and decide the next bounded instruction.
5. If the bridge is `queued` or `inflight`, call `wait_for_codex_review()` to
   return to a true blocking state until review is needed.
6. If the bridge is active but `$CLAUDEX_STATE_DIR/dispatch-stall.state.json`
   matches the active run, do not keep re-arming. Treat that as a transport
   failure already handed off to the watchdog recovery path.
7. Only stop for genuine user input, a genuine git/policy ambiguity, or an
   inactive / completed run.

The steady-state supervisor loop should not call `get_conversation()` or
`get_worker_observer()` unless the simpler path has already failed twice in a
row. Those tools are escalation-only for inconsistent bridge state, not part of
the normal review/steer cycle.

## Current Restart Slice

This section is the authoritative pointer the steady-state loop uses when it
finds the bridge idle with an empty queue and no pending-review artifact
(step 3 of Steady-State Behavior). It describes the single bounded slice the
supervisor should dispatch in that condition.

As of 2026-04-17 (post-push `995341e`), the Current Restart Slice is
**None — lane in steady-state maintenance**.

The pre-push integration prep is complete: 12-file pre-merge checkpoint
(`49e71d5`), upstream merge with 5 conflicts resolved (`959c3b2`),
follow-up merge (`995341e`), and push to `origin/feat/claudex-cutover`
all landed. Lane is 0 ahead / 0 behind.

No active cutover phase. No queued bounded slice. The supervisor should
dispatch only what the next Codex instruction explicitly authorises.

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

### Checkpoint-retry throttle rule (2026-04-17)

**Rule:** if a checkpoint retry is denied at the Claude Code harness
Bash-approval layer and the lane fingerprint is **unchanged** across
retries — same `HEAD` SHA, same staged file count, same denial class
(harness approval prompt on the same `git commit -F <path>` invocation)
and same verbatim denial text — the supervisor MUST NOT immediately
re-dispatch an identical checkpoint retry loop. Instead:

- Record the checkpoint debt as preserved (non-terminal) citing the
  unchanged lane fingerprint (HEAD, staged count, denial text).
- Proceed to the next bounded non-write cutover slice (diagnostic,
  documentation reconciliation, or planning work) that does not depend
  on the checkpoint landing first.
- Only retry the checkpoint when an **approval-state change** (the
  user grants the harness Bash approval for the denied command) or a
  **lane-state change** (HEAD moves, staged count changes, or the
  denial text changes) is observed. An unchanged-fingerprint repeat
  retry loop burns cycles without forward motion and creates noise in
  the artifact trail that obscures real state changes.

**Rationale:** a harness approval prompt is a pure session-scope gate.
The runtime policy engine, guardian lease, and test-pass state are all
clean and do not change between back-to-back retries. Repeating the
same command in the same session reliably produces the same denial.
Retrying is only meaningful when one of the three approval- or
lane-state inputs has actually changed.

**Fingerprint components (all three required for `unchanged`):**
1. `HEAD` SHA from `git rev-parse HEAD`.
2. Staged count from `git diff --cached --name-only | wc -l`.
3. Denial text (verbatim, starting with
   `Permission to use Bash with command git commit -F ...`).

If ANY of the three differs from the previous retry's record, the
fingerprint IS changed and a retry is permitted (and expected).

**Mechanical pin:** `tests/runtime/test_handoff_artifact_path_invariants.py::TestCheckpointRetryThrottleRule`.

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

## Historical Phase State Snapshot (as of 2026-04-14)

**This section is a historical snapshot of the Phase-plan status as
of the 2026-04-14 closeout. It is NOT current lane truth for 2026-04-17.**
Current lane truth lives in "Current Lane Truth (2026-04-17)" at the
top of this file: the lane is fully integrated and pushed (HEAD
`995341e`, 0 ahead / 0 behind). The phase-closure claims below
describe the 2026-04-14 Phase-plan state only and are preserved for
audit.

**Phases 3, 4, 5, 6, 7, and 8 are all COMPLETE (as of 2026-04-14).**
The ClauDEX cutover reached the Phase 8 closeout boundary at that date:

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

**Checkpoint stewardship is complete.** The ClauDEX cutover bundle
landed as commit `6b8cc5c` (`feat(claudex): cutover bundle - Phases 1-8
closeout`) and the subsequent auto-submit process-control fix landed as
`d8fdf96` (`Fix ClauDEX auto-submit process growth`). Both commits are
pushed to `origin/feat/claudex-cutover`. At the 2026-04-14 checkpoint
snapshot, this soak worktree was on `claudesox-local` tracking the same
upstream at HEAD `d8fdf96`; no checkpoint debt remained. These are
point-in-time checkpoint facts — post-checkpoint bridge / supervisor
fixes pushed to the same branch, and in-flight WIP in the soak
worktree, are expected and do not reopen the closed cutover.

**2026-04-17 post-checkpoint integration (Integration Wave 1):** ten
cutover-continuation bundles (Bundle 1 / A' / B / C / D / E / F / B2 /
B3 / B4 — see `ClauDEX/CURRENT_STATE.md` status block for
per-bundle SHAs and scopes) were authored as independent checkpoint
branches on origin, merged onto `checkpoint/integration-wave1`, and
fast-forwarded into `feat/claudex-cutover`. The custody tip advanced
`ca7190e → 018f2fa` via FF-only. No new cutover phase opened; the
integrated bundles are Category C retirements + Invariant #8 coverage +
Phase 2/2b/3 continuations + the CLAUDE.md narrative capstone. The
`CUTOVER_PLAN.md` Phase Plan remains exhausted; no Phase 9.

**Next bounded action: post-checkpoint state-record reconciliation
under the already-closed Phase 8. No Phase 9 exists.** With
Phases 1-8 closed and upstream, supervisor-session work on docs is
limited to narrow reconciliation of `ClauDEX/CURRENT_STATE.md` and
`ClauDEX/SUPERVISOR_HANDOFF.md` against the installed checkpoint
truth, plus lane maintenance (e.g. the lane-local Codex supervisor
launcher fix). Once those narrow bundles are reviewed and landed, the
supervisor should either (a) resume the `ClauDEX/CUTOVER_PLAN.md`
architecture track — the runtime-owned agent-session supervision
fabric — when ready to open a new slice, or (b) stay in steady-state
review/steer mode and handle narrow maintenance items without opening
fresh architecture work. Category C retirement (`proof_state`,
`dispatch_queue`/`dispatch_cycles`) pre-scoped in
`ClauDEX/PHASE8_DELETION_INVENTORY.md:205-216` remains future bounded
work, not current; it must not be auto-dispatched from this handoff
without a fresh Codex planning/scoping slice first. See
`ClauDEX/CURRENT_STATE.md` "Checkpoint Readiness" section for the
installed-truth git state and focused gate evidence.

Do not auto-dispatch a new architecture slice unless the cutover plan
has been re-read and a clearly bounded slice is ready.

For current detail, see `ClauDEX/CURRENT_STATE.md`.

## Current Restart Slice

**Status (post-checkpoint, post-integration):** no active cutover phase.
Phases 1-8 are complete; the accepted bundle is landed as `6b8cc5c` on
`feat/claudex-cutover`; the follow-up process-control fix landed as
`d8fdf96` and the supervisor-launch / state-record fix as `ca7190e` on
the same upstream. **On 2026-04-17 the Integration-Wave-1 set (ten
bundles, see `## Current State` above) was fast-forwarded into custody;
the live tip is `018f2fa`.** `ClauDEX/CUTOVER_PLAN.md` has no Phase 9,
the planned-area set is exhausted, and Category C is fully closed.

**Fresh-run bootstrap action (Steady-State step 3):** on a fresh
supervised run, the supervisor must dispatch a single bounded
verification / state-reconciliation slice — nothing more. Specifically:

1. Verify installed truth against the post-checkpoint claims in this
   file and in `ClauDEX/CURRENT_STATE.md`:
   - phase / work status (no active unfinished cutover phase, no hidden
     "Phase 9" style continuation)
   - branch / HEAD / upstream cleanliness claims understood as the
     2026-04-14 checkpoint snapshot, not as live runtime truth
   - `ClauDEX/CUTOVER_PLAN.md` alignment (no hidden continuation phase)
2. If drift is found **between** `CURRENT_STATE.md`,
   `SUPERVISOR_HANDOFF.md`, and `CUTOVER_PLAN.md`, apply **minimal
   docs-only reconciliation edits** to restore cross-doc coherence.
3. If no drift is found, make no changes and return evidence (commands
   run, key outputs, explicit "none" for files changed).

**Out of scope for the fresh-run slice:**

- Creating a new phase, slice, or control plane.
- Auto-dispatching any Category C implementation work
  (`proof_state`, `dispatch_queue` / `dispatch_cycles` retirement
  pre-scoped in `ClauDEX/PHASE8_DELETION_INVENTORY.md:205-216`).
  Category C remains future bounded work that requires a fresh Codex
  planning/scoping slice first — it must not be auto-dispatched from
  this handoff.
- Bridge / transport refinement, unless a bridge defect is a direct
  blocker on this verification slice.
- Any commit / push / destructive git action beyond the narrow
  reconciled docs bundle explicitly authorised by the supervisor.

**Next bounded action after this slice:** whichever bounded slice the
Codex supervisor explicitly authorises next. Until such authorisation,
the fresh-run slice is the entire restart-slice scope.

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
