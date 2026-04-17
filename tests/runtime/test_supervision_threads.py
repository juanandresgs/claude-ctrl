"""Unit tests for the ``supervision_threads`` runtime-owned domain.

@decision DEC-SUPERVISION-THREADS-DOMAIN-001
Title: supervision_threads domain module + CLI are runtime-owned authority
Status: accepted
Rationale: Phase 2b §2a seeded the supervision_threads table but never
  promoted it to a domain module. These tests pin the module's public API,
  the state-machine transitions, the vocabulary-guard contracts, and the
  CLI round-trip so later changes cannot silently diverge from the
  declared authority surface.

The tests operate on in-memory SQLite connections produced by
``ensure_schema`` — no adapter, no hook, no bridge transport. The only
subprocess-level test exercises ``python3 runtime/cli.py supervision``
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

from runtime.core import supervision_threads as sup_mod
from runtime.schemas import (
    SUPERVISION_THREAD_STATUSES,
    SUPERVISION_THREAD_TYPES,
    ensure_schema,
)


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


def _insert_seat(
    conn: sqlite3.Connection,
    seat_id: str,
    session_id: str,
    role: str = "worker",
) -> None:
    now = int(time.time())
    conn.execute(
        """
        INSERT INTO seats (
            seat_id, session_id, role, status, created_at, updated_at
        ) VALUES (?, ?, ?, 'active', ?, ?)
        """,
        (seat_id, session_id, role, now, now),
    )


@pytest.fixture
def two_seats(conn):
    _insert_session(conn, "sess-A")
    _insert_seat(conn, "seat-sup", "sess-A", role="supervisor")
    _insert_seat(conn, "seat-wrk", "sess-A", role="worker")
    conn.commit()
    return "seat-sup", "seat-wrk"


# ---------------------------------------------------------------------------
# attach()
# ---------------------------------------------------------------------------


def test_attach_returns_active_row(conn, two_seats):
    sup, wrk = two_seats
    row = sup_mod.attach(conn, sup, wrk, "analysis")
    assert row["status"] == "active"
    assert row["supervisor_seat_id"] == sup
    assert row["worker_seat_id"] == wrk
    assert row["thread_type"] == "analysis"
    assert row["thread_id"]
    assert isinstance(row["created_at"], int)
    assert row["created_at"] == row["updated_at"]


def test_attach_rejects_invalid_thread_type(conn, two_seats):
    sup, wrk = two_seats
    with pytest.raises(ValueError, match="invalid thread_type"):
        sup_mod.attach(conn, sup, wrk, "not-a-real-type")


def test_attach_rejects_self_supervision(conn, two_seats):
    sup, _ = two_seats
    with pytest.raises(ValueError, match="cannot supervise itself"):
        sup_mod.attach(conn, sup, sup, "analysis")


def test_attach_rejects_empty_seat_ids(conn, two_seats):
    sup, wrk = two_seats
    with pytest.raises(ValueError, match="supervisor_seat_id"):
        sup_mod.attach(conn, "", wrk, "analysis")
    with pytest.raises(ValueError, match="worker_seat_id"):
        sup_mod.attach(conn, sup, "", "analysis")


def test_attach_rejects_unknown_seat_fk(conn, two_seats):
    sup, _ = two_seats
    with pytest.raises(sqlite3.IntegrityError):
        sup_mod.attach(conn, sup, "seat-does-not-exist", "analysis")


def test_attach_accepts_every_declared_type(conn, two_seats):
    sup, wrk = two_seats
    for tt in sorted(SUPERVISION_THREAD_TYPES):
        row = sup_mod.attach(conn, sup, wrk, tt)
        assert row["thread_type"] == tt


# ---------------------------------------------------------------------------
# detach() / abandon() state machine
# ---------------------------------------------------------------------------


def test_detach_transitions_active_to_completed(conn, two_seats):
    sup, wrk = two_seats
    row = sup_mod.attach(conn, sup, wrk, "analysis")
    detached = sup_mod.detach(conn, row["thread_id"])
    assert detached["status"] == "completed"
    assert detached["thread_id"] == row["thread_id"]
    assert detached["updated_at"] >= row["updated_at"]


def test_abandon_transitions_active_to_abandoned(conn, two_seats):
    sup, wrk = two_seats
    row = sup_mod.attach(conn, sup, wrk, "analysis")
    abandoned = sup_mod.abandon(conn, row["thread_id"])
    assert abandoned["status"] == "abandoned"


def test_double_detach_raises(conn, two_seats):
    sup, wrk = two_seats
    row = sup_mod.attach(conn, sup, wrk, "analysis")
    sup_mod.detach(conn, row["thread_id"])
    with pytest.raises(ValueError, match="invalid transition"):
        sup_mod.detach(conn, row["thread_id"])


def test_abandon_after_detach_raises(conn, two_seats):
    sup, wrk = two_seats
    row = sup_mod.attach(conn, sup, wrk, "analysis")
    sup_mod.detach(conn, row["thread_id"])
    with pytest.raises(ValueError, match="invalid transition"):
        sup_mod.abandon(conn, row["thread_id"])


def test_detach_unknown_thread_raises(conn):
    with pytest.raises(ValueError, match="not found"):
        sup_mod.detach(conn, "nope")


def test_abandon_unknown_thread_raises(conn):
    with pytest.raises(ValueError, match="not found"):
        sup_mod.abandon(conn, "nope")


# ---------------------------------------------------------------------------
# get() + listing
# ---------------------------------------------------------------------------


def test_get_roundtrips_attached_row(conn, two_seats):
    sup, wrk = two_seats
    row = sup_mod.attach(conn, sup, wrk, "review")
    fetched = sup_mod.get(conn, row["thread_id"])
    assert fetched == row


def test_get_unknown_thread_raises(conn):
    with pytest.raises(ValueError, match="not found"):
        sup_mod.get(conn, "nope")


def test_list_for_supervisor_filters_and_orders(conn, two_seats):
    sup, wrk = two_seats
    t1 = sup_mod.attach(conn, sup, wrk, "analysis")
    t2 = sup_mod.attach(conn, sup, wrk, "review")
    sup_mod.detach(conn, t2["thread_id"])

    all_rows = sup_mod.list_for_supervisor(conn, sup)
    assert [r["thread_id"] for r in all_rows] == [t1["thread_id"], t2["thread_id"]]

    active_only = sup_mod.list_for_supervisor(conn, sup, status="active")
    assert [r["thread_id"] for r in active_only] == [t1["thread_id"]]

    completed_only = sup_mod.list_for_supervisor(conn, sup, status="completed")
    assert [r["thread_id"] for r in completed_only] == [t2["thread_id"]]


def test_list_for_worker_filters(conn, two_seats):
    sup, wrk = two_seats
    t1 = sup_mod.attach(conn, sup, wrk, "analysis")
    rows = sup_mod.list_for_worker(conn, wrk)
    assert len(rows) == 1 and rows[0]["thread_id"] == t1["thread_id"]
    empty = sup_mod.list_for_worker(conn, wrk, status="abandoned")
    assert empty == []


def test_list_active_returns_only_active(conn, two_seats):
    sup, wrk = two_seats
    t1 = sup_mod.attach(conn, sup, wrk, "analysis")
    t2 = sup_mod.attach(conn, sup, wrk, "review")
    sup_mod.detach(conn, t2["thread_id"])
    rows = sup_mod.list_active(conn)
    assert [r["thread_id"] for r in rows] == [t1["thread_id"]]


def test_list_helpers_reject_invalid_status(conn, two_seats):
    sup, wrk = two_seats
    with pytest.raises(ValueError, match="invalid status"):
        sup_mod.list_for_supervisor(conn, sup, status="bogus")
    with pytest.raises(ValueError, match="invalid status"):
        sup_mod.list_for_worker(conn, wrk, status="bogus")


# ---------------------------------------------------------------------------
# Vocabulary authority
# ---------------------------------------------------------------------------


def test_module_defers_to_schema_vocabulary():
    assert SUPERVISION_THREAD_STATUSES, "schema must declare non-empty status set"
    assert SUPERVISION_THREAD_TYPES, "schema must declare non-empty type set"
    # Every transition target must be a declared status.
    for current, allowed in sup_mod._VALID_TRANSITIONS.items():
        assert current in SUPERVISION_THREAD_STATUSES
        for nxt in allowed:
            assert nxt in SUPERVISION_THREAD_STATUSES


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


def _seed_seats_in_db(tmp_db: Path) -> tuple[str, str]:
    conn = sqlite3.connect(str(tmp_db))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    ensure_schema(conn)
    _insert_session(conn, "cli-sess")
    _insert_seat(conn, "cli-sup", "cli-sess", role="supervisor")
    _insert_seat(conn, "cli-wrk", "cli-sess", role="worker")
    conn.commit()
    conn.close()
    return "cli-sup", "cli-wrk"


def test_cli_help_lists_supervision_actions(tmp_path):
    tmp_db = tmp_path / "cli.sqlite3"
    env = os.environ.copy()
    env["CLAUDE_POLICY_DB"] = str(tmp_db)
    proc = subprocess.run(
        [sys.executable, str(_CLI_PATH), "supervision", "--help"],
        cwd=str(_PROJECT_ROOT),
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0
    for action in (
        "attach",
        "detach",
        "abandon",
        "get",
        "list-for-supervisor",
        "list-for-worker",
        "list-active",
    ):
        assert action in proc.stdout, f"'{action}' missing from supervision --help"


def test_cli_attach_list_detach_roundtrip(tmp_path):
    tmp_db = tmp_path / "cli.sqlite3"
    sup, wrk = _seed_seats_in_db(tmp_db)

    attached = _run_cli(
        tmp_db,
        "supervision", "attach",
        "--supervisor-seat-id", sup,
        "--worker-seat-id", wrk,
        "--thread-type", "analysis",
    )
    assert attached["status"] == "ok"
    thread = attached["thread"]
    assert thread["status"] == "active"
    tid = thread["thread_id"]

    listed = _run_cli(tmp_db, "supervision", "list-active")
    assert listed["status"] == "ok"
    assert any(r["thread_id"] == tid for r in listed["threads"])

    got = _run_cli(tmp_db, "supervision", "get", "--thread-id", tid)
    assert got["status"] == "ok"
    assert got["thread"]["thread_id"] == tid

    detached = _run_cli(tmp_db, "supervision", "detach", "--thread-id", tid)
    assert detached["status"] == "ok"
    assert detached["thread"]["status"] == "completed"

    listed_after = _run_cli(tmp_db, "supervision", "list-active")
    assert listed_after["status"] == "ok"
    assert all(r["thread_id"] != tid for r in listed_after["threads"])
