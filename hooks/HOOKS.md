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

SubagentStart/SubagentStop hooks receive `{"subagent_type": "planner|implementer|tester|guardian", ...}`. Stop hooks receive `{"response": "..."}`.

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

### Guard Pattern

The v2.0 backport now prefers **deny with a corrective command** for unsafe Bash.
This keeps the control plane deterministic and makes the model consciously choose
the safe path instead of silently inheriting a rewritten command.

---

## Shared Libraries

### log.sh — Input handling and logging

Source with: `source "$(dirname "$0")/log.sh"`

| Function | Purpose |
|----------|---------|
| `read_input` | Read and cache stdin JSON into `$HOOK_INPUT` (call once) |
| `get_field <jq_path>` | Extract field from cached input (e.g., `get_field '.tool_input.command'`) |
| `detect_project_root` | Returns `$CLAUDE_PROJECT_DIR` → git root → `$HOME` (fallback chain) |
| `log_info <stage> <msg>` | Human-readable stderr log |
| `log_json <stage> <msg>` | Structured JSON stderr log |

### context-lib.sh — Project state detection

Source with: `source "$(dirname "$0")/context-lib.sh"`

| Function | Populates |
|----------|-----------|
| `get_git_state <root>` | `$GIT_BRANCH`, `$GIT_DIRTY_COUNT`, `$GIT_WORKTREES`, `$GIT_WT_COUNT` |
| `get_plan_status <root>` | `$PLAN_EXISTS`, `$PLAN_PHASE`, `$PLAN_TOTAL_PHASES`, `$PLAN_COMPLETED_PHASES`, `$PLAN_IN_PROGRESS_PHASES`, `$PLAN_AGE_DAYS`, `$PLAN_COMMITS_SINCE`, `$PLAN_CHANGED_SOURCE_FILES`, `$PLAN_TOTAL_SOURCE_FILES`, `$PLAN_SOURCE_CHURN_PCT` |
| `get_session_changes <root>` | `$SESSION_CHANGED_COUNT`, `$SESSION_FILE` |
| `get_drift_data <root>` | `$DRIFT_UNPLANNED_COUNT`, `$DRIFT_UNIMPLEMENTED_COUNT`, `$DRIFT_MISSING_DECISIONS`, `$DRIFT_LAST_AUDIT_EPOCH` |
| `get_research_status <root>` | `$RESEARCH_EXISTS`, `$RESEARCH_ENTRY_COUNT` |
| `is_source_file <path>` | Tests against `$SOURCE_EXTENSIONS` regex |
| `is_skippable_path <path>` | Tests for config/test/vendor/generated paths |
| `append_audit <root> <event> <detail>` | Emits audit event via `rt_event_emit` (SQLite event store; `.audit-log` flat file removed in TKT-008) |
| `canonical_session_id` | Stable session ID for per-session files |
| `current_workflow_id <root>` | Stable workflow ID (usually current branch) |
| `file_mtime <path>` | Cross-platform file mtime helper |
| `resolve_proof_file <root> [workflow]` | **DEPRECATED** — no live callers; flat-file path helper retained for backwards compat only |
| `read_proof_status <root> [workflow]` | **DEPRECATED (TKT-024)** — proof_state has zero enforcement effect; evaluation_state is the readiness authority |
| `write_proof_status <root> <status> [workflow]` | **DEPRECATED (TKT-024)** — zero callers in hook chain after evaluator-state cutover |
| `resolve_proof_file_for_command <root> <command>` | **DEPRECATED** — no live callers |
| `read_evaluation_status <root> [workflow]` | Evaluation status (`idle`, `pending`, `needs_changes`, `ready_for_guardian`, `blocked_by_plan`) — sole readiness authority (TKT-024) |
| `read_evaluation_state <root> [workflow]` | Full evaluation state JSON including head_sha |
| `write_evaluation_status <root> <status> [wf] [sha]` | Upserts evaluation state — used by check-tester.sh (verdicts), post-task.sh (pending) |
| `current_active_agent_role <root>` | Best-effort current subagent role |
| `is_guardian_role <role>` | True only for Guardian |

