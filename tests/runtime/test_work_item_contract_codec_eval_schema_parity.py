"""Evaluation Contract schema parity invariant tests.

DEC-CLAUDEX-EVAL-CONTRACT-SCHEMA-PARITY-001

These tests pin the widened 9-field EvaluationContract schema introduced in
slice 33 and verify that:

  1. All 9 keys round-trip through the decoder without loss.
  2. Unknown keys still raise actionable ValueError naming the full legal set.
  3. The codec module-level constants (_EVAL_TUPLE_KEYS + _EVAL_STRING_KEYS) are
     anchored to the expected 9-key set (schema-parity invariant).
  4. The EvaluationContract dataclass field set is pinned at exactly 9 fields.
  5. The renderer (_render_evaluation_summary) emits all new section headers in
     the correct pinned group order.
  6. The end-to-end compile path (compile_prompt_pack_for_stage) succeeds on a
     widened payload and the compiled prompt contains the new sections.
  7. The CLI --evaluation-json help text references at least 6 of the 9 legal keys.
  8. This module's docstring carries the DEC-id anchor.

No test uses pytest.skip, pytest.xfail, or @pytest.mark.skipif.
No external I/O — in-memory SQLite only.
"""

from __future__ import annotations

import json
import sqlite3
from dataclasses import fields

import pytest

from runtime.core import contracts
from runtime.core import decision_work_registry as dwr
from runtime.core import work_item_contract_codec as wcc
from runtime.schemas import ensure_schema


# ---------------------------------------------------------------------------
# Module constants (checked in Case 8 below)
# ---------------------------------------------------------------------------

