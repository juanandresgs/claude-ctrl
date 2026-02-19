# MASTER_PLAN: Claude System v2 — Governance + Observability

## Project Overview
**Type:** meta-infrastructure (hooks, agents, skills, commands)
**Languages:** bash (78%), markdown (15%), python (7%)
**Root:** /Users/turla/.claude

### Architecture
  hooks/     — 28 lifecycle hooks (session, tool-use, subagent, stop)
  agents/    — 4 agent prompts (planner, implementer, tester, guardian)
  skills/    — 8 skills (deep-research, decide, consume-content, ...)
  commands/  — 6 slash commands (backlog, compact, ...)
  scripts/   — Utility scripts (todo, update-check, batch-fetch)
  traces/    — Agent trace protocol (43 manifests, 39 indexed, 489 in oldTraces/)
  tests/     — Hook validation suite (121 tests)
  observatory/ — Self-improvement flywheel (analyze, suggest, report)

### Active Work
  Observability Platform Overhaul — fix degraded trace lifecycle, observatory pipeline, test coverage
  v2 Session Observability — fuse observability into governance layer (partially implemented, deferred)

---

## Original Intent

> v1 is a governance layer: hooks enforce Sacred Practices, prevent bad states, gate
> commits on evidence. Strong at enforcement. Weak at memory. v2 fuses observability
> into that same layer. Hooks shift from gatekeeper to advisor. Agents share a session
> narrative. Commits tell stories. The system remembers friction and avoids repeating it.

## Problem Statement

A comprehensive audit (2026-02-18) revealed 14 significant issues across the trace
lifecycle, observatory pipeline, and test coverage. The system is functionally degraded:
- Observatory suggestion pipeline only produces output for cohort regressions (2/8 signals
  are in regression; the other 6 are marked implemented but some fixes were incomplete)
- 74% of traces (14/19 in post-refinalize index) have test_result="unknown"
- Index out of sync: 39 entries vs 43 manifests (4 traces missing from index)
- 489 traces in oldTraces/ invisible to observatory analysis
- 4 orphaned active trace markers from crashed agents
- Silent jq failures in finalize/refinalize mask manifest update errors
- detect_active_trace() glob expansion race with concurrent same-type agents

The v2 session observability features (session events, checkpoints, cross-session learning)
were partially implemented during organic development but were never formally validated
against their original requirements. The existing plan (Phases 0-4) is stale — 75% source
file churn since last update, and several planned features already exist in code.

**Dominant Constraint:** data quality (observatory insights are only as good as the trace data)

## Goals & Non-Goals

### Goals
- REQ-GOAL-001: Observatory flywheel produces actionable suggestions from trace data
- REQ-GOAL-002: Trace manifests accurately reflect agent outcomes (test results, files changed, duration)
- REQ-GOAL-003: Every session leaves a persistent trace (event log + summary)
- REQ-GOAL-004: Mid-session recovery in seconds via named checkpoints
- REQ-GOAL-005: System learns across sessions (friction patterns surfaced proactively)

### Non-Goals
- REQ-NOGO-001: External logging service integration — local files only
- REQ-NOGO-002: Real-time dashboard — event log is for post-hoc analysis and agent use
- REQ-NOGO-003: Modifying the trace protocol — session events complement traces, not replace
- REQ-NOGO-004: Reprocessing oldTraces/ data into the main index — archive is read-only reference
- REQ-NOGO-005: Rewriting observatory from scratch — targeted fixes to existing pipeline

## Requirements

### Must-Have (P0) — Observability Overhaul

- REQ-P0-OBS-001: Observatory suggest.sh produces suggestions for all active signals, including regression re-proposals.
  Acceptance: Given 2+ cohort regressions in analysis-cache.json, When suggest.sh runs, Then SUG-NNN.json files are created for each regression.

- REQ-P0-OBS-002: jq failures in finalize_trace and refinalize_trace are logged, not silently swallowed.
  Acceptance: Given a malformed manifest.json, When finalize_trace runs, Then an error is logged to stderr and the function returns non-zero.

