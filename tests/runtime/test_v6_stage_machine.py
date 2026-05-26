"""v6 stage machine and natural launch-ledger tests."""

from __future__ import annotations

import sqlite3
import subprocess

import pytest

from runtime.core import stage_machine, stage_runs
from runtime.schemas import ensure_schema


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


def test_stage_graph_core_loop():
    assert stage_machine.next_stage("planner", "next_work_item") == "guardian:provision"
    assert stage_machine.next_stage("guardian:provision", "provisioned") == "implementer"
    assert stage_machine.next_stage("implementer", "complete") == "critic"
    assert stage_machine.next_stage("critic", "try_again") == "implementer"
    assert stage_machine.next_stage("critic", "ready_for_reviewer") == "reviewer"
    assert stage_machine.next_stage("reviewer", "ready_for_guardian") == "guardian:land"
    assert stage_machine.next_stage("guardian:land", "landed") == "planner"


def test_unknown_transition_fails_closed():
    assert stage_machine.next_stage("implementer", "ready_for_guardian") is None
    with pytest.raises(ValueError):
        stage_machine.validate_verdict("implementer", "ready_for_guardian")


def test_ticket_claim_and_result_create_next_action(conn):
    run = stage_runs.create_stage_run(
        conn,
        workflow_id="wf-v6",
        stage_id="planner",
        goal_id="goal-v6",
        work_item_id="wi-v6",
        worktree_path=".",
    )
    ticket = stage_runs.issue_ticket(conn, stage_run_id=run["id"])
    assert ticket["status"] == "pending"
    assert ticket["subagent_type"] == "planner"

    claimed = stage_runs.claim_ticket(
        conn,
        ticket_id=ticket["id"],
        subagent_type="planner",
        session_id="sess-1",
        agent_id="agent-1",
    )
    assert claimed["status"] == "claimed"
    assert claimed["stage_run"]["status"] == "launched"

    submitted = stage_runs.submit_result(
        conn,
        stage_run_id=run["id"],
        payload={"stage_run_id": run["id"], "stage_id": "planner", "verdict": "next_work_item", "summary": "plan complete"},
    )
    assert submitted["validation"]["valid"] is True
    assert submitted["transition"]["to_stage"] == "guardian:provision"
    assert submitted["next_stage_run"]["stage_id"] == "guardian:provision"
    assert submitted["next_action"]["status"] == "pending"

    next_action = stage_runs.next_action(conn, workflow_id="wf-v6")
    assert next_action["id"] == submitted["next_action"]["id"]
    next_ticket = stage_runs.issue_ticket_for_next_action(conn, next_action["id"])
    assert next_ticket["prompt_prefix"].startswith(stage_runs.TICKET_PREFIX)
    assert next_ticket["stage_id"] == "guardian:provision"


def test_natural_agent_launch_claims_pending_stage_without_prompt_ticket(conn, tmp_path):
    boot = stage_runs.bootstrap_planner(
        conn,
        workflow_id="wf-natural",
        worktree_path=str(tmp_path),
        prompt="build the plan",
    )

    claimed = stage_runs.claim_natural_agent_launch(
        conn,
        subagent_type="planner",
        workflow_id="wf-natural",
        worktree_path=str(tmp_path),
        prompt="Build MASTER_PLAN.md from the research proposal.",
        session_id="sess-1",
        launch_tool_id="toolu-natural",
    )

    assert claimed["claimed"] is True
    assert claimed["ticket"]["id"] == boot["ticket"]["id"]
    assert claimed["ticket"]["agent_id"] == "toolu-natural"

    ctx = stage_runs.start_context_for_claimed_ticket(
        conn,
        subagent_type="planner",
        agent_id="child-agent",
        agent_ref="toolu-natural",
    )
    assert ctx is not None
    assert ctx["stage_run"]["id"] == boot["stage_run"]["id"]
    assert "stage_run_id" in ctx["context_text"]


def test_natural_guardian_commit_launch_creates_guardian_land_stage(conn, tmp_path):
    claimed = stage_runs.claim_natural_agent_launch(
        conn,
        subagent_type="guardian",
        workflow_id="wf-docs",
        worktree_path=str(tmp_path),
        prompt="Commit foundation docs to main.",
        launch_tool_id="toolu-guardian",
    )

    assert claimed["claimed"] is True
    assert claimed["stage_run"]["stage_id"] == "guardian:land"
    assert claimed["ticket"]["subagent_type"] == "guardian"


