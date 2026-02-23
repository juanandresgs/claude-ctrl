# MASTER_PLAN: Claude Code Governance System

## Identity

**Type:** meta-infrastructure (hooks, agents, skills, commands)
**Languages:** bash (78%), markdown (15%), python (7%)
**Root:** /Users/turla/.claude
**Created:** 2026-02-18
**Last updated:** 2026-02-23 (Metanoia initiative added)

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
| 2026-02-22 | DEC-ARCH-001 | architect | Content type detection via detect_content.sh | Testable bash script, consistent with uplevel pattern |
| 2026-02-22 | DEC-ARCH-002 | architect | Node extraction via multi-pass glob/grep | Deterministic extraction; LLM synthesizes, doesn't extract |
| 2026-02-22 | DEC-ARCH-003 | architect | Mermaid templates with dynamic population | Templates ensure valid syntax; dynamic generation risks errors |
| 2026-02-22 | DEC-ARCH-004 | architect | Manifest.json as Phase 1/Phase 2 contract | Clean separation; new backends just read manifest.json |
| 2026-02-22 | DEC-ARCH-005 | architect | Phase 2 dispatch via batched Task subagents | Per-node dispatch too many subagents; batch 3-5 keeps it manageable |
| 2026-02-22 | DEC-BAZAAR-009 | bazaar-completion | Remove lib/ from conftest.py sys.path | lib/http.py shadows stdlib http; SCRIPTS_DIR alone suffices for package discovery |
| 2026-02-22 | DEC-BAZAAR-012 | bazaar-completion | Local output directory replaces /tmp | Artifacts must be persistent and inspectable; CWD-relative bazaar-YYYYMMDD-HHMMSS/ |
| 2026-02-22 | DEC-BAZAAR-013 | bazaar-completion | Disk-based state passing with phase BLUF summaries | Agent reads only BLUFs; Python scripts handle data plumbing via disk paths |
| 2026-02-22 | DEC-BAZAAR-014 | bazaar-completion | bazaar_summarize.py generates phase BLUFs | Deterministic Python for concise summaries; keeps generation out of agent token budget |
| 2026-02-22 | DEC-BAZAAR-015 | bazaar-completion | SKILL.md rewrite with context discipline | Explicit prohibitions against reading full JSON; agent presents only BLUFs |
| 2026-02-22 | DEC-BAZAAR-016 | bazaar-completion | bazaar-manifest.json as run index | Machine-readable record of run: question, phases, artifacts, BLUFs |
| 2026-02-23 | DEC-META-001 | metanoia | Output buffering for multi-JSON prevention | Buffer advisories in variables, emit single JSON at end; guarantees one JSON object per hook invocation |
| 2026-02-23 | DEC-META-002 | metanoia | Differential test harness for old vs new hooks | Pipe same input through old hooks (separate) and new hook (single), diff permissionDecision fields |
| 2026-02-23 | DEC-META-003 | metanoia | Trace corpus extraction for real-world test data | Mine 489 traces for real hook inputs; deduplicate to 50-100 unique inputs per hook type |
| 2026-02-23 | DEC-META-004 | metanoia | Dual settings files with swap script for rollback | settings-legacy.json + settings-metanoia.json + swap.sh; validates JSON before overwrite |
| 2026-02-23 | DEC-META-005 | metanoia | Gradual rollout: pre-bash then post-write then pre-write | Safest first (guard.sh denies always exit), highest risk last (pre-write has 6 gates) |
| 2026-02-23 | DEC-META-006 | metanoia | Bake period: 5+ sessions per rollout stage | Any regression resets stage count; all 3 stages pass bake before merge |

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

### Initiative: /architect Skill -- Content-Agnostic Structural Analysis
**Status:** active
**Started:** 2026-02-22
**Goal:** Build a skill that maps the structure of any content path and optionally dispatches analysis to pluggable backends

> Understanding the structure of an unfamiliar codebase or document set requires 30-120 minutes
> of manual exploration that is repeated every time context is lost. No existing skill provides
> structural mapping with reusable artifacts. The /architect skill answers "what is the structure
> of this thing, how do its parts relate, and where can it be improved?" -- producing Mermaid
> diagrams, per-node documentation, and a manifest.json that any downstream analysis skill can
> consume. Phase 1 maps structure; Phase 2 dispatches to /deep-research per node for improvement
> analysis.

**Dominant Constraint:** simplicity (content-agnostic design; over-specialization defeats the purpose)

#### Goals
- REQ-GOAL-001: Produce a structural map (nodes + edges) of any content path in under 5 minutes
- REQ-GOAL-002: Generate valid, renderable Mermaid diagrams appropriate to content type
- REQ-GOAL-003: Create a reusable manifest.json consumable by any downstream analysis skill
- REQ-GOAL-004: Enable per-node deep-dive documentation grounded in structural context

#### Non-Goals
- REQ-NOGO-001: Runtime code analysis (profiling, tracing) -- static analysis only
- REQ-NOGO-002: Building a new research engine -- dispatches to existing /deep-research
- REQ-NOGO-003: Replacing ARCHITECTURE.md or MASTER_PLAN.md -- complementary, not substitute
- REQ-NOGO-004: Supporting binary analysis or compiled artifacts -- source/text/docs only

#### Requirements

**Must-Have (P0)**

- REQ-P0-001: Content type detection script identifies codebase, document set, mixed, or single file.
  Acceptance: Given a path, When detect_content.sh runs, Then it outputs JSON with content_type,
  root_path, language_stats, file_counts, entry_points.

- REQ-P0-002: SKILL.md defines complete Phase 1 (Map) workflow with step-by-step instructions.
  Acceptance: Given `/architect /path/to/project`, When skill executes, Then it produces
  essentials.md, per-node deep dives, and manifest.json.

- REQ-P0-003: Manifest.json follows the defined schema with nodes, edges, and diagram references.
  Acceptance: Given Phase 1 completes, When manifest.json is read, Then it validates against the
  schema with content_type, root, generated, nodes (with id, name, type, path, description,
  files, edges, metrics), and diagrams.

- REQ-P0-004: Mermaid diagrams render correctly for all content types.
  Acceptance: Given a codebase input, When diagrams are generated, Then they use module dependency
  + data flow patterns. Given a document set, When diagrams are generated, Then they use concept
  map patterns.

- REQ-P0-005: essentials.md contains high-level overview with system Mermaid diagram.
  Acceptance: Given Phase 1 completes, When essentials.md is read, Then it has project overview,
  system diagram, component summary table, and cross-cutting concerns.

- REQ-P0-006: Per-node deep-dive files contain module-specific analysis and diagram.
  Acceptance: Given a node in the manifest, When its deep-dive file is read, Then it has purpose,
  API surface, dependencies, diagram, and improvement opportunities.

- REQ-P0-007: .skill-result.md context summary written at skill completion.
  Acceptance: Given skill completes, When .skill-result.md is read, Then it contains status,
  output path, node count, and key structural findings.

- REQ-P0-008: Tests validate detect_content.sh against known content types.
  Acceptance: Given synthetic directories with known content types, When test-detect-content.sh
  runs, Then all cases produce correct content_type classification.

**Nice-to-Have (P1)**

- REQ-P1-001: `--depth essentials` flag produces overview only (no per-node deep dives).
- REQ-P1-002: `--output path` flag overrides default output directory.
- REQ-P1-003: Single-file analysis mode produces internal structure breakdown.

**Future Consideration (P2)**

- REQ-P2-001: /structured-analytics backend interface contract for future analytics skill.
- REQ-P2-002: Incremental re-mapping (detect changes since last manifest, update only affected nodes).
- REQ-P2-003: Interactive Mermaid diagram viewer via Playwright.

#### Definition of Done

`/architect /path/to/project` produces valid essentials.md, per-node deep dives in modules/,
manifest.json, and system Mermaid diagram for a real codebase. detect_content.sh tests pass
for all content types. Phase 2 dispatches /deep-research per node batch and folds results
into improvements.md.

#### Architectural Decisions

- DEC-ARCH-001: Content type detection via detect_content.sh bash script.
  Addresses: REQ-P0-001.
  Rationale: Testable, reusable, consistent with uplevel's detect_project.sh pattern. Runs
  before main analysis, providing ground truth to the skill prompt. Detection signals:
  package.json/.git/source files (codebase), .md/.txt/.pdf only (docs), both (mixed),
  single file (single).

