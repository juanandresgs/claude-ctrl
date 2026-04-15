"""Tests for runtime/core/decision_digest_projection.py.

@decision DEC-CLAUDEX-DECISION-DIGEST-PROJECTION-TESTS-001
Title: Pure decision-digest projection builder pins deterministic render ordering, schema field derivation, provenance identity, stale-condition watches, and shadow-only import discipline
Status: proposed (shadow-mode, Phase 7 Slice 13)
Rationale: The decision-digest projection builder is the first slice
  that consumes ``runtime.core.decision_work_registry.DecisionRecord``
  as an authority and emits a Phase 1 ``DecisionDigest`` record. Tests
  pin:

    1. ``render_decision_digest`` produces deterministic output: two
       calls with the same decisions/cutoff yield identical bytes.
    2. Render order is descending ``updated_at`` with ties broken by
       ``decision_id`` ascending, regardless of input iteration order.
    3. Records with ``updated_at < cutoff_epoch`` are dropped from
       the rendered body, ``decision_ids``, and ``provenance``.
    4. ``DecisionDigest.decision_ids`` matches the rendered order;
       ``cutoff_epoch`` is echoed back verbatim; ``content_hash`` is
       a stable sha256 of the same rendered bytes.
    5. ``metadata.provenance`` has one ``SourceRef`` per included
       decision, in render order, with
       ``source_kind=="decision_records"``,
       ``source_id==decision_id``,
       ``source_version=="<version>:<status>"``.
    6. ``metadata.stale_condition`` watches the
       ``decision_records`` authority and
       ``runtime/core/decision_work_registry.py`` source file.
    7. Empty decision sequences and no-in-window cases produce
       deterministic output with a placeholder body, empty
       ``decision_ids`` / ``provenance``, and a stable hash.
    8. Malformed inputs raise ``ValueError`` — duplicate decision
       ids, wrong element type, wrong container type, negative /
       non-int cutoff.
    9. Shadow-only discipline: the module imports only
       ``runtime.core.decision_work_registry`` and
       ``runtime.core.projection_schemas``; no live routing /
       policy / CLI / hooks / settings modules import it.
"""

from __future__ import annotations

import ast
import hashlib
import inspect

import pytest

from runtime.core import decision_digest_projection as ddp
from runtime.core import decision_work_registry as dwr
from runtime.core import projection_schemas as ps


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


def _decision(
    *,
    decision_id: str,
    title: str = "T",
    status: str = "proposed",
    rationale: str = "R",
    version: int = 1,
    author: str = "planner",
    scope: str = "kernel",
    updated_at: int = 1_700_000_000,
    created_at: int = 1_700_000_000,
) -> dwr.DecisionRecord:
    return dwr.DecisionRecord(
        decision_id=decision_id,
        title=title,
        status=status,
        rationale=rationale,
        version=version,
        author=author,
        scope=scope,
        created_at=created_at,
        updated_at=updated_at,
    )


# ---------------------------------------------------------------------------
# 1. render_decision_digest — determinism, ordering, body shape
# ---------------------------------------------------------------------------


