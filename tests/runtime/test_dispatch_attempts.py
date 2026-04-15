"""Invariant and integration tests for runtime/core/dispatch_attempts.py.

Pins:
1. ``issue()`` creates a pending attempt with correct defaults.
2. ``get()`` returns None for unknown IDs.
3. State-machine happy path:  pending→delivered→acknowledged.
4. State-machine cancel path: pending→cancelled.
5. State-machine timeout+retry cycle: pending→timed_out→pending (+retry_count).
6. State-machine fail+retry cycle: delivered→failed→pending (+retry_count).
7. ``retry()`` clears ``delivery_claimed_at`` on each retry.
8. Invalid transitions raise ``ValueError``.
9. Terminal states (acknowledged, cancelled) reject all transitions.
10. ``list_for_seat()`` returns correct subset ordered by created_at.
11. ``list_for_seat()`` status filter rejects unknown statuses.
12. ``expire_stale()`` marks pending/delivered attempts past timeout_at.
13. ``expire_stale()`` does not touch already-terminal or already-timed-out rows.
14. ``expire_stale()`` ignores attempts with no timeout_at.
15. Multiple attempts for one seat are independent.

These tests import only ``runtime.core.dispatch_attempts`` and
``runtime.schemas``.  No adapter, hook, or bridge code.
"""

from __future__ import annotations

import sqlite3
import time

import pytest

from runtime.core import dispatch_attempts as da
from runtime.schemas import ensure_schema


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    # Insert a minimal seat so FK references resolve without errors.
    # (SQLite does not enforce FK by default but explicit rows keep tests clear.)
    now = int(time.time())
    c.execute(
        "INSERT INTO agent_sessions (session_id, transport, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
        ("sess-da-01", "claude_code", "active", now, now),
    )
    c.execute(
        "INSERT INTO seats (seat_id, session_id, role, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
        ("seat-da-01", "sess-da-01", "worker", "active", now, now),
    )
    c.commit()
    yield c
    c.close()


SEAT = "seat-da-01"


def _issue(conn, instruction="do the thing", **kw) -> dict:
    return da.issue(conn, SEAT, instruction, **kw)


# ---------------------------------------------------------------------------
# 1. issue()
# ---------------------------------------------------------------------------


def test_issue_returns_dict_with_attempt_id(conn):
    row = _issue(conn)
    assert isinstance(row, dict)
    assert "attempt_id" in row
    assert len(row["attempt_id"]) == 32  # uuid4.hex


def test_issue_status_is_pending(conn):
    row = _issue(conn)
    assert row["status"] == "pending"


def test_issue_retry_count_zero(conn):
    row = _issue(conn)
    assert row["retry_count"] == 0


def test_issue_delivery_and_ack_timestamps_null(conn):
    row = _issue(conn)
    assert row["delivery_claimed_at"] is None
    assert row["acknowledged_at"] is None


def test_issue_stores_seat_id(conn):
    row = _issue(conn)
    assert row["seat_id"] == SEAT


def test_issue_stores_instruction(conn):
    row = _issue(conn, instruction="run tests")
    assert row["instruction"] == "run tests"


def test_issue_stores_workflow_id(conn):
    row = _issue(conn, workflow_id="wf-test-01")
    assert row["workflow_id"] == "wf-test-01"


def test_issue_stores_timeout_at(conn):
    t = int(time.time()) + 300
    row = _issue(conn, timeout_at=t)
    assert row["timeout_at"] == t


def test_issue_timeout_at_none_by_default(conn):
    row = _issue(conn)
    assert row["timeout_at"] is None


# ---------------------------------------------------------------------------
# 2. get()
# ---------------------------------------------------------------------------


def test_get_returns_none_for_unknown(conn):
    assert da.get(conn, "deadbeef" * 4) is None


def test_get_returns_row_for_known(conn):
    row = _issue(conn)
    fetched = da.get(conn, row["attempt_id"])
    assert fetched is not None
    assert fetched["attempt_id"] == row["attempt_id"]


