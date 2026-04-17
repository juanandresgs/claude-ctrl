"""Unit tests for the ``seats`` runtime-owned domain.

@decision DEC-SEAT-DOMAIN-001
Title: seats domain module + CLI are runtime-owned authority
Status: accepted
Rationale: §2a required every supervision primitive to be a
  runtime-owned domain.  Three of four primitives already were; seat
  was the last whose writes lived inside dispatch_hook.py.  These
  tests pin the module's public API, its state-machine transitions,
  the vocabulary-guard contracts against runtime.schemas, and the CLI
  round-trip so later changes cannot silently diverge from the
  declared authority surface.

The tests operate on in-memory SQLite connections produced by
``ensure_schema`` — no adapter, no hook, no bridge transport.  The
only subprocess-level tests exercise ``python3 runtime/cli.py seat``
end-to-end against a temp-file database to prove the CLI subparser is
wired.
"""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import pytest

from runtime.core import seats as seat_mod
from runtime.schemas import SEAT_ROLES, SEAT_STATUSES, ensure_schema


_PROJECT_ROOT = Path(__file__).resolve().parents[2]
_CLI_PATH = _PROJECT_ROOT / "runtime" / "cli.py"


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA foreign_keys = ON")
    ensure_schema(c)
    yield c
    c.close()


def _insert_session(conn: sqlite3.Connection, session_id: str) -> None:
    now = int(time.time())
    conn.execute(
        """
        INSERT INTO agent_sessions (
            session_id, workflow_id, transport, transport_handle,
            status, created_at, updated_at
        ) VALUES (?, NULL, 'claude_code', NULL, 'active', ?, ?)
        """,
        (session_id, now, now),
    )


@pytest.fixture
def session(conn):
    _insert_session(conn, "sess-seat-test")
    conn.commit()
    return "sess-seat-test"


# ---------------------------------------------------------------------------
# create()
# ---------------------------------------------------------------------------


def test_create_inserts_active_row(conn, session):
    row = seat_mod.create(conn, "seat-1", session, "worker")
    assert row["seat_id"] == "seat-1"
    assert row["session_id"] == session
    assert row["role"] == "worker"
    assert row["status"] == "active"
    assert isinstance(row["created_at"], int)


def test_create_is_idempotent(conn, session):
    first = seat_mod.create(conn, "seat-idem", session, "worker")
    second = seat_mod.create(conn, "seat-idem", session, "worker")
    # Same row returned — no duplicate insert, no updated_at bump.
    assert first["seat_id"] == second["seat_id"]
    assert first["created_at"] == second["created_at"]
    assert first["updated_at"] == second["updated_at"]
    rows = conn.execute(
        "SELECT COUNT(*) AS n FROM seats WHERE seat_id = ?", ("seat-idem",)
    ).fetchone()
    assert rows["n"] == 1


def test_create_accepts_every_declared_role(conn, session):
    for role in sorted(SEAT_ROLES):
        row = seat_mod.create(conn, f"seat-{role}", session, role)
        assert row["role"] == role


def test_create_rejects_invalid_role(conn, session):
    with pytest.raises(ValueError, match="invalid role"):
        seat_mod.create(conn, "seat-bad-role", session, "not-a-role")


def test_create_rejects_empty_ids(conn, session):
    with pytest.raises(ValueError, match="seat_id"):
        seat_mod.create(conn, "", session, "worker")
    with pytest.raises(ValueError, match="session_id"):
        seat_mod.create(conn, "seat-empty-sess", "", "worker")


def test_create_rejects_unknown_session_fk(conn):
    with pytest.raises(sqlite3.IntegrityError):
        seat_mod.create(conn, "seat-no-sess", "sess-does-not-exist", "worker")


# ---------------------------------------------------------------------------
# get()
# ---------------------------------------------------------------------------


def test_get_roundtrips_created_row(conn, session):
    created = seat_mod.create(conn, "seat-get", session, "worker")
    got = seat_mod.get(conn, "seat-get")
    assert got == created


def test_get_unknown_seat_raises(conn):
    with pytest.raises(ValueError, match="not found"):
        seat_mod.get(conn, "seat-does-not-exist")


# ---------------------------------------------------------------------------
# release() state machine
# ---------------------------------------------------------------------------


