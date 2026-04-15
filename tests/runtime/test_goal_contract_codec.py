"""Tests for runtime/core/goal_contract_codec.py.

@decision DEC-CLAUDEX-GOAL-CONTRACT-CODEC-TESTS-001
Title: Pure typed goal-contract codec — round-trip, deterministic JSON, type validation, and shadow-only discipline pinned
Status: proposed (shadow-mode, Phase 2 prompt-pack workflow-contract bridge)
Rationale: The codec is a pure bridge between
  :class:`runtime.core.contracts.GoalContract` and
  :class:`runtime.core.decision_work_registry.GoalRecord`. Its
  correctness is almost entirely about field-for-field mapping and
  the deterministic JSON policy for the four tuple-shaped fields.
  These tests pin:

    1. ``decode(encode(goal)) == goal`` for representative goal
       contracts (default, fully populated, unicode tuples).
    2. The JSON output for each tuple field uses compact
       separators and preserves element order verbatim. Empty
       tuples round-trip cleanly to ``"[]"``.
    3. Both byte-determinism (``encode(g) == encode(g)``) and
       structural determinism (`encode(g_a).continuation_rules_json
       == encode(g_b).continuation_rules_json`` when only ordering
       differs from a sorted form, proving the codec does NOT
       sort).
    4. Wrong input type rejection on encode (non-GoalContract) and
       on decode (non-GoalRecord).
    5. Encode rejects any non-string element in a tuple field
       with a clear ``ValueError`` naming the field and index.
    6. Decode rejects malformed JSON on any tuple field with a
       ``ValueError`` that names the field.
    7. Decode rejects JSON whose top-level value is not a list
       (dict, scalar, null) on any tuple field.
    8. Decode rejects JSON list elements that are not strings on
       any tuple field.
    9. Status validation flows through to the underlying dataclass
       ``__post_init__``: encoding a contract with an unknown
       status raises (because ``contracts.GoalContract`` itself
       cannot be constructed with an unknown status, but the
       codec also rejects round-trips through a forged record).
   10. Shadow-only discipline via AST: imports only stdlib +
       ``contracts`` + ``decision_work_registry``; no live routing
       module imports the codec; CLI does not import the codec.
"""

from __future__ import annotations

import ast
import inspect
import json

import pytest

from runtime.core import contracts
from runtime.core import decision_work_registry as dwr
from runtime.core import goal_contract_codec as gcc


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


def _default_goal(**overrides) -> contracts.GoalContract:
    """Build a minimally-valid GoalContract with optional overrides."""
    base = dict(
        goal_id="G-CODEC-1",
        desired_end_state="ship the codec slice",
        status="active",
        autonomy_budget=0,
        continuation_rules=(),
        stop_conditions=(),
        escalation_boundaries=(),
        user_decision_boundaries=(),
        created_at=0,
        updated_at=0,
    )
    base.update(overrides)
    return contracts.GoalContract(**base)


def _populated_goal() -> contracts.GoalContract:
    """A GoalContract with every tuple field non-empty and varied content."""
    return contracts.GoalContract(
        goal_id="G-FULL",
        desired_end_state="land the workflow capture path",
        status="active",
        autonomy_budget=7,
        continuation_rules=("rule-a", "rule-b", "rule-c"),
        stop_conditions=("cond-x",),
        escalation_boundaries=("boundary-1", "boundary-2"),
        user_decision_boundaries=("udb-only",),
        created_at=1_700_000_000,
        updated_at=1_700_000_500,
    )


# ---------------------------------------------------------------------------
# 1. Round-trip — decode(encode(goal)) == goal
# ---------------------------------------------------------------------------


