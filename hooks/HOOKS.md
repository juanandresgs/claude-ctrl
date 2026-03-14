# Hook System Reference

Technical reference for the Claude Code hook system. For philosophy and workflow, see `../CLAUDE.md`. For the summary table, see `../README.md`. For system architecture and visibility, see `../ARCHITECTURE.md`.

---

## Protocol

All hooks receive JSON on **stdin** and emit JSON on **stdout**. Stderr is for logging only. Exit code 0 = success. Non-zero = hook error (logged, does not block).

> **FD inheritance rule:** Background processes spawned in hooks (`&`) MUST redirect both stdout and stderr (`>/dev/null 2>&1 &`). When a test or tool captures hook output via `$()`, the command substitution creates an internal pipe. Background subshells inherit the pipe's write-end FDs — the `$()` blocks until ALL holders close them. A 5-minute heartbeat holding inherited FDs hangs the caller for 5 minutes. This applies even when the background process produces no output — FD inheritance is orthogonal to actual writes. See DEC-GUARDIAN-HEARTBEAT-002.

> **Caveat — SessionEnd + stderr:** Claude Code reports SessionEnd hooks as "failed" if they produce any stderr output, even with exit code 0. Suppress stderr in SessionEnd hooks (`exec 2>/dev/null`) since diagnostic messages have no audience at session termination.

### Stdin Format

```json
{
  "tool_name": "Write|Edit|Bash|...",
  "tool_input": { "file_path": "...", "command": "..." },
  "cwd": "/current/working/directory"
}
```

SubagentStart/SubagentStop hooks receive `{"agent_type": "planner|implementer|tester|guardian|Explore|general-purpose", ...}`. SubagentStop hooks additionally receive `{"last_assistant_message": "...", "agent_id": "...", "agent_transcript_path": "...", "stop_hook_active": false}` — use `.last_assistant_message` to read the agent's final response text. Stop hooks (non-subagent) receive `{"stop_hook_active": true/false}`.

### Stdout Responses (PreToolUse only)

**Deny** — block the tool call:
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Explanation shown to the model"
  }
}
```

**Rewrite** — transparently modify the command (model sees rewritten version):
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "Explanation",
    "updatedInput": { "command": "rewritten command here" }
  }
}
```

**Advisory** — inject context without blocking:
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "Warning or guidance text"
  }
}
```

PostToolUse hooks use `additionalContext` for feedback. Exit code 2 in lint.sh triggers a feedback loop (model retries with linter output).

### Stop Hook Responses

Stop hooks have a **different schema** from PreToolUse/PostToolUse. They do NOT accept `hookSpecificOutput`. Valid fields:

**System message** — inject context into the next turn:
```json
{
  "systemMessage": "Summary text shown as system-reminder"
}
```

> **Note**: `additionalContext` is NOT a valid field for Stop hooks. It may be silently
> processed but renders as passive context, not a `<system-reminder>`. Use `systemMessage`
> for any directive that the model must act on.

**Block** — prevent the response from completing (rare):
```json
{
  "decision": "block",
  "reason": "Explanation of why the response was blocked"
}
```

Stop hooks receive `{"stop_hook_active": true/false}` on stdin. Check `stop_hook_active` to prevent re-firing loops (if a Stop hook's `systemMessage` triggers another model response, the next Stop invocation will have `stop_hook_active: true`). Note: SubagentStop hooks use `last_assistant_message` for the agent response text — see the Stdin Format note above.

### Rewrite Pattern (Non-Functional in PreToolUse)

**Important:** `updatedInput` (the rewrite mechanism) is NOT supported in PreToolUse
hooks — it silently fails. The `rewrite()` function in pre-bash.sh produces valid JSON
output but the command is NOT modified. See upstream issue anthropics/claude-code#26506.

The `updatedInput` format below is documented for reference only:
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "Explanation",
    "updatedInput": { "command": "rewritten command here" }
  }
}
```

All active command corrections in pre-bash.sh use `deny()` instead, with the corrected
safe command in the reason message so the model can resubmit. Examples:
- `/tmp/` writes → denied; model directed to use project `tmp/` directory (Check 1)
- `--force` → denied with `--force-with-lease` alternative in message (Check 3)
- `git worktree remove` → denied; corrected safe-CWD command in message (Check 5)
- `rm -rf .worktrees/` → denied; corrected safe-CWD command in message (Check 5b)

---

## Shared Libraries

### log.sh — Input handling and logging

Source with: `source "$(dirname "$0")/log.sh"`

