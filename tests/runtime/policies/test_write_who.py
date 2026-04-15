"""Tests for write_who policy.

@decision DEC-PE-W2-TEST-002
Title: write_who tests use hand-crafted PolicyContext to exercise role checks
Status: accepted
Rationale: write_who is a pure function of context.actor_role and the file
  path classification. No subprocess calls — all tests use in-memory fixtures.
  This is the correct test pattern for policies with no external I/O.

Production sequence:
  Claude Write/Edit -> pre-write.sh -> cc-policy evaluate ->
  PolicyRegistry.evaluate() -> write_who(request) -> deny if not implementer.
"""

from __future__ import annotations

from runtime.core.authority_registry import capabilities_for
from runtime.core.policies.write_who import write_who
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
    assert write_who(req) is None


def test_meta_infra_skipped():
    """Files under .claude/ are exempt from WHO enforcement."""
    assert write_who(_req("/proj/.claude/hooks/myhook.sh")) is None


def test_non_source_file_skipped():
    """Markdown, JSON, YAML — no opinion from write_who."""
    assert write_who(_req("/proj/README.md")) is None
    assert write_who(_req("/proj/config.json")) is None
    assert write_who(_req("/proj/config.yaml")) is None


def test_skippable_path_skipped():
    assert write_who(_req("/proj/vendor/util.py")) is None
    assert write_who(_req("/proj/node_modules/index.js")) is None


# ---------------------------------------------------------------------------
# Allow case — implementer role
# ---------------------------------------------------------------------------


def test_implementer_allowed():
    """implementer role must pass (return None = no opinion = allow)."""
    result = write_who(_req("/proj/app.py", role="implementer"))
    assert result is None


# ---------------------------------------------------------------------------
# Deny cases — all non-implementer roles
# ---------------------------------------------------------------------------


def test_empty_role_denied():
    """No active agent (orchestrator) must be denied."""
    result = write_who(_req("/proj/app.py", role=""))
    assert result is not None
    assert result.action == "deny"
    assert "orchestrator" in result.reason
    assert result.policy_name == "write_who"


def test_planner_role_denied():
    result = write_who(_req("/proj/app.py", role="planner"))
    assert result is not None
    assert result.action == "deny"
    assert "planner" in result.reason


def test_guardian_role_denied():
    result = write_who(_req("/proj/service.go", role="guardian"))
    assert result is not None
    assert result.action == "deny"
    assert "guardian" in result.reason


def test_tester_role_denied():
    result = write_who(_req("/proj/main.ts", role="tester"))
    assert result is not None
    assert result.action == "deny"
    assert "tester" in result.reason


def test_plan_role_denied():
    """'Plan' (capitalized) is a planner alias — must also be denied."""
    result = write_who(_req("/proj/app.py", role="Plan"))
    assert result is not None
    assert result.action == "deny"


# ---------------------------------------------------------------------------
# Compound integration — WHO check in registry context
# ---------------------------------------------------------------------------


def test_registry_write_who_denies_orchestrator_for_source():
    """Integration: full registry evaluate() path for orchestrator writing source.

    Exercises: PolicyRequest construction -> registry dispatch -> write_who decision.
    """
    from runtime.core.policies.write_who import write_who as ww
    from runtime.core.policy_engine import PolicyRegistry

    reg = PolicyRegistry()
    reg.register("write_who", ww, event_types=["Write", "Edit"], priority=200)

    req = _req("/proj/src/main.py", role="")
    decision = reg.evaluate(req)
    assert decision.action == "deny"
    assert decision.policy_name == "write_who"


def test_registry_write_who_passes_implementer():
    """Integration: implementer writing source passes write_who (no deny)."""
    from runtime.core.policies.write_who import write_who as ww
    from runtime.core.policy_engine import PolicyRegistry

    reg = PolicyRegistry()
    reg.register("write_who", ww, event_types=["Write", "Edit"], priority=200)

    req = _req("/proj/src/main.py", role="implementer")
    decision = reg.evaluate(req)
    # write_who returns None -> registry default allow
    assert decision.action == "allow"


# ---------------------------------------------------------------------------
# Capability-gate invariant tests (Phase 3)
# ---------------------------------------------------------------------------


def test_capability_gate_not_role_string():
    """Capability presence — not the role string — controls authorization.

    A context with role="unknown_role" but CAN_WRITE_SOURCE injected should
    pass. This proves the policy uses context.capabilities, not actor_role.
    """
    import dataclasses
    from runtime.core.authority_registry import CAN_WRITE_SOURCE

    ctx = dataclasses.replace(
        _make_context(actor_role="unknown_role"),
        capabilities=frozenset({CAN_WRITE_SOURCE}),
    )
    req = PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={"file_path": "/proj/app.py"},
        context=ctx,
        cwd="/proj",
    )
    assert write_who(req) is None


def test_implementer_without_capability_is_denied():
    """Implementer role string alone is not sufficient — capability must be present.

    Simulates a context where the role name is "implementer" but capabilities
    is empty (e.g., build_context() returned an unknown/unmapped role).
    """
    import dataclasses

    ctx = dataclasses.replace(
        _make_context(actor_role="implementer"),
        capabilities=frozenset(),
    )
    req = PolicyRequest(
        event_type="Write",
        tool_name="Write",
        tool_input={"file_path": "/proj/app.py"},
        context=ctx,
        cwd="/proj",
    )
    result = write_who(req)
    assert result is not None
    assert result.action == "deny"
