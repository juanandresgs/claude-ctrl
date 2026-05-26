# Hooks — v6 Runtime Dispatch Snapshot

Status: v6 current
Date: 2026-05-18

## v6 hot path

```text
UserPromptSubmit → prompt-submit.sh bootstraps/reuses v6 stage context
PreToolUse:Agent → pre-agent.sh records canonical launch intent
SubagentStart → subagent-start.sh binds/repairs runtime stage context
SubagentStop → v6-result-submit.sh submits claude_ctrl_result and emits next V6_DISPATCH_READY
PreToolUse:Bash/Write/Edit → policy engine gates tool use
```

## Canonical dispatch hooks

| Hook | Event | v6 behavior |
|---|---|---|
| `prompt-submit.sh` | UserPromptSubmit | For actionable implementation prompts, calls `cc-policy stage bootstrap` and injects natural `V6_DISPATCH_READY` launch context. |
| `pre-agent.sh` | PreToolUse Agent/Task | Denies only harness worktree isolation; canonical `planner|implementer|critic|reviewer|guardian` launches are recorded as best-effort runtime claims and are not blocked for missing prompt ceremony. |
| `subagent-start.sh` | SubagentStart | Resolves context by launch id, child metadata, agent id, pending stage, or natural role/workflow fallback. It creates/repairs role markers and recomputes `v6_landing_readiness` when seating `guardian:land`. |
| `v6-result-submit.sh` | SubagentStop | Parses final `claude_ctrl_result`, submits to runtime, prepares the next internal launch binding, and emits `V6_DISPATCH_READY: launch <role> for stage <stage>`. For implementer results, invokes the bounded critic worker automatically. |
| `post-task.sh` | SubagentStop | Legacy adapter retained for non-v6/migration paths; not wired as the active v6 routing authority. |

## Result contract

Every canonical subagent final message ends with:

````text
```claude_ctrl_result
{
  "stage_run_id": "<runtime id>",
  "stage_id": "<stage id>",
  "verdict": "<allowed verdict>",
  "summary": "one-line evidence summary"
}
```
````

Stage-specific additions are injected by runtime context (`head_sha`, `findings`, `execution_proof`, etc.).

## Landing authority

Guardian source landing is gated by `v6_landing_readiness`, not legacy `evaluation_state`. That aggregate ties together:

- reviewer result and `head_sha`
- passing `test_state`
- workflow binding
- workflow scope
- active Guardian lease
- guardian:land stage run

Source changes invalidate both legacy readiness and v6 landing readiness via `track.sh`. Guarded docs/config commits may bypass reviewer readiness only when the shared non-source fast-path classifier accepts the staged files.

## Policy hooks

`pre-write.sh` and `pre-bash.sh` are thin adapters into `cc-policy evaluate`. The policy engine remains first-deny-wins. v6 git custody is enforced by `bash_git_who.py`: implementers do not mutate git by default; Guardian owns commits, merges, pushes, worktrees, stash, branch/ref changes, and landing.

## Install smoke

```bash
cc-policy doctor
bash tests/scenarios/test-v6-prompt-bootstrap.sh
bash tests/scenarios/test-v6-ticket-flow.sh
bash tests/scenarios/test-v6-critic-auto.sh
bash tests/scenarios/test-v6-backup-restore.sh
```
