"""v6 Guardian landing readiness aggregate.

This module collapses reviewer readiness, tests, scope, head SHA, lease, and
worktree binding into one v6 row keyed by the guardian:land stage run. Legacy
policy tables remain evidence sources; this row is the landing authority.
"""

from __future__ import annotations

import json
import sqlite3
import time
from typing import Optional

from runtime.core import stage_machine, stage_runs, test_state, workflows


def _now() -> int:
    return int(time.time())


def _json_dumps(value: object) -> str:
    return json.dumps(value if value is not None else {}, sort_keys=True)


def _json_loads(raw: str | None, default):
    if not raw:
        return default
    try:
        return json.loads(raw)
    except (TypeError, json.JSONDecodeError):
        return default


def _row_to_dict(row: sqlite3.Row | None) -> Optional[dict]:
    if row is None:
        return None
    d = dict(row)
    d["missing"] = _json_loads(d.get("missing_json"), [])
    d["evidence"] = _json_loads(d.get("evidence_json"), {})
    return d


def get(conn: sqlite3.Connection, guardian_stage_run_id: str) -> Optional[dict]:
    row = conn.execute(
        "SELECT * FROM v6_landing_readiness WHERE guardian_stage_run_id = ?",
        (guardian_stage_run_id,),
    ).fetchone()
    return _row_to_dict(row)


def latest_for_workflow(conn: sqlite3.Connection, workflow_id: str) -> Optional[dict]:
    row = conn.execute(
        """
        SELECT * FROM v6_landing_readiness
        WHERE workflow_id = ?
        ORDER BY updated_at DESC
        LIMIT 1
        """,
        (workflow_id,),
    ).fetchone()
    return _row_to_dict(row)


def assert_ready(conn: sqlite3.Connection, guardian_stage_run_id: str) -> dict:
    readiness = get(conn, guardian_stage_run_id)
    if not readiness:
        raise ValueError(f"no v6 landing readiness row for guardian stage_run_id={guardian_stage_run_id}")
    if readiness.get("status") != "ready":
        raise ValueError(
            f"v6 landing readiness is {readiness.get('status')}; missing={readiness.get('missing', [])}"
        )
    return readiness


