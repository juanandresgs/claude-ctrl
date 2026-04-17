"""Unit tests for the runtime-owned dead-loop recovery sweeper.

@decision DEC-DEAD-RECOVERY-001
Title: sweep_dead_seats / sweep_dead_sessions pin the silent-death
  recovery path
Status: accepted
Rationale: The SubagentStop adapter chain (3967f6d) only recovers
  seats when a stop event fires.  When the event does not fire —
  silent crash, transport drop, host kill — the runtime needs its
  own deterministic sweeper.  These tests pin eligibility rules,
  grace-window behavior, idempotency, cross-session non-mutation,
  and the CLI round-trip so later changes cannot silently diverge.

The sweeper must remain delegation-only — the Rule-1 authority-writer
invariant (``tests/runtime/test_authority_table_writers.py``) enforces
that ``dead_recovery.py`` stays outside the allowlist and contains no
direct writes to the four §2a tables.
"""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import pytest

from runtime.core import agent_sessions as as_mod
from runtime.core import dead_recovery as dr_mod
from runtime.core import dispatch_attempts as da_mod
from runtime.core import seats as seat_mod
from runtime.core import supervision_threads as sup_mod
from runtime.schemas import ensure_schema


_PROJECT_ROOT = Path(__file__).resolve().parents[2]
_CLI_PATH = _PROJECT_ROOT / "runtime" / "cli.py"


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


def _make_seat(
    conn: sqlite3.Connection,
    session_id: str,
    seat_id: str,
    role: str = "worker",
) -> str:
    as_mod.create(conn, session_id, transport="claude_code")
    seat_mod.create(conn, seat_id, session_id, role)
    return seat_id


def _seed_attempt(
    conn: sqlite3.Connection,
    seat_id: str,
    status: str,
    age_seconds: int,
) -> str:
    """Issue + transition an attempt, then backdate updated_at.

    Using ``age_seconds`` lets callers express eligibility either side
    of the grace window without fighting the wall clock.
    """
    row = da_mod.issue(conn, seat_id, instruction=f"task-for-{seat_id}")
    attempt_id = row["attempt_id"]
    if status == "pending":
        # Already pending; just backdate.
        pass
    elif status == "delivered":
        da_mod.claim(conn, attempt_id)
    elif status == "acknowledged":
        da_mod.claim(conn, attempt_id)
        da_mod.acknowledge(conn, attempt_id)
    elif status == "timed_out":
        da_mod.claim(conn, attempt_id)
        da_mod.timeout(conn, attempt_id)
    elif status == "failed":
        da_mod.claim(conn, attempt_id)
        da_mod.fail(conn, attempt_id)
    elif status == "cancelled":
        da_mod.cancel(conn, attempt_id)
    else:
        raise AssertionError(f"unhandled status {status!r}")
    ts = int(time.time()) - age_seconds
    conn.execute(
        "UPDATE dispatch_attempts SET updated_at = ? WHERE attempt_id = ?",
        (ts, attempt_id),
    )
    conn.commit()
    return attempt_id


# ---------------------------------------------------------------------------
# sweep_dead_seats — eligibility and transitions
# ---------------------------------------------------------------------------


def test_seat_with_recent_timeout_is_not_swept(conn):
    """Within the grace window, a timed_out attempt's seat is preserved."""
    seat = _make_seat(conn, "sess-recent", "seat-recent")
    _seed_attempt(conn, seat, "timed_out", age_seconds=60)

    result = dr_mod.sweep_dead_seats(conn, grace_seconds=900)
    assert result["swept"] == 0
    assert result["seats"] == []
    assert seat_mod.get(conn, seat)["status"] == "active"


def test_seat_with_past_grace_timeout_is_swept(conn):
    """Past the grace window, a timed_out attempt's seat is marked dead."""
    seat = _make_seat(conn, "sess-past", "seat-past")
    _seed_attempt(conn, seat, "timed_out", age_seconds=3600)

    result = dr_mod.sweep_dead_seats(conn, grace_seconds=900)
    assert result["swept"] == 1
    assert result["seats"] == [seat]
    assert seat_mod.get(conn, seat)["status"] == "dead"


