"""Tests for runtime/core/dispatch_shadow.py and its dispatch_engine wiring.

@decision DEC-CLAUDEX-DISPATCH-SHADOW-TESTS-001
Title: Shadow observer parity, divergence, and zero-effect are pinned in tests
Status: proposed (shadow-mode)
Rationale: The shadow observer is a best-effort side-channel, which makes
  regressions invisible unless they are mechanically asserted. This module
  pins:

    1. The pure mapper (live role/verdict → shadow stage/verdict) for every
       live role in ``dispatch_shadow.KNOWN_LIVE_ROLES``.
    2. Happy-path parity where live and shadow agree today.
    3. Phase 6 Slice 5 closed all planned divergences — guardian committed,
       merged, and skipped now route to planner in both live and shadow.
       Tests verify full parity for all guardian verdicts.
    4. Phase 5: implementer→reviewer is now direct parity (no tester in live
       chain).
    5. Phase 8 Slice 11: ``tester`` is no longer in ``KNOWN_LIVE_ROLES``.
       Any residual ``live_role="tester"`` input produces
       ``reason=unknown_live_role`` with every shadow field ``None``.
       ``dispatch_engine.process_agent_stop("tester", ...)`` returns
       silently (unknown-type path) and emits no shadow event.
    6. ``dispatch_engine.process_agent_stop`` emits a ``shadow_stage_decision``
       event with machine-readable JSON detail and does NOT change any
       live routing field (``next_role``, ``auto_dispatch``, ``error``,
       ``suggestion``).
    7. Errors during shadow emission never affect live routing.

  Purity: the mapper tests call ``dispatch_shadow`` functions directly and
  do not touch SQLite. The integration tests call ``process_agent_stop`` on
  an in-memory database and query the events table.
"""

from __future__ import annotations

import json
import sqlite3

import pytest

from runtime.core import (
    completions,
    decision_work_registry as dwr,
    dispatch_shadow,
    enforcement_config,
    events,
    leases,
)
from runtime.core import stage_registry as sr
from runtime.core.dispatch_engine import process_agent_stop
from runtime.schemas import ensure_schema

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
def project_root(tmp_path):
    return str(tmp_path)


def _issue_lease_at(conn, role, project_root, workflow_id="wf-shadow-001"):
    return leases.issue(
        conn,
        role=role,
        workflow_id=workflow_id,
        worktree_path=project_root,
    )


def _submit_guardian(conn, lease_id, workflow_id, verdict):
    return completions.submit(
        conn,
        lease_id=lease_id,
        workflow_id=workflow_id,
        role="guardian",
        payload={
            "LANDING_RESULT": verdict,
            "OPERATION_CLASS": "routine_local",
        },
    )


def _submit_implementer(conn, lease_id, workflow_id, verdict="complete"):
    return completions.submit(
        conn,
        lease_id=lease_id,
        workflow_id=workflow_id,
        role="implementer",
        payload={
            "IMPL_STATUS": verdict,
            "IMPL_HEAD_SHA": "sha-impl",
        },
    )


def _submit_planner(conn, lease_id, workflow_id, verdict="next_work_item"):
    """Submit a valid planner completion record (Phase 6 Slice 4)."""
    return completions.submit(
        conn,
        lease_id=lease_id,
        workflow_id=workflow_id,
        role="planner",
        payload={
            "PLAN_VERDICT": verdict,
            "PLAN_SUMMARY": "Test planner summary",
        },
    )


def _insert_goal(conn, goal_id, budget=5, status="active"):
    """Insert an active goal contract so planner→guardian budget check passes."""
    return dwr.insert_goal(
        conn,
        dwr.GoalRecord(
            goal_id=goal_id,
            desired_end_state="Test goal",
            status=status,
            autonomy_budget=budget,
        ),
    )


def _latest_shadow_event(conn) -> dict:
    rows = events.query(conn, type="shadow_stage_decision", limit=1)
    assert rows, "expected at least one shadow_stage_decision event"
    evt = rows[0]
    detail = json.loads(evt["detail"])
    return {"event": evt, "detail": detail}


# ---------------------------------------------------------------------------
# 1. Pure mapper — live (role, verdict) → shadow (stage, verdict)
# ---------------------------------------------------------------------------


