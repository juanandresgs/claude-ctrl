"""Shadow-mode tests for the ClauDEX stage registry and contracts scaffolding.

@decision DEC-CLAUDEX-STAGE-REGISTRY-TESTS-001
Title: tests/runtime/test_stage_registry.py pins the target ClauDEX graph and two-loop behavior
Status: proposed (shadow-mode)
Rationale: CUTOVER_PLAN Phase 1 requires invariant coverage for the stage
  registry before any later slice can depend on it. These tests pin:

    1. Every target-graph transition declared in CUTOVER_PLAN §Target
       Architecture → Stage Registry is present in ``TRANSITIONS`` and
       returned by ``next_stage``.
    2. The two-loop behavior — inner convergence via implementer<->reviewer
       and outer continuation via guardian(land) -> planner -> ... — walks
       without leaving the graph.
    3. Planner owns post-guardian continuation: no reviewer or guardian
       verdict routes directly past planner to terminal or user.
    4. Reviewer is closed to its three verdicts and cannot land directly.
    5. Guardian provision and land have disjoint verdict vocabularies.
    6. ``next_stage`` is pure and rejects unknown pairs with ``None``.
    7. ``GoalContract`` and ``WorkItemContract`` reject unknown statuses.

  These tests run independently of the live dispatch path — they import
  ``runtime.core.stage_registry`` and ``runtime.core.contracts`` only. They
  MUST NOT import ``dispatch_engine``, ``completions``, or any SQLite-backed
  runtime module. If a future change drifts the live routing table away from
  the target graph, these tests stay green (that is the point of shadow
  mode); when the live path is eventually cut over, these same tests become
  the cutover acceptance criteria.
"""

from __future__ import annotations

import pytest

from runtime.core import stage_registry as sr
from runtime.core.contracts import (
    GOAL_STATUSES,
    WORK_ITEM_STATUSES,
    EvaluationContract,
    GoalContract,
    ScopeManifest,
    WorkItemContract,
)

# ---------------------------------------------------------------------------
# Target graph declaration — this is the CUTOVER_PLAN table, mirrored here so
# the test file can be read on its own as proof of what we pinned.
# ---------------------------------------------------------------------------

TARGET_TRANSITIONS: tuple[tuple[str, str, str], ...] = (
    # planner outgoing
    (sr.PLANNER, "next_work_item", sr.GUARDIAN_PROVISION),
    (sr.PLANNER, "goal_complete", sr.TERMINAL),
    (sr.PLANNER, "needs_user_decision", sr.USER),
    (sr.PLANNER, "blocked_external", sr.TERMINAL),
    # guardian(provision) outgoing
    (sr.GUARDIAN_PROVISION, "provisioned", sr.IMPLEMENTER),
    (sr.GUARDIAN_PROVISION, "denied", sr.IMPLEMENTER),
    (sr.GUARDIAN_PROVISION, "skipped", sr.PLANNER),
    # implementer outgoing
    (sr.IMPLEMENTER, "complete", sr.REVIEWER),
    (sr.IMPLEMENTER, "partial", sr.REVIEWER),
    (sr.IMPLEMENTER, "blocked", sr.REVIEWER),
    # reviewer outgoing
    (sr.REVIEWER, "ready_for_guardian", sr.GUARDIAN_LAND),
    (sr.REVIEWER, "needs_changes", sr.IMPLEMENTER),
    (sr.REVIEWER, "blocked_by_plan", sr.PLANNER),
    # guardian(land) outgoing
    (sr.GUARDIAN_LAND, "committed", sr.PLANNER),
    (sr.GUARDIAN_LAND, "merged", sr.PLANNER),
    (sr.GUARDIAN_LAND, "denied", sr.IMPLEMENTER),
    (sr.GUARDIAN_LAND, "skipped", sr.PLANNER),
)


