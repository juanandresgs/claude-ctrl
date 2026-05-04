# @decision DEC-PRESERVED-CONTEXT-DB-001 — compaction handoff context lives in SQLite
# Why: PreCompact context is runtime memory. Writing it to
# ``.claude/.preserved-context`` made compaction recovery depend on another
# durable project flatfile and one-time cleanup timing.
"""SQLite-backed pre-compaction context handoff."""

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


def _normalise_session_id(session_id: str) -> str:
    return str(session_id or "").strip()


def save(
    conn: sqlite3.Connection,
    *,
    project_root: str,
    session_id: str,
    context_text: str,
) -> dict:
    """Save or replace the unconsumed compaction handoff for a session."""

    root = _normalise_project_root(project_root)
    sid = _normalise_session_id(session_id)
    text = str(context_text or "").strip()
    if not text:
        raise ValueError("context_text must be non-empty")
    now = _now()
    with conn:
        conn.execute(
            """
            INSERT INTO preserved_contexts
                (project_root, session_id, context_text, created_at, consumed_at)
            VALUES (?, ?, ?, ?, NULL)
            ON CONFLICT(project_root, session_id) DO UPDATE SET
                context_text = excluded.context_text,
                created_at = excluded.created_at,
                consumed_at = NULL
            """,
            (root, sid, text, now),
        )
    return {
        "found": True,
        "project_root": root,
        "session_id": sid,
        "created_at": now,
        "consumed_at": None,
    }


def get(
    conn: sqlite3.Connection,
    *,
    project_root: str,
    session_id: str,
    include_consumed: bool = False,
) -> Optional[dict]:
    root = _normalise_project_root(project_root)
    sid = _normalise_session_id(session_id)
    consumed_clause = "" if include_consumed else "AND consumed_at IS NULL"
    row = conn.execute(
        f"""
        SELECT project_root, session_id, context_text, created_at, consumed_at
        FROM preserved_contexts
        WHERE project_root = ? AND session_id = ?
        {consumed_clause}
        """,
        (root, sid),
    ).fetchone()
    if row is None:
        return None
    result = dict(row)
    result["found"] = True
    return result


def consume(
    conn: sqlite3.Connection,
    *,
    project_root: str,
    session_id: str,
) -> Optional[dict]:
    """Consume the best matching unconsumed context for a project/session.

    Exact session id wins. If Claude Code changes the session id across
    compaction, the latest unconsumed project row is consumed as a recovery
    fallback instead of silently losing the handoff.
    """

    root = _normalise_project_root(project_root)
    sid = _normalise_session_id(session_id)
    row = conn.execute(
        """
        SELECT project_root, session_id, context_text, created_at, consumed_at
        FROM preserved_contexts
        WHERE project_root = ?
          AND consumed_at IS NULL
        ORDER BY CASE WHEN session_id = ? THEN 0 ELSE 1 END,
                 created_at DESC
        LIMIT 1
        """,
        (root, sid),
    ).fetchone()
    if row is None:
        return None
    result = dict(row)
    now = _now()
    with conn:
        conn.execute(
            """
            UPDATE preserved_contexts
            SET consumed_at = ?
            WHERE project_root = ? AND session_id = ?
            """,
            (now, result["project_root"], result["session_id"]),
        )
    result["found"] = True
    result["consumed_at"] = now
    return result
