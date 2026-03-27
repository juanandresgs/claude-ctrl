"""Unit tests for statusline actor-truth hardening (TKT-023).

Verifies that:
  - get_active_with_age() returns None when no marker is active
  - get_active_with_age() returns age_seconds >= 0 for a fresh marker
  - age_seconds grows correctly for an artificially old marker
  - deactivated markers are not returned by get_active_with_age()
  - snapshot() includes marker_age_seconds as an int when marker is active
  - snapshot() returns marker_age_seconds=None when no marker is active
  - snapshot() still carries active_agent after TKT-023 refactor

Production sequence exercised: subagent-start.sh calls marker set → hook reads
snapshot → statusline.sh renders marker label with age. These tests cover that
full read path in-process using an in-memory DB.

@decision DEC-TEST-023
@title Unit tests for TKT-023 marker age and statusline truth hardening
@status accepted
@rationale Marker age is computed at read time (not stored), so the test suite
  must exercise the full markers.py → statusline.py projection chain to confirm
  age_seconds flows through correctly. Artificial old/future timestamps let us
  verify the max(0,...) clock-skew guard and the stale threshold without
  sleeping. The compound-interaction test (test_snapshot_marker_age_matches_old_marker)
  crosses both module boundaries in a single in-process call to mirror what
  the statusline HUD does on every render.
"""
import time
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from runtime.core.db import connect_memory
from runtime.schemas import ensure_schema
from runtime.core.markers import set_active, get_active, get_active_with_age, deactivate
from runtime.core.statusline import snapshot


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_schema(c)
    return c


class TestGetActiveWithAge:
    def test_returns_none_when_no_marker(self, conn):
        result = get_active_with_age(conn)
        assert result is None

    def test_returns_marker_with_age(self, conn):
        set_active(conn, "agent-1", "implementer")
        result = get_active_with_age(conn)
        assert result is not None
        assert result["role"] == "implementer"
        assert "age_seconds" in result
        assert result["age_seconds"] >= 0

    def test_age_increases_with_old_marker(self, conn):
        # Insert a marker with started_at 10 minutes ago to simulate stale state.
        old_time = int(time.time()) - 600
        conn.execute(
            "INSERT INTO agent_markers (agent_id, role, started_at, is_active)"
            " VALUES (?, ?, ?, 1)",
            ("agent-old", "planner", old_time),
        )
        conn.commit()
        result = get_active_with_age(conn)
        assert result is not None
        assert result["age_seconds"] >= 599  # 1s tolerance for test wall-clock

    def test_deactivated_marker_not_returned(self, conn):
        set_active(conn, "agent-1", "implementer")
        deactivate(conn, "agent-1")
        result = get_active_with_age(conn)
        assert result is None

    def test_age_seconds_is_non_negative(self, conn):
        # Clock skew guard: max(0, ...) must prevent negative values.
        future_time = int(time.time()) + 3600
        conn.execute(
            "INSERT INTO agent_markers (agent_id, role, started_at, is_active)"
            " VALUES (?, ?, ?, 1)",
            ("agent-future", "tester", future_time),
        )
        conn.commit()
        result = get_active_with_age(conn)
        assert result is not None
        assert result["age_seconds"] == 0


class TestSnapshotMarkerAge:
    def test_snapshot_includes_marker_age(self, conn):
        set_active(conn, "agent-1", "implementer")
        result = snapshot(conn)
        assert "marker_age_seconds" in result
        assert isinstance(result["marker_age_seconds"], int)
        assert result["marker_age_seconds"] >= 0

    def test_snapshot_marker_age_none_when_no_marker(self, conn):
        result = snapshot(conn)
        assert result["marker_age_seconds"] is None

    def test_snapshot_active_agent_still_present(self, conn):
        set_active(conn, "agent-1", "tester")
        result = snapshot(conn)
        assert result["active_agent"] == "tester"

    def test_snapshot_marker_age_matches_old_marker(self, conn):
        # Compound-interaction: write old marker → read snapshot → verify age field.
        # This exercises the full production sequence: marker write → snapshot
        # projection → field propagation, crossing markers.py and statusline.py.
        old_time = int(time.time()) - 600
        conn.execute(
            "INSERT INTO agent_markers (agent_id, role, started_at, is_active)"
            " VALUES (?, ?, ?, 1)",
            ("agent-stale", "guardian", old_time),
        )
        conn.commit()
        result = snapshot(conn)
        assert result["active_agent"] == "guardian"
        assert result["marker_age_seconds"] is not None
        assert result["marker_age_seconds"] >= 599

    def test_snapshot_marker_age_none_after_deactivate(self, conn):
        set_active(conn, "agent-1", "implementer")
        deactivate(conn, "agent-1")
        result = snapshot(conn)
        assert result["marker_age_seconds"] is None
        assert result["active_agent"] is None