# ---------------------------------------------------------------------------
# 3. Happy path: pending → delivered → acknowledged
# ---------------------------------------------------------------------------


def test_claim_transitions_to_delivered(conn):
    row = _issue(conn)
    updated = da.claim(conn, row["attempt_id"])
    assert updated["status"] == "delivered"


def test_claim_sets_delivery_claimed_at(conn):
    row = _issue(conn)
    before = int(time.time())
    updated = da.claim(conn, row["attempt_id"])
    assert updated["delivery_claimed_at"] is not None
    assert updated["delivery_claimed_at"] >= before


def test_acknowledge_transitions_to_acknowledged(conn):
    row = _issue(conn)
    da.claim(conn, row["attempt_id"])
    updated = da.acknowledge(conn, row["attempt_id"])
    assert updated["status"] == "acknowledged"


def test_acknowledge_sets_acknowledged_at(conn):
    row = _issue(conn)
    da.claim(conn, row["attempt_id"])
    before = int(time.time())
    updated = da.acknowledge(conn, row["attempt_id"])
    assert updated["acknowledged_at"] >= before


# ---------------------------------------------------------------------------
# 4. Cancel path: pending → cancelled
# ---------------------------------------------------------------------------


def test_cancel_transitions_to_cancelled(conn):
    row = _issue(conn)
    updated = da.cancel(conn, row["attempt_id"])
    assert updated["status"] == "cancelled"


def test_cancel_from_delivered_is_invalid(conn):
    row = _issue(conn)
    da.claim(conn, row["attempt_id"])
    with pytest.raises(ValueError, match="invalid transition"):
        da.cancel(conn, row["attempt_id"])


# ---------------------------------------------------------------------------
# 5. Timeout + retry cycle
# ---------------------------------------------------------------------------


def test_timeout_from_pending_transitions_to_timed_out(conn):
    row = _issue(conn)
    updated = da.timeout(conn, row["attempt_id"])
    assert updated["status"] == "timed_out"


def test_timeout_from_delivered_transitions_to_timed_out(conn):
    row = _issue(conn)
    da.claim(conn, row["attempt_id"])
    updated = da.timeout(conn, row["attempt_id"])
    assert updated["status"] == "timed_out"


def test_retry_from_timed_out_resets_to_pending(conn):
    row = _issue(conn)
    da.timeout(conn, row["attempt_id"])
    updated = da.retry(conn, row["attempt_id"])
    assert updated["status"] == "pending"


def test_retry_increments_retry_count(conn):
    row = _issue(conn)
    da.timeout(conn, row["attempt_id"])
    updated = da.retry(conn, row["attempt_id"])
    assert updated["retry_count"] == 1


def test_retry_multiple_times_accumulates_count(conn):
    row = _issue(conn)
    aid = row["attempt_id"]
    for i in range(3):
        da.timeout(conn, aid)
        da.retry(conn, aid)
    updated = da.get(conn, aid)
    assert updated["retry_count"] == 3


# ---------------------------------------------------------------------------
# 6. Fail + retry cycle
# ---------------------------------------------------------------------------


def test_fail_from_delivered_transitions_to_failed(conn):
    row = _issue(conn)
    da.claim(conn, row["attempt_id"])
    updated = da.fail(conn, row["attempt_id"])
    assert updated["status"] == "failed"


def test_fail_from_pending_is_invalid(conn):
    row = _issue(conn)
    with pytest.raises(ValueError, match="invalid transition"):
        da.fail(conn, row["attempt_id"])


def test_retry_from_failed_resets_to_pending(conn):
    row = _issue(conn)
    da.claim(conn, row["attempt_id"])
    da.fail(conn, row["attempt_id"])
    updated = da.retry(conn, row["attempt_id"])
    assert updated["status"] == "pending"
    assert updated["retry_count"] == 1


# ---------------------------------------------------------------------------
# 7. retry() clears delivery_claimed_at
# ---------------------------------------------------------------------------


def test_retry_clears_delivery_claimed_at(conn):
    row = _issue(conn)
    da.claim(conn, row["attempt_id"])
    da.timeout(conn, row["attempt_id"])
    updated = da.retry(conn, row["attempt_id"])
    assert updated["delivery_claimed_at"] is None


