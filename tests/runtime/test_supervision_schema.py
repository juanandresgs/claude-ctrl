"""Invariant tests for the Phase 2b supervision fabric schema authority.

@decision DEC-CLAUDEX-SUPERVISION-DOMAIN-001
Title: agent_sessions, seats, supervision_threads, dispatch_attempts schema invariants
Status: accepted
Rationale: CUTOVER_PLAN §Phase 2b requires the runtime to own the supervision fabric
  state. This file pins the exact schema shape so later adapter slices cannot quietly
  diverge from the declared authority surface:

    1. All four tables exist after ensure_schema on a fresh in-memory DB.
    2. Each table carries exactly the declared core columns (names and presence;
       types are advisory in SQLite but pinned here for documentation).
    3. FK-reference columns exist with the correct names so relational shape
       queries work as expected (SQLite does not enforce FKs by default, but the
       column names are the declared contract).
    4. Status and role constants exported from schemas.py are non-empty frozensets
       of strings and contain the values the Phase 2b design requires.
    5. All four tables accept INSERT + SELECT round-trips against the schema.
    6. ensure_schema is idempotent — calling it twice does not raise.

These tests are schema-only. They import only ``runtime.schemas``.
They MUST NOT import any domain helper, hook, or adapter module.
"""

from __future__ import annotations

import sqlite3
import time

import pytest

