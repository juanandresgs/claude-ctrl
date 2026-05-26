"""Unit tests for runtime.core.proof.

Tests the proof_state table domain module in isolation using an in-memory
SQLite database. No subprocess or external dependencies.

@decision DEC-RT-001
Title: Canonical SQLite schema for all shared workflow state
Status: accepted
Rationale: Tests use in-memory SQLite (connect_memory()) so they never
  touch the user's real state.db. ensure_schema() is called on every
  fixture so tests are independent and idempotent.
"""

from __future__ import annotations

import time
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from runtime.core.db import connect_memory
from runtime.schemas import ensure_schema
import runtime.core.proof as proof


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


def test_get_missing_returns_none(conn):
    assert proof.get(conn, "nonexistent") is None


def test_set_and_get_round_trip(conn):
    proof.set_status(conn, "wf-1", "pending")
    row = proof.get(conn, "wf-1")
    assert row is not None
    assert row["workflow_id"] == "wf-1"
    assert row["status"] == "pending"
    assert row["updated_at"] > 0


def test_set_all_valid_statuses(conn):
    for status in ("idle", "pending", "verified"):
        proof.set_status(conn, f"wf-{status}", status)
        row = proof.get(conn, f"wf-{status}")
        assert row["status"] == status


def test_set_invalid_status_raises(conn):
    with pytest.raises(ValueError, match="unknown proof status"):
        proof.set_status(conn, "wf-bad", "invalid")


def test_upsert_updates_status(conn):
    proof.set_status(conn, "wf-1", "idle")
    proof.set_status(conn, "wf-1", "verified")
    row = proof.get(conn, "wf-1")
    assert row["status"] == "verified"


def test_list_all_empty(conn):
    assert proof.list_all(conn) == []


def test_list_all_returns_all_rows(conn):
    proof.set_status(conn, "wf-a", "idle")
    proof.set_status(conn, "wf-b", "pending")
    proof.set_status(conn, "wf-c", "verified")
    rows = proof.list_all(conn)
    assert len(rows) == 3
    ids = {r["workflow_id"] for r in rows}
    assert ids == {"wf-a", "wf-b", "wf-c"}


def test_list_all_ordered_by_updated_at_desc(conn):
    # Insert both rows, then backdate "wf-first" so ordering is deterministic
    # without relying on sub-second time differences (updated_at is epoch int).
    proof.set_status(conn, "wf-first", "idle")
    proof.set_status(conn, "wf-second", "pending")
    conn.execute("UPDATE proof_state SET updated_at = updated_at - 10 WHERE workflow_id = 'wf-first'")
    conn.commit()
    rows = proof.list_all(conn)
    assert rows[0]["workflow_id"] == "wf-second"
