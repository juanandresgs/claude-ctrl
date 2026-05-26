"""Unit tests for runtime.core.eval_metrics.

Tests CRUD operations against eval_results.db using in-memory SQLite.
No subprocess, no disk I/O except the get_eval_conn() directory-creation test.

Covers:
  - create_run() returns UUID string
  - get_run() returns correct dict / None for missing
  - record_score() round-trips all fields correctly
  - record_output() round-trips correctly
  - finalize_run() computes correct pass/fail/error counts
  - list_runs() ordering and limit
  - get_scores() returns scores for specific run
  - get_eval_conn() creates .claude/ directory if missing

@decision DEC-EVAL-METRICS-001
Title: eval_metrics is the sole CRUD authority for eval_results.db
Status: accepted
Rationale: Following the same pattern as runtime/core/evaluation.py — conn
  as first arg, returns plain dicts via sqlite3.Row. All mutations are in
  explicit transactions. Tests use connect_memory() + ensure_eval_schema()
  so they never touch disk state.
"""

from __future__ import annotations

import sqlite3
import sys
import uuid
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import runtime.core.eval_metrics as eval_metrics
from runtime.eval_schemas import ensure_eval_schema

from runtime.core.db import connect_memory


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_eval_schema(c)
    yield c
    c.close()


@pytest.fixture
def run_id(conn):
    return eval_metrics.create_run(conn, mode="deterministic")


# ---------------------------------------------------------------------------
# create_run()
# ---------------------------------------------------------------------------


def test_create_run_returns_string(conn):
    result = eval_metrics.create_run(conn, mode="deterministic")
    assert isinstance(result, str)


def test_create_run_returns_uuid(conn):
    result = eval_metrics.create_run(conn, mode="deterministic")
    # Must be parseable as UUID
    parsed = uuid.UUID(result)
    assert str(parsed) == result


def test_create_run_deterministic_mode(conn):
    run = eval_metrics.create_run(conn, mode="deterministic")
    row = eval_metrics.get_run(conn, run)
    assert row["mode"] == "deterministic"


def test_create_run_live_mode(conn):
    run = eval_metrics.create_run(conn, mode="live")
    row = eval_metrics.get_run(conn, run)
    assert row["mode"] == "live"


def test_create_run_with_metadata(conn):
    meta = '{"initiator": "tester-agent", "wave": 1}'
    run = eval_metrics.create_run(conn, mode="deterministic", metadata=meta)
    row = eval_metrics.get_run(conn, run)
    assert row["metadata_json"] == meta


def test_create_run_without_metadata(conn):
    run = eval_metrics.create_run(conn, mode="deterministic")
    row = eval_metrics.get_run(conn, run)
    assert row["metadata_json"] is None


def test_create_run_initial_counts_zero(conn):
    run = eval_metrics.create_run(conn, mode="deterministic")
    row = eval_metrics.get_run(conn, run)
    assert row["scenario_count"] == 0
    assert row["pass_count"] == 0
    assert row["fail_count"] == 0
    assert row["error_count"] == 0


def test_create_run_finished_at_initially_null(conn):
    run = eval_metrics.create_run(conn, mode="deterministic")
    row = eval_metrics.get_run(conn, run)
    assert row["finished_at"] is None


def test_create_run_started_at_populated(conn):
    run = eval_metrics.create_run(conn, mode="deterministic")
    row = eval_metrics.get_run(conn, run)
    assert row["started_at"] is not None
    assert row["started_at"] > 0


def test_create_run_unique_ids(conn):
    id1 = eval_metrics.create_run(conn, mode="deterministic")
    id2 = eval_metrics.create_run(conn, mode="deterministic")
    assert id1 != id2


# ---------------------------------------------------------------------------
# get_run()
# ---------------------------------------------------------------------------


def test_get_run_missing_returns_none(conn):
    assert eval_metrics.get_run(conn, "nonexistent-uuid") is None


def test_get_run_returns_dict(conn, run_id):
    row = eval_metrics.get_run(conn, run_id)
    assert isinstance(row, dict)


def test_get_run_has_run_id_key(conn, run_id):
    row = eval_metrics.get_run(conn, run_id)
    assert row["run_id"] == run_id


