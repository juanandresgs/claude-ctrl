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
Use `cc-policy worktree retire` to clean up feature worktrees after landing (runtime authority — DEC-WT-RETIRE-001); or navigate to `<project_root>` before any manual directory removal.

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

## Output Contracts

### Implementer Trailer
Every implementer return message must end with:
```
IMPL_STATUS: complete|partial|blocked
IMPL_SCOPE_OK: yes|no
IMPL_HEAD_SHA: <sha|none>
```

### Reviewer Trailer
Every reviewer return message must end with:
```
REVIEW_VERDICT: ready_for_guardian|needs_changes|blocked_by_plan
REVIEW_HEAD_SHA: <current HEAD git sha>
REVIEW_FINDINGS_JSON: {"findings": []}
```

These trailers are the deterministic interface between roles. Hooks parse these
sections — not narrative language.

No lines may appear after the reviewer trailer. The trailer is the terminal
output of the reviewer role. The runtime projects valid reviewer completions
into `evaluation_state` for Guardian landing checks.

### Planner Trailer
Every planner return message must end with:
```
PLAN_VERDICT: next_work_item|goal_complete|needs_user_decision|blocked_external
PLAN_SUMMARY: <one-line summary>
```

### Guardian Trailer
```
LANDING_RESULT: provisioned|committed|merged|pushed|denied|skipped
OPERATION_CLASS: routine_local|high_risk|admin_recovery
```

## Debugging Discipline

When investigating failures, keep collecting until you have a minimal root-cause
set. Do not stop at the first non-zero command unless a hard gate prevents
further execution.

Before invoking test files by name, verify they exist with `ls` or glob.
A single interrupted command is not a diagnosis — it is a data point.

## Session End

Before completing, verify:
- [ ] `$TRACE_DIR/summary.md` written (if TRACE_DIR is set)
- [ ] Final text return message produced (not ending on a tool call)