# ---------------------------------------------------------------------------
# 1. Target-graph transition table is exactly what CUTOVER_PLAN declares
# ---------------------------------------------------------------------------


class TestTargetGraphTable:
    def test_every_target_transition_is_declared(self):
        declared = {(t.from_stage, t.verdict, t.to_stage) for t in sr.TRANSITIONS}
        missing = set(TARGET_TRANSITIONS) - declared
        assert not missing, f"stage registry missing target transitions: {missing}"

    def test_registry_has_no_extra_transitions(self):
        declared = {(t.from_stage, t.verdict, t.to_stage) for t in sr.TRANSITIONS}
        extra = declared - set(TARGET_TRANSITIONS)
        assert not extra, (
            "stage registry declared transitions beyond the CUTOVER_PLAN target: "
            f"{extra}. Any addition must be reflected in TARGET_TRANSITIONS."
        )

    def test_next_stage_resolves_every_target_transition(self):
        for from_stage, verdict, expected_to in TARGET_TRANSITIONS:
            assert sr.next_stage(from_stage, verdict) == expected_to, (
                f"{from_stage}/{verdict} expected -> {expected_to}, "
                f"got {sr.next_stage(from_stage, verdict)!r}"
            )


# ---------------------------------------------------------------------------
# 2. Verdict vocabularies are closed and per-stage disjoint where required
# ---------------------------------------------------------------------------


class TestVerdictVocabularies:
    def test_reviewer_has_exactly_three_verdicts(self):
        assert sr.REVIEWER_VERDICTS == frozenset(
            {"ready_for_guardian", "needs_changes", "blocked_by_plan"}
        )

    def test_reviewer_verdicts_never_route_to_guardian_land_except_ready(self):
        for verdict in sr.REVIEWER_VERDICTS:
            target = sr.next_stage(sr.REVIEWER, verdict)
            if verdict == "ready_for_guardian":
                assert target == sr.GUARDIAN_LAND
            else:
                assert target != sr.GUARDIAN_LAND

    def test_guardian_modes_have_disjoint_outcomes(self):
        # Provision mode has "provisioned" which land mode does not.
        # Land mode has "committed"/"merged" which provision mode does not.
        provision_only = sr.GUARDIAN_PROVISION_VERDICTS - sr.GUARDIAN_LAND_VERDICTS
        land_only = sr.GUARDIAN_LAND_VERDICTS - sr.GUARDIAN_PROVISION_VERDICTS
        assert "provisioned" in provision_only
        assert {"committed", "merged"} <= land_only

    def test_planner_verdicts_cover_all_continuation_cases(self):
        assert sr.PLANNER_VERDICTS == frozenset(
            {
                "next_work_item",
                "goal_complete",
                "needs_user_decision",
                "blocked_external",
            }
        )

    def test_every_transition_verdict_is_in_its_stage_vocabulary(self):
        for t in sr.TRANSITIONS:
            allowed = sr.allowed_verdicts(t.from_stage)
            assert t.verdict in allowed, (
                f"transition {t.from_stage}/{t.verdict} references a verdict "
                f"not declared in allowed_verdicts({t.from_stage!r})={sorted(allowed)}"
            )


# ---------------------------------------------------------------------------
# 3. Sink stages are terminal in the registry
# ---------------------------------------------------------------------------


class TestSinks:
    def test_terminal_is_terminal(self):
        assert sr.is_terminal(sr.TERMINAL) is True
        assert sr.is_terminal(sr.USER) is True

    def test_active_stages_are_not_terminal(self):
        for stage in sr.ACTIVE_STAGES:
            assert sr.is_terminal(stage) is False
            assert sr.is_active(stage) is True

    def test_sinks_have_no_outgoing_transitions(self):
        for sink in sr.SINK_STAGES:
            assert sr.outgoing(sink) == ()
            assert sr.allowed_verdicts(sink) == frozenset()

    def test_terminal_reachable_only_from_planner(self):
        terminal_entries = sr.incoming(sr.TERMINAL)
        assert terminal_entries, "TERMINAL must be reachable"
        for t in terminal_entries:
            assert t.from_stage == sr.PLANNER, (
                f"only planner may reach TERMINAL; saw {t.from_stage}"
            )

    def test_user_reachable_only_from_planner(self):
        user_entries = sr.incoming(sr.USER)
        assert user_entries, "USER must be reachable"
        for t in user_entries:
            assert t.from_stage == sr.PLANNER


