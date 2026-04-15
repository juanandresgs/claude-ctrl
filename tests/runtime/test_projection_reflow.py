"""Tests for runtime/core/projection_reflow.py.

@decision DEC-CLAUDEX-PROJECTION-REFLOW-TESTS-001
Title: Pure projection reflow staleness rule, deterministic ordering, and shadow-only import discipline are pinned
Status: proposed (shadow-mode, Phase 7 Slice 16 reflow primitive)
Rationale: The reflow planner is the first minimal reflow enforcement
  primitive and must have no behavioural slack. These tests pin:

    1. The staleness rule: a projection is stale iff at least one
       watched authority or watched file appears in the supplied
       change set. Empty watch lists are always fresh.
    2. Deterministic output regardless of input iteration order.
    3. ``matched_authorities`` / ``matched_files`` report the
       concrete reasons a projection was stale.
    4. Accepts both a bare :class:`ProjectionMetadata` and any
       concrete projection dataclass from
       :mod:`runtime.core.projection_schemas` via the shared
       ``.metadata`` attribute.
    5. Malformed inputs (non-str ids, missing metadata, non-string
       change-set items, duplicate ids in batch planner) raise
       :class:`ValueError` rather than silently returning "fresh".
    6. Shadow-only discipline: no imports of live routing, policy,
       hooks, leases, settings, or enforcement machinery. AST-based
       inspection so docstring prose cannot trigger false positives.
    7. ``cli.py`` does not import the reflow module at module scope
       (no CLI wiring in this slice).
"""

from __future__ import annotations

import ast
import inspect
import json

import pytest

from runtime.core import projection_reflow as pr
from runtime.core import projection_schemas as ps


# ---------------------------------------------------------------------------
# AST helper for shadow-only discipline tests
# ---------------------------------------------------------------------------


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
# Constructors
# ---------------------------------------------------------------------------


def _condition(
    *,
    authorities=(),
    files=(),
    rationale="demo rationale",
) -> ps.StaleCondition:
    return ps.StaleCondition(
        rationale=rationale,
        watched_authorities=tuple(authorities),
        watched_files=tuple(files),
    )


def _metadata(
    *,
    condition=None,
    generator_version="1.0.0",
    generated_at=1000,
    source_versions=(),
    provenance=(),
) -> ps.ProjectionMetadata:
    return ps.ProjectionMetadata(
        generator_version=generator_version,
        generated_at=generated_at,
        stale_condition=condition or _condition(),
        source_versions=tuple(source_versions),
        provenance=tuple(provenance),
    )


def _hook_doc_projection(metadata) -> ps.HookDocProjection:
    return ps.HookDocProjection(
        metadata=metadata,
        events=("PreToolUse",),
        matchers=("Write",),
        content_hash="sha256:" + "a" * 64,
    )


def _prompt_pack(metadata) -> ps.PromptPack:
    return ps.PromptPack(
        metadata=metadata,
        workflow_id="wf-1",
        stage_id="implementer",
        layer_names=("constitution", "stage_contract"),
        content_hash="sha256:" + "b" * 64,
    )


def _decision_digest(metadata) -> ps.DecisionDigest:
    return ps.DecisionDigest(
        metadata=metadata,
        decision_ids=("DEC-A",),
        cutoff_epoch=0,
        content_hash="sha256:" + "c" * 64,
    )


# ---------------------------------------------------------------------------
# 1. Status vocabulary
# ---------------------------------------------------------------------------


class TestStatusVocabulary:
    def test_status_constants_are_exactly_fresh_and_stale(self):
        assert pr.REFLOW_STATUS_FRESH == "fresh"
        assert pr.REFLOW_STATUS_STALE == "stale"

    def test_reflow_statuses_tuple_is_ordered_and_closed(self):
        assert pr.REFLOW_STATUSES == ("fresh", "stale")

    def test_status_constants_round_trip_through_set(self):
        assert set(pr.REFLOW_STATUSES) == {
            pr.REFLOW_STATUS_FRESH,
            pr.REFLOW_STATUS_STALE,
        }


# ---------------------------------------------------------------------------
# 2. Extraction helper
# ---------------------------------------------------------------------------


