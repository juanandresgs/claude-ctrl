"""Tests for runtime/core/workflow_contract_capture.py.

@decision DEC-CLAUDEX-WORKFLOW-CONTRACT-CAPTURE-TESTS-001
Title: Pure workflow-contract capture helper — deterministic chain, cross-check, error ordering, read-only, shadow-only discipline pinned
Status: proposed (shadow-mode, Phase 2 prompt-pack workflow-contract bridge)
Rationale: The capture helper is the read-only chain between the
  two persistence rows and the two typed contracts. Its correctness
  is almost entirely delegated to the four underlying helpers, but
  the chaining contract it advertises must be mechanically
  asserted:

    1. Happy-path: goal + work item inserted → helper returns the
       typed tuple with every field preserved.
    2. Missing goal → ``LookupError`` naming ``goal_id``.
    3. Missing work item → ``LookupError`` naming ``work_item_id``.
    4. Goal-id cross-check: work-item record's ``goal_id`` must
       match caller's ``goal_id`` or ``ValueError`` is raised.
    5. Error ordering: missing goal is reported before missing
       work item; missing work item is reported before the cross-
       check mismatch. A single pin for each transition so future
       reshuffling is a deliberate decision.
    6. Returned objects are exactly ``contracts.GoalContract`` and
       ``contracts.WorkItemContract`` — not dicts, not records,
       not a custom dataclass.
    7. Read-only guarantee: ``conn.total_changes`` is unchanged
       across the call; ``conn.in_transaction`` stays ``False``.
    8. Corrupt persisted rows surface the underlying codec's
       ``ValueError`` verbatim — the capture helper does not
       swallow decoder errors.
    9. Shadow-only discipline via AST: the module imports only
       stdlib + contracts + decision_work_registry + the two
       codec modules; no live-routing or CLI module imports it.
"""

from __future__ import annotations

import ast
import inspect
import sqlite3

import pytest

from runtime.core import contracts
from runtime.core import decision_work_registry as dwr
from runtime.core import goal_contract_codec
from runtime.core import work_item_contract_codec
from runtime.core import workflow_contract_capture as wcap
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
# Fixtures + seeding helpers
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


def _make_goal(
    *,
    goal_id: str = "G-CAP-1",
    desired_end_state: str = "ship the capture helper",
    continuation_rules: tuple = ("rule-a",),
    stop_conditions: tuple = ("cond-a",),
    escalation_boundaries: tuple = ("boundary-a",),
    user_decision_boundaries: tuple = ("udb-a",),
    autonomy_budget: int = 3,
) -> contracts.GoalContract:
    return contracts.GoalContract(
        goal_id=goal_id,
        desired_end_state=desired_end_state,
        status="active",
        autonomy_budget=autonomy_budget,
        continuation_rules=continuation_rules,
        stop_conditions=stop_conditions,
        escalation_boundaries=escalation_boundaries,
        user_decision_boundaries=user_decision_boundaries,
    )


def _seed_goal(conn, goal: contracts.GoalContract) -> dwr.GoalRecord:
    record = goal_contract_codec.encode_goal_contract(goal)
    return dwr.insert_goal(conn, record)


def _seed_work_item_record(
    conn,
    *,
    work_item_id: str = "WI-CAP-1",
    goal_id: str = "G-CAP-1",
    title: str = "capture slice",
    status: str = "in_progress",
    reviewer_round: int = 2,
    head_sha: str | None = "abcd1234",
    scope_json: str = '{"allowed_paths":["runtime/"]}',
    evaluation_json: str = '{"required_tests":["pytest tests/runtime/"]}',
) -> dwr.WorkItemRecord:
    record = dwr.WorkItemRecord(
        work_item_id=work_item_id,
        goal_id=goal_id,
        title=title,
        status=status,
        version=1,
        author="planner",
        scope_json=scope_json,
        evaluation_json=evaluation_json,
        head_sha=head_sha,
        reviewer_round=reviewer_round,
    )
    return dwr.insert_work_item(conn, record)


# ---------------------------------------------------------------------------
# 1. Happy-path capture
# ---------------------------------------------------------------------------


