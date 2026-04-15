"""Tests for plan_guard policy.

@decision DEC-PE-W2-TEST-004
Title: plan_guard tests use hand-crafted PolicyContext and env var manipulation
Status: accepted
Rationale: plan_guard is a pure function of context.capabilities, the file path
  classification (is_governance_markdown + is_constitution_level), and the
  CLAUDE_PLAN_MIGRATION env var. No subprocess calls, no disk I/O. All tests
  use in-memory fixtures and monkeypatch for env var control.

Production sequence:
  Claude Write/Edit -> pre-write.sh -> cc-policy evaluate ->
  plan_guard(request) -> deny if actor lacks CAN_WRITE_GOVERNANCE writing
  governance markdown or constitution-level file.
"""

from __future__ import annotations

from runtime.core.authority_registry import capabilities_for
from runtime.core.policies.write_plan_guard import plan_guard
from runtime.core.policy_engine import PolicyContext, PolicyRequest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_context(actor_role: str = "", project_root: str = "/proj") -> PolicyContext:
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
        capabilities=capabilities_for(actor_role),
    )


def _req(file_path: str, role: str = "", project_root: str = "/proj") -> PolicyRequest:
    return PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={"file_path": file_path},
        context=_make_context(actor_role=role, project_root=project_root),
        cwd=project_root,
    )


# ---------------------------------------------------------------------------
# Skip cases
# ---------------------------------------------------------------------------


def test_no_file_path_returns_none():
    req = PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={},
        context=_make_context(),
        cwd="/proj",
    )
    assert plan_guard(req) is None


def test_meta_infra_skipped():
    assert plan_guard(_req("/proj/.claude/agents/planner.md")) is None


def test_non_governance_file_skipped():
    """Source files and non-governance docs are not governed by plan_guard."""
    assert plan_guard(_req("/proj/src/main.py")) is None
    assert plan_guard(_req("/proj/README.md")) is None
    assert plan_guard(_req("/proj/notes/todo.md")) is None


def test_plan_migration_env_bypasses_check(monkeypatch):
    """CLAUDE_PLAN_MIGRATION=1 allows any role to write governance files."""
    monkeypatch.setenv("CLAUDE_PLAN_MIGRATION", "1")
    # orchestrator (empty role) would normally be denied
    result = plan_guard(_req("/proj/MASTER_PLAN.md", role=""))
    assert result is None


# ---------------------------------------------------------------------------
# Allow cases — planner / Plan role
# ---------------------------------------------------------------------------


def test_planner_role_allowed():
    assert plan_guard(_req("/proj/MASTER_PLAN.md", role="planner")) is None


def test_Plan_role_allowed():
    """'Plan' capitalized is a planner alias seen in SubagentStart payloads."""
    assert plan_guard(_req("/proj/MASTER_PLAN.md", role="Plan")) is None


def test_planner_allowed_for_agents_md():
    assert plan_guard(_req("/proj/agents/implementer.md", role="planner")) is None


def test_planner_allowed_for_claude_md():
    assert plan_guard(_req("/proj/CLAUDE.md", role="planner")) is None


def test_planner_allowed_for_docs_md():
    assert plan_guard(_req("/proj/docs/architecture.md", role="planner")) is None


# ---------------------------------------------------------------------------
# Deny cases
# ---------------------------------------------------------------------------


def test_orchestrator_denied_for_master_plan():
    result = plan_guard(_req("/proj/MASTER_PLAN.md", role=""))
    assert result is not None
    assert result.action == "deny"
    assert "orchestrator" in result.reason
    assert result.policy_name == "plan_guard"


def test_implementer_denied_for_master_plan():
    result = plan_guard(_req("/proj/MASTER_PLAN.md", role="implementer"))
    assert result is not None
    assert result.action == "deny"
    assert "implementer" in result.reason


def test_tester_denied_for_agents_md():
    result = plan_guard(_req("/proj/agents/tester.md", role="tester"))
    assert result is not None
    assert result.action == "deny"


def test_guardian_denied_for_claude_md():
    result = plan_guard(_req("/proj/CLAUDE.md", role="guardian"))
    assert result is not None
    assert result.action == "deny"


def test_deny_reason_includes_file_path():
    """Deny reason must name the file so agents know what triggered it."""
    result = plan_guard(_req("/proj/MASTER_PLAN.md", role="implementer"))
    assert result is not None
    assert "/proj/MASTER_PLAN.md" in result.reason


# ---------------------------------------------------------------------------
# Compound integration test
# ---------------------------------------------------------------------------


def test_registry_plan_guard_fires_only_for_governance_files():
    """Integration: plan_guard (300) does not affect source files in the registry.

    Exercises the full registry.evaluate() path: source file passes plan_guard,
    governance file is denied unless role is planner.
    """
    from runtime.core.policies.write_plan_guard import plan_guard as pg
    from runtime.core.policy_engine import PolicyRegistry

    reg = PolicyRegistry()
    reg.register("plan_guard", pg, event_types=["Write", "Edit"], priority=300)

    # Source file — plan_guard has no opinion
    src_req = _req("/proj/app.py", role="implementer")
    assert reg.evaluate(src_req).action == "allow"

    # Governance file by non-planner — denied
    gov_req = _req("/proj/MASTER_PLAN.md", role="implementer")
    gov_decision = reg.evaluate(gov_req)
    assert gov_decision.action == "deny"
    assert gov_decision.policy_name == "plan_guard"

    # Governance file by planner — allowed
    planner_req = _req("/proj/MASTER_PLAN.md", role="planner")
    assert reg.evaluate(planner_req).action == "allow"


