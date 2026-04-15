"""Tests for runtime/core/projection_schemas.py.

@decision DEC-CLAUDEX-PROJECTION-SCHEMAS-TESTS-001
Title: Projection schema family — shared metadata, concrete types, and validation invariants are pinned
Status: proposed (shadow-mode, Phase 1 constitutional kernel)
Rationale: CUTOVER_PLAN §Schema Contract Stack §3 declares the
  required-field set for projection schemas as a hard contract. These
  tests pin:

    1. Family identity and version are explicit runtime attributes,
       not docstring prose.
    2. ``ProjectionMetadata`` carries exactly the five fields required
       by CUTOVER_PLAN lines 933-939.
    3. Every concrete projection type named in the CUTOVER_PLAN
       (prompt pack, rendered MASTER_PLAN, decision digest, hook-doc
       projection, graph export, search-index metadata) exists,
       carries a ``SCHEMA_TYPE`` class attribute, and composes a
       ``ProjectionMetadata`` instance.
    4. Constructor invariants reject malformed inputs (missing
       metadata, wrong types, negative timestamps, duplicate
       source_version kinds, boolean timestamps, etc.) so a bad
       projection record cannot silently pass through the schema.
    5. The module stays shadow-only: no imports of live routing,
       policy engine, hooks, settings, or config machinery. AST-based
       inspection, not substring search, so docstring prose never
       triggers false positives.
"""

from __future__ import annotations

import ast
import dataclasses
import inspect

import pytest

from runtime.core import projection_schemas as ps


# ---------------------------------------------------------------------------
# AST helper for shadow-only discipline tests
# ---------------------------------------------------------------------------


def _imported_module_names(module) -> set[str]:
    """Return the set of dotted module names imported by ``module``.

    Walks ``ast.Import`` and ``ast.ImportFrom`` nodes so docstring
    prose that mentions forbidden module names never produces a false
    positive.
    """
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
# Shared constructors used by every projection-type test
# ---------------------------------------------------------------------------


def _stale() -> ps.StaleCondition:
    return ps.StaleCondition(
        rationale="demo",
        watched_authorities=("stage_transitions", "role_capabilities"),
        watched_files=("CLAUDE.md",),
    )


def _metadata() -> ps.ProjectionMetadata:
    return ps.ProjectionMetadata(
        generator_version="0.1.0",
        generated_at=1_700_000_000,
        stale_condition=_stale(),
        source_versions=(
            ("stage_transitions", "v1"),
            ("role_capabilities", "v1"),
        ),
        provenance=(
            ps.SourceRef(
                source_kind="stage_transitions",
                source_id="planner",
                source_version="v1",
            ),
        ),
    )


# ---------------------------------------------------------------------------
# 1. Family version constants
# ---------------------------------------------------------------------------


class TestFamilyVersion:
    def test_schema_family_is_projection(self):
        assert ps.SCHEMA_FAMILY == "projection"

    def test_schema_family_version_is_a_non_empty_string(self):
        assert isinstance(ps.SCHEMA_FAMILY_VERSION, str)
        assert ps.SCHEMA_FAMILY_VERSION != ""

    def test_schema_family_version_is_semver_shaped(self):
        # Three dot-separated components, each numeric. A future bump
        # must update this test deliberately.
        parts = ps.SCHEMA_FAMILY_VERSION.split(".")
        assert len(parts) == 3, (
            f"expected semver-shaped version, got {ps.SCHEMA_FAMILY_VERSION!r}"
        )
        for p in parts:
            assert p.isdigit(), f"version component {p!r} is not numeric"

    def test_current_version_is_1_0_0(self):
        # Pin the initial family version explicitly — bumping is a
        # deliberate bundled change.
        assert ps.SCHEMA_FAMILY_VERSION == "1.0.0"


# ---------------------------------------------------------------------------
# 2. ProjectionMetadata required-field set
# ---------------------------------------------------------------------------