class TestHappyPath:
    def test_returns_tuple_of_typed_contracts(self, conn):
        _seed_goal(conn, _make_goal())
        _seed_work_item_record(conn)

        result = wcap.capture_workflow_contracts(
            conn, goal_id="G-CAP-1", work_item_id="WI-CAP-1"
        )
        assert isinstance(result, tuple)
        assert len(result) == 2

    def test_first_element_is_goal_contract(self, conn):
        _seed_goal(conn, _make_goal())
        _seed_work_item_record(conn)
        goal, _ = wcap.capture_workflow_contracts(
            conn, goal_id="G-CAP-1", work_item_id="WI-CAP-1"
        )
        assert isinstance(goal, contracts.GoalContract)

    def test_second_element_is_work_item_contract(self, conn):
        _seed_goal(conn, _make_goal())
        _seed_work_item_record(conn)
        _, work_item = wcap.capture_workflow_contracts(
            conn, goal_id="G-CAP-1", work_item_id="WI-CAP-1"
        )
        assert isinstance(work_item, contracts.WorkItemContract)

    def test_goal_contract_fields_preserved(self, conn):
        seeded_goal = _make_goal(
            desired_end_state="deterministic end state",
            continuation_rules=("r1", "r2"),
            stop_conditions=("s1",),
            autonomy_budget=7,
        )
        _seed_goal(conn, seeded_goal)
        _seed_work_item_record(conn)

        captured_goal, _ = wcap.capture_workflow_contracts(
            conn, goal_id="G-CAP-1", work_item_id="WI-CAP-1"
        )
        assert captured_goal.goal_id == "G-CAP-1"
        assert captured_goal.desired_end_state == "deterministic end state"
        assert captured_goal.status == "active"
        assert captured_goal.autonomy_budget == 7
        assert captured_goal.continuation_rules == ("r1", "r2")
        assert captured_goal.stop_conditions == ("s1",)

    def test_work_item_contract_fields_preserved(self, conn):
        _seed_goal(conn, _make_goal())
        _seed_work_item_record(
            conn,
            work_item_id="WI-populated",
            status="in_review",
            reviewer_round=5,
            head_sha="deadbeef",
            scope_json=(
                '{"allowed_paths":["a","b"],'
                '"required_paths":["c"],'
                '"forbidden_paths":["d"],'
                '"state_domains":["e"]}'
            ),
            evaluation_json=(
                '{"required_tests":["t"],'
                '"required_evidence":["ev"],'
                '"rollback_boundary":"rb",'
                '"acceptance_notes":"an"}'
            ),
        )

        _, work_item = wcap.capture_workflow_contracts(
            conn, goal_id="G-CAP-1", work_item_id="WI-populated"
        )
        assert work_item.work_item_id == "WI-populated"
        assert work_item.goal_id == "G-CAP-1"
        assert work_item.title == "capture slice"
        assert work_item.status == "in_review"
        assert work_item.reviewer_round == 5
        assert work_item.head_sha == "deadbeef"
        assert work_item.scope.allowed_paths == ("a", "b")
        assert work_item.scope.required_paths == ("c",)
        assert work_item.scope.forbidden_paths == ("d",)
        assert work_item.scope.state_domains == ("e",)
        assert work_item.evaluation.required_tests == ("t",)
        assert work_item.evaluation.required_evidence == ("ev",)
        assert work_item.evaluation.rollback_boundary == "rb"
        assert work_item.evaluation.acceptance_notes == "an"

    def test_default_payloads_round_trip(self, conn):
        # Empty "{}" JSON fields must decode to empty subcontracts
        # — pinning the legacy-compatible path end-to-end.
        _seed_goal(conn, _make_goal())
        _seed_work_item_record(
            conn,
            work_item_id="WI-empty",
            scope_json="{}",
            evaluation_json="{}",
        )
        _, work_item = wcap.capture_workflow_contracts(
            conn, goal_id="G-CAP-1", work_item_id="WI-empty"
        )
        assert work_item.scope == contracts.ScopeManifest()
        assert work_item.evaluation == contracts.EvaluationContract()

    def test_deterministic_for_repeated_calls(self, conn):
        _seed_goal(conn, _make_goal())
        _seed_work_item_record(conn)
        a = wcap.capture_workflow_contracts(
            conn, goal_id="G-CAP-1", work_item_id="WI-CAP-1"
        )
        b = wcap.capture_workflow_contracts(
            conn, goal_id="G-CAP-1", work_item_id="WI-CAP-1"
        )
        assert a == b


# ---------------------------------------------------------------------------
# 2. Missing goal
# ---------------------------------------------------------------------------


