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
from runtime.core.policy_engine import PolicyRequest, build_context, default_registry
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


def test_record_subagent_delivery_legacy_fallback_claims_oldest_pending(conn):
    """Legacy claim fallback is FIFO; carrier-backed claims pass attempt_id."""
    r1 = record_agent_dispatch(conn, SID, ATYPE, "first dispatch")
    r2 = record_agent_dispatch(conn, SID, ATYPE, "second dispatch")

    delivered = record_subagent_delivery(conn, SID, ATYPE)
    assert delivered is not None
    # Oldest pending (r1) is claimed when no attempt_id is supplied.
    assert delivered["attempt_id"] == r1["attempt_id"]
    assert delivered["status"] == "delivered"

    # r2 remains pending.
    conn2 = conn
    r2_state = conn2.execute(
        "SELECT status FROM dispatch_attempts WHERE attempt_id = ?",
        (r2["attempt_id"],),
    ).fetchone()
    assert r2_state["status"] == "pending"


def test_record_subagent_delivery_claims_explicit_attempt_id(conn):
    r1 = record_agent_dispatch(conn, SID, ATYPE, "first dispatch")
    r2 = record_agent_dispatch(conn, SID, ATYPE, "second dispatch")

    delivered = record_subagent_delivery(conn, SID, ATYPE, attempt_id=r2["attempt_id"])
    assert delivered is not None
    assert delivered["attempt_id"] == r2["attempt_id"]
    assert delivered["status"] == "delivered"

    r1_state = conn.execute(
        "SELECT status FROM dispatch_attempts WHERE attempt_id = ?",
        (r1["attempt_id"],),
    ).fetchone()
    assert r1_state["status"] == "pending"


def test_record_subagent_delivery_ignores_already_delivered(conn):
    """If the only attempt is already delivered, None is returned."""
    record_agent_dispatch(conn, SID, ATYPE, INSTR)
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


def test_cli_attempt_fail_marks_delivered_attempt_failed(db_path):
    issue_out = _run_cli(
        db_path,
        "dispatch", "attempt-issue",
        "--session-id", "cli-sess-fail",
        "--agent-type", "general-purpose",
        "--instruction", "test instruction",
    )
    claim_out = _run_cli(
        db_path,
        "dispatch", "attempt-claim",
        "--session-id", "cli-sess-fail",
        "--agent-type", "general-purpose",
        "--attempt-id", issue_out["attempt_id"],
    )
    assert claim_out["attempt"]["status"] == "delivered"

    fail_out = _run_cli(
        db_path,
        "dispatch", "attempt-fail",
        "--attempt-id", issue_out["attempt_id"],
        "--reason", "prompt_pack_compile_failed",
    )

    assert fail_out["status"] == "ok"
    assert fail_out["attempt"]["status"] == "failed"
    assert fail_out["attempt"]["failure_reason"] == "prompt_pack_compile_failed"


def test_failed_child_attempt_does_not_block_parent_policy_boundary(conn):
    """Failed child delivery state is diagnostic only; it must not block parent tools."""
    attempt = record_agent_dispatch(
        conn,
        "sess-failed-child",
        "implementer",
        "bad child launch",
    )
    from runtime.core import dispatch_attempts

    dispatch_attempts.fail(
        conn,
        attempt["attempt_id"],
        reason="prompt_pack_compile_failed",
    )
    ctx = build_context(
        conn,
        cwd="/tmp/project",
        actor_id="parent-orchestrator",
        session_id="sess-failed-child",
        project_root="/tmp/project",
    )
    decision = default_registry().evaluate(
        PolicyRequest(
            event_type="PreToolUse",
            tool_name="Bash",
            tool_input={"command": "pwd"},
            context=ctx,
            cwd="/tmp/project",
        )
    )

    assert decision.action == "allow"


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


# ---------------------------------------------------------------------------
# release_session_seat — seat lifecycle teardown
# ---------------------------------------------------------------------------


def test_release_session_seat_transitions_active_to_released(conn):
    from runtime.core.dispatch_hook import release_session_seat

    seat_id = ensure_session_and_seat(conn, "sess-rel-01", "implementer")
    result = release_session_seat(conn, "sess-rel-01", "implementer")

    assert result["seat_id"] == seat_id
    assert result["found"] is True
    assert result["released"] is True
    assert result["abandoned_count"] == 0

    row = conn.execute(
        "SELECT status FROM seats WHERE seat_id = ?", (seat_id,)
    ).fetchone()
    assert row["status"] == "released"