class TestProjectionMetadataFieldSet:
    def test_metadata_has_exactly_the_cutover_plan_required_fields(self):
        field_names = {f.name for f in dataclasses.fields(ps.ProjectionMetadata)}
        # CUTOVER_PLAN §Schema Contract Stack §3 lines 933-939.
        expected = {
            "generator_version",
            "generated_at",
            "stale_condition",
            "source_versions",
            "provenance",
        }
        assert field_names == expected, (
            f"ProjectionMetadata fields differ from CUTOVER_PLAN §3: "
            f"{field_names ^ expected}"
        )

    def test_metadata_is_frozen(self):
        md = _metadata()
        with pytest.raises(dataclasses.FrozenInstanceError):
            md.generator_version = "0.2.0"  # type: ignore[misc]

    def test_source_versions_dict_returns_mapping_view(self):
        md = _metadata()
        view = md.source_versions_dict()
        assert view == {
            "stage_transitions": "v1",
            "role_capabilities": "v1",
        }

    def test_metadata_constructs_with_minimal_arguments(self):
        sc = ps.StaleCondition(rationale="ok")
        md = ps.ProjectionMetadata(
            generator_version="0.1.0",
            generated_at=0,
            stale_condition=sc,
        )
        assert md.source_versions == ()
        assert md.provenance == ()


# ---------------------------------------------------------------------------
# 3. ProjectionMetadata validation invariants
# ---------------------------------------------------------------------------


class TestProjectionMetadataValidation:
    def test_empty_generator_version_rejected(self):
        with pytest.raises(ValueError):
            ps.ProjectionMetadata(
                generator_version="",
                generated_at=0,
                stale_condition=_stale(),
            )

    def test_non_string_generator_version_rejected(self):
        with pytest.raises(ValueError):
            ps.ProjectionMetadata(
                generator_version=1.0,  # type: ignore[arg-type]
                generated_at=0,
                stale_condition=_stale(),
            )

    def test_negative_generated_at_rejected(self):
        with pytest.raises(ValueError):
            ps.ProjectionMetadata(
                generator_version="0.1.0",
                generated_at=-1,
                stale_condition=_stale(),
            )

    def test_boolean_generated_at_rejected(self):
        # bool is a subclass of int in Python — reject it explicitly.
        with pytest.raises(ValueError):
            ps.ProjectionMetadata(
                generator_version="0.1.0",
                generated_at=True,  # type: ignore[arg-type]
                stale_condition=_stale(),
            )

    def test_non_int_generated_at_rejected(self):
        with pytest.raises(ValueError):
            ps.ProjectionMetadata(
                generator_version="0.1.0",
                generated_at="now",  # type: ignore[arg-type]
                stale_condition=_stale(),
            )

    def test_wrong_stale_condition_type_rejected(self):
        with pytest.raises(ValueError):
            ps.ProjectionMetadata(
                generator_version="0.1.0",
                generated_at=0,
                stale_condition="not-a-StaleCondition",  # type: ignore[arg-type]
            )

    def test_source_versions_must_be_tuple(self):
        with pytest.raises(ValueError):
            ps.ProjectionMetadata(
                generator_version="0.1.0",
                generated_at=0,
                stale_condition=_stale(),
                source_versions=[("stage_transitions", "v1")],  # type: ignore[arg-type]
            )

    def test_source_versions_entries_must_be_pairs(self):
        with pytest.raises(ValueError):
            ps.ProjectionMetadata(
                generator_version="0.1.0",
                generated_at=0,
                stale_condition=_stale(),
                source_versions=(("stage_transitions",),),  # type: ignore[arg-type]
            )

    def test_source_versions_duplicate_kind_rejected(self):
        with pytest.raises(ValueError):
            ps.ProjectionMetadata(
                generator_version="0.1.0",
                generated_at=0,
                stale_condition=_stale(),
                source_versions=(
                    ("stage_transitions", "v1"),
                    ("stage_transitions", "v2"),
                ),
            )

    def test_source_versions_empty_strings_rejected(self):
        with pytest.raises(ValueError):
            ps.ProjectionMetadata(
                generator_version="0.1.0",
                generated_at=0,
                stale_condition=_stale(),
                source_versions=(("", "v1"),),
            )
        with pytest.raises(ValueError):
            ps.ProjectionMetadata(
                generator_version="0.1.0",
                generated_at=0,
                stale_condition=_stale(),
                source_versions=(("stage_transitions", ""),),
            )

    def test_provenance_must_be_tuple_of_source_refs(self):
        with pytest.raises(ValueError):
            ps.ProjectionMetadata(
                generator_version="0.1.0",
                generated_at=0,
                stale_condition=_stale(),
                provenance=({"source_kind": "x"},),  # type: ignore[arg-type]
            )


