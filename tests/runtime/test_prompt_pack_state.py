"""Tests for runtime/core/prompt_pack_state.py.

@decision DEC-CLAUDEX-PROMPT-PACK-STATE-TESTS-001
Title: Pure runtime-state capture helper — read-only, deterministic, and grounded in existing shadow authorities
Status: proposed (shadow-mode, Phase 2 prompt-pack state capture)
Rationale: The capture helper is the first authority-wiring step
  for the ``runtime_state_pack`` layer. It consults three existing
  authority modules (``workflows``, ``leases``, ``approvals``)
  and composes a :class:`RuntimeStateSnapshot` from their read
  surfaces. These tests pin:

    1. Read-only guarantee: ``conn.total_changes`` is unchanged
       across the capture call.
    2. Branch/worktree resolution precedence: explicit keyword
       argument beats the workflow binding.
    3. Binding fallback: without an explicit argument, the
       workflow binding's ``branch`` / ``worktree_path`` is used.
    4. Missing-binding / missing-explicit failure: ``ValueError``
       with a clear message.
    5. ``workflow_id`` is required and must be non-empty.
    6. Lease capture filters to ``status="active"`` +
       ``workflow_id`` and sorts identifiers lexicographically.
    7. Approval capture filters to the target ``workflow_id``,
       renders entries as ``"op_type#id"``, and sorts by
       ``(op_type, id)`` numerically so ``push#2`` comes before
       ``push#10``.
    8. ``unresolved_findings`` defaults to live capture from the
       reviewer findings ledger (open findings for the workflow).
       Explicit override (including empty tuple) suppresses live.
    9. End-to-end handoff: the captured snapshot feeds straight
       into :func:`runtime_state_summary_from_snapshot` and then
       into :func:`build_prompt_pack` without reshaping.
   10. Shadow-only discipline via AST: the module imports only
       stdlib + the three authority modules +
       :class:`RuntimeStateSnapshot`.
"""

from __future__ import annotations

import ast
import inspect
import sqlite3

import pytest

from runtime.core import approvals, leases, workflows
from runtime.core import prompt_pack as pp
from runtime.core import prompt_pack_resolver as ppr
from runtime.core import prompt_pack_state as pps
from runtime.core import reviewer_findings as rf
from runtime.core import stage_registry as sr
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
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


def _seed_binding(
    conn,
    *,
    workflow_id: str = "wf-test",
    branch: str = "feature/wf-test",
    worktree_path: str = "/tmp/wf-test",
) -> None:
    workflows.bind_workflow(
        conn,
        workflow_id=workflow_id,
        worktree_path=worktree_path,
        branch=branch,
    )


# ---------------------------------------------------------------------------
# 1. Return type + workflow_id validation
# ---------------------------------------------------------------------------


class TestBasicBehavior:
    def test_returns_runtime_state_snapshot(self, conn):
        _seed_binding(conn)
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        assert isinstance(snap, ppr.RuntimeStateSnapshot)

    def test_empty_workflow_id_raises(self, conn):
        with pytest.raises(ValueError, match="workflow_id"):
            pps.capture_runtime_state_snapshot(conn, workflow_id="")

    def test_non_string_workflow_id_raises(self, conn):
        with pytest.raises(ValueError, match="workflow_id"):
            pps.capture_runtime_state_snapshot(
                conn, workflow_id=42  # type: ignore[arg-type]
            )

    def test_default_no_findings_is_empty_tuple(self, conn):
        """When no findings exist in the ledger, default capture produces empty tuple."""
        _seed_binding(conn)
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        assert snap.unresolved_findings == ()

    def test_explicit_findings_passthrough(self, conn):
        _seed_binding(conn)
        snap = pps.capture_runtime_state_snapshot(
            conn,
            workflow_id="wf-test",
            unresolved_findings=("finding-a", "finding-b"),
        )
        assert snap.unresolved_findings == ("finding-a", "finding-b")


# ---------------------------------------------------------------------------
# 2. Branch / worktree resolution precedence
# ---------------------------------------------------------------------------


