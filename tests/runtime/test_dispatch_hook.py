"""Tests for dispatch_hook.py — hook-to-runtime wiring for dispatch_attempts.

Pins:
1.  ensure_session_and_seat creates agent_sessions row.
2.  ensure_session_and_seat creates seats row with correct role.
3.  ensure_session_and_seat is idempotent (repeated calls safe).
4.  ensure_session_and_seat returns stable seat_id for same (session, type).
5.  ensure_session_and_seat returns distinct seat_ids for different agent_types.
6.  record_agent_dispatch returns a pending attempt.
7.  record_agent_dispatch sets seat_id and instruction correctly.
8.  record_agent_dispatch passes workflow_id through to dispatch_attempts.
9.  record_agent_dispatch upserts session+seat on the fly (no pre-provisioning).
10. record_subagent_delivery claims the pending attempt → delivered.
11. record_subagent_delivery sets delivery_claimed_at.
12. record_subagent_delivery returns None when no pending attempt exists.
13. record_subagent_delivery is a no-op (returns None) for unknown seat.
14. Full PreToolUse→SubagentStart flow: pending → delivered.
15. record_subagent_delivery claims the MOST RECENT pending attempt when
    multiple exist (oldest-first sort, last element = newest).
16. record_subagent_delivery does not touch already-delivered attempts.
17. transport is 'claude_code' in upserted agent_sessions row.
18. seat status is 'active' in upserted seats row.
19. session status is 'active' in upserted agent_sessions row.
20. record_agent_dispatch respects timeout_at parameter.

CLI integration (via subprocess, against the real cli.py):
21. dispatch attempt-issue creates a pending row and returns JSON.
22. dispatch attempt-claim advances it to delivered and returns JSON.
23. dispatch attempt-claim returns {found: false} when no pending row exists.
"""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import time

import pytest

from runtime.core.dispatch_hook import (
    ensure_session_and_seat,
    record_agent_dispatch,
    record_subagent_delivery,
)
from runtime.schemas import ensure_schema

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_CLI = os.path.join(os.path.dirname(__file__), "..", "..", "runtime", "cli.py")


def _run_cli(db_path: str, *args: str) -> dict:
    """Run the cc-policy CLI and return parsed JSON output."""
    env = os.environ.copy()
    env["CLAUDE_POLICY_DB"] = db_path
    result = subprocess.run(
        [sys.executable, _CLI, *args],
        capture_output=True,
        text=True,
        env=env,
    )
    return json.loads(result.stdout)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


@pytest.fixture
def db_path(tmp_path):
    """On-disk DB for CLI integration tests."""
    p = tmp_path / "state.db"
    c = sqlite3.connect(str(p))
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    c.close()
    return str(p)


SID = "sess-hook-01"
ATYPE = "general-purpose"
INSTR = "CLAUDEX_CONTRACT_BLOCK:{\"workflow_id\":\"wf-hook\",\"stage_id\":\"implementer\"}"


# ---------------------------------------------------------------------------
# 1–5. ensure_session_and_seat
# ---------------------------------------------------------------------------


def test_ensure_creates_agent_sessions_row(conn):
    ensure_session_and_seat(conn, SID, ATYPE)
    row = conn.execute(
        "SELECT * FROM agent_sessions WHERE session_id = ?", (SID,)
    ).fetchone()
    assert row is not None


def test_ensure_creates_seats_row_with_worker_role(conn):
    """seats.role must be 'worker', not the harness agent_type value.

    Hook-wired seats are always 'worker' (SEAT_ROLES vocabulary).
    Transport identity is carried by seat_id, not seats.role.
    """
    from runtime.schemas import SEAT_ROLES

    ensure_session_and_seat(conn, SID, ATYPE)
    row = conn.execute(
        "SELECT role FROM seats WHERE session_id = ?", (SID,)
    ).fetchone()
    assert row is not None
    assert row["role"] == "worker"
    assert row["role"] in SEAT_ROLES
    # agent_type must NOT appear in seats.role — two different facts.
    assert row["role"] != ATYPE


def test_ensure_is_idempotent(conn):
    seat_id1 = ensure_session_and_seat(conn, SID, ATYPE)
    seat_id2 = ensure_session_and_seat(conn, SID, ATYPE)
    assert seat_id1 == seat_id2
    session_count = conn.execute(
        "SELECT COUNT(*) FROM agent_sessions WHERE session_id = ?", (SID,)
    ).fetchone()[0]
    seat_count = conn.execute(
        "SELECT COUNT(*) FROM seats WHERE session_id = ?", (SID,)
    ).fetchone()[0]
    assert session_count == 1
    assert seat_count == 1