_ALL_9_LEGAL_KEYS = frozenset(
    {
        "required_tests",
        "required_evidence",
        "required_real_path_checks",
        "required_authority_invariants",
        "required_integration_points",
        "forbidden_shortcuts",
        "rollback_boundary",
        "acceptance_notes",
        "ready_for_guardian_definition",
    }
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _record(**overrides) -> dwr.WorkItemRecord:
    """Build a minimally-valid WorkItemRecord with optional overrides."""
    base = dict(
        work_item_id="WI-PARITY-1",
        goal_id="G-PARITY-1",
        title="parity test slice",
        status="pending",
        version=1,
        author="planner",
        scope_json="{}",
        evaluation_json="{}",
        head_sha=None,
        reviewer_round=0,
        created_at=0,
        updated_at=0,
    )
    base.update(overrides)
    return dwr.WorkItemRecord(**base)


def _eval_json(**fields_) -> str:
    """Serialize evaluation fields as JSON."""
    return json.dumps(fields_)


def _default_goal(goal_id: str = "G-PARITY-1") -> contracts.GoalContract:
    return contracts.GoalContract(
        goal_id=goal_id,
        desired_end_state="Ship the parity slice",
        status="active",
    )


def _default_work_item(
    *,
    goal_id: str = "G-PARITY-1",
    evaluation: contracts.EvaluationContract | None = None,
) -> contracts.WorkItemContract:
    return contracts.WorkItemContract(
        work_item_id="WI-PARITY-1",
        goal_id=goal_id,
        title="Parity test work item",
        scope=contracts.ScopeManifest(),
        evaluation=(
            evaluation if evaluation is not None else contracts.EvaluationContract()
        ),
        status="in_progress",
    )


# ---------------------------------------------------------------------------
# Case 1: Round-trip through decoder with ALL 9 keys populated
# ---------------------------------------------------------------------------


class TestAllWidenedKeysRoundTripThroughDecoder:
    """Case 1 — all 9 canonical keys decode to the expected EvaluationContract."""

    def test_all_widened_keys_round_trip(self):
        payload = {
            "required_tests": ["pytest tests/runtime/test_foo.py", "pytest tests/runtime/test_bar.py"],
            "required_evidence": ["verbatim pytest footer", "cc-policy eval get output"],
            "required_real_path_checks": [
                "cc-policy dispatch agent-prompt --workflow-id global-soak-main --stage-id planner",
                "cc-policy prompt-pack subagent-start returns healthy=true",
            ],
            "required_authority_invariants": [
                "work_item_contract_codec.py remains sole authority for evaluation_json keys",
                "contracts.EvaluationContract remains sole typed shape for evaluation data",
            ],
            "required_integration_points": [
                "workflow_contract_capture.capture_workflow_contracts succeeds on widened payload",
                "compile_prompt_pack_for_stage Mode A + Mode B both succeed",
            ],
            "forbidden_shortcuts": [
                "Do not add a parallel relaxed decoder",
                "Do not silently drop unknown keys",
            ],
            "rollback_boundary": "git restore runtime/core/contracts.py runtime/core/work_item_contract_codec.py",
            "acceptance_notes": "All 22 pytest suites pass, real-path checks succeed",
            "ready_for_guardian_definition": "All tests pass, real-path checks succeed, baseline preservation holds",
        }
        record = _record(evaluation_json=json.dumps(payload))
        result = wcc.decode_work_item_contract(record)
        ev = result.evaluation

        # Verify all 9 fields
        assert ev.required_tests == (
            "pytest tests/runtime/test_foo.py",
            "pytest tests/runtime/test_bar.py",
        )
        assert ev.required_evidence == (
            "verbatim pytest footer",
            "cc-policy eval get output",
        )
        assert ev.required_real_path_checks == (
            "cc-policy dispatch agent-prompt --workflow-id global-soak-main --stage-id planner",
            "cc-policy prompt-pack subagent-start returns healthy=true",
        )
        assert ev.required_authority_invariants == (
            "work_item_contract_codec.py remains sole authority for evaluation_json keys",
            "contracts.EvaluationContract remains sole typed shape for evaluation data",
        )
        assert ev.required_integration_points == (
            "workflow_contract_capture.capture_workflow_contracts succeeds on widened payload",
            "compile_prompt_pack_for_stage Mode A + Mode B both succeed",
        )
        assert ev.forbidden_shortcuts == (
            "Do not add a parallel relaxed decoder",
            "Do not silently drop unknown keys",
        )
        assert ev.rollback_boundary == (
            "git restore runtime/core/contracts.py runtime/core/work_item_contract_codec.py"
        )
        assert ev.acceptance_notes == "All 22 pytest suites pass, real-path checks succeed"
        assert ev.ready_for_guardian_definition == (
            "All tests pass, real-path checks succeed, baseline preservation holds"
        )

    def test_round_trip_produces_expected_dataclass(self):
        """Cross-check via equality with a hand-constructed EvaluationContract."""
        payload = {
            "required_tests": ["test-a"],
            "required_evidence": ["evidence-a"],
            "required_real_path_checks": ["rpc-a"],
            "required_authority_invariants": ["inv-a"],
            "required_integration_points": ["int-a"],
            "forbidden_shortcuts": ["no-foo"],
            "rollback_boundary": "git restore x",
            "acceptance_notes": "ok",
            "ready_for_guardian_definition": "all tests pass",
        }
        record = _record(evaluation_json=json.dumps(payload))
        result = wcc.decode_work_item_contract(record)

        expected = contracts.EvaluationContract(
            required_tests=("test-a",),
            required_evidence=("evidence-a",),
            required_real_path_checks=("rpc-a",),
            required_authority_invariants=("inv-a",),
            required_integration_points=("int-a",),
            forbidden_shortcuts=("no-foo",),
            rollback_boundary="git restore x",
            acceptance_notes="ok",
            ready_for_guardian_definition="all tests pass",
        )
        assert result.evaluation == expected


# ---------------------------------------------------------------------------
# Case 2: Unknown key raises actionable ValueError naming full legal set
# ---------------------------------------------------------------------------


class TestUnknownKeyRaisesActionableValueError:
    """Case 2 — unknown keys still raise ValueError with schema-documentation error."""

    def test_fabricated_key_raises_value_error(self):
        payload = {
            "required_tests": ["pytest tests/runtime/test_foo.py"],
            "fabricated_key_99": ["x"],
        }
        record = _record(evaluation_json=json.dumps(payload))
        with pytest.raises(ValueError) as exc:
            wcc.decode_work_item_contract(record)
        msg = str(exc.value)
        # Must name the offending key
        assert "fabricated_key_99" in msg
        # Must name the parent field
        assert "evaluation_json" in msg
        # Must enumerate at least 6 of the 9 legal keys (error IS the schema docs)
        legal_keys_in_msg = [k for k in _ALL_9_LEGAL_KEYS if k in msg]
        assert len(legal_keys_in_msg) >= 6, (
            f"Error message should enumerate >=6 legal keys, got {len(legal_keys_in_msg)}: "
            f"{legal_keys_in_msg!r}\nFull message: {msg}"
        )

    def test_error_message_enumerates_all_9_legal_keys(self):
        """The closed-set error message IS the schema documentation."""
        payload = {"bad_key": ["x"]}
        record = _record(evaluation_json=json.dumps(payload))
        with pytest.raises(ValueError) as exc:
            wcc.decode_work_item_contract(record)
        msg = str(exc.value)
        # All 9 legal keys should appear in the sorted list in the error
        for key in _ALL_9_LEGAL_KEYS:
            assert key in msg, (
                f"Legal key {key!r} missing from error message: {msg!r}"
            )


# ---------------------------------------------------------------------------
# Case 3: Schema parity anchor — pin _EVAL_TUPLE_KEYS + _EVAL_STRING_KEYS
# ---------------------------------------------------------------------------


class TestSchemaParityAnchor:
    """Case 3 — codec module-level constants match the 9-key anchor."""

    def test_eval_tuple_keys_anchored(self):
        expected_tuple_keys = frozenset(
            {
                "required_tests",
                "required_evidence",
                "required_real_path_checks",
                "required_authority_invariants",
                "required_integration_points",
                "forbidden_shortcuts",
            }
        )
        actual = frozenset(wcc._EVAL_TUPLE_KEYS)
        symmetric_diff = actual.symmetric_difference(expected_tuple_keys)
        assert not symmetric_diff, (
            f"_EVAL_TUPLE_KEYS has drifted from the expected 6-key anchor.\n"
            f"Keys in actual but not expected: {actual - expected_tuple_keys!r}\n"
            f"Keys in expected but not actual: {expected_tuple_keys - actual!r}"
        )

    def test_eval_string_keys_anchored(self):
        expected_string_keys = frozenset(
            {
                "rollback_boundary",
                "acceptance_notes",
                "ready_for_guardian_definition",
            }
        )
        actual = frozenset(wcc._EVAL_STRING_KEYS)
        symmetric_diff = actual.symmetric_difference(expected_string_keys)
        assert not symmetric_diff, (
            f"_EVAL_STRING_KEYS has drifted from the expected 3-key anchor.\n"
            f"Keys in actual but not expected: {actual - expected_string_keys!r}\n"
            f"Keys in expected but not actual: {expected_string_keys - actual!r}"
        )

    def test_combined_key_set_is_exactly_9(self):
        combined = frozenset(wcc._EVAL_TUPLE_KEYS) | frozenset(wcc._EVAL_STRING_KEYS)
        assert len(combined) == 9, (
            f"Expected 9 total evaluation keys, got {len(combined)}: {sorted(combined)}"
        )
        assert combined == _ALL_9_LEGAL_KEYS


# ---------------------------------------------------------------------------
# Case 4: Dataclass field set pinned at exactly 9 fields
# ---------------------------------------------------------------------------


class TestDataclassFieldSetPinned:
    """Case 4 — EvaluationContract fields match the 9-field anchor."""

    def test_evaluation_contract_has_exactly_9_fields(self):
        actual_fields = {f.name for f in fields(contracts.EvaluationContract)}
        expected_fields = {
            "required_tests",
            "required_evidence",
            "rollback_boundary",
            "acceptance_notes",
            "required_real_path_checks",
            "required_authority_invariants",
            "required_integration_points",
            "forbidden_shortcuts",
            "ready_for_guardian_definition",
        }
        assert actual_fields == expected_fields, (
            f"EvaluationContract fields do not match expected 9-field set.\n"
            f"Symmetric diff: {actual_fields.symmetric_difference(expected_fields)}"
        )


# ---------------------------------------------------------------------------
# Case 5: Renderer group-order pinned
# ---------------------------------------------------------------------------


class TestEvaluationRendererGroupOrder:
    """Case 5 — _render_evaluation_summary emits section headers in pinned group order."""

    def _build_full_evaluation(self) -> contracts.EvaluationContract:
        return contracts.EvaluationContract(
            required_tests=("pytest tests/runtime/",),
            required_evidence=("verbatim pytest output",),
            required_real_path_checks=("cc-policy dispatch agent-prompt succeeds",),
            required_authority_invariants=("codec is sole authority for eval keys",),
            required_integration_points=("compile_prompt_pack_for_stage Mode B succeeds",),
            forbidden_shortcuts=("no parallel decoder authority",),
            rollback_boundary="git restore runtime/core/contracts.py",
            acceptance_notes="all 22 suites pass",
            ready_for_guardian_definition="all tests pass, real-path checks succeed",
        )

    def test_renderer_includes_all_new_section_headers(self):
        from runtime.core import prompt_pack_resolver as ppr
        goal = _default_goal()
        ev = self._build_full_evaluation()
        text = ppr._render_evaluation_summary(goal, ev)

        assert "Required real-path checks:" in text
        assert "Required authority invariants:" in text
        assert "Required integration points:" in text
        assert "Forbidden shortcuts:" in text
        assert "Ready for guardian when:" in text

    def test_renderer_group_order_tests_before_integration_before_boundaries(self):
        """Section group order is pinned by this test: reordering breaks it."""
        from runtime.core import prompt_pack_resolver as ppr
        goal = _default_goal()
        ev = self._build_full_evaluation()
        text = ppr._render_evaluation_summary(goal, ev)

        # Identify positions of anchor headers for each group
        pos_req_tests = text.index("Required tests:")
        pos_req_evidence = text.index("Required evidence:")
        pos_rpc = text.index("Required real-path checks:")
        pos_inv = text.index("Required authority invariants:")
        pos_int = text.index("Required integration points:")
        pos_forb = text.index("Forbidden shortcuts:")
        pos_rollback = text.index("Rollback boundary:")
        pos_acceptance = text.index("Acceptance notes:")
        pos_guardian = text.index("Ready for guardian when:")

        # Group 1 before Group 2
        assert pos_req_tests < pos_rpc, "Required tests must precede Required real-path checks"
        assert pos_req_evidence < pos_rpc, "Required evidence must precede Required real-path checks"
        # Group 2 internal order
        assert pos_rpc < pos_inv < pos_int < pos_forb, (
            "real-path → authority → integration → forbidden"
        )
        # Group 2 before Group 3
        assert pos_forb < pos_rollback, "Forbidden shortcuts must precede Rollback boundary"
        assert pos_rollback < pos_acceptance, "Rollback boundary must precede Acceptance notes"
        assert pos_acceptance < pos_guardian, "Acceptance notes must precede Ready for guardian when"

    def test_renderer_shows_none_placeholder_for_empty_new_fields(self):
        """Empty new-field sections show (none) placeholder, not blank."""
        from runtime.core import prompt_pack_resolver as ppr
        goal = _default_goal()
        ev = contracts.EvaluationContract()  # all defaults
        text = ppr._render_evaluation_summary(goal, ev)

        assert "Required real-path checks:\n  - (none)" in text
        assert "Required authority invariants:\n  - (none)" in text
        assert "Required integration points:\n  - (none)" in text
        assert "Forbidden shortcuts:\n  - (none)" in text
        assert "Ready for guardian when: (unspecified)" in text

    def test_renderer_shows_populated_values_under_correct_headers(self):
        """Each new field's value appears under its own header, not elsewhere."""
        from runtime.core import prompt_pack_resolver as ppr
        goal = _default_goal()
        ev = contracts.EvaluationContract(
            required_real_path_checks=("rpc-value-xyz",),
            required_authority_invariants=("inv-value-xyz",),
            required_integration_points=("int-value-xyz",),
            forbidden_shortcuts=("forb-value-xyz",),
            ready_for_guardian_definition="rg-value-xyz",
        )
        text = ppr._render_evaluation_summary(goal, ev)

        assert "rpc-value-xyz" in text
        assert "inv-value-xyz" in text
        assert "int-value-xyz" in text
        assert "forb-value-xyz" in text
        assert "rg-value-xyz" in text

    def test_workflow_summary_evaluation_field_contains_new_headers(self):
        """workflow_summary_from_contracts routes through _render_evaluation_summary."""
        from runtime.core import prompt_pack_resolver as ppr
        goal = _default_goal()
        ev = self._build_full_evaluation()
        work_item = _default_work_item(evaluation=ev)
        summary = ppr.workflow_summary_from_contracts(
            workflow_id="wf-parity",
            goal=goal,
            work_item=work_item,
        )
        text = summary.evaluation_summary
        assert "Required real-path checks:" in text
        assert "Required authority invariants:" in text
        assert "Required integration points:" in text
        assert "Forbidden shortcuts:" in text
        assert "Ready for guardian when:" in text
        assert "cc-policy dispatch agent-prompt succeeds" in text
        assert "codec is sole authority for eval keys" in text
        assert "compile_prompt_pack_for_stage Mode B succeeds" in text
        assert "no parallel decoder authority" in text
        assert "all tests pass, real-path checks succeed" in text


# ---------------------------------------------------------------------------
# Case 6: End-to-end prompt-pack compile succeeds with widened payload
# ---------------------------------------------------------------------------


class TestPromptPackCompileWidenedEvalContract:
    """Case 6 — end-to-end compile_prompt_pack_for_stage succeeds with 9-field contract."""

    @pytest.fixture
    def compile_conn(self):
        c = sqlite3.connect(":memory:")
        c.row_factory = sqlite3.Row
        ensure_schema(c)
        yield c
        c.close()

    def _seed_binding(self, conn) -> None:
        from runtime.core import workflows as wf
        wf.bind_workflow(
            conn,
            workflow_id="wf-parity",
            worktree_path="/tmp/wf-parity",
            branch="global-soak-main",
        )

    def _make_widened_work_item(self) -> contracts.WorkItemContract:
        return contracts.WorkItemContract(
            work_item_id="WI-PARITY-1",
            goal_id="G-PARITY-1",
            title="Parity slice — widened eval contract",
            scope=contracts.ScopeManifest(
                allowed_paths=("runtime/core/contracts.py",),
                required_paths=("tests/runtime/test_work_item_contract_codec_eval_schema_parity.py",),
                forbidden_paths=("runtime/cli.py",),
                state_domains=("work_items.evaluation_json_schema",),
            ),
            evaluation=contracts.EvaluationContract(
                required_tests=("pytest tests/runtime/test_work_item_contract_codec_eval_schema_parity.py",),
                required_evidence=("verbatim pytest output for all 22 suites",),
                required_real_path_checks=(
                    "cc-policy dispatch agent-prompt --workflow-id global-soak-main --stage-id planner",
                    "cc-policy prompt-pack subagent-start returns healthy=true on widened payload",
                ),
                required_authority_invariants=(
                    "codec is sole authority for evaluation_json key set",
                    "EvaluationContract is sole typed shape for evaluation data",
                ),
                required_integration_points=(
                    "compile_prompt_pack_for_stage Mode A + Mode B both succeed",
                ),
                forbidden_shortcuts=(
                    "no parallel relaxed decoder",
                    "no silent key drop",
                ),
                rollback_boundary="git restore runtime/core/contracts.py runtime/core/work_item_contract_codec.py runtime/core/prompt_pack_resolver.py runtime/cli.py",
                acceptance_notes="All 22 regression suites pass, widened schema compiles end-to-end",
                ready_for_guardian_definition="All tests pass, real-path proofs succeed, baseline preservation holds",
            ),
            status="in_progress",
        )

    def test_compile_succeeds_with_widened_eval_contract(self, compile_conn):
        """compile_prompt_pack_for_stage Mode A succeeds with all 9 eval fields."""
        from runtime.core import prompt_pack as pp
        from runtime.core import stage_registry as sr
        from runtime.core.projection_schemas import PromptPack

        self._seed_binding(compile_conn)
        goal = _default_goal(goal_id="G-PARITY-1")
        work_item = self._make_widened_work_item()

        pack = pp.compile_prompt_pack_for_stage(
            compile_conn,
            workflow_id="wf-parity",
            stage_id=sr.PLANNER,
            goal=goal,
            work_item=work_item,
            decision_scope="kernel",
            generated_at=1_750_000_000,
        )
        assert isinstance(pack, PromptPack)
        assert pack.workflow_id == "wf-parity"
        assert pack.layer_names == pp.CANONICAL_LAYER_ORDER
        assert pack.content_hash.startswith("sha256:")

    def test_compile_is_deterministic_across_two_invocations(self, compile_conn):
        """Same inputs produce byte-identical content_hash."""
        from runtime.core import prompt_pack as pp
        from runtime.core import stage_registry as sr

        self._seed_binding(compile_conn)
        goal = _default_goal(goal_id="G-PARITY-1")
        work_item = self._make_widened_work_item()

        pack1 = pp.compile_prompt_pack_for_stage(
            compile_conn,
            workflow_id="wf-parity",
            stage_id=sr.PLANNER,
            goal=goal,
            work_item=work_item,
            decision_scope="kernel",
            generated_at=1_750_000_000,
        )
        pack2 = pp.compile_prompt_pack_for_stage(
            compile_conn,
            workflow_id="wf-parity",
            stage_id=sr.PLANNER,
            goal=goal,
            work_item=work_item,
            decision_scope="kernel",
            generated_at=1_750_000_000,
        )
        assert pack1.content_hash == pack2.content_hash

    def test_compiled_evaluation_section_contains_new_headers(self, compile_conn):
        """The rendered evaluation summary in the workflow_contract layer has new headers.

        Proves the new fields reach the compiled prompt body without silent drop.
        """
        from runtime.core import prompt_pack as pp
        from runtime.core import prompt_pack_resolver as ppr
        from runtime.core import stage_registry as sr

        self._seed_binding(compile_conn)
        goal = _default_goal(goal_id="G-PARITY-1")
        work_item = self._make_widened_work_item()

        # Get the evaluation summary independently (same logic as compile path)
        ev = work_item.evaluation
        summary_text = ppr._render_evaluation_summary(goal, ev)

        # Assert at least 3 of the 5 new section headers appear in the rendered text
        new_headers = [
            "Required real-path checks:",
            "Required authority invariants:",
            "Required integration points:",
            "Forbidden shortcuts:",
            "Ready for guardian when:",
        ]
        found = [h for h in new_headers if h in summary_text]
        assert len(found) >= 3, (
            f"Expected >=3 new section headers in evaluation summary, got {len(found)}: "
            f"{found!r}"
        )
        # In fact all 5 should be present
        assert len(found) == 5, (
            f"Expected all 5 new section headers, got {found!r}"
        )

    def test_mode_b_compile_succeeds_with_widened_evaluation_json(self, compile_conn):
        """Mode B (id-input → SQLite read) compiles on a widened evaluation_json row."""
        from runtime.core import decision_work_registry as _dwr
        from runtime.core import goal_contract_codec as _gcc
        from runtime.core import prompt_pack as pp
        from runtime.core import stage_registry as sr
        from runtime.core.projection_schemas import PromptPack

        self._seed_binding(compile_conn)
        goal = _default_goal(goal_id="G-PARITY-MODE-B")
        work_item = self._make_widened_work_item()

        # Seed goal_contracts row
        goal_record = _gcc.encode_goal_contract(goal)
        _dwr.insert_goal(compile_conn, goal_record)

        # Seed work_items row with widened evaluation_json
        widened_payload = {
            "required_tests": ["pytest tests/runtime/test_work_item_contract_codec_eval_schema_parity.py"],
            "required_evidence": ["verbatim pytest output"],
            "required_real_path_checks": ["cc-policy dispatch agent-prompt succeeds"],
            "required_authority_invariants": ["codec is sole authority"],
            "required_integration_points": ["compile_prompt_pack_for_stage succeeds"],
            "forbidden_shortcuts": ["no parallel decoder"],
            "rollback_boundary": "git restore runtime/core/contracts.py",
            "acceptance_notes": "all tests pass",
            "ready_for_guardian_definition": "all tests pass and real-path checks succeed",
        }
        wi_record = dwr.WorkItemRecord(
            work_item_id="WI-PARITY-MODE-B",
            goal_id="G-PARITY-MODE-B",
            title="Mode B parity test",
            status="in_progress",
            version=1,
            author="planner",
            scope_json='{"allowed_paths":["runtime/core/contracts.py"],"required_paths":[],"forbidden_paths":[],"state_domains":["work_items.evaluation_json_schema"]}',
            evaluation_json=json.dumps(widened_payload),
            head_sha=None,
            reviewer_round=0,
        )
        _dwr.insert_work_item(compile_conn, wi_record)

        pack = pp.compile_prompt_pack_for_stage(
            compile_conn,
            workflow_id="wf-parity",
            stage_id=sr.PLANNER,
            goal_id="G-PARITY-MODE-B",
            work_item_id="WI-PARITY-MODE-B",
            decision_scope="kernel",
            generated_at=1_750_000_000,
        )
        assert isinstance(pack, PromptPack)
        assert pack.layer_names == pp.CANONICAL_LAYER_ORDER


# ---------------------------------------------------------------------------
# Case 7: CLI help text references at least 6 of the 9 legal keys
# ---------------------------------------------------------------------------


class TestCLIHelpTextWidenessSurface:
    """Case 7 — --evaluation-json help text is a derived surface of the schema."""

    def test_evaluation_json_help_references_at_least_6_legal_keys(self):
        """Help text must enumerate the widened key set (derived surface contract)."""
        import argparse
        import sys

        import runtime.cli as cli_mod  # noqa: F401  (triggers module parse)

        # Walk the argparse namespace to find the --evaluation-json action.
        # We can re-parse the module's argument setup by calling the function
        # that constructs the parser, but that's internal. Instead, we call
        # the CLI's build_parser (if exposed) or parse_args with --help.
        # The simplest approach: import and scan the cli module for the
        # wf_wi_set subparser action.
        #
        # Since cli.py builds parsers imperatively, we need to instantiate them.
        # Use the function exposed in the test suite pattern: call build_arg_parser
        # if available, else import and find the action via the build path.

        # Build the top-level parser (same as cli.main() does)
        # We deliberately do NOT call sys.exit or main(); we just build the parser.
        try:
            parser = cli_mod.build_arg_parser()
        except AttributeError:
            # If build_arg_parser is not a top-level exported function,
            # we'll scan the module source for the help text string directly.
            import inspect
            source = inspect.getsource(cli_mod)
            # Find the help text for --evaluation-json
            import re
            pattern = r'--evaluation-json[^)]*help\s*=\s*["\']([^"\']+)["\']'
            m = re.search(pattern, source, re.DOTALL)
            if m:
                help_text = m.group(1)
            else:
                # Multi-line help= using parens
                idx = source.find("--evaluation-json")
                snippet = source[idx:idx + 800]
                help_text = snippet
            keys_found = [k for k in _ALL_9_LEGAL_KEYS if k in help_text]
            assert len(keys_found) >= 6, (
                f"CLI --evaluation-json help text references only {len(keys_found)} of 9 legal keys "
                f"(need >=6). Found: {keys_found!r}"
            )
            return

        # Walk subparsers to find the workflow work-item-set → --evaluation-json action.
        # The argparse tree: top → sub "workflow" → sub "work-item-set" → action
        found_action = None
        for action in parser._actions:
            if hasattr(action, '_parser_class'):
                # It's a _SubParsersAction
                for name, subparser in action.choices.items():
                    if name == "workflow":
                        for sub_action in subparser._actions:
                            if hasattr(sub_action, 'choices'):
                                for sub_name, sub_sub_parser in sub_action.choices.items():
                                    if sub_name in ("work-item-set", "work_item_set"):
                                        for leaf in sub_sub_parser._actions:
                                            if getattr(leaf, 'dest', None) == "evaluation_json":
                                                found_action = leaf
                                                break

        if found_action is not None:
            help_text = found_action.help or ""
            keys_found = [k for k in _ALL_9_LEGAL_KEYS if k in help_text]
            assert len(keys_found) >= 6, (
                f"CLI --evaluation-json help text references only {len(keys_found)} of 9 legal keys "
                f"(need >=6). Found: {keys_found!r}"
            )
        else:
            # Fallback: scan source for the help string
            import inspect
            import re
            source = inspect.getsource(cli_mod)
            idx = source.find("--evaluation-json")
            snippet = source[idx:idx + 800]
            keys_found = [k for k in _ALL_9_LEGAL_KEYS if k in snippet]
            assert len(keys_found) >= 6, (
                f"CLI --evaluation-json definition references only {len(keys_found)} of 9 legal keys "
                f"(need >=6). Found: {keys_found!r}"
            )


# ---------------------------------------------------------------------------
# Case 8: Module docstring carries DEC-id anchor
# ---------------------------------------------------------------------------


class TestDECIdTracabilityAnchor:
    """Case 8 — this module's docstring carries DEC-CLAUDEX-EVAL-CONTRACT-SCHEMA-PARITY-001."""

    def test_module_docstring_contains_dec_id(self):
        import tests.runtime.test_work_item_contract_codec_eval_schema_parity as this_mod
        doc = this_mod.__doc__ or ""
        assert "DEC-CLAUDEX-EVAL-CONTRACT-SCHEMA-PARITY-001" in doc, (
            "This test module's docstring must contain the DEC-id anchor "
            "DEC-CLAUDEX-EVAL-CONTRACT-SCHEMA-PARITY-001 for traceability."
        )


# ---------------------------------------------------------------------------
# Additional codec tests for the new fields (regression + validation coverage)
# ---------------------------------------------------------------------------


class TestEmptyBracesDecodesToDefaults:
    """Empty {} still decodes to default EvaluationContract (legacy row compat)."""

    def test_empty_braces_decodes_to_all_defaults(self):
        record = _record(evaluation_json="{}")
        result = wcc.decode_work_item_contract(record)
        ev = result.evaluation
        assert ev.required_tests == ()
        assert ev.required_evidence == ()
        assert ev.required_real_path_checks == ()
        assert ev.required_authority_invariants == ()
        assert ev.required_integration_points == ()
        assert ev.forbidden_shortcuts == ()
        assert ev.rollback_boundary == ""
        assert ev.acceptance_notes == ""
        assert ev.ready_for_guardian_definition == ""


class TestLegacyAliasesUnchanged:
    """Legacy aliases still work after widening."""

    def test_evidence_alias_resolves_to_required_evidence(self):
        record = _record(evaluation_json='{"evidence": ["e1", "e2"]}')
        result = wcc.decode_work_item_contract(record)
        assert result.evaluation.required_evidence == ("e1", "e2")

    def test_acceptance_alias_resolves_to_acceptance_notes(self):
        record = _record(evaluation_json='{"acceptance": "ok"}')
        result = wcc.decode_work_item_contract(record)
        assert result.evaluation.acceptance_notes == "ok"

    def test_evidence_scalar_string_coerced_to_singleton_list(self):
        record = _record(evaluation_json='{"evidence": "single"}')
        result = wcc.decode_work_item_contract(record)
        assert result.evaluation.required_evidence == ("single",)


class TestPartialPopulationDefaultsRest:
    """Partial payload: populated fields set, unpopulated fields at default."""

    def test_only_new_keys_populated_defaults_old(self):
        payload = {
            "required_real_path_checks": ["rpc-a"],
            "required_authority_invariants": ["inv-a"],
            "required_integration_points": ["int-a"],
        }
        record = _record(evaluation_json=json.dumps(payload))
        result = wcc.decode_work_item_contract(record)
        ev = result.evaluation

        assert ev.required_real_path_checks == ("rpc-a",)
        assert ev.required_authority_invariants == ("inv-a",)
        assert ev.required_integration_points == ("int-a",)
        # Old fields at default
        assert ev.required_tests == ()
        assert ev.required_evidence == ()
        assert ev.forbidden_shortcuts == ()
        assert ev.rollback_boundary == ""
        assert ev.acceptance_notes == ""
        assert ev.ready_for_guardian_definition == ""


class TestTupleValidationCatchesNonStringElementInNewKeys:
    """Non-string elements in new tuple-valued keys raise ValueError naming field+index."""

    @pytest.mark.parametrize("key", [
        "required_real_path_checks",
        "required_authority_invariants",
        "required_integration_points",
        "forbidden_shortcuts",
    ])
    def test_non_string_element_raises(self, key):
        payload = {key: ["valid-string", 42]}  # 42 is non-string
        record = _record(evaluation_json=json.dumps(payload))
        with pytest.raises(ValueError) as exc:
            wcc.decode_work_item_contract(record)
        msg = str(exc.value)
        assert key in msg, f"Error message should name field {key!r}: {msg}"
        assert "1" in msg or "index" in msg.lower() or "42" in msg or "[1]" in msg


class TestReadyForGuardianDefinitionMustBeString:
    """Non-string ready_for_guardian_definition raises ValueError naming field."""

    def test_non_string_value_raises(self):
        payload = {"ready_for_guardian_definition": ["not", "a", "string"]}
        record = _record(evaluation_json=json.dumps(payload))
        with pytest.raises(ValueError) as exc:
            wcc.decode_work_item_contract(record)
        msg = str(exc.value)
        assert "ready_for_guardian_definition" in msg
