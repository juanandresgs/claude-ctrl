"""Unit tests for bash_worktree_creation policy.

Exercises denial of `git worktree add` from non-guardian contexts (W-GWT-3).
Production trigger: PreToolUse Bash hook — any command containing
`git worktree add` when actor_role is not guardian.

@decision DEC-GWT-3-POLICY-001
@title Unit tests for bash_worktree_creation policy
@status accepted
@rationale Guardian is the sole worktree lifecycle authority (DEC-GUARD-WT-002).
  Any non-guardian agent running `git worktree add` bypasses the provision
  sequence, creating a worktree without a Guardian lease, implementer lease,
  or workflow binding. The policy catches this at the PreToolUse boundary so
  the error is immediate rather than discovered later when check-guardian.sh
  can't find the lease.

  Test coverage:
  - Deny: non-guardian roles running `git worktree add`
  - Allow: guardian role running `git worktree add`
  - Allow: unrelated git commands (status, commit, worktree list, etc.)
  - Allow: empty command
  - Deny: various non-guardian roles (implementer, tester, planner, Bash)
  - Deny: `git -C /path worktree add ...` form (broadened grep pattern)
"""

from __future__ import annotations

from runtime.core.policies.bash_worktree_creation import check
from tests.runtime.policies.conftest import make_context, make_request


def _ctx(role: str):
    """Return a PolicyContext with the given actor_role and matching capabilities.

    Uses make_context(actor_role=role) so that capabilities are populated from
    authority_registry.capabilities_for(role) — matching production build_context().
    """
    return make_context(actor_role=role)


# ---------------------------------------------------------------------------
# Deny: non-guardian roles
# ---------------------------------------------------------------------------


