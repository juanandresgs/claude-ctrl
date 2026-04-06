"""Behavioral Evaluation Framework — CRUD authority for eval_results.db.

All mutations are in explicit transactions. conn is always the first argument,
following the same pattern as runtime/core/evaluation.py and peers.

@decision DEC-EVAL-METRICS-001
Title: eval_metrics is the sole CRUD authority for eval_results.db
Status: accepted
Rationale: Mirrors the module-per-domain pattern used throughout runtime/core/.
  Each domain module owns exactly one state domain; this one owns eval_runs,
  eval_scores, and eval_outputs. Connections come from the caller (get_eval_conn
  for production, connect_memory() for tests) — the module never opens its own
  connection implicitly. This keeps the connection lifecycle visible and
  testable without monkeypatching.

@decision DEC-EVAL-METRICS-002
Title: get_eval_conn() opens eval_results.db, never state.db
Status: accepted
Rationale: The eval database is a separate file from state.db (DEC-EVAL-SCHEMA-001).
  get_eval_conn() encapsulates the path derivation (.claude/eval_results.db relative
  to project_dir) and schema bootstrap so callers don't need to know either detail.
  It creates .claude/ if missing, matching the pattern in runtime/core/db.py connect().
"""

from __future__ import annotations

import sqlite3
import time
import uuid
from pathlib import Path

from runtime.core.db import connect
from runtime.eval_schemas import ensure_eval_schema

# ---------------------------------------------------------------------------
# Connection factory
# ---------------------------------------------------------------------------


def get_eval_conn(project_dir: Path) -> sqlite3.Connection:
    """Open a connection to eval_results.db inside project_dir/.claude/.

    Creates the .claude/ directory if it does not exist. Applies
    ensure_eval_schema() so the caller gets a fully bootstrapped connection.

    This function must NOT be used with state.db — it always opens
    eval_results.db.
    """
    claude_dir = project_dir / ".claude"
    claude_dir.mkdir(parents=True, exist_ok=True)
    db_path = claude_dir / "eval_results.db"
    conn = connect(db_path)
    ensure_eval_schema(conn)
    return conn


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _row_to_dict(row: sqlite3.Row) -> dict:
    return dict(row)


# ---------------------------------------------------------------------------
# eval_runs CRUD
# ---------------------------------------------------------------------------


def create_run(
    conn: sqlite3.Connection,
    mode: str,
    metadata: str | None = None,
) -> str:
    """Insert a new eval_runs row and return its UUID run_id.

    Args:
        conn:     Connection to eval_results.db.
        mode:     'deterministic' or 'live' (validated by caller against EVAL_MODES).
        metadata: Optional JSON string for freeform run-level metadata.

    Returns:
        UUID string (run_id) for the newly created run.
    """
    run_id = str(uuid.uuid4())
    now = int(time.time())
    with conn:
        conn.execute(
            """
            INSERT INTO eval_runs
                (run_id, started_at, finished_at, mode,
                 scenario_count, pass_count, fail_count, error_count, metadata_json)
            VALUES (?, ?, NULL, ?, 0, 0, 0, 0, ?)
            """,
            (run_id, now, mode, metadata),
        )
    return run_id


def get_run(conn: sqlite3.Connection, run_id: str) -> dict | None:
    """Return the eval_runs row for run_id as a dict, or None if not found."""
    row = conn.execute(
        """
        SELECT run_id, started_at, finished_at, mode,
               scenario_count, pass_count, fail_count, error_count, metadata_json
        FROM   eval_runs
        WHERE  run_id = ?
        """,
        (run_id,),
    ).fetchone()
    return _row_to_dict(row) if row else None


def finalize_run(conn: sqlite3.Connection, run_id: str) -> None:
    """Compute pass/fail/error/scenario counts from eval_scores and set finished_at.

    Count definitions:
      - pass_count:    rows where verdict_correct = 1 AND error_message IS NULL
      - error_count:   rows where error_message IS NOT NULL
      - fail_count:    rows where verdict_correct = 0 AND error_message IS NULL
      - scenario_count: total rows for this run

    finished_at is set to current epoch seconds.
    """
    now = int(time.time())
    with conn:
        conn.execute(
            """
            UPDATE eval_runs
            SET
                scenario_count = (
                    SELECT COUNT(*)
                    FROM   eval_scores
                    WHERE  run_id = ?
                ),
                pass_count = (
                    SELECT COUNT(*)
                    FROM   eval_scores
                    WHERE  run_id = ?
                      AND  verdict_correct = 1
                      AND  error_message IS NULL
                ),
                error_count = (
                    SELECT COUNT(*)
                    FROM   eval_scores
                    WHERE  run_id = ?
                      AND  error_message IS NOT NULL
                ),
                fail_count = (
                    SELECT COUNT(*)
                    FROM   eval_scores
                    WHERE  run_id = ?
                      AND  verdict_correct = 0
                      AND  error_message IS NULL
                ),
                finished_at = ?
            WHERE run_id = ?
            """,
            (run_id, run_id, run_id, run_id, now, run_id),
        )