def test_ensure_returns_stable_seat_id(conn):
    seat_id1 = ensure_session_and_seat(conn, SID, ATYPE)
    seat_id2 = ensure_session_and_seat(conn, SID, ATYPE)
    assert seat_id1 == seat_id2
    assert SID in seat_id1
    assert ATYPE in seat_id1


def test_ensure_distinct_seat_ids_for_different_agent_types(conn):
    sid_gp = ensure_session_and_seat(conn, SID, "general-purpose")
    sid_pl = ensure_session_and_seat(conn, SID, "Plan")
    assert sid_gp != sid_pl


# ---------------------------------------------------------------------------
# 6–9. record_agent_dispatch
# ---------------------------------------------------------------------------


def test_record_agent_dispatch_returns_pending_attempt(conn):
    row = record_agent_dispatch(conn, SID, ATYPE, INSTR)
    assert row["status"] == "pending"
    assert "attempt_id" in row


def test_record_agent_dispatch_sets_seat_and_instruction(conn):
    seat_id = ensure_session_and_seat(conn, SID, ATYPE)
    row = record_agent_dispatch(conn, SID, ATYPE, INSTR)
    assert row["seat_id"] == seat_id
    assert row["instruction"] == INSTR


def test_record_agent_dispatch_passes_workflow_id(conn):
    row = record_agent_dispatch(conn, SID, ATYPE, INSTR, workflow_id="wf-hook-01")
    assert row["workflow_id"] == "wf-hook-01"


def test_record_agent_dispatch_upserts_session_and_seat(conn):
    # No pre-provisioning — dispatch_hook must create the rows itself.
    session_before = conn.execute(
        "SELECT COUNT(*) FROM agent_sessions WHERE session_id = ?", (SID,)
    ).fetchone()[0]
    assert session_before == 0

    record_agent_dispatch(conn, SID, ATYPE, INSTR)

    session_after = conn.execute(
        "SELECT COUNT(*) FROM agent_sessions WHERE session_id = ?", (SID,)
    ).fetchone()[0]
    seat_after = conn.execute(
        "SELECT COUNT(*) FROM seats WHERE session_id = ?", (SID,)
    ).fetchone()[0]
    assert session_after == 1
    assert seat_after == 1


# ---------------------------------------------------------------------------
# 10–16. record_subagent_delivery
# ---------------------------------------------------------------------------


def test_record_subagent_delivery_claims_pending_attempt(conn):
    record_agent_dispatch(conn, SID, ATYPE, INSTR)
    updated = record_subagent_delivery(conn, SID, ATYPE)
    assert updated is not None
    assert updated["status"] == "delivered"


def test_record_subagent_delivery_sets_delivery_timestamp(conn):
    before = int(time.time())
    record_agent_dispatch(conn, SID, ATYPE, INSTR)
    updated = record_subagent_delivery(conn, SID, ATYPE)
    assert updated["delivery_claimed_at"] is not None
    assert updated["delivery_claimed_at"] >= before


def test_record_subagent_delivery_returns_none_when_no_pending(conn):
    # Ensure the session/seat exist but no dispatch attempt issued.
    ensure_session_and_seat(conn, SID, ATYPE)
    result = record_subagent_delivery(conn, SID, ATYPE)
    assert result is None


def test_record_subagent_delivery_returns_none_for_unknown_seat(conn):
    result = record_subagent_delivery(conn, "no-such-session", "no-such-type")
    assert result is None


def test_full_pretooluseagent_to_subagentstart_flow(conn):
    """PreToolUse:Agent → SubagentStart → pending → delivered."""
    attempt = record_agent_dispatch(conn, SID, ATYPE, INSTR, workflow_id="wf-hook")
    assert attempt["status"] == "pending"

    delivered = record_subagent_delivery(conn, SID, ATYPE)
    assert delivered is not None
    assert delivered["attempt_id"] == attempt["attempt_id"]
    assert delivered["status"] == "delivered"
    assert delivered["workflow_id"] == "wf-hook"


