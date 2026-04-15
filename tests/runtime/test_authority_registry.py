"""Tests for runtime/core/authority_registry.py.

@decision DEC-CLAUDEX-AUTHORITY-REGISTRY-TESTS-001
Title: Authority/capability vocabulary, role boundaries, and operational-fact uniqueness are pinned
Status: accepted (Phase 3 — capability contracts and policy-engine wiring live)
Rationale: CUTOVER_PLAN §5 Capability Model and §Authority Map are
  load-bearing invariants for every later cutover slice. If any future
  slice widens the capability vocabulary, loosens reviewer read-only
  enforcement, or lets two modules claim ownership of the same
  operational fact, these tests must fail immediately so the drift is
  caught at invariant-check time rather than at live-policy time.

  Scope of this test module:

    1. Exact capability vocabulary — set equality, not subset.
    2. Reviewer is mechanically read-only — has ``read_only_review``
       and lacks every write/land/provision/governance/config
       capability.
    3. Planner, implementer, and the two guardian modes have distinct
       capability boundaries that match the CUTOVER_PLAN's target role
       intents.
    4. Each capability has an intended uniqueness profile (e.g.
       exactly one stage may land git, exactly one may provision a
       worktree, exactly one may write source, exactly one may write
       governance, exactly one is read-only review).
    5. The operational-fact authority table gives exactly one owner
       per declared fact, every owner module is importable, and the
       table is closed under the shadow-kernel surfaces that currently
       exist.
    6. Import discipline: authority_registry must not import live
       routing modules (dispatch_engine, completions) or hooks/settings
       machinery. It IS imported by the live policy engine and
       enforcement_config — that wiring is intentional as of Phase 3.
    7. Stage capability contracts (Phase 3): fail-closed resolution,
       complete capability partition, reviewer read-only enforcement,
       stage distinctness, and prompt-pack projection determinism.
"""

from __future__ import annotations

import ast
import importlib
import inspect

import pytest

from runtime.core import authority_registry as ar
from runtime.core import stage_registry as sr


def _imported_module_names(module) -> set[str]:
    """Return the set of dotted module names actually imported by ``module``.

    Uses ``ast`` to walk the module source for ``Import`` and
    ``ImportFrom`` nodes. This is more precise than substring search,
    which would incorrectly match docstring prose that mentions module
    names without importing them.
    """
    tree = ast.parse(inspect.getsource(module))
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                names.add(alias.name)
        elif isinstance(node, ast.ImportFrom):
            module_name = node.module or ""
            # Track both the base module ("runtime.core") and each
            # imported name under it ("runtime.core.stage_registry").
            if module_name:
                names.add(module_name)
                for alias in node.names:
                    names.add(f"{module_name}.{alias.name}")
    return names


# ---------------------------------------------------------------------------
# 1. Exact capability vocabulary
# ---------------------------------------------------------------------------


class TestCapabilityVocabulary:
    def test_capabilities_set_is_exactly_the_cutover_plan_minimum(self):
        # CUTOVER_PLAN §5 "Capability Model" — this assertion is set
        # equality, not a subset, so any future slice that adds a new
        # capability MUST update this test in the same bundle.
        expected = {
            "can_write_source",
            "can_write_governance",
            "can_land_git",
            "can_provision_worktree",
            "can_set_control_config",
            "read_only_review",
            "can_emit_dispatch_transition",
        }
        assert set(ar.CAPABILITIES) == expected

    def test_capability_constants_are_exported_individually(self):
        # Every capability string must be accessible as a named constant
        # so call sites do not have to use string literals.
        assert ar.CAN_WRITE_SOURCE == "can_write_source"
        assert ar.CAN_WRITE_GOVERNANCE == "can_write_governance"
        assert ar.CAN_LAND_GIT == "can_land_git"
        assert ar.CAN_PROVISION_WORKTREE == "can_provision_worktree"
        assert ar.CAN_SET_CONTROL_CONFIG == "can_set_control_config"
        assert ar.READ_ONLY_REVIEW == "read_only_review"
        assert ar.CAN_EMIT_DISPATCH_TRANSITION == "can_emit_dispatch_transition"

    def test_capabilities_frozenset_is_immutable(self):
        with pytest.raises(AttributeError):
            ar.CAPABILITIES.add("rogue_capability")  # type: ignore[attr-defined]