| Function | Purpose |
|----------|---------|
| `read_input` | Read and cache stdin JSON into `$HOOK_INPUT` (call once) |
| `get_field <jq_path>` | Extract field from cached input (e.g., `get_field '.tool_input.command'`) |
| `detect_project_root` | Returns `$CLAUDE_PROJECT_DIR` → git root → `$HOME` (fallback chain) |
| `is_same_project(dir)` | Compares `git rev-parse --git-common-dir` for current project vs target dir. Returns 0 if same repo (handles worktrees). Defined in `guard.sh` |
| `extract_git_target_dir(cmd)` | Parses `cd /path && git ...` or `git -C /path ...` to find git target directory. Falls back to CWD. Defined in `guard.sh` |
| `resolve_proof_file <root>` | **Deprecated (W5-2)** — returns empty string. Proof state is now in SQLite via `proof_state_get()`/`proof_state_set()` in `state-lib.sh`. |
| `write_proof_status <status> [root]` | Writes proof status to SQLite via `proof_state_set()` (W5-2: SQLite-only, no flat-file writes). Enforces monotonic lattice atomically. |
| `log_info <stage> <msg>` | Human-readable stderr log |
| `log_json <stage> <msg>` | Structured JSON stderr log |

### Domain Library Functions (formerly in context-lib.sh)