# ---------------------------------------------------------------------------
# 4. Two-loop behavior
#
# Inner loop: implementer <-> reviewer converges via reviewer verdicts.
# Outer loop: guardian(land) -> planner -> (next_work_item) -> guardian(provision)
#             -> implementer -> reviewer -> guardian(land) -> ...
#
# These tests walk the graph using only next_stage so the behavior is pinned
# without any live dispatch path.
# ---------------------------------------------------------------------------


class TestInnerLoop:
    def test_implementer_to_reviewer_to_implementer_on_needs_changes(self):
        stage = sr.IMPLEMENTER
        stage = sr.next_stage(stage, "complete")
        assert stage == sr.REVIEWER
        stage = sr.next_stage(stage, "needs_changes")
        assert stage == sr.IMPLEMENTER

    def test_implementer_reviewer_converges_on_ready_for_guardian(self):
        stage = sr.IMPLEMENTER
        stage = sr.next_stage(stage, "complete")
        assert stage == sr.REVIEWER
        stage = sr.next_stage(stage, "ready_for_guardian")
        assert stage == sr.GUARDIAN_LAND

    def test_reviewer_blocked_by_plan_escapes_to_planner(self):
        assert sr.next_stage(sr.REVIEWER, "blocked_by_plan") == sr.PLANNER

    def test_inner_loop_can_iterate_multiple_rounds(self):
        # Walk three needs_changes rounds then land.
        stage = sr.IMPLEMENTER
        for _ in range(3):
            stage = sr.next_stage(stage, "complete")
            assert stage == sr.REVIEWER
            stage = sr.next_stage(stage, "needs_changes")
            assert stage == sr.IMPLEMENTER
        stage = sr.next_stage(stage, "complete")
        stage = sr.next_stage(stage, "ready_for_guardian")
        assert stage == sr.GUARDIAN_LAND


class TestOuterLoop:
    def test_full_outer_loop_planner_to_planner(self):
        # planner -> guardian(provision) -> implementer -> reviewer ->
        # guardian(land) -> planner
        stage = sr.PLANNER
        stage = sr.next_stage(stage, "next_work_item")
        assert stage == sr.GUARDIAN_PROVISION
        stage = sr.next_stage(stage, "provisioned")
        assert stage == sr.IMPLEMENTER
        stage = sr.next_stage(stage, "complete")
        assert stage == sr.REVIEWER
        stage = sr.next_stage(stage, "ready_for_guardian")
        assert stage == sr.GUARDIAN_LAND
        stage = sr.next_stage(stage, "committed")
        assert stage == sr.PLANNER

    def test_outer_loop_merged_also_returns_to_planner(self):
        stage = sr.next_stage(sr.GUARDIAN_LAND, "merged")
        assert stage == sr.PLANNER

    def test_planner_post_landing_continuation_to_next_work_item(self):
        # After landing, planner decides next_work_item and the outer loop
        # continues without user intervention.
        stage = sr.next_stage(sr.GUARDIAN_LAND, "committed")
        assert stage == sr.PLANNER
        stage = sr.next_stage(stage, "next_work_item")
        assert stage == sr.GUARDIAN_PROVISION

    def test_planner_owns_goal_complete_decision(self):
        # Only planner may route to TERMINAL via goal_complete. Reviewer and
        # guardian cannot reach TERMINAL directly.
        assert sr.next_stage(sr.PLANNER, "goal_complete") == sr.TERMINAL
        # Make sure no other active stage can reach TERMINAL.
        for stage in sr.ACTIVE_STAGES - {sr.PLANNER}:
            for verdict in sr.allowed_verdicts(stage):
                target = sr.next_stage(stage, verdict)
                assert target != sr.TERMINAL, (
                    f"{stage}/{verdict} reaches TERMINAL without going through planner"
                )

    def test_planner_owns_user_decision_boundary(self):
        assert sr.next_stage(sr.PLANNER, "needs_user_decision") == sr.USER
        for stage in sr.ACTIVE_STAGES - {sr.PLANNER}:
            for verdict in sr.allowed_verdicts(stage):
                target = sr.next_stage(stage, verdict)
                assert target != sr.USER, (
                    f"{stage}/{verdict} reaches USER without going through planner"
                )


