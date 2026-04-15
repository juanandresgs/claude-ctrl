"""Tests for runtime/core/prompt_pack_validation.py.

@decision DEC-CLAUDEX-PROMPT-PACK-VALIDATION-TESTS-001
Title: Pure prompt-pack drift validator — comparison rule, report shape, and hash alignment pinned
Status: proposed (shadow-mode, Phase 2 prompt-pack drift validation)
Rationale: The prompt-pack drift validator is the symmetric
  counterpart to ``runtime.core.hook_doc_validation``. Its
  comparison rule, report shape, and hash alignment with
  ``runtime.core.prompt_pack.build_prompt_pack`` must be
  mechanically asserted so a future slice that changes the compiler
  output format catches drift immediately.

  Covered invariants:

    1. Healthy case: passing ``render_prompt_pack(...)`` output
       verbatim returns ``status="ok"`` with hashes that match
       ``build_prompt_pack(...).content_hash``.
    2. Trailing-newline normalisation: candidates missing any
       trailing newlines (up to the expected count) are forgiven;
       extra trailing newlines are real drift.
    3. Modified-line drift: a single changed line produces
       ``status="drift"`` with the correct 1-indexed
       ``first_mismatch.line`` and captured expected/candidate
       strings.
    4. Length drift: shorter / longer candidates produce missing /
       extra line mismatches.
    5. Report stability: exact 11-key set pinned, JSON-serialisable,
       identity fields (``workflow_id``, ``stage_id``) echoed back.
    6. Hash alignment: ``report["expected_content_hash"]`` is
       literally ``build_prompt_pack(...).content_hash`` for the
       same inputs, even when those inputs change across calls.
    7. Delegation: malformed layer input raises ``ValueError`` from
       the compiler — the validator does not catch / swallow it.
    8. Shadow-only discipline via AST walk: the module imports only
       stdlib + ``runtime.core.prompt_pack``; no live modules import
       it; ``runtime/cli.py`` does not import it.
"""

from __future__ import annotations

import ast
import hashlib
import inspect
import json

import pytest

from runtime.core import prompt_pack as pp
from runtime.core import prompt_pack_validation as ppv


def _imported_module_names(module) -> set[str]:
    """Return all imported names, including those inside function bodies."""
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


def _module_level_imported_names(module) -> set[str]:
    """Return only module-level (top-level statement) imported names.

    Excludes imports inside function or class bodies.  Used to guard
    against module-level circular dependencies while permitting the
    established function-local import pattern.
    """
    tree = ast.parse(inspect.getsource(module))
    names: set[str] = set()
    for node in tree.body:  # top-level statements only
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


def _default_layers(suffix: str = "") -> dict:
    return {
        name: f"Body for {name}{suffix}."
        for name in pp.CANONICAL_LAYER_ORDER
    }


# Canonical validator call shape used across the test module.
_DEFAULT_WORKFLOW = "wf-test"
_DEFAULT_STAGE = "planner"
_DEFAULT_GENERATED_AT = 1_700_000_000


def _validate(candidate: str, **overrides) -> dict:
    kwargs = {
        "workflow_id": _DEFAULT_WORKFLOW,
        "stage_id": _DEFAULT_STAGE,
        "layers": _default_layers(),
        "generated_at": _DEFAULT_GENERATED_AT,
    }
    kwargs.update(overrides)
    return ppv.validate_prompt_pack(candidate, **kwargs)


def _expected_text(**overrides) -> str:
    kwargs = {
        "workflow_id": _DEFAULT_WORKFLOW,
        "stage_id": _DEFAULT_STAGE,
        "layers": _default_layers(),
    }
    kwargs.update(overrides)
    return pp.render_prompt_pack(**kwargs)


def _expected_pack(**overrides):
    kwargs = {
        "workflow_id": _DEFAULT_WORKFLOW,
        "stage_id": _DEFAULT_STAGE,
        "layers": _default_layers(),
        "generated_at": _DEFAULT_GENERATED_AT,
    }
    kwargs.update(overrides)
    return pp.build_prompt_pack(**kwargs)


# ---------------------------------------------------------------------------
# 1. Healthy case: identical content
# ---------------------------------------------------------------------------


class TestHealthyCase:
    def test_identical_content_is_healthy(self):
        report = _validate(_expected_text())
        assert report["status"] == ppv.VALIDATION_STATUS_OK
        assert report["healthy"] is True
        assert report["exact_match"] is True
        assert report["first_mismatch"] is None

    def test_healthy_report_hashes_match_build_prompt_pack(self):
        pack = _expected_pack()
        report = _validate(_expected_text())
        assert report["expected_content_hash"] == pack.content_hash
        assert report["candidate_content_hash"] == pack.content_hash

    def test_healthy_report_line_counts_match(self):
        report = _validate(_expected_text())
        assert report["expected_line_count"] == report["candidate_line_count"]
        assert report["expected_line_count"] > 0

    def test_generator_version_is_populated(self):
        report = _validate(_expected_text())
        assert report["generator_version"] == pp.PROMPT_PACK_GENERATOR_VERSION

    def test_identity_fields_are_echoed_back(self):
        report = _validate(
            _expected_text(workflow_id="wf-echo", stage_id="reviewer"),
            workflow_id="wf-echo",
            stage_id="reviewer",
        )
        assert report["workflow_id"] == "wf-echo"
        assert report["stage_id"] == "reviewer"
        assert report["healthy"] is True


# ---------------------------------------------------------------------------
# 2. Trailing-newline normalisation rule
# ---------------------------------------------------------------------------


class TestTrailingNewlineNormalisation:
    def test_candidate_missing_all_trailing_newlines_is_healthy(self):
        expected = _expected_text()
        assert expected.endswith("\n"), "test precondition failed"
        candidate = expected.rstrip("\n")
        report = _validate(candidate)
        assert report["status"] == ppv.VALIDATION_STATUS_OK
        assert report["healthy"] is True
        assert report["candidate_content_hash"] == report["expected_content_hash"]

    def test_candidate_missing_one_trailing_newline_is_healthy(self):
        expected = _expected_text()
        candidate = expected[:-1]
        assert candidate != expected
        report = _validate(candidate)
        assert report["status"] == ppv.VALIDATION_STATUS_OK
        assert report["healthy"] is True

    def test_candidate_with_extra_trailing_newline_is_drift(self):
        expected = _expected_text()
        candidate = expected + "\n"
        report = _validate(candidate)
        assert report["status"] == ppv.VALIDATION_STATUS_DRIFT
        assert report["healthy"] is False

    def test_candidate_with_extra_content_line_is_drift(self):
        expected = _expected_text()
        candidate = expected + "EXTRA CONTENT LINE\n"
        report = _validate(candidate)
        assert report["status"] == ppv.VALIDATION_STATUS_DRIFT
        assert report["candidate_line_count"] > report["expected_line_count"]
        assert report["first_mismatch"] is not None


# ---------------------------------------------------------------------------
# 3. Modified-line drift cases
# ---------------------------------------------------------------------------


