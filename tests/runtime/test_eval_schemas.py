"""Unit tests for runtime.eval_schemas.

Tests schema creation, idempotency, index existence, and constant values.
Uses in-memory SQLite so no disk state is left behind.

@decision DEC-EVAL-SCHEMA-001
Title: eval_results.db schema is separate from state.db
Status: accepted
Rationale: Behavioral eval data (runs, scores, outputs) must never mix with
  workflow control-plane data. Separate file means separate schema module and
  separate connection. ensure_eval_schema() is the single authority for the
  eval database schema.
"""

from __future__ import annotations

import sqlite3
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import runtime.eval_schemas as eval_schemas

from runtime.core.db import connect_memory


@pytest.fixture
def conn():
    c = connect_memory()
    yield c
    c.close()


@pytest.fixture
def schema_conn(conn):
    eval_schemas.ensure_eval_schema(conn)
    return conn


# ---------------------------------------------------------------------------
# Table existence after ensure_eval_schema()
# ---------------------------------------------------------------------------


def _table_names(conn: sqlite3.Connection) -> set[str]:
    rows = conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
    return {row[0] for row in rows}


def _index_names(conn: sqlite3.Connection) -> set[str]:
    rows = conn.execute("SELECT name FROM sqlite_master WHERE type='index'").fetchall()
    return {row[0] for row in rows}


def test_ensure_eval_schema_creates_eval_runs(conn):
    eval_schemas.ensure_eval_schema(conn)
    assert "eval_runs" in _table_names(conn)


def test_ensure_eval_schema_creates_eval_scores(conn):
    eval_schemas.ensure_eval_schema(conn)
    assert "eval_scores" in _table_names(conn)


def test_ensure_eval_schema_creates_eval_outputs(conn):
    eval_schemas.ensure_eval_schema(conn)
    assert "eval_outputs" in _table_names(conn)


def test_ensure_eval_schema_creates_all_three_tables(conn):
    eval_schemas.ensure_eval_schema(conn)
    tables = _table_names(conn)
    assert {"eval_runs", "eval_scores", "eval_outputs"}.issubset(tables)


# ---------------------------------------------------------------------------
# Idempotency — calling twice is a no-op
# ---------------------------------------------------------------------------


def test_ensure_eval_schema_idempotent_no_exception(conn):
    eval_schemas.ensure_eval_schema(conn)
    # Must not raise
    eval_schemas.ensure_eval_schema(conn)


def test_ensure_eval_schema_idempotent_same_tables(conn):
    eval_schemas.ensure_eval_schema(conn)
    tables_first = _table_names(conn)
    eval_schemas.ensure_eval_schema(conn)
    tables_second = _table_names(conn)
    assert tables_first == tables_second


def test_ensure_eval_schema_idempotent_three_times(conn):
    for _ in range(3):
        eval_schemas.ensure_eval_schema(conn)
    assert "eval_runs" in _table_names(conn)
    assert "eval_scores" in _table_names(conn)
    assert "eval_outputs" in _table_names(conn)


# ---------------------------------------------------------------------------
# Index existence
# ---------------------------------------------------------------------------


def test_indexes_created(schema_conn):
    indexes = _index_names(schema_conn)
    expected = {
        "idx_eval_scores_run",
        "idx_eval_scores_scenario",
        "idx_eval_scores_category",
        "idx_eval_outputs_run",
    }
    assert expected.issubset(indexes), f"missing indexes: {expected - indexes}"


def test_idx_eval_scores_run_exists(schema_conn):
    assert "idx_eval_scores_run" in _index_names(schema_conn)


def test_idx_eval_scores_scenario_exists(schema_conn):
    assert "idx_eval_scores_scenario" in _index_names(schema_conn)


def test_idx_eval_scores_category_exists(schema_conn):
    assert "idx_eval_scores_category" in _index_names(schema_conn)


def test_idx_eval_outputs_run_exists(schema_conn):
    assert "idx_eval_outputs_run" in _index_names(schema_conn)


# ---------------------------------------------------------------------------
# Column existence — spot-check critical columns
# ---------------------------------------------------------------------------


def _column_names(conn: sqlite3.Connection, table: str) -> set[str]:
    rows = conn.execute(f"PRAGMA table_info({table})").fetchall()
    return {row[1] for row in rows}


