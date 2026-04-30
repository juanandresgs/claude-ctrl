from __future__ import annotations

import json
import os
import subprocess
import sys
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path

from runtime import cli
from runtime.core.command_intent import build_bash_command_intent
from runtime.core.policy_engine import PolicyContext, PolicyRequest
from runtime.core.policies import bash_scratchlane_gate
from runtime.core.policies.bash_write_who import check as bash_write_who
from runtime.core.policies.write_scratchlane_gate import check as write_scratchlane_gate


def _make_context(
    project_root: Path,
    *,
    capabilities: frozenset[str] = frozenset(),
    scratchlane_roots: frozenset[str] = frozenset(),
) -> PolicyContext:
    return PolicyContext(
        actor_role="",
        actor_id="",
        workflow_id="wf-test",
        worktree_path=str(project_root),
        branch="feature/test",
        project_root=str(project_root),
        is_meta_repo=False,
        lease=None,
        scope=None,
        eval_state=None,
        test_state=None,
        binding=None,
        dispatch_phase=None,
        enforcement_config={},
        capabilities=capabilities,
        worktree_lease_suppressed_roles=frozenset(),
        scratchlane_roots=scratchlane_roots,
    )


def _run_cli(argv: list[str], monkeypatch, *, db_path: Path) -> dict:
    monkeypatch.setenv("CLAUDE_POLICY_DB", str(db_path))
    buf = StringIO()
    with redirect_stdout(buf):
        rc = cli.main(argv)
    assert rc == 0
    return json.loads(buf.getvalue())


def test_scratchlane_cli_grant_get_list_roundtrip(tmp_path, monkeypatch):
    project_root = tmp_path / "project"
    project_root.mkdir()
    db_path = tmp_path / "state.db"

    grant = _run_cli(
        [
            "scratchlane",
            "grant",
            "--project-root",
            str(project_root),
            "--task-slug",
            "dedup",
            "--note",
            "tmp automation",
        ],
        monkeypatch,
        db_path=db_path,
    )
    permit = grant["permit"]
    expected_root = project_root / "tmp" / ".claude-scratch" / "dedup"
    assert Path(permit["root_path"]) == expected_root
    assert expected_root.is_dir()

    get_payload = _run_cli(
        [
            "scratchlane",
            "get",
            "--project-root",
            str(project_root),
            "--task-slug",
            "dedup",
        ],
        monkeypatch,
        db_path=db_path,
    )
    assert get_payload["found"] is True
    assert get_payload["permit"]["task_slug"] == "dedup"

    list_payload = _run_cli(
        ["scratchlane", "list", "--project-root", str(project_root)],
        monkeypatch,
        db_path=db_path,
    )
    assert list_payload["count"] == 1
    assert list_payload["items"][0]["root_path"] == str(expected_root)


def test_write_scratchlane_gate_redirects_tmp_source_candidate(tmp_path):
    project_root = tmp_path
    request = PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={
            "file_path": str(project_root / "tmp" / "dedup.py"),
            "content": "print('hi')\n",
        },
        context=_make_context(project_root),
        cwd=str(project_root),
    )

    decision = write_scratchlane_gate(request)
    assert decision is not None
    assert decision.action == "deny"
    assert "scratchlane" in decision.reason
    assert "runtime/cli.py scratchlane grant --task-slug dedup" in decision.reason


def test_write_scratchlane_gate_allows_approved_scratchlane(tmp_path):
    project_root = tmp_path
    scratch_root = project_root / "tmp" / ".claude-scratch" / "dedup"
    scratch_root.mkdir(parents=True)
    request = PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={
            "file_path": str(scratch_root / "dedup.py"),
            "content": "print('hi')\n",
        },
        context=_make_context(project_root, scratchlane_roots=frozenset({str(scratch_root)})),
        cwd=str(project_root),
    )

    assert write_scratchlane_gate(request) is None


def test_bash_scratchlane_gate_denies_raw_interpreter(tmp_path):
    project_root = tmp_path
    command = "python3 - <<'PY'\nprint('hi')\nPY"
    request = PolicyRequest(
        event_type="PreToolUse",
        tool_name="Bash",
        tool_input={"command": command},
        context=_make_context(project_root),
        cwd=str(project_root),
        command_intent=build_bash_command_intent(command, cwd=str(project_root)),
    )

    decision = bash_scratchlane_gate.check(request)
    assert decision is not None
    assert decision.action == "deny"
    assert "scripts/scratchlane-exec.sh" in decision.reason


def test_bash_scratchlane_gate_allows_wrapper_command(tmp_path):
    project_root = tmp_path
    command = "./scripts/scratchlane-exec.sh --task-slug dedup -- python3 -c 'print(1)'"
    request = PolicyRequest(
        event_type="PreToolUse",
        tool_name="Bash",
        tool_input={"command": command},
        context=_make_context(project_root),
        cwd=str(project_root),
        command_intent=build_bash_command_intent(command, cwd=str(project_root)),
    )

    assert bash_scratchlane_gate.check(request) is None


def test_bash_write_who_ignores_approved_scratchlane_visible_write(tmp_path):
    project_root = tmp_path
    scratch_root = project_root / "tmp" / ".claude-scratch" / "notes"
    scratch_root.mkdir(parents=True)
    command = f"echo hi > {scratch_root / 'note.py'}"
    request = PolicyRequest(
        event_type="PreToolUse",
        tool_name="Bash",
        tool_input={"command": command},
        context=_make_context(project_root, scratchlane_roots=frozenset({str(scratch_root)})),
        cwd=str(project_root),
        command_intent=build_bash_command_intent(command, cwd=str(project_root)),
    )

    assert bash_scratchlane_gate.check(request) is None
    assert bash_write_who(request) is None


def test_scratchlane_exec_wrapper_uses_active_permit(tmp_path, monkeypatch):
    repo_root = Path(__file__).resolve().parents[2]
    db_path = tmp_path / "state.db"
    task_slug = "pytest-scratchlane"

    monkeypatch.setenv("CLAUDE_POLICY_DB", str(db_path))
    grant = subprocess.run(
        [
            sys.executable,
            str(repo_root / "runtime" / "cli.py"),
            "scratchlane",
            "grant",
            "--project-root",
            str(repo_root),
            "--task-slug",
            task_slug,
        ],
        check=True,
        capture_output=True,
        text=True,
        cwd=repo_root,
    )
    scratch_root = Path(json.loads(grant.stdout)["permit"]["root_path"])

    fakebin = tmp_path / "fakebin"
    fakebin.mkdir()
    fake_sandbox = fakebin / "sandbox-exec"
    fake_sandbox.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "[[ \"$1\" == \"-f\" ]]\n"
        "PROFILE=\"$2\"\n"
        "shift 2\n"
        "test -f \"$PROFILE\"\n"
        "exec \"$@\"\n",
        encoding="utf-8",
    )
    fake_sandbox.chmod(0o755)

    marker = tmp_path / "marker.txt"
    env = os.environ.copy()
    env["CLAUDE_POLICY_DB"] = str(db_path)
    env["PATH"] = f"{fakebin}{os.pathsep}{env['PATH']}"

    subprocess.run(
        [
            str(repo_root / "scripts" / "scratchlane-exec.sh"),
            "--task-slug",
            task_slug,
            "--",
            "/bin/sh",
            "-c",
            'test -d "$CC_SCRATCH_ROOT" && test -d "$TMPDIR" && pwd > "$1"',
            "_",
            str(marker),
        ],
        check=True,
        cwd=repo_root,
        env=env,
    )

    assert marker.read_text(encoding="utf-8").strip() == str(scratch_root)
