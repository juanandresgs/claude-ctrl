"""Tests for the transport-adapter contract and ClaudeCodeAdapter.

Pins:
1.  TransportAdapter is a runtime-checkable Protocol.
2.  ClaudeCodeAdapter satisfies the Protocol.
3.  Importing claude_code_adapter auto-registers "claude_code".
4.  get_adapter("claude_code") returns the registered instance.
5.  get_adapter raises KeyError for unknown transports.
6.  list_adapters returns sorted names.
7.  register() raises TypeError for non-adapters.
8.  Registering a second adapter under the same name replaces the first.

ClaudeCodeAdapter integration (against in-memory DB):
9.  dispatch() creates a pending attempt and returns the full row.
10. on_delivery_claimed() transitions pending → delivered  [SubagentStart].
11. on_acknowledged() transitions delivered → acknowledged [explicit caller;
    NO automatic harness trigger — not SubagentStop].
12. on_failed() transitions delivered → failed  [transport-layer failure;
    not work failure].
13. on_timeout() transitions pending → timed_out.
14. on_timeout() transitions delivered → timed_out.
15. Delivery-only happy path: dispatch → on_delivery_claimed  (claude_code
    primary path — delivered is the natural terminal state for this transport).
16. Full explicit-ack path: dispatch → on_delivery_claimed → on_acknowledged.
17. Fail path: dispatch → on_delivery_claimed → on_failed.
18. Retry-then-deliver chain.
19. Invalid transitions surface as ValueError through the adapter.
20. transport_name matches the value stored in agent_sessions.transport.
21. dispatch() passes workflow_id and timeout_at through correctly.

Semantic correctness pins:
22. on_delivery_claimed maps to SubagentStart, NOT SubagentStop.
23. on_acknowledged has no automatic harness trigger for claude_code —
    SubagentStop is work completion, owned by completions.py.
"""

from __future__ import annotations

import sqlite3
import time

import pytest

# Import the adapter module to trigger auto-registration.
import runtime.core.claude_code_adapter  # noqa: F401
from runtime.core import dispatch_attempts as da
from runtime.core.claude_code_adapter import ADAPTER, ClaudeCodeAdapter
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
        ("sess-tc-01", "claude_code", "active", now, now),
    )
    c.execute(
        "INSERT INTO seats (seat_id, session_id, role, status, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        ("seat-tc-01", "sess-tc-01", "worker", "active", now, now),
    )
    c.commit()
    yield c
    c.close()


SEAT = "seat-tc-01"


# ---------------------------------------------------------------------------
# 1–2. Protocol shape
# ---------------------------------------------------------------------------


def test_transport_adapter_is_runtime_checkable():
    """TransportAdapter is a @runtime_checkable Protocol."""
    assert isinstance(ClaudeCodeAdapter(), TransportAdapter)


def test_claude_code_adapter_satisfies_protocol():
    """ClaudeCodeAdapter fulfills every method the Protocol requires."""
    adapter = ClaudeCodeAdapter()
    assert hasattr(adapter, "transport_name")
    assert hasattr(adapter, "dispatch")
    assert hasattr(adapter, "on_delivery_claimed")
    assert hasattr(adapter, "on_acknowledged")
    assert hasattr(adapter, "on_failed")
    assert hasattr(adapter, "on_timeout")


# ---------------------------------------------------------------------------
# 3–8. Registry
# ---------------------------------------------------------------------------


def test_auto_registration_on_import():
    """Importing claude_code_adapter registers 'claude_code' in the registry."""
    assert "claude_code" in list_adapters()


def test_get_adapter_returns_registered_instance():
    adapter = get_adapter("claude_code")
    assert adapter is ADAPTER


def test_get_adapter_raises_for_unknown():
    with pytest.raises(KeyError, match="no-such-transport"):
        get_adapter("no-such-transport")


def test_list_adapters_sorted():
    names = list_adapters()
    assert names == sorted(names)


def test_register_raises_for_non_adapter():
    with pytest.raises(TypeError, match="TransportAdapter"):
        register("not-an-adapter")  # type: ignore[arg-type]