# ---------------------------------------------------------------------------
# 4. SourceRef + StaleCondition invariants
# ---------------------------------------------------------------------------


class TestSourceRefAndStaleCondition:
    def test_source_ref_rejects_empty_fields(self):
        for attr in ("source_kind", "source_id", "source_version"):
            kwargs = {
                "source_kind": "k",
                "source_id": "i",
                "source_version": "v",
            }
            kwargs[attr] = ""
            with pytest.raises(ValueError):
                ps.SourceRef(**kwargs)  # type: ignore[arg-type]

    def test_stale_condition_rejects_empty_rationale(self):
        with pytest.raises(ValueError):
            ps.StaleCondition(rationale="")
        with pytest.raises(ValueError):
            ps.StaleCondition(rationale="   ")

    def test_stale_condition_rejects_non_tuple_lists(self):
        with pytest.raises(ValueError):
            ps.StaleCondition(
                rationale="ok",
                watched_authorities=["stage_transitions"],  # type: ignore[arg-type]
            )

    def test_stale_condition_rejects_empty_string_entries(self):
        with pytest.raises(ValueError):
            ps.StaleCondition(
                rationale="ok",
                watched_files=("CLAUDE.md", ""),
            )

    def test_stale_condition_allows_empty_watched_lists(self):
        sc = ps.StaleCondition(rationale="always-fresh diagnostic snapshot")
        assert sc.watched_authorities == ()
        assert sc.watched_files == ()


# ---------------------------------------------------------------------------
# 5. Concrete projection types — presence and shape
# ---------------------------------------------------------------------------


class TestConcreteProjectionPresence:
    def test_all_required_projection_types_exist(self):
        expected_schema_types = {
            "prompt_pack",
            "rendered_master_plan",
            "decision_digest",
            "hook_doc_projection",
            "graph_export",
            "search_index_metadata",
        }
        assert ps.PROJECTION_TYPE_NAMES == expected_schema_types

    def test_projection_types_registry_has_exactly_six_types(self):
        assert len(ps.PROJECTION_TYPES) == 6

    def test_every_projection_type_has_class_attribute_schema_type(self):
        for cls in ps.PROJECTION_TYPES:
            schema_type = getattr(cls, "SCHEMA_TYPE", None)
            assert isinstance(schema_type, str) and schema_type, (
                f"{cls.__name__} missing SCHEMA_TYPE class attribute"
            )

    def test_every_projection_type_is_a_frozen_dataclass(self):
        for cls in ps.PROJECTION_TYPES:
            assert dataclasses.is_dataclass(cls)
            # Frozen dataclasses have `__dataclass_params__.frozen == True`
            assert cls.__dataclass_params__.frozen is True  # type: ignore[attr-defined]

    def test_projection_type_for_looks_up_by_schema_type(self):
        assert ps.projection_type_for("prompt_pack") is ps.PromptPack
        assert ps.projection_type_for("rendered_master_plan") is ps.RenderedMasterPlan
        assert ps.projection_type_for("decision_digest") is ps.DecisionDigest
        assert ps.projection_type_for("hook_doc_projection") is ps.HookDocProjection
        assert ps.projection_type_for("graph_export") is ps.GraphExport
        assert ps.projection_type_for("search_index_metadata") is ps.SearchIndexMetadata

    def test_projection_type_for_unknown_raises(self):
        with pytest.raises(KeyError):
            ps.projection_type_for("not_a_real_projection")


# ---------------------------------------------------------------------------
# 6. PromptPack
# ---------------------------------------------------------------------------