class TestExtractProjectionMetadata:
    def test_bare_metadata_passes_through(self):
        md = _metadata()
        assert pr.extract_projection_metadata(md) is md

    def test_concrete_projection_metadata_is_unwrapped(self):
        md = _metadata()
        proj = _hook_doc_projection(md)
        assert pr.extract_projection_metadata(proj) is md

    def test_prompt_pack_metadata_is_unwrapped(self):
        md = _metadata()
        proj = _prompt_pack(md)
        assert pr.extract_projection_metadata(proj) is md

    def test_decision_digest_metadata_is_unwrapped(self):
        md = _metadata()
        proj = _decision_digest(md)
        assert pr.extract_projection_metadata(proj) is md

    def test_random_object_without_metadata_raises(self):
        class NoMeta:
            pass

        with pytest.raises(ValueError):
            pr.extract_projection_metadata(NoMeta())

    def test_object_with_wrong_metadata_type_raises(self):
        class WrongMeta:
            metadata = "not-a-projection-metadata"

        with pytest.raises(ValueError):
            pr.extract_projection_metadata(WrongMeta())

    def test_none_raises(self):
        with pytest.raises(ValueError):
            pr.extract_projection_metadata(None)


# ---------------------------------------------------------------------------
# 3. Core staleness rule
# ---------------------------------------------------------------------------


