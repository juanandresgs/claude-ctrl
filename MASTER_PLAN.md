# MASTER_PLAN: Claude Code Governance System

## Identity

**Type:** meta-infrastructure (hooks, agents, skills, commands)
**Languages:** bash (78%), markdown (15%), python (7%)
**Root:** /Users/turla/.claude
**Created:** 2026-02-18
**Last updated:** 2026-02-19

This is the Claude Code configuration directory. It shapes how Claude Code operates
across all projects via lifecycle hooks, specialized agents, research skills, and
governance rules. The system enforces Sacred Practices (plan-first development,
worktree isolation, proof-before-commit) through deterministic hooks rather than
advisory prompts.

## Architecture

  hooks/       — 28 lifecycle hooks (session, tool-use, subagent, stop)
  agents/      — 4 agent prompts (planner, implementer, tester, guardian)
  skills/      — 8 skills (deep-research, decide, consume-content, ...)
  commands/    — 6 slash commands (backlog, compact, ...)
  scripts/     — Utility scripts (todo, update-check, batch-fetch, worktree-roster)
  traces/      — Agent trace protocol (43 manifests, 39 indexed, 489 in oldTraces/)
  tests/       — Hook validation suite (141 tests)
  observatory/ — Self-improvement flywheel (analyze, suggest, report)

## Original Intent

> Build a governance system for Claude Code that enforces disciplined development practices
> through deterministic hooks rather than advisory prompts. The system should ensure:
> plan-first development (no code without MASTER_PLAN.md), worktree isolation (main is
> sacred), proof-before-commit (tester verification gates merges), and institutional memory
> (traces, session events, cross-session learning). Each initiative refines this system.
> The plan itself is a living record of the project's evolution — not a disposable task
> tracker that gets archived and replaced.

## Principles

These are the project's enduring design principles. They do not change between initiatives.

1. **Deterministic over AI** — Hooks use grep/stat/jq, not LLM calls. Predictable runtime, zero cascade risk.
2. **Gate, don't advise** — Hard deny beats soft warning. Agents ignore warnings; they cannot ignore denials.
3. **Evidence over assertion** — Proof-before-commit, test-before-declare, trace-before-forget.
4. **Single source of truth** — context-lib.sh for shared functions. MASTER_PLAN.md for project intent. GitHub Issues for task tracking.
5. **Bounded injection** — Session context stays under ~200 lines regardless of project history length.

---

## Decision Log

Append-only record of significant decisions across all initiatives. Each entry references
the initiative and decision ID. This log persists across initiative boundaries — it is the
project's institutional memory.

