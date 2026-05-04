# @decision DEC-SESSION-ACTIVITY-001 — session activity and changed-file tracking live in SQLite
# Why: Session changed-file flatfiles created a second authority beside state.db,
# which broke root scoping in worktree-heavy runs and made visibility dependent
# on cleanup timing. The runtime DB now owns prompt counts and changed files.
"""Session activity and changed-file tracking.

The rows here are lightweight telemetry/context, not dispatch authority. They
replace project-local ``.session-changes-*``, ``.prompt-count-*``, and
``.session-start-epoch`` files with state.db rows keyed by project root and
session id.
"""

from __future__ import annotations

import sqlite3
import time
from typing import Optional

from runtime.core.policy_utils import normalize_path


def _now() -> int:
    return int(time.time())


def _normalise_session_id(session_id: str) -> str:
    value = str(session_id or "").strip()
    if not value:
        raise ValueError("session_id must be non-empty")
    return value


def _normalise_project_root(project_root: str) -> str:
    value = str(project_root or "").strip()
    if not value:
        raise ValueError("project_root must be non-empty")
    return normalize_path(value)


def touch_prompt(
    conn: sqlite3.Connection,
    *,
    project_root: str,
    session_id: str,
) -> dict:
    """Increment prompt count and create the session row if needed."""

    root = _normalise_project_root(project_root)
    sid = _normalise_session_id(session_id)
    now = _now()
    with conn:
        conn.execute(
            """
            INSERT INTO session_activity
                (session_id, project_root, prompt_count, started_at, updated_at)
            VALUES (?, ?, 1, ?, ?)
            ON CONFLICT(session_id, project_root) DO UPDATE SET
                prompt_count = session_activity.prompt_count + 1,
                updated_at = excluded.updated_at,
                ended_at = NULL
            """,
            (sid, root, now, now),
        )
    return get(conn, project_root=root, session_id=sid) or {"found": False}


def end(
    conn: sqlite3.Connection,
    *,
    project_root: str,
    session_id: str,
) -> dict:
    """Mark a session ended without deleting its telemetry."""

    root = _normalise_project_root(project_root)
    sid = _normalise_session_id(session_id)
    now = _now()
    with conn:
        conn.execute(
            """
            INSERT INTO session_activity
                (session_id, project_root, prompt_count, started_at, updated_at, ended_at)
            VALUES (?, ?, 0, ?, ?, ?)
            ON CONFLICT(session_id, project_root) DO UPDATE SET
                updated_at = excluded.updated_at,
                ended_at = excluded.ended_at
            """,
            (sid, root, now, now, now),
        )
    return get(conn, project_root=root, session_id=sid) or {"found": False}


def get(
    conn: sqlite3.Connection,
    *,
    project_root: str,
    session_id: str,
) -> Optional[dict]:
    root = _normalise_project_root(project_root)
    sid = _normalise_session_id(session_id)
    row = conn.execute(
        """
        SELECT session_id, project_root, prompt_count, started_at, updated_at, ended_at
        FROM session_activity
        WHERE session_id = ? AND project_root = ?
        """,
        (sid, root),
    ).fetchone()
    if row is None:
        return None
    result = dict(row)
    result["found"] = True
    return result


def record_file_change(
    conn: sqlite3.Connection,
    *,
    project_root: str,
    session_id: str,
    file_path: str,
) -> dict:
    """Upsert a changed file for the current session."""

    root = _normalise_project_root(project_root)
    sid = _normalise_session_id(session_id)
    path = str(file_path or "").strip()
    if not path:
        raise ValueError("file_path must be non-empty")
    canonical_path = normalize_path(path)
    now = _now()
    with conn:
        conn.execute(
            """
            INSERT INTO session_file_changes
                (session_id, project_root, file_path, first_seen_at, last_seen_at, change_count)
            VALUES (?, ?, ?, ?, ?, 1)
            ON CONFLICT(session_id, project_root, file_path) DO UPDATE SET
                last_seen_at = excluded.last_seen_at,
                change_count = session_file_changes.change_count + 1
            """,
            (sid, root, canonical_path, now, now),
        )
        conn.execute(
            """
            INSERT INTO session_activity
                (session_id, project_root, prompt_count, started_at, updated_at)
            VALUES (?, ?, 0, ?, ?)
            ON CONFLICT(session_id, project_root) DO UPDATE SET
                updated_at = excluded.updated_at,
                ended_at = NULL
            """,
            (sid, root, now, now),
        )
    return list_file_changes(conn, project_root=root, session_id=sid)


def list_file_changes(
    conn: sqlite3.Connection,
    *,
    project_root: str,
    session_id: str,
    limit: int = 0,
) -> dict:
    root = _normalise_project_root(project_root)
    sid = _normalise_session_id(session_id)
    params: list[object] = [sid, root]
    limit_clause = ""
    if limit and limit > 0:
        limit_clause = " LIMIT ?"
        params.append(int(limit))
    rows = conn.execute(
        f"""
        SELECT file_path, first_seen_at, last_seen_at, change_count
        FROM session_file_changes
        WHERE session_id = ? AND project_root = ?
        ORDER BY file_path ASC{limit_clause}
        """,
        tuple(params),
    ).fetchall()
    items = [dict(row) for row in rows]
    total = conn.execute(
        """
        SELECT COUNT(*) AS count
        FROM session_file_changes
        WHERE session_id = ? AND project_root = ?
        """,
        (sid, root),
    ).fetchone()
    return {
        "found": bool(items),
        "session_id": sid,
        "project_root": root,
        "items": items,
        "count": int(total["count"] if total else len(items)),
    }