`$SOURCE_EXTENSIONS` is the single source of truth for source file detection: `ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh`

---

## Execution Order (Session Lifecycle)

```
SessionStart    → session-init.sh (git state, plan status, worktree warnings)
                    ↓
UserPromptSubmit → prompt-submit.sh (keyword-based context injection)
                    ↓
PreToolUse:Bash → guard.sh (sacred practice guardrails + WHO enforcement)
                   auto-review.sh (intelligent command auto-approval)
PreToolUse:W/E  → test-gate.sh → mock-gate.sh → branch-guard.sh → doc-gate.sh → plan-check.sh
                    ↓
[Tool executes]
                    ↓
PostToolUse:W/E → lint.sh → track.sh → code-review.sh → plan-validate.sh → test-runner.sh (async)
                    ↓
SubagentStart   → subagent-start.sh (agent-specific context)
SubagentStop    → check-planner.sh | check-implementer.sh | check-tester.sh | check-guardian.sh
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
| **guard.sh** | Bash | 12 checks: denies unsafe `/tmp/` writes, bare `cd` into worktrees, non-Guardian commit/merge/push, commits on main, unsafe force push, destructive git, unsafe worktree removal; requires passing tests, evaluation_state=ready_for_guardian with matching head_sha (TKT-024), and workflow binding+scope for commits and merges |
| **auto-review.sh** | Bash | Three-tier command classifier: auto-approves safe commands, defers risky ones to user |
| **test-gate.sh** | Write\|Edit | Escalating gate: warns on first source write with failing tests, blocks on repeat |
| **mock-gate.sh** | Write\|Edit | Detects internal mocking patterns; warns first, blocks on repeat |
| **branch-guard.sh** | Write\|Edit | Blocks source file writes on main/master branch |
| **doc-gate.sh** | Write\|Edit | Enforces file headers and @decision annotations on 50+ line files; Write = hard deny, Edit = advisory; warns on new root-level markdown files (Sacred Practice #9) |
| **plan-check.sh** | Write\|Edit | Denies source writes without MASTER_PLAN.md; composite staleness scoring (source churn % + decision drift) warns then blocks when plan diverges from code; bypasses Edit tool, small writes (<20 lines), non-git dirs |

### PostToolUse — Feedback After Execution

| Hook | Matcher | What It Does |
|------|---------|--------------|
| **lint.sh** | Write\|Edit | Auto-detects project linter (ruff, black, prettier, eslint, etc.), runs on modified files. Exit 2 = feedback loop (Claude retries the fix automatically) |
| **track.sh** | Write\|Edit | Records file changes to `.session-changes-$SESSION_ID`. Invalidates evaluation_state (ready_for_guardian→pending) when source files change after evaluator clearance — ensuring the evaluated HEAD and the committed HEAD are the same (TKT-024) |
| **code-review.sh** | Write\|Edit | Fires on 20+ line source files (skips tests and config). Injects diff context and suggests `mcp__multi__codereview` for multi-model analysis. Falls back silently if Multi-MCP is unavailable |
| **plan-validate.sh** | Write\|Edit | Validates MASTER_PLAN.md structure on every write: phase Status fields (`planned`/`in-progress`/`completed`), Decision Log content for completed phases, original intent section preserved, DEC-COMPONENT-NNN ID format. Exit 2 = feedback loop with fix instructions |
| **test-runner.sh** | Write\|Edit | **Async** — doesn't block Claude. Auto-detects test framework (pytest, vitest, jest, npm-test, cargo-test, go-test). 2s debounce lets rapid writes settle. 10s cooldown between runs. Lock file ensures single instance (kills previous run if superseded). Writes `.test-status` (`pass\|0\|timestamp` or `fail\|count\|timestamp`) consumed by test-gate.sh and guard.sh. Reports results via `systemMessage` |

### Session Lifecycle

| Hook | Event | What It Does |
|------|-------|--------------|
| **session-init.sh** | SessionStart | Injects git state, MASTER_PLAN.md status, active worktrees, evaluation state (TKT-024), todo HUD, unresolved agent findings, preserved context from pre-compaction. Clears stale `.test-status` from previous sessions (prevents old passes from satisfying the commit gate). Resets prompt count for first-prompt fallback. Known: SessionStart has a bug ([#10373](https://github.com/anthropics/claude-code/issues/10373)) where output may not inject for brand-new sessions — works for `/clear`, `/compact`, resume |
| **prompt-submit.sh** | UserPromptSubmit | First-prompt mitigation for SessionStart bug: on the first prompt of any session, injects full session context (same as session-init.sh) as a reliability fallback. On subsequent prompts: keyword-based context injection — file references trigger @decision status, "plan"/"implement" trigger MASTER_PLAN phase status, "merge"/"commit" trigger git dirty state. Also: auto-claims issue refs ("fix #42"), detects deferred-work language ("later", "eventually") and suggests `/backlog`, flags large multi-step tasks for scope confirmation. Note: proof verification on user "verified" reply was removed in TKT-024 — readiness is now set exclusively by check-tester.sh via evaluation_state |
| **compact-preserve.sh** | PreCompact | Dual output: (1) persistent `.preserved-context` file that survives compaction and is re-injected by session-init.sh, and (2) `additionalContext` including a compaction directive instructing the model to generate a structured context summary (objective, active files, constraints, continuity handoff). Captures git state, plan status, session changes, @decision annotations, test status, agent findings, and audit trail |
| **session-end.sh** | SessionEnd | Kills lingering async test-runner processes, releases todo claims for this session, cleans session-scoped files (`.session-changes-*`, `.prompt-count-*`, `.lint-cache`, strike counters). Cross-session flat files `.audit-log` and `.plan-drift` are no longer written or trimmed (TKT-008/TKT-018); `.agent-findings` is still written by check-*.sh and consumed by prompt-submit.sh |

### Stop Hooks

| Hook | Event | What It Does |
|------|-------|--------------|
| **surface.sh** | Stop | Full decision audit pipeline: (1) extract — scans project source directories for @decision annotations using ripgrep (with grep fallback); (2) validate — checks changed files over 50 lines for @decision presence and rationale; (3) reconcile — compares DEC-IDs in MASTER_PLAN.md vs code, identifies unplanned decisions (in code but not plan) and unimplemented decisions (in plan but not code), respects deprecated/superseded status; (4) persist — still writes `.plan-drift` flat file (dead write: no consumer reads it since TKT-018 removed the plan-check.sh reader); audit events route through `rt_event_emit`. Reports via `systemMessage` |
| **session-summary.sh** | Stop | Deterministic (<2s runtime). Counts unique files changed (source vs config), @decision annotations added. Reports git branch, dirty/clean state, test status (waits briefly for in-flight async test-runner). Generates workflow-aware next-action guidance: on main → "create plan" or "create worktrees"; on feature branch → "fix tests", "run tests", "review changes", or "merge to main" based on current state. Includes pending todo count |
| **forward-motion.sh** | Stop | Deterministic regex check (not AI). Extracts the last paragraph of the assistant's response and checks for forward motion indicators: `?`, "want me to", "shall I", "let me know", "would you like", "next step", etc. Returns exit 2 (feedback loop) only if the response ends with a bare completion statement ("done", "finished", "all set") and no question mark — prompting the model to add a suggestion or offer |

### Notifications

| Hook | Matcher | What It Does |
|------|---------|--------------|
| **notify.sh** | permission_prompt\|idle_prompt | Desktop notification when Claude needs attention (macOS only). Uses `terminal-notifier` (activates terminal on click) with `osascript` fallback. Sound varies by urgency: `Ping` for permission prompts, `Glass` for idle prompts |

### Subagent Lifecycle

| Hook | Event / Matcher | What It Does |
|------|-----------------|--------------|
| **subagent-start.sh** | SubagentStart | Creates runtime agent marker via `rt_marker_set` (TKT-016). Injects git state + plan status into every subagent. Agent-type-specific guidance: **Implementer** gets worktree creation warning (if none exist), test status, and a Tester handoff reminder. **Tester** gets evaluation state context and REQUIRED EVAL_* trailer instructions (TKT-024). **Guardian** gets plan update rules, test status, and evaluation_state authority reminders. **Planner** gets research log status. Lightweight agents (Bash, Explore) get minimal context |
| **check-planner.sh** | SubagentStop (planner\|Plan) | Deactivates runtime agent marker via `rt_marker_deactivate` (TKT-016). 5 checks: (1) MASTER_PLAN.md exists, (2) has `## Phase N` headers, (3) has intent/vision section, (4) has issues/tasks, (5) approval-loop detection (agent ended with question but no plan completion confirmation). Advisory only — always exit 0. Persists findings to `.agent-findings` for next-prompt injection |
| **check-implementer.sh** | SubagentStop (implementer) | Deactivates runtime agent marker (TKT-016). 5 checks: (1) current branch is not main/master (worktree was used), (2) @decision coverage on 50+ line source files changed this session, (3) approval-loop detection, (4) test status verification (recent failures = "implementation not complete"), (5) verification handoff note so Tester is the next role. Advisory only. Persists findings |
| **check-tester.sh** | SubagentStop (tester) | Deactivates runtime agent marker (TKT-016). Sole writer of evaluation_state verdicts (TKT-024): parses EVAL_VERDICT/EVAL_TESTS_PASS/EVAL_NEXT_ROLE/EVAL_HEAD_SHA trailers from tester output, writes evaluation_state. Fail-closed: missing or malformed trailers → needs_changes. Also: advisory evidence check, test status check. Persists findings |
| **check-guardian.sh** | SubagentStop (guardian) | Deactivates runtime agent marker (TKT-016). 6 checks: (1) MASTER_PLAN.md freshness — only for phase-completing merges, must be updated within 300s, (2) git status is clean (no uncommitted changes), (3) branch info for context, (4) approval-loop detection, (5) test status for git operations (CRITICAL if tests failing when merge/commit detected), (6) evaluation_state for completed git operations — Guardian should only operate when eval_status == ready_for_guardian (TKT-024). Advisory only. Persists findings |
| **post-task.sh** | SubagentStop (all types) | Dispatch emission (TKT-009, wired by TKT-016). Sets evaluation_state=pending on implementer completion (TKT-024). Routes tester completion based on evaluator verdict: ready_for_guardian→guardian, needs_changes→implementer, blocked_by_plan→planner. Enqueues next-phase dispatch entries into `dispatch_queue`, emits events |

