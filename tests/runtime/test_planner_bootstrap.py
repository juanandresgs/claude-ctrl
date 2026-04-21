"""Tests for the runtime-owned planner bootstrap authority."""

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


def _run_cli(args: list[str], *, cwd: Path, extra_env: dict | None = None) -> subprocess.CompletedProcess[str]:
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


def test_bootstrap_planner_creates_local_state_db_and_returns_launch_spec(tmp_path: Path) -> None:
    repo = _make_git_repo(tmp_path)

    result = _run_cli(
        [
            "workflow",
            "bootstrap-planner",
            "wf-bootstrap",
            "--desired-end-state",
            "adopt synthesis into root plan",
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
            "SELECT work_item_id, status, workflow_id FROM work_items WHERE work_item_id = ?",
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
    }
    assert dict(evaluation) == {"status": "pending"}


def test_bootstrap_planner_followed_by_agent_prompt_succeeds(tmp_path: Path) -> None:
    repo = _make_git_repo(tmp_path)

    bootstrap = _run_cli(
        [
            "workflow",
            "bootstrap-planner",
            "wf-bootstrap",
            "--desired-end-state",
            "prepare the initial plan",
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


def test_bootstrap_planner_requires_git_repo_for_local_adoption(tmp_path: Path) -> None:
    outside_git = tmp_path / "outside"
    outside_git.mkdir()

    result = _run_cli(
        [
            "workflow",
            "bootstrap-planner",
            "wf-bootstrap",
            "--desired-end-state",
            "plan from a non-git directory",
        ],
        cwd=outside_git,
    )

    assert result.returncode == 1
    payload = json.loads(result.stderr)
    assert "bootstrap-planner" in payload["message"]
    assert "git init" in payload["message"]


def test_bootstrap_planner_rejects_non_git_worktree_path(tmp_path: Path) -> None:
    outside_git = tmp_path / "outside"
    outside_git.mkdir()
    worktree = tmp_path / "not-a-repo"
    worktree.mkdir()

    result = _run_cli(
        [
            "workflow",
            "bootstrap-planner",
            "wf-bootstrap",
            "--desired-end-state",
            "bootstrap planner",
            "--worktree-path",
            str(worktree),
        ],
        cwd=outside_git,
    )

    assert result.returncode == 1
    payload = json.loads(result.stderr)
    assert "requires a git repo/worktree" in payload["message"]
    assert "git init" in payload["message"]
