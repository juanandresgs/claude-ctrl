---
name: backlog
description: Manage your backlog — list, create, and close todos (GitHub Issues labeled claude-todo). Usage: /backlog [text | done <#>]
argument-hint: "[todo text | done <#>]"
---

# /backlog — Unified Backlog Management

Create, list, and close todos (GitHub Issues labeled `claude-todo`) using the `gh` CLI directly.

**Prerequisite:** `gh` CLI installed and authenticated (`gh auth status`).

## Instructions

Parse `$ARGUMENTS` to determine the action:

### No arguments → List open todos

```bash
gh issue list --label "claude-todo" --state open --json number,title,createdAt,labels --limit 50
```

Format results as a markdown table using the Display Format below.

### First word is `done` → Close a todo

Extract the issue number from the remaining arguments, then:

```bash
gh issue close <number> --comment "Closed via /backlog"
```

Confirm to the user with the issue URL.

### Otherwise → Create a new todo

Treat the entire `$ARGUMENTS` as the todo title:

```bash
gh issue create --title "$ARGUMENTS" --label "claude-todo" --body "## Problem\n\n$ARGUMENTS\n\n## Acceptance Criteria\n\n- [ ] TBD"
```

After creating the issue:
1. **Extract the issue number** from the creation output URL (format: `https://github.com/owner/repo/issues/N`).
2. **Clean up the title:** If the raw title is longer than 70 characters or reads as a stream-of-consciousness brain dump, propose a concise professional title (under 70 chars, imperative form) and apply it via `gh issue edit <N> --title "<clean title>"`.
3. **Brief interview:** Ask the user 1-2 quick follow-up questions using AskUserQuestion:
   - "What does 'done' look like? Any specific acceptance criteria?" (header: "Criteria")
   - Options: 2-3 concrete suggestions based on the title + "Skip — I'll fill this in later"
4. **Enrich if answered:** If the user provides acceptance criteria (not "Skip"), edit the issue body to replace the `- [ ] TBD` placeholder via `gh issue edit <N> --body "<updated body>"`.
5. **Confirm** to the user with the issue URL and clean title.

## Scope

By default, todos are filed against the **current project's GitHub repo**. If you are not in a git repo with a GitHub remote, create a global backlog repo (e.g., `<your-github-user>/cc-todos`) and file issues there.

## Display Format

Present todos as a markdown table. Columns: `#`, `Title`, `Created`. Truncate titles at ~60 chars with `...` if needed.

Example:

**PROJECT** [owner/repo] (3 open)

| # | Title | Created |
|---|-------|---------|
| 42 | Fix auth middleware | 2026-01-20 |
| 43 | Add rate limiting | 2026-02-01 |
| 18 | Update CI pipeline | 2026-02-10 |