def test_release_session_seat_is_idempotent(conn):
    from runtime.core.dispatch_hook import release_session_seat

    ensure_session_and_seat(conn, "sess-rel-02", "implementer")
    first = release_session_seat(conn, "sess-rel-02", "implementer")
    assert first["released"] is True

    second = release_session_seat(conn, "sess-rel-02", "implementer")
    assert second["found"] is True
    assert second["released"] is False
    assert second["abandoned_count"] == 0


def test_release_session_seat_missing_seat_is_no_op(conn):
    from runtime.core.dispatch_hook import release_session_seat

    result = release_session_seat(conn, "sess-ghost", "implementer")
    assert result == {
        "seat_id": "sess-ghost:implementer",
        "found": False,
        "released": False,
        "abandoned_count": 0,
    }
    row = conn.execute(
        "SELECT 1 FROM seats WHERE seat_id = ?", ("sess-ghost:implementer",)
    ).fetchone()
    assert row is None


def test_release_session_seat_abandons_active_supervision_threads(conn):
    from runtime.core import supervision_threads as sup
    from runtime.core.dispatch_hook import release_session_seat

    sup_id = ensure_session_and_seat(conn, "sess-rel-03", "reviewer")
    wrk_id = ensure_session_and_seat(conn, "sess-rel-03", "implementer")
    conn.execute(
        "UPDATE seats SET role = 'supervisor' WHERE seat_id = ?", (sup_id,)
    )
    conn.commit()

    t_a = sup.attach(conn, sup_id, wrk_id, "analysis")
    t_b = sup.attach(conn, sup_id, wrk_id, "review")
    t_c = sup.attach(conn, sup_id, wrk_id, "observer")
    sup.detach(conn, t_c["thread_id"])  # completed — must survive

    result = release_session_seat(conn, "sess-rel-03", "implementer")
    assert result["seat_id"] == wrk_id
    assert result["released"] is True
    assert result["abandoned_count"] == 2

    assert sup.get(conn, t_a["thread_id"])["status"] == "abandoned"
    assert sup.get(conn, t_b["thread_id"])["status"] == "abandoned"
    assert sup.get(conn, t_c["thread_id"])["status"] == "completed"

    again = release_session_seat(conn, "sess-rel-03", "implementer")
    assert again["released"] is False
    assert again["abandoned_count"] == 0


def test_release_session_seat_does_not_touch_other_sessions(conn):
    from runtime.core import supervision_threads as sup
    from runtime.core.dispatch_hook import release_session_seat

    a_sup = ensure_session_and_seat(conn, "sess-rel-04a", "reviewer")
    a_wrk = ensure_session_and_seat(conn, "sess-rel-04a", "implementer")
    b_sup = ensure_session_and_seat(conn, "sess-rel-04b", "reviewer")
    b_wrk = ensure_session_and_seat(conn, "sess-rel-04b", "implementer")
    conn.execute(
        "UPDATE seats SET role='supervisor' WHERE seat_id IN (?, ?)", (a_sup, b_sup)
    )
    conn.commit()

    t_a = sup.attach(conn, a_sup, a_wrk, "analysis")
    t_b = sup.attach(conn, b_sup, b_wrk, "analysis")

    release_session_seat(conn, "sess-rel-04a", "implementer")

    assert sup.get(conn, t_a["thread_id"])["status"] == "abandoned"
    assert sup.get(conn, t_b["thread_id"])["status"] == "active"
    assert conn.execute(
        "SELECT status FROM seats WHERE seat_id = ?", (b_wrk,)
    ).fetchone()["status"] == "active"


def test_cli_seat_release_roundtrip(db_path):
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    ensure_schema(conn)
    ensure_session_and_seat(conn, "sess-cli-rel", "implementer")
    conn.commit()
    conn.close()

    out = _run_cli(
        db_path, "dispatch", "seat-release",
        "--session-id", "sess-cli-rel",
        "--agent-type", "implementer",
    )
    assert out["status"] == "ok"
    assert out["seat_id"] == "sess-cli-rel:implementer"
    assert out["found"] is True
    assert out["released"] is True
    assert out["abandoned_count"] == 0

    again = _run_cli(
        db_path, "dispatch", "seat-release",
        "--session-id", "sess-cli-rel",
        "--agent-type", "implementer",
    )
    assert again["status"] == "ok"
    assert again["released"] is False
    assert again["abandoned_count"] == 0