# ---------------------------------------------------------------------------
# 2. Stage → capability mapping shape
# ---------------------------------------------------------------------------


class TestStageCapabilityMapping:
    def test_mapping_covers_every_active_stage(self):
        assert set(ar.STAGE_CAPABILITIES.keys()) == set(sr.ACTIVE_STAGES)

    def test_mapping_does_not_include_sink_stages(self):
        for sink in sr.SINK_STAGES:
            assert sink not in ar.STAGE_CAPABILITIES

    def test_every_declared_capability_is_in_vocabulary(self):
        for stage, caps in ar.STAGE_CAPABILITIES.items():
            for cap in caps:
                assert cap in ar.CAPABILITIES, (
                    f"{stage} declares unknown capability {cap!r}"
                )

    def test_every_active_stage_can_emit_dispatch_transition(self):
        # The stage graph is driven by verdict emission — every active
        # stage must be able to emit transitions.
        for stage in sr.ACTIVE_STAGES:
            assert ar.stage_has_capability(stage, ar.CAN_EMIT_DISPATCH_TRANSITION)


# ---------------------------------------------------------------------------
# 3. Reviewer read-only invariant (CUTOVER_PLAN §W4 + §Invariants #6)
# ---------------------------------------------------------------------------


class TestReviewerReadOnly:
    def test_reviewer_has_read_only_review(self):
        assert ar.stage_has_capability(sr.REVIEWER, ar.READ_ONLY_REVIEW)

    def test_reviewer_cannot_write_source(self):
        assert not ar.stage_has_capability(sr.REVIEWER, ar.CAN_WRITE_SOURCE)

    def test_reviewer_cannot_write_governance(self):
        assert not ar.stage_has_capability(sr.REVIEWER, ar.CAN_WRITE_GOVERNANCE)

    def test_reviewer_cannot_land_git(self):
        assert not ar.stage_has_capability(sr.REVIEWER, ar.CAN_LAND_GIT)

    def test_reviewer_cannot_provision_worktree(self):
        assert not ar.stage_has_capability(sr.REVIEWER, ar.CAN_PROVISION_WORKTREE)

    def test_reviewer_cannot_set_control_config(self):
        assert not ar.stage_has_capability(sr.REVIEWER, ar.CAN_SET_CONTROL_CONFIG)

    def test_reviewer_may_emit_dispatch_verdicts(self):
        # ready_for_guardian / needs_changes / blocked_by_plan are
        # dispatch transitions — reviewer must be able to emit them.
        assert ar.stage_has_capability(
            sr.REVIEWER, ar.CAN_EMIT_DISPATCH_TRANSITION
        )

    def test_reviewer_capability_set_is_exactly_two_items(self):
        assert ar.capabilities_for(sr.REVIEWER) == frozenset(
            {ar.READ_ONLY_REVIEW, ar.CAN_EMIT_DISPATCH_TRANSITION}
        )


# ---------------------------------------------------------------------------
# 4. Planner / implementer / guardian boundary enforcement
# ---------------------------------------------------------------------------


