"""Unit tests for agent_contract_required policy.

Exercises contract enforcement for dispatch-significant Agent/Task tool
invocations (DEC-POLICY-AGENT-CONTRACT-001). Dispatch-significant subagent
types (planner, implementer, guardian, reviewer, Plan) are denied when their
prompt does not start with CLAUDEX_CONTRACT_BLOCK: on line 1. Lightweight
types (Explore, general-purpose, statusline-setup, empty, missing) pass
through unaffected.

@decision DEC-POLICY-AGENT-CONTRACT-TEST-001
@title Unit tests for agent_contract_required policy
@status accepted
@rationale Verify all deny branches (dispatch-significant without contract),
  all allow branches (dispatch-significant with contract, lightweight types,
  non-Agent tools), deny reason text includes remediation CLI, and policy_name
  is correct. PolicyRequest objects are constructed by hand — no DB I/O.
"""

from __future__ import annotations

import sys
from pathlib import Path

# Ensure repo root is importable.
_ROOT = Path(__file__).resolve().parent.parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from runtime.core.authority_registry import capabilities_for
from runtime.core.policies.agent_contract_required import (
    DISPATCH_SIGNIFICANT,
    LIGHTWEIGHT,
    check,
)
from runtime.core.policy_engine import PolicyContext, PolicyDecision, PolicyRequest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _contract_block(stage_id: str) -> str:
    return (
        f'CLAUDEX_CONTRACT_BLOCK:{{"workflow_id":"test-wf","stage_id":"{stage_id}",'
        '"goal_id":"g1","work_item_id":"w1","decision_scope":"kernel","generated_at":1}'
    )


def _make_context(*, actor_role: str = "implementer") -> PolicyContext:
    """Minimal PolicyContext — policies under test do not inspect it."""
    return PolicyContext(
        actor_role=actor_role,
        actor_id="agent-test",
        workflow_id="test-wf",
        worktree_path="/project/.worktrees/test",
        branch="feature/test",
        project_root="/project",
        is_meta_repo=False,
        lease=None,
        scope=None,
        eval_state=None,
        test_state=None,
        binding=None,
        dispatch_phase=None,
        capabilities=capabilities_for(actor_role),
    )


def _make_agent_request(
    *,
    tool_name: str = "Agent",
    subagent_type: str = "",
    prompt: str = "",
    context: PolicyContext | None = None,
) -> PolicyRequest:
    """Build a PolicyRequest for an Agent/Task tool invocation."""
    tool_input: dict = {"prompt": prompt}
    if subagent_type is not None:
        tool_input["subagent_type"] = subagent_type
    if context is None:
        context = _make_context()
    return PolicyRequest(
        event_type="PreToolUse",
        tool_name=tool_name,
        tool_input=tool_input,
        context=context,
        cwd="/project/.worktrees/test",
    )


# ---------------------------------------------------------------------------
# Deny: dispatch-significant without contract
# ---------------------------------------------------------------------------


def test_deny_implementer_no_contract():
    req = _make_agent_request(subagent_type="implementer", prompt="Do some work")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert decision.policy_name == "agent_contract_required"
    assert "cc-policy dispatch agent-prompt" in decision.reason


def test_deny_planner_no_contract():
    req = _make_agent_request(subagent_type="planner", prompt="Plan the task")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert decision.policy_name == "agent_contract_required"


def test_deny_guardian_no_contract():
    req = _make_agent_request(subagent_type="guardian", prompt="Land it")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert decision.policy_name == "agent_contract_required"


def test_deny_reviewer_no_contract():
    req = _make_agent_request(subagent_type="reviewer", prompt="Review this")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert decision.policy_name == "agent_contract_required"


def test_deny_plan_no_contract():
    """'Plan' is dispatch-significant per CLAUDE.md mapping to planner."""
    req = _make_agent_request(subagent_type="Plan", prompt="Build a plan")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert decision.policy_name == "agent_contract_required"


# ---------------------------------------------------------------------------
# Deny: Task tool (not just Agent)
# ---------------------------------------------------------------------------