class TestLiveToShadowMapper:
    def test_planner_empty_verdict_preserved_as_empty(self):
        """Planner with empty verdict preserves it — no fallback to next_work_item.

        In production, dispatch_engine skips shadow emission when the live
        path errors (no completion record). Empty verdict reaching the mapper
        is a degenerate case; the shadow should not invent a verdict.
        """
        stage, verdict = dispatch_shadow.map_live_to_shadow_stage(
            "planner", "", ""
        )
        assert stage == sr.PLANNER
        assert verdict == ""

    def test_planner_preserves_actual_verdict(self):
        """Planner with real verdict passes it through verbatim."""
        for v in ("next_work_item", "goal_complete", "needs_user_decision", "blocked_external"):
            stage, verdict = dispatch_shadow.map_live_to_shadow_stage(
                "planner", v, ""
            )
            assert stage == sr.PLANNER
            assert verdict == v

    def test_implementer_maps_to_implementer_preserving_verdict(self):
        for verdict in ("complete", "partial", "blocked"):
            stage, shadow_verdict = dispatch_shadow.map_live_to_shadow_stage(
                "implementer", verdict, ""
            )
            assert stage == sr.IMPLEMENTER
            assert shadow_verdict == verdict

    def test_implementer_empty_verdict_defaults_to_complete(self):
        stage, verdict = dispatch_shadow.map_live_to_shadow_stage(
            "implementer", "", ""
        )
        assert stage == sr.IMPLEMENTER
        assert verdict == "complete"

    def test_tester_is_unknown_live_role_after_slice_11(self):
        """Phase 8 Slice 11: tester is removed from KNOWN_LIVE_ROLES.

        The mapper returns (None, None) for tester inputs — same as any
        other unknown role.
        """
        assert "tester" not in dispatch_shadow.KNOWN_LIVE_ROLES
        for verdict in ("ready_for_guardian", "needs_changes", "blocked_by_plan"):
            stage, shadow_verdict = dispatch_shadow.map_live_to_shadow_stage(
                "tester", verdict, ""
            )
            assert stage is None, (
                f"tester must produce None stage for verdict {verdict}"
            )
            assert shadow_verdict is None

    def test_reviewer_identity_maps_to_reviewer_preserving_verdict(self):
        """Phase 4: live reviewer identity-maps to shadow REVIEWER."""
        for verdict in ("ready_for_guardian", "needs_changes", "blocked_by_plan"):
            stage, shadow_verdict = dispatch_shadow.map_live_to_shadow_stage(
                "reviewer", verdict, ""
            )
            assert stage == sr.REVIEWER, (
                f"reviewer must identity-map to REVIEWER for verdict {verdict}"
            )
            assert shadow_verdict == verdict

    def test_guardian_with_provision_mode_hint_maps_to_provision(self):
        stage, verdict = dispatch_shadow.map_live_to_shadow_stage(
            "guardian", "provisioned", "provision"
        )
        assert stage == sr.GUARDIAN_PROVISION
        assert verdict == "provisioned"

    def test_guardian_without_mode_infers_provision_from_provisioned_verdict(self):
        stage, verdict = dispatch_shadow.map_live_to_shadow_stage(
            "guardian", "provisioned", ""
        )
        assert stage == sr.GUARDIAN_PROVISION
        assert verdict == "provisioned"

    def test_guardian_without_mode_defaults_to_land_for_landing_verdicts(self):
        for verdict in ("committed", "merged", "pushed", "denied", "skipped"):
            stage, shadow_verdict = dispatch_shadow.map_live_to_shadow_stage(
                "guardian", verdict, ""
            )
            assert stage == sr.GUARDIAN_LAND
            assert shadow_verdict == verdict

    def test_unknown_live_role_returns_none_pair(self):
        assert dispatch_shadow.map_live_to_shadow_stage("banana", "complete", "") == (
            None,
            None,
        )


# ---------------------------------------------------------------------------
# 2. translate_live_next_role — destination-side vocabulary translation
# ---------------------------------------------------------------------------


