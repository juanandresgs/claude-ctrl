"""Tests for runtime.core.eval_report — report generation module.

Tests are pure-unit: no subprocess calls, no filesystem. eval_conn is an
in-memory SQLite connection bootstrapped with eval schema. All helpers are
called directly with constructed data (no mocks needed — the module is
stateless/pure aside from DB reads via eval_metrics).

@decision DEC-EVAL-REPORT-001
Title: eval_report tests use in-memory SQLite seeded with real records
Status: accepted
Rationale: eval_report.generate_report() calls eval_metrics functions
  (get_run, get_scores, get_category_breakdown, get_regression_check).
  Using in-memory SQLite seeded with real records exercises the actual
  data flow without subprocess overhead. This mirrors the pattern in
  test_eval_runner.py and test_eval_metrics.py.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

# Ensure the project root is importable regardless of test runner CWD
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import runtime.core.eval_report as eval_report

import runtime.core.eval_metrics as eval_metrics
from runtime.core.db import connect_memory
from runtime.eval_schemas import ensure_eval_schema

# ---------------------------------------------------------------------------
# Shared fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def eval_conn():
    """In-memory eval_results.db connection, schema applied."""
    c = connect_memory()
    ensure_eval_schema(c)
    yield c
    c.close()


@pytest.fixture
def seeded_run(eval_conn):
    """A completed run with mixed pass/fail scores across three categories."""
    run_id = eval_metrics.create_run(eval_conn, mode="deterministic")

    # gate: 2 pass, 1 fail
    eval_metrics.record_score(
        eval_conn,
        run_id=run_id,
        scenario_id="write-who-deny",
        category="gate",
        verdict_expected="deny",
        verdict_actual="deny",
        verdict_correct=1,
        defect_recall=1.0,
        duration_ms=50,
    )
    eval_metrics.record_score(
        eval_conn,
        run_id=run_id,
        scenario_id="impl-source-allow",
        category="gate",
        verdict_expected="allow",
        verdict_actual="allow",
        verdict_correct=1,
        defect_recall=0.9,
        duration_ms=45,
    )
    eval_metrics.record_score(
        eval_conn,
        run_id=run_id,
        scenario_id="guardian-no-lease-deny",
        category="gate",
        verdict_expected="deny",
        verdict_actual="allow",
        verdict_correct=0,
        defect_recall=0.2,
        duration_ms=60,
    )

    # judgment: 1 pass, 1 error
    eval_metrics.record_score(
        eval_conn,
        run_id=run_id,
        scenario_id="tester-ready-verdict",
        category="judgment",
        verdict_expected="ready_for_guardian",
        verdict_actual="ready_for_guardian",
        verdict_correct=1,
        defect_recall=0.8,
        duration_ms=120,
    )
    eval_metrics.record_score(
        eval_conn,
        run_id=run_id,
        scenario_id="tester-evidence-missing",
        category="judgment",
        verdict_expected="needs_changes",
        verdict_actual=None,
        verdict_correct=0,
        error_message="timeout",
        duration_ms=5000,
    )

    # adversarial: 1 pass
    eval_metrics.record_score(
        eval_conn,
        run_id=run_id,
        scenario_id="adversarial-boundary-probe",
        category="adversarial",
        verdict_expected="deny",
        verdict_actual="deny",
        verdict_correct=1,
        defect_recall=0.75,
        duration_ms=80,
    )

    eval_metrics.finalize_run(eval_conn, run_id)
    return run_id


# ---------------------------------------------------------------------------
# format_run_summary()
# ---------------------------------------------------------------------------


def test_format_run_summary(eval_conn, seeded_run):
    """format_run_summary() includes run_id, mode, scenario counts, accuracy."""
    run = eval_metrics.get_run(eval_conn, seeded_run)
    scores = eval_metrics.get_scores(eval_conn, seeded_run)
    result = eval_report.format_run_summary(run, scores)

    assert seeded_run in result
    assert "deterministic" in result.lower()
    assert "Scenarios:" in result
    assert "Pass:" in result
    assert "Fail:" in result
    assert "Error:" in result
    assert "Accuracy" in result or "%" in result


def test_format_run_summary_zero_scenarios(eval_conn):
    """format_run_summary() handles a run with zero scenarios gracefully."""
    run_id = eval_metrics.create_run(eval_conn, mode="deterministic")
    eval_metrics.finalize_run(eval_conn, run_id)
    run = eval_metrics.get_run(eval_conn, run_id)
    result = eval_report.format_run_summary(run, [])

    assert run_id in result
    # Zero-scenario run should show 0 for all counts — no division-by-zero crash
    assert "0" in result


# ---------------------------------------------------------------------------
# format_category_breakdown()
# ---------------------------------------------------------------------------


def test_format_category_breakdown(eval_conn, seeded_run):
    """format_category_breakdown() produces a table with gate/judgment/adversarial rows."""
    breakdown = eval_metrics.get_category_breakdown(eval_conn, seeded_run)
    result = eval_report.format_category_breakdown(breakdown)

    # Table header
    assert "Category" in result
    assert "Pass" in result
    assert "Fail" in result
    assert "Error" in result

    # All three categories present
    assert "gate" in result
    assert "judgment" in result
    assert "adversarial" in result


def test_format_category_breakdown_empty():
    """format_category_breakdown() handles empty breakdown dict gracefully."""
    result = eval_report.format_category_breakdown({})
    # Should not raise; may return empty string or header-only table
    assert isinstance(result, str)


# ---------------------------------------------------------------------------
# format_scenario_detail()
# ---------------------------------------------------------------------------


def test_format_scenario_detail_pass(eval_conn, seeded_run):
    """format_scenario_detail() shows PASS for a passing score."""
    scores = eval_metrics.get_scores(eval_conn, seeded_run)
    passing = next(s for s in scores if s["verdict_correct"] == 1 and s["error_message"] is None)
    result = eval_report.format_scenario_detail(passing)

    assert "PASS" in result
    assert passing["scenario_id"] in result
    assert passing["category"] in result


def test_format_scenario_detail_fail(eval_conn, seeded_run):
    """format_scenario_detail() shows FAIL for a non-passing score."""
    scores = eval_metrics.get_scores(eval_conn, seeded_run)
    failing = next(s for s in scores if s["verdict_correct"] == 0 and s["error_message"] is None)
    result = eval_report.format_scenario_detail(failing)

    assert "FAIL" in result
    assert failing["scenario_id"] in result


# ---------------------------------------------------------------------------
# format_regression_alerts()
# ---------------------------------------------------------------------------


def test_format_regression_alerts_with_regressions():
    """format_regression_alerts() shows alert text when regressions exist."""
    regressions = [
        {
            "scenario_id": "dual-authority-detection",
            "latest_score": 0.50,
            "window_avg": 0.88,
            "regression": True,
            "delta": -0.38,
        }
    ]
    result = eval_report.format_regression_alerts(regressions)

    assert "dual-authority-detection" in result
    assert "0.50" in result or "0.5" in result
    assert "0.88" in result


def test_format_regression_alerts_empty():
    """format_regression_alerts() returns empty string when no regressions."""
    result = eval_report.format_regression_alerts([])
    assert result == ""


# ---------------------------------------------------------------------------
# generate_report()
# ---------------------------------------------------------------------------


def test_generate_report_with_run(eval_conn, seeded_run):
    """generate_report() returns a multi-section text report for a specific run_id."""
    result = eval_report.generate_report(eval_conn, run_id=seeded_run)

    # Must contain all main sections
    assert seeded_run in result
    assert "gate" in result
    assert "judgment" in result
    assert "adversarial" in result
    # scenario IDs appear in the report
    assert "write-who-deny" in result
    # overall structure non-empty
    assert len(result) > 100


def test_generate_report_most_recent(eval_conn, seeded_run):
    """generate_report() with no run_id defaults to most recent run."""
    result = eval_report.generate_report(eval_conn)
    # The seeded run is the most recent; its run_id should appear
    assert seeded_run in result


def test_generate_report_no_runs(eval_conn):
    """generate_report() returns an informative message when no runs exist."""
    result = eval_report.generate_report(eval_conn)
    assert isinstance(result, str)
    # Should not raise; should explain no data
    assert len(result) > 0


# ---------------------------------------------------------------------------
# generate_json_report()
# ---------------------------------------------------------------------------


def test_generate_json_report(eval_conn, seeded_run):
    """generate_json_report() returns a dict with expected top-level keys."""
    result = eval_report.generate_json_report(eval_conn, run_id=seeded_run)

    assert isinstance(result, dict)
    # Required keys per spec
    assert "run_id" in result
    assert "mode" in result
    assert "scenario_count" in result
    assert "pass_count" in result
    assert "fail_count" in result
    assert "error_count" in result
    assert "category_breakdown" in result
    assert "scores" in result

    # run_id matches
    assert result["run_id"] == seeded_run
    # category_breakdown is a dict keyed by category
    assert isinstance(result["category_breakdown"], dict)
    assert "gate" in result["category_breakdown"]
    # scores is a list
    assert isinstance(result["scores"], list)
    assert len(result["scores"]) == 6  # 6 scores seeded