class TestRoleBoundaries:
    def test_planner_owns_governance_and_control_config(self):
        caps = ar.capabilities_for(sr.PLANNER)
        assert ar.CAN_WRITE_GOVERNANCE in caps
        assert ar.CAN_SET_CONTROL_CONFIG in caps
        assert ar.CAN_EMIT_DISPATCH_TRANSITION in caps
        # Planner does NOT write source, land git, provision worktrees,
        # or act as a read-only reviewer.
        assert ar.CAN_WRITE_SOURCE not in caps
        assert ar.CAN_LAND_GIT not in caps
        assert ar.CAN_PROVISION_WORKTREE not in caps
        assert ar.READ_ONLY_REVIEW not in caps

    def test_implementer_owns_source_only(self):
        caps = ar.capabilities_for(sr.IMPLEMENTER)
        assert ar.CAN_WRITE_SOURCE in caps
        assert ar.CAN_EMIT_DISPATCH_TRANSITION in caps
        # Everything else must be absent.
        for forbidden in (
            ar.CAN_WRITE_GOVERNANCE,
            ar.CAN_LAND_GIT,
            ar.CAN_PROVISION_WORKTREE,
            ar.CAN_SET_CONTROL_CONFIG,
            ar.READ_ONLY_REVIEW,
        ):
            assert forbidden not in caps, (
                f"implementer unexpectedly carries {forbidden!r}"
            )

    def test_guardian_provision_owns_worktree_provisioning_only(self):
        caps = ar.capabilities_for(sr.GUARDIAN_PROVISION)
        assert ar.CAN_PROVISION_WORKTREE in caps
        assert ar.CAN_EMIT_DISPATCH_TRANSITION in caps
        # Provisioning mode must NOT be allowed to land git — landing
        # is guardian:land's exclusive capability.
        assert ar.CAN_LAND_GIT not in caps
        # And everything else must be absent.
        for forbidden in (
            ar.CAN_WRITE_SOURCE,
            ar.CAN_WRITE_GOVERNANCE,
            ar.CAN_SET_CONTROL_CONFIG,
            ar.READ_ONLY_REVIEW,
        ):
            assert forbidden not in caps

    def test_guardian_land_owns_git_landing_only(self):
        caps = ar.capabilities_for(sr.GUARDIAN_LAND)
        assert ar.CAN_LAND_GIT in caps
        assert ar.CAN_EMIT_DISPATCH_TRANSITION in caps
        # Land mode must NOT be allowed to provision — provisioning is
        # guardian:provision's exclusive capability.
        assert ar.CAN_PROVISION_WORKTREE not in caps
        for forbidden in (
            ar.CAN_WRITE_SOURCE,
            ar.CAN_WRITE_GOVERNANCE,
            ar.CAN_SET_CONTROL_CONFIG,
            ar.READ_ONLY_REVIEW,
        ):
            assert forbidden not in caps

    def test_guardian_modes_have_disjoint_exclusive_capabilities(self):
        provision = ar.capabilities_for(sr.GUARDIAN_PROVISION)
        land = ar.capabilities_for(sr.GUARDIAN_LAND)
        # The one cap they share is the dispatch-emit cap. The
        # exclusive caps (provision vs land) must be disjoint.
        shared_exclusive = (provision - {ar.CAN_EMIT_DISPATCH_TRANSITION}) & (
            land - {ar.CAN_EMIT_DISPATCH_TRANSITION}
        )
        assert shared_exclusive == frozenset(), (
            f"guardian modes share exclusive capabilities: {shared_exclusive}"
        )


# ---------------------------------------------------------------------------
# 5. Capability exclusivity — exactly one stage per exclusive capability
# ---------------------------------------------------------------------------


class TestCapabilityExclusivity:
    def test_exactly_one_stage_may_write_source(self):
        assert ar.stages_with_capability(ar.CAN_WRITE_SOURCE) == (sr.IMPLEMENTER,)

    def test_exactly_one_stage_may_land_git(self):
        assert ar.stages_with_capability(ar.CAN_LAND_GIT) == (sr.GUARDIAN_LAND,)

    def test_exactly_one_stage_may_provision_worktree(self):
        assert ar.stages_with_capability(ar.CAN_PROVISION_WORKTREE) == (
            sr.GUARDIAN_PROVISION,
        )

    def test_exactly_one_stage_may_write_governance(self):
        assert ar.stages_with_capability(ar.CAN_WRITE_GOVERNANCE) == (sr.PLANNER,)

    def test_exactly_one_stage_may_set_control_config(self):
        assert ar.stages_with_capability(ar.CAN_SET_CONTROL_CONFIG) == (sr.PLANNER,)

    def test_exactly_one_stage_is_read_only_review(self):
        assert ar.stages_with_capability(ar.READ_ONLY_REVIEW) == (sr.REVIEWER,)

    def test_every_active_stage_emits_dispatch_transitions(self):
        # This is the one non-exclusive cap: every active stage must
        # have it, so stages_with_capability returns all five.
        emitters = ar.stages_with_capability(ar.CAN_EMIT_DISPATCH_TRANSITION)
        assert set(emitters) == set(sr.ACTIVE_STAGES)
        assert len(emitters) == 5


# ---------------------------------------------------------------------------
# 6. capabilities_for / stage_has_capability edge cases
# ---------------------------------------------------------------------------


