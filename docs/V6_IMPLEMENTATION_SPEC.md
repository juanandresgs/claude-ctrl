# v6 Implementation Spec — Current Installed Truth

Status: implemented snapshot
Date: 2026-05-26

## Non-negotiables now implemented

1. Runtime-owned stage machine: `runtime/core/stage_machine.py`.
2. Runtime-owned prompt routing: `cc-policy prompt route`; no shell regex bootstrap.
3. Natural launch binding: canonical `planner|implementer|critic|reviewer|guardian` Agent launches do not require model-facing prompt claims.
4. Context repair: `SubagentStart` resolves by launch tool id, child metadata, agent id, pending runtime state, then natural role/workflow fallback.
5. Unified strict result contract: final `claude_ctrl_result` JSON block; runtime validates `stage_run_id`, `stage_id`, verdict, full SHA where required, findings/proof where required.
6. Critic as first-order stage: implementer routes to critic; `v6-result-submit.sh` invokes the bounded runtime critic worker automatically, while `cc-policy stage critic-worker` remains a repair/diagnostic CLI.
7. Reviewer readiness gates Guardian through `v6_landing_readiness`.
8. Implementer git mutation denied by default; Guardian owns git custody.
9. No hidden regular Stop review gate.
10. Isolated Claude launch renders repo-local settings via `cc-policy install render-settings`.
11. Guarded docs/config fast-path commits bypass source-review readiness only when the shared non-source classifier accepts the staged diff.

## Canonical chain

```text
planner → guardian:provision → implementer → critic → reviewer → guardian:land → planner|terminal
```

## User prompt path

`hooks/prompt-submit.sh` calls:

```bash
cc-policy prompt route --workflow-id <wf> --worktree-path <root> --stdin
```

Default v6 behavior is to bootstrap planner for non-empty prompts unless the first line is an explicit passthrough command like `/chat`, `/status`, `/help`, `/compact`, `/clear`, or `/no-v6`.

## Critic worker

The normal path is automatic: after an implementer emits a valid `complete` or `partial` result, `v6-result-submit.sh` creates the critic stage and invokes the runtime worker for that workflow. No user/operator command is required.

Repair/diagnostic command:

```bash
cc-policy stage critic-worker --workflow-id <wf>
```

Provider order is `CLAUDE_CTRL_CRITIC_PROVIDERS` or `codex,gemini,critic-subagent`; per-provider timeout is `CLAUDE_CTRL_CRITIC_TIMEOUT` or `60` seconds. External providers must emit a valid critic `claude_ctrl_result`. If unavailable or invalid, the worker exposes an adversarial critic subagent launch. `worker_pending` actions are not launchable until the worker produces reviewer readiness or fallback.

## Policy paths

Source commits and merges remain strict: implementer writes in the scoped
worktree, critic/reviewer are read-only, reviewer creates readiness, and
Guardian lands only with matching `v6_landing_readiness` SHA.

Docs/config/non-source commits may use the guarded fast path when staged files
are routine local, no more than two files, non-source, outside runtime state
authority directories, free of secret-like content, and not rewriting protected
governance permanent sections.

## Validation

```bash
python3 -m py_compile runtime/cli.py runtime/core/*.py runtime/core/policies/*.py
bash -n hooks/*.sh scripts/*.sh tests/scenarios/*.sh
python3 -m pytest -q tests/runtime tests/scenarios
bash tests/scenarios/test-v6-ticket-flow.sh
bash tests/scenarios/test-v6-prompt-bootstrap.sh
bash tests/scenarios/test-v6-critic-auto.sh
bash tests/scenarios/test-v6-backup-restore.sh
cc-policy doctor
```
