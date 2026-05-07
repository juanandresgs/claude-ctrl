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
The proof_state table itself was retired under DEC-CATEGORY-C-PROOF-RETIRE-001;
the display surface now shows only evaluation_state fields (eval_status,
eval_workflow, eval_head_sha).

@decision DEC-RT-011
Title: Statusline snapshot is a read-only projection across all runtime tables
Status: accepted
Rationale: snapshot() reads evaluation_state (sole readiness authority),
  agent_markers, worktrees, completion_records, and events in
  a single pass. It never writes. The extended field set (active_agent_id,
  worktrees list, dispatch_cycle_id, recent_events list) was added in TKT-011
  so scripts/statusline.sh has everything it needs for a richer HUD without
  calling multiple CLI subcommands. proof_state fields were removed from the
  snapshot in W-CONV-4 (DEC-EVAL-006) and the proof_state storage was retired
  under DEC-CATEGORY-C-PROOF-RETIRE-001.
  All fields have safe None/0 defaults so the statusline never crashes on an
  empty or partially-populated DB.

@decision DEC-WS6-001
Title: dispatch_status derived from completion records, not dispatch_queue
Status: accepted
Rationale: WS6 removed dispatch_queue from the routing hot-path. dispatch_status
  is derived from determine_next_role(latest_completion.role, verdict).
  The dispatch_queue / dispatch_cycles tables were subsequently retired under
  DEC-CATEGORY-C-DISPATCH-RETIRE-001.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import runtime.core.completions as completions_mod
import runtime.core.critic_runs as critic_runs_mod
import runtime.core.events as events_mod
import runtime.core.markers as markers_mod
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
    "critic_run",
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
    assert snap["critic_run"]["found"] is False
    assert snap["critic_run"]["active"] is False
    assert snap["critic_run"]["status"] is None
    assert snap["critic_run"]["verdict"] is None
    assert snap["critic_run"]["progress_preview"] == []
    # DEC-SL-160: errors list is empty on clean DB
    assert snap["errors"] == []
    assert isinstance(snap["snapshot_at"], int)
    assert snap["snapshot_at"] > 0
    assert snap["status"] == "ok"


def test_snapshot_reflects_active_critic_run(conn):
    """Latest critic run appears as a compact statusline heartbeat source."""
    run = critic_runs_mod.start(
        conn,
        workflow_id="wf-status-critic",
        provider="codex",
    )
    critic_runs_mod.progress(
        conn,
        run_id=run["run_id"],
        message="Provider status: codex ready.",
        phase="provider",
        status="provider_ready",
    )
    snap = statusline.snapshot(conn)
    assert snap["critic_run"]["found"] is True
    assert snap["critic_run"]["active"] is True
    assert snap["critic_run"]["status"] == "provider_ready"
    assert snap["critic_run"]["provider"] == "codex"
    assert snap["critic_run"]["workflow_id"] == "wf-status-critic"
    assert snap["critic_run"]["progress_preview"][-1] == "Provider status: codex ready."


def test_snapshot_persists_unavailable_fallback_until_completed(conn):
    """CRITIC_UNAVAILABLE stays visible until reviewer fallback closes it."""
    completions_mod.submit(
        conn,
        lease_id="lease-critic-anchor",
        workflow_id="wf-status-fallback",
        role="implementer",
        payload={"IMPL_STATUS": "complete", "IMPL_HEAD_SHA": "impl-head"},
    )
    run = critic_runs_mod.start(conn, workflow_id="wf-status-fallback", provider="codex")
    critic_runs_mod.complete(
        conn,
        run_id=run["run_id"],
        verdict="CRITIC_UNAVAILABLE",
        provider="codex",
        summary="Codex unavailable.",
        detail="Provider authentication missing.",
        fallback="reviewer",
    )
    snap = statusline.snapshot(conn)
    assert snap["critic_run"]["status"] == "fallback_required"
    assert snap["critic_run"]["verdict"] == "CRITIC_UNAVAILABLE"
    assert snap["critic_run"]["fallback"] == "reviewer"

    critic_runs_mod.mark_fallback_completed(
        conn,
        workflow_id="wf-status-fallback",
        summary="Reviewer fallback completed.",
    )
    snap_after = statusline.snapshot(conn)
    assert snap_after["critic_run"]["found"] is False


