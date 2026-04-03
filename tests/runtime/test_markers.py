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

import runtime.core.markers as markers
from runtime.core.db import connect_memory
from runtime.schemas import ensure_schema


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


# ---------------------------------------------------------------------------
# Schema migration tests — old-schema DB forward-compatibility
# ---------------------------------------------------------------------------


def _make_old_schema_conn():
    """Create an in-memory DB with the pre-TKT-STAB-A4 agent_markers schema.

    Replicates the schema installed in production DBs before the `status`
    column was added: has is_active and workflow_id but lacks status.
    """
    import sqlite3 as _sqlite3

    conn = _sqlite3.connect(":memory:")
    conn.row_factory = _sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    # Old DDL: no status column, but has workflow_id (from an earlier migration)
    conn.execute(
        """
        CREATE TABLE agent_markers (
            agent_id    TEXT    PRIMARY KEY,
            role        TEXT    NOT NULL,
            started_at  INTEGER NOT NULL,
            stopped_at  INTEGER,
            is_active   INTEGER NOT NULL DEFAULT 1,
            workflow_id TEXT
        )
        """
    )
    conn.commit()
    return conn


def test_ensure_schema_adds_status_to_old_db():
    """ensure_schema migrates an old DB that lacks the status column.

    Production sequence: old DB exists without status column; ensure_schema
    runs on startup; markers.expire_stale (which uses status) must then work.

    This is the compound-interaction test covering the real migration path:
      old schema → ensure_schema() → expire_stale() succeeds.
    """
    conn = _make_old_schema_conn()

    # Confirm status column is absent before migration
    try:
        conn.execute("SELECT status FROM agent_markers LIMIT 0")
        assert False, "Expected OperationalError — status should not exist yet"
    except Exception as exc:
        assert "no such column" in str(exc).lower()

    # Run the migration
    ensure_schema(conn)

    # Now the status column must exist and expire_stale must not raise
    conn.execute("SELECT status FROM agent_markers LIMIT 0")  # no exception

    import time

    now = int(time.time())
    # Insert a row directly using old-style columns (no status) to simulate a
    # row that existed before the migration — DEFAULT 'active' must fill it.
    conn.execute(
        "INSERT INTO agent_markers (agent_id, role, started_at, is_active)"
        " VALUES ('old-agent', 'implementer', ?, 1)",
        (now - 10800,),
    )
    conn.commit()

    # expire_stale references status — must succeed on the migrated DB
    count = markers.expire_stale(conn, ttl=7200, now=now)
    assert count == 1, f"Expected 1 expired, got {count}"
    assert markers.get_active(conn) is None


def test_ensure_schema_idempotent_on_new_db():
    """ensure_schema is a no-op for DBs that already have the status column."""
    c = connect_memory()
    ensure_schema(c)
    # Second call must not raise
    ensure_schema(c)
    # Column exists exactly once — verify via pragma
    cols = {row[1] for row in c.execute("PRAGMA table_info(agent_markers)").fetchall()}
    assert "status" in cols
    assert "workflow_id" in cols
    c.close()
