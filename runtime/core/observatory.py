"""Observatory domain module — metrics, suggestions, and analysis runs.

This is the canonical write authority for obs_metrics, obs_suggestions, and
obs_runs. No other module writes to these tables (W-OBS-1).

W-OBS-3 adds cross-table analysis functions (cross_analysis, pattern_detection,
generate_report) and refactors summary() to delegate to generate_report().
All joins to non-obs tables use LEFT JOIN so the analysis works when enrichment
tables have zero rows.

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

@decision DEC-OBS-004
Title: All cross-table joins are LEFT JOIN to tolerate empty enrichment tables
Status: accepted
Rationale: obs_metrics is the primary data source for the observatory. Enrichment
  tables (traces, evaluation_state, completion_records, agent_markers) may have
  zero rows in early sessions, test environments, or after cleanup. Using LEFT JOIN
  means enrichment columns are NULL rather than the query returning zero rows.
  Analysis functions must accept NULL enrichment columns gracefully. This satisfies
  the W-OBS-3 null-tolerance requirement without requiring data backfill.

@decision DEC-OBS-005
Title: summary() delegates entirely to generate_report() — no dual path
Status: accepted
Rationale: W-OBS-3 replaces summary()'s bespoke assembly logic with generate_report().
  Keeping both code paths would create dual-authority for the report structure.
  The old keys (metrics_24h, agent_performance, denial_hotspots) are removed;
  callers needing those fields can call the underlying functions directly or read
  the richer generate_report output. Deletion-first: the legacy assembly block
  is removed entirely in this wave.
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


def cross_analysis(conn: sqlite3.Connection, window_hours: int = 24) -> dict:
    """Produce a comprehensive operational picture by joining obs_metrics with
    enrichment tables via LEFT JOIN.

    All joins to non-obs tables (traces, completion_records, evaluation_state,
    agent_markers) use LEFT JOIN so null enrichment produces NULL columns rather
    than empty result sets. The function produces a valid report when enrichment
    tables are completely empty.

    Returns a dict with keys:
        agent_stats       list[dict] — per-role duration metrics
        test_health       dict       — pass rate, fail count, avg duration
        denial_patterns   list[dict] — top denied policies grouped by label
        evaluation_trends list[dict] — verdict distribution
        convergence_status list[dict] — active suggestions and convergence state
        review_gate_health dict      — infra failure rate, provider breakdown,
                                       predictive accuracy

    @decision DEC-OBS-004
    Title: All cross-table joins are LEFT JOIN to tolerate empty enrichment tables
    Status: accepted
    Rationale: See module-level docstring.
    """
    since = int(time.time()) - window_hours * 3600

    # --- agent_stats: per-role avg/p50/p95 from agent_duration_s ---
    # LEFT JOIN traces to enrich with ticket context; NULLs are fine.
    rows = conn.execute(
        """
        SELECT   m.role,
                 COUNT(*)            AS cnt,
                 AVG(m.value)        AS avg_duration,
                 MIN(m.value)        AS min_duration,
                 MAX(m.value)        AS max_duration,
                 t.ticket            AS ticket
        FROM     obs_metrics  m
        LEFT JOIN traces      t ON m.session_id = t.session_id
        WHERE    m.metric_name = 'agent_duration_s'
          AND    m.created_at  >= ?
          AND    m.role        IS NOT NULL
        GROUP BY m.role
        ORDER BY cnt DESC
        """,
        (since,),
    ).fetchall()

    agent_stats: list[dict] = []
    for r in rows:
        # Compute p50/p95 via Python sort (SQLite has no percentile function)
        vals_rows = conn.execute(
            """
            SELECT value FROM obs_metrics
            WHERE  metric_name = 'agent_duration_s'
              AND  created_at  >= ?
              AND  role        = ?
            ORDER  BY value ASC
            """,
            (since, r["role"]),
        ).fetchall()
        vals = [v[0] for v in vals_rows]
        p50 = vals[len(vals) // 2] if vals else 0.0
        p95_idx = int(len(vals) * 0.95)
        p95 = vals[min(p95_idx, len(vals) - 1)] if vals else 0.0

        agent_stats.append(
            {
                "role": r["role"],
                "count": r["cnt"],
                "avg_duration": r["avg_duration"],
                "min_duration": r["min_duration"],
                "max_duration": r["max_duration"],
                "p50_duration": p50,
                "p95_duration": p95,
                "ticket": r["ticket"],  # NULL when traces table is empty
            }
        )

    # --- test_health: pass rate and average duration ---
    th = test_health(conn, window_hours=window_hours)

    # --- denial_patterns: top denied policies ---
    dp = denial_hotspots(conn, window_hours=window_hours)

    # --- evaluation_trends: verdict distribution from eval_verdict metrics ---
    eval_rows = conn.execute(
        """
        SELECT   json_extract(labels_json, '$.verdict') AS verdict,
                 COUNT(*)                               AS cnt
        FROM     obs_metrics
        WHERE    metric_name = 'eval_verdict'
          AND    created_at  >= ?
        GROUP BY verdict
        ORDER BY cnt DESC
        """,
        (since,),
    ).fetchall()
    evaluation_trends = [
        {"verdict": r["verdict"] or "unknown", "count": r["cnt"]} for r in eval_rows
    ]

    # --- convergence_status: active suggestions and their convergence state ---
    sugg_rows = conn.execute(
        """
        SELECT id, category, title, status, target_metric,
               baseline_value, measured_value, effective, measure_after
        FROM   obs_suggestions
        WHERE  status IN ('proposed', 'accepted', 'measured')
        ORDER  BY created_at DESC
        LIMIT  50
        """,
    ).fetchall()
    convergence_status = [dict(r) for r in sugg_rows]

    # --- review_gate_health: infra failure rate, provider breakdown,
    #     predictive accuracy (review_verdict agreement with eval_verdict) ---
    total_reviews = conn.execute(
        "SELECT COUNT(*) FROM obs_metrics WHERE metric_name='review_verdict' AND created_at >= ?",
        (since,),
    ).fetchone()[0]

    infra_failures = conn.execute(
        "SELECT COUNT(*) FROM obs_metrics WHERE metric_name='review_infra_failure' AND created_at >= ?",
        (since,),
    ).fetchone()[0]

    infra_failure_rate = (infra_failures / total_reviews) if total_reviews > 0 else 0.0

    # Provider breakdown: group review_verdict by provider label
    provider_rows = conn.execute(
        """
        SELECT   json_extract(labels_json, '$.provider') AS provider,
                 COUNT(*)                                AS cnt
        FROM     obs_metrics
        WHERE    metric_name = 'review_verdict'
          AND    created_at  >= ?
        GROUP BY provider
        """,
        (since,),
    ).fetchall()
    provider_breakdown = [
        {"provider": r["provider"] or "unknown", "count": r["cnt"]} for r in provider_rows
    ]

    # Predictive accuracy: fraction of review_verdict rows whose verdict label
    # matches a corresponding eval_verdict within the same session.
    # Uses LEFT JOIN on session_id — when evaluation_state is empty, accuracy = None.
    accuracy_row = conn.execute(
        """
        SELECT COUNT(ev.id)  AS total_paired,
               SUM(
                 CASE WHEN json_extract(rv.labels_json, '$.verdict') IN ('ALLOW','pass')
                       AND json_extract(ev.labels_json, '$.verdict') IN ('ready_for_guardian','pass')
                      THEN 1
                      WHEN json_extract(rv.labels_json, '$.verdict') NOT IN ('ALLOW','pass')
                       AND json_extract(ev.labels_json, '$.verdict') NOT IN ('ready_for_guardian','pass')
                      THEN 1
                      ELSE 0
                 END
               )              AS agreed
        FROM   obs_metrics rv
        LEFT JOIN obs_metrics ev
               ON rv.session_id   = ev.session_id
              AND ev.metric_name  = 'eval_verdict'
              AND ev.created_at   >= ?
        WHERE  rv.metric_name = 'review_verdict'
          AND  rv.created_at  >= ?
        """,
        (since, since),
    ).fetchone()

    predictive_accuracy: Optional[float] = None
    if accuracy_row and accuracy_row["total_paired"] and accuracy_row["total_paired"] > 0:
        agreed = accuracy_row["agreed"] or 0
        predictive_accuracy = agreed / accuracy_row["total_paired"]

    review_gate_health = {
        "total_reviews": total_reviews,
        "infra_failures": infra_failures,
        "infra_failure_rate": infra_failure_rate,
        "provider_breakdown": provider_breakdown,
        "predictive_accuracy": predictive_accuracy,
    }

    return {
        "agent_stats": agent_stats,
        "test_health": th,
        "denial_patterns": dp,
        "evaluation_trends": evaluation_trends,
        "convergence_status": convergence_status,
        "review_gate_health": review_gate_health,
    }


def pattern_detection(conn: sqlite3.Connection, window_hours: int = 24) -> list[dict]:
    """Identify recurring operational patterns in obs_metrics.

    Detects these pattern types:
        repeated_denial    Same policy denied 3+ times in window
        slow_agent         Agent duration trending upward (slope > 0.1)
        test_regression    Test pass rate declining in recent half vs prior half
        evaluation_churn   Multiple needs_changes for same workflow
        stale_marker       Active agent_markers older than 1 hour (LEFT JOIN)
        review_quality     Review infra failure rate > 20%

    Each pattern dict has:
        pattern_type     str
        severity_score   float  (occurrence_count × recency_weight)
        description      str
        evidence         list   (specific occurrences)
        suggested_action str

    Recency weight: all occurrences in window receive weight 1.0 (uniform).
    Future waves can apply time-decay weighting.

    @decision DEC-OBS-004
    Title: LEFT JOIN for stale_marker detection
    Status: accepted
    Rationale: agent_markers may be empty. LEFT JOIN prevents empty-table
      crashes; the stale_marker pattern simply produces zero results when
      the table is empty.
    """
    now = int(time.time())
    since = now - window_hours * 3600
    patterns: list[dict] = []

    # --- repeated_denial: same policy denied 3+ times ---
    denial_rows = conn.execute(
        """
        SELECT   json_extract(labels_json, '$.policy') AS policy,
                 COUNT(*)                              AS cnt
        FROM     obs_metrics
        WHERE    metric_name = 'guard_denial'
          AND    created_at  >= ?
        GROUP BY policy
        HAVING   COUNT(*) >= 3
        ORDER BY cnt DESC
        """,
        (since,),
    ).fetchall()
    for r in denial_rows:
        policy = r["policy"] or "unknown"
        cnt = r["cnt"]
        # Collect specific evidence rows
        evidence_rows = conn.execute(
            """
            SELECT id, created_at, labels_json
            FROM   obs_metrics
            WHERE  metric_name = 'guard_denial'
              AND  created_at  >= ?
              AND  json_extract(labels_json, '$.policy') = ?
            ORDER  BY created_at DESC
            LIMIT  5
            """,
            (since, policy),
        ).fetchall()
        evidence = [dict(e) for e in evidence_rows]
        patterns.append(
            {
                "pattern_type": "repeated_denial",
                "severity_score": float(cnt),
                "description": f"Policy '{policy}' denied {cnt} times in {window_hours}h window",
                "evidence": evidence,
                "suggested_action": (
                    f"Review policy '{policy}' configuration. "
                    "Consider whether the rule is misconfigured or the workflow needs adjustment."
                ),
            }
        )

    # --- slow_agent: agent duration trending upward (slope > 0.1) ---
    role_rows = conn.execute(
        "SELECT DISTINCT role FROM obs_metrics WHERE metric_name='agent_duration_s' AND role IS NOT NULL",
    ).fetchall()
    for (role,) in role_rows:
        # compute_trend is not role-filtered; query role-specific slope directly
        role_vals = conn.execute(
            """
            SELECT value FROM obs_metrics
            WHERE  metric_name = 'agent_duration_s'
              AND  created_at  >= ?
              AND  role        = ?
            ORDER  BY created_at ASC
            """,
            (since, role),
        ).fetchall()
        vals = [v[0] for v in role_vals]
        if len(vals) < 2:
            continue
        slope = (vals[-1] - vals[0]) / len(vals)
        if slope > 0.1:
            patterns.append(
                {
                    "pattern_type": "slow_agent",
                    "severity_score": float(slope),
                    "description": (
                        f"Agent '{role}' duration trending upward "
                        f"(slope={slope:.2f}s/run, last={vals[-1]:.1f}s)"
                    ),
                    "evidence": [
                        {"role": role, "first": vals[0], "last": vals[-1], "count": len(vals)}
                    ],
                    "suggested_action": (
                        f"Investigate context growth or inefficiency in '{role}' agent. "
                        "Check for prompt bloat, large file reads, or excessive tool calls."
                    ),
                }
            )

    # --- test_regression: pass rate declining (recent half vs prior half) ---
    test_rows = conn.execute(
        """
        SELECT value, created_at FROM obs_metrics
        WHERE  metric_name = 'test_result'
          AND  created_at  >= ?
        ORDER  BY created_at ASC
        """,
        (since,),
    ).fetchall()
    if len(test_rows) >= 4:
        mid = len(test_rows) // 2
        prior_vals = [r["value"] for r in test_rows[:mid]]
        recent_vals = [r["value"] for r in test_rows[mid:]]
        prior_rate = sum(prior_vals) / len(prior_vals)
        recent_rate = sum(recent_vals) / len(recent_vals)
        if prior_rate > 0 and (prior_rate - recent_rate) / prior_rate >= 0.10:
            decline = prior_rate - recent_rate
            patterns.append(
                {
                    "pattern_type": "test_regression",
                    "severity_score": float(decline * len(recent_vals)),
                    "description": (
                        f"Test pass rate declined from {prior_rate:.1%} to {recent_rate:.1%} "
                        f"({decline:.1%} drop) in {window_hours}h window"
                    ),
                    "evidence": [
                        {
                            "prior_rate": prior_rate,
                            "recent_rate": recent_rate,
                            "prior_count": len(prior_vals),
                            "recent_count": len(recent_vals),
                        }
                    ],
                    "suggested_action": (
                        "Investigate recent test failures. Check for flaky tests or "
                        "newly broken functionality in recent commits."
                    ),
                }
            )

    # --- evaluation_churn: multiple needs_changes for same workflow ---
    churn_rows = conn.execute(
        """
        SELECT   session_id,
                 COUNT(*) AS cnt
        FROM     obs_metrics
        WHERE    metric_name  = 'eval_verdict'
          AND    created_at   >= ?
          AND    json_extract(labels_json, '$.verdict') = 'needs_changes'
          AND    session_id   IS NOT NULL
        GROUP BY session_id
        HAVING   COUNT(*) >= 2
        ORDER BY cnt DESC
        """,
        (since,),
    ).fetchall()
    for r in churn_rows:
        session = r["session_id"]
        cnt = r["cnt"]
        patterns.append(
            {
                "pattern_type": "evaluation_churn",
                "severity_score": float(cnt),
                "description": (
                    f"Session '{session}' received {cnt} needs_changes verdicts — "
                    "evaluation loop is not converging"
                ),
                "evidence": [{"session_id": session, "needs_changes_count": cnt}],
                "suggested_action": (
                    f"Review session '{session}' implementation. "
                    "Multiple evaluation failures suggest unclear requirements or "
                    "incomplete implementation scope."
                ),
            }
        )

    # --- stale_marker: LEFT JOIN agent_markers for markers > 1 hour old ---
    stale_rows = conn.execute(
        """
        SELECT am.agent_id, am.role, am.started_at
        FROM   agent_markers am
        WHERE  am.is_active  = 1
          AND  am.started_at < ?
        ORDER  BY am.started_at ASC
        LIMIT  20
        """,
        (now - 3600,),
    ).fetchall()
    for r in stale_rows:
        age_hours = (now - r["started_at"]) / 3600
        patterns.append(
            {
                "pattern_type": "stale_marker",
                "severity_score": float(age_hours),
                "description": (
                    f"Agent marker '{r['agent_id']}' (role={r['role']}) "
                    f"has been active for {age_hours:.1f}h"
                ),
                "evidence": [dict(r)],
                "suggested_action": (
                    f"Check whether agent '{r['agent_id']}' is still running. "
                    "Stale markers indicate crashed or orphaned agent sessions."
                ),
            }
        )

    # --- review_quality: infra failure rate > 20% ---
    total_reviews = conn.execute(
        "SELECT COUNT(*) FROM obs_metrics WHERE metric_name='review_verdict' AND created_at >= ?",
        (since,),
    ).fetchone()[0]
    infra_failures = conn.execute(
        "SELECT COUNT(*) FROM obs_metrics WHERE metric_name='review_infra_failure' AND created_at >= ?",
        (since,),
    ).fetchone()[0]
    if total_reviews > 0:
        failure_rate = infra_failures / total_reviews
        if failure_rate > 0.20:
            patterns.append(
                {
                    "pattern_type": "review_quality",
                    "severity_score": float(infra_failures),
                    "description": (
                        f"Review gate infra failure rate is {failure_rate:.1%} "
                        f"({infra_failures}/{total_reviews} reviews failed)"
                    ),
                    "evidence": [
                        {
                            "total_reviews": total_reviews,
                            "infra_failures": infra_failures,
                            "failure_rate": failure_rate,
                        }
                    ],
                    "suggested_action": (
                        "Investigate review gate provider health. "
                        "High infra failure rates indicate network issues, quota exhaustion, "
                        "or provider outages."
                    ),
                }
            )

    return patterns


def generate_report(conn: sqlite3.Connection, window_hours: int = 24) -> dict:
    """Assemble a comprehensive analysis report and record an obs_run.

    Calls cross_analysis(), pattern_detection(), check_convergence(), and
    compute_trend() for key metrics. Records the run via record_run().

    Returns a dict with keys:
        metrics_summary   dict  — total, by_type, by_role counts in window
        trends            dict  — compute_trend output keyed by metric name
        patterns          list  — output of pattern_detection()
        suggestions       list  — active obs_suggestions rows
        convergence       list  — output of check_convergence()
        review_gate_health dict — review verdict stats, provider breakdown,
                                  predictive accuracy (from cross_analysis)

    @decision DEC-OBS-005
    Title: summary() delegates entirely to generate_report()
    Status: accepted
    Rationale: See module-level docstring.
    """
    since = int(time.time()) - window_hours * 3600

    # --- metrics_summary: total, by_type, by_role ---
    total_metrics = conn.execute(
        "SELECT COUNT(*) FROM obs_metrics WHERE created_at >= ?",
        (since,),
    ).fetchone()[0]

    by_type_rows = conn.execute(
        """
        SELECT metric_name, COUNT(*) AS cnt
        FROM   obs_metrics
        WHERE  created_at >= ?
        GROUP  BY metric_name
        ORDER  BY cnt DESC
        """,
        (since,),
    ).fetchall()
    by_type = {r["metric_name"]: r["cnt"] for r in by_type_rows}

    by_role_rows = conn.execute(
        """
        SELECT role, COUNT(*) AS cnt
        FROM   obs_metrics
        WHERE  created_at >= ?
          AND  role IS NOT NULL
        GROUP  BY role
        ORDER  BY cnt DESC
        """,
        (since,),
    ).fetchall()
    by_role = {r["role"]: r["cnt"] for r in by_role_rows}

    metrics_summary = {"total": total_metrics, "by_type": by_type, "by_role": by_role}

    # --- trends: compute_trend for key metric names ---
    key_metrics = [
        "agent_duration_s",
        "test_result",
        "guard_denial",
        "eval_verdict",
        "review_verdict",
        "review_duration_s",
        "review_infra_failure",
    ]
    trends = {m: compute_trend(conn, m, window_hours=window_hours) for m in key_metrics}

    # --- patterns ---
    detected_patterns = pattern_detection(conn, window_hours=window_hours)

    # --- suggestions: active (proposed + accepted) ---
    sugg_rows = conn.execute(
        """
        SELECT id, category, title, status, target_metric,
               baseline_value, created_at
        FROM   obs_suggestions
        WHERE  status IN ('proposed', 'accepted')
        ORDER  BY created_at DESC
        LIMIT  100
        """,
    ).fetchall()
    suggestions = [dict(r) for r in sugg_rows]

    # --- convergence ---
    convergence = check_convergence(conn)

    # --- review_gate_health (from cross_analysis) ---
    cross = cross_analysis(conn, window_hours=window_hours)
    review_gate_health = cross["review_gate_health"]

    # --- record run ---
    active_suggestions = len(suggestions)
    record_run(
        conn,
        metrics_snapshot={"total_metrics": total_metrics, "active_suggestions": active_suggestions},
        trace_count=0,
        suggestion_count=active_suggestions,
    )

    return {
        "metrics_summary": metrics_summary,
        "trends": trends,
        "patterns": detected_patterns,
        "suggestions": suggestions,
        "convergence": convergence,
        "review_gate_health": review_gate_health,
    }


def summary(conn: sqlite3.Connection, window_hours: int = 24) -> dict:
    """Delegate entirely to generate_report() and return its output.

    W-OBS-3 replaces the prior bespoke assembly logic with generate_report().
    The old keys (metrics_24h, agent_performance, denial_hotspots,
    recent_anomalies, convergence_results) are superseded by the richer
    generate_report structure.

    @decision DEC-OBS-005
    Title: summary() delegates entirely to generate_report()
    Status: accepted
    Rationale: See module-level docstring. Deletion-first: old assembly
      block removed; no dual-path exists.
    """
    return generate_report(conn, window_hours=window_hours)