class TestTranslateLiveNextRole:
    def test_none_next_role_returns_none(self):
        assert (
            dispatch_shadow.translate_live_next_role("guardian", "committed", None, "")
            is None
        )

    def test_empty_next_role_returns_none(self):
        assert (
            dispatch_shadow.translate_live_next_role("reviewer", "needs_changes", "", "")
            is None
        )

    def test_planner_destination_translates_to_planner(self):
        assert (
            dispatch_shadow.translate_live_next_role(
                "reviewer", "blocked_by_plan", "planner", ""
            )
            == sr.PLANNER
        )

    def test_implementer_destination_translates_to_implementer(self):
        assert (
            dispatch_shadow.translate_live_next_role(
                "reviewer", "needs_changes", "implementer", ""
            )
            == sr.IMPLEMENTER
        )

    def test_tester_destination_returns_none_after_slice_11(self):
        """Phase 8 Slice 11: ``tester`` is no longer a recognised destination
        in the translator — it returns ``None`` like any other unknown role.
        """
        assert (
            dispatch_shadow.translate_live_next_role(
                "implementer", "complete", "tester", ""
            )
            is None
        )

    def test_guardian_destination_with_provision_mode_is_provision(self):
        assert (
            dispatch_shadow.translate_live_next_role(
                "planner", "next_work_item", "guardian", "provision"
            )
            == sr.GUARDIAN_PROVISION
        )

    def test_reviewer_destination_translates_to_reviewer(self):
        """Phase 4: live next_role='reviewer' translates to shadow REVIEWER."""
        assert (
            dispatch_shadow.translate_live_next_role(
                "implementer", "complete", "reviewer", ""
            )
            == sr.REVIEWER
        )

    def test_guardian_destination_from_reviewer_ready_is_land(self):
        """Phase 4: reviewer(ready_for_guardian) → guardian translates to GUARDIAN_LAND."""
        assert (
            dispatch_shadow.translate_live_next_role(
                "reviewer", "ready_for_guardian", "guardian", ""
            )
            == sr.GUARDIAN_LAND
        )


# ---------------------------------------------------------------------------
# 3. compute_shadow_decision — payload shape and parity/divergence codes
# ---------------------------------------------------------------------------


