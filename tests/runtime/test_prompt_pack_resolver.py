"""Tests for runtime/core/prompt_pack_resolver.py.

@decision DEC-CLAUDEX-PROMPT-PACK-RESOLVER-TESTS-001
Title: Prompt-pack layer resolver — canonical key set, authority derivation, per-stage distinctions, build_prompt_pack integration, shadow-only discipline
Status: proposed (shadow-mode, Phase 2 prompt-pack resolver bootstrap)
Rationale: The resolver composes the six canonical prompt-pack
  layers from live shadow authorities plus explicit caller
  summaries. These tests pin:

    1. The output dict has exactly the canonical key set, in no
       particular order but with no extras or omissions.
    2. Input dataclasses validate their inputs at construction
       time and reject empty / wrong-typed / malformed values.
    3. The ``constitution`` layer is derived from
       ``constitution_registry`` + ``authority_registry``, not
       from hand-coded folklore: monkey-patching the authority
       state changes the rendered layer deterministically.
    4. The ``stage_contract`` layer is derived from
       ``authority_registry.resolve_contract(stage)`` (the single
       capability authority) + ``stage_registry.allowed_verdicts(stage)``,
       and produces distinct output for planner / reviewer / guardian
       provision / guardian land / implementer.
    5. The ``next_actions`` layer reflects
       ``stage_registry.outgoing(stage)`` and produces distinct
       output per stage in declaration order.
    6. The three caller-supplied summary renderers land in their
       respective layers deterministically.
    7. The resolver's output can be passed directly into
       :func:`runtime.core.prompt_pack.build_prompt_pack` as the
       ``layers`` argument with no reshaping.
    8. Shadow-only discipline via AST walk: the resolver imports
       only stdlib + the four expected shadow authorities; live
       routing modules and ``runtime/cli.py`` do not import it.
"""

from __future__ import annotations

import ast
import inspect

import pytest

from runtime.core import authority_registry as ar
from runtime.core import constitution_registry as cr
from runtime.core import contracts
from runtime.core import decision_work_registry as dwr
from runtime.core import prompt_pack as pp
from runtime.core import prompt_pack_resolver as ppr
from runtime.core import stage_registry as sr


def _imported_module_names(module) -> set[str]:
    tree = ast.parse(inspect.getsource(module))
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                names.add(alias.name)
        elif isinstance(node, ast.ImportFrom):
            base = node.module or ""
            if base:
                names.add(base)
                for alias in node.names:
                    names.add(f"{base}.{alias.name}")
    return names


# ---------------------------------------------------------------------------
# Default caller-supplied summaries used across the module
# ---------------------------------------------------------------------------


def _default_workflow_summary() -> ppr.WorkflowContractSummary:
    return ppr.WorkflowContractSummary(
        workflow_id="wf-test",
        title="Sample workflow",
        status="pending",
        scope_summary="runtime/core/**",
        evaluation_summary="pytest tests/runtime/ must pass",
        rollback_boundary="git checkout -- runtime/core/",
    )


def _default_decision_summary() -> ppr.LocalDecisionSummary:
    return ppr.LocalDecisionSummary(
        rationale="Phase 2 prompt-pack resolver slice",
        relevant_decision_ids=("DEC-CLAUDEX-PROMPT-PACK-RESOLVER-001",),
        supersession_notes=(),
    )


def _default_runtime_state() -> ppr.RuntimeStateSummary:
    return ppr.RuntimeStateSummary(
        current_branch="fix/enforce-rca-13-git-shell-classifier",
        worktree_path="/repo/.worktrees/feature-x",
        active_leases=("lease-abc-123",),
        open_approvals=(),
        unresolved_findings=(),
    )


def _resolve(stage: str = sr.PLANNER, **overrides) -> dict:
    kwargs = {
        "stage": stage,
        "workflow_summary": _default_workflow_summary(),
        "decision_summary": _default_decision_summary(),
        "runtime_state_summary": _default_runtime_state(),
    }
    kwargs.update(overrides)
    return ppr.resolve_prompt_pack_layers(**kwargs)


# ---------------------------------------------------------------------------
# 1. Canonical layer key set and order
# ---------------------------------------------------------------------------


class TestCanonicalLayerKeys:
    def test_resolver_output_has_exactly_canonical_keys(self):
        layers = _resolve()
        assert set(layers.keys()) == set(pp.CANONICAL_LAYER_ORDER)

    def test_canonical_layer_order_all_present(self):
        layers = _resolve()
        for layer_name in pp.CANONICAL_LAYER_ORDER:
            assert layer_name in layers, (
                f"canonical layer {layer_name!r} missing from resolver output"
            )

    def test_no_extra_keys_in_resolver_output(self):
        layers = _resolve()
        extras = set(layers.keys()) - set(pp.CANONICAL_LAYER_ORDER)
        assert extras == set(), f"resolver produced extra keys: {extras}"

    def test_every_layer_value_is_non_empty_string(self):
        layers = _resolve()
        for name, value in layers.items():
            assert isinstance(value, str)
            assert value.strip() != "", f"layer {name!r} is blank"


# ---------------------------------------------------------------------------
# 2. Input dataclass validation
# ---------------------------------------------------------------------------


class TestWorkflowContractSummaryValidation:
    def test_valid_construction(self):
        summary = _default_workflow_summary()
        assert summary.workflow_id == "wf-test"

    @pytest.mark.parametrize(
        "attr",
        [
            "workflow_id",
            "title",
            "status",
            "scope_summary",
            "evaluation_summary",
            "rollback_boundary",
        ],
    )
    def test_empty_required_field_rejected(self, attr):
        kwargs = dict(
            workflow_id="wf",
            title="t",
            status="s",
            scope_summary="x",
            evaluation_summary="y",
            rollback_boundary="z",
        )
        kwargs[attr] = ""
        with pytest.raises(ValueError):
            ppr.WorkflowContractSummary(**kwargs)

    def test_whitespace_only_field_rejected(self):
        with pytest.raises(ValueError):
            ppr.WorkflowContractSummary(
                workflow_id="wf",
                title="   ",
                status="s",
                scope_summary="x",
                evaluation_summary="y",
                rollback_boundary="z",
            )

    def test_render_includes_every_field(self):
        summary = _default_workflow_summary()
        text = summary.render()
        assert "wf-test" in text
        assert "Sample workflow" in text
        assert "pending" in text
        assert "runtime/core/**" in text
        assert "pytest" in text
        assert "git checkout" in text


class TestLocalDecisionSummaryValidation:
    def test_valid_construction_with_defaults(self):
        summary = ppr.LocalDecisionSummary()
        assert summary.rationale == "(no relevant decisions)"
        assert summary.relevant_decision_ids == ()
        assert summary.supersession_notes == ()

    def test_empty_rationale_rejected(self):
        with pytest.raises(ValueError):
            ppr.LocalDecisionSummary(rationale="")

    def test_non_tuple_decision_ids_rejected(self):
        with pytest.raises(ValueError):
            ppr.LocalDecisionSummary(
                relevant_decision_ids=["DEC-001"]  # type: ignore[arg-type]
            )

    def test_empty_string_decision_id_rejected(self):
        with pytest.raises(ValueError):
            ppr.LocalDecisionSummary(
                relevant_decision_ids=("DEC-001", "")
            )

    def test_render_with_decisions(self):
        summary = ppr.LocalDecisionSummary(
            rationale="test",
            relevant_decision_ids=("DEC-A", "DEC-B"),
            supersession_notes=("DEC-A supersedes DEC-OLD",),
        )
        text = summary.render()
        assert "test" in text
        assert "DEC-A" in text
        assert "DEC-B" in text
        assert "supersedes" in text

    def test_render_with_empty_lists_shows_none_markers(self):
        summary = ppr.LocalDecisionSummary(rationale="nothing here")
        text = summary.render()
        assert "Relevant decisions: (none)" in text
        assert "Supersession notes: (none)" in text


class TestRuntimeStateSummaryValidation:
    def test_valid_minimal_construction(self):
        summary = ppr.RuntimeStateSummary(
            current_branch="main", worktree_path="/repo"
        )
        assert summary.active_leases == ()

    def test_empty_branch_rejected(self):
        with pytest.raises(ValueError):
            ppr.RuntimeStateSummary(
                current_branch="", worktree_path="/repo"
            )

    def test_empty_worktree_path_rejected(self):
        with pytest.raises(ValueError):
            ppr.RuntimeStateSummary(
                current_branch="main", worktree_path=""
            )

    def test_non_tuple_lease_list_rejected(self):
        with pytest.raises(ValueError):
            ppr.RuntimeStateSummary(
                current_branch="main",
                worktree_path="/repo",
                active_leases=["lease-1"],  # type: ignore[arg-type]
            )

    def test_render_with_empty_lists_shows_none_markers(self):
        summary = ppr.RuntimeStateSummary(
            current_branch="main", worktree_path="/repo"
        )
        text = summary.render()
        assert "Active leases: (none)" in text
        assert "Open approvals: (none)" in text
        assert "Unresolved findings: (none)" in text

    def test_render_with_populated_lists(self):
        summary = ppr.RuntimeStateSummary(
            current_branch="feature-x",
            worktree_path="/repo/.worktrees/x",
            active_leases=("lease-1", "lease-2"),
            open_approvals=("approval-42",),
            unresolved_findings=("finding-A",),
        )
        text = summary.render()
        assert "feature-x" in text
        assert "lease-1" in text
        assert "lease-2" in text
        assert "approval-42" in text
        assert "finding-A" in text


# ---------------------------------------------------------------------------
# 3. Constitution layer — derived from runtime authorities
# ---------------------------------------------------------------------------


class TestConstitutionLayerDerivation:
    def test_layer_lists_every_concrete_constitution_path(self):
        text = ppr.render_constitution_layer()
        for entry in cr.concrete_entries():
            assert f"- {entry.path}" in text, (
                f"constitution layer missing entry {entry.path!r}"
            )

    def test_layer_lists_every_capability(self):
        text = ppr.render_constitution_layer()
        for capability in ar.CAPABILITIES:
            assert f"- {capability}" in text, (
                f"constitution layer missing capability {capability!r}"
            )

    def test_layer_lists_every_authority_table_entry(self):
        text = ppr.render_constitution_layer()
        for fact in ar.AUTHORITY_TABLE:
            assert f"- {fact.name} → {fact.owner_module}" in text, (
                f"constitution layer missing fact {fact.name!r}"
            )

    def test_layer_is_deterministic(self):
        assert ppr.render_constitution_layer() == ppr.render_constitution_layer()

    def test_layer_does_not_inline_claude_md_prose(self):
        # Guard against the folklore-text antipattern: the
        # constitution layer references CLAUDE.md by path, not by
        # inlining its content.
        text = ppr.render_constitution_layer()
        assert "CLAUDE.md" in text  # the path is referenced
        # The CLAUDE.md content starts with "# CLAUDE.md — Canonical
        # Core" — the resolver must NOT inline that prose.
        assert "Canonical Core" not in text
        assert "Divine User" not in text

    def test_layer_changes_when_constitution_registry_changes(self, monkeypatch):
        baseline = ppr.render_constitution_layer()

        # Monkey-patch concrete_entries to return a shortened tuple.
        original_concrete = cr.concrete_entries()
        shortened = original_concrete[:-1]
        monkeypatch.setattr(
            cr, "concrete_entries", lambda: shortened
        )

        mutated = ppr.render_constitution_layer()
        assert mutated != baseline, (
            "constitution layer did not reflect constitution_registry change"
        )
        # The dropped entry's path should no longer appear.
        dropped = original_concrete[-1].path
        assert f"- {dropped}\n" not in mutated

    def test_layer_changes_when_authority_registry_capabilities_change(
        self, monkeypatch
    ):
        baseline = ppr.render_constitution_layer()

        # Monkey-patch CAPABILITIES to drop one capability.
        shrunk = frozenset(ar.CAPABILITIES - {"can_write_source"})
        monkeypatch.setattr(ar, "CAPABILITIES", shrunk)

        mutated = ppr.render_constitution_layer()
        assert mutated != baseline
        assert "- can_write_source" not in mutated


