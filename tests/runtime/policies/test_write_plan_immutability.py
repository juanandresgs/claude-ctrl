"""Tests for plan_immutability policy.

@decision DEC-PE-W2-TEST-006
Title: plan_immutability tests mock the planctl.py subprocess (external boundary)
Status: accepted
Rationale: planctl.py is an external process boundary — it has its own test
  suite (tests/runtime/test_planctl.py). Mocking subprocess.run here is
  appropriate because we are testing the policy's interpretation of planctl's
  output, not planctl itself. The mock is the correct tool: planctl is an
  external boundary the same way an HTTP API would be. All skip conditions
  (file name, env var, missing files) are tested without mocks.

Production sequence:
  Claude Write MASTER_PLAN.md -> pre-write.sh -> cc-policy evaluate ->
  plan_immutability(request) -> subprocess planctl check-immutability ->
  deny if immutable=false.
"""

from __future__ import annotations

import json
import os
import tempfile
from unittest.mock import MagicMock, patch

from runtime.core.policies.write_plan_immutability import plan_immutability
from runtime.core.policy_engine import PolicyContext, PolicyRequest

# @mock-exempt: planctl.py is an external subprocess boundary with its own test suite


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_context(project_root: str) -> PolicyContext:
    return PolicyContext(
        actor_role="planner",
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


def _req(file_path: str, project_root: str) -> PolicyRequest:
    return PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={"file_path": file_path},
        context=_make_context(project_root),
        cwd=project_root,
    )


def _setup_project(tmpdir: str) -> tuple[str, str]:
    """Create planctl.py stub and .plan-baseline.json in tmpdir.

    Returns (planctl_path, master_plan_path).
    """
    scripts_dir = os.path.join(tmpdir, "scripts")
    os.makedirs(scripts_dir, exist_ok=True)
    planctl = os.path.join(scripts_dir, "planctl.py")
    with open(planctl, "w") as f:
        f.write("# stub\n")

    baseline = os.path.join(tmpdir, ".plan-baseline.json")
    with open(baseline, "w") as f:
        json.dump({"version": 1}, f)

    master_plan = os.path.join(tmpdir, "MASTER_PLAN.md")
    with open(master_plan, "w") as f:
        f.write("# Plan\n")

    return planctl, master_plan


# ---------------------------------------------------------------------------
# Skip cases (no subprocess calls needed)
# ---------------------------------------------------------------------------


def test_non_master_plan_skipped():
    with tempfile.TemporaryDirectory() as tmpdir:
        assert plan_immutability(_req(os.path.join(tmpdir, "app.py"), tmpdir)) is None


def test_plan_migration_env_bypasses(monkeypatch):
    with tempfile.TemporaryDirectory() as tmpdir:
        monkeypatch.setenv("CLAUDE_PLAN_MIGRATION", "1")
        _, master_plan = _setup_project(tmpdir)
        assert plan_immutability(_req(master_plan, tmpdir)) is None


def test_no_planctl_skipped():
    with tempfile.TemporaryDirectory() as tmpdir:
        # Only baseline, no planctl
        baseline = os.path.join(tmpdir, ".plan-baseline.json")
        with open(baseline, "w") as f:
            json.dump({}, f)
        master_plan = os.path.join(tmpdir, "MASTER_PLAN.md")
        with open(master_plan, "w") as f:
            f.write("# Plan\n")
        assert plan_immutability(_req(master_plan, tmpdir)) is None


def test_no_baseline_skipped():
    with tempfile.TemporaryDirectory() as tmpdir:
        scripts_dir = os.path.join(tmpdir, "scripts")
        os.makedirs(scripts_dir)
        with open(os.path.join(scripts_dir, "planctl.py"), "w") as f:
            f.write("# stub\n")
        master_plan = os.path.join(tmpdir, "MASTER_PLAN.md")
        with open(master_plan, "w") as f:
            f.write("# Plan\n")
        # No .plan-baseline.json
        assert plan_immutability(_req(master_plan, tmpdir)) is None


def test_file_not_on_disk_skipped():
    with tempfile.TemporaryDirectory() as tmpdir:
        _setup_project(tmpdir)
        # Request for a MASTER_PLAN.md path that does not exist on disk
        nonexistent = os.path.join(tmpdir, "subdir", "MASTER_PLAN.md")
        assert plan_immutability(_req(nonexistent, tmpdir)) is None