def test_get_run_has_all_expected_keys(conn, run_id):
    row = eval_metrics.get_run(conn, run_id)
    expected_keys = {
        "run_id",
        "started_at",
        "finished_at",
        "mode",
        "scenario_count",
        "pass_count",
        "fail_count",
        "error_count",
        "metadata_json",
    }
    assert expected_keys.issubset(set(row.keys()))


# ---------------------------------------------------------------------------
# record_score()
# ---------------------------------------------------------------------------


def test_record_score_minimal(conn, run_id):
    # Must not raise
    eval_metrics.record_score(conn, run_id, "scenario-1", "gate", "deny")


def test_record_score_round_trips_verdict_expected(conn, run_id):
    eval_metrics.record_score(conn, run_id, "s1", "gate", "ready_for_guardian")
    scores = eval_metrics.get_scores(conn, run_id)
    assert len(scores) == 1
    assert scores[0]["verdict_expected"] == "ready_for_guardian"


def test_record_score_round_trips_verdict_actual(conn, run_id):
    eval_metrics.record_score(
        conn, run_id, "s1", "gate", "deny", verdict_actual="deny", verdict_correct=1
    )
    scores = eval_metrics.get_scores(conn, run_id)
    assert scores[0]["verdict_actual"] == "deny"
    assert scores[0]["verdict_correct"] == 1


def test_record_score_round_trips_defect_recall(conn, run_id):
    eval_metrics.record_score(conn, run_id, "s1", "judgment", "needs_changes", defect_recall=0.85)
    scores = eval_metrics.get_scores(conn, run_id)
    assert abs(scores[0]["defect_recall"] - 0.85) < 1e-9


def test_record_score_round_trips_evidence_score(conn, run_id):
    eval_metrics.record_score(conn, run_id, "s1", "judgment", "needs_changes", evidence_score=0.72)
    scores = eval_metrics.get_scores(conn, run_id)
    assert abs(scores[0]["evidence_score"] - 0.72) < 1e-9


def test_record_score_round_trips_false_positive_count(conn, run_id):
    eval_metrics.record_score(conn, run_id, "s1", "adversarial", "pending", false_positive_count=3)
    scores = eval_metrics.get_scores(conn, run_id)
    assert scores[0]["false_positive_count"] == 3


def test_record_score_round_trips_confidence_fields(conn, run_id):
    eval_metrics.record_score(
        conn, run_id, "s1", "gate", "deny", confidence_expected="High", confidence_actual="High"
    )
    scores = eval_metrics.get_scores(conn, run_id)
    assert scores[0]["confidence_expected"] == "High"
    assert scores[0]["confidence_actual"] == "High"


def test_record_score_round_trips_duration_ms(conn, run_id):
    eval_metrics.record_score(conn, run_id, "s1", "gate", "deny", duration_ms=1234)
    scores = eval_metrics.get_scores(conn, run_id)
    assert scores[0]["duration_ms"] == 1234


def test_record_score_round_trips_error_message(conn, run_id):
    eval_metrics.record_score(conn, run_id, "s1", "gate", "deny", error_message="timeout after 30s")
    scores = eval_metrics.get_scores(conn, run_id)
    assert scores[0]["error_message"] == "timeout after 30s"


def test_record_score_round_trips_category(conn, run_id):
    for cat in ("gate", "judgment", "adversarial"):
        eval_metrics.record_score(conn, run_id, f"s-{cat}", cat, "pending")
    scores = eval_metrics.get_scores(conn, run_id)
    cats = {s["category"] for s in scores}
    assert cats == {"gate", "judgment", "adversarial"}


def test_record_score_scored_at_populated(conn, run_id):
    eval_metrics.record_score(conn, run_id, "s1", "gate", "deny")
    scores = eval_metrics.get_scores(conn, run_id)
    assert scores[0]["scored_at"] > 0


def test_record_score_default_verdict_correct_is_zero(conn, run_id):
    eval_metrics.record_score(conn, run_id, "s1", "gate", "deny")
    scores = eval_metrics.get_scores(conn, run_id)
    assert scores[0]["verdict_correct"] == 0


def test_record_score_default_false_positive_count_is_zero(conn, run_id):
    eval_metrics.record_score(conn, run_id, "s1", "gate", "deny")
    scores = eval_metrics.get_scores(conn, run_id)
    assert scores[0]["false_positive_count"] == 0