| Date | DEC-ID | Initiative | Decision | Rationale |
|------|--------|-----------|----------|-----------|
| 2026-02-18 | DEC-CTXLIB-001 | v1 | Shared context library consolidates duplicate hook code | Eliminates drift across session-init, prompt-submit, subagent-start |
| 2026-02-18 | DEC-UPDATE-BG-001 | v1 | Background update-check with previous-session result display | Makes startup non-blocking for update notifications |
| 2026-02-18 | DEC-PROMPT-001 | v1 | User verification gate and dynamic context injection | Only path for user verification to reach .proof-status |
| 2026-02-18 | DEC-GUARDIAN-001 | v2 | Deterministic guardian validation replacing AI agent hook | File stat + git status in <1s with zero cascade risk |
| 2026-02-18 | DEC-PLANNER-STOP-001 | v2 | Deterministic planner validation | Every check is a grep/stat completing in <1s |
| 2026-02-18 | DEC-PLANNER-STOP-002 | v2 | Move finalize_trace before git/plan state checks | Ensures trace sealed even when downstream checks timeout |
| 2026-02-18 | DEC-OBS-P2-110 | v2 | Compact development log digest at session start | 5-trace digest orients new sessions on recent activity |
| 2026-02-18 | DEC-COMMUNITY-003 | v2 | Rate-limit community-check to 1-hour TTL | Prevents redundant API calls during rapid session cycling |
| 2026-02-18 | DEC-V2-005 | v2 | Structured session context in Guardian commits | Event log summary injected for richer commit messages |
| 2026-02-19 | DEC-V3-001 | v3-hardening | Diagnostic-first approach for auto-verify repair | Unknown root cause requires evidence before fix |
| 2026-02-19 | DEC-V3-002 | v3-hardening | Convert guard.sh rewrite() to deny() | updatedInput not supported in PreToolUse (upstream #26506) |
| 2026-02-19 | DEC-V3-003 | v3-hardening | Adapt proof chain tests to current architecture | Tester owns proof now, not implementer |
| 2026-02-19 | DEC-V3-004 | v3-hardening | Source source-lib.sh in test subshell for crash detection | context-lib.sh depends on log.sh which source-lib.sh bootstraps |
| 2026-02-19 | DEC-V3-005 | v3-hardening | Mechanical refactoring for shared library consolidation | Zero behavioral change, port robust implementations |
| 2026-02-19 | DEC-PLAN-001 | plan-redesign | Living document format with initiative-scoped phases | Plan persists across initiatives as evolving project record |
| 2026-02-19 | DEC-PLAN-002 | plan-redesign | Planner supports both create and amend workflows | Detect existing plan and add initiative vs. overwrite |
| 2026-02-19 | DEC-PLAN-003 | plan-redesign | Initiative-level lifecycle replaces document-level | PLAN_LIFECYCLE: none/active/dormant based on active initiatives |
| 2026-02-19 | DEC-PLAN-004 | plan-redesign | Tiered session injection with bounded extraction | Identity + Active Initiatives + Recent Decisions, capped ~200 lines |
| 2026-02-19 | DEC-PLAN-005 | plan-redesign | Manual migration via planner transform | One-time transform, no migration script maintenance |
| 2026-02-19 | DEC-PLAN-006 | plan-redesign | Deprecate archive_plan(), add compress_initiative() | Keep backward compat, new function compresses within plan |

---

## Active Initiatives

### Initiative: v3 Hardening and Reliability
**Status:** active
**Started:** 2026-02-19
**Goal:** Make the existing enforcement layer bulletproof — no new features, just reliability

> v2 built the governance + observability infrastructure. It works — 140/141 tests pass,
> all 6 phases completed. But production reveals reliability gaps: auto-verify never fires
> (dead fast path), the proof-of-work chain has untested links, guard.sh carries dead
> rewrite() code, and the shared library has accumulated duplication across 14 hooks.
> v3 hardens the existing system. No new features — just making what exists bulletproof.

**Dominant Constraint:** reliability (every enforcement gap is a bypass risk)

#### Goals
- REQ-GOAL-001: Auto-verify fast path fires in production when tester signals High confidence
- REQ-GOAL-002: Proof-of-work chain is fully tested with contract tests covering all enforcement points
- REQ-GOAL-003: All hook shared code flows through context-lib.sh (single source of truth)
- REQ-GOAL-004: Test suite reaches 0 failures on main (currently 1 failure)

#### Non-Goals
- REQ-NOGO-001: Multi-instance plan file scoping (#115) — deferred, separate initiative
- REQ-NOGO-002: Hook status visualization (#94) — enhancement, not hardening
- REQ-NOGO-003: New features or capabilities — this initiative fixes what exists
- REQ-NOGO-004: todo.sh refactoring (#57/#58/#69) — separate initiative
- REQ-NOGO-005: Release process or branch protection (#67/#61) — separate initiative

#### Requirements

**Must-Have (P0)**

- REQ-P0-001: Auto-verify signal extraction works in check-tester.sh.
  Acceptance: Given tester response contains "AUTOVERIFY: CLEAN", When check-tester.sh
  runs, Then .proof-status is set to "verified" and AUTO-VERIFIED is emitted.

- REQ-P0-002: Diagnostic logging in check-tester.sh reveals payload structure.
  Acceptance: check-tester.sh logs RESPONSE_TEXT length and AUTOVERIFY grep result to stderr.

- REQ-P0-003: Guardian session context data flow validated end-to-end (#121).
  Acceptance: Test proves event log -> get_session_summary_context() -> subagent-start.sh
  injection -> Guardian startup context with correct trajectory stats.

- REQ-P0-004: v2 lifecycle integration test covers full 10-stage arc (#122).
  Acceptance: INTENT-06 in test-v2-e2e.sh exercises session_start through cross-session
  context with 10 sequential assertions completing in under 10 seconds.

- REQ-P0-005: session-summary.sh includes proof status in stop output (#42 residual).
  Acceptance: When .proof-status exists, session summary GIT_LINE includes "Proof: verified."
  or "Proof: PENDING." or "Proof: not started."

- REQ-P0-006: subagent-start.sh injects current proof status for implementer (#42 residual).
  Acceptance: When implementer spawns, context includes proof status (verified/pending/missing)
  with appropriate guidance text.

- REQ-P0-007: Contract test script test-proof-chain.sh covers full enforcement chain (#43).
  Acceptance: 18 test cases covering guard.sh Check 8, track.sh invalidation,
  session-init.sh clearing, and meta-repo exemptions. All tests pass in isolated temp dir.

- REQ-P0-008: HOOKS.md session-init.sh description mentions proof clearing (#44 residual).
  Acceptance: HOOKS.md line for session-init.sh includes "Clears stale .proof-status" language.

- REQ-P0-009: Test suite has 0 failures on main.
  Acceptance: tests/run-hooks.sh reports 0 failed. Crash detection test sources source-lib.sh.

- REQ-P0-010: guard.sh has no remaining dead rewrite() calls (#92 final sweep).
  Acceptance: grep -c 'rewrite ' hooks/guard.sh returns 0. All converted to deny().

**Nice-to-Have (P1)**

- REQ-P1-001: Shared library consolidation — session lookup unified in context-lib.sh (#7).
- REQ-P1-002: compact-preserve.sh sources context-lib.sh instead of reimplementing (#7).
- REQ-P1-003: Raw jq calls converted to get_field() across 9 hooks (#7).
- REQ-P1-004: Self-audit harness consistency checks (#35) — evaluate /uplevel extension.
- REQ-P1-005: Markdown link verification in agent-written files (#93).

**Future Consideration (P2)**

- REQ-P2-001: Hook status visualization with statusline (#94).
- REQ-P2-002: Checkpoint frequency auto-tuning.
- REQ-P2-003: Cross-session friction pattern detection.

#### Definition of Done

All P0 requirements satisfied. Test suite at 0 failures. Auto-verify fires in production
on next clean tester run. Proof chain fully tested. Issues #41-44 closeable based on
evidence. Each phase independently valuable and mergeable.

#### Architectural Decisions

- DEC-V3-001: Diagnostic-first approach for auto-verify repair.
  Addresses: REQ-P0-001, REQ-P0-002.
  Rationale: Auto-verify has never fired in production despite correct tester output.
  The root cause is unknown — could be payload truncation, wrong field name, or empty
  response text. Add diagnostic logging first to capture the actual payload structure,
  then fix based on evidence. Avoids speculative rewrites.

- DEC-V3-002: Convert remaining guard.sh rewrite() to deny() with suggested command.
  Addresses: REQ-P0-010.
  Rationale: updatedInput is not supported in PreToolUse hooks (upstream claude-code#26506).
  All rewrite() calls silently fail. The deny() approach forces the model to resubmit
  with the corrected command. UX cost is acceptable since upstream fix timeline is unknown.

- DEC-V3-003: Proof chain architecture has evolved — adapt #41-44 to current design.
  Addresses: REQ-P0-005, REQ-P0-006, REQ-P0-007, REQ-P0-008.
  Rationale: The original #41-44 plan assumed check-implementer.sh owned proof verification
  (Check 5). This was replaced by DEC-IMPL-STOP-001 which moved proof to the tester agent.
  The contract tests (#43) must be rewritten to reflect the current architecture: guard.sh
  Check 8 + Check 9 + Check 10, track.sh invalidation, task-track.sh Gate C, session-init.sh
  clearing. check-implementer.sh proof tests are no longer applicable.

- DEC-V3-004: Fix test crash detection by sourcing source-lib.sh in test subshell.
  Addresses: REQ-P0-009.
  Rationale: Test 6 in run-hooks.sh sources context-lib.sh directly but context-lib.sh
  calls get_claude_dir() which is defined in log.sh. The fix is to source source-lib.sh
  (which bootstraps log.sh + context-lib.sh) instead of sourcing context-lib.sh alone.

- DEC-V3-005: Mechanical refactoring with zero behavioral change for shared library.
  Addresses: REQ-P1-001, REQ-P1-002, REQ-P1-003.
  Rationale: All changes are structural (function calls replace inline code). No logic changes.
  The shared library version of get_session_changes() is the weakest implementation — the
  inline copies in compact-preserve.sh and surface.sh have glob fallback and legacy support
  that the shared version lacks. Port the robust version into context-lib.sh, then replace.

#### Phase 6: Auto-Verify Pipeline Repair
**Status:** planned
**Decision IDs:** DEC-V3-001, DEC-V3-004
**Requirements:** REQ-P0-001, REQ-P0-002, REQ-P0-003, REQ-P0-004, REQ-P0-009
**Issues:** #129, #121, #122, #125, #130, #131, #132, #133
**Definition of Done:**
- REQ-P0-001 satisfied: Auto-verify fires when tester signals AUTOVERIFY: CLEAN
- REQ-P0-002 satisfied: check-tester.sh diagnostic logging captures payload structure
- REQ-P0-003 satisfied: Guardian session context data flow validated by test
- REQ-P0-004 satisfied: INTENT-06 lifecycle test passes with 10 assertions
- REQ-P0-009 satisfied: Test suite reports 0 failures (crash detection test fixed)

##### Planned Decisions
- DEC-V3-001: Diagnostic-first for auto-verify — add logging, observe payload, fix extraction — Addresses: REQ-P0-001, REQ-P0-002
- DEC-V3-004: Source source-lib.sh in test subshell to fix crash detection — Addresses: REQ-P0-009

##### Work Items

**W6-1: Add diagnostic logging to check-tester.sh (#129)**
- check-tester.sh line 91 extracts RESPONSE_TEXT from `.last_assistant_message // .response`.
  The field may be truncated, empty, or use a different name.
- Add stderr logging: payload keys, RESPONSE_TEXT length, AUTOVERIFY grep result,
  secondary validation pass/fail details.
- Trigger: log on every SubagentStop:tester invocation so next tester run reveals the issue.

**W6-2: Fix auto-verify signal extraction based on diagnostics (#129)**
- After W6-1 logging reveals the payload structure, fix the extraction logic.
- Likely fix: field name mismatch, truncation handling, or multi-line grep.
- Must also verify secondary validation (confidence, coverage, caveats checks) works.

**W6-3: Guardian session context data flow test (#121)**
- Extend tests/test-session-context.sh with 2 new tests:
  1. Guardian injection path — source subagent-start.sh logic, verify SESSION_SUMMARY non-empty
  2. Stats accuracy — verify trajectory fields match known synthetic input (precise counts)

**W6-4: v2 lifecycle integration test INTENT-06 (#122)**
- Extend tests/test-v2-e2e.sh with 1 new intent test covering 10-stage lifecycle arc:
  session_start -> agent_start -> writes -> test_fail -> pivot detection ->
  checkpoint -> test_pass -> session_summary -> archive -> cross-session context.

**W6-5: Fix crash detection test failure**
- Test 6 in run-hooks.sh sources context-lib.sh directly. context-lib.sh calls
  get_claude_dir() from log.sh. Fix: source source-lib.sh instead.
- Also: commit the doc-freshness.sh chmod fix (#125) as part of this phase.

##### Critical Files
- `hooks/check-tester.sh` — Auto-verify extraction (lines 89-159), diagnostic logging
- `tests/run-hooks.sh` — Test 6 crash detection (lines 1515-1537)
- `tests/test-session-context.sh` — Guardian injection tests
- `tests/test-v2-e2e.sh` — Lifecycle integration test INTENT-06

##### Decision Log
<!-- Guardian appends here after phase completion -->


#### Phase 7: Proof-of-Work Chain Completion
**Status:** planned
**Decision IDs:** DEC-V3-003
**Requirements:** REQ-P0-005, REQ-P0-006, REQ-P0-007, REQ-P0-008, REQ-P0-010
**Issues:** #41, #42, #43, #44, #92, #134, #135, #136
**Definition of Done:**
- REQ-P0-005 satisfied: session-summary.sh reports proof status
- REQ-P0-006 satisfied: subagent-start.sh injects proof status for implementer
- REQ-P0-007 satisfied: test-proof-chain.sh passes all test cases
- REQ-P0-008 satisfied: HOOKS.md session-init.sh description mentions proof clearing
- REQ-P0-010 satisfied: guard.sh has 0 rewrite() calls remaining

##### Planned Decisions
- DEC-V3-003: Adapt #41-44 to current architecture (tester owns proof, not implementer) — Addresses: REQ-P0-005, REQ-P0-006, REQ-P0-007, REQ-P0-008

##### Work Items

**W7-1: Add proof status to session-summary.sh (#42 residual)**
- After the GIT_LINE test status block (line 137), add proof status:
  Read .proof-status file. Append "Proof: verified." / "Proof: PENDING." / "Proof: not started."
- 5 lines of code.

**W7-2: Add proof status injection to subagent-start.sh (#42 residual)**
- Under the `implementer)` case, after the existing proof-status instruction (line 103):
  Read .proof-status and inject current status with contextual guidance.
  - verified: "Proof: verified -- user confirmed feature works."
  - pending: "WARNING: Proof PENDING -- source changed after last verification."
  - missing: "Proof: not started -- Phase 4 is REQUIRED before commit."
- 10 lines of code.

**W7-3: Write test-proof-chain.sh contract tests (#43, adapted)**
- Adapted from original 18-test plan. Revised for current architecture:
  - guard.sh Check 8: deny commit without verified (4 tests: no-file, pending, verified, meta-repo)
  - guard.sh Check 9: deny Bash writes to .proof-status (2 tests: block write, allow non-write)
  - guard.sh Check 10: deny deletion of active .proof-status (2 tests: block pending delete, allow verified delete)
  - track.sh invalidation: verified->pending on source change (4 tests: source/test/doc/already-pending)
  - task-track.sh Gate C: Guardian requires verified when file exists (3 tests: verified/pending/missing)
  - session-init.sh clearing: stale .proof-status cleaned at start (2 tests: cleaned/no-error)
  - session-summary.sh proof reporting (1 test: proof line present)
- Total: 18 tests in isolated temp git repo. TAP-compatible output.

**W7-4: Update HOOKS.md documentation (#44 residual)**
- session-init.sh description: add "Clears stale .proof-status (crash recovery)"
- Verify all other HOOKS.md proof-related documentation is accurate (spot-check done in
  planning phase — .proof-status state file row, check-implementer.sh description,
  guard.sh Checks 8-10 documentation all accurate).

**W7-5: Final guard.sh rewrite() audit (#92)**
- Grep for remaining rewrite() calls. #98 converted Check 1 (/tmp) and Check 3 (--force).
- Verify Check 0.5 (CWD recovery) and Check 5/5b (worktree deletion) are also converted.
- Confirm 0 rewrite() calls remain. Close #92.

##### #41-44 Disposition

Based on comprehensive codebase audit (2026-02-19):

**#41 — Phase 1: Audit proof-of-work chain links**
- guard.sh Check 8: DONE and working (worktree fallback, meta-repo exemption, commit+merge).
- check-implementer.sh Check 5: ARCHITECTURE CHANGED. DEC-IMPL-STOP-001 moved proof to
  tester agent. check-implementer.sh has no proof check by design (builder/judge separation).
- track.sh invalidation: DONE and working (verified->pending on source, skips tests/docs).
- HOOKS.md discrepancy: DONE. Accurately reflects advisory-only + tester-moved proof.
- **Remaining**: Contract tests (acceptance criteria never written). Addressed by W7-3.
- **Close when**: W7-3 test-proof-chain.sh passes.

**#42 — Phase 2: Fill session lifecycle gaps for proof status**
- session-init.sh proof clearing: DONE (lines 355-368, crash recovery path).
- session-summary.sh proof reporting: NOT DONE. Addressed by W7-1.
- subagent-start.sh proof injection: PARTIALLY DONE (tells implementer not to write,
  but doesn't inject current status). Addressed by W7-2.
- **Close when**: W7-1 and W7-2 merged plus W7-3 covers session lifecycle tests.

**#43 — Phase 3: Contract test for proof-of-work chain**
- test-proof-chain.sh: NOT DONE. File does not exist.
- Original 18-test plan needs adaptation (no check-implementer.sh proof tests,
  add Check 9/10 and task-track.sh Gate C tests). Addressed by W7-3.
- **Close when**: W7-3 merged with all 18 tests passing.

**#44 — Phase 4: Documentation and HOOKS.md accuracy**
- HOOKS.md check-implementer.sh: DONE. Accurately says "Advisory only...moved to tester."
- HOOKS.md .proof-status state file: DONE. Complete lifecycle documented.
- HOOKS.md session-init.sh proof clearing: NOT DONE. Addressed by W7-4.
- CLAUDE.md Sacred Practice #10: DONE. Accurate.
- CLAUDE.md pre-dispatch gate: DONE. task-track.sh Gate C is blocking (deny).
- **Close when**: W7-4 merged.

##### Critical Files
- `hooks/session-summary.sh` — Proof status addition (after line 137)
- `hooks/subagent-start.sh` — Proof injection for implementer (after line 103)
- `hooks/guard.sh` — rewrite() audit, Checks 8-10
- `hooks/task-track.sh` — Gate C (Guardian proof requirement)
- `tests/test-proof-chain.sh` — New file: 18 contract tests
- `hooks/HOOKS.md` — session-init.sh description update

##### Decision Log
<!-- Guardian appends here after phase completion -->


#### Phase 8: Shared Library Consolidation
**Status:** planned
**Decision IDs:** DEC-V3-005
**Requirements:** REQ-P1-001, REQ-P1-002, REQ-P1-003
**Issues:** #7, #137
**Definition of Done:**
- Session file lookup consolidated into context-lib.sh (one implementation, 4 callers)
- compact-preserve.sh sources context-lib.sh (no inline reimplementation)
- 9 hooks converted from raw jq to get_field()
- All existing tests continue to pass

##### Planned Decisions
- DEC-V3-005: Mechanical refactoring with zero behavioral change — Addresses: REQ-P1-001, REQ-P1-002, REQ-P1-003
  Rationale: All changes are structural (function calls replace inline code). No logic changes.
  The shared library version of get_session_changes() is the weakest implementation — the
  inline copies in compact-preserve.sh and surface.sh have glob fallback and legacy support
  that the shared version lacks. Port the robust version into context-lib.sh, then replace
  all inline copies.

##### Work Items

**W8-1: Port robust session lookup into context-lib.sh**
- compact-preserve.sh (lines 43-56) has the most robust implementation: glob fallback + legacy
  .session-decisions support. Port this into get_session_changes() in context-lib.sh.
- Replace inline implementations in: compact-preserve.sh, surface.sh, session-summary.sh.

**W8-2: Refactor compact-preserve.sh to source context-lib.sh**
- compact-preserve.sh is the only hook that reimplements context-lib equivalent operations.
- Replace 3 inline blocks with: get_git_state(), get_plan_status(), get_session_changes().
- Keep COMMIT_COUNT as a one-liner supplement (not in shared lib).

**W8-3: Convert raw jq to get_field() across 9 hooks**
- Affected: code-review.sh, plan-validate.sh, test-runner.sh, plan-check.sh (partially),
  notify.sh, forward-motion.sh, subagent-start.sh, surface.sh, session-summary.sh,
  prompt-submit.sh.
- Mechanical: `echo "$HOOK_INPUT" | jq -r '.field'` becomes `get_field "field"`.

**W8-4: Fix context-lib.sh permissions**
- chmod 755 (currently 644). All other .sh files are 755. Sourced not executed, but inconsistent.

**W8-5: Fix session-summary.sh SOURCE_EXTENSIONS hardcode**
- Line 64 hardcodes the extension list. context-lib.sh exports $SOURCE_EXTENSIONS.
- Replace hardcoded string with variable reference.

##### Critical Files
- `hooks/context-lib.sh` — get_session_changes() upgrade, SOURCE_EXTENSIONS export
- `hooks/compact-preserve.sh` — Refactor to source context-lib.sh
- `hooks/surface.sh` — Replace inline session lookup
- `hooks/log.sh` — get_field() function (already exists, just need consumers)

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### v3 Worktree Strategy

Main is sacred. Each phase works in its own worktree:
- **Phase 6:** `~/.claude/.worktrees/v3-auto-verify` on branch `fix/auto-verify-pipeline`
- **Phase 7:** `~/.claude/.worktrees/v3-proof-chain` on branch `fix/proof-chain-completion`
- **Phase 8:** `~/.claude/.worktrees/v3-shared-lib` on branch `refactor/shared-library`

Implementation order: Phase 6 first (auto-verify is the highest-impact reliability gap),
then Phase 7 (proof chain depends on understanding payload structure from Phase 6 diagnostics),
then Phase 8 (pure refactoring, no behavioral change, lowest risk).

#### v3 References

##### State Files
| File | Scope | Written By | Read By |
|------|-------|-----------|---------|
| `.proof-status` | Cross-session | task-track.sh (creates), tester (writes pending), prompt-submit.sh/check-tester.sh (writes verified), track.sh (invalidates) | guard.sh, task-track.sh, session-init.sh, session-summary.sh (planned), subagent-start.sh (planned) |
| `.session-events.jsonl` | Session | track.sh, guard.sh, checkpoint.sh | context-lib.sh, session-summary.sh |
| `.test-status` | Cross-session | test-runner.sh | guard.sh, test-gate.sh, session-summary.sh, check-implementer.sh, check-guardian.sh, subagent-start.sh |

##### Issue Cross-Reference
| Issue | Plan Item | Disposition |
|-------|-----------|-------------|
| #129 | W6-1, W6-2 | Auto-verify signal extraction fix |
| #130 | W6-1, W6-2 | Phase 6 tracking issue for auto-verify |
| #131 | W6-5 | Test suite fix + doc-freshness chmod |
| #132 | W6-3 | Guardian session context data flow test |
| #133 | W6-4 | v2 lifecycle integration test INTENT-06 |
| #125 | W6-5 | doc-freshness.sh chmod (already done, needs commit) |
| #121 | W6-3 | Guardian session context data flow test (original) |
| #122 | W6-4 | v2 lifecycle integration test INTENT-06 (original) |
| #134 | W7-1, W7-2 | Session lifecycle proof gaps |
| #135 | W7-3 | Contract test test-proof-chain.sh |
| #136 | W7-4, W7-5 | HOOKS.md accuracy + guard.sh rewrite sweep |
| #137 | W8-1 through W8-5 | Shared library consolidation |
| #41 | W7-3 | Proof chain audit — mostly done, needs contract tests |
| #42 | W7-1, W7-2 | Session lifecycle proof gaps — 2 items remaining |
| #43 | W7-3 | Contract test script — adapted for current architecture |
| #44 | W7-4 | HOOKS.md accuracy — 1 item remaining |
| #92 | W7-5 | guard.sh rewrite() final sweep |
| #7 | W8-1 through W8-5 | Shared library consolidation (original) |

---

### Initiative: MASTER_PLAN Redesign
**Status:** active
**Started:** 2026-02-19
**Goal:** Transform MASTER_PLAN.md from disposable task tracker to living project record (#138, #115)

> MASTER_PLAN.md was designed as a disposable task tracker that gets archived and replaced
> for each initiative. This destroys project decision history, architectural context, and
> completed-initiative records. The plan should be a living document that evolves across
> many initiatives, preserving the project's identity and accumulated wisdom. The
> archive-and-replace cycle also creates race conditions when multiple Claude instances
> work on the same project (#115).

**Dominant Constraint:** maintainability (format must be parseable by grep-based hooks, readable by agents and humans)

#### Goals
- REQ-GOAL-001: MASTER_PLAN.md persists across initiatives as a living project record
- REQ-GOAL-002: Active initiatives preserve full phase/issue tracking (current epic capability)
- REQ-GOAL-003: Completed initiatives compress to ~5 lines but preserve decision references
- REQ-GOAL-004: Session context injection stays bounded (~200 lines) regardless of plan age
- REQ-GOAL-005: Hook enforcement operates at initiative level, not document level

#### Non-Goals
- REQ-NOGO-001: Project-scoped plan files (MASTER_PLAN-slug.md) — solved by living format instead
- REQ-NOGO-002: Changing worktree strategy — worktrees still scope to phases within initiatives
- REQ-NOGO-003: Automated migration tool — one manual migration is sufficient
- REQ-NOGO-004: Touching v3 hardening work items (phases 6-8) — preserved as-is, just restructured

#### Requirements

**Must-Have (P0)**

- REQ-P0-001: New MASTER_PLAN.md format spec with Identity, Architecture, Principles,
  Decision Log, Active Initiatives, Completed Initiatives sections.
  Acceptance: Given a new plan, When planner writes it, Then it has all required sections.

- REQ-P0-002: planner.md supports amend workflow (add initiative, close initiative).
  Acceptance: Given existing plan with new format, When planner is invoked, Then it adds
  a new initiative section rather than overwriting.

- REQ-P0-003: get_plan_status() in context-lib.sh understands initiative-level status.
  Acceptance: Given plan with 2 initiatives (1 active, 1 completed), When get_plan_status runs,
  Then PLAN_LIFECYCLE="active", PLAN_ACTIVE_INITIATIVES=1, phase counts reflect active only.

- REQ-P0-004: session-init.sh bounded injection from living plan.
  Acceptance: Given plan with 50 completed initiatives, When session starts, Then injected
  context is under 250 lines.

- REQ-P0-005: plan-check.sh enforcement based on active initiatives.
  Acceptance: Given plan with all v3 phases done but new initiative active, When source write
  attempted, Then write is ALLOWED (not blocked as "completed").

- REQ-P0-006: plan-validate.sh validates new section structure.
  Acceptance: Given plan in new format, When validated, Then initiative headers and phase
  status fields are checked; Identity and Architecture sections required.

- REQ-P0-007: Migration transforms current plan into new format.
  Acceptance: New format contains v3 as active initiative, v2 as completed initiative,
  all content preserved.

- REQ-P0-008: check-planner.sh validates initiative-aware structure.
  Acceptance: Given planner output, When checked, Then initiative headers validated.

- REQ-P0-009: prompt-submit.sh plan context injection is initiative-aware.
  Acceptance: Given user mentions "plan", When context injected, Then shows active initiative
  status, not raw phase counts.

- REQ-P0-010: CLAUDE.md Sacred Practice #6 and dispatch rules reference living plan model.
  Acceptance: Sacred Practice #6 mentions living plan. Planner dispatch docs mention amend.

**Nice-to-Have (P1)**

- REQ-P1-001: check-guardian.sh detects initiative completion (not just plan completion).
- REQ-P1-002: compact-preserve.sh preserves active initiative context.
- REQ-P1-003: subagent-start.sh architecture injection from new preamble format.
- REQ-P1-004: ARCHITECTURE.md updated with new plan lifecycle.
- REQ-P1-005: HOOKS.md updated with new hook behaviors.

**Future Consideration (P2)**

- REQ-P2-001: Initiative templates (standard sections for different types).
- REQ-P2-002: Cross-initiative decision conflict detection.
- REQ-P2-003: Auto-compression of initiatives older than N days.

#### Definition of Done

All P0 requirements satisfied. Migration complete (v3 active, v2 compressed). All 15+
affected hooks pass their tests. New plan format parseable by all hooks. Session injection
bounded under 250 lines. plan-check lifecycle gate allows work when active initiatives exist.

#### Architectural Decisions

- DEC-PLAN-001: Living document format with initiative-scoped phases.
  Addresses: REQ-P0-001, REQ-GOAL-001.
  Rationale: Plan has permanent layers (Identity, Architecture, Principles), evolving layers
  (Decision Log, Active Initiatives), and compressed history (Completed Initiatives).
  Initiatives contain phases which contain issues -- same structure as today, but scoped
  within the plan rather than being the whole document.

- DEC-PLAN-002: Planner supports both create and amend workflows.
  Addresses: REQ-P0-002, REQ-GOAL-001, REQ-GOAL-002.
  Rationale: When MASTER_PLAN.md exists with new structure, planner adds new initiative.
  When it does not exist, creates full document. Detection is automatic.

- DEC-PLAN-003: Initiative-level lifecycle replaces document-level lifecycle.
  Addresses: REQ-P0-003, REQ-P0-005, REQ-GOAL-005.
  Rationale: PLAN_LIFECYCLE becomes: 'none' (no plan), 'active' (has active initiatives),
  'dormant' (all initiatives completed, needs new initiative). The plan is never "completed."

- DEC-PLAN-004: Tiered session injection with bounded extraction.
  Addresses: REQ-P0-004, REQ-GOAL-004.
  Rationale: Extract Identity (~10 lines) + Active Initiatives (full detail) + Recent
  Decisions (last 5-10) + Completed Initiatives (one-liner list). Total under ~200 lines.

- DEC-PLAN-005: Manual migration via planner transform.
  Addresses: REQ-P0-007.
  Rationale: One-time migration for ~/.claude. Planner already produces new format.
  Other projects adopt naturally when their next initiative starts.

- DEC-PLAN-006: Deprecate archive_plan(), add compress_initiative().
  Addresses: REQ-GOAL-003.
  Rationale: Keep archive_plan() for backward compatibility. compress_initiative() moves
  initiative from Active to Completed within the same plan file.

#### Phase 1: Format Spec + Agent Update
**Status:** in-progress
**Decision IDs:** DEC-PLAN-001, DEC-PLAN-002, DEC-PLAN-005
**Requirements:** REQ-P0-001, REQ-P0-002, REQ-P0-007
**Issues:** #139
**Definition of Done:**
- REQ-P0-001 satisfied: New format spec documented and demonstrated by this plan itself
- REQ-P0-002 satisfied: planner.md updated with create-or-amend workflow
- REQ-P0-007 satisfied: Current v3 plan migrated into new format (this document)

##### Planned Decisions
- DEC-PLAN-001: Living document format — this plan IS the format spec — Addresses: REQ-P0-001
- DEC-PLAN-002: Planner create-or-amend — detect existing plan sections — Addresses: REQ-P0-002
- DEC-PLAN-005: Migration via planner transform — one-time transform of v3 plan — Addresses: REQ-P0-007

##### Work Items

**W1-1: Define new MASTER_PLAN.md format spec**
- Format defined by example: this document IS the spec.
- Sections: Identity, Architecture, Principles, Decision Log, Active Initiatives, Completed Initiatives.
- Initiative format: Status, Started, Goal, intent quote, Dominant Constraint, Goals, Non-Goals,
  Requirements, Definition of Done, Architectural Decisions, Phases, Worktree Strategy, References.
- Phase format within initiative: same as current (Status, Decision IDs, Requirements, Issues,
  Definition of Done, Planned Decisions, Work Items, Critical Files, Decision Log).
- Header levels: ## for top-level sections, ### for initiatives, #### for initiative sub-sections,
  ##### for phases within initiatives.

**W1-2: Rewrite planner.md to support create-or-amend workflow**
- Detect existing MASTER_PLAN.md with ## Identity section.
- If exists: add new ### Initiative section under ## Active Initiatives.
- If not: create full document with all required sections.
- Closing an initiative: move from Active to Completed, compress to ~5 lines.
- Preserve: Identity, Architecture, Principles, Decision Log (append only).

**W1-3: Perform migration of current v3 plan into new format**
- DONE: This document is the migrated result.
- v3 Hardening preserved as active initiative.
- v2 Governance compressed to completed initiative.
- Decision Log populated with all known decisions across v1/v2/v3.

##### Critical Files
- `agents/planner.md` — Create-or-amend workflow rewrite
- `MASTER_PLAN.md` — Format spec by example (this document)

##### Decision Log
- 2026-02-19: DEC-PLAN-005 executed — migration performed by planner, v3 content preserved faithfully.

#### Phase 2: Core Hook Updates
**Status:** planned
**Decision IDs:** DEC-PLAN-003, DEC-PLAN-004, DEC-PLAN-006
**Requirements:** REQ-P0-003, REQ-P0-004, REQ-P0-005, REQ-P0-006, REQ-P0-009
**Issues:** #140
**Definition of Done:**
- REQ-P0-003 satisfied: get_plan_status() returns initiative-level lifecycle
- REQ-P0-004 satisfied: session-init.sh injection bounded under 250 lines
- REQ-P0-005 satisfied: plan-check.sh allows writes when active initiative exists
- REQ-P0-006 satisfied: plan-validate.sh validates new structure without false errors
- REQ-P0-009 satisfied: prompt-submit.sh shows active initiative status

##### Planned Decisions
- DEC-PLAN-003: Initiative-level lifecycle (none/active/dormant) — Addresses: REQ-P0-003, REQ-P0-005
- DEC-PLAN-004: Tiered session injection with bounded extraction — Addresses: REQ-P0-004
- DEC-PLAN-006: compress_initiative() in context-lib.sh — Addresses: REQ-GOAL-003

##### Work Items

**W2-1: Rewrite get_plan_status() in context-lib.sh**
- New variables: PLAN_ACTIVE_INITIATIVES, PLAN_COMPLETED_INITIATIVES, PLAN_ACTIVE_INITIATIVE_NAMES.
- PLAN_LIFECYCLE: 'none' (no plan), 'active' (has ### Initiative with Status: active),
  'dormant' (plan exists, all initiatives completed/compressed).
- PLAN_TOTAL_PHASES, PLAN_COMPLETED_PHASES: count only within active initiatives.
- Keep backward-compatible variables for hooks that only check PLAN_EXISTS and PLAN_LIFECYCLE.
- Parse with grep: `### Initiative:` headers, `**Status:** active` within initiative blocks.

**W2-2: Update plan-check.sh lifecycle enforcement**
- Replace `PLAN_LIFECYCLE == "completed"` check with `PLAN_LIFECYCLE == "dormant"`.
- Deny message: "All initiatives are completed. Add a new initiative before implementing."
- Plan staleness: scope churn/drift to active initiatives only.

**W2-3: Update plan-validate.sh structural validation**
- Require: ## Identity, ## Architecture sections (not just original intent).
- Validate initiative headers: ### Initiative: with **Status:** field.
- Validate phases within initiatives (existing phase validation, scoped).
- Decision Log section must exist at top level.
- Keep backward compat: old format (no ## Identity) passes with warning, not error.

**W2-4: Update session-init.sh plan injection**
- Extract: ## Identity + ## Architecture (permanent, ~20 lines).
- Extract: Active initiatives with full detail (bounded by active count).
- Extract: Last 10 entries from Decision Log.
- Extract: Completed initiative names only (one-liner list).
- Total bounded at ~200 lines.
- Replace current preamble extraction (awk to --- or ## Original Intent).

**W2-5: Update prompt-submit.sh plan context**
- Show: "Plan: 1 active initiative (v3 Hardening) | 3/3 phases | 1 completed initiative"
- Replace raw phase counts with initiative-scoped summary.

**W2-6: Add compress_initiative() to context-lib.sh**
- Input: initiative name, project root.
- Action: Move initiative from ## Active Initiatives to ## Completed Initiatives.
- Compressed format: `| v3-hardening | 2026-02-19 | 2026-MM-DD | 3 phases, 10 P0s | DEC-V3-001..005 |`
- Keep archive_plan() for backward compat (projects using old format).

##### Critical Files
- `hooks/context-lib.sh` — get_plan_status() rewrite, compress_initiative()
- `hooks/plan-check.sh` — Lifecycle enforcement update
- `hooks/plan-validate.sh` — Structure validation rewrite
- `hooks/session-init.sh` — Plan injection rewrite
- `hooks/prompt-submit.sh` — Context injection update

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Phase 3: Secondary Hooks + Documentation
**Status:** planned
**Decision IDs:** DEC-PLAN-002
**Requirements:** REQ-P0-008, REQ-P0-010, REQ-P1-001, REQ-P1-002, REQ-P1-003, REQ-P1-004, REQ-P1-005
**Issues:** #141
**Definition of Done:**
- REQ-P0-008 satisfied: check-planner.sh validates initiative headers
- REQ-P0-010 satisfied: CLAUDE.md references living plan model
- All P1 requirements satisfied for secondary hooks and documentation

##### Planned Decisions
- DEC-PLAN-002: Planner create-or-amend — check-planner.sh validates this — Addresses: REQ-P0-008

##### Work Items

**W3-1: Update check-planner.sh validation**
- Check for ### Initiative headers (not just ## Phase headers).
- Check for ## Identity section (replacement for ## Project Overview check).
- Keep phase-within-initiative validation.

**W3-2: Update check-guardian.sh completion detection**
- Detect initiative completion (all phases in one initiative done) vs. plan completion.
- Replace "All plan phases completed" with "Initiative [name] completed — compress it."
- Trigger compress_initiative() suggestion.

**W3-3: Update compact-preserve.sh preamble extraction**
- Replace awk extraction of pre-`---` preamble with ## Identity + ## Architecture extraction.
- Preserve active initiative names for post-compaction context.

**W3-4: Update subagent-start.sh architecture injection**
- Replace `### Architecture` awk extraction with `## Architecture` extraction.
- Inject active initiative name into agent context line.

**W3-5: Update CLAUDE.md**
- Sacred Practice #6: "MASTER_PLAN.md is a living project record. It persists across
  initiatives. The Planner adds new initiatives; it does not replace the plan."
- Dispatch rules: Planner creates or amends the plan.
- Session Acclimation: Identity + Active Initiative injected at start.

**W3-6: Update ARCHITECTURE.md plan lifecycle**
- Document new plan format and initiative lifecycle.
- Update plan-check.sh documentation for dormant state.
- Update archive_plan() documentation with compress_initiative() alternative.

**W3-7: Update HOOKS.md**
- plan-check.sh: dormant vs completed lifecycle.
- plan-validate.sh: initiative-aware validation.
- session-init.sh: bounded injection from living plan.
- check-planner.sh: initiative header validation.
- check-guardian.sh: initiative completion detection.

##### Critical Files
- `hooks/check-planner.sh` — Initiative validation
- `hooks/check-guardian.sh` — Initiative completion
- `hooks/compact-preserve.sh` — Preamble extraction
- `hooks/subagent-start.sh` — Architecture injection
- `CLAUDE.md` — Sacred Practices, dispatch rules
- `ARCHITECTURE.md` — Plan lifecycle documentation
- `hooks/HOOKS.md` — Hook behavior documentation

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Phase 4: Test Suite + Validation
**Status:** planned
**Decision IDs:** DEC-PLAN-003
**Requirements:** All REQ-P0 validated
**Issues:** #142
**Definition of Done:**
- All existing tests pass (no regressions from format change)
- New tests validate initiative-level lifecycle detection
- New tests validate bounded session injection
- Full test suite green

##### Planned Decisions
- DEC-PLAN-003: Initiative-level lifecycle — validate none/active/dormant transitions — Addresses: REQ-P0-003, REQ-P0-005

##### Work Items

**W4-1: Update existing tests referencing plan structure**
- tests/run-hooks.sh: update any assertions about MASTER_PLAN.md format.
- Update plan-check test expectations for dormant vs completed.

**W4-2: Add initiative-level lifecycle tests**
- Test: plan with 1 active initiative -> PLAN_LIFECYCLE=active.
- Test: plan with 0 active initiatives -> PLAN_LIFECYCLE=dormant.
- Test: no plan -> PLAN_LIFECYCLE=none.
- Test: plan-check allows writes when active initiative exists.
- Test: plan-check blocks when dormant (all initiatives completed).

**W4-3: Add bounded session injection tests**
- Test: plan with 1 completed initiative -> injection under 50 lines.
- Test: synthetic plan with 50 completed initiatives -> injection under 250 lines.
- Test: active initiative content fully included.

**W4-4: Full test suite run**
- Run tests/run-hooks.sh and all test-*.sh scripts.
- Fix any regressions from format changes.

##### Critical Files
- `tests/run-hooks.sh` — Existing test suite
- `tests/test-plan-lifecycle.sh` — New: initiative lifecycle tests
- `tests/test-plan-injection.sh` — New: bounded injection tests

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Plan Redesign Worktree Strategy

Main is sacred. Each phase works in its own worktree:
- **Phase 1:** On main (format spec + migration is a planning artifact, exempt from branch guard)
- **Phase 2:** `~/.claude/.worktrees/plan-core-hooks` on branch `feature/plan-redesign-hooks`
- **Phase 3:** `~/.claude/.worktrees/plan-secondary` on branch `feature/plan-redesign-docs`
- **Phase 4:** `~/.claude/.worktrees/plan-tests` on branch `feature/plan-redesign-tests`

Implementation order: Phase 1 first (this document), then Phase 2 (hooks must match format),
then Phase 3 (secondary hooks + docs), then Phase 4 (tests validate everything).

---

## Completed Initiatives

| Initiative | Period | Phases | Key Decisions | Archived |
|-----------|--------|--------|---------------|----------|
| v2 Governance + Observability | 2026-02-18 to 2026-02-19 | 6 phases (0-5), all completed | DEC-GUARDIAN-001, DEC-PLANNER-STOP-001, DEC-OBS-P2-110, DEC-V2-005 | `archived-plans/2026-02-19_v2-governance-observability.md` |

**v2 Summary:** Fused observability into governance layer. Session event logs, named checkpoints,
cross-session learning, structured commit context, observatory pipeline, trace lifecycle
hardening. 6 phases, issues #81-84, #99-122. All completed.

---

## Parked Issues

Issues not belonging to any active initiative. Tracked for future consideration.

| Issue | Description | Reason Parked |
|-------|-------------|---------------|
| #94 | Hook status visualization | Enhancement, not hardening |
| #93 | Link verification | P1, after hardening |
| #35 | Self-audit harness | P1, after hardening |
| #97/#96/#95 | Upstream-blocked features | Blocked on claude-code upstream |
| #46/#22/#17/#8 | Separate initiatives | Different scope |
| #69/#67/#61/#57/#58 | todo.sh / standards | Separate initiatives |

---

## Worktree Strategy

Main is sacred. Work happens in isolated worktrees per initiative phase.
Active worktrees are listed under each initiative's Worktree Strategy section.
Stale worktrees to clean: feature/guard-fix, feature/v2-session-hooks (both merged, clean).
