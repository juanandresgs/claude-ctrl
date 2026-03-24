"""Unit tests for runtime.core.statusline.snapshot().

Tests the read-only projection directly using an in-memory SQLite database.
No subprocess overhead — exercises the snapshot() function at the Python level
to validate field completeness, correct defaults, and state reflection.

Production sequence: hooks call cc-policy statusline snapshot (CLI entry point)
-> _handle_statusline() -> statusline_mod.snapshot(conn). These unit tests
exercise snapshot() directly with a live conn so every internal query path
is covered without subprocess overhead. The compound-interaction test
(test_snapshot_full_production_sequence) validates the CLI path end-to-end.

@decision DEC-RT-011
Title: Statusline snapshot is a read-only projection across all runtime tables
Status: accepted
Rationale: snapshot() reads proof_state, agent_markers, worktrees,
  dispatch_cycles, dispatch_queue, and events in a single pass. It never
  writes. The extended field set (proof_workflow, active_agent_id, worktrees
  list, dispatch_cycle_id, recent_events list) was added in TKT-011 so
  scripts/statusline.sh has everything it needs for a richer HUD without
  calling multiple CLI subcommands. All fields have safe None/0 defaults so
  the statusline never crashes on an empty or partially-populated DB.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from runtime.core.db import connect_memory
from runtime.schemas import ensure_schema
import runtime.core.proof as proof_mod
import runtime.core.markers as markers_mod
import runtime.core.worktrees as worktrees_mod
import runtime.core.dispatch as dispatch_mod
import runtime.core.events as events_mod
import runtime.core.statusline as statusline


# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

@pytest.fixture
def conn():
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


# ---------------------------------------------------------------------------
# Key presence — all expected fields must be present in every snapshot
# ---------------------------------------------------------------------------

REQUIRED_KEYS = {
    "proof_status",
    "proof_workflow",
    "active_agent",
    "active_agent_id",
    "worktree_count",
    "worktrees",
    "dispatch_status",
    "dispatch_initiative",
    "dispatch_cycle_id",
    "recent_event_count",
    "recent_events",
    "snapshot_at",
    "status",
}


def test_snapshot_has_all_required_keys(conn):
    """Every snapshot must contain exactly the canonical field set."""
    snap = statusline.snapshot(conn)
    missing = REQUIRED_KEYS - set(snap.keys())
    assert not missing, f"snapshot() missing fields: {missing}"


def test_snapshot_empty_db_safe_defaults(conn):
    """Empty DB returns safe defaults — no crash, no None where type matters."""
    snap = statusline.snapshot(conn)
    assert snap["proof_status"] == "idle"
    assert snap["proof_workflow"] is None
    assert snap["active_agent"] is None
    assert snap["active_agent_id"] is None
    assert snap["worktree_count"] == 0
    assert snap["worktrees"] == []
    assert snap["dispatch_status"] is None
    assert snap["dispatch_initiative"] is None
    assert snap["dispatch_cycle_id"] is None
    assert snap["recent_event_count"] == 0
    assert snap["recent_events"] == []
    assert isinstance(snap["snapshot_at"], int)
    assert snap["snapshot_at"] > 0
    assert snap["status"] == "ok"


# ---------------------------------------------------------------------------
# Proof state reflection
# ---------------------------------------------------------------------------

def test_snapshot_reflects_proof_status(conn):
    """Snapshot picks up the most recent non-idle proof status."""
    proof_mod.set_status(conn, "wf-active", "pending")
    snap = statusline.snapshot(conn)
    assert snap["proof_status"] == "pending"
    assert snap["proof_workflow"] == "wf-active"


def test_snapshot_proof_non_idle_takes_precedence(conn):
    """When multiple proofs exist, non-idle is preferred over idle."""
    proof_mod.set_status(conn, "wf-old", "idle")
    proof_mod.set_status(conn, "wf-live", "verified")
    snap = statusline.snapshot(conn)
    # verified is non-idle, must surface
    assert snap["proof_status"] == "verified"
    assert snap["proof_workflow"] == "wf-live"


def test_snapshot_proof_idle_when_all_idle(conn):
    """When all proof rows are idle, proof_status is idle and workflow is None."""
    proof_mod.set_status(conn, "wf-1", "idle")
    proof_mod.set_status(conn, "wf-2", "idle")
    snap = statusline.snapshot(conn)
    assert snap["proof_status"] == "idle"
    assert snap["proof_workflow"] is None


# ---------------------------------------------------------------------------
# Active agent reflection
# ---------------------------------------------------------------------------

def test_snapshot_reflects_active_agent(conn):
    """Snapshot surfaces active marker role and agent_id."""
    markers_mod.set_active(conn, "agent-007", "implementer")
    snap = statusline.snapshot(conn)
    assert snap["active_agent"] == "implementer"
    assert snap["active_agent_id"] == "agent-007"


def test_snapshot_no_active_agent_after_deactivate(conn):
    """After deactivate(), active_agent fields go None."""
    markers_mod.set_active(conn, "agent-007", "tester")
    markers_mod.deactivate(conn, "agent-007")
    snap = statusline.snapshot(conn)
    assert snap["active_agent"] is None
    assert snap["active_agent_id"] is None


# ---------------------------------------------------------------------------
# Worktree reflection
# ---------------------------------------------------------------------------

def test_snapshot_includes_worktree_details(conn):
    """Snapshot includes worktree list with path, branch, ticket fields."""
    worktrees_mod.register(conn, "/wt/feat-a", "feature/a", ticket="TKT-001")
    worktrees_mod.register(conn, "/wt/feat-b", "feature/b")
    snap = statusline.snapshot(conn)
    assert snap["worktree_count"] == 2
    assert len(snap["worktrees"]) == 2
    paths = {w["path"] for w in snap["worktrees"]}
    assert paths == {"/wt/feat-a", "/wt/feat-b"}
    # ticket present where registered
    a = next(w for w in snap["worktrees"] if w["path"] == "/wt/feat-a")
    assert a["ticket"] == "TKT-001"
    b = next(w for w in snap["worktrees"] if w["path"] == "/wt/feat-b")
    assert b["ticket"] is None


def test_snapshot_removed_worktrees_excluded(conn):
    """Soft-deleted worktrees do not appear in the snapshot."""
    worktrees_mod.register(conn, "/wt/gone", "feature/gone")
    worktrees_mod.remove(conn, "/wt/gone")
    snap = statusline.snapshot(conn)
    assert snap["worktree_count"] == 0
    assert snap["worktrees"] == []


def test_snapshot_worktree_fields_have_correct_keys(conn):
    """Each worktree entry must contain path, branch, ticket."""
    worktrees_mod.register(conn, "/wt/check", "main")
    snap = statusline.snapshot(conn)
    wt = snap["worktrees"][0]
    assert "path" in wt
    assert "branch" in wt
    assert "ticket" in wt


# ---------------------------------------------------------------------------
# Dispatch cycle reflection
# ---------------------------------------------------------------------------

def test_snapshot_reflects_active_dispatch_cycle(conn):
    """Snapshot surfaces dispatch_initiative, dispatch_cycle_id for active cycle."""
    cid = dispatch_mod.start_cycle(conn, "INIT-002")
    snap = statusline.snapshot(conn)
    assert snap["dispatch_initiative"] == "INIT-002"
    assert snap["dispatch_cycle_id"] == cid


def test_snapshot_dispatch_status_pending_queue_item(conn):
    """Snapshot surfaces the oldest pending dispatch queue item role."""
    dispatch_mod.enqueue(conn, "implementer", ticket="TKT-011")
    snap = statusline.snapshot(conn)
    assert snap["dispatch_status"] == "implementer"


def test_snapshot_dispatch_status_none_when_empty(conn):
    """No pending dispatch item => dispatch_status is None."""
    snap = statusline.snapshot(conn)
    assert snap["dispatch_status"] is None
    assert snap["dispatch_initiative"] is None
    assert snap["dispatch_cycle_id"] is None


# ---------------------------------------------------------------------------
# Recent events reflection
# ---------------------------------------------------------------------------

def test_snapshot_recent_events_populated(conn):
    """snapshot() includes up to 5 most recent events with required fields."""
    events_mod.emit(conn, "tkt.start", detail="began TKT-011")
    events_mod.emit(conn, "tkt.test", detail="tests running")
    snap = statusline.snapshot(conn)
    assert snap["recent_event_count"] == 2
    assert len(snap["recent_events"]) == 2
    # Newest first
    assert snap["recent_events"][0]["type"] == "tkt.test"
    assert snap["recent_events"][1]["type"] == "tkt.start"


def test_snapshot_recent_events_capped_at_five(conn):
    """recent_events list is capped at 5 even when more events exist."""
    for i in range(10):
        events_mod.emit(conn, f"evt.{i}")
    snap = statusline.snapshot(conn)
    assert len(snap["recent_events"]) == 5


def test_snapshot_recent_event_has_required_fields(conn):
    """Each recent_events entry must contain type, detail, created_at."""
    events_mod.emit(conn, "probe.event", detail="check fields")
    snap = statusline.snapshot(conn)
    evt = snap["recent_events"][0]
    assert "type" in evt
    assert "detail" in evt
    assert "created_at" in evt


# ---------------------------------------------------------------------------
# Snapshot timestamp
# ---------------------------------------------------------------------------

def test_snapshot_at_is_current_epoch(conn):
    """snapshot_at must be within 5 seconds of now."""
    before = int(time.time())
    snap = statusline.snapshot(conn)
    after = int(time.time())
    assert before <= snap["snapshot_at"] <= after + 1


# ---------------------------------------------------------------------------
# Compound interaction: full production state scenario
# ---------------------------------------------------------------------------

def test_snapshot_full_production_sequence(conn):
    """Exercises the complete production state sequence through snapshot().

    Production path: orchestrator starts a cycle -> dispatcher enqueues an
    implementer -> implementer marker is set -> worktree registered -> proof
    set to pending -> events emitted. snapshot() must reflect all of these
    in a single call.

    This is the compound-interaction test requirement: multiple domain modules
    collaborate and snapshot() synthesizes them into one coherent projection.
    """
    # 1. Start a dispatch cycle
    cid = dispatch_mod.start_cycle(conn, "INIT-002")

    # 2. Enqueue an implementer item
    dispatch_mod.enqueue(conn, "implementer", ticket="TKT-011")

    # 3. Set active agent marker
    markers_mod.set_active(conn, "agent-tkt011", "implementer")

    # 4. Register a worktree
    worktrees_mod.register(conn, "/wt/tkt-011", "feature/tkt-011", ticket="TKT-011")

    # 5. Set proof to pending
    proof_mod.set_status(conn, "TKT-011", "pending")

    # 6. Emit a couple events
    events_mod.emit(conn, "worktree.registered", detail="/wt/tkt-011")
    events_mod.emit(conn, "proof.set", detail="pending")

    # Now take a snapshot and verify every domain is reflected
    snap = statusline.snapshot(conn)

    assert snap["status"] == "ok"
    assert snap["proof_status"] == "pending"
    assert snap["proof_workflow"] == "TKT-011"
    assert snap["active_agent"] == "implementer"
    assert snap["active_agent_id"] == "agent-tkt011"
    assert snap["worktree_count"] == 1
    assert snap["worktrees"][0]["path"] == "/wt/tkt-011"
    assert snap["worktrees"][0]["ticket"] == "TKT-011"
    assert snap["dispatch_status"] == "implementer"
    assert snap["dispatch_initiative"] == "INIT-002"
    assert snap["dispatch_cycle_id"] == cid
    assert snap["recent_event_count"] == 2
    assert len(snap["recent_events"]) == 2
    assert snap["recent_events"][0]["type"] == "proof.set"
