"""Unit tests for runtime.core.statusline.snapshot().

Tests the read-only projection directly using an in-memory SQLite database.
No subprocess overhead — exercises the snapshot() function at the Python level
to validate field completeness, correct defaults, and state reflection.

Production sequence: hooks call cc-policy statusline snapshot (CLI entry point)
-> _handle_statusline() -> statusline_mod.snapshot(conn). These unit tests
exercise snapshot() directly with a live conn so every internal query path
is covered without subprocess overhead. The compound-interaction test
(test_snapshot_full_production_sequence) validates the CLI path end-to-end.

W-CONV-4: proof_status and proof_workflow were removed from the snapshot dict.
proof_state table is retained for storage; the display surface now shows only
evaluation_state fields (eval_status, eval_workflow, eval_head_sha).

@decision DEC-RT-011
Title: Statusline snapshot is a read-only projection across all runtime tables
Status: accepted
Rationale: snapshot() reads evaluation_state (sole readiness authority),
  agent_markers, worktrees, dispatch_cycles, completion_records, and events in
  a single pass. It never writes. The extended field set (active_agent_id,
  worktrees list, dispatch_cycle_id, recent_events list) was added in TKT-011
  so scripts/statusline.sh has everything it needs for a richer HUD without
  calling multiple CLI subcommands. proof_state was removed from the snapshot
  in W-CONV-4 (DEC-EVAL-006) — operators saw contradictory readiness signals.
  All fields have safe None/0 defaults so the statusline never crashes on an
  empty or partially-populated DB.

@decision DEC-WS6-001
Title: dispatch_status derived from completion records, not dispatch_queue
Status: accepted
Rationale: WS6 removes dispatch_queue from the routing hot-path. dispatch_status
  is now derived from determine_next_role(latest_completion.role, verdict).
  The queue table remains for backward compat but is not the routing authority.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import runtime.core.completions as completions_mod
import runtime.core.dispatch as dispatch_mod
import runtime.core.events as events_mod
import runtime.core.markers as markers_mod
import runtime.core.proof as proof_mod  # retained: storage still used in compound test
import runtime.core.statusline as statusline
import runtime.core.worktrees as worktrees_mod
from runtime.core.db import connect_memory
from runtime.schemas import ensure_schema

# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


# ---------------------------------------------------------------------------
# Key presence — all expected fields must be present in every snapshot
# ---------------------------------------------------------------------------

# W-CONV-4: proof_status and proof_workflow removed from snapshot display.
# evaluation_state fields (eval_status, eval_workflow, eval_head_sha) are the
# sole readiness surface. FORBIDDEN fields must not appear (enforced in
# test_statusline_truth.py::TestProofStateRemovedFromDisplay).
# DEC-SL-160: last_review and errors are new fields added by W-SL-160.
REQUIRED_KEYS = {
    "eval_status",
    "eval_workflow",
    "eval_head_sha",
    "active_agent",
    "active_agent_id",
    "marker_age_seconds",
    "worktree_count",
    "worktrees",
    "dispatch_status",
    "dispatch_workflow",
    "dispatch_from_role",
    "dispatch_from_verdict",
    "dispatch_initiative",
    "dispatch_cycle_id",
    "recent_event_count",
    "recent_events",
    "last_review",
    "snapshot_at",
    "status",
    "errors",
}


def test_snapshot_has_all_required_keys(conn):
    """Every snapshot must contain exactly the canonical field set."""
    snap = statusline.snapshot(conn)
    missing = REQUIRED_KEYS - set(snap.keys())
    assert not missing, f"snapshot() missing fields: {missing}"


def test_snapshot_empty_db_safe_defaults(conn):
    """Empty DB returns safe defaults — no crash, no None where type matters."""
    snap = statusline.snapshot(conn)
    # W-CONV-4: proof fields must not appear at all
    assert "proof_status" not in snap
    assert "proof_workflow" not in snap
    # evaluation_state fields default to idle/None
    assert snap["eval_status"] == "idle"
    assert snap["eval_workflow"] is None
    assert snap["eval_head_sha"] is None
    assert snap["active_agent"] is None
    assert snap["active_agent_id"] is None
    assert snap["worktree_count"] == 0
    assert snap["worktrees"] == []
    assert snap["dispatch_status"] is None
    assert snap["dispatch_initiative"] is None
    assert snap["dispatch_cycle_id"] is None
    assert snap["recent_event_count"] == 0
    assert snap["recent_events"] == []
    # DEC-SL-160: last_review defaults to unreviewed
    assert snap["last_review"]["reviewed"] is False
    assert snap["last_review"]["reviewer"] is None
    assert snap["last_review"]["verdict"] is None
    assert snap["last_review"]["reviewed_at"] is None
    # DEC-SL-160: errors list is empty on clean DB
    assert snap["errors"] == []
    assert isinstance(snap["snapshot_at"], int)
    assert snap["snapshot_at"] > 0
    assert snap["status"] == "ok"


# ---------------------------------------------------------------------------
# Active agent reflection
# ---------------------------------------------------------------------------


def test_snapshot_reflects_active_agent(conn):
    """Snapshot surfaces active marker role and agent_id."""
    markers_mod.set_active(conn, "agent-007", "implementer")
    snap = statusline.snapshot(conn)
    assert snap["active_agent"] == "implementer"
    assert snap["active_agent_id"] == "agent-007"


def test_snapshot_no_active_agent_after_deactivate(conn):
    """After deactivate(), active_agent fields go None."""
    markers_mod.set_active(conn, "agent-007", "tester")
    markers_mod.deactivate(conn, "agent-007")
    snap = statusline.snapshot(conn)
    assert snap["active_agent"] is None
    assert snap["active_agent_id"] is None


# ---------------------------------------------------------------------------
# Worktree reflection
# ---------------------------------------------------------------------------


def test_snapshot_includes_worktree_details(conn):
    """Snapshot includes worktree list with path, branch, ticket fields."""
    worktrees_mod.register(conn, "/wt/feat-a", "feature/a", ticket="TKT-001")
    worktrees_mod.register(conn, "/wt/feat-b", "feature/b")
    snap = statusline.snapshot(conn)
    assert snap["worktree_count"] == 2
    assert len(snap["worktrees"]) == 2
    paths = {w["path"] for w in snap["worktrees"]}
    assert paths == {"/wt/feat-a", "/wt/feat-b"}
    # ticket present where registered
    a = next(w for w in snap["worktrees"] if w["path"] == "/wt/feat-a")
    assert a["ticket"] == "TKT-001"
    b = next(w for w in snap["worktrees"] if w["path"] == "/wt/feat-b")
    assert b["ticket"] is None


def test_snapshot_removed_worktrees_excluded(conn):
    """Soft-deleted worktrees do not appear in the snapshot."""
    worktrees_mod.register(conn, "/wt/gone", "feature/gone")
    worktrees_mod.remove(conn, "/wt/gone")
    snap = statusline.snapshot(conn)
    assert snap["worktree_count"] == 0
    assert snap["worktrees"] == []


def test_snapshot_worktree_fields_have_correct_keys(conn):
    """Each worktree entry must contain path, branch, ticket."""
    worktrees_mod.register(conn, "/wt/check", "main")
    snap = statusline.snapshot(conn)
    wt = snap["worktrees"][0]
    assert "path" in wt
    assert "branch" in wt
    assert "ticket" in wt


# ---------------------------------------------------------------------------
# Dispatch cycle reflection
# ---------------------------------------------------------------------------


def test_snapshot_reflects_active_dispatch_cycle(conn):
    """Snapshot surfaces dispatch_initiative, dispatch_cycle_id for active cycle."""
    cid = dispatch_mod.start_cycle(conn, "INIT-002")
    snap = statusline.snapshot(conn)
    assert snap["dispatch_initiative"] == "INIT-002"
    assert snap["dispatch_cycle_id"] == cid


def test_snapshot_dispatch_status_from_completion_tester_ready(conn):
    """dispatch_status is derived from completion records, not dispatch_queue.

    DEC-WS6-001: A tester completion with verdict 'ready_for_guardian' must
    produce dispatch_status == 'guardian'. The queue is not consulted.
    """
    completions_mod.submit(
        conn,
        lease_id="lease-001",
        workflow_id="wf-ws6",
        role="tester",
        payload={
            "EVAL_VERDICT": "ready_for_guardian",
            "EVAL_TESTS_PASS": "yes",
            "EVAL_NEXT_ROLE": "guardian",
            "EVAL_HEAD_SHA": "abc123",
        },
    )
    snap = statusline.snapshot(conn)
    assert snap["dispatch_status"] == "guardian"
    assert snap["dispatch_workflow"] == "wf-ws6"
    assert snap["dispatch_from_role"] == "tester"
    assert snap["dispatch_from_verdict"] == "ready_for_guardian"


def test_snapshot_dispatch_status_from_completion_tester_needs_changes(conn):
    """Tester completion with 'needs_changes' routes back to implementer."""
    completions_mod.submit(
        conn,
        lease_id="lease-002",
        workflow_id="wf-ws6b",
        role="tester",
        payload={
            "EVAL_VERDICT": "needs_changes",
            "EVAL_TESTS_PASS": "no",
            "EVAL_NEXT_ROLE": "implementer",
            "EVAL_HEAD_SHA": "def456",
        },
    )
    snap = statusline.snapshot(conn)
    assert snap["dispatch_status"] == "implementer"
    assert snap["dispatch_from_role"] == "tester"
    assert snap["dispatch_from_verdict"] == "needs_changes"


def test_snapshot_dispatch_status_none_when_no_completion(conn):
    """No completion records => dispatch_status is None.

    DEC-WS6-001: queue-based lookup is gone. Without a completion record,
    all dispatch fields are None regardless of queue contents.
    """
    # Enqueue an item — must NOT influence dispatch_status
    dispatch_mod.enqueue(conn, "implementer", ticket="TKT-011")
    snap = statusline.snapshot(conn)
    assert snap["dispatch_status"] is None
    assert snap["dispatch_workflow"] is None
    assert snap["dispatch_from_role"] is None
    assert snap["dispatch_from_verdict"] is None
    assert snap["dispatch_initiative"] is None
    assert snap["dispatch_cycle_id"] is None


def test_snapshot_dispatch_status_invalid_completion_is_none(conn):
    """An invalid (failed validation) completion record yields dispatch_status None.

    Only valid completion records with a recognised routing path produce a
    next_role. Invalid records are not authoritative for routing.
    """
    # Submit an invalid tester completion (missing required fields).
    # submit() still inserts the record but valid=False.
    completions_mod.submit(
        conn,
        lease_id="lease-bad",
        workflow_id="wf-bad",
        role="tester",
        payload={
            "EVAL_VERDICT": "ready_for_guardian",
            # missing EVAL_TESTS_PASS, EVAL_NEXT_ROLE, EVAL_HEAD_SHA
        },
    )
    snap = statusline.snapshot(conn)
    assert snap["dispatch_status"] is None


# ---------------------------------------------------------------------------
# Recent events reflection
# ---------------------------------------------------------------------------


def test_snapshot_recent_events_populated(conn):
    """snapshot() includes up to 5 most recent events with required fields."""
    events_mod.emit(conn, "tkt.start", detail="began TKT-011")
    events_mod.emit(conn, "tkt.test", detail="tests running")
    snap = statusline.snapshot(conn)
    assert snap["recent_event_count"] == 2
    assert len(snap["recent_events"]) == 2
    # Newest first
    assert snap["recent_events"][0]["type"] == "tkt.test"
    assert snap["recent_events"][1]["type"] == "tkt.start"


def test_snapshot_recent_events_capped_at_five(conn):
    """recent_events list is capped at 5 even when more events exist."""
    for i in range(10):
        events_mod.emit(conn, f"evt.{i}")
    snap = statusline.snapshot(conn)
    assert len(snap["recent_events"]) == 5


def test_snapshot_recent_event_has_required_fields(conn):
    """Each recent_events entry must contain type, detail, created_at."""
    events_mod.emit(conn, "probe.event", detail="check fields")
    snap = statusline.snapshot(conn)
    evt = snap["recent_events"][0]
    assert "type" in evt
    assert "detail" in evt
    assert "created_at" in evt


# ---------------------------------------------------------------------------
# Snapshot timestamp
# ---------------------------------------------------------------------------


def test_snapshot_at_is_current_epoch(conn):
    """snapshot_at must be within 5 seconds of now."""
    before = int(time.time())
    snap = statusline.snapshot(conn)
    after = int(time.time())
    assert before <= snap["snapshot_at"] <= after + 1


# ---------------------------------------------------------------------------
# Compound interaction: full production state scenario
# ---------------------------------------------------------------------------


def test_snapshot_full_production_sequence(conn):
    """Exercises the complete production state sequence through snapshot().

    Production path (DEC-WS6-001 / W-CONV-4): tester submits a valid completion
    with ready_for_guardian -> implementer marker is set -> worktree registered
    -> dispatch cycle active -> proof written to storage (not displayed) ->
    events emitted.  snapshot() must reflect all of these in a single call.
    dispatch_status must be derived from the completion record (not the queue).
    proof_state must NOT appear in the snapshot (W-CONV-4).

    This is the compound-interaction test: completions.py, markers.py,
    worktrees.py, dispatch.py, proof.py (storage only), events.py, and
    statusline.py all collaborate — snapshot() synthesizes them into one
    coherent projection with proof display removed.
    """
    # 1. Start a dispatch cycle
    cid = dispatch_mod.start_cycle(conn, "INIT-002")

    # 2. Submit a valid tester completion — this is now the routing authority
    #    (DEC-WS6-001). The queue is NOT enqueued; dispatch_status is derived
    #    from this record via determine_next_role("tester", "ready_for_guardian")
    #    => "guardian".
    completions_mod.submit(
        conn,
        lease_id="lease-tkt011",
        workflow_id="TKT-011",
        role="tester",
        payload={
            "EVAL_VERDICT": "ready_for_guardian",
            "EVAL_TESTS_PASS": "yes",
            "EVAL_NEXT_ROLE": "guardian",
            "EVAL_HEAD_SHA": "abc123",
        },
    )

    # 3. Set active agent marker
    markers_mod.set_active(conn, "agent-tkt011", "implementer")

    # 4. Register a worktree
    worktrees_mod.register(conn, "/wt/tkt-011", "feature/tkt-011", ticket="TKT-011")

    # 5. Write proof to storage — must NOT appear in snapshot (W-CONV-4)
    proof_mod.set_status(conn, "TKT-011", "pending")

    # 6. Emit a couple events
    events_mod.emit(conn, "worktree.registered", detail="/wt/tkt-011")
    events_mod.emit(conn, "proof.set", detail="pending")

    # Now take a snapshot and verify every domain is reflected
    snap = statusline.snapshot(conn)

    assert snap["status"] == "ok"
    # W-CONV-4: proof fields must not appear even with live proof_state data
    assert "proof_status" not in snap
    assert "proof_workflow" not in snap
    assert snap["active_agent"] == "implementer"
    assert snap["active_agent_id"] == "agent-tkt011"
    assert snap["worktree_count"] == 1
    assert snap["worktrees"][0]["path"] == "/wt/tkt-011"
    assert snap["worktrees"][0]["ticket"] == "TKT-011"
    # dispatch_status comes from completion record, not queue (DEC-WS6-001)
    assert snap["dispatch_status"] == "guardian"
    assert snap["dispatch_workflow"] == "TKT-011"
    assert snap["dispatch_from_role"] == "tester"
    assert snap["dispatch_from_verdict"] == "ready_for_guardian"
    assert snap["dispatch_initiative"] == "INIT-002"
    assert snap["dispatch_cycle_id"] == cid
    assert snap["recent_event_count"] == 2
    assert len(snap["recent_events"]) == 2
    assert snap["recent_events"][0]["type"] == "proof.set"
    # DEC-SL-160: errors list is empty when all sections succeed
    assert snap["errors"] == []
    assert snap["status"] == "ok"


# ---------------------------------------------------------------------------
# Partial failure reporting (DEC-SL-160 / W-SL-160)
# ---------------------------------------------------------------------------


class TestPartialFailureReporting:
    """Per-section isolation: a failing section sets partial_failure without
    suppressing data from sections that succeeded (DEC-SL-160).

    These tests induce genuine SQLite OperationalErrors by dropping specific
    tables from the schema after ensure_schema runs. This exercises the real
    exception path without mocking internal C-extension methods (which are
    read-only in CPython ≥3.14).
    """

    @pytest.fixture
    def conn_no_worktrees(self):
        """In-memory DB with full schema except the worktrees table dropped."""
        c = connect_memory()
        ensure_schema(c)
        c.execute("DROP TABLE worktrees")
        c.commit()
        yield c
        c.close()

    def test_partial_failure_sets_status(self, conn_no_worktrees):
        """A missing worktrees table triggers partial_failure status."""
        snap = statusline.snapshot(conn_no_worktrees)
        assert snap["status"] == "partial_failure"

    def test_partial_failure_accumulates_error_entry(self, conn_no_worktrees):
        """errors[] has one entry with section='worktrees' when table missing."""
        snap = statusline.snapshot(conn_no_worktrees)
        assert len(snap["errors"]) >= 1
        sections = [e["section"] for e in snap["errors"]]
        assert "worktrees" in sections
        # The error string must contain sqlite diagnostic text.
        err = next(e for e in snap["errors"] if e["section"] == "worktrees")
        assert err["error"]  # non-empty

    def test_partial_failure_other_sections_still_populated(self):
        """When worktrees table is missing, eval and markers still populate.

        eval section runs before worktrees in snapshot(), so its data must
        survive the worktrees fault.
        """
        import runtime.core.evaluation as eval_mod

        c = connect_memory()
        ensure_schema(c)

        # Populate eval and markers before dropping worktrees.
        eval_mod.set_status(c, "wf-partial", "pending")
        markers_mod.set_active(c, "agent-partial", "tester")

        c.execute("DROP TABLE worktrees")
        c.commit()

        snap = statusline.snapshot(c)
        c.close()

        # Sections before the fault must still be present.
        assert snap["eval_status"] == "pending"
        assert snap["active_agent"] == "tester"
        # Worktrees section failed — count stays at safe default.
        assert snap["worktree_count"] == 0

    def test_no_errors_on_clean_db(self, conn):
        """Clean DB with no faults must return errors=[] and status='ok'."""
        snap = statusline.snapshot(conn)
        assert snap["errors"] == []
        assert snap["status"] == "ok"


# ---------------------------------------------------------------------------
# Last review indicator (DEC-SL-160 / W-SL-160)
# ---------------------------------------------------------------------------


class TestLastReview:
    """last_review field reflects the most recent codex_stop_review event
    scoped to the current eval cycle. The review indicator resets when a new
    eval step starts (DEC-SL-160).
    """

    def test_last_review_default_unreviewed(self, conn):
        """Empty DB: last_review.reviewed is False."""
        snap = statusline.snapshot(conn)
        assert snap["last_review"]["reviewed"] is False
        assert snap["last_review"]["reviewer"] is None
        assert snap["last_review"]["verdict"] is None
        assert snap["last_review"]["reviewed_at"] is None

    def test_last_review_allow_verdict(self, conn):
        """ALLOW verdict maps to reviewed=True, verdict='ALLOW'."""
        events_mod.emit(
            conn,
            "codex_stop_review",
            detail="VERDICT: ALLOW — workflow=wf-test | work looks good",
        )
        snap = statusline.snapshot(conn)
        assert snap["last_review"]["reviewed"] is True
        assert snap["last_review"]["verdict"] == "ALLOW"
        assert snap["last_review"]["reviewer"] == "codex"
        assert isinstance(snap["last_review"]["reviewed_at"], int)

    def test_last_review_block_verdict(self, conn):
        """BLOCK verdict maps to reviewed=True, verdict='BLOCK'."""
        events_mod.emit(
            conn,
            "codex_stop_review",
            detail="VERDICT: BLOCK — workflow=wf-test | missing tests",
        )
        snap = statusline.snapshot(conn)
        assert snap["last_review"]["reviewed"] is True
        assert snap["last_review"]["verdict"] == "BLOCK"

    def test_last_review_newest_wins(self, conn):
        """When multiple codex_stop_review events exist, newest wins."""
        events_mod.emit(conn, "codex_stop_review", detail="VERDICT: BLOCK — workflow=wf-1 | first")
        events_mod.emit(conn, "codex_stop_review", detail="VERDICT: ALLOW — workflow=wf-2 | second")
        snap = statusline.snapshot(conn)
        assert snap["last_review"]["verdict"] == "ALLOW"

    def test_last_review_resets_after_new_eval_step(self, conn):
        """Review event before eval reset does not carry into the new step.

        Production sequence (DEC-SL-160): a codex_stop_review event is
        emitted at T=100. Then a new evaluation_state row is written at T=200
        (new step starts). A snapshot at T=300 must show reviewed=False because
        no review event postdates the eval reset at T=200.
        """
        import time as time_mod

        # Insert an old review event (T-10)
        old_ts = int(time_mod.time()) - 10
        conn.execute(
            "INSERT INTO events (type, detail, created_at) VALUES (?, ?, ?)",
            ("codex_stop_review", "VERDICT: ALLOW — workflow=old | stale review", old_ts),
        )
        conn.commit()

        # Now set evaluation_state updated_at to now (new step, T=now)
        import runtime.core.evaluation as eval_mod

        eval_mod.set_status(conn, "wf-new-step", "pending")

        snap = statusline.snapshot(conn)
        # The review event predates the new eval step, so reviewed must be False.
        # (The eval update sets updated_at to now, which is after old_ts-10.)
        assert snap["last_review"]["reviewed"] is False

    def test_last_review_present_when_review_after_eval(self, conn):
        """Review event after eval start is correctly surfaced.

        Compound-interaction test (DEC-SL-160): evaluation_state is written
        first, then a codex_stop_review event is emitted. snapshot() must
        reflect reviewed=True because the event postdates the eval row.
        """
        import runtime.core.evaluation as eval_mod

        # Set eval state (this sets updated_at to approx now)
        eval_mod.set_status(conn, "wf-reviewed", "pending")

        # Emit review event after eval state is set (same second is fine —
        # the DB query uses >= so equal timestamps qualify).
        events_mod.emit(
            conn,
            "codex_stop_review",
            detail="VERDICT: ALLOW — workflow=wf-reviewed | all good",
        )

        snap = statusline.snapshot(conn)
        assert snap["last_review"]["reviewed"] is True
        assert snap["last_review"]["verdict"] == "ALLOW"