- REQ-P0-OBS-003: detect_active_trace() returns the correct trace for the current session without glob race.
  Acceptance: Given two concurrent planner agents, When detect_active_trace is called, Then each gets its own trace_id (not the other's).

- REQ-P0-OBS-004: Trace index stays in sync with manifests — rebuild_index covers all trace directories.
  Acceptance: Given 43 manifest files exist, When rebuild_index runs, Then index.jsonl has 43 entries.

- REQ-P0-OBS-005: refinalize_stale_traces runs successfully and heals orphaned/stale traces.
  Acceptance: Given 4 orphaned active markers, When refinalize_stale_traces runs, Then markers are cleaned and stale manifests are updated.

- REQ-P0-OBS-006: Observatory tests pass on main branch without worktree dependencies.
  Acceptance: Given a fresh clone on main, When tests/test-observatory-*.sh run, Then all tests pass.

- REQ-P0-OBS-007: test_result detection covers .test-status fallback in both finalize and refinalize paths.
  Acceptance: Given a trace with .test-status=pass but no test-output.txt, When finalize_trace runs, Then test_result=pass in manifest.

### Must-Have (P0) — v2 Session Observability (already partially implemented)

- REQ-P0-001: `.session-events.jsonl` written atomically during sessions with structured events.
  Acceptance: After any session with tool calls, `.session-events.jsonl` exists with valid JSONL.

- REQ-P0-002: `get_session_trajectory()` returns accurate session aggregates.
  Acceptance: Returns correct TRAJ_TOOL_CALLS, TRAJ_FILES_MODIFIED, TRAJ_GATE_BLOCKS counts.

- REQ-P0-003: Session events archived to `~/.claude/sessions/<project>/` on session end.
  Acceptance: After session ends, archived JSONL exists in sessions directory.

- REQ-P0-004: `refs/checkpoints/<branch>/N` created via git plumbing on Write/Edit.
  Acceptance: Checkpoint refs exist after implementer session with 5+ tool calls.

- REQ-P0-005: `/rewind` skill restores to a named checkpoint.
  Acceptance: After rewind, working tree matches checkpoint state.

- REQ-P0-006: Guardian includes `--- Session Context ---` block in non-trivial commits.
  Acceptance: Commits with >5 tool calls include the session context block.

- REQ-P0-007: test-gate provides trajectory-based guidance on strike 2+.
  Acceptance: When same assertion fails 3x, guidance mentions the specific assertion and files.

- REQ-P0-008: Prior session friction injected at session start.
  Acceptance: After 3+ sessions, session-init mentions recurring friction patterns.

### Nice-to-Have (P1)

- REQ-P1-001: Session retrospective written as human-readable summary.
- REQ-P1-002: Checkpoint frequency auto-tuned (more frequent near test failures).
- REQ-P1-003: Cross-session friction pattern detection (same assertion failing across sessions).
- REQ-P1-004: analyze.sh counts oldTraces/ in its dataset when computing historical baselines.
- REQ-P1-005: Assessment report auto-regenerates when analysis-cache is newer than report.

### Future Consideration (P2)

- REQ-P2-001: Structured development log digest in session-init (not just prior session summaries).
- REQ-P2-002: Historical baseline detection uses multi-day windows instead of single-day threshold.

## Definition of Done

All P0 requirements satisfied. All existing hook tests continue to pass. Observatory
flywheel produces actionable suggestions. Each phase independently valuable and mergeable.

## Architectural Decisions

- DEC-V2-001: Session events as JSONL append-only log.
  Addresses: REQ-P0-001.

- DEC-V2-002: Git ref-based checkpoints via plumbing commands.
  Addresses: REQ-P0-004, REQ-P0-005.

- DEC-V2-003: Session archive indexed by project hash.
  Addresses: REQ-P0-003, REQ-P0-008.

- DEC-V2-004: Trajectory data as shell variables, not JSON.
  Addresses: REQ-P0-002.

- DEC-V2-005: Session context in commits as structured text block, not metadata.
  Addresses: REQ-P0-006.

- DEC-OBS-OVERHAUL-001: Fix forward, not rewrite — targeted patches to existing pipeline.
  Addresses: REQ-P0-OBS-001 through REQ-P0-OBS-007.
  Rationale: The observatory pipeline (analyze.sh, suggest.sh, report.sh) is architecturally
  sound. The issues are specific bugs (jq error handling, glob races, missing fallbacks),
  not design flaws. Rewriting would lose the extensive @decision documentation and tested
  signal metadata. Fix the bugs, heal the data, add missing tests.

- DEC-OBS-OVERHAUL-002: Session-specific marker lookup before glob fallback in detect_active_trace.
  Addresses: REQ-P0-OBS-003.
  Rationale: The glob fallback (`ls -t .active-TYPE-*`) races when concurrent agents of
  the same type exist. The session-specific marker (`CLAUDE_SESSION_ID`) is already checked
  first but falls through to the racy glob when the session ID is missing. Fix: make the
  glob fallback validate the marker's trace_id against the manifest's session_id.

- DEC-OBS-OVERHAUL-003: jq error propagation via explicit error checking, not /dev/null.
  Addresses: REQ-P0-OBS-002.
  Rationale: 151 instances of `2>/dev/null` in context-lib.sh. Not all should be removed —
  many are legitimate (optional fields, non-git directories). The critical path is the
  manifest update in finalize_trace (line 844-861) where a jq failure silently drops all
  field updates. Fix: check jq exit code and log failures for the manifest write path.

## Critical Files
- `hooks/context-lib.sh` — All trace lifecycle functions (init, finalize, refinalize, rebuild_index)
- `skills/observatory/scripts/suggest.sh` — Suggestion pipeline (signal scoring, batch grouping)
- `skills/observatory/scripts/analyze.sh` — Analysis pipeline (signal detection, cohort regression)
- `observatory/state.json` — Implemented/rejected/deferred signal tracking
- `tests/test-observatory-*.sh` — Observatory test suite (4 test files, worktree-dependent)

---

## Phase 0: Critical Fixes (Observatory Pipeline Revival)
**Status:** completed
**Decision IDs:** DEC-OBS-OVERHAUL-001, DEC-OBS-OVERHAUL-002, DEC-OBS-OVERHAUL-003
**Requirements:** REQ-P0-OBS-001, REQ-P0-OBS-002, REQ-P0-OBS-003, REQ-P0-OBS-005
**Issues:** #99, #100, #101, #102
**Definition of Done:**
- REQ-P0-OBS-001 satisfied: suggest.sh produces SUG files for regression signals AND any new unimplemented signals
- REQ-P0-OBS-002 satisfied: finalize_trace manifest write failures are logged and detectable
- REQ-P0-OBS-003 satisfied: detect_active_trace returns correct trace_id with concurrent agents
- REQ-P0-OBS-005 satisfied: refinalize_stale_traces heals orphaned markers and stale manifests

### Planned Decisions
- DEC-OBS-OVERHAUL-001: Fix-forward approach for pipeline bugs — Addresses: REQ-P0-OBS-001, REQ-P0-OBS-002
- DEC-OBS-OVERHAUL-002: Session-specific marker validation in detect_active_trace — Addresses: REQ-P0-OBS-003
- DEC-OBS-OVERHAUL-003: jq error propagation in manifest writes — Addresses: REQ-P0-OBS-002

### Work Items

**C1: Verify and harden suggest.sh cohort regression path**
- The cohort regression query (lines 258-260) works correctly in isolation but the pipeline
  was reported as producing zero output. Investigate whether state.json entries lack
  implemented_at timestamps (preventing cohort analysis) or whether the signal loop
  receives no signals from analysis-cache.
- Root cause: All 8 signals are in state.json as "implemented". The pipeline only produces
  output for signals with cohort regressions. Currently 2 regressions exist and DO produce
  output when run manually. The audit finding may have been from a stale analysis-cache.
- Fix: Add defensive logging to suggest.sh so empty output is diagnosable. Validate that
  all implemented entries in state.json have implemented_at timestamps for cohort analysis.

**C2: Add jq error handling to finalize_trace manifest write**
- Lines 844-861: `jq ... "$manifest" > "$tmp_manifest" 2>/dev/null && mv "$tmp_manifest" "$manifest"`
- The `2>/dev/null` hides jq parse errors (malformed manifest). If jq fails, the `&&`
  prevents the mv but the error is invisible.
- Fix: Remove `2>/dev/null` from the critical jq call. Log the error. Return non-zero.
- Apply same pattern to refinalize_trace manifest write.

**C3: Fix detect_active_trace glob race**
- Line 649: `ls -t "${TRACE_STORE}/.active-${agent_type}-"* 2>/dev/null | head -1`
- With concurrent same-type agents, `ls -t` returns the most recently modified marker,
  which may belong to a different session.
- Fix: When CLAUDE_SESSION_ID is empty, iterate markers and validate each against the
  manifest's session_id field before returning.

**H1: Heal orphaned active traces**
- 4 orphaned .active-* markers exist (though init_trace already cleans markers >2hrs old).
- Immediate: Run refinalize_stale_traces to heal stale manifests.
- Verify the 1 current active marker (.active-planner-*) is this session.

### Critical Files
- `hooks/context-lib.sh` — finalize_trace (lines 661-879), detect_active_trace (lines 633-656)
- `skills/observatory/scripts/suggest.sh` — cohort regression check (lines 255-268)
- `observatory/state.json` — implemented signal entries need implemented_at validation

### Decision Log
<!-- Guardian appends here after phase completion -->


## Phase 1: Data Quality (Trace Accuracy)
**Status:** completed
**Decision IDs:** DEC-OBS-OVERHAUL-001
**Requirements:** REQ-P0-OBS-004, REQ-P0-OBS-006, REQ-P0-OBS-007
**Issues:** #103, #104, #105, #106
**Definition of Done:**
- REQ-P0-OBS-004 satisfied: index.jsonl has entries for all manifest files
- REQ-P0-OBS-006 satisfied: observatory test suite passes on main without worktree deps
- REQ-P0-OBS-007 satisfied: .test-status fallback resolves unknown test results

### Work Items

**H2: Validate .test-status fallback effectiveness**
- finalize_trace already has .test-status fallback (lines 727-743). refinalize_trace
  also has it (lines 961-1012) with timestamp window validation.
- 74% of traces still show unknown — investigate why the fallback isn't resolving them.
  Likely: .test-status doesn't exist at finalize time (agent hasn't written it yet),
  and refinalize hasn't been run since the fix shipped.
