"""Tests for the runtime-owned local workflow bootstrap authority."""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[2]
_CLI = str(_REPO_ROOT / "runtime" / "cli.py")


def _make_git_repo(tmp_path: Path, name: str = "repo") -> Path:
    repo = tmp_path / name
    repo.mkdir()
    subprocess.run(["git", "init", str(repo)], capture_output=True, check=True)
    subprocess.run(
        ["git", "-C", str(repo), "config", "user.email", "test@example.com"],
        capture_output=True,
        check=True,
    )
    subprocess.run(
        ["git", "-C", str(repo), "config", "user.name", "Test User"],
        capture_output=True,
        check=True,
    )
    return repo


def _run_cli(
    args: list[str], *, cwd: Path, extra_env: dict | None = None
) -> subprocess.CompletedProcess[str]:
    env = {
        **os.environ,
        "PYTHONPATH": str(_REPO_ROOT),
    }
    env.pop("CLAUDE_POLICY_DB", None)
    env.pop("CLAUDE_PROJECT_DIR", None)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        [sys.executable, _CLI] + args,
        cwd=str(cwd),
        capture_output=True,
        text=True,
        env=env,
    )


def _request_bootstrap_token(
    workflow_id: str,
    *,
    cwd: Path,
    desired_end_state: str,
    worktree_path: Path | None = None,
    ttl_seconds: int | None = None,
    extra_env: dict | None = None,
) -> str:
    args = [
        "workflow",
        "bootstrap-request",
        workflow_id,
        "--desired-end-state",
        desired_end_state,
        "--requested-by",
        "pytest",
        "--justification",
        "exercise local workflow bootstrap",
    ]
    if worktree_path is not None:
        args.extend(["--worktree-path", str(worktree_path)])
    if ttl_seconds is not None:
        args.extend(["--ttl-seconds", str(ttl_seconds)])
    result = _run_cli(args, cwd=cwd, extra_env=extra_env)
    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    return payload["bootstrap_request"]["token"]


def test_bootstrap_local_creates_local_state_db_and_returns_launch_spec(tmp_path: Path) -> None:
    repo = _make_git_repo(tmp_path)
    token = _request_bootstrap_token(
        "wf-bootstrap",
        cwd=repo,
        desired_end_state="adopt synthesis into root plan",
    )

    result = _run_cli(
        [
            "workflow",
            "bootstrap-local",
            "wf-bootstrap",
            "--bootstrap-token",
            token,
        ],
        cwd=repo,
    )

    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["status"] == "ok"
    assert payload["workflow_id"] == "wf-bootstrap"
    assert payload["stage_id"] == "planner"
    assert payload["agent_tool_spec"]["subagent_type"] == "planner"

    db_path = repo / ".claude" / "state.db"
    assert payload["bootstrap"]["db_path"] == str(db_path)
    assert db_path.is_file()

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        binding = conn.execute(
            "SELECT workflow_id, worktree_path, branch FROM workflow_bindings WHERE workflow_id = ?",
            ("wf-bootstrap",),
        ).fetchone()
        goal = conn.execute(
            "SELECT goal_id, status FROM goal_contracts WHERE goal_id = ?",
            ("g-initial-planning",),
        ).fetchone()
        work_item = conn.execute(
            "SELECT work_item_id, status, workflow_id, head_sha FROM work_items WHERE work_item_id = ?",
            ("wi-initial-planning",),
        ).fetchone()
        evaluation = conn.execute(
            "SELECT status FROM evaluation_state WHERE workflow_id = ?",
            ("wf-bootstrap",),
        ).fetchone()
    finally:
        conn.close()

    assert dict(binding) == {
        "workflow_id": "wf-bootstrap",
        "worktree_path": str(repo.resolve()),
        "branch": payload["bootstrap"]["branch"],
    }
    assert dict(goal) == {"goal_id": "g-initial-planning", "status": "active"}
    assert dict(work_item) == {
        "work_item_id": "wi-initial-planning",
        "status": "in_progress",
        "workflow_id": "wf-bootstrap",
        "head_sha": None,
    }
    assert dict(evaluation) == {"status": "pending"}
    assert payload["bootstrap"]["initial_work_item_head_sha"] is None