class TestRoundTrip:
    def test_default_goal_round_trips(self):
        goal = _default_goal()
        record = gcc.encode_goal_contract(goal)
        decoded = gcc.decode_goal_contract(record)
        assert decoded == goal

    def test_populated_goal_round_trips(self):
        goal = _populated_goal()
        record = gcc.encode_goal_contract(goal)
        decoded = gcc.decode_goal_contract(record)
        assert decoded == goal

    def test_round_trip_preserves_every_scalar_field(self):
        goal = contracts.GoalContract(
            goal_id="G-scalar",
            desired_end_state="explicit end state",
            status="awaiting_user",
            autonomy_budget=42,
            created_at=1_700_000_001,
            updated_at=1_700_000_002,
        )
        decoded = gcc.decode_goal_contract(gcc.encode_goal_contract(goal))
        assert decoded.goal_id == "G-scalar"
        assert decoded.desired_end_state == "explicit end state"
        assert decoded.status == "awaiting_user"
        assert decoded.autonomy_budget == 42
        assert decoded.created_at == 1_700_000_001
        assert decoded.updated_at == 1_700_000_002

    def test_round_trip_preserves_tuple_field_order(self):
        # The tuple ordering is the planner's authoring order — the
        # codec must NOT sort or normalize element order.
        goal = _default_goal(
            continuation_rules=("z", "a", "m"),
            stop_conditions=("z", "a", "m"),
            escalation_boundaries=("z", "a", "m"),
            user_decision_boundaries=("z", "a", "m"),
        )
        decoded = gcc.decode_goal_contract(gcc.encode_goal_contract(goal))
        assert decoded.continuation_rules == ("z", "a", "m")
        assert decoded.stop_conditions == ("z", "a", "m")
        assert decoded.escalation_boundaries == ("z", "a", "m")
        assert decoded.user_decision_boundaries == ("z", "a", "m")

    def test_empty_tuples_round_trip_cleanly(self):
        goal = _default_goal()
        # All four tuple fields default to ().
        assert goal.continuation_rules == ()
        decoded = gcc.decode_goal_contract(gcc.encode_goal_contract(goal))
        assert decoded.continuation_rules == ()
        assert decoded.stop_conditions == ()
        assert decoded.escalation_boundaries == ()
        assert decoded.user_decision_boundaries == ()

    @pytest.mark.parametrize(
        "status", ["active", "awaiting_user", "complete", "blocked_external"]
    )
    def test_round_trip_for_every_legal_status(self, status):
        goal = _default_goal(status=status)
        decoded = gcc.decode_goal_contract(gcc.encode_goal_contract(goal))
        assert decoded.status == status

    def test_unicode_strings_round_trip(self):
        goal = _default_goal(
            continuation_rules=("café", "naïve", "résumé"),
            stop_conditions=("日本語", "中文", "한국어"),
        )
        decoded = gcc.decode_goal_contract(gcc.encode_goal_contract(goal))
        assert decoded.continuation_rules == ("café", "naïve", "résumé")
        assert decoded.stop_conditions == ("日本語", "中文", "한국어")


# ---------------------------------------------------------------------------
# 2. Deterministic JSON policy
# ---------------------------------------------------------------------------


class TestDeterministicJsonPolicy:
    def test_empty_tuple_encodes_to_literal_brackets(self):
        record = gcc.encode_goal_contract(_default_goal())
        # All four tuple fields are empty in the default goal.
        assert record.continuation_rules_json == "[]"
        assert record.stop_conditions_json == "[]"
        assert record.escalation_boundaries_json == "[]"
        assert record.user_decision_boundaries_json == "[]"

    def test_single_element_uses_compact_separators(self):
        goal = _default_goal(continuation_rules=("only",))
        record = gcc.encode_goal_contract(goal)
        assert record.continuation_rules_json == '["only"]'

    def test_multi_element_uses_compact_separators_no_whitespace(self):
        goal = _default_goal(stop_conditions=("a", "b", "c"))
        record = gcc.encode_goal_contract(goal)
        # Compact separators: "," not ", " and ":" not ": ".
        assert record.stop_conditions_json == '["a","b","c"]'
        assert ", " not in record.stop_conditions_json

    def test_codec_does_not_sort_elements(self):
        # If the codec sorted, "z","a","m" would become ["a","m","z"]
        # — pinning the verbatim order proves it does not.
        goal = _default_goal(escalation_boundaries=("z", "a", "m"))
        record = gcc.encode_goal_contract(goal)
        assert record.escalation_boundaries_json == '["z","a","m"]'

    def test_byte_determinism_across_repeated_encodes(self):
        goal = _populated_goal()
        a = gcc.encode_goal_contract(goal)
        b = gcc.encode_goal_contract(goal)
        # Every JSON field must be byte-identical.
        assert a.continuation_rules_json == b.continuation_rules_json
        assert a.stop_conditions_json == b.stop_conditions_json
        assert a.escalation_boundaries_json == b.escalation_boundaries_json
        assert a.user_decision_boundaries_json == b.user_decision_boundaries_json

    def test_unicode_is_not_ascii_escaped(self):
        # ensure_ascii=False means non-ASCII content stays in the
        # output as-is (rather than being escaped to \uXXXX).
        goal = _default_goal(continuation_rules=("café",))
        record = gcc.encode_goal_contract(goal)
        assert "café" in record.continuation_rules_json
        assert "\\u" not in record.continuation_rules_json

    def test_json_is_parseable_with_stdlib(self):
        goal = _populated_goal()
        record = gcc.encode_goal_contract(goal)
        for field in (
            "continuation_rules_json",
            "stop_conditions_json",
            "escalation_boundaries_json",
            "user_decision_boundaries_json",
        ):
            value = json.loads(getattr(record, field))
            assert isinstance(value, list)
            for elem in value:
                assert isinstance(elem, str)