def test_snapshot_hides_terminal_critic_without_current_implementer_anchor(conn):
    """A completed critic row is historical unless anchored to current routing."""
    run = critic_runs_mod.start(conn, workflow_id="wf-old-critic", provider="codex")
    critic_runs_mod.complete(
        conn,
        run_id=run["run_id"],
        verdict="TRY_AGAIN",
        provider="codex",
        summary="Old retry.",
    )
    snap = statusline.snapshot(conn)
    assert snap["critic_run"]["found"] is False


def test_snapshot_hides_terminal_critic_after_reviewer_completion_supersedes_it(conn):
    """Reviewer completion means the implementer critic result is no longer current."""
    import json as _json

    completions_mod.submit(
        conn,
        lease_id="lease-impl",
        workflow_id="wf-superseded-critic",
        role="implementer",
        payload={"IMPL_STATUS": "complete", "IMPL_HEAD_SHA": "impl-head"},
    )
    run = critic_runs_mod.start(conn, workflow_id="wf-superseded-critic", provider="codex")
    critic_runs_mod.complete(
        conn,
        run_id=run["run_id"],
        verdict="READY_FOR_REVIEWER",
        provider="codex",
        summary="Hand off.",
    )
    snap_current = statusline.snapshot(conn)
    assert snap_current["critic_run"]["found"] is True
    assert snap_current["critic_run"]["verdict"] == "READY_FOR_REVIEWER"

    completions_mod.submit(
        conn,
        lease_id="lease-reviewer",
        workflow_id="wf-superseded-critic",
        role="reviewer",
        payload={
            "REVIEW_VERDICT": "ready_for_guardian",
            "REVIEW_HEAD_SHA": "review-head",
            "REVIEW_FINDINGS_JSON": _json.dumps({"findings": []}),
        },
    )
    snap_after_reviewer = statusline.snapshot(conn)
    assert snap_after_reviewer["critic_run"]["found"] is False


def test_snapshot_hides_stale_active_critic_run(conn):
    """An abandoned active row must not claim a critic is running forever."""
    run = critic_runs_mod.start(conn, workflow_id="wf-stale-active-critic", provider="codex")
    old = int(time.time()) - statusline.CRITIC_ACTIVE_MAX_AGE_SECONDS - 10
    conn.execute(
        "UPDATE critic_runs SET updated_at = ?, started_at = ? WHERE run_id = ?",
        (old, old, run["run_id"]),
    )
    snap = statusline.snapshot(conn)
    assert snap["critic_run"]["found"] is False


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
    markers_mod.set_active(conn, "agent-007", "reviewer")
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


def test_snapshot_keeps_dispatch_cycle_keys_with_none_after_retirement(conn):
    """DEC-CATEGORY-C-DISPATCH-RETIRE-001: dispatch_cycles is retired.

    The dispatch_initiative and dispatch_cycle_id keys remain in the snapshot
    dict with their None defaults for schema stability (downstream HUD
    consumers check key presence, not value truthiness).
    """
    snap = statusline.snapshot(conn)
    assert snap["dispatch_initiative"] is None
    assert snap["dispatch_cycle_id"] is None


def test_snapshot_dispatch_status_from_completion_reviewer_ready(conn):
    """dispatch_status is derived from completion records, not dispatch_queue.

    DEC-WS6-001: A reviewer completion with verdict 'ready_for_guardian' must
    produce dispatch_status == 'guardian'. The queue is not consulted.
    Phase 8 Slice 11: tester role retired — reviewer is the sole evaluator.
    """
    import json as _json
    completions_mod.submit(
        conn,
        lease_id="lease-001",
        workflow_id="wf-ws6",
        role="reviewer",
        payload={
            "REVIEW_VERDICT": "ready_for_guardian",
            "REVIEW_HEAD_SHA": "abc123",
            "REVIEW_FINDINGS_JSON": _json.dumps({
                "findings": [
                    {"severity": "note", "title": "ok", "detail": "looks good"},
                ],
            }),
        },
    )
    snap = statusline.snapshot(conn)
    assert snap["dispatch_status"] == "guardian"
    assert snap["dispatch_workflow"] == "wf-ws6"
    assert snap["dispatch_from_role"] == "reviewer"
    assert snap["dispatch_from_verdict"] == "ready_for_guardian"


