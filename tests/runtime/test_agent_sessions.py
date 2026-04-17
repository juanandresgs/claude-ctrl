"""Unit tests for the ``agent_sessions`` runtime-owned domain.

@decision DEC-AGENT-SESSION-DOMAIN-001
Title: agent_sessions domain module + CLI are runtime-owned authority
Status: accepted
Rationale: §2a required every supervision primitive to be a
  runtime-owned domain.  agent_session was the last one whose writes
  still lived inside dispatch_hook.py after seat was promoted at
  e982d50.  These tests pin the module's public API, state-machine
  transitions, vocabulary-guard contracts against runtime.schemas, and
  the CLI round-trip so later changes cannot silently diverge from
  the declared authority surface.

The tests operate on in-memory SQLite connections produced by
``ensure_schema`` — no adapter, no hook, no bridge transport.  The
subprocess-level tests exercise ``python3 runtime/cli.py
agent-session`` end-to-end against a temp-file database to prove the
CLI subparser is wired.
"""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

from runtime.core import agent_sessions as as_mod
from runtime.schemas import AGENT_SESSION_STATUSES, ensure_schema


_PROJECT_ROOT = Path(__file__).resolve().parents[2]
_CLI_PATH = _PROJECT_ROOT / "runtime" / "cli.py"


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


# ---------------------------------------------------------------------------
# create()
# ---------------------------------------------------------------------------


def test_create_inserts_active_row(conn):
    row = as_mod.create(conn, "sess-1", transport="claude_code")
    assert row["session_id"] == "sess-1"
    assert row["transport"] == "claude_code"
    assert row["status"] == "active"
    assert row["workflow_id"] is None
    assert row["transport_handle"] is None
    assert isinstance(row["created_at"], int)
    assert row["created_at"] == row["updated_at"]


def test_create_records_workflow_and_transport_handle(conn):
    row = as_mod.create(
        conn,
        "sess-wf",
        transport="tmux",
        transport_handle="pane-1",
        workflow_id="wf-42",
    )
    assert row["workflow_id"] == "wf-42"
    assert row["transport"] == "tmux"
    assert row["transport_handle"] == "pane-1"


def test_create_is_idempotent(conn):
    first = as_mod.create(conn, "sess-idem", transport="claude_code")
    second = as_mod.create(conn, "sess-idem", transport="claude_code")
    assert first == second
    rows = conn.execute(
        "SELECT COUNT(*) AS n FROM agent_sessions WHERE session_id = ?",
        ("sess-idem",),
    ).fetchone()
    assert rows["n"] == 1


def test_create_preserves_prior_workflow_on_idempotent_call(conn):
    """Second create call with different workflow_id must not overwrite."""
    as_mod.create(
        conn, "sess-preserve", transport="claude_code", workflow_id="wf-A"
    )
    second = as_mod.create(
        conn, "sess-preserve", transport="claude_code", workflow_id="wf-B"
    )
    # The original workflow_id stays bound — INSERT OR IGNORE semantics.
    assert second["workflow_id"] == "wf-A"


def test_create_rejects_empty_ids(conn):
    with pytest.raises(ValueError, match="session_id"):
        as_mod.create(conn, "", transport="claude_code")
    with pytest.raises(ValueError, match="transport"):
        as_mod.create(conn, "sess-x", transport="")


# ---------------------------------------------------------------------------
# get()
# ---------------------------------------------------------------------------


def test_get_roundtrips_created_row(conn):
    created = as_mod.create(conn, "sess-get", transport="claude_code")
    got = as_mod.get(conn, "sess-get")
    assert got == created


def test_get_unknown_session_raises(conn):
    with pytest.raises(ValueError, match="not found"):
        as_mod.get(conn, "sess-ghost")


