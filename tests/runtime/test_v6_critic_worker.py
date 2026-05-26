"""v6 critic worker tests."""

import sqlite3

import pytest

from runtime.core import critic_worker, stage_runs
from runtime.schemas import ensure_schema


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


def _payload(run, verdict="complete"):
    return {"stage_run_id": run["id"], "stage_id": run["stage_id"], "verdict": verdict, "summary": "x", "head_sha": "a" * 40}


def test_critic_worker_dry_run_submits_and_marks_source_action_completed(conn):
    impl = stage_runs.create_stage_run(conn, workflow_id="wf-worker", stage_id="implementer")
    result = stage_runs.submit_result(conn, stage_run_id=impl["id"], payload=_payload(impl))
    critic = result["next_stage_run"]
    action = result["next_action"]
    assert action["status"] == "worker_pending"

    out = critic_worker.run_once(conn, workflow_id="wf-worker", providers=["codex"], dry_run=True)
    assert out["count"] == 1
    assert out["processed"][0]["stage_run_id"] == critic["id"]
    assert out["processed"][0]["result"]["submitted_result"]["validation"]["valid"] is True
    assert stage_runs.get_next_action(conn, action["id"])["status"] == "completed"


def test_critic_worker_fallback_issues_critic_ticket(conn):
    impl = stage_runs.create_stage_run(conn, workflow_id="wf-worker-fallback", stage_id="implementer")
    result = stage_runs.submit_result(conn, stage_run_id=impl["id"], payload=_payload(impl))
    action = result["next_action"]

    out = critic_worker.run_once(conn, workflow_id="wf-worker-fallback", providers=["critic-subagent"])
    processed = out["processed"][0]["result"]
    assert processed["status"] == "fallback_required"
    assert processed["fallback_launch"]["prompt_prefix"].startswith(stage_runs.TICKET_PREFIX)
    assert stage_runs.get_next_action(conn, action["id"])["status"] == "ticketed"


def test_worker_pending_action_is_not_ticketable_before_worker_result(conn):
    impl = stage_runs.create_stage_run(conn, workflow_id="wf-worker-pending", stage_id="implementer")
    result = stage_runs.submit_result(conn, stage_run_id=impl["id"], payload=_payload(impl))
    action = result["next_action"]
    assert action["status"] == "worker_pending"

    with pytest.raises(ValueError, match="worker_pending"):
        stage_runs.issue_ticket_for_next_action(conn, int(action["id"]))

    bootstrap = stage_runs.bootstrap_planner(
        conn,
        workflow_id="wf-worker-pending",
        worktree_path="/repo",
        prompt="continue",
    )
    assert bootstrap["source"] == "worker_pending"
    assert bootstrap["prompt_prefix"] == ""
    assert "critic worker" in bootstrap["message"]
