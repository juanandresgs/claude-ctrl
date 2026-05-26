"""v6 critic runner, convergence, and landing-readiness tests."""

from __future__ import annotations

import sqlite3

import pytest

from runtime.core import critic_runner, landing_readiness, leases, stage_runs, test_state, workflows
from runtime.schemas import ensure_schema


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


def test_critic_runner_dry_run_records_execution_proof(conn):
    run = stage_runs.create_stage_run(conn, workflow_id="wf-c", stage_id="critic", worktree_path=".")
    out = critic_runner.run_critic(conn, stage_run_id=run["id"], providers=["codex"], dry_run=True)
    assert out["status"] == "completed"
    rec = critic_runner.latest_for_stage(conn, run["id"])
    assert rec["provider"] == "codex"
    assert rec["status"] == "completed"
    assert rec["execution_proof"]["valid"] is True


def test_critic_runner_falls_back_to_adversarial_subagent(conn):
    run = stage_runs.create_stage_run(conn, workflow_id="wf-c", stage_id="critic", worktree_path=".")
    out = critic_runner.run_critic(conn, stage_run_id=run["id"], providers=["definitely_missing_provider", "critic-subagent"])
    assert out["status"] == "fallback_required"
    assert out["selected_provider"] == "critic-subagent"
    assert "adversarial critic" in out["critic_run"]["prompt_text"]
    assert out["attempts"][0]["status"] == "failed"


def test_critic_result_requires_execution_proof(conn):
    run = stage_runs.create_stage_run(conn, workflow_id="wf-c", stage_id="critic")
    out = stage_runs.submit_result(
        conn,
        stage_run_id=run["id"],
        payload={"stage_run_id": run["id"], "stage_id": "critic", "verdict": "ready_for_reviewer", "summary": "ok", "findings": []},
    )
    assert out["validation"]["valid"] is False
    assert "execution_proof" in out["validation"]["missing_fields"]


def test_critic_try_again_loops_then_escalates_to_reviewer(conn):
    impl = stage_runs.create_stage_run(conn, workflow_id="wf-loop", stage_id="implementer")
    c1 = stage_runs.create_stage_run(conn, workflow_id="wf-loop", stage_id="critic", parent_run_id=impl["id"])
    def critic_payload(run):
        return {
            "stage_run_id": run["id"],
            "stage_id": "critic",
            "verdict": "try_again",
            "summary": "fix defects",
            "findings": [],
            "execution_proof": {"provider": "test", "valid": True},
        }

    r1 = stage_runs.submit_result(conn, stage_run_id=c1["id"], payload=critic_payload(c1))
    assert r1["next_stage_run"]["stage_id"] == "implementer"
    c2 = stage_runs.create_stage_run(conn, workflow_id="wf-loop", stage_id="critic", parent_run_id=r1["next_stage_run"]["id"])
    r2 = stage_runs.submit_result(conn, stage_run_id=c2["id"], payload=critic_payload(c2))
    assert r2["next_stage_run"]["stage_id"] == "implementer"
    c3 = stage_runs.create_stage_run(conn, workflow_id="wf-loop", stage_id="critic", parent_run_id=r2["next_stage_run"]["id"])
    r3 = stage_runs.submit_result(conn, stage_run_id=c3["id"], payload=critic_payload(c3))
    assert r3["next_stage_run"]["stage_id"] == "reviewer"
    assert r3["transition"]["terminal_reason"] == "retry_limit_exceeded:2"


def test_landing_readiness_collapses_evidence_sources(conn):
    wf = "wf-land"
    wt = "/tmp/wf-land"
    workflows.bind_workflow(conn, wf, wt, "feature/x")
    workflows.set_scope(conn, wf, ["**/*"], [], [], ["runtime"])
    full_sha = "a" * 40
    test_state.set_status(conn, wt, "pass_complete", head_sha=full_sha)
    reviewer = stage_runs.create_stage_run(conn, workflow_id=wf, stage_id="reviewer", worktree_path=wt)
    stage_runs.submit_result(
        conn,
        stage_run_id=reviewer["id"],
        payload={
            "stage_run_id": reviewer["id"],
            "stage_id": "reviewer",
            "verdict": "ready_for_guardian",
            "summary": "ready",
            "head_sha": full_sha,
            "findings": [],
        },
    )
    guardian = stage_runs.create_stage_run(
        conn,
        workflow_id=wf,
        stage_id="guardian:land",
        parent_run_id=reviewer["id"],
        worktree_path=wt,
    )
    leases.issue(
        conn,
        "guardian",
        worktree_path=wt,
        workflow_id=wf,
        metadata={"stage_run_id": guardian["id"]},
    )
    ready = landing_readiness.ensure_for_guardian_stage(conn, guardian["id"])
    assert ready["status"] == "ready"
    assert ready["head_sha"] == full_sha
    assert ready["missing"] == []
    assert landing_readiness.assert_ready(conn, guardian["id"])["status"] == "ready"

    invalidated = landing_readiness.invalidate_for_workflow(conn, wf)
    assert invalidated == 1
    assert landing_readiness.get(conn, guardian["id"])["status"] == "blocked"
