---
name: backlog
description: Manage your backlog — list, create, close, and triage todos (GitHub Issues). Usage: /backlog [text | done <#> | stale | review | --global | --project]
argument-hint: "[todo text | done <#> | stale | review | --global | --project]"
---

# /backlog — Unified Backlog Management

Create, list, close, and triage todos (GitHub Issues labeled `claude-todo`).

## JSON output pattern

**IMPORTANT:** For read-only list commands, use `--json` so the Bash tool block shows compact JSON (minimal visual noise), then format a clean table from the structured data. Do NOT also display the raw JSON — only show your formatted table.

Write commands (add, done) stay as-is — their confirmation output is useful raw. The `stale` command doesn't support `--json` — its raw output is short and already well-formatted, so run it directly.

## Instructions

Parse `$ARGUMENTS` to determine the action:

### No arguments → List all todos
```bash
~/.claude/scripts/todo.sh list --all --json
```
Format the JSON into the display format below.

### First word is `done` → Close a todo
```bash
~/.claude/scripts/todo.sh done <number>
```
Extract the issue number from the remaining arguments. If the user specifies `--global`, add that flag. If the issue number belongs to the global repo, add `--global`.

### First word is `stale` → Show old todos that need attention
```bash
~/.claude/scripts/todo.sh stale
```
Show stale items and ask the user which to close, keep, or reprioritize.

### First word is `review` → Interactive triage
1. Run `~/.claude/scripts/todo.sh list --all --json`
2. Parse the JSON.
3. **Cross-reference scan:** Before presenting items, identify semantically related issues across both scopes (project and global). Flag pairs/clusters that should be linked or merged.
4. Present each todo one by one, noting any related issues found
5. For each, ask: **Keep**, **Close**, **Reprioritize**, or **Link** (to a related issue)?
6. Execute the user's decision — for Link actions, add cross-reference comments on both issues

### Argument is `--project` or `--global` alone → Scoped listing
```bash
~/.claude/scripts/todo.sh list --project --json
~/.claude/scripts/todo.sh list --global --json
```
Format the JSON into the display format below.

### Otherwise → Create a new todo
Treat the entire `$ARGUMENTS` as todo text (plus any flags like `--global`, `--priority=high|medium|low`):
```bash
~/.claude/scripts/todo.sh add $ARGUMENTS
```

After creating the issue:
1. **Cross-reference check:** Scan existing issues (both project and global — use session-init context or `todo.sh list --all`) for semantically related topics. If a related issue exists in either scope, add a comment on **both** issues linking them (e.g., "**Related:** owner/repo#N — <brief reason>"). This catches duplicates and ensures agents see connections when they pick up work.
2. Confirm to the user with the issue URL and any cross-references found.

## Scope Rules

- **Default (no flag)**: Saves to / lists from current project's GitHub repo issues
- **`--global`**: Uses the global backlog repo (`<your-github-user>/cc-todos`, auto-detected)
- If not in a git repo, automatically falls back to global

## Display Format

Present todos clearly:
```
PROJECT [owner/repo] (N open):
  #42 Fix auth middleware (2026-01-20)
  #43 Add rate limiting (2026-02-01)

GLOBAL [<your-github-user>/cc-todos] (N open):
  #7 Learn about MCP servers (2026-01-15)
```

For stale items, flag them: "This todo is 21 days old — still relevant?"