# ---------------------------------------------------------------------------
# 8 + 9. Invalid transitions and terminal states
# ---------------------------------------------------------------------------


class TestInvalidTransitions:
    def test_claim_from_delivered_is_invalid(self, conn):
        row = _issue(conn)
        da.claim(conn, row["attempt_id"])
        with pytest.raises(ValueError, match="invalid transition"):
            da.claim(conn, row["attempt_id"])

    def test_acknowledge_from_pending_is_invalid(self, conn):
        row = _issue(conn)
        with pytest.raises(ValueError, match="invalid transition"):
            da.acknowledge(conn, row["attempt_id"])

    def test_timeout_from_acknowledged_is_invalid(self, conn):
        row = _issue(conn)
        da.claim(conn, row["attempt_id"])
        da.acknowledge(conn, row["attempt_id"])
        with pytest.raises(ValueError, match="invalid transition"):
            da.timeout(conn, row["attempt_id"])

    def test_retry_from_pending_is_invalid(self, conn):
        row = _issue(conn)
        with pytest.raises(ValueError, match="invalid transition"):
            da.retry(conn, row["attempt_id"])

    def test_retry_from_acknowledged_is_invalid(self, conn):
        row = _issue(conn)
        da.claim(conn, row["attempt_id"])
        da.acknowledge(conn, row["attempt_id"])
        with pytest.raises(ValueError, match="invalid transition"):
            da.retry(conn, row["attempt_id"])

    def test_any_transition_on_unknown_id_raises(self, conn):
        with pytest.raises(ValueError, match="not found"):
            da.claim(conn, "no-such-attempt")


class TestTerminalStates:
    def test_acknowledged_rejects_claim(self, conn):
        row = _issue(conn)
        da.claim(conn, row["attempt_id"])
        da.acknowledge(conn, row["attempt_id"])
        with pytest.raises(ValueError):
            da.claim(conn, row["attempt_id"])

    def test_acknowledged_rejects_cancel(self, conn):
        row = _issue(conn)
        da.claim(conn, row["attempt_id"])
        da.acknowledge(conn, row["attempt_id"])
        with pytest.raises(ValueError):
            da.cancel(conn, row["attempt_id"])

    def test_cancelled_rejects_claim(self, conn):
        row = _issue(conn)
        da.cancel(conn, row["attempt_id"])
        with pytest.raises(ValueError):
            da.claim(conn, row["attempt_id"])

    def test_cancelled_rejects_retry(self, conn):
        row = _issue(conn)
        da.cancel(conn, row["attempt_id"])
        with pytest.raises(ValueError):
            da.retry(conn, row["attempt_id"])


# ---------------------------------------------------------------------------
# 10. list_for_seat()
# ---------------------------------------------------------------------------


def test_list_for_seat_returns_all_for_seat(conn):
    for i in range(3):
        _issue(conn, instruction=f"task {i}")
    rows = da.list_for_seat(conn, SEAT)
    assert len(rows) == 3


def test_list_for_seat_ordered_by_created_at(conn):
    for i in range(3):
        _issue(conn, instruction=f"task {i}")
    rows = da.list_for_seat(conn, SEAT)
    ts = [r["created_at"] for r in rows]
    assert ts == sorted(ts)


def test_list_for_seat_status_filter(conn):
    r1 = _issue(conn, instruction="t1")
    r2 = _issue(conn, instruction="t2")
    da.claim(conn, r1["attempt_id"])
    pending = da.list_for_seat(conn, SEAT, status="pending")
    delivered = da.list_for_seat(conn, SEAT, status="delivered")
    assert len(pending) == 1
    assert pending[0]["attempt_id"] == r2["attempt_id"]
    assert len(delivered) == 1
    assert delivered[0]["attempt_id"] == r1["attempt_id"]


def test_list_for_seat_empty_for_unknown_seat(conn):
    rows = da.list_for_seat(conn, "no-such-seat")
    assert rows == []


