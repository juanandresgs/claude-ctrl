"""Tests for the runtime-owned stage execution packet."""

from __future__ import annotations

import dataclasses
import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from runtime.core import contracts
from runtime.core import decision_work_registry as dwr
from runtime.core import evaluation as evaluation_mod
from runtime.core import goal_contract_codec
from runtime.core import test_state as test_state_mod
from runtime.core import workflows as workflows_mod
from runtime.core.stage_packet import build_stage_packet
from runtime.schemas import ensure_schema

_REPO_ROOT = Path(__file__).resolve().parents[2]


def _seed(conn: sqlite3.Connection) -> None:
    goal = contracts.GoalContract(
        goal_id="GOAL-STAGE-1",
        desired_end_state="prove stage packet",
        status="active",
        autonomy_budget=3,
        continuation_rules=("rule-a",),
        stop_conditions=("cond-a",),
        escalation_boundaries=("boundary-a",),
        user_decision_boundaries=("udb-a",),
    )
    goal_record = dataclasses.replace(
        goal_contract_codec.encode_goal_contract(goal),
        workflow_id="wf-stage",
    )
    dwr.insert_goal(conn, goal_record)
    dwr.insert_work_item(
        conn,
        dwr.WorkItemRecord(
            work_item_id="WI-STAGE-1",
            goal_id="GOAL-STAGE-1",
            workflow_id="wf-stage",
            title="stage packet slice",
            status="in_progress",
            version=1,
            author="planner",
            scope_json=(
                '{"allowed_paths":["runtime/*.py"],'
                '"required_paths":["runtime/core/stage_packet.py"],'
                '"forbidden_paths":["hooks/*.sh"],'
                '"state_domains":["runtime"]}'
            ),
            evaluation_json=(
                '{"required_tests":["pytest tests/runtime/test_stage_packet.py"],'
                '"required_evidence":["verbatim pytest footer"],'
                '"rollback_boundary":"revert test fixture",'
                '"acceptance_notes":"packet exposes canonical command recipes"}'
            ),
            head_sha=None,
            reviewer_round=1,
        ),
    )
    workflows_mod.bind_workflow(
        conn,
        workflow_id="wf-stage",
        worktree_path=str(_REPO_ROOT),
        branch="feature/stage-packet",
    )
    workflows_mod.set_scope(
        conn,
        "wf-stage",
        allowed_paths=["runtime/*.py"],
        required_paths=["runtime/core/stage_packet.py"],
        forbidden_paths=["hooks/*.sh"],
        authority_domains=["runtime"],
    )
    evaluation_mod.set_status(conn, "wf-stage", "pending", head_sha="abc123")
    test_state_mod.set_status(
        conn,
        str(_REPO_ROOT),
        "pass",
        head_sha="abc123",
        pass_count=5,
        fail_count=0,
        total_count=5,
    )


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    _seed(c)
    yield c
    c.close()


def test_build_stage_packet_returns_agent_tool_spec_and_command_recipes(conn):
    result = build_stage_packet(
        conn,
        workflow_id="wf-stage",
        stage_id="implementer",
    )

    assert result["workflow_id"] == "wf-stage"
    assert result["stage_id"] == "implementer"
    assert result["agent_tool_spec"]["subagent_type"] == "implementer"
    assert result["agent_tool_spec"]["prompt_prefix"].startswith("CLAUDEX_CONTRACT_BLOCK:")
    assert result["commands"]["workflow_get"] == "cc-policy workflow get wf-stage"
    assert result["commands"]["goal_get"] == "cc-policy workflow goal-get GOAL-STAGE-1"
    assert result["commands"]["work_item_get"] == "cc-policy workflow work-item-get WI-STAGE-1"
    assert result["commands"]["evaluation_get"] == "cc-policy evaluation get wf-stage"


def test_build_stage_packet_includes_contracts_scope_and_runtime_state(conn):
    result = build_stage_packet(
        conn,
        workflow_id="wf-stage",
        stage_id="implementer",
    )

    assert result["workflow_binding"]["branch"] == "feature/stage-packet"
    assert result["workflow_scope"]["allowed_paths"] == ["runtime/*.py"]
    assert result["goal_contract"]["goal_id"] == "GOAL-STAGE-1"
    assert result["work_item_contract"]["work_item_id"] == "WI-STAGE-1"
    assert result["work_item_contract"]["evaluation"]["required_tests"] == [
        "pytest tests/runtime/test_stage_packet.py"
    ]
    assert result["runtime_state_snapshot"]["current_branch"] == "feature/stage-packet"
    assert result["runtime_state_snapshot"]["worktree_path"] == str(_REPO_ROOT)
    assert result["evaluation_state"]["status"] == "pending"
    assert result["test_state"]["found"] is True
    assert result["scope_parity"] == {
        "workflow_scope_found": True,
        "matches_work_item_scope": True,
    }


def test_workflow_stage_packet_cli_returns_json(tmp_path: Path):
    db_path = tmp_path / "state.db"
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    ensure_schema(conn)
    _seed(conn)
    conn.commit()
    conn.close()

    proc = subprocess.run(
        [
            sys.executable,
            str(_REPO_ROOT / "runtime" / "cli.py"),
            "workflow",
            "stage-packet",
            "wf-stage",
            "--stage-id",
            "implementer",
        ],
        check=True,
        capture_output=True,
        text=True,
        env={
            **os.environ,
            "CLAUDE_POLICY_DB": str(db_path),
            "PYTHONPATH": str(_REPO_ROOT),
        },
        cwd=str(_REPO_ROOT),
    )
    payload = json.loads(proc.stdout)
    assert payload["status"] == "ok"
    assert payload["agent_tool_spec"]["subagent_type"] == "implementer"
    assert payload["commands"]["work_item_get"] == "cc-policy workflow work-item-get WI-STAGE-1"
    assert payload["scope_parity"]["matches_work_item_scope"] is True
