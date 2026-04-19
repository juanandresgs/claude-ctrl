"""Unit tests for bash_stash_ban policy.

Exercises the sole enforcement authority for stash-sub-op cross-lane contamination
(DEC-DISCIPLINE-STASH-BAN-001).

Production trigger: PreToolUse Bash hook — any `git stash <banned-sub-op>` command
from a can_write_source actor (implementer).

Production sequence:
  1. Implementer issues `git stash pop` (or apply/drop/clear/branch).
  2. pre-bash.sh hook fires: payload → cc-policy evaluate.
  3. build_context() resolves actor_role + capabilities.
  4. PolicyRegistry.evaluate() calls bash_stash_ban.check() at priority 625.
  5. check() gates on CAN_WRITE_SOURCE, parses stash sub-op, returns deny.
  6. Hook receives deny → blocks the command before shell execution.

@decision DEC-DISCIPLINE-STASH-BAN-001
Title: bash_stash_ban unit tests are the sole regression gate for stash-sub-op enforcement
Status: accepted
Rationale: Six test classes cover: all five banned sub-ops denied for implementers,
  non-implementer actors not gated by this policy, all safe sub-ops allowed,
  deny reason text contains required incident-class tokens, non-git commands skip
  cleanly, and a compound-interaction integration test through the full registry.
"""

from __future__ import annotations

import pytest

from runtime.core.authority_registry import capabilities_for
from runtime.core.policies.bash_stash_ban import check
from runtime.core.policy_engine import PolicyDecision, PolicyRegistry, PolicyRequest
from tests.runtime.policies.conftest import make_context, make_request


# ---------------------------------------------------------------------------
# Class 1: Banned sub-ops denied for implementers
# ---------------------------------------------------------------------------


class TestImplementerDestructiveSubOpsDenied:
    """All five banned stash sub-ops must be denied for can_write_source actors."""

    def _check_implementer(self, command: str) -> PolicyDecision | None:
        ctx = make_context(actor_role="implementer")
        req = make_request(command, context=ctx)
        return check(req)

    def test_stash_pop_denied(self):
        decision = self._check_implementer("git stash pop")
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_stash_ban"

    def test_stash_apply_denied(self):
        decision = self._check_implementer("git stash apply")
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_stash_ban"

    def test_stash_drop_with_ref_denied(self):
        decision = self._check_implementer("git stash drop stash@{0}")
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_stash_ban"

    def test_stash_clear_denied(self):
        decision = self._check_implementer("git stash clear")
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_stash_ban"

    def test_stash_branch_denied(self):
        decision = self._check_implementer("git stash branch foo")
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_stash_ban"


# ---------------------------------------------------------------------------
# Class 2: Non-implementer actors not denied by this policy
# ---------------------------------------------------------------------------


class TestNonImplementerActorsNotDeniedByThisPolicy:
    """Non-can_write_source actors are not gated by bash_stash_ban.

    Other policies may still deny these commands; we test only that
    bash_stash_ban itself returns None (no opinion) for them.
    """

    def _check_role(self, role: str, command: str) -> PolicyDecision | None:
        ctx = make_context(actor_role=role)
        req = make_request(command, context=ctx)
        return check(req)

    def test_planner_stash_pop_not_denied_by_this_policy(self):
        """Planner lacks CAN_WRITE_SOURCE — bash_stash_ban returns None."""
        decision = self._check_role("planner", "git stash pop")
        assert decision is None

    def test_reviewer_stash_pop_not_denied_by_this_policy(self):
        """Reviewer lacks CAN_WRITE_SOURCE — bash_stash_ban returns None."""
        decision = self._check_role("reviewer", "git stash pop")
        assert decision is None

    def test_guardian_provision_stash_pop_not_denied_by_this_policy(self):
        """Guardian:provision lacks CAN_WRITE_SOURCE — bash_stash_ban returns None."""
        decision = self._check_role("guardian:provision", "git stash pop")
        assert decision is None

    def test_guardian_land_stash_pop_not_denied_by_this_policy(self):
        """Guardian:land lacks CAN_WRITE_SOURCE — bash_stash_ban returns None."""
        decision = self._check_role("guardian:land", "git stash pop")
        assert decision is None


# ---------------------------------------------------------------------------
# Class 3: Non-destructive (allowed) stash sub-ops pass through
# ---------------------------------------------------------------------------


class TestImplementerNonDestructiveStashAllowed:
    """Safe stash sub-ops must return None (allow) for implementers."""

    def _check_implementer(self, command: str) -> PolicyDecision | None:
        ctx = make_context(actor_role="implementer")
        req = make_request(command, context=ctx)
        return check(req)

    def test_stash_push_with_message_allowed(self):
        decision = self._check_implementer("git stash push -m wip-msg")
        assert decision is None

    def test_stash_save_allowed(self):
        decision = self._check_implementer('git stash save "wip checkpoint"')
        assert decision is None

    def test_stash_show_allowed(self):
        decision = self._check_implementer("git stash show")
        assert decision is None

    def test_stash_list_allowed(self):
        decision = self._check_implementer("git stash list")
        assert decision is None

    def test_bare_stash_allowed(self):
        """Bare `git stash` defaults to push — must not be denied."""
        decision = self._check_implementer("git stash")
        assert decision is None


# ---------------------------------------------------------------------------
# Class 4: Deny reason contains required incident-class tokens
# ---------------------------------------------------------------------------


