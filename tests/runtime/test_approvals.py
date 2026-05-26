"""Unit tests for runtime/core/approvals.py

@decision DEC-APPROVAL-001
Title: SQLite-backed approval tokens gate high-risk git ops
Status: accepted
Rationale: These tests exercise the three public functions (grant,
  check_and_consume, list_pending) against an in-memory SQLite database
  to prove the one-shot token semantics that guard.sh Check 13 relies on.
  External DB, hooks, and CLI are tested separately in the E2E scenario.
"""

import sqlite3

import pytest

from runtime.schemas import APPROVAL_OP_TYPES, ensure_schema
from runtime.core import approvals


# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    """In-memory SQLite connection with full schema applied."""
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


# ---------------------------------------------------------------------------
# grant()
# ---------------------------------------------------------------------------


def test_grant_returns_positive_int(conn):
    rid = approvals.grant(conn, "wf-1", "push")
    assert isinstance(rid, int)
    assert rid > 0


def test_grant_increments_id(conn):
    rid1 = approvals.grant(conn, "wf-1", "push")
    rid2 = approvals.grant(conn, "wf-1", "push")
    assert rid2 > rid1


def test_grant_all_valid_op_types(conn):
    """Every member of APPROVAL_OP_TYPES can be granted without error."""
    for op in sorted(APPROVAL_OP_TYPES):
        rid = approvals.grant(conn, "wf-all", op)
        assert rid > 0, f"grant failed for op_type={op!r}"


def test_grant_rejects_invalid_op_type(conn):
    with pytest.raises(ValueError, match="unknown op_type"):
        approvals.grant(conn, "wf-1", "invalid_op")


def test_grant_rejects_empty_op_type(conn):
    with pytest.raises(ValueError, match="unknown op_type"):
        approvals.grant(conn, "wf-1", "")


def test_grant_default_granted_by_is_user(conn):
    approvals.grant(conn, "wf-1", "push")
    row = conn.execute(
        "SELECT granted_by FROM approvals WHERE workflow_id = ?", ("wf-1",)
    ).fetchone()
    assert row["granted_by"] == "user"


def test_grant_custom_granted_by(conn):
    approvals.grant(conn, "wf-1", "push", granted_by="orchestrator")
    row = conn.execute(
        "SELECT granted_by FROM approvals WHERE workflow_id = ?", ("wf-1",)
    ).fetchone()
    assert row["granted_by"] == "orchestrator"


def test_grant_sets_consumed_zero(conn):
    approvals.grant(conn, "wf-1", "push")
    row = conn.execute("SELECT consumed FROM approvals WHERE workflow_id = ?", ("wf-1",)).fetchone()
    assert row["consumed"] == 0


# ---------------------------------------------------------------------------
# check_and_consume()
# ---------------------------------------------------------------------------


def test_check_and_consume_returns_true_when_token_exists(conn):
    approvals.grant(conn, "wf-1", "push")
    result = approvals.check_and_consume(conn, "wf-1", "push")
    assert result is True


def test_check_and_consume_one_shot_second_call_returns_false(conn):
    """The one-shot invariant: second call on same (wf, op) returns False."""
    approvals.grant(conn, "wf-1", "push")
    assert approvals.check_and_consume(conn, "wf-1", "push") is True
    assert approvals.check_and_consume(conn, "wf-1", "push") is False


def test_check_and_consume_returns_false_when_no_token(conn):
    result = approvals.check_and_consume(conn, "wf-1", "push")
    assert result is False


def test_check_and_consume_marks_row_consumed(conn):
    approvals.grant(conn, "wf-1", "push")
    approvals.check_and_consume(conn, "wf-1", "push")
    row = conn.execute("SELECT consumed FROM approvals WHERE workflow_id = ?", ("wf-1",)).fetchone()
    assert row["consumed"] == 1


def test_check_and_consume_sets_consumed_at(conn):
    approvals.grant(conn, "wf-1", "push")
    approvals.check_and_consume(conn, "wf-1", "push")
    row = conn.execute(
        "SELECT consumed_at FROM approvals WHERE workflow_id = ?", ("wf-1",)
    ).fetchone()
    assert row["consumed_at"] is not None
    assert row["consumed_at"] > 0


def test_check_and_consume_isolates_by_op_type(conn):
    """Token for 'push' does not satisfy 'rebase' check."""
    approvals.grant(conn, "wf-1", "push")
    assert approvals.check_and_consume(conn, "wf-1", "rebase") is False
    # The push token is still unconsumed
    assert approvals.check_and_consume(conn, "wf-1", "push") is True