# ---------------------------------------------------------------------------
# record_output()
# ---------------------------------------------------------------------------


def test_record_output_minimal(conn, run_id):
    eval_metrics.record_output(conn, run_id, "s1", "raw output text")


def test_record_output_round_trips_raw_output(conn, run_id):
    eval_metrics.record_output(conn, run_id, "s1", "The agent said: pass")
    rows = conn.execute(
        "SELECT raw_output FROM eval_outputs WHERE run_id=? AND scenario_id=?",
        (run_id, "s1"),
    ).fetchall()
    assert len(rows) == 1
    assert rows[0][0] == "The agent said: pass"


def test_record_output_round_trips_trailer_json(conn, run_id):
    tj = '{"IMPL_STATUS": "complete"}'
    eval_metrics.record_output(conn, run_id, "s1", "output", trailer_json=tj)
    rows = conn.execute(
        "SELECT trailer_json FROM eval_outputs WHERE run_id=? AND scenario_id=?",
        (run_id, "s1"),
    ).fetchall()
    assert rows[0][0] == tj


def test_record_output_round_trips_evidence_text(conn, run_id):
    ev = "write_who denied the write"
    eval_metrics.record_output(conn, run_id, "s1", "output", evidence_text=ev)
    rows = conn.execute(
        "SELECT evidence_text FROM eval_outputs WHERE run_id=? AND scenario_id=?",
        (run_id, "s1"),
    ).fetchall()
    assert rows[0][0] == ev


def test_record_output_round_trips_coverage_json(conn, run_id):
    cj = '{"covered": ["write_who", "deny"]}'
    eval_metrics.record_output(conn, run_id, "s1", "output", coverage_json=cj)
    rows = conn.execute(
        "SELECT coverage_json FROM eval_outputs WHERE run_id=? AND scenario_id=?",
        (run_id, "s1"),
    ).fetchall()
    assert rows[0][0] == cj


def test_record_output_captured_at_populated(conn, run_id):
    eval_metrics.record_output(conn, run_id, "s1", "output")
    rows = conn.execute(
        "SELECT captured_at FROM eval_outputs WHERE run_id=? AND scenario_id=?",
        (run_id, "s1"),
    ).fetchall()
    assert rows[0][0] > 0


# ---------------------------------------------------------------------------
# finalize_run()
# ---------------------------------------------------------------------------


def test_finalize_run_all_pass(conn, run_id):
    for i in range(3):
        eval_metrics.record_score(conn, run_id, f"s{i}", "gate", "deny", verdict_correct=1)
    eval_metrics.finalize_run(conn, run_id)
    row = eval_metrics.get_run(conn, run_id)
    assert row["pass_count"] == 3
    assert row["fail_count"] == 0
    assert row["error_count"] == 0
    assert row["scenario_count"] == 3
    assert row["finished_at"] is not None


def test_finalize_run_mixed(conn, run_id):
    # 2 pass, 1 fail, 1 error
    eval_metrics.record_score(conn, run_id, "s1", "gate", "deny", verdict_correct=1)
    eval_metrics.record_score(conn, run_id, "s2", "gate", "deny", verdict_correct=1)
    eval_metrics.record_score(conn, run_id, "s3", "gate", "deny", verdict_correct=0)
    eval_metrics.record_score(
        conn, run_id, "s4", "gate", "deny", verdict_correct=0, error_message="crash"
    )
    eval_metrics.finalize_run(conn, run_id)
    row = eval_metrics.get_run(conn, run_id)
    assert row["pass_count"] == 2
    assert row["fail_count"] == 1
    assert row["error_count"] == 1
    assert row["scenario_count"] == 4


def test_finalize_run_no_scores(conn, run_id):
    eval_metrics.finalize_run(conn, run_id)
    row = eval_metrics.get_run(conn, run_id)
    assert row["pass_count"] == 0
    assert row["fail_count"] == 0
    assert row["error_count"] == 0
    assert row["scenario_count"] == 0
    assert row["finished_at"] is not None


def test_finalize_run_sets_finished_at(conn, run_id):
    eval_metrics.finalize_run(conn, run_id)
    row = eval_metrics.get_run(conn, run_id)
    assert row["finished_at"] is not None
    assert row["finished_at"] > 0


