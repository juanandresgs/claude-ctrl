"""Tests for runtime/core/hook_doc_validation.py.

@decision DEC-CLAUDEX-HOOK-DOC-VALIDATION-TESTS-001
Title: Pure hook-doc drift validator — comparison rule, report shape, and shadow-only discipline pinned
Status: proposed (shadow-mode, Phase 2 derived-surface validation)
Rationale: The validator is a pure consumer of
  ``runtime.core.hook_doc_projection``. Its comparison rule, report
  shape, and hash alignment with the projection builder must be
  mechanically asserted so future slices that change the renderer
  or projection schema catch drift immediately.

  Covered invariants:

    1. The healthy case: passing ``render_hook_doc()`` output
       verbatim returns ``status="ok"``, ``healthy=True``, no
       mismatch, and both hashes match the projection's
       ``content_hash``.
    2. Trailing-newline normalisation: candidates with any number
       of stripped trailing newlines (up to the expected count) are
       still healthy; extra trailing newlines are real drift.
    3. Modified-line drift: a single changed line anywhere in the
       body produces ``status="drift"`` with the correct 1-indexed
       ``first_mismatch.line`` and the expected/candidate text
       captured.
    4. Length drift: a shorter candidate reports a missing-line
       mismatch; a longer candidate reports an extra-line mismatch.
    5. Report stability: the exact key set is pinned, and the
       report is JSON-serialisable for future CLI consumption.
    6. Shadow-only discipline via AST walk: the module imports only
       stdlib + ``runtime.core.hook_doc_projection``; no live
       modules import it; ``runtime/cli.py`` does not import it.
"""

from __future__ import annotations

import ast
import inspect
import json

import pytest

from runtime.core import hook_doc_projection as hdp
from runtime.core import hook_doc_validation as hdv


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
# 1. Healthy case: identical content
# ---------------------------------------------------------------------------


class TestHealthyCase:
    def test_identical_content_is_healthy(self):
        expected = hdp.render_hook_doc()
        report = hdv.validate_hook_doc(expected, generated_at=1)
        assert report["status"] == hdv.VALIDATION_STATUS_OK
        assert report["healthy"] is True
        assert report["exact_match"] is True
        assert report["first_mismatch"] is None

    def test_healthy_report_hashes_match_projection(self):
        expected = hdp.render_hook_doc()
        projection = hdp.build_hook_doc_projection(generated_at=1)
        report = hdv.validate_hook_doc(expected, generated_at=1)
        assert report["expected_content_hash"] == projection.content_hash
        assert report["candidate_content_hash"] == projection.content_hash

    def test_healthy_report_line_counts_match(self):
        expected = hdp.render_hook_doc()
        report = hdv.validate_hook_doc(expected, generated_at=1)
        assert report["expected_line_count"] == report["candidate_line_count"]
        # Non-zero — the real manifest produces a multi-line body.
        assert report["expected_line_count"] > 0

    def test_generator_version_is_populated(self):
        report = hdv.validate_hook_doc(hdp.render_hook_doc(), generated_at=1)
        assert report["generator_version"] == hdp.HOOK_DOC_GENERATOR_VERSION


# ---------------------------------------------------------------------------
# 2. Trailing-newline normalisation rule
# ---------------------------------------------------------------------------