class TestBranchWorktreeResolution:
    def test_binding_fallback_for_branch(self, conn):
        _seed_binding(conn, branch="feature/from-binding")
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        assert snap.current_branch == "feature/from-binding"

    def test_binding_fallback_for_worktree(self, conn):
        _seed_binding(conn, worktree_path="/tmp/wf-test-binding")
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        # The workflows module normalizes paths to realpath form, so
        # we assert that the returned value *contains* the declared
        # directory name rather than matching byte-for-byte.
        assert "wf-test-binding" in snap.worktree_path
        assert snap.worktree_path.startswith("/")

    def test_explicit_branch_wins_over_binding(self, conn):
        _seed_binding(conn, branch="feature/from-binding")
        snap = pps.capture_runtime_state_snapshot(
            conn,
            workflow_id="wf-test",
            current_branch="feature/override",
        )
        assert snap.current_branch == "feature/override"

    def test_explicit_worktree_wins_over_binding(self, conn):
        _seed_binding(conn, worktree_path="/tmp/wf-test-binding")
        snap = pps.capture_runtime_state_snapshot(
            conn,
            workflow_id="wf-test",
            worktree_path="/tmp/explicit-override",
        )
        assert snap.worktree_path == "/tmp/explicit-override"

    def test_both_overrides_take_effect(self, conn):
        _seed_binding(conn)
        snap = pps.capture_runtime_state_snapshot(
            conn,
            workflow_id="wf-test",
            current_branch="explicit-b",
            worktree_path="/tmp/explicit-w",
        )
        assert snap.current_branch == "explicit-b"
        assert snap.worktree_path == "/tmp/explicit-w"

    def test_missing_binding_no_explicit_branch_raises(self, conn):
        with pytest.raises(ValueError, match="current_branch"):
            pps.capture_runtime_state_snapshot(
                conn,
                workflow_id="wf-ghost",
                worktree_path="/tmp/explicit",
            )

    def test_missing_binding_no_explicit_worktree_raises(self, conn):
        with pytest.raises(ValueError, match="worktree_path"):
            pps.capture_runtime_state_snapshot(
                conn,
                workflow_id="wf-ghost",
                current_branch="explicit-b",
            )

    def test_missing_binding_no_explicits_raises_on_branch_first(self, conn):
        # With neither explicit, the helper validates branch first
        # and raises there.
        with pytest.raises(ValueError, match="current_branch"):
            pps.capture_runtime_state_snapshot(conn, workflow_id="wf-ghost")

    def test_explicit_empty_string_branch_rejected(self, conn):
        _seed_binding(conn)
        with pytest.raises(ValueError, match="current_branch"):
            pps.capture_runtime_state_snapshot(
                conn,
                workflow_id="wf-test",
                current_branch="",
            )

    def test_explicit_whitespace_only_branch_rejected(self, conn):
        _seed_binding(conn)
        with pytest.raises(ValueError, match="current_branch"):
            pps.capture_runtime_state_snapshot(
                conn,
                workflow_id="wf-test",
                current_branch="   ",
            )

    def test_explicit_empty_string_worktree_rejected(self, conn):
        _seed_binding(conn)
        with pytest.raises(ValueError, match="worktree_path"):
            pps.capture_runtime_state_snapshot(
                conn,
                workflow_id="wf-test",
                worktree_path="",
            )


# ---------------------------------------------------------------------------
# 3. Lease capture
# ---------------------------------------------------------------------------