class TestCapabilityLookupPurity:
    def test_unknown_stage_returns_empty_set(self):
        assert ar.capabilities_for("does_not_exist") == frozenset()

    def test_sink_stages_have_no_capabilities(self):
        for sink in sr.SINK_STAGES:
            assert ar.capabilities_for(sink) == frozenset()

    def test_stage_has_capability_returns_false_for_unknown_stage(self):
        assert ar.stage_has_capability("ghost_stage", ar.CAN_WRITE_SOURCE) is False

    def test_stage_has_capability_returns_false_for_unknown_capability(self):
        assert ar.stage_has_capability(sr.PLANNER, "can_summon_dragons") is False

    def test_lookup_never_raises_on_any_input(self):
        # Pure lookup contract: never raises.
        ar.capabilities_for("")
        ar.capabilities_for(None)  # type: ignore[arg-type]
        ar.stage_has_capability("", "")
        ar.stages_with_capability("")
        ar.stages_with_capability(None)  # type: ignore[arg-type]


# ---------------------------------------------------------------------------
# 7. Live-role alias resolution (Phase 3)
# ---------------------------------------------------------------------------


class TestLiveRoleAliases:
    """_LIVE_ROLE_ALIASES are resolved by capabilities_for() so policies
    can use capability gates without handling harness-level role variants."""

    def test_Plan_alias_has_write_governance(self):
        """'Plan' (SubagentStart capitalized variant) resolves to planner caps."""
        caps = ar.capabilities_for("Plan")
        assert ar.CAN_WRITE_GOVERNANCE in caps

    def test_Plan_alias_does_not_have_write_source(self):
        """'Plan' must not carry CAN_WRITE_SOURCE."""
        caps = ar.capabilities_for("Plan")
        assert ar.CAN_WRITE_SOURCE not in caps

    def test_Plan_alias_matches_planner_capabilities(self):
        """'Plan' caps must exactly equal canonical planner caps."""
        assert ar.capabilities_for("Plan") == ar.capabilities_for(sr.PLANNER)

    def test_guardian_alias_has_provision_worktree(self):
        """Live 'guardian' role must resolve to CAN_PROVISION_WORKTREE."""
        caps = ar.capabilities_for("guardian")
        assert ar.CAN_PROVISION_WORKTREE in caps

    def test_guardian_alias_does_not_have_write_source(self):
        """'guardian' alias must not carry CAN_WRITE_SOURCE."""
        assert ar.CAN_WRITE_SOURCE not in ar.capabilities_for("guardian")

    def test_guardian_alias_does_not_have_write_governance(self):
        """'guardian' alias must not carry CAN_WRITE_GOVERNANCE."""
        assert ar.CAN_WRITE_GOVERNANCE not in ar.capabilities_for("guardian")

    def test_alias_lookup_returns_frozenset(self):
        """capabilities_for() must return a frozenset for aliased roles."""
        assert isinstance(ar.capabilities_for("Plan"), frozenset)
        assert isinstance(ar.capabilities_for("guardian"), frozenset)

    def test_unknown_alias_returns_empty_frozenset(self):
        """Non-alias, non-stage strings still return empty frozenset."""
        assert ar.capabilities_for("Bash") == frozenset()
        assert ar.capabilities_for("tester") == frozenset()


# ---------------------------------------------------------------------------
# 8. Operational-fact authority table
# ---------------------------------------------------------------------------