class TestModifiedLineDrift:
    def test_mutated_title_produces_first_mismatch_at_line_1(self):
        expected = _expected_text()
        lines = expected.splitlines()
        original_title = lines[0]
        assert original_title.startswith("# ClauDEX Prompt Pack:")
        lines[0] = "# TAMPERED TITLE"
        candidate = "\n".join(lines) + "\n"
        report = _validate(candidate)
        assert report["status"] == ppv.VALIDATION_STATUS_DRIFT
        assert report["first_mismatch"] is not None
        assert report["first_mismatch"]["line"] == 1
        assert report["first_mismatch"]["expected"] == original_title
        assert report["first_mismatch"]["candidate"] == "# TAMPERED TITLE"

    def test_mutated_layer_heading_produces_mismatch(self):
        expected = _expected_text()
        lines = expected.splitlines()
        # Find the first ``## `` heading (one per canonical layer).
        for i, line in enumerate(lines):
            if line.startswith("## "):
                tampered_index = i
                break
        else:
            pytest.fail("no layer heading found — precondition failed")

        original_line = lines[tampered_index]
        lines[tampered_index] = "## tampered_layer_name"
        candidate = "\n".join(lines) + "\n"
        report = _validate(candidate)
        assert report["status"] == ppv.VALIDATION_STATUS_DRIFT
        assert report["first_mismatch"]["line"] == tampered_index + 1
        assert report["first_mismatch"]["expected"] == original_line
        assert report["first_mismatch"]["candidate"] == "## tampered_layer_name"

    def test_mutated_layer_body_produces_mismatch(self):
        layers = _default_layers()
        pack_layers = dict(layers)
        pack_layers["constitution"] = "ORIGINAL constitution body"
        expected = pp.render_prompt_pack(
            workflow_id=_DEFAULT_WORKFLOW,
            stage_id=_DEFAULT_STAGE,
            layers=pack_layers,
        )
        # Build candidate by editing the body line.
        candidate = expected.replace(
            "ORIGINAL constitution body",
            "TAMPERED constitution body",
            1,
        )
        report = _validate(
            candidate, layers=pack_layers
        )
        assert report["status"] == ppv.VALIDATION_STATUS_DRIFT
        assert report["first_mismatch"] is not None
        # The mismatch line must be somewhere inside the rendered body.
        assert report["first_mismatch"]["line"] >= 1
        assert "TAMPERED" in report["first_mismatch"]["candidate"]
        assert "ORIGINAL" in report["first_mismatch"]["expected"]

    def test_length_drift_shorter_candidate_reports_missing_line(self):
        expected = _expected_text()
        # Remove the first layer heading line via direct string
        # slicing so we don't round-trip through splitlines/join.
        heading_start = expected.find("## ")
        assert heading_start != -1
        line_end = expected.find("\n", heading_start)
        assert line_end != -1
        candidate = expected[:heading_start] + expected[line_end + 1 :]
        report = _validate(candidate)
        assert report["status"] == ppv.VALIDATION_STATUS_DRIFT
        assert report["candidate_line_count"] < report["expected_line_count"]
        assert report["first_mismatch"] is not None
        assert report["first_mismatch"]["line"] >= 1


# ---------------------------------------------------------------------------
# 4. Length drift + empty candidate
# ---------------------------------------------------------------------------


class TestLengthDrift:
    def test_candidate_with_extra_line_reports_drift(self):
        expected = _expected_text()
        candidate = expected + "extra line\n"
        report = _validate(candidate)
        assert report["status"] == ppv.VALIDATION_STATUS_DRIFT
        assert report["candidate_line_count"] > report["expected_line_count"]

    def test_empty_candidate_is_drift(self):
        report = _validate("")
        assert report["status"] == ppv.VALIDATION_STATUS_DRIFT
        assert report["healthy"] is False
        assert report["first_mismatch"] is not None


# ---------------------------------------------------------------------------
# 5. Report shape + JSON serialisation
# ---------------------------------------------------------------------------


EXPECTED_REPORT_KEYS = {
    "status",
    "healthy",
    "expected_content_hash",
    "candidate_content_hash",
    "exact_match",
    "expected_line_count",
    "candidate_line_count",
    "first_mismatch",
    "generator_version",
    "workflow_id",
    "stage_id",
}


class TestReportShape:
    def test_healthy_report_has_stable_keys(self):
        report = _validate(_expected_text())
        assert set(report.keys()) == EXPECTED_REPORT_KEYS

    def test_drift_report_has_same_keys(self):
        report = _validate("garbage")
        assert set(report.keys()) == EXPECTED_REPORT_KEYS

    def test_healthy_report_is_json_serialisable(self):
        report = _validate(_expected_text())
        encoded = json.dumps(report)
        decoded = json.loads(encoded)
        assert decoded == report

    def test_drift_report_with_mismatch_is_json_serialisable(self):
        candidate = _expected_text().replace(
            "# ClauDEX Prompt Pack:",
            "# TAMPERED:",
        )
        report = _validate(candidate)
        assert report["status"] == ppv.VALIDATION_STATUS_DRIFT
        encoded = json.dumps(report)
        decoded = json.loads(encoded)
        assert decoded == report

    def test_first_mismatch_is_none_when_healthy(self):
        report = _validate(_expected_text())
        assert report["first_mismatch"] is None

    def test_exact_match_true_implies_healthy(self):
        report = _validate(_expected_text())
        assert report["exact_match"] is True
        assert report["healthy"] is True

    def test_deterministic_report_for_identical_input(self):
        text = _expected_text()
        a = _validate(text)
        b = _validate(text)
        assert a == b


# ---------------------------------------------------------------------------
# 6. Hash alignment with build_prompt_pack
# ---------------------------------------------------------------------------


class TestHashAlignment:
    def test_expected_hash_tracks_workflow_id_changes(self):
        pack_a = _expected_pack(workflow_id="wf-one")
        pack_b = _expected_pack(workflow_id="wf-two")
        assert pack_a.content_hash != pack_b.content_hash

        report_a = _validate(
            _expected_text(workflow_id="wf-one"), workflow_id="wf-one"
        )
        report_b = _validate(
            _expected_text(workflow_id="wf-two"), workflow_id="wf-two"
        )
        assert report_a["expected_content_hash"] == pack_a.content_hash
        assert report_b["expected_content_hash"] == pack_b.content_hash
        assert report_a["expected_content_hash"] != report_b["expected_content_hash"]

    def test_expected_hash_tracks_stage_id_changes(self):
        pack_a = _expected_pack(stage_id="planner")
        pack_b = _expected_pack(stage_id="reviewer")
        assert pack_a.content_hash != pack_b.content_hash

        report_a = _validate(
            _expected_text(stage_id="planner"), stage_id="planner"
        )
        report_b = _validate(
            _expected_text(stage_id="reviewer"), stage_id="reviewer"
        )
        assert report_a["expected_content_hash"] == pack_a.content_hash
        assert report_b["expected_content_hash"] == pack_b.content_hash

    def test_expected_hash_tracks_layer_content_changes(self):
        base_layers = _default_layers()
        pack_a = _expected_pack(layers=base_layers)

        mutated = dict(base_layers)
        mutated["stage_contract"] = mutated["stage_contract"] + " [edit]"
        pack_b = _expected_pack(layers=mutated)
        assert pack_a.content_hash != pack_b.content_hash

        report_a = _validate(
            pp.render_prompt_pack(
                workflow_id=_DEFAULT_WORKFLOW,
                stage_id=_DEFAULT_STAGE,
                layers=base_layers,
            ),
            layers=base_layers,
        )
        report_b = _validate(
            pp.render_prompt_pack(
                workflow_id=_DEFAULT_WORKFLOW,
                stage_id=_DEFAULT_STAGE,
                layers=mutated,
            ),
            layers=mutated,
        )
        assert report_a["expected_content_hash"] == pack_a.content_hash
        assert report_b["expected_content_hash"] == pack_b.content_hash

    def test_candidate_hash_equals_expected_hash_when_match(self):
        report = _validate(_expected_text())
        assert report["candidate_content_hash"] == report["expected_content_hash"]

    def test_candidate_hash_differs_when_drift(self):
        report = _validate(_expected_text() + "EXTRA\n")
        assert report["candidate_content_hash"] != report["expected_content_hash"]

    def test_candidate_hash_is_sha256_format(self):
        report = _validate(_expected_text())
        assert report["candidate_content_hash"].startswith("sha256:")
        # sha256 hex digest is 64 chars; total length = 7 + 64 = 71
        assert len(report["candidate_content_hash"]) == len("sha256:") + 64