class TestAssessProjectionFreshness:
    def test_authority_match_marks_stale(self):
        md = _metadata(condition=_condition(authorities=("stage_transitions",)))
        assessment = pr.assess_projection_freshness(
            "p1",
            md,
            changed_authorities=("stage_transitions",),
            changed_files=(),
        )
        assert assessment.status == pr.REFLOW_STATUS_STALE
        assert assessment.healthy is False
        assert assessment.matched_authorities == ("stage_transitions",)
        assert assessment.matched_files == ()

    def test_file_match_marks_stale(self):
        md = _metadata(condition=_condition(files=("CLAUDE.md",)))
        assessment = pr.assess_projection_freshness(
            "p1",
            md,
            changed_authorities=(),
            changed_files=("CLAUDE.md",),
        )
        assert assessment.status == pr.REFLOW_STATUS_STALE
        assert assessment.matched_files == ("CLAUDE.md",)
        assert assessment.matched_authorities == ()

    def test_no_overlap_is_fresh(self):
        md = _metadata(
            condition=_condition(
                authorities=("stage_transitions",),
                files=("CLAUDE.md",),
            )
        )
        assessment = pr.assess_projection_freshness(
            "p1",
            md,
            changed_authorities=("role_capabilities",),
            changed_files=("README.md",),
        )
        assert assessment.status == pr.REFLOW_STATUS_FRESH
        assert assessment.healthy is True
        assert assessment.matched_authorities == ()
        assert assessment.matched_files == ()

    def test_empty_watch_lists_are_always_fresh(self):
        # StaleCondition allows both watch lists to be empty. The planner
        # honors the explicit opt-out.
        md = _metadata(condition=_condition())
        assessment = pr.assess_projection_freshness(
            "p1",
            md,
            changed_authorities=("stage_transitions", "role_capabilities"),
            changed_files=("CLAUDE.md", "AGENTS.md"),
        )
        assert assessment.status == pr.REFLOW_STATUS_FRESH
        assert assessment.matched_authorities == ()
        assert assessment.matched_files == ()

    def test_both_authority_and_file_match_both_reported(self):
        md = _metadata(
            condition=_condition(
                authorities=("stage_transitions",),
                files=("CLAUDE.md",),
            )
        )
        assessment = pr.assess_projection_freshness(
            "p1",
            md,
            changed_authorities=("stage_transitions", "role_capabilities"),
            changed_files=("CLAUDE.md", "AGENTS.md"),
        )
        assert assessment.status == pr.REFLOW_STATUS_STALE
        assert assessment.matched_authorities == ("stage_transitions",)
        assert assessment.matched_files == ("CLAUDE.md",)

    def test_partial_authority_subset_match(self):
        md = _metadata(
            condition=_condition(
                authorities=("stage_transitions", "role_capabilities"),
            )
        )
        assessment = pr.assess_projection_freshness(
            "p1",
            md,
            changed_authorities=("role_capabilities",),
            changed_files=(),
        )
        assert assessment.matched_authorities == ("role_capabilities",)
        assert assessment.watched_authorities == (
            "role_capabilities",
            "stage_transitions",
        )
        assert assessment.status == pr.REFLOW_STATUS_STALE

    def test_watched_fields_are_sorted_and_echoed(self):
        md = _metadata(
            condition=_condition(
                authorities=("stage_transitions", "role_capabilities"),
                files=("CLAUDE.md", "AGENTS.md"),
            )
        )
        assessment = pr.assess_projection_freshness(
            "p1",
            md,
            changed_authorities=(),
            changed_files=(),
        )
        assert assessment.watched_authorities == (
            "role_capabilities",
            "stage_transitions",
        )
        assert assessment.watched_files == ("AGENTS.md", "CLAUDE.md")

    def test_matched_lists_are_sorted(self):
        md = _metadata(
            condition=_condition(
                authorities=("stage_transitions", "role_capabilities"),
            )
        )
        assessment = pr.assess_projection_freshness(
            "p1",
            md,
            changed_authorities=("stage_transitions", "role_capabilities"),
            changed_files=(),
        )
        assert assessment.matched_authorities == (
            "role_capabilities",
            "stage_transitions",
        )

    def test_schema_type_is_read_from_concrete_projection(self):
        md = _metadata(condition=_condition(authorities=("stage_transitions",)))
        proj = _hook_doc_projection(md)
        assessment = pr.assess_projection_freshness(
            "p1",
            proj,
            changed_authorities=(),
            changed_files=(),
        )
        assert assessment.schema_type == "hook_doc_projection"

    def test_schema_type_is_none_for_bare_metadata(self):
        md = _metadata()
        assessment = pr.assess_projection_freshness(
            "p1",
            md,
            changed_authorities=(),
            changed_files=(),
        )
        assert assessment.schema_type is None

    def test_metadata_fields_echoed_on_assessment(self):
        md = _metadata(
            condition=_condition(rationale="pack version bump"),
            generator_version="2.3.4",
            generated_at=17,
            source_versions=(("decision", "v1"), ("work_item", "v2")),
        )
        assessment = pr.assess_projection_freshness(
            "p1",
            md,
            changed_authorities=(),
            changed_files=(),
        )
        assert assessment.stale_rationale == "pack version bump"
        assert assessment.generator_version == "2.3.4"
        assert assessment.generated_at == 17
        assert assessment.source_versions == (
            ("decision", "v1"),
            ("work_item", "v2"),
        )

    def test_deterministic_output_regardless_of_input_order(self):
        md = _metadata(
            condition=_condition(
                authorities=("stage_transitions", "role_capabilities"),
                files=("CLAUDE.md", "AGENTS.md"),
            )
        )
        first = pr.assess_projection_freshness(
            "p1",
            md,
            changed_authorities=("stage_transitions", "role_capabilities"),
            changed_files=("CLAUDE.md", "AGENTS.md"),
        )
        second = pr.assess_projection_freshness(
            "p1",
            md,
            changed_authorities=["role_capabilities", "stage_transitions"],
            changed_files=["AGENTS.md", "CLAUDE.md"],
        )
        assert first == second

    def test_duplicate_entries_in_change_set_do_not_duplicate_matches(self):
        md = _metadata(condition=_condition(authorities=("stage_transitions",)))
        assessment = pr.assess_projection_freshness(
            "p1",
            md,
            changed_authorities=(
                "stage_transitions",
                "stage_transitions",
                "role_capabilities",
            ),
            changed_files=(),
        )
        assert assessment.matched_authorities == ("stage_transitions",)

    def test_empty_change_set_is_fresh_even_with_watched(self):
        md = _metadata(condition=_condition(authorities=("stage_transitions",)))
        assessment = pr.assess_projection_freshness(
            "p1",
            md,
            changed_authorities=(),
            changed_files=(),
        )
        assert assessment.status == pr.REFLOW_STATUS_FRESH

    def test_frozen_assessment_is_immutable(self):
        md = _metadata()
        assessment = pr.assess_projection_freshness(
            "p1", md, changed_authorities=(), changed_files=()
        )
        with pytest.raises(Exception):
            assessment.status = "something"  # type: ignore[misc]

    def test_assessment_as_dict_is_json_serialisable(self):
        md = _metadata(
            condition=_condition(
                authorities=("stage_transitions",),
                files=("CLAUDE.md",),
            ),
            source_versions=(("decision", "v1"),),
        )
        assessment = pr.assess_projection_freshness(
            "p1",
            md,
            changed_authorities=("stage_transitions",),
            changed_files=(),
        )
        as_dict = assessment.as_dict()
        roundtrip = json.loads(json.dumps(as_dict))
        assert roundtrip["status"] == "stale"
        assert roundtrip["matched_authorities"] == ["stage_transitions"]
        assert roundtrip["matched_files"] == []
        assert roundtrip["source_versions"] == [["decision", "v1"]]


