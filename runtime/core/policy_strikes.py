# @decision DEC-POLICY-STRIKES-DB-001 — escalating policy strike counters live in SQLite
# Why: test_gate_pretool and mock_gate used project-local strike flatfiles for
# warning-then-deny behavior. Strike counters are policy state and must share
# the same state.db authority as the facts those policies evaluate.
"""SQLite-backed escalating policy strike counters."""

from __future__ import annotations

import sqlite3
import time
from typing import Optional

from runtime.core.policy_utils import normalize_path


def _now() -> int:
    return int(time.time())


def _normalise_project_root(project_root: str) -> str:
    value = str(project_root or "").strip()
    if not value:
        raise ValueError("project_root must be non-empty")
    return normalize_path(value)


def _normalise_token(value: str, field: str) -> str:
    token = str(value or "").strip()
    if not token:
        raise ValueError(f"{field} must be non-empty")
    return token


def key(policy_name: str, scope_key: str) -> str:
    return f"{policy_name}:{scope_key}"


def get(
    conn: sqlite3.Connection,
    *,
    project_root: str,
    policy_name: str,
    scope_key: str,
) -> Optional[dict]:
    root = _normalise_project_root(project_root)
    policy = _normalise_token(policy_name, "policy_name")
    scope = _normalise_token(scope_key, "scope_key")
    row = conn.execute(
        """
        SELECT project_root, policy_name, scope_key, count, updated_at
        FROM policy_strikes
        WHERE project_root = ? AND policy_name = ? AND scope_key = ?
        """,
        (root, policy, scope),
    ).fetchone()
    if row is None:
        return None
    result = dict(row)
    result["found"] = True
    result["key"] = key(policy, scope)
    return result


def list_for_project(conn: sqlite3.Connection, *, project_root: str) -> dict[str, dict]:
    root = _normalise_project_root(project_root)
    rows = conn.execute(
        """
        SELECT project_root, policy_name, scope_key, count, updated_at
        FROM policy_strikes
        WHERE project_root = ?
        """,
        (root,),
    ).fetchall()
    result: dict[str, dict] = {}
    for row in rows:
        item = dict(row)
        item["found"] = True
        item["key"] = key(str(item["policy_name"]), str(item["scope_key"]))
        result[str(item["key"])] = item
    return result


def set_count(
    conn: sqlite3.Connection,
    *,
    project_root: str,
    policy_name: str,
    scope_key: str,
    count: int,
) -> dict:
    root = _normalise_project_root(project_root)
    policy = _normalise_token(policy_name, "policy_name")
    scope = _normalise_token(scope_key, "scope_key")
    next_count = max(0, int(count or 0))
    now = _now()
    with conn:
        if next_count <= 0:
            conn.execute(
                """
                DELETE FROM policy_strikes
                WHERE project_root = ? AND policy_name = ? AND scope_key = ?
                """,
                (root, policy, scope),
            )
        else:
            conn.execute(
                """
                INSERT INTO policy_strikes
                    (project_root, policy_name, scope_key, count, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(project_root, policy_name, scope_key) DO UPDATE SET
                    count = excluded.count,
                    updated_at = excluded.updated_at
                """,
                (root, policy, scope, next_count, now),
            )
    return {
        "found": next_count > 0,
        "project_root": root,
        "policy_name": policy,
        "scope_key": scope,
        "key": key(policy, scope),
        "count": next_count,
        "updated_at": now,
    }
