"""Tests for runtime/core/work_item_contract_codec.py.

@decision DEC-CLAUDEX-WORK-ITEM-CONTRACT-CODEC-TESTS-001
Title: Pure work-item decode bridge — typed nested decoding, closed key sets, legacy empty-object compatibility, and shadow-only discipline pinned
Status: proposed (shadow-mode, Phase 2 prompt-pack workflow-contract bridge)
Rationale: The codec is the decode-only bridge from
  :class:`runtime.core.decision_work_registry.WorkItemRecord` to
  :class:`runtime.core.contracts.WorkItemContract`. The interesting
  surface is the nested JSON shape and the closed key set on both
  ``scope_json`` and ``evaluation_json`` — bugs there silently
  produce wrong contracts. These tests pin:

    1. Default ``"{}"`` decodes to empty :class:`ScopeManifest` and
       :class:`EvaluationContract` (legacy persistence default).
    2. Populated nested JSON decodes to the expected typed shape
       with every tuple field preserved verbatim.
    3. Unicode strings round-trip cleanly through the JSON layer.
    4. Wrong record type rejected on the public API.
    5. Malformed JSON rejected on both nested fields.
    6. Non-object top-level (list, scalar, null) rejected on both
       nested fields.
    7. Unknown keys rejected on both ``scope_json`` and
       ``evaluation_json``, with the error message naming the
       offending key.
    8. Non-list values rejected for every tuple-valued nested key
       on both fields.
    9. Non-string list elements rejected on every tuple-valued
       nested key.
   10. Non-string ``rollback_boundary`` / ``acceptance_notes``
       rejected.
   11. ``reviewer_round`` and ``head_sha`` flow through the decode
       verbatim from the record.
   12. End-to-end smoke through SQLite: ``insert_work_item`` →
       ``get_work_item`` → ``decode_work_item_contract``.
   13. Shadow-only discipline via AST: imports only stdlib +
       ``contracts`` + ``decision_work_registry``; reverse-dep
       guards on every live module the slice forbids.
"""

from __future__ import annotations

import ast
import inspect
import json
import sqlite3

import pytest

from runtime.core import contracts
from runtime.core import decision_work_registry as dwr
from runtime.core import work_item_contract_codec as wcc
from runtime.schemas import ensure_schema


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
# Fixtures + helpers
# ---------------------------------------------------------------------------