# ---------------------------------------------------------------------------
# 4. Input validation
# ---------------------------------------------------------------------------


class TestAssessInputValidation:
    def test_non_string_projection_id_raises(self):
        with pytest.raises(ValueError):
            pr.assess_projection_freshness(
                42,  # type: ignore[arg-type]
                _metadata(),
                changed_authorities=(),
                changed_files=(),
            )

    def test_empty_projection_id_raises(self):
        with pytest.raises(ValueError):
            pr.assess_projection_freshness(
                "",
                _metadata(),
                changed_authorities=(),
                changed_files=(),
            )

    def test_missing_metadata_raises(self):
        with pytest.raises(ValueError):
            pr.assess_projection_freshness(
                "p1",
                object(),
                changed_authorities=(),
                changed_files=(),
            )

    def test_non_string_changed_authority_raises(self):
        with pytest.raises(ValueError):
            pr.assess_projection_freshness(
                "p1",
                _metadata(),
                changed_authorities=(42,),  # type: ignore[arg-type]
                changed_files=(),
            )

    def test_empty_string_changed_file_raises(self):
        with pytest.raises(ValueError):
            pr.assess_projection_freshness(
                "p1",
                _metadata(),
                changed_authorities=(),
                changed_files=("",),
            )

    def test_none_changed_authorities_raises(self):
        with pytest.raises(ValueError):
            pr.assess_projection_freshness(
                "p1",
                _metadata(),
                changed_authorities=None,  # type: ignore[arg-type]
                changed_files=(),
            )

    def test_bare_string_changed_files_is_rejected(self):
        # Correctness correction: a bare string is iterable over
        # characters, which would silently decompose 'CLAUDE.md' into
        # ('C','L','A',...) and report a false 'fresh' verdict even
        # when 'CLAUDE.md' is in watched_files. The planner must reject
        # a top-level str input so caller bugs fail loudly instead.
        md = _metadata(condition=_condition(files=("CLAUDE.md",)))
        with pytest.raises(ValueError):
            pr.assess_projection_freshness(
                "p1",
                md,
                changed_authorities=(),
                changed_files="CLAUDE.md",  # type: ignore[arg-type]
            )

    def test_bare_string_changed_authorities_is_rejected(self):
        md = _metadata(condition=_condition(authorities=("stage_transitions",)))
        with pytest.raises(ValueError):
            pr.assess_projection_freshness(
                "p1",
                md,
                changed_authorities="stage_transitions",  # type: ignore[arg-type]
                changed_files=(),
            )

    def test_bare_bytes_changed_files_is_rejected(self):
        md = _metadata(condition=_condition(files=("CLAUDE.md",)))
        with pytest.raises(ValueError):
            pr.assess_projection_freshness(
                "p1",
                md,
                changed_authorities=(),
                changed_files=b"CLAUDE.md",  # type: ignore[arg-type]
            )

    def test_bare_bytearray_changed_authorities_is_rejected(self):
        md = _metadata()
        with pytest.raises(ValueError):
            pr.assess_projection_freshness(
                "p1",
                md,
                changed_authorities=bytearray(b"stage"),  # type: ignore[arg-type]
                changed_files=(),
            )

    def test_bare_string_plan_propagates_same_validation(self):
        # The batch planner must reject bare-string change sets with the
        # same ValueError contract as the single-projection assessor.
        md = _metadata(condition=_condition(files=("CLAUDE.md",)))
        with pytest.raises(ValueError):
            pr.plan_projection_reflow(
                [("p1", md)],
                changed_authorities=(),
                changed_files="CLAUDE.md",  # type: ignore[arg-type]
            )
        with pytest.raises(ValueError):
            pr.plan_projection_reflow(
                [("p1", md)],
                changed_authorities="stage_transitions",  # type: ignore[arg-type]
                changed_files=(),
            )