class TestMissingGoal:
    def test_missing_goal_raises_lookup_error(self, conn):
        _seed_work_item_record(conn)  # work item exists but no goal
        with pytest.raises(LookupError):
            wcap.capture_workflow_contracts(
                conn, goal_id="G-ghost", work_item_id="WI-CAP-1"
            )

    def test_missing_goal_error_names_goal_id(self, conn):
        _seed_work_item_record(conn)
        with pytest.raises(LookupError, match="G-ghost"):
            wcap.capture_workflow_contracts(
                conn, goal_id="G-ghost", work_item_id="WI-CAP-1"
            )

    def test_missing_goal_error_mentions_goal_id_label(self, conn):
        # The message uses the exact key "goal_id" so the caller
        # can distinguish it from the work-item lookup error.
        _seed_work_item_record(conn)
        with pytest.raises(LookupError, match="goal_id"):
            wcap.capture_workflow_contracts(
                conn, goal_id="G-ghost", work_item_id="WI-CAP-1"
            )

    def test_empty_database_missing_goal_raises_lookup_error(self, conn):
        # Neither row exists; the goal check runs first, so the
        # goal_id is in the message (not work_item_id).
        with pytest.raises(LookupError, match="goal_id"):
            wcap.capture_workflow_contracts(
                conn, goal_id="G-A", work_item_id="WI-A"
            )


# ---------------------------------------------------------------------------
# 3. Missing work item
# ---------------------------------------------------------------------------


class TestMissingWorkItem:
    def test_missing_work_item_raises_lookup_error(self, conn):
        _seed_goal(conn, _make_goal())
        with pytest.raises(LookupError):
            wcap.capture_workflow_contracts(
                conn, goal_id="G-CAP-1", work_item_id="WI-ghost"
            )

    def test_missing_work_item_error_names_work_item_id(self, conn):
        _seed_goal(conn, _make_goal())
        with pytest.raises(LookupError, match="WI-ghost"):
            wcap.capture_workflow_contracts(
                conn, goal_id="G-CAP-1", work_item_id="WI-ghost"
            )

    def test_missing_work_item_error_mentions_work_item_id_label(self, conn):
        _seed_goal(conn, _make_goal())
        with pytest.raises(LookupError, match="work_item_id"):
            wcap.capture_workflow_contracts(
                conn, goal_id="G-CAP-1", work_item_id="WI-ghost"
            )


# ---------------------------------------------------------------------------
# 4. Goal-id cross-check
# ---------------------------------------------------------------------------


class TestGoalIdCrossCheck:
    def test_mismatched_goal_id_raises_value_error(self, conn):
        # Seed TWO goals and a work item whose goal_id points at
        # the wrong one. Capture with the caller-supplied goal_id
        # of the FIRST goal → must raise because the work item's
        # goal_id column names the second goal.
        _seed_goal(conn, _make_goal(goal_id="G-caller"))
        _seed_goal(
            conn,
            _make_goal(
                goal_id="G-wrong",
                desired_end_state="mismatch target",
            ),
        )
        _seed_work_item_record(
            conn,
            work_item_id="WI-mismatch",
            goal_id="G-wrong",  # work item belongs to G-wrong
        )
        with pytest.raises(ValueError):
            wcap.capture_workflow_contracts(
                conn, goal_id="G-caller", work_item_id="WI-mismatch"
            )

    def test_mismatch_error_names_both_ids(self, conn):
        _seed_goal(conn, _make_goal(goal_id="G-caller"))
        _seed_goal(
            conn,
            _make_goal(
                goal_id="G-wrong",
                desired_end_state="mismatch target",
            ),
        )
        _seed_work_item_record(
            conn,
            work_item_id="WI-mismatch",
            goal_id="G-wrong",
        )
        with pytest.raises(ValueError) as exc_info:
            wcap.capture_workflow_contracts(
                conn, goal_id="G-caller", work_item_id="WI-mismatch"
            )
        msg = str(exc_info.value)
        assert "G-caller" in msg
        assert "G-wrong" in msg

    def test_mismatch_error_is_value_error_not_lookup_error(self, conn):
        # ValueError and LookupError are deliberately distinct so
        # callers can branch. Pin the distinction.
        _seed_goal(conn, _make_goal(goal_id="G-caller"))
        _seed_goal(conn, _make_goal(goal_id="G-wrong"))
        _seed_work_item_record(
            conn, work_item_id="WI-mismatch", goal_id="G-wrong"
        )
        with pytest.raises(ValueError):
            wcap.capture_workflow_contracts(
                conn, goal_id="G-caller", work_item_id="WI-mismatch"
            )
        # And confirm it's NOT a LookupError subclass.
        try:
            wcap.capture_workflow_contracts(
                conn, goal_id="G-caller", work_item_id="WI-mismatch"
            )
        except ValueError as exc:
            assert not isinstance(exc, LookupError)

    def test_matching_goal_id_succeeds(self, conn):
        # Sanity: correct caller goal_id → happy-path, no error.
        _seed_goal(conn, _make_goal(goal_id="G-match"))
        _seed_work_item_record(
            conn, work_item_id="WI-match", goal_id="G-match"
        )
        goal, work_item = wcap.capture_workflow_contracts(
            conn, goal_id="G-match", work_item_id="WI-match"
        )
        assert goal.goal_id == "G-match"
        assert work_item.goal_id == "G-match"