class TestRenderDecisionDigest:
    def test_render_returns_non_empty_string_ending_with_newline(self):
        text = ddp.render_decision_digest(
            [_decision(decision_id="D-1")],
            cutoff_epoch=0,
        )
        assert isinstance(text, str)
        assert text.strip() != ""
        assert text.endswith("\n")

    def test_render_is_deterministic(self):
        decisions = [
            _decision(decision_id="D-1", updated_at=100),
            _decision(decision_id="D-2", updated_at=200),
        ]
        a = ddp.render_decision_digest(decisions, cutoff_epoch=0)
        b = ddp.render_decision_digest(decisions, cutoff_epoch=0)
        assert a == b

    def test_render_sorts_by_updated_at_descending_then_decision_id(self):
        # D-3 newest, then D-1 and D-2 tied at 100 (D-1 wins on id).
        decisions = [
            _decision(decision_id="D-2", updated_at=100),
            _decision(decision_id="D-3", updated_at=300),
            _decision(decision_id="D-1", updated_at=100),
        ]
        text = ddp.render_decision_digest(decisions, cutoff_epoch=0)
        # The order of the three id lines in the body should be:
        # D-3 (300), D-1 (100, wins on id asc), D-2 (100).
        idx_d3 = text.index("`D-3`")
        idx_d1 = text.index("`D-1`")
        idx_d2 = text.index("`D-2`")
        assert idx_d3 < idx_d1 < idx_d2

    def test_render_order_is_independent_of_input_iteration_order(self):
        a_decisions = [
            _decision(decision_id="D-1", updated_at=100),
            _decision(decision_id="D-2", updated_at=200),
        ]
        b_decisions = list(reversed(a_decisions))
        a = ddp.render_decision_digest(a_decisions, cutoff_epoch=0)
        b = ddp.render_decision_digest(b_decisions, cutoff_epoch=0)
        assert a == b

    def test_render_drops_records_below_cutoff(self):
        decisions = [
            _decision(decision_id="D-OLD", updated_at=50),
            _decision(decision_id="D-NEW", updated_at=200),
        ]
        text = ddp.render_decision_digest(decisions, cutoff_epoch=100)
        assert "D-NEW" in text
        assert "D-OLD" not in text

    def test_render_includes_records_at_cutoff_boundary(self):
        decisions = [
            _decision(decision_id="D-BOUND", updated_at=100),
        ]
        text = ddp.render_decision_digest(decisions, cutoff_epoch=100)
        assert "D-BOUND" in text

    def test_render_contains_cutoff_line(self):
        text = ddp.render_decision_digest([], cutoff_epoch=12345)
        assert "Cutoff: epoch=12345" in text

    def test_render_empty_list_produces_placeholder(self):
        text = ddp.render_decision_digest([], cutoff_epoch=0)
        assert "_No decisions within cutoff window._" in text

    def test_render_all_filtered_out_produces_placeholder(self):
        decisions = [_decision(decision_id="D-OLD", updated_at=10)]
        text = ddp.render_decision_digest(decisions, cutoff_epoch=100)
        assert "_No decisions within cutoff window._" in text

    def test_render_includes_version_and_status_and_title(self):
        decisions = [
            _decision(
                decision_id="D-META",
                title="My Title",
                status="accepted",
                rationale="Because.",
                version=7,
                updated_at=100,
            )
        ]
        text = ddp.render_decision_digest(decisions, cutoff_epoch=0)
        assert "`D-META`" in text
        assert "v7" in text
        assert "[accepted]" in text
        assert "My Title" in text
        assert "Because." in text

    def test_render_generator_version_is_in_body(self):
        text = ddp.render_decision_digest([], cutoff_epoch=0)
        assert ddp.DECISION_DIGEST_GENERATOR_VERSION in text


# ---------------------------------------------------------------------------
# 2. build_decision_digest_projection — schema field derivation
# ---------------------------------------------------------------------------


