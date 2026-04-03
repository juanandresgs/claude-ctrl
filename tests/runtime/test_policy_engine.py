"""Unit tests for runtime.core.policy_engine.

Covers PolicyRegistry evaluation semantics, context building, and the
default registry (empty in W1). Tests run against an in-memory SQLite
DB so they never touch user state.

@decision DEC-PE-002
Title: PolicyRegistry evaluation contract tested in isolation
Status: accepted
Rationale: The registry is pure Python with no I/O — tests create registries
  directly and inject policy functions to verify the exact semantics
  (deny short-circuits, feedback continues, priority ordering, event filtering).
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from runtime.core.db import connect_memory
from runtime.core.policy_engine import (
    PolicyContext,
    PolicyDecision,
    PolicyRegistry,
    PolicyRequest,
    build_context,
    default_registry,
)
from runtime.schemas import ensure_schema

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


def _make_request(event_type: str = "PreToolUse", tool_name: str = "Write") -> PolicyRequest:
    return PolicyRequest(
        event_type=event_type,
        tool_name=tool_name,
        tool_input={},
        context=PolicyContext(
            actor_role="implementer",
            actor_id="agent-test",
            workflow_id="test-workflow",
            worktree_path="/tmp/test",
            branch="feature/test",
            project_root="/tmp/test",
            is_meta_repo=False,
            lease=None,
            scope=None,
            eval_state=None,
            test_state=None,
            binding=None,
            dispatch_phase=None,
        ),
        cwd="/tmp/test",
    )


# ---------------------------------------------------------------------------
# PolicyRegistry: register + list
# ---------------------------------------------------------------------------


def test_registry_register_and_list():
    reg = PolicyRegistry()
    reg.register("my-policy", lambda r: None, event_types=["PreToolUse"], priority=10)
    policies = reg.list_policies()
    assert len(policies) == 1
    assert policies[0].name == "my-policy"
    assert policies[0].priority == 10
    assert policies[0].enabled is True
    assert "PreToolUse" in policies[0].event_types


def test_registry_list_empty():
    reg = PolicyRegistry()
    assert reg.list_policies() == []


# ---------------------------------------------------------------------------
# evaluate: no policies → default allow
# ---------------------------------------------------------------------------


def test_evaluate_no_policies_returns_allow():
    reg = PolicyRegistry()
    req = _make_request()
    decision = reg.evaluate(req)
    assert decision.action == "allow"
    assert decision.policy_name == "default"


# ---------------------------------------------------------------------------
# evaluate: single deny policy
# ---------------------------------------------------------------------------


def test_evaluate_single_deny():
    reg = PolicyRegistry()

    def deny_all(request: PolicyRequest) -> PolicyDecision:
        return PolicyDecision(action="deny", reason="not allowed", policy_name="deny-all")

    reg.register("deny-all", deny_all, event_types=["PreToolUse"], priority=10)
    req = _make_request()
    decision = reg.evaluate(req)
    assert decision.action == "deny"
    assert decision.policy_name == "deny-all"
    assert decision.reason == "not allowed"


# ---------------------------------------------------------------------------
# evaluate: first-deny-wins (multiple policies)
# ---------------------------------------------------------------------------


def test_evaluate_first_deny_wins():
    reg = PolicyRegistry()

    def first_deny(request: PolicyRequest) -> PolicyDecision:
        return PolicyDecision(action="deny", reason="first deny", policy_name="first")

    def second_deny(request: PolicyRequest) -> PolicyDecision:
        return PolicyDecision(action="deny", reason="second deny", policy_name="second")

    # Lower priority number = runs first
    reg.register("first", first_deny, event_types=["PreToolUse"], priority=1)
    reg.register("second", second_deny, event_types=["PreToolUse"], priority=2)

    req = _make_request()
    decision = reg.evaluate(req)
    assert decision.action == "deny"
    assert decision.policy_name == "first"
    assert decision.reason == "first deny"


# ---------------------------------------------------------------------------
# evaluate: filters by event_type
# ---------------------------------------------------------------------------


def test_evaluate_filters_by_event_type():
    reg = PolicyRegistry()

    def deny_all(request: PolicyRequest) -> PolicyDecision:
        return PolicyDecision(action="deny", reason="denied", policy_name="deny-all")

    # Only registered for SubagentStop, not PreToolUse
    reg.register("deny-all", deny_all, event_types=["SubagentStop"], priority=10)

    req = _make_request(event_type="PreToolUse")
    decision = reg.evaluate(req)
    # Policy is skipped because event_type doesn't match
    assert decision.action == "allow"


# ---------------------------------------------------------------------------
# evaluate: skips disabled policies
# ---------------------------------------------------------------------------


def test_evaluate_skips_disabled_policy():
    reg = PolicyRegistry()

    def deny_all(request: PolicyRequest) -> PolicyDecision:
        return PolicyDecision(action="deny", reason="denied", policy_name="deny-all")

    reg.register("deny-all", deny_all, event_types=["PreToolUse"], priority=10, enabled=False)
    req = _make_request()
    decision = reg.evaluate(req)
    assert decision.action == "allow"


# ---------------------------------------------------------------------------
# evaluate: None return = no opinion
# ---------------------------------------------------------------------------


def test_evaluate_none_return_is_no_opinion():
    reg = PolicyRegistry()

    def no_opinion(request: PolicyRequest):
        return None

    reg.register("no-opinion", no_opinion, event_types=["PreToolUse"], priority=10)
    req = _make_request()
    decision = reg.evaluate(req)
    assert decision.action == "allow"


# ---------------------------------------------------------------------------
# evaluate: feedback continues (last feedback wins)
# ---------------------------------------------------------------------------


def test_evaluate_feedback_continues():
    reg = PolicyRegistry()
    call_order = []

    def first_feedback(request: PolicyRequest) -> PolicyDecision:
        call_order.append("first")
        return PolicyDecision(action="feedback", reason="first hint", policy_name="first")

    def second_feedback(request: PolicyRequest) -> PolicyDecision:
        call_order.append("second")
        return PolicyDecision(action="feedback", reason="second hint", policy_name="second")

    reg.register("first", first_feedback, event_types=["PreToolUse"], priority=1)
    reg.register("second", second_feedback, event_types=["PreToolUse"], priority=2)

    req = _make_request()
    decision = reg.evaluate(req)
    # Both ran (feedback doesn't short-circuit)
    assert call_order == ["first", "second"]
    # Last feedback wins
    assert decision.action == "feedback"
    assert decision.policy_name == "second"


# ---------------------------------------------------------------------------
# evaluate: deny after feedback stops evaluation
# ---------------------------------------------------------------------------


def test_evaluate_deny_after_feedback_stops():
    reg = PolicyRegistry()
    call_order = []

    def feedback_policy(request: PolicyRequest) -> PolicyDecision:
        call_order.append("feedback")
        return PolicyDecision(action="feedback", reason="hint", policy_name="feedback")

    def deny_policy(request: PolicyRequest) -> PolicyDecision:
        call_order.append("deny")
        return PolicyDecision(action="deny", reason="blocked", policy_name="deny")

    def should_not_run(request: PolicyRequest) -> PolicyDecision:
        call_order.append("after-deny")
        return None

    reg.register("feedback", feedback_policy, event_types=["PreToolUse"], priority=1)
    reg.register("deny", deny_policy, event_types=["PreToolUse"], priority=2)
    reg.register("after", should_not_run, event_types=["PreToolUse"], priority=3)

    req = _make_request()
    decision = reg.evaluate(req)
    # deny short-circuits; after-deny never runs
    assert "after-deny" not in call_order
    assert decision.action == "deny"


# ---------------------------------------------------------------------------
# explain: runs ALL matching policies (no short-circuit)
# ---------------------------------------------------------------------------


def test_explain_runs_all_policies():
    reg = PolicyRegistry()
    call_order = []

    def deny_first(request: PolicyRequest) -> PolicyDecision:
        call_order.append("deny-first")
        return PolicyDecision(action="deny", reason="first", policy_name="deny-first")

    def after_deny(request: PolicyRequest) -> PolicyDecision:
        call_order.append("after-deny")
        return PolicyDecision(action="deny", reason="second", policy_name="after-deny")

    reg.register("deny-first", deny_first, event_types=["PreToolUse"], priority=1)
    reg.register("after-deny", after_deny, event_types=["PreToolUse"], priority=2)

    req = _make_request()
    evals = reg.explain(req)
    # explain must run both
    assert "deny-first" in call_order
    assert "after-deny" in call_order
    assert len(evals) == 2


def test_explain_returns_policy_evaluations():
    reg = PolicyRegistry()

    def allow_policy(request: PolicyRequest) -> PolicyDecision:
        return PolicyDecision(action="allow", reason="fine", policy_name="allow-all")

    def no_opinion_policy(request: PolicyRequest):
        return None

    reg.register("allow-all", allow_policy, event_types=["PreToolUse"], priority=1)
    reg.register("no-op", no_opinion_policy, event_types=["PreToolUse"], priority=2)

    req = _make_request()
    evals = reg.explain(req)
    names = {e.policy_name for e in evals}
    assert "allow-all" in names
    assert "no-op" in names

    # no-opinion should be result="no_opinion"
    no_op_eval = next(e for e in evals if e.policy_name == "no-op")
    assert no_op_eval.result == "no_opinion"


# ---------------------------------------------------------------------------
# Priority ordering: lower number runs first
# ---------------------------------------------------------------------------


def test_priority_ordering():
    reg = PolicyRegistry()
    call_order = []

    def p10(request: PolicyRequest):
        call_order.append(10)

    def p1(request: PolicyRequest):
        call_order.append(1)

    def p5(request: PolicyRequest):
        call_order.append(5)

    reg.register("p10", p10, event_types=["PreToolUse"], priority=10)
    reg.register("p1", p1, event_types=["PreToolUse"], priority=1)
    reg.register("p5", p5, event_types=["PreToolUse"], priority=5)

    req = _make_request()
    reg.evaluate(req)
    assert call_order == [1, 5, 10]


# ---------------------------------------------------------------------------
# build_context: constructs PolicyContext from SQLite
# ---------------------------------------------------------------------------


def test_build_context_basic(conn, tmp_path):
    ctx = build_context(conn, cwd=str(tmp_path), actor_role="implementer", actor_id="agent-1")
    assert isinstance(ctx, PolicyContext)
    assert ctx.actor_role == "implementer"
    assert ctx.actor_id == "agent-1"
    # No lease, scope, etc. in empty DB → all None
    assert ctx.lease is None
    assert ctx.scope is None
    assert ctx.eval_state is None
    assert ctx.test_state is None
    assert ctx.binding is None


def test_build_context_has_project_root(conn, tmp_path):
    ctx = build_context(conn, cwd=str(tmp_path))
    # project_root is populated (may be tmp_path or git root)
    assert isinstance(ctx.project_root, str)
    assert len(ctx.project_root) > 0


# ---------------------------------------------------------------------------
# default_registry: empty in W1, fail-closed on register_all errors
# ---------------------------------------------------------------------------


def test_default_registry_is_registry():
    reg = default_registry()
    assert isinstance(reg, PolicyRegistry)


def test_default_registry_empty_in_w1():
    """W1: no policies registered. W2/W3 will add them."""
    reg = default_registry()
    policies = reg.list_policies()
    assert policies == []


def test_default_registry_fail_closed_on_register_all_error(monkeypatch):
    """If register_all raises, default_registry() must propagate — not swallow.

    This guards against the fail-open regression: an ImportError or exception
    in a policy module must crash the CLI, not silently return an empty registry
    that allows everything. See DEC-PE-008.
    """
    import runtime.core.policies as _policies_pkg

    def _bad_register_all(registry):
        raise ImportError("synthetic: policy module has a broken import")

    monkeypatch.setattr(_policies_pkg, "register_all", _bad_register_all)

    with pytest.raises(ImportError, match="synthetic"):
        default_registry()


# ---------------------------------------------------------------------------
# build_context: dispatch_phase is workflow-scoped
# ---------------------------------------------------------------------------


def test_dispatch_phase_is_workflow_scoped(conn, tmp_path):
    """dispatch_phase must come from the correct workflow, not a concurrent one.

    Two workflows each have a completion record. build_context() for workflow A
    must read workflow A's phase, not workflow B's more-recent record — even
    though workflow B's record has a more-recent created_at timestamp.

    This is the compound-interaction test: it exercises the real production
    sequence — two concurrent workflows writing completion records, then
    context resolution for each — crossing the boundary between the
    completion_records table and build_context()'s state resolution logic.

    build_context() resolves workflow_id from the active lease; we insert
    leases with distinct workflow_ids and distinct worktree_paths so the
    function can find each via the worktree_path fallback.
    """
    import time

    now = int(time.time())
    tmp_a = tmp_path / "wt-a"
    tmp_b = tmp_path / "wt-b"
    tmp_a.mkdir()
    tmp_b.mkdir()

    # --- Leases: one per workflow, each with a distinct worktree_path ---
    conn.execute(
        """INSERT INTO dispatch_leases
           (lease_id, agent_id, role, workflow_id, worktree_path, branch,
            status, issued_at, expires_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            "lease-a",
            "agent-a",
            "guardian",
            "workflow-A",
            str(tmp_a),
            "feature/a",
            "active",
            now,
            now + 3600,
        ),
    )
    conn.execute(
        """INSERT INTO dispatch_leases
           (lease_id, agent_id, role, workflow_id, worktree_path, branch,
            status, issued_at, expires_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            "lease-b",
            "agent-b",
            "implementer",
            "workflow-B",
            str(tmp_b),
            "feature/b",
            "active",
            now,
            now + 3600,
        ),
    )

    # --- Completion records: B is newer overall, but scoped to its workflow ---
    conn.execute(
        """INSERT INTO completion_records
           (lease_id, workflow_id, role, verdict, valid, payload_json, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)""",
        ("lease-a", "workflow-A", "tester", "ready_for_guardian", 1, "{}", now - 10),
    )
    conn.execute(
        """INSERT INTO completion_records
           (lease_id, workflow_id, role, verdict, valid, payload_json, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)""",
        ("lease-b", "workflow-B", "implementer", "complete", 1, "{}", now),
    )
    conn.commit()

    # Context for workflow A: must get A's record (tester:ready_for_guardian),
    # NOT workflow B's newer record (implementer:complete).
    ctx_a = build_context(
        conn,
        cwd=str(tmp_a),
        actor_role="guardian",
        actor_id="agent-a",
    )
    assert ctx_a.dispatch_phase == "tester:ready_for_guardian", (
        f"Expected workflow-A's phase but got: {ctx_a.dispatch_phase}"
    )

    # Context for workflow B: must get B's own record.
    ctx_b = build_context(
        conn,
        cwd=str(tmp_b),
        actor_role="implementer",
        actor_id="agent-b",
    )
    assert ctx_b.dispatch_phase == "implementer:complete", (
        f"Expected workflow-B's phase but got: {ctx_b.dispatch_phase}"
    )


def test_dispatch_phase_none_when_workflow_has_no_completions(conn, tmp_path):
    """dispatch_phase is None when the resolved workflow has no completion records.

    The workflow_id resolves from the active lease, but no completion rows exist
    for that workflow. The result must be None — not a record from a different
    workflow. This guards against the old global query that would return any
    record in the table regardless of workflow.
    """
    import time

    now = int(time.time())

    # Insert a lease that gives us a known workflow_id
    conn.execute(
        """INSERT INTO dispatch_leases
           (lease_id, agent_id, role, workflow_id, worktree_path, branch,
            status, issued_at, expires_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            "lease-new",
            "agent-new",
            "implementer",
            "workflow-NEW",
            str(tmp_path),
            "feature/new",
            "active",
            now,
            now + 3600,
        ),
    )
    # Insert a completion record for a DIFFERENT workflow (the global trap)
    conn.execute(
        """INSERT INTO completion_records
           (lease_id, workflow_id, role, verdict, valid, payload_json, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)""",
        ("lease-other", "workflow-OTHER", "tester", "ready_for_guardian", 1, "{}", now),
    )
    conn.commit()

    ctx = build_context(
        conn,
        cwd=str(tmp_path),
        actor_role="implementer",
        actor_id="agent-new",
    )
    # workflow-NEW has no completions → dispatch_phase must be None,
    # not "tester:ready_for_guardian" from workflow-OTHER.
    assert ctx.dispatch_phase is None, (
        f"dispatch_phase leaked from a different workflow: {ctx.dispatch_phase}"
    )