def test_check_and_consume_isolates_by_workflow_id(conn):
    """Token for wf-1 does not satisfy wf-2."""
    approvals.grant(conn, "wf-1", "push")
    assert approvals.check_and_consume(conn, "wf-2", "push") is False
    assert approvals.check_and_consume(conn, "wf-1", "push") is True


def test_check_and_consume_consumes_oldest_first(conn):
    """With multiple tokens, the earliest created_at is consumed first."""
    approvals.grant(conn, "wf-1", "push")
    approvals.grant(conn, "wf-1", "push")
    assert approvals.check_and_consume(conn, "wf-1", "push") is True
    # Second token should still be unconsumed
    pending = approvals.list_pending(conn, "wf-1")
    assert len(pending) == 1
    # The consumed one should be the first (earliest id) row
    consumed = conn.execute("SELECT id, consumed FROM approvals ORDER BY id").fetchall()
    assert consumed[0]["consumed"] == 1  # first grant consumed
    assert consumed[1]["consumed"] == 0  # second grant still pending


# ---------------------------------------------------------------------------
# list_pending()
# ---------------------------------------------------------------------------


def test_list_pending_empty_when_none(conn):
    assert approvals.list_pending(conn) == []


def test_list_pending_returns_unconsumed_only(conn):
    approvals.grant(conn, "wf-1", "push")
    approvals.grant(conn, "wf-1", "rebase")
    approvals.check_and_consume(conn, "wf-1", "push")
    pending = approvals.list_pending(conn)
    assert len(pending) == 1
    assert pending[0]["op_type"] == "rebase"


def test_list_pending_filters_by_workflow_id(conn):
    approvals.grant(conn, "wf-1", "push")
    approvals.grant(conn, "wf-2", "push")
    wf1_pending = approvals.list_pending(conn, "wf-1")
    wf2_pending = approvals.list_pending(conn, "wf-2")
    all_pending = approvals.list_pending(conn)
    assert len(wf1_pending) == 1
    assert len(wf2_pending) == 1
    assert len(all_pending) == 2
    assert wf1_pending[0]["workflow_id"] == "wf-1"
    assert wf2_pending[0]["workflow_id"] == "wf-2"


def test_list_pending_returns_dicts_with_expected_keys(conn):
    approvals.grant(conn, "wf-1", "push")
    pending = approvals.list_pending(conn)
    assert len(pending) == 1
    row = pending[0]
    for key in ("id", "workflow_id", "op_type", "granted_by", "created_at"):
        assert key in row, f"missing key {key!r} in list_pending row"


def test_list_pending_none_after_all_consumed(conn):
    approvals.grant(conn, "wf-1", "push")
    approvals.check_and_consume(conn, "wf-1", "push")
    assert approvals.list_pending(conn) == []


# ---------------------------------------------------------------------------
# Compound interaction — end-to-end token lifecycle
# ---------------------------------------------------------------------------


def test_full_approval_lifecycle(conn):
    """Compound test: grant → check-and-consume → exhausted → list shows nothing.

    This exercises the real production sequence:
      1. User grants approval via cc-policy approval grant
      2. guard.sh Check 13 calls check_and_consume (consumes token)
      3. Subsequent guard.sh calls for same op are denied (no token)
      4. list_pending confirms the consumed token is no longer shown
    """
    # Step 1: grant
    rid = approvals.grant(conn, "wf-prod", "push", granted_by="user")
    assert rid > 0

    # Pending before consumption
    pending_before = approvals.list_pending(conn, "wf-prod")
    assert len(pending_before) == 1
    assert pending_before[0]["op_type"] == "push"

    # Step 2: guard.sh Check 13 path — first call consumes
    consumed = approvals.check_and_consume(conn, "wf-prod", "push")
    assert consumed is True

    # Step 3: second call (same guard.sh Check 13 re-run) returns False
    consumed_again = approvals.check_and_consume(conn, "wf-prod", "push")
    assert consumed_again is False

    # Step 4: list shows nothing
    pending_after = approvals.list_pending(conn, "wf-prod")
    assert len(pending_after) == 0


def test_multiple_op_types_independent_lifecycle(conn):
    """Multiple op-type tokens coexist and are consumed independently."""
    approvals.grant(conn, "wf-1", "push")
    approvals.grant(conn, "wf-1", "rebase")
    approvals.grant(conn, "wf-1", "reset")

    assert len(approvals.list_pending(conn, "wf-1")) == 3

    assert approvals.check_and_consume(conn, "wf-1", "rebase") is True
    pending = approvals.list_pending(conn, "wf-1")
    assert len(pending) == 2
    op_types = {r["op_type"] for r in pending}
    assert "rebase" not in op_types
    assert "push" in op_types
    assert "reset" in op_types
