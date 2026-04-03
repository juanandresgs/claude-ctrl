"""Tests for decision_log policy.

@decision DEC-PE-W2-TEST-007
Title: decision_log tests mock planctl.py subprocess (external boundary)
Status: accepted
Rationale: Same rationale as plan_immutability tests — planctl.py is an
  external process boundary with its own test suite. Mocking subprocess.run
  is appropriate here: we test the policy's interpretation of planctl's
  check-decision-log output, not planctl itself. All precondition skips are
  tested without mocks.

Production sequence:
  Claude Write MASTER_PLAN.md -> pre-write.sh -> cc-policy evaluate ->
  decision_log(request) -> subprocess planctl check-decision-log ->
  deny if append_only=false.
"""

from __future__ import annotations

import json
import os
import tempfile
from unittest.mock import MagicMock, patch

from runtime.core.policies.write_decision_log import decision_log
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
    """Create planctl.py stub, .plan-baseline.json, and MASTER_PLAN.md."""
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
        f.write("# Plan\n## Decision Log\n- DEC-001: initial\n")

    return planctl, master_plan


# ---------------------------------------------------------------------------
# Skip cases (no subprocess calls needed)
# ---------------------------------------------------------------------------


def test_non_master_plan_skipped():
    with tempfile.TemporaryDirectory() as tmpdir:
        assert decision_log(_req(os.path.join(tmpdir, "app.py"), tmpdir)) is None


def test_plan_migration_env_bypasses(monkeypatch):
    with tempfile.TemporaryDirectory() as tmpdir:
        monkeypatch.setenv("CLAUDE_PLAN_MIGRATION", "1")
        _, master_plan = _setup_project(tmpdir)
        assert decision_log(_req(master_plan, tmpdir)) is None


def test_no_planctl_skipped():
    with tempfile.TemporaryDirectory() as tmpdir:
        baseline = os.path.join(tmpdir, ".plan-baseline.json")
        with open(baseline, "w") as f:
            json.dump({}, f)
        master_plan = os.path.join(tmpdir, "MASTER_PLAN.md")
        with open(master_plan, "w") as f:
            f.write("# Plan\n")
        assert decision_log(_req(master_plan, tmpdir)) is None


def test_no_baseline_skipped():
    with tempfile.TemporaryDirectory() as tmpdir:
        scripts_dir = os.path.join(tmpdir, "scripts")
        os.makedirs(scripts_dir)
        with open(os.path.join(scripts_dir, "planctl.py"), "w") as f:
            f.write("# stub\n")
        master_plan = os.path.join(tmpdir, "MASTER_PLAN.md")
        with open(master_plan, "w") as f:
            f.write("# Plan\n")
        assert decision_log(_req(master_plan, tmpdir)) is None


def test_file_not_on_disk_skipped():
    with tempfile.TemporaryDirectory() as tmpdir:
        _setup_project(tmpdir)
        nonexistent = os.path.join(tmpdir, "subdir", "MASTER_PLAN.md")
        assert decision_log(_req(nonexistent, tmpdir)) is None


# ---------------------------------------------------------------------------
# Allow: planctl returns append_only=true
# ---------------------------------------------------------------------------


def test_allow_when_append_only_true():
    with tempfile.TemporaryDirectory() as tmpdir:
        _, master_plan = _setup_project(tmpdir)
        planctl_output = json.dumps({"append_only": True, "violations": []})
        mock_result = MagicMock()
        mock_result.stdout = planctl_output
        mock_result.returncode = 0

        with patch("subprocess.run", return_value=mock_result):
            result = decision_log(_req(master_plan, tmpdir))
        assert result is None


def test_allow_when_planctl_empty_output():
    """Empty planctl output (unexpected failure) — allow through."""
    with tempfile.TemporaryDirectory() as tmpdir:
        _, master_plan = _setup_project(tmpdir)
        mock_result = MagicMock()
        mock_result.stdout = ""
        mock_result.returncode = 1

        with patch("subprocess.run", return_value=mock_result):
            result = decision_log(_req(master_plan, tmpdir))
        assert result is None


def test_allow_when_planctl_invalid_json():
    with tempfile.TemporaryDirectory() as tmpdir:
        _, master_plan = _setup_project(tmpdir)
        mock_result = MagicMock()
        mock_result.stdout = "not-json"
        mock_result.returncode = 0

        with patch("subprocess.run", return_value=mock_result):
            result = decision_log(_req(master_plan, tmpdir))
        assert result is None


# ---------------------------------------------------------------------------
# Deny: planctl returns append_only=false
# ---------------------------------------------------------------------------


def test_deny_when_append_only_false():
    with tempfile.TemporaryDirectory() as tmpdir:
        _, master_plan = _setup_project(tmpdir)
        planctl_output = json.dumps(
            {
                "append_only": False,
                "violations": [{"reason": "DEC-001 entry was deleted"}],
            }
        )
        mock_result = MagicMock()
        mock_result.stdout = planctl_output
        mock_result.returncode = 1

        with patch("subprocess.run", return_value=mock_result):
            result = decision_log(_req(master_plan, tmpdir))

        assert result is not None
        assert result.action == "deny"
        assert "DEC-001" in result.reason
        assert result.policy_name == "decision_log"


def test_deny_reason_fallback_when_no_violations():
    with tempfile.TemporaryDirectory() as tmpdir:
        _, master_plan = _setup_project(tmpdir)
        planctl_output = json.dumps({"append_only": False, "violations": []})
        mock_result = MagicMock()
        mock_result.stdout = planctl_output
        mock_result.returncode = 1

        with patch("subprocess.run", return_value=mock_result):
            result = decision_log(_req(master_plan, tmpdir))

        assert result is not None
        assert result.action == "deny"
        assert "entries modified or reordered" in result.reason


# ---------------------------------------------------------------------------
# Compound integration test
# ---------------------------------------------------------------------------


def test_registry_decision_log_fires_after_immutability():
    """Integration: decision_log (600) runs after plan_immutability (500).

    When immutability passes (immutable=true), decision_log must still fire
    and deny if append_only=false. Exercises the two planctl-backed policies
    running in sequence through the registry.
    """
    from runtime.core.policies.write_decision_log import decision_log as dl
    from runtime.core.policies.write_plan_immutability import plan_immutability as pi
    from runtime.core.policy_engine import PolicyRegistry

    with tempfile.TemporaryDirectory() as tmpdir:
        _, master_plan = _setup_project(tmpdir)

        immutability_ok = json.dumps({"immutable": True, "violations": []})
        decision_log_fail = json.dumps(
            {
                "append_only": False,
                "violations": [{"reason": "entry reordered"}],
            }
        )

        call_count = [0]

        def planctl_side_effect(cmd, **kwargs):
            r = MagicMock()
            r.returncode = 0
            if "check-immutability" in str(cmd):
                r.stdout = immutability_ok
            elif "check-decision-log" in str(cmd):
                r.stdout = decision_log_fail
                r.returncode = 1
            else:
                r.stdout = ""
            call_count[0] += 1
            return r

        reg = PolicyRegistry()
        reg.register("plan_immutability", pi, event_types=["Write", "Edit"], priority=500)
        reg.register("decision_log", dl, event_types=["Write", "Edit"], priority=600)

        req = _req(master_plan, tmpdir)

        with patch("subprocess.run", side_effect=planctl_side_effect):
            decision = reg.evaluate(req)

        assert decision.action == "deny"
        assert decision.policy_name == "decision_log"
        assert call_count[0] >= 2  # both planctl calls were made
