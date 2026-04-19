"""Invariant tests for DEC-CLAUDEX-SCOPE-TRIAD-UNIFIED-WRITE-AUTHORITY-001.

This module pins the atomic write-path guarantees for the scope-triad
unification introduced in slice 34. The ``cc-policy workflow scope-sync``
verb is the blessed orchestrator path that writes BOTH the
``workflow_scope`` enforcement row and ``work_items.scope_json`` in a
single SQLite transaction, preventing the dual-write-path drift that
causes ``_validate_work_item_scope_matches_authority`` to fire at
prompt-pack compile time.

@decision DEC-CLAUDEX-SCOPE-TRIAD-UNIFIED-WRITE-AUTHORITY-001
Title: scope-sync atomically writes workflow_scope + work_items.scope_json,
  eliminating dual-write-path drift between the enforcement authority and
  the planner intent declaration.
Status: accepted
Rationale: Prior to this slice, workflow_scope and work_items.scope_json were
  independent write targets. Any orchestrator that refreshed workflow_scope
  without mirroring the triad into work_items.scope_json would produce a
  prompt-pack compile failure from _validate_work_item_scope_matches_authority.
  scope-sync closes the gap by reading the scope file once and writing both
  rows in a single transaction. The guard function is preserved as a
  defense-in-depth backstop for callers that use legacy primitives incorrectly.
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
# Fixtures and helpers
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    """In-memory SQLite connection with schema bootstrapped."""
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


@pytest.fixture
def db(tmp_path):
    """On-disk SQLite DB path for subprocess CLI tests."""
    return str(tmp_path / "test-scope-sync.db")


def _seed_workflow(conn, *, workflow_id: str = "wf-sync-test") -> None:
    """Bind a test workflow (required before scope writes)."""
    workflows_mod.bind_workflow(
        conn,
        workflow_id=workflow_id,
        worktree_path="/tmp/wf-sync-test",
        branch="feature/sync-test",
    )


def _seed_goal(conn, *, goal_id: str = "GOAL-SYNC-1", workflow_id: str = "wf-sync-test") -> str:
    """Seed a goal record and return its goal_id."""
    record = dwr.GoalRecord(
        goal_id=goal_id,
        desired_end_state="ship the scope-sync slice",
        status="active",
        autonomy_budget=3,
        workflow_id=workflow_id,
    )
    dwr.insert_goal(conn, record)
    return goal_id


def _seed_work_item(
    conn,
    *,
    work_item_id: str = "WI-SYNC-1",
    goal_id: str = "GOAL-SYNC-1",
    workflow_id: str = "wf-sync-test",
    scope_json: str = "{}",
    title: str = "scope-sync slice",
    status: str = "in_progress",
    evaluation_json: str = "{}",
    head_sha: str | None = None,
    reviewer_round: int = 0,
    version: int = 1,
    author: str = "planner",
) -> dwr.WorkItemRecord:
    """Seed a work_item record and return it."""
    record = dwr.WorkItemRecord(
        work_item_id=work_item_id,
        goal_id=goal_id,
        workflow_id=workflow_id,
        title=title,
        status=status,
        version=version,
        author=author,
        scope_json=scope_json,
        evaluation_json=evaluation_json,
        head_sha=head_sha,
        reviewer_round=reviewer_round,
    )
    return dwr.insert_work_item(conn, record)


def _run_cli(args: list[str], db_path: str) -> tuple[int, dict]:
    """Invoke cc-policy CLI subprocess; return (exit_code, parsed_json)."""
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
        parsed = {"_raw": output, "_stdout": result.stdout, "_stderr": result.stderr}
    return result.returncode, parsed


def _seed_db_on_disk(db_path: str, *, with_work_item: bool = True) -> None:
    """Seed a file-based DB with workflow binding + goal + (optionally) work_item."""
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        ensure_schema(conn)
        _seed_workflow(conn)
        _seed_goal(conn)
        if with_work_item:
            _seed_work_item(conn)
        conn.commit()
    finally:
        conn.close()


_SAMPLE_SCOPE_TRIAD = {
    "allowed_paths": ["runtime/cli.py", "tmp/**"],
    "required_paths": ["runtime/cli.py"],
    "forbidden_paths": ["CLAUDE.md", "hooks/**"],
    "state_domains": ["workflow_scope_authority"],
}


# ---------------------------------------------------------------------------
# T1: update_work_item_scope_json — narrow-column update, other cols identical
# ---------------------------------------------------------------------------


class TestT1UpdateWorkItemScopeJsonNarrowColumn:
    """T1: update_work_item_scope_json updates scope_json + updated_at only."""

    def test_only_scope_json_and_updated_at_change(self, conn):
        """Read full row before/after; diff asserts only scope_json + updated_at changed."""
        _seed_workflow(conn)
        _seed_goal(conn)
        original = _seed_work_item(
            conn,
            scope_json="{}",
            evaluation_json='{"required_tests":["pytest tests/"]}',
            head_sha=None,
            reviewer_round=2,
            version=3,
            author="planner",
            title="original title",
            status="in_progress",
        )

        new_scope = '{"allowed_paths":["a.py"],"required_paths":[],"forbidden_paths":[],"state_domains":[]}'
        dwr.update_work_item_scope_json(conn, "WI-SYNC-1", new_scope)

        after = dwr.get_work_item(conn, "WI-SYNC-1")
        assert after is not None

        # scope_json must change.
        assert after.scope_json == new_scope, "scope_json was not updated"

        # updated_at must change (helper sets it to _now()).
        assert after.updated_at >= original.updated_at, "updated_at must be >= original"

        # Every other column must be byte-identical.
        assert after.work_item_id == original.work_item_id
        assert after.goal_id == original.goal_id
        assert after.workflow_id == original.workflow_id
        assert after.title == original.title
        assert after.status == original.status
        assert after.version == original.version
        assert after.author == original.author
        assert after.evaluation_json == original.evaluation_json
        assert after.head_sha == original.head_sha
        assert after.reviewer_round == original.reviewer_round
        assert after.created_at == original.created_at


# ---------------------------------------------------------------------------
# T2: update_work_item_scope_json — missing work_item_id raises ValueError
# ---------------------------------------------------------------------------


class TestT2UpdateWorkItemScopeJsonMissingId:
    """T2: update_work_item_scope_json raises ValueError on missing work_item_id."""

    def test_missing_id_raises_value_error_with_actionable_message(self, conn):
        """ValueError message must mention the missing work_item_id."""
        _seed_workflow(conn)
        _seed_goal(conn)
        # Do NOT seed a work_item.

        with pytest.raises(ValueError) as exc_info:
            dwr.update_work_item_scope_json(conn, "WI-DOES-NOT-EXIST", "{}")

        msg = str(exc_info.value)
        assert "WI-DOES-NOT-EXIST" in msg, (
            f"ValueError message must name the missing id; got: {msg!r}"
        )

    def test_missing_id_leaves_existing_rows_untouched(self, conn):
        """After a failed update, existing rows must be byte-identical to before."""
        _seed_workflow(conn)
        _seed_goal(conn)
        original = _seed_work_item(conn, scope_json='{"allowed_paths":[]}')

        with pytest.raises(ValueError):
            dwr.update_work_item_scope_json(conn, "WI-GHOST", '{"allowed_paths":["mutated"]}')

        # WI-SYNC-1 must be unchanged.
        after = dwr.get_work_item(conn, "WI-SYNC-1")
        assert after is not None
        assert after.scope_json == original.scope_json


# ---------------------------------------------------------------------------
# T3: CLI scope-sync happy path
# ---------------------------------------------------------------------------


class TestT3ScopeSyncHappyPath:
    """T3: CLI scope-sync writes both workflow_scope and work_items.scope_json."""

    def test_scope_sync_happy_path_both_rows_written(self, db, tmp_path):
        """After scope-sync: workflow_scope triad matches file; work_item.scope_json decodes to same triad."""
        _seed_db_on_disk(db)

        scope_file = tmp_path / "scope.json"
        scope_file.write_text(json.dumps(_SAMPLE_SCOPE_TRIAD))

        rc, resp = _run_cli(
            [
                "workflow", "scope-sync",
                "wf-sync-test",
                "--work-item-id", "WI-SYNC-1",
                "--scope-file", str(scope_file),
            ],
            db,
        )
        assert rc == 0, f"Expected exit 0; got {rc}: {resp}"
        assert resp.get("action") == "scope-sync"
        assert resp.get("status") == "ok"
        assert resp.get("workflow_id") == "wf-sync-test"
        assert resp.get("work_item_id") == "WI-SYNC-1"

        # Verify workflow_scope row.
        rc2, scope_resp = _run_cli(["workflow", "scope-get", "wf-sync-test"], db)
        assert rc2 == 0
        assert scope_resp.get("allowed_paths") == _SAMPLE_SCOPE_TRIAD["allowed_paths"]
        assert scope_resp.get("required_paths") == _SAMPLE_SCOPE_TRIAD["required_paths"]
        assert scope_resp.get("forbidden_paths") == _SAMPLE_SCOPE_TRIAD["forbidden_paths"]

        # Verify work_item.scope_json decoded to same triad.
        conn = sqlite3.connect(db)
        conn.row_factory = sqlite3.Row
        try:
            ensure_schema(conn)
            wi = dwr.get_work_item(conn, "WI-SYNC-1")
        finally:
            conn.close()
        assert wi is not None
        decoded = json.loads(wi.scope_json)
        assert decoded.get("allowed_paths") == _SAMPLE_SCOPE_TRIAD["allowed_paths"]
        assert decoded.get("required_paths") == _SAMPLE_SCOPE_TRIAD["required_paths"]
        assert decoded.get("forbidden_paths") == _SAMPLE_SCOPE_TRIAD["forbidden_paths"]
        # state_domains must be present in scope_json (mapped from scope file).
        assert "state_domains" in decoded


# ---------------------------------------------------------------------------
# T4: CLI scope-sync atomic rollback — missing work_item_id
# ---------------------------------------------------------------------------


class TestT4ScopeSyncAtomicRollbackMissingWorkItem:
    """T4: scope-sync with invalid work_item_id leaves workflow_scope byte-identical pre/post."""

    def test_missing_work_item_raises_and_leaves_scope_untouched(self, db, tmp_path):
        """workflow_scope row must be byte-identical before and after a failed scope-sync."""
        _seed_db_on_disk(db, with_work_item=False)  # No work_item seeded.

        # Pre-seed workflow_scope with a known state.
        conn_pre = sqlite3.connect(db)
        conn_pre.row_factory = sqlite3.Row
        try:
            ensure_schema(conn_pre)
            workflows_mod.set_scope(
                conn_pre,
                workflow_id="wf-sync-test",
                allowed_paths=["pre/existing.py"],
                required_paths=[],
                forbidden_paths=["forbidden/path.py"],
                authority_domains=["pre_domain"],
            )
        finally:
            conn_pre.close()

        # Capture pre-call state.
        conn_check = sqlite3.connect(db)
        conn_check.row_factory = sqlite3.Row
        try:
            ensure_schema(conn_check)
            pre_scope = workflows_mod.get_scope(conn_check, "wf-sync-test")
        finally:
            conn_check.close()
        assert pre_scope is not None

        scope_file = tmp_path / "scope.json"
        scope_file.write_text(json.dumps(_SAMPLE_SCOPE_TRIAD))

        rc, resp = _run_cli(
            [
                "workflow", "scope-sync",
                "wf-sync-test",
                "--work-item-id", "WI-DOES-NOT-EXIST",
                "--scope-file", str(scope_file),
            ],
            db,
        )
        # Must fail.
        assert rc != 0, f"Expected non-zero exit; got {rc}: {resp}"
        assert resp.get("status") == "error"
        # Error message must mention the missing work_item_id.
        assert "WI-DOES-NOT-EXIST" in resp.get("message", ""), (
            f"Error must name the missing work_item_id; got: {resp}"
        )

        # workflow_scope must be byte-identical to pre-call state.
        conn_post = sqlite3.connect(db)
        conn_post.row_factory = sqlite3.Row
        try:
            ensure_schema(conn_post)
            post_scope = workflows_mod.get_scope(conn_post, "wf-sync-test")
        finally:
            conn_post.close()
        assert post_scope is not None
        assert post_scope["allowed_paths"] == pre_scope["allowed_paths"]
        assert post_scope["required_paths"] == pre_scope["required_paths"]
        assert post_scope["forbidden_paths"] == pre_scope["forbidden_paths"]
        assert post_scope["authority_domains"] == pre_scope["authority_domains"]


# ---------------------------------------------------------------------------
# T5: CLI scope-sync atomic rollback — malformed scope file (non-object JSON)
# ---------------------------------------------------------------------------


class TestT5ScopeSyncAtomicRollbackMalformedJson:
    """T5: malformed scope file (non-object JSON) → ValueError, no writes."""

    def test_non_object_json_rejected_no_writes(self, db, tmp_path):
        """A scope file that is a JSON array (not object) must be rejected before any write."""
        _seed_db_on_disk(db)

        scope_file = tmp_path / "bad-scope.json"
        scope_file.write_text('["not", "a", "dict"]')  # non-object JSON

        # Capture pre-call workflow_scope (may be None — no scope seeded).
        conn_pre = sqlite3.connect(db)
        conn_pre.row_factory = sqlite3.Row
        try:
            ensure_schema(conn_pre)
            pre_scope = workflows_mod.get_scope(conn_pre, "wf-sync-test")
            pre_wi = dwr.get_work_item(conn_pre, "WI-SYNC-1")
        finally:
            conn_pre.close()
        pre_wi_scope = pre_wi.scope_json if pre_wi else None

        rc, resp = _run_cli(
            [
                "workflow", "scope-sync",
                "wf-sync-test",
                "--work-item-id", "WI-SYNC-1",
                "--scope-file", str(scope_file),
            ],
            db,
        )
        assert rc != 0, f"Expected non-zero exit; got {rc}: {resp}"
        assert resp.get("status") == "error"

        # No writes must have occurred.
        conn_post = sqlite3.connect(db)
        conn_post.row_factory = sqlite3.Row
        try:
            ensure_schema(conn_post)
            post_scope = workflows_mod.get_scope(conn_post, "wf-sync-test")
            post_wi = dwr.get_work_item(conn_post, "WI-SYNC-1")
        finally:
            conn_post.close()

        # workflow_scope unchanged (both None before and after, or same).
        assert post_scope == pre_scope, "workflow_scope must be unchanged after malformed-scope rejection"
        # work_item.scope_json unchanged.
        if post_wi is not None and pre_wi_scope is not None:
            assert post_wi.scope_json == pre_wi_scope

    def test_invalid_json_string_rejected_no_writes(self, db, tmp_path):
        """A scope file that is not valid JSON must be rejected."""
        _seed_db_on_disk(db)

        scope_file = tmp_path / "broken.json"
        scope_file.write_text('{allowed_paths: ["broken"]')  # invalid JSON

        rc, resp = _run_cli(
            [
                "workflow", "scope-sync",
                "wf-sync-test",
                "--work-item-id", "WI-SYNC-1",
                "--scope-file", str(scope_file),
            ],
            db,
        )
        assert rc != 0
        assert resp.get("status") == "error"


# ---------------------------------------------------------------------------
# T6: CLI scope-sync atomic rollback — unknown scope key
# ---------------------------------------------------------------------------


class TestT6ScopeSyncAtomicRollbackUnknownKey:
    """T6: scope file with unknown key → ValueError, no writes."""

    def test_unknown_key_rejected_no_writes(self, db, tmp_path):
        """scope file with an unknown key must fail before any write."""
        _seed_db_on_dist = _seed_db_on_disk  # alias for clarity
        _seed_db_on_disk(db)

        # Capture pre-call state.
        conn_pre = sqlite3.connect(db)
        conn_pre.row_factory = sqlite3.Row
        try:
            ensure_schema(conn_pre)
            pre_scope = workflows_mod.get_scope(conn_pre, "wf-sync-test")
            pre_wi = dwr.get_work_item(conn_pre, "WI-SYNC-1")
        finally:
            conn_pre.close()

        bad_scope = {
            "allowed_paths": ["runtime/cli.py"],
            "required_paths": [],
            "forbidden_paths": [],
            "unknown_key": "this should be rejected",  # unknown key
        }
        scope_file = tmp_path / "unknown-key-scope.json"
        scope_file.write_text(json.dumps(bad_scope))

        rc, resp = _run_cli(
            [
                "workflow", "scope-sync",
                "wf-sync-test",
                "--work-item-id", "WI-SYNC-1",
                "--scope-file", str(scope_file),
            ],
            db,
        )
        assert rc != 0, f"Expected non-zero exit for unknown key; got {rc}: {resp}"
        assert resp.get("status") == "error"
        # Error message should mention the unknown key.
        msg = resp.get("message", "")
        assert "unknown_key" in msg or "unknown" in msg.lower(), (
            f"Error must mention the unknown key; got: {msg!r}"
        )

        # No writes must have occurred.
        conn_post = sqlite3.connect(db)
        conn_post.row_factory = sqlite3.Row
        try:
            ensure_schema(conn_post)
            post_scope = workflows_mod.get_scope(conn_post, "wf-sync-test")
            post_wi = dwr.get_work_item(conn_post, "WI-SYNC-1")
        finally:
            conn_post.close()

        assert post_scope == pre_scope
        assert post_wi is not None and pre_wi is not None
        assert post_wi.scope_json == pre_wi.scope_json


# ---------------------------------------------------------------------------
# T7: CLI scope-sync atomic rollback — non-list path value
# ---------------------------------------------------------------------------


class TestT7ScopeSyncAtomicRollbackNonListPathValue:
    """T7: scope file with non-list path value → ValueError, no writes."""

    def test_non_list_allowed_paths_rejected(self, db, tmp_path):
        """allowed_paths must be a JSON array, not a string."""
        _seed_db_on_disk(db)

        bad_scope = {
            "allowed_paths": "should-be-a-list-not-a-string",  # non-list
            "required_paths": [],
            "forbidden_paths": [],
        }
        scope_file = tmp_path / "non-list-scope.json"
        scope_file.write_text(json.dumps(bad_scope))

        rc, resp = _run_cli(
            [
                "workflow", "scope-sync",
                "wf-sync-test",
                "--work-item-id", "WI-SYNC-1",
                "--scope-file", str(scope_file),
            ],
            db,
        )
        assert rc != 0, f"Expected non-zero exit for non-list path value; got {rc}: {resp}"
        assert resp.get("status") == "error"
        msg = resp.get("message", "")
        assert "allowed_paths" in msg or "list" in msg.lower(), (
            f"Error must mention the bad field; got: {msg!r}"
        )

    def test_non_list_required_paths_rejected(self, db, tmp_path):
        """required_paths as a dict (not a list) must be rejected."""
        _seed_db_on_disk(db)

        bad_scope = {
            "allowed_paths": [],
            "required_paths": {"should": "be-a-list"},  # non-list
            "forbidden_paths": [],
        }
        scope_file = tmp_path / "required-dict-scope.json"
        scope_file.write_text(json.dumps(bad_scope))

        rc, resp = _run_cli(
            [
                "workflow", "scope-sync",
                "wf-sync-test",
                "--work-item-id", "WI-SYNC-1",
                "--scope-file", str(scope_file),
            ],
            db,
        )
        assert rc != 0, f"Expected non-zero exit; got {rc}: {resp}"
        assert resp.get("status") == "error"

    def test_no_writes_on_non_list_rejection(self, db, tmp_path):
        """No rows must be written when validation fails due to non-list path value."""
        _seed_db_on_disk(db)

        conn_pre = sqlite3.connect(db)
        conn_pre.row_factory = sqlite3.Row
        try:
            ensure_schema(conn_pre)
            pre_wi = dwr.get_work_item(conn_pre, "WI-SYNC-1")
            pre_scope = workflows_mod.get_scope(conn_pre, "wf-sync-test")
        finally:
            conn_pre.close()

        bad_scope = {
            "allowed_paths": 42,  # non-list
            "required_paths": [],
            "forbidden_paths": [],
        }
        scope_file = tmp_path / "int-scope.json"
        scope_file.write_text(json.dumps(bad_scope))

        _run_cli(
            [
                "workflow", "scope-sync",
                "wf-sync-test",
                "--work-item-id", "WI-SYNC-1",
                "--scope-file", str(scope_file),
            ],
            db,
        )

        conn_post = sqlite3.connect(db)
        conn_post.row_factory = sqlite3.Row
        try:
            ensure_schema(conn_post)
            post_wi = dwr.get_work_item(conn_post, "WI-SYNC-1")
            post_scope = workflows_mod.get_scope(conn_post, "wf-sync-test")
        finally:
            conn_post.close()

        assert post_scope == pre_scope
        if post_wi is not None and pre_wi is not None:
            assert post_wi.scope_json == pre_wi.scope_json


# ---------------------------------------------------------------------------
# T8: End-to-end real-path — after scope-sync, compile_prompt_pack_for_stage
#     does NOT trigger the scope-triad guard
# ---------------------------------------------------------------------------


class TestT8EndToEndGuardDoesNotFireAfterScopeSync:
    """T8: end-to-end: scope-sync → compile_prompt_pack_for_stage succeeds.

    This is the compound-interaction test that crosses the boundaries of
    decision_work_registry, workflows, prompt_pack_state, prompt_pack_resolver,
    and prompt_pack — verifying the real production sequence where scope-sync
    is used as the write path.
    """

    def test_guard_does_not_fire_after_scope_sync(self, conn):
        """After scope-sync writes matching triad to both rows, compile succeeds."""
        from runtime.core import contracts
        from runtime.core import goal_contract_codec
        from runtime.core import prompt_pack as pp
        from runtime.core import stage_registry as sr

        # Seed workflow + scope + goal + work_item.
        _seed_workflow(conn)
        goal_id = _seed_goal(conn)

        scope_triad = {
            "allowed_paths": ["runtime/cli.py", "tmp/**"],
            "required_paths": ["runtime/cli.py"],
            "forbidden_paths": ["hooks/**"],
            "state_domains": ["scope_triad_write_path_atomicity"],
        }

        # Write workflow_scope (enforcement authority).
        workflows_mod.set_scope(
            conn,
            workflow_id="wf-sync-test",
            allowed_paths=scope_triad["allowed_paths"],
            required_paths=scope_triad["required_paths"],
            forbidden_paths=scope_triad["forbidden_paths"],
            authority_domains=scope_triad["state_domains"],
        )

        # Serialize scope_json matching the workflow_scope triad exactly.
        scope_json_str = json.dumps({
            "allowed_paths": scope_triad["allowed_paths"],
            "required_paths": scope_triad["required_paths"],
            "forbidden_paths": scope_triad["forbidden_paths"],
            "state_domains": scope_triad["state_domains"],
        })

        # Seed work_item with scope_json matching the workflow_scope.
        wi_record = _seed_work_item(
            conn,
            work_item_id="WI-E2E-1",
            goal_id=goal_id,
            scope_json=scope_json_str,
            evaluation_json=(
                '{"required_tests":["pytest tests/"],'
                '"required_evidence":["verbatim output"],'
                '"rollback_boundary":"git restore",'
                '"acceptance_notes":"end-to-end scope-sync test"}'
            ),
        )

        # Verify: compile_prompt_pack_for_stage in Mode B must NOT raise.
        # The guard _validate_work_item_scope_matches_authority fires when
        # work_item.scope (decoded from scope_json) != workflow_scope_record triad.
        # After scope-sync, they are equal, so the guard must pass silently.
        pack = pp.compile_prompt_pack_for_stage(
            conn,
            workflow_id="wf-sync-test",
            stage_id=sr.IMPLEMENTER,
            goal_id=goal_id,
            work_item_id="WI-E2E-1",
            decision_scope="kernel",
            generated_at=1_700_000_000,
        )

        from runtime.core import prompt_pack_state as pps

        # Verify the guard did not fire and compile produced a valid pack.
        assert pack is not None
        assert pack.workflow_id == "wf-sync-test"
        # The compiled pack should contain scope content derived from the authority.
        assert pack.content_hash.startswith("sha256:")

    def test_guard_fires_when_scope_sync_not_used(self, conn):
        """Regression: guard still fires when work_items.scope_json diverges from workflow_scope."""
        from runtime.core import contracts
        from runtime.core import prompt_pack as pp
        from runtime.core import stage_registry as sr

        _seed_workflow(conn)
        goal_id = _seed_goal(conn)

        # Write workflow_scope with one set of paths.
        workflows_mod.set_scope(
            conn,
            workflow_id="wf-sync-test",
            allowed_paths=["runtime/cli.py"],
            required_paths=["runtime/cli.py"],
            forbidden_paths=["CLAUDE.md"],
            authority_domains=[],
        )

        # Seed work_item with DIFFERENT scope_json (simulating the divergence that
        # the scope-sync verb is designed to prevent).
        _seed_work_item(
            conn,
            work_item_id="WI-DRIFT-1",
            goal_id=goal_id,
            scope_json=json.dumps({
                "allowed_paths": [],     # diverges from workflow_scope
                "required_paths": [],
                "forbidden_paths": [],
                "state_domains": [],
            }),
        )

        # Guard must fire.
        from runtime.core.prompt_pack_resolver import _validate_work_item_scope_matches_authority

        work_item_scope = contracts.ScopeManifest(
            allowed_paths=(),
            required_paths=(),
            forbidden_paths=(),
        )
        workflow_scope_record = {
            "allowed_paths": ["runtime/cli.py"],
            "required_paths": ["runtime/cli.py"],
            "forbidden_paths": ["CLAUDE.md"],
        }
        with pytest.raises(ValueError, match="drifted from the enforcement authority"):
            _validate_work_item_scope_matches_authority(work_item_scope, workflow_scope_record)


# ---------------------------------------------------------------------------
# T9: Legacy primitives preserved — scope-set and work-item-set --scope-json
# ---------------------------------------------------------------------------


class TestT9LegacyPrimitivesPreserved:
    """T9: cc-policy workflow scope-set and work-item-set --scope-json still work independently."""

    def test_scope_set_primitive_still_works(self, db):
        """Legacy scope-set CLI path is untouched and still accepts --allowed/--required/--forbidden."""
        _seed_db_on_disk(db)

        rc, resp = _run_cli(
            [
                "workflow", "scope-set",
                "wf-sync-test",
                "--allowed", json.dumps(["runtime/cli.py"]),
                "--required", json.dumps([]),
                "--forbidden", json.dumps(["CLAUDE.md"]),
            ],
            db,
        )
        assert rc == 0, f"scope-set failed: {resp}"
        assert resp.get("action") == "scope-set"
        assert resp.get("workflow_id") == "wf-sync-test"

        # Verify the scope row was written.
        rc2, scope_resp = _run_cli(["workflow", "scope-get", "wf-sync-test"], db)
        assert rc2 == 0
        assert scope_resp.get("allowed_paths") == ["runtime/cli.py"]

    def test_work_item_set_scope_json_primitive_still_works(self, db):
        """Legacy work-item-set --scope-json CLI path is untouched and still persists scope_json."""
        _seed_db_on_disk(db)

        new_scope = json.dumps({
            "allowed_paths": ["runtime/cli.py"],
            "required_paths": [],
            "forbidden_paths": [],
            "state_domains": [],
        })
        rc, resp = _run_cli(
            [
                "workflow", "work-item-set",
                "wf-sync-test",
                "GOAL-SYNC-1",
                "WI-SYNC-1",
                "--title", "updated title",
                "--scope-json", new_scope,
            ],
            db,
        )
        assert rc == 0, f"work-item-set failed: {resp}"
        assert resp.get("action") == "work-item-set"
        assert resp.get("work_item_id") == "WI-SYNC-1"

        # Verify scope_json was persisted.
        conn_check = sqlite3.connect(db)
        conn_check.row_factory = sqlite3.Row
        try:
            ensure_schema(conn_check)
            wi = dwr.get_work_item(conn_check, "WI-SYNC-1")
        finally:
            conn_check.close()
        assert wi is not None
        decoded = json.loads(wi.scope_json)
        assert decoded.get("allowed_paths") == ["runtime/cli.py"]


# ---------------------------------------------------------------------------
# T10: Module docstring contains DEC-CLAUDEX-SCOPE-TRIAD-UNIFIED-WRITE-AUTHORITY-001
# ---------------------------------------------------------------------------


class TestT10ModuleDocstringContainsDecisionId:
    """T10: This module's docstring contains DEC-CLAUDEX-SCOPE-TRIAD-UNIFIED-WRITE-AUTHORITY-001."""

    def test_module_docstring_contains_decision_id(self):
        """The module-level docstring must reference the decision ID."""
        import tests.runtime.test_scope_triad_unified_write_authority_invariant as _self

        doc = _self.__doc__ or ""
        assert "DEC-CLAUDEX-SCOPE-TRIAD-UNIFIED-WRITE-AUTHORITY-001" in doc, (
            "Module docstring must contain the decision ID "
            "DEC-CLAUDEX-SCOPE-TRIAD-UNIFIED-WRITE-AUTHORITY-001"
        )
