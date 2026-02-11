# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Security policy (SECURITY.md) with vulnerability reporting guidelines
- Changelog following Keep a Changelog format
- Standards compliance documentation

### Fixed
- README documentation for `update-check.sh` location (lives in `scripts/`, called by `session-init.sh`)

### Changed
- GitHub Actions now pin to commit SHAs for supply chain security

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

- **Repository Health**
  - `/uplevel` skill: Six-dimensional health scoring (security, testing, quality, docs, staleness, standards)
  - Automated issue creation from audit findings
  - Integration with `/decide` for remediation planning

- **Research & Context**
  - `deep-research` skill: Multi-model synthesis (OpenAI + Perplexity + Gemini)
  - `last30days` skill: Recent community discussions with engagement metrics
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

[Unreleased]: https://github.com/juanandresgs/claude-system/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/juanandresgs/claude-system/releases/tag/v2.0.0