- DEC-ARCH-002: Node extraction via multi-pass glob/grep analysis.
  Addresses: REQ-P0-003, REQ-P0-006, REQ-GOAL-001.
  Rationale: Deterministic extraction using existing tools (Glob, Grep, Read). For codebases:
  directory structure + package boundaries + imports. For docs: heading structure +
  cross-references. LLM synthesizes findings into documentation, but structure extraction
  is mechanical.

- DEC-ARCH-003: Mermaid diagram templates with dynamic population.
  Addresses: REQ-P0-004, REQ-GOAL-002.
  Rationale: Templates ensure valid Mermaid syntax; dynamic generation risks syntax errors.
  Template patterns per content type (module dependency, concept map, sequence diagram).
  The skill populates templates with extracted nodes/edges.

- DEC-ARCH-004: Manifest.json as Phase 1/Phase 2 integration contract.
  Addresses: REQ-P0-003, REQ-GOAL-003.
  Rationale: Clean separation of concerns. Phase 1 never needs to know what Phase 2 does.
  New backends just read manifest.json. Schema defined in the spec with nodes, edges,
  metrics, diagrams.

- DEC-ARCH-005: Phase 2 dispatch via Task subagent per node batch (3-5 nodes).
  Addresses: REQ-GOAL-004.
  Rationale: Per-node dispatch would create too many subagents. Batching by 3-5 keeps it
  manageable while maintaining focus. Each batch gets a research brief generated from
  manifest node data.

#### Phase 1: Core Skill (Map Only)
**Status:** completed
**Decision IDs:** DEC-ARCH-001, DEC-ARCH-002, DEC-ARCH-003, DEC-ARCH-004
**Requirements:** REQ-P0-001, REQ-P0-002, REQ-P0-003, REQ-P0-004, REQ-P0-005, REQ-P0-006, REQ-P0-007, REQ-P0-008
**Issues:** #23
**Definition of Done:**
- REQ-P0-001 satisfied: detect_content.sh classifies codebase, docs, mixed, single file
- REQ-P0-002 satisfied: SKILL.md has complete Phase 1 workflow
- REQ-P0-003 satisfied: manifest.json validates against schema
- REQ-P0-004 satisfied: Mermaid diagrams render for all content types
- REQ-P0-005 satisfied: essentials.md has overview + system diagram
- REQ-P0-006 satisfied: Per-node deep-dive files exist with module-specific analysis
- REQ-P0-007 satisfied: .skill-result.md written at completion
- REQ-P0-008 satisfied: detect_content.sh tests pass

##### Planned Decisions
- DEC-ARCH-001: Content type detection via detect_content.sh — Addresses: REQ-P0-001
- DEC-ARCH-002: Node extraction via multi-pass glob/grep — Addresses: REQ-P0-003, REQ-P0-006
- DEC-ARCH-003: Mermaid templates with dynamic population — Addresses: REQ-P0-004
- DEC-ARCH-004: Manifest.json as Phase 1/Phase 2 contract — Addresses: REQ-P0-003

##### Work Items

**W1-1: Create skills/architect/SKILL.md**
- YAML frontmatter: name, description, argument-hint, context: fork, agent: general-purpose
- Allowed tools: Bash, Read, Write, Glob, Grep, WebSearch, Task, AskUserQuestion
- Argument parsing for: path, --depth, --research, --analytics, --output
- Phase 1 (Map) workflow: detect content type -> extract nodes/edges -> generate manifest ->
  generate Mermaid diagrams -> write essentials.md -> write per-node deep dives
- Phase 2 (Analyze) workflow: read manifest -> batch nodes -> dispatch to backend -> fold results
- Error handling, edge cases, mandatory .skill-result.md
- Follow patterns from deep-research/SKILL.md and uplevel/SKILL.md

**W1-2: Create skills/architect/scripts/detect_content.sh**
- Input: path argument
- Detection logic:
  - Codebase: presence of package.json, Cargo.toml, go.mod, pyproject.toml, .git with source files
  - Document set: only .md/.txt/.pdf/.rst/.docx, no source code
  - Mixed: both source code and documentation present
  - Single file: input is a file, not a directory
- Output JSON: content_type, root_path, languages (array), file_counts (by extension),
  entry_points (main files, index files)
- chmod 755