# ---------------------------------------------------------------------------
# 5. Reachability — every active stage is reachable and has at least one exit
# ---------------------------------------------------------------------------


class TestReachability:
    def test_every_active_stage_has_outgoing_transitions(self):
        for stage in sr.ACTIVE_STAGES:
            assert sr.outgoing(stage), (
                f"{stage} has no outgoing transitions — dead stage"
            )

    def test_every_active_stage_is_reachable(self):
        # Every active stage except planner must have an incoming edge.
        # Planner is the entry point; it does not require one for the shadow
        # registry to be well-formed.
        for stage in sr.ACTIVE_STAGES - {sr.PLANNER}:
            assert sr.incoming(stage), (
                f"{stage} has no incoming transitions — unreachable"
            )

    def test_guardian_provision_reachable_from_planner_only(self):
        for t in sr.incoming(sr.GUARDIAN_PROVISION):
            assert t.from_stage == sr.PLANNER, (
                f"guardian(provision) entered from {t.from_stage}; "
                "only planner may initiate provisioning"
            )

    def test_guardian_land_reachable_from_reviewer_only(self):
        for t in sr.incoming(sr.GUARDIAN_LAND):
            assert t.from_stage == sr.REVIEWER, (
                f"guardian(land) entered from {t.from_stage}; "
                "only reviewer may gate landing"
            )


# ---------------------------------------------------------------------------
# 6. next_stage purity and negative behavior
# ---------------------------------------------------------------------------


class TestNextStageNegative:
    def test_unknown_stage_returns_none(self):
        assert sr.next_stage("does_not_exist", "complete") is None

    def test_unknown_verdict_returns_none(self):
        assert sr.next_stage(sr.IMPLEMENTER, "bogus") is None

    def test_sink_stage_has_no_outgoing(self):
        assert sr.next_stage(sr.TERMINAL, "goal_complete") is None
        assert sr.next_stage(sr.USER, "next_work_item") is None

    def test_next_stage_does_not_raise_on_bad_input(self):
        # Pure function contract: no exceptions for any string input.
        assert sr.next_stage("", "") is None
        assert sr.next_stage("planner", "") is None
        assert sr.next_stage("", "complete") is None

    def test_tester_is_not_in_active_stages(self):
        # The cutover removes tester — the shadow registry must not include it.
        assert "tester" not in sr.ACTIVE_STAGES
        assert "tester" not in sr.ALL_STAGES
        assert sr.next_stage("tester", "ready_for_guardian") is None


# ---------------------------------------------------------------------------
# 7. Goal and work-item contract scaffolding
# ---------------------------------------------------------------------------