> **Architecture note:** `context-lib.sh` was a 2,221-line monolith decomposed into focused
> domain libraries (issue #65 removed the backward-compatibility shim entirely). All callers
> now source `source-lib.sh` and call `require_*()` for the domain libraries they need.
> Use `source "$(dirname "$0")/source-lib.sh"` as the entry point for all hooks and tests.

Key functions across domain libraries (use `require_*()` to load the containing library):

| Function | Domain Library | Populates |
|----------|---------------|-----------|
| `get_git_state <root>` | git-lib.sh | `$GIT_BRANCH`, `$GIT_DIRTY_COUNT`, `$GIT_WORKTREES`, `$GIT_WT_COUNT` |
| `get_plan_status <root>` | plan-lib.sh | `$PLAN_EXISTS`, `$PLAN_PHASE`, `$PLAN_TOTAL_PHASES`, `$PLAN_SOURCE_CHURN_PCT`, `$PLAN_LIFECYCLE` |
| `get_session_changes <root>` | session-lib.sh | `$SESSION_CHANGED_COUNT`, `$SESSION_FILE` |
| `get_drift_data <root>` | session-lib.sh | `$DRIFT_UNPLANNED_COUNT`, `$DRIFT_UNIMPLEMENTED_COUNT`, `$DRIFT_LAST_AUDIT_EPOCH` |
| `get_research_status <root>` | session-lib.sh | `$RESEARCH_EXISTS`, `$RESEARCH_ENTRY_COUNT` |
| `is_source_file <path>` | core-lib.sh | Tests against `$SOURCE_EXTENSIONS` regex |
| `is_skippable_path <path>` | core-lib.sh | Tests for config/test/vendor/generated paths |
| `validate_state_file <file> <format>` | core-lib.sh | Guards against corrupt state file reads |
| `atomic_write <file> <content>` | core-lib.sh | Write via temp-file-then-mv (DEC-INTEGRITY-004) |
| `safe_cleanup <target> [fallback]` | core-lib.sh | `rm -rf` with CWD safety |
| `init_trace <agent_type> <project>` | trace-lib.sh | Create trace directory, manifest.json, active marker |
| `finalize_trace <trace_dir> <outcome>` | trace-lib.sh | Close manifest, remove active marker, append to index |
| `write_statusline_cache <root>` | session-lib.sh | Atomic cache write for status bar enrichment |
| `get_session_summary_context <root>` | session-lib.sh | Trajectory summary for compaction preservation |
| `build_resume_directive <root>` | session-lib.sh | Priority-ordered resume instruction from session state |
| `compress_initiative <plan_file> <name>` | plan-lib.sh | Archive completed initiative to Completed Initiatives table |
| `append_audit <root> <event> <detail>` | core-lib.sh | Appends to `.claude/.audit-log` |

`$SOURCE_EXTENSIONS` is the single source of truth for source file detection: `ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh`

### source-lib.sh — Bootstrap loader and lazy domain loader

Source with: `source "$(dirname "$0")/source-lib.sh"`

Bootstrap loader that sources `log.sh` and `core-lib.sh`. Provides `require_*()` lazy loaders
for domain libraries. All hooks source this file as their first dependency.

**What loads immediately:**
- `log.sh` — JSON I/O, stdin caching, path utilities
- `core-lib.sh` — deny/allow/advisory output, atomic writes

**What loads on demand via `require_*()`:**

| Function | Library | Purpose |
|----------|---------|---------|
| `require_git()` | `git-lib.sh` | Git state detection, branch guards, worktree safety |
| `require_plan()` | `plan-lib.sh` | Plan lifecycle, staleness scoring, MASTER_PLAN.md parsing |
| `require_trace()` | `trace-lib.sh` | Trace init/finalize, audit trail, agent markers |
| `require_session()` | `session-lib.sh` | Session summary, trajectory, compaction context |
| `require_doc()` | `doc-lib.sh` | @decision enforcement, doc-gate rules |
| `require_ci()` | `ci-lib.sh` | CI detection, workflow helpers |
| `require_state()` | `state-lib.sh` | Per-worktree state management and isolation |

Each `require_*()` is idempotent — calling `require_git()` twice is a no-op. Hooks that need
multiple domains call them explicitly (e.g., `require_git; require_plan`). `require_all()` was
removed in Phase 3 (dead code audit — no production hook called it).

**Example hook usage:**
```bash
source "$(dirname "$0")/source-lib.sh"
require_git          # only load git-lib.sh
get_git_state "$root"
echo "Branch: $GIT_BRANCH"
```

### state-registry.sh — State file registry

Not a hook — a declarative registry of every state file the hook system writes.
Format: `PATTERN|SCOPE|WRITER(S)|DESCRIPTION`. Used by `tests/test-state-registry.sh`
to lint hook source files and detect unregistered writes. Scopes: global, per-project
(keyed by 8-char SHA-256 hash), per-session, trace-global, trace-scoped.

---

## Execution Order (Session Lifecycle)

> **Metanoia architecture** (deployed 2026-02-23): 17 individual hooks consolidated into
> 4 entry points + 7 domain libraries. The behavioral contracts are identical — only the
> entry points changed.

```
SessionStart    → session-init.sh
                    ↓
UserPromptSubmit → prompt-submit.sh
                    ↓
PreToolUse:Bash → pre-bash.sh (consolidated: guard.sh + doc-freshness.sh)
PreToolUse:W/E  → pre-write.sh (consolidated: branch-guard + doc-gate + test-gate + mock-gate + plan-check + checkpoint)
                    ↓
[Tool executes]
                    ↓
PostToolUse:W/E → post-write.sh (consolidated: track + plan-validate)
PostToolUse:Task → post-task.sh (auto-verify on tester completion)
                    ↓
SubagentStart   → subagent-start.sh
SubagentStop    → check-planner.sh | check-implementer.sh | check-tester.sh | check-guardian.sh | check-explore.sh | check-general-purpose.sh
                    ↓
Stop            → stop.sh (consolidated: surface + session-summary + forward-motion)
                    ↓
PreCompact      → compact-preserve.sh
                    ↓
SessionEnd      → session-end.sh
```

Hooks within the same event run **sequentially** in array order from settings.json. A deny from any PreToolUse hook stops the tool call — later hooks in the chain don't run.

---

## Hook Details

### Consolidated Hooks (Metanoia)

| Hook | Event | Absorbs |
|------|-------|---------|
| **pre-bash.sh** | PreToolUse:Bash | guard.sh, doc-freshness.sh |
| **pre-write.sh** | PreToolUse:Write\|Edit | branch-guard, doc-gate, test-gate, mock-gate, plan-check, checkpoint |
| **post-write.sh** | PostToolUse:Write\|Edit | track.sh, plan-validate.sh |
| **stop.sh** | Stop | surface, session-summary, forward-motion |

### Domain Libraries (Metanoia)

| Library | Purpose |
|---------|--------|
| **core-lib.sh** | Input handling, JSON output, deny\/allow\/advisory, atomic writes |
| **doc-lib.sh** | Documentation freshness, doc-gate rules, @decision enforcement |
| **git-lib.sh** | Git state detection, branch guards, worktree safety checks |
| **plan-lib.sh** | Plan lifecycle, plan-check, plan-validate, staleness scoring |
| **session-lib.sh** | Session summary, trajectory, forward motion, compaction context |
| **state-lib.sh** | Per-worktree state management, workflow isolation |
| **trace-lib.sh** | Trace init\/finalize, compliance recording, audit trail |

### PreToolUse — Block Before Execution

| Hook | Matcher | What It Does |
|------|---------|--------------|
| **pre-bash.sh** | Bash | Consolidated safety gate: 11 checks covering nuclear deny (7 catastrophic command categories), CWD protection (denies cd into .worktrees/), `/tmp/` denial, main branch commit blocks, force push deny-with-correction, destructive git blocks (`reset --hard`, `clean -f`, `branch -D`), test evidence + proof-of-work verification for commits/merges, agent proof-status write blocking, proof-status deletion protection. Doc-freshness enforcement at merge time. All git patterns use flag-tolerant matching. Trailing boundaries reject hyphenated subcommands |
| **pre-write.sh** | Write\|Edit | Consolidated write gate: checkpoint snapshots (git ref-based), branch-guard (blocks main), plan-check (requires MASTER_PLAN.md, composite staleness scoring), test-gate (escalating: warn then block on failing tests), mock-gate (escalating: warn then block on internal mocks), defprog-gate (escalating: detects silent exception swallowing, `@defprog-exempt` bypass), doc-gate (headers + @decision on 50+ line files), Gate 1.5 dispatch enforcement (blocks orchestrator source writes via SESSION_ID comparison) |
| **task-track.sh** | Task | Agent dispatch gates: tracks subagent state, gates Guardian on verified proof, updates status bar |

### PostToolUse — Feedback After Execution

| Hook | Matcher | What It Does |
|------|---------|--------------|
| **lint.sh** | Write\|Edit | Auto-detects project linter (ruff, black, prettier, eslint, etc.), runs on modified files. Exit 2 = feedback loop (Claude retries the fix automatically) |
| **track.sh** | Write\|Edit | Records file changes to `.session-changes-$SESSION_ID`. Also invalidates `.proof-status` when verified source files change — ensuring the user always verifies the final state, not an intermediate one |
| **code-review.sh** | Write\|Edit | Fires on 20+ line source files (skips tests and config). Injects diff context and suggests `mcp__multi__codereview` for multi-model analysis. Falls back silently if Multi-MCP is unavailable |
| **plan-validate.sh** | Write\|Edit | Validates MASTER_PLAN.md structure on every write. Living-document format: checks for `## Identity`, `## Architecture`, `## Decision Log`, `### Initiative:` headers with `**Status:**` fields. Legacy format: phase Status fields (`planned`/`in-progress`/`completed`), original intent section preserved. Both formats: DEC-COMPONENT-NNN ID format, REQ-{CATEGORY}-NNN ID format. Advisory warnings for missing Goals/Non-Goals/Requirements/Success Metrics sections. Exit 2 = feedback loop with fix instructions. Old format passes with warning (not error) for backward compat. |
| **test-runner.sh** | Write\|Edit | **Async** — doesn't block Claude. Auto-detects test framework (pytest, vitest, jest, npm-test, cargo-test, go-test). 2s debounce lets rapid writes settle. 10s cooldown between runs. Lock file ensures single instance (kills previous run if superseded). Writes `.test-status` (`pass\|0\|timestamp` or `fail\|count\|timestamp`) consumed by test-gate.sh and guard.sh. Reports results via `systemMessage` |
| **skill-result.sh** | Skill | Reads `.skill-result.md` from forked skills, injects as `additionalContext` to parent session. Surfaces research/analysis results from `context: fork` skills (deep-research, last30days, decide, consume-content, prd, uplevel) back to orchestrator. Truncates files over 4000 bytes. Deletes file after reading to prevent stale results. Exit 0 silently if file doesn't exist |
| **webfetch-fallback.sh** | WebFetch | Fires when WebFetch tool fails (non-200 response or error). Suggests `mcp__fetch__fetch` as alternative fetch method. Exit 0 (advisory only) |
| **playwright-cleanup.sh** | mcp__playwright__browser_snapshot | Cleanup after Playwright browser snapshots. Prevents stale browser state accumulation |
| **post-task.sh** | Task | PostToolUse:Task handler that detects tester completions and performs auto-verify. Reads summary.md from the tester trace via the active-tester breadcrumb (PostToolUse lacks `last_assistant_message`), validates `AUTOVERIFY: CLEAN` signal with secondary checks (**High** confidence, no **Medium**/**Low**, no "Partially verified", no non-environmental "Not tested"), writes `verified` to proof-status at all three paths (worktree, orchestrator scoped, orchestrator legacy). Emits `AUTO-VERIFIED` directive in `additionalContext` on success. Replaces the dead SubagentStop:tester auto-verify path. Safety net: if proof-status is missing when tester completes, writes `needs-verification` so the manual approval flow can proceed |

### Session Lifecycle

| Hook | Event | What It Does |
|------|-------|--------------|
| **session-init.sh** | SessionStart | Calls update-check.sh inline (fixes race condition where parallel hooks caused one-session-late notifications), then injects git state, harness update status, MASTER_PLAN.md status, active worktrees, todo HUD, unresolved agent findings, preserved context from pre-compaction. Clears stale `.test-status` from previous sessions (prevents old passes from satisfying the commit gate). **Clears stale `.proof-status` (crash recovery)**: at session start, if no agent markers are active, any `.proof-status` is removed — a verified status from a crashed session would otherwise bypass the proof gate for unrelated future work. Resets prompt count for first-prompt fallback. **Plan injection (living-document format)**: extracts `## Identity` + active initiative sections + last 10 Decision Log entries, bounded to ~200 lines regardless of plan age — prevents injection growing unboundedly as initiatives accumulate. **Post-compaction resume**: when `.preserved-context` exists, extracts the `RESUME DIRECTIVE:` block (computed by `build_resume_directive()` in session-lib.sh) and injects it as the first context element so it takes priority over all other state. The session event log is preserved across compaction (not reset) so trajectory context survives. Known: SessionStart has a bug ([#10373](https://github.com/anthropics/claude-code/issues/10373)) where output may not inject for brand-new sessions — works for `/clear`, `/compact`, resume |
| **update-check.sh** | Called by session-init.sh | Fetches origin/main, compares versions. Auto-applies safe updates (same MAJOR). Notifies for breaking changes (different MAJOR). Aborts cleanly on conflict. Writes `.update-status` consumed by session-init.sh. Disabled by `.disable-auto-update` flag file |
| **prompt-submit.sh** | UserPromptSubmit | First-prompt mitigation for SessionStart bug: on the first prompt of any session, injects full session context (same as session-init.sh) as a reliability fallback. **User verification gate**: when user expresses approval (verified, approved, lgtm, looks good, ship it) and `.proof-status = pending`, writes `verified\|timestamp` — this is the ONLY path to verified status. On subsequent prompts: keyword-based context injection — file references trigger @decision status, "plan"/"implement" trigger MASTER_PLAN phase status, "merge"/"commit" trigger git dirty state. Also: auto-claims issue refs ("fix #42"), detects deferred-work language ("later", "eventually") and suggests `/backlog`, flags large multi-step tasks for scope confirmation. **Active agent detection**: when subagent tracker has ACTIVE entries and prompt is not an approval keyword, injects agent types and elapsed times as advisory context for the Task Interruption Protocol (DEC-INTERRUPT-001) |
| **compact-preserve.sh** | PreCompact | Dual output: (1) persistent `.preserved-context` file that survives compaction and is re-injected by session-init.sh, and (2) `additionalContext` instructing the model to preserve the resume directive verbatim. Captures git state, plan status, session changes, @decision annotations, test status, agent findings, audit trail, and **session trajectory** (`get_session_summary_context`). Computes a **resume directive** via `build_resume_directive()` — a priority-ordered actionable instruction derived from session state (active agent > proof status > test failures > branch state > plan phase) — and appends it to both outputs so neither the `additionalContext` nor the persistent file omit the "what to do next" signal |
| **session-end.sh** | SessionEnd | Kills lingering async test-runner processes, releases todo claims for this session, cleans session-scoped files (`.session-changes-*`, `.prompt-count-*`, `.lint-cache`, strike counters). Preserves cross-session state (`.audit-log`, `.agent-findings`, `.plan-drift`). Trims audit log to last 100 entries |

### Stop Hooks

| Hook | Event | What It Does |
|------|-------|--------------|
| **surface.sh** | Stop | Full decision audit pipeline: (1) extract — scans project source directories for @decision annotations using ripgrep (with grep fallback); (2) validate — checks changed files over 50 lines for @decision presence and rationale; (3) reconcile — compares DEC-IDs in MASTER_PLAN.md vs code, identifies unplanned decisions (in code but not plan) and unimplemented decisions (in plan but not code), respects deprecated/superseded status; (4) REQ-ID traceability — checks P0 requirements addressed by DEC-IDs via `Addresses:` linkage, flags unaddressed P0s; (5) persist — writes structured drift data (including `unaddressed_p0s`, `nogo_count`) to `.plan-drift` for consumption by plan-check.sh next session. Reports via `systemMessage` |
| **session-summary.sh** | Stop | Deterministic (<2s runtime). Counts unique files changed (source vs config), @decision annotations added. Reports git branch, dirty/clean state, test status (waits briefly for in-flight async test-runner). Generates workflow-aware next-action guidance: on main → "create plan" or "create worktrees"; on feature branch → "fix tests", "run tests", "review changes", or "merge to main" based on current state. Includes pending todo count |
| **forward-motion.sh** | Stop | Deterministic regex check (not AI). Extracts the last paragraph of the assistant's response and checks for forward motion indicators: `?`, "want me to", "shall I", "let me know", "would you like", "next step", etc. Returns exit 2 (feedback loop) only if the response ends with a bare completion statement ("done", "finished", "all set") and no question mark — prompting the model to add a suggestion or offer |

### Notifications

| Hook | Matcher | What It Does |
|------|---------|--------------|
| **notify.sh** | permission_prompt\|idle_prompt | Desktop notification when Claude needs attention (macOS only). Uses `terminal-notifier` (activates terminal on click) with `osascript` fallback. Sound varies by urgency: `Ping` for permission prompts, `Glass` for idle prompts |

### Subagent Lifecycle

| Hook | Event / Matcher | What It Does |
|------|-----------------|--------------|
| **task-track.sh** | PreToolUse:Task | Tracks subagent spawns for status bar. **Dispatch gates**: Guardian requires `.proof-status = verified` when file exists (missing = allow, fixes bootstrap deadlock; meta-repo exempt). Tester requires implementer trace to have completed (prevents premature dispatch). **Gate C.1: Implementer must be dispatched from a linked worktree** — checks worktree identity (not branch name) to prevent bypass on feature branches (DEC-GATE-C1-002); denies when dispatched from the main worktree without any linked worktrees. **Implementer dispatch activates proof gate** by creating `.proof-status = needs-verification`. All gates use PreToolUse deny |
| **subagent-start.sh** | SubagentStart | Injects git state + plan status + active initiative name into every subagent. Architecture extraction: living-document format uses `## Architecture` (top-level); legacy format uses `### Architecture` (nested). Agent-type-specific guidance: **Implementer** gets worktree creation warning (if none exist), test status. **Tester** gets implementer trace path, project type hints, branch context, verification protocol (includes Verification Assessment: methodology, coverage, confidence, gaps). **Guardian** gets plan update rules (only at phase boundaries) and test status. **Planner** gets research log status. Lightweight agents (Bash, Explore) get minimal context |
| **check-planner.sh** | SubagentStop (planner\|Plan) | Format-aware validation. Living-document format (detected by `### Initiative:` headers): (1) `## Identity` section present, (2) `## Architecture` section present, (3) `## Active Initiatives` section present, (4) `## Decision Log` present, (5) each initiative has `**Status:**` field, (6) active initiatives have Goals/Requirements. Legacy format: (1) MASTER_PLAN.md exists, (2) has `## Phase N` headers, (3) has intent/vision section, (4) has issues/tasks, (5) has structured requirements for multi-phase plans. Both formats: approval-loop detection. Advisory only — always exit 0. Persists findings to `.agent-findings` for next-prompt injection |
| **check-implementer.sh** | SubagentStop (implementer) | 4 checks: (1) current branch is not main/master (worktree was used), (2) @decision coverage on 50+ line source files changed this session, (3) approval-loop detection, (4) test status verification (recent failures = "implementation not complete"). Advisory only — proof-of-work verification moved to tester agent. Persists findings |
| **check-tester.sh** | SubagentStop (tester) | Validates tester completed verification: (1) `.proof-status` exists (at least pending), (2) trace artifacts include verification evidence. **Auto-verify**: if tester signals `AUTOVERIFY: CLEAN` and secondary validation confirms (High confidence, full coverage, no caveats), auto-writes `verified` to `.proof-status` — Guardian dispatch is immediately unblocked. Otherwise: if proof is `pending` → exit 0 with advisory (waiting for user approval). If proof missing → exit 2 (feedback loop: resume tester). Persists findings |
| **check-guardian.sh** | SubagentStop (guardian) | 6 checks: (1) MASTER_PLAN.md freshness — only for phase-completing merges, must be updated within 300s, (2) git status is clean (no uncommitted changes), (3) branch info for context, (4) approval-loop detection, (5) test status for git operations (CRITICAL if tests failing when merge/commit detected), (6) initiative completion detection — if response mentions completing an initiative, suggests `compress_initiative()` to move it from Active to Completed Initiatives. `PLAN_LIFECYCLE=dormant` → advisory to add new initiative. Advisory only. Persists findings |
| **check-explore.sh** | SubagentStop (Explore\|explore) | Post-exploration validation for Explore agents. Validates research output quality. Advisory only — persists findings |
| **check-general-purpose.sh** | SubagentStop (general-purpose) | Post-execution validation for general-purpose agents. Validates output quality. Advisory only — persists findings |

---

## Key pre-bash.sh Behaviors

The most complex hook — 11 checks covering 7 nuclear denies, 1 early-exit gate, 2 deny-with-correction, 3 CWD safety denies, 3 hard blocks, 2 evidence gates, and 2 human gate enforcers.

**Nuclear deny** (Check 0 — unconditional, fires first):

| Category | Pattern | Why |
|----------|---------|-----|
| Filesystem destruction | `rm -rf /`, `rm -rf ~`, `rm -rf /Users`, `rm -rf /*` | Recursive deletion of system/user root directories |
| Disk/device destruction | `dd ... of=/dev/`, `mkfs`, `> /dev/sd*` | Overwrites or formats storage devices |
| Fork bomb | `:(){ :\|:& };:` | Infinite process spawning exhausts system resources |
| Permission destruction | `chmod 777 /`, `chmod -R 777 /*` | Removes all permission boundaries on root |
| System halt | `shutdown`, `reboot`, `halt`, `poweroff`, `init 0/6` | Stops or restarts the machine |
| Remote code execution | `curl/wget ... \| bash/sh/python/perl/ruby/node` | Executes untrusted downloaded code |
| SQL destruction | `DROP DATABASE/TABLE/SCHEMA`, `TRUNCATE TABLE` | Permanently destroys database objects |

False positive safety: `rm -rf ./node_modules` (scoped path), `curl ... | jq` (jq is not a shell), `chmod 755 ./build` (not 777 on root) all pass through.

**Early-exit gate** (after Check 1 — non-git commands skip all git-specific checks):

Strips quoted strings from the command, then checks if `git` appears in a command position (start of line, or after `&&`, `||`, `|`, `;`). If no git command is found, exits immediately — skipping checks 2–8. This prevents false positives where git subcommand keywords appear inside quoted arguments (e.g., `todo.sh add "fix git committing"` or `echo "git merge strategy"`).

**Deny with correction** (command denied, safe alternative in the deny message — `updatedInput` rewrites are non-functional in PreToolUse hooks):

| Check | Trigger | Correction |
|-------|---------|------------|
| 1 | `/tmp/` or `/private/tmp/` write | → denied, project `tmp/` path in message (macOS symlink-aware; exempts Claude scratchpad) |
| 3 | `git push --force` (not to main) | → denied, `--force-with-lease` in message |

**Hard blocks** (deny with explanation):

| Check | Trigger | Why |
|-------|---------|-----|
| 2 | `git commit` on main/master | Sacred Practice #2 (exempts `~/.claude` meta-repo and MASTER_PLAN.md-only commits) |
| 3 | `git push --force` to main/master | Destructive to shared history |
| 4 | `git reset --hard`, `git clean -f`, `git branch -D` | Destructive operations — suggests safe alternatives |

**Evidence gates** (require proof before commit/merge):

| Check | Requires | State File | Exemption |
|-------|----------|------------|-----------|
| 6-7 | `.test-status` = `pass` (when file exists) | `.claude/.test-status` (format: `result\|fail_count\|timestamp`) | `~/.claude` meta-repo; missing file = allow (bootstrap path) |
| 8 | `.proof-status` = `verified` (when file exists) | `.claude/.proof-status` (format: `status\|timestamp`) | `~/.claude` meta-repo; missing file = allow (bootstrap path) |

Test evidence: only `pass` satisfies the gate when the file exists. Any non-pass status (`fail` of any age, unknown) = denied. Recent failures (< 10 min) get a specific error message with failure count; older failures get a generic "did not pass" message. Missing file = no test data to enforce = allowed (bootstrap path).

Proof-of-work: the user must see the feature work before code is committed. The gate is only active when `.proof-status` exists — created by implementer dispatch (task-track.sh Gate C writes `needs-verification`). Missing file means no implementation in progress, so commits are allowed (fixes bootstrap deadlock). `track.sh` resets proof status to `pending` when source files change after verification — ensuring the user always verifies the final state.

**Human gate enforcement** (Checks 9-10 — blocks agent bypass):

| Check | Trigger | Why |
|-------|---------|-----|
| 9 | Any Bash command writing approval status to `.proof-status` | Only `prompt-submit.sh` (user approval) and `check-tester.sh` (auto-verify) can write verified status. Guard.sh blocks Bash tool writes but not hook file operations |
| 10 | `rm` command targeting `.proof-status` when status is `pending` or `needs-verification` | Prevents agents from bypassing the gate by deleting the file. Verified status can be cleaned up freely |

---

## Key Plan-Check Behaviors

Beyond checking for MASTER_PLAN.md existence, this hook scores plan staleness using two signals:

| Signal | What It Measures | Warn Threshold | Deny Threshold |
|--------|-----------------|----------------|----------------|
| **Source churn %** | Percentage of tracked source files changed since plan update | 15% | 35% |
| **Decision drift** | Count of unplanned + unimplemented @decision IDs (from `surface.sh` audit) | 2 IDs | 5 IDs |

The composite score takes the worst tier across both signals. If either hits deny threshold, writes are blocked until the plan is updated. This is self-normalizing — a 3-file project and a 300-file project both trigger at the same percentage.

**Bypasses:** Edit tool (inherently scoped), Write under 20 lines (trivial), non-source files, test files, non-git directories, `~/.claude` meta-infrastructure.

---

## Enforcement Patterns

Three patterns recur across the hook system:

**Escalating gates** — warn on first offense, block on repeat. Used when the model may have a legitimate reason to proceed once, but repeat violations indicate a broken workflow.

| Hook | Strike File | Warn | Block |
|------|------------|------|-------|
| **test-gate.sh** | `.test-gate-strikes` | First source write with failing tests | Second source write without fixing tests |
| **mock-gate.sh** | `.mock-gate-strikes` | First internal mock detected | Second internal mock (external boundary mocks always allowed) |

**Feedback loops** — exit code 2 tells Claude Code to retry the operation with the hook's output as guidance, rather than failing outright. The model gets a chance to fix the issue automatically.

| Hook | Triggers exit 2 when |
|------|---------------------|
| **lint.sh** | Linter finds fixable issues in the written file |
| **plan-validate.sh** | MASTER_PLAN.md fails structural validation (missing Status fields, empty Decision Log, bad DEC-ID format) |
| **forward-motion.sh** | Response ends with bare completion ("done") and no question, suggestion, or offer |

**Deny with correction** — the command is denied with the safe alternative in the reason message. The model can resubmit the corrected command. Note: `updatedInput` transparent rewrites are NOT supported in PreToolUse hooks (silently fails — see issue anthropics/claude-code#26506).

| Hook | Denies with Correction |
|------|------------------------|
| **pre-bash.sh** | `/tmp/` → denied, project `tmp/` path in message; `--force` → denied, `--force-with-lease` in message; `worktree remove` → denied, safe `cd`-first command in message |

---

## State Files

Hooks communicate across events through state files in the project's `.claude/` directory. This is the backbone that connects async test execution to commit-time evidence gates, session tracking to end-of-session audits, and compaction preservation to next-session context injection.

**Session-scoped** (cleaned up by session-end.sh):

| File | Written By | Read By | Contents |
|------|-----------|---------|----------|
| `.session-changes-$ID` | track.sh | surface.sh, session-summary.sh, check-implementer.sh, compact-preserve.sh | One file path per line — every Write/Edit this session |
| `.prompt-count-$ID` | ~~prompt-submit.sh~~ (removed) | ~~prompt-submit.sh~~ (removed) | **Deprecated** — migrated to SQLite `prompt_count` key (DEC-PERF-003, 2026-03-14). File no longer written or read. session-init.sh and session-end.sh retain `rm -f .prompt-count-*` to clean up orphans from sessions predating the migration. |
| `.test-gate-strikes` | test-gate.sh | test-gate.sh | Strike count for escalating enforcement |
| `.mock-gate-strikes` | mock-gate.sh | mock-gate.sh | Strike count for escalating enforcement |
| `.test-runner.lock` | test-runner.sh | test-runner.sh | PID of active test process (prevents concurrent runs) |
| `.test-runner.last-run` | test-runner.sh | test-runner.sh | Epoch timestamp of last run (10s cooldown) |
| `.update-status` | update-check.sh | session-init.sh | `status\|local_ver\|remote_ver\|count\|timestamp\|summary` — one-shot, deleted after injection |
| `.update-check.lock` | update-check.sh | update-check.sh | PID of running update check (prevents concurrent runs) |

**Cross-session** (preserved by session-end.sh):

| File | Written By | Read By | Contents |
|------|-----------|---------|----------|
| `.test-status` | test-runner.sh | guard.sh (evidence gate), test-gate.sh, session-summary.sh, check-implementer.sh, check-guardian.sh, subagent-start.sh | `result\|fail_count\|timestamp` — cleared at session start by session-init.sh to prevent stale passes from satisfying the commit gate |
| `state/state.db` → `proof_state` table | log.sh `write_proof_status()` → `proof_state_set()`, check-tester.sh, prompt-submit.sh, task-track.sh | guard.sh (evidence gate), check-guardian.sh, pre-bash.sh, post-write.sh | SQLite-backed proof state via `state-lib.sh` API: `proof_state_set(status, source)` / `proof_state_get()` (returns `status\|epoch\|updated_at\|updated_by`). Monotonic lattice enforced by `state_cas()`. Flat-file `.proof-status-{phash}` is **deprecated** — no longer written since W5-2. `resolve_proof_file()` is deprecated (returns empty). |
| `.plan-drift` | surface.sh | plan-check.sh (staleness scoring) | Structured key=value: `unplanned_count`, `unimplemented_count`, `missing_decisions`, `total_decisions`, `source_files_changed`, `unaddressed_p0s`, `nogo_count` |
| `.agent-findings` | check-planner.sh, check-implementer.sh, check-guardian.sh | session-init.sh, prompt-submit.sh, compact-preserve.sh | `agent_type\|issue1;issue2` — cleared after injection (one-shot delivery) |
| `.preserved-context` | compact-preserve.sh | session-init.sh | Full session state snapshot — injected after compaction, then deleted (one-time use) |
| `.audit-log` | surface.sh, test-runner.sh, check-*.sh | compact-preserve.sh, session-summary.sh | Timestamped event trail — trimmed to last 100 entries by session-end.sh |

---

## settings.json Registration

Hook registration in `../settings.json` → `hooks` object:

```json
{
  "hooks": {
    "<EventName>": [
      {
        "matcher": "ToolName|OtherTool",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/hooks/script.sh",
            "timeout": 5,
            "async": false
          }
        ]
      }
    ]
  }
}
```

- **Event names**: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `SubagentStart`, `SubagentStop`, `PreCompact`, `Stop`, `SessionEnd`
- **matcher**: Pipe-delimited tool names for PreToolUse/PostToolUse, agent types for SubagentStop, event subtypes for SessionStart/Notification. Optional — omit to match all.
- **timeout**: Seconds before hook is killed (default varies by event)
- **async**: `true` for fire-and-forget hooks (e.g., test-runner.sh)

---

## Testing

```bash
# Run the full test suite (160+ tests)
bash tests/run-hooks.sh

# Run a targeted subset with --scope (faster feedback during hook development)
bash tests/run-hooks.sh --scope syntax       # Syntax validation + settings.json
bash tests/run-hooks.sh --scope pre-bash     # guard.sh behavioral tests
bash tests/run-hooks.sh --scope pre-write    # branch-guard, plan-check, doc-gate, test-gate
bash tests/run-hooks.sh --scope post-write   # plan-validate, statusline, registry lint
bash tests/run-hooks.sh --scope unit         # core-lib/git-lib/plan-lib/session-lib unit tests
bash tests/run-hooks.sh --scope session      # session-init, prompt-submit, compact-preserve
bash tests/run-hooks.sh --scope integration  # settings.json sync, subagent tracking
bash tests/run-hooks.sh --scope trace        # Trace protocol (init_trace, finalize_trace)
bash tests/run-hooks.sh --scope gate         # Gate hook behavioral tests
bash tests/run-hooks.sh --scope state        # State Registry Lint + Multi-Context Pass
bash tests/run-hooks.sh --scope fixtures     # Test fixture validation

# Combine multiple scopes (ORed — runs either matching section)
bash tests/run-hooks.sh --scope unit --scope gate

# PreToolUse:Write hook (consolidated)
echo '{"tool_name":"Write","tool_input":{"file_path":"/test.ts"}}' | bash hooks/pre-write.sh

# PreToolUse:Bash hook (consolidated)
echo '{"tool_name":"Bash","tool_input":{"command":"git status"}}' | bash hooks/pre-bash.sh

# Validate settings.json
python3 -m json.tool ../settings.json

# View audit trail
tail -20 ../.claude/.audit-log

# Check test gate status
cat <project>/.claude/.test-status

# Analyze hook performance (parses .hook-timing.log)
bash scripts/hook-timing-report.sh
```

### --scope Feature

The `--scope` flag targets specific test sections to reduce feedback time during
development. Full suite takes 45–90s; a single scope typically completes in <15s.

Multiple `--scope` flags are ORed — `--scope unit --scope syntax` runs both sections.
No `--scope` flag runs all tests (backward-compatible default for CI).
