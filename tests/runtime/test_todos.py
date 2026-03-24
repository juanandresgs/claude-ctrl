"""Unit tests for runtime.core.todos.

Tests the todo_state table domain module in isolation using an in-memory
SQLite database. No subprocess or external dependencies.

@decision DEC-RT-017
Title: todo_state table — project-scoped todo counts for statusline display
Status: accepted
Rationale: Todo counts are project-scoped (not session-scoped) because todos
  are a property of the project, not a single agent session. get_counts() returns
  zeroes when no row exists so the statusline never crashes on a fresh project.
  set_counts() uses INSERT OR REPLACE for idempotent upsert semantics.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from runtime.core.db import connect_memory
from runtime.schemas import ensure_schema
import runtime.core.todos as todos_mod


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


# ---------------------------------------------------------------------------
# set_counts / get_counts round-trip
# ---------------------------------------------------------------------------

def test_set_and_get_round_trip(conn):
    todos_mod.set_counts(conn, "proj-abc", project_count=3, global_count=10)
    result = todos_mod.get_counts(conn, "proj-abc")
    assert result["status"] == "ok"
    assert result["found"] is True
    assert result["project"] == 3
    assert result["global"] == 10


def test_get_missing_project_returns_zeros(conn):
    """Missing project hash returns zeros, not an error."""
    result = todos_mod.get_counts(conn, "nonexistent-hash")
    assert result["status"] == "ok"
    assert result["found"] is False
    assert result["project"] == 0
    assert result["global"] == 0


def test_set_replaces_existing(conn):
    """Second set_counts for same project replaces the first."""
    todos_mod.set_counts(conn, "proj-abc", 5, 15)
    todos_mod.set_counts(conn, "proj-abc", 2, 7)
    result = todos_mod.get_counts(conn, "proj-abc")
    assert result["project"] == 2
    assert result["global"] == 7


def test_zero_counts_stored_and_returned(conn):
    """Zero counts are valid and survive the round-trip."""
    todos_mod.set_counts(conn, "proj-zeros", 0, 0)
    result = todos_mod.get_counts(conn, "proj-zeros")
    assert result["found"] is True
    assert result["project"] == 0
    assert result["global"] == 0


def test_different_projects_isolated(conn):
    """Counts for project A do not affect project B."""
    todos_mod.set_counts(conn, "proj-aaa", 5, 20)
    todos_mod.set_counts(conn, "proj-bbb", 1, 3)
    result_a = todos_mod.get_counts(conn, "proj-aaa")
    result_b = todos_mod.get_counts(conn, "proj-bbb")
    assert result_a["project"] == 5
    assert result_a["global"] == 20
    assert result_b["project"] == 1
    assert result_b["global"] == 3


def test_set_counts_updates_updated_at(conn):
    """set_counts() writes a reasonable epoch timestamp to updated_at."""
    before = int(time.time())
    todos_mod.set_counts(conn, "proj-ts", 1, 1)
    after = int(time.time())
    row = conn.execute(
        "SELECT updated_at FROM todo_state WHERE project_hash=?",
        ("proj-ts",),
    ).fetchone()
    assert row is not None
    assert before <= row["updated_at"] <= after + 1


def test_get_returns_ok_status(conn):
    """get_counts() always returns status='ok', never raises."""
    result = todos_mod.get_counts(conn, "any-hash")
    assert result["status"] == "ok"
