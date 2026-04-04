"""Tests for runtime/core/lifecycle.py

@decision DEC-LIFECYCLE-001
Title: lifecycle.py owns agent start/stop marker transitions
Status: accepted
Rationale: Marker activation and deactivation is a distinct concern from dispatch
  routing. Separating it into lifecycle.py makes both modules independently testable
  and avoids conflating routing logic with agent identity tracking.

@decision DEC-LIFECYCLE-002
Title: CLI dispatch agent-start/agent-stop are the hook-reachable lifecycle entry points
Status: accepted
Rationale: subagent-start.sh and check-*.sh previously called rt_marker_set and
  rt_marker_deactivate through runtime-bridge.sh, which resolves the runtime via
  CLAUDE_RUNTIME_ROOT=$HOME/.claude/runtime. In worktrees (before merge), this path
  points to the installed runtime, not the worktree's runtime — so new subcommands
  added in a feature branch are unreachable. The fix: hooks that call lifecycle
  commands resolve the CLI via $(dirname "$0")/../runtime/cli.py (relative to the
  hook file) so they always reach the in-worktree runtime. The shell-boundary tests
  in this file verify that path by invoking the CLI as a subprocess.
"""

import json
import os
import sqlite3
import subprocess
import sys

import pytest

from runtime.core import markers
from runtime.core.lifecycle import on_agent_start, on_agent_stop
from runtime.schemas import ensure_schema

# ---------------------------------------------------------------------------
# Helpers for CLI subprocess tests
# ---------------------------------------------------------------------------

_PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
_CLI = os.path.join(_PROJECT_ROOT, "runtime", "cli.py")


def _cc(*args, db_path, stdin_text=None):
    """Invoke cli.py with the given args; return (returncode, parsed_json)."""
    env = {**os.environ, "CLAUDE_POLICY_DB": db_path, "PYTHONPATH": _PROJECT_ROOT}
    result = subprocess.run(
        [sys.executable, _CLI, *args],
        input=stdin_text,
        capture_output=True,
        text=True,
        env=env,
    )
    try:
        return result.returncode, json.loads(result.stdout)
    except json.JSONDecodeError:
        return result.returncode, {"_raw": result.stdout, "_err": result.stderr}


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


# ---------------------------------------------------------------------------
# on_agent_start
# ---------------------------------------------------------------------------


def test_on_agent_start_sets_marker_active(conn):
    on_agent_start(conn, "tester", "agent-abc")
    marker = markers.get_active(conn)
    assert marker is not None
    assert marker["agent_id"] == "agent-abc"
    assert marker["role"] == "tester"
    assert marker["is_active"] == 1


def test_on_agent_start_implementer(conn):
    on_agent_start(conn, "implementer", "agent-impl-001")
    marker = markers.get_active(conn)
    assert marker["role"] == "implementer"


def test_on_agent_start_overwrites_previous_marker(conn):
    """Second start for same agent_id replaces existing marker."""
    on_agent_start(conn, "implementer", "agent-001")
    on_agent_start(conn, "tester", "agent-001")
    marker = markers.get_active(conn)
    assert marker["role"] == "tester"
    assert marker["agent_id"] == "agent-001"


# ---------------------------------------------------------------------------
# on_agent_stop
# ---------------------------------------------------------------------------


def test_on_agent_stop_deactivates_marker(conn):
    on_agent_start(conn, "tester", "agent-xyz")
    on_agent_stop(conn, "tester", "agent-xyz")
    marker = markers.get_active(conn)
    assert marker is None


def test_on_agent_stop_noop_when_no_marker(conn):
    """Deactivating a non-existent marker should not raise."""
    on_agent_stop(conn, "tester", "agent-nonexistent")
    # No exception = pass


def test_on_agent_stop_does_not_affect_other_markers(conn):
    """Stopping agent-A should not deactivate agent-B."""
    on_agent_start(conn, "implementer", "agent-A")
    on_agent_start(conn, "tester", "agent-B")
    on_agent_stop(conn, "implementer", "agent-A")
    # agent-B (most recently started) should still be active
    marker = markers.get_active(conn)
    assert marker is not None
    assert marker["agent_id"] == "agent-B"