def list_runs(conn: sqlite3.Connection, limit: int = 20) -> list[dict]:
    """Return the most recent eval_runs rows, newest first.

    Args:
        conn:  Connection to eval_results.db.
        limit: Maximum number of rows to return (default 20).

    Returns:
        List of dicts ordered by started_at DESC.
    """
    rows = conn.execute(
        """
        SELECT run_id, started_at, finished_at, mode,
               scenario_count, pass_count, fail_count, error_count, metadata_json
        FROM   eval_runs
        ORDER  BY started_at DESC
        LIMIT  ?
        """,
        (limit,),
    ).fetchall()
    return [_row_to_dict(r) for r in rows]


# ---------------------------------------------------------------------------
# eval_scores CRUD
# ---------------------------------------------------------------------------


def record_score(
    conn: sqlite3.Connection,
    run_id: str,
    scenario_id: str,
    category: str,
    verdict_expected: str,
    verdict_actual: str | None = None,
    verdict_correct: int = 0,
    defect_recall: float | None = None,
    evidence_score: float | None = None,
    false_positive_count: int = 0,
    confidence_expected: str | None = None,
    confidence_actual: str | None = None,
    duration_ms: int | None = None,
    error_message: str | None = None,
) -> None:
    """Insert a scored result for a single scenario into eval_scores.

    Args:
        conn:                Connection to eval_results.db.
        run_id:              UUID of the parent eval_runs row.
        scenario_id:         Scenario name (e.g. 'write-who-deny').
        category:            One of EVAL_CATEGORIES: 'gate', 'judgment', 'adversarial'.
        verdict_expected:    The ground-truth expected verdict.
        verdict_actual:      The verdict the agent actually produced (None if errored).
        verdict_correct:     1 if verdict matched expected, 0 otherwise.
        defect_recall:       Fraction of expected defects the agent identified (0–1).
        evidence_score:      Quality score for cited evidence (0–1).
        false_positive_count: Number of spurious defects the agent hallucinated.
        confidence_expected: Expected confidence label (e.g. 'High').
        confidence_actual:   Confidence label the agent reported.
        duration_ms:         How long the scenario took to evaluate.
        error_message:       Non-None if the scenario failed to evaluate (crash/timeout).
    """
    now = int(time.time())
    with conn:
        conn.execute(
            """
            INSERT INTO eval_scores
                (run_id, scenario_id, category, verdict_expected, verdict_actual,
                 verdict_correct, defect_recall, evidence_score, false_positive_count,
                 confidence_expected, confidence_actual, duration_ms, error_message,
                 scored_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                run_id,
                scenario_id,
                category,
                verdict_expected,
                verdict_actual,
                verdict_correct,
                defect_recall,
                evidence_score,
                false_positive_count,
                confidence_expected,
                confidence_actual,
                duration_ms,
                error_message,
                now,
            ),
        )


def get_scores(conn: sqlite3.Connection, run_id: str) -> list[dict]:
    """Return all eval_scores rows for run_id as a list of dicts.

    Returns an empty list if the run has no scores or does not exist.
    """
    rows = conn.execute(
        """
        SELECT id, run_id, scenario_id, category, verdict_expected, verdict_actual,
               verdict_correct, defect_recall, evidence_score, false_positive_count,
               confidence_expected, confidence_actual, duration_ms, error_message,
               scored_at
        FROM   eval_scores
        WHERE  run_id = ?
        ORDER  BY id ASC
        """,
        (run_id,),
    ).fetchall()
    return [_row_to_dict(r) for r in rows]


# ---------------------------------------------------------------------------
# eval_outputs CRUD
# ---------------------------------------------------------------------------


def record_output(
    conn: sqlite3.Connection,
    run_id: str,
    scenario_id: str,
    raw_output: str,
    trailer_json: str | None = None,
    evidence_text: str | None = None,
    coverage_json: str | None = None,
) -> None:
    """Insert raw agent output for a scenario into eval_outputs.

    Args:
        conn:          Connection to eval_results.db.
        run_id:        UUID of the parent eval_runs row.
        scenario_id:   Scenario name.
        raw_output:    Full raw text output from the agent being evaluated.
        trailer_json:  JSON-encoded trailers extracted from the output (optional).
        evidence_text: Evidence section extracted from the output (optional).
        coverage_json: JSON-encoded coverage/contract coverage mapping (optional).
    """
    now = int(time.time())
    with conn:
        conn.execute(
            """
            INSERT INTO eval_outputs
                (run_id, scenario_id, raw_output, trailer_json,
                 evidence_text, coverage_json, captured_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (run_id, scenario_id, raw_output, trailer_json, evidence_text, coverage_json, now),
        )


# ---------------------------------------------------------------------------
# Aggregation and regression functions
# ---------------------------------------------------------------------------


def get_category_breakdown(conn: sqlite3.Connection, run_id: str) -> dict:
    """Return per-category pass/fail/error counts and average defect_recall scores.

    Counts follow the same definitions as finalize_run():
      pass  = verdict_correct=1 AND error_message IS NULL
      error = error_message IS NOT NULL
      fail  = verdict_correct=0 AND error_message IS NULL

    avg_score is the average of defect_recall for non-NULL rows in that
    category. If all rows have NULL defect_recall the average is 0.0.

    Args:
        conn:   Connection to eval_results.db.
        run_id: UUID of the eval run to break down.

    Returns:
        Dict keyed by category string. Each value is a dict with keys:
        pass, fail, error (int), avg_score (float).
        Empty dict if the run has no scores.
    """
    rows = conn.execute(
        """
        SELECT
            category,
            SUM(CASE WHEN verdict_correct = 1 AND error_message IS NULL THEN 1 ELSE 0 END) AS pass_count,
            SUM(CASE WHEN verdict_correct = 0 AND error_message IS NULL THEN 1 ELSE 0 END) AS fail_count,
            SUM(CASE WHEN error_message IS NOT NULL THEN 1 ELSE 0 END)                     AS error_count,
            AVG(CASE WHEN defect_recall IS NOT NULL THEN defect_recall ELSE NULL END)       AS avg_recall
        FROM   eval_scores
        WHERE  run_id = ?
        GROUP  BY category
        """,
        (run_id,),
    ).fetchall()

    result: dict = {}
    for row in rows:
        result[row[0]] = {
            "pass": row[1],
            "fail": row[2],
            "error": row[3],
            "avg_score": float(row[4]) if row[4] is not None else 0.0,
        }
    return result


def get_regression_check(conn: sqlite3.Connection, scenario_id: str, window: int = 5) -> dict:
    """Compare the latest defect_recall score for a scenario against a rolling window.

    Fetches the most recent `window` rows for scenario_id ordered by
    scored_at DESC. The latest score is compared against the average of all
    fetched rows (including itself). Regression is True if:

        latest_score < window_avg * 0.8  (i.e. drops strictly more than 20%)

    When no data exists, returns safe defaults with regression=False.

    Args:
        conn:        Connection to eval_results.db.
        scenario_id: Scenario name to check.
        window:      Number of recent runs to include in the average (default 5).

    Returns:
        Dict with keys: scenario_id, latest_score, window_avg, regression, delta.
    """
    rows = conn.execute(
        """
        SELECT defect_recall
        FROM   eval_scores
        WHERE  scenario_id = ?
          AND  defect_recall IS NOT NULL
        ORDER  BY scored_at DESC, id DESC
        LIMIT  ?
        """,
        (scenario_id, window),
    ).fetchall()

    if not rows:
        return {
            "scenario_id": scenario_id,
            "latest_score": 0.0,
            "window_avg": 0.0,
            "regression": False,
            "delta": 0.0,
        }

    scores = [r[0] for r in rows]
    latest_score = scores[0]
    window_avg = sum(scores) / len(scores)
    delta = latest_score - window_avg
    # Regression: latest drops strictly more than 20% below window average
    regression = bool(window_avg > 0.0 and latest_score < window_avg * 0.8)

    return {
        "scenario_id": scenario_id,
        "latest_score": latest_score,
        "window_avg": window_avg,
        "regression": regression,
        "delta": delta,
    }


def get_variance(conn: sqlite3.Connection, scenario_id: str, window: int = 5) -> dict:
    """Compute score variance across recent runs for a scenario.

    Fetches the most recent `window` defect_recall values for the scenario.
    Uses population variance (divides by N). Returns zeros when no data.

    Args:
        conn:        Connection to eval_results.db.
        scenario_id: Scenario name to measure.
        window:      Number of recent runs to include (default 5).

    Returns:
        Dict with keys: scenario_id, window, mean, variance, std_dev, run_count.
    """
    rows = conn.execute(
        """
        SELECT defect_recall
        FROM   eval_scores
        WHERE  scenario_id = ?
          AND  defect_recall IS NOT NULL
        ORDER  BY scored_at DESC, id DESC
        LIMIT  ?
        """,
        (scenario_id, window),
    ).fetchall()

    safe_default = {
        "scenario_id": scenario_id,
        "window": window,
        "mean": 0.0,
        "variance": 0.0,
        "std_dev": 0.0,
        "run_count": 0,
    }

    if not rows:
        return safe_default

    scores = [r[0] for r in rows]
    n = len(scores)
    mean = sum(scores) / n
    variance = sum((s - mean) ** 2 for s in scores) / n
    std_dev = variance**0.5

    return {
        "scenario_id": scenario_id,
        "window": window,
        "mean": mean,
        "variance": variance,
        "std_dev": std_dev,
        "run_count": n,
    }
