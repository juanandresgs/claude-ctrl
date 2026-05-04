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
from runtime.core.policies import bash_scratchlane_gate
from runtime.core.policies.bash_write_who import check as bash_write_who
from runtime.core.policies.write_scratchlane_gate import check as write_scratchlane_gate
from runtime.core.policy_engine import PolicyContext, PolicyRequest, default_registry
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


def _run_cli_without_policy_env(
    argv: list[str],
    *,
    cwd: Path,
    home: Path,
    stdin_text: str = "",
) -> tuple[int, dict]:
    env = {
        **os.environ,
        "HOME": str(home),
        "PYTHONPATH": str(_WORKTREE),
    }
    env.pop("CLAUDE_POLICY_DB", None)
    env.pop("CLAUDE_PROJECT_DIR", None)
    result = subprocess.run(
        [sys.executable, str(_CLI)] + argv,
        input=stdin_text,
        capture_output=True,
        text=True,
        cwd=cwd,
        env=env,
    )
    parsed = json.loads((result.stdout or result.stderr).strip() or "{}")
    return result.returncode, parsed


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
    expected_root = project_root / "tmp" / "dedup"
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


def test_scratchlane_permit_scope_filters_by_session_and_workflow(tmp_path):
    project_root = tmp_path / "project"
    project_root.mkdir()
    conn = connect_memory()
    ensure_schema(conn)

    scoped = scratchlanes.grant(
        conn,
        str(project_root),
        "ad-hoc",
        session_id="session-a",
        workflow_id="wf-a",
        granted_by="test",
    )
    assert scoped["session_id"] == "session-a"
    assert scoped["workflow_id"] == "wf-a"

    assert scratchlanes.active_roots(
        conn,
        str(project_root),
        session_id="session-a",
        workflow_id="wf-a",
    ) == (str(project_root / "tmp" / "ad-hoc"),)
    assert scratchlanes.active_roots(
        conn,
        str(project_root),
        session_id="session-b",
        workflow_id="wf-a",
    ) == ()
    assert scratchlanes.active_roots(
        conn,
        str(project_root),
        session_id="session-a",
        workflow_id="wf-b",
    ) == ()


def test_scratchlane_cleanup_removes_effectively_empty_session_root(tmp_path):
    project_root = tmp_path / "project"
    project_root.mkdir()
    conn = connect_memory()
    ensure_schema(conn)

    permit = scratchlanes.grant(
        conn,
        str(project_root),
        "ad-hoc",
        session_id="session-clean",
        granted_by="test",
    )
    scratch_root = Path(permit["root_path"])
    scratch_root.mkdir(parents=True)
    (scratch_root / ".DS_Store").write_text("mac clutter\n", encoding="utf-8")
    (scratch_root / ".tmp").mkdir()
    (scratch_root / ".tmp" / "._sandbox").write_text("", encoding="utf-8")

    result = scratchlanes.cleanup_empty_roots(
        conn,
        str(project_root),
        session_id="session-clean",
    )

    assert result["removed_count"] == 1
    assert result["items"][0]["status"] == "removed"
    assert not scratch_root.exists()
    assert not (project_root / "tmp").exists()


def test_scratchlane_cleanup_preserves_substantive_hidden_files(tmp_path):
    project_root = tmp_path / "project"
    project_root.mkdir()
    conn = connect_memory()
    ensure_schema(conn)

    permit = scratchlanes.grant(
        conn,
        str(project_root),
        "ad-hoc",
        session_id="session-keep",
        granted_by="test",
    )
    scratch_root = Path(permit["root_path"])
    scratch_root.mkdir(parents=True)
    (scratch_root / ".gitkeep").write_text("", encoding="utf-8")

    result = scratchlanes.cleanup_empty_roots(
        conn,
        str(project_root),
        session_id="session-keep",
    )

    assert result["removed_count"] == 0
    assert result["items"][0]["status"] == "kept"
    assert (scratch_root / ".gitkeep").exists()