class TestAuthorityTable:
    def test_every_fact_name_is_unique(self):
        names = [f.name for f in ar.AUTHORITY_TABLE]
        assert len(names) == len(set(names)), (
            f"duplicate fact names in authority table: {names}"
        )

    def test_every_declared_owner_module_is_importable(self):
        # CUTOVER_PLAN constraint: "Do not invent ownership for future
        # modules that do not exist yet." Every owner must resolve now.
        for fact in ar.AUTHORITY_TABLE:
            try:
                importlib.import_module(fact.owner_module)
            except ImportError as exc:
                pytest.fail(
                    f"authority table declares owner {fact.owner_module!r} "
                    f"for fact {fact.name!r}, but the module is not "
                    f"importable: {exc}"
                )

    def test_stage_transitions_owner_is_stage_registry(self):
        assert ar.owner_of("stage_transitions") == "runtime.core.stage_registry"

    def test_capabilities_owner_is_this_module(self):
        assert ar.owner_of("role_capabilities") == "runtime.core.authority_registry"

    def test_authority_table_is_self_owning(self):
        # The authority table itself is an operational fact whose sole
        # owner must be this module — otherwise the closure breaks.
        assert ar.owner_of("authority_table") == "runtime.core.authority_registry"

    def test_goal_and_work_item_shapes_owner_is_contracts(self):
        assert ar.owner_of("goal_contract_shape") == "runtime.core.contracts"
        assert ar.owner_of("work_item_contract_shape") == "runtime.core.contracts"

    def test_shadow_decision_mapping_owner_is_dispatch_shadow(self):
        assert ar.owner_of("shadow_decision_mapping") == "runtime.core.dispatch_shadow"

    def test_shadow_parity_reporting_owner_is_shadow_parity(self):
        assert ar.owner_of("shadow_parity_reporting") == "runtime.core.shadow_parity"

    def test_hook_wiring_owner_is_hook_manifest(self):
        # Phase 2 bookkeeping: once runtime.core.hook_manifest and the
        # cc-policy hook validate-settings CLI landed, the authority
        # table gained an explicit ``hook_wiring`` fact owned by the
        # manifest module. CUTOVER_PLAN §Authority Map line 515.
        assert ar.owner_of("hook_wiring") == "runtime.core.hook_manifest"

    def test_hook_wiring_fact_is_declared_exactly_once(self):
        hook_wiring_facts = [
            f for f in ar.AUTHORITY_TABLE if f.name == "hook_wiring"
        ]
        assert len(hook_wiring_facts) == 1
        assert hook_wiring_facts[0].owner_module == "runtime.core.hook_manifest"
        # Description must clearly state that this covers repo hook
        # wiring declarations — a later slice should not silently
        # broaden the scope.
        desc = hook_wiring_facts[0].description.lower()
        assert "hook" in desc
        assert "wiring" in desc or "manifest" in desc or "settings.json" in desc

    def test_prompt_pack_layers_owner_is_prompt_pack(self):
        # Phase 2 bookkeeping: once runtime.core.prompt_pack landed as
        # the bootstrap compiler for runtime-compiled prompt packs, the
        # authority table gained an explicit ``prompt_pack_layers``
        # fact owned by the compiler module. CUTOVER_PLAN §Runtime-
        # Compiled Prompt Packs + Phase 2 exit criterion on compiled
        # runtime context.
        assert ar.owner_of("prompt_pack_layers") == "runtime.core.prompt_pack"

    def test_prompt_pack_layers_fact_is_declared_exactly_once(self):
        prompt_pack_facts = [
            f for f in ar.AUTHORITY_TABLE if f.name == "prompt_pack_layers"
        ]
        assert len(prompt_pack_facts) == 1
        assert (
            prompt_pack_facts[0].owner_module == "runtime.core.prompt_pack"
        )
        # Description must clearly state that this covers the
        # canonical prompt-pack layer vocabulary / ordering /
        # compilation contract — a later slice should not silently
        # broaden the scope.
        desc = prompt_pack_facts[0].description.lower()
        assert "prompt" in desc
        assert "layer" in desc
        # Must reference either the vocabulary, the ordering, or the
        # compilation contract so the intent is explicit.
        assert (
            "canonical" in desc
            or "ordering" in desc
            or "compil" in desc
            or "vocabulary" in desc
        )

    def test_unknown_fact_returns_none(self):
        assert ar.owner_of("future_decision_registry") is None
        assert ar.owner_of("") is None

    def test_facts_owned_by_contracts_returns_both_contract_facts(self):
        assert set(ar.facts_owned_by("runtime.core.contracts")) == {
            "goal_contract_shape",
            "work_item_contract_shape",
        }

    def test_facts_owned_by_unknown_module_is_empty(self):
        assert ar.facts_owned_by("runtime.core.does_not_exist") == ()

    def test_declared_facts_in_order_matches_table(self):
        declared = ar.declared_facts()
        assert declared == tuple(f.name for f in ar.AUTHORITY_TABLE)

    def test_owner_index_matches_table(self):
        index = ar.owner_index()
        assert index == {f.name: f.owner_module for f in ar.AUTHORITY_TABLE}

    def test_authority_table_does_not_declare_future_owners(self):
        # Guard rail: the instruction says "Do not invent ownership for
        # future modules that do not exist yet." Enumerate known-future
        # owners (from CUTOVER_PLAN end-state) and assert NONE appear
        # in the table. If a later slice genuinely implements one of
        # these, that slice is responsible for updating both the table
        # and this test in one bundle.
        #
        # ``runtime.core.hook_manifest`` used to appear in this list
        # but was promoted to a concrete owner in the Phase 2
        # ``hook_wiring`` slice — do not re-add it here.
        #
        # ``runtime.core.prompt_pack`` was similarly promoted to a
        # concrete owner in the Phase 2 ``prompt_pack_layers`` slice
        # once the runtime-compiled prompt-pack compiler landed —
        # do not re-add it here either.
        future_owners = {
            "runtime.core.reviewer",
            "runtime.core.reviewer_findings",
            "runtime.core.projection_reflow",
            "runtime.core.decision_registry",
            "runtime.core.work_registry",
        }
        declared_owners = {f.owner_module for f in ar.AUTHORITY_TABLE}
        overlap = declared_owners & future_owners
        assert overlap == set(), (
            f"authority table contains future-owner placeholders: {overlap}"
        )


