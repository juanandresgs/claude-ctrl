# Hook System Reference

Technical reference for the Claude Code hook system. For philosophy and workflow, see `../CLAUDE.md`. For the summary table, see `../README.md`.

---

## Protocol

All hooks receive JSON on **stdin** and emit JSON on **stdout**. Stderr is for logging only. Exit code 0 = success. Non-zero = hook error (logged, does not block).

### Stdin Format

```json
{
  "tool_name": "Write|Edit|Bash|...",
  "tool_input": { "file_path": "...", "command": "..." },
  "cwd": "/current/working/directory"
}
```

SubagentStart/SubagentStop hooks receive `{"subagent_type": "planner|implementer|guardian", ...}`. Stop hooks receive `{"response": "..."}`.

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

**Block** — prevent the response from completing (rare):
```json
{
  "decision": "block",
  "reason": "Explanation of why the response was blocked"
}
```

Stop hooks receive `{"stop_hook_active": true/false, "response": "..."}` on stdin. Check `stop_hook_active` to prevent re-firing loops (if a Stop hook's `systemMessage` triggers another model response, the next Stop invocation will have `stop_hook_active: true`).

### Rewrite Pattern

Three checks in guard.sh use transparent rewrites (the model's command is silently replaced):
1. `/tmp/` and `/private/tmp/` writes → project `tmp/` directory (Check 1). On macOS `/tmp` → `/private/tmp` symlink; both forms are caught. Claude scratchpad (`/private/tmp/claude-*/`) is exempt.
2. `--force` → `--force-with-lease` (Check 3)
3. `git worktree remove` → prepends `cd "<main-worktree>" &&` (Check 5)

Prefer rewrite over deny when the intent is correct but the method is unsafe.

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
| `log_info <stage> <msg>` | Human-readable stderr log |
| `log_json <stage> <msg>` | Structured JSON stderr log |

### context-lib.sh — Project state detection

Source with: `source "$(dirname "$0")/context-lib.sh"`

| Function | Populates |
|----------|-----------|
| `get_git_state <root>` | `$GIT_BRANCH`, `$GIT_DIRTY_COUNT`, `$GIT_WORKTREES`, `$GIT_WT_COUNT` |
| `get_plan_status <root>` | `$PLAN_EXISTS`, `$PLAN_PHASE`, `$PLAN_TOTAL_PHASES`, `$PLAN_COMPLETED_PHASES`, `$PLAN_IN_PROGRESS_PHASES`, `$PLAN_AGE_DAYS`, `$PLAN_COMMITS_SINCE`, `$PLAN_CHANGED_SOURCE_FILES`, `$PLAN_TOTAL_SOURCE_FILES`, `$PLAN_SOURCE_CHURN_PCT`, `$PLAN_REQ_COUNT`, `$PLAN_P0_COUNT`, `$PLAN_NOGO_COUNT` |
| `get_session_changes <root>` | `$SESSION_CHANGED_COUNT`, `$SESSION_FILE` |
| `get_drift_data <root>` | `$DRIFT_UNPLANNED_COUNT`, `$DRIFT_UNIMPLEMENTED_COUNT`, `$DRIFT_MISSING_DECISIONS`, `$DRIFT_LAST_AUDIT_EPOCH` |
| `get_research_status <root>` | `$RESEARCH_EXISTS`, `$RESEARCH_ENTRY_COUNT` |
| `is_source_file <path>` | Tests against `$SOURCE_EXTENSIONS` regex |
| `is_skippable_path <path>` | Tests for config/test/vendor/generated paths |
| `append_audit <root> <event> <detail>` | Appends to `.claude/.audit-log` |

`$SOURCE_EXTENSIONS` is the single source of truth for source file detection: `ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh`

---

## Execution Order (Session Lifecycle)

```
SessionStart    → update-check.sh (fetch + auto-update, startup only)
                → session-init.sh (git state, update status, plan status, worktree warnings)
                    ↓
UserPromptSubmit → prompt-submit.sh (keyword-based context injection)
                    ↓
PreToolUse:Bash → guard.sh (sacred practice guardrails + rewrites)
                   auto-review.sh (intelligent command auto-approval)
PreToolUse:W/E  → test-gate.sh → mock-gate.sh → branch-guard.sh → doc-gate.sh → plan-check.sh
                    ↓
[Tool executes]
                    ↓
PostToolUse:W/E → lint.sh → track.sh → code-review.sh → plan-validate.sh → test-runner.sh (async)
                    ↓
SubagentStart   → subagent-start.sh (agent-specific context)
SubagentStop    → check-planner.sh | check-implementer.sh | check-guardian.sh
                    ↓
Stop            → surface.sh (decision audit) → session-summary.sh → forward-motion.sh
                    ↓
PreCompact      → compact-preserve.sh (context preservation)
                    ↓
SessionEnd      → session-end.sh (cleanup)
```

Hooks within the same event run **sequentially** in array order from settings.json. A deny from any PreToolUse hook stops the tool call — later hooks in the chain don't run.

---

## Hook Details

### PreToolUse — Block Before Execution

| Hook | Matcher | What It Does |
|------|---------|--------------|
| **guard.sh** | Bash | 9 checks: nuclear deny (7 catastrophic command categories), early-exit gate (non-git commands skip git-specific checks); rewrites `/tmp/` paths, `--force` → `--force-with-lease`, worktree CWD safety; blocks commits on main, force push to main, destructive git (`reset --hard`, `clean -f`, `branch -D`); requires test evidence + proof-of-work verification for commits and merges. All git subcommand patterns use flag-tolerant matching (`git\s+[^|;&]*\bSUBCMD`) to catch `git -C /path` and other global flags. Trailing boundaries use `[^a-zA-Z0-9-]` to reject hyphenated subcommands (`commit-msg`, `merge-base`, `merge-file`) |
| **auto-review.sh** | Bash | Three-tier command classifier: auto-approves safe commands, defers risky ones to user. `git commit/push/merge` classified as risky (requires Guardian dispatch per Sacred Practice #8) |
| **test-gate.sh** | Write\|Edit | Escalating gate: warns on first source write with failing tests, blocks on repeat |
| **mock-gate.sh** | Write\|Edit | Detects internal mocking patterns; warns first, blocks on repeat |
| **branch-guard.sh** | Write\|Edit | Blocks source file writes on main/master branch |
| **doc-gate.sh** | Write\|Edit | Enforces file headers and @decision annotations on 50+ line files; Write = hard deny, Edit = advisory; warns on new root-level markdown files (Sacred Practice #9) |
| **plan-check.sh** | Write\|Edit | Denies source writes without MASTER_PLAN.md; composite staleness scoring (source churn % + decision drift) warns then blocks when plan diverges from code; bypasses Edit tool, small writes (<20 lines), non-git dirs |

### PostToolUse — Feedback After Execution

| Hook | Matcher | What It Does |
|------|---------|--------------|
| **lint.sh** | Write\|Edit | Auto-detects project linter (ruff, black, prettier, eslint, etc.), runs on modified files. Exit 2 = feedback loop (Claude retries the fix automatically) |
| **track.sh** | Write\|Edit | Records file changes to `.session-changes-$SESSION_ID`. Also invalidates `.proof-status` when verified source files change — ensuring the user always verifies the final state, not an intermediate one |
| **code-review.sh** | Write\|Edit | Fires on 20+ line source files (skips tests and config). Injects diff context and suggests `mcp__multi__codereview` for multi-model analysis. Falls back silently if Multi-MCP is unavailable |
| **plan-validate.sh** | Write\|Edit | Validates MASTER_PLAN.md structure on every write: phase Status fields (`planned`/`in-progress`/`completed`), Decision Log content for completed phases, original intent section preserved, DEC-COMPONENT-NNN ID format, REQ-{CATEGORY}-NNN ID format. Advisory warnings for missing Goals/Non-Goals/Requirements/Success Metrics sections and completed phases without REQ-ID references. Exit 2 = feedback loop with fix instructions |
| **test-runner.sh** | Write\|Edit | **Async** — doesn't block Claude. Auto-detects test framework (pytest, vitest, jest, npm-test, cargo-test, go-test). 2s debounce lets rapid writes settle. 10s cooldown between runs. Lock file ensures single instance (kills previous run if superseded). Writes `.test-status` (`pass\|0\|timestamp` or `fail\|count\|timestamp`) consumed by test-gate.sh and guard.sh. Reports results via `systemMessage` |

### Session Lifecycle

| Hook | Event | What It Does |
|------|-------|--------------|
| **update-check.sh** | SessionStart (startup) | Fetches origin/main, compares versions. Auto-applies safe updates (same MAJOR). Notifies for breaking changes (different MAJOR). Aborts cleanly on conflict. Writes `.update-status` consumed by session-init.sh. Disabled by `.disable-auto-update` flag file |
| **session-init.sh** | SessionStart | Injects git state, harness update status, MASTER_PLAN.md status, active worktrees, todo HUD, unresolved agent findings, preserved context from pre-compaction. Clears stale `.test-status` from previous sessions (prevents old passes from satisfying the commit gate). Resets prompt count for first-prompt fallback. Known: SessionStart has a bug ([#10373](https://github.com/anthropics/claude-code/issues/10373)) where output may not inject for brand-new sessions — works for `/clear`, `/compact`, resume |
| **prompt-submit.sh** | UserPromptSubmit | First-prompt mitigation for SessionStart bug: on the first prompt of any session, injects full session context (same as session-init.sh) as a reliability fallback. On subsequent prompts: keyword-based context injection — file references trigger @decision status, "plan"/"implement" trigger MASTER_PLAN phase status, "merge"/"commit" trigger git dirty state. Also: auto-claims issue refs ("fix #42"), detects deferred-work language ("later", "eventually") and suggests `/backlog`, flags large multi-step tasks for scope confirmation |
| **compact-preserve.sh** | PreCompact | Dual output: (1) persistent `.preserved-context` file that survives compaction and is re-injected by session-init.sh, and (2) `additionalContext` including a compaction directive instructing the model to generate a structured context summary (objective, active files, constraints, continuity handoff). Captures git state, plan status, session changes, @decision annotations, test status, agent findings, and audit trail |
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
| **subagent-start.sh** | SubagentStart | Injects git state + plan status into every subagent. Agent-type-specific guidance: **Implementer** gets worktree creation warning (if none exist), test status, verification protocol instructions. **Guardian** gets plan update rules (only at phase boundaries) and test status. **Planner** gets research log status. Lightweight agents (Bash, Explore) get minimal context |
| **check-planner.sh** | SubagentStop (planner\|Plan) | 6 checks: (1) MASTER_PLAN.md exists, (2) has `## Phase N` headers, (3) has intent/vision section, (4) has issues/tasks, (5) approval-loop detection (agent ended with question but no plan completion confirmation), (6) has structured requirements sections — only flagged for multi-phase plans (single-phase/Tier 1 plans are expected to be brief). Advisory only — always exit 0. Persists findings to `.agent-findings` for next-prompt injection |
| **check-implementer.sh** | SubagentStop (implementer) | 5 checks: (1) current branch is not main/master (worktree was used), (2) @decision coverage on 50+ line source files changed this session, (3) approval-loop detection, (4) test status verification (recent failures = "implementation not complete"), (5) proof-of-work status (`verified`/`pending`/missing). Advisory only. Persists findings |
| **check-guardian.sh** | SubagentStop (guardian) | 5 checks: (1) MASTER_PLAN.md freshness — only for phase-completing merges, must be updated within 300s, (2) git status is clean (no uncommitted changes), (3) branch info for context, (4) approval-loop detection, (5) test status for git operations (CRITICAL if tests failing when merge/commit detected). Advisory only. Persists findings |

---

## Key guard.sh Behaviors

The most complex hook — 9 checks covering 7 nuclear denies, 1 early-exit gate, 3 rewrites, 3 hard blocks, and 2 evidence gates.

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

**Transparent rewrites** (model's command silently replaced with safe alternative):

| Check | Trigger | Rewrite |
|-------|---------|---------|
| 1 | `/tmp/` or `/private/tmp/` write | → project `tmp/` directory (macOS symlink-aware; exempts Claude scratchpad) |
| 3 | `git push --force` (not to main) | → `--force-with-lease` |
| 5 | `git worktree remove` | → prepends `cd` to main worktree (prevents CWD death spiral) |

**Hard blocks** (deny with explanation):

| Check | Trigger | Why |
|-------|---------|-----|
| 2 | `git commit` on main/master | Sacred Practice #2 (exempts `~/.claude` meta-repo and MASTER_PLAN.md-only commits) |
| 3 | `git push --force` to main/master | Destructive to shared history |
| 4 | `git reset --hard`, `git clean -f`, `git branch -D` | Destructive operations — suggests safe alternatives |

**Evidence gates** (require proof before commit/merge):

| Check | Requires | State File | Exemption |
|-------|----------|------------|-----------|
| 6-7 | `.test-status` = `pass` | `.claude/.test-status` (format: `result\|fail_count\|timestamp`) | `~/.claude` meta-repo (no test framework by design) |
| 8 | `.proof-status` = `verified` | `.claude/.proof-status` (format: `status\|timestamp`) | `~/.claude` meta-repo |

Test evidence: only `pass` satisfies the gate. Any non-pass status (`fail` of any age, unknown, missing file) = denied. Recent failures (< 10 min) get a specific error message with failure count; older failures get a generic "did not pass" message.

Proof-of-work: the user must see the feature work before code is committed. `track.sh` resets proof status to `pending` when source files change after verification — ensuring the user always verifies the final state.

---

## Key plan-check.sh Behaviors

Beyond checking for MASTER_PLAN.md existence, this hook scores plan staleness using two signals:

| Signal | What It Measures | Warn Threshold | Deny Threshold |
|--------|-----------------|----------------|----------------|
| **Source churn %** | Percentage of tracked source files changed since plan update | 15% | 35% |
| **Decision drift** | Count of unplanned + unimplemented @decision IDs (from `surface.sh` audit) | 2 IDs | 5 IDs |

The composite score takes the worst tier across both signals. If either hits deny threshold, writes are blocked until the plan is updated. This is self-normalizing — a 3-file project and a 300-file project both trigger at the same percentage.

**Bypasses:** Edit tool (inherently scoped), Write under 20 lines (trivial), non-source files, test files, non-git directories, `~/.claude` meta-infrastructure.

---

## Key auto-review.sh Behaviors

An 840-line policy engine that replaces the blunt "allow or ask" permission model with intelligent classification:

| Tier | Behavior | How It Decides |
|------|----------|---------------|
| **1 — Safe** | Auto-approve | Command is inherently read-only: `ls`, `cat`, `grep`, `cd`, `echo`, `sort`, `wc`, `date`, etc. |
| **2 — Behavior-dependent** | Analyze subcommand + flags | `git status` ✅ auto-approve; `git rebase` ⚠️ advisory. Compound commands (`&&`, `\|\|`, `;`, `\|`) decomposed — every segment must be safe |
| **3 — Always risky** | Advisory context → defer to user | `rm`, `sudo`, `kill`, `ssh`, `eval`, `bash -c` — risk reason injected so the permission prompt explains *why* |

**Recursive analysis:** Command substitutions (`$()` and backticks) are analyzed to depth 2. `cd $(git rev-parse --show-toplevel)` auto-approves because both `cd` (Tier 1) and `git rev-parse` (Tier 2 → read-only) are safe.

**Dangerous flag escalation:** `--force`, `--hard`, `--no-verify`, `-f` (on git) escalate any command to risky regardless of tier.

**Interaction with guard.sh:** Guard runs first (sequential in settings.json). If guard denies, auto-review never executes. If guard allows/passes through, auto-review classifies. This means guard handles the hard security boundaries, auto-review handles the UX of permission prompts.

**Git commit/push/merge reclassification:** These are classified as risky (return 1) rather than safe. This ensures every `git commit`, `git push`, and `git merge` triggers a user permission prompt, enforcing Guardian agent dispatch (Sacred Practice #8). Trade-off: Guardian's own git calls also trigger the prompt, meaning the user approves twice (Guardian plan + actual command). Acceptable — one extra click for mechanical enforcement.

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

**Transparent rewrites** — the model's command is silently replaced with a safe alternative. No denial, no feedback — the model doesn't even know the command was changed.

| Hook | Rewrites |
|------|----------|
| **guard.sh** | `/tmp/` → project `tmp/`, `--force` → `--force-with-lease`, `worktree remove` → prepends safe `cd` |

---

## State Files

Hooks communicate across events through state files in the project's `.claude/` directory. This is the backbone that connects async test execution to commit-time evidence gates, session tracking to end-of-session audits, and compaction preservation to next-session context injection.

**Session-scoped** (cleaned up by session-end.sh):

| File | Written By | Read By | Contents |
|------|-----------|---------|----------|
| `.session-changes-$ID` | track.sh | surface.sh, session-summary.sh, check-implementer.sh, compact-preserve.sh | One file path per line — every Write/Edit this session |
| `.prompt-count-$ID` | prompt-submit.sh | prompt-submit.sh | Tracks whether first-prompt mitigation has fired |
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
| `.proof-status` | user verification flow | guard.sh (evidence gate), track.sh (invalidation), check-implementer.sh | `status\|timestamp` — `verified` or `pending`. track.sh resets to `pending` when source files change after verification |
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
# PreToolUse:Write hook
echo '{"tool_name":"Write","tool_input":{"file_path":"/test.ts"}}' | bash hooks/<name>.sh

# PreToolUse:Bash hook
echo '{"tool_name":"Bash","tool_input":{"command":"git status"}}' | bash hooks/guard.sh

# Validate settings.json
python3 -m json.tool ../settings.json

# View audit trail
tail -20 ../.claude/.audit-log

# Check test gate status
cat <project>/.claude/.test-status
```