# ---------------------------------------------------------------------------
# 5. Batch planner
# ---------------------------------------------------------------------------


class TestPlanProjectionReflow:
    def test_batch_assesses_each_projection(self):
        md_a = _metadata(condition=_condition(authorities=("stage_transitions",)))
        md_b = _metadata(condition=_condition(files=("CLAUDE.md",)))
        md_c = _metadata(condition=_condition(authorities=("unrelated",)))

        plan = pr.plan_projection_reflow(
            [
                ("p_a", md_a),
                ("p_b", md_b),
                ("p_c", md_c),
            ],
            changed_authorities=("stage_transitions",),
            changed_files=("CLAUDE.md",),
        )
        assert plan.total == 3
        assert plan.stale_count == 2
        assert plan.fresh_count == 1
        assert plan.affected_projection_ids() == ("p_a", "p_b")

    def test_assessments_sorted_by_projection_id(self):
        md = _metadata()
        plan = pr.plan_projection_reflow(
            [
                ("zulu", md),
                ("alpha", md),
                ("mike", md),
            ],
            changed_authorities=(),
            changed_files=(),
        )
        assert [a.projection_id for a in plan.assessments] == [
            "alpha",
            "mike",
            "zulu",
        ]

    def test_plan_is_deterministic_regardless_of_input_order(self):
        md_a = _metadata(condition=_condition(authorities=("stage_transitions",)))
        md_b = _metadata(condition=_condition(files=("CLAUDE.md",)))

        plan_1 = pr.plan_projection_reflow(
            [("p_a", md_a), ("p_b", md_b)],
            changed_authorities=("stage_transitions",),
            changed_files=("CLAUDE.md",),
        )
        plan_2 = pr.plan_projection_reflow(
            [("p_b", md_b), ("p_a", md_a)],
            changed_authorities=["stage_transitions"],
            changed_files=["CLAUDE.md"],
        )
        assert plan_1 == plan_2

    def test_changed_sets_echoed_sorted(self):
        plan = pr.plan_projection_reflow(
            [],
            changed_authorities=("zulu_authority", "alpha_authority"),
            changed_files=("z.md", "a.md"),
        )
        assert plan.changed_authorities == ("alpha_authority", "zulu_authority")
        assert plan.changed_files == ("a.md", "z.md")

    def test_duplicate_projection_id_raises(self):
        md = _metadata()
        with pytest.raises(ValueError):
            pr.plan_projection_reflow(
                [("p_a", md), ("p_a", md)],
                changed_authorities=(),
                changed_files=(),
            )

    def test_non_tuple_entry_raises(self):
        md = _metadata()
        with pytest.raises(ValueError):
            pr.plan_projection_reflow(
                [md],  # type: ignore[list-item]
                changed_authorities=(),
                changed_files=(),
            )

    def test_empty_plan_has_zero_counts(self):
        plan = pr.plan_projection_reflow(
            [],
            changed_authorities=(),
            changed_files=(),
        )
        assert plan.total == 0
        assert plan.stale_count == 0
        assert plan.fresh_count == 0
        assert plan.assessments == ()
        assert plan.affected_projection_ids() == ()

    def test_accepts_concrete_projection_dataclasses(self):
        md_stale = _metadata(condition=_condition(authorities=("stage_transitions",)))
        md_fresh = _metadata(condition=_condition(files=("CLAUDE.md",)))
        plan = pr.plan_projection_reflow(
            [
                ("hook_doc", _hook_doc_projection(md_stale)),
                ("prompt_pack", _prompt_pack(md_fresh)),
                ("decision_digest", _decision_digest(md_fresh)),
            ],
            changed_authorities=("stage_transitions",),
            changed_files=(),
        )
        by_id = {a.projection_id: a for a in plan.assessments}
        assert by_id["hook_doc"].status == pr.REFLOW_STATUS_STALE
        assert by_id["hook_doc"].schema_type == "hook_doc_projection"
        assert by_id["prompt_pack"].status == pr.REFLOW_STATUS_FRESH
        assert by_id["prompt_pack"].schema_type == "prompt_pack"
        assert by_id["decision_digest"].status == pr.REFLOW_STATUS_FRESH
        assert by_id["decision_digest"].schema_type == "decision_digest"

    def test_plan_counts_invariant(self):
        # Direct construction of a plan with inconsistent counts must fail.
        with pytest.raises(ValueError):
            pr.ReflowPlan(
                total=3,
                fresh_count=1,
                stale_count=1,
                assessments=(),
                changed_authorities=(),
                changed_files=(),
            )

    def test_plan_total_must_match_len_assessments(self):
        with pytest.raises(ValueError):
            pr.ReflowPlan(
                total=5,
                fresh_count=0,
                stale_count=0,
                assessments=(),
                changed_authorities=(),
                changed_files=(),
            )

    def test_plan_as_dict_roundtrip(self):
        md_stale = _metadata(condition=_condition(authorities=("stage_transitions",)))
        plan = pr.plan_projection_reflow(
            [("p1", md_stale)],
            changed_authorities=("stage_transitions",),
            changed_files=(),
        )
        round = json.loads(json.dumps(plan.as_dict()))
        assert round["total"] == 1
        assert round["stale_count"] == 1
        assert round["fresh_count"] == 0
        assert round["affected_projection_ids"] == ["p1"]
        assert round["assessments"][0]["status"] == "stale"

    def test_batch_propagates_change_set_validation(self):
        md = _metadata()
        with pytest.raises(ValueError):
            pr.plan_projection_reflow(
                [("p1", md)],
                changed_authorities=("",),
                changed_files=(),
            )

    def test_entry_with_non_string_id_raises(self):
        md = _metadata()
        with pytest.raises(ValueError):
            pr.plan_projection_reflow(
                [(42, md)],  # type: ignore[list-item]
                changed_authorities=(),
                changed_files=(),
            )