def test_bootstrap_local_followed_by_agent_prompt_succeeds(tmp_path: Path) -> None:
    repo = _make_git_repo(tmp_path)
    token = _request_bootstrap_token(
        "wf-bootstrap",
        cwd=repo,
        desired_end_state="prepare the initial plan",
    )

    bootstrap = _run_cli(
        [
            "workflow",
            "bootstrap-local",
            "wf-bootstrap",
            "--bootstrap-token",
            token,
        ],
        cwd=repo,
    )
    assert bootstrap.returncode == 0, bootstrap.stderr

    dispatch = _run_cli(
        [
            "dispatch",
            "agent-prompt",
            "--workflow-id",
            "wf-bootstrap",
            "--stage-id",
            "planner",
        ],
        cwd=repo,
    )
    assert dispatch.returncode == 0, dispatch.stderr
    payload = json.loads(dispatch.stdout)
    assert payload["status"] == "ok"
    assert payload["required_subagent_type"] == "planner"
    assert payload["contract"]["goal_id"] == "g-initial-planning"
    assert payload["contract"]["work_item_id"] == "wi-initial-planning"


def test_bootstrap_local_requires_git_repo_for_local_adoption(tmp_path: Path) -> None:
    outside_git = tmp_path / "outside"
    outside_git.mkdir()

    result = _run_cli(
        [
            "workflow",
            "bootstrap-local",
            "wf-bootstrap",
            "--bootstrap-token",
            "bsr_fake",
        ],
        cwd=outside_git,
    )

    assert result.returncode == 1
    payload = json.loads(result.stderr)
    assert "bootstrap-local" in payload["message"]
    assert "git init" in payload["message"]


def test_bootstrap_local_rejects_non_git_worktree_path(tmp_path: Path) -> None:
    outside_git = tmp_path / "outside"
    outside_git.mkdir()
    worktree = tmp_path / "not-a-repo"
    worktree.mkdir()

    result = _run_cli(
        [
            "workflow",
            "bootstrap-local",
            "wf-bootstrap",
            "--bootstrap-token",
            "bsr_fake",
            "--worktree-path",
            str(worktree),
        ],
        cwd=outside_git,
    )

    assert result.returncode == 1
    payload = json.loads(result.stderr)
    assert "requires a git repo/worktree" in payload["message"]
    assert "git init" in payload["message"]


def test_bootstrap_local_normalizes_stale_initial_work_item_head_sha(tmp_path: Path) -> None:
    repo = _make_git_repo(tmp_path)
    first_token = _request_bootstrap_token(
        "wf-bootstrap",
        cwd=repo,
        desired_end_state="prepare the initial plan",
    )

    first = _run_cli(
        [
            "workflow",
            "bootstrap-local",
            "wf-bootstrap",
            "--bootstrap-token",
            first_token,
        ],
        cwd=repo,
    )
    assert first.returncode == 0, first.stderr

    db_path = repo / ".claude" / "state.db"
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        (repo / "README.md").write_text("bootstrap normalization\n")
        subprocess.run(
            ["git", "-C", str(repo), "add", "README.md"],
            capture_output=True,
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(repo), "commit", "-m", "seed head for stale bootstrap test"],
            capture_output=True,
            check=True,
        )
        head_sha = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        conn.execute(
            "UPDATE work_items SET head_sha = ? WHERE work_item_id = ?",
            (head_sha, "wi-initial-planning"),
        )
        conn.execute(
            "UPDATE evaluation_state SET head_sha = ? WHERE workflow_id = ?",
            (head_sha, "wf-bootstrap"),
        )
        conn.commit()
    finally:
        conn.close()

    second_token = _request_bootstrap_token(
        "wf-bootstrap",
        cwd=repo,
        desired_end_state="prepare the initial plan",
    )
    second = _run_cli(
        [
            "workflow",
            "bootstrap-local",
            "wf-bootstrap",
            "--bootstrap-token",
            second_token,
        ],
        cwd=repo,
    )
    assert second.returncode == 0, second.stderr
    payload = json.loads(second.stdout)
    assert payload["bootstrap"]["work_item_seeded"] is False
    assert payload["bootstrap"]["initial_work_item_head_sha"] is None

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        work_item = conn.execute(
            "SELECT head_sha, status FROM work_items WHERE work_item_id = ?",
            ("wi-initial-planning",),
        ).fetchone()
        evaluation = conn.execute(
            "SELECT head_sha, status FROM evaluation_state WHERE workflow_id = ?",
            ("wf-bootstrap",),
        ).fetchone()
    finally:
        conn.close()
    assert dict(work_item) == {"head_sha": None, "status": "in_progress"}
    assert dict(evaluation) == {"head_sha": None, "status": "pending"}