def test_finalize_run_all_errors(conn, run_id):
    for i in range(2):
        eval_metrics.record_score(
            conn, run_id, f"s{i}", "gate", "deny", verdict_correct=0, error_message="boom"
        )
    eval_metrics.finalize_run(conn, run_id)
    row = eval_metrics.get_run(conn, run_id)
    assert row["error_count"] == 2
    assert row["fail_count"] == 0
    assert row["pass_count"] == 0


# ---------------------------------------------------------------------------
# list_runs()
# ---------------------------------------------------------------------------


def test_list_runs_empty(conn):
    assert eval_metrics.list_runs(conn) == []


def test_list_runs_returns_list(conn):
    eval_metrics.create_run(conn, mode="deterministic")
    result = eval_metrics.list_runs(conn)
    assert isinstance(result, list)


def test_list_runs_returns_all_created(conn):
    for _ in range(3):
        eval_metrics.create_run(conn, mode="deterministic")
    result = eval_metrics.list_runs(conn)
    assert len(result) == 3


def test_list_runs_ordered_newest_first(conn):
    id1 = eval_metrics.create_run(conn, mode="deterministic")
    id2 = eval_metrics.create_run(conn, mode="deterministic")
    # Backdate id1 so ordering is deterministic
    conn.execute(
        "UPDATE eval_runs SET started_at = started_at - 10 WHERE run_id = ?",
        (id1,),
    )
    conn.commit()
    result = eval_metrics.list_runs(conn)
    assert result[0]["run_id"] == id2
    assert result[1]["run_id"] == id1


def test_list_runs_respects_limit(conn):
    for _ in range(5):
        eval_metrics.create_run(conn, mode="deterministic")
    result = eval_metrics.list_runs(conn, limit=3)
    assert len(result) == 3


def test_list_runs_default_limit_20(conn):
    for _ in range(25):
        eval_metrics.create_run(conn, mode="deterministic")
    result = eval_metrics.list_runs(conn)
    assert len(result) == 20


def test_list_runs_returns_dicts(conn):
    eval_metrics.create_run(conn, mode="live")
    result = eval_metrics.list_runs(conn)
    assert isinstance(result[0], dict)
    assert "run_id" in result[0]


# ---------------------------------------------------------------------------
# get_scores()
# ---------------------------------------------------------------------------


def test_get_scores_empty(conn, run_id):
    assert eval_metrics.get_scores(conn, run_id) == []


def test_get_scores_returns_list_of_dicts(conn, run_id):
    eval_metrics.record_score(conn, run_id, "s1", "gate", "deny")
    result = eval_metrics.get_scores(conn, run_id)
    assert isinstance(result, list)
    assert isinstance(result[0], dict)


def test_get_scores_scoped_to_run(conn):
    run_a = eval_metrics.create_run(conn, mode="deterministic")
    run_b = eval_metrics.create_run(conn, mode="deterministic")
    eval_metrics.record_score(conn, run_a, "s1", "gate", "deny")
    eval_metrics.record_score(conn, run_a, "s2", "gate", "deny")
    eval_metrics.record_score(conn, run_b, "s3", "gate", "deny")
    scores_a = eval_metrics.get_scores(conn, run_a)
    scores_b = eval_metrics.get_scores(conn, run_b)
    assert len(scores_a) == 2
    assert len(scores_b) == 1


def test_get_scores_has_scenario_id(conn, run_id):
    eval_metrics.record_score(conn, run_id, "write-who-deny", "gate", "deny")
    scores = eval_metrics.get_scores(conn, run_id)
    assert scores[0]["scenario_id"] == "write-who-deny"


def test_get_scores_missing_run_returns_empty(conn):
    result = eval_metrics.get_scores(conn, "nonexistent-run")
    assert result == []


# ---------------------------------------------------------------------------
# get_eval_conn() — creates .claude/ directory if missing
# ---------------------------------------------------------------------------


def test_get_eval_conn_creates_claude_dir(tmp_path):
    project_dir = tmp_path / "myproject"
    project_dir.mkdir()
    # .claude/ does NOT exist yet
    assert not (project_dir / ".claude").exists()
    conn = eval_metrics.get_eval_conn(project_dir)
    conn.close()
    assert (project_dir / ".claude").is_dir()