def test_scratchlane_prompt_approval_preserves_request_scope(tmp_path):
    project_root = tmp_path / "project"
    project_root.mkdir()
    conn = connect_memory()
    ensure_schema(conn)

    request = scratchlanes.request_approval(
        conn,
        session_id="session-a",
        project_root=str(project_root),
        task_slug="ad-hoc",
        workflow_id="wf-a",
        work_item_id="WI-1",
        attempt_id="attempt-1",
    )
    assert request["workflow_id"] == "wf-a"

    result = scratchlanes.resolve_pending_from_prompt(
        conn,
        session_id="session-a",
        project_root=str(project_root),
        prompt="yes",
    )

    assert result["resolution"] == "approved"
    permit = result["permit"]
    assert permit["session_id"] == "session-a"
    assert permit["workflow_id"] == "wf-a"
    assert permit["work_item_id"] == "WI-1"
    assert permit["attempt_id"] == "attempt-1"


def test_scratchlane_cli_uses_project_root_db_outside_project(tmp_path):
    project_root = tmp_path / "project"
    outside = tmp_path / "outside"
    home = tmp_path / "home"
    project_root.mkdir()
    outside.mkdir()
    home.mkdir()

    code, out = _run_cli_without_policy_env(
        [
            "scratchlane",
            "grant",
            "--project-root",
            str(project_root),
            "--task-slug",
            "ad-hoc",
        ],
        cwd=outside,
        home=home,
    )

    assert code == 0
    assert out["status"] == "ok"

    project_db = project_root / ".claude" / "state.db"
    assert project_db.exists()
    conn = connect(project_db)
    try:
        ensure_schema(conn)
        permit = scratchlanes.get_active(conn, str(project_root), "ad-hoc")
    finally:
        conn.close()

    assert permit is not None
    assert permit["root_path"] == str(project_root / "tmp" / "ad-hoc")


def test_scratchlane_resolve_prompt_uses_project_root_db_outside_project(tmp_path):
    project_root = tmp_path / "project"
    outside = tmp_path / "outside"
    home = tmp_path / "home"
    project_root.mkdir()
    outside.mkdir()
    home.mkdir()

    project_db = project_root / ".claude" / "state.db"
    conn = connect(project_db)
    try:
        ensure_schema(conn)
        scratchlanes.request_approval(
            conn,
            session_id="sess-cli-resolve",
            project_root=str(project_root),
            task_slug="ad-hoc",
            requested_path="",
            tool_name="Bash",
            request_reason="opaque_interpreter",
            requested_by="bash_scratchlane_gate",
        )
    finally:
        conn.close()

    code, out = _run_cli_without_policy_env(
        [
            "scratchlane",
            "resolve-prompt",
            "--project-root",
            str(project_root),
            "--session-id",
            "sess-cli-resolve",
        ],
        cwd=outside,
        home=home,
        stdin_text="yes",
    )

    assert code == 0
    assert out["resolution"] == "approved"

    conn = connect(project_db)
    try:
        ensure_schema(conn)
        permit = scratchlanes.get_active(conn, str(project_root), "ad-hoc")
        pending = scratchlanes.get_pending(
            conn,
            session_id="sess-cli-resolve",
            project_root=str(project_root),
        )
    finally:
        conn.close()

    assert permit is not None
    assert pending is None


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
    assert "Guardian Admission verdict=scratchlane_authorized" in decision.reason
    assert "GUARDIAN_MODE: admission" in decision.reason
    assert decision.effects is None
    assert decision.metadata["guardian_admission"]["scratchlane"]["task_slug"] == "dedup"


def test_write_scratchlane_gate_allows_approved_scratchlane(tmp_path):
    project_root = tmp_path
    scratch_root = project_root / "tmp" / "dedup"
    scratch_root.mkdir(parents=True)
    request = PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={
            "file_path": str(scratch_root / "dedup.py"),
            "content": "print('hi')\n",
        },
        context=_make_context(
            project_root,
            scratchlane_roots=frozenset({str(scratch_root)}),
        ),
        cwd=str(project_root),
    )

    assert write_scratchlane_gate(request) is None


