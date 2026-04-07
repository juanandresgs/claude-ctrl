"""Unit tests for runtime.core.observatory — W-OBS-1.

Tests use an in-memory SQLite database with the full schema applied.
All 20 evaluation-contract checks that are unit-testable are covered here.
Real-path CLI checks (EC-13 through EC-20) run via test_cc_policy.sh.

@decision DEC-OBS-001
Title: Observatory tables are sole authority for metrics, suggestions, and runs
Status: accepted
Rationale: obs_metrics, obs_suggestions, obs_runs are created idempotently by
  ensure_schema(). These tests confirm each table is fully operational through
  the domain module API. No mocks — all assertions go through real SQLite.

Production trigger sequence:
  1. A hook or agent calls rt_obs_metric (shell) or emit_metric (Python).
  2. cc-policy obs emit writes a row to obs_metrics via observatory_mod.
  3. Periodically, cc-policy obs summary calls summary() which calls
     detect_anomalies(), check_convergence(), and record_run().
  4. Suggestions accumulate via suggest(); lifecycle flows through
     accept/reject/defer/batch_accept/check_convergence.
  5. obs_cleanup() purges expired rows on a maintenance schedule.

These tests exercise that exact sequence end-to-end (test_full_production_sequence).
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import runtime.core.observatory as obs
from runtime.core.db import connect_memory
from runtime.schemas import ensure_schema

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


# ---------------------------------------------------------------------------
# EC-2: emit_metric + query_metrics round-trip (including role column)
# ---------------------------------------------------------------------------


def test_emit_metric_returns_integer_id(conn):
    row_id = obs.emit_metric(conn, "test_metric", 1.0)
    assert isinstance(row_id, int)
    assert row_id >= 1


def test_emit_and_query_round_trip_full_fields(conn):
    """EC-2: emitted row has correct metric_name, value, role, labels_json,
    session_id, created_at. Query by name returns the row."""
    before = int(time.time()) - 1
    row_id = obs.emit_metric(
        conn,
        name="cpu_usage",
        value=0.75,
        labels={"host": "worker-1"},
        session_id="sess-abc",
        role="implementer",
    )
    rows = obs.query_metrics(conn, "cpu_usage")
    assert len(rows) == 1
    r = rows[0]
    assert r["id"] == row_id
    assert r["metric_name"] == "cpu_usage"
    assert r["value"] == pytest.approx(0.75)
    assert r["role"] == "implementer"
    assert r["session_id"] == "sess-abc"
    assert r["created_at"] >= before
    # labels_json round-trips as a JSON string containing the dict
    import json

    assert json.loads(r["labels_json"]) == {"host": "worker-1"}


def test_query_with_role_filter_returns_only_matching_rows(conn):
    """EC-2: Query with role filter returns only matching rows (uses indexed role column)."""
    obs.emit_metric(conn, "m", 1.0, role="implementer")
    obs.emit_metric(conn, "m", 2.0, role="tester")
    obs.emit_metric(conn, "m", 3.0, role="implementer")

    impl_rows = obs.query_metrics(conn, "m", role="implementer")
    assert len(impl_rows) == 2
    assert all(r["role"] == "implementer" for r in impl_rows)

    tester_rows = obs.query_metrics(conn, "m", role="tester")
    assert len(tester_rows) == 1
    assert tester_rows[0]["value"] == pytest.approx(2.0)


def test_query_returns_empty_for_unknown_metric(conn):
    rows = obs.query_metrics(conn, "no_such_metric")
    assert rows == []


def test_query_since_filter(conn):
    obs.emit_metric(conn, "m", 1.0)
    conn.execute("UPDATE obs_metrics SET created_at = 1000 WHERE id = 1")
    conn.commit()
    obs.emit_metric(conn, "m", 2.0)
    now = int(time.time()) - 5
    rows = obs.query_metrics(conn, "m", since=now)
    assert len(rows) == 1
    assert rows[0]["value"] == pytest.approx(2.0)


def test_query_labels_filter(conn):
    obs.emit_metric(conn, "req", 1.0, labels={"env": "prod"})
    obs.emit_metric(conn, "req", 2.0, labels={"env": "staging"})
    rows = obs.query_metrics(conn, "req", labels_filter={"env": "prod"})
    assert len(rows) == 1
    assert rows[0]["value"] == pytest.approx(1.0)


# ---------------------------------------------------------------------------
# EC-3: emit_batch — all rows in single transaction
# ---------------------------------------------------------------------------


def test_emit_batch_inserts_all_rows(conn):
    """EC-3: emit_batch with 5+ metrics — all rows persisted, count matches."""
    metrics = [
        {"name": "latency", "value": float(i), "labels": {"idx": i}, "role": "tester"}
        for i in range(6)
    ]
    count = obs.emit_batch(conn, metrics)
    assert count == 6
    rows = obs.query_metrics(conn, "latency", limit=10)
    assert len(rows) == 6
    for i, r in enumerate(rows):
        assert r["value"] == pytest.approx(float(i))
        assert r["role"] == "tester"


def test_emit_batch_empty(conn):
    count = obs.emit_batch(conn, [])
    assert count == 0
    rows = obs.query_metrics(conn, "latency")
    assert rows == []


def test_emit_batch_no_optional_fields(conn):
    metrics = [{"name": "bare", "value": 1.0}, {"name": "bare", "value": 2.0}]
    count = obs.emit_batch(conn, metrics)
    assert count == 2
    rows = obs.query_metrics(conn, "bare")
    assert len(rows) == 2


# ---------------------------------------------------------------------------
# EC-4: compute_trend
# ---------------------------------------------------------------------------


def test_compute_trend_with_10_points(conn):
    """EC-4: compute_trend with 10+ data points returns dict with slope and average."""
    for i in range(12):
        obs.emit_metric(conn, "rps", float(i * 10))
    result = obs.compute_trend(conn, "rps")
    assert "slope" in result
    assert "average" in result
    assert "count" in result
    assert "first_value" in result
    assert "last_value" in result
    assert result["count"] == 12
    assert result["first_value"] == pytest.approx(0.0)
    assert result["last_value"] == pytest.approx(110.0)
    # slope = (110 - 0) / 12
    assert result["slope"] == pytest.approx(110.0 / 12)
    assert result["average"] == pytest.approx(sum(i * 10 for i in range(12)) / 12)


def test_compute_trend_empty_metric(conn):
    result = obs.compute_trend(conn, "no_data")
    assert result["count"] == 0
    assert result["slope"] == 0.0
    assert result["average"] == 0.0


def test_compute_trend_single_point(conn):
    obs.emit_metric(conn, "single", 42.0)
    result = obs.compute_trend(conn, "single")
    assert result["count"] == 1
    assert result["slope"] == 0.0
    assert result["average"] == pytest.approx(42.0)


# ---------------------------------------------------------------------------
# EC-5: detect_anomalies — injected outlier is returned
# ---------------------------------------------------------------------------


def test_detect_anomalies_returns_outlier_row(conn):
    """EC-5: detect_anomalies with injected outlier returns the outlier row
    (verify returned row's value matches the injected outlier)."""
    # Insert 9 normal values clustered around 10
    for _ in range(9):
        obs.emit_metric(conn, "latency_p99", 10.0)
    # Inject a clear outlier
    obs.emit_metric(conn, "latency_p99", 1000.0)

    anomalies = obs.detect_anomalies(conn, "latency_p99")
    assert len(anomalies) >= 1
    # The returned row's value must match the injected outlier
    values = [r["value"] for r in anomalies]
    assert 1000.0 in values


def test_detect_anomalies_no_outlier(conn):
    for _ in range(10):
        obs.emit_metric(conn, "stable", 5.0)
    anomalies = obs.detect_anomalies(conn, "stable")
    # All identical values → stddev=0 → no anomalies
    assert anomalies == []


def test_detect_anomalies_insufficient_data(conn):
    obs.emit_metric(conn, "sparse", 42.0)
    anomalies = obs.detect_anomalies(conn, "sparse")
    assert anomalies == []


# ---------------------------------------------------------------------------
# EC-6: Full suggestion lifecycle
# ---------------------------------------------------------------------------


def test_full_suggestion_lifecycle(conn):
    """EC-6: propose (with signal_id) → accept (with measure_after) →
    measure → converge. Verify each status transition and that
    signal_id, reject_reason, defer_reassess_after columns are
    correctly populated."""
    # Propose
    sid = obs.suggest(
        conn,
        category="perf",
        title="Speed up impl",
        body="Reduce context size",
        target_metric="agent_duration_s",
        baseline=60.0,
        signal_id="sig:perf:001",
        source_session="sess-xyz",
    )
    row = conn.execute("SELECT * FROM obs_suggestions WHERE id=?", (sid,)).fetchone()
    assert row["status"] == "proposed"
    assert row["signal_id"] == "sig:perf:001"
    assert row["category"] == "perf"
    assert row["baseline_value"] == pytest.approx(60.0)

    # Accept with measure_after in the past so convergence fires immediately
    past = int(time.time()) - 1
    obs.accept_suggestion(conn, sid, measure_after=past)
    row = conn.execute("SELECT * FROM obs_suggestions WHERE id=?", (sid,)).fetchone()
    assert row["status"] == "accepted"
    assert row["measure_after"] == past

    # Emit metric so convergence has data (improved: avg=40 vs baseline=60, change=-33%)
    for _ in range(5):
        obs.emit_metric(conn, "agent_duration_s", 40.0)

    # Converge
    results = obs.check_convergence(conn)
    assert len(results) >= 1
    match = next((r for r in results if r["id"] == sid), None)
    assert match is not None
    # 40 vs 60 → change = (40-60)/60 = -0.33 → regressed (effective=-1)
    assert match["effective"] == -1
    assert match["measured_value"] == pytest.approx(40.0)

    row = conn.execute("SELECT * FROM obs_suggestions WHERE id=?", (sid,)).fetchone()
    assert row["status"] == "measured"


def test_reject_suggestion_populates_reason(conn):
    sid = obs.suggest(conn, "cat", "title")
    obs.reject_suggestion(conn, sid, reason="not actionable")
    row = conn.execute("SELECT * FROM obs_suggestions WHERE id=?", (sid,)).fetchone()
    assert row["status"] == "rejected"
    assert row["reject_reason"] == "not actionable"
    assert row["disposition_at"] is not None


def test_defer_suggestion_populates_reassess_after(conn):
    sid = obs.suggest(conn, "cat", "title")
    obs.defer_suggestion(conn, sid, reassess_after=14)
    row = conn.execute("SELECT * FROM obs_suggestions WHERE id=?", (sid,)).fetchone()
    assert row["status"] == "deferred"
    assert row["defer_reassess_after"] == 14
    assert row["disposition_at"] is not None


# ---------------------------------------------------------------------------
# EC-7: batch_accept
# ---------------------------------------------------------------------------


def test_batch_accept_transitions_correct_category(conn):
    """EC-7: batch_accept with 3+ proposed suggestions in a category — all
    transition to accepted; suggestions in other categories remain proposed."""
    ids_perf = [obs.suggest(conn, "perf", f"Perf suggestion {i}") for i in range(3)]
    ids_other = [obs.suggest(conn, "reliability", f"Reliability {i}") for i in range(2)]

    count = obs.batch_accept(conn, "perf")
    assert count == 3

    for sid in ids_perf:
        row = conn.execute("SELECT status FROM obs_suggestions WHERE id=?", (sid,)).fetchone()
        assert row["status"] == "accepted"

    for sid in ids_other:
        row = conn.execute("SELECT status FROM obs_suggestions WHERE id=?", (sid,)).fetchone()
        assert row["status"] == "proposed"


def test_batch_accept_skips_already_accepted(conn):
    sid = obs.suggest(conn, "cat", "already accepted")
    obs.accept_suggestion(conn, sid)
    count = obs.batch_accept(conn, "cat")
    assert count == 0


# ---------------------------------------------------------------------------
# EC-8: check_convergence classification
# ---------------------------------------------------------------------------


def test_check_convergence_improved(conn):
    """EC-8: improved → effective=1 (metric improved ≥10% from baseline)."""
    # baseline=100, measured=200 → change=+100% → improved
    sid = obs.suggest(conn, "cat", "improve", target_metric="score", baseline=100.0)
    past = int(time.time()) - 1
    obs.accept_suggestion(conn, sid, measure_after=past)
    for _ in range(5):
        obs.emit_metric(conn, "score", 200.0)
    results = obs.check_convergence(conn)
    match = next(r for r in results if r["id"] == sid)
    assert match["effective"] == 1


def test_check_convergence_unchanged(conn):
    """EC-8: unchanged → effective=0 (change < 10%)."""
    # baseline=100, measured=105 → change=+5% → unchanged
    sid = obs.suggest(conn, "cat", "stable", target_metric="score2", baseline=100.0)
    past = int(time.time()) - 1
    obs.accept_suggestion(conn, sid, measure_after=past)
    for _ in range(5):
        obs.emit_metric(conn, "score2", 105.0)
    results = obs.check_convergence(conn)
    match = next(r for r in results if r["id"] == sid)
    assert match["effective"] == 0


def test_check_convergence_regressed(conn):
    """EC-8: regressed → effective=-1 (metric regressed ≥10% from baseline)."""
    # baseline=100, measured=50 → change=-50% → regressed
    sid = obs.suggest(conn, "cat", "regress", target_metric="score3", baseline=100.0)
    past = int(time.time()) - 1
    obs.accept_suggestion(conn, sid, measure_after=past)
    for _ in range(5):
        obs.emit_metric(conn, "score3", 50.0)
    results = obs.check_convergence(conn)
    match = next(r for r in results if r["id"] == sid)
    assert match["effective"] == -1


def test_check_convergence_skips_future_measure_after(conn):
    """Suggestions with measure_after in the future are not touched."""
    future = int(time.time()) + 86400
    sid = obs.suggest(conn, "cat", "future")
    obs.accept_suggestion(conn, sid, measure_after=future)
    results = obs.check_convergence(conn)
    assert not any(r["id"] == sid for r in results)
    row = conn.execute("SELECT status FROM obs_suggestions WHERE id=?", (sid,)).fetchone()
    assert row["status"] == "accepted"


# ---------------------------------------------------------------------------
# EC-9: record_run + latest_run round-trip
# ---------------------------------------------------------------------------


def test_record_run_and_latest_run_round_trip(conn):
    """EC-9: record_run inserts a row; latest_run returns it with correct
    metrics_snapshot JSON and counts."""
    import json

    snapshot = {"active_agents": 3, "pending_suggestions": 7}
    row_id = obs.record_run(conn, metrics_snapshot=snapshot, trace_count=12, suggestion_count=5)
    assert isinstance(row_id, int)

    latest = obs.latest_run(conn)
    assert latest is not None
    assert latest["id"] == row_id
    assert latest["trace_count"] == 12
    assert latest["suggestion_count"] == 5
    assert json.loads(latest["metrics_snapshot"]) == snapshot


def test_latest_run_returns_none_when_empty(conn):
    assert obs.latest_run(conn) is None


def test_latest_run_returns_most_recent(conn):
    obs.record_run(conn, trace_count=1)
    obs.record_run(conn, trace_count=2)
    latest = obs.latest_run(conn)
    assert latest["trace_count"] == 2


# ---------------------------------------------------------------------------
# EC-10: obs_cleanup
# ---------------------------------------------------------------------------


def test_obs_cleanup_removes_old_metrics(conn):
    """EC-10: obs_cleanup deletes metrics older than TTL; preserves recent data."""
    obs.emit_metric(conn, "old_m", 1.0)
    conn.execute("UPDATE obs_metrics SET created_at = 100 WHERE id = 1")
    conn.commit()
    obs.emit_metric(conn, "recent_m", 2.0)

    result = obs.obs_cleanup(conn, metrics_ttl_days=1, suggestions_ttl_days=1)
    assert result["metrics_deleted"] == 1

    rows = obs.query_metrics(conn, "old_m")
    assert len(rows) == 0
    rows = obs.query_metrics(conn, "recent_m")
    assert len(rows) == 1


def test_obs_cleanup_removes_terminal_suggestions(conn):
    """EC-10: obs_cleanup deletes terminal suggestions older than TTL."""
    sid = obs.suggest(conn, "cat", "old suggestion")
    obs.reject_suggestion(conn, sid, reason="stale")
    # Back-date disposition_at
    conn.execute("UPDATE obs_suggestions SET disposition_at = 100 WHERE id=?", (sid,))
    conn.commit()

    result = obs.obs_cleanup(conn, metrics_ttl_days=30, suggestions_ttl_days=1)
    assert result["suggestions_deleted"] == 1

    row = conn.execute("SELECT * FROM obs_suggestions WHERE id=?", (sid,)).fetchone()
    assert row is None


def test_obs_cleanup_preserves_proposed_suggestions(conn):
    """EC-10: obs_cleanup does not delete proposed (non-terminal) suggestions."""
    sid = obs.suggest(conn, "cat", "active suggestion")
    # Even with old created_at, proposed suggestions are not terminal
    result = obs.obs_cleanup(conn, metrics_ttl_days=1, suggestions_ttl_days=1)
    assert result["suggestions_deleted"] == 0

    row = conn.execute("SELECT * FROM obs_suggestions WHERE id=?", (sid,)).fetchone()
    assert row is not None


# ---------------------------------------------------------------------------
# EC-11: status returns expected keys
# ---------------------------------------------------------------------------


def test_status_returns_expected_keys(conn):
    """EC-11: status returns dict with keys: pending_count, acceptance_rate,
    last_analysis_at, total_metrics."""
    result = obs.status(conn)
    assert "pending_count" in result
    assert "acceptance_rate" in result
    assert "last_analysis_at" in result
    assert "total_metrics" in result


def test_status_pending_count_and_acceptance_rate(conn):
    obs.emit_metric(conn, "m", 1.0)
    obs.emit_metric(conn, "m", 2.0)

    sid1 = obs.suggest(conn, "cat", "s1")
    sid2 = obs.suggest(conn, "cat", "s2")
    sid3 = obs.suggest(conn, "cat", "s3")
    obs.accept_suggestion(conn, sid1)
    obs.accept_suggestion(conn, sid2)
    obs.reject_suggestion(conn, sid3)

    result = obs.status(conn)
    # sid4 (proposed) not yet created — only sid1,sid2,sid3 exist
    # pending_count = 0 (no proposed suggestions left after accept/reject)
    assert result["pending_count"] == 0
    # acceptance_rate = 2 accepted / (2 accepted + 1 rejected) = 2/3
    assert result["acceptance_rate"] == pytest.approx(2 / 3)
    assert result["total_metrics"] == 2
    # No run recorded yet
    assert result["last_analysis_at"] is None


def test_status_last_analysis_at_after_record_run(conn):
    obs.record_run(conn)
    result = obs.status(conn)
    assert result["last_analysis_at"] is not None
    assert result["last_analysis_at"] > 0


def test_status_zero_acceptance_rate_when_no_decisions(conn):
    obs.suggest(conn, "cat", "pending only")
    result = obs.status(conn)
    assert result["pending_count"] == 1
    assert result["acceptance_rate"] == 0.0


# ---------------------------------------------------------------------------
# EC-12: summary
# ---------------------------------------------------------------------------


def test_summary_returns_expected_keys(conn):
    """EC-12: summary delegates to generate_report() — result has generate_report keys.

    W-OBS-3 replaced the bespoke summary assembly with generate_report() delegation.
    The old keys (metrics_24h, active_suggestions, agent_performance, denial_hotspots,
    recent_anomalies, convergence_results) are superseded by the richer structure.
    """
    result = obs.summary(conn)
    assert "metrics_summary" in result
    assert "trends" in result
    assert "patterns" in result
    assert "suggestions" in result
    assert "convergence" in result
    assert "review_gate_health" in result


def test_summary_records_obs_run(conn):
    """EC-12: summary also records an obs_runs entry (verify row count increments)."""
    before = conn.execute("SELECT COUNT(*) FROM obs_runs").fetchone()[0]
    obs.summary(conn)
    after = conn.execute("SELECT COUNT(*) FROM obs_runs").fetchone()[0]
    assert after == before + 1


def test_summary_metrics_24h_count(conn):
    for _ in range(5):
        obs.emit_metric(conn, "probe", 1.0)
    result = obs.summary(conn)
    # W-OBS-3: metrics_24h moved into metrics_summary.total
    assert result["metrics_summary"]["total"] >= 5


# ---------------------------------------------------------------------------
# Compound interaction: full production sequence end-to-end
# ---------------------------------------------------------------------------


def test_full_production_sequence(conn):
    """Compound-interaction test: exercises the real production sequence crossing
    multiple internal component boundaries.

    Sequence:
      1. Batch-emit metrics (simulating hook instrumentation)
      2. Compute trend and detect anomalies
      3. Create suggestions from anomaly detection results
      4. Batch-accept suggestions in category
      5. Run convergence check (none ready yet — all future)
      6. Run summary() — records obs_run
      7. Run cleanup — purges stale data
      8. Verify final status() reflects correct state

    This mirrors what W-OBS-3 hooks and W-OBS-4 analysis will do in production.
    """
    # Step 1: batch-emit agent duration metrics
    metrics = [
        {"name": "agent_duration_s", "value": float(v), "role": "implementer"}
        for v in [30, 35, 32, 28, 900, 31, 29, 33, 34, 36]  # 900 is an outlier
    ]
    inserted = obs.emit_batch(conn, metrics)
    assert inserted == 10

    # Step 2: trend + anomaly detection
    trend = obs.compute_trend(conn, "agent_duration_s")
    assert trend["count"] == 10
    anomalies = obs.detect_anomalies(conn, "agent_duration_s")
    assert len(anomalies) == 1
    assert anomalies[0]["value"] == pytest.approx(900.0)

    # Step 3: create suggestions based on anomaly
    for i in range(3):
        obs.suggest(
            conn,
            category="perf",
            title=f"Reduce impl duration anomaly {i}",
            target_metric="agent_duration_s",
            baseline=trend["average"],
            signal_id=f"anomaly:{i}",
        )
    # Also suggest in a different category
    obs.suggest(conn, "reliability", "Increase test coverage")

    count = conn.execute("SELECT COUNT(*) FROM obs_suggestions WHERE status='proposed'").fetchone()[
        0
    ]
    assert count == 4

    # Step 4: batch-accept perf suggestions
    accepted = obs.batch_accept(conn, "perf")
    assert accepted == 3

    # Verify reliability suggestion unchanged
    rel_row = conn.execute(
        "SELECT status FROM obs_suggestions WHERE category='reliability'"
    ).fetchone()
    assert rel_row["status"] == "proposed"

    # Step 5: convergence — none ready (measure_after is 7 days in future)
    results = obs.check_convergence(conn)
    assert results == []

    # Step 6: summary records an obs_run
    run_count_before = conn.execute("SELECT COUNT(*) FROM obs_runs").fetchone()[0]
    report = obs.summary(conn)
    run_count_after = conn.execute("SELECT COUNT(*) FROM obs_runs").fetchone()[0]
    assert run_count_after == run_count_before + 1

    # Summary structure is complete (W-OBS-3: keys from generate_report)
    assert report["metrics_summary"]["total"] >= 10
    assert len(report["suggestions"]) >= 3  # 3 accepted + 1 proposed = 4 active
    assert "trends" in report
    assert "agent_duration_s" in report["trends"]

    # Step 7: cleanup — no expired data yet (all recent)
    cleanup_result = obs.obs_cleanup(conn, metrics_ttl_days=30, suggestions_ttl_days=90)
    assert cleanup_result["metrics_deleted"] == 0
    assert cleanup_result["suggestions_deleted"] == 0

    # Step 8: final status
    final = obs.status(conn)
    assert final["total_metrics"] == 10
    # 1 proposed (reliability) + 3 accepted = pending_count = 1 proposed
    assert final["pending_count"] == 1
    # acceptance_rate: 3 accepted / (3 + 0 rejected) = 1.0
    assert final["acceptance_rate"] == pytest.approx(1.0)
    assert final["last_analysis_at"] is not None


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------


def test_denial_hotspots_groups_by_policy(conn):
    obs.emit_metric(conn, "guard_denial", 1.0, labels={"policy": "branch-guard"})
    obs.emit_metric(conn, "guard_denial", 1.0, labels={"policy": "branch-guard"})
    obs.emit_metric(conn, "guard_denial", 1.0, labels={"policy": "scope-guard"})

    hotspots = obs.denial_hotspots(conn)
    assert hotspots[0]["policy"] == "branch-guard"
    assert hotspots[0]["count"] == 2
    assert hotspots[1]["policy"] == "scope-guard"
    assert hotspots[1]["count"] == 1


def test_test_health_pass_rate(conn):
    for _ in range(7):
        obs.emit_metric(conn, "test_result", 1.0)
    for _ in range(3):
        obs.emit_metric(conn, "test_result", 0.0)
    health = obs.test_health(conn)
    assert health["total"] == 10
    assert health["passed"] == 7
    assert health["failed"] == 3
    assert health["pass_rate"] == pytest.approx(0.7)


def test_agent_performance_returns_stats(conn):
    for v in [10.0, 20.0, 30.0]:
        obs.emit_metric(conn, "agent_duration_s", v, role="guardian")
    perf = obs.agent_performance(conn, "guardian")
    assert perf["count"] == 3
    assert perf["average"] == pytest.approx(20.0)
    assert perf["min"] == pytest.approx(10.0)
    assert perf["max"] == pytest.approx(30.0)


def test_accept_suggestion_default_measure_after(conn):
    """accept_suggestion with no measure_after defaults to now + 7 days."""
    sid = obs.suggest(conn, "cat", "title")
    before = int(time.time())
    obs.accept_suggestion(conn, sid)
    row = conn.execute("SELECT measure_after FROM obs_suggestions WHERE id=?", (sid,)).fetchone()
    assert row["measure_after"] >= before + 7 * 86400 - 1
