"""Tests for write_branch (branch_guard) policy.

@decision DEC-PE-W2-TEST-001
Title: branch_guard tests use real git repos for branch detection
Status: accepted
Rationale: branch_guard's core logic is a git subprocess call. Mocking
  subprocess.run would test the mock, not the policy. We use tempfile.TemporaryDirectory
  with real git init/checkout to exercise the actual production path: policy
  reads the branch from git, not from PolicyContext.branch. This is the
  only external boundary that cannot be avoided (git is the authority on branch).

Production sequence:
  Claude Write/Edit -> pre-write.sh -> cc-policy evaluate ->
  PolicyRegistry.evaluate() -> branch_guard(request) -> deny if on main/master.
"""

from __future__ import annotations

import os
import subprocess
import tempfile

from runtime.core.policies.write_branch import branch_guard
from runtime.core.policy_engine import PolicyContext, PolicyRequest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_context(project_root: str = "/proj", actor_role: str = "implementer") -> PolicyContext:
    return PolicyContext(
        actor_role=actor_role,
        actor_id="agent-1",
        workflow_id="wf-1",
        worktree_path=project_root,
        branch="feature/test",
        project_root=project_root,
        is_meta_repo=False,
        lease=None,
        scope=None,
        eval_state=None,
        test_state=None,
        binding=None,
        dispatch_phase=None,
    )


def _make_request(
    file_path: str,
    context: PolicyContext | None = None,
    tool_name: str = "Write",
) -> PolicyRequest:
    ctx = context or _make_context()
    return PolicyRequest(
        event_type="Write",
        tool_name=tool_name,
        tool_input={"file_path": file_path},
        context=ctx,
        cwd="/proj",
    )


# ---------------------------------------------------------------------------
# Skip cases — must return None
# ---------------------------------------------------------------------------


def test_no_file_path_returns_none():
    req = PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={},
        context=_make_context(),
        cwd="/proj",
    )
    assert branch_guard(req) is None


def test_meta_infra_skipped():
    """Files under {project_root}/.claude/ are skipped."""
    req = _make_request("/proj/.claude/hooks/foo.py")
    assert branch_guard(req) is None


def test_master_plan_skipped():
    req = _make_request("/proj/MASTER_PLAN.md")
    assert branch_guard(req) is None


def test_non_source_file_skipped():
    """JSON files are not source files — no opinion."""
    req = _make_request("/proj/config.json")
    assert branch_guard(req) is None


def test_skippable_path_skipped():
    """vendor/ paths are skippable — no opinion."""
    req = _make_request("/proj/vendor/lib.py")
    assert branch_guard(req) is None


def test_non_git_repo_skipped():
    """Files not inside any git repo — no opinion."""
    with tempfile.TemporaryDirectory() as tmpdir:
        source_file = os.path.join(tmpdir, "app.py")
        req = _make_request(source_file, context=_make_context(project_root=tmpdir))
        result = branch_guard(req)
        assert result is None


def test_non_main_branch_skipped():
    """Files on a feature branch — no opinion."""
    with tempfile.TemporaryDirectory() as tmpdir:
        subprocess.run(["git", "init", tmpdir], check=True, capture_output=True)
        subprocess.run(
            ["git", "-C", tmpdir, "checkout", "-b", "feature/wip"],
            check=True,
            capture_output=True,
        )
        source_file = os.path.join(tmpdir, "app.py")
        req = _make_request(source_file, context=_make_context(project_root=tmpdir))
        assert branch_guard(req) is None


# ---------------------------------------------------------------------------
# Deny cases
# ---------------------------------------------------------------------------


def _init_repo_on_branch(tmpdir: str, branch: str) -> None:
    """Initialize a git repo and check out the given branch."""
    subprocess.run(["git", "init", tmpdir], check=True, capture_output=True)
    current = subprocess.run(
        ["git", "-C", tmpdir, "symbolic-ref", "--short", "HEAD"],
        capture_output=True,
        text=True,
    ).stdout.strip()
    if current != branch:
        subprocess.run(
            ["git", "-C", tmpdir, "checkout", "-b", branch],
            check=True,
            capture_output=True,
        )


def test_deny_on_main_branch():
    """Source write on main branch must be denied."""
    with tempfile.TemporaryDirectory() as tmpdir:
        _init_repo_on_branch(tmpdir, "main")
        source_file = os.path.join(tmpdir, "app.py")
        req = _make_request(source_file, context=_make_context(project_root=tmpdir))
        result = branch_guard(req)
        assert result is not None
        assert result.action == "deny"
        assert "main" in result.reason
        assert "Sacred Practice #2" in result.reason
        assert result.policy_name == "branch_guard"


def test_deny_on_master_branch():
    """Source write on master branch must be denied."""
    with tempfile.TemporaryDirectory() as tmpdir:
        _init_repo_on_branch(tmpdir, "master")
        source_file = os.path.join(tmpdir, "service.go")
        req = _make_request(source_file, context=_make_context(project_root=tmpdir))
        result = branch_guard(req)
        assert result is not None
        assert result.action == "deny"
        assert "master" in result.reason
        assert result.policy_name == "branch_guard"


# ---------------------------------------------------------------------------
# Compound integration test — real production sequence
# ---------------------------------------------------------------------------


def test_registry_branch_guard_fires_before_write_who():
    """Integration: branch_guard (priority 100) stops evaluation before write_who (200).

    On main, branch_guard must deny so write_who never runs. This exercises
    the real PolicyRegistry.evaluate() short-circuit path end-to-end.
    """
    from runtime.core.policies.write_branch import branch_guard as bg
    from runtime.core.policies.write_who import write_who as ww
    from runtime.core.policy_engine import PolicyRegistry

    reg = PolicyRegistry()
    reg.register("branch_guard", bg, event_types=["Write", "Edit"], priority=100)
    reg.register("write_who", ww, event_types=["Write", "Edit"], priority=200)

    with tempfile.TemporaryDirectory() as tmpdir:
        _init_repo_on_branch(tmpdir, "main")

        # implementer role — write_who would pass, but branch_guard must fire first
        ctx = _make_context(project_root=tmpdir, actor_role="implementer")
        req = PolicyRequest(
            event_type="Write",
            tool_name="Write",
            tool_input={"file_path": os.path.join(tmpdir, "app.py")},
            context=ctx,
            cwd=tmpdir,
        )
        decision = reg.evaluate(req)
        assert decision.action == "deny"
        assert decision.policy_name == "branch_guard"
