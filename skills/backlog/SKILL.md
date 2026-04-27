---
name: backlog
description: Manage backlog issues: list, create, close, stale-review, and triage todos across project and global GitHub issue scopes.
argument-hint: "[todo text | done <#> | stale | review | --global | --project]"
context: fork
agent: general-purpose
allowed-tools:
  - Bash
  - Read
  - Grep
  - AskUserQuestion
---

# Backlog Skill

Create, list, close, and triage todos backed by GitHub Issues labeled
`claude-todo`.

## Scratch Output

For read-only list commands, redirect JSON to a project-local scratch file and
then read it before presenting a clean table. Do not expose raw JSON to the
user unless they explicitly ask for it.

Use this pattern:

```bash
SCRATCHPAD="${SCRATCHPAD:-$PWD/tmp}"
mkdir -p "$SCRATCHPAD"
~/.claude/scripts/todo.sh list <flags> --json > "$SCRATCHPAD/backlog.json"
```

Then read `$SCRATCHPAD/backlog.json` and format it for the user.

Write commands such as `add` and `done` can show their normal confirmation
output. The `stale` command does not support `--json`; its output is already
short and can be shown directly.

## Modes

Parse the user's arguments to determine the action.

### No Arguments

List all todos:

```bash
SCRATCHPAD="${SCRATCHPAD:-$PWD/tmp}"
mkdir -p "$SCRATCHPAD"
~/.claude/scripts/todo.sh list --all --json > "$SCRATCHPAD/backlog.json"
```

Read the JSON and present project/global sections as tables.

### `done <number>`

Close a todo:

```bash
~/.claude/scripts/todo.sh done <number>
```

If the user specifies `--global`, pass it through. If the issue belongs to the
global repo, add `--global`.

### `stale`

Show stale todos:

```bash
~/.claude/scripts/todo.sh stale
```

Ask which items to close, keep, or reprioritize.

### `review`

Run interactive triage:

1. List all todos as JSON.
2. Parse the JSON.
3. Identify semantically related issues across project and global scopes.
4. Present each todo one by one with any related items.
5. Ask whether to keep, close, reprioritize, or link it.
6. Execute the user's decision. For link actions, add cross-reference comments
   on both issues.

### `--project` or `--global`

List only that scope:

```bash
SCRATCHPAD="${SCRATCHPAD:-$PWD/tmp}"
mkdir -p "$SCRATCHPAD"
~/.claude/scripts/todo.sh list --project --json > "$SCRATCHPAD/backlog.json"
~/.claude/scripts/todo.sh list --global --json > "$SCRATCHPAD/backlog.json"
```

Read the JSON and present a table.

### Anything Else

Treat the full argument string as a new todo:

```bash
~/.claude/scripts/todo.sh add <todo text and flags>
```

After creating the issue, scan existing project and global todos for related
items. If one exists, add comments linking the issues in both directions, then
confirm with the issue URL and any cross-references.

## Scope Rules

- Default: use the current project's GitHub repo.
- `--global`: use the auto-detected global backlog repo.
- Outside a git repo, fall back to global.

## Display Format

Present todos as one markdown table per scope:

```markdown
**GLOBAL** [user/cc-todos] (3 open)

| # | Pri | Title | Created | Status |
|---|-----|-------|---------|--------|
| 18 | HIGH | Session-aware todo claiming | 2026-02-07 | |
| 14 | MED | Figure out Claude web + queued todos | 2026-02-07 | blocked |

**PROJECT** [owner/repo] (2 open)

| # | Pri | Title | Created | Status |
|---|-----|-------|---------|--------|
| 42 | | Fix auth middleware | 2026-01-20 | |
| 43 | | Add rate limiting | 2026-02-01 | assigned |
```

Use columns `#`, `Pri`, `Title`, `Created`, and `Status`. Truncate long titles
around 60 characters. For stale items, call out the age directly.
