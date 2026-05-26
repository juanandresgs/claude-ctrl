# Architecture — v6 Runtime Control Plane

v6 is a runtime-owned stage machine with hook adapters.

## Authorities

| Domain | Authority |
|---|---|
| Stage graph | `runtime/core/stage_machine.py` |
| Stage runs/results/tickets | `runtime/core/stage_runs.py` |
| Prompt routing | `runtime/core/prompt_router.py` |
| Work items/goals | `runtime/core/work_items.py` |
| External critics | `runtime/core/critic_worker.py` + `critic_runner.py` |
| Landing readiness | `runtime/core/landing_readiness.py` (`v6_landing_readiness`) |
| Tool policy | `runtime/core/policy_engine.py` + policies |
| Isolated settings render | `runtime/core/settings_renderer.py` |

## Flow

```text
UserPromptSubmit
  → prompt-submit.sh
  → cc-policy prompt route
  → V6_DISPATCH_READY
  → natural Agent launch
  → pre-agent.sh records launch intent
  → subagent-start.sh binds or repairs runtime context
  → final claude_ctrl_result
  → v6-result-submit.sh
  → stage result-submit
  → next stage / worker-pending critic / terminal
```

No shell regex decides workflow bootstrap. Canonical SubagentStart repairs
missing launch metadata from runtime state instead of blocking for ceremony.
`dispatch next` is v6-only.

## Critic path

Implementer completion creates a `critic` stage and marks its next action `worker_pending`. `hooks/v6-result-submit.sh` immediately invokes the bounded critic worker for that exact workflow (`CLAUDE_CTRL_CRITIC_TIMEOUT`, default `60`). If Codex/Gemini returns a valid `critic` result, the worker submits it and the hook emits the reviewer launch. If external providers are unavailable or invalid, the worker publishes a persisted adversarial `critic` fallback launch instead.

A `worker_pending` action is deliberately not launchable; no agent can bypass the external-critic attempt by claiming the critic seat early. `cc-policy stage critic-worker` remains a repair/diagnostic CLI, not a required manual workflow step.

## Landing

Guardian landing gates on `v6_landing_readiness`, which aggregates reviewer result, full HEAD SHA, test state, workflow binding, scope, and Guardian lease. Legacy `evaluation_state` can remain evidence/history for old flows, but it is not the v6 landing authority.

## Validation

```bash
python3 -m pytest -q tests/runtime tests/scenarios
cc-policy doctor
```