def test_legacy_nested_scratchlane_is_redirected_to_local_tmp(tmp_path):
    project_root = tmp_path
    nested_target = (
        project_root
        / "lsdyna_isolated"
        / "tmp"
        / ".claude-scratch"
        / "ad-hoc"
        / "ida_fast16_map.py"
    )
    canonical_root = project_root / "tmp" / "ad-hoc"
    request = PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={
            "file_path": str(nested_target),
            "content": "print('hi')\n",
        },
        context=_make_context(project_root),
        cwd=str(project_root / "lsdyna_isolated"),
    )

    decision = default_registry().evaluate(request)
    assert decision.action == "deny"
    assert decision.policy_name == "write_scratchlane_gate"
    assert "Guardian Admission verdict=scratchlane_authorized" in decision.reason
    assert decision.effects is None
    scratch = decision.metadata["guardian_admission"]["scratchlane"]
    assert scratch["task_slug"] == "ad-hoc"
    assert scratch["root_path"] == str(canonical_root)
    assert decision.metadata["guardian_admission"]["target_path"] == str(nested_target)


def test_active_scratchlane_redirects_legacy_path_without_reapproval(tmp_path):
    project_root = tmp_path
    legacy_target = (
        project_root
        / "lsdyna_isolated"
        / "tmp"
        / ".claude-scratch"
        / "ad-hoc"
        / "ida_fast16_map.py"
    )
    canonical_root = project_root / "tmp" / "ad-hoc"
    canonical_root.mkdir(parents=True)
    request = PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={
            "file_path": str(legacy_target),
            "content": "print('hi')\n",
        },
        context=_make_context(
            project_root,
            scratchlane_roots=frozenset({str(canonical_root)}),
        ),
        cwd=str(project_root / "lsdyna_isolated"),
    )

    decision = default_registry().evaluate(request)
    assert decision.action == "deny"
    assert decision.policy_name == "write_scratchlane_gate"
    assert "is active at" in decision.reason
    assert str(canonical_root) in decision.reason
    assert decision.effects is None


def test_active_canonical_scratchlane_is_artifact_not_source(tmp_path):
    project_root = tmp_path
    canonical_root = project_root / "tmp" / "ad-hoc"
    canonical_root.mkdir(parents=True)
    target = canonical_root / "ida_fast16_map.py"
    request = PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={
            "file_path": str(target),
            "content": "print('hi')\n",
        },
        context=_make_context(
            project_root,
            scratchlane_roots=frozenset({str(canonical_root)}),
        ),
        cwd=str(project_root / "lsdyna_isolated"),
    )

    decision = default_registry().evaluate(request)
    assert decision.action == "allow"
    assert decision.policy_name == "default"


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
    assert "Guardian Admission verdict=scratchlane_authorized" in decision.reason
    assert "GUARDIAN_MODE: admission" in decision.reason
    assert decision.effects is None
    assert decision.metadata["guardian_admission"]["scratchlane"]["task_slug"] == "wf-test"


