"""Observatory domain module — metrics, suggestions, and analysis runs.

This is the canonical write authority for obs_metrics, obs_suggestions, and
obs_runs. No other module writes to these tables (W-OBS-1).

In this wave the module is self-contained: all metric queries target obs_metrics
only. Cross-table analysis (joining events, traces, etc.) arrives in W-OBS-3.

@decision DEC-OBS-001
Title: Observatory tables are sole authority for metrics, suggestions, and runs
Status: accepted
Rationale: W-OBS-1 establishes three SQLite tables as the single source of truth
  for the observatory flywheel. obs_metrics collects time-series scalar values
  emitted by hooks and agents. obs_suggestions stores the proposal/accept/reject/
  defer/measure lifecycle for improvement recommendations. obs_runs records each
  analysis pass so convergence and trend analysis can reference prior state.
  No flat-file fallbacks exist — the tables are the authority (DEC-RT-001).

@decision DEC-OBS-002
Title: emit_batch uses a single transaction for atomicity
Status: accepted
Rationale: A batch of metrics is either fully persisted or fully rolled back.
  Partial batches would produce misleading trend data. Using conn as a context
  manager (with conn:) achieves BEGIN IMMEDIATE / COMMIT / ROLLBACK automatically
  via Python's sqlite3 isolation_level semantics.

@decision DEC-OBS-003
Title: Slope calculation is (last - first) / count, not linear regression
Status: accepted
Rationale: Full linear regression requires more compute and external libraries.
  The (last - first) / count approximation is sufficient for the early observatory
  wave and matches the spec. W-OBS-3 can upgrade to scipy regression when the
  analysis layer matures.
"""

from __future__ import annotations

import json
import math
import sqlite3
import time
from typing import Optional

# ---------------------------------------------------------------------------
# Metric emission
# ---------------------------------------------------------------------------


