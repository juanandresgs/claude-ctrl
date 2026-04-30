"""Parameterized hook-boundary scenarios replacing narrow shell smoke tests.

These tests still execute the real hook scripts against temp repos and a real
SQLite policy DB. They replace the former single-assertion shell scenarios for:

  - pre-write.sh
  - write-guard.sh
  - plan-guard.sh
  - pre-bash.sh
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

_WORKTREE = Path(__file__).resolve().parent.parent.parent.parent
_CLI = _WORKTREE / "runtime" / "cli.py"
_PRE_WRITE_HOOK = _WORKTREE / "hooks" / "pre-write.sh"
_WRITE_GUARD_HOOK = _WORKTREE / "hooks" / "write-guard.sh"
_PLAN_GUARD_HOOK = _WORKTREE / "hooks" / "plan-guard.sh"
_PRE_BASH_HOOK = _WORKTREE / "hooks" / "pre-bash.sh"


def _run(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    input_text: str | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=str(cwd) if cwd is not None else None,
        input=input_text,
        capture_output=True,
        text=True,
        env=env,
        check=check,
    )


def _git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return _run(["git", "-C", str(repo), *args])


def _db_path(project_root: Path) -> Path:
    return project_root / ".claude" / "state.db"


def _policy(project_root: Path, *args: str) -> subprocess.CompletedProcess[str]:
    env = {
        **os.environ,
        "CLAUDE_POLICY_DB": str(_db_path(project_root)),
        "PYTHONPATH": str(_WORKTREE),
    }
    return _run([sys.executable, str(_CLI), *args], env=env)


def _policy_with_db(db_path: Path, *args: str) -> subprocess.CompletedProcess[str]:
    env = {
        **os.environ,
        "CLAUDE_POLICY_DB": str(db_path),
        "PYTHONPATH": str(_WORKTREE),
    }
    return _run([sys.executable, str(_CLI), *args], env=env)


def _init_project(tmp_path: Path, *, name: str = "project") -> Path:
    project_root = tmp_path / name
    project_root.mkdir()
    (project_root / ".claude").mkdir()
    _policy(project_root, "schema", "ensure")
    return project_root


def _init_repo(tmp_path: Path, *, branch: str = "feature/test", name: str = "repo") -> Path:
    repo = _init_project(tmp_path, name=name)
    _run(["git", "init", "-q", str(repo)])
    _git(repo, "config", "user.email", "tests@example.com")
    _git(repo, "config", "user.name", "Tests")
    _git(repo, "checkout", "-B", branch, "-q")
    _git(repo, "commit", "--allow-empty", "-m", "init", "-q")
    return repo


def _set_role(project_root: Path, role: str) -> None:
    # ENFORCE-RCA-6-ext/#26: write the marker scoped to project_root so that
    # current_active_agent_role (which is now scoped) can find it. Before the
    # scoping fix the unscoped fallback would return this marker regardless;
    # with scoping enforced, the marker must match CLAUDE_PROJECT_DIR used by
    # the hook under test.
    _policy(
        project_root,
        "marker",
        "set",
        "agent-test",
        role,
        "--project-root",
        str(project_root),
    )


def _seed_master_plan(repo: Path, content: str = "# Plan\n") -> None:
    plan_path = repo / "MASTER_PLAN.md"
    plan_path.write_text(content, encoding="utf-8")
    _git(repo, "add", "MASTER_PLAN.md")
    _git(repo, "commit", "-m", "add plan", "-q")


def _hook_env(project_root: Path, extra_env: dict[str, str] | None = None) -> dict[str, str]:
    env = {
        **os.environ,
        "HOME": os.environ.get("HOME", "/tmp"),
        "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
        "PYTHONPATH": str(_WORKTREE),
        "CLAUDE_PROJECT_DIR": str(project_root),
        "CLAUDE_POLICY_DB": str(_db_path(project_root)),
        "CLAUDE_RUNTIME_ROOT": str(_WORKTREE / "runtime"),
    }
    if extra_env:
        env.update(extra_env)
    return env


def _hook_env_without_policy_db(project_root: Path) -> dict[str, str]:
    env = _hook_env(project_root)
    env.pop("CLAUDE_POLICY_DB", None)
    return env


def _run_write_hook(
    hook_path: Path,
    *,
    project_root: Path,
    file_path: Path,
    content: str,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    file_path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(
        {
            "tool_name": "Write",
            "tool_input": {
                "file_path": str(file_path),
                "content": content,
            },
        }
    )
    return _run(
        ["bash", str(hook_path)],
        env=_hook_env(project_root, extra_env),
        input_text=payload,
        check=False,
    )


def _run_bash_hook(
    *,
    project_root: Path,
    cwd: Path,
    command: str,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    payload = json.dumps(
        {
            "tool_name": "Bash",
            "tool_input": {"command": command},
            "cwd": str(cwd),
        }
    )
    return _run(
        ["bash", str(_PRE_BASH_HOOK)],
        env=_hook_env(project_root, extra_env),
        input_text=payload,
        check=False,
    )


def _parse_stdout(stdout: str) -> dict | None:
    text = stdout.strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        pytest.fail(f"hook stdout is not valid JSON: {exc}\nraw stdout: {stdout!r}")


def _decision(payload: dict | None) -> str | None:
    if payload is None:
        return None
    return payload.get("hookSpecificOutput", {}).get("permissionDecision")


def _reason(payload: dict | None) -> str:
    if payload is None:
        return ""
    return payload.get("hookSpecificOutput", {}).get("permissionDecisionReason", "")


def _assert_hook_result(
    result: subprocess.CompletedProcess[str],
    *,
    expected_decision: str,
    reason_substring: str | None = None,
) -> None:
    assert result.returncode == 0, (
        f"hook exited with {result.returncode}\nstdout={result.stdout!r}\nstderr={result.stderr!r}"
    )

    payload = _parse_stdout(result.stdout)
    decision = _decision(payload)

    if expected_decision == "deny":
        assert payload is not None, "deny path must emit hookSpecificOutput JSON"
        assert decision == "deny", f"expected deny, got {decision!r} payload={payload!r}"
        if reason_substring is not None:
            assert reason_substring in _reason(payload), (
                f"deny reason missing {reason_substring!r}: {_reason(payload)!r}"
            )
        # ENFORCE-RCA-11 / DEC-EVAL-HOOKOUT-001: hookEventName must be present
        # in hookSpecificOutput whenever a permissionDecision is emitted.
        # Without it Claude Code silently discards the deny and the command
        # executes unblocked (root cause: cc-policy evaluate was a no-op since PE-W1).
        hook_specific = (payload or {}).get("hookSpecificOutput", {})
        assert hook_specific.get("hookEventName") == "PreToolUse", (
            "ENFORCE-RCA-11: hookSpecificOutput must contain hookEventName='PreToolUse' "
            f"for deny decisions; got hookSpecificOutput={hook_specific!r}"
        )
        return

    assert decision != "deny", (
        f"expected non-deny path, got payload={payload!r}\nstderr={result.stderr!r}"
    )

    # ENFORCE-RCA-11 / DEC-EVAL-HOOKOUT-001: hookEventName must also be present
    # for allow decisions that emit a permissionDecision field.
    if payload is not None:
        hook_specific = payload.get("hookSpecificOutput", {})
        if hook_specific.get("permissionDecision") is not None:
            assert hook_specific.get("hookEventName") == "PreToolUse", (
                "ENFORCE-RCA-11: hookSpecificOutput must contain hookEventName='PreToolUse' "
                f"for allow decisions; got hookSpecificOutput={hook_specific!r}"
            )


def _typescript_exports(count: int = 25) -> str:
    lines = ["// Scenario fixture.\n"]
    lines.extend(f"export const value_{index} = {index};\n" for index in range(1, count + 1))
    return "".join(lines)


def _configure_guardian_git_allow(repo: Path) -> None:
    # Live truth: marker stores bare "guardian". build_context canonicalizes
    # to guardian:land via dispatch_phase from the reviewer completion seeded
    # below (DEC-WHO-GUARDIAN-CANONICALIZE-001).
    _set_role(repo, "guardian")
    _policy(
        repo,
        "test-state",
        "set",
        "pass",
        "--project-root",
        str(repo),
        "--passed",
        "1",
        "--total",
        "1",
    )

    head_sha = _git(repo, "rev-parse", "HEAD").stdout.strip()
    workflow_id = "feature-ready"

    _policy(repo, "evaluation", "set", workflow_id, "ready_for_guardian", "--head-sha", head_sha)
    _policy(repo, "workflow", "bind", workflow_id, str(repo), "feature/ready")
    _policy(repo, "workflow", "scope-set", workflow_id, "--allowed", '["*"]', "--forbidden", "[]")
    _policy(
        repo,
        "lease",
        "issue-for-dispatch",
        "guardian",
        "--worktree-path",
        str(repo),
        "--workflow-id",
        workflow_id,
        "--allowed-ops",
        '["routine_local","high_risk"]',
    )

    # Seed a reviewer:ready_for_guardian completion so build_context resolves
    # dispatch_phase to "reviewer:ready_for_guardian", canonicalizing bare
    # guardian → guardian:land. Inserted directly to avoid the full reviewer
    # completion payload validation (payload fields aren't relevant here —
    # only the row's role/verdict/workflow_id drive the dispatch_phase read).
    import sqlite3 as _sqlite3

    _db = _db_path(repo)
    _conn = _sqlite3.connect(str(_db))
    try:
        _conn.execute(
            "INSERT INTO completion_records "
            "(lease_id, workflow_id, role, verdict, valid, payload_json, missing_fields, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, CAST(strftime('%s','now') AS INTEGER))",
            ("seed-lease", workflow_id, "reviewer", "ready_for_guardian", 1, "{}", "[]"),
        )
        _conn.commit()
    finally:
        _conn.close()


def _configure_guardian_git_allow_in_shared_db(repo: Path, worktree: Path) -> None:
    """Seed a ready guardian landing context in repo DB for a linked worktree."""
    db = _db_path(repo)
    workflow_id = "feature-worktree-ready"
    branch = "feature/worktree-ready"
    head_sha = _git(worktree, "rev-parse", "HEAD").stdout.strip()

    _policy_with_db(
        db,
        "marker",
        "set",
        "agent-test",
        "guardian",
        "--project-root",
        str(worktree),
    )
    _policy_with_db(
        db,
        "test-state",
        "set",
        "pass",
        "--project-root",
        str(worktree),
        "--passed",
        "1",
        "--total",
        "1",
    )
    _policy_with_db(db, "evaluation", "set", workflow_id, "ready_for_guardian", "--head-sha", head_sha)
    _policy_with_db(db, "workflow", "bind", workflow_id, str(worktree), branch)
    _policy_with_db(db, "workflow", "scope-set", workflow_id, "--allowed", '["*"]', "--forbidden", "[]")
    _policy_with_db(
        db,
        "lease",
        "issue-for-dispatch",
        "guardian",
        "--worktree-path",
        str(worktree),
        "--workflow-id",
        workflow_id,
        "--allowed-ops",
        '["routine_local","high_risk"]',
    )

    import sqlite3 as _sqlite3

    _conn = _sqlite3.connect(str(db))
    try:
        _conn.execute(
            "INSERT INTO completion_records "
            "(lease_id, workflow_id, role, verdict, valid, payload_json, missing_fields, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, CAST(strftime('%s','now') AS INTEGER))",
            ("seed-lease", workflow_id, "reviewer", "ready_for_guardian", 1, "{}", "[]"),
        )
        _conn.commit()
    finally:
        _conn.close()


def _configure_parent_marker_feature_lease_in_shared_db(repo: Path, worktree: Path) -> None:
    """Seat Guardian on the parent session root and lease the linked worktree."""
    db = _db_path(repo)
    workflow_id = "feature-parent-marker-ready"
    branch = "feature/parent-marker-ready"
    head_sha = _git(worktree, "rev-parse", "HEAD").stdout.strip()

    _policy_with_db(
        db,
        "marker",
        "set",
        "guardian-land-agent",
        "guardian:land",
        "--project-root",
        str(repo),
        "--workflow-id",
        workflow_id,
    )
    _policy_with_db(
        db,
        "test-state",
        "set",
        "pass",
        "--project-root",
        str(worktree),
        "--passed",
        "1",
        "--total",
        "1",
    )
    _policy_with_db(db, "evaluation", "set", workflow_id, "ready_for_guardian", "--head-sha", head_sha)
    _policy_with_db(db, "workflow", "bind", workflow_id, str(worktree), branch)
    _policy_with_db(db, "workflow", "scope-set", workflow_id, "--allowed", '["*"]', "--forbidden", "[]")
    _policy_with_db(
        db,
        "lease",
        "issue-for-dispatch",
        "guardian",
        "--worktree-path",
        str(worktree),
        "--workflow-id",
        workflow_id,
        "--allowed-ops",
        '["routine_local","high_risk"]',
    )


@pytest.mark.parametrize(
    "case",
    [
        {
            "id": "pre-write-allow",
            "branch": "feature/test",
            "role": "implementer",
            "seed_plan": True,
            "file_path": "src/app.ts",
            "content": _typescript_exports(),
            "expected_decision": "allow",
        },
        {
            "id": "pre-write-branch-deny",
            "branch": "main",
            "role": "implementer",
            "seed_plan": True,
            "file_path": "src/app.ts",
            "content": _typescript_exports(),
            "expected_decision": "deny",
            "reason_substring": "main",
        },
        {
            "id": "pre-write-no-plan-deny",
            "branch": "feature/test",
            "role": "implementer",
            "seed_plan": False,
            "file_path": "src/app.ts",
            "content": _typescript_exports(),
            "expected_decision": "deny",
            "reason_substring": "MASTER_PLAN.md",
        },
        {
            "id": "pre-write-plan-guard-deny",
            "branch": "feature/test",
            "role": "implementer",
            "seed_plan": False,
            "file_path": "MASTER_PLAN.md",
            "content": "# Plan\n",
            "expected_decision": "deny",
            "reason_substring": "planner",
        },
        {
            "id": "pre-write-who-deny",
            "branch": "feature/test",
            "role": None,
            "seed_plan": True,
            "file_path": "src/app.ts",
            "content": _typescript_exports(1),
            "expected_decision": "deny",
            "reason_substring": "orchestrator",
        },
    ],
    ids=lambda case: case["id"],
)
def test_pre_write_hook_cases(tmp_path, case):
    repo = _init_repo(tmp_path, branch=case["branch"], name=case["id"])
    if case["seed_plan"]:
        _seed_master_plan(repo)
    if case["role"] is not None:
        _set_role(repo, case["role"])

    result = _run_write_hook(
        _PRE_WRITE_HOOK,
        project_root=repo,
        file_path=repo / case["file_path"],
        content=case["content"],
    )

    _assert_hook_result(
        result,
        expected_decision=case["expected_decision"],
        reason_substring=case.get("reason_substring"),
    )


@pytest.mark.parametrize(
    "case",
    [
        {
            "id": "write-guard-implementer-allow",
            "hook_path": _WRITE_GUARD_HOOK,
            "role": "implementer",
            "file_path": "src/app.ts",
            "content": "export const x = 1;\n",
            "expected_decision": "allow",
        },
        {
            "id": "write-guard-config-allow",
            "hook_path": _WRITE_GUARD_HOOK,
            "role": None,
            "file_path": "config/settings.json",
            "content": '{"key":"value"}\n',
            "expected_decision": "allow",
        },
        {
            "id": "write-guard-orchestrator-deny",
            "hook_path": _WRITE_GUARD_HOOK,
            "role": None,
            "file_path": "src/app.ts",
            "content": "export const x = 1;\n",
            "expected_decision": "deny",
            "reason_substring": "orchestrator",
        },
        {
            "id": "write-guard-planner-deny",
            "hook_path": _WRITE_GUARD_HOOK,
            "role": "planner",
            "file_path": "src/app.ts",
            "content": "export const x = 1;\n",
            "expected_decision": "deny",
            "reason_substring": "planner",
        },
        {
            "id": "plan-guard-planner-allow",
            "hook_path": _PLAN_GUARD_HOOK,
            "role": "planner",
            "file_path": "MASTER_PLAN.md",
            "content": "# Plan\n",
            "expected_decision": "allow",
        },
        {
            "id": "plan-guard-implementer-deny",
            "hook_path": _PLAN_GUARD_HOOK,
            "role": "implementer",
            "file_path": "MASTER_PLAN.md",
            "content": "# Plan\n",
            "expected_decision": "deny",
            "reason_substring": "implementer",
        },
        {
            "id": "plan-guard-migration-override",
            "hook_path": _PLAN_GUARD_HOOK,
            "role": "implementer",
            "file_path": "MASTER_PLAN.md",
            "content": "# Plan\n",
            "extra_env": {"CLAUDE_PLAN_MIGRATION": "1"},
            "expected_decision": "allow",
        },
        {
            "id": "plan-guard-non-governance",
            "hook_path": _PLAN_GUARD_HOOK,
            "role": None,
            "file_path": "src/app.ts",
            "content": "export const x = 1;\n",
            "expected_decision": "allow",
        },
    ],
    ids=lambda case: case["id"],
)
def test_legacy_write_hooks(tmp_path, case):
    repo = _init_repo(tmp_path, name=case["id"])
    if case["role"] is not None:
        _set_role(repo, case["role"])

    result = _run_write_hook(
        case["hook_path"],
        project_root=repo,
        file_path=repo / case["file_path"],
        content=case["content"],
        extra_env=case.get("extra_env"),
    )

    _assert_hook_result(
        result,
        expected_decision=case["expected_decision"],
        reason_substring=case.get("reason_substring"),
    )


@pytest.mark.parametrize(
    "case",
    [
        {
            "id": "pre-bash-git-who-deny",
            "setup": "repo",
            "branch": "feature/test",
            "command": "git commit -m wip",
            "expected_decision": "deny",
        },
        {
            "id": "pre-bash-git-allow-guardian",
            "setup": "guardian-ready",
            "branch": "feature/ready",
            "command_template": 'git -C "{repo}" commit --allow-empty -m done',
            "expected_decision": "allow",
        },
        {
            "id": "pre-bash-non-git-allow",
            "setup": "project",
            "command": "ls -la",
            "expected_decision": "allow",
        },
    ],
    ids=lambda case: case["id"],
)
def test_pre_bash_hook_cases(tmp_path, case):
    if case["setup"] == "project":
        project_root = _init_project(tmp_path, name=case["id"])
        cwd = project_root
    else:
        project_root = _init_repo(tmp_path, branch=case["branch"], name=case["id"])
        cwd = project_root

    if case["setup"] == "guardian-ready":
        _configure_guardian_git_allow(project_root)

    command = case.get("command")
    if command is None:
        command = case["command_template"].format(repo=project_root)

    result = _run_bash_hook(project_root=project_root, cwd=cwd, command=command)

    _assert_hook_result(result, expected_decision=case["expected_decision"])


def test_pre_bash_hook_matches_cli_evaluate_from_linked_worktree_without_policy_db(tmp_path):
    """CLI and hook must resolve the same shared DB from a linked worktree.

    Regression: runtime/core/config.py collapsed linked worktrees via
    --git-common-dir, but the shell hook bridge used --show-toplevel and opened
    <worktree>/.claude/state.db. That made direct `cc-policy evaluate` allow a
    Guardian landing while the live pre-bash hook denied the same command.
    """
    repo = _init_repo(tmp_path, branch="main", name="pre-bash-worktree-parity")
    worktree = repo / ".worktrees" / "feature-worktree-ready"
    worktree.parent.mkdir()
    _git(repo, "worktree", "add", str(worktree), "-b", "feature/worktree-ready")
    _configure_guardian_git_allow_in_shared_db(repo, worktree)

    command = f'git -C "{worktree}" commit --allow-empty -m done'
    payload = {
        "tool_name": "Bash",
        "tool_input": {"command": command},
        "cwd": str(worktree),
    }
    env = _hook_env_without_policy_db(worktree)
    private_db = worktree / ".claude" / "state.db"

    direct_payload = {
        **payload,
        "event_type": "PreToolUse",
        "actor_role": "guardian",
        "actor_id": "",
    }
    direct = _run(
        [sys.executable, str(_CLI), "evaluate"],
        cwd=worktree,
        env=env,
        input_text=json.dumps(direct_payload),
        check=False,
    )
    direct_out = _parse_stdout(direct.stdout)
    assert direct.returncode == 0, direct.stderr
    assert _decision(direct_out) == "allow"

    hook = _run(
        ["bash", str(_PRE_BASH_HOOK)],
        cwd=worktree,
        env=env,
        input_text=json.dumps(payload),
        check=False,
    )
    hook_out = _parse_stdout(hook.stdout)
    assert hook.returncode == 0, hook.stderr
    assert _decision(hook_out) == "allow"
    assert _decision(hook_out) == _decision(direct_out)
    assert not private_db.exists(), (
        "pre-bash hook must not create/read a private linked-worktree DB"
    )


def test_pre_bash_hook_joins_parent_marker_to_target_worktree_lease_without_policy_db(tmp_path):
    """Guardian identity is session-scoped; lease authority is target-scoped.

    Regression: the live hook only passed actor_role and looked up leases by
    raw cwd/project_root coincidence. A Guardian seated on the parent repo
    could be denied when committing in a linked implementer worktree even
    though the shared DB had a matching Guardian lease for that target.
    """
    repo = _init_repo(tmp_path, branch="main", name="pre-bash-parent-marker")
    worktree = repo / ".worktrees" / "feature-parent-marker-ready"
    worktree.parent.mkdir()
    _git(repo, "worktree", "add", str(worktree), "-b", "feature/parent-marker-ready")
    _configure_parent_marker_feature_lease_in_shared_db(repo, worktree)

    command = f'git -C "{worktree}" commit --allow-empty -m done'
    payload = {
        "tool_name": "Bash",
        "tool_input": {"command": command},
        "cwd": str(worktree),
    }
    env = _hook_env_without_policy_db(repo)
    private_db = worktree / ".claude" / "state.db"

    direct_payload = {
        **payload,
        "event_type": "PreToolUse",
        "actor_role": "guardian:land",
        "actor_id": "guardian-land-agent",
        "actor_workflow_id": "feature-parent-marker-ready",
    }
    direct = _run(
        [sys.executable, str(_CLI), "evaluate"],
        cwd=worktree,
        env=env,
        input_text=json.dumps(direct_payload),
        check=False,
    )
    direct_out = _parse_stdout(direct.stdout)
    assert direct.returncode == 0, direct.stderr
    assert _decision(direct_out) == "allow"

    hook = _run(
        ["bash", str(_PRE_BASH_HOOK)],
        cwd=worktree,
        env=env,
        input_text=json.dumps(payload),
        check=False,
    )
    hook_out = _parse_stdout(hook.stdout)
    assert hook.returncode == 0, hook.stderr
    assert _decision(hook_out) == "allow"
    assert _decision(hook_out) == _decision(direct_out)
    assert not private_db.exists(), (
        "pre-bash hook must not create/read a private linked-worktree DB"
    )
