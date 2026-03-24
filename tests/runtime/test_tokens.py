"""Unit tests for runtime.core.tokens.

Tests the session_tokens table domain module in isolation using an in-memory
SQLite database. No subprocess or external dependencies.

@decision DEC-RT-016
Title: session_tokens table — lifetime accumulation for project-scoped token budgets
Status: accepted
Rationale: Token counts are written per-session and summed project-wide for a
  lifetime view. upsert() is idempotent (INSERT OR REPLACE) so multiple writes
  from the same session converge on the most recent total. lifetime() sums across
  all sessions for the project so that switching sessions does not reset the display.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from runtime.core.db import connect_memory
from runtime.schemas import ensure_schema
import runtime.core.tokens as tokens_mod


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


# ---------------------------------------------------------------------------
# upsert / round-trip
# ---------------------------------------------------------------------------

def test_upsert_and_lifetime_round_trip(conn):
    tokens_mod.upsert(conn, "sess-1", "proj-abc", 50_000)
    result = tokens_mod.lifetime(conn, "proj-abc")
    assert result["status"] == "ok"
    assert result["total"] == 50_000


def test_upsert_replaces_same_session(conn):
    """Second upsert for same (session, project) replaces first — no double-count."""
    tokens_mod.upsert(conn, "sess-1", "proj-abc", 50_000)
    tokens_mod.upsert(conn, "sess-1", "proj-abc", 80_000)
    result = tokens_mod.lifetime(conn, "proj-abc")
    assert result["total"] == 80_000


def test_multiple_sessions_sum_correctly(conn):
    """Tokens from distinct sessions for the same project are summed."""
    tokens_mod.upsert(conn, "sess-1", "proj-abc", 100_000)
    tokens_mod.upsert(conn, "sess-2", "proj-abc", 200_000)
    tokens_mod.upsert(conn, "sess-3", "proj-abc", 50_000)
    result = tokens_mod.lifetime(conn, "proj-abc")
    assert result["total"] == 350_000


def test_lifetime_zero_for_unknown_project(conn):
    """Project with no sessions returns total=0, not an error."""
    result = tokens_mod.lifetime(conn, "unknown-hash")
    assert result["total"] == 0
    assert result["status"] == "ok"


def test_different_projects_isolated(conn):
    """Tokens for project A do not affect lifetime total for project B."""
    tokens_mod.upsert(conn, "sess-1", "proj-aaa", 100_000)
    tokens_mod.upsert(conn, "sess-2", "proj-bbb", 999_999)
    result_a = tokens_mod.lifetime(conn, "proj-aaa")
    result_b = tokens_mod.lifetime(conn, "proj-bbb")
    assert result_a["total"] == 100_000
    assert result_b["total"] == 999_999


def test_upsert_sets_updated_at(conn):
    """upsert() writes a reasonable epoch timestamp to updated_at."""
    before = int(time.time())
    tokens_mod.upsert(conn, "sess-ts", "proj-ts", 1_000)
    after = int(time.time())
    row = conn.execute(
        "SELECT updated_at FROM session_tokens WHERE session_id=? AND project_hash=?",
        ("sess-ts", "proj-ts"),
    ).fetchone()
    assert row is not None
    assert before <= row["updated_at"] <= after + 1


def test_lifetime_returns_ok_status(conn):
    """lifetime() always returns status='ok', never raises."""
    result = tokens_mod.lifetime(conn, "any-hash")
    assert result["status"] == "ok"
