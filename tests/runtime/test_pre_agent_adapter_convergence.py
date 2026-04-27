"""Regression tests for pre-agent.sh as a runtime policy adapter.

The Agent/Task launch path used to duplicate ``agent_contract_required`` in
shell. These tests pin the convergence contract: shell handles transport and
runtime policy owns Agent launch semantics.
"""

from __future__ import annotations

from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[2]
_PRE_AGENT = _REPO_ROOT / "hooks" / "pre-agent.sh"
_CLI = _REPO_ROOT / "runtime" / "cli.py"


def test_pre_agent_delegates_to_cc_policy_evaluate():
    text = _PRE_AGENT.read_text(encoding="utf-8")

    assert "cc_policy_local_runtime" in text
    assert " evaluate" in text
    assert "carrier_db_resolved" in text


def test_pre_agent_does_not_reimplement_contract_policy_reasons():
    text = _PRE_AGENT.read_text(encoding="utf-8")

    forbidden_shell_reason_codes = {
        "contract_block_missing_workflow_id",
        "contract_block_empty_workflow_id",
        "contract_block_missing_stage",
        "contract_block_missing_goal_id",
        "contract_block_missing_work_item_id",
        "contract_block_missing_decision_scope",
        "contract_block_missing_generated_at",
        "contract_block_invalid_generated_at",
        "contract_block_unknown_stage",
        "contract_block_missing_subagent_type",
        "contract_block_stage_subagent_type_mismatch",
    }
    for reason_code in forbidden_shell_reason_codes:
        assert reason_code not in text


def test_carrier_write_lives_behind_runtime_evaluate():
    text = _CLI.read_text(encoding="utf-8")

    assert "def _agent_contract_carrier_effect" in text
    assert "write_pending_request" in text
    assert "record_agent_dispatch" in text
