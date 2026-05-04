"""Tests for runtime-owned hook event envelope construction."""

from __future__ import annotations

import subprocess

from runtime.core.hook_envelope import build_hook_event_envelope


def _git(cwd, *args):
    return subprocess.run(
        ["git", "-C", str(cwd), *args],
        check=True,
        capture_output=True,
        text=True,
    )


def test_bash_envelope_resolves_git_dash_c_target(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init")

    payload = {
        "event_type": "PreToolUse",
        "tool_name": "Bash",
        "cwd": str(tmp_path),
        "session_id": "s1",
        "tool_use_id": "t1",
        "actor_role": "guardian:land",
        "actor_id": "agent-1",
        "actor_workflow_id": "wf-1",
        "tool_input": {"command": f"git -C {repo} status --short"},
    }

    envelope = build_hook_event_envelope(payload)

    assert envelope.cwd == str(tmp_path)
    assert envelope.target_cwd == str(repo)
    assert envelope.project_root == str(repo)
    assert envelope.effective_cwd == str(repo)
    assert envelope.actor_role == "guardian:land"
    assert envelope.command_intent is not None
    assert [op.invocation.subcommand for op in envelope.command_intent.git_operations] == ["status"]


def test_bash_envelope_honors_explicit_target_cwd_override(tmp_path):
    session_repo = tmp_path / "session"
    target_repo = tmp_path / "target"
    session_repo.mkdir()
    target_repo.mkdir()
    _git(session_repo, "init")
    _git(target_repo, "init")

    payload = {
        "event_type": "PreToolUse",
        "tool_name": "Bash",
        "cwd": str(session_repo),
        "target_cwd": str(target_repo),
        "tool_input": {"command": "git status --short"},
    }

    envelope = build_hook_event_envelope(payload)

    assert envelope.target_cwd == str(target_repo)
    assert envelope.project_root == str(target_repo)
    assert envelope.effective_cwd == str(target_repo)


def test_write_envelope_resolves_relative_file_path_from_payload_cwd(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init")
    (repo / "src").mkdir()

    payload = {
        "event_type": "PreToolUse",
        "tool_name": "Write",
        "cwd": str(repo),
        "tool_input": {"file_path": "src/app.ts", "content": "export {}\n"},
    }

    envelope = build_hook_event_envelope(payload)

    assert envelope.target_path == str(repo / "src" / "app.ts")
    assert envelope.tool_input["file_path"] == str(repo / "src" / "app.ts")
    assert envelope.target_cwd == str(repo / "src")
    assert envelope.project_root == str(repo)
    assert envelope.effective_cwd == str(repo / "src")


def test_write_envelope_resolves_relative_file_path_from_subdir_payload_cwd(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init")
    (repo / "src").mkdir()
    subdir = repo / "src"

    payload = {
        "event_type": "PreToolUse",
        "tool_name": "Write",
        "cwd": str(subdir),
        "tool_input": {"file_path": "app.ts", "content": "export {}\n"},
    }

    envelope = build_hook_event_envelope(payload)

    assert envelope.cwd == str(subdir)
    assert envelope.target_path == str(repo / "src" / "app.ts")
    assert envelope.tool_input["file_path"] == str(repo / "src" / "app.ts")
    assert envelope.target_cwd == str(repo / "src")
    assert envelope.project_root == str(repo)


def test_write_envelope_resolves_non_git_project_by_state_db_ancestor(tmp_path):
    project = tmp_path / "project"
    nested = project / "lsdyna_isolated" / "tmp" / "ad-hoc"
    nested.mkdir(parents=True)
    (project / ".claude").mkdir()
    (project / ".claude" / "state.db").write_text("", encoding="utf-8")
    (project / "lsdyna_isolated" / "tmp" / ".claude").mkdir()
    (project / "lsdyna_isolated" / "tmp" / ".claude" / "state.db").write_text(
        "",
        encoding="utf-8",
    )

    payload = {
        "event_type": "PreToolUse",
        "tool_name": "Write",
        "cwd": str(project / "lsdyna_isolated"),
        "tool_input": {
            "file_path": str(nested / "ida_fast16_map.py"),
            "content": "print('hi')\n",
        },
    }

    envelope = build_hook_event_envelope(payload)

    assert envelope.target_cwd == str(nested)
    assert envelope.project_root == str(project)


def test_write_envelope_anchors_non_git_first_write_to_payload_cwd(tmp_path):
    project = tmp_path / "project"
    nested = project / "site" / "src" / "pages"
    nested.mkdir(parents=True)

    payload = {
        "event_type": "PreToolUse",
        "tool_name": "Write",
        "cwd": str(project),
        "tool_input": {
            "file_path": str(nested / "index.astro"),
            "content": "---\n---\n",
        },
    }

    envelope = build_hook_event_envelope(payload)

    assert envelope.target_cwd == str(nested)
    assert envelope.project_root == str(project)