class TestComputeShadowDecision:
    def test_payload_has_stable_field_set(self):
        d = dispatch_shadow.compute_shadow_decision(
            live_role="planner",
            live_verdict="next_work_item",
            live_next_role="guardian",
            guardian_mode="provision",
        )
        required = {
            "live_role",
            "live_verdict",
            "live_next_role",
            "shadow_from_stage",
            "shadow_verdict",
            "shadow_next_stage",
            "agreed",
            "reason",
        }
        assert required <= set(d.keys()), (
            f"missing fields: {required - set(d.keys())}"
        )

    def test_payload_is_json_serialisable(self):
        d = dispatch_shadow.compute_shadow_decision(
            live_role="guardian",
            live_verdict="committed",
            live_next_role=None,
            guardian_mode="",
        )
        # Should not raise.
        encoded = json.dumps(d)
        decoded = json.loads(encoded)
        assert decoded == d

    # --- Happy-path parity cases -------------------------------------------

    def test_planner_to_guardian_provision_is_parity(self):
        d = dispatch_shadow.compute_shadow_decision(
            live_role="planner",
            live_verdict="next_work_item",
            live_next_role="guardian",
            guardian_mode="provision",
        )
        assert d["shadow_from_stage"] == sr.PLANNER
        assert d["shadow_verdict"] == "next_work_item"
        assert d["shadow_next_stage"] == sr.GUARDIAN_PROVISION
        assert d["agreed"] is True
        assert d["reason"] == dispatch_shadow.REASON_PARITY

    def test_implementer_to_reviewer_is_direct_parity(self):
        """Phase 5: live implementer→reviewer, shadow implementer→reviewer — direct parity."""
        d = dispatch_shadow.compute_shadow_decision(
            live_role="implementer",
            live_verdict="complete",
            live_next_role="reviewer",
            guardian_mode="",
        )
        assert d["shadow_from_stage"] == sr.IMPLEMENTER
        assert d["shadow_next_stage"] == sr.REVIEWER
        assert d["agreed"] is True
        assert d["reason"] == dispatch_shadow.REASON_PARITY

    def test_tester_inputs_are_unknown_live_role_after_slice_11(self):
        """Phase 8 Slice 11: tester is removed from KNOWN_LIVE_ROLES.

        Any residual shadow invocation with ``live_role="tester"`` — from old
        persisted events, tests, or misconfigured callers — must yield
        ``reason=unknown_live_role`` with every shadow field ``None`` and
        ``agreed=False``. The legacy ``tester → reviewer`` collapse is gone.
        """
        for verdict, next_role in (
            ("ready_for_guardian", "guardian"),
            ("needs_changes", "implementer"),
            ("blocked_by_plan", "planner"),
        ):
            d = dispatch_shadow.compute_shadow_decision(
                live_role="tester",
                live_verdict=verdict,
                live_next_role=next_role,
                guardian_mode="",
            )
            assert d["reason"] == dispatch_shadow.REASON_UNKNOWN_LIVE_ROLE
            assert d["shadow_from_stage"] is None
            assert d["shadow_verdict"] is None
            assert d["shadow_next_stage"] is None
            assert d["agreed"] is False

    # --- Phase 4: Reviewer parity cases -------------------------------------

    def test_reviewer_ready_for_guardian_is_parity(self):
        """Phase 4: reviewer(ready_for_guardian) → guardian:land agrees with live."""
        d = dispatch_shadow.compute_shadow_decision(
            live_role="reviewer",
            live_verdict="ready_for_guardian",
            live_next_role="guardian",
            guardian_mode="",
        )
        assert d["shadow_from_stage"] == sr.REVIEWER
        assert d["shadow_next_stage"] == sr.GUARDIAN_LAND
        assert d["agreed"] is True
        assert d["reason"] == dispatch_shadow.REASON_PARITY

    def test_reviewer_needs_changes_is_parity(self):
        """Phase 4: reviewer(needs_changes) → implementer agrees with live."""
        d = dispatch_shadow.compute_shadow_decision(
            live_role="reviewer",
            live_verdict="needs_changes",
            live_next_role="implementer",
            guardian_mode="",
        )
        assert d["shadow_next_stage"] == sr.IMPLEMENTER
        assert d["agreed"] is True
        assert d["reason"] == dispatch_shadow.REASON_PARITY

    def test_reviewer_blocked_by_plan_is_parity(self):
        """Phase 4: reviewer(blocked_by_plan) → planner agrees with live."""
        d = dispatch_shadow.compute_shadow_decision(
            live_role="reviewer",
            live_verdict="blocked_by_plan",
            live_next_role="planner",
            guardian_mode="",
        )
        assert d["shadow_next_stage"] == sr.PLANNER
        assert d["agreed"] is True
        assert d["reason"] == dispatch_shadow.REASON_PARITY

    def test_guardian_provisioned_is_parity(self):
        d = dispatch_shadow.compute_shadow_decision(
            live_role="guardian",
            live_verdict="provisioned",
            live_next_role="implementer",
            guardian_mode="",
        )
        assert d["shadow_from_stage"] == sr.GUARDIAN_PROVISION
        assert d["shadow_next_stage"] == sr.IMPLEMENTER
        assert d["agreed"] is True

    def test_guardian_denied_is_parity(self):
        d = dispatch_shadow.compute_shadow_decision(
            live_role="guardian",
            live_verdict="denied",
            live_next_role="implementer",
            guardian_mode="",
        )
        assert d["shadow_from_stage"] == sr.GUARDIAN_LAND
        assert d["shadow_next_stage"] == sr.IMPLEMENTER
        assert d["agreed"] is True

    # --- Phase 6 Slice 5: formerly-divergent cases now parity ---------------

    def test_guardian_committed_is_parity_after_slice5(self):
        """Phase 6 Slice 5: live now routes committed → planner, matching shadow."""
        d = dispatch_shadow.compute_shadow_decision(
            live_role="guardian",
            live_verdict="committed",
            live_next_role="planner",  # live: post-guardian continuation
            guardian_mode="",
        )
        assert d["shadow_from_stage"] == sr.GUARDIAN_LAND
        assert d["shadow_next_stage"] == sr.PLANNER
        assert d["agreed"] is True
        assert d["reason"] == dispatch_shadow.REASON_PARITY

    def test_guardian_merged_is_parity_after_slice5(self):
        """Phase 6 Slice 5: live now routes merged → planner, matching shadow."""
        d = dispatch_shadow.compute_shadow_decision(
            live_role="guardian",
            live_verdict="merged",
            live_next_role="planner",
            guardian_mode="",
        )
        assert d["shadow_next_stage"] == sr.PLANNER
        assert d["agreed"] is True
        assert d["reason"] == dispatch_shadow.REASON_PARITY

    def test_guardian_pushed_is_parity(self):
        """Guardian pushed routes to planner, matching shadow."""
        d = dispatch_shadow.compute_shadow_decision(
            live_role="guardian",
            live_verdict="pushed",
            live_next_role="planner",
            guardian_mode="",
        )
        assert d["shadow_next_stage"] == sr.PLANNER
        assert d["agreed"] is True
        assert d["reason"] == dispatch_shadow.REASON_PARITY

    def test_guardian_skipped_is_parity_after_slice5(self):
        """Phase 6 Slice 5: live now routes skipped → planner, matching shadow."""
        d = dispatch_shadow.compute_shadow_decision(
            live_role="guardian",
            live_verdict="skipped",
            live_next_role="planner",  # live: goal reassessment
            guardian_mode="",
        )
        assert d["shadow_next_stage"] == sr.PLANNER
        assert d["agreed"] is True
        assert d["reason"] == dispatch_shadow.REASON_PARITY

    # --- Unknown / unmapped ------------------------------------------------

    def test_unknown_live_role_yields_unknown_reason(self):
        d = dispatch_shadow.compute_shadow_decision(
            live_role="banana",
            live_verdict="complete",
            live_next_role="reviewer",
            guardian_mode="",
        )
        assert d["reason"] == dispatch_shadow.REASON_UNKNOWN_LIVE_ROLE
        assert d["shadow_from_stage"] is None
        assert d["shadow_next_stage"] is None
        assert d["agreed"] is False

    def test_compute_never_raises_on_garbage_input(self):
        # Exercise several bad inputs; none of these should raise.
        dispatch_shadow.compute_shadow_decision(
            live_role="", live_verdict="", live_next_role=None, guardian_mode=""
        )
        dispatch_shadow.compute_shadow_decision(
            live_role="implementer",
            live_verdict="",
            live_next_role=None,
            guardian_mode="",
        )
        dispatch_shadow.compute_shadow_decision(
            live_role="guardian",
            live_verdict="zzz-unknown",
            live_next_role="implementer",
            guardian_mode="",
        )


