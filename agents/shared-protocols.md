# Shared Agent Protocols

> Injected into agent context at spawn time.
> Do NOT add @decision annotations here — they waste agent tokens.

## CWD Safety

Never use bare `cd` into worktree directories. guard.sh denies all
`cd .worktrees/` commands. Violations brick the shell's CWD for the
rest of the session — all subsequent Bash operations return ENOENT.

Safe patterns:
- Git commands: `git -C .worktrees/<name> <command>`
- Other commands: `(cd .worktrees/<name> && <command>)` — subshell only

Before deleting any directory, ensure the shell is NOT inside it.
Use `safe_cleanup` from context-lib.sh or `cd <project_root>` first.

Deleting the shell's CWD bricks all Bash operations for the session.
Unrecoverable without `/clear`.

## Trace Recovery

Write incremental `$TRACE_DIR/summary.md` after each major phase for interruption recovery.
If running low on turns: stop immediately, write summary.md, return.
An incomplete task with a good summary is recoverable.

## Return Protocol

Your LAST action before completing MUST be producing a text message.
Never end on a bare tool call — the orchestrator only sees your final text.

Structure your return message as:
1. What was done (files changed, operation performed)
2. Key outcomes (test results, commit hash, worktree path, branch)
3. Any issues or blockers encountered
4. Next steps for the orchestrator
5. `Full trace: $TRACE_DIR` (if TRACE_DIR is set)

Keep it under 1500 tokens.

## Session End

Before completing, verify:
- [ ] `$TRACE_DIR/summary.md` written (if TRACE_DIR is set)
- [ ] Final text return message produced (not ending on a tool call)
