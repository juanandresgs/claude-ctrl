# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `feature/project-isolation`: Cross-project state isolation via 8-char SHA-256 project hash — scopes .proof-status, .active-worktree-path, and trace markers per project root to prevent state contamination across concurrent Claude Code sessions; three-tier backward-compatible lookup; 20 new isolation tests

### Changed
- `feature/observatory-stdout`: Observatory report.sh now prints a concise stdout summary (regressions, health, signals, batches) after writing the full report file, so callers get actionable output without reading the file

### Fixed
- `fix/sigpipe-crashes`: SIGPIPE (exit 141) crashes in session-init.sh and context-lib.sh when MASTER_PLAN.md has large sections — replaced 20 pipe patterns with SIGPIPE-safe equivalents (awk inline limits, bash builtins, single-pass awk); added 14-test SIGPIPE resistance suite
- `fix/stale-marker-blocking-tester`: Stale `.active-*` marker race condition blocking tester dispatch — reorder `finalize_trace` before timeout-heavy ops in check-implementer.sh and check-guardian.sh, add marker cleanup in `refinalize_trace()`, add completed-status fast path in task-track.sh Gate B

### Added
- `feature/plan-redesign-tests`: Phase 4 test suite for living plan format — 16 new tests across 2 suites (test-plan-lifecycle.sh, test-plan-injection.sh) validating initiative lifecycle edge cases and bounded session injection; bug fix for empty Active Initiatives section returning active instead of dormant (#142)

### Changed
- `feature/living-plan-hooks`: Living MASTER_PLAN format — initiative-level lifecycle with dormant/active states, get_plan_status() rewrite, plan-validate.sh structural validation, bounded session-init injection (796->81 lines), compress_initiative() for archival (#140)
- `refactor/shared-library`: Phase 8 shared library consolidation — 13 hooks converted from raw jq to `get_field()`, `get_session_changes()` ported to context-lib.sh with glob fallback, SOURCE_EXTENSIONS unified, context-lib.sh chmod 755; plus DEC-PROOF-PATH-003 meta-repo proof-status double-nesting fix (#7, #137)
- **Planner create-or-amend workflow** — `agents/planner.md` rewritten (391->629 lines) to support both creating new MASTER_PLAN.md and amending existing living documents with new initiatives; auto-detects plan format via `## Identity` marker (#139)
- **Tester agent rewrite** — 8 targeted fixes for 37.5% failure rate: feature-match validation, test infrastructure discovery, early proof-status write, hook/script table split, worktree path safety, meta-infra exception, retry limits, mandatory trace protocol

### Added
- **Documentation audit** — 38 discrepancies resolved: hardcoded hook counts removed, 3 undocumented hooks documented, /approve eradicated, updatedInput contradiction corrected, tester max_turns fixed
- **doc-freshness.sh** — PreToolUse:Bash hook enforcing documentation freshness at merge time; blocks merges to main when tracked docs are critically stale
- **check-explore.sh** — SubagentStop:Explore hook for post-exploration validation of Explore agent output quality
- **check-general-purpose.sh** — SubagentStop:general-purpose hook for post-execution validation of general-purpose agent output quality
- **Worktree Sweep** — Three-way reconciliation (filesystem/git/registry) with session-init orphan scan, post-merge Check 7b auto-cleanup, and proof-status leak fix (`scripts/worktree-roster.sh`, `hooks/session-init.sh`, `hooks/check-guardian.sh`)
- **Trace Analysis System** — Agent trace indexing and outcome classification (`hooks/context-lib.sh`)
- **Tester Agent** — Fourth agent for end-to-end verification with auto-verify fast path (`agents/tester.md`, `hooks/check-tester.sh`)
- **Checkpoint System** — Git ref-based snapshots before writes with `/rewind` restore skill (`hooks/checkpoint.sh`, `skills/rewind/`)
- **CWD Recovery** — Three-path system for worktree deletion CWD death spiral: directed recovery (Check 0.5 Path A), canary-based recovery (Path B), prevention (Check 0.75) in `guard.sh`
- **Cross-Session Learning** — Session-aware hooks with trajectory guidance, friction pattern detection (v2 Phase 4)
- **Session Summaries in Commits** — Structured session context embedded in commit metadata (v2 Phase 2)
- **Session-Aware Hooks** — Trajectory-based guidance, compaction-safe resume directives (v2 Phase 3)
- **SDLC Integrity Layer** — Guard hardening, state hygiene, preflight checks (Phase A)
- **Tester Completeness Gate** — Check 3 in check-tester.sh validates verification coverage
- **Deterministic Comparison Matrix** — Deep-research two-pass matching with content-based analysis
- **Environment Variable Handoff** — Implementer-to-tester environment variable propagation
- **/diagnose Skill** — System health checks integrated into agent pipeline
- **/approve Command** — Quick-approve verification gate
- **Guard Check 0.75** — Subshell containment for `cd` into `.worktrees/` directories
- Security policy (SECURITY.md) with vulnerability reporting guidelines
- Changelog following Keep a Changelog format
- Standards compliance documentation
- ARCHITECTURE.md comprehensive technical reference (this release)

### Changed
- **Auto-verify restructured** — Runs before heavy I/O for faster verification path
- **Observatory assessment overhaul** — Comprehensive reports, comparison matrix, deferred lifecycle management
- **Observatory signal catalog** — Extended from 5 to 12 signals across 4 categories
- **Session-init performance** — Startup latency reduced from 2-10s to 0.3-2s with 4 targeted fixes
- **Guardian auto-cleans worktrees** after merge instead of delegating to user
- **Deep-research matrix matching** — Simplified to heading-only with LLM unmatched_hints
- GitHub Actions now pin to commit SHAs for supply chain security
- Guard rewrite calls converted to deny — `updatedInput` not supported in PreToolUse hooks

### Fixed
- Observatory SUG-ID instability across runs (force state v1→v3 migration)
- Observatory duration UTC timezone bug in finalize_trace
- Guard long-form force-deletion variant detection in branch guard
- Check 5 worktree-remove crash on paths with spaces
- Proof-status path mismatch in git worktree scenarios
- Verification gate: escape hatch, empty-prompt awareness, env whitelist
- Tester AND logic for completeness gate + finalize_trace verification fallback
- Post-compaction amnesia with computed resume directives
- Meta-repo exemption for guard.sh proof-status deletion check
- Subagent tracker scoped to per-session thread
- Hook library race condition during git merge (session-scoped caching)
- Cross-platform stat for Linux CI (4 trace contract test failures)
- Shellcheck failures: tilde bug + expanded exclusions
- README documentation for `update-check.sh` location (lives in `scripts/`, called by `session-init.sh`)
- Observatory .test-status fallback to finalize_trace test result detection

### Security
- Cross-project git guard prevents accidental operations on wrong repositories
- Credential exposure protection via `.env` read deny rules

## [2.0.0] - 2026-02-08

### Added
- **Core System Architecture**
  - Three-agent system: Planner, Implementer, Guardian with role separation
  - 20+ deterministic hooks across 8 lifecycle events
  - Worktree-based isolation with main branch protection
  - Test-first enforcement via `test-gate.sh` and proof-of-work verification
  - Documentation requirements via `doc-gate.sh` for 50+ line files

- **Decision Intelligence**
  - `/decide` skill: Interactive decision configurator with HTML wizards
  - Bidirectional decision tracking: `MASTER_PLAN.md` ↔ `@decision` annotations in code
  - Plan lifecycle state machine with completed-plan source write protection
  - `surface.sh` decision audit on session end

- **Research & Context**
  - `deep-research` skill: Multi-model synthesis across research providers
  - `prd` skill: Deep-dive product requirement documents
  - `context-preservation` skill: Structured summaries across compaction
  - Dual-path compaction preservation (persistent file + directive)

- **Backlog Management**
  - `/backlog` command: Unified todo interface over GitHub Issues
  - Global and project-scoped issue tracking
  - Component grouping and image attachment support
  - Staleness detection (14-day threshold)

- **Safety & Enforcement**
  - `guard.sh`: Nuclear deny for destructive commands, transparent rewrites for `/tmp/` → `tmp/`, `--force` → `--force-with-lease`
  - `branch-guard.sh`: Blocks source writes on main, enforces worktree workflow
  - `mock-gate.sh`: Prevents internal mocking, allows external boundary mocks only
  - `plan-check.sh`: Requires MASTER_PLAN.md before implementation
  - Safe cleanup utilities to prevent CWD deletion bugs

- **Session Lifecycle**
  - `session-init.sh`: Git state, plan status, worktrees, todo HUD injection on startup
  - `prompt-submit.sh`: Keyword-based context injection, deferred-work detection
  - `session-summary.sh`: Decision audit, worktree status, forward momentum check
  - `forward-motion.sh`: Ensures user receives actionable next steps

- **Subagent Quality Gates**
  - `check-planner.sh`: Verifies MASTER_PLAN.md exists and is valid
  - `check-implementer.sh`: Enforces proof-of-work (live demo + tests) before commits
  - `check-guardian.sh`: Validates commit message format and issue linkage
  - Task tracking via `task-track.sh` for subagent state monitoring

- **Code Quality**
  - `lint.sh`: Auto-detect and run linters (shellcheck, python, etc.) with feedback loop
  - `code-review.sh`: Optional LLM-based review integration
  - `auto-review.sh`: Interpreter analyzer (distinguishes safe vs risky python/node/ruby/perl)
  - `test-runner.sh`: Async test execution with `.test-status` evidence file

- **Testing Infrastructure**
  - Contract tests for all hooks (`tests/run-hooks.sh`)
  - 54/54 passing test suite
  - GitHub Actions CI with shellcheck and contract validation
  - Test harness auto-update system

### Changed
- Promoted 16 safe utilities to global allow list in `settings.json`
- Removed LLM review hook (external command review discontinued)
- Removed version system in favor of git tags
- Professionalized repository structure with issue templates

### Fixed
- Inlined update-check into session-init to eliminate startup race condition
- Wired subagent tracking to status bar via PreToolUse:Task hook
- Replaced bare `rm -rf` with `safe_cleanup` in test runner
- Resolved all shellcheck warnings
- Fixed Guardian bypass via git global flags (enforced dispatch for commit/push/merge)
- Fixed test harness subshell bug that silently swallowed failures
- Prevented CWD-deletion ENOENT in Stop hooks
- Recognized meta-repo worktrees in `guard.sh`
- Anchored Category 5 nuclear deny to command position
- Stopped deep research from silently swallowing provider failures

### Security
- Cross-project git guard prevents accidental operations on wrong repositories
- Credential exposure protection via `.env` read deny rules
- Hook input sanitization via `log.sh` shared library
- Safe temporary directory handling (project `tmp/`, not `/tmp/`)

[Unreleased]: https://github.com/juanandresgs/claude-ctrl/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/juanandresgs/claude-ctrl/releases/tag/v2.0.0