def test_deny_task_tool_implementer_no_contract():
    req = _make_agent_request(
        tool_name="Task", subagent_type="implementer", prompt="Do work"
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert decision.policy_name == "agent_contract_required"


# ---------------------------------------------------------------------------
# Allow: dispatch-significant WITH valid contract
# ---------------------------------------------------------------------------


def test_allow_implementer_with_contract():
    prompt = f"{_contract_block('implementer')}\n\nDo the implementation work."
    req = _make_agent_request(subagent_type="implementer", prompt=prompt)
    decision = check(req)
    assert decision is None  # allow = no opinion


def test_allow_planner_with_contract():
    prompt = f"{_contract_block('planner')}\n\nBuild the plan."
    req = _make_agent_request(subagent_type="planner", prompt=prompt)
    decision = check(req)
    assert decision is None


def test_allow_guardian_with_contract():
    prompt = f"{_contract_block('guardian:land')}\n\nLand the commit."
    req = _make_agent_request(subagent_type="guardian", prompt=prompt)
    decision = check(req)
    assert decision is None


def test_allow_reviewer_with_contract():
    prompt = f"{_contract_block('reviewer')}\n\nReview the changes."
    req = _make_agent_request(subagent_type="reviewer", prompt=prompt)
    decision = check(req)
    assert decision is None


def test_deny_plan_alias_with_contract_for_planner_stage():
    prompt = f"{_contract_block('planner')}\n\nPlan the feature."
    req = _make_agent_request(subagent_type="Plan", prompt=prompt)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "must launch with subagent_type='planner'" in decision.reason


def test_deny_general_purpose_with_reviewer_contract():
    prompt = f"{_contract_block('reviewer')}\n\nReview the changes."
    req = _make_agent_request(subagent_type="general-purpose", prompt=prompt)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "stage_id='reviewer'" in decision.reason
    assert "required_subagent_type" in decision.reason


def test_deny_missing_subagent_type_with_contract():
    prompt = f"{_contract_block('planner')}\n\nPlan the feature."
    req = _make_agent_request(subagent_type="", prompt=prompt)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "omitted tool_input.subagent_type" in decision.reason


def test_deny_invalid_contract_json():
    prompt = "CLAUDEX_CONTRACT_BLOCK:{not-json}\n\nBad contract"
    req = _make_agent_request(subagent_type="planner", prompt=prompt)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "invalid" in decision.reason


def test_deny_unknown_stage_in_contract():
    prompt = f"{_contract_block('no-such-stage')}\n\nBad stage"
    req = _make_agent_request(subagent_type="planner", prompt=prompt)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "unknown stage_id" in decision.reason


# ---------------------------------------------------------------------------
# Allow: lightweight subagent types (no contract required)
# ---------------------------------------------------------------------------


def test_allow_explore_no_contract():
    req = _make_agent_request(subagent_type="Explore", prompt="Look around")
    decision = check(req)
    assert decision is None


def test_allow_general_purpose_no_contract():
    req = _make_agent_request(subagent_type="general-purpose", prompt="Help")
    decision = check(req)
    assert decision is None


def test_allow_statusline_setup_no_contract():
    req = _make_agent_request(subagent_type="statusline-setup", prompt="Setup")
    decision = check(req)
    assert decision is None


def test_allow_empty_subagent_type_no_contract():
    req = _make_agent_request(subagent_type="", prompt="Something")
    decision = check(req)
    assert decision is None


def test_allow_missing_subagent_type_no_contract():
    """When subagent_type key is absent from tool_input entirely."""
    context = _make_context()
    req = PolicyRequest(
        event_type="PreToolUse",
        tool_name="Agent",
        tool_input={"prompt": "No subagent_type key here"},
        context=context,
        cwd="/project/.worktrees/test",
    )
    decision = check(req)
    assert decision is None


# ---------------------------------------------------------------------------
# Allow: non-Agent tool (skip entirely)
# ---------------------------------------------------------------------------


def test_skip_bash_tool():
    context = _make_context()
    req = PolicyRequest(
        event_type="PreToolUse",
        tool_name="Bash",
        tool_input={"command": "echo hello"},
        context=context,
        cwd="/project/.worktrees/test",
    )
    decision = check(req)
    assert decision is None


def test_skip_write_tool():
    context = _make_context()
    req = PolicyRequest(
        event_type="PreToolUse",
        tool_name="Write",
        tool_input={"file_path": "/project/foo.py", "content": "pass"},
        context=context,
        cwd="/project/.worktrees/test",
    )
    decision = check(req)
    assert decision is None


# ---------------------------------------------------------------------------
# Deny reason text quality
# ---------------------------------------------------------------------------


def test_deny_reason_includes_remediation_cli():
    req = _make_agent_request(subagent_type="implementer", prompt="Do work")
    decision = check(req)
    assert decision is not None
    assert "cc-policy dispatch agent-prompt" in decision.reason
    assert "--workflow-id" in decision.reason
    assert "--stage-id" in decision.reason


def test_deny_reason_includes_subagent_type():
    req = _make_agent_request(subagent_type="guardian", prompt="Land")
    decision = check(req)
    assert decision is not None
    assert "guardian" in decision.reason


# ---------------------------------------------------------------------------
# Policy name invariant
# ---------------------------------------------------------------------------


def test_policy_name_is_agent_contract_required():
    req = _make_agent_request(subagent_type="reviewer", prompt="Review")
    decision = check(req)
    assert decision is not None
    assert decision.policy_name == "agent_contract_required"


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------


def test_contract_block_must_be_first_line():
    """Contract block on line 2 should NOT satisfy the requirement."""
    prompt = "Some preamble text\n" + _contract_block("implementer") + "\nDo work"
    req = _make_agent_request(subagent_type="implementer", prompt=prompt)
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


def test_empty_prompt_dispatch_significant_denied():
    req = _make_agent_request(subagent_type="implementer", prompt="")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


def test_unknown_subagent_type_is_lightweight():
    """Unknown subagent types not in DISPATCH_SIGNIFICANT are treated as lightweight."""
    req = _make_agent_request(subagent_type="custom-tool", prompt="Do something")
    decision = check(req)
    assert decision is None


def test_whitespace_subagent_type_is_lightweight():
    """Whitespace-only subagent_type should be treated as empty (lightweight)."""
    req = _make_agent_request(subagent_type="   ", prompt="Do something")
    decision = check(req)
    assert decision is None


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------


def test_register_adds_to_registry():
    from runtime.core.policies.agent_contract_required import register
    from runtime.core.policy_engine import PolicyRegistry

    reg = PolicyRegistry()
    register(reg)
    policies = reg.list_policies()
    assert len(policies) == 1
    p = policies[0]
    assert p.name == "agent_contract_required"
    assert p.priority == 150
    assert "PreToolUse" in p.event_types
    assert p.enabled is True


# ---------------------------------------------------------------------------
# Set membership invariants
# ---------------------------------------------------------------------------


def test_dispatch_significant_set_contents():
    expected = {"planner", "implementer", "guardian", "reviewer", "Plan"}
    assert DISPATCH_SIGNIFICANT == expected


def test_lightweight_set_contents():
    expected = {"Explore", "general-purpose", "statusline-setup", ""}
    assert LIGHTWEIGHT == expected


def test_no_overlap_between_sets():
    assert DISPATCH_SIGNIFICANT.isdisjoint(LIGHTWEIGHT)