# ---------------------------------------------------------------------------
# Allow: planctl returns immutable=true
# ---------------------------------------------------------------------------


def test_allow_when_immutable_true():
    with tempfile.TemporaryDirectory() as tmpdir:
        _, master_plan = _setup_project(tmpdir)
        planctl_output = json.dumps({"immutable": True, "violations": []})
        mock_result = MagicMock()
        mock_result.stdout = planctl_output
        mock_result.returncode = 0

        with patch("subprocess.run", return_value=mock_result):
            result = plan_immutability(_req(master_plan, tmpdir))
        assert result is None


def test_allow_when_planctl_empty_output():
    """Empty planctl output (unexpected failure) — allow through."""
    with tempfile.TemporaryDirectory() as tmpdir:
        _, master_plan = _setup_project(tmpdir)
        mock_result = MagicMock()
        mock_result.stdout = ""
        mock_result.returncode = 1

        with patch("subprocess.run", return_value=mock_result):
            result = plan_immutability(_req(master_plan, tmpdir))
        assert result is None


# ---------------------------------------------------------------------------
# Deny: planctl returns immutable=false
# ---------------------------------------------------------------------------


def test_deny_when_immutable_false():
    with tempfile.TemporaryDirectory() as tmpdir:
        _, master_plan = _setup_project(tmpdir)
        planctl_output = json.dumps(
            {
                "immutable": False,
                "violations": [{"reason": "permanent section 'Architecture' was modified"}],
            }
        )
        mock_result = MagicMock()
        mock_result.stdout = planctl_output
        mock_result.returncode = 1

        with patch("subprocess.run", return_value=mock_result):
            result = plan_immutability(_req(master_plan, tmpdir))

        assert result is not None
        assert result.action == "deny"
        assert "permanent section" in result.reason
        assert "Architecture" in result.reason
        assert result.policy_name == "plan_immutability"


def test_deny_reason_fallback_when_no_violations():
    with tempfile.TemporaryDirectory() as tmpdir:
        _, master_plan = _setup_project(tmpdir)
        planctl_output = json.dumps({"immutable": False, "violations": []})
        mock_result = MagicMock()
        mock_result.stdout = planctl_output
        mock_result.returncode = 1

        with patch("subprocess.run", return_value=mock_result):
            result = plan_immutability(_req(master_plan, tmpdir))

        assert result is not None
        assert result.action == "deny"
        assert "permanent section modified" in result.reason


# ---------------------------------------------------------------------------
# Compound integration test
# ---------------------------------------------------------------------------


def test_registry_immutability_fires_after_plan_exists():
    """Integration: plan_immutability (500) runs after plan_exists (400).

    plan_exists passes (MASTER_PLAN.md exists), then plan_immutability
    fires and denies. Exercises cross-boundary evaluation sequence.
    """
    from runtime.core.policies.write_plan_exists import plan_exists as pe
    from runtime.core.policies.write_plan_immutability import plan_immutability as pi
    from runtime.core.policy_engine import PolicyRegistry

    with tempfile.TemporaryDirectory() as tmpdir:
        _, master_plan = _setup_project(tmpdir)
        # Also need git repo for plan_exists git check
        import subprocess as _sp

        _sp.run(["git", "init", tmpdir], capture_output=True)

        planctl_output = json.dumps(
            {
                "immutable": False,
                "violations": [{"reason": "section modified"}],
            }
        )
        mock_result = MagicMock()
        mock_result.stdout = planctl_output
        mock_result.returncode = 1

        reg = PolicyRegistry()
        reg.register("plan_exists", pe, event_types=["Write", "Edit"], priority=400)
        reg.register("plan_immutability", pi, event_types=["Write", "Edit"], priority=500)

        req = PolicyRequest(
            event_type="Write",
            tool_name="Write",
            tool_input={"file_path": master_plan, "content": "x\n" * 25},
            context=_make_context(tmpdir),
            cwd=tmpdir,
        )

        with patch("subprocess.run") as mock_run:

            def side_effect(cmd, **kwargs):
                if "planctl.py" in str(cmd):
                    return mock_result
                # For all other subprocess calls (git), return success
                real_result = MagicMock()
                real_result.returncode = 0
                real_result.stdout = ""
                return real_result

            mock_run.side_effect = side_effect
            decision = reg.evaluate(req)

        assert decision.action == "deny"
        assert decision.policy_name == "plan_immutability"