# ---------------------------------------------------------------------------
# 5b. Real builder-output integration (test-only; no runtime import)
#
# The planner must accept live outputs from the existing pure projection
# builders — ``build_hook_doc_projection``, ``build_prompt_pack``, and
# ``build_decision_digest_projection`` — without any special-casing.
# These tests import the builders from tests only; ``projection_reflow``
# itself remains unaware of those modules (pinned separately by the
# shadow-only discipline tests below).
# ---------------------------------------------------------------------------


class TestRealBuilderOutputs:
    def _real_hook_doc(self):
        from runtime.core.hook_doc_projection import build_hook_doc_projection

        return build_hook_doc_projection(generated_at=100)

    def _real_prompt_pack(self):
        from runtime.core.prompt_pack import (
            CANONICAL_LAYER_ORDER,
            build_prompt_pack,
        )

        layers = {name: f"body-{name}" for name in CANONICAL_LAYER_ORDER}
        return build_prompt_pack(
            workflow_id="wf-real",
            stage_id="implementer",
            layers=layers,
            generated_at=100,
            watched_files=("CLAUDE.md",),
        )

    def _real_decision_digest(self):
        from runtime.core.decision_digest_projection import (
            build_decision_digest_projection,
        )
        from runtime.core.decision_work_registry import DecisionRecord

        rec = DecisionRecord(
            decision_id="DEC-REAL-1",
            title="real decision",
            status="accepted",
            rationale="real rationale",
            version=1,
            author="test",
            scope="kernel",
            created_at=10,
            updated_at=10,
        )
        return build_decision_digest_projection(
            [rec], generated_at=100, cutoff_epoch=0
        )

    def test_hook_doc_projection_round_trips_through_assessor_fresh(self):
        proj = self._real_hook_doc()
        assessment = pr.assess_projection_freshness(
            "hook_doc",
            proj,
            changed_authorities=(),
            changed_files=(),
        )
        assert assessment.schema_type == "hook_doc_projection"
        assert assessment.status == pr.REFLOW_STATUS_FRESH
        assert assessment.watched_authorities == ("hook_wiring",)

    def test_hook_doc_projection_stale_when_watched_file_changes(self):
        # build_hook_doc_projection watches hooks/HOOKS.md among others;
        # a change-set containing that file must produce a stale verdict.
        proj = self._real_hook_doc()
        assessment = pr.assess_projection_freshness(
            "hook_doc",
            proj,
            changed_authorities=(),
            changed_files=("hooks/HOOKS.md",),
        )
        assert assessment.status == pr.REFLOW_STATUS_STALE
        assert "hooks/HOOKS.md" in assessment.matched_files

    def test_hook_doc_projection_stale_when_watched_authority_changes(self):
        proj = self._real_hook_doc()
        assessment = pr.assess_projection_freshness(
            "hook_doc",
            proj,
            changed_authorities=("hook_wiring",),
            changed_files=(),
        )
        assert assessment.status == pr.REFLOW_STATUS_STALE
        assert assessment.matched_authorities == ("hook_wiring",)

    def test_prompt_pack_round_trips_through_assessor_fresh(self):
        proj = self._real_prompt_pack()
        assessment = pr.assess_projection_freshness(
            "prompt_pack",
            proj,
            changed_authorities=(),
            changed_files=(),
        )
        assert assessment.schema_type == "prompt_pack"
        assert assessment.status == pr.REFLOW_STATUS_FRESH

    def test_prompt_pack_stale_on_watched_file_change(self):
        proj = self._real_prompt_pack()
        assessment = pr.assess_projection_freshness(
            "prompt_pack",
            proj,
            changed_authorities=(),
            changed_files=("CLAUDE.md",),
        )
        assert assessment.status == pr.REFLOW_STATUS_STALE
        assert assessment.matched_files == ("CLAUDE.md",)

    def test_decision_digest_round_trips_through_assessor_fresh(self):
        proj = self._real_decision_digest()
        assessment = pr.assess_projection_freshness(
            "decision_digest",
            proj,
            changed_authorities=(),
            changed_files=(),
        )
        assert assessment.schema_type == "decision_digest"
        assert assessment.status == pr.REFLOW_STATUS_FRESH

    def test_decision_digest_stale_on_watched_authority_change(self):
        proj = self._real_decision_digest()
        assessment = pr.assess_projection_freshness(
            "decision_digest",
            proj,
            changed_authorities=("decision_records",),
            changed_files=(),
        )
        assert assessment.status == pr.REFLOW_STATUS_STALE
        assert assessment.matched_authorities == ("decision_records",)

    def test_batch_planner_accepts_all_three_real_builder_outputs(self):
        hook_doc = self._real_hook_doc()
        prompt_pack = self._real_prompt_pack()
        decision_digest = self._real_decision_digest()

        # Change set that lights up each projection on exactly one axis:
        #   - hook_doc via watched_files 'settings.json'
        #   - prompt_pack via watched_files 'CLAUDE.md'
        #   - decision_digest via watched_authorities 'decision_records'
        plan = pr.plan_projection_reflow(
            [
                ("hook_doc", hook_doc),
                ("prompt_pack", prompt_pack),
                ("decision_digest", decision_digest),
            ],
            changed_authorities=("decision_records",),
            changed_files=("CLAUDE.md", "settings.json"),
        )
        assert plan.total == 3
        assert plan.stale_count == 3
        assert plan.fresh_count == 0

        by_id = {a.projection_id: a for a in plan.assessments}
        assert by_id["hook_doc"].schema_type == "hook_doc_projection"
        assert "settings.json" in by_id["hook_doc"].matched_files
        assert by_id["prompt_pack"].schema_type == "prompt_pack"
        assert by_id["prompt_pack"].matched_files == ("CLAUDE.md",)
        assert by_id["decision_digest"].schema_type == "decision_digest"
        assert by_id["decision_digest"].matched_authorities == (
            "decision_records",
        )

    def test_batch_planner_is_fresh_when_no_change_overlaps_real_builders(self):
        hook_doc = self._real_hook_doc()
        prompt_pack = self._real_prompt_pack()
        decision_digest = self._real_decision_digest()
        plan = pr.plan_projection_reflow(
            [
                ("hook_doc", hook_doc),
                ("prompt_pack", prompt_pack),
                ("decision_digest", decision_digest),
            ],
            changed_authorities=("some_unrelated_authority",),
            changed_files=("README.md",),
        )
        assert plan.stale_count == 0
        assert plan.fresh_count == 3
        assert plan.affected_projection_ids() == ()


