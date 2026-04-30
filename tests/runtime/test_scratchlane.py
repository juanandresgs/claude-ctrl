from __future__ import annotations

import json
import os
import subprocess
import sys
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path

from runtime import cli
from runtime.core import scratchlanes
from runtime.core.command_intent import build_bash_command_intent
from runtime.core.db import connect, connect_memory
from runtime.core.policy_engine import PolicyContext, PolicyRequest
from runtime.core.policies import bash_scratchlane_gate
from runtime.core.policies.bash_write_who import check as bash_write_who
from runtime.core.policies.write_scratchlane_gate import check as write_scratchlane_gate
from runtime.schemas import ensure_schema

_WORKTREE = Path(__file__).resolve().parents[2]
_CLI = _WORKTREE / "runtime" / "cli.py"
_PROMPT_SUBMIT_HOOK = _WORKTREE / "hooks" / "prompt-submit.sh"
_PRE_WRITE_HOOK = _WORKTREE / "hooks" / "pre-write.sh"


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


def _run_cli_raw(
    argv: list[str],
    *,
    db_path: Path,
    stdin_text: str = "",
    extra_env: dict[str, str] | None = None,
) -> tuple[int, str, str]:
    env = {
        **os.environ,
        "CLAUDE_POLICY_DB": str(db_path),
        "PYTHONPATH": str(_WORKTREE),
    }
    if extra_env:
        env.update(extra_env)
    result = subprocess.run(
        [sys.executable, str(_CLI)] + argv,
        input=stdin_text,
        capture_output=True,
        text=True,
        cwd=_WORKTREE,
        env=env,
    )
    return result.returncode, result.stdout, result.stderr


def _run_evaluate(
    payload: dict,
    *,
    db_path: Path,
    extra_env: dict[str, str] | None = None,
) -> tuple[int, dict]:
    code, stdout, stderr = _run_cli_raw(
        ["evaluate"],
        db_path=db_path,
        stdin_text=json.dumps(payload),
        extra_env=extra_env,
    )
    parsed = json.loads((stdout or stderr).strip() or "{}")
    return code, parsed


def _init_git_repo(project_root: Path) -> None:
    subprocess.run(["git", "init", "-q"], cwd=project_root, check=True)
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=Scratchlane Test",
            "-c",
            "user.email=scratchlane@example.com",
            "commit",
            "--allow-empty",
            "-m",
            "init",
            "-q",
        ],
        cwd=project_root,
        check=True,
    )


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
    assert "runtime will activate it automatically" in decision.reason
    assert "Do not tell the user to run any command." in decision.reason
    assert decision.effects is not None
    assert decision.effects["request_scratchlane_approval"]["task_slug"] == "dedup"
    assert (
        decision.effects["request_scratchlane_approval"]["request_reason"]
        == "tmp_source_candidate"
    )


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
    assert "runtime will activate it automatically" in decision.reason
    assert decision.effects is not None
    assert decision.effects["request_scratchlane_approval"]["task_slug"] == "ad-hoc"
    assert "--project-root" in decision.reason
    assert str(project_root) in decision.reason
    assert (
        decision.effects["request_scratchlane_approval"]["request_reason"]
        == "opaque_interpreter"
    )


def test_bash_scratchlane_gate_allows_absolute_runtime_wrapper_command(tmp_path):
    project_root = tmp_path
    wrapper = _WORKTREE / "scripts" / "scratchlane-exec.sh"
    command = (
        f"{wrapper} --task-slug dedup --project-root {project_root} -- bash -c "
        "'cd /tmp && cc-policy evaluation get wf | python3 -c \"print(1)\"'"
    )
    request = PolicyRequest(
        event_type="PreToolUse",
        tool_name="Bash",
        tool_input={"command": command},
        context=_make_context(project_root),
        cwd=str(project_root),
        command_intent=build_bash_command_intent(command, cwd=str(project_root)),
    )

    assert bash_scratchlane_gate.check(request) is None


def test_bash_scratchlane_gate_allows_relative_wrapper_only_from_runtime_root():
    project_root = _WORKTREE
    command = (
        "./scripts/scratchlane-exec.sh --task-slug dedup "
        f"--project-root {project_root} -- python3 -c 'print(1)'"
    )
    request = PolicyRequest(
        event_type="PreToolUse",
        tool_name="Bash",
        tool_input={"command": command},
        context=_make_context(project_root),
        cwd=str(project_root),
        command_intent=build_bash_command_intent(command, cwd=str(project_root)),
    )

    assert bash_scratchlane_gate.check(request) is None