def test_snapshot_dispatch_status_from_completion_reviewer_needs_changes(conn):
    """Reviewer completion with 'needs_changes' routes back to implementer.
    Phase 8 Slice 11: tester role retired — reviewer is the sole evaluator.
    """
    import json as _json
    completions_mod.submit(
        conn,
        lease_id="lease-002",
        workflow_id="wf-ws6b",
        role="reviewer",
        payload={
            "REVIEW_VERDICT": "needs_changes",
            "REVIEW_HEAD_SHA": "def456",
            "REVIEW_FINDINGS_JSON": _json.dumps({
                "findings": [
                    {"severity": "blocking", "title": "bug", "detail": "fix this"},
                ],
            }),
        },
    )
    snap = statusline.snapshot(conn)
    assert snap["dispatch_status"] == "implementer"
    assert snap["dispatch_from_role"] == "reviewer"
    assert snap["dispatch_from_verdict"] == "needs_changes"


def test_snapshot_dispatch_status_none_when_no_completion(conn):
    """No completion records => dispatch_status is None.

    DEC-WS6-001 + DEC-CATEGORY-C-DISPATCH-RETIRE-001: queue-based lookup is
    gone and the dispatch_queue table has been retired. Without a completion
    record, all dispatch fields default to None.
    """
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

    Production path (DEC-WS6-001 / W-CONV-4 / DEC-CATEGORY-C-PROOF-RETIRE-001):
    reviewer submits a valid completion with ready_for_guardian -> implementer
    marker is set -> worktree registered -> events emitted.  snapshot()
    must reflect all of these in a single call.
    dispatch_status must be derived from the completion record (not the queue).
    proof_state fields must NOT appear in the snapshot — the underlying
    proof_state storage was retired under Category C bundle 1.
    dispatch_queue / dispatch_cycles were retired under Category C bundle 2;
    dispatch_initiative and dispatch_cycle_id remain as None in the snapshot
    for schema stability.
    Phase 8 Slice 11: tester retired — reviewer is the sole evaluator.

    This is the compound-interaction test: completions.py, markers.py,
    worktrees.py, events.py, and statusline.py all collaborate — snapshot()
    synthesizes them into one coherent projection.
    """
    import json as _json

    # 1. Submit a valid reviewer completion — this is now the routing authority
    #    (DEC-WS6-001). The queue is NOT enqueued; dispatch_status is derived
    #    from this record via determine_next_role("reviewer", "ready_for_guardian")
    #    => "guardian".
    completions_mod.submit(
        conn,
        lease_id="lease-tkt011",
        workflow_id="TKT-011",
        role="reviewer",
        payload={
            "REVIEW_VERDICT": "ready_for_guardian",
            "REVIEW_HEAD_SHA": "abc123",
            "REVIEW_FINDINGS_JSON": _json.dumps({
                "findings": [
                    {"severity": "note", "title": "ok", "detail": "approved"},
                ],
            }),
        },
    )

    # 2. Set active agent marker
    markers_mod.set_active(conn, "agent-tkt011", "implementer")

    # 3. Register a worktree
    worktrees_mod.register(conn, "/wt/tkt-011", "feature/tkt-011", ticket="TKT-011")

    # 4. Emit a couple events
    events_mod.emit(conn, "worktree.registered", detail="/wt/tkt-011")
    events_mod.emit(conn, "marker.set", detail="implementer")

    # Now take a snapshot and verify every domain is reflected
    snap = statusline.snapshot(conn)

    assert snap["status"] == "ok"
    # Proof fields must not appear (display removed in W-CONV-4; storage
    # removed in DEC-CATEGORY-C-PROOF-RETIRE-001).
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
    assert snap["dispatch_from_role"] == "reviewer"
    assert snap["dispatch_from_verdict"] == "ready_for_guardian"
    # DEC-CATEGORY-C-DISPATCH-RETIRE-001: dispatch_cycles table retired;
    # these keys remain as None for schema stability.
    assert snap["dispatch_initiative"] is None
    assert snap["dispatch_cycle_id"] is None
    assert snap["recent_event_count"] == 2
    assert len(snap["recent_events"]) == 2
    assert snap["recent_events"][0]["type"] == "marker.set"
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
        markers_mod.set_active(c, "agent-partial", "reviewer")

        c.execute("DROP TABLE worktrees")
        c.commit()

        snap = statusline.snapshot(c)
        c.close()

        # Sections before the fault must still be present.
        assert snap["eval_status"] == "pending"
        assert snap["active_agent"] == "reviewer"
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
        """ALLOW verdict maps to reviewed=True, verdict='ALLOW'.

        Bug #1 fix: review must be scoped to the active eval workflow.
        We set eval state for wf-test first, then insert a review event
        with created_at strictly after the eval updated_at.
        """
        import runtime.core.evaluation as eval_mod

        # Set eval state with updated_at = now - 2 so review event at now > it
        eval_mod.set_status(conn, "wf-test", "pending")
        # Backdate eval updated_at so the review event (at current time) is strictly later
        conn.execute(
            "UPDATE evaluation_state SET updated_at = updated_at - 2 WHERE workflow_id = 'wf-test'"
        )
        conn.commit()

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

    def test_last_review_workflow_source_keeps_reviewer_codex(self, conn):
        """Workflow scope in events.source must not surface as the reviewer name."""
        import runtime.core.evaluation as eval_mod

        eval_mod.set_status(conn, "wf-test", "pending")
        conn.execute(
            "UPDATE evaluation_state SET updated_at = updated_at - 2 WHERE workflow_id = 'wf-test'"
        )
        conn.commit()

        events_mod.emit(
            conn,
            "codex_stop_review",
            source="workflow:wf-test",
            detail="VERDICT: ALLOW — workflow=wf-test | work looks good",
        )
        snap = statusline.snapshot(conn)
        assert snap["last_review"]["reviewed"] is True
        assert snap["last_review"]["reviewer"] == "codex"

    def test_last_review_provider_detail_sets_reviewer_name(self, conn):
        """Provider in review detail surfaces Gemini/reviewer-subagent visibility."""
        import runtime.core.evaluation as eval_mod

        eval_mod.set_status(conn, "wf-test", "pending")
        conn.execute(
            "UPDATE evaluation_state SET updated_at = updated_at - 2 WHERE workflow_id = 'wf-test'"
        )
        conn.commit()

        events_mod.emit(
            conn,
            "codex_stop_review",
            source="workflow:wf-test",
            detail="VERDICT: ALLOW - workflow=wf-test | provider=gemini | work looks good",
        )
        snap = statusline.snapshot(conn)
        assert snap["last_review"]["reviewed"] is True
        assert snap["last_review"]["reviewer"] == "gemini"

    def test_last_review_block_verdict(self, conn):
        """BLOCK verdict maps to reviewed=True, verdict='BLOCK'.

        Bug #1 fix: review must be scoped to the active eval workflow.
        """
        import runtime.core.evaluation as eval_mod

        eval_mod.set_status(conn, "wf-test", "pending")
        conn.execute(
            "UPDATE evaluation_state SET updated_at = updated_at - 2 WHERE workflow_id = 'wf-test'"
        )
        conn.commit()

        events_mod.emit(
            conn,
            "codex_stop_review",
            detail="VERDICT: BLOCK — workflow=wf-test | missing tests",
        )
        snap = statusline.snapshot(conn)
        assert snap["last_review"]["reviewed"] is True
        assert snap["last_review"]["verdict"] == "BLOCK"

    def test_last_review_newest_wins(self, conn):
        """When multiple codex_stop_review events exist for same workflow, newest wins.

        Bug #1 fix: both events must reference the active eval workflow.
        """
        import runtime.core.evaluation as eval_mod

        eval_mod.set_status(conn, "wf-test", "pending")
        conn.execute(
            "UPDATE evaluation_state SET updated_at = updated_at - 2 WHERE workflow_id = 'wf-test'"
        )
        conn.commit()

        events_mod.emit(
            conn, "codex_stop_review", detail="VERDICT: BLOCK — workflow=wf-test | first"
        )
        events_mod.emit(
            conn, "codex_stop_review", detail="VERDICT: ALLOW — workflow=wf-test | second"
        )
        snap = statusline.snapshot(conn)
        assert snap["last_review"]["verdict"] == "ALLOW"

    def test_last_review_not_shown_when_eval_idle(self, conn):
        """Bug #1: review must not surface when eval is idle (no active workflow).

        A codex_stop_review event exists, but no evaluation_state is active.
        last_review.reviewed must be False.
        """
        events_mod.emit(
            conn,
            "codex_stop_review",
            detail="VERDICT: ALLOW — workflow=wf-orphan | orphan review",
        )
        snap = statusline.snapshot(conn)
        assert snap["last_review"]["reviewed"] is False

    def test_last_review_wrong_workflow_not_shown(self, conn):
        """Bug #1: review for wf-b must not surface when eval_workflow is wf-a.

        A review event exists for wf-b, but the active eval is wf-a.
        last_review.reviewed must be False.
        """
        import runtime.core.evaluation as eval_mod

        eval_mod.set_status(conn, "wf-a", "pending")
        conn.execute(
            "UPDATE evaluation_state SET updated_at = updated_at - 2 WHERE workflow_id = 'wf-a'"
        )
        conn.commit()

        events_mod.emit(
            conn,
            "codex_stop_review",
            detail="VERDICT: ALLOW — workflow=wf-b | wrong workflow",
        )
        snap = statusline.snapshot(conn)
        assert snap["last_review"]["reviewed"] is False

    def test_last_review_same_second_not_shown(self, conn):
        """Bug #2: review emitted in the same second as eval reset must not qualify.

        Both evaluation_state.updated_at and events.created_at use int(time.time()).
        The filter must be strict greater-than (created_at > updated_at) so a
        same-second review does not carry forward after an eval reset.
        """
        import runtime.core.evaluation as eval_mod

        now = int(time.time())
        eval_mod.set_status(conn, "wf-same-sec", "pending")
        # Force both timestamps to be identical
        conn.execute(
            "UPDATE evaluation_state SET updated_at = ? WHERE workflow_id = 'wf-same-sec'",
            (now,),
        )
        conn.execute(
            "INSERT INTO events (type, detail, created_at) VALUES (?, ?, ?)",
            ("codex_stop_review", "VERDICT: ALLOW — workflow=wf-same-sec | same second", now),
        )
        conn.commit()

        snap = statusline.snapshot(conn)
        assert snap["last_review"]["reviewed"] is False

    def test_last_review_resets_after_new_eval_step(self, conn):
        """Review event before eval reset does not carry into the new step.

        Production sequence (DEC-SL-160): a codex_stop_review event is
        emitted at T=100. Then a new evaluation_state row is written at T=200
        (new step starts). A snapshot at T=300 must show reviewed=False because
        no review event postdates the eval reset at T=200.

        Bug #1 fix: review is also for a different workflow (old vs wf-new-step),
        so workflow scoping additionally prevents it from surfacing.
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
        # The review event predates the new eval step AND has wrong workflow,
        # so reviewed must be False.
        assert snap["last_review"]["reviewed"] is False

    def test_last_review_present_when_review_after_eval(self, conn):
        """Review event after eval start is correctly surfaced.

        Compound-interaction test (DEC-SL-160): evaluation_state is written
        first, then a codex_stop_review event is emitted. snapshot() must
        reflect reviewed=True because the event strictly postdates the eval row.

        Bug #2 fix: strict greater-than means same-second no longer qualifies.
        We backdate eval updated_at by 2 seconds so the review event at current
        time is strictly later.
        """
        import runtime.core.evaluation as eval_mod

        # Set eval state (this sets updated_at to approx now)
        eval_mod.set_status(conn, "wf-reviewed", "pending")

        # Backdate eval updated_at so the review event is strictly later
        conn.execute(
            "UPDATE evaluation_state SET updated_at = updated_at - 2 WHERE workflow_id = 'wf-reviewed'"
        )
        conn.commit()

        # Emit review event — its created_at (now) is strictly > eval updated_at (now-2)
        events_mod.emit(
            conn,
            "codex_stop_review",
            detail="VERDICT: ALLOW — workflow=wf-reviewed | all good",
        )

        snap = statusline.snapshot(conn)
        assert snap["last_review"]["reviewed"] is True
        assert snap["last_review"]["verdict"] == "ALLOW"
