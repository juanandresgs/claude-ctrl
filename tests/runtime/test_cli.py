"""Integration tests for runtime/cli.py via subprocess.

Each test invokes `python3 runtime/cli.py` with real arguments and validates
JSON output. Uses a temporary file-based SQLite DB (not the user's state.db).
This is the compound-interaction test that exercises the real production
sequence end-to-end through the CLI boundary.

@decision DEC-RT-001
Title: Canonical SQLite schema for all shared workflow state
Status: accepted
Rationale: Subprocess tests verify the full stack: arg parsing -> domain
  module -> SQLite -> JSON serialization. They catch integration failures
  that unit tests (which call domain functions directly) cannot catch, such
  as import errors, argparse misconfiguration, or wrong field names in JSON
  output. Each test uses a fresh tmp DB via CLAUDE_POLICY_DB env override.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pytest

# Path to the cli.py under test
_WORKTREE = Path(__file__).resolve().parent.parent.parent
_CLI = str(_WORKTREE / "runtime" / "cli.py")


def run(args: list[str], db_path: str) -> tuple[int, dict]:
    """Run cc-policy with the given args, return (exit_code, parsed_json)."""
    env = {**os.environ, "CLAUDE_POLICY_DB": db_path, "PYTHONPATH": str(_WORKTREE)}
    result = subprocess.run(
        [sys.executable, _CLI] + args,
        capture_output=True,
        text=True,
        env=env,
    )
    # Success output on stdout; error output on stderr
    output = result.stdout.strip() or result.stderr.strip()
    try:
        parsed = json.loads(output)
    except json.JSONDecodeError:
        parsed = {"_raw": output}
    return result.returncode, parsed


@pytest.fixture
def db(tmp_path):
    """Return a path to a fresh temporary database file."""
    return str(tmp_path / "test-state.db")


# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

def test_schema_ensure(db):
    code, out = run(["schema", "ensure"], db)
    assert code == 0
    assert out["status"] == "ok"


def test_init_alias(db):
    code, out = run(["init"], db)
    assert code == 0
    assert out["status"] == "ok"


# ---------------------------------------------------------------------------
# Proof
# ---------------------------------------------------------------------------

def test_proof_get_missing(db):
    code, out = run(["proof", "get", "wf-x"], db)
    assert code == 0
    # proof get returns status="idle" (the proof status) when not found,
    # not status="ok" — "ok" is the envelope default but proof status wins
    assert out["found"] is False
    assert out["workflow_id"] == "wf-x"
    # status field reflects proof status ("idle"), not envelope status
    assert out["status"] == "idle"


def test_proof_set_and_get(db):
    code, out = run(["proof", "set", "wf-1", "pending"], db)
    assert code == 0
    # proof set returns the new status as the "status" field
    assert out["workflow_id"] == "wf-1"
    assert out["status"] == "pending"

    code, out = run(["proof", "get", "wf-1"], db)
    assert code == 0
    assert out["status"] == "pending"
    assert out["found"] is True


def test_proof_list(db):
    run(["proof", "set", "wf-a", "idle"], db)
    run(["proof", "set", "wf-b", "verified"], db)
    code, out = run(["proof", "list"], db)
    assert code == 0
    assert out["count"] == 2


# ---------------------------------------------------------------------------
# Marker
# ---------------------------------------------------------------------------

def test_marker_set_and_get_active(db):
    code, out = run(["marker", "set", "agent-1", "implementer"], db)
    assert code == 0
    assert out["status"] == "ok"

    code, out = run(["marker", "get-active"], db)
    assert code == 0
    assert out["found"] is True
    assert out["role"] == "implementer"


def test_marker_deactivate(db):
    run(["marker", "set", "agent-1", "implementer"], db)
    code, out = run(["marker", "deactivate", "agent-1"], db)
    assert code == 0

    code, out = run(["marker", "get-active"], db)
    assert out["found"] is False


def test_marker_get_active_empty(db):
    code, out = run(["marker", "get-active"], db)
    assert code == 0
    assert out["found"] is False


# ---------------------------------------------------------------------------
# Event
# ---------------------------------------------------------------------------

def test_event_emit_and_query(db):
    code, out = run(["event", "emit", "tkt.start", "--source", "tkt-006", "--detail", "began"], db)
    assert code == 0
    assert out["status"] == "ok"
    assert isinstance(out["id"], int)

    code, out = run(["event", "query"], db)
    assert code == 0
    assert out["count"] == 1
    assert out["items"][0]["type"] == "tkt.start"


def test_event_query_type_filter(db):
    run(["event", "emit", "type.a"], db)
    run(["event", "emit", "type.b"], db)
    code, out = run(["event", "query", "--type", "type.a"], db)
    assert code == 0
    assert out["count"] == 1
    assert out["items"][0]["type"] == "type.a"


def test_event_query_limit(db):
    for _ in range(5):
        run(["event", "emit", "evt"], db)
    code, out = run(["event", "query", "--limit", "2"], db)
    assert code == 0
    assert out["count"] == 2


# ---------------------------------------------------------------------------
# Worktree
# ---------------------------------------------------------------------------

def test_worktree_register_list_remove(db):
    code, out = run(["worktree", "register", "/path/a", "feature/a", "--ticket", "TKT-1"], db)
    assert code == 0

    code, out = run(["worktree", "list"], db)
    assert code == 0
    assert out["count"] == 1
    assert out["items"][0]["path"] == "/path/a"

    code, out = run(["worktree", "remove", "/path/a"], db)
    assert code == 0

    code, out = run(["worktree", "list"], db)
    assert out["count"] == 0


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

def test_dispatch_full_lifecycle(db):
    # Start a cycle
    code, out = run(["dispatch", "cycle-start", "INIT-002"], db)
    assert code == 0
    cycle_id = out["id"]

    # current-cycle returns it
    code, out = run(["dispatch", "cycle-current"], db)
    assert out["found"] is True
    assert out["initiative"] == "INIT-002"

    # Enqueue an item
    code, out = run(["dispatch", "enqueue", "implementer", "--ticket", "TKT-6"], db)
    assert code == 0
    qid = out["id"]

    # next returns it
    code, out = run(["dispatch", "next"], db)
    assert out["found"] is True
    assert out["id"] == qid

    # start it
    code, out = run(["dispatch", "start", str(qid)], db)
    assert code == 0

    # next now empty
    code, out = run(["dispatch", "next"], db)
    assert out["found"] is False

    # complete it
    code, out = run(["dispatch", "complete", str(qid)], db)
    assert code == 0


# ---------------------------------------------------------------------------
# Statusline
# ---------------------------------------------------------------------------

def test_statusline_snapshot_keys(db):
    # Populate some state
    run(["proof", "set", "wf-1", "verified"], db)
    run(["marker", "set", "agent-1", "implementer"], db)
    run(["worktree", "register", "/wt/a", "feature/a"], db)

    code, out = run(["statusline", "snapshot"], db)
    assert code == 0
    assert out["status"] == "ok"
    for key in ("proof_status", "active_agent", "worktree_count",
                "dispatch_status", "dispatch_initiative",
                "recent_event_count", "snapshot_at"):
        assert key in out, f"missing key: {key}"


def test_statusline_snapshot_empty_db(db):
    """Snapshot must return safe defaults on an empty database."""
    code, out = run(["statusline", "snapshot"], db)
    assert code == 0
    assert out["proof_status"] == "idle"
    assert out["active_agent"] is None
    assert out["worktree_count"] == 0


# ---------------------------------------------------------------------------
# Latency
# ---------------------------------------------------------------------------

def test_proof_get_latency_under_100ms(db):
    """cc-policy proof get must complete in under 100ms on a warm DB."""
    # Warm up: ensure schema exists
    run(["proof", "set", "wf-lat", "idle"], db)

    start = time.perf_counter()
    code, out = run(["proof", "get", "wf-lat"], db)
    elapsed_ms = (time.perf_counter() - start) * 1000

    assert code == 0
    print(f"\n  proof get latency: {elapsed_ms:.1f}ms")
    assert elapsed_ms < 100, f"latency {elapsed_ms:.1f}ms exceeds 100ms threshold"