# ---------------------------------------------------------------------------
# 3b. constitution_watched_files — compile-path freshness bridge (Slice 11)
# ---------------------------------------------------------------------------


class TestConstitutionWatchedFiles:
    """Phase 7 Slice 11: the resolver exposes the concrete constitution
    path set in deterministic registry order so compiled prompt packs
    can populate ``StaleCondition.watched_files`` from a single
    authority (``constitution_registry.all_concrete_paths``)."""

    def test_helper_returns_all_concrete_paths_in_registry_order(self):
        assert ppr.constitution_watched_files() == cr.all_concrete_paths()

    def test_helper_returns_tuple(self):
        # Must be a tuple so it composes directly with StaleCondition.
        result = ppr.constitution_watched_files()
        assert isinstance(result, tuple)

    def test_helper_is_deterministic(self):
        assert ppr.constitution_watched_files() == ppr.constitution_watched_files()

    def test_helper_reflects_registry_mutation(self, monkeypatch):
        baseline = ppr.constitution_watched_files()
        shortened = baseline[:-1]
        monkeypatch.setattr(cr, "all_concrete_paths", lambda: shortened)
        assert ppr.constitution_watched_files() == shortened

    def test_helper_covers_phase_7_promotions(self):
        paths = ppr.constitution_watched_files()
        # Spot-check the Slice 8 + Slice 10 promotions are reachable
        # through the helper — not a duplicated full list, just a
        # non-trivial lower bound.
        assert "runtime/core/hook_manifest.py" in paths
        assert "runtime/core/prompt_pack_resolver.py" in paths


# ---------------------------------------------------------------------------
# 4. Stage contract layer — per-stage distinctions
# ---------------------------------------------------------------------------


class TestStageContractLayer:
    # -- fail-closed behavior --

    def test_rejects_unknown_stage(self):
        with pytest.raises(ValueError, match="unknown active stage"):
            ppr.render_stage_contract_layer("ghost_stage")

    def test_rejects_sink_stage(self):
        # Sink stages (TERMINAL / USER) are not active — resolver
        # must reject them.
        with pytest.raises(ValueError):
            ppr.render_stage_contract_layer(sr.TERMINAL)

    def test_rejects_empty_string(self):
        with pytest.raises(ValueError, match="unknown active stage"):
            ppr.render_stage_contract_layer("")

    # -- per-stage content --

    def test_planner_layer_mentions_planner_capabilities(self):
        text = ppr.render_stage_contract_layer(sr.PLANNER)
        assert sr.PLANNER in text
        # Planner has can_write_governance and
        # can_set_control_config per the authority registry.
        assert "can_write_governance" in text
        assert "can_set_control_config" in text

    def test_reviewer_layer_mentions_read_only_review(self):
        text = ppr.render_stage_contract_layer(sr.REVIEWER)
        assert sr.REVIEWER in text
        assert "read_only_review" in text

    def test_implementer_layer_mentions_can_write_source(self):
        text = ppr.render_stage_contract_layer(sr.IMPLEMENTER)
        assert sr.IMPLEMENTER in text
        assert "can_write_source" in text

    def test_guardian_provision_layer_mentions_can_provision_worktree(self):
        text = ppr.render_stage_contract_layer(sr.GUARDIAN_PROVISION)
        assert "guardian:provision" in text
        assert "can_provision_worktree" in text

    def test_guardian_land_layer_mentions_can_land_git(self):
        text = ppr.render_stage_contract_layer(sr.GUARDIAN_LAND)
        assert "guardian:land" in text
        assert "can_land_git" in text

    def test_forbidden_capabilities_section_present(self):
        # Every stage should list capabilities it does NOT carry
        # explicitly, not just the ones it does.
        text = ppr.render_stage_contract_layer(sr.REVIEWER)
        assert "Forbidden capabilities:" in text
        # Reviewer must NOT be allowed to write source.
        idx_forbidden = text.find("Forbidden capabilities:")
        assert "can_write_source" in text[idx_forbidden:]

    def test_allowed_verdicts_listed(self):
        text = ppr.render_stage_contract_layer(sr.REVIEWER)
        for verdict in sr.allowed_verdicts(sr.REVIEWER):
            assert verdict in text

    def test_distinct_output_across_five_active_stages(self):
        outputs = {
            stage: ppr.render_stage_contract_layer(stage)
            for stage in sr.ACTIVE_STAGES
        }
        unique = set(outputs.values())
        assert len(unique) == len(outputs), (
            "stage_contract output collapsed across distinct stages"
        )

    # -- reviewer read-only rendering --

    def test_reviewer_read_only_flag_rendered(self):
        text = ppr.render_stage_contract_layer(sr.REVIEWER)
        assert "Read-only: yes" in text

    def test_non_reviewer_stages_omit_read_only_flag(self):
        for stage in sr.ACTIVE_STAGES:
            if stage == sr.REVIEWER:
                continue
            text = ppr.render_stage_contract_layer(stage)
            assert "Read-only:" not in text, (
                f"{stage} should not render a Read-only line"
            )

    # -- resolve_contract() is the sole capability source --

    def test_granted_caps_match_resolve_contract(self):
        """Rendered 'Allowed capabilities' must exactly match the
        contract's granted set — proving the layer uses
        resolve_contract(), not a parallel recomputation."""
        for stage in sr.ACTIVE_STAGES:
            contract = ar.resolve_contract(stage)
            assert contract is not None
            text = ppr.render_stage_contract_layer(stage)
            idx_allowed = text.find("Allowed capabilities:")
            idx_forbidden = text.find("Forbidden capabilities:")
            allowed_section = text[idx_allowed:idx_forbidden]
            for cap in sorted(contract.granted):
                assert f"- {cap}" in allowed_section, (
                    f"{stage}: granted cap {cap!r} missing from layer"
                )

    def test_denied_caps_match_resolve_contract(self):
        """Rendered 'Forbidden capabilities' must exactly match the
        contract's denied set."""
        for stage in sr.ACTIVE_STAGES:
            contract = ar.resolve_contract(stage)
            assert contract is not None
            text = ppr.render_stage_contract_layer(stage)
            idx_forbidden = text.find("Forbidden capabilities:")
            idx_verdicts = text.find("Allowed verdicts:")
            forbidden_section = text[idx_forbidden:idx_verdicts]
            for cap in sorted(contract.denied):
                assert f"- {cap}" in forbidden_section, (
                    f"{stage}: denied cap {cap!r} missing from layer"
                )

    def test_layer_moves_when_contract_changes(self, monkeypatch):
        """Monkey-patching STAGE_CAPABILITIES must change the rendered
        layer via resolve_contract() — proving no stale parallel copy."""
        baseline = ppr.render_stage_contract_layer(sr.IMPLEMENTER)
        # Remove can_write_source from implementer's capability set.
        patched = dict(ar.STAGE_CAPABILITIES)
        patched[sr.IMPLEMENTER] = frozenset(
            {ar.CAN_EMIT_DISPATCH_TRANSITION}
        )
        monkeypatch.setattr(ar, "STAGE_CAPABILITIES", patched)
        mutated = ppr.render_stage_contract_layer(sr.IMPLEMENTER)
        assert mutated != baseline
        # can_write_source should have moved from Allowed to Forbidden.
        idx_forbidden = mutated.find("Forbidden capabilities:")
        idx_verdicts = mutated.find("Allowed verdicts:")
        assert "can_write_source" in mutated[idx_forbidden:idx_verdicts]

    # -- determinism and sorting --

    def test_capabilities_are_sorted_in_output(self):
        for stage in sr.ACTIVE_STAGES:
            text = ppr.render_stage_contract_layer(stage)
            # Extract lines between "Allowed capabilities:" and
            # "Forbidden capabilities:".
            idx_a = text.find("Allowed capabilities:")
            idx_f = text.find("Forbidden capabilities:")
            idx_v = text.find("Allowed verdicts:")
            allowed_lines = [
                line.strip("- ").strip()
                for line in text[idx_a:idx_f].splitlines()
                if line.startswith("- ")
            ]
            forbidden_lines = [
                line.strip("- ").strip()
                for line in text[idx_f:idx_v].splitlines()
                if line.startswith("- ")
            ]
            assert allowed_lines == sorted(allowed_lines), (
                f"{stage}: allowed capabilities not sorted"
            )
            assert forbidden_lines == sorted(forbidden_lines), (
                f"{stage}: forbidden capabilities not sorted"
            )

    def test_output_is_deterministic(self):
        for stage in sr.ACTIVE_STAGES:
            assert (
                ppr.render_stage_contract_layer(stage)
                == ppr.render_stage_contract_layer(stage)
            )

    # -- live-role alias canonicalization --

    def test_plan_alias_renders_canonical_planner_stage(self):
        """'Plan' alias must resolve through resolve_contract() and
        render the canonical planner stage, not 'Plan'."""
        text = ppr.render_stage_contract_layer("Plan")
        assert "Stage: planner" in text
        assert "Stage: Plan" not in text

    def test_plan_alias_includes_planner_verdicts(self):
        """'Plan' alias must produce planner verdicts via
        contract.stage_id, not empty verdicts from the raw alias."""
        text = ppr.render_stage_contract_layer("Plan")
        assert "next_work_item" in text
        assert "goal_complete" in text
        assert "needs_user_decision" in text

    def test_plan_alias_matches_canonical_planner_output(self):
        """Rendering via alias must be identical to rendering via
        canonical stage name."""
        assert (
            ppr.render_stage_contract_layer("Plan")
            == ppr.render_stage_contract_layer(sr.PLANNER)
        )

    def test_bare_guardian_raises_after_alias_removal(self):
        """Bare 'guardian' raises ValueError after DEC-WHO-LANDING-ALIAS-001.
        Callers must use 'guardian:provision' or 'guardian:land'."""
        import pytest
        with pytest.raises(ValueError, match="unknown active stage"):
            ppr.render_stage_contract_layer("guardian")


# ---------------------------------------------------------------------------
# 5. Next actions layer — per-stage transitions
# ---------------------------------------------------------------------------


class TestNextActionsLayer:
    def test_rejects_unknown_stage(self):
        with pytest.raises(ValueError):
            ppr.render_next_actions_layer("nope")

    def test_planner_next_actions_lists_every_planner_transition(self):
        text = ppr.render_next_actions_layer(sr.PLANNER)
        for transition in sr.outgoing(sr.PLANNER):
            assert (
                f"verdict={transition.verdict} → {transition.to_stage}"
                in text
            )

    def test_reviewer_next_actions_lists_every_reviewer_transition(self):
        text = ppr.render_next_actions_layer(sr.REVIEWER)
        for transition in sr.outgoing(sr.REVIEWER):
            assert (
                f"verdict={transition.verdict} → {transition.to_stage}"
                in text
            )

    def test_guardian_land_next_actions_are_terminal_or_planner(self):
        text = ppr.render_next_actions_layer(sr.GUARDIAN_LAND)
        # guardian:land transitions should include committed→planner
        # and merged→planner per the target stage graph.
        assert f"verdict=committed → {sr.PLANNER}" in text
        assert f"verdict=merged → {sr.PLANNER}" in text

    def test_per_stage_distinct_output(self):
        outputs = {
            stage: ppr.render_next_actions_layer(stage)
            for stage in sr.ACTIVE_STAGES
        }
        assert len(set(outputs.values())) == len(outputs), (
            "next_actions output collapsed across distinct stages"
        )

    def test_layer_is_deterministic(self):
        assert ppr.render_next_actions_layer(
            sr.PLANNER
        ) == ppr.render_next_actions_layer(sr.PLANNER)