class TestBuildDecisionDigestProjection:
    def test_returns_decision_digest_instance(self):
        proj = ddp.build_decision_digest_projection(
            [_decision(decision_id="D-1")],
            generated_at=1,
            cutoff_epoch=0,
        )
        assert isinstance(proj, ps.DecisionDigest)

    def test_decision_ids_match_render_order(self):
        decisions = [
            _decision(decision_id="D-2", updated_at=100),
            _decision(decision_id="D-3", updated_at=300),
            _decision(decision_id="D-1", updated_at=100),
        ]
        proj = ddp.build_decision_digest_projection(
            decisions, generated_at=1, cutoff_epoch=0
        )
        # Render order: D-3 (300), D-1 (100, id wins), D-2 (100).
        assert proj.decision_ids == ("D-3", "D-1", "D-2")

    def test_decision_ids_drop_below_cutoff(self):
        decisions = [
            _decision(decision_id="D-OLD", updated_at=50),
            _decision(decision_id="D-NEW", updated_at=200),
        ]
        proj = ddp.build_decision_digest_projection(
            decisions, generated_at=1, cutoff_epoch=100
        )
        assert proj.decision_ids == ("D-NEW",)

    def test_cutoff_epoch_is_echoed_verbatim(self):
        proj = ddp.build_decision_digest_projection(
            [], generated_at=1, cutoff_epoch=99_999
        )
        assert proj.cutoff_epoch == 99_999

    def test_content_hash_matches_rendered_body(self):
        decisions = [_decision(decision_id="D-1", updated_at=100)]
        rendered = ddp.render_decision_digest(decisions, cutoff_epoch=0)
        expected_hash = (
            "sha256:" + hashlib.sha256(rendered.encode("utf-8")).hexdigest()
        )
        proj = ddp.build_decision_digest_projection(
            decisions, generated_at=1, cutoff_epoch=0
        )
        assert proj.content_hash == expected_hash

    def test_content_hash_stable_for_identical_inputs(self):
        decisions = [_decision(decision_id="D-1", updated_at=100)]
        a = ddp.build_decision_digest_projection(
            decisions, generated_at=1, cutoff_epoch=0
        )
        b = ddp.build_decision_digest_projection(
            decisions, generated_at=1, cutoff_epoch=0
        )
        assert a.content_hash == b.content_hash

    def test_content_hash_changes_when_content_changes(self):
        a = ddp.build_decision_digest_projection(
            [_decision(decision_id="D-1", updated_at=100)],
            generated_at=1,
            cutoff_epoch=0,
        )
        b = ddp.build_decision_digest_projection(
            [_decision(decision_id="D-2", updated_at=100)],
            generated_at=1,
            cutoff_epoch=0,
        )
        assert a.content_hash != b.content_hash

    def test_empty_projection_has_empty_decision_ids_and_stable_hash(self):
        a = ddp.build_decision_digest_projection(
            [], generated_at=1, cutoff_epoch=0
        )
        b = ddp.build_decision_digest_projection(
            [], generated_at=2, cutoff_epoch=0
        )
        assert a.decision_ids == ()
        assert a.content_hash == b.content_hash  # body only depends on cutoff+decisions


# ---------------------------------------------------------------------------
# 3. Provenance
# ---------------------------------------------------------------------------


class TestProvenance:
    def test_one_sourceref_per_included_decision(self):
        decisions = [
            _decision(decision_id="D-1", updated_at=100),
            _decision(decision_id="D-2", updated_at=200),
        ]
        proj = ddp.build_decision_digest_projection(
            decisions, generated_at=1, cutoff_epoch=0
        )
        assert len(proj.metadata.provenance) == 2

    def test_provenance_order_matches_render_order(self):
        decisions = [
            _decision(decision_id="D-2", updated_at=100),
            _decision(decision_id="D-3", updated_at=300),
            _decision(decision_id="D-1", updated_at=100),
        ]
        proj = ddp.build_decision_digest_projection(
            decisions, generated_at=1, cutoff_epoch=0
        )
        ids = tuple(ref.source_id for ref in proj.metadata.provenance)
        assert ids == proj.decision_ids

    def test_provenance_source_kind_is_decision_records(self):
        proj = ddp.build_decision_digest_projection(
            [_decision(decision_id="D-1")],
            generated_at=1,
            cutoff_epoch=0,
        )
        for ref in proj.metadata.provenance:
            assert ref.source_kind == "decision_records"
            assert ref.source_kind == ddp.DECISIONS_SOURCE_KIND

    def test_provenance_source_version_encodes_version_and_status(self):
        proj = ddp.build_decision_digest_projection(
            [
                _decision(
                    decision_id="D-1",
                    version=4,
                    status="accepted",
                )
            ],
            generated_at=1,
            cutoff_epoch=0,
        )
        assert proj.metadata.provenance[0].source_version == "4:accepted"

    def test_below_cutoff_decisions_are_not_in_provenance(self):
        decisions = [
            _decision(decision_id="D-OLD", updated_at=50),
            _decision(decision_id="D-NEW", updated_at=200),
        ]
        proj = ddp.build_decision_digest_projection(
            decisions, generated_at=1, cutoff_epoch=100
        )
        ids = {ref.source_id for ref in proj.metadata.provenance}
        assert ids == {"D-NEW"}