# ---------------------------------------------------------------------------
# 11. list_for_seat() status filter rejects unknown statuses
# ---------------------------------------------------------------------------


def test_list_for_seat_rejects_unknown_status(conn):
    with pytest.raises(ValueError, match="unknown status"):
        da.list_for_seat(conn, SEAT, status="flying")


# ---------------------------------------------------------------------------
# 12. expire_stale() — marks eligible attempts
# ---------------------------------------------------------------------------


def test_expire_stale_marks_pending_past_timeout(conn):
    past = int(time.time()) - 10
    row = _issue(conn, timeout_at=past)
    count = da.expire_stale(conn)
    assert count == 1
    updated = da.get(conn, row["attempt_id"])
    assert updated["status"] == "timed_out"


def test_expire_stale_marks_delivered_past_timeout(conn):
    past = int(time.time()) - 10
    row = _issue(conn, timeout_at=past)
    da.claim(conn, row["attempt_id"])
    count = da.expire_stale(conn)
    assert count == 1
    updated = da.get(conn, row["attempt_id"])
    assert updated["status"] == "timed_out"


def test_expire_stale_returns_count(conn):
    past = int(time.time()) - 10
    for _ in range(4):
        _issue(conn, timeout_at=past)
    count = da.expire_stale(conn)
    assert count == 4


def test_expire_stale_not_yet_expired_stays_pending(conn):
    future = int(time.time()) + 3600
    row = _issue(conn, timeout_at=future)
    da.expire_stale(conn)
    assert da.get(conn, row["attempt_id"])["status"] == "pending"


# ---------------------------------------------------------------------------
# 13. expire_stale() — does not touch terminal or already-timed-out rows
# ---------------------------------------------------------------------------


def test_expire_stale_skips_acknowledged(conn):
    past = int(time.time()) - 10
    row = _issue(conn, timeout_at=past)
    da.claim(conn, row["attempt_id"])
    da.acknowledge(conn, row["attempt_id"])
    count = da.expire_stale(conn)
    assert count == 0
    assert da.get(conn, row["attempt_id"])["status"] == "acknowledged"


def test_expire_stale_skips_cancelled(conn):
    past = int(time.time()) - 10
    row = _issue(conn, timeout_at=past)
    da.cancel(conn, row["attempt_id"])
    count = da.expire_stale(conn)
    assert count == 0


def test_expire_stale_skips_already_timed_out(conn):
    past = int(time.time()) - 10
    row = _issue(conn, timeout_at=past)
    da.timeout(conn, row["attempt_id"])
    count = da.expire_stale(conn)
    assert count == 0


def test_expire_stale_skips_failed(conn):
    past = int(time.time()) - 10
    row = _issue(conn, timeout_at=past)
    da.claim(conn, row["attempt_id"])
    da.fail(conn, row["attempt_id"])
    count = da.expire_stale(conn)
    assert count == 0


# ---------------------------------------------------------------------------
# 14. expire_stale() — no timeout_at means no auto-expiry
# ---------------------------------------------------------------------------


def test_expire_stale_ignores_no_timeout(conn):
    row = _issue(conn)  # no timeout_at
    count = da.expire_stale(conn)
    assert count == 0
    assert da.get(conn, row["attempt_id"])["status"] == "pending"


# ---------------------------------------------------------------------------
# 15. Multiple attempts for one seat are independent
# ---------------------------------------------------------------------------


def test_multiple_attempts_independent(conn):
    r1 = _issue(conn, instruction="first")
    r2 = _issue(conn, instruction="second")
    da.claim(conn, r1["attempt_id"])
    da.acknowledge(conn, r1["attempt_id"])
    # r2 must be unaffected
    assert da.get(conn, r2["attempt_id"])["status"] == "pending"
    assert da.get(conn, r1["attempt_id"])["status"] == "acknowledged"


def test_each_attempt_has_unique_id(conn):
    rows = [_issue(conn) for _ in range(5)]
    ids = {r["attempt_id"] for r in rows}
    assert len(ids) == 5