# ---------------------------------------------------------------------------
# 6. Resolver top-level behaviour + integration with build_prompt_pack
# ---------------------------------------------------------------------------


class TestResolvePromptPackLayers:
    def test_workflow_summary_lands_in_workflow_contract_layer(self):
        layers = _resolve()
        workflow = _default_workflow_summary()
        assert layers[pp.LAYER_WORKFLOW_CONTRACT] == workflow.render()

    def test_decision_summary_lands_in_local_decision_pack_layer(self):
        layers = _resolve()
        decision = _default_decision_summary()
        assert layers[pp.LAYER_LOCAL_DECISION_PACK] == decision.render()

    def test_runtime_state_lands_in_runtime_state_pack_layer(self):
        layers = _resolve()
        rt = _default_runtime_state()
        assert layers[pp.LAYER_RUNTIME_STATE_PACK] == rt.render()

    def test_constitution_layer_is_render_constitution_layer_output(self):
        layers = _resolve()
        assert layers[pp.LAYER_CONSTITUTION] == ppr.render_constitution_layer()

    def test_stage_contract_layer_reflects_stage_argument(self):
        layers_planner = _resolve(stage=sr.PLANNER)
        layers_reviewer = _resolve(stage=sr.REVIEWER)
        assert (
            layers_planner[pp.LAYER_STAGE_CONTRACT]
            != layers_reviewer[pp.LAYER_STAGE_CONTRACT]
        )
        assert layers_planner[pp.LAYER_STAGE_CONTRACT] == (
            ppr.render_stage_contract_layer(sr.PLANNER)
        )

    def test_next_actions_layer_reflects_stage_argument(self):
        layers_planner = _resolve(stage=sr.PLANNER)
        layers_reviewer = _resolve(stage=sr.REVIEWER)
        assert (
            layers_planner[pp.LAYER_NEXT_ACTIONS]
            != layers_reviewer[pp.LAYER_NEXT_ACTIONS]
        )
        assert layers_planner[pp.LAYER_NEXT_ACTIONS] == (
            ppr.render_next_actions_layer(sr.PLANNER)
        )

    def test_unknown_stage_raises(self):
        with pytest.raises(ValueError):
            _resolve(stage="banana")

    def test_wrong_workflow_summary_type_raises(self):
        with pytest.raises(ValueError, match="WorkflowContractSummary"):
            ppr.resolve_prompt_pack_layers(
                stage=sr.PLANNER,
                workflow_summary={"workflow_id": "w"},  # type: ignore[arg-type]
                decision_summary=_default_decision_summary(),
                runtime_state_summary=_default_runtime_state(),
            )

    def test_wrong_decision_summary_type_raises(self):
        with pytest.raises(ValueError, match="LocalDecisionSummary"):
            ppr.resolve_prompt_pack_layers(
                stage=sr.PLANNER,
                workflow_summary=_default_workflow_summary(),
                decision_summary="not a summary",  # type: ignore[arg-type]
                runtime_state_summary=_default_runtime_state(),
            )

    def test_wrong_runtime_state_type_raises(self):
        with pytest.raises(ValueError, match="RuntimeStateSummary"):
            ppr.resolve_prompt_pack_layers(
                stage=sr.PLANNER,
                workflow_summary=_default_workflow_summary(),
                decision_summary=_default_decision_summary(),
                runtime_state_summary=None,  # type: ignore[arg-type]
            )

    def test_resolver_is_deterministic_for_same_inputs(self):
        a = _resolve()
        b = _resolve()
        assert a == b


class TestBuildPromptPackIntegration:
    def test_resolver_output_feeds_build_prompt_pack_directly(self):
        # The core round-trip: resolver → build_prompt_pack
        # without any reshaping.
        layers = _resolve(stage=sr.PLANNER)
        pack = pp.build_prompt_pack(
            workflow_id="wf-integration",
            stage_id=sr.PLANNER,
            layers=layers,
            generated_at=1_700_000_000,
        )
        assert pack.layer_names == pp.CANONICAL_LAYER_ORDER
        assert pack.content_hash.startswith("sha256:")
        assert pack.workflow_id == "wf-integration"
        assert pack.stage_id == sr.PLANNER

    def test_every_active_stage_round_trips_through_build_prompt_pack(self):
        # Proves that every stage the resolver understands produces
        # layers the compiler will accept.
        for stage in sr.ACTIVE_STAGES:
            layers = _resolve(stage=stage)
            pack = pp.build_prompt_pack(
                workflow_id="wf-roundtrip",
                stage_id=stage,
                layers=layers,
                generated_at=1,
            )
            assert pack.stage_id == stage

    def test_different_stages_produce_different_content_hashes(self):
        hashes: set[str] = set()
        for stage in sr.ACTIVE_STAGES:
            pack = pp.build_prompt_pack(
                workflow_id="wf-hash",
                stage_id=stage,
                layers=_resolve(stage=stage),
                generated_at=1,
            )
            hashes.add(pack.content_hash)
        # Five active stages should produce five distinct content
        # hashes because stage_contract + next_actions differ per
        # stage.
        assert len(hashes) == len(sr.ACTIVE_STAGES)


# ---------------------------------------------------------------------------
# 7. Shadow-only discipline (AST inspection)
# ---------------------------------------------------------------------------


class TestShadowOnlyDiscipline:
    def test_resolver_only_imports_stdlib_and_expected_shadow_authorities(self):
        imported = _imported_module_names(ppr)
        runtime_core_imports = {
            name for name in imported if name.startswith("runtime.core")
        }
        # The resolver is allowed to import exactly these shadow
        # modules (and the base ``runtime.core`` package node that
        # ImportFrom emits). ``runtime.core.contracts`` was added
        # as a permitted import in the ``workflow_summary_from_contracts``
        # bridge slice; ``runtime.core.decision_work_registry`` was
        # added in the ``local_decision_summary_from_records``
        # bridge slice.
        permitted_bases = {"runtime.core"}
        permitted_prefixes = (
            "runtime.core.authority_registry",
            "runtime.core.constitution_registry",
            "runtime.core.contracts",
            "runtime.core.decision_work_registry",
            "runtime.core.prompt_pack",
            "runtime.core.stage_registry",
        )
        for name in runtime_core_imports:
            assert name in permitted_bases or name.startswith(
                permitted_prefixes
            ), (
                f"prompt_pack_resolver.py has unexpected runtime.core "
                f"import: {name!r}"
            )

    def test_resolver_has_no_live_imports(self):
        imported = _imported_module_names(ppr)
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
                    f"prompt_pack_resolver.py imports {name!r} containing "
                    f"forbidden token {needle!r}"
                )

    def test_live_modules_do_not_import_resolver(self):
        import runtime.core.completions as completions
        import runtime.core.dispatch_engine as dispatch_engine
        import runtime.core.policy_engine as policy_engine

        for mod in (dispatch_engine, completions, policy_engine):
            imported = _imported_module_names(mod)
            for name in imported:
                assert "prompt_pack_resolver" not in name, (
                    f"{mod.__name__} imports {name!r} — prompt_pack_resolver "
                    f"must stay shadow-only this slice"
                )

    def test_cli_imports_resolver_only_via_function_scope(self):
        # Architecture invariant after the prompt-pack compile CLI
        # slice (DEC-CLAUDEX-PROMPT-PACK-COMPILE-CLI-001):
        # ``runtime/cli.py`` reaches ``prompt_pack_resolver`` only
        # via a function-scope import inside the ``compile`` branch
        # of ``_handle_prompt_pack``. At module level the CLI must
        # NOT import the resolver, so the resolver is not promoted
        # to an always-loaded CLI dependency. The guard walks
        # ``tree.body`` only.
        import runtime.cli as cli

        tree = ast.parse(inspect.getsource(cli))
        module_level_imports: set[str] = set()
        for node in tree.body:
            if isinstance(node, ast.Import):
                for alias in node.names:
                    module_level_imports.add(alias.name)
            elif isinstance(node, ast.ImportFrom):
                base = node.module or ""
                if base:
                    module_level_imports.add(base)
                    for alias in node.names:
                        module_level_imports.add(f"{base}.{alias.name}")
        for name in module_level_imports:
            assert "prompt_pack_resolver" not in name, (
                f"cli.py imports {name!r} at module level — "
                f"prompt_pack_resolver may only be reached via a "
                f"function-scope import inside _handle_prompt_pack"
            )

    def test_prompt_pack_module_imports_resolver_only_via_capstone_helper(self):
        # Architecture invariant after the capstone compile slice
        # (DEC-CLAUDEX-PROMPT-PACK-COMPILE-FOR-STAGE-001):
        # ``runtime.core.prompt_pack`` is the single compiler
        # authority and chains the prompt-pack resolver / state /
        # decisions helpers via *function-level* imports inside
        # ``compile_prompt_pack_for_stage``. The reverse-dependency
        # guard therefore allows the resolver name to appear, but
        # only inside that helper's body — not at module level — so
        # the resolver still cannot be silently widened into an
        # always-loaded compiler dependency.
        import ast
        import inspect

        tree = ast.parse(inspect.getsource(pp))
        module_level_imports: set[str] = set()
        for node in tree.body:
            if isinstance(node, ast.Import):
                for alias in node.names:
                    module_level_imports.add(alias.name)
            elif isinstance(node, ast.ImportFrom):
                base = node.module or ""
                if base:
                    module_level_imports.add(base)
                    for alias in node.names:
                        module_level_imports.add(f"{base}.{alias.name}")
        for name in module_level_imports:
            assert "prompt_pack_resolver" not in name, (
                f"prompt_pack.py imports {name!r} at module level — "
                f"the resolver may only be reached via the function-level "
                f"capstone import inside compile_prompt_pack_for_stage"
            )

    def test_prompt_pack_validation_does_not_import_resolver(self):
        from runtime.core import prompt_pack_validation as ppv

        imported = _imported_module_names(ppv)
        for name in imported:
            assert "prompt_pack_resolver" not in name


# ---------------------------------------------------------------------------
# 8. workflow_summary_from_contracts — bridge from contracts.py
#
# Pinned invariants:
#   * Type validation on both contract arguments.
#   * goal_id mismatch raises ValueError with both ids in the message.
#   * Deterministic rendering.
#   * Title, status, scope, evaluation, rollback_boundary all derived
#     mechanically from contract fields.
#   * Empty / sparse contract fields produce explicit (none) / (unrestricted)
#     / (unspecified) markers, never blank strings that would fail
#     WorkflowContractSummary validation.
#   * Integration: the helper's output can be passed into
#     resolve_prompt_pack_layers and then into build_prompt_pack.
# ---------------------------------------------------------------------------


def _default_goal(
    goal_id: str = "G-1",
    desired_end_state: str = "Ship the ClauDEX slice",
    status: str = "active",
) -> contracts.GoalContract:
    return contracts.GoalContract(
        goal_id=goal_id,
        desired_end_state=desired_end_state,
        status=status,
    )


def _default_work_item(
    *,
    work_item_id: str = "WI-1",
    goal_id: str = "G-1",
    title: str = "First work item",
    scope: contracts.ScopeManifest | None = None,
    evaluation: contracts.EvaluationContract | None = None,
    status: str = "in_progress",
) -> contracts.WorkItemContract:
    return contracts.WorkItemContract(
        work_item_id=work_item_id,
        goal_id=goal_id,
        title=title,
        scope=scope if scope is not None else contracts.ScopeManifest(),
        evaluation=(
            evaluation if evaluation is not None else contracts.EvaluationContract()
        ),
        status=status,
    )


