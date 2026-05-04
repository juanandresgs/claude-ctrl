"""Tests for plan_exists policy.

@decision DEC-PE-W2-TEST-005
Title: plan_exists tests use real git repos and temp MASTER_PLAN.md files
Status: accepted
Rationale: plan_exists calls git subprocess (git rev-parse, git rev-list, git
  ls-files) to compute staleness. The correct test approach is a real git repo
  in a temp directory with a real MASTER_PLAN.md. This exercises the actual
  staleness-computation path. Staleness thresholds are controlled via env vars
  (PLAN_CHURN_WARN, PLAN_CHURN_DENY) to avoid fragility from real git history.

Production sequence:
  Claude Write tool fires -> pre-write.sh -> cc-policy evaluate ->
  plan_exists(request) -> deny/feedback/allow based on plan state.
"""

from __future__ import annotations

import os
import subprocess
import tempfile

from runtime.core.policies.write_plan_exists import plan_exists
from runtime.core.policy_engine import PolicyContext, PolicyRequest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_context(project_root: str, actor_role: str = "implementer") -> PolicyContext:
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


def _req(
    file_path: str,
    project_root: str,
    tool_name: str = "Write",
    content: str = "x\n" * 25,
) -> PolicyRequest:
    return PolicyRequest(
        event_type="Write",
        tool_name=tool_name,
        tool_input={"file_path": file_path, "content": content},
        context=_make_context(project_root),
        cwd=project_root,
    )


def _init_git_repo(tmpdir: str) -> None:
    subprocess.run(["git", "init", "-b", "feature/test", tmpdir], capture_output=True)
    current = subprocess.run(
        ["git", "-C", tmpdir, "symbolic-ref", "--short", "HEAD"],
        capture_output=True,
        text=True,
    ).stdout.strip()
    if not current or current == "HEAD":
        subprocess.run(["git", "-C", tmpdir, "checkout", "-b", "feature/test"], capture_output=True)
    subprocess.run(
        ["git", "-C", tmpdir, "config", "user.email", "test@test.com"], capture_output=True
    )
    subprocess.run(["git", "-C", tmpdir, "config", "user.name", "Test"], capture_output=True)


def _write_master_plan(tmpdir: str, content: str = "# Plan\n") -> None:
    with open(os.path.join(tmpdir, "MASTER_PLAN.md"), "w") as f:
        f.write(content)


# ---------------------------------------------------------------------------
# Skip cases
# ---------------------------------------------------------------------------


def test_no_file_path_returns_none():
    with tempfile.TemporaryDirectory() as tmpdir:
        req = PolicyRequest(
            event_type="Write",
            tool_name="Write",
            tool_input={},
            context=_make_context(tmpdir),
            cwd=tmpdir,
        )
        assert plan_exists(req) is None


def test_non_source_file_skipped():
    with tempfile.TemporaryDirectory() as tmpdir:
        assert plan_exists(_req("/proj/README.md", tmpdir)) is None


def test_skippable_path_skipped():
    with tempfile.TemporaryDirectory() as tmpdir:
        assert plan_exists(_req("/proj/vendor/lib.py", tmpdir)) is None


def test_meta_infra_skipped():
    with tempfile.TemporaryDirectory() as tmpdir:
        assert plan_exists(_req(os.path.join(tmpdir, ".claude", "hook.sh"), tmpdir)) is None


def test_edit_tool_requires_plan_before_staleness_bypass():
    """Edit skips staleness only after MASTER_PLAN.md presence is proven."""
    with tempfile.TemporaryDirectory() as tmpdir:
        _init_git_repo(tmpdir)
        req = _req(os.path.join(tmpdir, "app.py"), tmpdir, tool_name="Edit")
        result = plan_exists(req)
        assert result is not None
        assert result.action == "deny"
        assert "MASTER_PLAN.md" in result.reason

        _write_master_plan(tmpdir)
        assert plan_exists(req) is None