def test_seat_with_past_grace_failed_is_swept(conn):
    """Failed attempts past grace also sweep the seat dead."""
    seat = _make_seat(conn, "sess-failed", "seat-failed")
    _seed_attempt(conn, seat, "failed", age_seconds=3600)
    assert dr_mod.sweep_dead_seats(conn, grace_seconds=900)["swept"] == 1
    assert seat_mod.get(conn, seat)["status"] == "dead"


def test_seat_with_cancelled_attempt_is_not_swept(conn):
    """Cancelled is a user-driven early termination — not a silent death."""
    seat = _make_seat(conn, "sess-cancelled", "seat-cancelled")
    _seed_attempt(conn, seat, "cancelled", age_seconds=3600)

    result = dr_mod.sweep_dead_seats(conn, grace_seconds=900)
    assert result["swept"] == 0
    assert seat_mod.get(conn, seat)["status"] == "active"


def test_seat_with_live_attempt_is_not_swept(conn):
    """A live pending attempt on the seat blocks sweeping, even alongside
    a stale terminal attempt — the adapter is still working."""
    seat = _make_seat(conn, "sess-mixed", "seat-mixed")
    _seed_attempt(conn, seat, "timed_out", age_seconds=3600)
    _seed_attempt(conn, seat, "pending", age_seconds=60)

    result = dr_mod.sweep_dead_seats(conn, grace_seconds=900)
    assert result["swept"] == 0
    assert seat_mod.get(conn, seat)["status"] == "active"


def test_seat_with_newer_cancelled_after_old_timeout_is_not_swept(conn):
    """Review regression: an old timed_out attempt followed by a newer
    cancelled attempt must NOT sweep the seat — eligibility is keyed off
    the most recent attempt, and cancel is a user-driven early
    termination rather than a silent death."""
    seat = _make_seat(conn, "sess-mixed-cancel", "seat-mixed-cancel")
    _seed_attempt(conn, seat, "timed_out", age_seconds=3600)
    _seed_attempt(conn, seat, "cancelled", age_seconds=60)

    result = dr_mod.sweep_dead_seats(conn, grace_seconds=900)
    assert result["swept"] == 0
    assert result["seats"] == []
    assert seat_mod.get(conn, seat)["status"] == "active"


def test_seat_with_newer_acknowledged_after_old_timeout_is_not_swept(conn):
    """A prior timeout followed by a newer acknowledged attempt means
    the adapter recovered — sweep must not pre-empt a working seat."""
    seat = _make_seat(conn, "sess-mixed-ack", "seat-mixed-ack")
    _seed_attempt(conn, seat, "timed_out", age_seconds=3600)
    _seed_attempt(conn, seat, "acknowledged", age_seconds=60)

    assert dr_mod.sweep_dead_seats(conn, grace_seconds=900)["swept"] == 0
    assert seat_mod.get(conn, seat)["status"] == "active"