class TestWorkflowSummaryFromContractsValidation:
    def test_matching_goal_and_work_item_accepted(self):
        goal = _default_goal()
        work_item = _default_work_item()
        summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf-test", goal=goal, work_item=work_item
        )
        assert isinstance(summary, ppr.WorkflowContractSummary)

    def test_goal_id_mismatch_raises_with_both_ids(self):
        goal = _default_goal(goal_id="G-alpha")
        work_item = _default_work_item(goal_id="G-beta")
        with pytest.raises(ValueError) as exc:
            ppr.workflow_summary_from_contracts(
                workflow_id="wf", goal=goal, work_item=work_item
            )
        # Both ids must appear in the error message for debuggability.
        assert "G-alpha" in str(exc.value)
        assert "G-beta" in str(exc.value)

    def test_non_goal_contract_raises(self):
        work_item = _default_work_item()
        with pytest.raises(ValueError, match="GoalContract"):
            ppr.workflow_summary_from_contracts(
                workflow_id="wf",
                goal={"goal_id": "G-1"},  # type: ignore[arg-type]
                work_item=work_item,
            )

    def test_non_work_item_contract_raises(self):
        goal = _default_goal()
        with pytest.raises(ValueError, match="WorkItemContract"):
            ppr.workflow_summary_from_contracts(
                workflow_id="wf",
                goal=goal,
                work_item="not a work item",  # type: ignore[arg-type]
            )

    def test_empty_workflow_id_raises_via_summary_validation(self):
        goal = _default_goal()
        work_item = _default_work_item()
        with pytest.raises(ValueError, match="workflow_id"):
            ppr.workflow_summary_from_contracts(
                workflow_id="",
                goal=goal,
                work_item=work_item,
            )

    def test_empty_work_item_title_raises_via_summary_validation(self):
        goal = _default_goal()
        work_item = _default_work_item(title="")
        with pytest.raises(ValueError, match="title"):
            ppr.workflow_summary_from_contracts(
                workflow_id="wf", goal=goal, work_item=work_item
            )

    def test_whitespace_only_title_raises_via_summary_validation(self):
        goal = _default_goal()
        work_item = _default_work_item(title="   ")
        with pytest.raises(ValueError, match="title"):
            ppr.workflow_summary_from_contracts(
                workflow_id="wf", goal=goal, work_item=work_item
            )


class TestWorkflowSummaryFromContractsDerivation:
    def test_title_derived_from_work_item_not_goal(self):
        goal = _default_goal(desired_end_state="Ship the widget")
        work_item = _default_work_item(title="Slice 17 — add the foo")
        summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf", goal=goal, work_item=work_item
        )
        assert summary.title == "Slice 17 — add the foo"
        # The goal's desired_end_state must NOT accidentally shadow
        # the work-item title.
        assert "widget" not in summary.title

    def test_status_combines_goal_and_work_item_statuses(self):
        goal = _default_goal(status="awaiting_user")
        work_item = _default_work_item(status="in_review")
        summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf", goal=goal, work_item=work_item
        )
        assert "goal=awaiting_user" in summary.status
        assert "work_item=in_review" in summary.status
        # Compact, deterministic separator so downstream parsers
        # can split on "; ".
        assert summary.status == "goal=awaiting_user; work_item=in_review"

    def test_status_preserves_every_goal_status_vocabulary_value(self):
        for goal_status in contracts.GOAL_STATUSES:
            goal = _default_goal(status=goal_status)
            work_item = _default_work_item()
            summary = ppr.workflow_summary_from_contracts(
                workflow_id="wf", goal=goal, work_item=work_item
            )
            assert f"goal={goal_status}" in summary.status

    def test_status_preserves_every_work_item_status_vocabulary_value(self):
        for wi_status in contracts.WORK_ITEM_STATUSES:
            goal = _default_goal()
            work_item = _default_work_item(status=wi_status)
            summary = ppr.workflow_summary_from_contracts(
                workflow_id="wf", goal=goal, work_item=work_item
            )
            assert f"work_item={wi_status}" in summary.status

    def test_deterministic_output_for_identical_inputs(self):
        goal = _default_goal()
        work_item = _default_work_item()
        a = ppr.workflow_summary_from_contracts(
            workflow_id="wf", goal=goal, work_item=work_item
        )
        b = ppr.workflow_summary_from_contracts(
            workflow_id="wf", goal=goal, work_item=work_item
        )
        assert a == b


class TestScopeSummaryRendering:
    """Unit coverage for the legacy ``_render_scope_summary`` helper.

    DEC-CLAUDEX-PROMPT-PACK-SCOPE-AUTHORITY-002: this helper is no
    longer reachable from any production compile path. These tests
    exercise it directly as a unit (the helper remains in module for
    diagnostic / test-only callers that work on the intent-declaration
    manifest shape). The corresponding compile-path behaviour (None
    authoritative record → explicit no-authoritative marker) is pinned
    by ``TestNoAuthoritativeScopeBehavior`` below.
    """

    def test_empty_scope_shows_explicit_markers(self):
        scope_text = ppr._render_scope_summary(contracts.ScopeManifest())
        assert "Allowed paths:" in scope_text
        assert "Required paths:" in scope_text
        assert "Forbidden paths:" in scope_text
        assert "State domains:" in scope_text
        assert "(unrestricted)" in scope_text
        assert scope_text.count("(none)") == 3

    def test_populated_scope_lists_each_path(self):
        scope = contracts.ScopeManifest(
            allowed_paths=("runtime/core/**", "tests/runtime/**"),
            required_paths=("runtime/core/foo.py",),
            forbidden_paths=("hooks/**",),
            state_domains=("contracts", "authority_registry"),
        )
        text = ppr._render_scope_summary(scope)
        assert "runtime/core/**" in text
        assert "tests/runtime/**" in text
        assert "runtime/core/foo.py" in text
        assert "hooks/**" in text
        assert "contracts" in text
        assert "authority_registry" in text
        assert "(unrestricted)" not in text

    def test_partial_scope_mixes_explicit_markers_with_paths(self):
        scope = contracts.ScopeManifest(
            allowed_paths=("runtime/**",),
            # required_paths / forbidden_paths / state_domains empty
        )
        text = ppr._render_scope_summary(scope)
        assert "runtime/**" in text
        assert "(unrestricted)" not in text
        assert text.count("(none)") == 3

    def test_scope_summary_is_non_empty_even_with_fully_empty_scope(self):
        # Helper must always produce a non-empty block so downstream
        # readers never see a blank section.
        text = ppr._render_scope_summary(contracts.ScopeManifest())
        assert text.strip() != ""


class TestEvaluationSummaryRendering:
    def test_empty_evaluation_shows_explicit_none_markers(self):
        summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf",
            goal=_default_goal(desired_end_state="Ship the widget"),
            work_item=_default_work_item(
                evaluation=contracts.EvaluationContract()
            ),
        )
        text = summary.evaluation_summary
        # Desired end state from goal is preserved.
        assert "Ship the widget" in text
        # Sections still present with explicit (none) markers.
        assert "Required tests:" in text
        assert "Required evidence:" in text
        assert "Acceptance notes: (none)" in text
        # Required tests + required evidence both empty.
        assert text.count("(none)") >= 3

    def test_empty_desired_end_state_uses_unspecified_placeholder(self):
        # GoalContract allows an empty desired_end_state.
        summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf",
            goal=_default_goal(desired_end_state=""),
            work_item=_default_work_item(),
        )
        text = summary.evaluation_summary
        assert "Desired end state: (unspecified)" in text

    def test_populated_evaluation_renders_every_field(self):
        evaluation = contracts.EvaluationContract(
            required_tests=(
                "tests/runtime/test_foo.py",
                "tests/runtime/test_bar.py",
            ),
            required_evidence=("pytest -v output", "coverage report"),
            rollback_boundary="git restore runtime/core/foo.py",
            acceptance_notes="Green on full runtime suite",
        )
        summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf",
            goal=_default_goal(desired_end_state="Ship the slice"),
            work_item=_default_work_item(evaluation=evaluation),
        )
        text = summary.evaluation_summary
        assert "Ship the slice" in text
        assert "tests/runtime/test_foo.py" in text
        assert "tests/runtime/test_bar.py" in text
        assert "pytest -v output" in text
        assert "coverage report" in text
        assert "Green on full runtime suite" in text
        # Populated fields should not carry the (none) placeholder.
        assert "Required tests:\n  - (none)" not in text
        assert "Required evidence:\n  - (none)" not in text

    def test_evaluation_summary_is_non_empty_even_with_fully_empty_evaluation(
        self,
    ):
        summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf",
            goal=_default_goal(desired_end_state=""),
            work_item=_default_work_item(
                evaluation=contracts.EvaluationContract()
            ),
        )
        assert summary.evaluation_summary.strip() != ""


class TestRollbackBoundaryRendering:
    def test_populated_rollback_preserved_verbatim(self):
        evaluation = contracts.EvaluationContract(
            rollback_boundary="git checkout -- runtime/core/foo.py",
        )
        summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf",
            goal=_default_goal(),
            work_item=_default_work_item(evaluation=evaluation),
        )
        assert summary.rollback_boundary == "git checkout -- runtime/core/foo.py"

    def test_blank_rollback_uses_unspecified_placeholder(self):
        summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf",
            goal=_default_goal(),
            work_item=_default_work_item(
                evaluation=contracts.EvaluationContract(rollback_boundary="")
            ),
        )
        assert summary.rollback_boundary == "(unspecified)"

    def test_whitespace_only_rollback_uses_placeholder(self):
        summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf",
            goal=_default_goal(),
            work_item=_default_work_item(
                evaluation=contracts.EvaluationContract(rollback_boundary="   \n")
            ),
        )
        assert summary.rollback_boundary == "(unspecified)"

    def test_rollback_boundary_is_always_non_empty(self):
        # WorkflowContractSummary rejects empty strings; the helper
        # must always produce a non-empty rollback_boundary.
        for boundary in ("", "   ", "\n\t", "git revert HEAD"):
            summary = ppr.workflow_summary_from_contracts(
                workflow_id="wf",
                goal=_default_goal(),
                work_item=_default_work_item(
                    evaluation=contracts.EvaluationContract(
                        rollback_boundary=boundary
                    )
                ),
            )
            assert summary.rollback_boundary.strip() != ""