from runtime.schemas import (
    AGENT_SESSION_STATUSES,
    DISPATCH_ATTEMPT_STATUSES,
    SEAT_ROLES,
    SEAT_STATUSES,
    SUPERVISION_THREAD_STATUSES,
    SUPERVISION_THREAD_TYPES,
    ensure_schema,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


def _columns(conn: sqlite3.Connection, table: str) -> dict[str, str]:
    """Return {column_name: type} for a table via PRAGMA table_info."""
    rows = conn.execute(f"PRAGMA table_info({table})").fetchall()
    return {row["name"]: row["type"] for row in rows}


# ---------------------------------------------------------------------------
# 1. Tables exist
# ---------------------------------------------------------------------------


def test_agent_sessions_table_exists(conn):
    cols = _columns(conn, "agent_sessions")
    assert cols, "agent_sessions table must exist after ensure_schema"


def test_seats_table_exists(conn):
    cols = _columns(conn, "seats")
    assert cols, "seats table must exist after ensure_schema"


def test_supervision_threads_table_exists(conn):
    cols = _columns(conn, "supervision_threads")
    assert cols, "supervision_threads table must exist after ensure_schema"


def test_dispatch_attempts_table_exists(conn):
    cols = _columns(conn, "dispatch_attempts")
    assert cols, "dispatch_attempts table must exist after ensure_schema"


# ---------------------------------------------------------------------------
# 2. Core column presence for each table
# ---------------------------------------------------------------------------


class TestAgentSessionsColumns:
    REQUIRED = {
        "session_id",
        "workflow_id",
        "transport",
        "transport_handle",
        "status",
        "created_at",
        "updated_at",
    }

    def test_all_required_columns_present(self, conn):
        cols = set(_columns(conn, "agent_sessions"))
        missing = self.REQUIRED - cols
        assert not missing, f"agent_sessions missing columns: {missing}"

    def test_session_id_is_primary_key(self, conn):
        rows = conn.execute("PRAGMA table_info(agent_sessions)").fetchall()
        pk_cols = {row["name"] for row in rows if row["pk"] == 1}
        assert "session_id" in pk_cols

    def test_status_default_is_active(self, conn):
        rows = conn.execute("PRAGMA table_info(agent_sessions)").fetchall()
        dflt = {row["name"]: row["dflt_value"] for row in rows}
        assert dflt.get("status") == "'active'"


class TestSeatsColumns:
    REQUIRED = {
        "seat_id",
        "session_id",
        "role",
        "status",
        "created_at",
        "updated_at",
    }

    def test_all_required_columns_present(self, conn):
        cols = set(_columns(conn, "seats"))
        missing = self.REQUIRED - cols
        assert not missing, f"seats missing columns: {missing}"

    def test_seat_id_is_primary_key(self, conn):
        rows = conn.execute("PRAGMA table_info(seats)").fetchall()
        pk_cols = {row["name"] for row in rows if row["pk"] == 1}
        assert "seat_id" in pk_cols

    def test_session_id_fk_column_exists(self, conn):
        cols = set(_columns(conn, "seats"))
        assert "session_id" in cols, "seats must carry session_id FK column"

    def test_status_default_is_active(self, conn):
        rows = conn.execute("PRAGMA table_info(seats)").fetchall()
        dflt = {row["name"]: row["dflt_value"] for row in rows}
        assert dflt.get("status") == "'active'"


class TestSupervisionThreadsColumns:
    REQUIRED = {
        "thread_id",
        "supervisor_seat_id",
        "worker_seat_id",
        "thread_type",
        "status",
        "created_at",
        "updated_at",
    }

    def test_all_required_columns_present(self, conn):
        cols = set(_columns(conn, "supervision_threads"))
        missing = self.REQUIRED - cols
        assert not missing, f"supervision_threads missing columns: {missing}"

    def test_thread_id_is_primary_key(self, conn):
        rows = conn.execute("PRAGMA table_info(supervision_threads)").fetchall()
        pk_cols = {row["name"] for row in rows if row["pk"] == 1}
        assert "thread_id" in pk_cols

    def test_supervisor_and_worker_fk_columns_exist(self, conn):
        cols = set(_columns(conn, "supervision_threads"))
        assert "supervisor_seat_id" in cols
        assert "worker_seat_id" in cols

    def test_status_default_is_active(self, conn):
        rows = conn.execute("PRAGMA table_info(supervision_threads)").fetchall()
        dflt = {row["name"]: row["dflt_value"] for row in rows}
        assert dflt.get("status") == "'active'"


class TestDispatchAttemptsColumns:
    REQUIRED = {
        "attempt_id",
        "seat_id",
        "workflow_id",
        "instruction",
        "status",
        "delivery_claimed_at",
        "acknowledged_at",
        "retry_count",
        "timeout_at",
        "created_at",
        "updated_at",
    }

    def test_all_required_columns_present(self, conn):
        cols = set(_columns(conn, "dispatch_attempts"))
        missing = self.REQUIRED - cols
        assert not missing, f"dispatch_attempts missing columns: {missing}"

    def test_attempt_id_is_primary_key(self, conn):
        rows = conn.execute("PRAGMA table_info(dispatch_attempts)").fetchall()
        pk_cols = {row["name"] for row in rows if row["pk"] == 1}
        assert "attempt_id" in pk_cols

    def test_seat_id_fk_column_exists(self, conn):
        cols = set(_columns(conn, "dispatch_attempts"))
        assert "seat_id" in cols

    def test_retry_count_default_is_zero(self, conn):
        rows = conn.execute("PRAGMA table_info(dispatch_attempts)").fetchall()
        dflt = {row["name"]: row["dflt_value"] for row in rows}
        assert dflt.get("retry_count") == "0"

    def test_status_default_is_pending(self, conn):
        rows = conn.execute("PRAGMA table_info(dispatch_attempts)").fetchall()
        dflt = {row["name"]: row["dflt_value"] for row in rows}
        assert dflt.get("status") == "'pending'"


# ---------------------------------------------------------------------------
# 3. Status and role constants
# ---------------------------------------------------------------------------


class TestStatusConstants:
    def test_agent_session_statuses_is_frozenset(self):
        assert isinstance(AGENT_SESSION_STATUSES, frozenset)

    def test_agent_session_statuses_contains_required(self):
        required = {"active", "completed", "dead", "orphaned"}
        assert required <= AGENT_SESSION_STATUSES

    def test_seat_statuses_is_frozenset(self):
        assert isinstance(SEAT_STATUSES, frozenset)

    def test_seat_statuses_contains_required(self):
        required = {"active", "released", "dead"}
        assert required <= SEAT_STATUSES

    def test_seat_roles_is_frozenset(self):
        assert isinstance(SEAT_ROLES, frozenset)

    def test_seat_roles_contains_required(self):
        required = {"worker", "supervisor", "reviewer", "observer"}
        assert required <= SEAT_ROLES

    def test_supervision_thread_statuses_is_frozenset(self):
        assert isinstance(SUPERVISION_THREAD_STATUSES, frozenset)

    def test_supervision_thread_statuses_contains_required(self):
        required = {"active", "completed", "abandoned"}
        assert required <= SUPERVISION_THREAD_STATUSES

    def test_supervision_thread_types_is_frozenset(self):
        assert isinstance(SUPERVISION_THREAD_TYPES, frozenset)

    def test_supervision_thread_types_contains_required(self):
        required = {"analysis", "review", "autopilot", "observer"}
        assert required <= SUPERVISION_THREAD_TYPES

    def test_dispatch_attempt_statuses_is_frozenset(self):
        assert isinstance(DISPATCH_ATTEMPT_STATUSES, frozenset)

    def test_dispatch_attempt_statuses_contains_required(self):
        required = {
            "pending",
            "delivered",
            "acknowledged",
            "timed_out",
            "failed",
            "cancelled",
        }
        assert required <= DISPATCH_ATTEMPT_STATUSES


# ---------------------------------------------------------------------------
# 4. INSERT + SELECT round-trips (basic relational shape)
# ---------------------------------------------------------------------------


class TestInsertRoundTrips:
    """Prove the tables accept valid data and that FK-column relationships hold."""

    def _now(self) -> int:
        return int(time.time())

    def test_agent_session_insert_and_select(self, conn):
        now = self._now()
        conn.execute(
            """
            INSERT INTO agent_sessions
              (session_id, workflow_id, transport, transport_handle, status,
               created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            ("sess-001", "wf-001", "tmux", "pane:0.0", "active", now, now),
        )
        row = conn.execute(
            "SELECT * FROM agent_sessions WHERE session_id = ?", ("sess-001",)
        ).fetchone()
        assert row is not None
        assert row["transport"] == "tmux"
        assert row["workflow_id"] == "wf-001"
        assert row["status"] == "active"

    def test_seat_insert_and_select(self, conn):
        now = self._now()
        conn.execute(
            """
            INSERT INTO agent_sessions
              (session_id, transport, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            ("sess-002", "mcp", "active", now, now),
        )
        conn.execute(
            """
            INSERT INTO seats
              (seat_id, session_id, role, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            ("seat-002", "sess-002", "worker", "active", now, now),
        )
        row = conn.execute(
            "SELECT * FROM seats WHERE seat_id = ?", ("seat-002",)
        ).fetchone()
        assert row is not None
        assert row["session_id"] == "sess-002"
        assert row["role"] == "worker"

    def test_supervision_thread_insert_and_select(self, conn):
        now = self._now()
        conn.execute(
            "INSERT INTO agent_sessions (session_id, transport, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
            ("sess-003", "tmux", "active", now, now),
        )
        conn.execute(
            "INSERT INTO seats (seat_id, session_id, role, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
            ("seat-sup", "sess-003", "supervisor", "active", now, now),
        )
        conn.execute(
            "INSERT INTO seats (seat_id, session_id, role, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
            ("seat-wrk", "sess-003", "worker", "active", now, now),
        )
        conn.execute(
            """
            INSERT INTO supervision_threads
              (thread_id, supervisor_seat_id, worker_seat_id, thread_type,
               status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            ("thread-001", "seat-sup", "seat-wrk", "review", "active", now, now),
        )
        row = conn.execute(
            "SELECT * FROM supervision_threads WHERE thread_id = ?", ("thread-001",)
        ).fetchone()
        assert row is not None
        assert row["supervisor_seat_id"] == "seat-sup"
        assert row["worker_seat_id"] == "seat-wrk"
        assert row["thread_type"] == "review"

    def test_dispatch_attempt_insert_and_select(self, conn):
        now = self._now()
        conn.execute(
            "INSERT INTO agent_sessions (session_id, transport, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
            ("sess-004", "claude_code", "active", now, now),
        )
        conn.execute(
            "INSERT INTO seats (seat_id, session_id, role, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
            ("seat-004", "sess-004", "worker", "active", now, now),
        )
        conn.execute(
            """
            INSERT INTO dispatch_attempts
              (attempt_id, seat_id, workflow_id, instruction, status,
               retry_count, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                "att-001",
                "seat-004",
                "wf-004",
                "implement feature X",
                "pending",
                0,
                now,
                now,
            ),
        )
        row = conn.execute(
            "SELECT * FROM dispatch_attempts WHERE attempt_id = ?", ("att-001",)
        ).fetchone()
        assert row is not None
        assert row["seat_id"] == "seat-004"
        assert row["status"] == "pending"
        assert row["retry_count"] == 0
        assert row["delivery_claimed_at"] is None
        assert row["acknowledged_at"] is None

    def test_dispatch_attempt_delivery_claim_update(self, conn):
        now = self._now()
        conn.execute(
            "INSERT INTO agent_sessions (session_id, transport, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
            ("sess-005", "tmux", "active", now, now),
        )
        conn.execute(
            "INSERT INTO seats (seat_id, session_id, role, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
            ("seat-005", "sess-005", "worker", "active", now, now),
        )
        conn.execute(
            "INSERT INTO dispatch_attempts (attempt_id, seat_id, instruction, status, retry_count, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            ("att-002", "seat-005", "run tests", "pending", 0, now, now),
        )
        conn.execute(
            "UPDATE dispatch_attempts SET status = 'delivered', delivery_claimed_at = ?, updated_at = ? WHERE attempt_id = ?",
            (now + 1, now + 1, "att-002"),
        )
        row = conn.execute(
            "SELECT status, delivery_claimed_at FROM dispatch_attempts WHERE attempt_id = ?",
            ("att-002",),
        ).fetchone()
        assert row["status"] == "delivered"
        assert row["delivery_claimed_at"] == now + 1


# ---------------------------------------------------------------------------
# 5. Idempotency
# ---------------------------------------------------------------------------


def test_ensure_schema_is_idempotent():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    ensure_schema(c)  # must not raise
    cols = set(_columns(c, "agent_sessions"))
    assert "session_id" in cols
    c.close()


# ---------------------------------------------------------------------------
# 6. Indexes exist
# ---------------------------------------------------------------------------


def _index_names(conn: sqlite3.Connection, table: str) -> set[str]:
    rows = conn.execute(f"PRAGMA index_list({table})").fetchall()
    return {row["name"] for row in rows}


def test_agent_sessions_indexes_exist(conn):
    idx = _index_names(conn, "agent_sessions")
    assert "idx_agent_sessions_workflow" in idx
    assert "idx_agent_sessions_status" in idx


def test_seats_indexes_exist(conn):
    idx = _index_names(conn, "seats")
    assert "idx_seats_session" in idx
    assert "idx_seats_status" in idx


def test_supervision_threads_indexes_exist(conn):
    idx = _index_names(conn, "supervision_threads")
    assert "idx_supervision_threads_supervisor" in idx
    assert "idx_supervision_threads_worker" in idx


def test_dispatch_attempts_indexes_exist(conn):
    idx = _index_names(conn, "dispatch_attempts")
    assert "idx_dispatch_attempts_seat_status" in idx
    assert "idx_dispatch_attempts_workflow" in idx


# ---------------------------------------------------------------------------
# 7. Domain-module / schema vocabulary linkage
#    (DEC-SUPERVISION-THREADS-DOMAIN-001)
#    The supervision_threads runtime-owned domain module must key off the
#    same schema vocabulary pinned above — no private copy of the status or
#    type set, no extra columns beyond the declared DDL.
# ---------------------------------------------------------------------------


def test_seats_domain_module_imports_and_pins_schema_vocabulary():
    """@decision DEC-SEAT-DOMAIN-001 — seats.py public surface pin.

    Symmetric to the supervision_threads pin below.  Ensures the seat
    domain module exposes the declared public API and that its state
    machine never invents a status outside SEAT_STATUSES.
    """
    from runtime.core import seats as seat_mod

    for name in (
        "create",
        "get",
        "release",
        "mark_dead",
        "list_for_session",
        "list_active",
    ):
        assert hasattr(seat_mod, name), (
            f"seats domain module missing public API: {name}"
        )

    for current, allowed in seat_mod._VALID_TRANSITIONS.items():
        assert current in SEAT_STATUSES
        for nxt in allowed:
            assert nxt in SEAT_STATUSES


def test_supervision_threads_domain_module_imports_and_pins_schema_vocabulary(conn):
    from runtime.core import supervision_threads as sup_mod

    # Module must expose the declared public API surface.
    for name in (
        "attach",
        "detach",
        "abandon",
        "abandon_for_seat",
        "abandon_for_session",
        "get",
        "list_for_supervisor",
        "list_for_worker",
        "list_for_session",
        "list_for_seat",
        "list_active",
    ):
        assert hasattr(sup_mod, name), (
            f"supervision_threads domain module missing public API: {name}"
        )

    # State-machine transitions must all live within the schema-declared
    # status vocabulary. No bespoke states.
    for current, allowed in sup_mod._VALID_TRANSITIONS.items():
        assert current in SUPERVISION_THREAD_STATUSES
        for nxt in allowed:
            assert nxt in SUPERVISION_THREAD_STATUSES

    # A live attach() round-trip must produce a row whose columns match the
    # schema-declared shape exactly (no silent column drift).
    now = int(time.time())
    conn.execute(
        """
        INSERT INTO agent_sessions (
            session_id, workflow_id, transport, transport_handle,
            status, created_at, updated_at
        ) VALUES ('sess-x', NULL, 'claude_code', NULL, 'active', ?, ?)
        """,
        (now, now),
    )
    conn.execute(
        """
        INSERT INTO seats (
            seat_id, session_id, role, status, created_at, updated_at
        ) VALUES ('seat-x-sup', 'sess-x', 'supervisor', 'active', ?, ?)
        """,
        (now, now),
    )
    conn.execute(
        """
        INSERT INTO seats (
            seat_id, session_id, role, status, created_at, updated_at
        ) VALUES ('seat-x-wrk', 'sess-x', 'worker', 'active', ?, ?)
        """,
        (now, now),
    )
    conn.commit()

    row = sup_mod.attach(conn, "seat-x-sup", "seat-x-wrk", "analysis")
    declared_cols = set(_columns(conn, "supervision_threads"))
    assert set(row.keys()) == declared_cols, (
        "attach() row keys must match supervision_threads columns exactly"
    )
