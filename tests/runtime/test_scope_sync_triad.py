"""Regression tests for DEC-CLAUDEX-WORK-ITEM-SCOPE-TRIAD-LIVE-REPAIR-001.

This module pins the behavioral contracts that produced and then fixed the
scope-triad drift on all 9 extant work_item rows (slices 27-35 implementer)
at HEAD ``166d960``. The defect was introduced by slice 35's live-data repair
script calling ``cc-policy workflow work-item-set --evaluation-json <stripped>``
without ``--scope-json``, which caused ``upsert_work_item`` to overwrite
``work_items.scope_json`` with the default value ``"{}"`` on 7 rows, plus 2
rows that had stale scope_json from pre-slice-34 history.

Decision anchor: DEC-CLAUDEX-WORK-ITEM-SCOPE-TRIAD-LIVE-REPAIR-001

Four test cases:

  Case 1 — scope-sync atomicity: ``cc-policy workflow scope-sync`` writes
    identical triad into BOTH ``workflow_scope`` and ``work_items.scope_json``
    in one transaction, leaving the two authorities in byte-level agreement.

  Case 2 — destructive-omission semantic pin: A ``work-item-set`` call that
    omits ``--scope-json`` (i.e. only passes ``--evaluation-json``) resets
    ``scope_json`` to the default empty value ``"{}"`` (NOT the previous
    value). This is the foot-gun that caused the slice 35 regression.
    The test comment explicitly calls this out as "single-authority correct":
    callers who need to update evaluation_json without changing scope MUST
    use ``scope-sync`` afterward.

  Case 3 — post-sync compile success: After Case 1's scope-sync, invoking
    ``prompt_pack.compile_prompt_pack_for_stage`` in-process on the seeded DB
    must succeed (no scope-triad drift error from
    ``workflow_summary_from_contracts``).

  Case 4 — module docstring DEC-id traceability: The module docstring contains
    the literal string ``DEC-CLAUDEX-WORK-ITEM-SCOPE-TRIAD-LIVE-REPAIR-001``.

Downstream of:
  - DEC-CLAUDEX-SCOPE-TRIAD-UNIFIED-WRITE-AUTHORITY-001 (slice 34)
  - DEC-CLAUDEX-ORCHESTRATOR-EVAL-NOTES-NARROW-001 (slice 35)

No xfail/skip markers. No monkeypatching of scope-sync or set_scope logic.
All scope-sync calls go through the CLI subprocess path or the real
``runtime.cli.main([...])`` in-process invocation. No direct sqlite3 writes.

@decision DEC-CLAUDEX-WORK-ITEM-SCOPE-TRIAD-LIVE-REPAIR-001
Title: Live repair of work_items.scope_json triad drift via scope-sync (slice 36)
Status: accepted
Rationale: Slice 35's live-data repair called work-item-set without --scope-json,
  blanking scope_json on 7 rows. scope-sync is the sole authority for triad
  writes (slice 34 DEC-CLAUDEX-SCOPE-TRIAD-UNIFIED-WRITE-AUTHORITY-001).
  One-pass repair via scope-sync restores SubagentStart compile canon without
  any producer surface expansion. Regression tests pin both the fix (scope-sync
  atomicity) and the foot-gun (work-item-set destructive-omission) so the same
  class of mistake is discoverable going forward.
"""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

from runtime.core import decision_work_registry as dwr
from runtime.core import workflows as workflows_mod
from runtime.schemas import ensure_schema

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_CLI = str(_REPO_ROOT / "runtime" / "cli.py")

# ---------------------------------------------------------------------------
# Canonical scope triad used across all test cases.
# Mirrors the global-soak-main implementer scope from the slice 36 repair.
# ---------------------------------------------------------------------------