def test_release_transitions_active_to_released(conn, session):
    seat_mod.create(conn, "seat-rel", session, "worker")
    result = seat_mod.release(conn, "seat-rel")
    assert result["transitioned"] is True
    assert result["row"]["status"] == "released"


def test_release_is_idempotent_on_released_seat(conn, session):
    seat_mod.create(conn, "seat-rel-again", session, "worker")
    seat_mod.release(conn, "seat-rel-again")
    second = seat_mod.release(conn, "seat-rel-again")
    assert second["transitioned"] is False
    assert second["row"]["status"] == "released"


def test_release_on_dead_seat_raises(conn, session):
    seat_mod.create(conn, "seat-dead-rel", session, "worker")
    seat_mod.mark_dead(conn, "seat-dead-rel")
    with pytest.raises(ValueError, match="invalid transition"):
        seat_mod.release(conn, "seat-dead-rel")


def test_release_unknown_seat_raises(conn):
    with pytest.raises(ValueError, match="not found"):
        seat_mod.release(conn, "seat-ghost")


# ---------------------------------------------------------------------------
# mark_dead() state machine
# ---------------------------------------------------------------------------


def test_mark_dead_transitions_active_to_dead(conn, session):
    seat_mod.create(conn, "seat-dead-from-active", session, "worker")
    result = seat_mod.mark_dead(conn, "seat-dead-from-active")
    assert result["transitioned"] is True
    assert result["row"]["status"] == "dead"


def test_mark_dead_transitions_released_to_dead(conn, session):
    seat_mod.create(conn, "seat-dead-from-released", session, "worker")
    seat_mod.release(conn, "seat-dead-from-released")
    result = seat_mod.mark_dead(conn, "seat-dead-from-released")
    assert result["transitioned"] is True
    assert result["row"]["status"] == "dead"


def test_mark_dead_is_idempotent_on_dead_seat(conn, session):
    seat_mod.create(conn, "seat-dead-idem", session, "worker")
    seat_mod.mark_dead(conn, "seat-dead-idem")
    second = seat_mod.mark_dead(conn, "seat-dead-idem")
    assert second["transitioned"] is False
    assert second["row"]["status"] == "dead"


def test_mark_dead_unknown_seat_raises(conn):
    with pytest.raises(ValueError, match="not found"):
        seat_mod.mark_dead(conn, "seat-ghost")


# ---------------------------------------------------------------------------
# list_for_session / list_active
# ---------------------------------------------------------------------------


def test_list_for_session_returns_only_matching_session(conn, session):
    _insert_session(conn, "sess-other")
    seat_mod.create(conn, "seat-A-1", session, "worker")
    seat_mod.create(conn, "seat-A-2", session, "supervisor")
    seat_mod.create(conn, "seat-B-1", "sess-other", "worker")

    rows_a = seat_mod.list_for_session(conn, session)
    assert {r["seat_id"] for r in rows_a} == {"seat-A-1", "seat-A-2"}
    rows_b = seat_mod.list_for_session(conn, "sess-other")
    assert [r["seat_id"] for r in rows_b] == ["seat-B-1"]


def test_list_for_session_filters_by_status(conn, session):
    s1 = seat_mod.create(conn, "seat-st-1", session, "worker")
    s2 = seat_mod.create(conn, "seat-st-2", session, "worker")
    seat_mod.release(conn, s2["seat_id"])
    s3 = seat_mod.create(conn, "seat-st-3", session, "worker")
    seat_mod.mark_dead(conn, s3["seat_id"])

    active = seat_mod.list_for_session(conn, session, status="active")
    assert [r["seat_id"] for r in active] == [s1["seat_id"]]

    released = seat_mod.list_for_session(conn, session, status="released")
    assert [r["seat_id"] for r in released] == [s2["seat_id"]]

    dead = seat_mod.list_for_session(conn, session, status="dead")
    assert [r["seat_id"] for r in dead] == [s3["seat_id"]]


def test_list_for_session_rejects_empty_id(conn):
    with pytest.raises(ValueError, match="session_id"):
        seat_mod.list_for_session(conn, "")


def test_list_for_session_rejects_invalid_status(conn, session):
    with pytest.raises(ValueError, match="invalid status"):
        seat_mod.list_for_session(conn, session, status="bogus")