def test_small_write_requires_plan_before_fast_mode_feedback():
    """Small writes skip staleness only after MASTER_PLAN.md exists."""
    with tempfile.TemporaryDirectory() as tmpdir:
        _init_git_repo(tmpdir)
        req = _req(
            os.path.join(tmpdir, "app.py"),
            tmpdir,
            tool_name="Write",
            content="x\n" * 5,  # 5 lines < 20
        )
        result = plan_exists(req)
        assert result is not None
        assert result.action == "deny"
        assert "MASTER_PLAN.md" in result.reason

        _write_master_plan(tmpdir)
        result = plan_exists(req)
        assert result is not None
        assert result.action == "feedback"
        assert "Fast-mode bypass" in result.reason


def test_non_git_repo_requires_plan_presence():
    with tempfile.TemporaryDirectory() as tmpdir:
        result = plan_exists(_req(os.path.join(tmpdir, "app.py"), tmpdir))
        assert result is not None
        assert result.action == "deny"
        assert "MASTER_PLAN.md" in result.reason

        _write_master_plan(tmpdir)
        assert plan_exists(_req(os.path.join(tmpdir, "app.py"), tmpdir)) is None


# ---------------------------------------------------------------------------
# Deny: no MASTER_PLAN.md
# ---------------------------------------------------------------------------


def test_deny_when_no_master_plan():
    with tempfile.TemporaryDirectory() as tmpdir:
        _init_git_repo(tmpdir)
        result = plan_exists(_req(os.path.join(tmpdir, "app.py"), tmpdir))
        assert result is not None
        assert result.action == "deny"
        assert "MASTER_PLAN.md" in result.reason
        assert result.policy_name == "plan_exists"


# ---------------------------------------------------------------------------
# Allow: MASTER_PLAN.md exists, fresh repo (no churn/commits)
# ---------------------------------------------------------------------------


def test_allow_when_plan_exists_and_no_staleness():
    with tempfile.TemporaryDirectory() as tmpdir:
        _init_git_repo(tmpdir)
        _write_master_plan(tmpdir)
        result = plan_exists(_req(os.path.join(tmpdir, "app.py"), tmpdir))
        # Fresh repo — no commits, no churn
        assert result is None or result.action in ("allow", "feedback")


# ---------------------------------------------------------------------------
# Staleness thresholds via env vars
# ---------------------------------------------------------------------------


def test_deny_staleness_env_override(monkeypatch):
    """Force deny threshold to 0% so any churn triggers deny."""
    with tempfile.TemporaryDirectory() as tmpdir:
        _init_git_repo(tmpdir)
        _write_master_plan(tmpdir)
        # Set deny threshold to 0 so churn check is bypassed in a different way:
        # we set warn=0, deny=0 — the staleness helpers compute 0% churn on
        # a fresh repo, so 0 >= 0 triggers deny tier.
        monkeypatch.setenv("PLAN_CHURN_DENY", "0")
        monkeypatch.setenv("PLAN_CHURN_WARN", "0")
        result = plan_exists(_req(os.path.join(tmpdir, "app.py"), tmpdir))
        # 0% >= 0% deny threshold -> deny
        assert result is not None
        assert result.action == "deny"
        assert "critically stale" in result.reason or "MASTER_PLAN" in result.reason


# ---------------------------------------------------------------------------
# Compound integration test
# ---------------------------------------------------------------------------


def test_registry_plan_exists_fires_after_enforcement_gap():
    """Integration: plan_exists (400) runs after enforcement_gap (250).

    When enforcement_gap passes (no gaps file), plan_exists must still deny
    if MASTER_PLAN.md is absent. Exercises the cross-boundary sequence:
    enforcement_gap returns None -> plan_exists returns deny.
    """
    from runtime.core.policies.write_enforcement_gap import enforcement_gap as eg
    from runtime.core.policies.write_plan_exists import plan_exists as pe
    from runtime.core.policy_engine import PolicyRegistry

    with tempfile.TemporaryDirectory() as tmpdir:
        _init_git_repo(tmpdir)
        # No MASTER_PLAN.md, no gaps file

        reg = PolicyRegistry()
        reg.register("enforcement_gap", eg, event_types=["Write", "Edit"], priority=250)
        reg.register("plan_exists", pe, event_types=["Write", "Edit"], priority=400)

        req = _req(os.path.join(tmpdir, "app.py"), tmpdir)
        decision = reg.evaluate(req)
        assert decision.action == "deny"
        assert decision.policy_name == "plan_exists"