def test_seat_with_retried_attempt_timing_out_after_newer_cancel_is_swept(conn):
    """Review regression on c400245: ``dispatch_attempts.retry()`` reuses
    the same row — it updates ``updated_at`` and ``status`` but leaves
    ``created_at`` fixed.  A retried attempt therefore can have an older
    ``created_at`` than a subsequently-issued attempt yet be the most
    recent delivery activity on the seat.

    Sequence reproduced here:

      1. attempt A issued → A.created_at = T1
      2. A claimed, A times out (updated_at = T2)
      3. attempt B issued → B.created_at = T3 (T3 > T2 > T1)
      4. B cancelled (B.updated_at = T4)
      5. A retried — A.retry_count += 1, A.status = 'pending',
         A.updated_at = T5 (T5 > T4), A.created_at still T1
      6. A claimed, A times out again past grace
         (A.updated_at = T6, the newest on the seat)

    Under the earlier created_at-keyed selector this seat did NOT
    sweep, because B still had the newest created_at.  The correct
    answer is to sweep: the most recent delivery effort on the seat
    is A's second timeout.
    """
    seat = _make_seat(conn, "sess-retry-regress", "seat-retry-regress")

    # Step 1-2: A issued + timed_out; back-date so A.created_at looks
    # older than B.created_at later.
    attempt_a = _seed_attempt(conn, seat, "timed_out", age_seconds=7200)
    conn.execute(
        "UPDATE dispatch_attempts SET created_at = ? WHERE attempt_id = ?",
        (int(time.time()) - 7200, attempt_a),
    )
    conn.commit()

    # Step 3-4: B issued + cancelled, with a newer created_at than A.
    attempt_b = _seed_attempt(conn, seat, "cancelled", age_seconds=3600)
    # Assert the invariant we are about to exploit: B.created_at > A.created_at.
    ca_row = conn.execute(
        "SELECT attempt_id, created_at FROM dispatch_attempts WHERE seat_id = ?"
        " ORDER BY created_at DESC", (seat,),
    ).fetchall()
    assert ca_row[0]["attempt_id"] == attempt_b
    assert ca_row[1]["attempt_id"] == attempt_a

    # Step 5-6: retry A (pending → claimed → timed_out) past grace.
    da_mod.retry(conn, attempt_a)
    da_mod.claim(conn, attempt_a)
    da_mod.timeout(conn, attempt_a)
    # Back-date A's updated_at so it is BOTH past grace AND newer than
    # B.updated_at.  Cancel happened at (now - 3600); the retried
    # timeout happened logically after that, so place it at (now -
    # 1800) — newer than B but still past a 900-second grace.
    conn.execute(
        "UPDATE dispatch_attempts SET updated_at = ? WHERE attempt_id = ?",
        (int(time.time()) - 1800, attempt_a),
    )
    conn.commit()

    # Pre-condition checks — make the invariants the selector must key
    # off visible in the test log if it ever flakes.
    ua_row = conn.execute(
        "SELECT attempt_id, updated_at FROM dispatch_attempts WHERE seat_id = ?"
        " ORDER BY updated_at DESC", (seat,),
    ).fetchall()
    assert ua_row[0]["attempt_id"] == attempt_a  # newest updated_at is A
    assert ua_row[1]["attempt_id"] == attempt_b

    result = dr_mod.sweep_dead_seats(conn, grace_seconds=900)
    assert result["swept"] == 1
    assert result["seats"] == [seat]
    assert seat_mod.get(conn, seat)["status"] == "dead"


def test_seat_with_newer_timed_out_after_old_pending_is_swept(conn):
    """Complement to the cancelled case: an older *live* pending
    attempt followed by a newer past-grace timed_out attempt still
    sweeps the seat.  Eligibility tracks the latest attempt only;
    the older pending row must not shield the seat from sweeping
    when the adapter has since died.

    This test relies on test seeding to produce the ordering: the
    helper issues a fresh attempt each call, so the second call is
    genuinely newer by created_at / attempt_id.  The first attempt's
    pending row is back-dated but remains 'pending' in the table —
    the selector must correctly treat the second row (timed_out) as
    the one that determines eligibility."""
    seat = _make_seat(conn, "sess-pending-then-timeout", "seat-ptt")
    _seed_attempt(conn, seat, "pending", age_seconds=7200)   # older
    _seed_attempt(conn, seat, "timed_out", age_seconds=3600) # newer

    result = dr_mod.sweep_dead_seats(conn, grace_seconds=900)
    assert result["swept"] == 1
    assert result["seats"] == [seat]
    assert seat_mod.get(conn, seat)["status"] == "dead"


def test_released_seat_is_not_re_swept(conn):
    """Already-released seats must not be touched by the sweeper."""
    seat = _make_seat(conn, "sess-rel", "seat-rel")
    _seed_attempt(conn, seat, "timed_out", age_seconds=3600)
    seat_mod.release(conn, seat)

    result = dr_mod.sweep_dead_seats(conn, grace_seconds=900)
    assert result["swept"] == 0
    assert seat_mod.get(conn, seat)["status"] == "released"


def test_dead_seat_is_idempotent(conn):
    """Running the sweep twice returns swept=0 on the second call."""
    seat = _make_seat(conn, "sess-idem", "seat-idem")
    _seed_attempt(conn, seat, "timed_out", age_seconds=3600)

    assert dr_mod.sweep_dead_seats(conn, grace_seconds=900)["swept"] == 1
    second = dr_mod.sweep_dead_seats(conn, grace_seconds=900)
    assert second["swept"] == 0
    assert second["seats"] == []