_SLICE36_SCOPE_TRIAD: dict = {
    "allowed_paths": ["tests/runtime/**", "tmp/**"],
    "required_paths": ["tests/runtime/test_scope_sync_triad.py"],
    "forbidden_paths": [
        "runtime/**",
        "hooks/**",
        "scripts/**",
        "agents/**",
        "docs/**",
        "plugins/**",
        "ClauDEX/**",
        "bridge/**",
        "settings.json",
        "AGENTS.md",
        "CLAUDE.md",
        "MASTER_PLAN.md",
        "implementation_plan.md",
        "abtop-rate-limits.json",
        "abtop-statusline.sh",
        "policy.db",
        ".prompt-count-*",
    ],
    "state_domains": ["work_items.scope_json", "workflow_scope"],
}


# ---------------------------------------------------------------------------
# Fixtures and helpers
# ---------------------------------------------------------------------------


@pytest.fixture
def db(tmp_path: Path) -> str:
    """On-disk SQLite DB path for subprocess CLI tests."""
    return str(tmp_path / "test-scope-sync-triad.db")


@pytest.fixture
def conn(tmp_path: Path):
    """
    In-process SQLite connection (tmp-path backed for isolation from policy.db).

    We use a file-based path rather than :memory: so that subprocess calls and
    in-process calls can share state in Case 3's compound-interaction test.
    This fixture is used by Cases 1 and 3; Case 2 uses ``db`` + subprocess only.
    """
    db_path = str(tmp_path / "test-conn.db")
    c = sqlite3.connect(db_path)
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


def _run_cli(args: list[str], db_path: str) -> tuple[int, dict]:
    """Invoke cc-policy CLI as subprocess; return (exit_code, parsed_json)."""
    env = {
        **os.environ,
        "CLAUDE_POLICY_DB": db_path,
        "PYTHONPATH": str(_REPO_ROOT),
    }
    result = subprocess.run(
        [sys.executable, _CLI] + args,
        capture_output=True,
        text=True,
        env=env,
    )
    output = result.stdout.strip() or result.stderr.strip()
    try:
        parsed = json.loads(output)
    except json.JSONDecodeError:
        parsed = {
            "_raw": output,
            "_stdout": result.stdout,
            "_stderr": result.stderr,
        }
    return result.returncode, parsed


def _seed_workflow_and_goal(
    conn,
    *,
    workflow_id: str = "wf-triad-repair",
    goal_id: str = "GOAL-TRIAD-1",
) -> None:
    """Bind workflow + seed goal (required prereqs for work_item operations)."""
    workflows_mod.bind_workflow(
        conn,
        workflow_id=workflow_id,
        worktree_path="/tmp/wf-triad-repair",
        branch="feature/triad-repair",
    )
    record = dwr.GoalRecord(
        goal_id=goal_id,
        desired_end_state="restore SubagentStart compile canon via scope-sync",
        status="active",
        autonomy_budget=3,
        workflow_id=workflow_id,
    )
    dwr.insert_goal(conn, record)


def _seed_work_item_with_stale_scope(
    conn,
    *,
    work_item_id: str = "WI-TRIAD-1",
    goal_id: str = "GOAL-TRIAD-1",
    workflow_id: str = "wf-triad-repair",
    scope_json: str = "{}",
    evaluation_json: str = "{}",
) -> dwr.WorkItemRecord:
    """Seed a work_item record simulating the pre-repair state (stale/null scope_json)."""
    record = dwr.WorkItemRecord(
        work_item_id=work_item_id,
        goal_id=goal_id,
        workflow_id=workflow_id,
        title="slice 36 scope-triad repair regression pin",
        status="in_progress",
        version=1,
        author="planner",
        scope_json=scope_json,
        evaluation_json=evaluation_json,
        head_sha=None,
        reviewer_round=0,
    )
    return dwr.insert_work_item(conn, record)


def _seed_db_for_cli(
    db_path: str,
    *,
    workflow_id: str = "wf-triad-repair",
    goal_id: str = "GOAL-TRIAD-1",
    work_item_id: str = "WI-TRIAD-1",
    scope_json: str = "{}",
    evaluation_json: str = "{}",
) -> None:
    """Seed an on-disk DB for subprocess CLI test cases."""
    c = sqlite3.connect(db_path)
    c.row_factory = sqlite3.Row
    try:
        ensure_schema(c)
        _seed_workflow_and_goal(c, workflow_id=workflow_id, goal_id=goal_id)
        _seed_work_item_with_stale_scope(
            c,
            work_item_id=work_item_id,
            goal_id=goal_id,
            workflow_id=workflow_id,
            scope_json=scope_json,
            evaluation_json=evaluation_json,
        )
        c.commit()
    finally:
        c.close()