# ---------------------------------------------------------------------------
# 4. Stale condition
# ---------------------------------------------------------------------------


class TestStaleCondition:
    def test_watched_authorities_includes_decision_records(self):
        proj = ddp.build_decision_digest_projection(
            [], generated_at=1, cutoff_epoch=0
        )
        assert "decision_records" in proj.metadata.stale_condition.watched_authorities

    def test_watched_files_includes_registry_source_file(self):
        proj = ddp.build_decision_digest_projection(
            [], generated_at=1, cutoff_epoch=0
        )
        assert (
            "runtime/core/decision_work_registry.py"
            in proj.metadata.stale_condition.watched_files
        )

    def test_watched_files_matches_module_constant(self):
        proj = ddp.build_decision_digest_projection(
            [], generated_at=1, cutoff_epoch=0
        )
        assert (
            ddp.DECISION_REGISTRY_SOURCE_FILE
            in proj.metadata.stale_condition.watched_files
        )

    def test_rationale_is_non_empty(self):
        proj = ddp.build_decision_digest_projection(
            [], generated_at=1, cutoff_epoch=0
        )
        assert proj.metadata.stale_condition.rationale.strip() != ""

    def test_source_versions_declares_decision_records_kind(self):
        proj = ddp.build_decision_digest_projection(
            [], generated_at=1, cutoff_epoch=0
        )
        kinds = dict(proj.metadata.source_versions)
        assert "decision_records" in kinds

    def test_manifest_version_override_flows_into_source_versions(self):
        proj = ddp.build_decision_digest_projection(
            [],
            generated_at=1,
            cutoff_epoch=0,
            manifest_version="9.9.9",
        )
        kinds = dict(proj.metadata.source_versions)
        assert kinds["decision_records"] == "9.9.9"


# ---------------------------------------------------------------------------
# 5. Input validation
# ---------------------------------------------------------------------------


class TestInputValidation:
    def test_duplicate_decision_ids_raise(self):
        decisions = [
            _decision(decision_id="D-DUP"),
            _decision(decision_id="D-DUP"),
        ]
        with pytest.raises(ValueError):
            ddp.build_decision_digest_projection(
                decisions, generated_at=1, cutoff_epoch=0
            )

    def test_non_decision_record_raises(self):
        with pytest.raises(ValueError):
            ddp.build_decision_digest_projection(
                [{"decision_id": "D-1"}],  # type: ignore[list-item]
                generated_at=1,
                cutoff_epoch=0,
            )

    def test_non_sequence_decisions_raises(self):
        with pytest.raises(ValueError):
            ddp.build_decision_digest_projection(
                "not a list",  # type: ignore[arg-type]
                generated_at=1,
                cutoff_epoch=0,
            )

    def test_negative_cutoff_raises(self):
        with pytest.raises(ValueError):
            ddp.build_decision_digest_projection(
                [], generated_at=1, cutoff_epoch=-1
            )

    def test_non_int_cutoff_raises(self):
        with pytest.raises(ValueError):
            ddp.build_decision_digest_projection(
                [], generated_at=1, cutoff_epoch="today",  # type: ignore[arg-type]
            )

    def test_bool_cutoff_raises(self):
        # bool is a subclass of int in Python; guard against
        # ``cutoff_epoch=True`` silently passing.
        with pytest.raises(ValueError):
            ddp.build_decision_digest_projection(
                [], generated_at=1, cutoff_epoch=True,  # type: ignore[arg-type]
            )

    def test_render_rejects_duplicate_ids(self):
        decisions = [
            _decision(decision_id="D-DUP"),
            _decision(decision_id="D-DUP"),
        ]
        with pytest.raises(ValueError):
            ddp.render_decision_digest(decisions, cutoff_epoch=0)