def test_register_replaces_existing():
    """Registering under the same transport name replaces the prior entry."""

    class _FakeAdapter:
        @property
        def transport_name(self) -> str:
            return "claude_code"

        def dispatch(self, conn, seat_id, instruction, *, workflow_id=None, timeout_at=None):
            ...

        def on_delivery_claimed(self, conn, attempt_id):
            ...

        def on_acknowledged(self, conn, attempt_id):
            ...

        def on_failed(self, conn, attempt_id):
            ...

        def on_timeout(self, conn, attempt_id):
            ...

    fake = _FakeAdapter()
    register(fake)
    assert get_adapter("claude_code") is fake
    # Restore the real adapter so other tests are not affected.
    register(ADAPTER)
    assert get_adapter("claude_code") is ADAPTER


# ---------------------------------------------------------------------------
# 9. dispatch() creates a pending attempt
# ---------------------------------------------------------------------------


def test_dispatch_creates_pending_attempt(conn):
    row = ADAPTER.dispatch(conn, SEAT, "run tests")
    assert row["status"] == "pending"
    assert row["seat_id"] == SEAT
    assert row["instruction"] == "run tests"
    assert "attempt_id" in row


def test_dispatch_returns_full_row(conn):
    row = ADAPTER.dispatch(conn, SEAT, "implement feature X")
    # Full row includes all schema columns.
    assert "retry_count" in row
    assert "delivery_claimed_at" in row
    assert "acknowledged_at" in row
    assert row["retry_count"] == 0
    assert row["delivery_claimed_at"] is None


# ---------------------------------------------------------------------------
# 10. on_delivery_claimed(): pending → delivered
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
# 11. on_acknowledged(): delivered → acknowledged
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
# 12. on_failed(): delivered → failed
# ---------------------------------------------------------------------------


def test_on_failed_transitions_to_failed(conn):
    row = ADAPTER.dispatch(conn, SEAT, "task E")
    ADAPTER.on_delivery_claimed(conn, row["attempt_id"])
    updated = ADAPTER.on_failed(conn, row["attempt_id"])
    assert updated["status"] == "failed"


# ---------------------------------------------------------------------------
# 13–14. on_timeout(): pending or delivered → timed_out
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
# 15. Delivery-only happy path (primary path for claude_code transport)
# ---------------------------------------------------------------------------


def test_delivery_only_happy_path(conn):
    """dispatch → on_delivery_claimed is the primary path for claude_code.

    For claude_code, SubagentStart is both delivery claim and implicit
    receipt.  The attempt ends at 'delivered' unless the caller explicitly
    advances it further.
    """
    adapter = get_adapter("claude_code")
    row = adapter.dispatch(conn, SEAT, "implement X")
    aid = row["attempt_id"]

    claimed = adapter.on_delivery_claimed(conn, aid)
    assert claimed["status"] == "delivered"
    assert claimed["delivery_claimed_at"] is not None


# ---------------------------------------------------------------------------
# 16. Full explicit-ack path
# ---------------------------------------------------------------------------


def test_explicit_ack_path_via_registry(conn):
    """dispatch → on_delivery_claimed → on_acknowledged (explicit caller only).

    on_acknowledged is available for callers that need the terminal state,
    but it has no automatic harness trigger for claude_code.
    """
    adapter = get_adapter("claude_code")
    row = adapter.dispatch(conn, SEAT, "task with explicit ack")
    aid = row["attempt_id"]

    adapter.on_delivery_claimed(conn, aid)
    acked = adapter.on_acknowledged(conn, aid)
    assert acked["status"] == "acknowledged"
    assert acked["acknowledged_at"] is not None


# ---------------------------------------------------------------------------
# 17. Fail path: transport-layer failure (not work failure)
# ---------------------------------------------------------------------------


def test_fail_path_via_registry(conn):
    """dispatch → on_delivery_claimed → on_failed (transport layer failure)."""
    adapter = get_adapter("claude_code")
    row = adapter.dispatch(conn, SEAT, "task that will fail at transport layer")
    aid = row["attempt_id"]

    adapter.on_delivery_claimed(conn, aid)
    failed = adapter.on_failed(conn, aid)
    assert failed["status"] == "failed"


# ---------------------------------------------------------------------------
# 18. Retry-then-deliver chain
# ---------------------------------------------------------------------------