def test_bash_scratchlane_gate_requires_project_root_on_runtime_wrapper(tmp_path):
    project_root = tmp_path
    wrapper = _WORKTREE / "scripts" / "scratchlane-exec.sh"
    command = f"{wrapper} --task-slug dedup -- python3 -c 'print(1)'"
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
    assert "declare the governed project root" in decision.reason
    assert f"--project-root {project_root}" in decision.reason


def test_bash_scratchlane_gate_denies_relative_wrapper_from_other_repo(tmp_path):
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

    decision = bash_scratchlane_gate.check(request)
    assert decision is not None
    assert decision.action == "deny"
    assert "runtime-owned wrapper" in decision.reason
    assert str(_WORKTREE / "scripts" / "scratchlane-exec.sh") in decision.reason


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


def test_scratchlane_request_roundtrip_approve(tmp_path):
    conn = connect_memory()
    ensure_schema(conn)

    project_root = str(tmp_path / "project")
    request = scratchlanes.request_approval(
        conn,
        session_id="sess-approve",
        project_root=project_root,
        task_slug="dedup",
        requested_path=str(Path(project_root) / "tmp" / "dedup.py"),
        tool_name="Write",
        request_reason="tmp_source_candidate",
        requested_by="write_scratchlane_gate",
    )

    assert request["status"] == "pending"
    assert request["request_state"] == "created"

    result = scratchlanes.resolve_pending_from_prompt(
        conn,
        session_id="sess-approve",
        project_root=project_root,
        prompt="yes",
    )

    assert result["resolution"] == "approved"
    assert result["permit"] is not None
    assert result["permit"]["task_slug"] == "dedup"
    assert scratchlanes.get_pending(
        conn,
        session_id="sess-approve",
        project_root=project_root,
    ) is None
    assert "Do not ask the user to run any command." in result["additional_context"]


def test_scratchlane_request_roundtrip_deny(tmp_path):
    conn = connect_memory()
    ensure_schema(conn)

    project_root = str(tmp_path / "project")
    scratchlanes.request_approval(
        conn,
        session_id="sess-deny",
        project_root=project_root,
        task_slug="dedup",
        requested_path=str(Path(project_root) / "tmp" / "dedup.py"),
        tool_name="Write",
        request_reason="tmp_source_candidate",
        requested_by="write_scratchlane_gate",
    )

    result = scratchlanes.resolve_pending_from_prompt(
        conn,
        session_id="sess-deny",
        project_root=project_root,
        prompt="no",
    )

    assert result["resolution"] == "denied"
    assert result["permit"] is None
    assert scratchlanes.get_active(conn, project_root, "dedup") is None
    assert "Scratchlane denied" in result["additional_context"]


def test_scratchlane_request_roundtrip_ambiguous_reply_stays_pending(tmp_path):
    conn = connect_memory()
    ensure_schema(conn)

    project_root = str(tmp_path / "project")
    scratchlanes.request_approval(
        conn,
        session_id="sess-pending",
        project_root=project_root,
        task_slug="dedup",
        requested_path=str(Path(project_root) / "tmp" / "dedup.py"),
        tool_name="Write",
        request_reason="tmp_source_candidate",
        requested_by="write_scratchlane_gate",
    )

    result = scratchlanes.resolve_pending_from_prompt(
        conn,
        session_id="sess-pending",
        project_root=project_root,
        prompt="what else needs to change?",
    )

    assert result["resolution"] == "pending"
    assert result["permit"] is None
    assert scratchlanes.get_pending(
        conn,
        session_id="sess-pending",
        project_root=project_root,
    ) is not None


def test_identical_pending_request_is_reused_without_duplication(tmp_path):
    conn = connect_memory()
    ensure_schema(conn)

    project_root = str(tmp_path / "project")
    first = scratchlanes.request_approval(
        conn,
        session_id="sess-reuse",
        project_root=project_root,
        task_slug="dedup",
        requested_path=str(Path(project_root) / "tmp" / "dedup.py"),
        tool_name="Write",
        request_reason="tmp_source_candidate",
        requested_by="write_scratchlane_gate",
    )
    second = scratchlanes.request_approval(
        conn,
        session_id="sess-reuse",
        project_root=project_root,
        task_slug="dedup",
        requested_path=str(Path(project_root) / "tmp" / "dedup.py"),
        tool_name="Write",
        request_reason="tmp_source_candidate",
        requested_by="write_scratchlane_gate",
    )

    assert first["request_state"] == "created"
    assert second["request_state"] == "existing"
    assert second["id"] == first["id"]
    assert len(
        scratchlanes.list_pending(
            conn,
            project_root=project_root,
            session_id="sess-reuse",
        )
    ) == 1


