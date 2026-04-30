"""Project-local scratchlane authority.

Owns the ``scratchlane_permits`` table. A scratchlane is a user-approved,
task-scoped artifact root under ``tmp/.claude-scratch/<task_slug>`` inside a
project checkout. Scratchlanes exist so the orchestrator may perform one-off
automation work (scripts, manifests, generated outputs) without being forced
into the source-write path.

The module is intentionally narrow:

  * SQLite stores only the permit state (approved roots and provenance).
  * Filesystem creation is a CLI concern; this module never writes directories.
  * The root path is canonical and deterministic: callers never choose an
    arbitrary absolute path outside the project-local scratch parent.

@decision DEC-SCRATCHLANE-001
Title: scratchlane_permits is the sole authority for task-local artifact roots
Status: accepted
Rationale: The control plane needs one mechanically checkable place that says
  "this task may write under this local scratch root". Reusing source/governance
  capabilities would overload the meaning of those authorities and would not
  express the user's per-task approval. A small SQLite table gives one durable
  authority for that approval without widening source-write permissions.
"""

from __future__ import annotations

import os
import sqlite3
import time
from typing import Optional

from runtime.core.policy_utils import (
    SCRATCHLANE_PARENT_REL,
    normalize_path,
    sanitize_token,
    scratchlane_root,
)


def grant(
    conn: sqlite3.Connection,
    project_root: str,
    task_slug: str,
    *,
    granted_by: str = "user",
    note: str = "",
) -> dict:
    """Create or refresh an active scratchlane permit for ``task_slug``."""
    canonical_project_root = normalize_path(project_root)
    slug = sanitize_token(task_slug)
    root_path = scratchlane_root(canonical_project_root, slug)
    now = int(time.time())

    with conn:
        conn.execute(
            """
            UPDATE scratchlane_permits
            SET    active = 0,
                   revoked_at = ?
            WHERE  project_root = ?
              AND  task_slug = ?
              AND  active = 1
            """,
            (now, canonical_project_root, slug),
        )
        conn.execute(
            """
            INSERT INTO scratchlane_permits
                (project_root, task_slug, root_path, granted_by, note,
                 created_at, active, revoked_at)
            VALUES (?, ?, ?, ?, ?, ?, 1, NULL)
            """,
            (canonical_project_root, slug, root_path, granted_by, note, now),
        )

    record = get_active(conn, canonical_project_root, slug)
    if record is None:
        raise RuntimeError("scratchlane grant was written but could not be read back")
    return record


def revoke(conn: sqlite3.Connection, project_root: str, task_slug: str) -> bool:
    """Deactivate the current scratchlane permit, if one exists."""
    canonical_project_root = normalize_path(project_root)
    slug = sanitize_token(task_slug)
    now = int(time.time())
    with conn:
        cursor = conn.execute(
            """
            UPDATE scratchlane_permits
            SET    active = 0,
                   revoked_at = ?
            WHERE  project_root = ?
              AND  task_slug = ?
              AND  active = 1
            """,
            (now, canonical_project_root, slug),
        )
    return cursor.rowcount > 0


def get_active(
    conn: sqlite3.Connection,
    project_root: str,
    task_slug: str,
) -> Optional[dict]:
    """Return the active scratchlane permit for ``task_slug``, or ``None``."""
    canonical_project_root = normalize_path(project_root)
    slug = sanitize_token(task_slug)
    row = conn.execute(
        """
        SELECT id, project_root, task_slug, root_path, granted_by, note, created_at
        FROM   scratchlane_permits
        WHERE  project_root = ?
          AND  task_slug = ?
          AND  active = 1
        ORDER  BY created_at DESC, id DESC
        LIMIT  1
        """,
        (canonical_project_root, slug),
    ).fetchone()
    return dict(row) if row else None


def list_active(
    conn: sqlite3.Connection,
    *,
    project_root: str | None = None,
) -> list[dict]:
    """Return active scratchlane permits, newest first."""
    if project_root is not None:
        canonical_project_root = normalize_path(project_root)
        rows = conn.execute(
            """
            SELECT id, project_root, task_slug, root_path, granted_by, note, created_at
            FROM   scratchlane_permits
            WHERE  active = 1
              AND  project_root = ?
            ORDER  BY created_at DESC, id DESC
            """,
            (canonical_project_root,),
        ).fetchall()
    else:
        rows = conn.execute(
            """
            SELECT id, project_root, task_slug, root_path, granted_by, note, created_at
            FROM   scratchlane_permits
            WHERE  active = 1
            ORDER  BY created_at DESC, id DESC
            """
        ).fetchall()
    return [dict(row) for row in rows]


def active_roots(conn: sqlite3.Connection, project_root: str) -> tuple[str, ...]:
    """Return the active scratchlane roots for ``project_root``."""
    items = list_active(conn, project_root=project_root)
    return tuple(str(item["root_path"]) for item in items)