class TestWorkflowSummaryContractsIntegration:
    def test_helper_output_feeds_resolve_prompt_pack_layers(self):
        goal = _default_goal()
        work_item = _default_work_item()
        summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf-int", goal=goal, work_item=work_item
        )
        layers = ppr.resolve_prompt_pack_layers(
            stage=sr.PLANNER,
            workflow_summary=summary,
            decision_summary=_default_decision_summary(),
            runtime_state_summary=_default_runtime_state(),
        )
        assert set(layers.keys()) == set(pp.CANONICAL_LAYER_ORDER)
        # The workflow_contract layer must equal the summary's
        # render() output.
        assert layers[pp.LAYER_WORKFLOW_CONTRACT] == summary.render()

    def test_helper_output_feeds_build_prompt_pack_end_to_end(self):
        goal = _default_goal()
        work_item = _default_work_item(
            scope=contracts.ScopeManifest(
                allowed_paths=("runtime/core/**",),
                required_paths=("runtime/core/prompt_pack_resolver.py",),
                state_domains=("contracts",),
            ),
            evaluation=contracts.EvaluationContract(
                required_tests=("tests/runtime/test_prompt_pack_resolver.py",),
                rollback_boundary="git restore runtime/core/prompt_pack_resolver.py",
                acceptance_notes="Resolver + bridge tests pass",
            ),
        )
        summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf-e2e", goal=goal, work_item=work_item
        )
        layers = ppr.resolve_prompt_pack_layers(
            stage=sr.PLANNER,
            workflow_summary=summary,
            decision_summary=_default_decision_summary(),
            runtime_state_summary=_default_runtime_state(),
        )
        pack = pp.build_prompt_pack(
            workflow_id="wf-e2e",
            stage_id=sr.PLANNER,
            layers=layers,
            generated_at=1_700_000_000,
        )
        assert pack.workflow_id == "wf-e2e"
        assert pack.stage_id == sr.PLANNER
        assert pack.layer_names == pp.CANONICAL_LAYER_ORDER
        assert pack.content_hash.startswith("sha256:")

    def test_contract_field_changes_flow_through_content_hash(self):
        goal = _default_goal()
        base_work_item = _default_work_item(
            evaluation=contracts.EvaluationContract(
                rollback_boundary="original"
            )
        )
        mutated_work_item = _default_work_item(
            evaluation=contracts.EvaluationContract(
                rollback_boundary="mutated"
            )
        )

        base_summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf", goal=goal, work_item=base_work_item
        )
        mutated_summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf", goal=goal, work_item=mutated_work_item
        )

        base_layers = ppr.resolve_prompt_pack_layers(
            stage=sr.PLANNER,
            workflow_summary=base_summary,
            decision_summary=_default_decision_summary(),
            runtime_state_summary=_default_runtime_state(),
        )
        mutated_layers = ppr.resolve_prompt_pack_layers(
            stage=sr.PLANNER,
            workflow_summary=mutated_summary,
            decision_summary=_default_decision_summary(),
            runtime_state_summary=_default_runtime_state(),
        )

        base_pack = pp.build_prompt_pack(
            workflow_id="wf",
            stage_id=sr.PLANNER,
            layers=base_layers,
            generated_at=1,
        )
        mutated_pack = pp.build_prompt_pack(
            workflow_id="wf",
            stage_id=sr.PLANNER,
            layers=mutated_layers,
            generated_at=1,
        )

        # Changing a contract field must flow through the compiler's
        # content hash — proof that the bridge is wired end-to-end.
        assert base_pack.content_hash != mutated_pack.content_hash


# ---------------------------------------------------------------------------
# 9. local_decision_summary_from_records — bridge from decision_work_registry
#
# Pinned invariants:
#   * Empty tuple → default LocalDecisionSummary semantics.
#   * Wrong container type (list / generator / other iterable) raises.
#   * Non-DecisionRecord element raises with the offending index.
#   * Duplicate decision_id values raise.
#   * Canonical order is (created_at, decision_id) and is independent of
#     caller tuple order.
#   * relevant_decision_ids mirrors the normalized order.
#   * supersession_notes are mechanically derived from `supersedes` links,
#     deduplicated, and sorted lexicographically.
#   * rationale lists active head decisions (status == accepted AND
#     superseded_by is None) when any exist; otherwise degrades into a
#     count-only fallback.
#   * Integration: the helper's output can be fed into
#     resolve_prompt_pack_layers and then into build_prompt_pack.
#   * Content-hash propagation: mutating a decision record changes the
#     compiled PromptPack.content_hash.
# ---------------------------------------------------------------------------


def _mk_decision(
    decision_id: str,
    status: str = "accepted",
    *,
    created_at: int = 100,
    supersedes: str | None = None,
    superseded_by: str | None = None,
    title: str = "Decision title",
    rationale: str = "decision rationale",
    version: int = 1,
    author: str = "planner",
    scope: str = "slice",
) -> dwr.DecisionRecord:
    """Build an in-memory DecisionRecord without touching SQLite."""
    return dwr.DecisionRecord(
        decision_id=decision_id,
        title=title,
        status=status,
        rationale=rationale,
        version=version,
        author=author,
        scope=scope,
        supersedes=supersedes,
        superseded_by=superseded_by,
        created_at=created_at,
        updated_at=created_at,
    )


class TestLocalDecisionSummaryFromRecordsValidation:
    def test_empty_tuple_returns_default_summary(self):
        summary = ppr.local_decision_summary_from_records(decisions=())
        assert summary == ppr.LocalDecisionSummary()
        assert summary.rationale == "(no relevant decisions)"
        assert summary.relevant_decision_ids == ()
        assert summary.supersession_notes == ()

    def test_non_tuple_input_rejected(self):
        with pytest.raises(ValueError, match="must be a tuple"):
            ppr.local_decision_summary_from_records(
                decisions=[_mk_decision("DEC-A")]  # type: ignore[arg-type]
            )

    def test_generator_input_rejected(self):
        def _gen():
            yield _mk_decision("DEC-A")

        with pytest.raises(ValueError, match="must be a tuple"):
            ppr.local_decision_summary_from_records(
                decisions=_gen()  # type: ignore[arg-type]
            )

    def test_non_decision_record_element_rejected(self):
        with pytest.raises(ValueError, match="DecisionRecord"):
            ppr.local_decision_summary_from_records(
                decisions=("not-a-record",)  # type: ignore[arg-type]
            )

    def test_non_decision_record_element_reports_index(self):
        with pytest.raises(ValueError, match=r"decisions\[1\]"):
            ppr.local_decision_summary_from_records(
                decisions=(
                    _mk_decision("DEC-A"),
                    "bad",  # type: ignore[arg-type]
                ),
            )

    def test_duplicate_decision_id_rejected(self):
        with pytest.raises(ValueError, match="duplicate decision_id"):
            ppr.local_decision_summary_from_records(
                decisions=(
                    _mk_decision("DEC-A", created_at=100),
                    _mk_decision("DEC-A", created_at=200),
                )
            )

    def test_duplicate_detection_names_the_duplicate(self):
        with pytest.raises(ValueError) as exc:
            ppr.local_decision_summary_from_records(
                decisions=(
                    _mk_decision("DEC-A"),
                    _mk_decision("DEC-B"),
                    _mk_decision("DEC-A"),
                )
            )
        assert "DEC-A" in str(exc.value)


class TestLocalDecisionSummaryCanonicalOrder:
    def test_canonical_order_by_created_at(self):
        summary = ppr.local_decision_summary_from_records(
            decisions=(
                _mk_decision("DEC-LATER", created_at=200),
                _mk_decision("DEC-EARLIER", created_at=100),
            )
        )
        assert summary.relevant_decision_ids == ("DEC-EARLIER", "DEC-LATER")

    def test_canonical_order_tiebreak_by_decision_id(self):
        summary = ppr.local_decision_summary_from_records(
            decisions=(
                _mk_decision("DEC-Z", created_at=100),
                _mk_decision("DEC-A", created_at=100),
                _mk_decision("DEC-M", created_at=100),
            )
        )
        assert summary.relevant_decision_ids == ("DEC-A", "DEC-M", "DEC-Z")

    def test_output_independent_of_caller_tuple_order(self):
        a = ppr.local_decision_summary_from_records(
            decisions=(
                _mk_decision("DEC-A", created_at=100),
                _mk_decision("DEC-B", created_at=200),
            )
        )
        b = ppr.local_decision_summary_from_records(
            decisions=(
                _mk_decision("DEC-B", created_at=200),
                _mk_decision("DEC-A", created_at=100),
            )
        )
        assert a == b

    def test_deterministic_output_for_identical_input(self):
        records = (
            _mk_decision("DEC-A", created_at=100),
            _mk_decision("DEC-B", created_at=200),
        )
        assert ppr.local_decision_summary_from_records(
            decisions=records
        ) == ppr.local_decision_summary_from_records(decisions=records)


class TestLocalDecisionSummaryRationale:
    def test_single_accepted_head_listed_in_rationale(self):
        summary = ppr.local_decision_summary_from_records(
            decisions=(_mk_decision("DEC-HEAD", "accepted"),)
        )
        assert summary.rationale == "Active head decisions: DEC-HEAD"

    def test_multiple_accepted_heads_listed_in_canonical_order(self):
        summary = ppr.local_decision_summary_from_records(
            decisions=(
                _mk_decision("DEC-ALPHA", "accepted", created_at=100),
                _mk_decision("DEC-BETA", "accepted", created_at=200),
            )
        )
        assert summary.rationale == "Active head decisions: DEC-ALPHA, DEC-BETA"

    def test_superseded_record_is_not_an_active_head(self):
        summary = ppr.local_decision_summary_from_records(
            decisions=(
                _mk_decision(
                    "DEC-OLD",
                    "superseded",
                    created_at=100,
                    superseded_by="DEC-NEW",
                ),
                _mk_decision(
                    "DEC-NEW",
                    "accepted",
                    created_at=200,
                    supersedes="DEC-OLD",
                ),
            )
        )
        assert summary.rationale == "Active head decisions: DEC-NEW"

    def test_fully_superseded_population_degrades(self):
        summary = ppr.local_decision_summary_from_records(
            decisions=(
                _mk_decision(
                    "DEC-OLD",
                    "superseded",
                    created_at=100,
                    superseded_by="DEC-EXTERNAL",
                ),
            )
        )
        assert (
            summary.rationale
            == "No active head decisions among 1 decision record(s)."
        )

    def test_rejected_only_population_degrades(self):
        summary = ppr.local_decision_summary_from_records(
            decisions=(
                _mk_decision("DEC-R1", "rejected"),
                _mk_decision("DEC-R2", "rejected", created_at=200),
            )
        )
        assert "No active head decisions" in summary.rationale
        assert "2 decision record(s)" in summary.rationale

    def test_deprecated_only_population_degrades(self):
        summary = ppr.local_decision_summary_from_records(
            decisions=(_mk_decision("DEC-D", "deprecated"),)
        )
        assert "No active head decisions" in summary.rationale

    def test_proposed_only_population_is_not_an_active_head(self):
        # Proposed decisions are candidates, not authorities. The
        # bridge rule is strict: only ``accepted`` + unsuperseded
        # counts as an active head.
        summary = ppr.local_decision_summary_from_records(
            decisions=(_mk_decision("DEC-P", "proposed"),)
        )
        assert "No active head decisions" in summary.rationale

    def test_accepted_but_superseded_is_not_an_active_head(self):
        # An inconsistent but legal record: status=accepted with a
        # superseded_by link set. The bridge's rule treats the
        # ``superseded_by`` link as the head signal, so this record
        # does NOT count as active.
        summary = ppr.local_decision_summary_from_records(
            decisions=(
                _mk_decision(
                    "DEC-X",
                    "accepted",
                    superseded_by="DEC-Y",
                ),
            )
        )
        assert "No active head decisions" in summary.rationale

    def test_mixed_active_and_superseded_only_lists_active(self):
        summary = ppr.local_decision_summary_from_records(
            decisions=(
                _mk_decision(
                    "DEC-OLD",
                    "superseded",
                    created_at=100,
                    superseded_by="DEC-NEW",
                ),
                _mk_decision(
                    "DEC-NEW",
                    "accepted",
                    created_at=200,
                    supersedes="DEC-OLD",
                ),
                _mk_decision("DEC-OTHER", "accepted", created_at=300),
            )
        )
        # Canonical order for active heads is (created_at,
        # decision_id): DEC-NEW (200) then DEC-OTHER (300).
        assert (
            summary.rationale
            == "Active head decisions: DEC-NEW, DEC-OTHER"
        )


