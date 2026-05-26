# Prompt Canon

Status: v6 runtime-context prompt snapshot
Date: 2026-05-26

## Source of truth

- `CLAUDE.md` is the orchestrator prompt.
- `agents/planner.md`
- `agents/implementer.md`
- `agents/critic.md`
- `agents/reviewer.md`
- `agents/guardian.md`
- `agents/shared-protocols.md`
- `agents/tester.md` remains as legacy/migration prompt material; v6 readiness authority is `reviewer`.

## v6 prompt contract

Canonical dispatch uses ordinary task prompts. Machine context is injected by
`hooks/subagent-start.sh` from runtime state:

- `stage_run_id`
- `workflow_id`
- `stage_id`
- `work_item_id`
- `worktree_path`
- allowed verdicts
- required `claude_ctrl_result` schema

Agents must end with a final fenced block and nothing after it:

````text
```claude_ctrl_result
{
  "stage_run_id": "<injected stage_run_id>",
  "stage_id": "<runtime stage id>",
  "verdict": "<allowed verdict>",
  "summary": "one-line evidence summary"
}
```
````

## Role prompts

| Prompt | v6 role |
|---|---|
| `planner.md` | Creates/amends plan and emits `next_work_item`, `goal_complete`, `needs_user_decision`, or `blocked_external`. |
| `guardian.md` | Handles `guardian:provision` and `guardian:land`; owns git/worktree custody. |
| `implementer.md` | Writes files and tests only; does not mutate git by default. |
| `critic.md` | Read-only tactical convergence filter before reviewer. |
| `reviewer.md` | Read-only readiness authority before Guardian landing. |

## Design goal

Prompts carry judgment and evidence expectations. Runtime carries workflow
truth. The context/result contract is intentionally small so agents do not need
to carry large JSON prompt packs or duplicate the control plane in prose.