# ---------------------------------------------------------------------------
# 8. Stage capability contracts (Phase 3 — Capability-Gated Policy Model)
#
# StageCapabilityContract is the projectable form of STAGE_CAPABILITIES.
# These tests pin the invariants declared in DEC-CLAUDEX-CAPABILITY-CONTRACT-001:
# fail-closed resolution, complete partition, reviewer read-only enforcement,
# stage distinctness, and prompt-pack projection determinism.
# ---------------------------------------------------------------------------


class TestCapabilityContractResolution:
    """Capabilities resolve from stage identity through one authority."""

    def test_all_active_stages_produce_contracts(self):
        for stage in sr.ACTIVE_STAGES:
            contract = ar.resolve_contract(stage)
            assert contract is not None, (
                f"active stage {stage!r} returned None contract"
            )

    def test_unknown_stage_fails_closed(self):
        assert ar.resolve_contract("unknown_stage") is None

    def test_empty_string_fails_closed(self):
        assert ar.resolve_contract("") is None

    def test_none_input_fails_closed(self):
        # resolve_contract should handle None gracefully (fail-closed).
        assert ar.resolve_contract(None) is None  # type: ignore[arg-type]

    def test_sink_stages_fail_closed(self):
        for sink in sr.SINK_STAGES:
            assert ar.resolve_contract(sink) is None, (
                f"sink stage {sink!r} should not produce a contract"
            )

    def test_live_role_alias_resolves_to_canonical_contract(self):
        """'Plan' alias produces the same contract as 'planner'."""
        assert ar.resolve_contract("Plan") == ar.resolve_contract(sr.PLANNER)

    def test_guardian_alias_resolves_to_provision_contract(self):
        """'guardian' alias produces the same contract as 'guardian:provision'."""
        assert ar.resolve_contract("guardian") == ar.resolve_contract(
            sr.GUARDIAN_PROVISION
        )

    def test_contract_stage_id_is_canonical(self):
        """Aliased lookups return contracts with canonical stage_id, not the alias."""
        plan_contract = ar.resolve_contract("Plan")
        assert plan_contract is not None
        assert plan_contract.stage_id == sr.PLANNER


class TestCapabilityContractPartition:
    """granted ∪ denied = CAPABILITIES and granted ∩ denied = ∅."""

    def test_granted_union_denied_equals_capabilities(self):
        for stage in sr.ACTIVE_STAGES:
            contract = ar.resolve_contract(stage)
            assert contract is not None
            assert contract.granted | contract.denied == ar.CAPABILITIES, (
                f"{stage}: granted ∪ denied ≠ CAPABILITIES"
            )

    def test_granted_intersection_denied_is_empty(self):
        for stage in sr.ACTIVE_STAGES:
            contract = ar.resolve_contract(stage)
            assert contract is not None
            assert contract.granted & contract.denied == frozenset(), (
                f"{stage}: granted ∩ denied is non-empty"
            )