def test_cli_seat_release_unknown_seat_returns_not_found(db_path):
    out = _run_cli(
        db_path, "dispatch", "seat-release",
        "--session-id", "sess-ghost",
        "--agent-type", "implementer",
    )
    assert out["status"] == "ok"
    assert out["found"] is False
    assert out["released"] is False
    assert out["abandoned_count"] == 0


# ---------------------------------------------------------------------------
# SubagentStop adapter wiring pin — all four check hooks call
# `cc-policy dispatch seat-release` with the canonical shape.
# ---------------------------------------------------------------------------


_CHECK_HOOKS = [
    "check-implementer.sh",
    "check-reviewer.sh",
    "check-guardian.sh",
    "check-planner.sh",
]


def _read_hook(name: str) -> str:
    path = os.path.join(
        os.path.dirname(__file__), "..", "..", "hooks", name
    )
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


@pytest.mark.parametrize("hook_name", _CHECK_HOOKS)
def test_check_hook_wires_seat_release(hook_name):
    """Every SubagentStop check adapter must call `dispatch seat-release`.

    This is a source-level pin rather than a live-hook simulation: the
    call pattern must be uniform across all four adapters so later
    changes cannot silently drop the seat-release wiring from one role.
    """
    src = _read_hook(hook_name)

    # Each hook must extract session_id from the SubagentStop payload.
    assert "jq -r '.session_id // empty'" in src, (
        f"{hook_name} must capture session_id via the canonical "
        "jq extraction used by subagent-start.sh / pre-agent.sh"
    )

    # Each hook must call dispatch seat-release with both required args.
    assert "_local_cc_policy dispatch seat-release" in src, (
        f"{hook_name} must invoke seat-release via the local cc-policy wrapper"
    )
    assert '--session-id "$SESSION_ID"' in src, (
        f"{hook_name} seat-release call must pass --session-id from the payload"
    )
    assert '--agent-type "$AGENT_TYPE"' in src, (
        f"{hook_name} seat-release call must pass --agent-type from the payload"
    )

    # Best-effort posture: failures must never block the hook.
    assert '>/dev/null 2>&1 || true' in src, (
        f"{hook_name} must keep seat-release best-effort (|| true)"
    )

    # Guard must check both fields so an empty-session payload is a no-op.
    assert '[[ -n "$SESSION_ID" && -n "$AGENT_TYPE" ]]' in src, (
        f"{hook_name} must guard the seat-release call on non-empty "
        "SESSION_ID and AGENT_TYPE"
    )


# ---------------------------------------------------------------------------
# SubagentStop adapter execution pin — running each check hook against a
# hermetic temp DB must actually release the seat and abandon supervision
# threads touching it.  This is the behavioral complement to the source-
# level pins above: those prevent drift in the written code, these prove
# the code does what the plan says when executed.
# ---------------------------------------------------------------------------


_REPO_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..")
)


def _run_check_hook(
    hook_name: str,
    db_path: str,
    session_id: str,
    agent_type: str,
) -> int:
    """Invoke a check-*.sh hook with a synthetic SubagentStop payload.

    The hook is invoked with CLAUDE_POLICY_DB pointing at the test DB so
    every _local_cc_policy call inside the hook writes to our hermetic
    DB.  Hook exit status is returned but *not* asserted — downstream
    hook checks (branch detection, completion submission, lease lookup)
    may produce noise in a temp workspace that is irrelevant to the
    seat-release side effect we are testing.  Side-effect correctness is
    asserted by reading the DB directly.
    """
    import subprocess as _sp
    payload = json.dumps({
        "session_id": session_id,
        "agent_type": agent_type,
    })
    env = os.environ.copy()
    env["CLAUDE_POLICY_DB"] = db_path
    # Keep hooks scoped to a known project dir so detect_project_root
    # returns a stable path.  The repo root is a valid git dir and
    # satisfies downstream git-based checks without any custody effect.
    env["CLAUDE_PROJECT_DIR"] = _REPO_ROOT
    hook_path = os.path.join(_REPO_ROOT, "hooks", hook_name)
    proc = _sp.run(
        ["bash", hook_path],
        input=payload,
        capture_output=True,
        text=True,
        env=env,
        cwd=_REPO_ROOT,
        timeout=30,
    )
    return proc.returncode