def test_get_eval_conn_creates_eval_results_db(tmp_path):
    project_dir = tmp_path / "myproject"
    project_dir.mkdir()
    conn = eval_metrics.get_eval_conn(project_dir)
    conn.close()
    assert (project_dir / ".claude" / "eval_results.db").exists()


def test_get_eval_conn_not_state_db(tmp_path):
    project_dir = tmp_path / "myproject"
    project_dir.mkdir()
    conn = eval_metrics.get_eval_conn(project_dir)
    db_path = Path(conn.execute("PRAGMA database_list").fetchone()[2])
    conn.close()
    assert db_path.name == "eval_results.db"
    assert db_path.name != "state.db"


def test_get_eval_conn_returns_connection(tmp_path):
    project_dir = tmp_path / "myproject"
    project_dir.mkdir()
    conn = eval_metrics.get_eval_conn(project_dir)
    assert isinstance(conn, sqlite3.Connection)
    conn.close()


def test_get_eval_conn_schema_applied(tmp_path):
    project_dir = tmp_path / "myproject"
    project_dir.mkdir()
    conn = eval_metrics.get_eval_conn(project_dir)
    # Schema must be applied — eval_runs table must exist
    tables = {
        row[0]
        for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
    }
    conn.close()
    assert "eval_runs" in tables
    assert "eval_scores" in tables
    assert "eval_outputs" in tables


def test_get_eval_conn_claude_dir_already_exists(tmp_path):
    project_dir = tmp_path / "myproject"
    project_dir.mkdir()
    (project_dir / ".claude").mkdir()
    # Must not raise even if .claude/ already exists
    conn = eval_metrics.get_eval_conn(project_dir)
    conn.close()


# ---------------------------------------------------------------------------
# Compound interaction: full eval run production sequence end-to-end
# ---------------------------------------------------------------------------


def test_full_eval_run_lifecycle(conn):
    """Exercise the real production sequence end-to-end.

    Production sequence:
      1. Orchestrator creates a new eval run
      2. For each scenario: record_output() captures raw agent output
      3. Scorer computes verdict, calls record_score()
      4. After all scenarios: finalize_run() computes aggregates

    This crosses create_run, record_output, record_score, finalize_run,
    get_run, get_scores, list_runs in the order production would invoke them.
    """
    # Step 1: create run
    run = eval_metrics.create_run(conn, mode="deterministic", metadata='{"wave": 1}')
    assert run  # non-empty UUID

    # Step 2+3: process 3 scenarios — 2 pass, 1 fail
    scenarios = [
        ("write-who-deny", "gate", "deny", "deny", 1),
        ("judgment-good-impl", "judgment", "needs_changes", "needs_changes", 1),
        ("adversarial-bypass", "adversarial", "pending", "idle", 0),
    ]
    for sid, cat, v_expected, v_actual, correct in scenarios:
        eval_metrics.record_output(
            conn,
            run,
            sid,
            raw_output=f"Agent output for {sid}",
            evidence_text=f"Evidence for {sid}",
        )
        eval_metrics.record_score(
            conn,
            run,
            sid,
            cat,
            v_expected,
            verdict_actual=v_actual,
            verdict_correct=correct,
            defect_recall=0.9 if correct else 0.0,
        )

    # Step 4: finalize
    eval_metrics.finalize_run(conn, run)

    # Verify aggregates
    row = eval_metrics.get_run(conn, run)
    assert row["pass_count"] == 2
    assert row["fail_count"] == 1
    assert row["error_count"] == 0
    assert row["scenario_count"] == 3
    assert row["finished_at"] is not None

    # Verify scores retrievable
    scores = eval_metrics.get_scores(conn, run)
    assert len(scores) == 3
    scenario_ids = {s["scenario_id"] for s in scores}
    assert scenario_ids == {"write-who-deny", "judgment-good-impl", "adversarial-bypass"}

    # Verify outputs in DB
    output_rows = conn.execute(
        "SELECT scenario_id, evidence_text FROM eval_outputs WHERE run_id=?",
        (run,),
    ).fetchall()
    assert len(output_rows) == 3

    # Verify run appears in list
    runs = eval_metrics.list_runs(conn)
    assert any(r["run_id"] == run for r in runs)

    # Verify no contamination into eval_runs from a different run
    other_run = eval_metrics.create_run(conn, mode="live")
    other_scores = eval_metrics.get_scores(conn, other_run)
    assert other_scores == []