# ---------------------------------------------------------------------------
# 3. Encode validation
# ---------------------------------------------------------------------------


class TestEncodeValidation:
    def test_non_goal_contract_input_rejected(self):
        with pytest.raises(ValueError, match="GoalContract"):
            gcc.encode_goal_contract("not a goal")  # type: ignore[arg-type]

    def test_none_input_rejected(self):
        with pytest.raises(ValueError, match="GoalContract"):
            gcc.encode_goal_contract(None)  # type: ignore[arg-type]

    def test_dict_input_rejected(self):
        with pytest.raises(ValueError, match="GoalContract"):
            gcc.encode_goal_contract({"goal_id": "G-1"})  # type: ignore[arg-type]

    def test_record_input_rejected(self):
        # GoalRecord is the persistence shape, not the contract — the
        # encoder must refuse it explicitly rather than silently
        # treating it as a contract.
        record = dwr.GoalRecord(
            goal_id="G-rec",
            desired_end_state="state",
            status="active",
        )
        with pytest.raises(ValueError, match="GoalContract"):
            gcc.encode_goal_contract(record)  # type: ignore[arg-type]

    @pytest.mark.parametrize(
        "field",
        [
            "continuation_rules",
            "stop_conditions",
            "escalation_boundaries",
            "user_decision_boundaries",
        ],
    )
    def test_non_string_tuple_element_rejected(self, field):
        # Build a contract via dataclasses.replace so we can sneak in
        # a non-string element. ``contracts.GoalContract`` does not
        # validate tuple element types, so the codec is the gate.
        import dataclasses

        base = _default_goal()
        bad = dataclasses.replace(base, **{field: ("ok", 42, "also-ok")})
        with pytest.raises(ValueError, match=field):
            gcc.encode_goal_contract(bad)

    @pytest.mark.parametrize(
        "field",
        [
            "continuation_rules",
            "stop_conditions",
            "escalation_boundaries",
            "user_decision_boundaries",
        ],
    )
    def test_none_tuple_element_rejected(self, field):
        import dataclasses

        base = _default_goal()
        bad = dataclasses.replace(base, **{field: ("first", None)})
        with pytest.raises(ValueError, match=field):
            gcc.encode_goal_contract(bad)

    @pytest.mark.parametrize(
        "field",
        [
            "continuation_rules",
            "stop_conditions",
            "escalation_boundaries",
            "user_decision_boundaries",
        ],
    )
    def test_non_tuple_field_rejected(self, field):
        # If somebody hands the encoder a list instead of a tuple,
        # the codec must refuse — the contract dataclass is typed as
        # tuple, and accepting a list would silently widen the
        # contract.
        import dataclasses

        base = _default_goal()
        bad = dataclasses.replace(base, **{field: ["a", "b"]})  # list, not tuple
        with pytest.raises(ValueError, match=field):
            gcc.encode_goal_contract(bad)


# ---------------------------------------------------------------------------
# 4. Decode validation
# ---------------------------------------------------------------------------


