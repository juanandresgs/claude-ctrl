"""Unit tests for runtime.core.markers.

Tests the agent_markers table domain module using an in-memory SQLite
database. Covers set_active/get_active/deactivate/list_all round-trips,
scoped queries (W-CONV-2), and schema migrations.

@decision DEC-RT-001
Title: Canonical SQLite schema for all shared workflow state
Status: accepted
Rationale: agent_markers replaces the .subagent-tracker flat file.
  Tests confirm the is_active flag and stopped_at timestamp are managed
  correctly through the full lifecycle: set -> get-active -> deactivate.

@decision DEC-CONV-002
Title: Marker authority scoped by project_root and workflow_id
Status: accepted
Rationale: W-CONV-2 adds project_root + workflow_id scoping to set_active()
  and get_active(). Tests confirm scoped queries return only the matching
  project/workflow marker, unscoped queries remain backward-compatible, and
  lightweight role markers are rejected at the shell layer (verified via
  integration path in test-marker-lifecycle.sh).
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
# W-CONV-2: project_root + workflow_id scoping tests
# ---------------------------------------------------------------------------


def test_set_active_stores_project_root_and_workflow_id(conn):
    """set_active() persists project_root and workflow_id when provided."""
    markers.set_active(
        conn,
        "agent-1",
        "implementer",
        project_root="/repo/project-a",
        workflow_id="wf-001",
    )
    row = markers.get_active(conn)
    assert row is not None
    assert row["project_root"] == "/repo/project-a"
    assert row["workflow_id"] == "wf-001"


def test_get_active_scoped_by_project_root_returns_match(conn):
    """get_active(project_root=X) returns only the marker for project X."""
    markers.set_active(
        conn, "agent-a", "tester", project_root="/repo/project-a", workflow_id="wf-a"
    )
    markers.set_active(
        conn, "agent-b", "implementer", project_root="/repo/project-b", workflow_id="wf-b"
    )
    # Backdate agent-b so agent-a is newer in started_at; ensures scoping is
    # filtering, not just ordering.
    conn.execute("UPDATE agent_markers SET started_at = started_at - 10 WHERE agent_id = 'agent-b'")
    conn.commit()

    row = markers.get_active(conn, project_root="/repo/project-a")
    assert row is not None
    assert row["agent_id"] == "agent-a"
    assert row["role"] == "tester"


def test_get_active_scoped_by_project_root_no_match_returns_none(conn):
    """get_active(project_root=X) returns None when no marker for X."""
    markers.set_active(conn, "agent-a", "tester", project_root="/repo/project-a")
    row = markers.get_active(conn, project_root="/repo/project-other")
    assert row is None


def test_get_active_scoped_by_workflow_id(conn):
    """get_active(workflow_id=W) returns the marker for workflow W."""
    markers.set_active(
        conn, "agent-a", "tester", project_root="/repo/project-a", workflow_id="wf-a"
    )
    markers.set_active(
        conn, "agent-b", "implementer", project_root="/repo/project-a", workflow_id="wf-b"
    )
    conn.execute("UPDATE agent_markers SET started_at = started_at - 10 WHERE agent_id = 'agent-a'")
    conn.commit()

    row = markers.get_active(conn, project_root="/repo/project-a", workflow_id="wf-a")
    assert row is not None
    assert row["agent_id"] == "agent-a"


def test_get_active_scoped_no_match_returns_none_not_global(conn):
    """get_active with scoping params returns None if no match — no global fallback.

    This is the critical invariant: when scoping params are supplied, a
    non-matching marker in another project must NOT be returned.
    """
    # An unscoped marker exists in the DB
    markers.set_active(conn, "agent-global", "implementer")
    # Scoped query for a specific project must not return the unscoped marker
    row = markers.get_active(conn, project_root="/repo/some-project")
    assert row is None


def test_get_active_without_params_returns_newest_active(conn):
    """Unscoped get_active() returns the newest active marker (backward compat).

    This preserves the behavior relied on by statusline.py which calls
    get_active_with_age(conn) without scoping params.
    """
    markers.set_active(conn, "agent-1", "implementer")
    markers.set_active(conn, "agent-2", "tester")
    conn.execute("UPDATE agent_markers SET started_at = started_at - 10 WHERE agent_id = 'agent-1'")
    conn.commit()
    row = markers.get_active(conn)
    assert row is not None
    assert row["agent_id"] == "agent-2"


def test_set_active_replaces_previous_active_same_scope_and_role(conn):
    """set_active keeps one active marker per (role, project_root, workflow_id)."""
    markers.set_active(
        conn, "agent-old", "guardian", project_root="/repo/project-a", workflow_id="wf-1"
    )
    markers.set_active(
        conn, "agent-new", "guardian", project_root="/repo/project-a", workflow_id="wf-1"
    )

    active = markers.get_active(conn, project_root="/repo/project-a", workflow_id="wf-1")
    assert active is not None
    assert active["agent_id"] == "agent-new"
    assert active["status"] == "active"

    replaced = conn.execute(
        "SELECT is_active, status, stopped_at FROM agent_markers WHERE agent_id = 'agent-old'"
    ).fetchone()
    assert replaced is not None
    assert replaced["is_active"] == 0
    assert replaced["status"] == "replaced"
    assert replaced["stopped_at"] is not None


def test_set_active_does_not_replace_different_workflow(conn):
    """Replacement scope is exact; same role across workflows remains independent."""
    markers.set_active(
        conn, "agent-wf-a", "guardian", project_root="/repo/project-a", workflow_id="wf-a"
    )
    markers.set_active(
        conn, "agent-wf-b", "guardian", project_root="/repo/project-a", workflow_id="wf-b"
    )

    wf_a = markers.get_active(conn, project_root="/repo/project-a", workflow_id="wf-a")
    wf_b = markers.get_active(conn, project_root="/repo/project-a", workflow_id="wf-b")
    assert wf_a is not None and wf_a["agent_id"] == "agent-wf-a"
    assert wf_b is not None and wf_b["agent_id"] == "agent-wf-b"


def test_tester_wf_a_vs_implementer_wf_b_cross_project_isolation(conn):
    """Compound interaction: two workflows in same project are independently queryable.

    Production sequence: Tester active for workflow-A, Implementer active for
    workflow-B (parallel work in same repo). get_active(project_root=X,
    workflow_id=wf-A) returns tester; get_active(project_root=X,
    workflow_id=wf-B) returns implementer.
    """
    project = "/repo/shared-project"
    markers.set_active(conn, "agent-tester", "tester", project_root=project, workflow_id="wf-A")
    markers.set_active(conn, "agent-impl", "implementer", project_root=project, workflow_id="wf-B")
    # Ensure tester is newer so unscoped query would return tester
    conn.execute(
        "UPDATE agent_markers SET started_at = started_at - 5 WHERE agent_id = 'agent-impl'"
    )
    conn.commit()

    tester_row = markers.get_active(conn, project_root=project, workflow_id="wf-A")
    assert tester_row is not None
    assert tester_row["agent_id"] == "agent-tester"
    assert tester_row["role"] == "tester"

    impl_row = markers.get_active(conn, project_root=project, workflow_id="wf-B")
    assert impl_row is not None
    assert impl_row["agent_id"] == "agent-impl"
    assert impl_row["role"] == "implementer"


def test_project_root_column_in_schema(conn):
    """project_root column exists in agent_markers after ensure_schema."""
    cols = {row[1] for row in conn.execute("PRAGMA table_info(agent_markers)").fetchall()}
    assert "project_root" in cols


def test_cleanup_migration_deactivates_lightweight_roles(conn):
    """ensure_schema cleanup step deactivates existing ghost markers for lightweight roles.

    Simulates accumulated Explore/Bash/unknown markers from before W-CONV-2.
    After ensure_schema runs again on the same DB, those markers must be
    deactivated (is_active=0, status='stopped').
    """
    import time as _time

    now = int(_time.time())
    # Manually insert lightweight role markers (bypassing set_active so we can
    # use the pre-W-CONV-2 path with is_active=1)
    conn.execute(
        "INSERT INTO agent_markers (agent_id, role, started_at, is_active, status)"
        " VALUES ('explore-1', 'Explore', ?, 1, 'active')",
        (now - 100,),
    )
    conn.execute(
        "INSERT INTO agent_markers (agent_id, role, started_at, is_active, status)"
        " VALUES ('bash-1', 'Bash', ?, 1, 'active')",
        (now - 200,),
    )
    conn.execute(
        "INSERT INTO agent_markers (agent_id, role, started_at, is_active, status)"
        " VALUES ('unknown-1', 'unknown', ?, 1, 'active')",
        (now - 300,),
    )
    # A dispatch-significant marker that MUST remain active
    conn.execute(
        "INSERT INTO agent_markers (agent_id, role, started_at, is_active, status)"
        " VALUES ('impl-1', 'implementer', ?, 1, 'active')",
        (now - 50,),
    )
    conn.commit()

    # Run ensure_schema again on the already-migrated DB — cleanup step fires
    ensure_schema(conn)

    # Lightweight markers must be deactivated
    for agent_id in ("explore-1", "bash-1", "unknown-1"):
        row = conn.execute(
            "SELECT is_active, status FROM agent_markers WHERE agent_id = ?",
            (agent_id,),
        ).fetchone()
        assert row is not None
        assert row["is_active"] == 0, f"{agent_id} should be deactivated"
        assert row["status"] == "stopped", f"{agent_id} status should be 'stopped'"

    # Dispatch-significant marker must remain active
    impl_row = conn.execute(
        "SELECT is_active FROM agent_markers WHERE agent_id = 'impl-1'"
    ).fetchone()
    assert impl_row["is_active"] == 1


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
    # Columns exist exactly once — verify via pragma
    cols = {row[1] for row in c.execute("PRAGMA table_info(agent_markers)").fetchall()}
    assert "status" in cols
    assert "workflow_id" in cols
    assert "project_root" in cols
    c.close()