def test_sweep_cascades_abandons_supervision_threads(conn):
    """A swept seat's active supervision_threads transition to abandoned."""
    sup_id = _make_seat(conn, "sess-sup", "seat-sup-sup", role="supervisor")
    wrk_id = _make_seat(conn, "sess-sup", "seat-sup-wrk", role="worker")
    _seed_attempt(conn, wrk_id, "timed_out", age_seconds=3600)

    t_a = sup_mod.attach(conn, sup_id, wrk_id, "analysis")
    t_b = sup_mod.attach(conn, sup_id, wrk_id, "review")
    t_c = sup_mod.attach(conn, sup_id, wrk_id, "observer")
    sup_mod.detach(conn, t_c["thread_id"])  # completed — preserved

    result = dr_mod.sweep_dead_seats(conn, grace_seconds=900)
    assert result["swept"] == 1
    assert result["abandoned_threads"] == 2
    assert sup_mod.get(conn, t_a["thread_id"])["status"] == "abandoned"
    assert sup_mod.get(conn, t_b["thread_id"])["status"] == "abandoned"
    assert sup_mod.get(conn, t_c["thread_id"])["status"] == "completed"


def test_sweep_does_not_touch_other_sessions(conn):
    """A stale seat in session A must not affect an active seat in B."""
    a = _make_seat(conn, "sess-A", "seat-A")
    b = _make_seat(conn, "sess-B", "seat-B")
    _seed_attempt(conn, a, "timed_out", age_seconds=3600)
    _seed_attempt(conn, b, "pending", age_seconds=60)

    dr_mod.sweep_dead_seats(conn, grace_seconds=900)
    assert seat_mod.get(conn, a)["status"] == "dead"
    assert seat_mod.get(conn, b)["status"] == "active"


def test_sweep_rejects_negative_grace(conn):
    with pytest.raises(ValueError, match="grace_seconds"):
        dr_mod.sweep_dead_seats(conn, grace_seconds=-1)


def test_sweep_honors_injected_now(conn):
    """Injected ``now`` lets tests pin the cutoff deterministically."""
    seat = _make_seat(conn, "sess-now", "seat-now")
    attempt_id = _seed_attempt(conn, seat, "timed_out", age_seconds=0)
    # updated_at is approximately time.time() now; choose now+1000 so
    # cutoff = 1000-900 = 100 seconds ago, and the attempt updated_at
    # (~real now) is WELL past cutoff — eligible.
    injected = int(time.time()) + 1000
    assert dr_mod.sweep_dead_seats(
        conn, grace_seconds=900, now=injected
    )["swept"] == 1
    assert seat_mod.get(conn, seat)["status"] == "dead"
    assert attempt_id  # quiet unused warning


# ---------------------------------------------------------------------------
# sweep_dead_sessions — terminal-transition selection
# ---------------------------------------------------------------------------


def test_session_with_all_released_seats_transitions_to_completed(conn):
    _make_seat(conn, "sess-comp", "seat-comp-1")
    _make_seat(conn, "sess-comp", "seat-comp-2")
    seat_mod.release(conn, "seat-comp-1")
    seat_mod.release(conn, "seat-comp-2")

    result = dr_mod.sweep_dead_sessions(conn)
    assert result["swept"] == 1
    assert result["completed"] == ["sess-comp"]
    assert result["dead"] == []
    assert as_mod.get(conn, "sess-comp")["status"] == "completed"


def test_session_with_any_dead_seat_transitions_to_dead(conn):
    _make_seat(conn, "sess-dead", "seat-dead-1")
    _make_seat(conn, "sess-dead", "seat-dead-2")
    seat_mod.release(conn, "seat-dead-1")
    seat_mod.mark_dead(conn, "seat-dead-2")

    result = dr_mod.sweep_dead_sessions(conn)
    assert result["swept"] == 1
    assert result["dead"] == ["sess-dead"]
    assert result["completed"] == []
    assert as_mod.get(conn, "sess-dead")["status"] == "dead"


def test_session_with_active_seat_is_not_swept(conn):
    _make_seat(conn, "sess-live", "seat-live-1")
    _make_seat(conn, "sess-live", "seat-live-2")
    seat_mod.release(conn, "seat-live-1")
    # seat-live-2 stays active — session must not transition.

    result = dr_mod.sweep_dead_sessions(conn)
    assert result["swept"] == 0
    assert as_mod.get(conn, "sess-live")["status"] == "active"


def test_session_with_no_seats_is_not_swept(conn):
    """A fresh session with no seats yet is not a recovery candidate."""
    as_mod.create(conn, "sess-bare", transport="claude_code")
    result = dr_mod.sweep_dead_sessions(conn)
    assert result["swept"] == 0
    assert as_mod.get(conn, "sess-bare")["status"] == "active"