class TestLeaseCapture:
    def test_no_leases_produces_empty_tuple(self, conn):
        _seed_binding(conn)
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        assert snap.active_leases == ()

    def test_active_leases_captured(self, conn):
        _seed_binding(conn)
        l1 = leases.issue(
            conn,
            role="implementer",
            workflow_id="wf-test",
            worktree_path="/tmp/wf-test",
        )
        l2 = leases.issue(conn, role="reviewer", workflow_id="wf-test")
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        assert set(snap.active_leases) == {l1["lease_id"], l2["lease_id"]}

    def test_active_leases_sorted_lexicographically(self, conn):
        _seed_binding(conn)
        # Issue multiple leases; their lease_ids are UUID hex so
        # sort order is not insertion order.
        issued_ids: list[str] = []
        for role in ("planner", "implementer", "reviewer", "guardian"):
            result = leases.issue(conn, role=role, workflow_id="wf-test")
            issued_ids.append(result["lease_id"])
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        assert list(snap.active_leases) == sorted(issued_ids)

    def test_released_lease_excluded(self, conn):
        _seed_binding(conn)
        l1 = leases.issue(conn, role="implementer", workflow_id="wf-test")
        l2 = leases.issue(conn, role="reviewer", workflow_id="wf-test")
        leases.release(conn, l1["lease_id"])
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        # Only the still-active lease remains.
        assert snap.active_leases == (l2["lease_id"],)

    def test_other_workflow_leases_excluded(self, conn):
        _seed_binding(conn)
        _seed_binding(conn, workflow_id="wf-other", worktree_path="/tmp/other")
        l1 = leases.issue(conn, role="implementer", workflow_id="wf-test")
        leases.issue(conn, role="implementer", workflow_id="wf-other")
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        assert snap.active_leases == (l1["lease_id"],)


# ---------------------------------------------------------------------------
# 4. Approval capture
# ---------------------------------------------------------------------------


class TestApprovalCapture:
    def test_no_approvals_produces_empty_tuple(self, conn):
        _seed_binding(conn)
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        assert snap.open_approvals == ()

    def test_single_approval_rendered_as_op_type_hash_id(self, conn):
        _seed_binding(conn)
        approval_id = approvals.grant(conn, "wf-test", "push")
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        assert snap.open_approvals == (f"push#{approval_id}",)

    def test_approvals_sorted_by_op_type_then_numeric_id(self, conn):
        _seed_binding(conn)
        id1 = approvals.grant(conn, "wf-test", "push")  # push#1
        id2 = approvals.grant(conn, "wf-test", "push")  # push#2
        id3 = approvals.grant(conn, "wf-test", "rebase")  # rebase#3
        id4 = approvals.grant(conn, "wf-test", "push")  # push#4
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        # Expected order: all pushes by numeric id ascending, then
        # rebases by numeric id ascending. "push" < "rebase"
        # lexicographically.
        assert snap.open_approvals == (
            f"push#{id1}",
            f"push#{id2}",
            f"push#{id4}",
            f"rebase#{id3}",
        )

    def test_numeric_id_sort_beats_lexicographic(self, conn):
        _seed_binding(conn)
        # Grant enough pushes that lexicographic sort would put
        # push#10 before push#2.
        ids: list[int] = []
        for _ in range(11):
            ids.append(approvals.grant(conn, "wf-test", "push"))
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        # The snapshot should be numerically sorted, so push#2
        # comes before push#10.
        rendered = list(snap.open_approvals)
        assert rendered[0] == f"push#{ids[0]}"
        assert rendered[1] == f"push#{ids[1]}"  # push#2
        assert rendered == [f"push#{id_}" for id_ in sorted(ids)]

    def test_consumed_approval_excluded(self, conn):
        _seed_binding(conn)
        id1 = approvals.grant(conn, "wf-test", "push")
        id2 = approvals.grant(conn, "wf-test", "push")
        approvals.check_and_consume(conn, "wf-test", "push")  # consumes id1
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        # Only the unconsumed approval (id2) remains.
        assert snap.open_approvals == (f"push#{id2}",)

    def test_other_workflow_approvals_excluded(self, conn):
        _seed_binding(conn)
        _seed_binding(conn, workflow_id="wf-other", worktree_path="/tmp/other")
        id_ours = approvals.grant(conn, "wf-test", "push")
        approvals.grant(conn, "wf-other", "push")
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        assert snap.open_approvals == (f"push#{id_ours}",)


# ---------------------------------------------------------------------------
# 4b. Live reviewer findings capture
# ---------------------------------------------------------------------------