def test_bootstrap_local_uses_explicit_worktree_path_for_db_resolution(tmp_path: Path) -> None:
    target_repo = _make_git_repo(tmp_path, "target")
    other_repo = _make_git_repo(tmp_path, "other")
    (other_repo / ".claude").mkdir()
    other_db = other_repo / ".claude" / "state.db"
    token = _request_bootstrap_token(
        "wf-bootstrap",
        cwd=tmp_path,
        desired_end_state="bootstrap target repo from outside its cwd",
        worktree_path=target_repo,
        extra_env={"CLAUDE_PROJECT_DIR": str(other_repo)},
    )

    result = _run_cli(
        [
            "workflow",
            "bootstrap-local",
            "wf-bootstrap",
            "--bootstrap-token",
            token,
            "--worktree-path",
            str(target_repo),
        ],
        cwd=tmp_path,
        extra_env={"CLAUDE_PROJECT_DIR": str(other_repo)},
    )

    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["bootstrap"]["db_path"] == str(target_repo / ".claude" / "state.db")
    assert payload["bootstrap"]["db_path"] != str(other_db)

    target_conn = sqlite3.connect(str(target_repo / ".claude" / "state.db"))
    target_conn.row_factory = sqlite3.Row
    try:
        target_binding = target_conn.execute(
            "SELECT workflow_id FROM workflow_bindings WHERE workflow_id = ?",
            ("wf-bootstrap",),
        ).fetchone()
    finally:
        target_conn.close()
    assert target_binding is not None

    if other_db.exists():
        other_conn = sqlite3.connect(str(other_db))
        other_conn.row_factory = sqlite3.Row
        try:
            other_binding = other_conn.execute(
                "SELECT workflow_id FROM workflow_bindings WHERE workflow_id = ?",
                ("wf-bootstrap",),
            ).fetchone()
        finally:
            other_conn.close()
        assert other_binding is None

    get_result = _run_cli(
        [
            "workflow",
            "get",
            "wf-bootstrap",
            "--worktree-path",
            str(target_repo),
        ],
        cwd=tmp_path,
        extra_env={"CLAUDE_PROJECT_DIR": str(other_repo)},
    )
    assert get_result.returncode == 0, get_result.stderr


def test_bootstrap_local_requires_runtime_issued_token(tmp_path: Path) -> None:
    repo = _make_git_repo(tmp_path)

    result = _run_cli(
        [
            "workflow",
            "bootstrap-local",
            "wf-bootstrap",
        ],
        cwd=repo,
    )

    assert result.returncode == 2
    assert "--bootstrap-token" in result.stderr


