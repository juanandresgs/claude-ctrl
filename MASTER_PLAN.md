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
  traces/    — Agent trace protocol (52 indexed traces)
  tests/     — Hook validation suite (121 tests)

### Active Work
  v2 Governance + Observability — fuse observability into governance layer

---

## Original Intent

> v1 is a governance layer: hooks enforce Sacred Practices, prevent bad states, gate
> commits on evidence. Strong at enforcement. Weak at memory. v2 fuses observability
> into that same layer. Hooks shift from gatekeeper to advisor. Agents share a session
> narrative. Commits tell stories. The system remembers friction and avoids repeating it.

## Problem Statement

The v1 system is stateless within sessions and amnesiac across sessions:
- Hooks fire, decide, forget — no trajectory awareness
- Agents pass artifacts in isolation, not sharing a narrative
- Commits describe what changed, not how we got there
- Sessions are ephemeral — no trace survives session end
- Recovery from agent mistakes requires manual git surgery
- New sessions start cold — same friction recurs across sessions

## Goals & Non-Goals

### Goals
- REQ-GOAL-001: Every session leaves a persistent trace (event log + summary)
- REQ-GOAL-002: Mid-session recovery in seconds via named checkpoints
- REQ-GOAL-003: Commits narrate engineering journey (approaches, friction, alternatives)
- REQ-GOAL-004: Hooks provide contextual guidance based on session trajectory
- REQ-GOAL-005: System learns across sessions (friction patterns surfaced proactively)

### Non-Goals
- REQ-NOGO-001: External logging service integration — local files only
- REQ-NOGO-002: Real-time dashboard — event log is for post-hoc analysis and agent use
- REQ-NOGO-003: Modifying the trace protocol — session events complement traces, not replace

## Requirements

### Must-Have (P0)

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

## Definition of Done

All P0 requirements satisfied. All existing hook tests continue to pass. Each phase
independently valuable and mergeable. v2 retrospective completed after Phase 4.

## Architectural Decisions

- DEC-V2-001: Session events as JSONL append-only log.
  Addresses: REQ-P0-001.
  Rationale: JSONL is atomic (one write per line), grep-friendly, and doesn't require
  parsing the entire file to append. Alternatives: SQLite (heavier, overkill for <1000
  events/session), plain text (not structured enough for trajectory queries).

- DEC-V2-002: Git ref-based checkpoints via plumbing commands.
  Addresses: REQ-P0-004, REQ-P0-005.
  Rationale: Git refs are first-class, survive garbage collection when referenced, and
  support random access without branch switching or stash pollution. Using write-tree +
  commit-tree + update-ref avoids touching the working copy or staging area.

- DEC-V2-003: Session archive indexed by project hash.
  Addresses: REQ-P0-003, REQ-P0-008.
  Rationale: Project paths contain spaces and special characters. A hash of the project
  path provides a stable, filesystem-safe directory name. Index.jsonl per project enables
  fast cross-session queries without reading every archived session.

- DEC-V2-004: Trajectory data as shell variables, not JSON.
  Addresses: REQ-P0-002.
  Rationale: Hooks are bash scripts. Shell variables (TRAJ_TOOL_CALLS=23) are faster to
  produce and consume than JSON parsing via jq. The event log itself is JSON for structure;
  the aggregates are shell variables for speed.

- DEC-V2-005: Session context in commits as structured text block, not metadata.
  Addresses: REQ-P0-006.
  Rationale: Git commit messages are the universal interface — every tool (GitHub, git log,
  blame) displays them. Structured text (Key: value) is human-readable and grep-parseable.
  Alternatives: git notes (not pushed by default, easily lost), trailers (limited to
  single-line values).

## Intent Statements

- **INTENT-01**: Every session leaves a trace. Event log + summary persist in `~/.claude/sessions/`.
- **INTENT-02**: Mid-session recovery takes seconds, not minutes. `/rewind` restores to checkpoint.
- **INTENT-03**: Commits tell engineering stories. Non-trivial commits include session context.
- **INTENT-04**: Hooks steer, not just block. Contextual guidance based on trajectory.
- **INTENT-05**: System learns across sessions. Prior friction surfaced proactively.

## Phase 0: Session Event Log (Foundation)
**Status:** planned
**Decision IDs:** DEC-V2-001, DEC-V2-003, DEC-V2-004
**Requirements:** REQ-P0-001, REQ-P0-002, REQ-P0-003
**Issues:** #81
**Definition of Done:**
- REQ-P0-001 satisfied: `.session-events.jsonl` written with structured events
- REQ-P0-002 satisfied: `get_session_trajectory()` returns accurate aggregates
- REQ-P0-003 satisfied: Events archived to `~/.claude/sessions/<project>/` on session end

### File Changes

| File | Change |
|------|--------|
| `hooks/context-lib.sh` | Add `append_session_event()`, `get_session_trajectory()`, `get_session_summary_context()` (~80 lines) |
| `hooks/track.sh` | Call `append_session_event "write"` after tracking file change (~3 lines) |
| `hooks/guard.sh` | Log gate evaluations via `append_session_event "gate_eval"` (~10 lines) |
| `hooks/session-init.sh` | Initialize `.session-events.jsonl` with `session_start` event (~5 lines) |
| `hooks/session-end.sh` | Archive event log to `~/.claude/sessions/`, add to cleanup (~15 lines) |

### Test Plan
- Write events, read back, verify JSONL format
- `get_session_trajectory()` returns correct aggregates from sample event log
- Session archive created in correct directory with correct content