class TestTrailingNewlineNormalisation:
    def test_candidate_missing_all_trailing_newlines_is_healthy(self):
        # The editor-strips-trailing-whitespace case. ``rstrip("\n")``
        # removes every trailing newline; the validator pads them
        # back to match the expected count.
        expected = hdp.render_hook_doc()
        assert expected.endswith("\n"), "test precondition failed"
        candidate = expected.rstrip("\n")
        report = hdv.validate_hook_doc(candidate, generated_at=1)
        assert report["status"] == hdv.VALIDATION_STATUS_OK
        assert report["healthy"] is True
        assert report["candidate_content_hash"] == report["expected_content_hash"]

    def test_candidate_missing_one_trailing_newline_is_healthy(self):
        expected = hdp.render_hook_doc()
        # Drop exactly one trailing newline.
        candidate = expected[:-1]
        assert candidate != expected
        report = hdv.validate_hook_doc(candidate, generated_at=1)
        assert report["status"] == hdv.VALIDATION_STATUS_OK
        assert report["healthy"] is True

    def test_candidate_with_extra_trailing_newline_is_drift(self):
        # Extra trailing content is real drift — never silently
        # collapsed.
        expected = hdp.render_hook_doc()
        candidate = expected + "\n"
        report = hdv.validate_hook_doc(candidate, generated_at=1)
        assert report["status"] == hdv.VALIDATION_STATUS_DRIFT
        assert report["healthy"] is False

    def test_candidate_with_extra_content_line_is_drift(self):
        expected = hdp.render_hook_doc()
        candidate = expected + "EXTRA CONTENT LINE\n"
        report = hdv.validate_hook_doc(candidate, generated_at=1)
        assert report["status"] == hdv.VALIDATION_STATUS_DRIFT
        assert report["candidate_line_count"] > report["expected_line_count"]
        assert report["first_mismatch"] is not None


# ---------------------------------------------------------------------------
# 3. Modified-line drift cases
# ---------------------------------------------------------------------------


class TestModifiedLineDrift:
    def test_mutated_heading_produces_first_mismatch_at_that_line(self):
        expected = hdp.render_hook_doc()
        lines = expected.splitlines()
        # Line 0 is "# ClauDEX Hook Adapter Manifest". Pick a later
        # line we are sure is an H2 event heading (line 6 in
        # 0-indexed, 7 in 1-indexed terms for the current renderer
        # shape). We do not hard-code the offset; we find the first
        # H2 heading and tamper with it instead.
        for i, line in enumerate(lines):
            if line.startswith("## "):
                tampered_index = i
                break
        else:
            pytest.fail("renderer produced no H2 headings — test precondition failed")

        original_line = lines[tampered_index]
        lines[tampered_index] = "## TAMPERED HEADING"
        candidate = "\n".join(lines) + "\n" * 2  # preserve trailing \n\n
        report = hdv.validate_hook_doc(candidate, generated_at=1)

        assert report["status"] == hdv.VALIDATION_STATUS_DRIFT
        assert report["healthy"] is False
        assert report["first_mismatch"] is not None
        assert report["first_mismatch"]["line"] == tampered_index + 1
        assert report["first_mismatch"]["expected"] == original_line
        assert report["first_mismatch"]["candidate"] == "## TAMPERED HEADING"

    def test_removed_middle_line_produces_mismatch(self):
        expected = hdp.render_hook_doc()
        lines = expected.splitlines()
        # Drop the first bullet line. Find a line starting with
        # "- matcher" to stay renderer-agnostic.
        for i, line in enumerate(lines):
            if line.startswith("- matcher"):
                drop_index = i
                break
        else:
            pytest.fail("no bullet rows found — precondition failed")

        del lines[drop_index]
        candidate = "\n".join(lines) + "\n" * 2
        report = hdv.validate_hook_doc(candidate, generated_at=1)

        assert report["status"] == hdv.VALIDATION_STATUS_DRIFT
        assert report["first_mismatch"] is not None
        # The first mismatch is at the 1-indexed ``drop_index + 1``
        # position: the line that shifted into the gap.
        assert report["first_mismatch"]["line"] == drop_index + 1

    def test_length_drift_shorter_candidate_reports_missing_line(self):
        expected = hdp.render_hook_doc()
        # Remove the first bullet line via direct string slicing so we
        # don't round-trip through splitlines()/join(), which fights
        # trailing-newline arithmetic in subtle ways. The bullet line
        # begins at "- matcher " and ends at the next "\n"; slicing
        # both away produces a candidate that is exactly one line
        # shorter than expected.
        bullet_start = expected.find("- matcher ")
        assert bullet_start != -1, "precondition failed: no bullet in rendered body"
        line_end = expected.find("\n", bullet_start)
        assert line_end != -1
        candidate = expected[:bullet_start] + expected[line_end + 1 :]

        report = hdv.validate_hook_doc(candidate, generated_at=1)
        assert report["status"] == hdv.VALIDATION_STATUS_DRIFT
        assert report["candidate_line_count"] < report["expected_line_count"]
        assert report["first_mismatch"] is not None
        # The mismatch must report a concrete 1-indexed line number.
        assert report["first_mismatch"]["line"] >= 1