def test_start_context_repairs_missing_launch_claim_for_canonical_role(conn, tmp_path):
    ctx = stage_runs.start_context_for_claimed_ticket(
        conn,
        subagent_type="critic",
        workflow_id="wf-repair",
        worktree_path=str(tmp_path),
        agent_id="critic-child",
        prompt="Review the implementation before reviewer.",
    )

    assert ctx is not None
    assert ctx["stage_run"]["workflow_id"] == "wf-repair"
    assert ctx["stage_run"]["stage_id"] == "critic"
    assert "v6 Runtime Context" in ctx["context_text"]


def test_result_submission_accepts_launch_ticket_ref(conn):
    run = stage_runs.create_stage_run(
        conn,
        workflow_id="wf-v6",
        stage_id="guardian:provision",
        worktree_path="/repo",
    )
    ticket = stage_runs.issue_ticket(conn, stage_run_id=run["id"])
    stage_runs.claim_ticket(
        conn,
        ticket_id=ticket["id"],
        subagent_type="guardian",
        session_id="sess-guardian",
        agent_id="agent-guardian",
    )

    submitted = stage_runs.submit_result(
        conn,
        stage_run_id=ticket["id"],
        payload={
            "stage_run_id": ticket["id"],
            "stage_id": "guardian:provision",
            "verdict": "provisioned",
            "summary": "worktree ready",
            "worktree_path": "/repo/.worktrees/feature-x",
        },
    )

    assert submitted["validation"]["valid"] is True
    assert submitted["result"]["stage_run_id"] == run["id"]
    assert submitted["next_stage_run"]["stage_id"] == "implementer"
    refreshed = stage_runs.get_stage_run(conn, run["id"])
    assert refreshed["result"]["stage_run_id"] == run["id"]
    assert refreshed["result"]["runtime_aliases"]["submitted_ticket_id"] == ticket["id"]


def test_invalid_result_does_not_route(conn):
    run = stage_runs.create_stage_run(conn, workflow_id="wf-v6", stage_id="reviewer")
    out = stage_runs.submit_result(
        conn,
        stage_run_id=run["id"],
        payload={"stage_run_id": run["id"], "stage_id": "reviewer", "verdict": "ready_for_guardian", "summary": "missing head"},
    )
    assert out["validation"]["valid"] is False
    assert "head_sha" in out["validation"]["missing_fields"]
    assert out["next_stage_run"] is None
    assert out["repair_ticket"]["stage_id"] == "reviewer"
    refreshed = stage_runs.get_stage_run(conn, run["id"])
    assert refreshed["status"] == "pending"


def test_short_head_sha_is_normalized_when_git_can_resolve(conn, tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "-C", str(repo), "init"], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.name", "Test"], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@example.com"], check=True)
    (repo / "README.md").write_text("seed\n")
    subprocess.run(["git", "-C", str(repo), "add", "README.md"], check=True)
    subprocess.run(["git", "-C", str(repo), "commit", "-m", "seed"], check=True, capture_output=True)
    full_sha = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()

    run = stage_runs.create_stage_run(
        conn,
        workflow_id="wf-v6",
        stage_id="implementer",
        worktree_path=str(repo),
    )
    out = stage_runs.submit_result(
        conn,
        stage_run_id=run["id"],
        payload={
            "stage_run_id": run["id"],
            "stage_id": "implementer",
            "verdict": "complete",
            "summary": "implemented",
            "head_sha": full_sha[:7],
        },
    )

    assert out["validation"]["valid"] is True
    assert out["result"]["payload"]["head_sha"] == full_sha
    assert out["result"]["payload"]["runtime_aliases"]["submitted_head_sha_ref"] == full_sha[:7]


def test_canonical_prompt_ticket_parse():
    assert stage_runs.parse_ticket_from_prompt("CLAUDE_CTRL_TICKET:abc\nDo work") == "abc"
    assert stage_runs.parse_ticket_from_prompt("\n\nCLAUDE_CTRL_TICKET:abc\nDo work") == "abc"
    assert stage_runs.parse_ticket_from_prompt("no ticket") == ""
    diag = stage_runs.ticket_parse_diagnostic("context first\nCLAUDE_CTRL_TICKET:abc\n")
    assert diag["ok"] is False
    assert "natural role binding" in diag["reason"]
    diag = stage_runs.ticket_parse_diagnostic("CLAUDE_CTRL_TICKET:abc extra\n")
    assert diag["ok"] is False
    assert "extra text" in diag["reason"]