### Decision Log
<!-- Guardian appends here after phase completion -->


## Phase 1: Checkpoints & Rewind
**Status:** planned
**Decision IDs:** DEC-V2-002
**Requirements:** REQ-P0-004, REQ-P0-005
**Issues:** #82
**Definition of Done:**
- REQ-P0-004 satisfied: Checkpoint refs created at correct frequency
- REQ-P0-005 satisfied: `/rewind` restores working tree to checkpoint state

### File Changes

| File | Change |
|------|--------|
| `hooks/checkpoint.sh` | **New** — PreToolUse hook for Write/Edit, creates git ref checkpoints (~60 lines) |
| `skills/rewind.md` | **New** — Skill listing + restoring checkpoints (~30 lines) |
| `hooks/subagent-start.sh` | Reset `.checkpoint-counter` on implementer start (~5 lines) |
| `settings.json` | Register `checkpoint.sh` in PreToolUse Write/Edit matcher |
| `agents/guardian.md` | Add checkpoint ref cleanup to merge protocol (~5 lines) |

### Test Plan
- Checkpoint ref created after threshold tool calls
- Multiple checkpoints have sequential numbering
- `/rewind` lists checkpoints with timestamps
- `/rewind` restores correct file state
- Checkpoints cleaned up after merge

### Decision Log
<!-- Guardian appends here after phase completion -->


## Phase 2: Session Summaries in Commits
**Status:** planned
**Decision IDs:** DEC-V2-005
**Requirements:** REQ-P0-006
**Issues:** #83
**Definition of Done:**
- REQ-P0-006 satisfied: Non-trivial commits include `--- Session Context ---` block

### File Changes

| File | Change |
|------|--------|
| `agents/guardian.md` | Add session context protocol (~20 lines) |
| `hooks/subagent-start.sh` | Inject session summary when spawning Guardian (~15 lines) |
| `hooks/context-lib.sh` | Add `get_session_summary_context()` (~40 lines) |

### Test Plan
- `get_session_summary_context()` produces structured text from sample events
- Non-trivial session (>5 tool calls) generates context block
- Trivial session (<5 tool calls) omits context block

### Decision Log
<!-- Guardian appends here after phase completion -->


## Phase 3: Session-Aware Hooks
**Status:** planned
**Decision IDs:** (trajectory analysis additions)
**Requirements:** REQ-P0-007
**Issues:** #84
**Definition of Done:**
- REQ-P0-007 satisfied: test-gate provides trajectory-based guidance on strike 2+

### File Changes

| File | Change |
|------|--------|
| `hooks/context-lib.sh` | Add `detect_approach_pivots()` (~30 lines) |
| `hooks/test-gate.sh` | Trajectory-aware guidance on strike 2+ (~30 lines replacement) |
| `hooks/session-summary.sh` | Structured retrospective with trajectory data (~40 lines) |

### Test Plan
- `detect_approach_pivots()` finds repeated edit+fail patterns in sample events
- test-gate on strike 2+ with event log mentions specific assertion and files
- test-gate without event log falls back to current behavior
- Session summary includes trajectory narrative

### Decision Log
<!-- Guardian appends here after phase completion -->


## Phase 4: Cross-Session Learning
**Status:** planned
**Decision IDs:** DEC-V2-003
**Requirements:** REQ-P0-008
**Issues:** #85
**Definition of Done:**
- REQ-P0-008 satisfied: Prior session friction injected at session start after 3+ sessions

### File Changes

| File | Change |
|------|--------|
| `hooks/session-end.sh` | Write session index entry to `~/.claude/sessions/<project>/index.jsonl` (~20 lines) |
| `hooks/session-init.sh` | Read + inject prior session context and friction patterns (~25 lines) |
| `hooks/context-lib.sh` | Add `get_prior_sessions()` (~30 lines) |

### Test Plan
- Session index entry written with correct schema
- Index trimmed to last 20 entries
- `get_prior_sessions()` returns recent summaries and friction patterns
- session-init injects prior session context when index exists
- Friction patterns detected from recurring entries across sessions

### Decision Log
<!-- Guardian appends here after phase completion -->


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
  "agents": ["type1", "type2"],
  "files_touched": ["path1", "path2"],
  "tool_calls": N,
  "checkpoints": N,
  "rewinds": N,
  "pivots": N,
  "friction": ["description1"],
  "outcome": "committed|tests-passing|tests-failing",
  "summary": "narrative text"
}
```

## Worktree Strategy

Main is sacred. Each phase works in its own worktree:
- **Phase 0:** `~/.claude/.worktrees/v2-phase-0` on branch `feature/v2-phase-0`
- **Phases 1-4:** Sequential worktrees after Phase 0 merges

Implementation order: Phase 0 (foundation, must be first) -> Phase 1 (checkpoints) ->
Phase 2 (commit context) -> Phase 3 (smart hooks) -> Phase 4 (cross-session).
Each phase is independently valuable and mergeable.

## References

### New State Files
| File | Scope | Written By | Read By |
|------|-------|-----------|---------|
| `.session-events.jsonl` | Session | track.sh, guard.sh, checkpoint.sh | context-lib.sh, session-summary.sh |
| `~/.claude/sessions/<project>/<session>.jsonl` | Persistent | session-end.sh | session-init.sh |
| `~/.claude/sessions/<project>/index.jsonl` | Persistent | session-end.sh | session-init.sh |
| `refs/checkpoints/<branch>/N` | Branch-scoped | checkpoint.sh | /rewind, Guardian |