def ensure_for_guardian_stage(conn: sqlite3.Connection, guardian_stage_run_id: str) -> dict:
    guardian = stage_runs.get_stage_run(conn, guardian_stage_run_id)
    if not guardian:
        raise ValueError(f"stage_run_id not found: {guardian_stage_run_id}")
    if guardian["stage_id"] != stage_machine.GUARDIAN_LAND:
        raise ValueError(f"landing readiness requires guardian:land stage, got {guardian['stage_id']!r}")

    reviewer_id = str(guardian.get("parent_run_id") or "")
    reviewer = stage_runs.get_stage_run(conn, reviewer_id) if reviewer_id else None
    missing: list[str] = []
    evidence: dict = {"guardian_stage_run": guardian, "reviewer_stage_run": reviewer}

    if not reviewer or reviewer.get("stage_id") != stage_machine.REVIEWER:
        missing.append("reviewer_parent_stage_run")
        reviewer_payload = {}
    else:
        reviewer_payload = reviewer.get("result") or _json_loads(reviewer.get("result_json"), {})
        if reviewer.get("status") != "completed":
            missing.append("reviewer_stage_completed")
        if reviewer_payload.get("verdict") != "ready_for_guardian":
            missing.append("reviewer_ready_for_guardian")

    head_sha = str(reviewer_payload.get("head_sha") or "")
    if not head_sha:
        missing.append("reviewer_head_sha")

    workflow_id = guardian["workflow_id"]
    worktree_path = guardian.get("worktree_path") or ""
    binding = workflows.get_binding(conn, workflow_id)
    evidence["binding"] = binding
    if not binding:
        missing.append("workflow_binding")
    else:
        bound_path = binding.get("worktree_path") or ""
        if not worktree_path:
            worktree_path = bound_path
        if worktree_path and bound_path and worktree_path != bound_path:
            missing.append("worktree_binding_match")

    scope = workflows.get_scope(conn, workflow_id)
    evidence["scope"] = scope
    if not scope:
        missing.append("workflow_scope")

    ts = test_state.get_status(conn, worktree_path) if worktree_path else {"found": False, "status": "unknown"}
    evidence["test_state"] = ts
    if not ts.get("found"):
        missing.append("test_state")
    elif ts.get("status") not in {"pass", "pass_complete"}:
        missing.append("tests_pass")
    elif head_sha and ts.get("head_sha") and not _sha_prefix_match(str(ts.get("head_sha")), head_sha):
        missing.append("test_head_sha_match")

    lease = _active_guardian_lease(conn, workflow_id, worktree_path)
    evidence["guardian_lease"] = lease
    if not lease:
        missing.append("guardian_lease")
    else:
        metadata = _json_loads(lease.get("metadata_json"), {})
        lease_stage = metadata.get("stage_run_id") if isinstance(metadata, dict) else ""
        if lease_stage and lease_stage != guardian_stage_run_id:
            missing.append("guardian_lease_stage_run_match")

    status = "ready" if not missing else "blocked"
    now = _now()
    with conn:
        conn.execute(
            """
            INSERT INTO v6_landing_readiness (
                guardian_stage_run_id, reviewer_stage_run_id, workflow_id,
                status, head_sha, worktree_path, missing_json, evidence_json,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(guardian_stage_run_id) DO UPDATE SET
                reviewer_stage_run_id = excluded.reviewer_stage_run_id,
                workflow_id = excluded.workflow_id,
                status = excluded.status,
                head_sha = excluded.head_sha,
                worktree_path = excluded.worktree_path,
                missing_json = excluded.missing_json,
                evidence_json = excluded.evidence_json,
                updated_at = excluded.updated_at
            """,
            (
                guardian_stage_run_id,
                reviewer_id or "",
                workflow_id,
                status,
                head_sha,
                worktree_path,
                _json_dumps(missing),
                _json_dumps(evidence),
                now,
                now,
            ),
        )
    return get(conn, guardian_stage_run_id) or {}


def invalidate_for_workflow(conn: sqlite3.Connection, workflow_id: str, reason: str = "source_changed") -> int:
    now = _now()
    rows = conn.execute(
        "SELECT guardian_stage_run_id, missing_json FROM v6_landing_readiness WHERE workflow_id = ? AND status = 'ready'",
        (workflow_id,),
    ).fetchall()
    count = 0
    with conn:
        for row in rows:
            missing = _json_loads(row["missing_json"], [])
            if reason not in missing:
                missing.append(reason)
            conn.execute(
                """
                UPDATE v6_landing_readiness
                SET status = 'blocked', missing_json = ?, updated_at = ?
                WHERE guardian_stage_run_id = ?
                """,
                (_json_dumps(missing), now, row["guardian_stage_run_id"]),
            )
            count += 1
    return count


def _active_guardian_lease(conn: sqlite3.Connection, workflow_id: str, worktree_path: str) -> Optional[dict]:
    row = conn.execute(
        """
        SELECT * FROM dispatch_leases
        WHERE workflow_id = ? AND role = 'guardian' AND status = 'active'
          AND (? = '' OR worktree_path = ?)
        ORDER BY issued_at DESC
        LIMIT 1
        """,
        (workflow_id, worktree_path, worktree_path),
    ).fetchone()
    return dict(row) if row else None


def _sha_prefix_match(a: str, b: str) -> bool:
    a = str(a or "")
    b = str(b or "")
    if len(a) == 40 and len(b) == 40:
        return a.lower() == b.lower()
    if min(len(a), len(b)) < 12:
        return False
    return bool(a and b and (a.lower().startswith(b.lower()) or b.lower().startswith(a.lower())))
