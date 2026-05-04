# @decision DEC-ENFORCEMENT-GAPS-DB-001 — linter enforcement gaps live in state.db
# Why: The old .claude/.enforcement-gaps flatfile was both a write-path policy
# input and a startup prompt surface, creating a project-local authority outside
# the runtime database. This module makes enforcement gaps structured DB state.
"""Structured enforcement gap state.

An enforcement gap is a persistent runtime fact that write policies consume.
It therefore belongs in state.db, not in a project-local text file.
"""

from __future__ import annotations

import sqlite3
import time

from runtime.core.policy_utils import normalize_path

VALID_GAP_TYPES = frozenset({"unsupported", "missing_dep"})
OPEN_STATUS = "open"
RESOLVED_STATUS = "resolved"


def _now() -> int:
    return int(time.time())


def _root(project_root: str) -> str:
    value = str(project_root or "").strip()
    if not value:
        raise ValueError("project_root must be non-empty")
    return normalize_path(value)


def _gap_type(gap_type: str) -> str:
    value = str(gap_type or "").strip()
    if value not in VALID_GAP_TYPES:
        raise ValueError(f"gap_type must be one of {sorted(VALID_GAP_TYPES)}, got {gap_type!r}")
    return value


def _ext(ext: str) -> str:
    value = str(ext or "").strip().lstrip(".")
    if not value:
        raise ValueError("ext must be non-empty")
    return value


def record(
    conn: sqlite3.Connection,
    *,
    project_root: str,
    gap_type: str,
    ext: str,
    tool: str = "",
) -> dict:
    root = _root(project_root)
    typ = _gap_type(gap_type)
    extension = _ext(ext)
    tool_name = str(tool or "").strip()
    now = _now()
    with conn:
        conn.execute(
            """
            INSERT INTO enforcement_gaps
                (project_root, gap_type, ext, tool, first_seen_at, last_seen_at,
                 encounter_count, status, resolved_at)
            VALUES (?, ?, ?, ?, ?, ?, 1, ?, NULL)
            ON CONFLICT(project_root, gap_type, ext) DO UPDATE SET
                tool = excluded.tool,
                last_seen_at = excluded.last_seen_at,
                encounter_count = enforcement_gaps.encounter_count + 1,
                status = ?,
                resolved_at = NULL
            """,
            (root, typ, extension, tool_name, now, now, OPEN_STATUS, OPEN_STATUS),
        )
    return get(conn, project_root=root, gap_type=typ, ext=extension) or {"found": False}


def clear(
    conn: sqlite3.Connection,
    *,
    project_root: str,
    gap_type: str,
    ext: str,
) -> dict:
    root = _root(project_root)
    typ = _gap_type(gap_type)
    extension = _ext(ext)
    now = _now()
    with conn:
        cur = conn.execute(
            """
            UPDATE enforcement_gaps
            SET status = ?, resolved_at = ?, last_seen_at = ?
            WHERE project_root = ? AND gap_type = ? AND ext = ? AND status = ?
            """,
            (RESOLVED_STATUS, now, now, root, typ, extension, OPEN_STATUS),
        )
    row = get(conn, project_root=root, gap_type=typ, ext=extension)
    return {"found": row is not None, "cleared": cur.rowcount > 0, "gap": row}


def get(
    conn: sqlite3.Connection,
    *,
    project_root: str,
    gap_type: str,
    ext: str,
) -> dict | None:
    root = _root(project_root)
    typ = _gap_type(gap_type)
    extension = _ext(ext)
    row = conn.execute(
        """
        SELECT project_root, gap_type, ext, tool, first_seen_at, last_seen_at,
               encounter_count, status, resolved_at
        FROM enforcement_gaps
        WHERE project_root = ? AND gap_type = ? AND ext = ?
        """,
        (root, typ, extension),
    ).fetchone()
    if row is None:
        return None
    result = dict(row)
    result["found"] = True
    return result


def count(
    conn: sqlite3.Connection,
    *,
    project_root: str,
    gap_type: str,
    ext: str,
) -> int:
    row = get(conn, project_root=project_root, gap_type=gap_type, ext=ext)
    if row is None or row.get("status") != OPEN_STATUS:
        return 0
    return int(row.get("encounter_count") or 0)


def list_open(conn: sqlite3.Connection, *, project_root: str) -> list[dict]:
    root = _root(project_root)
    rows = conn.execute(
        """
        SELECT project_root, gap_type, ext, tool, first_seen_at, last_seen_at,
               encounter_count, status, resolved_at
        FROM enforcement_gaps
        WHERE project_root = ? AND status = ?
        ORDER BY last_seen_at DESC, ext ASC
        """,
        (root, OPEN_STATUS),
    ).fetchall()
    return [dict(row) for row in rows]