class TestLiveFindingsCapture:
    """When unresolved_findings=None (default), open findings are read from
    the reviewer findings ledger for the workflow."""

    def test_open_finding_captured(self, conn):
        _seed_binding(conn)
        f = rf.insert(
            conn, workflow_id="wf-test", severity="blocking",
            title="Missing error handling", detail="Needs fix",
        )
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        assert len(snap.unresolved_findings) == 1
        rendered = snap.unresolved_findings[0]
        assert f.finding_id in rendered
        assert "[blocking]" in rendered
        assert "Missing error handling" in rendered

    def test_resolved_finding_excluded(self, conn):
        _seed_binding(conn)
        f = rf.insert(
            conn, workflow_id="wf-test", severity="blocking",
            title="Fixed issue", detail="Was fixed",
        )
        rf.resolve(conn, f.finding_id)
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        assert snap.unresolved_findings == ()

    def test_waived_finding_excluded(self, conn):
        _seed_binding(conn)
        f = rf.insert(
            conn, workflow_id="wf-test", severity="concern",
            title="Waived issue", detail="Accepted risk",
        )
        rf.waive(conn, f.finding_id)
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        assert snap.unresolved_findings == ()

    def test_explicit_empty_tuple_suppresses_live(self, conn):
        """Explicit unresolved_findings=() suppresses live findings."""
        _seed_binding(conn)
        rf.insert(
            conn, workflow_id="wf-test", severity="blocking",
            title="Should be suppressed", detail="Explicit override",
        )
        snap = pps.capture_runtime_state_snapshot(
            conn, workflow_id="wf-test", unresolved_findings=(),
        )
        assert snap.unresolved_findings == ()

    def test_explicit_tuple_overrides_live(self, conn):
        """Explicit findings replace live ledger findings entirely."""
        _seed_binding(conn)
        rf.insert(
            conn, workflow_id="wf-test", severity="blocking",
            title="Live finding", detail="From ledger",
        )
        snap = pps.capture_runtime_state_snapshot(
            conn, workflow_id="wf-test",
            unresolved_findings=("manual-finding-1",),
        )
        assert snap.unresolved_findings == ("manual-finding-1",)

    def test_other_workflow_findings_excluded(self, conn):
        _seed_binding(conn)
        rf.insert(
            conn, workflow_id="wf-other", severity="blocking",
            title="Other workflow", detail="Not ours",
        )
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        assert snap.unresolved_findings == ()

    def test_finding_with_file_path_and_line(self, conn):
        """Rendered string includes (file_path:line) when available."""
        _seed_binding(conn)
        rf.insert(
            conn, workflow_id="wf-test", severity="concern",
            title="Type mismatch", detail="Wrong type",
            file_path="src/main.py", line=42,
        )
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        rendered = snap.unresolved_findings[0]
        assert "(src/main.py:42)" in rendered

    def test_finding_with_file_path_no_line(self, conn):
        """Rendered string includes (file_path) without line when line is None."""
        _seed_binding(conn)
        rf.insert(
            conn, workflow_id="wf-test", severity="note",
            title="Style issue", detail="Minor",
            file_path="src/utils.py",
        )
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        rendered = snap.unresolved_findings[0]
        assert "(src/utils.py)" in rendered
        assert ":" not in rendered.split("(")[1]

    def test_deterministic_sort_by_severity_then_finding_id(self, conn):
        """Findings are sorted by (severity, finding_id) for determinism."""
        _seed_binding(conn)
        rf.insert(
            conn, workflow_id="wf-test", severity="note",
            title="Note A", detail="D", finding_id="f-note-a",
        )
        rf.insert(
            conn, workflow_id="wf-test", severity="blocking",
            title="Block B", detail="D", finding_id="f-block-b",
        )
        rf.insert(
            conn, workflow_id="wf-test", severity="blocking",
            title="Block A", detail="D", finding_id="f-block-a",
        )
        rf.insert(
            conn, workflow_id="wf-test", severity="concern",
            title="Concern C", detail="D", finding_id="f-concern-c",
        )
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        assert len(snap.unresolved_findings) == 4
        # Severity sort: blocking < concern < note (lexicographic).
        # Within same severity, by finding_id.
        assert "[blocking] f-block-a:" in snap.unresolved_findings[0]
        assert "[blocking] f-block-b:" in snap.unresolved_findings[1]
        assert "[concern] f-concern-c:" in snap.unresolved_findings[2]
        assert "[note] f-note-a:" in snap.unresolved_findings[3]

    def test_render_format_pinned(self, conn):
        """Pin the exact rendering format for stability."""
        _seed_binding(conn)
        rf.insert(
            conn, workflow_id="wf-test", severity="blocking",
            title="Null pointer", detail="D",
            finding_id="f-001", file_path="src/app.py", line=10,
        )
        snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        assert snap.unresolved_findings == (
            "[blocking] f-001: Null pointer (src/app.py:10)",
        )

    def test_work_item_scoping(self, conn):
        """When work_item_id is supplied, only findings for that work item are captured."""
        _seed_binding(conn)
        rf.insert(
            conn, workflow_id="wf-test", severity="blocking",
            title="Target", detail="D", work_item_id="wi-target",
        )
        rf.insert(
            conn, workflow_id="wf-test", severity="blocking",
            title="Other", detail="D", work_item_id="wi-other",
        )
        snap = pps.capture_runtime_state_snapshot(
            conn, workflow_id="wf-test", work_item_id="wi-target",
        )
        assert len(snap.unresolved_findings) == 1
        assert "Target" in snap.unresolved_findings[0]