def emit_metric(
    conn: sqlite3.Connection,
    name: str,
    value: float,
    labels: Optional[dict] = None,
    session_id: Optional[str] = None,
    role: Optional[str] = None,
) -> int:
    """Insert a single metric row and return its auto-assigned id.

    Args:
        conn:       Open SQLite connection with obs_metrics table.
        name:       Metric name (e.g. "agent_duration_s", "test_result").
        value:      Scalar float measurement.
        labels:     Optional dict serialised to JSON in labels_json column.
        session_id: Optional session identifier for correlation.
        role:       Optional agent role; stored in the indexed role column.

    Returns:
        The AUTOINCREMENT id of the inserted row.
    """
    now = int(time.time())
    labels_json = json.dumps(labels) if labels is not None else None
    with conn:
        cur = conn.execute(
            """
            INSERT INTO obs_metrics
                (metric_name, value, role, labels_json, session_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (name, value, role, labels_json, session_id, now),
        )
    return cur.lastrowid


def emit_batch(conn: sqlite3.Connection, metrics_list: list[dict]) -> int:
    """Insert multiple metrics in a single transaction.

    Each element of metrics_list is a dict with keys:
        name        (str, required)
        value       (float, required)
        labels      (dict, optional)
        session_id  (str, optional)
        role        (str, optional)

    Returns the number of rows inserted.

    @decision DEC-OBS-002
    Title: emit_batch uses a single transaction for atomicity
    Status: accepted
    Rationale: See module-level docstring.
    """
    now = int(time.time())
    rows = []
    for m in metrics_list:
        lj = json.dumps(m["labels"]) if m.get("labels") is not None else None
        rows.append(
            (
                m["name"],
                float(m["value"]),
                m.get("role"),
                lj,
                m.get("session_id"),
                now,
            )
        )
    with conn:
        conn.executemany(
            """
            INSERT INTO obs_metrics
                (metric_name, value, role, labels_json, session_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            rows,
        )
    return len(rows)


# ---------------------------------------------------------------------------
# Metric queries
# ---------------------------------------------------------------------------


def query_metrics(
    conn: sqlite3.Connection,
    name: str,
    since: Optional[int] = None,
    until: Optional[int] = None,
    labels_filter: Optional[dict] = None,
    role: Optional[str] = None,
    limit: int = 100,
) -> list[dict]:
    """Query obs_metrics with optional filters.

    When role is provided the query uses the indexed role column.
    When labels_filter is provided each key/value pair is matched via
    SQLite's json_extract() function.

    Returns a list of row dicts ordered by created_at ASC.
    """
    clauses: list[str] = ["metric_name = ?"]
    params: list = [name]

    if since is not None:
        clauses.append("created_at >= ?")
        params.append(since)
    if until is not None:
        clauses.append("created_at <= ?")
        params.append(until)
    if role is not None:
        clauses.append("role = ?")
        params.append(role)
    if labels_filter:
        for key, val in labels_filter.items():
            clauses.append(f"json_extract(labels_json, '$.{key}') = ?")
            params.append(val)

    where = "WHERE " + " AND ".join(clauses)
    params.append(limit)

    rows = conn.execute(
        f"""
        SELECT id, metric_name, value, role, labels_json, session_id, created_at
        FROM   obs_metrics
        {where}
        ORDER  BY created_at ASC
        LIMIT  ?
        """,
        params,
    ).fetchall()
    return [dict(r) for r in rows]


# ---------------------------------------------------------------------------
# Analysis helpers
# ---------------------------------------------------------------------------


def compute_trend(
    conn: sqlite3.Connection,
    name: str,
    window_hours: int = 24,
) -> dict:
    """Compute trend statistics for a metric over a time window.

    Returns:
        {
            "slope":       float,  # (last_value - first_value) / count
            "average":     float,
            "count":       int,
            "first_value": float,
            "last_value":  float,
        }

    When count < 2, slope is 0.0 and first/last values equal the single
    value (or 0.0 when count == 0).

    @decision DEC-OBS-003
    Title: Slope is (last - first) / count
    Status: accepted
    Rationale: See module-level docstring.
    """
    since = int(time.time()) - window_hours * 3600
    rows = query_metrics(conn, name, since=since, limit=10000)
    count = len(rows)
    if count == 0:
        return {"slope": 0.0, "average": 0.0, "count": 0, "first_value": 0.0, "last_value": 0.0}
    values = [r["value"] for r in rows]
    first_value = values[0]
    last_value = values[-1]
    average = sum(values) / count
    slope = (last_value - first_value) / count if count >= 2 else 0.0
    return {
        "slope": slope,
        "average": average,
        "count": count,
        "first_value": first_value,
        "last_value": last_value,
    }


def detect_anomalies(
    conn: sqlite3.Connection,
    name: str,
    threshold_sigma: float = 2.0,
) -> list[dict]:
    """Return rows whose value exceeds mean + threshold_sigma * stddev.

    Uses all available rows for the metric (no time window). Returns a list
    of row dicts — callers can inspect the value field on each returned row.
    """
    rows = query_metrics(conn, name, limit=100000)
    if len(rows) < 2:
        return []
    values = [r["value"] for r in rows]
    mean = sum(values) / len(values)
    variance = sum((v - mean) ** 2 for v in values) / len(values)
    stddev = math.sqrt(variance)
    if stddev == 0.0:
        return []
    threshold = mean + threshold_sigma * stddev
    return [r for r in rows if r["value"] > threshold]


def agent_performance(
    conn: sqlite3.Connection,
    role: str,
    window_hours: int = 24,
) -> dict:
    """Query agent_duration_s metrics for a given role and return stats.

    Returns:
        {"role": str, "count": int, "average": float, "min": float, "max": float}
    """
    since = int(time.time()) - window_hours * 3600
    rows = query_metrics(conn, "agent_duration_s", since=since, role=role, limit=10000)
    count = len(rows)
    if count == 0:
        return {"role": role, "count": 0, "average": 0.0, "min": 0.0, "max": 0.0}
    values = [r["value"] for r in rows]
    return {
        "role": role,
        "count": count,
        "average": sum(values) / count,
        "min": min(values),
        "max": max(values),
    }


def denial_hotspots(
    conn: sqlite3.Connection,
    window_hours: int = 24,
) -> list[dict]:
    """Query guard_denial metrics, group by policy label, return sorted by count.

    The policy label is expected in labels_json as {"policy": "<name>"}.
    Returns a list of {"policy": str, "count": int} dicts, descending by count.
    """
    since = int(time.time()) - window_hours * 3600
    rows = query_metrics(conn, "guard_denial", since=since, limit=100000)
    counts: dict[str, int] = {}
    for r in rows:
        policy = "unknown"
        if r["labels_json"]:
            try:
                labels = json.loads(r["labels_json"])
                policy = labels.get("policy", "unknown")
            except (json.JSONDecodeError, AttributeError):
                pass
        counts[policy] = counts.get(policy, 0) + 1
    return sorted(
        [{"policy": k, "count": v} for k, v in counts.items()],
        key=lambda x: x["count"],
        reverse=True,
    )


def test_health(
    conn: sqlite3.Connection,
    window_hours: int = 24,
) -> dict:
    """Query test_result metrics and compute pass rate trend.

    Expects metric values of 1.0 (pass) or 0.0 (fail).
    Returns:
        {"total": int, "passed": int, "failed": int, "pass_rate": float}
    """
    since = int(time.time()) - window_hours * 3600
    rows = query_metrics(conn, "test_result", since=since, limit=100000)
    total = len(rows)
    if total == 0:
        return {"total": 0, "passed": 0, "failed": 0, "pass_rate": 0.0}
    passed = sum(1 for r in rows if r["value"] >= 1.0)
    failed = total - passed
    return {"total": total, "passed": passed, "failed": failed, "pass_rate": passed / total}


# ---------------------------------------------------------------------------
# Suggestion lifecycle
# ---------------------------------------------------------------------------


def suggest(
    conn: sqlite3.Connection,
    category: str,
    title: str,
    body: Optional[str] = None,
    target_metric: Optional[str] = None,
    baseline: Optional[float] = None,
    signal_id: Optional[str] = None,
    source_session: Optional[str] = None,
) -> int:
    """Insert a new suggestion with status='proposed'. Returns the new row id."""
    now = int(time.time())
    with conn:
        cur = conn.execute(
            """
            INSERT INTO obs_suggestions
                (signal_id, category, title, body, target_metric,
                 baseline_value, status, source_session, created_at)
            VALUES (?, ?, ?, ?, ?, ?, 'proposed', ?, ?)
            """,
            (signal_id, category, title, body, target_metric, baseline, source_session, now),
        )
    return cur.lastrowid


def accept_suggestion(
    conn: sqlite3.Connection,
    id: int,
    measure_after: Optional[int] = None,
) -> None:
    """Transition a suggestion to status='accepted'.

    If measure_after is None, defaults to now + 7 days.
    """
    now = int(time.time())
    if measure_after is None:
        measure_after = now + 7 * 86400
    with conn:
        conn.execute(
            """
            UPDATE obs_suggestions
            SET    status         = 'accepted',
                   disposition_at = ?,
                   measure_after  = ?
            WHERE  id = ?
            """,
            (now, measure_after, id),
        )


def reject_suggestion(
    conn: sqlite3.Connection,
    id: int,
    reason: Optional[str] = None,
) -> None:
    """Transition a suggestion to status='rejected'."""
    now = int(time.time())
    with conn:
        conn.execute(
            """
            UPDATE obs_suggestions
            SET    status         = 'rejected',
                   reject_reason  = ?,
                   disposition_at = ?
            WHERE  id = ?
            """,
            (reason, now, id),
        )


def defer_suggestion(
    conn: sqlite3.Connection,
    id: int,
    reassess_after: int = 5,
) -> None:
    """Transition a suggestion to status='deferred'."""
    now = int(time.time())
    with conn:
        conn.execute(
            """
            UPDATE obs_suggestions
            SET    status                = 'deferred',
                   defer_reassess_after  = ?,
                   disposition_at        = ?
            WHERE  id = ?
            """,
            (reassess_after, now, id),
        )


def batch_accept(conn: sqlite3.Connection, category: str) -> int:
    """Accept all 'proposed' suggestions in a category. Returns count updated."""
    now = int(time.time())
    default_measure_after = now + 7 * 86400
    with conn:
        cur = conn.execute(
            """
            UPDATE obs_suggestions
            SET    status         = 'accepted',
                   disposition_at = ?,
                   measure_after  = ?
            WHERE  category = ?
              AND  status   = 'proposed'
            """,
            (now, default_measure_after, category),
        )
    return cur.rowcount


def check_convergence(conn: sqlite3.Connection) -> list[dict]:
    """Measure accepted suggestions whose measure_after time has passed.

    For each such suggestion:
    - Queries the target_metric for a recent average (last 24h).
    - Compares to baseline_value.
    - Sets effective=1 (improved >=10%), 0 (unchanged), or -1 (regressed >=10%).
    - Sets status='measured'.

    Returns a list of convergence result dicts.
    """
    now = int(time.time())
    rows = conn.execute(
        """
        SELECT id, target_metric, baseline_value, measure_after
        FROM   obs_suggestions
        WHERE  status        = 'accepted'
          AND  measure_after IS NOT NULL
          AND  measure_after <= ?
        """,
        (now,),
    ).fetchall()

    results = []
    for row in rows:
        sid = row[0]
        target = row[1]
        baseline = row[2]

        measured_value: Optional[float] = None
        effective = 0

        if target is not None and baseline is not None:
            since = now - 24 * 3600
            metric_rows = query_metrics(conn, target, since=since, limit=10000)
            if metric_rows:
                vals = [r["value"] for r in metric_rows]
                measured_value = sum(vals) / len(vals)
                if baseline != 0:
                    change = (measured_value - baseline) / abs(baseline)
                    if change >= 0.10:
                        effective = 1
                    elif change <= -0.10:
                        effective = -1
                    else:
                        effective = 0

        with conn:
            conn.execute(
                """
                UPDATE obs_suggestions
                SET    status         = 'measured',
                       measured_value = ?,
                       effective      = ?,
                       disposition_at = ?
                WHERE  id = ?
                """,
                (measured_value, effective, now, sid),
            )

        results.append(
            {
                "id": sid,
                "target_metric": target,
                "baseline_value": baseline,
                "measured_value": measured_value,
                "effective": effective,
            }
        )
    return results


# ---------------------------------------------------------------------------
# Run records
# ---------------------------------------------------------------------------


def record_run(
    conn: sqlite3.Connection,
    metrics_snapshot: Optional[dict] = None,
    trace_count: int = 0,
    suggestion_count: int = 0,
) -> int:
    """Insert an obs_runs row. Returns the new row id."""
    now = int(time.time())
    snapshot_json = json.dumps(metrics_snapshot) if metrics_snapshot is not None else None
    with conn:
        cur = conn.execute(
            """
            INSERT INTO obs_runs (ran_at, metrics_snapshot, trace_count, suggestion_count)
            VALUES (?, ?, ?, ?)
            """,
            (now, snapshot_json, trace_count, suggestion_count),
        )
    return cur.lastrowid


def latest_run(conn: sqlite3.Connection) -> Optional[dict]:
    """Return the most recent obs_runs row as a dict, or None."""
    row = conn.execute(
        "SELECT id, ran_at, metrics_snapshot, trace_count, suggestion_count "
        "FROM obs_runs ORDER BY id DESC LIMIT 1"
    ).fetchone()
    if row is None:
        return None
    return dict(row)


# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------


def obs_cleanup(
    conn: sqlite3.Connection,
    metrics_ttl_days: int = 30,
    suggestions_ttl_days: int = 90,
) -> dict:
    """Delete stale metrics and terminal suggestions.

    Returns {"metrics_deleted": int, "suggestions_deleted": int}.
    """
    now = int(time.time())
    metrics_cutoff = now - metrics_ttl_days * 86400
    suggestions_cutoff = now - suggestions_ttl_days * 86400

    with conn:
        mc = conn.execute(
            "DELETE FROM obs_metrics WHERE created_at < ?",
            (metrics_cutoff,),
        )
        sc = conn.execute(
            """
            DELETE FROM obs_suggestions
            WHERE  status       IN ('measured', 'rejected')
              AND  disposition_at IS NOT NULL
              AND  disposition_at < ?
            """,
            (suggestions_cutoff,),
        )
    return {"metrics_deleted": mc.rowcount, "suggestions_deleted": sc.rowcount}


# ---------------------------------------------------------------------------
# Status and summary
# ---------------------------------------------------------------------------


def status(conn: sqlite3.Connection) -> dict:
    """Return high-level observatory status.

    Returns:
        {
            "pending_count":    int,   # proposed suggestions count
            "acceptance_rate":  float, # accepted / (accepted + rejected) or 0.0
            "last_analysis_at": int or None,
            "total_metrics":    int,
        }
    """
    pending_count = conn.execute(
        "SELECT COUNT(*) FROM obs_suggestions WHERE status = 'proposed'"
    ).fetchone()[0]

    accepted = conn.execute(
        "SELECT COUNT(*) FROM obs_suggestions WHERE status = 'accepted'"
    ).fetchone()[0]
    rejected = conn.execute(
        "SELECT COUNT(*) FROM obs_suggestions WHERE status = 'rejected'"
    ).fetchone()[0]
    denominator = accepted + rejected
    acceptance_rate = accepted / denominator if denominator > 0 else 0.0

    total_metrics = conn.execute("SELECT COUNT(*) FROM obs_metrics").fetchone()[0]

    last_run = latest_run(conn)
    last_analysis_at = last_run["ran_at"] if last_run else None

    return {
        "pending_count": pending_count,
        "acceptance_rate": acceptance_rate,
        "last_analysis_at": last_analysis_at,
        "total_metrics": total_metrics,
    }


def summary(conn: sqlite3.Connection, window_hours: int = 24) -> dict:
    """Run all analysis functions and assemble a report dict.

    Also records an obs_runs entry with a snapshot of the report.

    Returns a dict with keys:
        metrics_24h, active_suggestions, recent_anomalies,
        convergence_results, agent_performance, denial_hotspots, test_health
    """
    since = int(time.time()) - window_hours * 3600

    # Count metrics in the window
    metrics_24h = conn.execute(
        "SELECT COUNT(*) FROM obs_metrics WHERE created_at >= ?",
        (since,),
    ).fetchone()[0]

    # Active suggestions (proposed + accepted)
    active_suggestions = conn.execute(
        "SELECT COUNT(*) FROM obs_suggestions WHERE status IN ('proposed', 'accepted')"
    ).fetchone()[0]

    # Anomalies: collect across all distinct metric names in window
    distinct_names = conn.execute(
        "SELECT DISTINCT metric_name FROM obs_metrics WHERE created_at >= ?",
        (since,),
    ).fetchall()
    recent_anomalies: list[dict] = []
    for (mname,) in distinct_names:
        recent_anomalies.extend(detect_anomalies(conn, mname))

    # Convergence check
    convergence_results = check_convergence(conn)

    # Agent performance (aggregate across known roles)
    roles = ["implementer", "tester", "guardian", "planner"]
    ap = {r: agent_performance(conn, r, window_hours=window_hours) for r in roles}

    dh = denial_hotspots(conn, window_hours=window_hours)
    th = test_health(conn, window_hours=window_hours)

    report = {
        "metrics_24h": metrics_24h,
        "active_suggestions": active_suggestions,
        "recent_anomalies": recent_anomalies,
        "convergence_results": convergence_results,
        "agent_performance": ap,
        "denial_hotspots": dh,
        "test_health": th,
    }

    # Record this run
    record_run(
        conn,
        metrics_snapshot={"metrics_24h": metrics_24h, "active_suggestions": active_suggestions},
        trace_count=0,
        suggestion_count=active_suggestions,
    )

    return report