# ---------------------------------------------------------------------------
# 6. Module surface
# ---------------------------------------------------------------------------


class TestModuleSurface:
    def test_all_exports_match_expected_surface(self):
        assert set(pr.__all__) == {
            "REFLOW_STATUS_FRESH",
            "REFLOW_STATUS_STALE",
            "REFLOW_STATUSES",
            "ProjectionAssessment",
            "ReflowPlan",
            "extract_projection_metadata",
            "assess_projection_freshness",
            "plan_projection_reflow",
        }

    def test_assessment_is_frozen_dataclass(self):
        import dataclasses

        assert dataclasses.is_dataclass(pr.ProjectionAssessment)
        assert pr.ProjectionAssessment.__dataclass_params__.frozen is True

    def test_plan_is_frozen_dataclass(self):
        import dataclasses

        assert dataclasses.is_dataclass(pr.ReflowPlan)
        assert pr.ReflowPlan.__dataclass_params__.frozen is True


# ---------------------------------------------------------------------------
# 7. Shadow-only discipline (AST inspection, not substring search)
# ---------------------------------------------------------------------------


class TestShadowOnlyDiscipline:
    def test_projection_reflow_does_not_import_live_modules(self):
        imported = _imported_module_names(pr)
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
            "decision_work_registry",
            "decision_digest_projection",
            "hook_manifest",
            "hook_doc_projection",
            "hook_doc_validation",
            "prompt_pack",
            "prompt_pack_resolver",
            "prompt_pack_validation",
            "stage_registry",
            "authority_registry",
            "constitution_registry",
        )
        for name in imported:
            for needle in forbidden_substrings:
                assert needle not in name, (
                    f"projection_reflow.py imports {name!r} which contains "
                    f"forbidden token {needle!r}"
                )

    def test_projection_reflow_only_depends_on_projection_schemas(self):
        imported = _imported_module_names(pr)
        runtime_core_imports = {
            name for name in imported if name.startswith("runtime.core")
        }
        # The only permitted runtime.core dependency is projection_schemas
        # (needed for ProjectionMetadata / StaleCondition type contracts).
        allowed_prefix = "runtime.core.projection_schemas"
        for name in runtime_core_imports:
            assert name.startswith(allowed_prefix), (
                f"projection_reflow.py imports unexpected runtime.core "
                f"module {name!r}"
            )

    def test_core_routing_modules_do_not_import_projection_reflow(self):
        import runtime.core.completions as completions
        import runtime.core.dispatch_engine as dispatch_engine
        import runtime.core.policy_engine as policy_engine

        for mod in (dispatch_engine, completions, policy_engine):
            imported = _imported_module_names(mod)
            for name in imported:
                assert "projection_reflow" not in name, (
                    f"{mod.__name__} imports {name!r} — projection_reflow "
                    f"must stay shadow-only in Slice 16"
                )

    def test_cli_does_not_import_projection_reflow(self):
        # Slice 16 does not wire a CLI adapter. Future slices may expose
        # reflow via a subcommand using the same function-scope import
        # discipline the decision-digest adapters use; for now, no CLI
        # surface reaches this module.
        import runtime.cli as cli

        imported = _imported_module_names(cli)
        for name in imported:
            assert "projection_reflow" not in name, (
                f"runtime/cli.py imports {name!r} — projection_reflow has "
                f"no CLI adapter in Slice 16"
            )

    def test_projection_reflow_has_no_filesystem_or_process_imports(self):
        imported = _imported_module_names(pr)
        forbidden = ("subprocess", "sqlite3", "os.path", "pathlib", "shutil")
        for name in imported:
            for needle in forbidden:
                assert needle not in name, (
                    f"projection_reflow.py imports {name!r} which contains "
                    f"forbidden side-effect token {needle!r}"
                )