def test_list_active_returns_only_active_seats(conn, session):
    seat_mod.create(conn, "seat-act-1", session, "worker")
    s2 = seat_mod.create(conn, "seat-act-2", session, "worker")
    seat_mod.release(conn, s2["seat_id"])
    rows = seat_mod.list_active(conn)
    assert [r["seat_id"] for r in rows] == ["seat-act-1"]


# ---------------------------------------------------------------------------
# Vocabulary authority
# ---------------------------------------------------------------------------


def test_state_machine_uses_only_schema_declared_statuses():
    for current, allowed in seat_mod._VALID_TRANSITIONS.items():
        assert current in SEAT_STATUSES
        for nxt in allowed:
            assert nxt in SEAT_STATUSES


# ---------------------------------------------------------------------------
# CLI round-trip
# ---------------------------------------------------------------------------


def _run_cli(tmp_db: Path, *cli_args: str) -> dict:
    env = os.environ.copy()
    env["CLAUDE_POLICY_DB"] = str(tmp_db)
    proc = subprocess.run(
        [sys.executable, str(_CLI_PATH), *cli_args],
        cwd=str(_PROJECT_ROOT),
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0, (
        f"cc-policy {' '.join(cli_args)} failed: "
        f"stdout={proc.stdout!r} stderr={proc.stderr!r}"
    )
    return json.loads(proc.stdout)


def _seed_seat_in_db(tmp_db: Path) -> str:
    c = sqlite3.connect(str(tmp_db))
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA foreign_keys = ON")
    ensure_schema(c)
    _insert_session(c, "cli-sess")
    seat_mod.create(c, "cli-seat", "cli-sess", "worker")
    c.commit()
    c.close()
    return "cli-seat"


def test_cli_help_lists_seat_actions(tmp_path):
    env = os.environ.copy()
    env["CLAUDE_POLICY_DB"] = str(tmp_path / "cli.sqlite3")
    proc = subprocess.run(
        [sys.executable, str(_CLI_PATH), "seat", "--help"],
        cwd=str(_PROJECT_ROOT),
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0
    for action in ("get", "release", "mark-dead", "list-for-session", "list-active"):
        assert action in proc.stdout, f"'{action}' missing from seat --help"


def test_cli_get_roundtrip(tmp_path):
    tmp_db = tmp_path / "cli.sqlite3"
    seat_id = _seed_seat_in_db(tmp_db)
    got = _run_cli(tmp_db, "seat", "get", "--seat-id", seat_id)
    assert got["status"] == "ok"
    assert got["seat"]["seat_id"] == seat_id
    assert got["seat"]["status"] == "active"


def test_cli_release_transitions_and_is_idempotent(tmp_path):
    tmp_db = tmp_path / "cli.sqlite3"
    seat_id = _seed_seat_in_db(tmp_db)

    first = _run_cli(tmp_db, "seat", "release", "--seat-id", seat_id)
    assert first["status"] == "ok"
    assert first["transitioned"] is True
    assert first["seat"]["status"] == "released"

    # Second call must be a no-op.
    second = _run_cli(tmp_db, "seat", "release", "--seat-id", seat_id)
    assert second["transitioned"] is False
    assert second["seat"]["status"] == "released"


def test_cli_mark_dead_transitions(tmp_path):
    tmp_db = tmp_path / "cli.sqlite3"
    seat_id = _seed_seat_in_db(tmp_db)
    out = _run_cli(tmp_db, "seat", "mark-dead", "--seat-id", seat_id)
    assert out["status"] == "ok"
    assert out["transitioned"] is True
    assert out["seat"]["status"] == "dead"


def test_cli_list_for_session(tmp_path):
    tmp_db = tmp_path / "cli.sqlite3"
    _seed_seat_in_db(tmp_db)
    out = _run_cli(
        tmp_db, "seat", "list-for-session", "--session-id", "cli-sess"
    )
    assert out["status"] == "ok"
    ids = [r["seat_id"] for r in out["seats"]]
    assert "cli-seat" in ids


def test_cli_list_active(tmp_path):
    tmp_db = tmp_path / "cli.sqlite3"
    _seed_seat_in_db(tmp_db)
    out = _run_cli(tmp_db, "seat", "list-active")
    assert out["status"] == "ok"
    assert any(r["seat_id"] == "cli-seat" for r in out["seats"])