# ---------------------------------------------------------------------------
# 6. Metadata envelope shape
# ---------------------------------------------------------------------------


class TestMetadataEnvelope:
    def test_generator_version_matches_module_constant(self):
        proj = ddp.build_decision_digest_projection(
            [], generated_at=1, cutoff_epoch=0
        )
        assert (
            proj.metadata.generator_version
            == ddp.DECISION_DIGEST_GENERATOR_VERSION
        )

    def test_generated_at_echoed_verbatim(self):
        proj = ddp.build_decision_digest_projection(
            [], generated_at=1_234_567, cutoff_epoch=0
        )
        assert proj.metadata.generated_at == 1_234_567


# ---------------------------------------------------------------------------
# 7. Shadow-only discipline
# ---------------------------------------------------------------------------


class TestShadowOnlyDiscipline:
    def test_decision_digest_projection_imports_only_allowed_modules(self):
        imported = _imported_module_names(ddp)
        runtime_core_imports = {
            name for name in imported if name.startswith("runtime.core")
        }
        permitted_prefixes = (
            "runtime.core.decision_work_registry",
            "runtime.core.projection_schemas",
        )
        permitted_bases = {
            "runtime.core",
            "runtime.core.decision_work_registry",
            "runtime.core.projection_schemas",
        }
        for name in runtime_core_imports:
            assert name in permitted_bases or name.startswith(permitted_prefixes), (
                f"decision_digest_projection.py has unexpected runtime.core "
                f"import: {name!r}"
            )

    def test_decision_digest_projection_has_no_live_imports(self):
        imported = _imported_module_names(ddp)
        forbidden_substrings = (
            "dispatch_engine",
            "completions",
            "policy_engine",
            "enforcement_config",
            "runtime.core.leases",
            "runtime.core.workflows",
            "runtime.core.policy_utils",
            "runtime.cli",
            "sqlite3",
            "subprocess",
        )
        for name in imported:
            for needle in forbidden_substrings:
                assert needle not in name, (
                    f"decision_digest_projection.py imports {name!r} "
                    f"containing forbidden token {needle!r}"
                )

    def test_live_modules_do_not_import_decision_digest_projection(self):
        import runtime.core.completions as completions
        import runtime.core.dispatch_engine as dispatch_engine
        import runtime.core.policy_engine as policy_engine

        for mod in (dispatch_engine, completions, policy_engine):
            imported = _imported_module_names(mod)
            for name in imported:
                assert "decision_digest_projection" not in name, (
                    f"{mod.__name__} imports {name!r} — "
                    f"decision_digest_projection must stay shadow-only "
                    f"this slice"
                )

    def test_cli_does_not_import_decision_digest_projection_at_module_level(
        self,
    ):
        # Phase 7 Slice 14 introduced a read-only
        # ``cc-policy decision digest`` surface that imports this module
        # at *function* scope inside ``_handle_decision``. Module-level
        # import is still forbidden so the CLI's module-load graph does
        # not acquire a build-time dependency on the projection
        # generator. Function-scope CLI use is asserted directly by
        # ``tests/runtime/test_decision_digest_cli.py``.
        import runtime.cli as cli

        tree = ast.parse(inspect.getsource(cli))
        for node in tree.body:
            if isinstance(node, ast.Import):
                for alias in node.names:
                    assert "decision_digest_projection" not in alias.name, (
                        f"runtime/cli.py imports {alias.name!r} at "
                        f"module scope — decision_digest_projection "
                        f"must stay function-scoped"
                    )
            elif isinstance(node, ast.ImportFrom):
                name = node.module or ""
                assert "decision_digest_projection" not in name, (
                    f"runtime/cli.py imports from {name!r} at module "
                    f"scope — decision_digest_projection must stay "
                    f"function-scoped"
                )

    def test_decision_work_registry_does_not_import_projection(self):
        # Guard against a reverse dependency — the authority must not
        # depend on any of its projections.
        imported = _imported_module_names(dwr)
        for name in imported:
            assert "decision_digest_projection" not in name

    def test_projection_schemas_does_not_import_projection(self):
        # The schema family must not depend on a specific projection
        # builder either.
        imported = _imported_module_names(ps)
        for name in imported:
            assert "decision_digest_projection" not in name


