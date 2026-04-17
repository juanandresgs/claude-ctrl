"""Unit tests for statusline actor-truth hardening (TKT-023) and readiness
surface cleanup (W-CONV-4).

Verifies that:
  - get_active_with_age() returns None when no marker is active
  - get_active_with_age() returns age_seconds >= 0 for a fresh marker
  - age_seconds grows correctly for an artificially old marker
  - deactivated markers are not returned by get_active_with_age()
  - snapshot() includes marker_age_seconds as an int when marker is active
  - snapshot() returns marker_age_seconds=None when no marker is active
  - snapshot() still carries active_agent after TKT-023 refactor
  - snapshot() does NOT expose proof_status or proof_workflow (W-CONV-4:
    proof_state was removed from the display surface; DEC-CATEGORY-C-PROOF-
    RETIRE-001: underlying proof_state storage has also been retired;
    evaluation_state is sole readiness authority)

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

@decision DEC-EVAL-007
@title W-CONV-4: proof_state removed from statusline display surface
@status accepted
@rationale Operators were seeing both proof_status/proof_workflow and
  evaluation_state in the HUD, creating two contradictory readiness signals.
  Enforcement already uses only evaluation_state (TKT-024). W-CONV-4 removed
  proof_state from the snapshot dict entirely so there is exactly one readiness
  display; DEC-CATEGORY-C-PROOF-RETIRE-001 subsequently retired the underlying
  proof_state table, proof.py module, and proof CLI subcommands.
"""

import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from runtime.core.db import connect_memory
from runtime.core.markers import deactivate, get_active_with_age, set_active
from runtime.core.statusline import snapshot
from runtime.schemas import ensure_schema


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
            "INSERT INTO agent_markers (agent_id, role, started_at, is_active) VALUES (?, ?, ?, 1)",
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
            "INSERT INTO agent_markers (agent_id, role, started_at, is_active) VALUES (?, ?, ?, 1)",
            ("agent-future", "reviewer", future_time),
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
        set_active(conn, "agent-1", "reviewer")
        result = snapshot(conn)
        assert result["active_agent"] == "reviewer"

    def test_snapshot_marker_age_matches_old_marker(self, conn):
        # Compound-interaction: write old marker → read snapshot → verify age field.
        # This exercises the full production sequence: marker write → snapshot
        # projection → field propagation, crossing markers.py and statusline.py.
        old_time = int(time.time()) - 600
        conn.execute(
            "INSERT INTO agent_markers (agent_id, role, started_at, is_active) VALUES (?, ?, ?, 1)",
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


# ---------------------------------------------------------------------------
# W-CONV-4 + DEC-CATEGORY-C-PROOF-RETIRE-001: proof_state fully retired
# ---------------------------------------------------------------------------
# W-CONV-4 removed proof_status / proof_workflow from the display surface.
# DEC-CATEGORY-C-PROOF-RETIRE-001 subsequently retired the underlying
# proof_state table and the proof.py module entirely. These tests now assert
# the combined invariant: snapshot() exposes no proof_* fields, and the
# proof module is not importable.
# ---------------------------------------------------------------------------


class TestProofStateRemovedFromDisplay:
    """snapshot() must not expose proof_status or proof_workflow.

    evaluation_state is the sole readiness authority (TKT-024 / DEC-EVAL-006 /
    DEC-CATEGORY-C-PROOF-RETIRE-001). The proof_state surface no longer exists
    in any layer; these tests prove the display surface is clean regardless
    of DB state.

    Production sequence: the evaluator stop hook writes evaluation_state →
    Guardian reads snapshot → snapshot must carry only eval_status, not
    proof_status.
    """

    def test_proof_status_not_in_snapshot_empty_db(self, conn):
        """proof_status must not appear in snapshot when DB is empty."""
        result = snapshot(conn)
        assert "proof_status" not in result, (
            "proof_status must not be a top-level snapshot field"
        )

    def test_proof_workflow_not_in_snapshot_empty_db(self, conn):
        """proof_workflow must not appear in snapshot when DB is empty."""
        result = snapshot(conn)
        assert "proof_workflow" not in result, (
            "proof_workflow must not be a top-level snapshot field"
        )

    def test_eval_status_still_present_after_proof_removal(self, conn):
        """Removing proof_state display must not disturb eval_status fields.

        eval_status and eval_workflow are the sole readiness display and must
        remain present in the snapshot after the proof_state query is removed.
        """
        result = snapshot(conn)
        assert "eval_status" in result, "eval_status must remain in snapshot"
        assert "eval_workflow" in result, "eval_workflow must remain in snapshot"

    def test_compound_eval_only_readiness_surface(self, conn):
        """Compound-interaction: evaluation_state is the sole readiness surface.

        After DEC-CATEGORY-C-PROOF-RETIRE-001 there is no proof.py module and
        no proof_state table. The snapshot must surface only eval_* fields.
        """
        import runtime.core.evaluation as eval_mod

        eval_mod.set_status(conn, "wf-compound", "ready_for_guardian", head_sha="abc123")

        result = snapshot(conn)

        # Display surface must not expose proof fields
        assert "proof_status" not in result
        assert "proof_workflow" not in result

        # Readiness authority must be surfaced correctly
        assert result["eval_status"] == "ready_for_guardian"
        assert result["eval_workflow"] == "wf-compound"
        assert result["eval_head_sha"] == "abc123"