---

## Key guard.sh Behaviors

The most complex hook — 10 checks covering worktree safety, WHO enforcement,
destructive git protection, and evidence gates.

**Hard blocks** (deny with explanation and a safe replacement when useful):

| Check | Trigger | Why |
|-------|---------|-----|
| 1 | `/tmp/` or `/private/tmp/` write | Artifacts must stay in project-local `tmp/` |
| 2 | bare `cd` into `.worktrees/` | Prevents CWD-related worktree deletion failures |
| 3 | `git commit`, `merge`, or `push` by non-Guardian | Permanent git authority belongs to Guardian only |
| 4 | `git commit` on main/master | Sacred Practice #2 (exempts `~/.claude` meta-repo and MASTER_PLAN.md-only commits) |
| 5 | raw `git push --force` | Must use `--force-with-lease`; main/master force push is denied outright |
| 6 | `git reset --hard`, `git clean -f`, `git branch -D` | Destructive operations — suggests safe alternatives |
| 7 | unsafe `git worktree remove` | Requires an explicit safe `cd` away from the target worktree |

**Evidence gates** (require evidence before commit/merge):

| Check | Requires | State Source | Exemption |
|-------|----------|------------|-----------|
| 8-9 | `.test-status` = `pass` | `.claude/.test-status` (format: `result\|fail_count\|timestamp`) | `~/.claude` meta-repo (no test framework by design) |
| 10 | `evaluation_state.status` = `ready_for_guardian` AND `head_sha` matches current HEAD | `evaluation_state` table via `read_evaluation_status` / `read_evaluation_state` (runtime SQLite) | `~/.claude` meta-repo |
| 12 | workflow binding + scope | `workflow_bindings` + `workflow_scope` tables | `~/.claude` meta-repo |

