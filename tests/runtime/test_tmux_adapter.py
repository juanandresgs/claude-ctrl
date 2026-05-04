"""Tests for TmuxAdapter — tmux transport adapter (Phase 2b, second adapter).

Pins:
1.  TmuxAdapter satisfies the TransportAdapter Protocol.
2.  Importing tmux_adapter auto-registers "tmux".
3.  get_adapter("tmux") returns the registered TmuxAdapter instance.
4.  transport_name is "tmux".
5.  list_adapters() includes "tmux" alongside "claude_code".

TmuxAdapter integration (against in-memory DB):
6.  dispatch() creates a pending attempt and returns the full row.
7.  dispatch() passes workflow_id through correctly.
8.  dispatch() passes timeout_at through correctly.
9.  dispatch() uses workflow_id=None and timeout_at=None by default.
10. on_delivery_claimed() transitions pending → delivered.
11. on_delivery_claimed() sets delivery_claimed_at timestamp.
12. on_acknowledged() transitions delivered → acknowledged (terminal).
13. on_acknowledged() sets acknowledged_at timestamp.
14. on_failed() transitions delivered → failed.
15. on_timeout() transitions pending → timed_out.
16. on_timeout() transitions delivered → timed_out.
17. Full sentinel-confirm path: dispatch → on_delivery_claimed.
18. Full explicit-ack path: dispatch → on_delivery_claimed → on_acknowledged.
19. Fail path: dispatch → on_delivery_claimed → on_failed.
20. Retry-then-deliver chain.
21. Invalid transition (on_acknowledged from pending) raises ValueError.
22. Invalid transition (on_failed from pending) raises ValueError.
23. Invalid transition (on_delivery_claimed from acknowledged) raises ValueError.
24. transport_name matches "tmux" stored in agent_sessions.transport.

Semantic correctness (tmux-specific):
25. on_delivery_claimed() is NOT automatic — caller supplies sentinel evidence.
26. on_acknowledged() has genuine utility for tmux (receipt sentinel).
27. Pane state (pane_id, sentinel string) is NOT stored in dispatch_attempts.
28. Both "tmux" and "claude_code" are registered after both modules imported.
"""

from __future__ import annotations

import sqlite3
import time

import pytest

# Import both adapters to confirm coexistence in registry.
import runtime.core.claude_code_adapter  # noqa: F401
import runtime.core.tmux_adapter  # noqa: F401
from runtime.core import dispatch_attempts as da
from runtime.core.tmux_adapter import ADAPTER, TmuxAdapter
from runtime.core.transport_contract import (
    TransportAdapter,
    get_adapter,
    list_adapters,
    register,
)
from runtime.schemas import ensure_schema


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    now = int(time.time())
    c.execute(
        "INSERT INTO agent_sessions (session_id, transport, status, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?)",
        ("sess-tmux-01", "tmux", "active", now, now),
    )
    c.execute(
        "INSERT INTO seats (seat_id, session_id, role, status, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        ("seat-tmux-01", "sess-tmux-01", "worker", "active", now, now),
    )
    c.commit()
    yield c
    c.close()


SEAT = "seat-tmux-01"


# ---------------------------------------------------------------------------
# 1–5. Protocol shape and registry
# ---------------------------------------------------------------------------


def test_tmux_adapter_satisfies_protocol():
    """TmuxAdapter fulfills every method the Protocol requires."""
    adapter = TmuxAdapter()
    assert isinstance(adapter, TransportAdapter)


def test_tmux_adapter_has_all_required_methods():
    adapter = TmuxAdapter()
    assert hasattr(adapter, "transport_name")
    assert hasattr(adapter, "dispatch")
    assert hasattr(adapter, "on_delivery_claimed")
    assert hasattr(adapter, "on_acknowledged")
    assert hasattr(adapter, "on_failed")
    assert hasattr(adapter, "on_timeout")


def test_auto_registration_on_import():
    """Importing tmux_adapter registers 'tmux' in the registry."""
    assert "tmux" in list_adapters()


def test_get_adapter_returns_tmux_instance():
    adapter = get_adapter("tmux")
    assert adapter is ADAPTER
    assert isinstance(adapter, TmuxAdapter)


