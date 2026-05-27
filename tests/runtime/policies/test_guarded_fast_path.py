"""Policy tests for guarded docs/config commit fast path."""

from __future__ import annotations

import json
import subprocess
import time

from runtime.core.policy_engine import PolicyRequest, default_registry
from tests.runtime.policies.conftest import make_context


def _init_repo(path):
    subprocess.run(["git", "-C", str(path), "init"], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(path), "config", "user.name", "Test"], check=True)
    subprocess.run(["git", "-C", str(path), "config", "user.email", "test@example.com"], check=True)
    subprocess.run(["git", "-C", str(path), "checkout", "-B", "main"], check=True, capture_output=True)
    (path / "README.md").write_text("seed\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(path), "add", "README.md"], check=True)
    subprocess.run(["git", "-C", str(path), "commit", "-m", "seed"], check=True, capture_output=True)


def _request(repo, *, actor_role="", lease=None, test_state=None, landing_readiness=None):
    ctx = make_context(
        project_root=str(repo),
        worktree_path=str(repo),
        branch=subprocess.check_output(["git", "-C", str(repo), "rev-parse", "--abbrev-ref", "HEAD"], text=True).strip(),
        actor_role=actor_role,
        actor_id="agent-fast",
        lease=lease,
        test_state=test_state,
        landing_readiness=landing_readiness,
    )
    return PolicyRequest(
        event_type="PreToolUse",
        tool_name="Bash",
        tool_input={"command": "git commit -m docs"},
        context=ctx,
        cwd=str(repo),
    )


def _write_request(repo, file_path, *, actor_role="guardian", content='"""small source fix"""\nprint("x")\n'):
    ctx = make_context(
        project_root=str(repo),
        worktree_path=str(repo),
        branch=subprocess.check_output(["git", "-C", str(repo), "rev-parse", "--abbrev-ref", "HEAD"], text=True).strip(),
        actor_role=actor_role,
        actor_id="agent-fast",
    )
    return PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={"file_path": str(file_path), "content": content},
        context=ctx,
        cwd=str(repo),
    )


def test_docs_config_commit_fast_path_allows_without_review_readiness(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _init_repo(repo)
    (repo / "settings.json").write_text('{"verbose": true}\n', encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", "settings.json"], check=True)

    decision = default_registry().evaluate(_request(repo, actor_role=""))

    assert decision.action == "allow"


def test_guardian_small_source_write_allowed_on_main(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _init_repo(repo)
    decision = default_registry().evaluate(_write_request(repo, repo / "app.py"))
    assert decision.action == "allow"


def test_guardian_small_source_write_rejects_control_plane_authority(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _init_repo(repo)
    path = repo / "runtime" / "core" / "stage_runs.py"
    path.parent.mkdir(parents=True)
    decision = default_registry().evaluate(_write_request(repo, path))
    assert decision.action == "deny"
    assert decision.policy_name == "branch_guard"


def test_guardian_small_source_write_rejects_third_file(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _init_repo(repo)
    (repo / "one.py").write_text("one\n", encoding="utf-8")
    (repo / "two.py").write_text("two\n", encoding="utf-8")
    decision = default_registry().evaluate(_write_request(repo, repo / "three.py"))
    assert decision.action == "deny"
    assert decision.policy_name == "branch_guard"


def test_guardian_small_source_commit_on_main_allowed_with_test_state(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _init_repo(repo)
    (repo / "app.py").write_text('"""app"""\nprint("x")\n', encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", "app.py"], check=True)

    decision = default_registry().evaluate(
        _request(repo, actor_role="guardian", test_state={"status": "pass_complete"})
    )

    assert decision.action == "allow"


def test_guardian_small_source_commit_on_main_requires_tests(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _init_repo(repo)
    (repo / "app.py").write_text('"""app"""\nprint("x")\n', encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", "app.py"], check=True)

    decision = default_registry().evaluate(_request(repo, actor_role="guardian"))

    assert decision.action == "deny"
    assert decision.policy_name == "bash_test_gate_commit"


def test_guardian_small_source_commit_rejects_control_plane_authority(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _init_repo(repo)
    path = repo / "runtime" / "core" / "stage_runs.py"
    path.parent.mkdir(parents=True)
    path.write_text('"""runtime"""\n', encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", str(path)], check=True)

    decision = default_registry().evaluate(
        _request(repo, actor_role="guardian", test_state={"status": "pass_complete"})
    )

    assert decision.action == "deny"
    assert decision.policy_name == "bash_git_who"


def test_non_small_source_commit_without_landing_readiness_still_denied(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _init_repo(repo)
    subprocess.run(["git", "-C", str(repo), "checkout", "-B", "feature/source"], check=True, capture_output=True)
    for name in ("app.py", "lib.py", "worker.py"):
        (repo / name).write_text(f'"""{name}"""\nprint("x")\n', encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", "app.py", "lib.py", "worker.py"], check=True)
    lease = {
        "role": "guardian",
        "workflow_id": "wf-source",
        "expires_at": int(time.time()) + 3600,
        "allowed_ops_json": json.dumps(["routine_local"]),
        "blocked_ops_json": "[]",
    }

    decision = default_registry().evaluate(
        _request(
            repo,
            actor_role="guardian",
            lease=lease,
            test_state={"status": "pass_complete"},
            landing_readiness=None,
        )
    )

    assert decision.action == "deny"
    assert decision.policy_name == "bash_eval_readiness"


def test_fast_path_rejects_secret_like_diff(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _init_repo(repo)
    (repo / "docs.md").write_text("API_TOKEN=abc123\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", "docs.md"], check=True)

    decision = default_registry().evaluate(_request(repo, actor_role="guardian"))

    assert decision.action == "deny"
    assert decision.policy_name == "bash_git_who"