def test_bootstrap_request_records_audit_and_returns_replay_command(tmp_path: Path) -> None:
    repo = _make_git_repo(tmp_path)

    result = _run_cli(
        [
            "workflow",
            "bootstrap-request",
            "wf-bootstrap",
            "--desired-end-state",
            "prepare the initial plan",
            "--requested-by",
            "pytest",
            "--justification",
            "exercise token issuance",
        ],
        cwd=repo,
    )

    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    request = payload["bootstrap_request"]
    assert request["requested_by"] == "pytest"
    assert "bootstrap-local wf-bootstrap --bootstrap-token" in payload["bootstrap_local_command"]

    conn = sqlite3.connect(str(repo / ".claude" / "state.db"))
    conn.row_factory = sqlite3.Row
    try:
        row = conn.execute(
            """
            SELECT workflow_id, worktree_path, requested_by, justification, consumed
            FROM bootstrap_requests
            WHERE token = ?
            """,
            (request["token"],),
        ).fetchone()
        event = conn.execute(
            """
            SELECT type, source
            FROM events
            WHERE type = 'workflow.bootstrap.requested'
            ORDER BY id DESC
            LIMIT 1
            """
        ).fetchone()
    finally:
        conn.close()

    assert dict(row) == {
        "workflow_id": "wf-bootstrap",
        "worktree_path": str(repo.resolve()),
        "requested_by": "pytest",
        "justification": "exercise token issuance",
        "consumed": 0,
    }
    assert dict(event) == {
        "type": "workflow.bootstrap.requested",
        "source": "workflow:wf-bootstrap",
    }


def test_bootstrap_local_consumes_token_once(tmp_path: Path) -> None:
    repo = _make_git_repo(tmp_path)
    token = _request_bootstrap_token(
        "wf-bootstrap",
        cwd=repo,
        desired_end_state="prepare the initial plan",
    )

    first = _run_cli(
        [
            "workflow",
            "bootstrap-local",
            "wf-bootstrap",
            "--bootstrap-token",
            token,
        ],
        cwd=repo,
    )
    assert first.returncode == 0, first.stderr

    second = _run_cli(
        [
            "workflow",
            "bootstrap-local",
            "wf-bootstrap",
            "--bootstrap-token",
            token,
        ],
        cwd=repo,
    )
    assert second.returncode == 1
    payload = json.loads(second.stderr)
    assert "already been consumed" in payload["message"]


# @mock-exempt: race condition simulation — the "lost the race" outcome (SQLite rowcount=0
# after a concurrent UPDATE) cannot be reproduced deterministically without multi-process
# coordination. The mock replaces only consume() at the workflow_bootstrap call site to
# simulate exactly the outcome that a real concurrent loser would see. No other internal
# code is mocked; DB writes (workflow_bindings, goal_contracts, work_items) are real and
# inspected directly to verify atomicity.
def test_bootstrap_local_consume_precedes_writes_under_race(tmp_path: Path) -> None:
    """When consume() fails (simulated race loss), no DB writes must have landed.

    This test verifies DEC-ADMIT-001: consume() fires BEFORE bind_workflow/upsert_goal/
    upsert_work_item. If consume() raises BootstrapRequestError before those calls,
    no workflow_bindings / goal_contracts / work_items rows exist for the workflow.

    The production sequence being exercised:
      1. resolve_pending() validates the token (read-only)
      2. consume() atomically claims the token via UPDATE … WHERE consumed = 0
         → if rowcount=0, raises BootstrapRequestError (race lost)
      3. bind_workflow / upsert_goal / upsert_work_item (writes, skipped on race loss)

    The mock simulates step 2 failing. Real DB assertions verify step 3 never ran.
    """
    from unittest.mock import patch  # @mock-exempt (see module annotation above)

    from runtime.core import workflow_bootstrap as workflow_bootstrap_mod
    from runtime.core.bootstrap_requests import BootstrapRequestError

    repo = _make_git_repo(tmp_path)

    # Issue a real token so resolve_pending passes pre-consume validation.
    token = _request_bootstrap_token(
        "wf-race",
        cwd=repo,
        desired_end_state="test consume-before-writes atomicity",
    )

    # Patch consume on the reference used inside workflow_bootstrap so the winner-check
    # (UPDATE rowcount) fails, simulating the "lost the race" outcome.
    with patch.object(
        workflow_bootstrap_mod.bootstrap_requests_mod,
        "consume",
        side_effect=BootstrapRequestError(
            "bootstrap token could not be consumed atomically; request a new token"
        ),
    ):
        import pytest as _pytest

        with _pytest.raises(Exception):
            workflow_bootstrap_mod.bootstrap_local_workflow(
                workflow_id="wf-race",
                bootstrap_token=token,
                desired_end_state="test consume-before-writes atomicity",
                worktree_path=str(repo),
            )

    # Verify: no writes landed. The DB may not even exist if the schema seeding
    # itself is skipped — but if it does exist, rows must be absent.
    db_path = repo / ".claude" / "state.db"
    if not db_path.exists():
        # DB was never created — writes definitely did not land.
        return

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        binding = conn.execute(
            "SELECT workflow_id FROM workflow_bindings WHERE workflow_id = ?",
            ("wf-race",),
        ).fetchone()
        goal = conn.execute(
            "SELECT goal_id FROM goal_contracts WHERE goal_id = ?",
            ("g-initial-planning",),
        ).fetchone()
        work_item = conn.execute(
            "SELECT work_item_id FROM work_items WHERE work_item_id = ? AND workflow_id = ?",
            ("wi-initial-planning", "wf-race"),
        ).fetchone()
    finally:
        conn.close()

    assert binding is None, (
        "workflow_bindings row found after consume() race loss — "
        "DEC-ADMIT-001 atomicity invariant violated: writes landed before consume() succeeded"
    )
    assert goal is None, (
        "goal_contracts row found after consume() race loss — "
        "DEC-ADMIT-001 atomicity invariant violated: writes landed before consume() succeeded"
    )
    assert work_item is None, (
        "work_items row found after consume() race loss — "
        "DEC-ADMIT-001 atomicity invariant violated: writes landed before consume() succeeded"
    )