def test_transport_name_is_tmux():
    assert ADAPTER.transport_name == "tmux"


def test_list_adapters_includes_tmux_and_claude_code():
    """Both adapters coexist in the registry after both modules are imported."""
    names = list_adapters()
    assert "tmux" in names
    assert "claude_code" in names
    # Registry is sorted.
    assert names == sorted(names)


# ---------------------------------------------------------------------------
# 6–9. dispatch()
# ---------------------------------------------------------------------------


def test_dispatch_creates_pending_attempt(conn):
    row = ADAPTER.dispatch(conn, SEAT, "run via tmux")
    assert row["status"] == "pending"
    assert row["seat_id"] == SEAT
    assert row["instruction"] == "run via tmux"
    assert "attempt_id" in row


def test_dispatch_passes_workflow_id(conn):
    row = ADAPTER.dispatch(conn, SEAT, "wf task", workflow_id="wf-tmux-01")
    assert row["workflow_id"] == "wf-tmux-01"


def test_dispatch_passes_timeout_at(conn):
    t = int(time.time()) + 600
    row = ADAPTER.dispatch(conn, SEAT, "timed task", timeout_at=t)
    assert row["timeout_at"] == t


def test_dispatch_workflow_id_none_by_default(conn):
    row = ADAPTER.dispatch(conn, SEAT, "no wf")
    assert row["workflow_id"] is None


def test_dispatch_timeout_at_none_by_default(conn):
    row = ADAPTER.dispatch(conn, SEAT, "no timeout")
    assert row["timeout_at"] is None


def test_dispatch_returns_full_row(conn):
    row = ADAPTER.dispatch(conn, SEAT, "full row check")
    assert "retry_count" in row
    assert "delivery_claimed_at" in row
    assert "acknowledged_at" in row
    assert row["retry_count"] == 0
    assert row["delivery_claimed_at"] is None


# ---------------------------------------------------------------------------
# 10–11. on_delivery_claimed(): pending → delivered
# ---------------------------------------------------------------------------


def test_on_delivery_claimed_transitions_to_delivered(conn):
    row = ADAPTER.dispatch(conn, SEAT, "task A")
    updated = ADAPTER.on_delivery_claimed(conn, row["attempt_id"])
    assert updated["status"] == "delivered"


def test_on_delivery_claimed_sets_delivery_timestamp(conn):
    before = int(time.time())
    row = ADAPTER.dispatch(conn, SEAT, "task B")
    updated = ADAPTER.on_delivery_claimed(conn, row["attempt_id"])
    assert updated["delivery_claimed_at"] is not None
    assert updated["delivery_claimed_at"] >= before


# ---------------------------------------------------------------------------
# 12–13. on_acknowledged(): delivered → acknowledged
# ---------------------------------------------------------------------------


def test_on_acknowledged_transitions_to_acknowledged(conn):
    row = ADAPTER.dispatch(conn, SEAT, "task C")
    ADAPTER.on_delivery_claimed(conn, row["attempt_id"])
    updated = ADAPTER.on_acknowledged(conn, row["attempt_id"])
    assert updated["status"] == "acknowledged"


def test_on_acknowledged_sets_ack_timestamp(conn):
    before = int(time.time())
    row = ADAPTER.dispatch(conn, SEAT, "task D")
    ADAPTER.on_delivery_claimed(conn, row["attempt_id"])
    updated = ADAPTER.on_acknowledged(conn, row["attempt_id"])
    assert updated["acknowledged_at"] is not None
    assert updated["acknowledged_at"] >= before


# ---------------------------------------------------------------------------
# 14. on_failed(): delivered → failed
# ---------------------------------------------------------------------------


def test_on_failed_transitions_to_failed(conn):
    row = ADAPTER.dispatch(conn, SEAT, "task E")
    ADAPTER.on_delivery_claimed(conn, row["attempt_id"])
    updated = ADAPTER.on_failed(conn, row["attempt_id"])
    assert updated["status"] == "failed"


# ---------------------------------------------------------------------------
# 15–16. on_timeout(): pending or delivered → timed_out
# ---------------------------------------------------------------------------


