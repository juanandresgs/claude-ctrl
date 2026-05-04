from __future__ import annotations

from pathlib import Path

from runtime.core.authority_registry import capabilities_for
from runtime.core.policies.write_admission_gate import check as write_admission_gate
from runtime.core.policy_engine import PolicyContext, PolicyRequest


def _context(root: Path, *, actor_role: str = "") -> PolicyContext:
    return PolicyContext(
        actor_role=actor_role,
        actor_id="agent-admission",
        workflow_id="wf-admission",
        worktree_path=str(root),
        branch="",
        project_root=str(root),
        is_meta_repo=False,
        lease=None,
        scope=None,
        eval_state=None,
        test_state=None,
        binding=None,
        dispatch_phase=None,
        capabilities=capabilities_for(actor_role),
    )


def _request(root: Path, *, actor_role: str = "") -> PolicyRequest:
    return PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={"file_path": str(root / "src" / "app.py")},
        context=_context(root, actor_role=actor_role),
        cwd=str(root),
    )


def test_non_git_source_write_routes_to_guardian_admission(tmp_path):
    root = tmp_path / "project"
    root.mkdir()
    decision = write_admission_gate(_request(root))

    assert decision is not None
    assert decision.action == "deny"
    assert decision.policy_name == "write_admission_gate"
    assert "ADMISSION_REQUIRED" in decision.reason
    assert "project_onboarding_required" in decision.reason
    assert decision.metadata["guardian_admission"]["next_authority"] == "workflow_bootstrap"


def test_implementer_capability_skips_admission_gate(tmp_path):
    root = tmp_path / "project"
    root.mkdir()
    assert write_admission_gate(_request(root, actor_role="implementer")) is None
