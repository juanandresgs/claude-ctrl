"""Unit tests for runtime.core.worktrees.

Tests the worktrees table domain module using an in-memory SQLite database.
Covers register/remove/list_active with soft-delete semantics.

@decision DEC-RT-001
Title: Canonical SQLite schema for all shared workflow state
Status: accepted
Rationale: worktrees uses a soft-delete (removed_at) pattern so history is
  preserved while list_active() stays cheap via WHERE removed_at IS NULL.
  Tests verify that remove() does not delete rows, that re-registering a
  removed path clears removed_at, and that list_active() filters correctly.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from runtime.core.db import connect_memory
from runtime.schemas import ensure_schema
import runtime.core.worktrees as worktrees


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


def test_list_active_empty(conn):
    assert worktrees.list_active(conn) == []


def test_register_and_list(conn):
    worktrees.register(conn, "/path/a", "feature/a", ticket="TKT-001")
    rows = worktrees.list_active(conn)
    assert len(rows) == 1
    assert rows[0]["path"] == "/path/a"
    assert rows[0]["branch"] == "feature/a"
    assert rows[0]["ticket"] == "TKT-001"
    assert rows[0]["removed_at"] is None


def test_register_without_ticket(conn):
    worktrees.register(conn, "/path/b", "feature/b")
    rows = worktrees.list_active(conn)
    assert rows[0]["ticket"] is None


def test_remove_soft_deletes(conn):
    worktrees.register(conn, "/path/a", "feature/a")
    worktrees.remove(conn, "/path/a")
    assert worktrees.list_active(conn) == []
    # Row still exists in the table
    row = conn.execute("SELECT removed_at FROM worktrees WHERE path='/path/a'").fetchone()
    assert row is not None
    assert row[0] is not None


def test_remove_nonexistent_is_noop(conn):
    worktrees.remove(conn, "/nonexistent")  # must not raise


def test_register_updates_existing(conn):
    worktrees.register(conn, "/path/a", "feature/a")
    worktrees.register(conn, "/path/a", "feature/a-v2", ticket="TKT-999")
    rows = worktrees.list_active(conn)
    assert len(rows) == 1
    assert rows[0]["branch"] == "feature/a-v2"
    assert rows[0]["ticket"] == "TKT-999"


def test_re_register_removed_path_clears_removed_at(conn):
    worktrees.register(conn, "/path/a", "feature/a")
    worktrees.remove(conn, "/path/a")
    assert worktrees.list_active(conn) == []
    worktrees.register(conn, "/path/a", "feature/a-reborn")
    rows = worktrees.list_active(conn)
    assert len(rows) == 1
    assert rows[0]["removed_at"] is None


def test_multiple_active_worktrees(conn):
    worktrees.register(conn, "/path/a", "feature/a")
    worktrees.register(conn, "/path/b", "feature/b")
    worktrees.register(conn, "/path/c", "feature/c")
    worktrees.remove(conn, "/path/b")
    rows = worktrees.list_active(conn)
    assert len(rows) == 2
    paths = {r["path"] for r in rows}
    assert paths == {"/path/a", "/path/c"}