class TestContractScaffolding:
    def test_goal_contract_accepts_legal_statuses(self):
        for status in GOAL_STATUSES:
            g = GoalContract(
                goal_id="g-1",
                desired_end_state="ship the widget",
                status=status,
            )
            assert g.status == status

    def test_goal_contract_rejects_unknown_status(self):
        with pytest.raises(ValueError):
            GoalContract(
                goal_id="g-1",
                desired_end_state="ship the widget",
                status="not_a_real_status",
            )

    def test_work_item_contract_accepts_legal_statuses(self):
        for status in WORK_ITEM_STATUSES:
            wi = WorkItemContract(
                work_item_id="wi-1",
                goal_id="g-1",
                title="first slice",
                status=status,
            )
            assert wi.status == status

    def test_work_item_contract_rejects_unknown_status(self):
        with pytest.raises(ValueError):
            WorkItemContract(
                work_item_id="wi-1",
                goal_id="g-1",
                title="first slice",
                status="landing",
            )

    def test_work_item_links_to_goal(self):
        goal = GoalContract(goal_id="g-42", desired_end_state="...")
        wi = WorkItemContract(
            work_item_id="wi-1",
            goal_id=goal.goal_id,
            title="first slice",
        )
        assert wi.goal_id == goal.goal_id

    def test_scope_manifest_is_immutable_and_defaults_empty(self):
        sm = ScopeManifest()
        assert sm.allowed_paths == ()
        assert sm.required_paths == ()
        assert sm.forbidden_paths == ()
        assert sm.state_domains == ()
        with pytest.raises(Exception):
            sm.allowed_paths = ("x",)  # type: ignore[misc]

    def test_evaluation_contract_defaults(self):
        ec = EvaluationContract()
        assert ec.required_tests == ()
        assert ec.required_evidence == ()
        assert ec.rollback_boundary == ""
        assert ec.acceptance_notes == ""

    def test_work_item_carries_scope_and_evaluation(self):
        wi = WorkItemContract(
            work_item_id="wi-1",
            goal_id="g-1",
            title="first slice",
            scope=ScopeManifest(
                allowed_paths=("runtime/core/stage_registry.py",),
                state_domains=("stage_registry",),
            ),
            evaluation=EvaluationContract(
                required_tests=("tests/runtime/test_stage_registry.py",),
                rollback_boundary="revert runtime/core/stage_registry.py",
            ),
        )
        assert wi.scope.allowed_paths == ("runtime/core/stage_registry.py",)
        assert wi.evaluation.required_tests == (
            "tests/runtime/test_stage_registry.py",
        )


# ---------------------------------------------------------------------------
# 8. Shadow-mode isolation — the registry must not own any live routing
#
# The shadow observer wiring (runtime/core/dispatch_shadow.py) is allowed to
# import stage_registry, and dispatch_engine is allowed to import the shadow
# observer. What must NOT happen:
#   * dispatch_engine imports stage_registry directly (would mean live
#     routing consults the shadow table).
#   * completions imports stage_registry or dispatch_shadow (the live routing
#     table in completions.determine_next_role must stay untouched).
# ---------------------------------------------------------------------------


class TestShadowIsolation:
    def test_dispatch_engine_does_not_import_stage_registry_directly(self):
        # dispatch_engine may import dispatch_shadow (the seam); it must not
        # import stage_registry directly, which would mean live routing
        # consults the shadow table.
        import importlib
        import inspect

        dispatch_engine = importlib.import_module("runtime.core.dispatch_engine")
        src = inspect.getsource(dispatch_engine)
        assert "from runtime.core import stage_registry" not in src
        assert "from runtime.core.stage_registry" not in src
        assert "runtime.core.stage_registry" not in src
        assert "from runtime.core.contracts" not in src, (
            "dispatch_engine.py must not import contracts while they are in "
            "shadow mode"
        )

    def test_completions_does_not_import_shadow_or_contracts(self):
        """completions.py may import stage_registry (for reviewer verdicts
        and reviewer routing derivation via next_stage), but must not import
        dispatch_shadow or contracts which remain shadow-only."""
        import importlib
        import inspect

        completions = importlib.import_module("runtime.core.completions")
        src = inspect.getsource(completions)
        assert "dispatch_shadow" not in src
        assert "from runtime.core.contracts" not in src