def test_evaluate_registers_pending_scratchlane_request(tmp_path):
    project_root = tmp_path / "project"
    project_root.mkdir()
    db_path = tmp_path / "state.db"

    payload = {
        "event_type": "Write",
        "tool_name": "Write",
        "tool_input": {
            "file_path": str(project_root / "tmp" / "dedup.py"),
            "content": "print('hi')\n",
        },
        "cwd": str(project_root),
        "session_id": "sess-evaluate",
        "actor_role": "",
        "actor_id": "",
    }

    code, out = _run_evaluate(
        payload,
        db_path=db_path,
        extra_env={"CLAUDE_PROJECT_DIR": str(project_root)},
    )

    assert code == 0
    assert out["action"] == "deny"
    assert "scratchlane" in out["reason"]
    assert out["runtimeNotification"]["notification_type"] == "scratchlane_approval_needed"
    assert "tmp/.claude-scratch/dedup" in out["runtimeNotification"]["message"]

    conn = connect(db_path)
    try:
        ensure_schema(conn)
        pending = scratchlanes.get_pending(
            conn,
            session_id="sess-evaluate",
            project_root=str(project_root),
        )
    finally:
        conn.close()

    assert pending is not None
    assert pending["task_slug"] == "dedup"
    assert pending["requested_path"] == str(project_root / "tmp" / "dedup.py")


def test_evaluate_reuses_identical_pending_request_without_repeat_notification(tmp_path):
    project_root = tmp_path / "project"
    project_root.mkdir()
    db_path = tmp_path / "state.db"

    payload = {
        "event_type": "Write",
        "tool_name": "Write",
        "tool_input": {
            "file_path": str(project_root / "tmp" / "dedup.py"),
            "content": "print('hi')\n",
        },
        "cwd": str(project_root),
        "session_id": "sess-repeat",
        "actor_role": "",
        "actor_id": "",
    }

    first_code, first_out = _run_evaluate(
        payload,
        db_path=db_path,
        extra_env={"CLAUDE_PROJECT_DIR": str(project_root)},
    )
    second_code, second_out = _run_evaluate(
        payload,
        db_path=db_path,
        extra_env={"CLAUDE_PROJECT_DIR": str(project_root)},
    )

    assert first_code == 0
    assert second_code == 0
    assert "runtimeNotification" in first_out
    assert "runtimeNotification" not in second_out

    conn = connect(db_path)
    try:
        ensure_schema(conn)
        pending = scratchlanes.list_pending(
            conn,
            project_root=str(project_root),
            session_id="sess-repeat",
        )
    finally:
        conn.close()

    assert len(pending) == 1