**W1-3: Create skills/architect/templates/**
- mermaid-module-dependency.md: template for codebase module dependency graphs
- mermaid-concept-map.md: template for document set concept maps
- mermaid-data-flow.md: template for data flow diagrams
- mermaid-sequence.md: template for interaction sequences
- Each template has placeholder markers that the skill populates

**W1-4: Define manifest.json schema**
- Create skills/architect/schema/manifest-schema.json (JSON Schema)
- Validates the manifest.json output from Phase 1
- Fields: content_type, root, generated, nodes[], diagrams{}

**W1-5: Create tests/test-detect-content.sh**
- Test 1: Codebase detection (directory with package.json + .js files)
- Test 2: Document set detection (directory with only .md files)
- Test 3: Mixed detection (directory with both source and docs)
- Test 4: Single file detection (path to a single .py file)
- Test 5: Empty directory (graceful handling)
- Test 6: Nested codebase (monorepo structure)
- Test 7: Syntax check -- detect_content.sh is valid bash
- TAP-compatible output. Isolated temp directories per test.

**W1-6: Integration test with ~/.claude as sample codebase**
- Run detect_content.sh against ~/.claude, verify content_type = "mixed"
- Verify output JSON has expected fields
- Quick smoke test, not exhaustive

##### Critical Files
- `skills/architect/SKILL.md` -- Core skill definition
- `skills/architect/scripts/detect_content.sh` -- Content type detection
- `skills/architect/templates/` -- Mermaid diagram templates
- `skills/architect/schema/manifest-schema.json` -- Manifest schema
- `tests/test-detect-content.sh` -- Detection tests

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Phase 2: Backend Integration
**Status:** completed
**Decision IDs:** DEC-ARCH-005
**Requirements:** REQ-GOAL-004, REQ-P2-001
**Issues:** #24
**Definition of Done:**
- /deep-research dispatch works per node batch from manifest.json
- Research results fold back into improvements.md
- /structured-analytics interface contract defined (future backend)

##### Planned Decisions
- DEC-ARCH-005: Phase 2 dispatch via batched Task subagents (3-5 nodes) — Addresses: REQ-GOAL-004

##### Work Items

**W2-1: Add /deep-research dispatch to SKILL.md Phase 2**
- When --research flag is present, read manifest.json
- Batch nodes into groups of 3-5 by relatedness (same parent directory or edge connections)
- Generate focused research brief per batch: node names, descriptions, relationships,
  specific questions
- Dispatch via Task subagent with /deep-research skill
- Collect results from .skill-result.md or research output directory

**W2-2: Create research brief template**
- Create skills/architect/templates/research-brief.md
- Template for converting manifest nodes into research queries
- Fields: node names, descriptions, edge context, specific improvement questions
- One brief per batch (3-5 nodes)

**W2-3: Implement results folding into improvements.md**
- After all research dispatches complete, read research reports
- Group findings by node ID
- Write improvements.md with per-node improvement sections
- Include confidence levels from research (consensus, majority, unique)
- Link back to relevant node deep-dive files

**W2-4: Define /structured-analytics interface contract**
- Create skills/architect/schema/analytics-input-schema.json
- Defines what a future /structured-analytics backend would receive
- Same manifest.json input but with analytics-specific query fields
- Contract definition only -- no implementation

**W2-5: Tests for dispatch integration**
- Test 1: Research brief generation from manifest with 5 nodes
- Test 2: Results folding produces improvements.md with per-node sections
- Test 3: --research flag with no manifest.json gives clear error
- Test 4: Manifest with 1 node (no batching needed)
- TAP-compatible output.

##### Critical Files
- `skills/architect/SKILL.md` -- Phase 2 additions
- `skills/architect/templates/research-brief.md` -- Research brief template
- `skills/architect/schema/analytics-input-schema.json` -- Future backend contract
- `tests/test-architect-dispatch.sh` -- Dispatch integration tests

##### Decision Log
- DEC-ARCH-005: Phase 2 dispatch via batched Task subagents (3-5 nodes per batch). 3-tier heuristic: <=5 nodes single batch, 6-15 nodes 2-3 batches, >15 nodes 4+ batches. Sequential dispatch prevents resource exhaustion. Addresses: REQ-GOAL-004.

#### /architect Worktree Strategy

Main is sacred. Each phase works in its own worktree:
- **Phase 1:** `~/.claude/.worktrees/architect-core` on branch `feature/architect-skill`
- **Phase 2:** `~/.claude/.worktrees/architect-backends` on branch `feature/architect-backends`

Implementation order: Phase 1 first (core skill with map functionality), then Phase 2
(backend integration depends on manifest schema from Phase 1).

#### /architect References

##### Existing Skill Patterns
| Skill | Pattern Used |
|-------|-------------|
| deep-research | Multi-phase execution, background processing, .skill-result.md |
| uplevel | Project detection script, parallel subagent dispatch, area-based analysis |
| consume-content | Content type detection, read-write-verify pipeline |
| decide | Config JSON schema, integration with planner |

---

### Initiative: Bazaar Competitive Analytical Marketplace -- Completion
**Status:** active
**Started:** 2026-02-22
**Goal:** Harden and validate the /bazaar skill so it can merge to main and operate in production

> The /bazaar skill implements a competitive analytical marketplace: diverse ideation via multiple
> LLM providers, judicial funding of the best ideas, obsessive deep-research on funded ideas,
> analyst translation of research into actionable insights, and a market-proportional final report.
> The skill is 90%+ built (SKILL.md, bazaar_dispatch.py, aggregate.py, report.py, 4 archetype
> families, provider wrappers, 66 passing tests) but lives in an unmerged worktree. Two gaps
> remain: a test import inconsistency (conftest.py adds lib/ to sys.path, contradicting the
> production fix that avoids this to prevent http.py shadowing Python's stdlib http module),
> and no live E2E validation has been performed.

**Dominant Constraint:** simplicity (skill is nearly done; minimize changes, validate, merge)

#### Goals
- REQ-GOAL-001: /bazaar skill available on main branch and invocable in production
- REQ-GOAL-002: Test imports consistent with production imports (no stdlib shadowing)
- REQ-GOAL-003: At least one successful E2E run with real API providers
- REQ-GOAL-004: All 6 bazaar phases complete autonomously in a single /bazaar invocation
- REQ-GOAL-005: All artifacts persisted to structured local directory, not /tmp
- REQ-GOAL-006: Agent presents BLUF summaries; users inspect full artifacts on disk

#### Non-Goals
- REQ-NOGO-001: Adding new archetypes or providers -- ship what exists, extend later
- REQ-NOGO-002: Performance optimization of dispatch parallelism -- works well enough
- REQ-NOGO-003: Integration with /architect or other skills -- separate initiative
- REQ-NOGO-004: Multi-command workflow -- user should NOT need to run separate phase commands
- REQ-NOGO-005: Changing the archetype system or provider dispatch logic -- those work fine
- REQ-NOGO-006: Reducing analytical depth to fit context -- quality must not degrade

#### Requirements

**Must-Have (P0)**

- REQ-P0-001: conftest.py does not add lib/ to sys.path (prevents http.py shadowing).
  Acceptance: Given conftest.py, When inspected, Then only SCRIPTS_DIR is on sys.path
  (lib/ is discoverable as a package via SCRIPTS_DIR).

- REQ-P0-002: All 66 existing tests pass after conftest.py fix.
  Acceptance: Given conftest fix applied, When pytest runs, Then 66 passed, 0 failed.

- REQ-P0-003: /bazaar skill merges to main and is invocable.
  Acceptance: Given main branch, When `/bazaar "test question"` is invoked, Then skill
  starts execution (SKILL.md discovered by Claude Code skill loader).

- REQ-P0-004: E2E validation with at least one real API provider.
  Acceptance: Given at least one API key (Anthropic, OpenAI, Gemini, or Perplexity),
  When /bazaar runs a real analytical question, Then all 6 phases complete and a
  report is produced.

**Nice-to-Have (P1)**

- REQ-P1-001: E2E validation with all 4 providers for maximum diversity.
- REQ-P1-002: Report output quality review -- coherent synthesis, proper citations.

- REQ-P0-005: All artifacts written to structured local directory (not /tmp).
  Acceptance: Given /bazaar invoked from CWD, When skill runs, Then all outputs appear in
  `./bazaar-YYYYMMDD-HHMMSS/` with subdirectories: ideators/, judges/, obsessives/,
  analysts/, and top-level brief.md, funded_scenarios.json, bazaar-report.md.

- REQ-P0-006: Output directory contains a manifest file tying all artifacts together.
  Acceptance: Given a completed bazaar run, When bazaar-manifest.json is read, Then it
  contains: question, timestamps, provider availability, phase completion status with
  artifact paths, and BLUF summaries for each phase.

- REQ-P0-007: Each phase produces a BLUF summary (5-15 lines) that the agent presents.
  Acceptance: Given Phase N completes, When agent continues, Then it presents a concise
  BLUF (counts, key findings, issues) and does NOT display raw JSON or full data.

- REQ-P0-008: Agent does not read full JSON outputs into context between phases.
  Acceptance: Given Phase N writes outputs to disk, When Phase N+1 starts, Then the
  agent calls Python scripts that read from disk directly; the agent reads only the
  BLUF summary file (phase-N-bluf.md).

- REQ-P0-009: Restructured SKILL.md enables autonomous completion of all 6 phases.
  Acceptance: Given /bazaar invoked with a real analytical question, When skill executes
  as forked agent, Then all 6 phases complete and bazaar-report.md is produced without
  manual intervention.

- REQ-P0-010: New bazaar_summarize.py generates phase BLUFs from disk artifacts.
  Acceptance: Given phase outputs exist on disk, When bazaar_summarize.py is called
  with phase number and output directory, Then it writes phase-N-bluf.md with concise
  metrics and findings.

**Nice-to-Have (P1)**

- REQ-P1-001: E2E validation with all 4 providers for maximum diversity.
- REQ-P1-002: Report output quality review -- coherent synthesis, proper citations.
- REQ-P1-003: bazaar-manifest.json includes per-phase timing data for performance analysis.
- REQ-P1-004: Output directory name configurable via --output flag.

**Future Consideration (P2)**

- REQ-P2-001: Archetype tuning based on real output quality assessment.
- REQ-P2-002: Provider fallback chain when API keys are missing.
- REQ-P2-003: Incremental re-run: resume from last completed phase on failure.
- REQ-P2-004: HTML report generation with interactive funding visualization.

#### Definition of Done

conftest.py import fix applied. 75 tests pass. Branch merged to main. At least one E2E
run completes all 6 bazaar phases autonomously and produces a report in a structured local
directory. Agent presents BLUF summaries without reading full intermediate data into context.
Issue created and closed.

#### Architectural Decisions

- DEC-BAZAAR-009: Remove lib/ from conftest.py sys.path to match production import strategy.
  Addresses: REQ-P0-001, REQ-P0-002.
  Rationale: bazaar_dispatch.py explicitly avoids adding lib/ to sys.path because lib/http.py
  shadows Python's stdlib http module (see line 71 comment). conftest.py contradicts this by
  adding LIB_DIR as a fallback. Since SCRIPTS_DIR on sys.path makes lib/ discoverable as a
  package (import lib.anthropic_chat works), the LIB_DIR fallback is unnecessary and harmful.

- DEC-BAZAAR-012: Local output directory replaces /tmp for all bazaar artifacts.
  Addresses: REQ-P0-005, REQ-P0-006, REQ-GOAL-005.
  Rationale: User requirement: artifacts must be persistent and inspectable. /tmp is ephemeral
  and lost on reboot. CWD-relative output directory (bazaar-YYYYMMDD-HHMMSS/) mirrors the
  natural artifact hierarchy demonstrated in the E2E run. Subdirectories: ideators/, judges/,
  obsessives/, analysts/ plus top-level brief.md, funded_scenarios.json, bazaar-report.md,
  and bazaar-manifest.json.

- DEC-BAZAAR-013: Disk-based state passing with phase BLUF summaries.
  Addresses: REQ-P0-007, REQ-P0-008, REQ-GOAL-004, REQ-GOAL-006.
  Rationale: The E2E run stalled at Phase 3 because the agent's context accumulated full JSON
  outputs from ideators and judges (~15-30KB per archetype). The fix: each phase writes full
  data to disk and a concise phase-N-bluf.md (5-15 lines). The agent reads ONLY BLUFs into
  context. Python scripts handle all data plumbing between phases via disk paths, not agent
  context. Alternatives rejected: (1) phase-specific sub-skills (too much infrastructure,
  breaks single-command UX), (2) controller dispatching phases as Task agents (skill-within-
  skill not well-supported, max_turns overhead), (3) SKILL.md simplification alone (necessary
  but insufficient -- the file itself is only ~5K tokens; context bloat comes from intermediate
  data the agent reads during execution).

- DEC-BAZAAR-014: New bazaar_summarize.py generates phase BLUFs from disk artifacts.
  Addresses: REQ-P0-007, REQ-P0-010, REQ-GOAL-006.
  Rationale: Deterministic Python script reads phase outputs from disk and produces concise
  markdown BLUFs. Keeps summary generation out of the agent's token budget. Called after each
  phase's existing Python scripts complete. Output: phase-N-bluf.md with counts, key findings,
  top items, and any errors/warnings.

- DEC-BAZAAR-015: SKILL.md rewrite with explicit context discipline instructions.
  Addresses: REQ-P0-009, REQ-GOAL-004.
  Rationale: Without explicit instructions, the agent naturally tries to read and display
  intermediate data (JSON outputs, full dispatch files). The restructured SKILL.md must contain
  explicit prohibitions: "NEVER read the full JSON output files", "NEVER display raw data to
  the user", "Read ONLY phase-N-bluf.md files", "Let Python scripts pass data between phases
  via disk". These instructions are as important as the workflow itself.

- DEC-BAZAAR-016: Manifest/index file ties all artifacts together.
  Addresses: REQ-P0-006, REQ-P0-010, REQ-GOAL-005.
  Rationale: A top-level bazaar-manifest.json records: question, timestamps, provider
  availability, phase completion status, artifact paths, and BLUF summaries. Serves as both
  a table of contents for humans and a machine-readable record. Updated after each phase
  completes by bazaar_summarize.py.

#### Phase 1: Hardening
**Status:** completed
**Decision IDs:** DEC-BAZAAR-009
**Requirements:** REQ-P0-001, REQ-P0-002, REQ-P0-003
**Issues:** #26
**Definition of Done:**
- REQ-P0-001 satisfied: conftest.py only adds SCRIPTS_DIR to sys.path
- REQ-P0-002 satisfied: 66 tests pass after fix
- REQ-P0-003 satisfied: branch merged to main

##### Planned Decisions
- DEC-BAZAAR-009: Remove LIB_DIR from conftest.py sys.path -- aligns test imports with production -- Addresses: REQ-P0-001, REQ-P0-002

##### Work Items

**W1-1: Fix conftest.py import shadowing**
- Remove line 21 (`sys.path.insert(0, str(LIB_DIR))`) from tests/conftest.py
- Remove LIB_DIR variable definition (line 16)
- Remove docstring reference to lib/ fallback (lines 7-8)
- SCRIPTS_DIR remains -- it enables `import lib.anthropic_chat` via package discovery

**W1-2: Verify test suite passes**
- Run: `python3 -m pytest skills/bazaar/tests/ --tb=short -q`
- Expected: 66 passed, 0 failed
- If any test breaks, it was relying on bare `import anthropic_chat` instead of
  `import lib.anthropic_chat` -- fix the import in the test file

**W1-3: Merge to main via Guardian**
- Branch: feature/bazaar-skill in .worktrees/feat-bazaar
- Guardian commit + merge to main
- Verify skill directory appears at skills/bazaar/ on main

##### Critical Files
- `skills/bazaar/tests/conftest.py` -- Import path fix (remove LIB_DIR)
- `skills/bazaar/scripts/bazaar_dispatch.py` -- Reference: lines 71-75 show correct import strategy
- `skills/bazaar/SKILL.md` -- Skill definition (already complete)

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Phase 2: E2E Validation
**Status:** completed
**Decision IDs:** none (validation only)
**Requirements:** REQ-P0-004
**Issues:** #27
**Definition of Done:**
- REQ-P0-004 satisfied: /bazaar completes all 6 phases on a real question with real API

##### Planned Decisions
- None -- this phase is pure validation

##### Work Items

**W2-1: Run /bazaar with a real analytical question**
- Invoke: `/bazaar "What are the most effective approaches to reducing LLM hallucination in production systems?"`
- Verify each phase executes: ideation (5 ideators), judging (3 judges), obsessive research
  (top-funded ideas dispatched), analysis (3 analysts), aggregation, report generation
- Capture output report path

**W2-2: Validate report quality**
- Read generated report
- Verify: multiple perspectives represented, research citations present, analyst insights
  coherent, market-proportional weighting visible in report structure
- Flag any phase failures or empty sections for remediation

##### Critical Files
- `skills/bazaar/SKILL.md` -- Orchestration workflow (all 6 phases)
- `skills/bazaar/scripts/aggregate.py` -- Aggregation logic
- `skills/bazaar/scripts/report.py` -- Report generation
- `skills/bazaar/templates/report-template.md` -- Report format

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Phase 3: Output Codification & Autonomous Execution
**Status:** planned
**Decision IDs:** DEC-BAZAAR-012, DEC-BAZAAR-013, DEC-BAZAAR-014, DEC-BAZAAR-015, DEC-BAZAAR-016
**Requirements:** REQ-P0-005, REQ-P0-006, REQ-P0-007, REQ-P0-008, REQ-P0-009, REQ-P0-010
**Issues:** #35
**Definition of Done:**
- REQ-P0-005 satisfied: All artifacts in structured local directory (not /tmp)
- REQ-P0-006 satisfied: bazaar-manifest.json present with full run metadata
- REQ-P0-007 satisfied: Each phase produces phase-N-bluf.md presented to user
- REQ-P0-008 satisfied: Agent reads no full JSON outputs between phases
- REQ-P0-009 satisfied: All 6 phases complete autonomously in forked agent
- REQ-P0-010 satisfied: bazaar_summarize.py produces BLUFs for all phases

##### Planned Decisions
- DEC-BAZAAR-012: Local output directory (bazaar-YYYYMMDD-HHMMSS/) replaces /tmp -- persistent, inspectable artifacts -- Addresses: REQ-P0-005, REQ-P0-006
- DEC-BAZAAR-013: Disk-based state passing -- agent reads only BLUFs, Python scripts handle data plumbing via disk -- Addresses: REQ-P0-007, REQ-P0-008, REQ-GOAL-004
- DEC-BAZAAR-014: bazaar_summarize.py generates phase BLUFs from disk artifacts -- Addresses: REQ-P0-007, REQ-P0-010
- DEC-BAZAAR-015: SKILL.md rewrite with explicit context discipline (never read full JSON, present only BLUFs) -- Addresses: REQ-P0-009
- DEC-BAZAAR-016: bazaar-manifest.json as run index/table of contents -- Addresses: REQ-P0-006

##### Work Items

**W3-1: Create bazaar_summarize.py phase BLUF generator**
- New file: `skills/bazaar/scripts/bazaar_summarize.py`
- CLI: `bazaar_summarize.py <phase_number> <output_dir>`
- Phase 1 (brief): Read brief.md, output question, scope, key uncertainties
- Phase 2 (ideation): Read ideators/*.json, output: N ideators, M unique scenarios,
  list scenario IDs + titles (one line each), any failures
- Phase 3 (funding): Read funded_scenarios.json, output: funding table (rank, ID,
  title, percent), Kendall's W, Gini coefficient, top-funded scenario
- Phase 4 (research): Read obsessives/*.json, output: N domain obsessives completed,
  M search obsessives completed, signal counts per scenario, any failures
- Phase 5 (analysis): Read analysts/*.json, output: N analysts completed, key themes
  extracted, confidence levels, any failures
- Phase 6 (report): Read bazaar-report.md, output: word count, section count,
  report path, funding summary table
- Output: writes `<output_dir>/phase-N-bluf.md` (5-15 lines markdown)
- Also updates bazaar-manifest.json with phase completion status and BLUF text
- Tests: add test_summarize.py with fixtures for each phase

**W3-2: Restructure SKILL.md for local output and context discipline**
- Replace `WORK_DIR=$(mktemp -d /tmp/bazaar-XXXXXX)` with:
  `WORK_DIR="./bazaar-$(date +%Y%m%d-%H%M%S)"` (CWD-relative)
- Add `## Context Discipline` section near the top with explicit rules:
  1. "NEVER use Read tool to open JSON files in ideators/, judges/, obsessives/, analysts/"
  2. "After each phase's Python scripts complete, run bazaar_summarize.py"
  3. "Read ONLY the phase-N-bluf.md file and present its contents to the user"
  4. "Python scripts accept disk paths and handle all data plumbing"
  5. "Your context is precious -- every JSON blob you read reduces your ability to
     complete later phases"
- Remove inline JSON examples from dispatch file construction (the agent can construct
  these from the archetype paths and provider config without seeing a full example)
- Replace verbose inline Python snippets with calls to Python scripts that accept
  command-line arguments (e.g., scenario deduplication becomes a function in
  bazaar_summarize.py or a new utility)
- Add `bazaar_summarize.py` call after each phase
- After Phase 6, add call to finalize bazaar-manifest.json

**W3-3: Create bazaar_prepare.py for dispatch file construction**
- New file: `skills/bazaar/scripts/bazaar_prepare.py`
- CLI: `bazaar_prepare.py <phase> <output_dir> <providers_json> [options]`
- Phase 2 (ideation): builds ideation_dispatches.json from archetype paths + providers
- Phase 3 (funding): builds judge_dispatches.json from scenarios + archetype paths
- Phase 5 (analysis): builds analyst_dispatches.json from funded scenarios + obsessive outputs
- This removes the largest inline code blocks from SKILL.md (the dispatch JSON
  construction, which is ~100 lines of inline Python currently)
- The agent calls: `python3 bazaar_prepare.py ideation "$WORK_DIR" "$PROVIDERS_JSON"`
  instead of constructing the dispatch JSON inline

**W3-4: Implement bazaar-manifest.json generation**
- Schema:
  ```json
  {
    "question": "...",
    "started": "ISO-8601",
    "completed": "ISO-8601 or null",
    "output_dir": "absolute path",
    "providers": {"anthropic": true, "openai": true, ...},
    "phases": {
      "1": {"status": "completed", "artifacts": ["brief.md"], "bluf": "..."},
      "2": {"status": "completed", "artifacts": ["ideators/..."], "bluf": "..."},
      ...
    },
    "report_path": "bazaar-report.md",
    "word_count": 3000,
    "scenarios_funded": 5
  }
  ```
- bazaar_summarize.py creates/updates this file after each phase
- Initial creation in SKILL.md Setup section (question + providers + start time)

**W3-5: Refactor scenario deduplication into Python utility**
- Move the inline Python deduplication snippet (SKILL.md lines 208-231) into
  bazaar_prepare.py as a `deduplicate_scenarios(output_dir)` function
- CLI: `bazaar_prepare.py dedup "$WORK_DIR"`
- Reads ideators/*.json, deduplicates, writes all_scenarios.json
- Returns count to stdout for the BLUF

**W3-6: Refactor analyst output collection into Python utility**
- Move the inline analyst output collection (SKILL.md lines 483-498) into
  bazaar_prepare.py as a `collect_analyst_outputs(output_dir)` function
- CLI: `bazaar_prepare.py collect-analysts "$WORK_DIR"`
- Reads analysts/*.json, collects into analyst_outputs.json
- Returns count to stdout

**W3-7: Update tests for new scripts**
- Add `tests/test_summarize.py`:
  - Test phase 2 BLUF from sample ideator outputs (fixture)
  - Test phase 3 BLUF from sample funded scenarios (fixture)
  - Test phase 6 BLUF from sample report
  - Test manifest creation and update
  - Test missing artifacts handling (graceful degradation)
- Add `tests/test_prepare.py`:
  - Test ideation dispatch generation from providers.json + archetypes
  - Test judge dispatch generation from scenarios
  - Test analyst dispatch generation from funded scenarios
  - Test deduplication logic
  - Test analyst output collection
- Update existing tests if any import paths change
- Target: 75+ total tests (current 75 + new tests)

**W3-8: E2E validation of restructured skill**
- Run `/bazaar "What are the most effective approaches to reducing LLM hallucination
  in production systems?"` with the restructured SKILL.md
- Verify: all 6 phases complete autonomously (no manual intervention)
- Verify: local output directory contains all expected artifacts
- Verify: bazaar-manifest.json is complete and accurate
- Verify: bazaar-report.md is coherent and has market-proportional sections
- Verify: agent presented only BLUF summaries (not raw JSON) at each phase

##### Critical Files
- `skills/bazaar/scripts/bazaar_summarize.py` -- New: phase BLUF generation + manifest
- `skills/bazaar/scripts/bazaar_prepare.py` -- New: dispatch construction + dedup + collection
- `skills/bazaar/SKILL.md` -- Major restructure: context discipline, local output, BLUF flow
- `skills/bazaar/scripts/bazaar_dispatch.py` -- No changes (still handles parallel dispatch)
- `skills/bazaar/scripts/aggregate.py` -- No changes (still handles funding aggregation)
- `skills/bazaar/scripts/report.py` -- No changes (still handles report generation)
- `skills/bazaar/tests/test_summarize.py` -- New: BLUF generation tests
- `skills/bazaar/tests/test_prepare.py` -- New: dispatch preparation tests

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Bazaar Completion Worktree Strategy

Main is sacred. Each phase works in its own worktree:
- **Phase 1:** `~/.claude/.worktrees/feat-bazaar` on branch `feature/bazaar-skill` (completed)
- **Phase 2:** On main (post-merge E2E validation) (completed)
- **Phase 3:** `~/.claude/.worktrees/bazaar-codify` on branch `feature/bazaar-output-codification`

Implementation order: Phase 1 (fix + merge) -> Phase 2 (validate on main) -> Phase 3 (restructure for autonomous execution).

#### Bazaar Completion References

##### Existing Code Inventory
| Component | Path | Status |
|-----------|------|--------|
| SKILL.md | skills/bazaar/SKILL.md | Needs restructure (20k, 6-phase workflow -- Phase 3 target) |
| Dispatch engine | skills/bazaar/scripts/bazaar_dispatch.py | Complete (parallel ThreadPoolExecutor) |
| Aggregation | skills/bazaar/scripts/aggregate.py | Complete (market-proportional weighting) |
| Report generator | skills/bazaar/scripts/report.py | Complete (template-based) |
| Provider wrappers | skills/bazaar/scripts/lib/ | Complete (anthropic, openai, gemini, perplexity) |
| Archetypes | skills/bazaar/archetypes/ | Complete (4 families: ideators, judges, obsessives, analysts) |
| Provider config | skills/bazaar/providers.json | Complete (4 providers with models) |
| Tests | skills/bazaar/tests/ | 75 passing (dispatch, aggregate, report) |
| Report template | skills/bazaar/templates/report-template.md | Complete |
| **bazaar_summarize.py** | skills/bazaar/scripts/bazaar_summarize.py | **Phase 3: new** |
| **bazaar_prepare.py** | skills/bazaar/scripts/bazaar_prepare.py | **Phase 3: new** |

##### Existing Decisions (in code @decision annotations)
| DEC-ID | Title |
|--------|-------|
| DEC-BAZAAR-001 | Multi-provider model diversity as "temperature" |
| DEC-BAZAAR-002 | Archetype system prompt families |
| DEC-BAZAAR-003 | Market-proportional aggregation weighting |
| DEC-BAZAAR-004 | bazaar_dispatch.py for non-tool phases, Task agents for tool phases |
| DEC-BAZAAR-005 | Judge funding as idea selection mechanism |
| DEC-BAZAAR-006 | Analyst persona diversity (skeptic, pragmatist, synthesizer) |
| DEC-BAZAAR-007 | Report template with market voice sections |
| DEC-BAZAAR-008 | Mock mode for deterministic testing |
| DEC-BAZAAR-010 | KEYCHAIN_DIR anchor walk |
| DEC-BAZAAR-011 | Markdown fence stripping |

##### E2E Run Observations (Phase 2)
| Observation | Impact on Phase 3 |
|-------------|-------------------|
| Agent stalled at Phase 3 (Judicial Funding) | Context exhaustion from accumulated JSON -- DEC-BAZAAR-013 |
| All output in /tmp, lost on reboot | Need local persistent directory -- DEC-BAZAAR-012 |
| Agent tried to display all raw data | Need BLUF discipline in SKILL.md -- DEC-BAZAAR-015 |
| Phases 3-6 completed manually | Proves phases work; issue is context, not logic |
| Inline JSON dispatch construction is verbose | Factor into bazaar_prepare.py -- W3-3 |

---

### Initiative: Metanoia -- Hook System Restructuring
**Status:** active
**Started:** 2026-02-23
**Goal:** Safely transition from 11+3 individual hooks to 3 consolidated hooks with zero behavioral regressions

> The efficacy review (woolly-twirling-wolf.md) measured 200ms-1.5s overhead per Bash command
> and 800ms-12s per Write/Edit cycle, with 60-160ms wasted per hook on redundant source-lib.sh
> loading. The consolidation (pre-write.sh, post-write.sh, pre-bash.sh) was built in worktree
> hook-consolidation/ and passes 20/22 tests. However, code review found a critical safety defect:
> pre-write.sh has 7 advisory JSON outputs that don't exit, meaning a later deny can be silently
> dropped when Claude Code only parses one JSON object from stdout. This initiative fixes the
> defect, validates with real production traces, and rolls out gradually with instant rollback.

**Dominant Constraint:** safety (multi-JSON defect is a bypass risk; consolidated hooks must be provably equivalent to originals)

#### Goals
- REQ-GOAL-001: Zero behavioral regressions when switching from legacy hooks to consolidated hooks
- REQ-GOAL-002: Multi-JSON safety defect eliminated before any production exposure
- REQ-GOAL-003: Real-world trace corpus validates consolidated hooks against production inputs
- REQ-GOAL-004: Instant rollback to legacy hooks at any point during rollout

#### Non-Goals
- REQ-NOGO-001: context-lib.sh split into focused modules -- separate performance initiative
- REQ-NOGO-002: Adding new hook functionality -- behavioral equivalence only
- REQ-NOGO-003: Pruning noise generators (auto-review, code-review removal) -- out of scope
- REQ-NOGO-004: Hook timing instrumentation -- separate scope (Phase 3 of efficacy review)
- REQ-NOGO-005: session-init.sh or check-*.sh changes -- different subsystems

#### Requirements

**Must-Have (P0)**

- REQ-P0-001: All advisory JSON outputs in pre-write.sh, post-write.sh, and pre-bash.sh buffered.
  Acceptance: Given any gate sequence in a consolidated hook, When multiple gates produce output,
  Then exactly one JSON object appears on stdout (either a deny or combined advisories).

- REQ-P0-002: Buffered advisories folded into deny reason when deny occurs.
  Acceptance: Given Gate N emits advisory and Gate M emits deny (N < M), When the hook exits,
  Then the deny JSON includes the advisory text in permissionDecisionReason as supplementary context.

- REQ-P0-003: Differential test harness reports decision-level parity between old and new hooks.
  Acceptance: Given a hook input JSON, When harness runs old hooks (separate processes) and new
  hook (single process), Then permissionDecision fields match for all inputs.

- REQ-P0-004: Test corpus extracted from production traces covers real-world input distribution.
  Acceptance: Given 489 traces, When corpus extraction runs, Then 50-100 unique inputs per hook
  type (PreToolUse:Write|Edit, PreToolUse:Bash, PostToolUse:Write|Edit) are available as test data.

- REQ-P0-005: Differential harness reports zero unexpected decision differences on full corpus.
  Acceptance: Given extracted corpus of 150-300 inputs, When differential tests run, Then zero
  inputs produce different permissionDecision between old and new hooks.

- REQ-P0-006: Config swap mechanism enables instant rollback.
  Acceptance: Given settings-legacy.json and settings-metanoia.json, When `bash scripts/swap.sh legacy`
  runs, Then settings.json is replaced with legacy config and a backup is created.

- REQ-P0-007: Rollout follows pre-bash -> post-write -> pre-write order.
  Acceptance: Given Stage 1 config, When inspected, Then only pre-bash.sh is enabled
  (post-write and pre-write still use legacy individual hooks).

- REQ-P0-008: Each rollout stage bakes for 5+ sessions with zero regressions before advancing.
  Acceptance: Given Stage N is active, When 5 sessions complete without regressions, Then
  Stage N+1 can be enabled. Any regression resets the session count.

- REQ-P0-009: Legacy hooks archived after successful full bake.
  Acceptance: Given all 3 stages have passed bake, When merge completes, Then original
  individual hooks are moved to hooks/legacy/ and settings.json uses consolidated hooks only.

**Nice-to-Have (P1)**

- REQ-P1-001: Advisory text in consolidated hooks is contextually richer than individual hooks
  (since the consolidated hook has more state available from prior gates).
- REQ-P1-002: Differential harness produces a summary report (pass/fail counts, timing comparison).
- REQ-P1-003: Corpus extraction deduplicates by input characteristics, not just file path.

**Future Consideration (P2)**

- REQ-P2-001: context-lib.sh split into focused modules (core, git, plan, trace, doc) for further
  per-invocation startup reduction (~40-60% estimated).
- REQ-P2-002: Hook timing instrumentation to measure actual per-hook latency in production.
- REQ-P2-003: Adaptive context injection based on task phase (less context mid-implementation).

#### Definition of Done

Multi-JSON defect fixed in all 3 consolidated hooks. Differential harness validates behavioral
parity across 150-300 real-world inputs. Config swap mechanism enables instant rollback. All 3
rollout stages pass 5-session bake period. Worktree merged to main. Legacy hooks archived.
Zero safety regressions throughout entire process.

#### Architectural Decisions

- DEC-META-001: Output buffering pattern for multi-JSON prevention.
  Addresses: REQ-GOAL-002, REQ-P0-001, REQ-P0-002.
  Rationale: Buffer advisory JSON in shell variables. After all gates run: if any deny occurred,
  emit only the deny (with advisories folded into permissionDecisionReason). If no deny, combine
  all advisories into a single JSON with joined additionalContext. Guarantees exactly one JSON
  object on stdout per hook invocation.

- DEC-META-002: Differential test harness comparing old vs new hook outputs.
  Addresses: REQ-GOAL-001, REQ-P0-003, REQ-P0-005.
  Rationale: A script that takes a hook input JSON, pipes it through each old hook individually
  (capturing all outputs), then pipes it through the consolidated hook, and diffs the decisions.
  Old hooks run as separate processes just like Claude Code would invoke them. Comparison is on
  permissionDecision field (deny/allow). Advisory text differences are expected and acceptable.

- DEC-META-003: Extract test corpus from production traces.
  Addresses: REQ-GOAL-003, REQ-P0-004.
  Rationale: The 489 traces contain real hook inputs from production sessions. Extract unique
  PreToolUse:Write|Edit, PreToolUse:Bash, and PostToolUse:Write|Edit inputs. Deduplicate by
  (tool_name, file_path pattern, key input characteristics). Target: 50-100 unique inputs per
  hook type. Real-world distribution beats synthetic tests.

- DEC-META-004: Dual settings files with swap script for rollback.
  Addresses: REQ-GOAL-004, REQ-P0-006.
  Rationale: Maintain settings-legacy.json and settings-metanoia.json plus a swap.sh script.
  Rollback: `bash scripts/swap.sh legacy`. Each rollout stage modifies settings-metanoia.json
  to enable one more consolidated hook. Script validates JSON before overwriting and creates backup.

- DEC-META-005: Gradual rollout order: pre-bash first, post-write second, pre-write last.
  Addresses: REQ-GOAL-001, REQ-P0-007.
  Rationale: pre-bash.sh is safest (guard.sh denies always exit, doc-freshness is advisory-only,
  highest volume so latency savings felt immediately). post-write.sh is second (no deny semantics
  in PostToolUse). pre-write.sh is last (multi-JSON defect source, most complex gate logic).

- DEC-META-006: Bake period: 5+ sessions per rollout stage, zero regressions.
  Addresses: REQ-P0-008, REQ-P0-009.
  Rationale: Each stage runs for at least 5 normal work sessions before advancing. A regression
  resets the stage. After all 3 stages pass bake, full metanoia config becomes default and
  legacy hooks are archived.

#### Phase 1: Fix Multi-JSON Safety Defect
**Status:** planned
**Decision IDs:** DEC-META-001
**Requirements:** REQ-P0-001, REQ-P0-002
**Issues:** #29
**Definition of Done:**
- REQ-P0-001 satisfied: All advisory outputs buffered in variables, single JSON emitted at end
- REQ-P0-002 satisfied: Deny JSON includes buffered advisory text as supplementary context

##### Planned Decisions
- DEC-META-001: Output buffering pattern -- buffer advisories in variables, emit single JSON at end -- Addresses: REQ-P0-001, REQ-P0-002

##### Work Items

**W1-1: Implement output buffering in pre-write.sh**
- Add ADVISORIES array and DENY_JSON variable at top of script (after source-lib.sh)
- Replace all 7 non-exiting `cat <<EOF ... EOF` advisory blocks with `ADVISORIES+=("message")`
  - Line 88-95: Gate 2 small file bypass -> `ADVISORIES+=("Fast-mode bypass: ...")`
  - Line 175-184: Gate 2 plan staleness warn -> `ADVISORIES+=("Plan staleness: ...")`
  - Line 292-300: Gate 3 test strike 1 -> `ADVISORIES+=("Tests failing: ...")`
  - Line 404-411: Gate 4 mock strike 1 -> `ADVISORIES+=("Internal mocks: ...")`
  - Line 433-440: Gate 5 new markdown -> `ADVISORIES+=("New markdown file: ...")`
  - Line 543-550: Gate 5 @decision advisory -> `ADVISORIES+=("Missing @decision: ...")`
  - Line 554-561: Gate 5 doc header advisory -> `ADVISORIES+=("Missing doc header: ...")`
- Add emit_buffered_output function at bottom (before Gate 6 checkpoint):
  ```bash
  emit_buffered_output() {
      if [[ ${#ADVISORIES[@]} -gt 0 ]]; then
          local combined
          combined=$(printf '%s\n' "${ADVISORIES[@]}")
          local escaped
          escaped=$(echo "$combined" | jq -Rs '.[0:-1]')
          cat <<EMIT_EOF
  {
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "additionalContext": $escaped
    }
  }
  EMIT_EOF
      fi
  }
  ```
- Call emit_buffered_output after Gate 5, before Gate 6 (checkpoint is side-effect only)
- Deny blocks remain unchanged (they exit immediately, so no buffering needed)

**W1-2: Implement output buffering in post-write.sh**
- Same pattern: buffer advisory outputs from lint, track, plan-validate hooks
- PostToolUse has no deny semantics, so this is purely for combining multiple advisories
- Simpler: just collect all advisories and emit one combined JSON

**W1-3: Implement output buffering in pre-bash.sh**
- Buffer doc-freshness advisory and guard.sh advisory (if both fire)
- Guard.sh denies already exit immediately -- no change needed for deny paths

**W1-4: Re-run existing test harness**
- Run: `bash tmp/test-hooks.sh` in worktree
- Expected: all 22 tests pass (buffering doesn't change test semantics)
- Verify: no test expects multi-JSON output

**W1-5: Add multi-JSON prevention test**
- New test: construct input that triggers Gate 2 advisory AND Gate 3 deny
  (small file + failing test status + 2+ strikes)
- Assert: exactly 1 JSON object on stdout
- Assert: that JSON has permissionDecision = "deny"
- Assert: deny reason includes advisory context

##### Critical Files
- `hooks/pre-write.sh` -- 7 advisory output points need buffering (lines 88, 175, 292, 404, 433, 543, 554)
- `hooks/post-write.sh` -- Advisory accumulation from lint/track/validate
- `hooks/pre-bash.sh` -- doc-freshness + guard advisory stacking
- `tmp/test-hooks.sh` -- Existing 22-test harness

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Phase 2: Build Differential Test Harness
**Status:** planned
**Decision IDs:** DEC-META-002
**Requirements:** REQ-P0-003
**Issues:** #30
**Definition of Done:**
- REQ-P0-003 satisfied: Harness runs old hooks individually, new hook consolidated, diffs decisions

##### Planned Decisions
- DEC-META-002: Differential test harness -- run same input through old and new, compare permissionDecision -- Addresses: REQ-P0-003

##### Work Items

**W2-1: Create tests/test-differential.sh harness script**
- Input: a JSON file containing hook input payload
- For PreToolUse:Write|Edit inputs:
  - Run each of 6 old hooks (test-gate.sh, mock-gate.sh, branch-guard.sh, doc-gate.sh,
    plan-check.sh, checkpoint.sh) as separate processes, capture stdout
  - Run pre-write.sh, capture stdout
  - Extract permissionDecision from each old hook output (first deny wins, else allow)
  - Extract permissionDecision from new hook output
  - Compare: must match
- For PreToolUse:Bash inputs:
  - Run each of 3 old hooks (guard.sh, doc-freshness.sh, auto-review.sh) separately
  - Run pre-bash.sh, capture stdout
  - Compare permissionDecision
- For PostToolUse:Write|Edit inputs:
  - Run each of 5 old hooks (lint.sh, track.sh, code-review.sh, plan-validate.sh, test-runner.sh)
  - Run post-write.sh, capture stdout
  - Compare: advisory presence (PostToolUse has no deny)
- TAP-compatible output per input file

**W2-2: Create harness runner for batch inputs**
- Accepts a directory of JSON input files
- Runs test-differential.sh on each
- Produces summary: total inputs, matches, mismatches, errors
- Outputs mismatch details for debugging

**W2-3: Validate harness against existing 22 test inputs**
- Convert existing test-hooks.sh inputs to harness format
- Run harness on all 22
- Expected: 100% match (these are known-good inputs)

##### Critical Files
- `tests/test-differential.sh` -- New: core differential comparison logic
- `tests/run-differential.sh` -- New: batch runner with summary
- `tmp/test-hooks.sh` -- Reference: existing test inputs to convert

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Phase 3: Extract Test Corpus and Validate
**Status:** planned
**Decision IDs:** DEC-META-003
**Requirements:** REQ-P0-004, REQ-P0-005
**Issues:** #31
**Definition of Done:**
- REQ-P0-004 satisfied: 50-100 unique inputs per hook type extracted from traces
- REQ-P0-005 satisfied: Zero unexpected decision differences on full corpus

##### Planned Decisions
- DEC-META-003: Mine 489 traces for real hook inputs, deduplicate to 50-100 per type -- Addresses: REQ-P0-004, REQ-P0-005

##### Work Items

**W3-1: Create scripts/extract-corpus.sh**
- Scan traces/ and traces/oldTraces/ for hook invocation logs
- Extract PreToolUse:Write|Edit, PreToolUse:Bash, PostToolUse:Write|Edit payloads
- Deduplicate by: tool_name + basename(file_path) + content_length_bucket
- Write to tests/corpus/write-edit/, tests/corpus/bash/, tests/corpus/post-write/
- Target: 50-100 unique inputs per type

**W3-2: Run differential harness on extracted corpus**
- Run tests/run-differential.sh on each corpus directory
- Capture summary report
- Investigate any mismatches -- expected differences (advisory text) vs unexpected (decision changes)

**W3-3: Fix any discovered regressions**
- If differential tests reveal decision mismatches, fix the consolidated hook
- Re-run until zero unexpected differences
- Document any expected differences (advisory text improvements) in the report

##### Critical Files
- `scripts/extract-corpus.sh` -- New: trace mining and deduplication
- `tests/corpus/` -- New: extracted test inputs (gitignored, may contain sensitive paths)
- `tests/run-differential.sh` -- Batch runner from Phase 2

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Phase 4: Config Management
**Status:** planned
**Decision IDs:** DEC-META-004
**Requirements:** REQ-P0-006
**Issues:** #32
**Definition of Done:**
- REQ-P0-006 satisfied: swap.sh round-trips between legacy and metanoia configs without data loss

##### Planned Decisions
- DEC-META-004: Dual settings files + swap.sh with validation and backup -- Addresses: REQ-P0-006

##### Work Items

**W4-1: Create settings-legacy.json**
- Copy current settings.json to settings-legacy.json
- This is the known-good fallback configuration

**W4-2: Create settings-metanoia.json**
- Start as copy of settings-legacy.json
- This will be progressively modified in Phase 5 to enable consolidated hooks

**W4-3: Create scripts/swap.sh**
- Usage: `bash scripts/swap.sh [legacy|metanoia|status]`
- `legacy`: validate settings-legacy.json (jq check), backup settings.json, copy legacy
- `metanoia`: validate settings-metanoia.json (jq check), backup settings.json, copy metanoia
- `status`: report which config is active (diff against each, report match)
- Backups to settings.json.bak-{timestamp}
- Exit with error if source file doesn't exist or fails jq validation

**W4-4: Test swap script**
- Test: swap to legacy, verify settings.json matches settings-legacy.json
- Test: swap to metanoia, verify settings.json matches settings-metanoia.json
- Test: round-trip, verify no data loss
- Test: swap with invalid JSON in source, verify error and no overwrite
- Test: status command reports correct active config

##### Critical Files
- `settings-legacy.json` -- New: frozen copy of current settings.json
- `settings-metanoia.json` -- New: progressively modified during rollout
- `scripts/swap.sh` -- New: config swap with validation and backup

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Phase 5: Gradual Rollout
**Status:** planned
**Decision IDs:** DEC-META-005, DEC-META-006
**Requirements:** REQ-P0-007, REQ-P0-008
**Issues:** #33
**Definition of Done:**
- REQ-P0-007 satisfied: Rollout follows pre-bash -> post-write -> pre-write order
- REQ-P0-008 satisfied: Each stage bakes 5+ sessions with zero regressions

##### Planned Decisions
- DEC-META-005: Gradual rollout order -- pre-bash (safest) -> post-write (no deny) -> pre-write (most complex) -- Addresses: REQ-P0-007
- DEC-META-006: 5+ sessions per stage bake -- regression resets count -- Addresses: REQ-P0-008

##### Work Items

**W5-1: Stage 1 -- Enable pre-bash.sh**
- Modify settings-metanoia.json: replace guard.sh + doc-freshness.sh + auto-review.sh PreToolUse:Bash
  entries with single pre-bash.sh entry
- Copy pre-bash.sh from worktree to hooks/
- `bash scripts/swap.sh metanoia`
- Bake: 5 sessions of normal work
- Monitor: no false denies, no missed denies, guard.sh safety patterns still enforced

**W5-2: Stage 2 -- Enable post-write.sh**
- Modify settings-metanoia.json: replace lint.sh + track.sh + code-review.sh + plan-validate.sh +
  test-runner.sh PostToolUse:Write|Edit entries with single post-write.sh entry
  (keep test-runner.sh as async -- post-write.sh handles sync hooks only)
- Copy post-write.sh from worktree to hooks/
- `bash scripts/swap.sh metanoia` (refresh)
- Bake: 5 sessions

**W5-3: Stage 3 -- Enable pre-write.sh**
- Modify settings-metanoia.json: replace test-gate.sh + mock-gate.sh + branch-guard.sh +
  doc-gate.sh + plan-check.sh + checkpoint.sh PreToolUse:Write|Edit entries with single
  pre-write.sh entry
- Copy pre-write.sh from worktree to hooks/
- `bash scripts/swap.sh metanoia` (refresh)
- Bake: 5 sessions
- This is the highest-risk stage -- the multi-JSON fix (Phase 1) must be solid

##### Critical Files
- `settings-metanoia.json` -- Progressive modifications per stage
- `hooks/pre-bash.sh` -- Copied from worktree at Stage 1
- `hooks/post-write.sh` -- Copied from worktree at Stage 2
- `hooks/pre-write.sh` -- Copied from worktree at Stage 3
- `scripts/swap.sh` -- Activation and rollback mechanism

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Phase 6: Bake and Merge
**Status:** planned
**Decision IDs:** DEC-META-006
**Requirements:** REQ-P0-009
**Issues:** #34
**Definition of Done:**
- REQ-P0-009 satisfied: Legacy hooks archived, consolidated hooks on main, zero regressions

##### Planned Decisions
- DEC-META-006: Full bake before merge -- 5+ additional sessions after all stages active -- Addresses: REQ-P0-009

##### Work Items

**W6-1: Full bake period**
- Run with all 3 consolidated hooks active for 5+ sessions
- Run differential harness one final time on full corpus
- Confirm zero regressions

**W6-2: Archive legacy hooks**
- Create hooks/legacy/ directory
- Move original individual hooks:
  - test-gate.sh, mock-gate.sh, branch-guard.sh, doc-gate.sh, plan-check.sh, checkpoint.sh
  - lint.sh, track.sh, code-review.sh, plan-validate.sh (test-runner.sh stays -- async)
  - doc-freshness.sh, auto-review.sh
- Keep them available for reference and emergency rollback

**W6-3: Finalize settings.json**
- settings-metanoia.json becomes the permanent settings.json
- Remove settings-legacy.json and settings-metanoia.json
- Keep scripts/swap.sh for potential future use

**W6-4: Merge worktree to main**
- Guardian merge of hook-consolidation worktree
- Verify: all tests pass on main
- Clean up worktree

**W6-5: Update documentation**
- Update HOOKS.md: document consolidated hooks, reference legacy/ for history
- Update ARCHITECTURE.md: hook count reduced from 28 to ~18
- Close related GitHub issues

##### Critical Files
- `hooks/legacy/` -- New directory for archived individual hooks
- `settings.json` -- Finalized with consolidated hook entries
- `hooks/HOOKS.md` -- Documentation update
- `ARCHITECTURE.md` -- Hook count update

##### Decision Log
<!-- Guardian appends here after phase completion -->

#### Metanoia Worktree Strategy

Phases 1-3 work in the existing worktree:
- **Phases 1-3:** `~/.claude/.worktrees/hook-consolidation` on branch `feature/hook-consolidation`

Phases 4-5 work on main (config changes, not source code):
- **Phase 4:** On main (scripts/swap.sh, settings files are config, not source)
- **Phase 5:** On main (config swap activation)

Phase 6 is the merge:
- **Phase 6:** Merge from `feature/hook-consolidation` to main

#### Metanoia References

##### Efficacy Review
- `plans/woolly-twirling-wolf.md` -- Full hook system efficacy review with cost analysis
- Measured: 200ms-1.5s per Bash, 800ms-12s per Write/Edit overhead
- Recommended: selective consolidation (Phase 1), pruning (Phase 2), new infrastructure (Phase 3)

##### Existing Worktree Code
| File | Lines | Status |
|------|-------|--------|
| `hooks/pre-write.sh` | 657 | Built, needs multi-JSON fix |
| `hooks/post-write.sh` | 482 | Built, needs multi-JSON fix |
| `hooks/pre-bash.sh` | 592 | Built, needs multi-JSON fix |
| `tmp/test-hooks.sh` | 200+ | 20/22 tests passing |

##### Multi-JSON Defect Map
| Line | Gate | Type | Risk |
|------|------|------|------|
| 88 | Gate 2: plan-check (small file) | advisory, no exit | **UNSAFE** |
| 175 | Gate 2: plan-check (stale warn) | advisory, no exit | **UNSAFE** |
| 292 | Gate 3: test-gate (strike 1) | advisory, no exit | **UNSAFE** |
| 404 | Gate 4: mock-gate (strike 1) | advisory, no exit | **UNSAFE** |
| 433 | Gate 5: doc-gate (new markdown) | advisory, no exit | **UNSAFE** |
| 543 | Gate 5: doc-gate (@decision) | advisory, no exit | **UNSAFE** |
| 554 | Gate 5: doc-gate (header) | advisory, no exit | **UNSAFE** |

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
