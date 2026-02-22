# MASTER_PLAN: Claude Code Governance System

## Identity

**Type:** meta-infrastructure (hooks, agents, skills, commands)
**Languages:** bash (78%), markdown (15%), python (7%)
**Root:** /Users/turla/.claude
**Created:** 2026-02-18
**Last updated:** 2026-02-22

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
| 2026-02-21 | DEC-GOV-001 | state-governance | State file registry as structural gate | Declarative JSON registry with lint test catches unscoped writes at test time |
| 2026-02-21 | DEC-GOV-002 | state-governance | Multi-CWD test execution | Second pass with alternate CWD catches environment assumptions |
| 2026-02-21 | DEC-GOV-003 | state-governance | Observatory signal for cross-project state reads | Fits existing analyzer pipeline, surfaces contamination in reports |
| 2026-02-22 | DEC-PROOF-LIFE-001 | proof-lifecycle | New post-task.sh handler for PostToolUse:Task auto-verify | SubagentStop never fires; PostToolUse:Task is the reliable hook event for tester completion |
| 2026-02-22 | DEC-PROOF-LIFE-002 | proof-lifecycle | Read summary.md via tester breadcrumb instead of last_assistant_message | PostToolUse:Task lacks last_assistant_message; Trace Protocol guarantees summary.md is written before return |
| 2026-02-22 | DEC-PROOF-LIFE-003 | proof-lifecycle | Preserve SubagentStop hooks as dead code with deprecation annotation | SubagentStop may be fixed upstream; dedup guard (DEC-TESTER-006) prevents double auto-verify if both paths fire |

---

## Active Initiatives

### Initiative: v3 Hardening and Reliability
**Status:** completed
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
**Status:** completed
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
**Status:** completed
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
**Status:** completed
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
**Status:** completed
**Started:** 2026-02-19
**Completed:** 2026-02-20
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
**Status:** completed
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
**Status:** completed
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
**Status:** completed
**Decision IDs:** DEC-PLAN-003
**Requirements:** All REQ-P0 validated
**Issues:** #142
**Definition of Done:**
- All existing tests pass (no regressions from format change)
- New tests validate initiative-level lifecycle detection
- New tests validate bounded session injection
- Full test suite green (352 tests, 0 failures)

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
- 2026-02-20: DEC-PLAN-003 validated — 16 new tests across 2 suites confirm initiative lifecycle transitions and bounded injection. Bug fix: empty Active Initiatives section now correctly returns dormant.

#### Plan Redesign Worktree Strategy

Main is sacred. Each phase works in its own worktree:
- **Phase 1:** On main (format spec + migration is a planning artifact, exempt from branch guard)
- **Phase 2:** `~/.claude/.worktrees/plan-core-hooks` on branch `feature/plan-redesign-hooks`
- **Phase 3:** `~/.claude/.worktrees/plan-secondary` on branch `feature/plan-redesign-docs`
- **Phase 4:** `~/.claude/.worktrees/plan-tests` on branch `feature/plan-redesign-tests`

Implementation order: Phase 1 first (this document), then Phase 2 (hooks must match format),
then Phase 3 (secondary hooks + docs), then Phase 4 (tests validate everything).

---

### Initiative: State Governance & Isolation Hardening
**Status:** active
**Started:** 2026-02-21
**Goal:** Prevent cross-project state contamination structurally rather than reactively

> Cross-project state contamination was fixed reactively during v3 (project hash scoping via
> DEC-ISOLATION-001 through DEC-ISOLATION-007). The fixes work, but three structural gaps remain:
> no registry of state files to catch unscoped writes, tests that only run from ~/.claude CWD so
> environment assumptions go undetected, and no runtime signal when cross-project state is read.
> This initiative adds structural gates and runtime detection so future state file additions
> cannot regress isolation.

**Dominant Constraint:** reliability (every unregistered state file is a potential contamination vector)

#### Goals
- REQ-GOAL-001: Every state file write is registered and scoped (structural gate)
- REQ-GOAL-002: Tests catch CWD-dependent code paths that break in production
- REQ-GOAL-003: Runtime contamination is detectable without manual diagnosis