class TestReviewerContractReadOnly:
    """Reviewer is mechanically read-only: no write/source/git landing."""

    def test_reviewer_contract_is_read_only(self):
        contract = ar.resolve_contract(sr.REVIEWER)
        assert contract is not None
        assert contract.read_only is True

    def test_reviewer_denies_write_source(self):
        contract = ar.resolve_contract(sr.REVIEWER)
        assert contract is not None
        assert ar.CAN_WRITE_SOURCE in contract.denied

    def test_reviewer_denies_land_git(self):
        contract = ar.resolve_contract(sr.REVIEWER)
        assert contract is not None
        assert ar.CAN_LAND_GIT in contract.denied

    def test_reviewer_denies_provision_worktree(self):
        contract = ar.resolve_contract(sr.REVIEWER)
        assert contract is not None
        assert ar.CAN_PROVISION_WORKTREE in contract.denied

    def test_reviewer_denies_write_governance(self):
        contract = ar.resolve_contract(sr.REVIEWER)
        assert contract is not None
        assert ar.CAN_WRITE_GOVERNANCE in contract.denied

    def test_reviewer_denies_set_control_config(self):
        contract = ar.resolve_contract(sr.REVIEWER)
        assert contract is not None
        assert ar.CAN_SET_CONTROL_CONFIG in contract.denied

    def test_reviewer_grants_only_read_only_and_dispatch(self):
        contract = ar.resolve_contract(sr.REVIEWER)
        assert contract is not None
        assert contract.granted == frozenset(
            {ar.READ_ONLY_REVIEW, ar.CAN_EMIT_DISPATCH_TRANSITION}
        )

    def test_non_reviewer_contracts_are_not_read_only(self):
        for stage in sr.ACTIVE_STAGES:
            if stage == sr.REVIEWER:
                continue
            contract = ar.resolve_contract(stage)
            assert contract is not None
            assert contract.read_only is False, (
                f"{stage} should not be read-only"
            )


class TestContractDistinctness:
    """Planner, guardian:provision, and guardian:land produce distinct contracts."""

    def test_planner_and_guardian_provision_are_distinct(self):
        planner = ar.resolve_contract(sr.PLANNER)
        g_prov = ar.resolve_contract(sr.GUARDIAN_PROVISION)
        assert planner is not None and g_prov is not None
        assert planner.granted != g_prov.granted

    def test_planner_and_guardian_land_are_distinct(self):
        planner = ar.resolve_contract(sr.PLANNER)
        g_land = ar.resolve_contract(sr.GUARDIAN_LAND)
        assert planner is not None and g_land is not None
        assert planner.granted != g_land.granted

    def test_guardian_provision_and_land_are_distinct(self):
        g_prov = ar.resolve_contract(sr.GUARDIAN_PROVISION)
        g_land = ar.resolve_contract(sr.GUARDIAN_LAND)
        assert g_prov is not None and g_land is not None
        assert g_prov.granted != g_land.granted

    def test_all_five_contracts_have_unique_granted_sets(self):
        contracts = ar.all_contracts()
        granted_sets = [c.granted for c in contracts]
        # Each granted frozenset is a valid dict key (hashable).
        assert len(set(granted_sets)) == len(granted_sets), (
            "two active stages share identical granted capability sets"
        )