class TestLocalDecisionSummarySupersessionNotes:
    def test_single_link_produces_one_note(self):
        summary = ppr.local_decision_summary_from_records(
            decisions=(
                _mk_decision("DEC-A", "superseded", superseded_by="DEC-B"),
                _mk_decision("DEC-B", "accepted", supersedes="DEC-A"),
            )
        )
        assert summary.supersession_notes == ("DEC-B supersedes DEC-A",)

    def test_multiple_links_are_sorted_lexicographically(self):
        summary = ppr.local_decision_summary_from_records(
            decisions=(
                _mk_decision(
                    "DEC-OLD-1",
                    "superseded",
                    created_at=100,
                    superseded_by="DEC-MID",
                ),
                _mk_decision(
                    "DEC-MID",
                    "superseded",
                    created_at=200,
                    supersedes="DEC-OLD-1",
                    superseded_by="DEC-NEW",
                ),
                _mk_decision(
                    "DEC-NEW",
                    "accepted",
                    created_at=300,
                    supersedes="DEC-MID",
                ),
            )
        )
        assert summary.supersession_notes == (
            "DEC-MID supersedes DEC-OLD-1",
            "DEC-NEW supersedes DEC-MID",
        )

    def test_record_without_supersedes_link_emits_no_note(self):
        summary = ppr.local_decision_summary_from_records(
            decisions=(_mk_decision("DEC-A", "accepted"),)
        )
        assert summary.supersession_notes == ()

    def test_duplicate_notes_are_deduplicated(self):
        # Two records cannot legitimately carry the same (new, old)
        # pair because decision_ids are unique, but the de-dup logic
        # still needs to be tested for cases where the set-based
        # derivation would see the same string produced twice.
        # Here we exploit the fact that duplicate decision_ids are
        # rejected elsewhere and just prove the set is used: a
        # single link produces exactly one note.
        summary = ppr.local_decision_summary_from_records(
            decisions=(
                _mk_decision("DEC-A", "superseded", superseded_by="DEC-B"),
                _mk_decision("DEC-B", "accepted", supersedes="DEC-A"),
            )
        )
        assert len(summary.supersession_notes) == 1


class TestLocalDecisionSummaryIntegration:
    def test_helper_output_feeds_resolve_prompt_pack_layers(self):
        records = (
            _mk_decision("DEC-A", "accepted", created_at=100),
            _mk_decision("DEC-B", "accepted", created_at=200),
        )
        dec_summary = ppr.local_decision_summary_from_records(decisions=records)
        layers = ppr.resolve_prompt_pack_layers(
            stage=sr.PLANNER,
            workflow_summary=_default_workflow_summary(),
            decision_summary=dec_summary,
            runtime_state_summary=_default_runtime_state(),
        )
        assert set(layers.keys()) == set(pp.CANONICAL_LAYER_ORDER)
        assert layers[pp.LAYER_LOCAL_DECISION_PACK] == dec_summary.render()

    def test_helper_output_feeds_build_prompt_pack_end_to_end(self):
        records = (
            _mk_decision(
                "DEC-OLD",
                "superseded",
                created_at=100,
                superseded_by="DEC-NEW",
            ),
            _mk_decision(
                "DEC-NEW",
                "accepted",
                created_at=200,
                supersedes="DEC-OLD",
            ),
        )
        dec_summary = ppr.local_decision_summary_from_records(decisions=records)
        layers = ppr.resolve_prompt_pack_layers(
            stage=sr.PLANNER,
            workflow_summary=_default_workflow_summary(),
            decision_summary=dec_summary,
            runtime_state_summary=_default_runtime_state(),
        )
        pack = pp.build_prompt_pack(
            workflow_id="wf-e2e",
            stage_id=sr.PLANNER,
            layers=layers,
            generated_at=1_700_000_000,
        )
        assert pack.workflow_id == "wf-e2e"
        assert pack.layer_names == pp.CANONICAL_LAYER_ORDER
        assert pack.content_hash.startswith("sha256:")

    def test_decision_record_changes_flow_through_content_hash(self):
        base_records = (_mk_decision("DEC-A", "accepted"),)
        mutated_records = (
            _mk_decision(
                "DEC-A",
                "superseded",
                superseded_by="DEC-B",
            ),
            _mk_decision(
                "DEC-B",
                "accepted",
                created_at=200,
                supersedes="DEC-A",
            ),
        )

        def _pack(records):
            dec = ppr.local_decision_summary_from_records(decisions=records)
            layers = ppr.resolve_prompt_pack_layers(
                stage=sr.PLANNER,
                workflow_summary=_default_workflow_summary(),
                decision_summary=dec,
                runtime_state_summary=_default_runtime_state(),
            )
            return pp.build_prompt_pack(
                workflow_id="wf",
                stage_id=sr.PLANNER,
                layers=layers,
                generated_at=1,
            )

        base_hash = _pack(base_records).content_hash
        mutated_hash = _pack(mutated_records).content_hash
        # Adding a supersession chain flips both the rationale and
        # the supersession_notes, which must flow through the
        # compiler's content hash.
        assert base_hash != mutated_hash

    def test_empty_helper_output_matches_manual_default(self):
        # A caller that uses the helper with no records should get
        # exactly the same layers as a caller that constructs
        # LocalDecisionSummary() manually.
        via_helper = ppr.resolve_prompt_pack_layers(
            stage=sr.PLANNER,
            workflow_summary=_default_workflow_summary(),
            decision_summary=ppr.local_decision_summary_from_records(
                decisions=()
            ),
            runtime_state_summary=_default_runtime_state(),
        )
        via_manual = ppr.resolve_prompt_pack_layers(
            stage=sr.PLANNER,
            workflow_summary=_default_workflow_summary(),
            decision_summary=ppr.LocalDecisionSummary(),
            runtime_state_summary=_default_runtime_state(),
        )
        assert via_helper == via_manual


# ---------------------------------------------------------------------------
# 10. runtime_state_summary_from_snapshot — typed snapshot bridge
#
# Pinned invariants:
#   * RuntimeStateSnapshot dataclass enforces non-empty strings for
#     current_branch / worktree_path and tuple-of-non-empty-strings
#     for active_leases / open_approvals / unresolved_findings.
#   * Snapshot is frozen.
#   * The bridge rejects wrong container types with a ValueError that
#     names RuntimeStateSnapshot.
#   * Tuple fields are sorted lexicographically on the way through
#     the bridge, so the output is independent of snapshot tuple
#     order.
#   * Empty collection fields are preserved as empty tuples, letting
#     the existing RuntimeStateSummary.render() path emit its (none)
#     markers.
#   * Integration: the helper's output feeds into
#     resolve_prompt_pack_layers and then into build_prompt_pack.
#   * Content-hash propagation: mutating a snapshot field changes the
#     compiled PromptPack.content_hash.
# ---------------------------------------------------------------------------


def _default_snapshot(**overrides) -> ppr.RuntimeStateSnapshot:
    kwargs = dict(
        current_branch="feature-x",
        worktree_path="/repo/.worktrees/x",
        active_leases=("lease-abc-123",),
        open_approvals=(),
        unresolved_findings=(),
    )
    kwargs.update(overrides)
    return ppr.RuntimeStateSnapshot(**kwargs)


class TestRuntimeStateSnapshotValidation:
    def test_valid_construction(self):
        snap = _default_snapshot()
        assert snap.current_branch == "feature-x"
        assert snap.active_leases == ("lease-abc-123",)

    def test_frozen(self):
        snap = _default_snapshot()
        with pytest.raises(Exception):
            snap.current_branch = "mutation"  # type: ignore[misc]

    def test_empty_current_branch_rejected(self):
        with pytest.raises(ValueError, match="current_branch"):
            ppr.RuntimeStateSnapshot(
                current_branch="", worktree_path="/repo"
            )

    def test_whitespace_only_current_branch_rejected(self):
        with pytest.raises(ValueError, match="current_branch"):
            ppr.RuntimeStateSnapshot(
                current_branch="   ", worktree_path="/repo"
            )

    def test_empty_worktree_path_rejected(self):
        with pytest.raises(ValueError, match="worktree_path"):
            ppr.RuntimeStateSnapshot(
                current_branch="main", worktree_path=""
            )

    def test_non_tuple_active_leases_rejected(self):
        with pytest.raises(ValueError, match="active_leases"):
            ppr.RuntimeStateSnapshot(
                current_branch="main",
                worktree_path="/repo",
                active_leases=["lease-1"],  # type: ignore[arg-type]
            )

    def test_non_tuple_open_approvals_rejected(self):
        with pytest.raises(ValueError, match="open_approvals"):
            ppr.RuntimeStateSnapshot(
                current_branch="main",
                worktree_path="/repo",
                open_approvals=["approval-1"],  # type: ignore[arg-type]
            )

    def test_non_tuple_unresolved_findings_rejected(self):
        with pytest.raises(ValueError, match="unresolved_findings"):
            ppr.RuntimeStateSnapshot(
                current_branch="main",
                worktree_path="/repo",
                unresolved_findings=["finding-1"],  # type: ignore[arg-type]
            )

    def test_empty_string_lease_element_rejected(self):
        with pytest.raises(ValueError, match="active_leases"):
            ppr.RuntimeStateSnapshot(
                current_branch="main",
                worktree_path="/repo",
                active_leases=("lease-1", ""),
            )

    def test_empty_string_approval_element_rejected(self):
        with pytest.raises(ValueError, match="open_approvals"):
            ppr.RuntimeStateSnapshot(
                current_branch="main",
                worktree_path="/repo",
                open_approvals=("",),
            )

    def test_empty_string_finding_element_rejected(self):
        with pytest.raises(ValueError, match="unresolved_findings"):
            ppr.RuntimeStateSnapshot(
                current_branch="main",
                worktree_path="/repo",
                unresolved_findings=("finding-1", ""),
            )

    def test_optional_collections_default_empty(self):
        snap = ppr.RuntimeStateSnapshot(
            current_branch="main", worktree_path="/repo"
        )
        assert snap.active_leases == ()
        assert snap.open_approvals == ()
        assert snap.unresolved_findings == ()