Test evidence: only `pass` satisfies the gate. Any non-pass status (`fail` of any age, unknown, missing file) = denied. Recent failures (< 10 min) get a specific error message with failure count; older failures get a generic "did not pass" message.

Evaluator readiness (TKT-024): the Tester evaluates the implementation and emits EVAL_VERDICT/EVAL_TESTS_PASS/EVAL_NEXT_ROLE/EVAL_HEAD_SHA trailers. `check-tester.sh` parses these and writes `evaluation_state`. Only `ready_for_guardian` with a matching `head_sha` passes Check 10. Source changes after evaluator clearance invalidate readiness via `track.sh` (ready_for_guardian→pending). `proof_state` has zero enforcement effect after TKT-024 cutover — stale proof cannot satisfy this gate.

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

**Corrective denies** — the hook blocks the unsafe command and tells the model the exact safe pattern to use instead.

| Hook | Corrective behavior |
|------|--------------------|
| **guard.sh** | Denies unsafe `/tmp/`, raw force push, and unsafe worktree removal with explicit replacement commands |

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

**Cross-session** (preserved by session-end.sh):

| File | Written By | Read By | Contents |
|------|-----------|---------|----------|
| `.test-status` | test-runner.sh | guard.sh (evidence gate), test-gate.sh, session-summary.sh, check-implementer.sh, check-guardian.sh, subagent-start.sh | `result\|fail_count\|timestamp` — cleared at session start by session-init.sh to prevent stale passes from satisfying the commit gate |
| `.agent-findings` | check-planner.sh, check-implementer.sh, check-tester.sh, check-guardian.sh | prompt-submit.sh, compact-preserve.sh | `agent_type\|issue1;issue2` — cleared after injection (one-shot delivery). Still active; not yet migrated to runtime |
| `.preserved-context` | compact-preserve.sh | session-init.sh | Full session state snapshot — injected after compaction, then deleted (one-time use) |

**Eliminated flat files** (no longer written or read as state authority):

| File | Former Role | Replacement | Removed By |
|------|------------|-------------|-----------|
| `.proof-status-<workflow>` | Proof state authority | `evaluation_state` table (TKT-024); `proof_state` table retained but deprecated with zero enforcement effect | TKT-007/TKT-018/TKT-024 |
| `.subagent-tracker` | Active agent role tracking | `agent_markers` table via `rt_marker_set`/`rt_marker_deactivate` | TKT-007/TKT-018 |
| `.statusline-cache` | Statusline data cache | `cc-policy statusline snapshot` runtime projection | TKT-012/TKT-018 |
| `.audit-log` | Audit trail file | `events` table via `rt_event_emit` (through `append_audit`) | TKT-008. Note: `compact-preserve.sh` still has a stale reader |
| `.plan-drift` | Drift scoring data | Dead write: `surface.sh` still writes it, but `plan-check.sh` no longer reads it (uses commit-count heuristic) | TKT-018 (reader removed) |

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

# Query audit trail (now in SQLite event store)
cc-policy event query --type audit --limit 20

# Check test gate status
cat <project>/.claude/.test-status
```