# ---------------------------------------------------------------------------
# 4. dispatch_engine wiring — shadow emission is side-effect-only
# ---------------------------------------------------------------------------


class TestDispatchEngineShadowEmission:
    def test_planner_stop_emits_shadow_event_and_preserves_live_routing(
        self, conn, project_root
    ):
        # Phase 6 Slice 4: planner requires lease + completion for routing.
        wf = "wf-shadow-planner"
        _insert_goal(conn, wf)
        lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf)
        _submit_planner(conn, lease["lease_id"], wf, verdict="next_work_item")

        before = len(events.query(conn, type="shadow_stage_decision", limit=100))

        result = process_agent_stop(conn, "planner", project_root)

        # Live routing: planner (next_work_item) → guardian provision.
        assert result["next_role"] == "guardian"
        assert result["error"] is None
        assert result["guardian_mode"] == "provision"

        # Shadow event emitted.
        after = len(events.query(conn, type="shadow_stage_decision", limit=100))
        assert after == before + 1

        shadow = _latest_shadow_event(conn)
        detail = shadow["detail"]
        assert detail["live_role"] == "planner"
        assert detail["live_verdict"] == "next_work_item"
        assert detail["live_next_role"] == "guardian"
        assert detail["shadow_from_stage"] == sr.PLANNER
        assert detail["shadow_verdict"] == "next_work_item"
        assert detail["shadow_next_stage"] == sr.GUARDIAN_PROVISION
        assert detail["agreed"] is True
        assert detail["reason"] == dispatch_shadow.REASON_PARITY

    def test_implementer_stop_emits_shadow_event(self, conn, project_root):
        wf = "wf-shadow-impl"
        enforcement_config.set_(
            conn,
            "critic_enabled_implementer_stop",
            "false",
            scope=f"project={project_root}",
            actor_role="planner",
        )
        lease = _issue_lease_at(conn, "implementer", project_root, workflow_id=wf)
        _submit_implementer(conn, lease["lease_id"], wf, verdict="complete")

        result = process_agent_stop(conn, "implementer", project_root)

        assert result["next_role"] == "reviewer"
        assert result["error"] is None

        shadow = _latest_shadow_event(conn)
        detail = shadow["detail"]
        assert detail["live_role"] == "implementer"
        assert detail["live_verdict"] == "complete"
        assert detail["live_next_role"] == "reviewer"
        assert detail["shadow_from_stage"] == sr.IMPLEMENTER
        assert detail["shadow_next_stage"] == sr.REVIEWER
        assert detail["agreed"] is True
        assert detail["reason"] == dispatch_shadow.REASON_PARITY

    def test_tester_stop_returns_silently_and_emits_no_shadow_event(
        self, conn, project_root
    ):
        """Phase 8 Slice 11: tester is no longer a known agent type.

        ``process_agent_stop`` with ``agent_type="tester"`` takes the
        unknown-type early-exit path: no routing, no lease mutation, and
        NO shadow event emission. Shadow emission is gated on the role
        being a known routing authority; since tester is no longer one,
        the shadow side-channel has nothing to compare against.
        """
        wf = "wf-shadow-tester-ready"
        _issue_lease_at(conn, "tester", project_root, workflow_id=wf)
        # No completion submitted — tester has no schema after Slice 11 and
        # process_agent_stop returns before attempting to read completions.

        before = len(events.query(conn, type="shadow_stage_decision", limit=100))
        result = process_agent_stop(conn, "tester", project_root)

        # Unknown-type path: silent exit with empty routing.
        assert result["next_role"] is None or result["next_role"] == ""
        assert result["error"] is None
        assert result["auto_dispatch"] is False

        # No shadow event emitted.
        after = len(events.query(conn, type="shadow_stage_decision", limit=100))
        assert after == before

    def test_guardian_committed_emits_parity_event_after_slice5(
        self, conn, project_root
    ):
        """Phase 6 Slice 5: guardian committed → planner (live matches shadow)."""
        wf = "wf-shadow-guardian-committed"
        lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf)
        _submit_guardian(conn, lease["lease_id"], wf, verdict="committed")

        result = process_agent_stop(conn, "guardian", project_root)

        # Live: post-guardian continuation → planner.
        assert result["next_role"] == "planner"
        assert result["error"] is None

        shadow = _latest_shadow_event(conn)
        detail = shadow["detail"]
        assert detail["live_role"] == "guardian"
        assert detail["live_verdict"] == "committed"
        assert detail["live_next_role"] == "planner"
        assert detail["shadow_from_stage"] == sr.GUARDIAN_LAND
        assert detail["shadow_next_stage"] == sr.PLANNER
        assert detail["agreed"] is True
        assert detail["reason"] == dispatch_shadow.REASON_PARITY

    def test_guardian_merged_emits_parity_event_after_slice5(
        self, conn, project_root
    ):
        """Phase 6 Slice 5: guardian merged → planner (live matches shadow)."""
        wf = "wf-shadow-guardian-merged"
        lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf)
        _submit_guardian(conn, lease["lease_id"], wf, verdict="merged")

        result = process_agent_stop(conn, "guardian", project_root)

        assert result["next_role"] == "planner"
        shadow = _latest_shadow_event(conn)
        detail = shadow["detail"]
        assert detail["shadow_next_stage"] == sr.PLANNER
        assert detail["agreed"] is True
        assert detail["reason"] == dispatch_shadow.REASON_PARITY

    def test_guardian_provisioned_emits_parity_event(self, conn, project_root):
        wf = "wf-shadow-guardian-prov"
        lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf)
        _submit_guardian(conn, lease["lease_id"], wf, verdict="provisioned")

        result = process_agent_stop(conn, "guardian", project_root)

        assert result["next_role"] == "implementer"
        shadow = _latest_shadow_event(conn)
        detail = shadow["detail"]
        assert detail["shadow_from_stage"] == sr.GUARDIAN_PROVISION
        assert detail["shadow_next_stage"] == sr.IMPLEMENTER
        assert detail["agreed"] is True
        assert detail["reason"] == dispatch_shadow.REASON_PARITY

    def test_shadow_event_detail_is_valid_json(self, conn, project_root):
        wf = "wf-shadow-json"
        lease = _issue_lease_at(conn, "reviewer", project_root, workflow_id=wf)
        _submit_reviewer(conn, lease["lease_id"], wf, verdict="ready_for_guardian")
        process_agent_stop(conn, "reviewer", project_root)

        rows = events.query(conn, type="shadow_stage_decision", limit=1)
        assert rows
        # Must be parseable as JSON without mutation.
        parsed = json.loads(rows[0]["detail"])
        assert isinstance(parsed, dict)
        # Every required field is present.
        for key in (
            "live_role",
            "live_verdict",
            "live_next_role",
            "shadow_from_stage",
            "shadow_verdict",
            "shadow_next_stage",
            "agreed",
            "reason",
            "workflow_id",
        ):
            assert key in parsed, f"shadow payload missing field: {key}"

    def test_shadow_event_source_scopes_by_workflow(self, conn, project_root):
        wf = "wf-shadow-source"
        lease = _issue_lease_at(conn, "reviewer", project_root, workflow_id=wf)
        _submit_reviewer(conn, lease["lease_id"], wf, verdict="needs_changes")
        process_agent_stop(conn, "reviewer", project_root)

        rows = events.query(
            conn, type="shadow_stage_decision", source=f"workflow:{wf}", limit=1
        )
        assert rows, "shadow event must be filterable by workflow source"


