"""Tests for runtime-owned checkout hygiene classification.

@decision DEC-CLAUDEX-CHECKOUT-HYGIENE-001
Title: checkout hygiene classification is runtime-owned and CLI-addressable
Status: accepted
"""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from runtime.core.checkout_hygiene import classify_checkout_hygiene
from runtime.core.workflows import bind_workflow, set_scope
from runtime.schemas import ensure_schema

_REPO_ROOT = Path(__file__).resolve().parents[2]


def _git(repo: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
    )


def _init_repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    (repo / "scripts").mkdir(parents=True)
    (repo / "runtime").mkdir(parents=True)
    (repo / "hooks").mkdir(parents=True)
    (repo / "docs").mkdir(parents=True)

    (repo / "scripts" / "statusline.sh").write_text("#!/usr/bin/env bash\n")
    (repo / "runtime" / "cli.py").write_text("print('ok')\n")
    (repo / "hooks" / "pre-agent.sh").write_text("#!/usr/bin/env bash\n")
    (repo / "docs" / "spec.md").write_text("spec\n")

    _git(tmp_path, "init", "-b", "main", str(repo))
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test User")
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "init")
    return repo


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


def test_classifies_active_baseline_ephemeral_and_unexpected(conn, tmp_path: Path):
    repo = _init_repo(tmp_path)
    bind_workflow(conn, "wf-hygiene", str(repo), "feature/hygiene")
    set_scope(
        conn,
        "wf-hygiene",
        allowed_paths=["runtime/*.py"],
        required_paths=[],
        forbidden_paths=["hooks/*.sh"],
        authority_domains=[],
    )

    (repo / "scripts" / "statusline.sh").write_text("#!/usr/bin/env bash\necho baseline\n")
    (repo / "runtime" / "cli.py").write_text("print('active slice')\n")
    (repo / "hooks" / "pre-agent.sh").write_text("#!/usr/bin/env bash\necho forbidden\n")
    (repo / "docs" / "spec.md").write_text("changed outside scope\n")
    (repo / "abtop-rate-limits.json").write_text("{}\n")
    (repo / "policy.db").write_text("sqlite-junk\n")
    (repo / ".prompt-count-123").write_text("9\n")

    result = classify_checkout_hygiene(conn, worktree_path=str(repo))

    assert result["workflow_id"] == "wf-hygiene"
    assert result["scope_found"] is True
    assert result["active_slice_count"] == 1
    assert result["baseline_tolerated_count"] == 2
    assert result["ephemeral_runtime_count"] == 2
    assert result["unexpected_drift_count"] == 2
    assert result["display_dirty_count"] == 5
    assert {item["path"] for item in result["active_slice_changes"]} == {"runtime/cli.py"}
    assert {item["path"] for item in result["baseline_tolerated_changes"]} == {
        "scripts/statusline.sh",
        "abtop-rate-limits.json",
    }
    assert {item["path"] for item in result["ephemeral_runtime_artifacts"]} == {
        "policy.db",
        ".prompt-count-123",
    }
    assert {
        (item["path"], item["reason"])
        for item in result["unexpected_drift"]
    } == {
        ("hooks/pre-agent.sh", "FORBIDDEN"),
        ("docs/spec.md", "OUT_OF_SCOPE"),
    }


def test_without_binding_treats_non_baseline_as_active(conn, tmp_path: Path):
    repo = _init_repo(tmp_path)
    (repo / "runtime" / "cli.py").write_text("print('active slice')\n")
    (repo / "policy.db").write_text("sqlite-junk\n")

    result = classify_checkout_hygiene(conn, worktree_path=str(repo))

    assert result["workflow_id"] is None
    assert result["scope_found"] is False
    assert {item["path"] for item in result["active_slice_changes"]} == {"runtime/cli.py"}
    assert {item["path"] for item in result["ephemeral_runtime_artifacts"]} == {"policy.db"}


def test_statusline_hygiene_cli_returns_runtime_authority_json(tmp_path: Path):
    repo = _init_repo(tmp_path)
    db_path = tmp_path / "state.db"

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    ensure_schema(conn)
    bind_workflow(conn, "wf-cli", str(repo), "feature/cli")
    set_scope(
        conn,
        "wf-cli",
        allowed_paths=["runtime/*.py"],
        required_paths=[],
        forbidden_paths=[],
        authority_domains=[],
    )
    conn.commit()
    conn.close()

    (repo / "runtime" / "cli.py").write_text("print('active slice')\n")
    (repo / "abtop-statusline.sh").write_text("#!/usr/bin/env bash\necho sidecar\n")

    proc = subprocess.run(
        [
            sys.executable,
            str(_REPO_ROOT / "runtime" / "cli.py"),
            "statusline",
            "hygiene",
            "--worktree-path",
            str(repo),
        ],
        check=True,
        capture_output=True,
        text=True,
        env={
            **os.environ,
            "CLAUDE_POLICY_DB": str(db_path),
            "PYTHONPATH": str(_REPO_ROOT),
        },
        cwd=str(_REPO_ROOT),
    )
    payload = json.loads(proc.stdout)
    assert payload["status"] == "ok"
    assert payload["workflow_id"] == "wf-cli"
    assert payload["active_slice_count"] == 1
    assert payload["baseline_tolerated_count"] == 1
