"""Unit tests for runtime.core.traces.

Tests the traces and trace_manifest tables domain module using an
in-memory SQLite database.

Covers:
- start_trace / end_trace round-trip
- add_manifest_entry recording
- get_trace with manifest
- recent_traces ordering
- compound interaction: full session lifecycle from start through manifest
  entries to close, then queried by recent_traces and get_trace

@decision DEC-TRACE-001
Title: Trace-lite uses dedicated tables, not the events table
Status: accepted
Rationale: TKT-013 spec provides dedicated `traces` and `trace_manifest`
  tables rather than overloading the existing `events` table. This keeps
  the trace domain independently queryable without post-hoc type filtering,
  and makes the schema self-documenting. DEC-FORK-013 explicitly notes
  that trace artifacts are evidence and recovery material only — no control
  decision may depend on them — so a lightweight, append-friendly schema
  is correct here.
"""

from __future__ import annotations

import time
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from runtime.core.db import connect_memory
from runtime.schemas import ensure_schema
import runtime.core.traces as traces


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


# ---------------------------------------------------------------------------
# start_trace
# ---------------------------------------------------------------------------

def test_start_trace_returns_session_id(conn):
    sid = traces.start_trace(conn, "sess-001")
    assert sid == "sess-001"


def test_start_trace_with_role_and_ticket(conn):
    traces.start_trace(conn, "sess-002", agent_role="implementer", ticket="TKT-013")
    row = conn.execute(
        "SELECT * FROM traces WHERE session_id = ?", ("sess-002",)
    ).fetchone()
    assert row is not None
    assert dict(row)["agent_role"] == "implementer"
    assert dict(row)["ticket"] == "TKT-013"


def test_start_trace_sets_started_at(conn):
    before = int(time.time())
    traces.start_trace(conn, "sess-003")
    after = int(time.time())
    row = dict(conn.execute(
        "SELECT started_at FROM traces WHERE session_id = ?", ("sess-003",)
    ).fetchone())
    assert before <= row["started_at"] <= after


def test_start_trace_null_role_and_ticket_by_default(conn):
    traces.start_trace(conn, "sess-004")
    row = dict(conn.execute(
        "SELECT agent_role, ticket FROM traces WHERE session_id = ?", ("sess-004",)
    ).fetchone())
    assert row["agent_role"] is None
    assert row["ticket"] is None


# ---------------------------------------------------------------------------
# end_trace
# ---------------------------------------------------------------------------

def test_end_trace_sets_ended_at(conn):
    traces.start_trace(conn, "sess-010")
    before = int(time.time())
    traces.end_trace(conn, "sess-010")
    after = int(time.time())
    row = dict(conn.execute(
        "SELECT ended_at FROM traces WHERE session_id = ?", ("sess-010",)
    ).fetchone())
    assert row["ended_at"] is not None
    assert before <= row["ended_at"] <= after


def test_end_trace_with_summary(conn):
    traces.start_trace(conn, "sess-011")
    traces.end_trace(conn, "sess-011", summary="Implemented TKT-013 trace domain")
    row = dict(conn.execute(
        "SELECT summary FROM traces WHERE session_id = ?", ("sess-011",)
    ).fetchone())
    assert row["summary"] == "Implemented TKT-013 trace domain"


def test_end_trace_without_summary_leaves_null(conn):
    traces.start_trace(conn, "sess-012")
    traces.end_trace(conn, "sess-012")
    row = dict(conn.execute(
        "SELECT summary FROM traces WHERE session_id = ?", ("sess-012",)
    ).fetchone())
    assert row["summary"] is None


# ---------------------------------------------------------------------------
# add_manifest_entry
# ---------------------------------------------------------------------------