class TestDecodeValidation:
    def test_non_goal_record_input_rejected(self):
        with pytest.raises(ValueError, match="GoalRecord"):
            gcc.decode_goal_contract("not a record")  # type: ignore[arg-type]

    def test_none_input_rejected(self):
        with pytest.raises(ValueError, match="GoalRecord"):
            gcc.decode_goal_contract(None)  # type: ignore[arg-type]

    def test_contract_input_rejected(self):
        # Symmetric with the encoder — handing a contract to the
        # decoder is a caller bug and must surface clearly.
        with pytest.raises(ValueError, match="GoalRecord"):
            gcc.decode_goal_contract(_default_goal())  # type: ignore[arg-type]

    @pytest.mark.parametrize(
        "field",
        [
            "continuation_rules_json",
            "stop_conditions_json",
            "escalation_boundaries_json",
            "user_decision_boundaries_json",
        ],
    )
    def test_malformed_json_rejected(self, field):
        import dataclasses

        # Start with a valid record, then corrupt one JSON field.
        base = gcc.encode_goal_contract(_default_goal())
        bad = dataclasses.replace(base, **{field: "{not valid json"})
        with pytest.raises(ValueError, match=field):
            gcc.decode_goal_contract(bad)

    @pytest.mark.parametrize(
        "field",
        [
            "continuation_rules_json",
            "stop_conditions_json",
            "escalation_boundaries_json",
            "user_decision_boundaries_json",
        ],
    )
    def test_dict_top_level_json_rejected(self, field):
        import dataclasses

        base = gcc.encode_goal_contract(_default_goal())
        bad = dataclasses.replace(base, **{field: '{"key":"value"}'})
        with pytest.raises(ValueError, match="JSON list"):
            gcc.decode_goal_contract(bad)

    @pytest.mark.parametrize(
        "field",
        [
            "continuation_rules_json",
            "stop_conditions_json",
            "escalation_boundaries_json",
            "user_decision_boundaries_json",
        ],
    )
    def test_scalar_top_level_json_rejected(self, field):
        import dataclasses

        base = gcc.encode_goal_contract(_default_goal())
        bad = dataclasses.replace(base, **{field: '"a string"'})
        with pytest.raises(ValueError, match="JSON list"):
            gcc.decode_goal_contract(bad)

    @pytest.mark.parametrize(
        "field",
        [
            "continuation_rules_json",
            "stop_conditions_json",
            "escalation_boundaries_json",
            "user_decision_boundaries_json",
        ],
    )
    def test_null_top_level_json_rejected(self, field):
        import dataclasses

        base = gcc.encode_goal_contract(_default_goal())
        bad = dataclasses.replace(base, **{field: "null"})
        with pytest.raises(ValueError, match="JSON list"):
            gcc.decode_goal_contract(bad)

    @pytest.mark.parametrize(
        "field",
        [
            "continuation_rules_json",
            "stop_conditions_json",
            "escalation_boundaries_json",
            "user_decision_boundaries_json",
        ],
    )
    def test_non_string_list_element_rejected(self, field):
        import dataclasses

        base = gcc.encode_goal_contract(_default_goal())
        bad = dataclasses.replace(base, **{field: '["ok", 42, "also-ok"]'})
        with pytest.raises(ValueError, match=field):
            gcc.decode_goal_contract(bad)

    @pytest.mark.parametrize(
        "field",
        [
            "continuation_rules_json",
            "stop_conditions_json",
            "escalation_boundaries_json",
            "user_decision_boundaries_json",
        ],
    )
    def test_nested_list_element_rejected(self, field):
        import dataclasses

        base = gcc.encode_goal_contract(_default_goal())
        bad = dataclasses.replace(base, **{field: '[["nested"]]'})
        with pytest.raises(ValueError, match=field):
            gcc.decode_goal_contract(bad)


# ---------------------------------------------------------------------------
# 5. Status validation flows through dataclasses
# ---------------------------------------------------------------------------


class TestStatusValidation:
    def test_unknown_status_rejected_at_contract_construction(self):
        # ``contracts.GoalContract`` itself rejects unknown statuses,
        # so the codec inherits the validation. This pins that the
        # codec does not silently widen the status space.
        with pytest.raises(ValueError, match="goal status"):
            _default_goal(status="banana")

    def test_unknown_status_in_record_rejected_on_decode(self):
        # If somebody manages to forge a GoalRecord with an unknown
        # status (e.g. via direct SQLite insert), the decoder must
        # surface the error rather than silently producing a
        # contract with a status the contract layer would reject.
        # GoalRecord itself rejects unknown statuses at construction
        # time too — confirming the validation chain is intact.
        with pytest.raises(ValueError, match="goal status"):
            dwr.GoalRecord(
                goal_id="G-bad",
                desired_end_state="state",
                status="banana",
            )