- Fix: Run refinalize_stale_traces to heal existing traces. Verify fallback logic is correct.

**H3: Rebuild index to sync with manifests**
- 39 index entries vs 43 manifests. 4 traces missing from index.
- Fix: Run rebuild_index() to resync. Add a pre-flight check to analyze.sh that
  detects index/manifest count mismatch and auto-rebuilds.

**H5: Fix missing start_commit/end_commit in traces**
- 10 traces missing end_commit, 6 missing start_commit per audit.
- Root cause: end_commit only captured when project_root is a git repo AND git rev-parse
  succeeds. For worktree-based work that was already merged/deleted, this fails.
- Fix: start_commit is already captured in init_trace. end_commit capture in finalize_trace
  (line 838) is correct but only runs if project_root has a .git dir. For the existing
  traces, this is data that cannot be retroactively recovered.

**M5: Fix observatory tests — remove worktree dependency**
- 4 test files depend on feature branch worktrees that no longer exist.
- Fix: Make tests self-contained — create temporary test fixtures instead of depending
  on worktree state. Use `mktemp -d` for isolated test environments.

### Critical Files
- `hooks/context-lib.sh` — rebuild_index (lines 1291-1326), refinalize_stale_traces (lines 1220-1273)
- `tests/test-observatory-*.sh` — 4 test files with worktree dependencies
- `traces/index.jsonl` — trace index (39 entries, should be 43)