def test_session_sweep_is_idempotent(conn):
    _make_seat(conn, "sess-idem", "seat-idem")
    seat_mod.release(conn, "seat-idem")

    first = dr_mod.sweep_dead_sessions(conn)
    assert first["swept"] == 1
    second = dr_mod.sweep_dead_sessions(conn)
    assert second["swept"] == 0


# ---------------------------------------------------------------------------
# sweep_all — end-to-end compose
# ---------------------------------------------------------------------------


def test_sweep_all_marks_seat_dead_then_session_dead(conn):
    """sweep_all runs seat sweep first so session sweep sees the dead seat."""
    seat = _make_seat(conn, "sess-all", "seat-all")
    _seed_attempt(conn, seat, "timed_out", age_seconds=3600)

    result = dr_mod.sweep_all(conn, grace_seconds=900)
    assert result["seats"]["swept"] == 1
    assert result["sessions"]["swept"] == 1
    assert result["sessions"]["dead"] == ["sess-all"]
    assert seat_mod.get(conn, seat)["status"] == "dead"
    assert as_mod.get(conn, "sess-all")["status"] == "dead"


# ---------------------------------------------------------------------------
# Delegation invariant — the sweeper must not hold direct SQL writes.
# The authority-writer test provides the mechanical pin; this is a
# lightweight per-module affirmation documenting expectation.
# ---------------------------------------------------------------------------


def test_dead_recovery_source_contains_no_direct_authority_writes():
    import runtime.core.dead_recovery as mod
    src = Path(mod.__file__).read_text()
    for forbidden in (
        "INSERT INTO seats",
        "INSERT INTO agent_sessions",
        "INSERT INTO supervision_threads",
        "INSERT OR IGNORE INTO seats",
        "INSERT OR IGNORE INTO agent_sessions",
        "UPDATE seats",
        "UPDATE agent_sessions",
        "UPDATE supervision_threads",
        "DELETE FROM seats",
        "DELETE FROM agent_sessions",
        "DELETE FROM supervision_threads",
    ):
        assert forbidden not in src, (
            f"dead_recovery.py must delegate via domain modules; found "
            f"direct write pattern: {forbidden!r}"
        )


# ---------------------------------------------------------------------------
# CLI round-trip
# ---------------------------------------------------------------------------


def _run_cli(tmp_db: Path, *cli_args: str) -> dict:
    env = os.environ.copy()
    env["CLAUDE_POLICY_DB"] = str(tmp_db)
    proc = subprocess.run(
        [sys.executable, str(_CLI_PATH), *cli_args],
        cwd=str(_PROJECT_ROOT),
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0, (
        f"cc-policy {' '.join(cli_args)} failed: "
        f"stdout={proc.stdout!r} stderr={proc.stderr!r}"
    )
    return json.loads(proc.stdout)


def test_cli_sweep_dead_help(tmp_path):
    env = os.environ.copy()
    env["CLAUDE_POLICY_DB"] = str(tmp_path / "cli.sqlite3")
    proc = subprocess.run(
        [sys.executable, str(_CLI_PATH), "dispatch", "sweep-dead", "--help"],
        cwd=str(_PROJECT_ROOT),
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0
    assert "--grace-seconds" in proc.stdout


def test_cli_sweep_dead_roundtrip(tmp_path):
    tmp_db = tmp_path / "cli.sqlite3"
    c = sqlite3.connect(str(tmp_db))
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    _make_seat(c, "cli-sess", "cli-seat")
    _seed_attempt(c, "cli-seat", "timed_out", age_seconds=3600)
    c.commit()
    c.close()

    out = _run_cli(
        tmp_db, "dispatch", "sweep-dead", "--grace-seconds", "900"
    )
    assert out["status"] == "ok"
    assert out["seats"]["swept"] == 1
    assert out["seats"]["seats"] == ["cli-seat"]
    assert out["sessions"]["swept"] == 1
    assert out["sessions"]["dead"] == ["cli-sess"]

    # Second invocation is a total no-op.
    out2 = _run_cli(
        tmp_db, "dispatch", "sweep-dead", "--grace-seconds", "900"
    )
    assert out2["seats"]["swept"] == 0
    assert out2["sessions"]["swept"] == 0
