# Public Promise Matrix

Status: current v6 claim/test map
Date: 2026-05-18

Public docs should only claim what these commands prove.

| Claim | Mechanism | Proof command |
|---|---|---|
| v6 has a runtime-owned stage graph. | `runtime/core/stage_machine.py` | `python3 -m pytest -q tests/runtime/test_v6_stage_machine.py::test_stage_graph_core_loop` |
| Invalid verdicts fail closed. | `stage_machine.validate_verdict()` | `python3 -m pytest -q tests/runtime/test_v6_stage_machine.py::test_unknown_transition_fails_closed` |
| Completed valid stages create next actions. | `stage_runs.submit_result()` | `python3 -m pytest -q tests/runtime/test_v6_stage_machine.py::test_ticket_claim_and_result_create_next_action` |
| Invalid result contracts do not route. | `stage_runs.validate_result()` | `python3 -m pytest -q tests/runtime/test_v6_stage_machine.py::test_invalid_result_does_not_route` |
| Canonical Agent launches without prompt claims bind to runtime stages. | `stage_runs.claim_natural_agent_launch()` and `pre-agent.sh` | `python3 -m pytest -q tests/runtime/test_v6_stage_machine.py::test_natural_agent_launch_claims_pending_stage_without_prompt_ticket && bash tests/scenarios/test-v6-ticket-flow.sh` |
| SubagentStart repairs missing launch context for canonical roles. | `hooks/subagent-start.sh` + `stage start-context` | `bash tests/scenarios/test-v6-ticket-flow.sh` |
| `claude_ctrl_result` is submitted to runtime and creates v6 next action rows. | `hooks/v6-result-submit.sh` | `bash tests/scenarios/test-v6-ticket-flow.sh` |
| Implementers cannot commit by default. | `runtime/core/policies/bash_git_who.py` | `python3 -m pytest -q tests/runtime/policies/test_v6_git_custody.py::test_v6_implementer_commit_denied_by_default` |
| Implementer checkpoint commit requires explicit grant. | lease metadata `work_item_grant.can_commit_branch=true` | `python3 -m pytest -q tests/runtime/policies/test_v6_git_custody.py::test_v6_implementer_commit_allowed_only_with_explicit_grant` |
| Implementers cannot push even with checkpoint grant. | `bash_git_who.py` | `python3 -m pytest -q tests/runtime/policies/test_v6_git_custody.py::test_v6_implementer_push_denied_even_with_commit_grant` |
| Guardian git remains allowed by lease/policy chain. | `bash_git_who.py` | `python3 -m pytest -q tests/runtime/policies/test_v6_git_custody.py::test_guardian_git_still_allowed_by_lease` |
| Settings JSON and hooks are syntactically valid. | shell/json syntax checks | `bash -n hooks/*.sh && python3 -m json.tool settings.json >/dev/null` |

| Codex/Gemini critic attempts are durable and visible. | `runtime/core/critic_runner.py`, `critic_runs` | `python3 -m pytest -q tests/runtime/test_v6_critic_and_readiness.py::test_critic_runner_dry_run_records_execution_proof` |
| External critic failure falls back to adversarial critic-subagent prompt. | `critic_runner.run_critic()` / `critic_worker.run_once()` | `python3 -m pytest -q tests/runtime/test_v6_critic_and_readiness.py::test_critic_runner_falls_back_to_adversarial_subagent tests/runtime/test_v6_critic_worker.py::test_critic_worker_fallback_issues_critic_ticket` |
| Critic results require execution proof. | `stage_runs.validate_result()` | `python3 -m pytest -q tests/runtime/test_v6_critic_and_readiness.py::test_critic_result_requires_execution_proof` |
| Critic try-again loops then escalates. | `stage_machine.resolve_transition()` + lineage retry count | `python3 -m pytest -q tests/runtime/test_v6_critic_and_readiness.py::test_critic_try_again_loops_then_escalates_to_reviewer` |
| Guardian landing readiness is one v6 aggregate. | `runtime/core/landing_readiness.py`, `v6_landing_readiness` | `python3 -m pytest -q tests/runtime/test_v6_critic_and_readiness.py::test_landing_readiness_collapses_evidence_sources` |
| Landing policy uses v6 readiness, not legacy evaluation_state. | `bash_eval_readiness.py` | `python3 -m pytest -q tests/runtime/policies/test_v6_landing_readiness_policy.py tests/runtime/policies/test_bash_eval_readiness.py` |
| Docs/config fast-path commits can bypass source-review readiness only when non-source and small. | `runtime/core/policies/fast_path.py` | `python3 -m pytest -q tests/runtime/policies/test_guarded_fast_path.py` |
| Hidden regular Stop review gate is not wired by default. | `settings.json`, Codex plugin hook manifest, enforcement defaults | `python3 -m pytest -q tests/runtime/test_hook_config.py tests/runtime/test_enforcement_config.py::test_get_global_default_returns_seeded_value` |
| Broad Claude permissions are backstopped by deterministic hooks. | `settings.json` PreToolUse/UserPromptSubmit/SubagentStart/SubagentStop wiring | `python3 -m pytest -q tests/runtime/test_v6_release_defaults.py::test_bypass_permissions_is_backstopped_by_deterministic_hooks` |
| Critic worker is automatic on implementer completion; no manual daemon required. | `hooks/v6-result-submit.sh`, `critic_worker`, non-ticketable `worker_pending` actions | `python3 -m pytest -q tests/runtime/test_v6_critic_worker.py::test_worker_pending_action_is_not_ticketable_before_worker_result && bash tests/scenarios/test-v6-critic-auto.sh` |
| Existing Claude config can be backed up, installed, and restored without losing histories. | `scripts/claude-v6-migrate.sh` | `bash tests/scenarios/test-v6-backup-restore.sh` |
| `cc-policy doctor` proves install/workflow health. | `runtime/cli.py::_handle_doctor` | `python3 runtime/cli.py doctor` |