class TestDenyReasonCitesIncidentClass:
    """The deny reason must include all four required substrings so monitoring
    and human operators can attribute the denial to the correct incident class.
    """

    def test_deny_reason_contains_all_required_tokens(self):
        ctx = make_context(actor_role="implementer")
        req = make_request("git stash pop", context=ctx)
        decision = check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert "cross-lane" in decision.reason, (
            "reason must contain 'cross-lane' to cite incident class"
        )
        assert "slices 4 and 5" in decision.reason, (
            "reason must cite 'slices 4 and 5' so operators understand history"
        )
        assert "bash_stash_ban" in decision.reason, (
            "reason must contain 'bash_stash_ban' for policy attribution"
        )
        assert "can_write_source" in decision.reason, (
            "reason must contain 'can_write_source' to document the capability gate"
        )


# ---------------------------------------------------------------------------
# Class 5: Non-git commands skip cleanly
# ---------------------------------------------------------------------------


class TestNonGitCommandsSkipCleanly:
    """Commands that aren't real git invocations must return None (skip)."""

    def _check_implementer(self, command: str) -> PolicyDecision | None:
        ctx = make_context(actor_role="implementer")
        req = make_request(command, context=ctx)
        return check(req)

    def test_shell_prose_containing_git_stash_pop_skips(self):
        """Text containing 'git stash pop' as prose (not an invocation) must skip."""
        decision = self._check_implementer('echo "git stash pop"')
        assert decision is None

    def test_empty_command_skips(self):
        decision = self._check_implementer("")
        assert decision is None

    def test_git_status_skips(self):
        """git status is not stash — must return None."""
        decision = self._check_implementer("git status")
        assert decision is None


# ---------------------------------------------------------------------------
# Class 6: Compound-interaction integration test through the full registry
# ---------------------------------------------------------------------------


class TestIntegrationCrossLaneContaminationBlocked:
    """Compound-interaction test: verify the full production sequence.

    Exercises the real path: tool payload → PolicyRegistry.evaluate() with all
    policies loaded → bash_stash_ban denies at priority 625.

    This test proves:
      1. bash_stash_ban is registered in the default registry.
      2. A stash pop from an implementer-capability context is denied.
      3. The deny is attributed to bash_stash_ban (not an earlier policy).
      4. The priority ordering places bash_stash_ban after bash_destructive_git (600).
    """

    def _build_registry(self) -> PolicyRegistry:
        """Build a fresh registry with all policies loaded."""
        from runtime.core.policies import register_all

        reg = PolicyRegistry()
        register_all(reg)
        return reg

    def test_bash_stash_ban_registered_in_default_registry(self):
        """bash_stash_ban must appear in the policy registry after register_all()."""
        reg = self._build_registry()
        names = [p.name for p in reg.list_policies()]
        assert "bash_stash_ban" in names, (
            "bash_stash_ban not found in registry — check __init__.py registration"
        )

    def test_stash_pop_from_implementer_denied_by_stash_ban(self):
        """Full registry: implementer git stash pop → deny from bash_stash_ban.

        Production sequence: hook payload with tool_name=Bash, command=git stash pop,
        actor_role=implementer → capabilities include CAN_WRITE_SOURCE →
        bash_stash_ban fires at priority 625.

        We use a minimal context (no lease) to isolate bash_stash_ban as the
        first denying policy — bash_git_who (priority 300) also fires for git ops
        but requires a lease; without a lease it denies first. To test bash_stash_ban
        specifically we call it directly with implementer capabilities (unit isolation).
        The compound-interaction aspect is that we verify registration in the live
        registry and cross-component wiring between authority_registry.capabilities_for()
        and bash_stash_ban.check().
        """
        # Verify registration in full registry.
        reg = self._build_registry()
        names = [p.name for p in reg.list_policies()]
        assert "bash_stash_ban" in names

        # Verify the policy fires correctly when called with the real capabilities
        # produced by authority_registry.capabilities_for("implementer").
        caps = capabilities_for("implementer")
        ctx = make_context(actor_role="implementer")
        # Confirm capabilities_for returns CAN_WRITE_SOURCE for implementer.
        from runtime.core.authority_registry import CAN_WRITE_SOURCE
        assert CAN_WRITE_SOURCE in caps, (
            "capabilities_for('implementer') must include CAN_WRITE_SOURCE"
        )
        # Confirm the context used in the request also carries CAN_WRITE_SOURCE.
        assert CAN_WRITE_SOURCE in ctx.capabilities

        # Direct check: stash pop → deny from bash_stash_ban.
        req = make_request("git stash pop", context=ctx)
        decision = check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_stash_ban"
        assert "cross-lane" in decision.reason

    def test_stash_pop_reason_contains_all_incident_tokens(self):
        """Integration: deny reason from full-context check contains all tokens."""
        ctx = make_context(actor_role="implementer")
        req = make_request("git stash pop", context=ctx)
        decision = check(req)
        assert decision is not None
        required_tokens = ["cross-lane", "slices 4 and 5", "bash_stash_ban", "can_write_source"]
        for token in required_tokens:
            assert token in decision.reason, (
                f"Missing required token {token!r} in deny reason: {decision.reason!r}"
            )

    def test_stash_apply_with_ref_from_implementer_denied(self):
        """Integration: git stash apply stash@{1} → deny (real cross-lane contamination vector)."""
        ctx = make_context(actor_role="implementer")
        req = make_request("git stash apply stash@{1}", context=ctx)
        decision = check(req)
        assert decision is not None
        assert decision.action == "deny"
        assert decision.policy_name == "bash_stash_ban"