### Decision Log
<!-- Guardian appends here after phase completion -->


## Phase 2: Pipeline Completion (Observatory Enhancement)
**Status:** completed
**Decision IDs:** DEC-OBS-OVERHAUL-001
**Requirements:** REQ-P1-004, REQ-P1-005, REQ-P2-001
**Issues:** #107, #108, #109, #110
**Definition of Done:**
- analyze.sh produces accurate signal counts including oldTraces/ context
- Assessment report reflects latest analysis-cache
- Session-init structured development log digest implemented

### Work Items

**H4: Count oldTraces/ in observatory analysis**
- analyze.sh Stage 2 (artifact health scan) only counts depth-1 dirs in traces/.
  The 489 traces in oldTraces/ are invisible.
- Fix: Extend the artifact health scan to optionally include oldTraces/ as a
  historical reference dataset. Do not add them to the active index — they are
  archived data. Add a `historical_traces` section to analysis-cache.json.

**M1: Auto-regenerate assessment report**
- Assessment report is generated before latest analysis cache, making it stale.
- Fix: Add a timestamp check in report.sh — if analysis-cache.json is newer than
  the assessment report, regenerate before rendering.

**M2: Historical baseline detection improvement**
- NO_HISTORICAL_BASELINE flag may false-fire when all traces are from today,
  suppressing trend analysis even when there are multiple runs within a day.