# ---------------------------------------------------------------------------
# 5. Error ordering
# ---------------------------------------------------------------------------


class TestErrorOrdering:
    def test_missing_goal_checked_before_missing_work_item(self, conn):
        # Neither row present → the goal check runs first, so the
        # error mentions goal_id rather than work_item_id.
        with pytest.raises(LookupError) as exc_info:
            wcap.capture_workflow_contracts(
                conn, goal_id="G-A", work_item_id="WI-A"
            )
        msg = str(exc_info.value)
        assert "goal_id" in msg
        assert "G-A" in msg

    def test_missing_work_item_checked_before_cross_check(self, conn):
        # Goal present, work item missing → LookupError for the
        # work item, not a ValueError for a cross-check that can't
        # run because one side doesn't exist.
        _seed_goal(conn, _make_goal())
        with pytest.raises(LookupError) as exc_info:
            wcap.capture_workflow_contracts(
                conn, goal_id="G-CAP-1", work_item_id="WI-ghost"
            )
        # Confirm it's a LookupError, NOT a ValueError for mismatch.
        assert not isinstance(exc_info.value, ValueError)


# ---------------------------------------------------------------------------
# 6. Read-only guarantee
# ---------------------------------------------------------------------------


class TestReadOnly:
    def test_capture_performs_no_writes(self, conn):
        _seed_goal(conn, _make_goal())
        _seed_work_item_record(conn)

        before = conn.total_changes
        wcap.capture_workflow_contracts(
            conn, goal_id="G-CAP-1", work_item_id="WI-CAP-1"
        )
        after = conn.total_changes
        assert after == before, (
            f"capture_workflow_contracts is not read-only; "
            f"total_changes went from {before} to {after}"
        )

    def test_capture_does_not_open_a_transaction(self, conn):
        _seed_goal(conn, _make_goal())
        _seed_work_item_record(conn)

        assert conn.in_transaction is False
        wcap.capture_workflow_contracts(
            conn, goal_id="G-CAP-1", work_item_id="WI-CAP-1"
        )
        assert conn.in_transaction is False

    def test_missing_row_path_also_read_only(self, conn):
        # The error paths must also be read-only — a failed
        # lookup cannot silently upsert a sentinel row.
        before = conn.total_changes
        with pytest.raises(LookupError):
            wcap.capture_workflow_contracts(
                conn, goal_id="G-ghost", work_item_id="WI-ghost"
            )
        after = conn.total_changes
        assert after == before


# ---------------------------------------------------------------------------
# 7. Corrupt row pass-through
# ---------------------------------------------------------------------------


class TestCorruptRowPassThrough:
    def test_malformed_scope_json_surfaces_value_error(self, conn):
        # The capture helper must NOT swallow decoder errors.
        _seed_goal(conn, _make_goal())
        _seed_work_item_record(
            conn,
            work_item_id="WI-corrupt",
            scope_json='{"allowed_paths":',  # truncated
        )
        with pytest.raises(ValueError, match="scope_json"):
            wcap.capture_workflow_contracts(
                conn, goal_id="G-CAP-1", work_item_id="WI-corrupt"
            )

    def test_malformed_evaluation_json_surfaces_value_error(self, conn):
        _seed_goal(conn, _make_goal())
        _seed_work_item_record(
            conn,
            work_item_id="WI-corrupt-eval",
            evaluation_json='{"required_tests":',  # truncated
        )
        with pytest.raises(ValueError, match="evaluation_json"):
            wcap.capture_workflow_contracts(
                conn, goal_id="G-CAP-1", work_item_id="WI-corrupt-eval"
            )

    def test_unknown_scope_key_surfaces_value_error(self, conn):
        _seed_goal(conn, _make_goal())
        _seed_work_item_record(
            conn,
            work_item_id="WI-rogue",
            scope_json='{"rogue_key":"x"}',
        )
        with pytest.raises(ValueError, match="rogue_key"):
            wcap.capture_workflow_contracts(
                conn, goal_id="G-CAP-1", work_item_id="WI-rogue"
            )