# ---------------------------------------------------------------------------
# 7. Delegation of input validation to the compiler
# ---------------------------------------------------------------------------


class TestValidationDelegation:
    def test_missing_layer_raises_value_error(self):
        bad = _default_layers()
        del bad["constitution"]
        with pytest.raises(ValueError, match="missing canonical entries"):
            _validate(_expected_text(), layers=bad)

    def test_extra_layer_raises_value_error(self):
        bad = _default_layers()
        bad["rogue_layer"] = "unexpected"
        with pytest.raises(ValueError, match="unknown entries"):
            _validate("whatever", layers=bad)

    def test_empty_layer_raises_value_error(self):
        bad = _default_layers()
        bad["stage_contract"] = ""
        with pytest.raises(ValueError, match="non-empty"):
            _validate("whatever", layers=bad)

    def test_empty_workflow_id_raises_value_error(self):
        with pytest.raises(ValueError, match="workflow_id"):
            _validate("whatever", workflow_id="")

    def test_empty_stage_id_raises_value_error(self):
        with pytest.raises(ValueError, match="stage_id"):
            _validate("whatever", stage_id="")


# ---------------------------------------------------------------------------
# 8. Shadow-only discipline
# ---------------------------------------------------------------------------


class TestShadowOnlyDiscipline:
    def test_validator_only_imports_prompt_pack_and_stdlib(self):
        imported = _imported_module_names(ppv)
        runtime_core_imports = {
            name for name in imported if name.startswith("runtime.core")
        }
        permitted_prefixes = ("runtime.core.prompt_pack",)
        permitted_bases = {"runtime.core"}
        for name in runtime_core_imports:
            assert name in permitted_bases or name.startswith(permitted_prefixes), (
                f"prompt_pack_validation.py has unexpected runtime.core "
                f"import: {name!r}"
            )

    def test_validator_has_no_live_imports(self):
        imported = _imported_module_names(ppv)
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
                    f"prompt_pack_validation.py imports {name!r} containing "
                    f"forbidden token {needle!r}"
                )

    def test_live_modules_do_not_import_validator(self):
        import runtime.core.completions as completions
        import runtime.core.dispatch_engine as dispatch_engine
        import runtime.core.policy_engine as policy_engine

        for mod in (dispatch_engine, completions, policy_engine):
            imported = _imported_module_names(mod)
            for name in imported:
                assert "prompt_pack_validation" not in name, (
                    f"{mod.__name__} imports {name!r} — "
                    f"prompt_pack_validation must stay shadow-only"
                )

    def test_cli_imports_prompt_pack_validation_only_for_read_only_check(self):
        # As of the Phase 2 ``cc-policy prompt-pack check`` slice
        # (DEC-CLAUDEX-PROMPT-PACK-CHECK-CLI-001), cli.py is
        # permitted to import ``runtime.core.prompt_pack_validation``
        # to power the read-only ``cc-policy prompt-pack check``
        # command. What must NOT happen is cli.py using the
        # validator for any write path or any live enforcement: the
        # handler is strictly read + report.
        import runtime.cli as cli

        imported = _imported_module_names(cli)
        refs = {
            name for name in imported if "prompt_pack_validation" in name
        }
        assert refs <= {"runtime.core.prompt_pack_validation"}, (
            f"cli.py has unexpected prompt_pack_validation imports: {refs}"
        )

    def test_prompt_pack_does_not_import_validator_at_module_level(self):
        # Reverse module-level dependency guard.
        # prompt_pack.py uses a function-local import of prompt_pack_validation
        # inside build_subagent_start_prompt_pack_response to call the canonical
        # request validator without creating a module-level load cycle.
        # Module-level imports in the reverse direction are still forbidden.
        module_level = _module_level_imported_names(pp)
        for name in module_level:
            assert "prompt_pack_validation" not in name


# ---------------------------------------------------------------------------
# 9. SubagentStart envelope validator
# ---------------------------------------------------------------------------


def _valid_envelope(**overrides) -> dict:
    """Build a fresh valid envelope via the canonical builder."""
    workflow_id = overrides.pop("workflow_id", "wf-sse-valid")
    stage_id = overrides.pop("stage_id", "planner")
    content_hash = overrides.pop("content_hash", "sha256:abc123")
    rendered_body = overrides.pop(
        "rendered_body",
        pp.render_prompt_pack(
            workflow_id=workflow_id,
            stage_id=stage_id,
            layers=_default_layers(),
        ),
    )
    assert not overrides, f"unexpected _valid_envelope overrides: {overrides}"
    return pp.build_subagent_start_envelope(
        workflow_id=workflow_id,
        stage_id=stage_id,
        content_hash=content_hash,
        rendered_body=rendered_body,
    )


def _corrupt_context(envelope: dict, *, context: str) -> dict:
    """Return a shallow copy of ``envelope`` with a replaced additionalContext."""
    return {
        "hookSpecificOutput": {
            "hookEventName": envelope["hookSpecificOutput"]["hookEventName"],
            "additionalContext": context,
        }
    }


# -- 9a. Happy path and report shape --------------------------------------


class TestSubagentStartEnvelopeHappyPath:
    def test_valid_envelope_reports_ok(self):
        report = ppv.validate_subagent_start_envelope(_valid_envelope())
        assert report["status"] == ppv.VALIDATION_STATUS_OK
        assert report["healthy"] is True
        assert report["violations"] == []

    def test_report_shape_is_stable(self):
        report = ppv.validate_subagent_start_envelope(_valid_envelope())
        assert set(report.keys()) == {
            "status",
            "healthy",
            "violations",
            "workflow_id",
            "stage_id",
            "content_hash",
            "body_line_count",
        }

    def test_report_extracts_workflow_id(self):
        report = ppv.validate_subagent_start_envelope(
            _valid_envelope(workflow_id="wf-extracted")
        )
        assert report["workflow_id"] == "wf-extracted"

    def test_report_extracts_stage_id(self):
        report = ppv.validate_subagent_start_envelope(
            _valid_envelope(stage_id="guardian:land")
        )
        assert report["stage_id"] == "guardian:land"

    def test_report_extracts_content_hash(self):
        report = ppv.validate_subagent_start_envelope(
            _valid_envelope(content_hash="sha256:deadbeef")
        )
        assert report["content_hash"] == "sha256:deadbeef"

    def test_report_body_line_count_is_positive(self):
        report = ppv.validate_subagent_start_envelope(_valid_envelope())
        assert report["body_line_count"] > 0

    def test_report_is_json_serialisable(self):
        report = ppv.validate_subagent_start_envelope(_valid_envelope())
        encoded = json.dumps(report)
        decoded = json.loads(encoded)
        assert decoded == report

    def test_report_is_deterministic(self):
        env = _valid_envelope()
        a = ppv.validate_subagent_start_envelope(env)
        b = ppv.validate_subagent_start_envelope(env)
        assert a == b