- Fix: Use run count (>1 analysis-cache.prev.json exists) instead of calendar day
  uniqueness as the baseline indicator.

**M3: Session-init structured development log digest**
- Currently session-init shows last trace info but not a structured summary of
  recent development activity.
- Fix: Build a compact digest from the last 5 traces: agent type, outcome, duration,
  files changed. Inject as structured context at session start.

### Critical Files
- `skills/observatory/scripts/analyze.sh` — Stage 2 artifact scan, Stage 0 baseline detection
- `skills/observatory/scripts/report.sh` — Assessment report generation
- `hooks/session-init.sh` — Development log digest injection

### Decision Log
<!-- Guardian appends here after phase completion -->


## Phase 3: v2 Session Event Log (Foundation)
**Status:** completed
**Decision IDs:** DEC-V2-001, DEC-V2-003, DEC-V2-004, DEC-V2-SCHEMA-001
**Requirements:** REQ-P0-001, REQ-P0-002, REQ-P0-003
**Issues:** #81, #116, #117
**Definition of Done:**
- REQ-P0-001 satisfied: `.session-events.jsonl` written with structured events
- REQ-P0-002 satisfied: `get_session_trajectory()` returns accurate aggregates
- REQ-P0-003 satisfied: Events archived to `~/.claude/sessions/<project>/` on session end

### Implementation Status
All P0 requirements validated and tested:
- `append_session_event()` in context-lib.sh (functional, schema-validated)
- `get_session_trajectory()` in context-lib.sh (functional, accuracy-validated)
- Session archive in session-end.sh (functional, writes index.jsonl, schema-validated)
- `get_prior_sessions()` in context-lib.sh (functional)
- Guardian commit event emission via SHA comparison (W3-1)
- 11-test schema compliance suite (W3-5, W3-6)

### Decision Log
- DEC-V2-001: Session events as JSONL append-only log — Implemented in context-lib.sh `append_session_event()`. All event types conform to schema.
- DEC-V2-003: Session archive indexed by project hash — Implemented in session-end.sh. Archive index entries validated by test suite (W3-6).
- DEC-V2-004: Trajectory data as shell variables, not JSON — Implemented in `get_session_trajectory()`. Accuracy validated against synthetic event logs.
- DEC-V2-SCHEMA-001: Schema compliance tests validate event structure at unit level — 11 tests in test-event-schema.sh cover all event types, graceful degradation, and aggregate accuracy.


## Phase 4: v2 Checkpoints & Rewind
**Status:** completed
**Decision IDs:** DEC-V2-002
**Requirements:** REQ-P0-004, REQ-P0-005
**Issues:** #82, #118, #119, #120
**Definition of Done:**
- REQ-P0-004 satisfied: Checkpoint refs created at correct frequency
- REQ-P0-005 satisfied: `/rewind` restores working tree to checkpoint state

### Implementation Status
- `hooks/checkpoint.sh` registered in settings.json — creates refs on Write/Edit tool calls
- `skills/rewind/SKILL.md` — full restore protocol with `git checkout` + `git clean -fd -e .claude/`
- 8-test round-trip suite validates checkpoint creation, sequential numbering, restore accuracy, untracked file cleanup, .claude/ exclusion, counter reset, and worktree context

