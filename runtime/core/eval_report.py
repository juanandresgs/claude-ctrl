"""Behavioral Evaluation Framework — report generation.

All public functions are pure transformations: they take data (dicts, lists,
or a db connection for generate_report/generate_json_report) and return strings
or dicts. No writes to any database occur here.

@decision DEC-EVAL-REPORT-001
Title: eval_report is read-only; all formatting functions are pure
Status: accepted
Rationale: Report generation must never mutate eval_results.db or state.db.
  Keeping every format_* function as a pure string transformation (takes data,
  returns str) makes them trivially testable without database setup. Only
  generate_report() and generate_json_report() accept a db connection, and
  they use it read-only (calling eval_metrics getters, not writers). This
  mirrors DEC-EVAL-SCORER-001 (scorer is stateless).

@decision DEC-EVAL-REPORT-002
Title: generate_report() resolves run_id from list_runs() when not provided
Status: accepted
Rationale: Callers often want "the most recent run" without knowing the run_id.
  Rather than having the CLI resolve this and pass it in, generate_report()
  accepts run_id=None and falls back to list_runs(limit=1)[0]. This keeps the
  CLI handler thin (no repeated lookup logic) and the report module self-
  contained. If no runs exist the function returns a descriptive "no runs"
  message rather than raising.
"""

from __future__ import annotations

import sqlite3
from typing import Optional

import runtime.core.eval_metrics as eval_metrics

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_COL_W_CAT = 14  # Category column width
_COL_W_PASS = 6
_COL_W_FAIL = 6
_COL_W_ERR = 7
_COL_W_SCORE = 10


# ---------------------------------------------------------------------------
# format_run_summary()
# ---------------------------------------------------------------------------


def format_run_summary(run: dict, scores: list[dict]) -> str:
    """Format a single run as human-readable text.

    Args:
        run:    A dict from eval_metrics.get_run() — the eval_runs row.
        scores: A list of dicts from eval_metrics.get_scores() for this run.

    Returns:
        Multi-line string with run identity, mode, timestamps, counts, accuracy.

    Example output::

        Eval Run: <run_id>
        Mode: deterministic | Started: 1712345678 | Finished: 1712345712
        Scenarios: 6 | Pass: 3 | Fail: 2 | Error: 1
        Overall Accuracy: 50.0%
    """
    run_id = run.get("run_id", "unknown")
    mode = run.get("mode", "unknown")
    started_at = run.get("started_at", "")
    finished_at = run.get("finished_at", "")

    # Use finalized counts from the run record (set by finalize_run)
    total = run.get("scenario_count", len(scores))
    pass_count = run.get("pass_count", 0)
    fail_count = run.get("fail_count", 0)
    error_count = run.get("error_count", 0)

    if total > 0:
        accuracy = pass_count / total * 100
    else:
        accuracy = 0.0

    lines = [
        f"Eval Run: {run_id}",
        f"Mode: {mode} | Started: {started_at} | Finished: {finished_at}",
        f"Scenarios: {total} | Pass: {pass_count} | Fail: {fail_count} | Error: {error_count}",
        f"Overall Accuracy: {accuracy:.1f}%",
    ]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# format_category_breakdown()
# ---------------------------------------------------------------------------