class TestPromptPack:
    def test_constructs_with_valid_inputs(self):
        pp = ps.PromptPack(
            metadata=_metadata(),
            workflow_id="wf-1",
            stage_id="planner",
            layer_names=("constitution", "stage_contract"),
            content_hash="sha-1",
        )
        assert pp.SCHEMA_TYPE == "prompt_pack"
        assert pp.workflow_id == "wf-1"

    def test_rejects_non_metadata_in_metadata_field(self):
        with pytest.raises(ValueError):
            ps.PromptPack(
                metadata={"generator_version": "0.1"},  # type: ignore[arg-type]
                workflow_id="wf-1",
                stage_id="planner",
                layer_names=("x",),
                content_hash="sha-1",
            )

    def test_rejects_empty_workflow_id(self):
        with pytest.raises(ValueError):
            ps.PromptPack(
                metadata=_metadata(),
                workflow_id="",
                stage_id="planner",
                layer_names=("x",),
                content_hash="sha-1",
            )

    def test_rejects_empty_layer_names(self):
        with pytest.raises(ValueError):
            ps.PromptPack(
                metadata=_metadata(),
                workflow_id="wf-1",
                stage_id="planner",
                layer_names=(),
                content_hash="sha-1",
            )

    def test_rejects_non_tuple_layer_names(self):
        with pytest.raises(ValueError):
            ps.PromptPack(
                metadata=_metadata(),
                workflow_id="wf-1",
                stage_id="planner",
                layer_names=["x"],  # type: ignore[arg-type]
                content_hash="sha-1",
            )

    def test_rejects_empty_content_hash(self):
        with pytest.raises(ValueError):
            ps.PromptPack(
                metadata=_metadata(),
                workflow_id="wf-1",
                stage_id="planner",
                layer_names=("x",),
                content_hash="",
            )


# ---------------------------------------------------------------------------
# 7. RenderedMasterPlan
# ---------------------------------------------------------------------------


class TestRenderedMasterPlan:
    def test_constructs_with_matching_section_count(self):
        rmp = ps.RenderedMasterPlan(
            metadata=_metadata(),
            content_hash="sha-2",
            section_ids=("intro", "phase-1", "phase-2"),
            section_count=3,
        )
        assert rmp.SCHEMA_TYPE == "rendered_master_plan"

    def test_rejects_section_count_mismatch(self):
        with pytest.raises(ValueError):
            ps.RenderedMasterPlan(
                metadata=_metadata(),
                content_hash="sha-2",
                section_ids=("intro",),
                section_count=2,
            )

    def test_rejects_negative_section_count(self):
        with pytest.raises(ValueError):
            ps.RenderedMasterPlan(
                metadata=_metadata(),
                content_hash="sha-2",
                section_ids=(),
                section_count=-1,
            )

    def test_rejects_non_tuple_section_ids(self):
        with pytest.raises(ValueError):
            ps.RenderedMasterPlan(
                metadata=_metadata(),
                content_hash="sha-2",
                section_ids=["a"],  # type: ignore[arg-type]
                section_count=1,
            )

    def test_rejects_empty_content_hash(self):
        with pytest.raises(ValueError):
            ps.RenderedMasterPlan(
                metadata=_metadata(),
                content_hash="",
                section_ids=(),
                section_count=0,
            )

    def test_allows_empty_sections_when_count_is_zero(self):
        rmp = ps.RenderedMasterPlan(
            metadata=_metadata(),
            content_hash="sha-zero",
            section_ids=(),
            section_count=0,
        )
        assert rmp.section_count == 0


# ---------------------------------------------------------------------------
# 8. DecisionDigest
# ---------------------------------------------------------------------------


class TestDecisionDigest:
    def test_constructs_with_valid_inputs(self):
        dd = ps.DecisionDigest(
            metadata=_metadata(),
            decision_ids=("DEC-001", "DEC-002"),
            cutoff_epoch=1_700_000_000,
            content_hash="sha-3",
        )
        assert dd.SCHEMA_TYPE == "decision_digest"

    def test_rejects_non_string_decision_ids(self):
        with pytest.raises(ValueError):
            ps.DecisionDigest(
                metadata=_metadata(),
                decision_ids=("", "DEC-002"),
                cutoff_epoch=0,
                content_hash="sha-3",
            )

    def test_rejects_negative_cutoff(self):
        with pytest.raises(ValueError):
            ps.DecisionDigest(
                metadata=_metadata(),
                decision_ids=(),
                cutoff_epoch=-1,
                content_hash="sha-3",
            )

    def test_rejects_non_tuple_decision_ids(self):
        with pytest.raises(ValueError):
            ps.DecisionDigest(
                metadata=_metadata(),
                decision_ids=["DEC-001"],  # type: ignore[arg-type]
                cutoff_epoch=0,
                content_hash="sha-3",
            )