def test_add_manifest_entry_file_write(conn):
    traces.start_trace(conn, "sess-020")
    traces.add_manifest_entry(
        conn, "sess-020", "file_write",
        path="runtime/core/traces.py",
        detail="created new domain module"
    )
    rows = conn.execute(
        "SELECT * FROM trace_manifest WHERE session_id = ?", ("sess-020",)
    ).fetchall()
    assert len(rows) == 1
    entry = dict(rows[0])
    assert entry["entry_type"] == "file_write"
    assert entry["path"] == "runtime/core/traces.py"
    assert entry["detail"] == "created new domain module"
    assert entry["created_at"] > 0


def test_add_manifest_entry_multiple_types(conn):
    traces.start_trace(conn, "sess-021")
    traces.add_manifest_entry(conn, "sess-021", "file_read", path="runtime/schemas.py")
    traces.add_manifest_entry(conn, "sess-021", "decision", detail="DEC-TRACE-001 accepted")
    traces.add_manifest_entry(conn, "sess-021", "command", detail="python3 -m pytest")
    traces.add_manifest_entry(conn, "sess-021", "event", detail="schema ensured")

    rows = conn.execute(
        "SELECT entry_type FROM trace_manifest WHERE session_id = ? ORDER BY created_at",
        ("sess-021",)
    ).fetchall()
    types = [dict(r)["entry_type"] for r in rows]
    assert types == ["file_read", "decision", "command", "event"]


def test_add_manifest_entry_sets_created_at(conn):
    traces.start_trace(conn, "sess-022")
    before = int(time.time())
    traces.add_manifest_entry(conn, "sess-022", "command", detail="test cmd")
    after = int(time.time())
    row = dict(conn.execute(
        "SELECT created_at FROM trace_manifest WHERE session_id = ?", ("sess-022",)
    ).fetchone())
    assert before <= row["created_at"] <= after


def test_add_manifest_entry_optional_path_and_detail(conn):
    traces.start_trace(conn, "sess-023")
    traces.add_manifest_entry(conn, "sess-023", "event")
    row = dict(conn.execute(
        "SELECT path, detail FROM trace_manifest WHERE session_id = ?", ("sess-023",)
    ).fetchone())
    assert row["path"] is None
    assert row["detail"] is None


# ---------------------------------------------------------------------------
# get_trace
# ---------------------------------------------------------------------------

def test_get_trace_returns_none_for_unknown(conn):
    result = traces.get_trace(conn, "does-not-exist")
    assert result is None


def test_get_trace_returns_trace_with_empty_manifest(conn):
    traces.start_trace(conn, "sess-030", agent_role="reviewer", ticket="TKT-013")
    result = traces.get_trace(conn, "sess-030")
    assert result is not None
    assert result["session_id"] == "sess-030"
    assert result["agent_role"] == "reviewer"
    assert result["ticket"] == "TKT-013"
    assert result["manifest"] == []


def test_get_trace_includes_manifest_in_created_at_order(conn):
    traces.start_trace(conn, "sess-031")
    traces.add_manifest_entry(conn, "sess-031", "file_read", path="a.py")
    traces.add_manifest_entry(conn, "sess-031", "file_write", path="b.py")
    traces.add_manifest_entry(conn, "sess-031", "decision", detail="chose X")

    result = traces.get_trace(conn, "sess-031")
    assert len(result["manifest"]) == 3
    assert result["manifest"][0]["entry_type"] == "file_read"
    assert result["manifest"][1]["entry_type"] == "file_write"
    assert result["manifest"][2]["entry_type"] == "decision"


def test_get_trace_after_end_has_ended_at_and_summary(conn):
    traces.start_trace(conn, "sess-032")
    traces.end_trace(conn, "sess-032", summary="all done")
    result = traces.get_trace(conn, "sess-032")
    assert result["ended_at"] is not None
    assert result["summary"] == "all done"


# ---------------------------------------------------------------------------
# recent_traces
# ---------------------------------------------------------------------------

def test_recent_traces_empty(conn):
    result = traces.recent_traces(conn)
    assert result == []