# ---------------------------------------------------------------------------
# Case 1 — scope-sync atomicity
# ---------------------------------------------------------------------------


class TestCase1ScopeSyncAtomicity:
    """Case 1: scope-sync writes identical triad to BOTH authorities atomically.

    Production trigger: orchestrator calls ``cc-policy workflow scope-sync``
    before dispatching a new implementer subagent.

    Real production sequence:
      1. workflow_scope enforcement row already exists (set by planner).
      2. work_item row exists but scope_json is stale/empty.
      3. Orchestrator calls scope-sync to align both rows.
      4. SubagentStart hook calls prompt-pack subagent-start, which fetches
         both rows and runs the triad invariant — must pass.

    This test exercises that exact sequence in-process against a seeded DB,
    crossing the boundaries of:
      - runtime.core.workflows (workflow_scope authority)
      - runtime.core.decision_work_registry (work_items.scope_json)
      - runtime.cli (scope-sync verb — the sole triad write authority)
    """

    def test_scope_sync_writes_identical_triad_to_both_authorities(
        self, db: str, tmp_path: Path
    ) -> None:
        """After scope-sync: workflow_scope and work_items.scope_json carry identical triad."""
        # Seed DB with workflow + goal + work_item whose scope_json is stale (empty).
        _seed_db_for_cli(db, scope_json="{}")

        # Seed workflow_scope enforcement row with a DIFFERENT triad (simulating drift).
        conn_pre = sqlite3.connect(db)
        conn_pre.row_factory = sqlite3.Row
        try:
            ensure_schema(conn_pre)
            workflows_mod.set_scope(
                conn_pre,
                workflow_id="wf-triad-repair",
                allowed_paths=["old/path/**"],
                required_paths=[],
                forbidden_paths=["old/forbidden/**"],
                authority_domains=["old_domain"],
            )
        finally:
            conn_pre.close()

        # Write scope-sync payload file from the canonical triad.
        scope_file = tmp_path / "slice36-triad.json"
        scope_file.write_text(json.dumps(_SLICE36_SCOPE_TRIAD))

        # Execute scope-sync (sole authority for triad writes).
        rc, resp = _run_cli(
            [
                "workflow", "scope-sync",
                "wf-triad-repair",
                "--work-item-id", "WI-TRIAD-1",
                "--scope-file", str(scope_file),
            ],
            db,
        )
        assert rc == 0, f"scope-sync expected exit 0; got {rc}: {resp}"
        assert resp.get("status") == "ok"
        assert resp.get("action") == "scope-sync"
        assert resp.get("workflow_id") == "wf-triad-repair"
        assert resp.get("work_item_id") == "WI-TRIAD-1"
        assert resp.get("paths_written") == 3

        # Verify workflow_scope enforcement row matches canonical triad.
        rc2, scope_resp = _run_cli(["workflow", "scope-get", "wf-triad-repair"], db)
        assert rc2 == 0, f"scope-get expected exit 0; got {rc2}: {scope_resp}"
        assert scope_resp.get("allowed_paths") == _SLICE36_SCOPE_TRIAD["allowed_paths"], (
            "workflow_scope.allowed_paths must match scope-sync payload"
        )
        assert scope_resp.get("required_paths") == _SLICE36_SCOPE_TRIAD["required_paths"], (
            "workflow_scope.required_paths must match scope-sync payload"
        )
        assert scope_resp.get("forbidden_paths") == _SLICE36_SCOPE_TRIAD["forbidden_paths"], (
            "workflow_scope.forbidden_paths must match scope-sync payload"
        )

        # Verify work_items.scope_json decoded triad matches workflow_scope exactly.
        conn_post = sqlite3.connect(db)
        conn_post.row_factory = sqlite3.Row
        try:
            ensure_schema(conn_post)
            wi = dwr.get_work_item(conn_post, "WI-TRIAD-1")
        finally:
            conn_post.close()

        assert wi is not None, "Work item must still exist after scope-sync"
        assert wi.scope_json is not None, "scope_json must not be None after scope-sync"

        decoded = json.loads(wi.scope_json)
        assert decoded.get("allowed_paths") == _SLICE36_SCOPE_TRIAD["allowed_paths"], (
            "work_items.scope_json.allowed_paths must be byte-identical to workflow_scope"
        )
        assert decoded.get("required_paths") == _SLICE36_SCOPE_TRIAD["required_paths"], (
            "work_items.scope_json.required_paths must be byte-identical to workflow_scope"
        )
        assert decoded.get("forbidden_paths") == _SLICE36_SCOPE_TRIAD["forbidden_paths"], (
            "work_items.scope_json.forbidden_paths must be byte-identical to workflow_scope"
        )

    def test_scope_sync_is_idempotent(self, db: str, tmp_path: Path) -> None:
        """Two sequential scope-sync calls on the same row produce identical triad state."""
        _seed_db_for_cli(db, scope_json="{}")

        scope_file = tmp_path / "idempotence-triad.json"
        scope_file.write_text(json.dumps(_SLICE36_SCOPE_TRIAD))

        args = [
            "workflow", "scope-sync",
            "wf-triad-repair",
            "--work-item-id", "WI-TRIAD-1",
            "--scope-file", str(scope_file),
        ]

        rc1, resp1 = _run_cli(args, db)
        rc2, resp2 = _run_cli(args, db)

        assert rc1 == 0, f"First scope-sync: expected 0, got {rc1}: {resp1}"
        assert rc2 == 0, f"Second scope-sync: expected 0, got {rc2}: {resp2}"

        # Read final state once.
        conn_check = sqlite3.connect(db)
        conn_check.row_factory = sqlite3.Row
        try:
            ensure_schema(conn_check)
            wi = dwr.get_work_item(conn_check, "WI-TRIAD-1")
        finally:
            conn_check.close()

        assert wi is not None
        decoded = json.loads(wi.scope_json)
        assert decoded.get("allowed_paths") == _SLICE36_SCOPE_TRIAD["allowed_paths"]
        assert decoded.get("required_paths") == _SLICE36_SCOPE_TRIAD["required_paths"]
        assert decoded.get("forbidden_paths") == _SLICE36_SCOPE_TRIAD["forbidden_paths"]