# ---------------------------------------------------------------------------
# mark_completed / mark_dead / mark_orphaned state machine
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "method_name, expected_status",
    [
        ("mark_completed", "completed"),
        ("mark_dead", "dead"),
        ("mark_orphaned", "orphaned"),
    ],
)
def test_transition_from_active(conn, method_name, expected_status):
    as_mod.create(conn, f"sess-{expected_status}", transport="claude_code")
    result = getattr(as_mod, method_name)(conn, f"sess-{expected_status}")
    assert result["transitioned"] is True
    assert result["row"]["status"] == expected_status


@pytest.mark.parametrize(
    "method_name, expected_status",
    [
        ("mark_completed", "completed"),
        ("mark_dead", "dead"),
        ("mark_orphaned", "orphaned"),
    ],
)
def test_transition_is_idempotent_on_same_terminal(
    conn, method_name, expected_status
):
    as_mod.create(conn, f"sess-idem-{expected_status}", transport="claude_code")
    getattr(as_mod, method_name)(conn, f"sess-idem-{expected_status}")
    second = getattr(as_mod, method_name)(conn, f"sess-idem-{expected_status}")
    assert second["transitioned"] is False
    assert second["row"]["status"] == expected_status


def test_cross_terminal_transitions_raise(conn):
    """Once a session is in a terminal state, it cannot flip to another."""
    as_mod.create(conn, "sess-x1", transport="claude_code")
    as_mod.mark_completed(conn, "sess-x1")
    with pytest.raises(ValueError, match="invalid transition"):
        as_mod.mark_dead(conn, "sess-x1")
    with pytest.raises(ValueError, match="invalid transition"):
        as_mod.mark_orphaned(conn, "sess-x1")

    as_mod.create(conn, "sess-x2", transport="claude_code")
    as_mod.mark_dead(conn, "sess-x2")
    with pytest.raises(ValueError, match="invalid transition"):
        as_mod.mark_completed(conn, "sess-x2")
    with pytest.raises(ValueError, match="invalid transition"):
        as_mod.mark_orphaned(conn, "sess-x2")

    as_mod.create(conn, "sess-x3", transport="claude_code")
    as_mod.mark_orphaned(conn, "sess-x3")
    with pytest.raises(ValueError, match="invalid transition"):
        as_mod.mark_completed(conn, "sess-x3")
    with pytest.raises(ValueError, match="invalid transition"):
        as_mod.mark_dead(conn, "sess-x3")


def test_transitions_raise_on_unknown_session(conn):
    for meth in ("mark_completed", "mark_dead", "mark_orphaned"):
        with pytest.raises(ValueError, match="not found"):
            getattr(as_mod, meth)(conn, "sess-ghost")


# ---------------------------------------------------------------------------
# list_active
# ---------------------------------------------------------------------------


def test_list_active_returns_only_active(conn):
    as_mod.create(conn, "sess-la-1", transport="claude_code")
    as_mod.create(conn, "sess-la-2", transport="claude_code")
    as_mod.mark_completed(conn, "sess-la-2")
    as_mod.create(conn, "sess-la-3", transport="claude_code")
    as_mod.mark_dead(conn, "sess-la-3")
    as_mod.create(conn, "sess-la-4", transport="claude_code")
    as_mod.mark_orphaned(conn, "sess-la-4")

    rows = as_mod.list_active(conn)
    assert [r["session_id"] for r in rows] == ["sess-la-1"]


def test_list_active_filters_by_workflow_id(conn):
    as_mod.create(
        conn, "sess-wf-A", transport="claude_code", workflow_id="wf-A"
    )
    as_mod.create(
        conn, "sess-wf-B", transport="claude_code", workflow_id="wf-B"
    )
    as_mod.create(conn, "sess-wf-none", transport="claude_code")

    rows_a = as_mod.list_active(conn, workflow_id="wf-A")
    assert [r["session_id"] for r in rows_a] == ["sess-wf-A"]

    rows_b = as_mod.list_active(conn, workflow_id="wf-B")
    assert [r["session_id"] for r in rows_b] == ["sess-wf-B"]

    # No workflow filter returns all three.
    rows_all = as_mod.list_active(conn)
    ids = {r["session_id"] for r in rows_all}
    assert ids == {"sess-wf-A", "sess-wf-B", "sess-wf-none"}


