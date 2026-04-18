"""Unit tests for agent_contract_required policy.

Exercises contract enforcement for dispatch-significant Agent/Task tool
invocations (DEC-POLICY-AGENT-CONTRACT-001). Dispatch-significant subagent
types (planner, implementer, guardian, reviewer, Plan) are denied when their
prompt does not start with CLAUDEX_CONTRACT_BLOCK: on line 1. Non-canonical
types (Explore, general-purpose, statusline-setup, empty, missing, and any
unknown value) pass through unaffected.

Classification is now resolved at call time via
authority_registry.canonical_dispatch_subagent_type — not via module-level
frozen sets. This is the A6 soak-parity implementation of the A1 pattern
(DEC-CLAUDEX-AGENT-CONTRACT-REQUIRED-AUTHORITY-SOAK-001).

@decision DEC-POLICY-AGENT-CONTRACT-TEST-001
@title Unit tests for agent_contract_required policy
@status accepted
@rationale Verify all deny branches (dispatch-significant without contract),
  all allow branches (dispatch-significant with contract, non-canonical types,
  non-Agent tools), deny reason text includes remediation CLI, and policy_name
  is correct. PolicyRequest objects are constructed by hand — no DB I/O.
  Single-authority classification via authority_registry enforced by
  TestSingleAuthorityClassification.
"""

from __future__ import annotations

import sys
from pathlib import Path

# Ensure repo root is importable.
_ROOT = Path(__file__).resolve().parent.parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

import runtime.core.policies.agent_contract_required as _acr_mod
from runtime.core.authority_registry import capabilities_for
from runtime.core.policies.agent_contract_required import check
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
    """Unknown subagent types (not canonical per authority_registry) are treated as pass-through."""
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
# Single-authority classification invariants (A6 soak-parity)
# ---------------------------------------------------------------------------