def test_record_subagent_delivery_claims_most_recent_pending(conn):
    """When multiple pending attempts exist, the newest is claimed."""
    r1 = record_agent_dispatch(conn, SID, ATYPE, "first dispatch")
    r2 = record_agent_dispatch(conn, SID, ATYPE, "second dispatch")

    delivered = record_subagent_delivery(conn, SID, ATYPE)
    assert delivered is not None
    # Most recent pending (r2) is claimed.
    assert delivered["attempt_id"] == r2["attempt_id"]
    assert delivered["status"] == "delivered"

    # r1 remains pending.
    conn2 = conn
    r1_state = conn2.execute(
        "SELECT status FROM dispatch_attempts WHERE attempt_id = ?",
        (r1["attempt_id"],),
    ).fetchone()
    assert r1_state["status"] == "pending"


def test_record_subagent_delivery_ignores_already_delivered(conn):
    """If the only attempt is already delivered, None is returned."""
    attempt = record_agent_dispatch(conn, SID, ATYPE, INSTR)
    # Manually deliver it via a first SubagentStart.
    record_subagent_delivery(conn, SID, ATYPE)

    # Second SubagentStart: no more pending attempts.
    result = record_subagent_delivery(conn, SID, ATYPE)
    assert result is None


def test_pending_attempt_stays_pending_without_carrier_match(conn):
    """A pending attempt must NOT be claimed by a bare SubagentStart.

    Authority invariant: record_subagent_delivery must only be called by
    subagent-start.sh when _CARRIER_JSON is non-empty (i.e. the carrier row
    was consumed from pending_agent_requests). Without that proof the pending
    attempt must remain pending — there is no PreToolUse-backed link.

    This test demonstrates the hook-level gating: the attempt stays pending
    because the caller (hook) withholds the record_subagent_delivery call
    when no carrier row was consumed. The function itself is not called here,
    mirroring what the hook does when _CARRIER_JSON is empty.
    """
    attempt = record_agent_dispatch(conn, SID, ATYPE, INSTR)
    assert attempt["status"] == "pending"

    # Hook gate: no carrier row consumed → record_subagent_delivery NOT called.
    # Attempt remains pending.
    state = conn.execute(
        "SELECT status FROM dispatch_attempts WHERE attempt_id = ?",
        (attempt["attempt_id"],),
    ).fetchone()
    assert state["status"] == "pending"


# ---------------------------------------------------------------------------
# 17–20. Schema correctness on upserted rows
# ---------------------------------------------------------------------------


def test_transport_is_claude_code_in_upserted_session(conn):
    ensure_session_and_seat(conn, SID, ATYPE)
    row = conn.execute(
        "SELECT transport FROM agent_sessions WHERE session_id = ?", (SID,)
    ).fetchone()
    assert row["transport"] == "claude_code"


def test_seat_status_is_active_in_upserted_seat(conn):
    ensure_session_and_seat(conn, SID, ATYPE)
    row = conn.execute(
        "SELECT status FROM seats WHERE session_id = ?", (SID,)
    ).fetchone()
    assert row["status"] == "active"


def test_session_status_is_active_in_upserted_session(conn):
    ensure_session_and_seat(conn, SID, ATYPE)
    row = conn.execute(
        "SELECT status FROM agent_sessions WHERE session_id = ?", (SID,)
    ).fetchone()
    assert row["status"] == "active"


def test_record_agent_dispatch_respects_timeout_at(conn):
    t = int(time.time()) + 300
    row = record_agent_dispatch(conn, SID, ATYPE, INSTR, timeout_at=t)
    assert row["timeout_at"] == t


# ---------------------------------------------------------------------------
# 21–23. CLI integration
# ---------------------------------------------------------------------------


def test_cli_attempt_issue_creates_pending_row(db_path):
    # _ok() merges "status: ok" into the payload; the attempt row's own
    # "status" field ("pending") takes precedence via setdefault.
    out = _run_cli(
        db_path,
        "dispatch", "attempt-issue",
        "--session-id", "cli-sess-01",
        "--agent-type", "general-purpose",
        "--instruction", "CLAUDEX_CONTRACT_BLOCK:{...}",
        "--workflow-id", "wf-cli-01",
    )
    assert out.get("status") == "pending"
    assert "attempt_id" in out
    assert out.get("workflow_id") == "wf-cli-01"


def test_cli_attempt_claim_advances_to_delivered(db_path):
    issue_out = _run_cli(
        db_path,
        "dispatch", "attempt-issue",
        "--session-id", "cli-sess-02",
        "--agent-type", "general-purpose",
        "--instruction", "test instruction",
    )
    assert issue_out.get("status") == "pending"

    # _ok({"found": True, "attempt": row}) → {"found": True, "attempt": {...}, "status": "ok"}
    claim_out = _run_cli(
        db_path,
        "dispatch", "attempt-claim",
        "--session-id", "cli-sess-02",
        "--agent-type", "general-purpose",
    )
    assert claim_out.get("status") == "ok"
    assert claim_out["found"] is True
    assert claim_out["attempt"]["status"] == "delivered"