def test_implementer_worktree_add_denied():
    """Implementer must not create worktrees — Guardian provisions them."""
    req = make_request(
        "git worktree add .worktrees/feature-foo -b feature/foo",
        context=_ctx("implementer"),
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert decision.policy_name == "bash_worktree_creation"


def test_tester_worktree_add_denied():
    """Tester must not create worktrees."""
    req = make_request(
        "git worktree add .worktrees/feature-bar -b feature/bar",
        context=_ctx("tester"),
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert decision.policy_name == "bash_worktree_creation"


def test_planner_worktree_add_denied():
    """Planner must not create worktrees."""
    req = make_request(
        "git worktree add .worktrees/feature-baz -b feature/baz",
        context=_ctx("planner"),
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


def test_bash_role_worktree_add_denied():
    """Lightweight Bash role must not create worktrees."""
    req = make_request(
        "git worktree add ../some-tree -b some-branch",
        context=_ctx("Bash"),
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


def test_unknown_role_worktree_add_denied():
    """Unknown / empty role must not create worktrees (fail-closed)."""
    req = make_request(
        "git worktree add .worktrees/feature-x -b feature/x",
        context=_ctx(""),
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


# ---------------------------------------------------------------------------
# Deny: git -C /path worktree add form (broadened pattern)
# ---------------------------------------------------------------------------


def test_git_c_path_worktree_add_denied_for_implementer():
    """`git -C /path worktree add` from implementer is denied."""
    req = make_request(
        "git -C /some/project worktree add .worktrees/feature-foo -b feature/foo",
        context=_ctx("implementer"),
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


# ---------------------------------------------------------------------------
# Deny: reason message references Guardian
# ---------------------------------------------------------------------------


def test_denial_reason_references_guardian():
    """Denial message must mention Guardian so the error is actionable."""
    req = make_request(
        "git worktree add .worktrees/feature-x -b feature/x",
        context=_ctx("implementer"),
    )
    decision = check(req)
    assert decision is not None
    assert "guardian" in decision.reason.lower() or "Guardian" in decision.reason


# ---------------------------------------------------------------------------
# Allow: guardian role
# ---------------------------------------------------------------------------


def test_guardian_provision_worktree_add_allowed():
    """guardian:provision is the sole worktree lifecycle authority — must be allowed."""
    req = make_request(
        "git worktree add .worktrees/feature-allowed -b feature/allowed",
        context=_ctx("guardian:provision"),
    )
    decision = check(req)
    assert decision is None


def test_guardian_provision_worktree_add_with_git_c_allowed():
    """`git -C /path worktree add` from guardian:provision is allowed."""
    req = make_request(
        "git -C /project worktree add .worktrees/feature-allowed -b feature/allowed",
        context=_ctx("guardian:provision"),
    )
    decision = check(req)
    assert decision is None


# ---------------------------------------------------------------------------
# Allow: non-worktree-add git commands
# Default make_request() uses conftest default context (actor_role=implementer).
# ---------------------------------------------------------------------------


def test_git_status_skipped():
    """git status is not a worktree add — must pass through."""
    req = make_request("git status")
    decision = check(req)
    assert decision is None


def test_git_commit_skipped():
    """git commit is not affected by this policy."""
    req = make_request("git commit -m 'fix'")
    decision = check(req)
    assert decision is None


def test_git_worktree_list_skipped():
    """git worktree list is read-only — must pass through."""
    req = make_request("git worktree list")
    decision = check(req)
    assert decision is None


def test_git_worktree_remove_skipped():
    """git worktree remove is governed by bash_worktree_removal — not this policy."""
    req = make_request(
        "cd /project && git worktree remove .worktrees/feature-old",
    )
    decision = check(req)
    assert decision is None


def test_git_worktree_prune_skipped():
    """git worktree prune is maintenance, not creation — pass through."""
    req = make_request("git worktree prune")
    decision = check(req)
    assert decision is None


def test_empty_command_skipped():
    """Empty command must never produce a decision."""
    req = make_request("")
    decision = check(req)
    assert decision is None


# ---------------------------------------------------------------------------
# Integration: register() wires the policy into a registry
# ---------------------------------------------------------------------------


def test_register_wires_policy():
    """register() must add bash_worktree_creation to the registry at priority 350."""
    from runtime.core.policies.bash_worktree_creation import register
    from runtime.core.policy_engine import PolicyRegistry

    registry = PolicyRegistry()
    register(registry)

    policies = registry.list_policies()
    names = [p.name for p in policies]
    assert "bash_worktree_creation" in names

    info = next(p for p in policies if p.name == "bash_worktree_creation")
    assert info.priority == 350
    assert "Bash" in info.event_types or "PreToolUse" in info.event_types


# ---------------------------------------------------------------------------
# Capability-gate invariant tests (Phase 3)
# ---------------------------------------------------------------------------


def test_guardian_provision_stage_resolves_via_capability():
    """guardian:provision stage resolves to CAN_PROVISION_WORKTREE.

    capabilities_for("guardian:provision") must return a set containing
    CAN_PROVISION_WORKTREE. Bare "guardian" no longer resolves (DEC-WHO-LANDING-ALIAS-001).
    """
    from runtime.core.authority_registry import CAN_PROVISION_WORKTREE, capabilities_for

    caps = capabilities_for("guardian:provision")
    assert CAN_PROVISION_WORKTREE in caps


def test_capability_gate_not_role_string():
    """Capability presence — not the role string — controls authorization.

    A context with role="unknown_role" but CAN_PROVISION_WORKTREE injected
    should pass. Proves the policy uses context.capabilities.
    """
    import dataclasses
    from runtime.core.authority_registry import CAN_PROVISION_WORKTREE

    ctx = dataclasses.replace(
        _ctx("unknown_role"),
        capabilities=frozenset({CAN_PROVISION_WORKTREE}),
    )
    req = make_request(
        "git worktree add .worktrees/feature-foo -b feature/foo",
        context=ctx,
    )
    assert check(req) is None


def test_guardian_without_capability_is_denied():
    """Guardian role string alone is not sufficient — capability must be present.

    Simulates a context where the role is "guardian" but capabilities is empty.
    """
    import dataclasses

    ctx = dataclasses.replace(
        _ctx("guardian"),
        capabilities=frozenset(),
    )
    req = make_request(
        "git worktree add .worktrees/feature-foo -b feature/foo",
        context=ctx,
    )
    result = check(req)
    assert result is not None
    assert result.action == "deny"
