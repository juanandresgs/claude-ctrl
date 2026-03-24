"""Trace-lite: lightweight session manifests and summaries.

Owns the traces and trace_manifest tables. Trace records are evidence and
recovery material only — no control decision in the successor runtime may
depend on a trace being present (DEC-FORK-013). The purpose is to give
future implementers context about what each session/agent did without
requiring them to read full conversation logs.

@decision DEC-TRACE-001
Title: Trace-lite uses dedicated tables, not the events table
Status: accepted
Rationale: The events table (owned by runtime.core.events) is an append-only
  audit log keyed by type. Overloading it with trace manifests would require
  encoding structured manifest entries (file_read, file_write, decision,
  command, event) into the untyped `detail` text field and post-hoc JSON
  parsing. Dedicated traces + trace_manifest tables give each entry a proper
  schema (entry_type, path, detail) and allow get_trace() to return a
  structured dict with a typed manifest list in a single query pair.
  This also keeps trace queries independent of event type filtering — a
  future sidecar (TKT-015) can read trace_manifest directly without
  knowing the events table's type namespace.
  DEC-FORK-013 constrains: trace data is evidence only, never authority.
  The schema is therefore deliberately minimal with no status fields or
  lifecycle state beyond started_at/ended_at.
"""

from __future__ import annotations

import sqlite3
import time
from typing import Optional


def start_trace(
    conn: sqlite3.Connection,
    session_id: str,
    agent_role: Optional[str] = None,
    ticket: Optional[str] = None,
) -> str:
    """Begin a new trace for a session/agent.

    Inserts a row into traces with started_at set to the current epoch.
    Returns session_id so callers can chain: sid = start_trace(conn, sid).

    Args:
        conn:       Open SQLite connection with trace tables present.
        session_id: Caller-assigned identifier — typically CLAUDE_SESSION_ID
                    or a synthetic ID for testing.
        agent_role: Optional role string (implementer, tester, planner, etc.).
        ticket:     Optional ticket reference (e.g. "TKT-013").

    Returns:
        The session_id that was inserted, unchanged.
    """
    now = int(time.time())
    with conn:
        conn.execute(
            "INSERT INTO traces (session_id, agent_role, ticket, started_at)"
            " VALUES (?, ?, ?, ?)",
            (session_id, agent_role, ticket, now),
        )
    return session_id


def end_trace(
    conn: sqlite3.Connection,
    session_id: str,
    summary: Optional[str] = None,
) -> None:
    """Close a trace with an optional human-readable summary.

    Sets ended_at to the current epoch. If the session_id does not exist
    this is a no-op (UPDATE with no matching rows is not an error).

    Args:
        conn:       Open SQLite connection.
        session_id: The session to close.
        summary:    Optional free-text summary of what the session accomplished
                    (e.g. "TKT-013 trace domain implemented, 20 tests pass").
    """
    now = int(time.time())
    with conn:
        conn.execute(
            "UPDATE traces SET ended_at = ?, summary = ? WHERE session_id = ?",
            (now, summary, session_id),
        )


def add_manifest_entry(
    conn: sqlite3.Connection,
    session_id: str,
    entry_type: str,
    path: Optional[str] = None,
    detail: Optional[str] = None,
) -> None:
    """Record a file touch, decision, command, or event in the trace manifest.

    Entry types (by convention — not enforced at DB level so future callers
    can extend without schema changes):
      file_read  — a source file was read
      file_write — a source file was written or created
      decision   — an architectural or implementation decision was made
      command    — a shell command was executed
      event      — any other notable session event

    Args:
        conn:       Open SQLite connection.
        session_id: The owning trace session.
        entry_type: One of the conventional types above (or any string).
        path:       File path for file_read/file_write entries; None otherwise.
        detail:     Human-readable description of the entry.
    """
    now = int(time.time())
    with conn:
        conn.execute(
            "INSERT INTO trace_manifest"
            " (session_id, entry_type, path, detail, created_at)"
            " VALUES (?, ?, ?, ?, ?)",
            (session_id, entry_type, path, detail, now),
        )


def get_trace(
    conn: sqlite3.Connection,
    session_id: str,
) -> Optional[dict]:
    """Return a trace dict with its manifest, or None if not found.

    The returned dict contains all traces columns plus a 'manifest' key
    holding a list of trace_manifest dicts ordered by created_at ascending
    (chronological order — earliest entry first).

    Args:
        conn:       Open SQLite connection.
        session_id: The session to retrieve.

    Returns:
        dict with keys: session_id, agent_role, ticket, started_at,
        ended_at, summary, manifest (list of entry dicts).
        None if no trace with that session_id exists.
    """
    row = conn.execute(
        "SELECT session_id, agent_role, ticket, started_at, ended_at, summary"
        " FROM traces WHERE session_id = ?",
        (session_id,),
    ).fetchone()
    if row is None:
        return None

    manifest_rows = conn.execute(
        "SELECT id, session_id, entry_type, path, detail, created_at"
        " FROM trace_manifest"
        " WHERE session_id = ?"
        " ORDER BY created_at ASC",
        (session_id,),
    ).fetchall()

    result = dict(row)
    result["manifest"] = [dict(m) for m in manifest_rows]
    return result


def recent_traces(
    conn: sqlite3.Connection,
    limit: int = 10,
) -> list[dict]:
    """Return the most recently started traces, newest first.

    Does not include manifest entries — callers who need the full manifest
    for a specific session should call get_trace(). This function is for
    listing/discovery, not full retrieval.

    Args:
        conn:  Open SQLite connection.
        limit: Maximum number of rows to return (default 10).

    Returns:
        List of dicts with traces columns (no manifest key).
        Empty list if no traces exist.
    """
    rows = conn.execute(
        "SELECT session_id, agent_role, ticket, started_at, ended_at, summary"
        " FROM traces"
        " ORDER BY started_at DESC"
        " LIMIT ?",
        (limit,),
    ).fetchall()
    return [dict(r) for r in rows]
