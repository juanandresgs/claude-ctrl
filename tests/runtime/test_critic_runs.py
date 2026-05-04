"""Unit tests for runtime.core.critic_runs telemetry.

These tests pin the observability lane around implementer critic reviews:
lifecycle progress, trace evidence, fallback persistence, and aggregate metrics.
Routing authority remains covered by test_critic_reviews.py.
"""

from __future__ import annotations

import sqlite3

import pytest

from runtime.core import critic_runs
from runtime.core.db import connect_memory
from runtime.schemas import ensure_schema


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


def test_start_progress_complete_writes_trace(conn: sqlite3.Connection):
    run = critic_runs.start(
        conn,
        workflow_id="wf-telemetry-001",
        lease_id="lease-telemetry-001",
        provider="codex",
    )
    assert run["status"] == "started"
    assert run["active"] is True
    assert run["trace_session_id"].startswith("critic-run:")

    progressed = critic_runs.progress(
        conn,
        run_id=run["run_id"],
        message="Provider status: codex ready.",
        phase="provider",
        status="provider_ready",
    )
    assert progressed["status"] == "provider_ready"
    assert progressed["progress"][-1]["message"] == "Provider status: codex ready."

    done = critic_runs.complete(
        conn,
        run_id=run["run_id"],
        verdict="TRY_AGAIN",
        provider="codex",
        summary="Add regression coverage.",
        detail="The retry boundary is still untested.",
        artifact_path="/tmp/critic.md",
        metrics={"try_again_streak": 1, "retry_limit": 2},
    )
    assert done["status"] == "completed"
    assert done["active"] is False
    assert done["verdict"] == "TRY_AGAIN"
    assert done["artifact_path"] == "/tmp/critic.md"
    assert done["metrics"]["try_again_streak"] == 1

    trace = conn.execute(
        "SELECT ended_at, summary FROM traces WHERE session_id = ?",
        (done["trace_session_id"],),
    ).fetchone()
    assert trace is not None
    assert trace["ended_at"] is not None
    assert "TRY_AGAIN" in trace["summary"]

    entries = conn.execute(
        "SELECT entry_type FROM trace_manifest WHERE session_id = ? ORDER BY id",
        (done["trace_session_id"],),
    ).fetchall()
    assert [row["entry_type"] for row in entries] == [
        "critic_started",
        "critic_progress",
        "critic_verdict",
    ]


def test_unavailable_persists_until_fallback_completed(conn: sqlite3.Connection):
    run = critic_runs.start(conn, workflow_id="wf-telemetry-002", provider="codex")
    unavailable = critic_runs.complete(
        conn,
        run_id=run["run_id"],
        verdict="CRITIC_UNAVAILABLE",
        provider="codex",
        summary="Codex unavailable.",
        detail="Authentication missing.",
        fallback="reviewer",
        error="Authentication missing.",
    )
    assert unavailable["status"] == "fallback_required"
    assert unavailable["verdict"] == "CRITIC_UNAVAILABLE"
    assert unavailable["fallback"] == "reviewer"

    trace_before = conn.execute(
        "SELECT ended_at FROM traces WHERE session_id = ?",
        (unavailable["trace_session_id"],),
    ).fetchone()
    assert trace_before["ended_at"] is None

    completed = critic_runs.mark_fallback_completed(
        conn,
        workflow_id="wf-telemetry-002",
        summary="Reviewer fallback finished.",
    )
    assert completed is not None
    assert completed["status"] == "fallback_completed"
    assert completed["progress"][-1]["message"] == "Reviewer fallback completed."

    trace_after = conn.execute(
        "SELECT ended_at, summary FROM traces WHERE session_id = ?",
        (completed["trace_session_id"],),
    ).fetchone()
    assert trace_after["ended_at"] is not None
    assert trace_after["summary"] == "Reviewer fallback finished."


def test_metrics_expose_loopback_and_fallback_rates(conn: sqlite3.Connection):
    r1 = critic_runs.start(conn, workflow_id="wf-telemetry-003", provider="codex")
    critic_runs.complete(
        conn,
        run_id=r1["run_id"],
        verdict="TRY_AGAIN",
        summary="Need another pass.",
        metrics={"try_again_streak": 1, "retry_limit": 2},
    )
    r2 = critic_runs.start(conn, workflow_id="wf-telemetry-003", provider="codex")
    critic_runs.complete(
        conn,
        run_id=r2["run_id"],
        verdict="READY_FOR_REVIEWER",
        summary="Ready.",
    )
    r3 = critic_runs.start(conn, workflow_id="wf-telemetry-003", provider="codex")
    critic_runs.complete(
        conn,
        run_id=r3["run_id"],
        verdict="CRITIC_UNAVAILABLE",
        summary="Unavailable.",
        fallback="reviewer",
        metrics={"escalation_reason": "provider_unavailable"},
    )

    metrics = critic_runs.metrics(conn, workflow_id="wf-telemetry-003").as_dict()
    assert metrics["total_runs"] == 3
    assert metrics["final_runs"] == 3
    assert metrics["try_again"] == 1
    assert metrics["ready_for_reviewer"] == 1
    assert metrics["critic_unavailable"] == 1
    assert metrics["loopback_rate"] == pytest.approx(1 / 3)
    assert metrics["unavailable_rate"] == pytest.approx(1 / 3)
    assert metrics["fallback_completion_rate"] == 0.0
    assert metrics["escalation_counts"] == {"provider_unavailable": 1}