# ---------------------------------------------------------------------------
# Vocabulary authority
# ---------------------------------------------------------------------------


def test_state_machine_uses_only_schema_declared_statuses():
    for current, allowed in as_mod._VALID_TRANSITIONS.items():
        assert current in AGENT_SESSION_STATUSES
        for nxt in allowed:
            assert nxt in AGENT_SESSION_STATUSES


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


def _seed_session_in_db(
    tmp_db: Path,
    session_id: str,
    workflow_id: str | None = None,
) -> None:
    c = sqlite3.connect(str(tmp_db))
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    as_mod.create(
        c, session_id, transport="claude_code", workflow_id=workflow_id
    )
    c.commit()
    c.close()


def test_cli_help_lists_agent_session_actions(tmp_path):
    env = os.environ.copy()
    env["CLAUDE_POLICY_DB"] = str(tmp_path / "cli.sqlite3")
    proc = subprocess.run(
        [sys.executable, str(_CLI_PATH), "agent-session", "--help"],
        cwd=str(_PROJECT_ROOT),
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0
    for action in (
        "get",
        "mark-completed",
        "mark-dead",
        "mark-orphaned",
        "list-active",
    ):
        assert action in proc.stdout, (
            f"'{action}' missing from agent-session --help"
        )


def test_cli_get_roundtrip(tmp_path):
    tmp_db = tmp_path / "cli.sqlite3"
    _seed_session_in_db(tmp_db, "cli-sess")
    out = _run_cli(tmp_db, "agent-session", "get", "--session-id", "cli-sess")
    assert out["status"] == "ok"
    assert out["session"]["session_id"] == "cli-sess"
    assert out["session"]["status"] == "active"


def test_cli_mark_completed_transitions_and_is_idempotent(tmp_path):
    tmp_db = tmp_path / "cli.sqlite3"
    _seed_session_in_db(tmp_db, "cli-done")
    first = _run_cli(
        tmp_db, "agent-session", "mark-completed", "--session-id", "cli-done"
    )
    assert first["transitioned"] is True
    assert first["session"]["status"] == "completed"

    second = _run_cli(
        tmp_db, "agent-session", "mark-completed", "--session-id", "cli-done"
    )
    assert second["transitioned"] is False
    assert second["session"]["status"] == "completed"


def test_cli_mark_dead_transitions(tmp_path):
    tmp_db = tmp_path / "cli.sqlite3"
    _seed_session_in_db(tmp_db, "cli-dead")
    out = _run_cli(
        tmp_db, "agent-session", "mark-dead", "--session-id", "cli-dead"
    )
    assert out["status"] == "ok"
    assert out["transitioned"] is True
    assert out["session"]["status"] == "dead"


def test_cli_mark_orphaned_transitions(tmp_path):
    tmp_db = tmp_path / "cli.sqlite3"
    _seed_session_in_db(tmp_db, "cli-orph")
    out = _run_cli(
        tmp_db, "agent-session", "mark-orphaned", "--session-id", "cli-orph"
    )
    assert out["status"] == "ok"
    assert out["transitioned"] is True
    assert out["session"]["status"] == "orphaned"


def test_cli_list_active_filters_by_workflow(tmp_path):
    tmp_db = tmp_path / "cli.sqlite3"
    _seed_session_in_db(tmp_db, "cli-a", workflow_id="wf-A")
    _seed_session_in_db(tmp_db, "cli-b", workflow_id="wf-B")

    out_all = _run_cli(tmp_db, "agent-session", "list-active")
    ids = {s["session_id"] for s in out_all["sessions"]}
    assert {"cli-a", "cli-b"}.issubset(ids)

    out_a = _run_cli(
        tmp_db, "agent-session", "list-active", "--workflow-id", "wf-A"
    )
    assert [s["session_id"] for s in out_a["sessions"]] == ["cli-a"]