class TestRuntimeStateSummaryFromSnapshot:
    def test_returns_runtime_state_summary_instance(self):
        summary = ppr.runtime_state_summary_from_snapshot(
            snapshot=_default_snapshot()
        )
        assert isinstance(summary, ppr.RuntimeStateSummary)

    def test_non_snapshot_rejected(self):
        with pytest.raises(ValueError, match="RuntimeStateSnapshot"):
            ppr.runtime_state_summary_from_snapshot(
                snapshot={"current_branch": "main"}  # type: ignore[arg-type]
            )

    def test_none_rejected(self):
        with pytest.raises(ValueError, match="RuntimeStateSnapshot"):
            ppr.runtime_state_summary_from_snapshot(
                snapshot=None  # type: ignore[arg-type]
            )

    def test_raw_runtime_state_summary_rejected(self):
        # A bare RuntimeStateSummary is NOT a RuntimeStateSnapshot — the
        # helper is strict about its input type.
        with pytest.raises(ValueError, match="RuntimeStateSnapshot"):
            ppr.runtime_state_summary_from_snapshot(
                snapshot=_default_runtime_state()  # type: ignore[arg-type]
            )

    def test_current_branch_passthrough(self):
        summary = ppr.runtime_state_summary_from_snapshot(
            snapshot=_default_snapshot(current_branch="main-branch")
        )
        assert summary.current_branch == "main-branch"

    def test_worktree_path_passthrough(self):
        summary = ppr.runtime_state_summary_from_snapshot(
            snapshot=_default_snapshot(worktree_path="/tmp/custom")
        )
        assert summary.worktree_path == "/tmp/custom"

    def test_active_leases_sorted_lexicographically(self):
        summary = ppr.runtime_state_summary_from_snapshot(
            snapshot=_default_snapshot(
                active_leases=("lease-z", "lease-a", "lease-m")
            )
        )
        assert summary.active_leases == ("lease-a", "lease-m", "lease-z")

    def test_open_approvals_sorted_lexicographically(self):
        summary = ppr.runtime_state_summary_from_snapshot(
            snapshot=_default_snapshot(
                open_approvals=("push-B", "rebase-A")
            )
        )
        assert summary.open_approvals == ("push-B", "rebase-A")

    def test_unresolved_findings_sorted_lexicographically(self):
        summary = ppr.runtime_state_summary_from_snapshot(
            snapshot=_default_snapshot(
                unresolved_findings=("finding-Z", "finding-A")
            )
        )
        assert summary.unresolved_findings == ("finding-A", "finding-Z")

    def test_order_independence_across_snapshots(self):
        a = ppr.runtime_state_summary_from_snapshot(
            snapshot=_default_snapshot(
                active_leases=("x", "y", "z"),
                open_approvals=("a", "b"),
                unresolved_findings=("p", "q"),
            )
        )
        b = ppr.runtime_state_summary_from_snapshot(
            snapshot=_default_snapshot(
                active_leases=("z", "y", "x"),
                open_approvals=("b", "a"),
                unresolved_findings=("q", "p"),
            )
        )
        assert a == b

    def test_deterministic_output_for_identical_input(self):
        snap = _default_snapshot(
            active_leases=("x",),
            open_approvals=("a",),
            unresolved_findings=("p",),
        )
        assert ppr.runtime_state_summary_from_snapshot(
            snapshot=snap
        ) == ppr.runtime_state_summary_from_snapshot(snapshot=snap)

    def test_empty_collections_preserved_as_empty(self):
        summary = ppr.runtime_state_summary_from_snapshot(
            snapshot=_default_snapshot(
                active_leases=(),
                open_approvals=(),
                unresolved_findings=(),
            )
        )
        assert summary.active_leases == ()
        assert summary.open_approvals == ()
        assert summary.unresolved_findings == ()

    def test_empty_collections_render_as_none_markers(self):
        summary = ppr.runtime_state_summary_from_snapshot(
            snapshot=ppr.RuntimeStateSnapshot(
                current_branch="main", worktree_path="/repo"
            )
        )
        rendered = summary.render()
        # The existing RuntimeStateSummary.render() produces these
        # exact markers — the bridge must not duplicate or change
        # that logic.
        assert "Active leases: (none)" in rendered
        assert "Open approvals: (none)" in rendered
        assert "Unresolved findings: (none)" in rendered

    def test_populated_collections_render_as_bulleted_lists(self):
        summary = ppr.runtime_state_summary_from_snapshot(
            snapshot=_default_snapshot(
                active_leases=("lease-1", "lease-2"),
                open_approvals=("push-1",),
                unresolved_findings=("finding-1",),
            )
        )
        rendered = summary.render()
        assert "lease-1" in rendered
        assert "lease-2" in rendered
        assert "push-1" in rendered
        assert "finding-1" in rendered
        # Sorted order is preserved in the rendered text too.
        assert rendered.find("lease-1") < rendered.find("lease-2")


class TestRuntimeStateSnapshotIntegration:
    def _feed_into_pack(
        self, snapshot: ppr.RuntimeStateSnapshot
    ) -> pp.PromptPack:
        rt = ppr.runtime_state_summary_from_snapshot(snapshot=snapshot)
        layers = ppr.resolve_prompt_pack_layers(
            stage=sr.PLANNER,
            workflow_summary=_default_workflow_summary(),
            decision_summary=_default_decision_summary(),
            runtime_state_summary=rt,
        )
        return pp.build_prompt_pack(
            workflow_id="wf-rt",
            stage_id=sr.PLANNER,
            layers=layers,
            generated_at=1_700_000_000,
        )

    def test_helper_output_feeds_resolve_prompt_pack_layers(self):
        rt = ppr.runtime_state_summary_from_snapshot(
            snapshot=_default_snapshot()
        )
        layers = ppr.resolve_prompt_pack_layers(
            stage=sr.PLANNER,
            workflow_summary=_default_workflow_summary(),
            decision_summary=_default_decision_summary(),
            runtime_state_summary=rt,
        )
        assert set(layers.keys()) == set(pp.CANONICAL_LAYER_ORDER)
        assert layers[pp.LAYER_RUNTIME_STATE_PACK] == rt.render()

    def test_helper_output_feeds_build_prompt_pack_end_to_end(self):
        pack = self._feed_into_pack(_default_snapshot())
        assert pack.workflow_id == "wf-rt"
        assert pack.stage_id == sr.PLANNER
        assert pack.layer_names == pp.CANONICAL_LAYER_ORDER
        assert pack.content_hash.startswith("sha256:")

    def test_branch_change_flows_through_content_hash(self):
        base = self._feed_into_pack(
            _default_snapshot(current_branch="branch-before")
        )
        mutated = self._feed_into_pack(
            _default_snapshot(current_branch="branch-after")
        )
        assert base.content_hash != mutated.content_hash

    def test_lease_addition_flows_through_content_hash(self):
        base = self._feed_into_pack(
            _default_snapshot(active_leases=("lease-a",))
        )
        mutated = self._feed_into_pack(
            _default_snapshot(active_leases=("lease-a", "lease-b"))
        )
        assert base.content_hash != mutated.content_hash

    def test_finding_addition_flows_through_content_hash(self):
        base = self._feed_into_pack(
            _default_snapshot(unresolved_findings=())
        )
        mutated = self._feed_into_pack(
            _default_snapshot(unresolved_findings=("new-finding",))
        )
        assert base.content_hash != mutated.content_hash

    def test_snapshot_order_does_not_affect_content_hash(self):
        # Same logical state, different tuple orderings → same
        # content hash thanks to canonical sorting in the bridge.
        forward = self._feed_into_pack(
            _default_snapshot(
                active_leases=("lease-a", "lease-b", "lease-c"),
                open_approvals=("app-1", "app-2"),
                unresolved_findings=("find-a", "find-b"),
            )
        )
        reverse = self._feed_into_pack(
            _default_snapshot(
                active_leases=("lease-c", "lease-b", "lease-a"),
                open_approvals=("app-2", "app-1"),
                unresolved_findings=("find-b", "find-a"),
            )
        )
        assert forward.content_hash == reverse.content_hash

    def test_empty_helper_output_matches_manual_minimal_summary(self):
        # A snapshot with empty collections produces a summary
        # semantically identical to one constructed manually with
        # the same minimal inputs. Content hashes must match.
        via_snapshot = self._feed_into_pack(
            ppr.RuntimeStateSnapshot(
                current_branch="main", worktree_path="/repo"
            )
        )
        manual_rt = ppr.RuntimeStateSummary(
            current_branch="main", worktree_path="/repo"
        )
        manual_layers = ppr.resolve_prompt_pack_layers(
            stage=sr.PLANNER,
            workflow_summary=_default_workflow_summary(),
            decision_summary=_default_decision_summary(),
            runtime_state_summary=manual_rt,
        )
        via_manual = pp.build_prompt_pack(
            workflow_id="wf-rt",
            stage_id=sr.PLANNER,
            layers=manual_layers,
            generated_at=1_700_000_000,
        )
        assert via_snapshot.content_hash == via_manual.content_hash


# ---------------------------------------------------------------------------
# DEC-CLAUDEX-PROMPT-PACK-SCOPE-AUTHORITY-001 — compiled prompt-pack
# scope_summary derives from the workflow_scope enforcement authority.
# When the authoritative record is passed:
#   - scope_summary renders from it (not from work_item.scope)
#   - work_item.scope must match (set equality on the path triad) or
#     compile raises ValueError
# When authoritative record is None:
#   - legacy path: renders from work_item.scope (early-lifecycle only)
# ---------------------------------------------------------------------------


