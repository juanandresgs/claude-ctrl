"""Worktree registry authority.

Owns the worktrees table. Tracks which worktrees are active (removed_at IS
NULL). remove() sets removed_at rather than deleting rows so history is
preserved.

@decision DEC-RT-001
Title: Canonical SQLite schema for all shared workflow state
Status: accepted
Rationale: worktrees replaces the computed `git worktree list` approach.
  Storing registration time and ticket association gives richer context than
  git metadata alone. removed_at soft-delete preserves history for audit
  without complicating list_active() (WHERE removed_at IS NULL).
"""

from __future__ import annotations

import sqlite3
import time
from typing import Optional


def register(
    conn: sqlite3.Connection,
    path: str,
    branch: str,
    ticket: Optional[str] = None,
) -> None:
    """Register a worktree path. If path already exists, update branch/ticket."""
    now = int(time.time())
    with conn:
        conn.execute(
            """
            INSERT INTO worktrees (path, branch, ticket, created_at, removed_at)
            VALUES (?, ?, ?, ?, NULL)
            ON CONFLICT(path) DO UPDATE SET
                branch     = excluded.branch,
                ticket     = excluded.ticket,
                removed_at = NULL
            """,
            (path, branch, ticket, now),
        )


def remove(conn: sqlite3.Connection, path: str) -> None:
    """Soft-delete a worktree by setting removed_at. No-op if not found."""
    now = int(time.time())
    with conn:
        conn.execute(
            "UPDATE worktrees SET removed_at = ? WHERE path = ?",
            (now, path),
        )


def list_active(conn: sqlite3.Connection) -> list[dict]:
    """Return all worktrees where removed_at IS NULL, ordered by created_at."""
    rows = conn.execute(
        """
        SELECT path, branch, ticket, created_at, removed_at
        FROM   worktrees
        WHERE  removed_at IS NULL
        ORDER  BY created_at DESC
        """
    ).fetchall()
    return [dict(r) for r in rows]