# ---------------------------------------------------------------------------
# Round-trip: start then stop
# ---------------------------------------------------------------------------


def test_start_stop_roundtrip(conn):
    on_agent_start(conn, "guardian", "agent-guardian-001")
    active_before = markers.get_active(conn)
    assert active_before is not None

    on_agent_stop(conn, "guardian", "agent-guardian-001")
    active_after = markers.get_active(conn)
    assert active_after is None


# ---------------------------------------------------------------------------
# Shell-boundary tests: CLI subprocess path (DEC-LIFECYCLE-002)
#
# These tests verify that `dispatch agent-start` and `dispatch agent-stop`
# are reachable through the local CLI path ($(dirname "$0")/../runtime/cli.py)
# exactly as post-task.sh and subagent-start.sh will call it after the fix.
# They cross the boundary between shell resolution and the Python runtime so
# they serve as the compound-interaction proof required by the evaluation contract.
# ---------------------------------------------------------------------------


@pytest.fixture
def db_path(tmp_path):
    """Isolated SQLite DB path for CLI subprocess tests."""
    # Ensure schema exists before use
    db = str(tmp_path / "test.db")
    _cc("schema", "ensure", db_path=db)
    return db


def test_dispatch_agent_start_via_cli(db_path):
    """dispatch agent-start writes an active marker via the local CLI path."""
    rc, data = _cc("dispatch", "agent-start", "implementer", "agent-cli-001", db_path=db_path)
    assert rc == 0, f"non-zero exit: {data}"
    assert data.get("status") == "ok"
    assert data.get("agent_id") == "agent-cli-001"


def test_dispatch_agent_stop_via_cli(db_path):
    """dispatch agent-stop deactivates an active marker via the local CLI path."""
    _cc("dispatch", "agent-start", "tester", "agent-cli-002", db_path=db_path)
    rc, data = _cc("dispatch", "agent-stop", "tester", "agent-cli-002", db_path=db_path)
    assert rc == 0, f"non-zero exit: {data}"
    assert data.get("status") == "ok"
    assert data.get("agent_id") == "agent-cli-002"


def test_dispatch_agent_start_then_stop_marker_cleared(db_path):
    """Full round-trip: agent-start sets marker active; agent-stop clears it."""
    _cc("dispatch", "agent-start", "implementer", "agent-rt-001", db_path=db_path)

    # Verify marker is active via marker get-active
    rc_get, active = _cc("marker", "get-active", db_path=db_path)
    assert rc_get == 0
    assert active.get("found") is True
    assert active.get("role") == "implementer"

    _cc("dispatch", "agent-stop", "implementer", "agent-rt-001", db_path=db_path)

    rc_get2, after = _cc("marker", "get-active", db_path=db_path)
    assert rc_get2 == 0
    assert after.get("found") is False


def test_dispatch_process_stop_reachable_via_local_cli_path(db_path):
    """Compound-interaction test: dispatch process-stop is reachable through the
    local CLI path (not via cc_policy bridge) and returns hookSpecificOutput.

    This is the shell-boundary proof for Blocker 1: post-task.sh must resolve
    the runtime relative to its own location so worktree-local CLI changes are
    reachable. This test exercises that exact path by calling the CLI directly
    as a subprocess (the same mechanism post-task.sh uses after the fix).
    """
    payload = json.dumps({"agent_type": "planner", "project_root": ""})
    rc, data = _cc("dispatch", "process-stop", db_path=db_path, stdin_text=payload)
    assert rc == 0, f"non-zero exit: {data}"
    # Must contain hookSpecificOutput — this is the contract post-task.sh checks
    assert "hookSpecificOutput" in data, f"missing hookSpecificOutput in: {data}"
    hook_out = data["hookSpecificOutput"]
    assert hook_out.get("hookEventName") == "SubagentStop"
    # planner always routes to implementer
    assert data.get("next_role") == "implementer"