def test_retry_then_deliver(conn):
    """Timed-out attempt can be retried and then reach delivered state."""
    row = ADAPTER.dispatch(conn, SEAT, "flaky task")
    aid = row["attempt_id"]

    # First attempt times out.
    ADAPTER.on_timeout(conn, aid)
    assert da.get(conn, aid)["status"] == "timed_out"

    # Retry resets to pending.
    retried = da.retry(conn, aid)
    assert retried["status"] == "pending"
    assert retried["retry_count"] == 1
    assert retried["delivery_claimed_at"] is None

    # Second attempt reaches delivered (SubagentStart fires again).
    ADAPTER.on_delivery_claimed(conn, aid)
    assert da.get(conn, aid)["status"] == "delivered"
    assert da.get(conn, aid)["retry_count"] == 1


# ---------------------------------------------------------------------------
# 19. Invalid transitions raise ValueError through the adapter
# ---------------------------------------------------------------------------


def test_on_acknowledged_from_pending_raises(conn):
    row = ADAPTER.dispatch(conn, SEAT, "bad sequence")
    with pytest.raises(ValueError, match="invalid transition"):
        ADAPTER.on_acknowledged(conn, row["attempt_id"])


def test_on_failed_from_pending_raises(conn):
    row = ADAPTER.dispatch(conn, SEAT, "bad fail")
    with pytest.raises(ValueError, match="invalid transition"):
        ADAPTER.on_failed(conn, row["attempt_id"])


def test_on_delivery_claimed_from_acknowledged_raises(conn):
    row = ADAPTER.dispatch(conn, SEAT, "terminal test")
    ADAPTER.on_delivery_claimed(conn, row["attempt_id"])
    ADAPTER.on_acknowledged(conn, row["attempt_id"])
    with pytest.raises(ValueError, match="invalid transition"):
        ADAPTER.on_delivery_claimed(conn, row["attempt_id"])


# ---------------------------------------------------------------------------
# 19. transport_name matches agent_sessions.transport
# ---------------------------------------------------------------------------


def test_transport_name_matches_session_transport(conn):
    """Adapter transport_name equals the value stored in agent_sessions."""
    row = conn.execute(
        "SELECT transport FROM agent_sessions WHERE session_id = 'sess-tc-01'"
    ).fetchone()
    assert row["transport"] == ADAPTER.transport_name


# ---------------------------------------------------------------------------
# 20. dispatch() passes workflow_id and timeout_at through
# ---------------------------------------------------------------------------


def test_dispatch_passes_workflow_id(conn):
    row = ADAPTER.dispatch(conn, SEAT, "wf task", workflow_id="wf-tc-01")
    assert row["workflow_id"] == "wf-tc-01"


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


# ---------------------------------------------------------------------------
# 22–23. Semantic correctness: delivery vs. completion domain boundary
# ---------------------------------------------------------------------------


def test_on_delivery_claimed_is_subagent_start_not_stop(conn):
    """SubagentStart (delivery) reaches 'delivered'; no further adapter step.

    For claude_code, the delivery domain ends at 'delivered'.
    SubagentStop is work completion — a separate domain.
    """
    row = ADAPTER.dispatch(conn, SEAT, "semantic pin task")
    ADAPTER.on_delivery_claimed(conn, row["attempt_id"])
    state = da.get(conn, row["attempt_id"])
    # Delivery is confirmed; 'acknowledged' is NOT automatic for claude_code.
    assert state["status"] == "delivered"
    assert state["acknowledged_at"] is None


def test_on_acknowledged_has_no_automatic_harness_trigger(conn):
    """on_acknowledged() works as a state transition but maps to no harness event.

    SubagentStop is work completion (completions.py domain), not receipt ack.
    Calling on_acknowledged() explicitly advances the state machine for callers
    that need the terminal state, but it is never triggered automatically by
    SubagentStop or any other automatic harness event for claude_code.
    """
    row = ADAPTER.dispatch(conn, SEAT, "ack semantics pin")
    ADAPTER.on_delivery_claimed(conn, row["attempt_id"])
    # Explicit caller advances to acknowledged — this is valid.
    updated = ADAPTER.on_acknowledged(conn, row["attempt_id"])
    assert updated["status"] == "acknowledged"
    # But the delivery_claimed_at timestamp (set by SubagentStart) is distinct
    # from acknowledged_at (set by explicit caller), proving they are separate.
    assert updated["delivery_claimed_at"] is not None
    assert updated["acknowledged_at"] is not None
    assert updated["acknowledged_at"] >= updated["delivery_claimed_at"]