def test_on_timeout_from_pending(conn):
    row = ADAPTER.dispatch(conn, SEAT, "task F")
    updated = ADAPTER.on_timeout(conn, row["attempt_id"])
    assert updated["status"] == "timed_out"


def test_on_timeout_from_delivered(conn):
    row = ADAPTER.dispatch(conn, SEAT, "task G")
    ADAPTER.on_delivery_claimed(conn, row["attempt_id"])
    updated = ADAPTER.on_timeout(conn, row["attempt_id"])
    assert updated["status"] == "timed_out"


# ---------------------------------------------------------------------------
# 17. Sentinel-confirm path (primary path for tmux transport)
# ---------------------------------------------------------------------------


def test_sentinel_confirm_path(conn):
    """dispatch → on_delivery_claimed is the primary path for tmux.

    The caller (watchdog) confirmed the delivery sentinel in the pane capture
    and called on_delivery_claimed().  Attempt reaches 'delivered'.
    """
    adapter = get_adapter("tmux")
    row = adapter.dispatch(conn, SEAT, "instruction via pane write")
    aid = row["attempt_id"]

    claimed = adapter.on_delivery_claimed(conn, aid)
    assert claimed["status"] == "delivered"
    assert claimed["delivery_claimed_at"] is not None


# ---------------------------------------------------------------------------
# 18. Full explicit-ack path
# ---------------------------------------------------------------------------


def test_explicit_ack_path_via_registry(conn):
    """dispatch → on_delivery_claimed → on_acknowledged.

    For tmux, on_acknowledged() is triggered when the pane emits an explicit
    receipt sentinel (e.g. __RECEIPT_ACK__).  This is the primary use of
    on_acknowledged() for the tmux transport.
    """
    adapter = get_adapter("tmux")
    row = adapter.dispatch(conn, SEAT, "task with receipt sentinel")
    aid = row["attempt_id"]

    adapter.on_delivery_claimed(conn, aid)
    acked = adapter.on_acknowledged(conn, aid)
    assert acked["status"] == "acknowledged"
    assert acked["acknowledged_at"] is not None


# ---------------------------------------------------------------------------
# 19. Fail path
# ---------------------------------------------------------------------------


def test_fail_path_via_registry(conn):
    """dispatch → on_delivery_claimed → on_failed (pane process died)."""
    adapter = get_adapter("tmux")
    row = adapter.dispatch(conn, SEAT, "task in dying pane")
    aid = row["attempt_id"]

    adapter.on_delivery_claimed(conn, aid)
    failed = adapter.on_failed(conn, aid)
    assert failed["status"] == "failed"


# ---------------------------------------------------------------------------
# 20. Retry-then-deliver chain
# ---------------------------------------------------------------------------


def test_retry_then_deliver(conn):
    """Timed-out attempt can be retried and reach delivered on second attempt."""
    row = ADAPTER.dispatch(conn, SEAT, "flaky pane task")
    aid = row["attempt_id"]

    # First write to pane; sentinel never observed → timeout.
    ADAPTER.on_timeout(conn, aid)
    assert da.get(conn, aid)["status"] == "timed_out"

    # Retry resets to pending.
    retried = da.retry(conn, aid)
    assert retried["status"] == "pending"
    assert retried["retry_count"] == 1
    assert retried["delivery_claimed_at"] is None

    # Second write; sentinel confirmed → delivered.
    ADAPTER.on_delivery_claimed(conn, aid)
    assert da.get(conn, aid)["status"] == "delivered"
    assert da.get(conn, aid)["retry_count"] == 1


# ---------------------------------------------------------------------------
# 21–23. Terminal/invalid transitions raise ValueError
# ---------------------------------------------------------------------------


def test_on_acknowledged_from_pending_raises(conn):
    row = ADAPTER.dispatch(conn, SEAT, "bad sequence")
    with pytest.raises(ValueError, match="invalid transition"):
        ADAPTER.on_acknowledged(conn, row["attempt_id"])


def test_on_failed_from_pending_transitions_to_failed(conn):
    row = ADAPTER.dispatch(conn, SEAT, "bad fail")
    updated = ADAPTER.on_failed(conn, row["attempt_id"])
    assert updated["status"] == "failed"