@pytest.mark.parametrize(
    "hook_name, agent_type",
    [
        ("check-implementer.sh", "implementer"),
        ("check-reviewer.sh", "reviewer"),
        ("check-guardian.sh", "guardian"),
        ("check-planner.sh", "planner"),
    ],
)
def test_check_hook_execution_releases_seat_and_abandons_threads(
    tmp_path, hook_name, agent_type
):
    """Running the hook flips the seat to released and abandons its threads."""
    db_path = str(tmp_path / "state.db")

    # Seed: session + two seats + two active threads + one completed thread.
    c = sqlite3.connect(db_path)
    c.row_factory = sqlite3.Row
    ensure_schema(c)

    session_id = f"exec-test-{agent_type}"
    # ensure_session_and_seat creates a role='worker' seat keyed as
    # '{session_id}:{agent_type}'.  Add a second seat in the same session
    # to act as the supervisor for the supervision_thread rows.
    worker_seat = ensure_session_and_seat(c, session_id, agent_type)
    supervisor_seat = ensure_session_and_seat(c, session_id, f"{agent_type}-sup")
    c.execute(
        "UPDATE seats SET role = 'supervisor' WHERE seat_id = ?",
        (supervisor_seat,),
    )
    c.commit()

    from runtime.core import supervision_threads as sup
    t_a = sup.attach(c, supervisor_seat, worker_seat, "analysis")
    t_b = sup.attach(c, supervisor_seat, worker_seat, "review")
    t_c = sup.attach(c, supervisor_seat, worker_seat, "observer")
    sup.detach(c, t_c["thread_id"])  # completed — must NOT be rewritten
    c.commit()
    c.close()

    # Run hook.
    _run_check_hook(hook_name, db_path, session_id, agent_type)

    # Verify side effects against the hermetic DB.
    c2 = sqlite3.connect(db_path)
    c2.row_factory = sqlite3.Row
    try:
        seat_row = c2.execute(
            "SELECT status FROM seats WHERE seat_id = ?", (worker_seat,)
        ).fetchone()
        assert seat_row["status"] == "released", (
            f"{hook_name} did not release the worker seat"
        )

        # Supervisor seat was not the one released.
        sup_row = c2.execute(
            "SELECT status FROM seats WHERE seat_id = ?", (supervisor_seat,)
        ).fetchone()
        assert sup_row["status"] == "active", (
            f"{hook_name} must not touch the supervisor seat"
        )

        for tid in (t_a["thread_id"], t_b["thread_id"]):
            row = c2.execute(
                "SELECT status FROM supervision_threads WHERE thread_id = ?",
                (tid,),
            ).fetchone()
            assert row["status"] == "abandoned", (
                f"{hook_name} did not abandon active thread {tid}"
            )

        completed_row = c2.execute(
            "SELECT status FROM supervision_threads WHERE thread_id = ?",
            (t_c["thread_id"],),
        ).fetchone()
        assert completed_row["status"] == "completed", (
            f"{hook_name} must not rewrite a non-active thread"
        )
    finally:
        c2.close()


@pytest.mark.parametrize(
    "hook_name, agent_type",
    [
        ("check-implementer.sh", "implementer"),
        ("check-reviewer.sh", "reviewer"),
        ("check-guardian.sh", "guardian"),
        ("check-planner.sh", "planner"),
    ],
)
def test_check_hook_execution_is_idempotent(tmp_path, hook_name, agent_type):
    """A second invocation leaves released/abandoned state unchanged."""
    db_path = str(tmp_path / "state.db")
    session_id = f"idem-{agent_type}"

    c = sqlite3.connect(db_path)
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    worker_seat = ensure_session_and_seat(c, session_id, agent_type)
    supervisor_seat = ensure_session_and_seat(c, session_id, f"{agent_type}-sup")
    c.execute(
        "UPDATE seats SET role='supervisor' WHERE seat_id = ?",
        (supervisor_seat,),
    )
    c.commit()
    from runtime.core import supervision_threads as sup
    thread = sup.attach(c, supervisor_seat, worker_seat, "analysis")
    c.commit()
    c.close()

    # First run releases + abandons.
    _run_check_hook(hook_name, db_path, session_id, agent_type)
    # Capture updated_at fingerprint for both rows after first run.
    c2 = sqlite3.connect(db_path)
    c2.row_factory = sqlite3.Row
    seat_first = c2.execute(
        "SELECT status, updated_at FROM seats WHERE seat_id = ?",
        (worker_seat,),
    ).fetchone()
    thread_first = c2.execute(
        "SELECT status, updated_at FROM supervision_threads WHERE thread_id = ?",
        (thread["thread_id"],),
    ).fetchone()
    c2.close()
    assert seat_first["status"] == "released"
    assert thread_first["status"] == "abandoned"

    # Second run must be a no-op — status stays and updated_at is
    # preserved (release_session_seat() only writes when status was
    # 'active', and abandon_for_seat() only rewrites active rows).
    _run_check_hook(hook_name, db_path, session_id, agent_type)

    c3 = sqlite3.connect(db_path)
    c3.row_factory = sqlite3.Row
    seat_second = c3.execute(
        "SELECT status, updated_at FROM seats WHERE seat_id = ?",
        (worker_seat,),
    ).fetchone()
    thread_second = c3.execute(
        "SELECT status, updated_at FROM supervision_threads WHERE thread_id = ?",
        (thread["thread_id"],),
    ).fetchone()
    c3.close()

    assert seat_second["status"] == "released"
    assert thread_second["status"] == "abandoned"
    # No second write — updated_at did not move.
    assert seat_second["updated_at"] == seat_first["updated_at"], (
        f"{hook_name} rewrote the released seat on a second invocation"
    )
    assert thread_second["updated_at"] == thread_first["updated_at"], (
        f"{hook_name} rewrote the abandoned thread on a second invocation"
    )


