"""Tests for runtime/core/pending_agent_requests.py.

Covers the table helpers (write_pending_request, consume_pending_request) and
the CLI entry-points used by hooks/pre-agent.sh and hooks/subagent-start.sh.

@decision DEC-CLAUDEX-SA-CARRIER-001
Title: pending_agent_requests: SQLite carrier for SubagentStart contract fields
Status: accepted
Rationale: See runtime/core/pending_agent_requests.py module docstring.
"""

from __future__ import annotations

import json
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

from runtime.core.pending_agent_requests import (
    consume_pending_request,
    write_pending_request,
)
from runtime.schemas import ensure_schema

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_MODULE = str(_REPO_ROOT / "runtime" / "core" / "pending_agent_requests.py")

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def db(tmp_path: Path):
    db_path = tmp_path / "state.db"
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        ensure_schema(conn)
        conn.commit()
    finally:
        conn.close()
    return db_path


def _open(db_path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    return conn


def _sample(**overrides) -> dict:
    base = dict(
        session_id="session-abc",
        agent_type="planner",
        workflow_id="wf-001",
        stage_id="planner",
        goal_id="GOAL-1",
        work_item_id="WI-1",
        decision_scope="kernel",
        generated_at=1_700_000_000,
    )
    base.update(overrides)
    return base


# ---------------------------------------------------------------------------
# write_pending_request
# ---------------------------------------------------------------------------


class TestWritePendingRequest:
    def test_row_visible_after_write(self, db):
        conn = _open(db)
        try:
            write_pending_request(conn, **_sample())
            row = conn.execute(
                "SELECT * FROM pending_agent_requests WHERE session_id=? AND agent_type=?",
                ("session-abc", "planner"),
            ).fetchone()
        finally:
            conn.close()
        assert row is not None

    def test_all_contract_fields_stored(self, db):
        conn = _open(db)
        try:
            write_pending_request(conn, **_sample())
            row = conn.execute(
                "SELECT workflow_id, stage_id, goal_id, work_item_id, decision_scope, generated_at "
                "FROM pending_agent_requests WHERE session_id=? AND agent_type=?",
                ("session-abc", "planner"),
            ).fetchone()
        finally:
            conn.close()
        assert row["workflow_id"] == "wf-001"
        assert row["stage_id"] == "planner"
        assert row["goal_id"] == "GOAL-1"
        assert row["work_item_id"] == "WI-1"
        assert row["decision_scope"] == "kernel"
        assert row["generated_at"] == 1_700_000_000

    def test_written_at_auto_populated(self, db):
        conn = _open(db)
        try:
            write_pending_request(conn, **_sample())
            row = conn.execute(
                "SELECT written_at FROM pending_agent_requests WHERE session_id=? AND agent_type=?",
                ("session-abc", "planner"),
            ).fetchone()
        finally:
            conn.close()
        assert isinstance(row["written_at"], int) and row["written_at"] > 0

    def test_insert_or_replace_overwrites_stale_row(self, db):
        conn = _open(db)
        try:
            write_pending_request(conn, **_sample(workflow_id="wf-old"))
            write_pending_request(conn, **_sample(workflow_id="wf-new"))
            row = conn.execute(
                "SELECT workflow_id FROM pending_agent_requests WHERE session_id=? AND agent_type=?",
                ("session-abc", "planner"),
            ).fetchone()
            count = conn.execute("SELECT COUNT(*) FROM pending_agent_requests").fetchone()[0]
        finally:
            conn.close()
        assert row["workflow_id"] == "wf-new"
        assert count == 1

    def test_different_agent_types_are_independent_rows(self, db):
        conn = _open(db)
        try:
            write_pending_request(conn, **_sample(agent_type="planner"))
            write_pending_request(conn, **_sample(agent_type="implementer"))
            count = conn.execute("SELECT COUNT(*) FROM pending_agent_requests").fetchone()[0]
        finally:
            conn.close()
        assert count == 2

    def test_different_sessions_are_independent_rows(self, db):
        conn = _open(db)
        try:
            write_pending_request(conn, **_sample(session_id="sess-A"))
            write_pending_request(conn, **_sample(session_id="sess-B"))
            count = conn.execute("SELECT COUNT(*) FROM pending_agent_requests").fetchone()[0]
        finally:
            conn.close()
        assert count == 2


# ---------------------------------------------------------------------------
# consume_pending_request
# ---------------------------------------------------------------------------


class TestConsumePendingRequest:
    def test_returns_dict_when_row_exists(self, db):
        conn = _open(db)
        try:
            write_pending_request(conn, **_sample())
            result = consume_pending_request(conn, session_id="session-abc", agent_type="planner")
        finally:
            conn.close()
        assert isinstance(result, dict)

    def test_returns_all_six_contract_fields(self, db):
        conn = _open(db)
        try:
            write_pending_request(conn, **_sample())
            result = consume_pending_request(conn, session_id="session-abc", agent_type="planner")
        finally:
            conn.close()
        assert result["workflow_id"] == "wf-001"
        assert result["stage_id"] == "planner"
        assert result["goal_id"] == "GOAL-1"
        assert result["work_item_id"] == "WI-1"
        assert result["decision_scope"] == "kernel"
        assert result["generated_at"] == 1_700_000_000

    def test_row_deleted_after_consume(self, db):
        conn = _open(db)
        try:
            write_pending_request(conn, **_sample())
            consume_pending_request(conn, session_id="session-abc", agent_type="planner")
            count = conn.execute("SELECT COUNT(*) FROM pending_agent_requests").fetchone()[0]
        finally:
            conn.close()
        assert count == 0

    def test_double_consume_returns_none(self, db):
        conn = _open(db)
        try:
            write_pending_request(conn, **_sample())
            consume_pending_request(conn, session_id="session-abc", agent_type="planner")
            second = consume_pending_request(conn, session_id="session-abc", agent_type="planner")
        finally:
            conn.close()
        assert second is None

    def test_consume_nonexistent_returns_none(self, db):
        conn = _open(db)
        try:
            result = consume_pending_request(conn, session_id="ghost", agent_type="planner")
        finally:
            conn.close()
        assert result is None

    def test_consume_wrong_agent_type_returns_none(self, db):
        conn = _open(db)
        try:
            write_pending_request(conn, **_sample(agent_type="planner"))
            result = consume_pending_request(conn, session_id="session-abc", agent_type="implementer")
        finally:
            conn.close()
        assert result is None

    def test_consume_does_not_delete_sibling_row(self, db):
        conn = _open(db)
        try:
            write_pending_request(conn, **_sample(agent_type="planner"))
            write_pending_request(conn, **_sample(agent_type="implementer"))
            consume_pending_request(conn, session_id="session-abc", agent_type="planner")
            remaining = conn.execute(
                "SELECT agent_type FROM pending_agent_requests WHERE session_id=?",
                ("session-abc",),
            ).fetchall()
        finally:
            conn.close()
        assert len(remaining) == 1
        assert remaining[0]["agent_type"] == "implementer"


# ---------------------------------------------------------------------------
# CLI — write command
# ---------------------------------------------------------------------------


def _run_cli(*args: str, input_text: str | None = None) -> tuple[int, str, str]:
    result = subprocess.run(
        [sys.executable, _MODULE, *args],
        input=input_text,
        capture_output=True,
        text=True,
        cwd=str(_REPO_ROOT),
    )
    return result.returncode, result.stdout, result.stderr


class TestCliWrite:
    def test_write_succeeds_with_valid_json(self, db):
        contract = json.dumps(
            {
                "workflow_id": "wf-cli",
                "stage_id": "planner",
                "goal_id": "GOAL-CLI",
                "work_item_id": "WI-CLI",
                "decision_scope": "kernel",
                "generated_at": 1_700_000_001,
            }
        )
        rc, _out, _err = _run_cli("write", str(db), "sess-cli", "planner", contract)
        assert rc == 0

    def test_write_row_readable_after_cli_write(self, db):
        contract = json.dumps(
            {
                "workflow_id": "wf-cli",
                "stage_id": "planner",
                "goal_id": "GOAL-CLI",
                "work_item_id": "WI-CLI",
                "decision_scope": "kernel",
                "generated_at": 1_700_000_001,
            }
        )
        _run_cli("write", str(db), "sess-cli", "planner", contract)
        conn = _open(db)
        try:
            row = conn.execute(
                "SELECT goal_id FROM pending_agent_requests WHERE session_id=? AND agent_type=?",
                ("sess-cli", "planner"),
            ).fetchone()
        finally:
            conn.close()
        assert row is not None
        assert row["goal_id"] == "GOAL-CLI"

    def test_write_exits_nonzero_on_invalid_json(self, db):
        rc, _out, err = _run_cli("write", str(db), "sess-cli", "planner", "NOT_JSON")
        assert rc != 0
        assert "invalid contract JSON" in err

    def test_write_exits_nonzero_on_missing_field(self, db):
        contract = json.dumps({"workflow_id": "wf-cli"})  # missing five fields
        rc, _out, err = _run_cli("write", str(db), "sess-cli", "planner", contract)
        assert rc != 0
        assert "missing fields" in err

    def test_write_wrong_arg_count_exits_nonzero(self, db):
        rc, _out, err = _run_cli("write", str(db), "sess-cli")
        assert rc != 0


# ---------------------------------------------------------------------------
# CLI — consume command
# ---------------------------------------------------------------------------


class TestCliConsume:
    def test_consume_prints_json_when_row_exists(self, db):
        conn = _open(db)
        try:
            write_pending_request(conn, **_sample(session_id="sess-cons"))
        finally:
            conn.close()
        rc, out, _err = _run_cli("consume", str(db), "sess-cons", "planner")
        assert rc == 0
        data = json.loads(out.strip())
        assert data["workflow_id"] == "wf-001"

    def test_consume_prints_nothing_when_row_absent(self, db):
        rc, out, _err = _run_cli("consume", str(db), "ghost-sess", "planner")
        assert rc == 0
        assert out.strip() == ""

    def test_consume_deletes_row(self, db):
        conn = _open(db)
        try:
            write_pending_request(conn, **_sample(session_id="sess-del"))
        finally:
            conn.close()
        _run_cli("consume", str(db), "sess-del", "planner")
        rc2, out2, _err2 = _run_cli("consume", str(db), "sess-del", "planner")
        assert rc2 == 0
        assert out2.strip() == ""

    def test_consume_wrong_arg_count_exits_nonzero(self, db):
        rc, _out, err = _run_cli("consume", str(db), "sess-cli")
        assert rc != 0

    def test_unknown_command_exits_nonzero(self, db):
        rc, _out, err = _run_cli("bogus", str(db))
        assert rc != 0
        assert "unknown command" in err
