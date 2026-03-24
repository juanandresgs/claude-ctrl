"""Unit tests for runtime.core.events.

Tests the events table domain module using an in-memory SQLite database.
Covers emit/query ordering, type filtering, time filtering, and limit.

@decision DEC-RT-001
Title: Canonical SQLite schema for all shared workflow state
Status: accepted
Rationale: The events table is append-only. Tests confirm AUTOINCREMENT
  ordering, type/since/limit query parameters, and that emit() returns
  a valid integer id. Ordering by id DESC means newest events come first
  in query results — matching the display convention for recent activity.
"""

from __future__ import annotations

import time
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from runtime.core.db import connect_memory
from runtime.schemas import ensure_schema
import runtime.core.events as events


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


def test_emit_returns_integer_id(conn):
    event_id = events.emit(conn, "test.event")
    assert isinstance(event_id, int)
    assert event_id >= 1


def test_emit_and_query_round_trip(conn):
    events.emit(conn, "probe.start", source="tkt-006", detail="started")
    rows = events.query(conn)
    assert len(rows) == 1
    assert rows[0]["type"] == "probe.start"
    assert rows[0]["source"] == "tkt-006"
    assert rows[0]["detail"] == "started"
    assert rows[0]["created_at"] > 0


def test_query_empty_returns_empty_list(conn):
    assert events.query(conn) == []


def test_query_type_filter(conn):
    events.emit(conn, "type.a")
    events.emit(conn, "type.b")
    events.emit(conn, "type.a")
    rows = events.query(conn, type="type.a")
    assert len(rows) == 2
    assert all(r["type"] == "type.a" for r in rows)


def test_query_returns_newest_first(conn):
    id1 = events.emit(conn, "evt")
    id2 = events.emit(conn, "evt")
    id3 = events.emit(conn, "evt")
    rows = events.query(conn)
    assert rows[0]["id"] == id3
    assert rows[-1]["id"] == id1


def test_query_limit(conn):
    for i in range(10):
        events.emit(conn, "evt")
    rows = events.query(conn, limit=3)
    assert len(rows) == 3


def test_query_since_filter(conn):
    before = int(time.time()) - 10
    events.emit(conn, "old.event")
    # Manipulate created_at directly to simulate an old event
    conn.execute("UPDATE events SET created_at = ? WHERE type = 'old.event'", (before - 100,))
    conn.commit()
    events.emit(conn, "new.event")
    rows = events.query(conn, since=before)
    assert len(rows) == 1
    assert rows[0]["type"] == "new.event"


def test_emit_optional_fields_none(conn):
    event_id = events.emit(conn, "bare.event")
    rows = events.query(conn)
    assert rows[0]["source"] is None
    assert rows[0]["detail"] is None
