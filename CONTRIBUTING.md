# Contributing to claude-ctrl

Thanks for your interest in improving Claude Code's SDLC enforcement. This guide covers the most common contribution types and what to expect.

## Quick Start

```bash
# Clone the repo
git clone --recurse-submodules git@github.com:juanandresgs/claude-ctrl.git ~/.claude-dev

# Test a hook manually
echo '{"tool_name":"Bash","tool_input":{"command":"git status"}}' | bash hooks/guard.sh

# Validate settings.json
python3 -m json.tool settings.json > /dev/null && echo "Valid JSON"

# Lint all hooks
shellcheck hooks/*.sh
```

## How the System Works

Every hook receives JSON on stdin and emits JSON on stdout. The protocol is documented in [`hooks/HOOKS.md`](hooks/HOOKS.md). The key responses a PreToolUse hook can emit:

- **Deny** — block the tool call with a reason
- **Rewrite** — transparently modify the command to a safe alternative
- **Advisory** — inject context without blocking

PostToolUse hooks use `additionalContext` for feedback. Exit code 2 in linting hooks triggers a retry loop.

## Contributing a New Hook

Hooks are the most likely contribution. Here's the process:

### 1. Identify the lifecycle event

| Event | When It Fires |
|-------|--------------|
| `PreToolUse` | Before a tool executes (can deny/rewrite) |
| `PostToolUse` | After a tool executes (can advise) |
| `SessionStart` | When a Claude Code session begins |
| `UserPromptSubmit` | On each user prompt |
| `SubagentStart/Stop` | When agents launch or complete |
| `Stop` | When Claude finishes a response |
| `PreCompact` | Before context compaction |
| `SessionEnd` | When the session ends |

### 2. Write the hook

```bash
#!/usr/bin/env bash
# hooks/my-hook.sh — Brief description of what this enforces
#
# Event: PreToolUse | Matcher: Write|Edit
# Behavior: Describe the enforcement behavior

set -euo pipefail
source "$(dirname "$0")/log.sh"

read_input
TOOL=$(get_field '.tool_name')

# Your logic here

# To deny:
cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Reason shown to the model"
  }
}
EOF

# To allow with advisory:
cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "Warning or guidance text"
  }
}
EOF
```

### 3. Use the shared libraries

- **`log.sh`** — `read_input`, `get_field`, `detect_project_root`, `log_info`, `log_json`
- **`context-lib.sh`** — `get_git_state`, `get_plan_status`, `is_source_file`, `is_skippable_path`

Source them with `source "$(dirname "$0")/log.sh"`. See the existing hooks for patterns.

### 4. Test manually

```bash
# PreToolUse:Bash
echo '{"tool_name":"Bash","tool_input":{"command":"your test command"}}' | bash hooks/my-hook.sh

# PreToolUse:Write
echo '{"tool_name":"Write","tool_input":{"file_path":"/path/to/file.ts"}}' | bash hooks/my-hook.sh

# Check exit code
echo $?

# Check stderr for logs
echo '{"tool_name":"Bash","tool_input":{"command":"test"}}' | bash hooks/my-hook.sh 2>/dev/null
```

### 5. Register in settings.json

Add your hook to the appropriate event array. Hooks run sequentially in array order — placement matters, especially for PreToolUse where a deny stops the chain.

### 6. Add a test fixture

Create `tests/fixtures/my-hook-*.json` with sample inputs:

```json
{
  "tool_name": "Write",
  "tool_input": {
    "file_path": "/path/to/test/file.ts"
  }
}
```

## Code Style

- **Bash conventions**: `set -euo pipefail` at the top, use `$(...)` not backticks, quote variables
- **jq for JSON**: Use `jq` for all JSON parsing and generation — no `sed`/`awk` on JSON
- **Stderr for logging**: All debug/info output goes to stderr. Stdout is exclusively for hook protocol responses
- **Exit codes**: 0 = success, non-zero = hook error (logged, does not block tool). Exception: exit 2 in PostToolUse linting hooks triggers retry
- **Shared libraries**: Always use `log.sh` and `context-lib.sh` instead of reimplementing input parsing or project detection

## PR Expectations

Your pull request should include:

- [ ] Hook script in `hooks/` following the patterns above
- [ ] Manual test showing the hook works (`echo '...' | bash hooks/name.sh`)
- [ ] Registration in `settings.json` (correct event, appropriate position in chain)
- [ ] Entry in the hook table in `hooks/HOOKS.md`
- [ ] Test fixture(s) in `tests/fixtures/`
- [ ] No breaking changes to existing hooks (existing hooks should still pass their tests)

## Other Contribution Types

### Agent definitions (`agents/*.md`)

These are instruction files for the Planner, Implementer, and Guardian agents. Changes here affect the agent workflow, so include clear rationale.

### Skills (`skills/*/SKILL.md`)

Skills are non-deterministic intelligence layers. They have their own `SKILL.md` files with structured prompts.

### Bug fixes

For hook bugs: include the JSON input that triggers the bug and the expected vs. actual output. See the bug report issue template.

## Removing a Feature

When removing a hook, skill, or feature, follow this checklist to avoid orphaned artifacts:

1. Remove the hook/script files from `hooks/` or `scripts/`
2. Remove registration from `settings.json`
3. Remove documentation from `hooks/HOOKS.md` tables
4. Remove test references from `tests/` and `tests/fixtures/`
5. Search codebase for feature name references: `grep -r "feature-name" .`
6. Remove or update plan files in `plans/` that discuss the feature
7. Remove `.gitignore` entries for feature-specific cache or state files
8. Update `README.md` hook table if applicable
9. Run a new session — `session-init.sh` consistency check will flag any remaining references

## Questions?

Open a discussion or issue. The hook system is designed to be modular — each hook enforces one practice, so new contributions rarely conflict with existing ones.