def _record(**overrides) -> dwr.WorkItemRecord:
    """Build a minimally-valid WorkItemRecord with optional overrides."""
    base = dict(
        work_item_id="WI-CODEC-1",
        goal_id="G-CODEC-1",
        title="codec slice",
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


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


# ---------------------------------------------------------------------------
# 1. Default empty JSON object decode
# ---------------------------------------------------------------------------


class TestEmptyObjectDecode:
    def test_default_empty_scope_decodes_to_empty_manifest(self):
        contract = wcc.decode_work_item_contract(_record())
        assert isinstance(contract.scope, contracts.ScopeManifest)
        assert contract.scope.allowed_paths == ()
        assert contract.scope.required_paths == ()
        assert contract.scope.forbidden_paths == ()
        assert contract.scope.state_domains == ()

    def test_default_empty_evaluation_decodes_to_empty_contract(self):
        contract = wcc.decode_work_item_contract(_record())
        assert isinstance(contract.evaluation, contracts.EvaluationContract)
        assert contract.evaluation.required_tests == ()
        assert contract.evaluation.required_evidence == ()
        assert contract.evaluation.rollback_boundary == ""
        assert contract.evaluation.acceptance_notes == ""

    def test_default_empty_decode_returns_work_item_contract(self):
        contract = wcc.decode_work_item_contract(_record())
        assert isinstance(contract, contracts.WorkItemContract)
        assert contract.work_item_id == "WI-CODEC-1"
        assert contract.goal_id == "G-CODEC-1"
        assert contract.title == "codec slice"
        assert contract.status == "pending"


# ---------------------------------------------------------------------------
# 2. Populated nested JSON decode
# ---------------------------------------------------------------------------


class TestPopulatedDecode:
    def test_populated_scope_decodes_every_tuple_field(self):
        scope_payload = {
            "allowed_paths": ["runtime/", "tests/"],
            "required_paths": ["runtime/core/work_item_contract_codec.py"],
            "forbidden_paths": ["runtime/cli.py"],
            "state_domains": ["work_items", "decisions"],
        }
        record = _record(scope_json=json.dumps(scope_payload))
        contract = wcc.decode_work_item_contract(record)
        assert contract.scope.allowed_paths == ("runtime/", "tests/")
        assert contract.scope.required_paths == (
            "runtime/core/work_item_contract_codec.py",
        )
        assert contract.scope.forbidden_paths == ("runtime/cli.py",)
        assert contract.scope.state_domains == ("work_items", "decisions")

    def test_populated_evaluation_decodes_every_field(self):
        eval_payload = {
            "required_tests": ["pytest tests/runtime/test_work_item_contract_codec.py"],
            "required_evidence": ["verbatim pytest footer"],
            "rollback_boundary": "git restore runtime/core/work_item_contract_codec.py",
            "acceptance_notes": "decode bridge round-trips legacy + populated payloads",
        }
        record = _record(evaluation_json=json.dumps(eval_payload))
        contract = wcc.decode_work_item_contract(record)
        assert contract.evaluation.required_tests == (
            "pytest tests/runtime/test_work_item_contract_codec.py",
        )
        assert contract.evaluation.required_evidence == ("verbatim pytest footer",)
        assert (
            contract.evaluation.rollback_boundary
            == "git restore runtime/core/work_item_contract_codec.py"
        )
        assert (
            contract.evaluation.acceptance_notes
            == "decode bridge round-trips legacy + populated payloads"
        )

    def test_decode_preserves_tuple_element_order(self):
        # Element ordering is significant — the codec must NOT
        # sort or normalize.
        record = _record(
            scope_json='{"allowed_paths":["z","a","m"]}',
            evaluation_json='{"required_tests":["z","a","m"]}',
        )
        contract = wcc.decode_work_item_contract(record)
        assert contract.scope.allowed_paths == ("z", "a", "m")
        assert contract.evaluation.required_tests == ("z", "a", "m")

    def test_unicode_strings_round_trip(self):
        scope_payload = {"allowed_paths": ["café/", "日本語/", "résumé.md"]}
        eval_payload = {
            "required_evidence": ["naïve test"],
            "acceptance_notes": "中文 acceptance",
        }
        record = _record(
            scope_json=json.dumps(scope_payload, ensure_ascii=False),
            evaluation_json=json.dumps(eval_payload, ensure_ascii=False),
        )
        contract = wcc.decode_work_item_contract(record)
        assert contract.scope.allowed_paths == ("café/", "日本語/", "résumé.md")
        assert contract.evaluation.required_evidence == ("naïve test",)
        assert contract.evaluation.acceptance_notes == "中文 acceptance"

    def test_partial_scope_payload_defaults_missing_keys(self):
        # Only one key present — the other three default to ().
        record = _record(scope_json='{"allowed_paths":["a","b"]}')
        contract = wcc.decode_work_item_contract(record)
        assert contract.scope.allowed_paths == ("a", "b")
        assert contract.scope.required_paths == ()
        assert contract.scope.forbidden_paths == ()
        assert contract.scope.state_domains == ()

    def test_partial_evaluation_payload_defaults_missing_keys(self):
        # Only one tuple and one string — the other two default.
        record = _record(
            evaluation_json='{"required_tests":["t"],"acceptance_notes":"ok"}'
        )
        contract = wcc.decode_work_item_contract(record)
        assert contract.evaluation.required_tests == ("t",)
        assert contract.evaluation.required_evidence == ()
        assert contract.evaluation.rollback_boundary == ""
        assert contract.evaluation.acceptance_notes == "ok"


# ---------------------------------------------------------------------------
# 3. Pass-through scalar fields
# ---------------------------------------------------------------------------


class TestScalarPassthrough:
    def test_reviewer_round_flows_through(self):
        contract = wcc.decode_work_item_contract(_record(reviewer_round=4))
        assert contract.reviewer_round == 4

    def test_head_sha_none_flows_through(self):
        contract = wcc.decode_work_item_contract(_record(head_sha=None))
        assert contract.head_sha is None

    def test_head_sha_string_flows_through(self):
        contract = wcc.decode_work_item_contract(_record(head_sha="abc123"))
        assert contract.head_sha == "abc123"

    def test_status_flows_through(self):
        contract = wcc.decode_work_item_contract(_record(status="in_review"))
        assert contract.status == "in_review"

    def test_timestamps_flow_through(self):
        contract = wcc.decode_work_item_contract(
            _record(created_at=1_700_000_000, updated_at=1_700_000_500)
        )
        assert contract.created_at == 1_700_000_000
        assert contract.updated_at == 1_700_000_500

    def test_goal_id_trusted_verbatim(self):
        # No cross-check is performed — the codec trusts whatever
        # goal_id the record carries. Pin this so a future cross-
        # check addition is a deliberate decision, not a regression.
        contract = wcc.decode_work_item_contract(
            _record(goal_id="G-trust-me")
        )
        assert contract.goal_id == "G-trust-me"


# ---------------------------------------------------------------------------
# 4. Wrong input type rejection
# ---------------------------------------------------------------------------


class TestRecordTypeRejection:
    def test_string_input_rejected(self):
        with pytest.raises(ValueError, match="WorkItemRecord"):
            wcc.decode_work_item_contract("not a record")  # type: ignore[arg-type]

    def test_none_input_rejected(self):
        with pytest.raises(ValueError, match="WorkItemRecord"):
            wcc.decode_work_item_contract(None)  # type: ignore[arg-type]

    def test_dict_input_rejected(self):
        with pytest.raises(ValueError, match="WorkItemRecord"):
            wcc.decode_work_item_contract(  # type: ignore[arg-type]
                {"work_item_id": "WI-1"}
            )

    def test_goal_record_input_rejected(self):
        # GoalRecord shares the registry's persistence family but
        # is the wrong record kind — must be refused explicitly.
        goal = dwr.GoalRecord(
            goal_id="G-1",
            desired_end_state="end",
            status="active",
        )
        with pytest.raises(ValueError, match="WorkItemRecord"):
            wcc.decode_work_item_contract(goal)  # type: ignore[arg-type]

    def test_contract_input_rejected(self):
        # Handing the decoder a WorkItemContract is a caller bug.
        contract = contracts.WorkItemContract(
            work_item_id="WI-1",
            goal_id="G-1",
            title="t",
        )
        with pytest.raises(ValueError, match="WorkItemRecord"):
            wcc.decode_work_item_contract(contract)  # type: ignore[arg-type]


# ---------------------------------------------------------------------------
# 5. Malformed JSON rejection
# ---------------------------------------------------------------------------


class TestMalformedJsonRejection:
    def test_malformed_scope_json_rejected(self):
        with pytest.raises(ValueError, match="scope_json"):
            wcc.decode_work_item_contract(_record(scope_json="{not valid"))

    def test_malformed_evaluation_json_rejected(self):
        with pytest.raises(ValueError, match="evaluation_json"):
            wcc.decode_work_item_contract(
                _record(evaluation_json="{not valid")
            )

    def test_truncated_scope_json_rejected(self):
        with pytest.raises(ValueError, match="scope_json"):
            wcc.decode_work_item_contract(
                _record(scope_json='{"allowed_paths":')
            )

    def test_truncated_evaluation_json_rejected(self):
        with pytest.raises(ValueError, match="evaluation_json"):
            wcc.decode_work_item_contract(
                _record(evaluation_json='{"required_tests":[')
            )


# ---------------------------------------------------------------------------
# 6. Non-object top-level rejection
# ---------------------------------------------------------------------------


class TestNonObjectTopLevelRejection:
    @pytest.mark.parametrize(
        "raw",
        ["[]", "[1,2,3]", '"a string"', "42", "null", "true", "false"],
    )
    def test_scope_non_object_top_level_rejected(self, raw):
        with pytest.raises(ValueError, match="scope_json"):
            wcc.decode_work_item_contract(_record(scope_json=raw))

    @pytest.mark.parametrize(
        "raw",
        ["[]", "[1,2,3]", '"a string"', "42", "null", "true", "false"],
    )
    def test_evaluation_non_object_top_level_rejected(self, raw):
        with pytest.raises(ValueError, match="evaluation_json"):
            wcc.decode_work_item_contract(_record(evaluation_json=raw))


# ---------------------------------------------------------------------------
# 7. Unknown key rejection
# ---------------------------------------------------------------------------


class TestUnknownKeyRejection:
    def test_scope_unknown_key_rejected(self):
        with pytest.raises(ValueError, match="rogue_key"):
            wcc.decode_work_item_contract(
                _record(scope_json='{"rogue_key":["x"]}')
            )

    def test_scope_unknown_key_alongside_legal_keys_rejected(self):
        with pytest.raises(ValueError, match="rogue_key"):
            wcc.decode_work_item_contract(
                _record(
                    scope_json='{"allowed_paths":["a"],"rogue_key":"y"}'
                )
            )

    def test_scope_error_names_field(self):
        with pytest.raises(ValueError, match="scope_json"):
            wcc.decode_work_item_contract(
                _record(scope_json='{"surprise":1}')
            )

    def test_evaluation_unknown_key_rejected(self):
        with pytest.raises(ValueError, match="rogue_key"):
            wcc.decode_work_item_contract(
                _record(evaluation_json='{"rogue_key":"x"}')
            )

    def test_evaluation_unknown_key_alongside_legal_keys_rejected(self):
        with pytest.raises(ValueError, match="rogue_key"):
            wcc.decode_work_item_contract(
                _record(
                    evaluation_json='{"required_tests":["t"],"rogue_key":1}'
                )
            )

    def test_evaluation_error_names_field(self):
        with pytest.raises(ValueError, match="evaluation_json"):
            wcc.decode_work_item_contract(
                _record(evaluation_json='{"surprise":1}')
            )

    def test_scope_error_lists_legal_key_set(self):
        # The error message must include the legal keys so a
        # caller can repair the row without consulting the codec
        # source. Match a few of the legal names rather than the
        # full sorted list (which is implementation detail).
        with pytest.raises(ValueError, match="allowed_paths"):
            wcc.decode_work_item_contract(
                _record(scope_json='{"oops":[]}')
            )

    def test_evaluation_error_lists_legal_key_set(self):
        with pytest.raises(ValueError, match="required_tests"):
            wcc.decode_work_item_contract(
                _record(evaluation_json='{"oops":[]}')
            )


# ---------------------------------------------------------------------------
# 8. Non-list tuple field rejection
# ---------------------------------------------------------------------------


class TestNonListTupleRejection:
    @pytest.mark.parametrize(
        "key",
        ["allowed_paths", "required_paths", "forbidden_paths", "state_domains"],
    )
    def test_scope_string_value_rejected(self, key):
        with pytest.raises(ValueError, match=key):
            wcc.decode_work_item_contract(
                _record(scope_json=json.dumps({key: "not a list"}))
            )

    @pytest.mark.parametrize(
        "key",
        ["allowed_paths", "required_paths", "forbidden_paths", "state_domains"],
    )
    def test_scope_dict_value_rejected(self, key):
        with pytest.raises(ValueError, match=key):
            wcc.decode_work_item_contract(
                _record(scope_json=json.dumps({key: {"nested": True}}))
            )

    @pytest.mark.parametrize(
        "key",
        ["allowed_paths", "required_paths", "forbidden_paths", "state_domains"],
    )
    def test_scope_null_value_rejected(self, key):
        with pytest.raises(ValueError, match=key):
            wcc.decode_work_item_contract(
                _record(scope_json=json.dumps({key: None}))
            )

    @pytest.mark.parametrize("key", ["required_tests", "required_evidence"])
    def test_evaluation_string_value_rejected(self, key):
        with pytest.raises(ValueError, match=key):
            wcc.decode_work_item_contract(
                _record(evaluation_json=json.dumps({key: "not a list"}))
            )

    @pytest.mark.parametrize("key", ["required_tests", "required_evidence"])
    def test_evaluation_dict_value_rejected(self, key):
        with pytest.raises(ValueError, match=key):
            wcc.decode_work_item_contract(
                _record(
                    evaluation_json=json.dumps({key: {"nested": True}})
                )
            )

    @pytest.mark.parametrize("key", ["required_tests", "required_evidence"])
    def test_evaluation_null_value_rejected(self, key):
        with pytest.raises(ValueError, match=key):
            wcc.decode_work_item_contract(
                _record(evaluation_json=json.dumps({key: None}))
            )


# ---------------------------------------------------------------------------
# 9. Non-string list element rejection
# ---------------------------------------------------------------------------


class TestNonStringElementRejection:
    @pytest.mark.parametrize(
        "key",
        ["allowed_paths", "required_paths", "forbidden_paths", "state_domains"],
    )
    def test_scope_int_element_rejected(self, key):
        with pytest.raises(ValueError, match=key):
            wcc.decode_work_item_contract(
                _record(scope_json=json.dumps({key: ["ok", 42, "also"]}))
            )

    @pytest.mark.parametrize(
        "key",
        ["allowed_paths", "required_paths", "forbidden_paths", "state_domains"],
    )
    def test_scope_null_element_rejected(self, key):
        with pytest.raises(ValueError, match=key):
            wcc.decode_work_item_contract(
                _record(scope_json=json.dumps({key: ["ok", None]}))
            )

    @pytest.mark.parametrize(
        "key",
        ["allowed_paths", "required_paths", "forbidden_paths", "state_domains"],
    )
    def test_scope_nested_list_element_rejected(self, key):
        with pytest.raises(ValueError, match=key):
            wcc.decode_work_item_contract(
                _record(scope_json=json.dumps({key: [["nested"]]}))
            )

    @pytest.mark.parametrize("key", ["required_tests", "required_evidence"])
    def test_evaluation_int_element_rejected(self, key):
        with pytest.raises(ValueError, match=key):
            wcc.decode_work_item_contract(
                _record(
                    evaluation_json=json.dumps({key: ["ok", 42]})
                )
            )

    @pytest.mark.parametrize("key", ["required_tests", "required_evidence"])
    def test_evaluation_null_element_rejected(self, key):
        with pytest.raises(ValueError, match=key):
            wcc.decode_work_item_contract(
                _record(
                    evaluation_json=json.dumps({key: ["ok", None]})
                )
            )


# ---------------------------------------------------------------------------
# 10. Non-string evaluation string fields rejected
# ---------------------------------------------------------------------------


class TestNonStringEvaluationStringFieldRejection:
    @pytest.mark.parametrize(
        "key", ["rollback_boundary", "acceptance_notes"]
    )
    def test_int_value_rejected(self, key):
        with pytest.raises(ValueError, match=key):
            wcc.decode_work_item_contract(
                _record(evaluation_json=json.dumps({key: 42}))
            )

    @pytest.mark.parametrize(
        "key", ["rollback_boundary", "acceptance_notes"]
    )
    def test_list_value_rejected(self, key):
        with pytest.raises(ValueError, match=key):
            wcc.decode_work_item_contract(
                _record(evaluation_json=json.dumps({key: ["a", "b"]}))
            )

    @pytest.mark.parametrize(
        "key", ["rollback_boundary", "acceptance_notes"]
    )
    def test_dict_value_rejected(self, key):
        with pytest.raises(ValueError, match=key):
            wcc.decode_work_item_contract(
                _record(evaluation_json=json.dumps({key: {"nested": "x"}}))
            )

    @pytest.mark.parametrize(
        "key", ["rollback_boundary", "acceptance_notes"]
    )
    def test_null_value_rejected(self, key):
        with pytest.raises(ValueError, match=key):
            wcc.decode_work_item_contract(
                _record(evaluation_json=json.dumps({key: None}))
            )


# ---------------------------------------------------------------------------
# 11. SQLite end-to-end smoke
# ---------------------------------------------------------------------------


class TestSqliteSmoke:
    def test_round_trip_through_sqlite_default_payloads(self, conn):
        record_in = _record(
            work_item_id="WI-smoke-default",
            reviewer_round=2,
            head_sha="cafe1234",
        )
        dwr.insert_work_item(conn, record_in)
        record_out = dwr.get_work_item(conn, "WI-smoke-default")
        assert record_out is not None

        contract = wcc.decode_work_item_contract(record_out)
        assert isinstance(contract, contracts.WorkItemContract)
        assert contract.work_item_id == "WI-smoke-default"
        assert contract.reviewer_round == 2
        assert contract.head_sha == "cafe1234"
        # Empty default payloads → empty subcontracts.
        assert contract.scope == contracts.ScopeManifest()
        assert contract.evaluation == contracts.EvaluationContract()

    def test_round_trip_through_sqlite_populated_payloads(self, conn):
        scope_payload = {
            "allowed_paths": ["runtime/core/work_item_contract_codec.py"],
            "required_paths": ["tests/runtime/test_work_item_contract_codec.py"],
            "forbidden_paths": ["runtime/cli.py"],
            "state_domains": ["work_items"],
        }
        eval_payload = {
            "required_tests": [
                "pytest tests/runtime/test_work_item_contract_codec.py"
            ],
            "required_evidence": ["verbatim pytest footer"],
            "rollback_boundary": "git restore runtime/core/work_item_contract_codec.py",
            "acceptance_notes": "decode-only bridge round-trips through SQLite",
        }
        record_in = _record(
            work_item_id="WI-smoke-full",
            scope_json=json.dumps(scope_payload),
            evaluation_json=json.dumps(eval_payload),
            reviewer_round=3,
            head_sha="0123abcd",
        )
        dwr.insert_work_item(conn, record_in)
        record_out = dwr.get_work_item(conn, "WI-smoke-full")
        assert record_out is not None

        contract = wcc.decode_work_item_contract(record_out)
        assert contract.work_item_id == "WI-smoke-full"
        assert contract.scope.allowed_paths == (
            "runtime/core/work_item_contract_codec.py",
        )
        assert contract.scope.required_paths == (
            "tests/runtime/test_work_item_contract_codec.py",
        )
        assert contract.scope.forbidden_paths == ("runtime/cli.py",)
        assert contract.scope.state_domains == ("work_items",)
        assert contract.evaluation.required_tests == (
            "pytest tests/runtime/test_work_item_contract_codec.py",
        )
        assert contract.evaluation.required_evidence == (
            "verbatim pytest footer",
        )
        assert (
            contract.evaluation.rollback_boundary
            == "git restore runtime/core/work_item_contract_codec.py"
        )
        assert (
            contract.evaluation.acceptance_notes
            == "decode-only bridge round-trips through SQLite"
        )
        assert contract.reviewer_round == 3
        assert contract.head_sha == "0123abcd"


# ---------------------------------------------------------------------------
# 12. Shadow-only discipline
# ---------------------------------------------------------------------------


class TestShadowOnlyDiscipline:
    def test_codec_only_imports_permitted_shadow_modules(self):
        imported = _imported_module_names(wcc)
        runtime_core_imports = {
            n for n in imported if n.startswith("runtime.core")
        }
        permitted_bases = {"runtime.core"}
        permitted_prefixes = (
            "runtime.core.contracts",
            "runtime.core.decision_work_registry",
        )
        for name in runtime_core_imports:
            assert name in permitted_bases or name.startswith(
                permitted_prefixes
            ), (
                f"work_item_contract_codec.py has unexpected runtime.core "
                f"import: {name!r}"
            )

    def test_codec_has_no_live_routing_imports(self):
        imported = _imported_module_names(wcc)
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
            "prompt_pack",
        )
        for name in imported:
            for needle in forbidden_substrings:
                assert needle not in name, (
                    f"work_item_contract_codec.py imports {name!r} containing "
                    f"forbidden token {needle!r}"
                )

    def test_codec_does_not_import_subprocess_or_filesystem(self):
        imported = _imported_module_names(wcc)
        # Pure decoder — no subprocess, no filesystem walking, no
        # SQLite. The persistence helpers do all the I/O.
        assert "subprocess" not in imported
        assert "sqlite3" not in imported
        for name in imported:
            assert "pathlib" not in name
            assert "os.walk" not in name

    def test_cli_does_not_import_codec(self):
        import runtime.cli as cli

        imported = _imported_module_names(cli)
        for name in imported:
            assert "work_item_contract_codec" not in name, (
                f"cli.py imports {name!r} — work_item_contract_codec must "
                f"not be wired into the CLI this slice"
            )

    def test_prompt_pack_does_not_import_codec(self):
        from runtime.core import prompt_pack as pp

        imported = _imported_module_names(pp)
        for name in imported:
            assert "work_item_contract_codec" not in name, (
                f"prompt_pack.py imports {name!r} — work_item_contract_codec "
                f"must not be wired into the compiler this slice"
            )

    def test_dispatch_engine_does_not_import_codec(self):
        import runtime.core.dispatch_engine as dispatch_engine

        imported = _imported_module_names(dispatch_engine)
        for name in imported:
            assert "work_item_contract_codec" not in name

    def test_completions_does_not_import_codec(self):
        import runtime.core.completions as completions

        imported = _imported_module_names(completions)
        for name in imported:
            assert "work_item_contract_codec" not in name

    def test_policy_engine_does_not_import_codec(self):
        import runtime.core.policy_engine as policy_engine

        imported = _imported_module_names(policy_engine)
        for name in imported:
            assert "work_item_contract_codec" not in name

    def test_decision_work_registry_does_not_import_codec(self):
        # Reverse dep guard: the persistence module owns the record
        # and must not depend on a specific decoder.
        imported = _imported_module_names(dwr)
        for name in imported:
            assert "work_item_contract_codec" not in name

    def test_contracts_does_not_import_codec(self):
        imported = _imported_module_names(contracts)
        for name in imported:
            assert "work_item_contract_codec" not in name

    def test_goal_contract_codec_does_not_import_work_item_codec(self):
        # The two codec modules must remain independent — neither
        # owns the other's contract family.
        from runtime.core import goal_contract_codec as gcc

        imported = _imported_module_names(gcc)
        for name in imported:
            assert "work_item_contract_codec" not in name