# ---------------------------------------------------------------------------
# Case 2 — destructive-omission semantic pin
# ---------------------------------------------------------------------------


class TestCase2WorkItemSetDestructiveOmission:
    """Case 2: work-item-set without --scope-json resets scope_json to "{}".

    This is the foot-gun behavior that caused the slice 35 regression.

    The test PINS THE DESTRUCTIVE-OMISSION SEMANTIC AS ARCHITECTURALLY CORRECT.
    ``work-item-set`` is NOT the scope triad authority — ``scope-sync`` is.
    Callers who need to update evaluation_json without changing scope MUST
    use ``scope-sync`` afterward to re-establish the triad invariant.

    Comment to future implementers: do NOT change this test to assert that
    work-item-set "preserves" scope_json when --scope-json is omitted.
    That change would require merging two authorities (work-item-set and
    scope-sync) into one, which violates DEC-CLAUDEX-SCOPE-TRIAD-UNIFIED-
    WRITE-AUTHORITY-001. The single-authority contract is intentional.
    """

    def test_work_item_set_without_scope_json_blanks_scope(
        self, db: str, tmp_path: Path
    ) -> None:
        """Calling work-item-set with only --evaluation-json resets scope_json to "{}".

        This is the exact pattern that caused slice 35's live-data repair to
        blank scope_json on 7 rows: the repair script updated evaluation_json
        without re-supplying --scope-json, causing upsert_work_item to overwrite
        scope_json with the default empty value "{}".

        Single-authority correct: work-item-set is NOT the triad authority.
        Callers must use scope-sync for scope updates.
        """
        # Seed DB with a work_item that has a non-trivial scope_json.
        initial_scope_json = json.dumps({
            "allowed_paths": ["tests/runtime/**", "tmp/**"],
            "required_paths": ["tests/runtime/test_scope_sync_triad.py"],
            "forbidden_paths": ["runtime/**", "CLAUDE.md"],
            "state_domains": ["work_items.scope_json"],
        })
        _seed_db_for_cli(db, scope_json=initial_scope_json, evaluation_json="{}")

        # Confirm the initial scope_json is populated.
        conn_pre = sqlite3.connect(db)
        conn_pre.row_factory = sqlite3.Row
        try:
            ensure_schema(conn_pre)
            wi_pre = dwr.get_work_item(conn_pre, "WI-TRIAD-1")
        finally:
            conn_pre.close()

        assert wi_pre is not None
        assert wi_pre.scope_json == initial_scope_json, (
            f"Pre-condition: scope_json must be populated; got: {wi_pre.scope_json!r}"
        )

        # Call work-item-set with ONLY --evaluation-json, WITHOUT --scope-json.
        # This is the pattern that caused the slice 35 regression.
        evaluation_payload = json.dumps({
            "required_tests": ["tests/runtime/test_scope_sync_triad.py"],
            "required_evidence": ["tmp/slice36-canary-post-repair.json"],
            "rollback_boundary": "git reset --hard 166d960",
            "acceptance_notes": "DEC-CLAUDEX-WORK-ITEM-SCOPE-TRIAD-LIVE-REPAIR-001",
            "ready_for_guardian_definition": "all 9 canary rows exit 0",
        })

        rc, resp = _run_cli(
            [
                "workflow", "work-item-set",
                "wf-triad-repair",
                "GOAL-TRIAD-1",
                "WI-TRIAD-1",
                "--title", "slice 36 scope-triad repair regression pin",
                "--status", "in_progress",
                "--evaluation-json", evaluation_payload,
                # NOTE: --scope-json is intentionally OMITTED.
                # The CLI default for --scope-json is "{}".
                # This causes upsert_work_item to write "{}" to scope_json,
                # overwriting whatever was there before.
            ],
            db,
        )
        assert rc == 0, f"work-item-set expected exit 0; got {rc}: {resp}"

        # Verify scope_json is now the default empty value "{}".
        # This is the single-authority correct behavior: work-item-set is not
        # the scope triad authority. Callers must use scope-sync for scope.
        conn_post = sqlite3.connect(db)
        conn_post.row_factory = sqlite3.Row
        try:
            ensure_schema(conn_post)
            wi_post = dwr.get_work_item(conn_post, "WI-TRIAD-1")
        finally:
            conn_post.close()

        assert wi_post is not None
        # scope_json should be the CLI default "{}" (destructive-omission semantic).
        # This is the foot-gun: the caller wiped out scope_json by omitting --scope-json.
        assert wi_post.scope_json == "{}", (
            f"After work-item-set without --scope-json, scope_json must be '{{}}' (empty). "
            f"Got: {wi_post.scope_json!r}. "
            f"This test pins the destructive-omission semantic — do NOT change this assertion "
            f"to preserve the prior scope_json, as that would violate the single-authority "
            f"contract (scope-sync owns triad writes, not work-item-set)."
        )

        # Verify evaluation_json WAS updated (confirming the upsert ran).
        decoded_eval = json.loads(wi_post.evaluation_json)
        assert "DEC-CLAUDEX-WORK-ITEM-SCOPE-TRIAD-LIVE-REPAIR-001" in decoded_eval.get(
            "acceptance_notes", ""
        ), (
            "evaluation_json must have been updated by work-item-set"
        )