def test_pre_write_emits_local_notification_for_new_pending_request(tmp_path):
    project_root = tmp_path / "project"
    project_root.mkdir()
    _init_git_repo(project_root)
    db_path = tmp_path / "state.db"
    capture_path = tmp_path / "terminal-notifier-args.bin"
    fakebin = tmp_path / "fakebin"
    fakebin.mkdir()

    (fakebin / "uname").write_text("#!/usr/bin/env bash\necho Darwin\n", encoding="utf-8")
    (fakebin / "terminal-notifier").write_text(
        "#!/usr/bin/env bash\n"
        "printf '%s\\0' \"$@\" > \"$CLAUDE_NOTIFY_CAPTURE\"\n",
        encoding="utf-8",
    )
    (fakebin / "uname").chmod(0o755)
    (fakebin / "terminal-notifier").chmod(0o755)

    env = {
        **os.environ,
        "CLAUDE_POLICY_DB": str(db_path),
        "CLAUDE_PROJECT_DIR": str(project_root),
        "CLAUDE_RUNTIME_ROOT": str(_WORKTREE / "runtime"),
        "PYTHONPATH": str(_WORKTREE),
        "PATH": f"{fakebin}{os.pathsep}{os.environ['PATH']}",
        "CLAUDE_NOTIFY_CAPTURE": str(capture_path),
    }
    payload = {
        "tool_name": "Write",
        "tool_input": {
            "file_path": str(project_root / "tmp" / "dedup.py"),
            "content": "print('hi')\n",
        },
        "session_id": "sess-pre-write",
        "cwd": str(project_root),
    }

    result = subprocess.run(
        ["bash", str(_PRE_WRITE_HOOK)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        cwd=_WORKTREE,
        env=env,
    )

    assert result.returncode == 0, result.stderr
    output = json.loads(result.stdout)
    assert output["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "runtimeNotification" not in output

    capture = capture_path.read_bytes().split(b"\0")
    args = [item.decode("utf-8") for item in capture if item]
    assert "-title" in args
    assert "Scratchlane Approval Needed" in args
    assert "-message" in args
    message = args[args.index("-message") + 1]
    assert "tmp/.claude-scratch/dedup" in message
    assert "Reply yes or no" in message


def test_prompt_submit_consumes_plain_yes_into_scratchlane_approval(tmp_path):
    project_root = tmp_path / "project"
    project_root.mkdir()
    db_path = tmp_path / "state.db"
    session_id = "sess-prompt-submit"

    _init_git_repo(project_root)

    conn = connect(db_path)
    try:
        ensure_schema(conn)
        scratchlanes.request_approval(
            conn,
            session_id=session_id,
            project_root=str(project_root),
            task_slug="dedup",
            requested_path=str(project_root / "tmp" / "dedup.py"),
            tool_name="Write",
            request_reason="tmp_source_candidate",
            requested_by="write_scratchlane_gate",
        )
    finally:
        conn.close()

    prompt_count = project_root / ".claude" / f".prompt-count-{session_id}"
    prompt_count.parent.mkdir(parents=True, exist_ok=True)
    prompt_count.write_text("1\n", encoding="utf-8")

    env = {
        **os.environ,
        "CLAUDE_POLICY_DB": str(db_path),
        "CLAUDE_PROJECT_DIR": str(project_root),
        "CLAUDE_RUNTIME_ROOT": str(_WORKTREE / "runtime"),
        "PYTHONPATH": str(_WORKTREE),
    }
    payload = {
        "prompt": "yes",
        "session_id": session_id,
        "cwd": str(project_root),
    }

    result = subprocess.run(
        ["bash", str(_PROMPT_SUBMIT_HOOK)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        cwd=_WORKTREE,
        env=env,
    )

    assert result.returncode == 0, result.stderr
    output = json.loads(result.stdout)
    additional_context = output["hookSpecificOutput"]["additionalContext"]
    assert "Scratchlane approved" in additional_context
    assert "Do not ask the user to run any command." in additional_context

    conn = connect(db_path)
    try:
        ensure_schema(conn)
        permit = scratchlanes.get_active(conn, str(project_root), "dedup")
        pending = scratchlanes.get_pending(
            conn,
            session_id=session_id,
            project_root=str(project_root),
        )
    finally:
        conn.close()

    assert permit is not None
    assert Path(permit["root_path"]).is_dir()
    assert pending is None


def test_scratchlane_exec_wrapper_uses_active_permit(tmp_path, monkeypatch):
    repo_root = _WORKTREE
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
            "--project-root",
            str(repo_root),
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


def test_scratchlane_exec_wrapper_defaults_to_invocation_project_root(tmp_path, monkeypatch):
    repo_root = _WORKTREE
    target_root = tmp_path / "target-project"
    target_root.mkdir()
    _init_git_repo(target_root)
    db_path = tmp_path / "state.db"
    task_slug = "target-scratchlane"

    monkeypatch.setenv("CLAUDE_POLICY_DB", str(db_path))
    grant = subprocess.run(
        [
            sys.executable,
            str(repo_root / "runtime" / "cli.py"),
            "scratchlane",
            "grant",
            "--project-root",
            str(target_root),
            "--task-slug",
            task_slug,
        ],
        check=True,
        capture_output=True,
        text=True,
        cwd=repo_root,
    )
    scratch_root = Path(json.loads(grant.stdout)["permit"]["root_path"])

    fakebin = tmp_path / "fakebin-target"
    fakebin.mkdir()
    fake_sandbox = fakebin / "sandbox-exec"
    fake_sandbox.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "[[ \"$1\" == \"-f\" ]]\n"
        "shift 2\n"
        "exec \"$@\"\n",
        encoding="utf-8",
    )
    fake_sandbox.chmod(0o755)

    marker = tmp_path / "target-marker.txt"
    env = os.environ.copy()
    env.pop("CLAUDE_PROJECT_DIR", None)
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
            'test -d "$CC_SCRATCH_ROOT" && pwd > "$1"',
            "_",
            str(marker),
        ],
        check=True,
        cwd=target_root,
        env=env,
    )

    assert marker.read_text(encoding="utf-8").strip() == str(scratch_root)