def format_category_breakdown(breakdown: dict) -> str:
    """Format per-category results as a fixed-width table.

    Args:
        breakdown: Dict from eval_metrics.get_category_breakdown() keyed by
                   category string. Each value is a dict with pass, fail,
                   error (int), avg_score (float).

    Returns:
        Multi-line string formatted as a table. Returns an empty string if
        breakdown is empty.

    Example output::

        Category       | Pass | Fail  | Error  | Avg Score
        ---------------|------|-------|--------|----------
        gate           |    3 |    1  |     0  |      0.85
        judgment       |    2 |    2  |     1  |      0.62
        adversarial    |    1 |    3  |     1  |      0.45
    """
    if not breakdown:
        return ""

    header = (
        f"{'Category':{_COL_W_CAT}} | "
        f"{'Pass':>{_COL_W_PASS}} | "
        f"{'Fail':>{_COL_W_FAIL}} | "
        f"{'Error':>{_COL_W_ERR}} | "
        f"{'Avg Score':>{_COL_W_SCORE}}"
    )
    sep = (
        f"{'-' * _COL_W_CAT}-|-"
        f"{'-' * _COL_W_PASS}-|-"
        f"{'-' * _COL_W_FAIL}-|-"
        f"{'-' * _COL_W_ERR}-|-"
        f"{'-' * _COL_W_SCORE}"
    )

    lines = [header, sep]
    for cat in sorted(breakdown.keys()):
        stats = breakdown[cat]
        p = stats.get("pass", 0)
        f = stats.get("fail", 0)
        e = stats.get("error", 0)
        s = stats.get("avg_score", 0.0)
        row = (
            f"{cat:{_COL_W_CAT}} | "
            f"{p:>{_COL_W_PASS}} | "
            f"{f:>{_COL_W_FAIL}} | "
            f"{e:>{_COL_W_ERR}} | "
            f"{s:>{_COL_W_SCORE}.2f}"
        )
        lines.append(row)

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# format_scenario_detail()
# ---------------------------------------------------------------------------


def format_scenario_detail(score: dict) -> str:
    """Format a single scenario score with key fields.

    Args:
        score: A dict from eval_metrics.get_scores() — one eval_scores row.

    Returns:
        Single-line string (with optional sub-line for details).

    Example output (PASS)::

      write-who-deny [gate] — PASS
        Expected: deny | Actual: deny | Evidence: 1.00 | Defect Recall: N/A

    Example output (FAIL)::

      guardian-no-lease-deny [gate] — FAIL
        Expected: deny | Actual: allow | Evidence: N/A | Defect Recall: N/A
    """
    scenario_id = score.get("scenario_id", "unknown")
    category = score.get("category", "?")
    verdict_expected = score.get("verdict_expected", "?")
    verdict_actual = score.get("verdict_actual") or "N/A"
    defect_recall = score.get("defect_recall")
    evidence_score = score.get("evidence_score")
    error_message = score.get("error_message")

    # Determine outcome label
    if error_message:
        outcome = "ERROR"
    elif score.get("verdict_correct", 0) == 1:
        outcome = "PASS"
    else:
        outcome = "FAIL"

    dr_str = f"{defect_recall:.2f}" if defect_recall is not None else "N/A"
    ev_str = f"{evidence_score:.2f}" if evidence_score is not None else "N/A"

    line1 = f"  {scenario_id} [{category}] — {outcome}"
    line2 = (
        f"    Expected: {verdict_expected} | Actual: {verdict_actual} "
        f"| Evidence: {ev_str} | Defect Recall: {dr_str}"
    )
    return f"{line1}\n{line2}"


# ---------------------------------------------------------------------------
# format_regression_alerts()
# ---------------------------------------------------------------------------


def format_regression_alerts(regressions: list[dict]) -> str:
    """Format regression warnings.

    Args:
        regressions: List of regression check dicts (from get_regression_check).
                     Each dict has: scenario_id, latest_score, window_avg,
                     regression (bool), delta (float).

    Returns:
        Formatted warning block if any regressions exist, empty string otherwise.

    Example output::

        Regression Alerts:
          dual-authority-detection: 0.90 -> 0.50 (avg 0.88, delta -0.38)
    """
    active = [r for r in regressions if r.get("regression", False)]
    if not active:
        return ""

    lines = ["Regression Alerts:"]
    for r in active:
        sid = r.get("scenario_id", "unknown")
        latest = r.get("latest_score", 0.0)
        avg = r.get("window_avg", 0.0)
        delta = r.get("delta", 0.0)
        lines.append(f"  {sid}: {avg:.2f} -> {latest:.2f} (avg {avg:.2f}, delta {delta:+.2f})")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# generate_report()
# ---------------------------------------------------------------------------


