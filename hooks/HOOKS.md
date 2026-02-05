# Hook System Reference

Technical reference for the Claude Code hook system. For philosophy and workflow, see `../CLAUDE.md`.

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

### Rewrite Pattern

Three checks in guard.sh use transparent rewrites (the model's command is silently replaced):
1. `/tmp/` writes → project `tmp/` directory (Check 1)
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
| `log_info <stage> <msg>` | Human-readable stderr log |
| `log_json <stage> <msg>` | Structured JSON stderr log |

### context-lib.sh — Project state detection

Source with: `source "$(dirname "$0")/context-lib.sh"`

| Function | Populates |
|----------|-----------|
| `get_git_state <root>` | `$GIT_BRANCH`, `$GIT_DIRTY_COUNT`, `$GIT_WORKTREES`, `$GIT_WT_COUNT` |
| `get_plan_status <root>` | `$PLAN_EXISTS`, `$PLAN_PHASE`, `$PLAN_TOTAL_PHASES`, `$PLAN_COMPLETED_PHASES`, `$PLAN_AGE_DAYS` |
| `get_session_changes <root>` | `$SESSION_CHANGED_COUNT`, `$SESSION_FILE` |
| `is_source_file <path>` | Tests against `$SOURCE_EXTENSIONS` regex |
| `is_skippable_path <path>` | Tests for config/test/vendor/generated paths |
| `append_audit <root> <event> <detail>` | Appends to `.claude/.audit-log` |

`$SOURCE_EXTENSIONS` is the single source of truth for source file detection: `ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh`

---

## Execution Order (Session Lifecycle)

```
SessionStart    → session-init.sh (git state, plan status, worktree warnings)
                    ↓
UserPromptSubmit → prompt-submit.sh (keyword-based context injection)
                    ↓
PreToolUse:Bash → guard.sh (sacred practice guardrails + rewrites)
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

### guard.sh — Commit/Merge Test Evidence Gate

Checks 6 (merge) and 7 (commit) require test evidence before allowing git operations:

- **`.test-status` missing** → DENY (no test evidence)
- **`.test-status` shows `fail`** (within 10 min) → DENY (tests failing)
- **`.test-status` shows non-`pass`** → DENY (unknown/error status)
- **`.test-status` shows `pass`** → ALLOW

**Exemption:** The `~/.claude` meta-infrastructure repo is exempt from test evidence requirements (no test framework by design). Uses `is_claude_meta_repo()` helper.

### mock-gate.sh — Mock Detection Gate (Escalating)

PreToolUse hook for Write|Edit. Detects internal mocking patterns in test files and enforces Sacred Practice #5.

| State | Behavior |
|-------|----------|
| Non-test file | ALLOW (always) |
| `@mock-exempt` annotation | ALLOW (always) |
| External-boundary mocks only | ALLOW (always) |
| Internal mocks, strike 1 | ALLOW + advisory warning |
| Internal mocks, strike 2+ | DENY |

**Detection patterns:**
- Python: `unittest.mock`, `MagicMock`, `@patch`, `mock.patch`, `mocker.patch`
- JS/TS: `jest.mock(`, `vi.mock(`, `.mockImplementation`, `.mockReturnValue`, `sinon.stub/mock`
- Go: `gomock`, `mockgen`

**External boundary exemptions:** `requests`, `httpx`, `redis`, `sqlalchemy`, `boto3`, `axios`, `node-fetch`, `pg`, `mongodb`, `aws-sdk`, `pytest-httpx`, `httpretty`, `responses`, `nock`, `msw`, `testcontainers`

**State file:** `.claude/.mock-gate-strikes` (format: `count|epoch`, cleaned by session-end.sh)

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