def test_resolve_pending_token_not_found_names_db_path_and_worktree_scoping(
    tmp_path: Path,
) -> None:
    """token-not-found error includes db_path, scoped-to-worktree hint, and --worktree-path.

    Verifies DEC-ADMIT-002: when resolve_pending() is called with a db_path and the token
    does not exist in that DB, the raised BootstrapRequestError message contains:
      (i)  the resolved db_path string
      (ii) the phrase "scoped to the worktree"
      (iii) the string "--worktree-path"

    This exercises the production sequence for an operator who ran bootstrap-request
    in repo A, then ran bootstrap-local --worktree-path repo_B, resolving a different DB
    that has no record of the token.
    """
    import sqlite3 as _sqlite3

    from runtime.core.bootstrap_requests import BootstrapRequestError, resolve_pending
    from runtime.core.db import connect
    from runtime.schemas import ensure_schema

    # Build a real empty DB — no bootstrap_requests rows in it.
    db_dir = tmp_path / ".claude"
    db_dir.mkdir()
    db_file = db_dir / "state.db"
    conn = connect(db_file)
    ensure_schema(conn)
    conn.row_factory = _sqlite3.Row

    fake_token = "bsr_notpresent_xyzzy"
    resolved_db_path = str(db_file)

    try:
        resolve_pending(
            conn,
            token=fake_token,
            workflow_id="wf-wrong-worktree",
            worktree_path=str(tmp_path),
            db_path=resolved_db_path,
        )
    except BootstrapRequestError as exc:
        msg = str(exc)
        assert resolved_db_path in msg, (
            f"Expected db_path {resolved_db_path!r} in error message, got: {msg!r}"
        )
        assert "scoped to the worktree" in msg, (
            f"Expected 'scoped to the worktree' in error message, got: {msg!r}"
        )
        assert "--worktree-path" in msg, (
            f"Expected '--worktree-path' in error message, got: {msg!r}"
        )
    else:
        raise AssertionError(
            "Expected BootstrapRequestError for missing token, but no exception was raised"
        )
    finally:
        conn.close()