# ---------------------------------------------------------------------------
# Capability-gate invariant tests (Phase 3)
# ---------------------------------------------------------------------------


def test_Plan_alias_resolves_via_capability():
    """'Plan' alias (capitalized) is resolved through _LIVE_ROLE_ALIASES.

    capabilities_for("Plan") must return a set containing CAN_WRITE_GOVERNANCE,
    so plan_guard allows it. This test proves the alias resolution, not just
    the role-string check.
    """
    from runtime.core.authority_registry import CAN_WRITE_GOVERNANCE, capabilities_for

    caps = capabilities_for("Plan")
    assert CAN_WRITE_GOVERNANCE in caps
    # The policy itself allows "Plan" via capability
    assert plan_guard(_req("/proj/MASTER_PLAN.md", role="Plan")) is None


def test_capability_gate_not_role_string():
    """Capability presence — not the role string — controls authorization.

    A context with role="unknown_role" but CAN_WRITE_GOVERNANCE injected
    should pass. Proves the policy uses context.capabilities.
    """
    import dataclasses
    from runtime.core.authority_registry import CAN_WRITE_GOVERNANCE

    ctx = dataclasses.replace(
        _make_context(actor_role="unknown_role"),
        capabilities=frozenset({CAN_WRITE_GOVERNANCE}),
    )
    req = PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={"file_path": "/proj/MASTER_PLAN.md"},
        context=ctx,
        cwd="/proj",
    )
    assert plan_guard(req) is None


def test_planner_without_capability_is_denied():
    """Planner role string alone is not sufficient — capability must be present."""
    import dataclasses

    ctx = dataclasses.replace(
        _make_context(actor_role="planner"),
        capabilities=frozenset(),
    )
    req = PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={"file_path": "/proj/MASTER_PLAN.md"},
        context=ctx,
        cwd="/proj",
    )
    result = plan_guard(req)
    assert result is not None
    assert result.action == "deny"


# ---------------------------------------------------------------------------
# Constitution-level file enforcement (Phase 7 Slice 6)
# ---------------------------------------------------------------------------


def test_implementer_denied_for_constitution_level_source_file():
    """Implementer is denied for a non-markdown constitution file."""
    result = plan_guard(_req("/proj/runtime/cli.py", role="implementer"))
    assert result is not None
    assert result.action == "deny"
    assert "constitution-level" in result.reason
    assert result.policy_name == "plan_guard"


def test_implementer_denied_for_constitution_level_stage_registry():
    """Another non-markdown constitution file."""
    result = plan_guard(_req("/proj/runtime/core/stage_registry.py", role="implementer"))
    assert result is not None
    assert result.action == "deny"
    assert "constitution-level" in result.reason


def test_planner_allowed_for_constitution_level_source_file():
    """Planner (CAN_WRITE_GOVERNANCE) is allowed for constitution files."""
    assert plan_guard(_req("/proj/runtime/cli.py", role="planner")) is None


def test_Plan_allowed_for_constitution_level_source_file():
    """'Plan' alias also works for constitution files."""
    assert plan_guard(_req("/proj/runtime/core/stage_registry.py", role="Plan")) is None


def test_plan_migration_env_bypasses_constitution_check(monkeypatch):
    """CLAUDE_PLAN_MIGRATION=1 bypasses constitution-level enforcement."""
    monkeypatch.setenv("CLAUDE_PLAN_MIGRATION", "1")
    assert plan_guard(_req("/proj/runtime/cli.py", role="implementer")) is None


def test_unrelated_source_file_unaffected_by_constitution_check():
    """Files not in the constitution registry remain ungated by plan_guard."""
    assert plan_guard(_req("/proj/runtime/core/some_other_module.py", role="implementer")) is None
    assert plan_guard(_req("/proj/src/main.py", role="implementer")) is None


def test_constitution_check_uses_registry_not_hardcoded_list():
    """The policy delegates to constitution_registry.is_constitution_level,
    so any file added to the registry is automatically gated."""
    from runtime.core.constitution_registry import CONCRETE_PATHS

    # Verify at least one non-markdown path is gated.
    non_md = [p for p in CONCRETE_PATHS if not p.endswith(".md")]
    assert len(non_md) > 0, "registry must have non-markdown concrete entries"
    sample = non_md[0]
    result = plan_guard(_req(f"/proj/{sample}", role="implementer"))
    assert result is not None
    assert result.action == "deny"


def test_constitution_relative_path_also_works():
    """Relative paths (no project_root prefix) are also checked."""
    # Use a request with no project_root prefix on the path.
    req = PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={"file_path": "runtime/cli.py"},
        context=_make_context(actor_role="implementer", project_root="/proj"),
        cwd="/proj",
    )
    result = plan_guard(req)
    assert result is not None
    assert result.action == "deny"
    assert "constitution-level" in result.reason