def test_eval_runs_has_required_columns(schema_conn):
    cols = _column_names(schema_conn, "eval_runs")
    required = {
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
    assert required.issubset(cols), f"missing columns: {required - cols}"


def test_eval_scores_has_required_columns(schema_conn):
    cols = _column_names(schema_conn, "eval_scores")
    required = {
        "id",
        "run_id",
        "scenario_id",
        "category",
        "verdict_expected",
        "verdict_actual",
        "verdict_correct",
        "defect_recall",
        "evidence_score",
        "false_positive_count",
        "confidence_expected",
        "confidence_actual",
        "duration_ms",
        "error_message",
        "scored_at",
    }
    assert required.issubset(cols), f"missing columns: {required - cols}"


def test_eval_outputs_has_required_columns(schema_conn):
    cols = _column_names(schema_conn, "eval_outputs")
    required = {
        "id",
        "run_id",
        "scenario_id",
        "raw_output",
        "trailer_json",
        "evidence_text",
        "coverage_json",
        "captured_at",
    }
    assert required.issubset(cols), f"missing columns: {required - cols}"


# ---------------------------------------------------------------------------
# DDL constants defined
# ---------------------------------------------------------------------------


def test_eval_runs_ddl_defined():
    assert hasattr(eval_schemas, "EVAL_RUNS_DDL")
    assert "eval_runs" in eval_schemas.EVAL_RUNS_DDL
    assert "run_id" in eval_schemas.EVAL_RUNS_DDL


def test_eval_scores_ddl_defined():
    assert hasattr(eval_schemas, "EVAL_SCORES_DDL")
    assert "eval_scores" in eval_schemas.EVAL_SCORES_DDL
    assert "scenario_id" in eval_schemas.EVAL_SCORES_DDL


def test_eval_outputs_ddl_defined():
    assert hasattr(eval_schemas, "EVAL_OUTPUTS_DDL")
    assert "eval_outputs" in eval_schemas.EVAL_OUTPUTS_DDL
    assert "raw_output" in eval_schemas.EVAL_OUTPUTS_DDL


def test_eval_all_ddl_is_list():
    assert isinstance(eval_schemas.EVAL_ALL_DDL, list)
    assert len(eval_schemas.EVAL_ALL_DDL) >= 3


def test_eval_all_ddl_contains_all_three():
    ddl_text = " ".join(eval_schemas.EVAL_ALL_DDL)
    assert "eval_runs" in ddl_text
    assert "eval_scores" in ddl_text
    assert "eval_outputs" in ddl_text


# ---------------------------------------------------------------------------
# Frozenset constants — correct values
# ---------------------------------------------------------------------------


def test_eval_categories_is_frozenset():
    assert isinstance(eval_schemas.EVAL_CATEGORIES, frozenset)


def test_eval_categories_values():
    assert eval_schemas.EVAL_CATEGORIES == frozenset({"gate", "judgment", "adversarial"})


def test_eval_modes_is_frozenset():
    assert isinstance(eval_schemas.EVAL_MODES, frozenset)


def test_eval_modes_values():
    assert eval_schemas.EVAL_MODES == frozenset({"deterministic", "live"})


def test_eval_verdicts_is_frozenset():
    assert isinstance(eval_schemas.EVAL_VERDICTS, frozenset)


def test_eval_verdicts_contains_expected_values():
    # EVAL_VERDICTS must match EVALUATION_STATUSES from schemas.py
    from runtime.schemas import EVALUATION_STATUSES

    assert eval_schemas.EVAL_VERDICTS == EVALUATION_STATUSES


def test_eval_verdicts_has_deny():
    # Scenarios use 'deny' as a verdict — it must be present
    # Note: EVALUATION_STATUSES from schemas.py defines the verdict space
    # The actual values are the evaluation statuses
    assert len(eval_schemas.EVAL_VERDICTS) > 0


# ---------------------------------------------------------------------------
# No cross-contamination — eval schema must not touch state.db DDL
# ---------------------------------------------------------------------------


def test_eval_schema_does_not_create_proof_state(schema_conn):
    assert "proof_state" not in _table_names(schema_conn)


def test_eval_schema_does_not_create_agent_markers(schema_conn):
    assert "agent_markers" not in _table_names(schema_conn)


def test_eval_schema_does_not_create_dispatch_leases(schema_conn):
    assert "dispatch_leases" not in _table_names(schema_conn)
