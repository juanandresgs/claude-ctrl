"""Tests for runtime/core/prompt_pack_decisions.py.

@decision DEC-CLAUDEX-PROMPT-PACK-DECISIONS-TESTS-001
Title: Pure decision-capture helper — exact scope match, deterministic order, read-only, and shadow-only discipline pinned
Status: proposed (shadow-mode, Phase 2 prompt-pack decision capture)
Rationale: The decision-capture helper is a thin canonical
  wrapper over
  :func:`runtime.core.decision_work_registry.list_decisions`. Its
  correctness is almost entirely delegated, but the bootstrap
  contract it advertises must still be mechanically asserted:

    1. Only exact scope matches are returned — no fuzzy file
       matching, no fallback scopes, no inherited domains.
    2. Return type is a tuple (not a list), so the bridge
       boundary is immutable.
    3. The authority module's ``(created_at ASC, decision_id
       ASC)`` canonical order is preserved.
    4. Empty result is an empty tuple, not ``None``.
    5. Empty / whitespace-only / non-string scopes raise
       ``ValueError``.
    6. The helper is read-only: ``conn.total_changes`` is
       unchanged across the call and no write transaction is
       opened.
    7. The captured tuple feeds directly into
       :func:`runtime.core.prompt_pack_resolver.local_decision_summary_from_records`
       without any reshaping.
    8. Shadow-only discipline: the module imports only stdlib
       plus the decision authority module; no live routing
       modules or CLI import it.
"""

from __future__ import annotations

import ast
import inspect
import sqlite3

import pytest

from runtime.core import decision_work_registry as dwr
from runtime.core import prompt_pack_decisions as ppd
from runtime.core import prompt_pack_resolver as ppr
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