class TestScopeSummaryAuthoritativeSource:

    def test_authoritative_record_overrides_work_item_scope_in_summary(self):
        """When the caller passes workflow_scope_record, scope_summary
        renders from it. The work_item.scope still gates via validation
        (must match), but the TEXT of the summary is the enforcement
        authority's view."""
        wi_scope = contracts.ScopeManifest(
            allowed_paths=("runtime/core/a.py",),
            required_paths=(),
            forbidden_paths=("settings.json",),
        )
        # Authoritative record has the SAME triad (validation passes)
        # but includes authority_domains — which the legacy renderer
        # never emits. If the authoritative path is used, we should
        # see "Authority domains:" in the output.
        auth_record = {
            "workflow_id": "wf-auth",
            "allowed_paths": ["runtime/core/a.py"],
            "required_paths": [],
            "forbidden_paths": ["settings.json"],
            "authority_domains": ["who_landing_authority"],
        }
        summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf-auth",
            goal=_default_goal(),
            work_item=_default_work_item(scope=wi_scope),
            workflow_scope_record=auth_record,
        )
        # Rendered from the authoritative record:
        assert "Authority domains:" in summary.scope_summary
        assert "who_landing_authority" in summary.scope_summary
        # Legacy renderer would emit "State domains:" — which must NOT
        # appear when the authoritative path is taken.
        assert "State domains:" not in summary.scope_summary

    def test_authoritative_scope_change_produces_different_summary(self):
        """The regression the instruction explicitly requires:
        authoritative scope changes and the compiled prompt-pack output
        changes with it. Prior slice had them silently drift — this
        test pins that drift is impossible on this path."""
        wi_scope_v1 = contracts.ScopeManifest(
            allowed_paths=("runtime/core/a.py",),
            required_paths=(),
            forbidden_paths=(),
        )
        auth_v1 = {
            "workflow_id": "wf",
            "allowed_paths": ["runtime/core/a.py"],
            "required_paths": [],
            "forbidden_paths": [],
            "authority_domains": ["d1"],
        }
        wi_scope_v2 = contracts.ScopeManifest(
            allowed_paths=("runtime/core/a.py", "runtime/core/b.py"),
            required_paths=(),
            forbidden_paths=(),
        )
        auth_v2 = {
            "workflow_id": "wf",
            "allowed_paths": ["runtime/core/a.py", "runtime/core/b.py"],
            "required_paths": [],
            "forbidden_paths": [],
            "authority_domains": ["d1"],
        }
        goal = _default_goal()
        summary_v1 = ppr.workflow_summary_from_contracts(
            workflow_id="wf", goal=goal,
            work_item=_default_work_item(scope=wi_scope_v1),
            workflow_scope_record=auth_v1,
        )
        summary_v2 = ppr.workflow_summary_from_contracts(
            workflow_id="wf", goal=goal,
            work_item=_default_work_item(scope=wi_scope_v2),
            workflow_scope_record=auth_v2,
        )
        # The two authoritative records differ → summaries must differ.
        assert summary_v1.scope_summary != summary_v2.scope_summary
        assert "runtime/core/b.py" not in summary_v1.scope_summary
        assert "runtime/core/b.py" in summary_v2.scope_summary

    def test_drift_between_work_item_and_authority_raises_on_allowed(self):
        """work_item.scope.allowed diverges from authoritative.allowed → raise."""
        wi_scope = contracts.ScopeManifest(
            allowed_paths=("runtime/core/a.py",),  # stale
        )
        auth_record = {
            "workflow_id": "wf",
            "allowed_paths": ["runtime/core/b.py"],  # refreshed
            "required_paths": [],
            "forbidden_paths": [],
            "authority_domains": [],
        }
        with pytest.raises(ValueError, match="drifted from the enforcement authority"):
            ppr.workflow_summary_from_contracts(
                workflow_id="wf",
                goal=_default_goal(),
                work_item=_default_work_item(scope=wi_scope),
                workflow_scope_record=auth_record,
            )

    def test_drift_between_work_item_and_authority_raises_on_forbidden(self):
        """Divergence on forbidden_paths triad also fails."""
        wi_scope = contracts.ScopeManifest(
            allowed_paths=("runtime/**",),
            forbidden_paths=("settings.json",),
        )
        auth_record = {
            "workflow_id": "wf",
            "allowed_paths": ["runtime/**"],
            "required_paths": [],
            "forbidden_paths": ["settings.json", "CLAUDE.md"],  # extra
            "authority_domains": [],
        }
        with pytest.raises(ValueError, match="drifted from the enforcement authority"):
            ppr.workflow_summary_from_contracts(
                workflow_id="wf",
                goal=_default_goal(),
                work_item=_default_work_item(scope=wi_scope),
                workflow_scope_record=auth_record,
            )

    def test_drift_error_names_both_surfaces_in_message(self):
        """The deny message must name work_item-extra and workflow_scope-extra
        explicitly so the operator can route the fix."""
        wi_scope = contracts.ScopeManifest(
            allowed_paths=("old/path.py",),
        )
        auth_record = {
            "workflow_id": "wf",
            "allowed_paths": ["new/path.py"],
            "required_paths": [],
            "forbidden_paths": [],
            "authority_domains": [],
        }
        with pytest.raises(ValueError) as ei:
            ppr.workflow_summary_from_contracts(
                workflow_id="wf",
                goal=_default_goal(),
                work_item=_default_work_item(scope=wi_scope),
                workflow_scope_record=auth_record,
            )
        msg = str(ei.value)
        assert "work_item-extra=['old/path.py']" in msg
        assert "workflow_scope-extra=['new/path.py']" in msg

    def test_matching_scopes_allow_and_render_from_authority(self):
        """Matching triad → no raise, rendered from authoritative record."""
        paths = ("runtime/core/x.py",)
        wi_scope = contracts.ScopeManifest(allowed_paths=paths)
        auth_record = {
            "workflow_id": "wf",
            "allowed_paths": list(paths),
            "required_paths": [],
            "forbidden_paths": [],
            "authority_domains": ["d"],
        }
        summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf",
            goal=_default_goal(),
            work_item=_default_work_item(scope=wi_scope),
            workflow_scope_record=auth_record,
        )
        assert "runtime/core/x.py" in summary.scope_summary
        assert "Authority domains:" in summary.scope_summary

    def test_authoritative_path_ignores_state_domains_from_work_item(self):
        """work_item.scope.state_domains is not compared against authority
        (they use different vocabularies). Divergence on state_domains
        alone must not raise."""
        wi_scope = contracts.ScopeManifest(
            allowed_paths=("runtime/a.py",),
            state_domains=("proof_state",),
        )
        auth_record = {
            "workflow_id": "wf",
            "allowed_paths": ["runtime/a.py"],
            "required_paths": [],
            "forbidden_paths": [],
            "authority_domains": ["d"],  # different vocabulary, fine
        }
        # Should not raise.
        summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf",
            goal=_default_goal(),
            work_item=_default_work_item(scope=wi_scope),
            workflow_scope_record=auth_record,
        )
        # Rendered from authority: "Authority domains:" appears,
        # "State domains:" does not.
        assert "Authority domains:" in summary.scope_summary
        assert "State domains:" not in summary.scope_summary

    def test_none_record_emits_no_authoritative_scope_marker(self):
        """DEC-CLAUDEX-PROMPT-PACK-SCOPE-AUTHORITY-002: when the
        caller passes ``workflow_scope_record=None``, the compile
        path MUST emit the explicit no-authoritative-scope marker
        rather than rendering ``work_item.scope`` as if it were
        live law. The work_item's scope is deliberately leaked
        with rich content here to prove it does NOT show up in
        the compiled summary."""
        wi_scope = contracts.ScopeManifest(
            allowed_paths=("runtime/a.py", "tests/**"),
            required_paths=("runtime/core/x.py",),
            forbidden_paths=("settings.json",),
            state_domains=("proof_state",),
        )
        summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf",
            goal=_default_goal(),
            work_item=_default_work_item(scope=wi_scope),
            workflow_scope_record=None,
        )
        # Explicit marker present.
        assert summary.scope_summary == ppr._NO_AUTHORITATIVE_SCOPE_MARKER
        # Operator-facing remediation guidance is in the marker.
        assert "cc-policy workflow scope-set" in summary.scope_summary
        assert "fail-closed" in summary.scope_summary
        # work_item.scope contents must NOT surface on the compile
        # path — none of the work_item paths should appear.
        assert "runtime/a.py" not in summary.scope_summary
        assert "tests/**" not in summary.scope_summary
        assert "runtime/core/x.py" not in summary.scope_summary
        assert "settings.json" not in summary.scope_summary
        # Legacy section labels must NOT appear either (they would
        # indicate the legacy renderer was reached).
        assert "Allowed paths:" not in summary.scope_summary
        assert "Required paths:" not in summary.scope_summary
        assert "Forbidden paths:" not in summary.scope_summary
        assert "State domains:" not in summary.scope_summary
        assert "Authority domains:" not in summary.scope_summary


class TestNoAuthoritativeScopeBehavior:
    """DEC-CLAUDEX-PROMPT-PACK-SCOPE-AUTHORITY-002: pin the compile-path
    fail-loud behaviour when ``workflow_scope_record=None``."""

    def test_marker_is_emitted_when_work_item_scope_is_empty(self):
        """No authoritative row + empty work_item.scope still emits the
        explicit marker, not an empty string or the legacy empty-manifest
        render. Proves the marker is not conditional on work_item content."""
        summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf",
            goal=_default_goal(),
            work_item=_default_work_item(scope=contracts.ScopeManifest()),
            workflow_scope_record=None,
        )
        assert summary.scope_summary == ppr._NO_AUTHORITATIVE_SCOPE_MARKER
        # Must satisfy WorkflowContractSummary's non-empty constraint.
        assert summary.scope_summary.strip() != ""

    def test_marker_names_workflow_scope_set_remediation(self):
        """Operator-facing message must name the exact CLI verb to fix."""
        summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf",
            goal=_default_goal(),
            work_item=_default_work_item(),
            workflow_scope_record=None,
        )
        assert "cc-policy workflow scope-set" in summary.scope_summary
        assert "<workflow_id>" in summary.scope_summary

    def test_marker_calls_out_that_work_item_scope_is_not_rendered(self):
        """Marker text must make it explicit that the omission is
        deliberate — not a missing-data bug."""
        summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf",
            goal=_default_goal(),
            work_item=_default_work_item(),
            workflow_scope_record=None,
        )
        assert "work_item.scope" in summary.scope_summary
        assert "intentionally does not render" in summary.scope_summary

    def test_marker_cannot_be_mistaken_for_an_enforceable_scope(self):
        """The marker must not contain any labelled scope section —
        readers (human or LLM) must not be able to parse it as if it
        were an actual allowed/forbidden list."""
        summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf",
            goal=_default_goal(),
            work_item=_default_work_item(),
            workflow_scope_record=None,
        )
        for label in (
            "Allowed paths:", "Required paths:", "Forbidden paths:",
            "State domains:", "Authority domains:",
        ):
            assert label not in summary.scope_summary, (
                f"marker accidentally carries {label!r} — could be "
                "misread as a real scope block"
            )

    def test_marker_text_is_stable_and_deterministic(self):
        """Two calls with identical inputs produce byte-identical output."""
        kwargs = dict(
            workflow_id="wf",
            goal=_default_goal(),
            work_item=_default_work_item(),
            workflow_scope_record=None,
        )
        first = ppr.workflow_summary_from_contracts(**kwargs)
        second = ppr.workflow_summary_from_contracts(**kwargs)
        assert first.scope_summary == second.scope_summary
        assert first.scope_summary == ppr._NO_AUTHORITATIVE_SCOPE_MARKER

    def test_legacy_helper_is_not_called_on_compile_path(self):
        """Direct instrumentation: if ``workflow_summary_from_contracts``
        ever starts calling ``_render_scope_summary`` on the None path
        again, this test fails."""
        from unittest import mock
        with mock.patch.object(
            ppr, "_render_scope_summary",
            wraps=ppr._render_scope_summary,
        ) as spy:
            ppr.workflow_summary_from_contracts(
                workflow_id="wf",
                goal=_default_goal(),
                work_item=_default_work_item(
                    scope=contracts.ScopeManifest(allowed_paths=("runtime/a.py",))
                ),
                workflow_scope_record=None,
            )
            assert spy.call_count == 0, (
                "_render_scope_summary must not be reachable from "
                "workflow_summary_from_contracts when workflow_scope_record=None"
            )

    def test_empty_authority_domains_renders_none_marker(self):
        """Empty authority_domains list renders the explicit (none) marker."""
        wi_scope = contracts.ScopeManifest(allowed_paths=("x.py",))
        auth_record = {
            "workflow_id": "wf",
            "allowed_paths": ["x.py"],
            "required_paths": [],
            "forbidden_paths": [],
            "authority_domains": [],
        }
        summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf",
            goal=_default_goal(),
            work_item=_default_work_item(scope=wi_scope),
            workflow_scope_record=auth_record,
        )
        assert "Authority domains:\n  - (none)" in summary.scope_summary


class TestScopeAuthoritativeHelpers:
    """Direct unit coverage for the new rendering / validation helpers."""

    def test_render_from_workflow_scope_populates_all_sections(self):
        scope_record = {
            "workflow_id": "wf",
            "allowed_paths": ["a.py", "b.py"],
            "required_paths": ["c.py"],
            "forbidden_paths": ["secret.json"],
            "authority_domains": ["auth-a", "auth-b"],
        }
        out = ppr._render_scope_summary_from_workflow_scope(scope_record)
        assert "Allowed paths:" in out
        assert "  - a.py" in out and "  - b.py" in out
        assert "Required paths:" in out and "  - c.py" in out
        assert "Forbidden paths:" in out and "  - secret.json" in out
        assert "Authority domains:" in out and "  - auth-a" in out

    def test_render_from_workflow_scope_empty_sections_show_explicit_markers(self):
        scope_record = {
            "workflow_id": "wf",
            "allowed_paths": [],
            "required_paths": [],
            "forbidden_paths": [],
            "authority_domains": [],
        }
        out = ppr._render_scope_summary_from_workflow_scope(scope_record)
        assert "Allowed paths:\n  - (unrestricted)" in out
        assert "Required paths:\n  - (none)" in out
        assert "Forbidden paths:\n  - (none)" in out
        assert "Authority domains:\n  - (none)" in out

    def test_validator_passes_on_exact_match(self):
        wi = contracts.ScopeManifest(
            allowed_paths=("a.py",),
            required_paths=("b.py",),
            forbidden_paths=("c.py",),
        )
        auth = {
            "allowed_paths": ["a.py"],
            "required_paths": ["b.py"],
            "forbidden_paths": ["c.py"],
        }
        # Should not raise.
        ppr._validate_work_item_scope_matches_authority(wi, auth)

    def test_validator_order_independence(self):
        """Set equality means path order doesn't affect matching."""
        wi = contracts.ScopeManifest(
            allowed_paths=("a.py", "b.py"),
        )
        auth = {
            "allowed_paths": ["b.py", "a.py"],  # different order
            "required_paths": [],
            "forbidden_paths": [],
        }
        ppr._validate_work_item_scope_matches_authority(wi, auth)

    def test_validator_duplicates_collapsed_via_set_equality(self):
        wi = contracts.ScopeManifest(allowed_paths=("a.py",))
        auth = {
            "allowed_paths": ["a.py", "a.py"],  # duplicates
            "required_paths": [],
            "forbidden_paths": [],
        }
        ppr._validate_work_item_scope_matches_authority(wi, auth)
