"""Unit tests for runtime.core.evaluation.

Tests the evaluation_state table domain module in isolation using an
in-memory SQLite database. No subprocess or external dependencies.

Covers:
  - get() returns None for missing rows, dict for found rows
  - set_status() round-trips all valid statuses
  - set_status() raises ValueError for invalid status
  - set_status() preserves head_sha on status-only updates
  - list_all() ordering
  - invalidate_if_ready() transitions ready_for_guardian→pending only
  - invalidate_if_ready() is a no-op for non-ready statuses

@decision DEC-EVAL-001
Title: evaluation_state is the sole Guardian readiness authority (TKT-024)
Status: accepted
Rationale: Tests use in-memory SQLite (connect_memory()) so they never
  touch the user's real state.db. ensure_schema() is called on every
  fixture so tests are independent and idempotent.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from runtime.core.db import connect_memory
from runtime.schemas import ensure_schema
import runtime.core.evaluation as evaluation


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


# ---------------------------------------------------------------------------
# get()
# ---------------------------------------------------------------------------

def test_get_missing_returns_none(conn):
    assert evaluation.get(conn, "nonexistent") is None


def test_get_found_returns_dict(conn):
    evaluation.set_status(conn, "wf-1", "pending")
    row = evaluation.get(conn, "wf-1")
    assert row is not None
    assert row["workflow_id"] == "wf-1"
    assert row["status"] == "pending"
    assert row["updated_at"] > 0


def test_get_includes_all_schema_fields(conn):
    evaluation.set_status(conn, "wf-x", "ready_for_guardian", head_sha="abc123",
                          blockers=1, major=2, minor=3)
    row = evaluation.get(conn, "wf-x")
    assert row["head_sha"] == "abc123"
    assert row["blockers"] == 1
    assert row["major"] == 2
    assert row["minor"] == 3


# ---------------------------------------------------------------------------
# set_status() — valid statuses
# ---------------------------------------------------------------------------

def test_set_all_valid_statuses(conn):
    valid = ("idle", "pending", "needs_changes", "ready_for_guardian", "blocked_by_plan")
    for status in valid:
        evaluation.set_status(conn, f"wf-{status}", status)
        row = evaluation.get(conn, f"wf-{status}")
        assert row is not None
        assert row["status"] == status, f"expected {status!r}, got {row['status']!r}"


def test_set_invalid_status_raises(conn):
    with pytest.raises(ValueError, match="unknown evaluation status"):
        evaluation.set_status(conn, "wf-bad", "verified")


def test_set_invalid_status_raises_for_proof_era_values(conn):
    """proof_state values must not be accepted by evaluation domain."""
    for bad in ("verified", "bogus", ""):
        with pytest.raises(ValueError):
            evaluation.set_status(conn, "wf-bad", bad)


# ---------------------------------------------------------------------------
# set_status() — upsert / head_sha preservation
# ---------------------------------------------------------------------------

def test_upsert_updates_status(conn):
    evaluation.set_status(conn, "wf-1", "idle")
    evaluation.set_status(conn, "wf-1", "ready_for_guardian")
    row = evaluation.get(conn, "wf-1")
    assert row["status"] == "ready_for_guardian"


def test_head_sha_preserved_on_status_only_update(conn):
    """head_sha written once must survive a subsequent status-only upsert."""
    evaluation.set_status(conn, "wf-1", "ready_for_guardian", head_sha="deadbeef")
    # Update status without providing head_sha
    evaluation.set_status(conn, "wf-1", "pending")
    row = evaluation.get(conn, "wf-1")
    assert row["head_sha"] == "deadbeef"
    assert row["status"] == "pending"


def test_head_sha_overwritten_when_provided(conn):
    evaluation.set_status(conn, "wf-1", "ready_for_guardian", head_sha="aaa")
    evaluation.set_status(conn, "wf-1", "ready_for_guardian", head_sha="bbb")
    row = evaluation.get(conn, "wf-1")
    assert row["head_sha"] == "bbb"


# ---------------------------------------------------------------------------
# list_all()
# ---------------------------------------------------------------------------

def test_list_all_empty(conn):
    assert evaluation.list_all(conn) == []


def test_list_all_returns_all_rows(conn):
    evaluation.set_status(conn, "wf-a", "idle")
    evaluation.set_status(conn, "wf-b", "pending")
    evaluation.set_status(conn, "wf-c", "needs_changes")
    rows = evaluation.list_all(conn)
    assert len(rows) == 3
    ids = {r["workflow_id"] for r in rows}
    assert ids == {"wf-a", "wf-b", "wf-c"}


def test_list_all_ordered_by_updated_at_desc(conn):
    evaluation.set_status(conn, "wf-first", "idle")
    evaluation.set_status(conn, "wf-second", "pending")
    # Backdate wf-first so ordering is deterministic
    conn.execute(
        "UPDATE evaluation_state SET updated_at = updated_at - 10 WHERE workflow_id = 'wf-first'"
    )
    conn.commit()
    rows = evaluation.list_all(conn)
    assert rows[0]["workflow_id"] == "wf-second"


# ---------------------------------------------------------------------------
# invalidate_if_ready()
# ---------------------------------------------------------------------------

def test_invalidate_ready_for_guardian_returns_true(conn):
    evaluation.set_status(conn, "wf-1", "ready_for_guardian")
    result = evaluation.invalidate_if_ready(conn, "wf-1")
    assert result is True
    row = evaluation.get(conn, "wf-1")
    assert row["status"] == "pending"


def test_invalidate_pending_is_noop(conn):
    evaluation.set_status(conn, "wf-1", "pending")
    result = evaluation.invalidate_if_ready(conn, "wf-1")
    assert result is False
    row = evaluation.get(conn, "wf-1")
    assert row["status"] == "pending"


def test_invalidate_needs_changes_is_noop(conn):
    evaluation.set_status(conn, "wf-1", "needs_changes")
    result = evaluation.invalidate_if_ready(conn, "wf-1")
    assert result is False
    row = evaluation.get(conn, "wf-1")
    assert row["status"] == "needs_changes"


def test_invalidate_missing_row_returns_false(conn):
    result = evaluation.invalidate_if_ready(conn, "wf-missing")
    assert result is False


def test_invalidate_blocked_by_plan_is_noop(conn):
    evaluation.set_status(conn, "wf-1", "blocked_by_plan")
    result = evaluation.invalidate_if_ready(conn, "wf-1")
    assert result is False


# ---------------------------------------------------------------------------
# Compound interaction: production sequence end-to-end
# ---------------------------------------------------------------------------

def test_full_evaluator_lifecycle(conn):
    """Exercise the real production sequence across multiple state transitions.

    Production sequence (Phase 8 Slice 11: reviewer replaces retired ``tester``):
      1. implementer completes → post-task.sh writes pending
      2. evaluator (reviewer, historically the tester stop hook) writes
         ready_for_guardian + head_sha
      3. source write detected → track.sh calls invalidate_if_ready → pending
      4. evaluator re-runs → ready_for_guardian again
      5. guard.sh checks eval_status == ready_for_guardian AND head_sha matches

    This test crosses get(), set_status(), and invalidate_if_ready() in the
    order that production hooks invoke them.
    """
    wf = "feature-tkt-024"
    head = "c2631ac"

    # Step 1: implementer done, evaluation pending
    evaluation.set_status(conn, wf, "pending")
    assert evaluation.get(conn, wf)["status"] == "pending"

    # Step 2: tester clears with head_sha
    evaluation.set_status(conn, wf, "ready_for_guardian", head_sha=head)
    row = evaluation.get(conn, wf)
    assert row["status"] == "ready_for_guardian"
    assert row["head_sha"] == head

    # Step 3: source write invalidates
    invalidated = evaluation.invalidate_if_ready(conn, wf)
    assert invalidated is True
    row = evaluation.get(conn, wf)
    assert row["status"] == "pending"
    # head_sha preserved through invalidation
    assert row["head_sha"] == head

    # Step 4: tester re-evaluates with new SHA
    new_head = "abc1234"
    evaluation.set_status(conn, wf, "ready_for_guardian", head_sha=new_head)
    row = evaluation.get(conn, wf)
    assert row["status"] == "ready_for_guardian"
    assert row["head_sha"] == new_head

    # Step 5: guard gate check — eval_status correct and SHA accessible
    fetched = evaluation.get(conn, wf)
    assert fetched["status"] == "ready_for_guardian"
    assert fetched["head_sha"] == new_head

    # A18: proof_state table was retired post-Phase-8 under
    # DEC-CATEGORY-C-PROOF-RETIRE-001 (Category C bundle 1). The original
    # assertion probed the retired table to confirm evaluation domain did not
    # accidentally write to it — that guarantee is now structural (no table
    # to write to). Assertion replaced with a schema-absence check that fails
    # loudly if the table is ever reintroduced, preserving the original
    # "evaluation domain has nothing to do with proof_state" invariant.
    proof_table = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='proof_state'"
    ).fetchone()
    assert proof_table is None, (
        "proof_state table reappeared in schema — Category C bundle 1 "
        "retirement was reversed; evaluation domain invariant needs re-audit"
    )