# -- 9b. Top-level shape violations ---------------------------------------


class TestSubagentStartEnvelopeTopLevelShape:
    def test_non_dict_input_rejected(self):
        report = ppv.validate_subagent_start_envelope("not a dict")
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert report["healthy"] is False
        assert any("mapping" in v for v in report["violations"])

    def test_none_input_rejected(self):
        report = ppv.validate_subagent_start_envelope(None)
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any("mapping" in v for v in report["violations"])

    def test_list_input_rejected(self):
        report = ppv.validate_subagent_start_envelope([1, 2, 3])
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID

    def test_missing_hook_specific_output_key(self):
        report = ppv.validate_subagent_start_envelope({"wrong_key": {}})
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        # The top-level-keys violation should fire AND the
        # hookSpecificOutput-type violation should fire.
        assert any(
            "hookSpecificOutput" in v for v in report["violations"]
        )

    def test_extra_top_level_key_rejected(self):
        env = _valid_envelope()
        env["extra_key"] = "rogue"
        report = ppv.validate_subagent_start_envelope(env)
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any(
            "top-level keys" in v for v in report["violations"]
        )

    def test_inner_not_mapping_rejected(self):
        report = ppv.validate_subagent_start_envelope(
            {"hookSpecificOutput": "not a dict"}
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any(
            "hookSpecificOutput must be a mapping" in v
            for v in report["violations"]
        )

    def test_inner_missing_keys_rejected(self):
        report = ppv.validate_subagent_start_envelope(
            {"hookSpecificOutput": {"hookEventName": "SubagentStart"}}
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any(
            "hookSpecificOutput keys" in v for v in report["violations"]
        )

    def test_inner_extra_keys_rejected(self):
        report = ppv.validate_subagent_start_envelope(
            {
                "hookSpecificOutput": {
                    "hookEventName": "SubagentStart",
                    "additionalContext": "[runtime-compiled prompt pack]\n"
                    "workflow_id: a\nstage_id: b\ncontent_hash: c\n\nbody\n",
                    "rogue_key": "x",
                }
            }
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any(
            "hookSpecificOutput keys" in v for v in report["violations"]
        )


# -- 9c. Wrong hookEventName ----------------------------------------------


class TestSubagentStartEnvelopeWrongEventName:
    def test_wrong_event_name_rejected(self):
        env = _valid_envelope()
        env["hookSpecificOutput"]["hookEventName"] = "UserPromptSubmit"
        report = ppv.validate_subagent_start_envelope(env)
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any(
            "hookEventName" in v and "SubagentStart" in v
            for v in report["violations"]
        )

    def test_empty_event_name_rejected(self):
        env = _valid_envelope()
        env["hookSpecificOutput"]["hookEventName"] = ""
        report = ppv.validate_subagent_start_envelope(env)
        assert any("hookEventName" in v for v in report["violations"])

    def test_non_string_event_name_rejected(self):
        env = _valid_envelope()
        env["hookSpecificOutput"]["hookEventName"] = 42
        report = ppv.validate_subagent_start_envelope(env)
        assert any("hookEventName" in v for v in report["violations"])


# -- 9d. additionalContext field issues -----------------------------------


class TestSubagentStartEnvelopeAdditionalContextField:
    def test_missing_additional_context_rejected(self):
        report = ppv.validate_subagent_start_envelope(
            {
                "hookSpecificOutput": {
                    "hookEventName": "SubagentStart",
                }
            }
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any(
            "additionalContext must be a string" in v
            for v in report["violations"]
        )

    def test_non_string_additional_context_rejected(self):
        env = _valid_envelope()
        env["hookSpecificOutput"]["additionalContext"] = 123
        report = ppv.validate_subagent_start_envelope(env)
        assert any(
            "additionalContext must be a string" in v
            for v in report["violations"]
        )

    def test_empty_additional_context_rejected(self):
        report = ppv.validate_subagent_start_envelope(
            _corrupt_context(_valid_envelope(), context="")
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any(
            "non-empty" in v for v in report["violations"]
        )

    def test_whitespace_only_additional_context_rejected(self):
        report = ppv.validate_subagent_start_envelope(
            _corrupt_context(_valid_envelope(), context="   \n\t  ")
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any(
            "non-whitespace" in v for v in report["violations"]
        )


# -- 9e. Framing-order drift ----------------------------------------------


class TestSubagentStartEnvelopeFramingOrderDrift:
    def test_missing_preamble_tag_rejected(self):
        # Replace line 0 with something that isn't the tag.
        ctx = (
            "WRONG TAG\n"
            "workflow_id: wf-1\n"
            "stage_id: planner\n"
            "content_hash: sha256:abc\n"
            "\n"
            "body line\n"
        )
        report = ppv.validate_subagent_start_envelope(
            _corrupt_context(_valid_envelope(), context=ctx)
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any(
            "line 0 must be the preamble tag" in v
            for v in report["violations"]
        )

    def test_swapped_workflow_and_stage_lines_rejected(self):
        # Put stage_id on line 1 and workflow_id on line 2 —
        # framing order drift.
        ctx = (
            f"{pp.PROMPT_PACK_PREAMBLE_TAG}\n"
            "stage_id: planner\n"
            "workflow_id: wf-1\n"
            "content_hash: sha256:abc\n"
            "\n"
            "body line\n"
        )
        report = ppv.validate_subagent_start_envelope(
            _corrupt_context(_valid_envelope(), context=ctx)
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        violations_blob = " ".join(report["violations"])
        assert "line 1" in violations_blob
        assert "line 2" in violations_blob

    def test_content_hash_line_missing_rejected(self):
        # Drop the content_hash line entirely.
        ctx = (
            f"{pp.PROMPT_PACK_PREAMBLE_TAG}\n"
            "workflow_id: wf-1\n"
            "stage_id: planner\n"
            "\n"
            "body line\n"
        )
        report = ppv.validate_subagent_start_envelope(
            _corrupt_context(_valid_envelope(), context=ctx)
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID

    def test_empty_workflow_id_value_rejected(self):
        ctx = (
            f"{pp.PROMPT_PACK_PREAMBLE_TAG}\n"
            "workflow_id: \n"
            "stage_id: planner\n"
            "content_hash: sha256:abc\n"
            "\n"
            "body line\n"
        )
        report = ppv.validate_subagent_start_envelope(
            _corrupt_context(_valid_envelope(), context=ctx)
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any(
            "workflow_id value is empty" in v for v in report["violations"]
        )
        assert report["workflow_id"] is None

    def test_empty_stage_id_value_rejected(self):
        ctx = (
            f"{pp.PROMPT_PACK_PREAMBLE_TAG}\n"
            "workflow_id: wf-1\n"
            "stage_id: \n"
            "content_hash: sha256:abc\n"
            "\n"
            "body line\n"
        )
        report = ppv.validate_subagent_start_envelope(
            _corrupt_context(_valid_envelope(), context=ctx)
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any(
            "stage_id value is empty" in v for v in report["violations"]
        )
        assert report["stage_id"] is None

    def test_empty_content_hash_value_rejected(self):
        ctx = (
            f"{pp.PROMPT_PACK_PREAMBLE_TAG}\n"
            "workflow_id: wf-1\n"
            "stage_id: planner\n"
            "content_hash: \n"
            "\n"
            "body line\n"
        )
        report = ppv.validate_subagent_start_envelope(
            _corrupt_context(_valid_envelope(), context=ctx)
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any(
            "content_hash value is empty" in v
            for v in report["violations"]
        )
        assert report["content_hash"] is None

    def test_missing_blank_separator_rejected(self):
        ctx = (
            f"{pp.PROMPT_PACK_PREAMBLE_TAG}\n"
            "workflow_id: wf-1\n"
            "stage_id: planner\n"
            "content_hash: sha256:abc\n"
            "body line without blank\n"
            "another\n"
        )
        report = ppv.validate_subagent_start_envelope(
            _corrupt_context(_valid_envelope(), context=ctx)
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any(
            "line 4 must be a blank separator" in v
            for v in report["violations"]
        )

    def test_fewer_than_six_lines_rejected(self):
        ctx = (
            f"{pp.PROMPT_PACK_PREAMBLE_TAG}\n"
            "workflow_id: wf-1\n"
            "stage_id: planner\n"
        )
        report = ppv.validate_subagent_start_envelope(
            _corrupt_context(_valid_envelope(), context=ctx)
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any(
            "at least 6 lines" in v for v in report["violations"]
        )


# -- 9f. Missing body after separator -------------------------------------


class TestSubagentStartEnvelopeMissingBody:
    def test_body_entirely_empty_rejected(self):
        # Body section is just a single empty line → no non-whitespace.
        ctx = (
            f"{pp.PROMPT_PACK_PREAMBLE_TAG}\n"
            "workflow_id: wf-1\n"
            "stage_id: planner\n"
            "content_hash: sha256:abc\n"
            "\n"
            "\n"
        )
        report = ppv.validate_subagent_start_envelope(
            _corrupt_context(_valid_envelope(), context=ctx)
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any(
            "non-whitespace body line" in v
            for v in report["violations"]
        )

    def test_body_only_whitespace_rejected(self):
        ctx = (
            f"{pp.PROMPT_PACK_PREAMBLE_TAG}\n"
            "workflow_id: wf-1\n"
            "stage_id: planner\n"
            "content_hash: sha256:abc\n"
            "\n"
            "   \n"
            "\t\n"
        )
        report = ppv.validate_subagent_start_envelope(
            _corrupt_context(_valid_envelope(), context=ctx)
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any(
            "non-whitespace body line" in v
            for v in report["violations"]
        )


# -- 9g. Round-trip with the canonical builder ----------------------------


class TestSubagentStartEnvelopeRoundTrip:
    def test_round_trip_from_builder_validates_ok(self):
        # Build a real envelope end-to-end via the canonical
        # builder and validate it — this is the most important
        # regression guard: if the builder and validator drift,
        # this test breaks.
        layers = _default_layers()
        rendered = pp.render_prompt_pack(
            workflow_id="wf-e2e",
            stage_id="planner",
            layers=layers,
        )
        projection = pp.build_prompt_pack(
            workflow_id="wf-e2e",
            stage_id="planner",
            layers=layers,
            generated_at=1_700_000_000,
        )
        env = pp.build_subagent_start_envelope(
            workflow_id="wf-e2e",
            stage_id="planner",
            content_hash=projection.content_hash,
            rendered_body=rendered,
        )
        report = ppv.validate_subagent_start_envelope(env)
        assert report["status"] == ppv.VALIDATION_STATUS_OK
        assert report["healthy"] is True
        assert report["violations"] == []
        assert report["workflow_id"] == "wf-e2e"
        assert report["stage_id"] == "planner"
        assert report["content_hash"] == projection.content_hash

    def test_round_trip_survives_multi_stage_ids(self):
        # Stage ids with colons (e.g. "guardian:land") must survive
        # the line parser because the parser uses a fixed prefix,
        # not a strict "one colon only" split.
        env = _valid_envelope(stage_id="guardian:land")
        report = ppv.validate_subagent_start_envelope(env)
        assert report["healthy"] is True
        assert report["stage_id"] == "guardian:land"

    def test_round_trip_survives_sha256_content_hash(self):
        env = _valid_envelope(
            content_hash="sha256:0123456789abcdef0123456789abcdef"
        )
        report = ppv.validate_subagent_start_envelope(env)
        assert report["healthy"] is True
        assert (
            report["content_hash"]
            == "sha256:0123456789abcdef0123456789abcdef"
        )


# -- 9h. Shadow-only discipline for the new helper ------------------------


class TestSubagentStartEnvelopeShadowDiscipline:
    def test_validator_imports_only_prompt_pack(self):
        imported = _imported_module_names(ppv)
        runtime_core_imports = {
            name for name in imported if name.startswith("runtime.core")
        }
        permitted_bases = {"runtime.core"}
        permitted_prefixes = ("runtime.core.prompt_pack",)
        for name in runtime_core_imports:
            assert name in permitted_bases or name.startswith(
                permitted_prefixes
            ), (
                f"prompt_pack_validation.py has unexpected runtime.core "
                f"import: {name!r}"
            )

    def test_validator_has_no_live_routing_imports(self):
        imported = _imported_module_names(ppv)
        forbidden_substrings = (
            "dispatch_engine",
            "completions",
            "policy_engine",
            "enforcement_config",
            "settings",
            "hooks",
            "runtime.core.leases",
            "runtime.core.workflows",
            "runtime.core.approvals",
            "runtime.core.policy_utils",
            "workflow_contract_capture",
        )
        for name in imported:
            for needle in forbidden_substrings:
                assert needle not in name, (
                    f"prompt_pack_validation.py imports {name!r} "
                    f"containing forbidden token {needle!r}"
                )

    def test_validator_does_not_import_subprocess_or_sqlite(self):
        imported = _imported_module_names(ppv)
        assert "subprocess" not in imported
        assert "sqlite3" not in imported

    def test_validation_status_invalid_is_stable_literal(self):
        assert ppv.VALIDATION_STATUS_INVALID == "invalid"

    def test_validate_subagent_start_envelope_is_exported(self):
        assert "validate_subagent_start_envelope" in ppv.__all__
        assert callable(ppv.validate_subagent_start_envelope)


# ---------------------------------------------------------------------------
# 10. SubagentStart prompt-pack request validator
#
# Covers validate_subagent_start_prompt_pack_request(payload).
#
# Required contract fields (DEC-CLAUDEX-PROMPT-PACK-REQUEST-VALIDATION-001):
#   - workflow_id, stage_id, goal_id, work_item_id, decision_scope:
#     non-empty strings at the TOP LEVEL of the payload.
#   - generated_at: non-bool int at the TOP LEVEL.
# Extra fields are allowed. Cumulative violations.
# ---------------------------------------------------------------------------

_VALID_REQUEST_PAYLOAD = {
    "workflow_id": "wf-req-001",
    "stage_id": "planner",
    "goal_id": "goal-abc",
    "work_item_id": "wi-xyz",
    "decision_scope": "runtime/core",
    "generated_at": 1_700_000_000,
}

EXPECTED_REQUEST_REPORT_KEYS = {
    "status",
    "healthy",
    "violations",
    "workflow_id",
    "stage_id",
    "goal_id",
    "work_item_id",
    "decision_scope",
    "generated_at",
}


# -- 10a. Happy path -------------------------------------------------------


class TestSubagentStartRequestHappyPath:
    def test_valid_payload_reports_ok(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            _VALID_REQUEST_PAYLOAD
        )
        assert report["status"] == ppv.VALIDATION_STATUS_OK
        assert report["healthy"] is True
        assert report["violations"] == []

    def test_report_shape_is_stable(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            _VALID_REQUEST_PAYLOAD
        )
        assert set(report.keys()) == EXPECTED_REQUEST_REPORT_KEYS

    def test_fields_are_extracted_when_valid(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            _VALID_REQUEST_PAYLOAD
        )
        assert report["workflow_id"] == "wf-req-001"
        assert report["stage_id"] == "planner"
        assert report["goal_id"] == "goal-abc"
        assert report["work_item_id"] == "wi-xyz"
        assert report["decision_scope"] == "runtime/core"
        assert report["generated_at"] == 1_700_000_000

    def test_extra_top_level_fields_are_allowed(self):
        payload = dict(_VALID_REQUEST_PAYLOAD)
        payload["session_id"] = "sess-99"
        payload["model"] = "claude-sonnet-4-6"
        payload["hook_event_name"] = "SubagentStart"
        report = ppv.validate_subagent_start_prompt_pack_request(payload)
        assert report["status"] == ppv.VALIDATION_STATUS_OK
        assert report["healthy"] is True

    def test_report_is_json_serialisable(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            _VALID_REQUEST_PAYLOAD
        )
        encoded = json.dumps(report)
        decoded = json.loads(encoded)
        assert decoded == report

    def test_report_is_deterministic(self):
        a = ppv.validate_subagent_start_prompt_pack_request(
            _VALID_REQUEST_PAYLOAD
        )
        b = ppv.validate_subagent_start_prompt_pack_request(
            _VALID_REQUEST_PAYLOAD
        )
        assert a == b


# -- 10b. Non-mapping input -----------------------------------------------


class TestSubagentStartRequestNonMapping:
    def test_none_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(None)
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert report["healthy"] is False
        assert any("mapping" in v for v in report["violations"])

    def test_string_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request("not a dict")
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any("mapping" in v for v in report["violations"])

    def test_list_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request([1, 2, 3])
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any("mapping" in v for v in report["violations"])

    def test_integer_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(42)
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID

    def test_non_mapping_report_has_stable_keys(self):
        report = ppv.validate_subagent_start_prompt_pack_request(None)
        assert set(report.keys()) == EXPECTED_REQUEST_REPORT_KEYS

    def test_non_mapping_extraction_fields_are_none(self):
        report = ppv.validate_subagent_start_prompt_pack_request(None)
        for field in ("workflow_id", "stage_id", "goal_id",
                      "work_item_id", "decision_scope", "generated_at"):
            assert report[field] is None


# -- 10c. Missing required string fields ----------------------------------


class TestSubagentStartRequestMissingStringFields:
    def _drop(self, field: str) -> dict:
        payload = dict(_VALID_REQUEST_PAYLOAD)
        del payload[field]
        return payload

    def test_missing_workflow_id_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._drop("workflow_id")
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any("workflow_id" in v for v in report["violations"])
        assert report["workflow_id"] is None

    def test_missing_stage_id_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._drop("stage_id")
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any("stage_id" in v for v in report["violations"])
        assert report["stage_id"] is None

    def test_missing_goal_id_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._drop("goal_id")
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any("goal_id" in v for v in report["violations"])
        assert report["goal_id"] is None

    def test_missing_work_item_id_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._drop("work_item_id")
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any("work_item_id" in v for v in report["violations"])
        assert report["work_item_id"] is None

    def test_missing_decision_scope_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._drop("decision_scope")
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any("decision_scope" in v for v in report["violations"])
        assert report["decision_scope"] is None

    def test_missing_generated_at_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._drop("generated_at")
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any("generated_at" in v for v in report["violations"])
        assert report["generated_at"] is None

    def test_all_fields_missing_produces_six_violations(self):
        report = ppv.validate_subagent_start_prompt_pack_request({})
        assert len(report["violations"]) == 6
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID


# -- 10d. Wrong types for string fields -----------------------------------


class TestSubagentStartRequestWrongStringFieldTypes:
    def _replace(self, field: str, value) -> dict:
        payload = dict(_VALID_REQUEST_PAYLOAD)
        payload[field] = value
        return payload

    def test_workflow_id_integer_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._replace("workflow_id", 123)
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any("workflow_id" in v for v in report["violations"])
        assert report["workflow_id"] is None

    def test_stage_id_none_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._replace("stage_id", None)
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert report["stage_id"] is None

    def test_goal_id_list_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._replace("goal_id", ["not", "a", "string"])
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert report["goal_id"] is None

    def test_work_item_id_dict_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._replace("work_item_id", {"nested": "dict"})
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert report["work_item_id"] is None

    def test_decision_scope_float_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._replace("decision_scope", 3.14)
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert report["decision_scope"] is None


# -- 10e. Empty/whitespace-only string fields -----------------------------


class TestSubagentStartRequestEmptyStringFields:
    def _replace(self, field: str, value: str) -> dict:
        payload = dict(_VALID_REQUEST_PAYLOAD)
        payload[field] = value
        return payload

    def test_empty_workflow_id_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._replace("workflow_id", "")
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert report["workflow_id"] is None

    def test_whitespace_workflow_id_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._replace("workflow_id", "   ")
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert report["workflow_id"] is None

    def test_empty_stage_id_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._replace("stage_id", "")
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert report["stage_id"] is None

    def test_empty_goal_id_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._replace("goal_id", "")
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert report["goal_id"] is None

    def test_empty_work_item_id_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._replace("work_item_id", "")
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert report["work_item_id"] is None

    def test_empty_decision_scope_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._replace("decision_scope", "")
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert report["decision_scope"] is None

    def test_tab_only_decision_scope_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._replace("decision_scope", "\t\t")
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert report["decision_scope"] is None


# -- 10f. generated_at type rules -----------------------------------------


class TestSubagentStartRequestGeneratedAt:
    def _replace(self, value) -> dict:
        payload = dict(_VALID_REQUEST_PAYLOAD)
        payload["generated_at"] = value
        return payload

    def test_valid_int_accepted(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._replace(1_700_000_000)
        )
        assert report["status"] == ppv.VALIDATION_STATUS_OK
        assert report["generated_at"] == 1_700_000_000

    def test_zero_int_accepted(self):
        # Zero is a valid epoch value.
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._replace(0)
        )
        assert report["status"] == ppv.VALIDATION_STATUS_OK
        assert report["generated_at"] == 0

    def test_negative_int_accepted(self):
        # Negative epochs are structurally valid.
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._replace(-1)
        )
        assert report["status"] == ppv.VALIDATION_STATUS_OK
        assert report["generated_at"] == -1

    def test_float_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._replace(1_700_000_000.5)
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any("generated_at" in v for v in report["violations"])
        assert report["generated_at"] is None

    def test_string_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._replace("1700000000")
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any("generated_at" in v for v in report["violations"])
        assert report["generated_at"] is None

    def test_none_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._replace(None)
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert report["generated_at"] is None

    def test_bool_true_rejected(self):
        # bool is a subclass of int in Python, but True is not a
        # valid unix epoch timestamp — the validator must exclude it.
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._replace(True)
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert any("generated_at" in v for v in report["violations"])
        assert report["generated_at"] is None

    def test_bool_false_rejected(self):
        report = ppv.validate_subagent_start_prompt_pack_request(
            self._replace(False)
        )
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert report["generated_at"] is None


# -- 10g. Cumulative violations -------------------------------------------


class TestSubagentStartRequestCumulativeViolations:
    def test_two_bad_fields_produce_two_violations(self):
        payload = dict(_VALID_REQUEST_PAYLOAD)
        payload["workflow_id"] = ""
        payload["stage_id"] = 42
        report = ppv.validate_subagent_start_prompt_pack_request(payload)
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        assert len(report["violations"]) >= 2

    def test_three_missing_fields_produce_three_violations(self):
        payload = dict(_VALID_REQUEST_PAYLOAD)
        del payload["goal_id"]
        del payload["work_item_id"]
        del payload["decision_scope"]
        report = ppv.validate_subagent_start_prompt_pack_request(payload)
        assert len(report["violations"]) == 3
        blob = " ".join(report["violations"])
        assert "goal_id" in blob
        assert "work_item_id" in blob
        assert "decision_scope" in blob

    def test_valid_fields_are_extracted_even_when_other_fields_bad(self):
        # workflow_id is valid; stage_id is missing.
        payload = dict(_VALID_REQUEST_PAYLOAD)
        del payload["stage_id"]
        report = ppv.validate_subagent_start_prompt_pack_request(payload)
        assert report["status"] == ppv.VALIDATION_STATUS_INVALID
        # The valid workflow_id is still extracted.
        assert report["workflow_id"] == "wf-req-001"
        # The missing stage_id is None.
        assert report["stage_id"] is None


# -- 10h. Export and shadow discipline ------------------------------------


class TestSubagentStartRequestExportAndDiscipline:
    def test_function_is_exported(self):
        assert "validate_subagent_start_prompt_pack_request" in ppv.__all__
        assert callable(ppv.validate_subagent_start_prompt_pack_request)

    def test_validator_still_imports_only_prompt_pack_and_stdlib(self):
        # Re-run the shadow-discipline import check with the new function
        # in scope to ensure the new code did not sneak in a new import.
        imported = _imported_module_names(ppv)
        runtime_core_imports = {
            name for name in imported if name.startswith("runtime.core")
        }
        permitted_bases = {"runtime.core"}
        permitted_prefixes = ("runtime.core.prompt_pack",)
        for name in runtime_core_imports:
            assert name in permitted_bases or name.startswith(
                permitted_prefixes
            ), (
                f"prompt_pack_validation.py has unexpected runtime.core "
                f"import after adding request validator: {name!r}"
            )

    def test_report_is_json_serialisable_on_all_none_extraction(self):
        # Non-mapping input → all extraction fields None → JSON round-trip.
        report = ppv.validate_subagent_start_prompt_pack_request(None)
        encoded = json.dumps(report)
        decoded = json.loads(encoded)
        assert decoded == report


# ---------------------------------------------------------------------------
# Metadata validator (Phase 7 Slice 12)
#
# @decision DEC-CLAUDEX-PROMPT-PACK-METADATA-VALIDATION-TESTS-001
# Title: validate_prompt_pack_metadata pins drift detection on the compiled-metadata envelope
# Status: proposed (Phase 7 Slice 12)
# Rationale: The body-drift validator (``validate_prompt_pack``) cannot
#   detect drift in the compiled ``metadata`` envelope. Slice 12 adds
#   :func:`validate_prompt_pack_metadata` as a pure, symmetric drift
#   checker whose expected output is rebuilt by the same compiler
#   that produced the artifact. These tests pin:
#
#     * healthy case — metadata derived from ``build_prompt_pack`` is
#       reported ``status=ok, healthy=True, exact_match=True,
#       first_mismatch=None``
#     * tampered ``watched_files`` surfaces the exact dotted-path
#       mismatch (``stale_condition.watched_files`` or ``...[i]``)
#     * tampered ``generator_version`` surfaces as a root-level or
#       ``generator_version`` mismatch
#     * malformed candidate shapes (missing key, extra key, wrong
#       container type) all classify as drift — never exceptions
#     * the returned dict is JSON-serialisable and echoes
#       ``workflow_id`` / ``stage_id``
# ---------------------------------------------------------------------------


def _build_expected_metadata(
    *,
    workflow_id: str = "wf-md",
    stage_id: str = "planner",
    generated_at: int = 1_700_000_000,
    watched_files: tuple[str, ...] = ("runtime/core/prompt_pack_resolver.py",),
) -> tuple[dict, dict]:
    """Return ``(layers, expected_metadata_dict)`` for the given inputs."""
    layers = _default_layers()
    projection = pp.build_prompt_pack(
        workflow_id=workflow_id,
        stage_id=stage_id,
        layers=layers,
        generated_at=generated_at,
        watched_files=watched_files,
    )
    return layers, ppv._serialise_metadata_to_compile_shape(projection.metadata)


def _validate_metadata(
    candidate: dict,
    *,
    layers: dict,
    workflow_id: str = "wf-md",
    stage_id: str = "planner",
    generated_at: int = 1_700_000_000,
    watched_files: tuple[str, ...] = ("runtime/core/prompt_pack_resolver.py",),
) -> dict:
    return ppv.validate_prompt_pack_metadata(
        candidate,
        workflow_id=workflow_id,
        stage_id=stage_id,
        layers=layers,
        generated_at=generated_at,
        watched_files=watched_files,
    )


class TestMetadataValidatorHealthy:
    def test_matching_metadata_is_healthy(self):
        layers, expected = _build_expected_metadata()
        report = _validate_metadata(expected, layers=layers)
        assert report["status"] == ppv.VALIDATION_STATUS_OK
        assert report["healthy"] is True
        assert report["exact_match"] is True
        assert report["first_mismatch"] is None

    def test_report_echoes_identity_fields(self):
        # workflow_id / stage_id are not embedded in the metadata
        # envelope itself (cf. ``_serialise_metadata_to_compile_shape``)
        # — they are echoed back in the report for traceability.
        layers, expected = _build_expected_metadata(
            workflow_id="wf-echo",
            stage_id="implementer",
        )
        report = _validate_metadata(
            expected,
            layers=layers,
            workflow_id="wf-echo",
            stage_id="implementer",
        )
        assert report["workflow_id"] == "wf-echo"
        assert report["stage_id"] == "implementer"
        assert report["healthy"] is True

    def test_report_is_json_serialisable(self):
        layers, expected = _build_expected_metadata()
        report = _validate_metadata(expected, layers=layers)
        encoded = json.dumps(report)
        decoded = json.loads(encoded)
        assert decoded == report

    def test_expected_metadata_contains_watched_files(self):
        layers, expected = _build_expected_metadata(
            watched_files=("a.md", "b.md", "c.md"),
        )
        report = _validate_metadata(
            expected,
            layers=layers,
            watched_files=("a.md", "b.md", "c.md"),
        )
        assert report["healthy"] is True
        assert report["expected_metadata"]["stale_condition"]["watched_files"] == [
            "a.md",
            "b.md",
            "c.md",
        ]


class TestMetadataValidatorTampered:
    def test_tampered_watched_files_list_surfaces_drift(self):
        layers, expected = _build_expected_metadata()
        tampered = {
            **expected,
            "stale_condition": {
                **expected["stale_condition"],
                "watched_files": ["WRONG.md"],
            },
        }
        report = _validate_metadata(tampered, layers=layers)
        assert report["status"] == ppv.VALIDATION_STATUS_DRIFT
        assert report["healthy"] is False
        assert report["first_mismatch"] is not None
        # Either the list itself differs (length path) or a specific
        # index — in both shapes the dotted path must mention
        # ``watched_files``.
        assert "watched_files" in report["first_mismatch"]["path"]

    def test_single_entry_mutation_surfaces_indexed_path(self):
        layers, expected = _build_expected_metadata(
            watched_files=("a.md", "b.md", "c.md"),
        )
        # Mutate one entry in-place; list length unchanged → the
        # walker should descend into ``watched_files[1]``.
        tampered = {
            **expected,
            "stale_condition": {
                **expected["stale_condition"],
                "watched_files": ["a.md", "MUTATED.md", "c.md"],
            },
        }
        report = _validate_metadata(
            tampered,
            layers=layers,
            watched_files=("a.md", "b.md", "c.md"),
        )
        assert report["healthy"] is False
        assert (
            report["first_mismatch"]["path"]
            == "stale_condition.watched_files[1]"
        )
        assert report["first_mismatch"]["expected"] == "b.md"
        assert report["first_mismatch"]["candidate"] == "MUTATED.md"

    def test_tampered_generator_version_surfaces_drift(self):
        layers, expected = _build_expected_metadata()
        tampered = {**expected, "generator_version": "0.0.0-tampered"}
        report = _validate_metadata(tampered, layers=layers)
        assert report["healthy"] is False
        assert report["first_mismatch"] is not None
        assert report["first_mismatch"]["path"] == "generator_version"
        assert report["first_mismatch"]["candidate"] == "0.0.0-tampered"

    def test_tampered_generated_at_surfaces_drift(self):
        layers, expected = _build_expected_metadata()
        tampered = {**expected, "generated_at": expected["generated_at"] + 1}
        report = _validate_metadata(tampered, layers=layers)
        assert report["healthy"] is False
        assert report["first_mismatch"]["path"] == "generated_at"

    def test_wrong_watched_files_argument_vs_candidate_is_drift(self):
        # Expected rebuilt with watched_files=("x.md",) but candidate
        # carries ("y.md",). Detects cross-drift between caller-
        # supplied watched_files and the embedded candidate metadata.
        layers, _ = _build_expected_metadata(watched_files=("x.md",))
        # Build a candidate whose metadata was shaped for ("y.md",).
        _, candidate = _build_expected_metadata(watched_files=("y.md",))
        report = _validate_metadata(
            candidate,
            layers=layers,
            watched_files=("x.md",),
        )
        assert report["healthy"] is False
        assert "watched_files" in report["first_mismatch"]["path"]


class TestMetadataValidatorMalformedShape:
    def test_empty_mapping_is_drift_not_exception(self):
        layers, _expected = _build_expected_metadata()
        report = _validate_metadata({}, layers=layers)
        assert report["healthy"] is False
        assert report["status"] == ppv.VALIDATION_STATUS_DRIFT
        assert report["first_mismatch"] is not None
        # First missing key reported with None candidate.
        assert report["first_mismatch"]["candidate"] is None

    def test_missing_stale_condition_key_is_drift(self):
        layers, expected = _build_expected_metadata()
        tampered = {k: v for k, v in expected.items() if k != "stale_condition"}
        report = _validate_metadata(tampered, layers=layers)
        assert report["healthy"] is False
        assert report["first_mismatch"]["path"] == "stale_condition"
        assert report["first_mismatch"]["candidate"] is None

    def test_extra_top_level_key_is_drift(self):
        layers, expected = _build_expected_metadata()
        tampered = {**expected, "unexpected_key": "surprise"}
        report = _validate_metadata(tampered, layers=layers)
        assert report["healthy"] is False
        assert report["first_mismatch"]["path"] == "unexpected_key"
        assert report["first_mismatch"]["expected"] is None

    def test_wrong_type_for_watched_files_container_is_drift(self):
        layers, expected = _build_expected_metadata()
        tampered = {
            **expected,
            "stale_condition": {
                **expected["stale_condition"],
                "watched_files": "not-a-list",
            },
        }
        report = _validate_metadata(tampered, layers=layers)
        assert report["healthy"] is False
        assert report["first_mismatch"] is not None
        assert "watched_files" in report["first_mismatch"]["path"]

    def test_wrong_type_for_provenance_container_is_drift(self):
        layers, expected = _build_expected_metadata()
        tampered = {**expected, "provenance": {"not": "a list"}}
        report = _validate_metadata(tampered, layers=layers)
        assert report["healthy"] is False
        assert report["first_mismatch"] is not None
        assert report["first_mismatch"]["path"].startswith("provenance")

    def test_none_candidate_metadata_is_drift_not_exception(self):
        layers, _expected = _build_expected_metadata()
        # ``None`` cast to dict() via the function's preamble → {}
        # → drift, not TypeError.
        report = _validate_metadata(None, layers=layers)
        assert report["healthy"] is False
        assert report["status"] == ppv.VALIDATION_STATUS_DRIFT

    def test_malformed_layers_raises_valueerror_not_drift(self):
        # Malformed compiler inputs are caller bugs, not drift —
        # they must raise from build_prompt_pack.
        with pytest.raises(ValueError):
            ppv.validate_prompt_pack_metadata(
                {},
                workflow_id="wf",
                stage_id="planner",
                layers={"not_a_canonical_layer": "x"},
                generated_at=1,
                watched_files=("a.md",),
            )


class TestMetadataValidatorExportAndDiscipline:
    def test_function_is_exported(self):
        assert "validate_prompt_pack_metadata" in getattr(ppv, "__all__", [])
        assert callable(ppv.validate_prompt_pack_metadata)

    def test_serialiser_is_public_and_exported(self):
        # Phase 7 Slice 12 correction: the JSON shape helper must be a
        # public single-authority surface so ``runtime/cli.py`` does
        # not depend on a private underscore name.
        assert "serialise_prompt_pack_metadata" in getattr(ppv, "__all__", [])
        assert callable(ppv.serialise_prompt_pack_metadata)

    def test_serialiser_matches_private_alias(self):
        # The private alias is retained for intra-module readability
        # but must forward to the public helper — no two
        # implementations.
        assert (
            ppv.serialise_prompt_pack_metadata
            is ppv._serialise_metadata_to_compile_shape
        )

    def test_determinism(self):
        # Two calls with identical inputs return byte-identical
        # reports (once JSON-encoded) — no hidden time / rng.
        layers, expected = _build_expected_metadata()
        r1 = _validate_metadata(expected, layers=layers)
        r2 = _validate_metadata(expected, layers=layers)
        assert json.dumps(r1, sort_keys=True) == json.dumps(r2, sort_keys=True)