# ---------------------------------------------------------------------------
# 5. Zero routing effect — live results identical with shadow on, and shadow
#    errors never affect live results.
# ---------------------------------------------------------------------------


class TestShadowHasZeroRoutingEffect:
    def test_planner_routing_fields_identical_regardless_of_shadow(
        self, conn, project_root
    ):
        # Phase 6 Slice 4: planner requires lease + completion for routing.
        wf = "wf-zero-effect-planner"
        _insert_goal(conn, wf)
        lease = _issue_lease_at(conn, "planner", project_root, workflow_id=wf)
        _submit_planner(conn, lease["lease_id"], wf, verdict="next_work_item")
        # Capture the full live-routing field set. If the shadow observer
        # changes any of these, this test fails.
        result = process_agent_stop(conn, "planner", project_root)
        assert result["next_role"] == "guardian"
        assert result["guardian_mode"] == "provision"
        assert result["error"] is None
        assert result["auto_dispatch"] is True

    def test_tester_routing_fields_unchanged_after_slice_11(self, conn, project_root):
        """Phase 8 Slice 11: tester is retired — process_agent_stop takes the
        unknown-type early-exit path with null routing and no shadow emission.
        """
        wf = "wf-zero-effect-tester"
        _issue_lease_at(conn, "tester", project_root, workflow_id=wf)
        result = process_agent_stop(conn, "tester", project_root)
        assert result["next_role"] is None or result["next_role"] == ""
        assert result["error"] is None
        assert result["auto_dispatch"] is False

    def test_guardian_committed_routes_to_planner_matching_shadow(
        self, conn, project_root
    ):
        """Phase 6 Slice 5: live and shadow both route committed → planner."""
        wf = "wf-zero-effect-guardian"
        lease = _issue_lease_at(conn, "guardian", project_root, workflow_id=wf)
        _submit_guardian(conn, lease["lease_id"], wf, verdict="committed")
        result = process_agent_stop(conn, "guardian", project_root)
        assert result["next_role"] == "planner"
        assert result["error"] is None
        assert result["auto_dispatch"] is True

    def test_shadow_emission_failure_does_not_affect_routing(
        self, conn, project_root, monkeypatch
    ):
        # Force dispatch_shadow.compute_shadow_decision to raise. The live
        # routing result must remain exactly as it would without shadow.
        # Use reviewer (a role with active routing) to verify shadow crash
        # doesn't affect live routing.
        def _boom(**kwargs):
            raise RuntimeError("shadow observer crashed")

        monkeypatch.setattr(dispatch_shadow, "compute_shadow_decision", _boom)

        wf = "wf-shadow-crash"
        lease = _issue_lease_at(conn, "reviewer", project_root, workflow_id=wf)
        _submit_reviewer(conn, lease["lease_id"], wf, verdict="ready_for_guardian")

        result = process_agent_stop(conn, "reviewer", project_root)

        # Live routing still succeeds.
        assert result["next_role"] == "guardian"
        assert result["error"] is None
        assert result["auto_dispatch"] is True

        # No shadow event was emitted for this stop (the crash swallowed it).
        rows = events.query(
            conn, type="shadow_stage_decision", source=f"workflow:{wf}", limit=5
        )
        assert rows == []

    def test_shadow_emission_on_live_error_path_is_suppressed(
        self, conn, project_root
    ):
        # Reviewer without an active lease → live path reports PROCESS ERROR
        # and next_role=None. Shadow must NOT emit, since there is no real
        # live routing decision to compare against.
        result = process_agent_stop(conn, "reviewer", project_root)
        assert result["next_role"] is None
        assert result["error"] is not None
        rows = events.query(conn, type="shadow_stage_decision", limit=5)
        assert rows == []