# ---------------------------------------------------------------------------
# 8. Module surface
# ---------------------------------------------------------------------------


class TestModuleSurface:
    def test_public_api_exported_via_all(self):
        exported = set(getattr(ddp, "__all__", ()))
        assert "render_decision_digest" in exported
        assert "build_decision_digest_projection" in exported
        assert "validate_decision_digest" in exported
        assert "VALIDATION_STATUS_OK" in exported
        assert "VALIDATION_STATUS_DRIFT" in exported

    def test_decisions_source_kind_is_stable(self):
        # Pinned because stale-condition invariants key off this
        # literal — any future change must update both the module
        # and the reflow engine's watch list in the same bundle.
        assert ddp.DECISIONS_SOURCE_KIND == "decision_records"

    def test_decision_registry_source_file_is_stable(self):
        assert (
            ddp.DECISION_REGISTRY_SOURCE_FILE
            == "runtime/core/decision_work_registry.py"
        )

    def test_validation_status_constants_stable(self):
        # Pinned so CLI / hook docs / invariant tests keying off
        # these strings cannot silently drift.
        assert ddp.VALIDATION_STATUS_OK == "ok"
        assert ddp.VALIDATION_STATUS_DRIFT == "drift"


# ---------------------------------------------------------------------------
# 9. validate_decision_digest — pure drift checker (Phase 7 Slice 15)
# ---------------------------------------------------------------------------