def test_bash_scratchlane_gate_allows_read_only_inline_json_filter(tmp_path):
    project_root = tmp_path
    command = (
        "cc-policy workflow stage-packet coeditor --stage-id implementer 2>&1 | "
        "python3 -c \"import json,sys; d=json.load(sys.stdin); "
        "print(d.get('contract_block_line',''))\""
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


def test_bash_scratchlane_gate_routes_mutating_inline_filter_to_admission(tmp_path):
    project_root = tmp_path
    command = (
        "cc-policy workflow stage-packet coeditor --stage-id implementer | "
        "python3 -c \"import sys; open('out.json','w').write(sys.stdin.read())\""
    )
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
    assert decision.effects is None
    assert "Guardian Admission verdict=scratchlane_authorized" in decision.reason
    assert decision.metadata["guardian_admission"]["scratchlane"]["task_slug"] == "wf-test"


def test_bash_scratchlane_gate_ignores_active_lane_for_no_target_interpreter(tmp_path):
    project_root = tmp_path
    scratch_root = project_root / "tmp" / "ad-hoc"
    command = "python3 -c 'print(1)'"
    request = PolicyRequest(
        event_type="PreToolUse",
        tool_name="Bash",
        tool_input={"command": command},
        context=_make_context(
            project_root,
            scratchlane_roots=frozenset({str(scratch_root)}),
        ),
        cwd=str(project_root),
        command_intent=build_bash_command_intent(command, cwd=str(project_root)),
    )

    decision = bash_scratchlane_gate.check(request)
    assert decision is not None
    assert decision.action == "deny"
    assert decision.effects is None
    assert "Guardian Admission verdict=scratchlane_authorized" in decision.reason
    assert "GUARDIAN_MODE: admission" in decision.reason
    assert "tmp/ad-hoc" not in decision.reason
    assert decision.metadata["guardian_admission"]["scratchlane"]["task_slug"] == "wf-test"


def test_bash_scratchlane_gate_allows_absolute_runtime_wrapper_command(tmp_path):
    project_root = tmp_path
    scratch_root = project_root / "tmp" / "dedup"
    wrapper = _WORKTREE / "scripts" / "scratchlane-exec.sh"
    command = (
        f"{wrapper} --task-slug dedup --project-root {project_root} -- bash -c "
        "'cd /tmp && cc-policy evaluation get wf | python3 -c \"print(1)\"'"
    )
    request = PolicyRequest(
        event_type="PreToolUse",
        tool_name="Bash",
        tool_input={"command": command},
        context=_make_context(
            project_root,
            scratchlane_roots=frozenset({str(scratch_root)}),
        ),
        cwd=str(project_root),
        command_intent=build_bash_command_intent(command, cwd=str(project_root)),
    )

    assert bash_scratchlane_gate.check(request) is None


def test_bash_scratchlane_gate_requests_approval_for_inactive_runtime_wrapper(tmp_path):
    project_root = tmp_path
    wrapper = _WORKTREE / "scripts" / "scratchlane-exec.sh"
    command = (
        f"{wrapper} --task-slug ad-hoc --project-root {project_root} -- "
        "python3 -c 'print(1)'"
    )
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
    assert "Guardian Admission verdict=scratchlane_authorized" in decision.reason
    expected_root = project_root / "tmp" / "ad-hoc"
    assert str(expected_root) in decision.reason
    assert decision.effects is None
    scratch = decision.metadata["guardian_admission"]["scratchlane"]
    assert scratch["task_slug"] == "ad-hoc"
    assert scratch["root_path"] == str(expected_root)
    assert decision.metadata["guardian_admission"]["target_path"] == str(
        expected_root / ".scratchlane"
    )


def test_bash_scratchlane_gate_allows_relative_wrapper_only_from_runtime_root():
    project_root = _WORKTREE
    scratch_root = project_root / "tmp" / "dedup"
    command = (
        "./scripts/scratchlane-exec.sh --task-slug dedup "
        f"--project-root {project_root} -- python3 -c 'print(1)'"
    )
    request = PolicyRequest(
        event_type="PreToolUse",
        tool_name="Bash",
        tool_input={"command": command},
        context=_make_context(
            project_root,
            scratchlane_roots=frozenset({str(scratch_root)}),
        ),
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
    scratch_root = project_root / "tmp" / "notes"
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


def test_bash_legacy_nested_scratchlane_target_requests_local_tmp(tmp_path):
    project_root = tmp_path
    nested_target = (
        project_root
        / "lsdyna_isolated"
        / "tmp"
        / ".claude-scratch"
        / "ad-hoc"
        / "ida_fast16_map.py"
    )
    canonical_root = project_root / "tmp" / "ad-hoc"
    command = f"echo hi > {nested_target}"
    request = PolicyRequest(
        event_type="PreToolUse",
        tool_name="Bash",
        tool_input={"command": command},
        context=_make_context(project_root),
        cwd=str(project_root / "lsdyna_isolated"),
        command_intent=build_bash_command_intent(
            command,
            cwd=str(project_root / "lsdyna_isolated"),
        ),
    )

    decision = bash_scratchlane_gate.check(request)
    assert decision is not None
    assert decision.action == "deny"
    assert "Guardian Admission verdict=scratchlane_authorized" in decision.reason
    assert decision.effects is None
    scratch = decision.metadata["guardian_admission"]["scratchlane"]
    assert scratch["task_slug"] == "ad-hoc"
    assert scratch["root_path"] == str(canonical_root)


def test_bash_active_scratchlane_redirects_legacy_target_without_reapproval(tmp_path):
    project_root = tmp_path
    legacy_target = (
        project_root
        / "lsdyna_isolated"
        / "tmp"
        / ".claude-scratch"
        / "ad-hoc"
        / "ida_fast16_map.py"
    )
    canonical_root = project_root / "tmp" / "ad-hoc"
    canonical_root.mkdir(parents=True)
    command = f"echo hi > {legacy_target}"
    request = PolicyRequest(
        event_type="PreToolUse",
        tool_name="Bash",
        tool_input={"command": command},
        context=_make_context(
            project_root,
            scratchlane_roots=frozenset({str(canonical_root)}),
        ),
        cwd=str(project_root / "lsdyna_isolated"),
        command_intent=build_bash_command_intent(
            command,
            cwd=str(project_root / "lsdyna_isolated"),
        ),
    )

    decision = bash_scratchlane_gate.check(request)
    assert decision is not None
    assert decision.action == "deny"
    assert "is active at" in decision.reason
    assert str(canonical_root) in decision.reason
    assert decision.effects is None


def test_bash_active_canonical_scratchlane_target_is_not_source_write(tmp_path):
    project_root = tmp_path
    canonical_root = project_root / "tmp" / "ad-hoc"
    canonical_root.mkdir(parents=True)
    target = canonical_root / "ida_fast16_map.py"
    command = f"echo hi > {target}"
    request = PolicyRequest(
        event_type="PreToolUse",
        tool_name="Bash",
        tool_input={"command": command},
        context=_make_context(
            project_root,
            scratchlane_roots=frozenset({str(canonical_root)}),
        ),
        cwd=str(project_root / "lsdyna_isolated"),
        command_intent=build_bash_command_intent(
            command,
            cwd=str(project_root / "lsdyna_isolated"),
        ),
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


def test_direct_scratchlane_grant_resolves_matching_pending_request(tmp_path):
    conn = connect_memory()
    ensure_schema(conn)

    project_root = str(tmp_path / "project")
    scratchlanes.request_approval(
        conn,
        session_id="sess-direct-grant",
        project_root=project_root,
        task_slug="ad-hoc",
        requested_path="",
        tool_name="Bash",
        request_reason="opaque_interpreter",
        requested_by="bash_scratchlane_gate",
    )

    permit = scratchlanes.grant(
        conn,
        project_root,
        "ad-hoc",
        granted_by="user",
        note="fallback grant",
    )

    assert permit["task_slug"] == "ad-hoc"
    assert scratchlanes.get_pending(
        conn,
        session_id="sess-direct-grant",
        project_root=project_root,
    ) is None


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
    assert "GUARDIAN_MODE: admission" in out["reason"]
    assert "runtimeNotification" not in out

    conn = connect(db_path)
    try:
        ensure_schema(conn)
        permit = scratchlanes.get_active(conn, str(project_root), "dedup")
        pending = scratchlanes.get_pending(conn, session_id="sess-evaluate", project_root=str(project_root))
    finally:
        conn.close()

    assert pending is None
    assert permit is None


def test_evaluate_registers_pending_scratchlane_request_for_inactive_wrapper(tmp_path):
    project_root = tmp_path / "project"
    project_root.mkdir()
    db_path = tmp_path / "state.db"
    wrapper = _WORKTREE / "scripts" / "scratchlane-exec.sh"

    payload = {
        "event_type": "PreToolUse",
        "tool_name": "Bash",
        "tool_input": {
            "command": (
                f"{wrapper} --task-slug ad-hoc --project-root {project_root} -- "
                "python3 -c 'print(1)'"
            ),
        },
        "cwd": str(project_root),
        "session_id": "sess-wrapper-approval",
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
    assert "Guardian Admission verdict=scratchlane_authorized" in out["reason"]
    assert "GUARDIAN_MODE: admission" in out["reason"]
    assert "runtimeNotification" not in out

    conn = connect(db_path)
    try:
        ensure_schema(conn)
        permit = scratchlanes.get_active(conn, str(project_root), "ad-hoc")
        pending = scratchlanes.get_pending(conn, session_id="sess-wrapper-approval", project_root=str(project_root))
    finally:
        conn.close()

    assert pending is None
    assert permit is None


def test_evaluate_missing_session_id_omits_manual_scratchlane_grant_command(tmp_path):
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
    assert "Guardian Admission verdict=scratchlane_authorized" in out["reason"]
    assert "GUARDIAN_MODE: admission" in out["reason"]
    assert "python3" not in out["reason"]
    assert "scratchlane grant" not in out["reason"]


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
    assert "runtimeNotification" not in first_out
    assert "runtimeNotification" not in second_out

    conn = connect(db_path)
    try:
        ensure_schema(conn)
        pending = scratchlanes.list_pending(
            conn,
            project_root=str(project_root),
            session_id="sess-repeat",
        )
        permit = scratchlanes.get_active(conn, str(project_root), "dedup")
    finally:
        conn.close()

    assert pending == []
    assert permit is None


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

    assert not capture_path.exists()
    conn = connect(db_path)
    try:
        ensure_schema(conn)
        permit = scratchlanes.get_active(conn, str(project_root), "dedup")
    finally:
        conn.close()
    assert permit is None


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


def test_scratchlane_exec_wrapper_inactive_permit_omits_raw_grant_hint(tmp_path):
    repo_root = _WORKTREE
    db_path = tmp_path / "state.db"
    env = os.environ.copy()
    env["CLAUDE_POLICY_DB"] = str(db_path)

    result = subprocess.run(
        [
            str(repo_root / "scripts" / "scratchlane-exec.sh"),
            "--task-slug",
            "ad-hoc",
            "--project-root",
            str(repo_root),
            "--",
            "python3",
            "-c",
            "print(1)",
        ],
        capture_output=True,
        text=True,
        cwd=repo_root,
        env=env,
    )

    assert result.returncode == 1
    assert "Guardian Admission" in result.stderr
    assert "python3" not in result.stderr
    assert "scratchlane grant" not in result.stderr


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


def test_scratchlane_authority_not_reimplemented_in_policy_effects():
    runtime_paths = [
        *(_WORKTREE / "runtime" / "core" / "policies").glob("*.py"),
        _WORKTREE / "runtime" / "cli.py",
    ]
    banned = (
        "apply_guardian_admission",
        "VERDICT_SCRATCHLANE_AUTHORIZED",
        '"scratchlane_authorized"',
        "'scratchlane_authorized'",
        "tmp/ad-hoc",
    )

    offenders: list[str] = []
    for path in runtime_paths:
        text = path.read_text(encoding="utf-8")
        for needle in banned:
            if needle in text:
                offenders.append(f"{path.relative_to(_WORKTREE)}: {needle}")

    assert offenders == []