# ---------------------------------------------------------------------------
# 6. Persistence-layer integration smoke
# ---------------------------------------------------------------------------


class TestPersistenceIntegration:
    """End-to-end smoke: contract → record → SQLite → record → contract."""

    def test_full_round_trip_through_sqlite(self):
        import sqlite3

        from runtime.schemas import ensure_schema

        conn = sqlite3.connect(":memory:")
        conn.row_factory = sqlite3.Row
        ensure_schema(conn)
        try:
            goal = _populated_goal()
            record = gcc.encode_goal_contract(goal)
            dwr.insert_goal(conn, record)

            fetched = dwr.get_goal(conn, "G-FULL")
            assert fetched is not None

            decoded = gcc.decode_goal_contract(fetched)
            # The contract round-trips through SQLite byte-for-byte
            # in every field that the contract and record both own.
            assert decoded.goal_id == goal.goal_id
            assert decoded.desired_end_state == goal.desired_end_state
            assert decoded.status == goal.status
            assert decoded.autonomy_budget == goal.autonomy_budget
            assert decoded.continuation_rules == goal.continuation_rules
            assert decoded.stop_conditions == goal.stop_conditions
            assert decoded.escalation_boundaries == goal.escalation_boundaries
            assert (
                decoded.user_decision_boundaries
                == goal.user_decision_boundaries
            )
            # Timestamps will have been backfilled by insert_goal,
            # so they may differ from the encoded record's
            # caller-supplied values — assert they are non-zero
            # rather than equal to the input.
            assert decoded.created_at > 0
            assert decoded.updated_at > 0
        finally:
            conn.close()


# ---------------------------------------------------------------------------
# 7. Shadow-only discipline
# ---------------------------------------------------------------------------


class TestShadowOnlyDiscipline:
    def test_codec_only_imports_permitted_shadow_modules(self):
        imported = _imported_module_names(gcc)
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
                f"goal_contract_codec.py has unexpected runtime.core import: "
                f"{name!r}"
            )

    def test_codec_has_no_live_routing_imports(self):
        imported = _imported_module_names(gcc)
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
                    f"goal_contract_codec.py imports {name!r} containing "
                    f"forbidden token {needle!r}"
                )

    def test_codec_does_not_import_subprocess_or_filesystem(self):
        imported = _imported_module_names(gcc)
        # Pure codec — no subprocess, no filesystem walking, no
        # SQLite. The persistence helpers do all the I/O.
        assert "subprocess" not in imported
        assert "sqlite3" not in imported
        for name in imported:
            assert "pathlib" not in name
            assert "os.walk" not in name

    def test_live_modules_do_not_import_codec(self):
        import runtime.core.completions as completions
        import runtime.core.dispatch_engine as dispatch_engine
        import runtime.core.policy_engine as policy_engine

        for mod in (dispatch_engine, completions, policy_engine):
            imported = _imported_module_names(mod)
            for name in imported:
                assert "goal_contract_codec" not in name, (
                    f"{mod.__name__} imports {name!r} — goal_contract_codec "
                    f"must stay shadow-only this slice"
                )

    def test_cli_does_not_import_codec(self):
        import runtime.cli as cli

        imported = _imported_module_names(cli)
        for name in imported:
            assert "goal_contract_codec" not in name, (
                f"cli.py imports {name!r} — goal_contract_codec must not be "
                f"wired into the CLI this slice"
            )

    def test_prompt_pack_does_not_import_codec(self):
        # The prompt-pack compiler module must not depend on the
        # codec yet — workflow capture is a later slice.
        from runtime.core import prompt_pack as pp

        imported = _imported_module_names(pp)
        for name in imported:
            assert "goal_contract_codec" not in name, (
                f"prompt_pack.py imports {name!r} — goal_contract_codec "
                f"must not be wired into the compiler this slice"
            )

    def test_decision_work_registry_does_not_import_codec(self):
        # Reverse dep guard: the persistence module owns the record
        # and must not depend on a specific codec.
        imported = _imported_module_names(dwr)
        for name in imported:
            assert "goal_contract_codec" not in name

    def test_contracts_does_not_import_codec(self):
        imported = _imported_module_names(contracts)
        for name in imported:
            assert "goal_contract_codec" not in name
