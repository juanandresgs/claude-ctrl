# claude-ctrl

## Ethos

`claude-ctrl` exists to turn good intentions into enforceable reality.

The project is guided by one principle:

> Make the right path automatic, the wrong path hard, and ambiguity impossible to ignore.

From that follow these rules:

1. **Judgment lives in prompts; truth lives in mechanisms.**
   Prompts can shape how agents think, but only hooks, runtime state, and tests are allowed to make claims true.

2. **Each operational fact gets one authority.**
   If two systems can answer the same control question, the system is already drifting. Replacements are not complete until the old authority is removed.

3. **The safe path must be the easy path.**
   Agents should not need to remember rituals, hidden environment variables, or special-case folklore to behave correctly. The default path should already be the correct one.

4. **Ambiguity must fail loud.**
   Silent fallback is a design smell. If workflow identity, DB scope, proof state, or scope authority is unclear, the system should stop, deny, or surface the ambiguity explicitly.

5. **Reality outranks narration.**
   Agent summaries are useful, but they are never authority. Git state, runtime state, executed checks, and observed behavior decide what is true.

6. **Concurrency is a first-class constraint.**
   Workflow state must remain correct when multiple agents, worktrees, or sessions operate at once. Any mechanism that only works in the single-threaded happy path is incomplete.

7. **Delete what you replace.**
   Migrations are not finished when the new path exists; they are finished when the old path can no longer affect outcomes.

8. **Documentation must describe the installed system.**
   The repo must not claim protections, guarantees, or architecture that the running code does not actually enforce.

9. **Human approval is not fake technical proof.**
   Users approve irreversible actions, priorities, and intent. The system itself must verify technical correctness.

10. **The control plane must be able to govern itself.**
    `claude-ctrl` is not just a set of prompts or hooks. It is an attempt to build a self-hosting, mechanically trustworthy operating layer for agentic work.

## v6 Runtime Loop

v6 runs Claude Code through a runtime-owned stage machine:

```text
planner → guardian:provision → implementer → critic → reviewer → guardian:land → planner|terminal
```

Canonical agent launches consume a runtime ticket:

```text
CLAUDE_CTRL_TICKET:<ticket-id>
```

Canonical agent stops emit one final result block:

````text
```claude_ctrl_result
{"stage_run_id":"...","stage_id":"...","verdict":"...","summary":"..."}
```
````

Hooks enforce the launch/result boundary; SQLite records stage runs, launch tickets, results, and next actions. Guardian owns git mutation by default. Critic/reviewer are explicit stages, not hidden regular Stop gates.

Docs:

- [`docs/V6_ARCHITECTURE.md`](docs/V6_ARCHITECTURE.md) — diagrams and current implementation map
- [`docs/DISPATCH.md`](docs/DISPATCH.md) — dispatch commands and transition table
- [`docs/PROMPTS.md`](docs/PROMPTS.md) — v6 prompt contract
- [`docs/PROMISES.md`](docs/PROMISES.md) — public claim/test matrix
- [`docs/V6_RELEASE_READINESS.md`](docs/V6_RELEASE_READINESS.md) — release hardening, backup/restore, and validation record
- [`docs/V6_LIVE_TESTING.md`](docs/V6_LIVE_TESTING.md) — required live Claude Code dogfood before public push

Safe v6 trial without replacing an existing Claude config:

```bash
scripts/claude-v6.sh --verify-config /path/to/project
scripts/claude-v6.sh /path/to/project
```

Live Claude Code dogfood before public push:

```bash
scripts/claude-v6-live-test.sh prepare
scripts/claude-v6-live-test.sh open
scripts/claude-v6-live-test.sh start
# rollback installed dogfood when done:
scripts/claude-v6-live-test.sh restore
```

Safe cutover with full backup/restore:

```bash
BACKUP=$(scripts/claude-v6-migrate.sh backup)
scripts/claude-v6-migrate.sh install --backup-dir "$BACKUP" --yes
# rollback if needed:
scripts/claude-v6-migrate.sh restore "$BACKUP" --yes
```

The backup captures the existing `~/.claude` target, conversation/session/project history, state DBs, plugin state/cache, and `~/.claude.json` before symlinking v6.

Fast validation:

```bash
python3 -m pytest -q tests/runtime/test_v6_stage_machine.py tests/runtime/policies/test_v6_git_custody.py
bash tests/scenarios/test-v6-ticket-flow.sh
```
