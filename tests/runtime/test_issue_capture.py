"""Tests for runtime.core.issue_capture."""

from __future__ import annotations

import sys
from pathlib import Path
import unittest.mock as mock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import runtime.core.events as events
import runtime.core.issue_capture as issue_capture
from runtime.core.db import connect_memory
from runtime.schemas import ensure_schema


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


def _todo_sh(tmp_path: Path, issue_url: str = "https://github.com/org/repo/issues/42") -> str:
    script = tmp_path / "todo.sh"
    script.write_text(f"#!/usr/bin/env bash\necho '{issue_url}'\n")
    script.chmod(0o755)
    return str(script)


def test_file_issue_project_scope_persists_and_emits_event(conn, tmp_path):
    todo_sh = _todo_sh(tmp_path)

    result = issue_capture.file_issue(
        conn,
        item_kind="follow_up",
        title="reviewer follow-up",
        body="body",
        scope="project",
        source_component="reviewer",
        evidence="reviewer noted it",
        project_root=str(tmp_path),
        todo_sh_path=todo_sh,
    )

    assert result["disposition"] == "filed"
    assert result["scope"] == "project"
    assert result["issue_url"] == "https://github.com/org/repo/issues/42"
    row = issue_capture.get_by_fingerprint(conn, result["fingerprint"])
    assert row is not None
    assert row["item_kind"] == "follow_up"
    assert row["encounter_count"] == 1
    assert len(events.query(conn, type="issue_filed")) == 1


def test_duplicate_issue_does_not_refile(conn, tmp_path):
    todo_sh = _todo_sh(tmp_path)
    calls = 0

    def fake_run(cmd, **kwargs):
        nonlocal calls
        calls += 1
        proc = mock.MagicMock()
        proc.returncode = 0
        proc.stdout = "https://github.com/org/repo/issues/77"
        return proc

    kwargs = dict(
        item_kind="task",
        title="same task",
        body="body",
        scope="project",
        project_root=str(tmp_path),
        todo_sh_path=todo_sh,
    )
    with mock.patch("subprocess.run", side_effect=fake_run):
        first = issue_capture.file_issue(conn, **kwargs)
        second = issue_capture.file_issue(conn, **kwargs)

    assert first["disposition"] == "filed"
    assert second["disposition"] == "duplicate"
    assert second["encounter_count"] == 2
    assert calls == 1


def test_config_route_uses_repo_adapter_when_config_path_is_implicated(conn, tmp_path):
    todo_sh = _todo_sh(tmp_path)
    config_root = tmp_path / ".claude"
    config_root.mkdir()

    with mock.patch.object(
        issue_capture, "_DEFAULT_CONFIG_ROOT", config_root
    ), mock.patch.object(
        issue_capture, "_infer_github_repo", return_value="owner/config"
    ), mock.patch(
        "subprocess.run"
    ) as run:
        proc = mock.MagicMock()
        proc.returncode = 0
        proc.stdout = "https://github.com/owner/config/issues/9"
        run.return_value = proc

        result = issue_capture.file_issue(
            conn,
            item_kind="bug",
            title="config bug",
            body="body",
            scope="auto",
            source_component=str(config_root / "hooks" / "stop-advisor.sh"),
            file_path=str(config_root / "hooks" / "stop-advisor.sh"),
            evidence="hook blocked the wrong stop",
            project_root=str(tmp_path / "project"),
            todo_sh_path=todo_sh,
        )

    assert result["disposition"] == "filed"
    assert result["scope"] == "config"
    assert result["repo"] == "owner/config"
    cmd = run.call_args.args[0]
    assert cmd[:4] == [todo_sh, "add", "--repo", "owner/config"]


def test_explicit_repo_wins_over_scope(conn, tmp_path):
    todo_sh = _todo_sh(tmp_path)

    with mock.patch("subprocess.run") as run:
        proc = mock.MagicMock()
        proc.returncode = 0
        proc.stdout = "https://github.com/owner/target/issues/12"
        run.return_value = proc
        result = issue_capture.file_issue(
            conn,
            item_kind="tech_debt",
            title="route explicitly",
            body="body",
            scope="global",
            repo="owner/target",
            project_root=str(tmp_path),
            todo_sh_path=todo_sh,
        )

    assert result["scope"] == "explicit"
    assert result["repo"] == "owner/target"
    cmd = run.call_args.args[0]
    assert cmd[:4] == [todo_sh, "add", "--repo", "owner/target"]


def test_bug_kind_requires_evidence(conn):
    result = issue_capture.file_issue(
        conn,
        item_kind="bug",
        title="missing evidence",
        scope="project",
    )
    assert result["disposition"] == "rejected_non_issue"