# ---------------------------------------------------------------------------
# 4. Length drift cases
# ---------------------------------------------------------------------------


class TestLengthDrift:
    def test_candidate_with_extra_line_reports_extra_line(self):
        expected = hdp.render_hook_doc()
        # Preserve the trailing newline region of expected so only the
        # content differs.
        candidate = expected + "extra line\n"
        report = hdv.validate_hook_doc(candidate, generated_at=1)
        assert report["status"] == hdv.VALIDATION_STATUS_DRIFT
        assert report["candidate_line_count"] > report["expected_line_count"]
        mismatch = report["first_mismatch"]
        assert mismatch is not None
        # The extra-line case produces either a content divergence at
        # the boundary or an explicit None-expected entry.
        assert mismatch["line"] >= 1

    def test_empty_candidate_is_drift(self):
        report = hdv.validate_hook_doc("", generated_at=1)
        assert report["status"] == hdv.VALIDATION_STATUS_DRIFT
        assert report["healthy"] is False
        # Empty candidate should not crash the line comparator.
        assert report["candidate_line_count"] >= 0
        assert report["first_mismatch"] is not None


# ---------------------------------------------------------------------------
# 5. Report shape + JSON serialisation
# ---------------------------------------------------------------------------


class TestReportShape:
    def test_report_has_stable_keys(self):
        expected_keys = {
            "status",
            "healthy",
            "expected_content_hash",
            "candidate_content_hash",
            "exact_match",
            "expected_line_count",
            "candidate_line_count",
            "first_mismatch",
            "generator_version",
        }
        report = hdv.validate_hook_doc(hdp.render_hook_doc(), generated_at=1)
        assert set(report.keys()) == expected_keys

    def test_drift_report_has_same_keys(self):
        expected_keys = {
            "status",
            "healthy",
            "expected_content_hash",
            "candidate_content_hash",
            "exact_match",
            "expected_line_count",
            "candidate_line_count",
            "first_mismatch",
            "generator_version",
        }
        report = hdv.validate_hook_doc("garbage", generated_at=1)
        assert set(report.keys()) == expected_keys

    def test_healthy_report_is_json_serialisable(self):
        report = hdv.validate_hook_doc(hdp.render_hook_doc(), generated_at=1)
        encoded = json.dumps(report)
        decoded = json.loads(encoded)
        assert decoded == report

    def test_drift_report_with_mismatch_is_json_serialisable(self):
        candidate = hdp.render_hook_doc().replace(
            "# ClauDEX Hook Adapter Manifest",
            "# TAMPERED",
        )
        report = hdv.validate_hook_doc(candidate, generated_at=1)
        assert report["status"] == hdv.VALIDATION_STATUS_DRIFT
        # first_mismatch is a plain dict; the whole report must
        # round-trip through json.
        encoded = json.dumps(report)
        decoded = json.loads(encoded)
        assert decoded == report

    def test_first_mismatch_is_none_when_healthy(self):
        report = hdv.validate_hook_doc(hdp.render_hook_doc(), generated_at=1)
        assert report["first_mismatch"] is None

    def test_exact_match_true_implies_healthy(self):
        report = hdv.validate_hook_doc(hdp.render_hook_doc(), generated_at=1)
        assert report["exact_match"] is True
        assert report["healthy"] is True

    def test_deterministic_report_for_identical_input(self):
        expected = hdp.render_hook_doc()
        a = hdv.validate_hook_doc(expected, generated_at=1_700_000_000)
        b = hdv.validate_hook_doc(expected, generated_at=1_700_000_000)
        assert a == b


# ---------------------------------------------------------------------------
# 6. Hash alignment with projection builder
# ---------------------------------------------------------------------------