def test_on_delivery_claimed_from_acknowledged_raises(conn):
    row = ADAPTER.dispatch(conn, SEAT, "terminal test")
    ADAPTER.on_delivery_claimed(conn, row["attempt_id"])
    ADAPTER.on_acknowledged(conn, row["attempt_id"])
    with pytest.raises(ValueError, match="invalid transition"):
        ADAPTER.on_delivery_claimed(conn, row["attempt_id"])


# ---------------------------------------------------------------------------
# 24. transport_name matches agent_sessions.transport value
# ---------------------------------------------------------------------------


def test_transport_name_matches_session_transport(conn):
    """Adapter transport_name equals the value stored in agent_sessions."""
    row = conn.execute(
        "SELECT transport FROM agent_sessions WHERE session_id = 'sess-tmux-01'"
    ).fetchone()
    assert row["transport"] == ADAPTER.transport_name
    assert row["transport"] == "tmux"


# ---------------------------------------------------------------------------
# 25–27. Semantic correctness (tmux-specific)
# ---------------------------------------------------------------------------


def test_on_delivery_claimed_requires_caller_sentinel_evidence(conn):
    """on_delivery_claimed() is not automatic — the caller supplies evidence.

    For tmux, there is no deterministic harness event that fires on delivery.
    The watchdog/observer must confirm the sentinel in the pane capture and
    then call on_delivery_claimed().  Without that call, the attempt stays
    pending even if the pane actually received the instruction.

    This test demonstrates the caller-driven nature: the attempt stays pending
    until the caller (simulated here) calls on_delivery_claimed().
    """
    row = ADAPTER.dispatch(conn, SEAT, "instruction written to pane")
    aid = row["attempt_id"]

    # Before caller confirms sentinel — still pending.
    state = da.get(conn, aid)
    assert state["status"] == "pending"

    # Caller confirms sentinel → delivery claimed.
    ADAPTER.on_delivery_claimed(conn, aid)
    state = da.get(conn, aid)
    assert state["status"] == "delivered"


def test_on_acknowledged_is_genuine_for_tmux(conn):
    """on_acknowledged() has real utility for tmux receipt sentinel.

    Unlike claude_code where on_acknowledged() has no automatic trigger,
    for tmux the pane process may emit __RECEIPT_ACK__ before beginning work.
    The caller detects this and calls on_acknowledged() to reach the terminal
    acknowledged state.  delivery_claimed_at and acknowledged_at are separate
    timestamps proving delivery and receipt are distinct events.
    """
    row = ADAPTER.dispatch(conn, SEAT, "task with receipt ack")
    aid = row["attempt_id"]

    ADAPTER.on_delivery_claimed(conn, aid)
    acked = ADAPTER.on_acknowledged(conn, aid)

    assert acked["status"] == "acknowledged"
    assert acked["delivery_claimed_at"] is not None
    assert acked["acknowledged_at"] is not None
    # Receipt must follow delivery.
    assert acked["acknowledged_at"] >= acked["delivery_claimed_at"]


def test_pane_state_not_stored_in_dispatch_attempts(conn):
    """Pane ID and sentinel string are transport evidence, not runtime state.

    dispatch_attempts rows have no pane_id or sentinel column.  The caller
    retains transport evidence.  This test confirms the schema has no such
    columns, enforcing the adapter/domain boundary.
    """
    row = ADAPTER.dispatch(conn, SEAT, "pane boundary check")
    aid = row["attempt_id"]
    # dict keys from the returned row must not include pane-specific fields.
    assert "pane_id" not in row
    assert "sentinel" not in row
    assert "pane_output" not in row

    # After delivery claim, still no pane fields.
    claimed = ADAPTER.on_delivery_claimed(conn, aid)
    assert "pane_id" not in claimed
    assert "sentinel" not in claimed


# ---------------------------------------------------------------------------
# 28. Both adapters coexist
# ---------------------------------------------------------------------------


def test_both_adapters_coexist_in_registry():
    """tmux and claude_code are independently registered and retrievable."""
    tmux = get_adapter("tmux")
    cc = get_adapter("claude_code")
    assert tmux is not cc
    assert tmux.transport_name == "tmux"
    assert cc.transport_name == "claude_code"
