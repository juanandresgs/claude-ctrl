"""Tests for runtime/core/lifecycle.py

@decision DEC-LIFECYCLE-001
Title: lifecycle.py owns agent start/stop marker transitions
Status: accepted
Rationale: Marker activation and deactivation is a distinct concern from dispatch
  routing. Separating it into lifecycle.py makes both modules independently testable
  and avoids conflating routing logic with agent identity tracking.
"""

import sqlite3

import pytest
from runtime.core.lifecycle import on_agent_start, on_agent_stop

from runtime.core import markers
from runtime.schemas import ensure_schema


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