def generate_report(
    conn: sqlite3.Connection,
    run_id: Optional[str] = None,
    last_n: int = 1,
) -> str:
    """Generate a full human-readable report.

    If run_id is provided, reports on that specific run. Otherwise reports on
    the most recent run (per list_runs limit=1). Returns an informative message
    when no runs exist.

    Args:
        conn:   Read-only connection to eval_results.db.
        run_id: Optional specific run UUID. Defaults to most recent.
        last_n: Reserved for future multi-run summary mode (unused in v1).

    Returns:
        Full multi-section text report string.
    """
    # Resolve run_id if not provided
    if run_id is None:
        recent = eval_metrics.list_runs(conn, limit=1)
        if not recent:
            return "No eval runs found in eval_results.db. Run `cc-policy eval run` first."
        run_id = recent[0]["run_id"]

    run = eval_metrics.get_run(conn, run_id)
    if run is None:
        return f"Eval run '{run_id}' not found in eval_results.db."

    scores = eval_metrics.get_scores(conn, run_id)
    breakdown = eval_metrics.get_category_breakdown(conn, run_id)

    # Build regression check for all unique scenario_ids in the run
    scenario_ids = list({s["scenario_id"] for s in scores})
    regression_checks = [eval_metrics.get_regression_check(conn, sid) for sid in scenario_ids]
    regressions = [r for r in regression_checks if r.get("regression", False)]

    sections = []

    # Section 1: Summary
    sections.append("=" * 60)
    sections.append("EVAL RUN REPORT")
    sections.append("=" * 60)
    sections.append(format_run_summary(run, scores))

    # Section 2: Category breakdown
    if breakdown:
        sections.append("")
        sections.append("Category Breakdown")
        sections.append("-" * 40)
        sections.append(format_category_breakdown(breakdown))

    # Section 3: Scenario details
    if scores:
        sections.append("")
        sections.append("Scenario Details")
        sections.append("-" * 40)
        for score in scores:
            sections.append(format_scenario_detail(score))

    # Section 4: Regression alerts
    if regressions:
        sections.append("")
        sections.append("-" * 40)
        sections.append(format_regression_alerts(regressions))

    sections.append("=" * 60)
    return "\n".join(sections)


# ---------------------------------------------------------------------------
# generate_json_report()
# ---------------------------------------------------------------------------


def generate_json_report(
    conn: sqlite3.Connection,
    run_id: Optional[str] = None,
) -> dict:
    """Generate a machine-readable report dict for the --json flag.

    Args:
        conn:   Read-only connection to eval_results.db.
        run_id: Optional specific run UUID. Defaults to most recent.

    Returns:
        Dict with keys: run_id, mode, started_at, finished_at,
        scenario_count, pass_count, fail_count, error_count,
        category_breakdown, scores, regressions.
        Returns {"error": "message"} if the run is not found.
    """
    # Resolve run_id if not provided
    if run_id is None:
        recent = eval_metrics.list_runs(conn, limit=1)
        if not recent:
            return {"error": "No eval runs found in eval_results.db."}
        run_id = recent[0]["run_id"]

    run = eval_metrics.get_run(conn, run_id)
    if run is None:
        return {"error": f"Eval run '{run_id}' not found in eval_results.db."}

    scores = eval_metrics.get_scores(conn, run_id)
    breakdown = eval_metrics.get_category_breakdown(conn, run_id)

    # Regression checks
    scenario_ids = list({s["scenario_id"] for s in scores})
    regression_checks = [eval_metrics.get_regression_check(conn, sid) for sid in scenario_ids]
    regressions = [r for r in regression_checks if r.get("regression", False)]

    return {
        "run_id": run_id,
        "mode": run.get("mode", "unknown"),
        "started_at": run.get("started_at"),
        "finished_at": run.get("finished_at"),
        "scenario_count": run.get("scenario_count", 0),
        "pass_count": run.get("pass_count", 0),
        "fail_count": run.get("fail_count", 0),
        "error_count": run.get("error_count", 0),
        "category_breakdown": breakdown,
        "scores": scores,
        "regressions": regressions,
    }