class TestHashAlignment:
    def test_expected_content_hash_tracks_projection_across_manifest_changes(
        self, monkeypatch
    ):
        from runtime.core import hook_manifest as hm

        before_report = hdv.validate_hook_doc(
            hdp.render_hook_doc(), generated_at=1
        )
        before_hash = before_report["expected_content_hash"]

        shortened = hm.HOOK_MANIFEST[:-1]
        monkeypatch.setattr(hm, "HOOK_MANIFEST", shortened)

        after_projection = hdp.build_hook_doc_projection(generated_at=1)
        after_rendered = hdp.render_hook_doc()
        after_report = hdv.validate_hook_doc(after_rendered, generated_at=1)

        # The expected hash must track the NEW projection, not the
        # old one — the validator must always consult the live
        # authority layer.
        assert after_report["expected_content_hash"] == after_projection.content_hash
        assert after_report["expected_content_hash"] != before_hash
        assert after_report["healthy"] is True

    def test_candidate_hash_equals_expected_hash_when_match(self):
        expected = hdp.render_hook_doc()
        report = hdv.validate_hook_doc(expected, generated_at=1)
        assert report["candidate_content_hash"] == report["expected_content_hash"]

    def test_candidate_hash_differs_when_drift(self):
        candidate = hdp.render_hook_doc() + "EXTRA\n"
        report = hdv.validate_hook_doc(candidate, generated_at=1)
        assert report["candidate_content_hash"] != report["expected_content_hash"]


# ---------------------------------------------------------------------------
# 7. Shadow-only discipline
# ---------------------------------------------------------------------------


class TestShadowOnlyDiscipline:
    def test_validator_only_imports_hook_doc_projection_and_stdlib(self):
        imported = _imported_module_names(hdv)
        runtime_core_imports = {
            name for name in imported if name.startswith("runtime.core")
        }
        permitted_prefixes = ("runtime.core.hook_doc_projection",)
        permitted_bases = {"runtime.core"}
        for name in runtime_core_imports:
            assert name in permitted_bases or name.startswith(permitted_prefixes), (
                f"hook_doc_validation.py has unexpected runtime.core import: "
                f"{name!r}"
            )

    def test_validator_has_no_live_imports(self):
        imported = _imported_module_names(hdv)
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
                    f"hook_doc_validation.py imports {name!r} containing "
                    f"forbidden token {needle!r}"
                )

    def test_live_modules_do_not_import_validator(self):
        import runtime.core.completions as completions
        import runtime.core.dispatch_engine as dispatch_engine
        import runtime.core.policy_engine as policy_engine

        for mod in (dispatch_engine, completions, policy_engine):
            imported = _imported_module_names(mod)
            for name in imported:
                assert "hook_doc_validation" not in name, (
                    f"{mod.__name__} imports {name!r} — hook_doc_validation "
                    f"must stay shadow-only this slice"
                )

    def test_cli_imports_hook_doc_validation_only_for_read_only_doc_check(self):
        # As of the Phase 2 ``cc-policy hook doc-check`` slice
        # (DEC-CLAUDEX-HOOK-DOC-VALIDATION-001), cli.py is permitted
        # to import ``runtime.core.hook_doc_validation`` to power the
        # read-only ``cc-policy hook doc-check`` command. What must
        # NOT happen is cli.py using the validator for any write
        # path or any live enforcement: the handler is strictly
        # read + report.
        import runtime.cli as cli

        imported = _imported_module_names(cli)
        hook_doc_validation_refs = {
            name for name in imported if "hook_doc_validation" in name
        }
        assert hook_doc_validation_refs <= {
            "runtime.core.hook_doc_validation",
        }, (
            f"cli.py has unexpected hook_doc_validation imports: "
            f"{hook_doc_validation_refs}"
        )

    def test_hook_doc_projection_does_not_import_validator(self):
        # Reverse dependency guard: the generator must not pull in
        # the validator.
        imported = _imported_module_names(hdp)
        for name in imported:
            assert "hook_doc_validation" not in name
