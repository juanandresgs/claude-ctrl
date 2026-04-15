"""Unit tests for runtime.core.dispatch.

Tests the dispatch_queue and dispatch_cycles tables using an in-memory
SQLite database. Covers the full pending->active->done lifecycle plus
cycle management.

@decision DEC-RT-001
Title: Canonical SQLite schema for all shared workflow state
Status: accepted
Rationale: dispatch_queue uses a claim-execute-ack pattern: enqueue()
  creates a pending item, start() transitions it to active, complete()
  transitions it to done. next_pending() returns the oldest pending item
  (FIFO). Tests verify that state transitions only fire when the item is
  in the expected prior state (start only works on pending, complete only
  on active), preventing accidental double-transitions.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from runtime.core.db import connect_memory
from runtime.schemas import ensure_schema
import runtime.core.dispatch as dispatch


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


# --- Queue tests ---

def test_next_pending_empty_returns_none(conn):
    assert dispatch.next_pending(conn) is None


def test_enqueue_returns_integer_id(conn):
    qid = dispatch.enqueue(conn, "implementer")
    assert isinstance(qid, int)
    assert qid >= 1


def test_enqueue_and_next_pending(conn):
    qid = dispatch.enqueue(conn, "implementer", ticket="TKT-006")
    item = dispatch.next_pending(conn)
    assert item is not None
    assert item["id"] == qid
    assert item["role"] == "implementer"
    assert item["ticket"] == "TKT-006"
    assert item["status"] == "pending"


def test_start_transitions_to_active(conn):
    qid = dispatch.enqueue(conn, "reviewer")
    dispatch.start(conn, qid)
    # next_pending should now return None (item is no longer pending)
    assert dispatch.next_pending(conn) is None
    row = conn.execute("SELECT status, started_at FROM dispatch_queue WHERE id=?", (qid,)).fetchone()
    assert row[0] == "active"
    assert row[1] is not None


def test_complete_transitions_to_done(conn):
    qid = dispatch.enqueue(conn, "guardian")
    dispatch.start(conn, qid)
    dispatch.complete(conn, qid)
    row = conn.execute("SELECT status, completed_at FROM dispatch_queue WHERE id=?", (qid,)).fetchone()
    assert row[0] == "done"
    assert row[1] is not None


def test_start_only_affects_pending(conn):
    qid = dispatch.enqueue(conn, "implementer")
    dispatch.start(conn, qid)
    dispatch.complete(conn, qid)
    # start on already-done item is a no-op (WHERE status='pending' guard)
    dispatch.start(conn, qid)
    row = conn.execute("SELECT status FROM dispatch_queue WHERE id=?", (qid,)).fetchone()
    assert row[0] == "done"


def test_next_pending_is_fifo(conn):
    # Insert both, backdate id1 so created_at ordering is deterministic.
    id1 = dispatch.enqueue(conn, "planner")
    id2 = dispatch.enqueue(conn, "implementer")
    conn.execute("UPDATE dispatch_queue SET created_at = created_at - 10 WHERE id = ?", (id1,))
    conn.commit()
    item = dispatch.next_pending(conn)
    assert item["id"] == id1


def test_full_lifecycle_end_to_end(conn):
    """Exercises the real production sequence: enqueue -> next -> start -> complete."""
    qid = dispatch.enqueue(conn, "implementer", ticket="TKT-006")
    # Simulate orchestrator picking next pending
    item = dispatch.next_pending(conn)
    assert item["id"] == qid
    assert item["status"] == "pending"
    # Implementer starts work
    dispatch.start(conn, item["id"])
    assert dispatch.next_pending(conn) is None  # no more pending
    # Implementer completes
    dispatch.complete(conn, item["id"])
    row = conn.execute("SELECT status FROM dispatch_queue WHERE id=?", (qid,)).fetchone()
    assert row[0] == "done"


# --- Cycle tests ---

def test_current_cycle_empty_returns_none(conn):
    assert dispatch.current_cycle(conn) is None


def test_start_cycle_returns_id(conn):
    cid = dispatch.start_cycle(conn, "INIT-002")
    assert isinstance(cid, int)
    assert cid >= 1


def test_current_cycle_returns_active(conn):
    cid = dispatch.start_cycle(conn, "INIT-002")
    cycle = dispatch.current_cycle(conn)
    assert cycle is not None
    assert cycle["id"] == cid
    assert cycle["initiative"] == "INIT-002"
    assert cycle["status"] == "active"


def test_current_cycle_returns_most_recent(conn):
    # Insert both cycles, then backdate INIT-001 so ordering is deterministic
    # without relying on sub-second time differences (created_at is epoch int).
    cid1 = dispatch.start_cycle(conn, "INIT-001")
    cid2 = dispatch.start_cycle(conn, "INIT-002")
    conn.execute("UPDATE dispatch_cycles SET created_at = created_at - 10 WHERE id = ?", (cid1,))
    conn.commit()
    cycle = dispatch.current_cycle(conn)
    assert cycle["id"] == cid2