class TestContractDeterminism:
    """Contracts are deterministic enough to feed prompt-pack compilation."""

    def test_resolve_contract_is_deterministic(self):
        for stage in sr.ACTIVE_STAGES:
            c1 = ar.resolve_contract(stage)
            c2 = ar.resolve_contract(stage)
            assert c1 == c2

    def test_all_contracts_order_is_stable(self):
        contracts_a = ar.all_contracts()
        contracts_b = ar.all_contracts()
        assert contracts_a == contracts_b

    def test_all_contracts_returns_five_in_canonical_order(self):
        contracts = ar.all_contracts()
        assert len(contracts) == 5
        assert contracts[0].stage_id == sr.PLANNER
        assert contracts[1].stage_id == sr.GUARDIAN_PROVISION
        assert contracts[2].stage_id == sr.IMPLEMENTER
        assert contracts[3].stage_id == sr.REVIEWER
        assert contracts[4].stage_id == sr.GUARDIAN_LAND

    def test_prompt_projection_is_json_serializable(self):
        import json

        for stage in sr.ACTIVE_STAGES:
            contract = ar.resolve_contract(stage)
            assert contract is not None
            projection = contract.as_prompt_projection()
            serialized = json.dumps(projection, sort_keys=True)
            assert isinstance(serialized, str)

    def test_prompt_projection_is_deterministic(self):
        import json

        for stage in sr.ACTIVE_STAGES:
            c1 = ar.resolve_contract(stage)
            c2 = ar.resolve_contract(stage)
            assert c1 is not None and c2 is not None
            s1 = json.dumps(c1.as_prompt_projection(), sort_keys=True)
            s2 = json.dumps(c2.as_prompt_projection(), sort_keys=True)
            assert s1 == s2, f"{stage}: projection not deterministic"

    def test_prompt_projection_lists_are_sorted(self):
        for stage in sr.ACTIVE_STAGES:
            contract = ar.resolve_contract(stage)
            assert contract is not None
            proj = contract.as_prompt_projection()
            assert proj["granted"] == sorted(proj["granted"])
            assert proj["denied"] == sorted(proj["denied"])

    def test_prompt_projection_contains_required_keys(self):
        for stage in sr.ACTIVE_STAGES:
            contract = ar.resolve_contract(stage)
            assert contract is not None
            proj = contract.as_prompt_projection()
            assert set(proj.keys()) == {"stage", "granted", "denied", "read_only"}


# ---------------------------------------------------------------------------
# 9. Import discipline
#
# authority_registry must not import live routing modules
# (dispatch_engine, completions) or hooks/settings machinery. It IS
# imported by the live policy engine and enforcement_config — that
# wiring is intentional (Phase 3). Import inspection via AST walk.
# ---------------------------------------------------------------------------


class TestImportDiscipline:
    def test_authority_registry_does_not_import_forbidden_modules(self):
        # authority_registry must stay dependency-light: its only
        # runtime.core import is stage_registry. It must not pull in
        # routing modules, hooks, settings, or any module that would
        # create a circular dependency or couple the capability
        # vocabulary to live dispatch/config machinery.
        imported = _imported_module_names(ar)
        forbidden_substrings = (
            "dispatch_engine",
            "completions",
            "policy_engine",
            "enforcement_config",
            "settings",
            "hooks",
            "runtime.core.leases",
            "runtime.core.workflows",
            "runtime.core.policy_utils",
        )
        for name in imported:
            for needle in forbidden_substrings:
                assert needle not in name, (
                    f"authority_registry.py imports {name!r} which contains "
                    f"forbidden module token {needle!r}"
                )

    def test_live_routing_modules_do_not_import_authority_registry(self):
        # dispatch_engine and completions are the live routing modules
        # whose isolation from authority_registry must be preserved until
        # the cutover plan authorises the transition. policy_engine and
        # enforcement_config DO import authority_registry — that wiring
        # is intentional (Phase 3 capability gates).
        import runtime.core.completions as completions
        import runtime.core.dispatch_engine as dispatch_engine

        for mod in (dispatch_engine, completions):
            imported = _imported_module_names(mod)
            for name in imported:
                assert "authority_registry" not in name, (
                    f"{mod.__name__} imports {name!r} — authority_registry "
                    f"must not be imported by routing modules (dispatch_engine, completions)"
                )

    def test_authority_registry_only_depends_on_stage_registry(self):
        # Positive assertion: the only runtime.core import should be
        # stage_registry. This keeps the module as a pure projection of
        # the stage vocabulary + the CUTOVER_PLAN capability model.
        imported = _imported_module_names(ar)
        runtime_core_imports = {
            name for name in imported
            if name.startswith("runtime.core")
        }
        # ImportFrom walks record both the base ("runtime.core") and
        # the dotted alias ("runtime.core.stage_registry"). Accept
        # either / both as long as the only concrete dependency is
        # stage_registry.
        concrete = {
            name for name in runtime_core_imports
            if name != "runtime.core"
        }
        assert concrete == {"runtime.core.stage_registry"}, (
            f"authority_registry imports unexpected runtime.core modules: "
            f"{concrete}"
        )
