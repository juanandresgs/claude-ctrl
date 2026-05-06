"""Tests for Bash PostToolUse test-state projection."""

from __future__ import annotations

import sqlite3
import subprocess
from pathlib import Path

from runtime.core import bash_lifecycle, test_state
from runtime.schemas import ensure_schema


def _git(cwd: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(cwd), *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def _repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test User")
    (repo / "README.md").write_text("seed\n", encoding="utf-8")
    _git(repo, "add", "README.md")
    _git(repo, "commit", "-m", "seed")
    return repo


def _conn() -> sqlite3.Connection:
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    ensure_schema(conn)
    return conn


def test_post_bash_projects_passing_pytest_output(tmp_path: Path):
    repo = _repo(tmp_path)
    conn = _conn()
    try:
        payload = {
            "hook_event_name": "PostToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "python3 -m pytest tests/runtime -q"},
            "tool_response": {
                "exit_code": 0,
                "output": "================ 12 passed in 0.31s ================",
            },
            "cwd": str(repo),
        }
        result = bash_lifecycle.handle_post_bash(conn, payload)
        state = test_state.get_status(conn, str(repo))

        assert result.projected_test_state is True
        assert result.test_status == "pass"
        assert state["status"] == "pass"
        assert state["pass_count"] == 12
        assert state["fail_count"] == 0
        assert state["total_count"] == 12
        assert state["head_sha"] == _git(repo, "rev-parse", "HEAD")
    finally:
        conn.close()


def test_post_bash_detects_uv_run_pytest(tmp_path: Path):
    repo = _repo(tmp_path)
    conn = _conn()
    try:
        payload = {
            "hook_event_name": "PostToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "uv run pytest tests/runtime -q"},
            "tool_response": {
                "exit_code": 0,
                "output": "8 passed in 0.12s",
            },
            "cwd": str(repo),
        }
        result = bash_lifecycle.handle_post_bash(conn, payload)
        state = test_state.get_status(conn, str(repo))

        assert result.projected_test_state is True
        assert state["status"] == "pass"
        assert state["pass_count"] == 8
    finally:
        conn.close()


def test_post_bash_projects_failing_cargo_output(tmp_path: Path):
    repo = _repo(tmp_path)
    conn = _conn()
    try:
        payload = {
            "hook_event_name": "PostToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "cargo test --workspace"},
            "tool_response": {
                "exit_code": 101,
                "output": "test result: FAILED. 3 passed; 1 failed; 0 ignored",
            },
            "cwd": str(repo),
        }
        result = bash_lifecycle.handle_post_bash(conn, payload)
        state = test_state.get_status(conn, str(repo))

        assert result.projected_test_state is True
        assert result.test_status == "fail"
        assert state["status"] == "fail"
        assert state["pass_count"] == 3
        assert state["fail_count"] == 1
        assert state["total_count"] == 4
    finally:
        conn.close()


def test_post_bash_non_test_command_does_not_touch_test_state(tmp_path: Path):
    repo = _repo(tmp_path)
    conn = _conn()
    try:
        payload = {
            "hook_event_name": "PostToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "ls -la"},
            "tool_response": {"exit_code": 0, "output": ""},
            "cwd": str(repo),
        }
        result = bash_lifecycle.handle_post_bash(conn, payload)
        state = test_state.get_status(conn, str(repo))

        assert result.projected_test_state is False
        assert state["found"] is False
    finally:
        conn.close()