# ---------------------------------------------------------------------------
# 6. Phase 4: Reviewer in KNOWN_LIVE_ROLES + engine emission
# ---------------------------------------------------------------------------


def _submit_reviewer(conn, lease_id, workflow_id, verdict, head_sha="sha-rev"):
    """Submit a valid reviewer completion for shadow emission tests."""
    return completions.submit(
        conn,
        lease_id=lease_id,
        workflow_id=workflow_id,
        role="reviewer",
        payload={
            "REVIEW_VERDICT": verdict,
            "REVIEW_HEAD_SHA": head_sha,
            "REVIEW_FINDINGS_JSON": json.dumps({
                "findings": [
                    {"severity": "note", "title": "test", "detail": "test detail"},
                ],
            }),
        },
    )


class TestReviewerKnownLiveRoles:
    def test_reviewer_in_known_live_roles(self):
        """Phase 4: KNOWN_LIVE_ROLES must include 'reviewer'."""
        assert "reviewer" in dispatch_shadow.KNOWN_LIVE_ROLES


class TestDispatchEngineReviewerShadowEmission:
    def test_reviewer_ready_emits_parity_event(self, conn, project_root):
        """Phase 4: reviewer(ready_for_guardian) emits shadow parity event."""
        wf = "wf-shadow-reviewer-ready"
        lease = _issue_lease_at(conn, "reviewer", project_root, workflow_id=wf)
        _submit_reviewer(conn, lease["lease_id"], wf, verdict="ready_for_guardian")

        result = process_agent_stop(conn, "reviewer", project_root)

        assert result["next_role"] == "guardian"
        assert result["error"] is None

        shadow = _latest_shadow_event(conn)
        detail = shadow["detail"]
        assert detail["live_role"] == "reviewer"
        assert detail["live_verdict"] == "ready_for_guardian"
        assert detail["live_next_role"] == "guardian"
        assert detail["shadow_from_stage"] == sr.REVIEWER
        assert detail["shadow_next_stage"] == sr.GUARDIAN_LAND
        assert detail["agreed"] is True
        assert detail["reason"] == dispatch_shadow.REASON_PARITY
        assert detail["workflow_id"] == wf

    def test_reviewer_needs_changes_emits_parity_event(self, conn, project_root):
        """Phase 4: reviewer(needs_changes) emits shadow parity event."""
        wf = "wf-shadow-reviewer-changes"
        lease = _issue_lease_at(conn, "reviewer", project_root, workflow_id=wf)
        _submit_reviewer(conn, lease["lease_id"], wf, verdict="needs_changes")

        result = process_agent_stop(conn, "reviewer", project_root)

        assert result["next_role"] == "implementer"
        shadow = _latest_shadow_event(conn)
        detail = shadow["detail"]
        assert detail["live_role"] == "reviewer"
        assert detail["live_verdict"] == "needs_changes"
        assert detail["shadow_next_stage"] == sr.IMPLEMENTER
        assert detail["agreed"] is True

    def test_reviewer_blocked_by_plan_emits_parity_event(self, conn, project_root):
        """Phase 4: reviewer(blocked_by_plan) emits shadow parity event."""
        wf = "wf-shadow-reviewer-blocked"
        lease = _issue_lease_at(conn, "reviewer", project_root, workflow_id=wf)
        _submit_reviewer(conn, lease["lease_id"], wf, verdict="blocked_by_plan")

        result = process_agent_stop(conn, "reviewer", project_root)

        assert result["next_role"] == "planner"
        shadow = _latest_shadow_event(conn)
        detail = shadow["detail"]
        assert detail["live_role"] == "reviewer"
        assert detail["shadow_next_stage"] == sr.PLANNER
        assert detail["agreed"] is True

    def test_reviewer_error_path_suppresses_shadow_emission(self, conn, project_root):
        """Phase 4: reviewer without lease → error → no shadow event emitted."""
        result = process_agent_stop(conn, "reviewer", project_root)
        assert result["error"] is not None
        rows = events.query(conn, type="shadow_stage_decision", limit=5)
        assert rows == []