### P0 Requirement Coverage
- REQ-P0-004 (checkpoint refs): Addressed by DEC-V2-002 — checkpoint.sh creates `refs/checkpoints/<branch>/N` every 5 writes and on first modification of new files. Validated by tests 1-4, 7-8.
- REQ-P0-005 (rewind restore): Addressed by DEC-V2-002 — SKILL.md Step 3 restores tracked files via `git checkout SHA -- .` and removes untracked files via `git clean -fd -e .claude/`. Validated by tests 1, 5-6.

### Deferred (P1)
- W4-5: Checkpoint frequency auto-tuning (REQ-P1-002)
- W4-6: Cross-session friction pattern detection (REQ-P1-003)

### Decision Log
- DEC-V2-002: Git ref-based checkpoints via plumbing commands — Implemented in checkpoint.sh (creation) and SKILL.md (restore). Critical bug fix: original SKILL.md lacked `git clean -fd -e .claude/` after restore, leaving untracked files from after the checkpoint. Fixed in W4-1 (#118). Round-trip test suite (W4-3 #119, W4-4 #120) validates full lifecycle including worktree context.


## Phase 5: v2 Session-Aware Hooks + Commit Context
**Status:** completed
**Decision IDs:** DEC-V2-005
**Requirements:** REQ-P0-006, REQ-P0-007
**Issues:** #83, #84, #121, #122
**Definition of Done:**
- REQ-P0-006 satisfied: Non-trivial commits include `--- Session Context ---` block
- REQ-P0-007 satisfied: test-gate provides trajectory-based guidance on strike 2+

### Implementation Status
All P0 requirements validated and tested:
- `get_session_summary_context()` in context-lib.sh generates structured commit context blocks for non-trivial sessions (>5 tool calls)
- `detect_approach_pivots()` in context-lib.sh identifies edit-fail loops as approach pivots
- `subagent-start.sh` injects session summary when spawning Guardian agents
- `test-gate.sh` provides trajectory-aware guidance on strike 2+ (file-specific, assertion-specific)
- 76 tests across 3 test files validate the complete session-aware hook lifecycle

### P0 Requirement Coverage
- REQ-P0-006 (session context in commits): Addressed by DEC-V2-005 — guardian.md protocol + subagent-start.sh injection + get_session_summary_context(). Validated by test-session-context.sh (10 tests including Guardian injection path).
- REQ-P0-007 (trajectory-based test guidance): Addressed by DEC-V2-005 — test-gate.sh uses get_session_trajectory() to provide file-specific and assertion-specific guidance. Validated by test-trajectory.sh (17 tests including 52-event scale test).

### File Changes

| File | Change |
|------|--------|
| `agents/guardian.md` | Add session context protocol (~20 lines) |
| `hooks/subagent-start.sh` | Inject session summary when spawning Guardian (~15 lines) |
| `hooks/context-lib.sh` | Add `get_session_summary_context()`, `detect_approach_pivots()` |
| `hooks/test-gate.sh` | Trajectory-aware guidance on strike 2+ (~30 lines replacement) |
| `tests/test-session-context.sh` | +2 tests: Guardian injection path, trajectory accuracy |
| `tests/test-trajectory.sh` | +1 scale test with 3 assertions (52 events, pivot detection) |
| `tests/test-v2-e2e.sh` | +14 lifecycle assertions (9-stage full session arc) |

### Decision Log
- DEC-V2-005: Session context in commits as structured text block — Implemented in guardian.md (protocol), subagent-start.sh (injection), context-lib.sh (generation). Non-trivial sessions (>5 tool calls) produce a `--- Session Context ---` block with Intent, Approach, Friction, Rejected, Open, and Stats fields. Trivial sessions omit the block. Validated by 10 unit tests + 17 trajectory tests + 49 e2e lifecycle tests.


## Event Log Schema

```jsonl
{"ts":"ISO8601","event":"session_start","project":"name","branch":"branch"}
{"ts":"ISO8601","event":"write","file":"path","lines_changed":N}
{"ts":"ISO8601","event":"checkpoint","ref":"refs/checkpoints/branch/N","trigger":"reason"}
{"ts":"ISO8601","event":"test_run","result":"pass|fail","failures":N,"assertion":"name"}
{"ts":"ISO8601","event":"gate_eval","hook":"name","result":"allow|block","reason":"text"}
{"ts":"ISO8601","event":"agent_start","type":"agent_type","trace_id":"id"}
{"ts":"ISO8601","event":"agent_stop","type":"agent_type","duration_min":N,"pivots":N}
{"ts":"ISO8601","event":"commit","sha":"hash","message":"text"}
```

## Session Summary Schema (index.jsonl)

```json
{
  "id": "session-id",
  "project": "name",
  "started": "ISO8601",
  "duration_min": N,
  "files_touched": ["path1", "path2"],
  "tool_calls": N,
  "checkpoints": N,
  "pivots": N,
  "friction": ["description1"],
  "outcome": "committed|tests-passing|tests-failing",
  "summary": "narrative text"
}
```

## Worktree Strategy

Main is sacred. Each phase works in its own worktree:
- **Phase 0:** `~/.claude/.worktrees/obs-overhaul-phase-0` on branch `fix/obs-critical`
- **Phase 1:** `~/.claude/.worktrees/obs-overhaul-phase-1` on branch `fix/obs-data-quality`
- **Phase 2:** `~/.claude/.worktrees/obs-overhaul-phase-2` on branch `feature/obs-pipeline-completion`
- **Phases 3-5:** Sequential worktrees after overhaul merges

Implementation order: Phase 0 (critical fixes, must be first) -> Phase 1 (data quality,
depends on Phase 0 healing) -> Phase 2 (pipeline completion) -> Phases 3-5 (v2 features,
deferred until observatory is healthy).

Phase 0 and Phase 1 can be done in rapid succession (same worktree if desired).
Phase 2 is independent and can parallelize with Phase 1.

## References

### State Files
| File | Scope | Written By | Read By |
|------|-------|-----------|---------|
| `.session-events.jsonl` | Session | track.sh, guard.sh, checkpoint.sh | context-lib.sh, session-summary.sh |
| `~/.claude/sessions/<project>/<session>.jsonl` | Persistent | session-end.sh | session-init.sh |
| `~/.claude/sessions/<project>/index.jsonl` | Persistent | session-end.sh | session-init.sh |
| `refs/checkpoints/<branch>/N` | Branch-scoped | checkpoint.sh | /rewind, Guardian |
| `observatory/state.json` | Persistent | observatory skill | suggest.sh, analyze.sh |
| `observatory/analysis-cache.json` | Persistent | analyze.sh | suggest.sh, report.sh |
| `traces/index.jsonl` | Persistent | finalize_trace, rebuild_index | analyze.sh, session-init.sh |

### Audit Findings Reference
| ID | Severity | Summary | Phase |
|----|----------|---------|-------|
| C1 | Critical | suggest.sh pipeline produces zero output (all signals implemented, cohort regression path untested) | 0 |
| C2 | Critical | Silent jq failures in finalize/refinalize manifest writes | 0 |
| C3 | Critical | detect_active_trace glob race with concurrent agents | 0 |
| H1 | High | 4 orphaned active trace markers (>16h old) | 0 |
| H2 | High | 74% of traces have test_result="unknown" | 1 |
| H3 | High | Index out of sync: 39 entries vs 43 manifests | 1 |
| H4 | High | oldTraces/ (489) not counted in observatory analysis | 2 |
| H5 | High | 10 traces missing end_commit, 6 missing start_commit | 1 |
| M1 | Medium | Assessment report stale — generated before latest analysis cache | 2 |
| M2 | Medium | Historical baseline detection may false-flag | 2 |
| M3 | Medium | Session-init lacks structured development log digest | 2 |
| M4 | Medium | Phase 4 Cross-Session Learning not implemented | 3 (already done) |
| M5 | Medium | Observatory tests depend on feature branch worktrees | 1 |
| M6 | Medium | SUG-file mapping fragile — renumbering on each run | N/A (by design, DEC-OBS-022) |