def _seed(
    conn,
    *,
    decision_id: str,
    scope: str = "kernel",
    status: str = "accepted",
    created_at: int = 100,
    title: str = "Title",
    rationale: str = "rationale",
    version: int = 1,
    author: str = "planner",
    supersedes: str | None = None,
    superseded_by: str | None = None,
) -> dwr.DecisionRecord:
    record = dwr.DecisionRecord(
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
    return dwr.insert_decision(conn, record)


# ---------------------------------------------------------------------------
# 1. Return type + basic shape
# ---------------------------------------------------------------------------


class TestReturnShape:
    def test_returns_tuple_not_list(self, conn):
        _seed(conn, decision_id="DEC-A", scope="kernel")
        result = ppd.capture_relevant_decisions(conn, scope="kernel")
        assert isinstance(result, tuple)
        assert not isinstance(result, list)

    def test_returns_decision_record_instances(self, conn):
        _seed(conn, decision_id="DEC-A", scope="kernel")
        result = ppd.capture_relevant_decisions(conn, scope="kernel")
        assert all(isinstance(r, dwr.DecisionRecord) for r in result)

    def test_empty_result_is_empty_tuple_not_none(self, conn):
        _seed(conn, decision_id="DEC-A", scope="kernel")
        result = ppd.capture_relevant_decisions(conn, scope="does-not-exist")
        assert result == ()
        assert isinstance(result, tuple)

    def test_database_with_no_decisions_returns_empty_tuple(self, conn):
        # Table is empty entirely.
        result = ppd.capture_relevant_decisions(conn, scope="kernel")
        assert result == ()


# ---------------------------------------------------------------------------
# 2. Exact scope match
# ---------------------------------------------------------------------------


class TestExactScopeMatch:
    def test_only_records_with_matching_scope_returned(self, conn):
        _seed(conn, decision_id="DEC-KERNEL-A", scope="kernel")
        _seed(conn, decision_id="DEC-HOOKS-A", scope="hooks")
        _seed(conn, decision_id="DEC-KERNEL-B", scope="kernel")

        kernel = ppd.capture_relevant_decisions(conn, scope="kernel")
        assert {r.decision_id for r in kernel} == {"DEC-KERNEL-A", "DEC-KERNEL-B"}

    def test_does_not_fuzzy_match_prefix(self, conn):
        # A "kernel-inner" scope must not match "kernel".
        _seed(conn, decision_id="DEC-OUTER", scope="kernel")
        _seed(conn, decision_id="DEC-INNER", scope="kernel-inner")

        kernel = ppd.capture_relevant_decisions(conn, scope="kernel")
        assert [r.decision_id for r in kernel] == ["DEC-OUTER"]

    def test_does_not_fuzzy_match_suffix(self, conn):
        _seed(conn, decision_id="DEC-A", scope="kernel")
        _seed(conn, decision_id="DEC-B", scope="deep/kernel")

        kernel = ppd.capture_relevant_decisions(conn, scope="kernel")
        assert [r.decision_id for r in kernel] == ["DEC-A"]

    def test_case_sensitive_scope_match(self, conn):
        _seed(conn, decision_id="DEC-LOWER", scope="kernel")
        _seed(conn, decision_id="DEC-UPPER", scope="KERNEL")

        lower = ppd.capture_relevant_decisions(conn, scope="kernel")
        upper = ppd.capture_relevant_decisions(conn, scope="KERNEL")
        assert [r.decision_id for r in lower] == ["DEC-LOWER"]
        assert [r.decision_id for r in upper] == ["DEC-UPPER"]

    def test_no_fallback_scope(self, conn):
        # There is no second-chance lookup: an unknown scope
        # returns an empty tuple even when decisions exist under
        # semantically-related scopes.
        _seed(conn, decision_id="DEC-A", scope="runtime")
        _seed(conn, decision_id="DEC-B", scope="runtime.core")

        result = ppd.capture_relevant_decisions(conn, scope="runtime.hooks")
        assert result == ()


# ---------------------------------------------------------------------------
# 3. Deterministic ordering
# ---------------------------------------------------------------------------


class TestDeterministicOrdering:
    def test_ordering_is_by_created_at_ascending(self, conn):
        # Seed out of order; helper should return chronological.
        _seed(conn, decision_id="DEC-LATER", scope="kernel", created_at=300)
        _seed(conn, decision_id="DEC-EARLIER", scope="kernel", created_at=100)
        _seed(conn, decision_id="DEC-MIDDLE", scope="kernel", created_at=200)

        result = ppd.capture_relevant_decisions(conn, scope="kernel")
        assert [r.decision_id for r in result] == [
            "DEC-EARLIER",
            "DEC-MIDDLE",
            "DEC-LATER",
        ]

    def test_tiebreak_on_decision_id_when_created_at_equal(self, conn):
        _seed(conn, decision_id="DEC-Z", scope="kernel", created_at=100)
        _seed(conn, decision_id="DEC-A", scope="kernel", created_at=100)
        _seed(conn, decision_id="DEC-M", scope="kernel", created_at=100)

        result = ppd.capture_relevant_decisions(conn, scope="kernel")
        assert [r.decision_id for r in result] == ["DEC-A", "DEC-M", "DEC-Z"]

    def test_output_independent_of_insertion_order(self, conn):
        order_a = ["DEC-A", "DEC-B", "DEC-C"]
        order_b = ["DEC-C", "DEC-A", "DEC-B"]

        # First arrangement
        conn_1 = sqlite3.connect(":memory:")
        conn_1.row_factory = sqlite3.Row
        ensure_schema(conn_1)
        try:
            for i, did in enumerate(order_a):
                _seed(conn_1, decision_id=did, scope="kernel", created_at=100 + i)
            result_a = ppd.capture_relevant_decisions(conn_1, scope="kernel")
        finally:
            conn_1.close()

        # Second arrangement — same (decision_id, created_at)
        # pairs, different insertion order.
        conn_2 = sqlite3.connect(":memory:")
        conn_2.row_factory = sqlite3.Row
        ensure_schema(conn_2)
        try:
            ids_to_created_at = {
                "DEC-A": 100,
                "DEC-B": 101,
                "DEC-C": 102,
            }
            for did in order_b:
                _seed(
                    conn_2,
                    decision_id=did,
                    scope="kernel",
                    created_at=ids_to_created_at[did],
                )
            result_b = ppd.capture_relevant_decisions(conn_2, scope="kernel")
        finally:
            conn_2.close()

        # Same logical state → identical returned tuples.
        assert [r.decision_id for r in result_a] == [
            r.decision_id for r in result_b
        ]

    def test_identical_repeat_calls_are_equal(self, conn):
        _seed(conn, decision_id="DEC-A", scope="kernel", created_at=100)
        _seed(conn, decision_id="DEC-B", scope="kernel", created_at=200)
        a = ppd.capture_relevant_decisions(conn, scope="kernel")
        b = ppd.capture_relevant_decisions(conn, scope="kernel")
        assert a == b


# ---------------------------------------------------------------------------
# 4. Scope validation
# ---------------------------------------------------------------------------


class TestScopeValidation:
    def test_empty_string_scope_rejected(self, conn):
        with pytest.raises(ValueError, match="non-empty"):
            ppd.capture_relevant_decisions(conn, scope="")

    def test_whitespace_only_scope_rejected(self, conn):
        with pytest.raises(ValueError, match="non-empty"):
            ppd.capture_relevant_decisions(conn, scope="   ")

    def test_tab_only_scope_rejected(self, conn):
        with pytest.raises(ValueError, match="non-empty"):
            ppd.capture_relevant_decisions(conn, scope="\t\n")

    def test_non_string_scope_rejected(self, conn):
        with pytest.raises(ValueError, match="must be a string"):
            ppd.capture_relevant_decisions(
                conn, scope=42  # type: ignore[arg-type]
            )

    def test_none_scope_rejected(self, conn):
        with pytest.raises(ValueError, match="must be a string"):
            ppd.capture_relevant_decisions(
                conn, scope=None  # type: ignore[arg-type]
            )

    def test_list_scope_rejected(self, conn):
        with pytest.raises(ValueError, match="must be a string"):
            ppd.capture_relevant_decisions(
                conn, scope=["kernel"]  # type: ignore[arg-type]
            )


# ---------------------------------------------------------------------------
# 5. Read-only guarantee
# ---------------------------------------------------------------------------


class TestReadOnly:
    def test_capture_performs_no_writes(self, conn):
        _seed(conn, decision_id="DEC-A", scope="kernel")
        _seed(conn, decision_id="DEC-B", scope="kernel")

        before = conn.total_changes
        ppd.capture_relevant_decisions(conn, scope="kernel")
        after = conn.total_changes
        assert after == before, (
            f"capture_relevant_decisions is not read-only; "
            f"total_changes went from {before} to {after}"
        )

    def test_capture_does_not_open_a_transaction(self, conn):
        _seed(conn, decision_id="DEC-A", scope="kernel")
        assert conn.in_transaction is False
        ppd.capture_relevant_decisions(conn, scope="kernel")
        assert conn.in_transaction is False

    def test_capture_does_not_modify_stored_records(self, conn):
        original = _seed(conn, decision_id="DEC-A", scope="kernel")
        ppd.capture_relevant_decisions(conn, scope="kernel")
        fetched = dwr.get_decision(conn, "DEC-A")
        assert fetched == original


# ---------------------------------------------------------------------------
# 6. End-to-end handoff into local_decision_summary_from_records
# ---------------------------------------------------------------------------


class TestEndToEndHandoff:
    def test_captured_tuple_feeds_local_decision_summary_bridge(self, conn):
        _seed(conn, decision_id="DEC-A", scope="kernel", created_at=100)
        _seed(conn, decision_id="DEC-B", scope="kernel", created_at=200)

        records = ppd.capture_relevant_decisions(conn, scope="kernel")
        summary = ppr.local_decision_summary_from_records(decisions=records)
        assert set(summary.relevant_decision_ids) == {"DEC-A", "DEC-B"}

    def test_empty_capture_produces_default_summary(self, conn):
        # No records in the scope → default LocalDecisionSummary.
        records = ppd.capture_relevant_decisions(conn, scope="empty-scope")
        summary = ppr.local_decision_summary_from_records(decisions=records)
        assert summary == ppr.LocalDecisionSummary()

    def test_supersession_chain_flows_through_bridge(self, conn):
        _seed(
            conn,
            decision_id="DEC-OLD",
            scope="kernel",
            status="superseded",
            superseded_by="DEC-NEW",
            created_at=100,
        )
        _seed(
            conn,
            decision_id="DEC-NEW",
            scope="kernel",
            status="accepted",
            supersedes="DEC-OLD",
            created_at=200,
        )

        records = ppd.capture_relevant_decisions(conn, scope="kernel")
        summary = ppr.local_decision_summary_from_records(decisions=records)
        # The bridge surfaces the active head decision.
        assert summary.rationale == "Active head decisions: DEC-NEW"
        assert summary.supersession_notes == ("DEC-NEW supersedes DEC-OLD",)

    def test_captured_order_matches_bridge_canonical_order(self, conn):
        # The bridge normalizes records by (created_at, decision_id)
        # internally. Because the capture helper already produces
        # records in that order, the summary's
        # relevant_decision_ids should be identical to the captured
        # tuple's id sequence.
        _seed(conn, decision_id="DEC-A", scope="kernel", created_at=100)
        _seed(conn, decision_id="DEC-B", scope="kernel", created_at=200)
        _seed(conn, decision_id="DEC-C", scope="kernel", created_at=300)

        records = ppd.capture_relevant_decisions(conn, scope="kernel")
        captured_ids = tuple(r.decision_id for r in records)
        summary = ppr.local_decision_summary_from_records(decisions=records)
        assert summary.relevant_decision_ids == captured_ids


# ---------------------------------------------------------------------------
# 7. Shadow-only discipline
# ---------------------------------------------------------------------------


class TestShadowOnlyDiscipline:
    def test_module_imports_only_permitted_shadow_authority(self):
        imported = _imported_module_names(ppd)
        runtime_core_imports = {
            name for name in imported if name.startswith("runtime.core")
        }
        permitted_bases = {"runtime.core"}
        permitted_prefixes = ("runtime.core.decision_work_registry",)
        for name in runtime_core_imports:
            assert name in permitted_bases or name.startswith(
                permitted_prefixes
            ), (
                f"prompt_pack_decisions.py has unexpected runtime.core "
                f"import: {name!r}"
            )

    def test_no_live_routing_imports(self):
        imported = _imported_module_names(ppd)
        forbidden_substrings = (
            "dispatch_engine",
            "completions",
            "policy_engine",
            "enforcement_config",
            "settings",
            "hooks",
            "runtime.core.policy_utils",
            "runtime.core.leases",
            "runtime.core.workflows",
            "runtime.core.approvals",
        )
        for name in imported:
            for needle in forbidden_substrings:
                assert needle not in name, (
                    f"prompt_pack_decisions.py imports {name!r} containing "
                    f"forbidden token {needle!r}"
                )

    def test_no_subprocess_or_filesystem_imports(self):
        imported = _imported_module_names(ppd)
        assert "subprocess" not in imported
        for name in imported:
            assert "pathlib" not in name
            assert "os.walk" not in name

    def test_live_modules_do_not_import_prompt_pack_decisions(self):
        import runtime.core.completions as completions
        import runtime.core.dispatch_engine as dispatch_engine
        import runtime.core.policy_engine as policy_engine

        for mod in (dispatch_engine, completions, policy_engine):
            imported = _imported_module_names(mod)
            for name in imported:
                assert "prompt_pack_decisions" not in name, (
                    f"{mod.__name__} imports {name!r} — prompt_pack_decisions "
                    f"must stay shadow-only this slice"
                )

    def test_cli_imports_prompt_pack_decisions_only_via_function_scope(self):
        # Architecture invariant after the prompt-pack compile CLI
        # slice (DEC-CLAUDEX-PROMPT-PACK-COMPILE-CLI-001):
        # ``runtime/cli.py`` reaches ``prompt_pack_decisions`` only
        # via a function-scope import inside the ``compile`` branch
        # of ``_handle_prompt_pack``. At module level the CLI must
        # NOT import the decision capture helper.
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
            assert "prompt_pack_decisions" not in name, (
                f"cli.py imports {name!r} at module level — "
                f"prompt_pack_decisions may only be reached via a "
                f"function-scope import inside _handle_prompt_pack"
            )

    def test_decision_work_registry_does_not_import_prompt_pack_decisions(self):
        # Reverse dependency guard: the decision authority owns the
        # records and must not depend on a prompt-pack-specific
        # consumer.
        imported = _imported_module_names(dwr)
        for name in imported:
            assert "prompt_pack_decisions" not in name

    def test_prompt_pack_resolver_does_not_import_prompt_pack_decisions(self):
        # The resolver module (which defines the
        # LocalDecisionSummary bridge) should not depend on the
        # capture helper. The direction of dependency is:
        # resolver ← decisions, not the other way around.
        imported = _imported_module_names(ppr)
        for name in imported:
            assert "prompt_pack_decisions" not in name