# ---------------------------------------------------------------------------
# 8. Shadow-only discipline
# ---------------------------------------------------------------------------


class TestShadowOnlyDiscipline:
    def test_module_only_imports_permitted_shadow_modules(self):
        imported = _imported_module_names(wcap)
        runtime_core_imports = {
            n for n in imported if n.startswith("runtime.core")
        }
        permitted_bases = {"runtime.core"}
        permitted_prefixes = (
            "runtime.core.contracts",
            "runtime.core.decision_work_registry",
            "runtime.core.goal_contract_codec",
            "runtime.core.work_item_contract_codec",
        )
        for name in runtime_core_imports:
            assert name in permitted_bases or name.startswith(
                permitted_prefixes
            ), (
                f"workflow_contract_capture.py has unexpected runtime.core "
                f"import: {name!r}"
            )

    def test_module_has_no_live_routing_imports(self):
        imported = _imported_module_names(wcap)
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
                    f"workflow_contract_capture.py imports {name!r} "
                    f"containing forbidden token {needle!r}"
                )

    def test_module_does_not_import_subprocess_or_filesystem(self):
        imported = _imported_module_names(wcap)
        # Pure read-only chain — the caller owns the connection
        # and the persistence helpers issue the SQL.
        assert "subprocess" not in imported
        for name in imported:
            assert "pathlib" not in name
            assert "os.walk" not in name

    def test_cli_imports_capture_helper_only_via_function_scope(self):
        # Architecture invariant after the prompt-pack compile CLI
        # slice (DEC-CLAUDEX-PROMPT-PACK-COMPILE-CLI-001):
        # ``runtime/cli.py`` reaches ``workflow_contract_capture``
        # only via a function-scope import inside the ``compile``
        # branch of ``_handle_prompt_pack``. At module level the
        # CLI must NOT import the capture helper.
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
            assert "workflow_contract_capture" not in name, (
                f"cli.py imports {name!r} at module level — "
                f"workflow_contract_capture may only be reached via "
                f"a function-scope import inside _handle_prompt_pack"
            )

    def test_prompt_pack_imports_capture_helper_only_via_function_scope(self):
        # Architecture invariant after the capstone mode-selection
        # slice (DEC-CLAUDEX-PROMPT-PACK-COMPILE-MODE-SELECTION-001):
        # ``runtime.core.prompt_pack`` imports
        # ``workflow_contract_capture`` deliberately but only via a
        # function-scope import inside ``compile_prompt_pack_for_stage``'s
        # id-mode branch. The reverse-dependency guard therefore
        # allows the name to appear, but only inside a function body
        # — not at module level — so the capture helper cannot be
        # silently promoted to an always-loaded compiler dependency.
        from runtime.core import prompt_pack as pp

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
            assert "workflow_contract_capture" not in name, (
                f"prompt_pack.py imports {name!r} at module level — "
                f"workflow_contract_capture may only be reached via "
                f"the function-scope import inside "
                f"compile_prompt_pack_for_stage"
            )

    def test_dispatch_engine_does_not_import_capture_helper(self):
        import runtime.core.dispatch_engine as dispatch_engine

        imported = _imported_module_names(dispatch_engine)
        for name in imported:
            assert "workflow_contract_capture" not in name

    def test_completions_does_not_import_capture_helper(self):
        import runtime.core.completions as completions

        imported = _imported_module_names(completions)
        for name in imported:
            assert "workflow_contract_capture" not in name

    def test_policy_engine_does_not_import_capture_helper(self):
        import runtime.core.policy_engine as policy_engine

        imported = _imported_module_names(policy_engine)
        for name in imported:
            assert "workflow_contract_capture" not in name

    def test_decision_work_registry_does_not_import_capture_helper(self):
        # Reverse dep guard: the registry must not depend on a
        # higher-level consumer.
        imported = _imported_module_names(dwr)
        for name in imported:
            assert "workflow_contract_capture" not in name

    def test_goal_contract_codec_does_not_import_capture_helper(self):
        # The two codec modules must remain independent of the
        # consumer that chains them.
        imported = _imported_module_names(goal_contract_codec)
        for name in imported:
            assert "workflow_contract_capture" not in name

    def test_work_item_contract_codec_does_not_import_capture_helper(self):
        imported = _imported_module_names(work_item_contract_codec)
        for name in imported:
            assert "workflow_contract_capture" not in name

    def test_contracts_does_not_import_capture_helper(self):
        imported = _imported_module_names(contracts)
        for name in imported:
            assert "workflow_contract_capture" not in name
