from __future__ import annotations

import sys
from pathlib import Path

import pytest

BRAID_V2_ROOT = Path(__file__).resolve().parents[2] / "ClauDEX" / "braid-v2"
if str(BRAID_V2_ROOT) not in sys.path:
    sys.path.insert(0, str(BRAID_V2_ROOT))

from braid2 import db, kernel  # noqa: E402


class FakeTmuxAdapter:
    def __init__(self) -> None:
        self.captures: dict[str, str] = {}

    def adopt(self, target: str) -> dict:
        return {
            "target": target,
            "session_name": "fake",
            "window_index": "1",
            "window_name": "main",
            "pane_index": "2",
            "pane_id": "%2",
            "pane_dead": False,
            "current_command": "claude",
            "cwd": "/tmp/project",
        }

    def spawn_window(self, *, session_name: str, window_name: str | None, cwd: str, command: str) -> dict:
        return {
            "target": f"{session_name}:1.1",
            "session_name": session_name,
            "window_index": "1",
            "window_name": window_name or "worker",
            "pane_index": "1",
            "pane_id": "%11",
            "pane_dead": False,
            "current_command": command.split()[0],
            "cwd": cwd,
        }

    def split_pane(self, *, target: str, cwd: str, command: str, orientation: str = "h") -> dict:
        session = target.split(":", 1)[0]
        return {
            "target": f"{session}:1.2",
            "session_name": session,
            "window_index": "1",
            "window_name": "worker",
            "pane_index": "2",
            "pane_id": "%12",
            "pane_dead": False,
            "current_command": command.split()[0],
            "cwd": cwd,
            "orientation": orientation,
        }

    def capture(self, *, target: str, lines: int | None = None) -> dict:
        return {
            "target": target,
            "session_name": target.split(":", 1)[0],
            "window_index": "1",
            "window_name": "worker",
            "pane_index": target.rsplit(".", 1)[1],
            "pane_id": "%99",
            "pane_dead": False,
            "current_command": "claude",
            "cwd": "/tmp/project",
            "text": self.captures.get(target, ""),
        }

    def send_text(self, *, target: str, text: str, enter: bool = True) -> dict:
        self.captures[target] = text + ("\n" if enter else "")
        return self.capture(target=target, lines=None)


@pytest.fixture
def conn(tmp_path: Path):
    database_path = tmp_path / "braid2.db"
    connection = db.open_db(database_path)
    yield connection
    connection.close()


def test_bundle_create_and_tree(conn):
    bundle = kernel.create_bundle(conn, bundle_type="coding_loop")
    tree = kernel.bundle_tree(conn, bundle["bundle_id"])

    assert tree["bundle"]["bundle_id"] == bundle["bundle_id"]
    assert tree["summary"]["counts"]["sessions"] == 0
    assert tree["children"] == []


def test_adopt_tmux_worker_creates_runtime_rows(conn):
    bundle = kernel.create_bundle(conn, bundle_type="coding_loop")
    adapter = FakeTmuxAdapter()

    result = kernel.adopt_tmux_worker(
        conn,
        bundle_id=bundle["bundle_id"],
        harness="claude_code",
        endpoint="fake:1.2",
        role="worker",
        cwd=None,
        label="adopted-worker",
        adapter=adapter,
    )

    assert result["bundle"]["status"] == "active"
    assert result["session"]["transport"] == "tmux"
    assert result["session"]["adopted"] == 1
    assert result["endpoint"]["endpoint_ref"] == "fake:1.2"
    assert result["seat"]["role"] == "worker"


