"""Dispatch queue and cycle authority.

Owns dispatch_queue and dispatch_cycles tables. The queue tracks individual
role-based work items (pending -> active -> done/skipped). Cycles group a
set of queue items under a named initiative.

@decision DEC-RT-001
Title: Canonical SQLite schema for all shared workflow state
Status: accepted
Rationale: dispatch_queue and dispatch_cycles replace the purely social
  prompt-driven dispatch lifecycle (prior to INIT-002 there was no
  persistent queue). current_cycle() returns the most recent active cycle
  so callers don't need to track cycle IDs externally. next_pending() and
  start()/complete() form the claim-execute-ack pattern: one pending item
  transitions to active, then to done in explicit separate calls.
"""

from __future__ import annotations

import sqlite3
import time
from typing import Optional

from runtime.schemas import DISPATCH_QUEUE_STATUSES


def enqueue(
    conn: sqlite3.Connection,
    role: str,
    ticket: Optional[str] = None,
) -> int:
    """Insert a pending queue item and return its id."""
    now = int(time.time())
    with conn:
        cur = conn.execute(
            """
            INSERT INTO dispatch_queue (role, status, ticket, created_at)
            VALUES (?, 'pending', ?, ?)
            """,
            (role, ticket, now),
        )
    return cur.lastrowid


def next_pending(conn: sqlite3.Connection) -> Optional[dict]:
    """Return the oldest pending item, or None if the queue is empty."""
    row = conn.execute(
        """
        SELECT id, role, status, ticket, created_at, started_at, completed_at
        FROM   dispatch_queue
        WHERE  status = 'pending'
        ORDER  BY created_at ASC
        LIMIT  1
        """
    ).fetchone()
    return dict(row) if row else None


def start(conn: sqlite3.Connection, queue_id: int) -> None:
    """Transition a pending item to active. No-op if already active/done."""
    now = int(time.time())
    with conn:
        conn.execute(
            """
            UPDATE dispatch_queue
            SET    status     = 'active',
                   started_at = ?
            WHERE  id     = ?
              AND  status = 'pending'
            """,
            (now, queue_id),
        )


def complete(conn: sqlite3.Connection, queue_id: int) -> None:
    """Transition an active item to done."""
    now = int(time.time())
    with conn:
        conn.execute(
            """
            UPDATE dispatch_queue
            SET    status       = 'done',
                   completed_at = ?
            WHERE  id     = ?
              AND  status = 'active'
            """,
            (now, queue_id),
        )


def current_cycle(conn: sqlite3.Connection) -> Optional[dict]:
    """Return the most recently created active cycle, or None."""
    row = conn.execute(
        """
        SELECT id, initiative, status, created_at, completed_at
        FROM   dispatch_cycles
        WHERE  status = 'active'
        ORDER  BY created_at DESC
        LIMIT  1
        """
    ).fetchone()
    return dict(row) if row else None


def start_cycle(conn: sqlite3.Connection, initiative: str) -> int:
    """Create a new active dispatch cycle and return its id."""
    now = int(time.time())
    with conn:
        cur = conn.execute(
            """
            INSERT INTO dispatch_cycles (initiative, status, created_at)
            VALUES (?, 'active', ?)
            """,
            (initiative, now),
        )
    return cur.lastrowid
