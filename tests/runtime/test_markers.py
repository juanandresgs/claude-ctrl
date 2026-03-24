"""Unit tests for runtime.core.markers.

Tests the agent_markers table domain module using an in-memory SQLite
database. Covers set_active/get_active/deactivate/list_all round-trips.

@decision DEC-RT-001
Title: Canonical SQLite schema for all shared workflow state
Status: accepted
Rationale: agent_markers replaces the .subagent-tracker flat file.
  Tests confirm the is_active flag and stopped_at timestamp are managed
  correctly through the full lifecycle: set -> get-active -> deactivate.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from runtime.core.db import connect_memory
from runtime.schemas import ensure_schema
import runtime.core.markers as markers


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


def test_get_active_empty_returns_none(conn):
    assert markers.get_active(conn) is None


def test_set_active_and_get_active(conn):
    markers.set_active(conn, "agent-1", "implementer")
    row = markers.get_active(conn)
    assert row is not None
    assert row["agent_id"] == "agent-1"
    assert row["role"] == "implementer"
    assert row["is_active"] == 1
    assert row["stopped_at"] is None


def test_deactivate_clears_is_active(conn):
    markers.set_active(conn, "agent-1", "implementer")
    markers.deactivate(conn, "agent-1")
    assert markers.get_active(conn) is None


def test_deactivate_sets_stopped_at(conn):
    markers.set_active(conn, "agent-1", "implementer")
    markers.deactivate(conn, "agent-1")
    all_rows = markers.list_all(conn)
    assert len(all_rows) == 1
    assert all_rows[0]["stopped_at"] is not None
    assert all_rows[0]["is_active"] == 0


def test_deactivate_nonexistent_is_noop(conn):
    markers.deactivate(conn, "nobody")  # must not raise


def test_set_active_upserts_existing(conn):
    markers.set_active(conn, "agent-1", "implementer")
    markers.set_active(conn, "agent-1", "tester")
    row = markers.get_active(conn)
    assert row["role"] == "tester"
    assert row["is_active"] == 1
    # Only one row for agent-1
    assert len(markers.list_all(conn)) == 1


def test_get_active_returns_most_recent(conn):
    # Insert both, then backdate agent-1 so ordering is deterministic
    # without relying on sub-second time differences (started_at is epoch int).
    markers.set_active(conn, "agent-1", "implementer")
    markers.set_active(conn, "agent-2", "tester")
    conn.execute("UPDATE agent_markers SET started_at = started_at - 10 WHERE agent_id = 'agent-1'")
    conn.commit()
    row = markers.get_active(conn)
    assert row["agent_id"] == "agent-2"


def test_list_all_returns_all_markers(conn):
    markers.set_active(conn, "agent-1", "implementer")
    markers.set_active(conn, "agent-2", "tester")
    rows = markers.list_all(conn)
    assert len(rows) == 2
    ids = {r["agent_id"] for r in rows}
    assert ids == {"agent-1", "agent-2"}