def test_spawn_tmux_supervised_bundle_creates_child_bundle_threads_and_sessions(conn):
    adapter = FakeTmuxAdapter()
    parent_bundle = kernel.create_bundle(conn, bundle_type="coding_loop", status="active")
    dispatcher_session = kernel.create_session(
        conn,
        bundle_id=parent_bundle["bundle_id"],
        harness="codex",
        transport="tmux",
    )
    dispatcher_seat = kernel.create_seat(
        conn,
        bundle_id=parent_bundle["bundle_id"],
        session_id=dispatcher_session["session_id"],
        role="dispatcher",
        label="meta-dispatch",
    )

    result = kernel.spawn_tmux_supervised_bundle(
        conn,
        parent_bundle_id=parent_bundle["bundle_id"],
        requested_by_seat=dispatcher_seat["seat_id"],
        worker_harness="claude_code",
        supervisor_harness="codex",
        goal_ref="goal-1",
        work_item_ref="wi-1",
        worker_cwd="/tmp/project",
        worker_command="claude --dangerously-skip-permissions",
        supervisor_cwd="/tmp/project",
        supervisor_command="codex --profile supervisor",
        tmux_session="braid2-test",
        window_name="child-a",
        adapter=adapter,
    )

    assert result["bundle"]["status"] == "active"
    assert result["worker"]["seat"]["role"] == "worker"
    assert result["supervisor"]["seat"]["role"] == "supervisor"
    assert result["local_thread"]["target_seat_id"] == result["worker"]["seat"]["seat_id"]
    assert result["parent_thread"]["target_bundle_id"] == result["bundle"]["bundle_id"]
    assert result["spawn_request"]["status"] == "fulfilled"


def test_observe_tmux_seat_opens_and_clears_gates(conn):
    adapter = FakeTmuxAdapter()
    bundle = kernel.create_bundle(conn, bundle_type="coding_loop", status="active")
    session = kernel.create_session(
        conn,
        bundle_id=bundle["bundle_id"],
        harness="claude_code",
        transport="tmux",
    )
    kernel.attach_endpoint(
        conn,
        session_id=session["session_id"],
        adapter_name="tmux",
        endpoint_kind="pane",
        endpoint_ref="gate:1.2",
        metadata={"target": "gate:1.2"},
    )
    seat = kernel.create_seat(
        conn,
        bundle_id=bundle["bundle_id"],
        session_id=session["session_id"],
        role="worker",
    )
    kernel.issue_dispatch_attempt(
        conn,
        seat_id=seat["seat_id"],
        instruction_ref="/tmp/instruction.txt",
    )

    adapter.captures["gate:1.2"] = """
Do you want to make this edit to CLAUDE.md?
❯ 1. Yes
  2. No
"""
    first = kernel.observe_tmux_seat(conn, seat_id=seat["seat_id"], adapter=adapter)
    assert first["gate"]["status"] == "open"
    assert kernel.get_seat(conn, seat["seat_id"])["status"] == "blocked"

    adapter.captures["gate:1.2"] = "normal working output"
    second = kernel.observe_tmux_seat(conn, seat_id=seat["seat_id"], adapter=adapter)
    assert second["gate"] is None
    assert second["expired_gate_count"] == 1
    assert kernel.get_seat(conn, seat["seat_id"])["status"] == "active"


def test_controller_sweep_times_out_attempts_and_opens_findings(conn):
    bundle = kernel.create_bundle(conn, bundle_type="coding_loop", status="active")
    session = kernel.create_session(
        conn,
        bundle_id=bundle["bundle_id"],
        harness="claude_code",
        transport="tmux",
    )
    seat = kernel.create_seat(
        conn,
        bundle_id=bundle["bundle_id"],
        session_id=session["session_id"],
        role="worker",
    )
    kernel.issue_dispatch_attempt(
        conn,
        seat_id=seat["seat_id"],
        instruction_ref="/tmp/instruction.txt",
        timeout_at=kernel.now_ts() - 5,
    )

    sweep = kernel.controller_sweep(conn, bundle_id=bundle["bundle_id"])

    assert sweep["health"] == "needs_attention"
    assert len(sweep["timed_out_attempts"]) == 1
    assert sweep["summaries"][0]["counts"]["open_findings"] == 1