# ---------------------------------------------------------------------------
# 5. Determinism + read-only guarantee
# ---------------------------------------------------------------------------


class TestDeterminismAndReadOnly:
    def test_deterministic_for_identical_state(self, conn):
        _seed_binding(conn)
        leases.issue(conn, role="implementer", workflow_id="wf-test")
        approvals.grant(conn, "wf-test", "push")

        a = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        b = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        assert a == b

    def test_capture_performs_no_writes(self, conn):
        _seed_binding(conn)
        leases.issue(conn, role="implementer", workflow_id="wf-test")
        approvals.grant(conn, "wf-test", "push")

        before = conn.total_changes
        pps.capture_runtime_state_snapshot(
            conn,
            workflow_id="wf-test",
            unresolved_findings=("finding-1",),
        )
        after = conn.total_changes
        assert after == before, (
            f"capture_runtime_state_snapshot is not read-only; "
            f"total_changes went from {before} to {after}"
        )

    def test_capture_does_not_commit_a_transaction(self, conn):
        # The helper must not open a transaction. SQLite's
        # ``conn.in_transaction`` reflects whether a write
        # transaction is currently open. For a read-only call
        # path that attribute should stay False throughout.
        _seed_binding(conn)
        assert conn.in_transaction is False
        pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
        assert conn.in_transaction is False


# ---------------------------------------------------------------------------
# 6. End-to-end handoff
# ---------------------------------------------------------------------------