# ---------------------------------------------------------------------------
# 9. HookDocProjection
# ---------------------------------------------------------------------------


class TestHookDocProjection:
    def test_constructs_with_valid_inputs(self):
        hdp = ps.HookDocProjection(
            metadata=_metadata(),
            events=("PreToolUse", "SubagentStop"),
            matchers=("Bash", "Write"),
            content_hash="sha-4",
        )
        assert hdp.SCHEMA_TYPE == "hook_doc_projection"

    def test_rejects_empty_events(self):
        with pytest.raises(ValueError):
            ps.HookDocProjection(
                metadata=_metadata(),
                events=(),
                matchers=(),
                content_hash="sha-4",
            )

    def test_allows_empty_matchers(self):
        hdp = ps.HookDocProjection(
            metadata=_metadata(),
            events=("SessionStart",),
            matchers=(),
            content_hash="sha-4",
        )
        assert hdp.matchers == ()

    def test_rejects_non_tuple_events(self):
        with pytest.raises(ValueError):
            ps.HookDocProjection(
                metadata=_metadata(),
                events=["X"],  # type: ignore[arg-type]
                matchers=(),
                content_hash="sha-4",
            )


# ---------------------------------------------------------------------------
# 10. GraphExport + SearchIndexMetadata
# ---------------------------------------------------------------------------


class TestGraphExport:
    def test_constructs_with_valid_inputs(self):
        ge = ps.GraphExport(
            metadata=_metadata(),
            node_count=10,
            edge_count=12,
            content_hash="sha-5",
        )
        assert ge.SCHEMA_TYPE == "graph_export"

    def test_rejects_negative_counts(self):
        with pytest.raises(ValueError):
            ps.GraphExport(
                metadata=_metadata(),
                node_count=-1,
                edge_count=0,
                content_hash="sha-5",
            )
        with pytest.raises(ValueError):
            ps.GraphExport(
                metadata=_metadata(),
                node_count=0,
                edge_count=-1,
                content_hash="sha-5",
            )

    def test_rejects_boolean_counts(self):
        with pytest.raises(ValueError):
            ps.GraphExport(
                metadata=_metadata(),
                node_count=True,  # type: ignore[arg-type]
                edge_count=0,
                content_hash="sha-5",
            )


class TestSearchIndexMetadata:
    def test_constructs_with_valid_inputs(self):
        sim = ps.SearchIndexMetadata(
            metadata=_metadata(),
            index_name="claudex-search",
            document_count=42,
            content_hash="sha-6",
        )
        assert sim.SCHEMA_TYPE == "search_index_metadata"

    def test_rejects_empty_index_name(self):
        with pytest.raises(ValueError):
            ps.SearchIndexMetadata(
                metadata=_metadata(),
                index_name="",
                document_count=0,
                content_hash="sha-6",
            )

    def test_rejects_negative_document_count(self):
        with pytest.raises(ValueError):
            ps.SearchIndexMetadata(
                metadata=_metadata(),
                index_name="x",
                document_count=-1,
                content_hash="sha-6",
            )


# ---------------------------------------------------------------------------
# 11. Shadow-only discipline
# ---------------------------------------------------------------------------


class TestShadowOnlyDiscipline:
    def test_projection_schemas_has_no_runtime_core_dependencies(self):
        imported = _imported_module_names(ps)
        runtime_core_imports = {
            name for name in imported if name.startswith("runtime.core")
        }
        assert runtime_core_imports == set(), (
            f"projection_schemas.py unexpectedly depends on {runtime_core_imports}"
        )

    def test_projection_schemas_does_not_import_live_modules(self):
        imported = _imported_module_names(ps)
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
                    f"projection_schemas.py imports {name!r} which contains "
                    f"forbidden live-module token {needle!r}"
                )

    def test_live_modules_do_not_import_projection_schemas(self):
        import runtime.core.completions as completions
        import runtime.core.dispatch_engine as dispatch_engine
        import runtime.core.policy_engine as policy_engine

        for mod in (dispatch_engine, completions, policy_engine):
            imported = _imported_module_names(mod)
            for name in imported:
                assert "projection_schemas" not in name, (
                    f"{mod.__name__} imports {name!r} — projection_schemas "
                    f"must stay shadow-only this slice"
                )