#### Non-Goals
- REQ-NOGO-001: Automatic remediation of contamination — detect, don't fix
- REQ-NOGO-002: Refactoring all state files to a new location — structural gate, not migration
- REQ-NOGO-003: Multi-instance locking (#115 scope) — different problem space

#### Requirements

**Must-Have (P0)**

- REQ-P0-001: State file registry (hooks/state-registry.json) declares every state file.
  Acceptance: Given a hook writes to CLAUDE_DIR or TRACE_STORE, When registry is checked,
  Then the target path pattern appears in state-registry.json with scope and writer fields.

- REQ-P0-002: Lint test catches unregistered state writes.
  Acceptance: Given a new hook writes `.foo-bar` to CLAUDE_DIR without registry entry,
  When test-state-registry.sh runs, Then it fails with the unregistered path identified.

- REQ-P0-003: State-writing tests execute from alternate CWD.
  Acceptance: Given run-hooks.sh completes its primary pass, When the isolation pass runs
  from /tmp/test-cwd-XXXX, Then state-writing tests produce identical results.

- REQ-P0-004: Isolation assertions verify project-scoped suffixes.
  Acceptance: Given a test writes .proof-status in alternate CWD, When the write completes,
  Then the file path contains the project hash suffix (not bare .proof-status).

- REQ-P0-005: Observatory analyzer detects cross-project state reads.
  Acceptance: Given trace data shows session reading .proof-status-{hashA} while
  PROJECT_ROOT hashes to hashB, When analyzer runs, Then a cross-project-contamination
  signal is emitted.

- REQ-P0-006: Cross-project signal surfaces in observatory reports.
  Acceptance: Given the analyzer found contamination signals, When observatory report
  generates, Then the signal appears in the findings section with project hashes and
  affected state files.

**Nice-to-Have (P1)**

- REQ-P1-001: Registry includes reader hooks (not just writers) for full dependency graph.
- REQ-P1-002: `state-registry.json` is validated by plan-validate.sh on planner runs.
- REQ-P1-003: Observatory signal includes remediation suggestion (which hash to clean).

**Future Consideration (P2)**

- REQ-P2-001: Auto-cleanup of orphaned state files from stale project hashes.
- REQ-P2-002: State file migration tool for hash scheme changes.

#### Definition of Done

All P0 requirements satisfied. State registry covers all existing state writes (10+ entries).
Lint test catches unregistered writes. Tests pass from both ~/.claude and alternate CWD.
Observatory analyzer detects and reports cross-project contamination. No regressions in
existing test suite.

#### Architectural Decisions

- DEC-GOV-001: State file registry as structural gate against unscoped writes.
  Addresses: REQ-GOAL-001, REQ-P0-001, REQ-P0-002.
  Rationale: A declarative JSON registry (hooks/state-registry.json) lists every state file
  with its scope (global/per-project/per-session), writer hook, and path pattern. A lint test
  greps all hook .sh files for writes to CLAUDE_DIR/TRACE_STORE and verifies each target
  appears in the registry. Zero runtime cost. New state files require explicit registration
  or the lint test fails.

- DEC-GOV-002: Multi-CWD test execution to catch environment assumptions.
  Addresses: REQ-GOAL-002, REQ-P0-003, REQ-P0-004.
  Rationale: Adding a second pass in run-hooks.sh that sets CWD to a temp directory (not
  ~/.claude) reuses existing test infrastructure. State-writing tests get isolation
  assertions that verify output paths use project-scoped suffixes. Catches CWD assumptions
  that only work when running from ~/.claude.

- DEC-GOV-003: Observatory signal for cross-project state reads.
  Addresses: REQ-GOAL-003, REQ-P0-005, REQ-P0-006.
  Rationale: An observatory analyzer pattern detects when a session reads state written by
  a different project hash. Fits the existing analyze pipeline. Surfaces in reports alongside
  other signals. No runtime overhead in hooks — analysis happens post-hoc on trace data.

#### Phase 1: State File Registry + Lint Test
**Status:** planned
**Decision IDs:** DEC-GOV-001
**Requirements:** REQ-P0-001, REQ-P0-002
**Issues:** #143
**Definition of Done:**
- REQ-P0-001 satisfied: state-registry.json exists with all current state file entries
- REQ-P0-002 satisfied: test-state-registry.sh fails on unregistered writes

##### Planned Decisions
- DEC-GOV-001: JSON registry with lint test — grep hook sources for state writes, cross-check against registry — Addresses: REQ-P0-001, REQ-P0-002

##### Work Items

**W1-1: Create hooks/state-registry.json**
- Declare every state file written by hooks to CLAUDE_DIR or TRACE_STORE.
- Fields per entry: `path_pattern` (glob, e.g. `.proof-status-*`), `scope` (global|per-project|per-session),
  `writer` (hook filename), `readers` (list of hook filenames), `description` (1-line purpose).
- Initial inventory from analysis.md: ~10 entries covering proof-status, active-worktree-path,
  guardian-start-sha, session-start-epoch, test-status, active-{type} markers, session index.
- Evidence base: grep for `> "${CLAUDE_DIR}`, `> "${TRACE_STORE}`, `> "$(get_claude_dir)` across all hooks.

**W1-2: Create tests/test-state-registry.sh**
- Grep all hooks/*.sh for patterns: `> "$CLAUDE_DIR/`, `> "${CLAUDE_DIR}/`, `> "$(get_claude_dir)/`,
  `> "$TRACE_STORE/`, `> "${TRACE_STORE}/`.
- Extract the target filename from each match.
- Cross-check each target against state-registry.json entries.
- TAP-compatible output. Fail on any unregistered write.
- Also validate: every registry entry has a matching write in hook source (no stale entries).

**W1-3: Integrate into run-hooks.sh**
- Add test-state-registry.sh to the test suite runner.
- Ensure it runs as part of the standard `bash tests/run-hooks.sh` invocation.

##### Critical Files
- `hooks/state-registry.json` — New: declarative state file registry
- `tests/test-state-registry.sh` — New: lint test for unregistered writes
- `tests/run-hooks.sh` — Integration of new test
- `hooks/track.sh` — State writes: .proof-status (lines 70-71)
- `hooks/prompt-submit.sh` — State writes: .proof-status, .session-start-epoch (lines 60, 153-154)
- `hooks/task-track.sh` — State writes: .active-worktree-path (line 195)
- `hooks/context-lib.sh` — State writes: .active-{type} markers (line 1107)

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Phase 2: Multi-Context Test Runner
**Status:** planned
**Decision IDs:** DEC-GOV-002
**Requirements:** REQ-P0-003, REQ-P0-004
**Issues:** #144
**Definition of Done:**
- REQ-P0-003 satisfied: State-writing tests pass from alternate CWD
- REQ-P0-004 satisfied: Isolation assertions verify project-scoped suffixes

##### Planned Decisions
- DEC-GOV-002: Second pass with alternate CWD in run-hooks.sh — Addresses: REQ-P0-003, REQ-P0-004

##### Work Items

**W2-1: Add isolation pass to run-hooks.sh**
- After the primary test pass completes, create a temp directory (`mktemp -d`).
- Re-run state-writing test suites (test-project-isolation.sh, test-proof-chain.sh,
  test-proof-gate.sh, test-state-registry.sh) with CWD set to the temp directory.
- Use `(cd "$TMPDIR" && bash "$SCRIPT_DIR/test-xxx.sh")` subshell pattern.
- Report pass/fail separately as "Isolation Pass" in TAP output.
- Clean up temp directory after.

**W2-2: Add isolation assertions to state-writing tests**
- In test-project-isolation.sh: after each state file write, assert the file path
  contains the project hash suffix (not bare filename).
- Pattern: `[[ "$written_path" == *"-${expected_hash}"* ]]` or equivalent.
- Cover: .proof-status-{hash}, .active-worktree-path-{hash}, .active-{type}-{session}-{hash}.
- Skip for legitimately global files (.session-start-epoch, .test-status).

**W2-3: Document CWD-independence requirement**
- Add a comment block to test infrastructure explaining that state-writing tests
  must not assume CWD == ~/.claude.
- Add to HOOKS.md under testing guidelines.

##### Critical Files
- `tests/run-hooks.sh` — Isolation pass addition
- `tests/test-project-isolation.sh` — Isolation assertions
- `tests/test-proof-chain.sh` — Isolation assertions
- `tests/test-proof-gate.sh` — Isolation assertions
- `hooks/HOOKS.md` — Testing guidelines

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Phase 3: Observatory Cross-Project Signal
**Status:** planned
**Decision IDs:** DEC-GOV-003
**Requirements:** REQ-P0-005, REQ-P0-006
**Issues:** #145
**Definition of Done:**
- REQ-P0-005 satisfied: Analyzer detects cross-project state reads in trace data
- REQ-P0-006 satisfied: Signal surfaces in observatory reports

##### Planned Decisions
- DEC-GOV-003: Observatory analyzer pattern for cross-project contamination — Addresses: REQ-P0-005, REQ-P0-006

##### Work Items

**W3-1: Add cross-project contamination analyzer**
- New analyzer function in observatory/analyze.sh (or new file observatory/analyzers/cross-project.sh).
- Input: trace manifests and session event logs.
- Detection logic: for each session, extract PROJECT_ROOT hash. Scan session events for
  state file reads. If any read targets a different project hash, emit signal.
- Signal format: `{ "type": "cross-project-contamination", "session": "...",
  "project_hash": "...", "contaminating_hash": "...", "state_file": "...", "severity": "high" }`

**W3-2: Integrate signal into observatory report**
- Add cross-project contamination to the findings section of observatory reports.
- Include: affected session, project hashes involved, state files read, timestamp.
- Severity: always "high" (contamination is never benign).

**W3-3: Add test for cross-project signal**
- Create synthetic trace data with cross-project state reads.
- Run analyzer. Assert signal is emitted with correct fields.
- Add to existing observatory test suite.

##### Critical Files
- `observatory/analyze.sh` — Analyzer integration point
- `observatory/analyzers/` — New analyzer (if separate file)
- `observatory/report.sh` — Report generation
- `tests/test-obs-pipeline.sh` — Observatory test suite

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### State Governance Worktree Strategy

Main is sacred. Each phase works in its own worktree:
- **Phase 1:** `~/.claude/.worktrees/gov-registry` on branch `feature/state-registry`
- **Phase 2:** `~/.claude/.worktrees/gov-multi-cwd` on branch `feature/multi-cwd-tests`
- **Phase 3:** `~/.claude/.worktrees/gov-observatory` on branch `feature/cross-project-signal`

Implementation order: Phase 1 first (registry is the structural foundation), then Phase 2
(tests use registry as reference), then Phase 3 (observatory signal is independent but benefits
from registry definitions).

#### State Governance References

##### State File Inventory
| State File | Scope | Writer | Readers |
|-----------|-------|--------|---------|
| .proof-status-{phash} | per-project | track.sh, prompt-submit.sh, check-tester.sh | guard.sh, task-track.sh, session-init.sh, session-summary.sh, subagent-start.sh |
| .proof-status | per-project (legacy) | track.sh, prompt-submit.sh | guard.sh (fallback) |
| .session-start-epoch | per-session | prompt-submit.sh | session-summary.sh |
| .active-worktree-path-{phash} | per-project | task-track.sh | task-track.sh, subagent-start.sh |
| .guardian-start-sha | per-session | subagent-start.sh | check-guardian.sh |
| .test-status | per-session | test-runner.sh | guard.sh, session-summary.sh, check-implementer.sh |
| TRACE_STORE/.active-{type}-{session}-{phash} | per-project | context-lib.sh | context-lib.sh, compact-preserve.sh, session-end.sh |
| sessions/{hash}/index.jsonl | per-project | session-end.sh, context-lib.sh | context-lib.sh, session-init.sh |
| .session-events.jsonl | per-session | track.sh, guard.sh, checkpoint.sh | context-lib.sh, session-summary.sh |

##### Related Issues
| Issue | Relation |
|-------|----------|
| #115 | Multi-instance plan file scoping (different problem, same isolation domain) |
| DEC-ISOLATION-001..007 | Prior reactive fixes for cross-project contamination |

---

### Initiative: Proof-Status Lifecycle Hardening
**Status:** active
**Started:** 2026-02-22
**Goal:** Migrate auto-verify from dead SubagentStop hook to PostToolUse:Task so it fires in production

> Auto-verify is the fast path that bypasses manual user approval when the tester produces a
> clean verification (AUTOVERIFY: CLEAN with High confidence). It was built into check-tester.sh
> (SubagentStop:tester) but SubagentStop hooks never fire in Claude Code (confirmed by
> DEC-CACHE-003 for SubagentStart; SubagentStop has the same issue, confirmed by production
> observation on 2026-02-21). Every clean tester verification requires manual user approval,
> adding friction to the proof-before-commit workflow. This initiative migrates the auto-verify
> logic to PostToolUse:Task, which fires reliably.

**Dominant Constraint:** reliability (auto-verify is a critical fast path; if it doesn't fire, the proof gate adds friction without reducing risk)

#### Goals
- REQ-GOAL-001: Auto-verify fires in production when tester produces AUTOVERIFY: CLEAN with High confidence
- REQ-GOAL-002: No regression in proof-status invalidation for non-Guardian writes
- REQ-GOAL-003: Dead SubagentStop code documented as deprecated, not removed (upstream may fix)

#### Non-Goals
- REQ-NOGO-001: Removing SubagentStop hooks from settings.json — leave as dead code, upstream may fix
- REQ-NOGO-002: Refactoring check-tester.sh Phase 2 (advisory/completeness) logic — only Phase 1 auto-verify migrates
- REQ-NOGO-003: Merging with State Governance initiative — different subsystem, different concern
- REQ-NOGO-004: Fixing upstream SubagentStop event (#96/updatedInput) — blocked upstream

#### Requirements

**Must-Have (P0)**

- REQ-P0-001: PostToolUse:Task handler detects tester completion and runs auto-verify.
  Acceptance: Given tester task returns, When post-task.sh fires, Then it detects subagent_type=tester
  and reads the tester's summary.md from the active trace directory.

- REQ-P0-002: Auto-verify writes .proof-status=verified when secondary validation passes.
  Acceptance: Given summary.md contains "AUTOVERIFY: CLEAN" and "**High**" confidence with no
  "Partially verified" or non-environmental "Not tested", When post-task.sh validates, Then
  .proof-status is set to "verified" with dual-write to orchestrator's scoped and legacy copies.

- REQ-P0-003: AUTO-VERIFIED directive emitted in additionalContext for orchestrator.
  Acceptance: Given auto-verify succeeds, When post-task.sh exits, Then JSON output contains
  additionalContext with "AUTO-VERIFIED" and Guardian dispatch instruction.

- REQ-P0-004: check-tester.sh Phase 1 annotated as deprecated with pointer to post-task.sh.
  Acceptance: Given check-tester.sh auto-verify block (lines 89-285), When read, Then @deprecated
  annotation explains PostToolUse:Task is the live path and this code is retained for upstream fix.

- REQ-P0-005: PostToolUse:Task handler registered in settings.json.
  Acceptance: Given settings.json, When inspected, Then PostToolUse section has a Task matcher
  entry pointing to hooks/post-task.sh with timeout 15.

- REQ-P0-006: Test suite validates PostToolUse:Task auto-verify end-to-end.
  Acceptance: Given synthetic tester trace with AUTOVERIFY: CLEAN in summary.md, When post-task.sh
  runs with mock environment, Then .proof-status transitions to "verified" and JSON output
  contains AUTO-VERIFIED.

**Nice-to-Have (P1)**

- REQ-P1-001: PostToolUse:Task also handles non-tester agents (implementer finalize_trace).
- REQ-P1-002: Diagnostic logging in post-task.sh for debugging (subagent type, trace ID, validation steps).

**Future Consideration (P2)**

- REQ-P2-001: Consolidate all SubagentStop handlers into PostToolUse:Task when upstream confirms SubagentStop is abandoned.
- REQ-P2-002: Auto-resume incomplete testers from PostToolUse:Task (currently in check-tester.sh Phase 2).

#### Definition of Done

Auto-verify fires in production on the next clean tester run. proof-status transitions from
needs-verification/pending to verified without manual user approval. PostToolUse:Task handler
registered and tested. check-tester.sh deprecated annotation added. cc-todos#49 closed (already
fixed). Issue #147 resolved.

#### Architectural Decisions

- DEC-PROOF-LIFE-001: New post-task.sh handler for PostToolUse:Task auto-verify.
  Addresses: REQ-P0-001, REQ-P0-002, REQ-P0-003, REQ-P0-005.
  Rationale: PostToolUse:Task fires reliably (unlike SubagentStop). A dedicated handler keeps
  tester-specific verification logic separate from task-track.sh dispatch gating. The handler
  reads summary.md from the tester's trace directory (since PostToolUse doesn't receive
  last_assistant_message) and runs the same secondary validation as check-tester.sh Phase 1.
  Alternatives considered: extending task-track.sh for both Pre and Post (rejected — mixes
  dispatch gating with verification in an already 200-line file with different payload structure).

- DEC-PROOF-LIFE-002: Read summary.md via tester breadcrumb instead of last_assistant_message.
  Addresses: REQ-P0-001, REQ-P0-003.
  Rationale: PostToolUse:Task does not provide last_assistant_message in its payload. The tester's
  AUTOVERIFY signal is written to TRACE_DIR/summary.md per the Trace Protocol. The handler detects
  the active tester trace via detect_active_trace() and reads summary.md. This is the same
  fallback path already implemented in check-tester.sh (DEC-V3-001, lines 128-151) but promoted
  to the primary path.

- DEC-PROOF-LIFE-003: Preserve SubagentStop hooks as dead code with deprecation annotation.
  Addresses: REQ-NOGO-001.
  Rationale: SubagentStop may be fixed upstream. Removing the hooks loses the logic. The @deprecated
  annotation explains that PostToolUse:Task is the live path. The dedup guard (DEC-TESTER-006,
  check-tester.sh line 170) prevents double auto-verify if upstream fixes SubagentStop and both
  paths fire simultaneously.

#### Phase 1: Auto-Verify Migration
**Status:** planned
**Decision IDs:** DEC-PROOF-LIFE-001, DEC-PROOF-LIFE-002, DEC-PROOF-LIFE-003
**Requirements:** REQ-P0-001, REQ-P0-002, REQ-P0-003, REQ-P0-004, REQ-P0-005, REQ-P0-006
**Issues:** #150
**Definition of Done:**
- REQ-P0-001 satisfied: post-task.sh detects tester and reads summary.md
- REQ-P0-002 satisfied: .proof-status=verified on AUTOVERIFY: CLEAN + High confidence
- REQ-P0-003 satisfied: AUTO-VERIFIED in additionalContext output
- REQ-P0-004 satisfied: @deprecated annotation on check-tester.sh Phase 1
- REQ-P0-005 satisfied: PostToolUse:Task registered in settings.json
- REQ-P0-006 satisfied: test-post-task-autoverify.sh passes all cases

##### Planned Decisions
- DEC-PROOF-LIFE-001: New post-task.sh with auto-verify extracted from check-tester.sh Phase 1 — Addresses: REQ-P0-001, REQ-P0-002, REQ-P0-003, REQ-P0-005
- DEC-PROOF-LIFE-002: Read summary.md via detect_active_trace() — Addresses: REQ-P0-001, REQ-P0-003
- DEC-PROOF-LIFE-003: @deprecated annotation on check-tester.sh auto-verify — Addresses: REQ-P0-004

##### Work Items

**W1-1: Create hooks/post-task.sh PostToolUse:Task handler**
- Source source-lib.sh for shared functions.
- Extract subagent_type from tool_input (same field used by task-track.sh).
- If subagent_type != "tester", exit 0 (no-op for non-tester agents).
- Find active tester trace via detect_active_trace(PROJECT_ROOT, "tester").
- Read TRACE_DIR/summary.md as RESPONSE_TEXT.
- Read current .proof-status via resolve_proof_file().
- Dedup guard: if already "verified", emit advisory and exit 0 (mirrors DEC-TESTER-006).
- Run secondary validation (same logic as check-tester.sh lines 194-231):
  - Accept "pending" or "needs-verification" status.
  - Require AUTOVERIFY: CLEAN signal in RESPONSE_TEXT.
  - Require **High** confidence (markdown bold).
  - Reject "Partially verified".
  - Reject non-environmental "Not tested" (whitelist browser/viewport/device/network).
  - Reject **Medium** or **Low** confidence.
- If validation passes: write "verified|timestamp" to proof file with dual-write
  (scoped + legacy copies for guard.sh compatibility).
- Track agent stop, append audit entry.
- Finalize trace via finalize_trace().
- Emit JSON with additionalContext containing AUTO-VERIFIED directive.
- If validation fails or no signal: emit advisory context and exit 0.

**W1-2: Register PostToolUse:Task handler in settings.json**
- Add to PostToolUse section (after the Skill matcher block):
  ```json
  {
    "matcher": "Task",
    "hooks": [
      {
        "type": "command",
        "command": "$HOME/.claude/hooks/post-task.sh",
        "timeout": 15
      }
    ]
  }
  ```
- Timeout 15s matches check-tester.sh SubagentStop timeout.

**W1-3: Add @deprecated annotation to check-tester.sh Phase 1**
- Before the Phase 1 header comment (line 74), add:
  ```bash
  # @deprecated DEC-PROOF-LIFE-003
  # @title Phase 1 auto-verify is dead code — SubagentStop:tester never fires
  # @status deprecated
  # @rationale SubagentStop hooks do not fire in Claude Code (DEC-CACHE-003).
  #   Auto-verify logic has been migrated to hooks/post-task.sh (PostToolUse:Task).
  #   This code is retained because: (1) SubagentStop may be fixed upstream,
  #   (2) the dedup guard at line 170 (DEC-TESTER-006) prevents double auto-verify
  #   if both paths fire simultaneously. Do not delete without confirming upstream status.
  #   See: Issue #147, DEC-PROOF-LIFE-001.
  ```

**W1-4: Close cc-todos#49 (already fixed)**
- Run: `gh issue close 49 -c "Fixed in commit 368b3c4 (DEC-TRACK-GUARDIAN-001). Tests: test-track-guardian-exemption.sh (6 tests, all passing)."`
- This is a housekeeping item, not implementation work.

**W1-5: Create tests/test-post-task-autoverify.sh**
- Test 1: Tester with AUTOVERIFY: CLEAN + High confidence -> proof = verified, output has AUTO-VERIFIED.
- Test 2: Tester with AUTOVERIFY: CLEAN + Medium confidence -> proof stays pending (rejected).
- Test 3: Tester with AUTOVERIFY: CLEAN + "Partially verified" -> proof stays pending (rejected).
- Test 4: Tester with AUTOVERIFY: CLEAN + "Not tested" (non-environmental) -> proof stays pending.
- Test 5: Tester with AUTOVERIFY: CLEAN + "Not tested: requires browser" -> proof = verified (whitelisted).
- Test 6: Tester without AUTOVERIFY signal -> proof stays pending (no-op).
- Test 7: proof-status already verified -> dedup guard, no duplicate audit entry.
- Test 8: Non-tester agent (implementer) -> exit 0 immediately (no-op).
- Test 9: No active tester trace -> exit 0 with advisory.
- Test 10: Syntax check — post-task.sh is valid bash.
- Each test creates isolated temp repo with mock trace directory and summary.md.
- TAP-compatible output. All tests use make_temp_repo pattern from test-track-guardian-exemption.sh.

##### Critical Files
- `hooks/post-task.sh` — New: PostToolUse:Task auto-verify handler
- `hooks/check-tester.sh` — @deprecated annotation on Phase 1 (lines 74-285)
- `settings.json` — PostToolUse:Task registration
- `hooks/context-lib.sh` — detect_active_trace(), resolve_proof_file(), finalize_trace() (existing, used by new handler)
- `hooks/source-lib.sh` — Bootstrap for all hooks (existing)
- `tests/test-post-task-autoverify.sh` — New: 10 auto-verify migration tests

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Proof-Status Lifecycle Worktree Strategy

Main is sacred. Each phase works in its own worktree:
- **Phase 1:** `~/.claude/.worktrees/proof-autoverify` on branch `feature/autoverify-migration`

#### Proof-Status Lifecycle References

##### Related Decisions
| DEC-ID | Source | Relevance |
|--------|--------|-----------|
| DEC-CACHE-003 | task-track.sh | Confirmed SubagentStart never fires; same issue affects SubagentStop |
| DEC-TESTER-001 | check-tester.sh | Original auto-verify design (SubagentStop-based) |
| DEC-TESTER-006 | check-tester.sh | Dedup guard prevents double auto-verify |
| DEC-V3-001 | check-tester.sh | summary.md fallback for AUTOVERIFY signal |
| DEC-TRACK-GUARDIAN-001 | track.sh | Guardian race fix (cc-todos#49, already implemented) |

##### Related Issues
| Issue | Relation |
|-------|----------|
| #147 | Primary issue: auto-verify dead code migration |
| cc-todos#49 | Guardian race condition — already fixed, needs closure |
| #129 | Original diagnostic logging for auto-verify pipeline |
| #96 | Upstream: updatedInput not supported in PreToolUse |

---

## Completed Initiatives

| Initiative | Period | Phases | Key Decisions | Archived |
|-----------|--------|--------|---------------|----------|
| v2 Governance + Observability | 2026-02-18 to 2026-02-19 | 6 phases (0-5), all completed | DEC-GUARDIAN-001, DEC-PLANNER-STOP-001, DEC-OBS-P2-110, DEC-V2-005 | `archived-plans/2026-02-19_v2-governance-observability.md` |
| v3 Hardening & Reliability | 2026-02-19 to 2026-02-20 | 3 phases (6-8), all completed | DEC-V3-001..005, DEC-TRACK-001, DEC-PROOF-PATH-003 | Inline (completed initiative above) |

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
