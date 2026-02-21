---
name: backlog
description: Manage your backlog — list, create, close, and triage todos (GitHub Issues). Usage: /backlog [text | done <#> | stale | review | group | --global | --config | --project]
argument-hint: "[todo text | done <#> | stale | review | group <component> #N... | --global | --config | --project]"
---

# /backlog — Unified Backlog Management

Create, list, close, and triage todos (GitHub Issues labeled `claude-todo`).

## JSON output pattern

**IMPORTANT:** For read-only list commands, redirect `--json` output to a scratchpad file so the user never sees raw JSON in the Bash tool output. Then use the Read tool to silently parse the file and format a clean table.

Pattern:
1. `mkdir -p "$SCRATCHPAD" && ~/.claude/scripts/todo.sh list <flags> --json > "$SCRATCHPAD/backlog.json"` (Bash — produces no visible output)
2. Read `$SCRATCHPAD/backlog.json` (Read tool — silent ingestion)
3. Format the parsed data into the display table below

Write commands (add, done) stay as-is — their confirmation output is useful raw. The `stale` command doesn't support `--json` — its raw output is short and already well-formatted, so run it directly.

## Instructions

Parse `$ARGUMENTS` to determine the action:

### No arguments → List all todos
```bash
mkdir -p "$SCRATCHPAD" && ~/.claude/scripts/todo.sh list --all --json > "$SCRATCHPAD/backlog.json"
```
Read `$SCRATCHPAD/backlog.json`, then format into the markdown table described in Display Format below.

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
1. Run `mkdir -p "$SCRATCHPAD" && ~/.claude/scripts/todo.sh list --all --json > "$SCRATCHPAD/backlog.json"`, then Read the file.
2. Parse the JSON.
3. **Cross-reference scan:** Before presenting items, identify semantically related issues across both scopes (project and global). Flag pairs/clusters that should be linked or merged.
4. Present each todo one by one, noting any related issues found
5. For each, ask: **Keep**, **Close**, **Reprioritize**, or **Link** (to a related issue)?
6. Execute the user's decision — for Link actions, add cross-reference comments on both issues

### Argument is `--project`, `--global`, or `--config` alone → Scoped listing
```bash
mkdir -p "$SCRATCHPAD" && ~/.claude/scripts/todo.sh list --project --json > "$SCRATCHPAD/backlog.json"
mkdir -p "$SCRATCHPAD" && ~/.claude/scripts/todo.sh list --global --json > "$SCRATCHPAD/backlog.json"
mkdir -p "$SCRATCHPAD" && ~/.claude/scripts/todo.sh list --config --json > "$SCRATCHPAD/backlog.json"
```
Read `$SCRATCHPAD/backlog.json`, then format into the markdown table described in Display Format below.

### First word is `group` → Add component label to issues
```bash
~/.claude/scripts/todo.sh group <component> <issue-numbers...> [--global|--config]
```
Labels the specified issues with `component:<name>`. Example: `group auth 31 28` labels both issues with `component:auth`.

### First word is `ungroup` → Remove component label from issues
```bash
~/.claude/scripts/todo.sh ungroup <component> <issue-numbers...> [--global|--config]
```

### Argument is `--grouped` → Grouped listing by component
```bash
mkdir -p "$SCRATCHPAD" && ~/.claude/scripts/todo.sh list --all --grouped > "$SCRATCHPAD/backlog-grouped.txt"
```
Read the file and present to the user. Issues are grouped by `component:*` label with an "ungrouped" bucket for untagged issues. Useful for `review --grouped` to triage one component at a time.

### First word is `attach` → Attach image to an issue
```bash
~/.claude/scripts/todo.sh attach <issue-number> <image-path> [--global|--config] [--gist]
```
Saves the image locally to `~/.claude/todo-images/` and optionally uploads to a GitHub Gist. Adds a comment on the issue with the image reference.

### First word is `images` → List images for an issue
```bash
~/.claude/scripts/todo.sh images <issue-number> [--global|--config]
```

### Otherwise → Create a new todo
Treat the entire `$ARGUMENTS` as todo text (plus any flags like `--global`, `--config`, `--priority=high|medium|low`, `--image=path`, `--gist`):
```bash
~/.claude/scripts/todo.sh add $ARGUMENTS
```

After creating the issue:
1. **Extract the issue number** from the creation output URL (format: `https://github.com/owner/repo/issues/N`).
2. **Clean up the title:** If the raw title is longer than 70 characters or reads as a stream-of-consciousness brain dump, propose a concise professional title (under 70 chars, imperative form) and apply it via `gh issue edit <N> --title "<clean title>"`. The original raw text is preserved in the issue body's Problem section.
3. **Cross-reference check:** Scan existing issues (both project and global — use session-init context or `todo.sh list --all`) for semantically related topics. If a related issue exists in either scope, add a comment on **both** issues linking them (e.g., "**Related:** owner/repo#N — <brief reason>"). This catches duplicates and ensures agents see connections when they pick up work.
4. **Brief interview:** Ask the user 1-2 quick follow-up questions using AskUserQuestion:
   - "What does 'done' look like? Any specific acceptance criteria?" (header: "Criteria")
   - Options: 2-3 concrete suggestions based on the title + "Skip — I'll fill this in later"
   The question should be a single AskUserQuestion call with one question and relevant options inferred from the issue title.
5. **Enrich if answered:** If the user provides acceptance criteria (not "Skip"), edit the issue body to replace the `- [ ] TBD` placeholder with the user's criteria via `gh issue edit <N> --body "<updated body>"`. Read the current body first, then substitute the TBD line.
6. **Confirm** to the user with the issue URL, clean title, and any cross-references found.

## Scope Rules

- **Default (no flag)**: Saves to / lists from current project's GitHub repo issues
- **`--global`**: Uses the global backlog repo (`<your-github-user>/cc-todos`, auto-detected)
- **`--config`**: Uses the harness repo (`~/.claude` git remote, e.g. `user/claude-ctrl`). For filing harness bugs and config improvements from any project directory.
- If not in a git repo, automatically falls back to global

## Display Format

Present todos as a markdown table, one section per scope. Use columns: `#`, `Pri`, `Title`, `Created`, and `Status` (for labels like blocked/assigned). Truncate titles at ~60 chars with `...` if needed.

Example:

**GLOBAL** [user/cc-todos] (3 open)

| # | Pri | Title | Created | Status |
|---|-----|-------|---------|--------|
| 18 | HIGH | Session-aware todo claiming | 2026-02-07 | |
| 14 | MED | Figure out Claude web + queued todos | 2026-02-07 | blocked |
| 7 | LOW | nvim: Add `<Space>h` for comment toggle | 2026-02-06 | |

**PROJECT** [owner/repo] (2 open)

| # | Pri | Title | Created | Status |
|---|-----|-------|---------|--------|
| 42 | | Fix auth middleware | 2026-01-20 | |
| 43 | | Add rate limiting | 2026-02-01 | assigned |

**CONFIG** [user/claude-ctrl] (1 open)

| # | Pri | Title | Created | Status |
|---|-----|-------|---------|--------|
| 5 | MED | Fix session-init hook timing | 2026-02-08 | |

For stale items, flag them: "This todo is 21 days old — still relevant?"