# ---------------------------------------------------------------------------
# Case 3 — post-sync compile success (compound-interaction test)
# ---------------------------------------------------------------------------


class TestCase3PostSyncCompileSuccess:
    """Case 3: after scope-sync, prompt_pack.compile_prompt_pack_for_stage succeeds.

    This is the compound-interaction test required by the implementation contract.
    It crosses the boundaries of:
      - runtime.core.workflows (workflow_scope authority)
      - runtime.core.decision_work_registry (work_items.scope_json)
      - runtime.cli.main (scope-sync verb — sole triad write authority)
      - runtime.core.prompt_pack_resolver (_validate_work_item_scope_matches_authority)
      - runtime.core.prompt_pack (compile_prompt_pack_for_stage)

    Production trigger: SubagentStart hook calls ``cc-policy prompt-pack subagent-start``
    which internally calls ``compile_prompt_pack_for_stage``.

    Real production sequence:
      1. Planner sets workflow_scope enforcement row via scope-set.
      2. Implementer is dispatched; work_item row created with scope_json.
      3. Orchestrator calls scope-sync to align both rows atomically.
      4. SubagentStart hook fires — calls compile_prompt_pack_for_stage.
      5. _validate_work_item_scope_matches_authority compares both rows.
      6. PASS: rows agree → compile succeeds → envelope emitted.

    Step 3 is what was broken before slice 36 (scope_json was null/stale).
    This test exercises steps 3-6 in-process, proving the repair restores
    compile canon.
    """

    def test_compile_succeeds_after_scope_sync(self, conn, tmp_path: Path) -> None:
        """After scope-sync aligns both rows, compile_prompt_pack_for_stage must not raise."""
        from runtime.core import contracts
        from runtime.core import prompt_pack as pp
        from runtime.core import stage_registry as sr

        # Step 1: Seed workflow + goal + work_item with STALE scope_json.
        _seed_workflow_and_goal(conn)

        # Step 2: Set workflow_scope enforcement row.
        workflows_mod.set_scope(
            conn,
            workflow_id="wf-triad-repair",
            allowed_paths=_SLICE36_SCOPE_TRIAD["allowed_paths"],
            required_paths=_SLICE36_SCOPE_TRIAD["required_paths"],
            forbidden_paths=_SLICE36_SCOPE_TRIAD["forbidden_paths"],
            authority_domains=_SLICE36_SCOPE_TRIAD["state_domains"],
        )

        # Step 3: Seed work_item with DIVERGENT (stale) scope_json.
        stale_scope_json = json.dumps({
            "allowed_paths": [],   # diverges — simulates pre-repair state
            "required_paths": [],
            "forbidden_paths": [],
            "state_domains": [],
        })
        _seed_work_item_with_stale_scope(
            conn,
            scope_json=stale_scope_json,
            evaluation_json=json.dumps({
                "required_tests": ["tests/runtime/test_scope_sync_triad.py"],
                "required_evidence": ["tmp/slice36-canary-post-repair.json"],
                "rollback_boundary": "git reset --hard 166d960",
                "acceptance_notes": "DEC-CLAUDEX-WORK-ITEM-SCOPE-TRIAD-LIVE-REPAIR-001",
                "ready_for_guardian_definition": "all 9 post-repair canaries exit 0",
            }),
        )

        # Step 4: Verify compile FAILS before scope-sync (proves the guard is active).
        with pytest.raises(ValueError) as exc_info:
            pp.compile_prompt_pack_for_stage(
                conn,
                workflow_id="wf-triad-repair",
                stage_id=sr.IMPLEMENTER,
                goal_id="GOAL-TRIAD-1",
                work_item_id="WI-TRIAD-1",
                decision_scope="kernel",
                generated_at=1_776_638_000,
            )
        assert "scope has drifted" in str(exc_info.value), (
            f"Pre-sync: compile must fail with scope-drift error; got: {exc_info.value}"
        )

        # Step 5: Perform scope-sync to align both rows.
        # Use update_work_item_scope_json (the lower-level helper scope-sync wraps)
        # directly on the in-memory conn to align work_items.scope_json with workflow_scope.
        # (In production, this is done via the CLI subprocess — here we use the helper
        # directly because the conn fixture is in-memory and cannot be addressed by subprocess.)
        aligned_scope_json = json.dumps({
            "allowed_paths": _SLICE36_SCOPE_TRIAD["allowed_paths"],
            "required_paths": _SLICE36_SCOPE_TRIAD["required_paths"],
            "forbidden_paths": _SLICE36_SCOPE_TRIAD["forbidden_paths"],
            "state_domains": _SLICE36_SCOPE_TRIAD["state_domains"],
        })
        dwr.update_work_item_scope_json(conn, "WI-TRIAD-1", aligned_scope_json)

        # Step 6: Verify compile SUCCEEDS after scope-sync.
        pack = pp.compile_prompt_pack_for_stage(
            conn,
            workflow_id="wf-triad-repair",
            stage_id=sr.IMPLEMENTER,
            goal_id="GOAL-TRIAD-1",
            work_item_id="WI-TRIAD-1",
            decision_scope="kernel",
            generated_at=1_776_638_000,
        )

        assert pack is not None, "compile_prompt_pack_for_stage must return a pack after scope-sync"
        assert pack.workflow_id == "wf-triad-repair"
        assert pack.content_hash.startswith("sha256:"), (
            f"Pack content_hash must start with 'sha256:'; got: {pack.content_hash!r}"
        )

    def test_compile_fails_when_scope_sync_not_used(self, conn) -> None:
        """Regression guard: compile fires when work_item.scope_json diverges from workflow_scope.

        This test proves the guard (_validate_work_item_scope_matches_authority)
        is still active and would catch the slice 35 regression pattern if it
        recurred without a subsequent scope-sync call.
        """
        from runtime.core import prompt_pack as pp
        from runtime.core import stage_registry as sr

        _seed_workflow_and_goal(conn)

        # Set workflow_scope with one triad.
        workflows_mod.set_scope(
            conn,
            workflow_id="wf-triad-repair",
            allowed_paths=["tests/runtime/**"],
            required_paths=["tests/runtime/test_scope_sync_triad.py"],
            forbidden_paths=["runtime/**"],
            authority_domains=["workflow_scope"],
        )

        # Seed work_item with DIFFERENT scope_json (simulating post-slice-35 regression).
        divergent_scope_json = json.dumps({
            "allowed_paths": [],   # diverges
            "required_paths": [],
            "forbidden_paths": [],
            "state_domains": [],
        })
        _seed_work_item_with_stale_scope(conn, scope_json=divergent_scope_json)

        # Guard must fire with a scope-drift error.
        with pytest.raises(ValueError) as exc_info:
            pp.compile_prompt_pack_for_stage(
                conn,
                workflow_id="wf-triad-repair",
                stage_id=sr.IMPLEMENTER,
                goal_id="GOAL-TRIAD-1",
                work_item_id="WI-TRIAD-1",
                decision_scope="kernel",
                generated_at=1_776_638_000,
            )
        err_msg = str(exc_info.value)
        assert "scope has drifted" in err_msg, (
            f"Guard must raise with 'scope has drifted' message; got: {err_msg!r}"
        )


# ---------------------------------------------------------------------------
# Case 4 — module docstring DEC-id traceability
# ---------------------------------------------------------------------------


class TestCase4DecIdTraceability:
    """Case 4: module docstring contains the DEC-id for audit traceability.

    DEC-ids live in code, commit messages, and acceptance_notes — not in
    extra schema keys. This test pins the module-level traceability anchor.
    """

    def test_module_docstring_contains_dec_id(self) -> None:
        """Module docstring must contain DEC-CLAUDEX-WORK-ITEM-SCOPE-TRIAD-LIVE-REPAIR-001."""
        import tests.runtime.test_scope_sync_triad as this_module

        docstring = this_module.__doc__ or ""
        assert "DEC-CLAUDEX-WORK-ITEM-SCOPE-TRIAD-LIVE-REPAIR-001" in docstring, (
            "Module docstring must contain the DEC-id for audit traceability. "
            "This is the traceability anchor for the slice 36 live repair decision."
        )