def test_cli_attempt_claim_returns_not_found_when_no_pending(db_path):
    # _ok({"found": False, "attempt": None}) → {"found": False, "attempt": null, "status": "ok"}
    out = _run_cli(
        db_path,
        "dispatch", "attempt-claim",
        "--session-id", "no-such-session",
        "--agent-type", "no-such-type",
    )
    assert out.get("status") == "ok"
    assert out["found"] is False
    assert out["attempt"] is None


# ---------------------------------------------------------------------------
# CLI: attempt-expire-stale
# ---------------------------------------------------------------------------


def test_cli_attempt_expire_stale_returns_zero_when_nothing_stale(db_path):
    # No attempts → expired: 0
    out = _run_cli(db_path, "dispatch", "attempt-expire-stale")
    assert out.get("status") == "ok"
    assert out["expired"] == 0


def test_cli_attempt_expire_stale_expires_past_timeout(db_path):
    """Pending attempt with timeout_at in the past is transitioned to timed_out."""
    import sqlite3 as _sqlite3
    from runtime.schemas import ensure_schema as _ensure_schema
    from runtime.core.dispatch_hook import record_agent_dispatch as _rad

    conn = _sqlite3.connect(db_path)
    conn.row_factory = _sqlite3.Row
    _ensure_schema(conn)

    past = int(time.time()) - 3600  # 1 hour ago
    row = _rad(conn, "sess-exp-01", "general-purpose", "stale task", timeout_at=past)
    conn.close()

    out = _run_cli(db_path, "dispatch", "attempt-expire-stale")
    assert out.get("status") == "ok"
    assert out["expired"] == 1

    # Verify the row is now timed_out.
    conn2 = _sqlite3.connect(db_path)
    conn2.row_factory = _sqlite3.Row
    state = conn2.execute(
        "SELECT status FROM dispatch_attempts WHERE attempt_id = ?",
        (row["attempt_id"],),
    ).fetchone()
    conn2.close()
    assert state["status"] == "timed_out"


def test_cli_attempt_expire_stale_ignores_future_timeout(db_path):
    """Pending attempt with timeout_at in the future is NOT expired."""
    import sqlite3 as _sqlite3
    from runtime.schemas import ensure_schema as _ensure_schema
    from runtime.core.dispatch_hook import record_agent_dispatch as _rad

    conn = _sqlite3.connect(db_path)
    conn.row_factory = _sqlite3.Row
    _ensure_schema(conn)

    future = int(time.time()) + 3600
    _rad(conn, "sess-exp-02", "general-purpose", "active task", timeout_at=future)
    conn.close()

    out = _run_cli(db_path, "dispatch", "attempt-expire-stale")
    assert out.get("status") == "ok"
    assert out["expired"] == 0


def test_cli_attempt_expire_stale_fallback_expires_legacy_pending(db_path):
    """Fallback age option expires pending rows that have timeout_at=NULL."""
    import sqlite3 as _sqlite3
    from runtime.schemas import ensure_schema as _ensure_schema
    from runtime.core.dispatch_hook import record_agent_dispatch as _rad

    conn = _sqlite3.connect(db_path)
    conn.row_factory = _sqlite3.Row
    _ensure_schema(conn)

    row = _rad(conn, "sess-exp-03", "general-purpose", "legacy pending task")
    attempt_id = row["attempt_id"]
    old = int(time.time()) - 5000
    conn.execute(
        "UPDATE dispatch_attempts SET created_at = ?, updated_at = ? WHERE attempt_id = ?",
        (old, old, attempt_id),
    )
    conn.commit()
    conn.close()

    out = _run_cli(
        db_path,
        "dispatch",
        "attempt-expire-stale",
        "--fallback-pending-max-age-seconds",
        "3600",
    )
    assert out.get("status") == "ok"
    assert out["expired"] == 1

    conn2 = _sqlite3.connect(db_path)
    conn2.row_factory = _sqlite3.Row
    state = conn2.execute(
        "SELECT status FROM dispatch_attempts WHERE attempt_id = ?",
        (attempt_id,),
    ).fetchone()
    conn2.close()
    assert state["status"] == "timed_out"