class TestEndToEndHandoff:
    def test_snapshot_feeds_runtime_state_summary_from_snapshot(self, conn):
        _seed_binding(conn)
        leases.issue(conn, role="implementer", workflow_id="wf-test")
        approvals.grant(conn, "wf-test", "push")

        snap = pps.capture_runtime_state_snapshot(
            conn,
            workflow_id="wf-test",
            unresolved_findings=("finding-a",),
        )
        summary = ppr.runtime_state_summary_from_snapshot(snapshot=snap)
        rendered = summary.render()

        assert summary.current_branch == snap.current_branch
        assert summary.worktree_path == snap.worktree_path
        # The rendered layer mentions the captured lease / approval /
        # finding.
        assert "push#" in rendered
        assert "finding-a" in rendered

    def test_snapshot_feeds_build_prompt_pack_end_to_end(self, conn):
        _seed_binding(conn)
        leases.issue(conn, role="implementer", workflow_id="wf-test")
        approvals.grant(conn, "wf-test", "push")

        snap = pps.capture_runtime_state_snapshot(
            conn,
            workflow_id="wf-test",
            unresolved_findings=("finding-e2e",),
        )
        rt_summary = ppr.runtime_state_summary_from_snapshot(snapshot=snap)

        wf_summary = ppr.WorkflowContractSummary(
            workflow_id="wf-test",
            title="End-to-end capture",
            status="goal=active; work_item=in_progress",
            scope_summary="runtime/core/**",
            evaluation_summary="pytest green",
            rollback_boundary="git restore runtime/core/",
        )
        dec_summary = ppr.LocalDecisionSummary()

        layers = ppr.resolve_prompt_pack_layers(
            stage=sr.PLANNER,
            workflow_summary=wf_summary,
            decision_summary=dec_summary,
            runtime_state_summary=rt_summary,
        )
        pack = pp.build_prompt_pack(
            workflow_id="wf-test",
            stage_id=sr.PLANNER,
            layers=layers,
            generated_at=1_700_000_000,
        )
        assert pack.content_hash.startswith("sha256:")
        assert pack.layer_names == pp.CANONICAL_LAYER_ORDER

    def test_state_change_flows_through_content_hash(self, conn):
        _seed_binding(conn)

        def _pack_hash() -> str:
            snap = pps.capture_runtime_state_snapshot(conn, workflow_id="wf-test")
            rt_summary = ppr.runtime_state_summary_from_snapshot(snapshot=snap)
            layers = ppr.resolve_prompt_pack_layers(
                stage=sr.PLANNER,
                workflow_summary=ppr.WorkflowContractSummary(
                    workflow_id="wf-test",
                    title="hash-test",
                    status="pending",
                    scope_summary="x",
                    evaluation_summary="y",
                    rollback_boundary="z",
                ),
                decision_summary=ppr.LocalDecisionSummary(),
                runtime_state_summary=rt_summary,
            )
            pack = pp.build_prompt_pack(
                workflow_id="wf-test",
                stage_id=sr.PLANNER,
                layers=layers,
                generated_at=1,
            )
            return pack.content_hash

        base_hash = _pack_hash()

        # Grant an approval — the capture should reflect the
        # change and the compiled content hash must differ.
        approvals.grant(conn, "wf-test", "push")
        mutated_hash = _pack_hash()

        assert base_hash != mutated_hash


# ---------------------------------------------------------------------------
# 7. Shadow-only discipline
# ---------------------------------------------------------------------------


class TestShadowOnlyDiscipline:
    def test_module_imports_only_permitted_shadow_authorities(self):
        imported = _imported_module_names(pps)
        runtime_core_imports = {
            name for name in imported if name.startswith("runtime.core")
        }
        permitted_bases = {"runtime.core"}
        permitted_prefixes = (
            "runtime.core.approvals",
            "runtime.core.leases",
            "runtime.core.prompt_pack_resolver",
            "runtime.core.reviewer_findings",
            "runtime.core.workflows",
        )
        for name in runtime_core_imports:
            assert name in permitted_bases or name.startswith(
                permitted_prefixes
            ), (
                f"prompt_pack_state.py has unexpected runtime.core "
                f"import: {name!r}"
            )

    def test_no_live_routing_imports(self):
        imported = _imported_module_names(pps)
        forbidden_substrings = (
            "dispatch_engine",
            "completions",
            "policy_engine",
            "enforcement_config",
            "settings",
            "hooks",
            "runtime.core.policy_utils",
        )
        for name in imported:
            for needle in forbidden_substrings:
                assert needle not in name, (
                    f"prompt_pack_state.py imports {name!r} containing "
                    f"forbidden token {needle!r}"
                )

    def test_module_does_not_import_subprocess_or_os_walk(self):
        imported = _imported_module_names(pps)
        # A "pure read-only" contract means no subprocess, no
        # filesystem walking. ``sqlite3`` is allowed because the
        # caller passes in the connection.
        assert "subprocess" not in imported
        for name in imported:
            assert "pathlib" not in name
            assert "os.walk" not in name

    def test_live_modules_do_not_import_prompt_pack_state(self):
        import runtime.core.completions as completions
        import runtime.core.dispatch_engine as dispatch_engine
        import runtime.core.policy_engine as policy_engine

        for mod in (dispatch_engine, completions, policy_engine):
            imported = _imported_module_names(mod)
            for name in imported:
                assert "prompt_pack_state" not in name, (
                    f"{mod.__name__} imports {name!r} — prompt_pack_state "
                    f"must stay shadow-only this slice"
                )

    def test_cli_imports_prompt_pack_state_only_via_function_scope(self):
        # Architecture invariant after the prompt-pack compile CLI
        # slice (DEC-CLAUDEX-PROMPT-PACK-COMPILE-CLI-001):
        # ``runtime/cli.py`` reaches ``prompt_pack_state`` only via
        # a function-scope import inside the ``compile`` branch of
        # ``_handle_prompt_pack``. At module level the CLI must
        # NOT import the state capture helper.
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
            assert "prompt_pack_state" not in name, (
                f"cli.py imports {name!r} at module level — "
                f"prompt_pack_state may only be reached via a "
                f"function-scope import inside _handle_prompt_pack"
            )

    def test_resolver_module_does_not_import_prompt_pack_state(self):
        # Reverse dependency guard: the resolver owns the carrier
        # type and must not depend on the capture helper.
        imported = _imported_module_names(ppr)
        for name in imported:
            assert "prompt_pack_state" not in name