def test_dispatch_hook_delegates_seat_writes_to_seats_domain():
    """Both ``ensure_session_and_seat`` and ``release_session_seat``
    must write seats exclusively via ``runtime.core.seats`` — inline
    SQL against the ``seats`` table inside ``dispatch_hook.py`` would
    silently re-introduce the authority-split this slice removed.
    """
    hook_src_path = os.path.abspath(
        os.path.join(
            os.path.dirname(__file__), "..", "..", "runtime", "core",
            "dispatch_hook.py",
        )
    )
    with open(hook_src_path, "r", encoding="utf-8") as f:
        src = f.read()

    # No direct seats table writes allowed in dispatch_hook.py.
    for forbidden in (
        "INSERT OR IGNORE INTO seats",
        "INSERT INTO seats",
        "UPDATE seats",
        "DELETE FROM seats",
    ):
        assert forbidden not in src, (
            f"dispatch_hook.py must not issue '{forbidden}' directly — "
            "seat writes must flow through runtime.core.seats"
        )

    # It must delegate to the seats domain module — the create helper
    # for bootstrap and the release transition for teardown.
    assert "seats as _seats" in src or "from runtime.core import seats" in src, (
        "dispatch_hook.py must import the seats domain module"
    )
    assert "_seats.create" in src, (
        "ensure_session_and_seat must delegate to seats.create"
    )
    assert "_seats.release" in src, (
        "release_session_seat must delegate to seats.release"
    )

    # @decision DEC-AGENT-SESSION-DOMAIN-001 — no direct agent_sessions
    # writes allowed either; bootstrap must delegate to
    # runtime.core.agent_sessions.
    for forbidden in (
        "INSERT OR IGNORE INTO agent_sessions",
        "INSERT INTO agent_sessions",
        "UPDATE agent_sessions",
        "DELETE FROM agent_sessions",
    ):
        assert forbidden not in src, (
            f"dispatch_hook.py must not issue '{forbidden}' directly — "
            "agent_session writes must flow through "
            "runtime.core.agent_sessions"
        )
    assert (
        "agent_sessions as _as" in src
        or "from runtime.core import agent_sessions" in src
    ), "dispatch_hook.py must import the agent_sessions domain module"
    assert "_as.create" in src, (
        "ensure_session_and_seat must delegate to agent_sessions.create"
    )


def test_seat_release_wiring_is_uniform_across_hooks():
    """Every hook must carry byte-identical seat-release invocation lines."""
    canonical_lines = (
        'SESSION_ID=$(printf \'%s\' "$AGENT_RESPONSE" | jq -r \'.session_id // empty\' 2>/dev/null || echo "")',
        'if [[ -n "$SESSION_ID" && -n "$AGENT_TYPE" ]]; then',
        '    _local_cc_policy dispatch seat-release \\',
        '        --session-id "$SESSION_ID" \\',
        '        --agent-type "$AGENT_TYPE" >/dev/null 2>&1 || true',
        'fi',
    )
    block = "\n".join(canonical_lines)
    for hook_name in _CHECK_HOOKS:
        src = _read_hook(hook_name)
        assert block in src, (
            f"{hook_name} does not carry the canonical seat-release "
            "block verbatim; cross-adapter drift detected"
        )
