from __future__ import annotations

from pathlib import Path

from runtime.core.authority_registry import capabilities_for
from runtime.core.policies.bash_admission_gate import check as bash_admission_gate
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


def _request(root: Path, command: str, *, actor_role: str = "") -> PolicyRequest:
    return PolicyRequest(
        event_type="PreToolUse",
        tool_name="Bash",
        tool_input={"command": command},
        context=_context(root, actor_role=actor_role),
        cwd=str(root),
    )


def test_bash_source_write_routes_to_guardian_admission(tmp_path):
    root = tmp_path / "project"
    root.mkdir()
    decision = bash_admission_gate(_request(root, "printf 'x' > src/app.py"))

    assert decision is not None
    assert decision.action == "deny"
    assert decision.policy_name == "bash_admission_gate"
    assert "ADMISSION_REQUIRED" in decision.reason
    assert "project_onboarding_required" in decision.reason


def test_bash_implementer_capability_skips_admission_gate(tmp_path):
    root = tmp_path / "project"
    root.mkdir()
    assert (
        bash_admission_gate(
            _request(root, "printf 'x' > src/app.py", actor_role="implementer")
        )
        is None
    )