# ---------------------------------------------------------------------------
# DEC-CLAUDEX-PROMPT-PACK-SCOPE-AUTHORITY-001 — capture_workflow_scope
# is the shadow-only read-through that lets prompt_pack load the
# enforcement-authority workflow_scope row without importing
# runtime.core.workflows directly (which would break the shadow-only
# import discipline pinned by TestShadowOnlyDiscipline below).
# ---------------------------------------------------------------------------


class TestCaptureWorkflowScope:

    def test_returns_none_when_no_scope_row(self, conn):
        assert pps.capture_workflow_scope(conn, "wf-absent") is None

    def test_returns_parsed_dict_when_scope_exists(self, conn):
        _seed_binding(conn, workflow_id="wf-test")
        workflows.set_scope(
            conn,
            workflow_id="wf-test",
            allowed_paths=["runtime/**", "tests/**"],
            forbidden_paths=["settings.json"],
            required_paths=["runtime/core/x.py"],
            authority_domains=["auth-d"],
        )
        got = pps.capture_workflow_scope(conn, "wf-test")
        assert got is not None
        assert got["workflow_id"] == "wf-test"
        # Path lists must be parsed from JSON back to Python lists.
        assert got["allowed_paths"] == ["runtime/**", "tests/**"]
        assert got["forbidden_paths"] == ["settings.json"]
        assert got["required_paths"] == ["runtime/core/x.py"]
        assert got["authority_domains"] == ["auth-d"]

    def test_agrees_with_workflows_get_scope_directly(self, conn):
        """The helper is a thin read-through — no drift from the
        underlying workflows.get_scope output."""
        _seed_binding(conn, workflow_id="wf-parity")
        workflows.set_scope(
            conn,
            workflow_id="wf-parity",
            allowed_paths=["a.py"],
            forbidden_paths=["b.py"],
            required_paths=["c.py"],
            authority_domains=["d"],
        )
        via_helper = pps.capture_workflow_scope(conn, "wf-parity")
        via_direct = workflows.get_scope(conn, "wf-parity")
        assert via_helper == via_direct

    def test_read_only_does_not_mutate_state(self, conn):
        _seed_binding(conn, workflow_id="wf-ro")
        workflows.set_scope(
            conn,
            workflow_id="wf-ro",
            allowed_paths=["x.py"],
            forbidden_paths=[],
            required_paths=[],
            authority_domains=[],
        )
        total_before = conn.total_changes
        pps.capture_workflow_scope(conn, "wf-ro")
        pps.capture_workflow_scope(conn, "wf-absent")
        assert conn.total_changes == total_before