class TestSingleAuthorityClassification:
    """Verify classification is resolved via authority_registry at call time.

    These tests replace the three set-membership invariants that enforced
    module-level DISPATCH_SIGNIFICANT / LIGHTWEIGHT frozensets. The policy
    no longer owns a local copy of the canonical seat list — it delegates
    to authority_registry.canonical_dispatch_subagent_type exclusively.
    (DEC-CLAUDEX-AGENT-CONTRACT-REQUIRED-AUTHORITY-SOAK-001)
    """

    def test_no_module_level_classification_frozensets(self):
        """The module must NOT export DISPATCH_SIGNIFICANT or LIGHTWEIGHT."""
        assert not hasattr(_acr_mod, "DISPATCH_SIGNIFICANT"), (
            "DISPATCH_SIGNIFICANT frozenset must be removed; "
            "use authority_registry at call time"
        )
        assert not hasattr(_acr_mod, "LIGHTWEIGHT"), (
            "LIGHTWEIGHT frozenset must be removed; "
            "use authority_registry at call time"
        )

    def test_denies_every_canonical_dispatch_seat_without_contract(self):
        """All canonical seats must be denied when no contract is provided."""
        canonical_seats = ["planner", "implementer", "guardian", "reviewer", "Plan"]
        for seat in canonical_seats:
            req = _make_agent_request(subagent_type=seat, prompt="Do some work")
            decision = check(req)
            assert decision is not None, (
                f"Expected deny for canonical seat {seat!r} but got None"
            )
            assert decision.action == "deny", (
                f"Expected action=deny for {seat!r}, got {decision.action!r}"
            )
            assert decision.policy_name == "agent_contract_required", (
                f"Wrong policy_name for {seat!r}: {decision.policy_name!r}"
            )

    def test_allows_every_non_canonical_subagent_type_without_contract(self):
        """All non-canonical types must pass through (return None) without contract."""
        non_canonical = ["Explore", "general-purpose", "statusline-setup", "", "custom-tool"]
        for seat in non_canonical:
            req = _make_agent_request(subagent_type=seat, prompt="Some work")
            decision = check(req)
            assert decision is None, (
                f"Expected None (pass-through) for non-canonical seat {seat!r} "
                f"but got decision.action={getattr(decision, 'action', None)!r}"
            )

    def test_classification_tracks_authority_registry_monkeypatch(self, monkeypatch):
        """Classification must change when authority_registry is patched.

        CRITICAL: we patch the module-local alias (the ``authority_registry``
        name inside agent_contract_required), not the authority module directly.
        This proves the policy calls through the alias at call time rather than
        a cached copy.
        """
        original_fn = _acr_mod.authority_registry.canonical_dispatch_subagent_type

        # "newseat" → canonical; "planner" → non-canonical (inverted for test)
        def patched(subagent_type: str):
            if subagent_type == "newseat":
                return "newseat"
            if subagent_type == "planner":
                return None
            return original_fn(subagent_type)

        monkeypatch.setattr(
            _acr_mod.authority_registry,
            "canonical_dispatch_subagent_type",
            patched,
        )

        # "newseat" is now canonical — must be denied without contract
        req_new = _make_agent_request(subagent_type="newseat", prompt="New seat work")
        decision_new = check(req_new)
        assert decision_new is not None, "newseat should be denied after monkeypatch"
        assert decision_new.action == "deny"

        # "planner" is now non-canonical — must pass through
        req_planner = _make_agent_request(subagent_type="planner", prompt="Plan it")
        decision_planner = check(req_planner)
        assert decision_planner is None, (
            "planner should pass through when patched to non-canonical"
        )

    def test_canonical_matching_contract_allowed(self):
        """Contract-bearing prompt with stage=planner and subagent=planner must pass."""
        prompt = f"{_contract_block('planner')}\n\nBuild the plan."
        req = _make_agent_request(subagent_type="planner", prompt=prompt)
        decision = check(req)
        assert decision is None, (
            f"Expected None for valid planner contract but got {decision!r}"
        )

    def test_stage_subagent_type_mismatch_denied(self):
        """Contract-bearing prompt where stage=reviewer but subagent=general-purpose must deny."""
        prompt = f"{_contract_block('reviewer')}\n\nReview the changes."
        req = _make_agent_request(subagent_type="general-purpose", prompt=prompt)
        decision = check(req)
        assert decision is not None, (
            "Expected deny for stage/subagent_type mismatch"
        )
        assert decision.action == "deny"
        assert "stage_id='reviewer'" in decision.reason


# ---------------------------------------------------------------------------
# A8: Six-field contract shape authenticity (DEC-CLAUDEX-AGENT-CONTRACT-AUTHENTICITY-A8-001)
# ---------------------------------------------------------------------------


import json as _json


def _make_block(**overrides) -> str:
    """Return a CLAUDEX_CONTRACT_BLOCK: line with all six fields, overrides applied.

    Pass field=None to remove the key entirely.  Pass field="value" to set it.
    Used to construct forged / partial contracts for shape-validation tests.
    """
    base = {
        "workflow_id": "test-wf",
        "stage_id": "implementer",
        "goal_id": "g1",
        "work_item_id": "w1",
        "decision_scope": "kernel",
        "generated_at": 1_700_000_000,
    }
    for k, v in overrides.items():
        if v is None:
            base.pop(k, None)
        else:
            base[k] = v
    return "CLAUDEX_CONTRACT_BLOCK:" + _json.dumps(base)