class TestValidateDecisionDigest:
    """Pin drift-validator behaviour for the decision-digest projection.

    Mirrors the comparison contract documented in
    :mod:`runtime.core.hook_doc_validation`: strict byte-for-byte after
    padding the candidate's trailing newlines up to the expected count,
    never removing content. Extra trailing newlines on the candidate
    are real drift.
    """

    def _three_decisions(self):
        return [
            _decision(
                decision_id="DEC-A",
                title="Alpha",
                rationale="why A",
                updated_at=1_700_000_000,
            ),
            _decision(
                decision_id="DEC-B",
                title="Beta",
                rationale="why B",
                updated_at=1_700_000_100,
            ),
            _decision(
                decision_id="DEC-C",
                title="Gamma",
                rationale="why C",
                updated_at=1_700_000_200,
            ),
        ]

    # -- Happy path round trip ---------------------------------------------

    def test_round_trip_from_rendered_output_is_healthy(self):
        decisions = self._three_decisions()
        expected = ddp.render_decision_digest(decisions, cutoff_epoch=0)
        report = ddp.validate_decision_digest(
            expected, decisions, cutoff_epoch=0
        )
        assert report["status"] == "ok"
        assert report["healthy"] is True
        assert report["exact_match"] is True
        assert report["first_mismatch"] is None
        assert (
            report["expected_content_hash"] == report["candidate_content_hash"]
        )

    def test_expected_hash_matches_projection_content_hash(self):
        """Validator and builder must agree on the expected hash.

        This is the single-authority pin: the validator re-uses
        ``render_decision_digest`` to compute the expected bytes, so the
        hash it reports must be byte-identical to
        ``DecisionDigest.content_hash`` that ``build_decision_digest_projection``
        emits from the same rendered body.
        """
        decisions = self._three_decisions()
        expected = ddp.render_decision_digest(decisions, cutoff_epoch=0)
        projection = ddp.build_decision_digest_projection(
            decisions, generated_at=1_700_000_000, cutoff_epoch=0
        )
        report = ddp.validate_decision_digest(
            expected, decisions, cutoff_epoch=0
        )
        assert report["expected_content_hash"] == projection.content_hash

    # -- Trailing-newline tolerance ----------------------------------------

    def test_candidate_missing_single_trailing_newline_is_healthy(self):
        decisions = self._three_decisions()
        expected = ddp.render_decision_digest(decisions, cutoff_epoch=0)
        # Renderer emits a trailing "\n"; strip exactly one.
        candidate = expected.rstrip("\n")
        assert candidate != expected
        report = ddp.validate_decision_digest(
            candidate, decisions, cutoff_epoch=0
        )
        assert report["status"] == "ok", (
            f"trailing-newline-strip should not produce drift; "
            f"first_mismatch={report['first_mismatch']}"
        )
        assert report["healthy"] is True
        assert report["exact_match"] is True

    def test_candidate_with_extra_trailing_newlines_is_drift(self):
        decisions = self._three_decisions()
        expected = ddp.render_decision_digest(decisions, cutoff_epoch=0)
        candidate = expected + "\n\n"  # extra trailing whitespace
        report = ddp.validate_decision_digest(
            candidate, decisions, cutoff_epoch=0
        )
        assert report["status"] == "drift"
        assert report["healthy"] is False
        assert report["exact_match"] is False
        # First-mismatch falls on the first extra line past the expected tail.
        assert report["first_mismatch"] is not None
        assert report["first_mismatch"]["expected"] is None

    # -- Tampered content --------------------------------------------------

    def test_tampered_title_produces_drift_with_first_mismatch(self):
        decisions = self._three_decisions()
        expected = ddp.render_decision_digest(decisions, cutoff_epoch=0)
        # Swap one decision's title in the candidate.
        candidate = expected.replace("Gamma", "Gamma-tampered")
        assert candidate != expected
        report = ddp.validate_decision_digest(
            candidate, decisions, cutoff_epoch=0
        )
        assert report["status"] == "drift"
        assert report["healthy"] is False
        fm = report["first_mismatch"]
        assert fm is not None
        assert fm["line"] >= 1
        assert "Gamma" in (fm["expected"] or "")
        assert "Gamma-tampered" in (fm["candidate"] or "")

    def test_candidate_missing_a_bullet_reports_expected_line(self):
        decisions = self._three_decisions()
        expected = ddp.render_decision_digest(decisions, cutoff_epoch=0)
        lines = expected.splitlines()
        # Drop the final bullet line.
        candidate = "\n".join(lines[:-1]) + "\n"
        report = ddp.validate_decision_digest(
            candidate, decisions, cutoff_epoch=0
        )
        assert report["status"] == "drift"
        fm = report["first_mismatch"]
        assert fm is not None
        # The candidate is missing a line, so its slot reports expected
        # text and candidate=None at the drop point.
        assert fm["candidate"] is None
        assert fm["expected"] is not None

    def test_candidate_with_extra_content_line_reports_extra_in_first_mismatch(self):
        decisions = self._three_decisions()
        expected = ddp.render_decision_digest(decisions, cutoff_epoch=0)
        # Append a non-whitespace extra line before the trailing newline
        # so the trailing-newline padding rule doesn't swallow it.
        candidate = expected + "UNEXPECTED EXTRA LINE\n"
        report = ddp.validate_decision_digest(
            candidate, decisions, cutoff_epoch=0
        )
        assert report["status"] == "drift"
        fm = report["first_mismatch"]
        assert fm is not None
        # The candidate has an extra line past the expected tail: either
        # expected=None (pure trailing extra) or a line-by-line pair at
        # the boundary — both satisfy the "extra line present" predicate.
        assert (
            fm["expected"] is None
            or "UNEXPECTED EXTRA LINE" in (fm["candidate"] or "")
        )

    # -- Empty / boundary cases --------------------------------------------

    def test_empty_candidate_against_empty_projection_is_drift(self):
        """Even an empty-window projection renders a non-empty body.

        ``render_decision_digest`` emits a canonical "no decisions in
        window" placeholder body, so an empty candidate cannot match
        even when the decisions list is empty.
        """
        report = ddp.validate_decision_digest(
            "", [], cutoff_epoch=0
        )
        assert report["status"] == "drift"
        assert report["healthy"] is False
        # Empty candidate + trailing-newline padding yields far fewer
        # lines than the canonical empty-window body.
        assert report["expected_line_count"] > 1
        assert report["candidate_line_count"] < report["expected_line_count"]

    def test_round_trip_empty_decisions_is_healthy(self):
        expected = ddp.render_decision_digest([], cutoff_epoch=0)
        report = ddp.validate_decision_digest(expected, [], cutoff_epoch=0)
        assert report["status"] == "ok"
        assert report["healthy"] is True
        assert report["decision_ids"] == []

    # -- Report shape ------------------------------------------------------

    def test_report_has_all_required_keys(self):
        decisions = self._three_decisions()
        expected = ddp.render_decision_digest(decisions, cutoff_epoch=0)
        report = ddp.validate_decision_digest(
            expected, decisions, cutoff_epoch=0
        )
        required = {
            "status",
            "healthy",
            "expected_content_hash",
            "candidate_content_hash",
            "exact_match",
            "expected_line_count",
            "candidate_line_count",
            "first_mismatch",
            "decision_ids",
            "cutoff_epoch",
            "generator_version",
        }
        assert required <= set(report.keys()), (
            f"missing keys: {required - set(report.keys())}"
        )

    def test_line_counts_are_non_negative_ints(self):
        decisions = self._three_decisions()
        expected = ddp.render_decision_digest(decisions, cutoff_epoch=0)
        report = ddp.validate_decision_digest(
            expected, decisions, cutoff_epoch=0
        )
        assert isinstance(report["expected_line_count"], int)
        assert isinstance(report["candidate_line_count"], int)
        assert report["expected_line_count"] >= 0
        assert report["candidate_line_count"] >= 0

    def test_decision_ids_match_render_order(self):
        decisions = self._three_decisions()
        expected = ddp.render_decision_digest(decisions, cutoff_epoch=0)
        report = ddp.validate_decision_digest(
            expected, decisions, cutoff_epoch=0
        )
        # Rendered descending updated_at: C, B, A.
        assert report["decision_ids"] == ["DEC-C", "DEC-B", "DEC-A"]

    def test_cutoff_epoch_echoed_verbatim(self):
        decisions = self._three_decisions()
        expected = ddp.render_decision_digest(
            decisions, cutoff_epoch=1_700_000_150
        )
        report = ddp.validate_decision_digest(
            expected, decisions, cutoff_epoch=1_700_000_150
        )
        assert report["cutoff_epoch"] == 1_700_000_150
        # Only DEC-C survives cutoff.
        assert report["decision_ids"] == ["DEC-C"]

    def test_generator_version_matches_module_constant(self):
        decisions = self._three_decisions()
        expected = ddp.render_decision_digest(decisions, cutoff_epoch=0)
        report = ddp.validate_decision_digest(
            expected, decisions, cutoff_epoch=0
        )
        assert (
            report["generator_version"]
            == ddp.DECISION_DIGEST_GENERATOR_VERSION
        )

    # -- Input validation --------------------------------------------------

    def test_non_str_candidate_raises_valueerror(self):
        decisions = self._three_decisions()
        with pytest.raises(ValueError, match="candidate must be a str"):
            ddp.validate_decision_digest(
                b"not-a-str", decisions, cutoff_epoch=0  # type: ignore[arg-type]
            )

    def test_duplicate_decision_ids_propagate_valueerror(self):
        dup = self._three_decisions() + [
            _decision(decision_id="DEC-A", title="Alpha 2")
        ]
        with pytest.raises(ValueError, match="duplicate decision_id"):
            ddp.validate_decision_digest("", dup, cutoff_epoch=0)

    def test_negative_cutoff_propagates_valueerror(self):
        decisions = self._three_decisions()
        with pytest.raises(ValueError, match="cutoff_epoch must be non-negative"):
            ddp.validate_decision_digest("", decisions, cutoff_epoch=-1)