def test_recent_traces_ordering(conn):
    # Insert three traces with forced distinct started_at values
    traces.start_trace(conn, "sess-040")
    traces.start_trace(conn, "sess-041")
    traces.start_trace(conn, "sess-042")

    # Force distinct timestamps to make ordering assertion deterministic
    conn.execute("UPDATE traces SET started_at = 100 WHERE session_id = 'sess-040'")
    conn.execute("UPDATE traces SET started_at = 200 WHERE session_id = 'sess-041'")
    conn.execute("UPDATE traces SET started_at = 300 WHERE session_id = 'sess-042'")
    conn.commit()

    result = traces.recent_traces(conn)
    assert len(result) == 3
    assert result[0]["session_id"] == "sess-042"
    assert result[1]["session_id"] == "sess-041"
    assert result[2]["session_id"] == "sess-040"


def test_recent_traces_limit(conn):
    for i in range(15):
        traces.start_trace(conn, f"sess-lim-{i:02d}")
    result = traces.recent_traces(conn, limit=10)
    assert len(result) == 10


def test_recent_traces_default_limit_is_10(conn):
    for i in range(20):
        traces.start_trace(conn, f"sess-def-{i:02d}")
    result = traces.recent_traces(conn)
    assert len(result) == 10


# ---------------------------------------------------------------------------
# Compound interaction: full session lifecycle
#
# Production sequence:
#   1. Session starts -> start_trace called
#   2. Agent reads files -> add_manifest_entry(file_read)
#   3. Agent writes files -> add_manifest_entry(file_write)
#   4. Agent makes decision -> add_manifest_entry(decision)
#   5. Agent runs tests -> add_manifest_entry(command)
#   6. Agent completes -> end_trace with summary
#   7. Next agent queries -> recent_traces, get_trace
#
# This is the actual production sequence that TKT-014 acceptance tests and
# hooks/lib/trace-lite.sh will trigger end-to-end.
# ---------------------------------------------------------------------------

def test_full_session_lifecycle_compound(conn):
    SESSION = "sess-e2e-tkt013"

    # Step 1: session start
    sid = traces.start_trace(conn, SESSION, agent_role="implementer", ticket="TKT-013")
    assert sid == SESSION

    # Step 2: file reads
    traces.add_manifest_entry(conn, SESSION, "file_read", path="runtime/schemas.py")
    traces.add_manifest_entry(conn, SESSION, "file_read", path="runtime/cli.py")

    # Step 3: file writes
    traces.add_manifest_entry(conn, SESSION, "file_write", path="runtime/core/traces.py",
                              detail="created new domain module")
    traces.add_manifest_entry(conn, SESSION, "file_write", path="tests/runtime/test_traces.py",
                              detail="created test suite")

    # Step 4: decision recorded
    traces.add_manifest_entry(conn, SESSION, "decision",
                              detail="DEC-TRACE-001: dedicated tables over events table overloading")

    # Step 5: command (test run)
    traces.add_manifest_entry(conn, SESSION, "command",
                              detail="python3 -m pytest tests/runtime/test_traces.py")

    # Step 6: session end with summary
    traces.end_trace(conn, SESSION, summary="TKT-013 trace domain implemented, 20 tests pass")

    # Step 7a: verify via get_trace -- full round-trip
    result = traces.get_trace(conn, SESSION)
    assert result is not None
    assert result["session_id"] == SESSION
    assert result["agent_role"] == "implementer"
    assert result["ticket"] == "TKT-013"
    assert result["ended_at"] is not None
    assert result["summary"] == "TKT-013 trace domain implemented, 20 tests pass"

    manifest = result["manifest"]
    assert len(manifest) == 6

    entry_types = [e["entry_type"] for e in manifest]
    assert entry_types == [
        "file_read", "file_read",
        "file_write", "file_write",
        "decision",
        "command",
    ]

    # Step 7b: verify via recent_traces -- appears as most recent
    recent = traces.recent_traces(conn, limit=5)
    assert any(r["session_id"] == SESSION for r in recent)
    assert recent[0]["session_id"] == SESSION