class TestContractShapeAuthenticity:
    """A8: strict six-field shape validation for contract-bearing launches.

    Each of the 7 new deny reason-code substrings must fire on its specific
    malformed / missing field.  A fully valid contract must pass shape checks.

    DEC-CLAUDEX-AGENT-CONTRACT-AUTHENTICITY-A8-001
    """

    # ---- positive: valid full contract passes ----

    def test_valid_full_contract_passes(self):
        """All six fields well-formed → no deny from shape validation."""
        prompt = f"{_make_block()}\n\nDo work."
        req = _make_agent_request(subagent_type="implementer", prompt=prompt)
        decision = check(req)
        assert decision is None, f"Full valid contract must pass; got {decision!r}"

    # ---- contract_block_missing_workflow_id ----

    def test_missing_workflow_id_denied(self):
        prompt = f"{_make_block(workflow_id=None)}\n\nDo work."
        req = _make_agent_request(subagent_type="implementer", prompt=prompt)
        decision = check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert "contract_block_missing_workflow_id" in decision.reason
        assert decision.policy_name == "agent_contract_required"

    # ---- contract_block_empty_workflow_id ----

    def test_empty_workflow_id_denied(self):
        prompt = f"{_make_block(workflow_id='')}\n\nDo work."
        req = _make_agent_request(subagent_type="implementer", prompt=prompt)
        decision = check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert "contract_block_empty_workflow_id" in decision.reason

    def test_whitespace_only_workflow_id_denied(self):
        prompt = f"{_make_block(workflow_id='   ')}\n\nDo work."
        req = _make_agent_request(subagent_type="implementer", prompt=prompt)
        decision = check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert "contract_block_empty_workflow_id" in decision.reason

    # ---- contract_block_missing_goal_id ----

    def test_missing_goal_id_denied(self):
        prompt = f"{_make_block(goal_id=None)}\n\nDo work."
        req = _make_agent_request(subagent_type="implementer", prompt=prompt)
        decision = check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert "contract_block_missing_goal_id" in decision.reason

    def test_empty_goal_id_denied(self):
        prompt = f"{_make_block(goal_id='')}\n\nDo work."
        req = _make_agent_request(subagent_type="implementer", prompt=prompt)
        decision = check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert "contract_block_missing_goal_id" in decision.reason

    def test_null_goal_id_denied(self):
        """JSON null goal_id must be denied (not str)."""
        base = {
            "workflow_id": "wf", "stage_id": "implementer",
            "goal_id": None, "work_item_id": "w1",
            "decision_scope": "kernel", "generated_at": 1_700_000_000,
        }
        prompt = "CLAUDEX_CONTRACT_BLOCK:" + _json.dumps(base) + "\nDo work."
        req = _make_agent_request(subagent_type="implementer", prompt=prompt)
        decision = check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert "contract_block_missing_goal_id" in decision.reason

    # ---- contract_block_missing_work_item_id ----

    def test_missing_work_item_id_denied(self):
        prompt = f"{_make_block(work_item_id=None)}\n\nDo work."
        req = _make_agent_request(subagent_type="implementer", prompt=prompt)
        decision = check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert "contract_block_missing_work_item_id" in decision.reason

    def test_empty_work_item_id_denied(self):
        prompt = f"{_make_block(work_item_id='')}\n\nDo work."
        req = _make_agent_request(subagent_type="implementer", prompt=prompt)
        decision = check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert "contract_block_missing_work_item_id" in decision.reason

    # ---- contract_block_missing_decision_scope ----

    def test_missing_decision_scope_denied(self):
        prompt = f"{_make_block(decision_scope=None)}\n\nDo work."
        req = _make_agent_request(subagent_type="implementer", prompt=prompt)
        decision = check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert "contract_block_missing_decision_scope" in decision.reason

    def test_empty_decision_scope_denied(self):
        prompt = f"{_make_block(decision_scope='')}\n\nDo work."
        req = _make_agent_request(subagent_type="implementer", prompt=prompt)
        decision = check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert "contract_block_missing_decision_scope" in decision.reason

    # ---- contract_block_missing_generated_at ----

    def test_missing_generated_at_denied(self):
        prompt = f"{_make_block(generated_at=None)}\n\nDo work."
        req = _make_agent_request(subagent_type="implementer", prompt=prompt)
        decision = check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert "contract_block_missing_generated_at" in decision.reason

    # ---- contract_block_invalid_generated_at ----

    def test_zero_generated_at_denied(self):
        prompt = f"{_make_block(generated_at=0)}\n\nDo work."
        req = _make_agent_request(subagent_type="implementer", prompt=prompt)
        decision = check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert "contract_block_invalid_generated_at" in decision.reason

    def test_negative_generated_at_denied(self):
        prompt = f"{_make_block(generated_at=-1)}\n\nDo work."
        req = _make_agent_request(subagent_type="implementer", prompt=prompt)
        decision = check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert "contract_block_invalid_generated_at" in decision.reason

    def test_string_generated_at_denied(self):
        """String generated_at (not int-coercible) must be denied."""
        prompt = f"{_make_block(generated_at='not-a-number')}\n\nDo work."
        req = _make_agent_request(subagent_type="implementer", prompt=prompt)
        decision = check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert "contract_block_invalid_generated_at" in decision.reason

    def test_bool_generated_at_denied(self):
        """Boolean generated_at must be denied (booleans excluded from int coercion)."""
        base = {
            "workflow_id": "wf", "stage_id": "implementer",
            "goal_id": "g1", "work_item_id": "w1",
            "decision_scope": "kernel", "generated_at": True,
        }
        prompt = "CLAUDEX_CONTRACT_BLOCK:" + _json.dumps(base) + "\nDo work."
        req = _make_agent_request(subagent_type="implementer", prompt=prompt)
        decision = check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert "contract_block_invalid_generated_at" in decision.reason

    def test_null_generated_at_denied(self):
        """JSON null generated_at must be denied."""
        base = {
            "workflow_id": "wf", "stage_id": "implementer",
            "goal_id": "g1", "work_item_id": "w1",
            "decision_scope": "kernel", "generated_at": None,
        }
        prompt = "CLAUDEX_CONTRACT_BLOCK:" + _json.dumps(base) + "\nDo work."
        req = _make_agent_request(subagent_type="implementer", prompt=prompt)
        decision = check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert "contract_block_invalid_generated_at" in decision.reason

    def test_int_coercible_string_generated_at_accepted(self):
        """String generated_at that is int-coercible and positive is accepted.

        The spec says "int or int-coercible from str, >0" — so "1700000000"
        must pass shape validation and proceed to stage/subagent_type checks.
        """
        prompt = f"{_make_block(generated_at='1700000000')}\n\nDo work."
        req = _make_agent_request(subagent_type="implementer", prompt=prompt)
        decision = check(req)
        # Should not be denied by shape; may be None (allow) since all other checks pass
        if decision is not None:
            assert "contract_block_invalid_generated_at" not in decision.reason, (
                f"Coercible string generated_at should not produce invalid_generated_at deny; got: {decision.reason}"
            )

    # ---- shape-check ordering: workflow_id before goal_id before work_item_id ----

    def test_shape_order_workflow_id_before_goal_id(self):
        """workflow_id missing fires before goal_id missing (check ordering invariant)."""
        prompt = f"{_make_block(workflow_id=None, goal_id=None)}\n\nDo work."
        req = _make_agent_request(subagent_type="implementer", prompt=prompt)
        decision = check(req)
        assert decision is not None
        assert "contract_block_missing_workflow_id" in decision.reason

    def test_shape_order_goal_id_before_work_item_id(self):
        """goal_id missing fires before work_item_id missing."""
        prompt = f"{_make_block(goal_id=None, work_item_id=None)}\n\nDo work."
        req = _make_agent_request(subagent_type="implementer", prompt=prompt)
        decision = check(req)
        assert decision is not None
        assert "contract_block_missing_goal_id" in decision.reason

    # ---- policy_name invariant ----

    def test_policy_name_agent_contract_required_on_shape_deny(self):
        prompt = f"{_make_block(workflow_id=None)}\n\nDo work."
        req = _make_agent_request(subagent_type="implementer", prompt=prompt)
        decision = check(req)
        assert decision is not None
        assert decision.policy_name == "agent_contract_required"
